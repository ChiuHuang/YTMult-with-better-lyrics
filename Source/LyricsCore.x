#import "LyricsShared.h"

BOOL _safe_cache_component(NSString *s);

@interface NSObject (YTMUQueuePrecache)
- (NSArray *)queueItems;
- (NSString *)videoId;
- (NSString *)contentVideoId;
@end

double g_currentPlaybackTime = 0.0;
NSString *g_currentVideoID = nil;
__weak YTPlayerViewController *g_activePlayer = nil;
__weak UIButton *g_ytmuOwnLyricsButton = nil;
NSMutableDictionary *g_lyricsCache = nil;
NSString *g_globalLoadingVideoID = nil;
BOOL g_globalLoadingInFlight = NO;
NSDate *g_loadingSince = nil;
__weak id g_activeEngagementPanelContainer = nil;

void YTMUReleaseGlobalFetch(void) {
    g_globalLoadingInFlight = NO;
    g_globalLoadingVideoID = nil;
    g_loadingSince = nil;
}

BOOL YTMULyricsPreference(NSString *key, BOOL fallback) {
    NSDictionary *settings = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    id value = settings[key];
    return value ? [value boolValue] : fallback;
}

static NSString *YTMULyricsOffsetKey(NSString *videoID) {
    return [NSString stringWithFormat:@"lyricsTimingOffset_%@", videoID];
}
double YTMULyricsOffsetForVideoID(NSString *videoID) {
    if (!videoID.length) return 0.0;
    NSDictionary *settings = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    return [settings[YTMULyricsOffsetKey(videoID)] doubleValue];
}
void YTMULyricsSetOffsetForVideoID(NSString *videoID, double offset) {
    if (!videoID.length) return;
    if (offset > 30.0) offset = 30.0;
    if (offset < -30.0) offset = -30.0;
    NSMutableDictionary *d = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"] mutableCopy];
    if (!d) d = [NSMutableDictionary dictionary];
    if (offset == 0.0) [d removeObjectForKey:YTMULyricsOffsetKey(videoID)];
    else d[YTMULyricsOffsetKey(videoID)] = @(offset);
    [[NSUserDefaults standardUserDefaults] setObject:d forKey:@"YTMUltimate"];
}

NSString *YTMUApiBase(void) {
    NSDictionary *settings = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    NSString *base = settings[@"lyricsApiEndpoint"];
    if (![base isKindOfClass:[NSString class]] || !base.length) return @"https://ytmtranslate.chiuhuang.dev";
    while ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];
    return base;
}
NSString *YTMUTargetLang(void) {
    NSDictionary *settings = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    NSString *lang = settings[@"lyricsTargetLang"];
    if (![lang isKindOfClass:[NSString class]] || !lang.length) return @"zh-TW";
    return lang;
}
NSString *YTMUAutoZhParam(void) {
    NSDictionary *settings = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    id value = settings[@"lyricsAutoZhConvert"];
    BOOL enabled = value ? [value boolValue] : YES;
    return enabled ? @"&az=1" : @"";
}
NSString *YTMUUrlEncode(NSString *s) {
    return [s stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: s;
}

NSString *YTMULyricsTier(NSArray *lyrics) {
    for (NSDictionary *l in lyrics) {
        if (l[@"wordSynced"] && [l[@"parts"] count] > 1) return @"wbw";
    }
    for (NSDictionary *l in lyrics) {
        if ([l[@"time"] doubleValue] > 0.0) return @"line";
    }
    return @"raw";
}

void sendDebugLog(NSString *msg) {
    NSString *full = msg;
    if (g_currentVideoID) {
        full = [NSString stringWithFormat:@"%@ [v=%@ t=%.1f]", msg, g_currentVideoID, g_currentPlaybackTime];
    }
    NSLog(@"[YTMU] %@", full);
    NSString *encodedMsg = YTMUUrlEncode(full);
    NSString *serverURL = [NSString stringWithFormat:@"%@/api/lyrics?v=DEBUG_%@", YTMUApiBase(), encodedMsg];
    [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:serverURL]] resume];
}
void __attribute__((unused)) sendDebugLogWithPayload(NSString *event, NSString *msg, NSDictionary *payload) {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:payload ?: @{}];
    if (g_currentVideoID) dict[@"videoId"] = g_currentVideoID;
    dict[@"playbackTime"] = @(g_currentPlaybackTime);
    NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"type": @"APP_LOG", @"event": event, @"level": @"info", @"message": msg, @"payload": dict} options:0 error:nil];
    if (json) {
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"%@/log", YTMUApiBase()]]];
        req.HTTPMethod = @"POST";
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        req.HTTPBody = json;
        [[[NSURLSession sharedSession] dataTaskWithRequest:req] resume];
    }
    sendDebugLog([NSString stringWithFormat:@"%@: %@ %@", event, msg, dict]);
}

NSString *YTMULyricsCacheDirectory(void) {
    NSString *cache = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [cache stringByAppendingPathComponent:@"YTMU_LyricsCache"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}
NSString *YTMULyricsCachePathForVideoID(NSString *vid) {
    if (!vid.length) return nil;
    NSString *safe = [vid stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [[YTMULyricsCacheDirectory() stringByAppendingPathComponent:safe] stringByAppendingPathExtension:@"json"];
}
BOOL YTMULyricsCacheEnabled(void) {
    NSDictionary *s = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    if (!s[@"lyricsCacheEnabled"]) return YES;
    return [s[@"lyricsCacheEnabled"] boolValue];
}
NSInteger YTMULyricsCacheMaxCount(void) {
    NSDictionary *s = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    NSInteger v = [s[@"lyricsCacheMaxCount"] integerValue];
    return v > 0 ? v : 200;
}
NSInteger YTMULyricsCacheMaxSizeMB(void) {
    NSDictionary *s = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    NSInteger v = [s[@"lyricsCacheMaxSizeMB"] integerValue];
    return v > 0 ? v : 50;
}
NSInteger YTMULyricsCacheFormatVersion(void) {
    // Bump when the lyrics array shape changes in a way that makes old cached
    // data invalid (real per-word durations / last-word timing). Sent to the
    // server as `cv` on /api/lyrics/check; older values make the server answer
    // upgrade=1 so the client refetches and self-heals.
    return 2;
}
NSInteger YTMULyricsCacheVersionForVideoID(NSString *videoID) {
    if (!videoID.length) return 0;
    NSString *path = YTMULyricsCachePathForVideoID(videoID);
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return 0;
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![dict isKindOfClass:[NSDictionary class]]) return 0;
    return [dict[@"cv"] integerValue];
}
void YTMULyricsCacheSave(NSString *videoID, NSArray *lyrics) {
    if (!YTMULyricsCacheEnabled() || !videoID.length || !lyrics) return;
    NSString *path = YTMULyricsCachePathForVideoID(videoID);
    if (!path) return;
    NSDictionary *dict = @{@"lyrics": lyrics, @"ts": @([[NSDate date] timeIntervalSince1970]), @"videoID": videoID, @"cv": @(YTMULyricsCacheFormatVersion())};
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    if (data) [data writeToFile:path atomically:YES];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        NSString *dir = YTMULyricsCacheDirectory();
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
        if (!files) return;
        NSInteger maxCount = YTMULyricsCacheMaxCount();
        if ((NSInteger)files.count > maxCount) {
            NSMutableArray *infos = [NSMutableArray array];
            for (NSString *f in files) {
                NSString *fp = [dir stringByAppendingPathComponent:f];
                NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:fp error:nil];
                NSDate *mod = attr[NSFileModificationDate] ?: [NSDate distantPast];
                [infos addObject:@{@"path": fp, @"date": mod}];
            }
            [infos sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b){
                return [a[@"date"] compare:b[@"date"]];
            }];
            NSInteger toRemove = files.count - maxCount;
            for (NSInteger i=0; i<toRemove; i++) {
                [[NSFileManager defaultManager] removeItemAtPath:infos[i][@"path"] error:nil];
            }
        }
        NSInteger maxBytes = YTMULyricsCacheMaxSizeMB() * 1024 * 1024;
        NSArray *allFiles = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
        unsigned long long total = 0;
        NSMutableArray *sized = [NSMutableArray array];
        for (NSString *f in allFiles) {
            NSString *fp = [dir stringByAppendingPathComponent:f];
            NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:fp error:nil];
            unsigned long long sz = [attr fileSize];
            NSDate *mod = attr[NSFileModificationDate] ?: [NSDate distantPast];
            total += sz;
            [sized addObject:@{@"path": fp, @"size": @(sz), @"date": mod}];
        }
        if (total > (unsigned long long)maxBytes) {
            [sized sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b){
                return [a[@"date"] compare:b[@"date"]];
            }];
            for (NSDictionary *info in sized) {
                if (total <= (unsigned long long)maxBytes) break;
                [[NSFileManager defaultManager] removeItemAtPath:info[@"path"] error:nil];
                total -= [info[@"size"] unsignedLongLongValue];
            }
        }
    });
}
NSArray *YTMULyricsCacheLoad(NSString *videoID) {
    if (!YTMULyricsCacheEnabled() || !videoID.length) return nil;
    NSString *path = YTMULyricsCachePathForVideoID(videoID);
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSArray *lyrics = dict[@"lyrics"];
    if ([lyrics isKindOfClass:[NSArray class]] && lyrics.count) {
        NSTimeInterval ts = [dict[@"ts"] doubleValue];
        if (ts > 0 && [[NSDate date] timeIntervalSince1970] - ts > 7*24*3600) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            return nil;
        }
        return lyrics;
    }
    return nil;
}
NSDictionary * __attribute__((unused)) YTMULyricsCacheStats(void) {
    NSString *dir = YTMULyricsCacheDirectory();
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil] ?: @[];
    unsigned long long total = 0;
    for (NSString *f in files) {
        NSString *fp = [dir stringByAppendingPathComponent:f];
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:fp error:nil];
        total += [attr fileSize];
    }
    return @{@"count": @(files.count), @"size": @(total), @"sizeMB": @(total/1024.0/1024.0)};
}
void __attribute__((unused)) YTMULyricsCacheClearAll(void) {
    NSString *dir = YTMULyricsCacheDirectory();
    [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    if (g_lyricsCache) [g_lyricsCache removeAllObjects];
}

void YTMULyricsPrecacheQueue(NSArray *videoIDs, NSString *lang, BOOL useFull) {
    if (!videoIDs || videoIDs.count == 0) return;
    if (!lang.length) lang = YTMUTargetLang();
    
    NSString *apiBase = YTMUApiBase();
    NSString *urlStr = [NSString stringWithFormat:@"%@/api/lyrics/precache", apiBase];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return;
    
    NSMutableArray *validVids = [NSMutableArray array];
    for (NSString *vid in videoIDs) {
        if ([vid isKindOfClass:[NSString class]] && vid.length && _safe_cache_component(vid)) {
            [validVids addObject:vid];
            if (validVids.count >= 20) break;
        }
    }
    if (validVids.count == 0) return;
    
    NSMutableDictionary *body = [NSMutableDictionary dictionary];
    body[@"video_ids"] = validVids;
    body[@"lang"] = lang;
    if (useFull) body[@"full"] = @YES;
    
    NSString *jwt = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"][@"ytmuJwtToken"];
    if (jwt && jwt.length) body[@"jwt"] = jwt;
    
    NSData *jsonBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if (!jsonBody) return;
    
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = jsonBody;
    req.timeoutInterval = 10.0;
    
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            sendDebugLog([NSString stringWithFormat:@"[PRECACHE] Request failed: %@", error.localizedDescription]);
            return;
        }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (http.statusCode != 200) {
            sendDebugLog([NSString stringWithFormat:@"[PRECACHE] HTTP %ld", (long)http.statusCode]);
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (!json) return;
        sendDebugLog([NSString stringWithFormat:@"[PRECACHE] Queued %@ videos (job: %@)", @(validVids.count), json[@"job_id"] ?: @"?"]);
    }] resume];
}

BOOL _safe_cache_component(NSString *s) {
    if (!s || !s.length) return NO;
    NSCharacterSet *invalid = [NSCharacterSet characterSetWithCharactersInString:@":/\\?%*|\"<>"];
    return [s rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

// Queue precache trigger - hook into queue model changes
%hook YTMQueueConfigImpl

- (void)setQueueModel:(id)queueModel {
    %orig(queueModel);
    
    // Extract up-next video IDs for precaching
    if (!YTMULyricsPreference(@"lyricsPrecacheQueue", YES)) return;
    
    NSArray *items = nil;
    if ([queueModel respondsToSelector:@selector(items)]) {
        items = [queueModel items];
    } else if ([queueModel respondsToSelector:@selector(queueItems)]) {
        items = [queueModel queueItems];
    }
    
    if (!items || items.count <= 1) return; // Only current playing
    
    NSMutableArray *upNext = [NSMutableArray array];
    NSInteger maxPrecache = 5; // Next 5 songs
    for (id item in items) {
        if ([upNext count] >= maxPrecache) break;
        
        NSString *vid = nil;
        if ([item respondsToSelector:@selector(videoId)]) {
            @try { vid = [item videoId]; } @catch (NSException *e) { vid = nil; }
        } else if ([item respondsToSelector:@selector(contentVideoId)]) {
            @try { vid = [item contentVideoId]; } @catch (NSException *e) { vid = nil; }
        }
        
        if (vid && vid.length && _safe_cache_component(vid)) {
            // Skip currently playing
            if (![vid isEqualToString:g_currentVideoID]) {
                [upNext addObject:vid];
            }
        }
    }
    
    if ([upNext count] > 0) {
        // Use fast pipeline for speed
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            YTMULyricsPrecacheQueue(upNext, YTMUTargetLang(), NO);
        });
    }
}

%end

NSString *YTMUResolveCurrentVideoID(void) {
    if (g_currentVideoID.length) return g_currentVideoID;
    YTPlayerViewController *player = g_activePlayer;
    if (player) {
        NSString *vid = nil;
        if ([player respondsToSelector:@selector(currentVideoID)]) {
            @try { vid = [player currentVideoID]; } @catch (NSException *e) { vid = nil; }
        }
        if (!vid.length && [player respondsToSelector:@selector(contentVideoID)]) {
            @try { vid = [player contentVideoID]; } @catch (NSException *e) { vid = nil; }
        }
        if (vid.length) {
            g_currentVideoID = [vid copy];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"YTMUSongDidChange" object:g_currentVideoID];
            return g_currentVideoID;
        }
    }
    return nil;
}

%hook YTPlayerViewController
- (void)playbackController:(id)arg1 didActivateVideo:(id)arg2 withPlaybackData:(id)arg3 {
    %orig;
    g_activePlayer = self;
    g_currentPlaybackTime = 0.0;
    if (self.currentVideoID) {
        if (![self.currentVideoID isEqualToString:g_currentVideoID]) {
            g_currentVideoID = self.currentVideoID;
            [[NSNotificationCenter defaultCenter] postNotificationName:@"YTMUSongDidChange" object:g_currentVideoID];
        } else {
            [[NSNotificationCenter defaultCenter] postNotificationName:@"YTMUSongDidChange" object:g_currentVideoID];
        }
    } else {
        sendDebugLog(@"[WARN] didActivateVideo fired but currentVideoID is nil");
    }
}

- (void)playbackController:(id)arg1 didReceivePlaybackPositionTime:(double)time {
    %orig;
    g_currentPlaybackTime = time;
    if (!g_currentVideoID.length && [self respondsToSelector:@selector(currentVideoID)]) {
        NSString *vid = nil;
        @try { vid = [self currentVideoID]; } @catch (NSException *e) { vid = nil; }
        if (vid.length) {
            g_currentVideoID = [vid copy];
            sendDebugLog([NSString stringWithFormat:@"[MUSIC] Recovered videoID from playback position: %@", vid]);
            [[NSNotificationCenter defaultCenter] postNotificationName:@"YTMUSongDidChange" object:g_currentVideoID];
        }
    }
}
%end

static NSString *dumpViewHierarchy(UIView *view, int indent) {
    if (!view) return @"";
    NSMutableString *str = [NSMutableString string];
    for (int i = 0; i < indent; i++) [str appendString:@"  "];
    [str appendFormat:@"<%@: %p; frame = (%.1f, %.1f; %.1f, %.1f); hidden = %@; alpha = %.2f; userInteraction = %@",
        NSStringFromClass([view class]), view,
        view.frame.origin.x, view.frame.origin.y, view.frame.size.width, view.frame.size.height,
        view.hidden ? @"YES" : @"NO", view.alpha,
        view.userInteractionEnabled ? @"YES" : @"NO"];
    if (view.tag != 0) {
        [str appendFormat:@"; tag = %ld", (long)view.tag];
    }
    if ([view isKindOfClass:[UILabel class]]) {
        [str appendFormat:@"; text = \"%@\"", ((UILabel *)view).text ?: @""];
    } else if ([view isKindOfClass:[UIButton class]]) {
        [str appendFormat:@"; title = \"%@\"", [((UIButton *)view) titleForState:UIControlStateNormal] ?: @""];
    }
    if (view.gestureRecognizers.count > 0) {
        [str appendFormat:@"; gestures = %lu", (unsigned long)view.gestureRecognizers.count];
    }
    [str appendString:@">\n"];
    for (UIView *sub in view.subviews) {
        [str appendString:dumpViewHierarchy(sub, indent + 1)];
    }
    return str;
}

static NSString *dumpVCHierarchy(UIViewController *vc, int indent) {
    if (!vc) return @"";
    NSMutableString *str = [NSMutableString string];
    for (int i = 0; i < indent; i++) [str appendString:@"  "];
    [str appendFormat:@"<%@: %p; title = \"%@\"; view = %p; isViewLoaded = %@>\n",
        NSStringFromClass([vc class]), vc, vc.title ?: @"", vc.isViewLoaded ? vc.view : nil,
        vc.isViewLoaded ? @"YES" : @"NO"];
    for (UIViewController *child in vc.childViewControllers) {
        [str appendString:dumpVCHierarchy(child, indent + 1)];
    }
    if (vc.presentedViewController && vc.presentedViewController != vc) {
        for (int i = 0; i < indent + 1; i++) [str appendString:@"  "];
        [str appendString:@"[Presented] ->\n"];
        [str appendString:dumpVCHierarchy(vc.presentedViewController, indent + 2)];
    }
    return str;
}

static void sendUIDump(void) {
    NSMutableString *dump = [NSMutableString string];
    [dump appendFormat:@"=== SCREENSHOT UI DUMP at %@ ===\n", [NSDate date]];
    [dump appendFormat:@"Tweak Build: %@\n", @TWEAK_GIT_COMMIT];
    [dump appendFormat:@"Current VideoID: %@\n", g_currentVideoID ?: @"(none)"];
    [dump appendFormat:@"Playback Time: %f\n", g_currentPlaybackTime];
    YTPlayerViewController *dbgPlayer = g_activePlayer;
    if (dbgPlayer) {
        NSString *dbgCurrent = nil, *dbgContent = nil;
        if ([dbgPlayer respondsToSelector:@selector(currentVideoID)]) {
            @try { dbgCurrent = [dbgPlayer currentVideoID]; } @catch (NSException *e) { dbgCurrent = nil; }
        }
        if ([dbgPlayer respondsToSelector:@selector(contentVideoID)]) {
            @try { dbgContent = [dbgPlayer contentVideoID]; } @catch (NSException *e) { dbgContent = nil; }
        }
        [dump appendFormat:@"ActivePlayer: %@ currentVideoID=%@ contentVideoID=%@\n\n",
            NSStringFromClass([dbgPlayer class]), dbgCurrent ?: @"(nil)", dbgContent ?: @"(nil)"];
    } else {
        [dump appendString:@"ActivePlayer: (nil)\n\n"];
    }

    UIWindow *keyWin = [UIApplication sharedApplication].keyWindow;
    if (!keyWin) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow || w.rootViewController) { keyWin = w; break; }
        }
    }

    [dump appendString:@"--- VIEW CONTROLLER HIERARCHY ---\n"];
    if (keyWin && keyWin.rootViewController) {
        [dump appendString:dumpVCHierarchy(keyWin.rootViewController, 0)];
    }

    [dump appendString:@"\n--- WINDOWS & VIEW HIERARCHY ---\n"];
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        [dump appendFormat:@"[WINDOW: %@; frame = (%.1f, %.1f; %.1f, %.1f)]\n",
            NSStringFromClass([w class]), w.frame.origin.x, w.frame.origin.y, w.frame.size.width, w.frame.size.height];
        [dump appendString:dumpViewHierarchy(w, 1)];
    }

    NSDictionary *payload = @{
        @"type": @"UI_DUMP",
        @"request_body": dump
    };
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (jsonData) {
        sendDebugLog(@" Screenshot detected, uploading UI dump...");
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"%@/log", YTMUApiBase()]]];
        req.HTTPMethod = @"POST";
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        req.HTTPBody = jsonData;
        [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
            if (err) {
                sendDebugLog([NSString stringWithFormat:@"[FAIL] UI Dump upload failed: %@", err.localizedDescription]);
            } else {
                sendDebugLog(@"[OK] UI Dump uploaded successfully!");
            }
        }] resume];
    }
}

UIViewController *topMostViewController(void) {
    UIWindow *keyWin = [UIApplication sharedApplication].keyWindow;
    if (!keyWin) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow || w.rootViewController) { keyWin = w; break; }
        }
    }
    UIViewController *top = keyWin.rootViewController;
    while (top.presentedViewController) {
        top = top.presentedViewController;
    }
    return top;
}

BOOL isLyricsEngagementPanel(UIViewController *vc) {
    if (!vc) return NO;
    id obj = (id)vc;

    if ([obj respondsToSelector:@selector(panelIdentifier)]) {
    id pidObj = [obj performSelector:@selector(panelIdentifier)];
    NSString *pid = nil;
    if ([pidObj isKindOfClass:[NSString class]]) {
        pid = pidObj;
    } else if (pidObj) {
        pid = [pidObj description];
    }
    if ([pid.lowercaseString containsString:@"lyric"]) return YES;
}

    if ([obj respondsToSelector:@selector(model)]) {
        id model = [obj performSelector:@selector(model)];
        if (model) {
            NSString *desc = [model description].lowercaseString;
            if ([desc containsString:@"lyric"]) return YES;
        }
    }

    if (vc.title && (
        [vc.title containsString:@"歌詞"] ||
        [vc.title containsString:@"歌词"] ||
        [vc.title.lowercaseString containsString:@"lyric"])) {
        return YES;
    }

    for (UIView *sub in vc.view.subviews) {
        if ([NSStringFromClass([sub class]) containsString:@"EngagementPanelHeader"]) {
            for (UIView *hSub in sub.subviews) {
                if ([hSub isKindOfClass:[UILabel class]]) {
                    NSString *htxt = [(UILabel *)hSub text];
                    if (htxt && (
                        [htxt containsString:@"歌詞"] ||
                        [htxt containsString:@"歌词"] ||
                        [htxt.lowercaseString containsString:@"lyric"])) {
                        return YES;
                    }
                }
            }
        }
    }

    return NO;
}

BOOL isLyricsViewVisibleOnScreen(void) {
    UIWindow *win = [UIApplication sharedApplication].keyWindow;
    if (!win) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow || w.rootViewController) { win = w; break; }
        }
    }
    if (!win) return NO;
    UIView *existing = [win viewWithTag:9999];
    if (!existing || existing.hidden || existing.alpha < 0.05 || !existing.window) return NO;
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    CGRect r = [existing convertRect:existing.bounds toView:nil];
    CGRect isect = CGRectIntersection(screenBounds, r);
    return (isect.size.width > 50 && isect.size.height > 100);
}

%hook YTMAppDelegate
- (BOOL)application:(id)app didFinishLaunchingWithOptions:(id)options {
    BOOL result = %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [[YTMUTurnstileManager sharedManager] getJWTTokenWithCompletion:nil];
    });
    return result;
}
%end

%ctor {
    %init;
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationUserDidTakeScreenshotNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if (YTMULyricsPreference(@"sendLyricsScreenshotDebug", NO)) {
            sendUIDump();
        }
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:@"YTMUClearMemoryCache" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if (g_lyricsCache) [g_lyricsCache removeAllObjects];
    }];
    void (^prewarmJWT)(NSNotification *) = ^(NSNotification *note) {
        [[YTMUTurnstileManager sharedManager] getJWTTokenWithCompletion:nil];
    };
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:prewarmJWT];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:prewarmJWT];
}
