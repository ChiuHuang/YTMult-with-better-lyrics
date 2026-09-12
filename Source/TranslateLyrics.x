#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "YTMUTurnstileManager.h"
#import "Headers/YTPlayerViewController.h"
#import "Headers/YTIButtonRenderer.h"
#import "Headers/YTMNowPlayingViewController.h"
#import "Headers/ELMNodeController.h"
#import "Headers/YTMActionRowView.h"

#ifndef TWEAK_GIT_COMMIT
#define TWEAK_GIT_COMMIT "unknown"
#endif

@interface UIView ()
- (UIViewController *)_viewControllerForAncestor;
@end

@interface ELMTouchCommandPropertiesHandler : NSObject
- (void)handleTap;
@end

@interface YTIButtonRenderer ()
- (BOOL)isDisabled;
@end

@interface YTMNowPlayingViewController (YTMULyrics)
- (void)ytmu_makeLyricsViewClickable:(UIView *)v;
- (void)ytmu_didTapLyricsBar:(UITapGestureRecognizer *)gesture;
- (BOOL)ytmu_replaceLyricsChip:(UIView *)official;
@end

@interface YTPlayerViewController (YTMUExt)
- (double)currentMediaTime;
- (void)seekToTime:(double)time toleranceBefore:(double)before toleranceAfter:(double)after;
@end

// Global current time updated by player hook
static double g_currentPlaybackTime = 0.0;

@interface YTFormattedStringLabel : UILabel
@end

@interface YTMLightweightMusicDescriptionShelfCell : UIView
@property (retain, nonatomic) UITextView *lyrics;
@end

static NSString *g_currentVideoID = nil;
static __weak YTPlayerViewController *g_activePlayer = nil;
static NSMutableDictionary *g_lyricsCache = nil;
// Global in-flight guard: prevents multiple VC instances from firing parallel
// requests for the same video. Only one full fetch runs at a time across all VCs.
static NSString *g_globalLoadingVideoID = nil; // videoID currently being fetched
static BOOL g_globalLoadingInFlight = NO;      // YES while a full request chain is active
static NSDate *g_loadingSince = nil;           // when the current fetch claimed the slot

// Release the global fetch slot (always clears the watchdog timestamp too)
static void YTMUReleaseGlobalFetch(void) {
    g_globalLoadingInFlight = NO;
    g_globalLoadingVideoID = nil;
    g_loadingSince = nil;
}

static BOOL YTMULyricsPreference(NSString *key, BOOL fallback) {
    NSDictionary *settings = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    id value = settings[key];
    return value ? [value boolValue] : fallback;
}

// 輔助工具：把除錯訊息傳給你的 Python 伺服器
static void sendDebugLog(NSString *msg) {
    NSString *full = msg;
    if (g_currentVideoID) {
        full = [NSString stringWithFormat:@"%@ [v=%@ t=%.1f]", msg, g_currentVideoID, g_currentPlaybackTime];
    }
    NSLog(@"[YTMU] %@", full);
    NSString *encodedMsg = [full stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *serverURL = [NSString stringWithFormat:@"https://ytmtranslate.chiuhuang.dev/api/lyrics?v=DEBUG_%@", encodedMsg];
    [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:serverURL]] resume];
}
static void __attribute__((unused)) sendDebugLogWithPayload(NSString *event, NSString *msg, NSDictionary *payload) {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:payload ?: @{}];
    if (g_currentVideoID) dict[@"videoId"] = g_currentVideoID;
    dict[@"playbackTime"] = @(g_currentPlaybackTime);
    NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"type": @"APP_LOG", @"event": event, @"level": @"info", @"message": msg, @"payload": dict} options:0 error:nil];
    if (json) {
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://ytmtranslate.chiuhuang.dev/log"]];
        req.HTTPMethod = @"POST";
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        req.HTTPBody = json;
        [[[NSURLSession sharedSession] dataTaskWithRequest:req] resume];
    }
    sendDebugLog([NSString stringWithFormat:@"%@: %@ %@", event, msg, dict]);
}

// Client persistent cache for lyrics
static NSString *YTMULyricsCacheDirectory(void) {
    NSString *cache = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [cache stringByAppendingPathComponent:@"YTMU_LyricsCache"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}
static NSString *YTMULyricsCachePathForVideoID(NSString *vid) {
    if (!vid.length) return nil;
    NSString *safe = [vid stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [[YTMULyricsCacheDirectory() stringByAppendingPathComponent:safe] stringByAppendingPathExtension:@"json"];
}
static BOOL YTMULyricsCacheEnabled(void) {
    NSDictionary *s = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    if (!s[@"lyricsCacheEnabled"]) return YES;
    return [s[@"lyricsCacheEnabled"] boolValue];
}
static NSInteger YTMULyricsCacheMaxCount(void) {
    NSDictionary *s = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    NSInteger v = [s[@"lyricsCacheMaxCount"] integerValue];
    return v > 0 ? v : 200;
}
static NSInteger YTMULyricsCacheMaxSizeMB(void) {
    NSDictionary *s = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    NSInteger v = [s[@"lyricsCacheMaxSizeMB"] integerValue];
    return v > 0 ? v : 50;
}
static void YTMULyricsCacheSave(NSString *videoID, NSArray *lyrics) {
    if (!YTMULyricsCacheEnabled() || !videoID.length || !lyrics) return;
    NSString *path = YTMULyricsCachePathForVideoID(videoID);
    if (!path) return;
    NSDictionary *dict = @{@"lyrics": lyrics, @"ts": @([[NSDate date] timeIntervalSince1970]), @"videoID": videoID};
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
static NSArray *YTMULyricsCacheLoad(NSString *videoID) {
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
static __attribute__((unused)) NSDictionary *YTMULyricsCacheStats(void) {
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
static void __attribute__((unused)) YTMULyricsCacheClearAll(void) {
    NSString *dir = YTMULyricsCacheDirectory();
    [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    if (g_lyricsCache) [g_lyricsCache removeAllObjects];
}




// Resolve the current video ID from multiple sources. The didActivateVideo
// hook can miss (delegate signature changes), leaving g_currentVideoID nil
// and the lyrics sheet empty — so re-resolve lazily at tap time.
static NSString *YTMUResolveCurrentVideoID(void) {
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
            // Re-broadcast so panel loads on restore
            [[NSNotificationCenter defaultCenter] postNotificationName:@"YTMUSongDidChange" object:g_currentVideoID];
        }
    } else {
        sendDebugLog(@"[WARN] didActivateVideo fired but currentVideoID is nil");
    }
}

// Hook playback time updates — YTMusic calls this every ~0.1s
- (void)playbackController:(id)arg1 didReceivePlaybackPositionTime:(double)time {
    %orig;
    g_currentPlaybackTime = time;
    // Self-heal: if the activate hook missed, grab the ID from the player here
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

// UI Dump Helpers for Screenshot Trigger
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
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://ytmtranslate.chiuhuang.dev/log"]];
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

%hook YTMAppDelegate
- (BOOL)application:(id)app didFinishLaunchingWithOptions:(id)options {
    BOOL result = %orig;
    // Pre-warm the JWT token in background at launch
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [[YTMUTurnstileManager sharedManager] getJWTTokenWithCompletion:nil];
    });
    return result;
}
%end

%ctor {
    %init;
    // Register screenshot listener at tweak load so it never misses app startup
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationUserDidTakeScreenshotNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if (YTMULyricsPreference(@"sendLyricsScreenshotDebug", NO)) {
            sendUIDump();
        }
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:@"YTMUClearMemoryCache" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if (g_lyricsCache) [g_lyricsCache removeAllObjects];
    }];
    // Refresh JWT in background when app is opened / foregrounded so lyrics
    // requests already have a token (manager no-ops if token is cached)
    void (^prewarmJWT)(NSNotification *) = ^(NSNotification *note) {
        [[YTMUTurnstileManager sharedManager] getJWTTokenWithCompletion:nil];
    };
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:prewarmJWT];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:prewarmJWT];
}

// Hook 2: 攔截靜態歌詞的 Cell (如果還存在的話)
%hook YTMLightweightMusicDescriptionShelfCell

- (void)layoutSubviews {
    %orig;

    UILabel *descriptionLabel = [self valueForKey:@"_descriptionLabel"];
    if (descriptionLabel) {
        CGRect f = descriptionLabel.frame;
        if (f.origin.x < 18) {
            CGFloat diff = 18 - f.origin.x;
            f.origin.x = 18;
            f.size.width = MAX(0, f.size.width - diff);
            descriptionLabel.frame = f;
        }
    }

    if ([self respondsToSelector:@selector(lyrics)] && self.lyrics) {
        CGRect f = self.lyrics.frame;
        if (f.origin.x < 18) {
            CGFloat diff = 18 - f.origin.x;
            f.origin.x = 18;
            f.size.width = MAX(0, f.size.width - diff);
            self.lyrics.frame = f;
        }
        self.lyrics.textContainerInset = UIEdgeInsetsMake(0, 4, 0, 4);
    }
}

- (void)setRenderer:(id)renderer {
    %orig;

    sendDebugLog(@"[OK] 成功進入歌詞 Cell (YTMLightweightMusicDescriptionShelfCell)");

    UILabel *descriptionLabel = [self valueForKey:@"_descriptionLabel"];
    if (!descriptionLabel) {
        sendDebugLog(@"[WARN]️ 找不到 _descriptionLabel");
        return;
    }

    if (!g_lyricsCache) {
        g_lyricsCache = [[NSMutableDictionary alloc] init];
    }

    NSString *videoID = g_currentVideoID;
    if (!videoID) return;

    if (g_lyricsCache[videoID]) {
        NSString *translatedText = g_lyricsCache[videoID];
        descriptionLabel.text = translatedText;

        if ([self respondsToSelector:@selector(lyrics)] && self.lyrics) {
            self.lyrics.text = translatedText;
        }
        return;
    }

    sendDebugLog([NSString stringWithFormat:@"準備向伺服器要歌詞: %@", videoID]);

    NSString *serverURL = [NSString stringWithFormat:@"https://ytmtranslate.chiuhuang.dev/api/lyrics?v=%@", videoID];
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:serverURL]];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && data) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (json && json[@"translated_lyrics"]) {
                NSString *newLyrics = json[@"translated_lyrics"];
                g_lyricsCache[videoID] = newLyrics;

                dispatch_async(dispatch_get_main_queue(), ^{
                    if ([g_currentVideoID isEqualToString:videoID]) {
                        descriptionLabel.text = newLyrics;

                        if ([self respondsToSelector:@selector(lyrics)] && self.lyrics) {
                            self.lyrics.text = newLyrics;
                        }
                        [self setNeedsLayout];
                    }
                });
            }
        }
    }] resume];
}

%end


@interface YTMULyricsCell : UITableViewCell
@property (nonatomic, strong) UILabel *lyricLabel;
@property (nonatomic, strong) UILabel *transLabel;
// Bright overlay clipped by wipeMask: a CAShapeLayer union of the sung word
// rects, so the reveal follows real per-word timing under any line wrapping.
@property (nonatomic, strong) UILabel *wipeLabel;
@property (nonatomic, strong) CAShapeLayer *wipeMask;
@property (nonatomic, assign) CGFloat wipeProgress;
- (void)setWipeProgress:(CGFloat)progress;
- (void)clearWipe;
@end

@implementation YTMULyricsCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        self.lyricLabel = [[UILabel alloc] init];
        self.lyricLabel.numberOfLines = 0;
        self.lyricLabel.font = [UIFont boldSystemFontOfSize:22];
        self.lyricLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.45];
        self.lyricLabel.layer.shadowColor = [UIColor blackColor].CGColor;
        self.lyricLabel.layer.shadowOffset = CGSizeMake(0, 2);
        self.lyricLabel.layer.shadowRadius = 4.0;
        self.lyricLabel.layer.masksToBounds = NO;
        self.lyricLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:self.lyricLabel];

        // Same text/font/geometry as lyricLabel, revealed left-to-right by wipeMask
        self.wipeLabel = [[UILabel alloc] init];
        self.wipeLabel.numberOfLines = 0;
        self.wipeLabel.font = [UIFont boldSystemFontOfSize:22];
        self.wipeLabel.textColor = [UIColor whiteColor];
        self.wipeLabel.layer.shadowColor = [UIColor blackColor].CGColor;
        self.wipeLabel.layer.shadowOffset = CGSizeMake(0, 2);
        self.wipeLabel.layer.shadowRadius = 4.0;
        self.wipeLabel.layer.shadowOpacity = 0.75;
        self.wipeLabel.layer.masksToBounds = NO;
        self.wipeLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:self.wipeLabel];

        self.wipeMask = [CAShapeLayer layer];
        self.wipeMask.fillColor = [UIColor whiteColor].CGColor;
        self.wipeMask.frame = CGRectZero;
        self.wipeLabel.layer.mask = self.wipeMask;
        _wipeProgress = 0.0;

        self.transLabel = [[UILabel alloc] init];
        self.transLabel.numberOfLines = 0;
        self.transLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        self.transLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.32];
        self.transLabel.layer.shadowColor = [UIColor blackColor].CGColor;
        self.transLabel.layer.shadowOffset = CGSizeMake(0, 1);
        self.transLabel.layer.shadowRadius = 2.0;
        self.transLabel.layer.shadowOpacity = 0.35;
        self.transLabel.layer.masksToBounds = NO;
        self.transLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:self.transLabel];

        [NSLayoutConstraint activateConstraints:@[
            [self.lyricLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12],
            [self.lyricLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:20],
            [self.lyricLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-20],

            [self.wipeLabel.topAnchor constraintEqualToAnchor:self.lyricLabel.topAnchor],
            [self.wipeLabel.leadingAnchor constraintEqualToAnchor:self.lyricLabel.leadingAnchor],
            [self.wipeLabel.trailingAnchor constraintEqualToAnchor:self.lyricLabel.trailingAnchor],
            [self.wipeLabel.bottomAnchor constraintEqualToAnchor:self.lyricLabel.bottomAnchor],

            [self.transLabel.topAnchor constraintEqualToAnchor:self.lyricLabel.bottomAnchor constant:5],
            [self.transLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:20],
            [self.transLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-20],
            [self.transLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-12]
        ]];
    }
    return self;
}

- (void)setWipeProgress:(CGFloat)progress {
    _wipeProgress = MIN(MAX(progress, 0.0), 1.0);
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // Mask path lives in wipeLabel's own coordinate space
    self.wipeMask.frame = self.wipeLabel.bounds;
}

- (void)clearWipe {
    _wipeProgress = 0.0;
    self.wipeLabel.text = nil;
    self.wipeLabel.attributedText = nil;
    self.wipeMask.path = nil;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    _wipeProgress = 0.0;
    self.lyricLabel.alpha = 1.0;
    self.lyricLabel.transform = CGAffineTransformIdentity;
    self.wipeLabel.text = nil;
    self.wipeLabel.attributedText = nil;
    self.wipeMask.path = nil;
    self.lyricLabel.attributedText = nil;
}

@end


@interface YTMULyricsViewController : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray *lyrics;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) NSInteger currentIndex;
@property (nonatomic, assign) BOOL isLoading;
@property (nonatomic, copy) NSString *loadingVideoID;
@property (nonatomic, strong) UIImageView *artworkImageView;
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIView *darkOverlay;
@property (nonatomic, assign) BOOL isModal;
@property (nonatomic, assign) BOOL isSynced;
@property (nonatomic, strong) NSString *lastColorKey;
@property (nonatomic, strong) NSDate *loadingSince;
@property (nonatomic, strong) UILabel *fpsLabel;
@property (nonatomic, assign) NSInteger fpsTicks;
@property (nonatomic, assign) NSTimeInterval fpsWindowStart;
@property (nonatomic, assign) float lastVolume;
- (void)updateLyrics:(NSArray *)newLyrics;
- (void)fetchLyricsForVideo:(NSString *)videoID;
- (void)loadArtworkForVideo:(NSString *)videoID;
- (void)forceReloadLyrics;
- (void)dismissModal;
@end

@interface YTPlayerViewController (YTMU_Lyrics)
- (CGFloat)currentVideoMediaTime;
@end

@interface YTMNowPlayingViewController (YTMU_Lyrics)
- (void)ytmu_keepLyricsButtonActive;
- (void)ytmu_makeLyricsViewClickable:(UIView *)v;
- (void)ytmu_didTapLyricsButtonAction:(id)sender;
- (void)ytmu_didTapLyricsBar:(UITapGestureRecognizer *)gesture;
@end

static __weak id g_activeEngagementPanelContainer = nil;
static void openLyricsFromViewController(UIViewController *parentVC);

@implementation YTMULyricsViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.currentIndex = -1;
    self.view.backgroundColor = [UIColor blackColor];

    // Background: high-res album artwork with dark blur
    self.artworkImageView = [[UIImageView alloc] initWithFrame:self.view.bounds];
    self.artworkImageView.contentMode = UIViewContentModeScaleAspectFill;
    self.artworkImageView.clipsToBounds = YES;
    self.artworkImageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view insertSubview:self.artworkImageView atIndex:0];

    UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    self.blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    self.blurView.frame = self.view.bounds;
    self.blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view insertSubview:self.blurView aboveSubview:self.artworkImageView];

    self.darkOverlay = [[UIView alloc] initWithFrame:self.view.bounds];
    self.darkOverlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.48];
    self.darkOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view insertSubview:self.darkOverlay aboveSubview:self.blurView];

    // Setup UITableView with Auto Layout and generous bottom inset
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.showsVerticalScrollIndicator = NO;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 85.0;
    // Prevent safe-area from adding unexpected insets that fight our manual inset
    self.tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.tableView.contentInset = UIEdgeInsetsMake(20, 0, 350, 0);
    [self.tableView registerClass:[YTMULyricsCell class] forCellReuseIdentifier:@"YTMULyricsCell"];

    // Header for top spacing and status label
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 50)];
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UILabel *statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 10, self.view.bounds.size.width, 36)];
    statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    statusLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.7];
    statusLabel.textAlignment = NSTextAlignmentCenter;
    statusLabel.font = [UIFont systemFontOfSize:14];
    statusLabel.tag = 8888;
    [header addSubview:statusLabel];

    UIButton *reloadBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    reloadBtn.frame = CGRectMake(self.view.bounds.size.width - 105, 10, 85, 34);
    reloadBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [reloadBtn setTitle:@"Reload" forState:UIControlStateNormal];
    [reloadBtn setTitleColor:[[UIColor whiteColor] colorWithAlphaComponent:0.9] forState:UIControlStateNormal];
    reloadBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    reloadBtn.titleLabel.adjustsFontSizeToFitWidth = YES;
    reloadBtn.titleLabel.minimumScaleFactor = 0.7;
    reloadBtn.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
    reloadBtn.layer.cornerRadius = 17;
    [reloadBtn addTarget:self action:@selector(forceReloadLyrics) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:reloadBtn];

    if (self.isModal || self.presentingViewController) {
        UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        closeBtn.frame = CGRectMake(16, 10, 36, 36);
        [closeBtn setTitle:@"X" forState:UIControlStateNormal];
        [closeBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:18];
        closeBtn.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
        closeBtn.layer.cornerRadius = 18;
        [closeBtn addTarget:self action:@selector(dismissModal) forControlEvents:UIControlEventTouchUpInside];
        [header addSubview:closeBtn];
    }

    self.tableView.tableHeaderView = header;

    [self.view addSubview:self.tableView];

    // FPS readout (toggled by volume-down, gated by lyricsFpsMeter setting)
    self.fpsLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 64, 140, 24)];
    self.fpsLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
    self.fpsLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.7];
    self.fpsLabel.hidden = YES;
    self.fpsLabel.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
    [self.view addSubview:self.fpsLabel];
    self.fpsTicks = 0;
    self.fpsWindowStart = 0;
    self.lastVolume = -1;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ytmu_volumeChanged:) name:@"AVSystemController_SystemVolumeDidChangeNotification" object:nil];

    self.lyrics = @[];

    // Listen for song changes and lyrics updates across instances
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleSongChange:) name:@"YTMUSongDidChange" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleLyricsDidLoad:) name:@"YTMULyricsDidLoad" object:nil];

    // Start display link for real-time lyric highlighting. Ask for the full
    // ProMotion range; the panel caps at 60 and the system may still dip.
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(updatePlaybackTime)];
    if (@available(iOS 15.0, *)) {
        self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(60, 120, 120);
    } else if ([self.displayLink respondsToSelector:@selector(setPreferredFramesPerSecond:)]) {
        self.displayLink.preferredFramesPerSecond = 120;
    }
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)dismissModal {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    // The header is built while bounds are still zero, and tableHeaderView
    // does not autoresize — without this the Reload button stays clipped.
    UIView *header = self.tableView.tableHeaderView;
    if (header && fabs(header.frame.size.width - self.tableView.bounds.size.width) > 1.0) {
        header.frame = CGRectMake(0, 0, self.tableView.bounds.size.width, 50);
        self.tableView.tableHeaderView = header;
    }

    // Dynamically size the bottom inset so the last row can scroll to the middle of the screen.
    // We need at least half the visible height as padding below the last row.
    CGFloat visibleHeight = self.view.bounds.size.height;
    CGFloat bottomPad = MAX(350.0, visibleHeight * 0.60);

    UIEdgeInsets current = self.tableView.contentInset;
    if (fabs(current.bottom - bottomPad) > 1.0) {
        self.tableView.contentInset = UIEdgeInsetsMake(current.top, 0, bottomPad, 0);
        self.tableView.scrollIndicatorInsets = UIEdgeInsetsMake(0, 0, bottomPad, 0);
    }

    // Keep a footer view the same height as the bottom inset so the table can
    // physically scroll the last row into the visible center.
    UIView *existingFooter = self.tableView.tableFooterView;
    if (!existingFooter || fabs(existingFooter.frame.size.height - bottomPad) > 1.0) {
        UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, bottomPad)];
        footer.backgroundColor = [UIColor clearColor];
        self.tableView.tableFooterView = footer;
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.displayLink invalidate];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Converge to the current song: covers stale sheets and fetches that
    // finished before the view loaded (viewDidLoad resets lyrics).
    NSString *vid = YTMUResolveCurrentVideoID();
    if (vid && (![vid isEqualToString:self.loadingVideoID] || (self.lyrics.count == 0 && !self.isLoading))) {
        [self fetchLyricsForVideo:vid];
    }
}

- (void)handleLyricsDidLoad:(NSNotification *)notif {
    NSString *videoID = notif.object;
    NSArray *lyrics = notif.userInfo[@"lyrics"];
    if (videoID && lyrics && [videoID isEqualToString:g_currentVideoID]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UILabel *statusLabel = [self.tableView.tableHeaderView viewWithTag:8888];
            if (statusLabel) statusLabel.text = @"";
            [self updateLyrics:lyrics];
        });
    }
}

- (void)handleSongChange:(NSNotification *)notif {
    NSString *videoID = notif.object;
    if (videoID) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self.loadingVideoID isEqualToString:videoID]) {
                self.currentIndex = -1;
                UILabel *statusLabel = [self.tableView.tableHeaderView viewWithTag:8888];
                statusLabel.text = @"";
                self.lyrics = @[];
                [self.tableView reloadData];
            }
            [self fetchLyricsForVideo:videoID];
        });
    }
}

// Volume-down toggles the FPS readout (setting: lyricsFpsMeter). Uses only
// the notification name string + defensive userInfo parsing, no private API.
- (void)ytmu_volumeChanged:(NSNotification *)notif {
    if (!YTMULyricsPreference(@"lyricsFpsMeter", YES)) return;
    id param = notif.userInfo[@"AVSystemController_AudioVolumeNotificationParameter"];
    float vol = -1;
    if ([param isKindOfClass:[NSNumber class]]) {
        vol = [param floatValue];
    } else if ([param isKindOfClass:[NSDictionary class]]) {
        id v = ((NSDictionary *)param)[@"Volume"];
        if ([v isKindOfClass:[NSNumber class]]) vol = [v floatValue];
    }
    if (vol < 0) return;
    float prev = self.lastVolume;
    self.lastVolume = vol;
    if (prev >= 0 && vol < prev - 0.001) {
        self.fpsLabel.hidden = !self.fpsLabel.hidden;
        if (!self.fpsLabel.hidden) {
            self.fpsTicks = 0;
            self.fpsWindowStart = CACurrentMediaTime();
            self.fpsLabel.text = @"... fps";
        }
        sendDebugLog(@"[FPS] readout toggled by volume-down");
    }
}

- (void)loadArtworkForVideo:(NSString *)videoID {
    if (!videoID || videoID.length == 0) return;

    NSString *maxURL = [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/maxresdefault.jpg", videoID];
    [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:maxURL] completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
        NSHTTPURLResponse *httpRes = (NSHTTPURLResponse *)res;
        if (!err && data && httpRes.statusCode == 200) {
            UIImage *img = [UIImage imageWithData:data];
            if (img) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if ([self.loadingVideoID isEqualToString:videoID]) {
                        [UIView transitionWithView:self.artworkImageView duration:0.4 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
                            self.artworkImageView.image = img;
                        } completion:nil];
                    }
                });
                return;
            }
        }
        // Fallback to hqdefault
        NSString *hqURL = [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/hqdefault.jpg", videoID];
        [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:hqURL] completionHandler:^(NSData *d2, NSURLResponse *r2, NSError *e2) {
            if (!e2 && d2) {
                UIImage *img2 = [UIImage imageWithData:d2];
                if (img2) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if ([self.loadingVideoID isEqualToString:videoID]) {
                            [UIView transitionWithView:self.artworkImageView duration:0.4 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
                                self.artworkImageView.image = img2;
                            } completion:nil];
                        }
                    });
                }
            }
        }] resume];
    }] resume];
}

// Full lyrics request (server full pipeline + translation). Never blocks on
// JWT: callers race getJWTTokenWithCompletion against a timeout and pass nil
// on expiry — the server simply skips Cubey and tries the free providers.
- (void)fetchFullLyricsForVideo:(NSString *)videoID jwt:(NSString *)jwt force:(BOOL)force {
    if (![self.loadingVideoID isEqualToString:videoID]) {
        self.isLoading = NO;
        self.loadingSince = nil;
        if ([g_globalLoadingVideoID isEqualToString:videoID]) {
            YTMUReleaseGlobalFetch();
        }
        return;
    }

    NSString *fullURL = [NSString stringWithFormat:@"https://ytmtranslate.chiuhuang.dev/api/lyrics?v=%@", videoID];
    if (force) {
        fullURL = [fullURL stringByAppendingString:@"&force=1"];
    }
    if (jwt) {
        fullURL = [fullURL stringByAppendingFormat:@"&jwt=%@", jwt];
    }

    [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:fullURL] completionHandler:^(NSData *fullData, NSURLResponse *fullRes, NSError *fullErr) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.isLoading = NO;
            self.loadingSince = nil;
            // Release global in-flight slot
            if ([g_globalLoadingVideoID isEqualToString:videoID]) {
                YTMUReleaseGlobalFetch();
            }

            if (![self.loadingVideoID isEqualToString:videoID]) return;

            UILabel *statusLabel = [self.tableView.tableHeaderView viewWithTag:8888];
            if (fullData && !fullErr) {
                NSDictionary *fullDict = [NSJSONSerialization JSONObjectWithData:fullData options:0 error:nil];
                if (fullDict && fullDict[@"lyrics"]) {
                    statusLabel.text = @"";
                    if (!g_lyricsCache) g_lyricsCache = [[NSMutableDictionary alloc] init];
                    g_lyricsCache[videoID] = fullDict[@"lyrics"];
                    YTMULyricsCacheSave(videoID, fullDict[@"lyrics"]);
                    [self updateLyrics:fullDict[@"lyrics"]];
                    // Broadcast full result so all other VCs update too
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"YTMULyricsDidLoad"
                                                                        object:videoID
                                                                      userInfo:@{@"lyrics": fullDict[@"lyrics"]}];
                } else if (self.lyrics.count == 0) {
                    statusLabel.text = @"[WARN]️ 找不到歌詞 / No lyrics found";
                    self.lyrics = @[];
                    [self.tableView reloadData];
                }
            } else if (self.lyrics.count == 0) {
                statusLabel.text = @"[WARN]️ 網路錯誤 / Network error";
                self.lyrics = @[];
                [self.tableView reloadData];
            }
        });
    }] resume];
}

- (void)fetchLyricsForVideo:(NSString *)videoID {
    if (!videoID || videoID.length == 0) return;

    if (!g_lyricsCache) {
        g_lyricsCache = [[NSMutableDictionary alloc] init];
    }

    // Memory cache hit
    if (g_lyricsCache[videoID]) {
        UILabel *statusLabel = [self.tableView.tableHeaderView viewWithTag:8888];
        statusLabel.text = @"";
        // Cache hits never set loadingVideoID, so artwork stayed black.
        // Claim the ID first, then load the background like the fetch path.
        self.loadingVideoID = videoID;
        self.isLoading = NO;
        [self loadArtworkForVideo:videoID];
        [self updateLyrics:g_lyricsCache[videoID]];
        return;
    }
    // File cache hit
    if (YTMULyricsCacheEnabled()) {
        NSArray *fileCached = YTMULyricsCacheLoad(videoID);
        if (fileCached) {
            if (!g_lyricsCache) g_lyricsCache = [[NSMutableDictionary alloc] init];
            g_lyricsCache[videoID] = fileCached;
            UILabel *statusLabel = [self.tableView.tableHeaderView viewWithTag:8888];
            statusLabel.text = @"";
            self.loadingVideoID = videoID;
            self.isLoading = NO;
            [self loadArtworkForVideo:videoID];
            [self updateLyrics:fileCached];
            return;
        }
    }

    UILabel *statusLabel = [self.tableView.tableHeaderView viewWithTag:8888];
    statusLabel.text = @"Loading...";

    // Global in-flight guard: if ANY VC instance is already fetching this video,
    // wait for it — the result arrives via YTMULyricsDidLoad notification.
    // Watchdog: a fetch that claimed the slot but never finished (e.g. lost
    // JWT callback) must not wedge the sheet empty forever. Reclaim after 45s.
    if (g_globalLoadingInFlight && [g_globalLoadingVideoID isEqualToString:videoID]) {
        if (g_loadingSince && [[NSDate date] timeIntervalSinceDate:g_loadingSince] > 45) {
            sendDebugLog(@"[WARN] Reclaiming stale global fetch slot");
            YTMUReleaseGlobalFetch();
        } else {
            statusLabel.text = @"Waiting...";
            return;
        }
    }
    // Per-instance guard (for the same VC re-entering)
    if (self.isLoading && [self.loadingVideoID isEqualToString:videoID]) {
        if (self.loadingSince && [[NSDate date] timeIntervalSinceDate:self.loadingSince] <= 45) {
            statusLabel.text = @"Waiting...";
            return;
        }
        sendDebugLog(@"[WARN] Reclaiming stale instance fetch slot");
    }

    // Claim the global in-flight slot
    g_globalLoadingInFlight = YES;
    g_globalLoadingVideoID = videoID;
    g_loadingSince = [NSDate date];
    self.isLoading = YES;
    self.loadingVideoID = videoID;
    self.loadingSince = [NSDate date];

    // loadingVideoID must be set before artwork starts so the background applies
    [self loadArtworkForVideo:videoID];

    // Fast Request (LRCLIB + GTX)
    NSString *fastURL = [NSString stringWithFormat:@"https://ytmtranslate.chiuhuang.dev/api/lyrics?v=%@&fast=1", videoID];
    [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:fastURL] completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self.loadingVideoID isEqualToString:videoID]) return;
            if (data && !err) {
                NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if (dict && dict[@"lyrics"]) {
                    statusLabel.text = @"";
                    [self updateLyrics:dict[@"lyrics"]];
                    // Broadcast fast result so other VCs can show something while full loads
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"YTMULyricsDidLoad"
                                                                        object:videoID
                                                                      userInfo:@{@"lyrics": dict[@"lyrics"]}];
                }
            }

            // Full Request (Cubey + Cohere) using JWT, with a 10s fallback so
            // a lost Turnstile callback can never wedge the sheet empty.
            __block BOOL jwtResolved = NO;
            [[YTMUTurnstileManager sharedManager] getJWTTokenWithCompletion:^(NSString *jwt) {
                if (jwtResolved) return;
                jwtResolved = YES;
                [self fetchFullLyricsForVideo:videoID jwt:jwt force:NO];
            }];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (!jwtResolved && [self.loadingVideoID isEqualToString:videoID]) {
                    jwtResolved = YES;
                    sendDebugLog(@"[WARN] JWT timeout, full fetch without JWT");
                    [self fetchFullLyricsForVideo:videoID jwt:nil force:NO];
                }
            });
        });
    }] resume];
}

- (void)updatePlaybackTime {
    // FPS probe: measures the display-link tick rate itself (before guards),
    // so it reports the real link rate even with plain/empty lyrics.
    self.fpsTicks++;
    NSTimeInterval fpsNow = CACurrentMediaTime();
    if (fpsNow - self.fpsWindowStart >= 1.0) {
        NSInteger fps = (NSInteger)(self.fpsTicks / MAX(fpsNow - self.fpsWindowStart, 0.001));
        self.fpsTicks = 0;
        self.fpsWindowStart = fpsNow;
        if (self.fpsLabel && !self.fpsLabel.hidden) {
            NSInteger maxFps = (NSInteger)[UIScreen mainScreen].maximumFramesPerSecond;
            self.fpsLabel.text = [NSString stringWithFormat:@"%ld/%ld fps", (long)fps, (long)maxFps];
            sendDebugLog([NSString stringWithFormat:@"[FPS] lyric render rate %ld fps (panel max %ld)", (long)fps, (long)maxFps]);
        }
    }
    if (!self.isSynced || self.lyrics.count == 0) return;

    double currentTime = 0;
    if (g_activePlayer) {
        if ([g_activePlayer respondsToSelector:@selector(currentVideoMediaTime)]) {
            currentTime = [g_activePlayer currentVideoMediaTime];
        } else if ([g_activePlayer respondsToSelector:@selector(currentMediaTime)]) {
            currentTime = [g_activePlayer currentMediaTime];
        }
    }
    if (currentTime > 0) {
        g_currentPlaybackTime = currentTime;
    } else {
        currentTime = g_currentPlaybackTime;
    }

    if (currentTime <= 0) return;

    NSInteger newIndex = -1;
    for (NSInteger i = 0; i < self.lyrics.count; i++) {
        NSDictionary *lyric = self.lyrics[i];
        double time = [lyric[@"time"] doubleValue];

        if (currentTime >= time) {
            newIndex = i;
        } else {
            break;
        }
    }

    if (newIndex != self.currentIndex) {
        NSInteger oldIndex = self.currentIndex;
        self.currentIndex = newIndex;

        // Directly re-style old and new cells without reloadRows
        if (oldIndex >= 0 && oldIndex < self.lyrics.count) {
            YTMULyricsCell *oldCell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:oldIndex inSection:0]];
            if (oldCell) {
                [self configureCell:oldCell atIndex:oldIndex isActive:NO currentTime:currentTime];
            }
        }

        if (newIndex >= 0 && newIndex < self.lyrics.count) {
            YTMULyricsCell *newCell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:newIndex inSection:0]];
            if (newCell) {
                [self configureCell:newCell atIndex:newIndex isActive:YES currentTime:currentTime];
                // Apple-Music-style activation pop: line-level rows crossfade
                // in, every row settles from a slight scale-up. Word rows keep
                // coloring themselves per tick after the pop.
                NSDictionary *nl = self.lyrics[newIndex];
                if (!([nl[@"wordSynced"] boolValue] && [(NSArray *)nl[@"parts"] count] > 0)) {
                    newCell.lyricLabel.alpha = 0.3;
                }
                newCell.lyricLabel.transform = CGAffineTransformMakeScale(1.04, 1.04);
                [UIView animateWithDuration:0.5 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
                    newCell.lyricLabel.alpha = 1.0;
                    newCell.lyricLabel.transform = CGAffineTransformIdentity;
                } completion:nil];
            }

            // Smooth auto-scroll to the middle of the screen (only if user is not manually scrolling)
            if (!self.tableView.isDragging && !self.tableView.isDecelerating) {
                NSIndexPath *indexPath = [NSIndexPath indexPathForRow:newIndex inSection:0];
                [self.tableView scrollToRowAtIndexPath:indexPath atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
            }
        }
        // The current line remains highlighted until its timestamp changes.
    } else if (newIndex >= 0) {
        // Same line still active: advance the word-by-word fill from real
        // per-word timestamps (line-level rows need no per-frame work).
        YTMULyricsCell *cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:newIndex inSection:0]];
        if (cell) {
            NSDictionary *lyric = self.lyrics[newIndex];
            if ([lyric[@"wordSynced"] boolValue] && [(NSArray *)lyric[@"parts"] count] > 0) {
                [self applyWordColorsToCell:cell lyric:lyric index:newIndex currentTime:currentTime force:NO];
            }
        }
    }
}

- (void)forceReloadLyrics {
    if (!g_currentVideoID) return;

    if (g_lyricsCache) {
        [g_lyricsCache removeObjectForKey:g_currentVideoID];
    }
    self.lyrics = @[];
    [self.tableView reloadData];

    UILabel *statusLabel = [self.tableView.tableHeaderView viewWithTag:8888];
    statusLabel.text = @"Force Reloading...";

    g_globalLoadingInFlight = YES;
    g_globalLoadingVideoID = g_currentVideoID;
    g_loadingSince = [NSDate date];
    self.isLoading = YES;
    self.loadingVideoID = g_currentVideoID;
    self.loadingSince = [NSDate date];

    [self loadArtworkForVideo:g_currentVideoID];

    // Same 10s JWT fallback as the normal path — a lost Turnstile callback
    // must not wedge the sheet on "Force Reloading..." forever.
    __block BOOL jwtResolved = NO;
    [[YTMUTurnstileManager sharedManager] getJWTTokenWithCompletion:^(NSString *jwt) {
        if (jwtResolved) return;
        jwtResolved = YES;
        [self fetchFullLyricsForVideo:g_currentVideoID jwt:jwt force:YES];
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!jwtResolved && [self.loadingVideoID isEqualToString:g_currentVideoID]) {
            jwtResolved = YES;
            sendDebugLog(@"[WARN] JWT timeout, force reload without JWT");
            [self fetchFullLyricsForVideo:g_currentVideoID jwt:nil force:YES];
        }
    });
}

- (void)updateLyrics:(NSArray *)newLyrics {
    self.lyrics = newLyrics;

    BOOL hasTimestamp = NO;
    for (NSDictionary *l in newLyrics) {
        if ([l[@"time"] doubleValue] > 0.0) {
            hasTimestamp = YES;
            break;
        }
    }
    self.isSynced = hasTimestamp;
    if (!self.isSynced) {
        self.currentIndex = -1;
    }
    self.lastColorKey = nil;

    // Background safety net: lyrics delivered without a fetch on this
    // instance (broadcast from another VC) never triggered artwork loading,
    // which is why the backdrop stayed black most of the time.
    NSString *artVid = self.loadingVideoID;
    if (!artVid) artVid = g_currentVideoID;
    if (artVid && !self.artworkImageView.image) {
        if (!self.loadingVideoID) self.loadingVideoID = artVid;
        [self loadArtworkForVideo:artVid];
    }

    [self.tableView reloadData];

    if (newLyrics.count > 0 && YTMULyricsPreference(@"lyricsAlwaysOn", YES)) {
        self.view.hidden = NO;
        UIView *contentContainer = self.view.superview;
        if (contentContainer) {
            [contentContainer bringSubviewToFront:self.view];
            for (UIView *sub in contentContainer.subviews) {
                if (sub.tag != 9999) sub.hidden = YES;
            }
        }
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.lyrics.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewAutomaticDimension;
}

- (NSString *)normalizedLyricText:(NSString *)raw {
    if (!raw || raw.length == 0) return @"";
    // Collapse multiple consecutive spaces (from word-boundary artefacts) into one
    NSArray *tokens = [raw componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSMutableArray *nonEmpty = [NSMutableArray array];
    for (NSString *t in tokens) {
        if (t.length > 0) [nonEmpty addObject:t];
    }
    return [nonEmpty componentsJoinedByString:@" "];
}

// Normalized display string for a word-synced line, with provider word runs
// aligned to it by consuming each part's trimmed text in order. Collapsing
// provider padding (fixed-width karaoke spacing) is what fixes the broken
// gaps; forward search keeps duplicate words ("la la la") in order.
// Unmatchable parts get an NSNotFound range and are skipped by the mask.
- (NSString *)wbwDisplayTextForLyric:(NSDictionary *)lyric ranges:(NSArray **)outRanges {
    NSArray *parts = lyric[@"parts"];
    NSMutableString *concat = [NSMutableString string];
    for (NSDictionary *p in parts) {
        NSString *w = p[@"words"];
        if (w) [concat appendString:w];
    }
    NSString *display = [self normalizedLyricText:([concat length] ? concat : lyric[@"text"])];
    if (outRanges) {
        NSMutableArray *ranges = [NSMutableArray array];
        NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
        NSUInteger cursor = 0;
        for (NSDictionary *p in parts) {
            NSString *w = [((NSString *)(p[@"words"] ?: @"")) stringByTrimmingCharactersInSet:ws];
            if (w.length == 0) continue;
            if (cursor > display.length) cursor = display.length;
            NSRange found = [display rangeOfString:w options:0 range:NSMakeRange(cursor, display.length - cursor)];
            if (found.location == NSNotFound) {
                [ranges addObject:[NSValue valueWithRange:NSMakeRange(NSNotFound, 0)]];
                continue;
            }
            [ranges addObject:[NSValue valueWithRange:found]];
            cursor = NSMaxRange(found);
            while (cursor < display.length && [ws characterIsMember:[display characterAtIndex:cursor]]) cursor++;
        }
        *outRanges = ranges;
    }
    return display;
}

// Word-by-word MASK reveal driven by each word's real start/duration (not a
// uniform left-to-right sweep, not letter coloring). Base label stays dim;
// a bright overlay with baked text shadow is revealed through a shape mask
// built from the measured rect of every sung word, so variable word widths
// and wrapped lines highlight correctly. Skips work when the reveal key is
// unchanged so 120fps ticks stay cheap.
- (UIBezierPath *)maskPathForWordRange:(NSRange)r inLayoutManager:(NSLayoutManager *)lm textContainer:(NSTextContainer *)tc fraction:(double)frac {
    NSRange glyphs = [lm glyphRangeForCharacterRange:r actualCharacterRange:NULL];
    CGRect b = [lm boundingRectForGlyphRange:glyphs inTextContainer:tc];
    if (frac < 1.0) b.size.width *= MAX(frac, 0.0);
    // Pad so ascenders/descenders and the baked shadow are not hard-clipped
    return [UIBezierPath bezierPathWithRect:CGRectInset(b, -1, -2)];
}

- (void)applyWordColorsToCell:(YTMULyricsCell *)cell lyric:(NSDictionary *)lyric index:(NSInteger)index currentTime:(double)currentTime force:(BOOL)force {
    NSArray *parts = lyric[@"parts"];
    if ([parts count] == 0) return;
    double nowMs = currentTime * 1000.0;
    NSInteger partCount = [parts count];
    // Ratio normalization: provider word spans rarely fill the line window,
    // which leaves dead fully-lit time after the last word reveals. Stretch
    // the word schedule proportionally so the last word lands exactly on the
    // line end (next line start), keeping each word's share by duration ratio.
    double lineStart = [lyric[@"startTimeMs"] doubleValue];
    if (lineStart <= 0) lineStart = [lyric[@"time"] doubleValue] * 1000.0;
    double lineEnd = 0;
    if (index + 1 < self.lyrics.count) {
        NSDictionary *nextLyric = self.lyrics[index + 1];
        lineEnd = [nextLyric[@"startTimeMs"] doubleValue];
        if (lineEnd <= 0) lineEnd = [nextLyric[@"time"] doubleValue] * 1000.0;
    }
    if (lineEnd <= lineStart) {
        double lineDur = [lyric[@"durationMs"] doubleValue];
        if (lineDur <= 0) lineDur = [lyric[@"duration"] doubleValue] * 1000.0;
        lineEnd = lineStart + (lineDur > 0 ? lineDur : 4000.0);
    }
    NSDictionary *firstPart = parts[0];
    double firstStart = [firstPart[@"startTimeMs"] doubleValue];
    double lastEnd = firstStart;
    for (NSDictionary *p in parts) {
        double e = [p[@"startTimeMs"] doubleValue] + MAX([p[@"durationMs"] doubleValue], 1.0);
        if (e > lastEnd) lastEnd = e;
    }
    double ratioK = 1.0;
    if (lastEnd > firstStart && lineEnd > lineStart) {
        ratioK = (lineEnd - lineStart) / (lastEnd - firstStart);
    }
    NSInteger curWord = partCount; // past-the-end = everything sung
    double curFrac = 1.0;
    for (NSInteger i = 0; i < partCount; i++) {
        NSDictionary *p = parts[i];
        double s = lineStart + ([p[@"startTimeMs"] doubleValue] - firstStart) * ratioK;
        double d = MAX([p[@"durationMs"] doubleValue], 1.0) * ratioK;
        if (nowMs < s) { curWord = i; curFrac = 0.0; break; }
        if (nowMs < s + d) { curWord = i; curFrac = (nowMs - s) / d; break; }
    }
    NSInteger fracQ = (NSInteger)(curFrac * 24.0); // quantized: stable key, smooth glide
    NSString *key = [NSString stringWithFormat:@"%ld:%ld:%ld", (long)index, (long)curWord, (long)fracQ];
    if (!force && [key isEqualToString:self.lastColorKey]) return;
    if (cell.wipeLabel.bounds.size.width <= 0) return; // no layout yet: retry on a later key, never cache this
    self.lastColorKey = key;

    NSArray *ranges = nil;
    NSString *display = [self wbwDisplayTextForLyric:lyric ranges:&ranges];

    // Dim base
    cell.lyricLabel.attributedText = nil;
    cell.lyricLabel.text = display;
    cell.lyricLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.2];

    // Bright overlay with baked shadow (layer shadow would be clipped by the mask)
    UIFont *font = cell.wipeLabel.font;
    if (!font) font = [UIFont boldSystemFontOfSize:22];
    NSShadow *sh = [[NSShadow alloc] init];
    sh.shadowColor = [[UIColor blackColor] colorWithAlphaComponent:0.8];
    sh.shadowOffset = CGSizeMake(0, 2);
    sh.shadowBlurRadius = 4;
    cell.wipeLabel.attributedText = [[NSAttributedString alloc] initWithString:display
        attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: [UIColor whiteColor], NSShadowAttributeName: sh}];

    // Measure word rects with TextKit under the same width/wrapping as the label
    NSTextStorage *ts = [[NSTextStorage alloc] initWithString:display attributes:@{NSFontAttributeName: font}];
    NSLayoutManager *lm = [[NSLayoutManager alloc] init];
    NSTextContainer *tc = [[NSTextContainer alloc] initWithSize:CGSizeMake(cell.wipeLabel.bounds.size.width, CGFLOAT_MAX)];
    tc.lineFragmentPadding = 0;
    tc.maximumNumberOfLines = 0;
    tc.lineBreakMode = NSLineBreakByWordWrapping;
    [lm addTextContainer:tc];
    [ts addLayoutManager:lm];
    [lm ensureLayoutForTextContainer:tc];

    UIBezierPath *path = [UIBezierPath bezierPath];
    NSInteger rcount = MIN(partCount, (NSInteger)[ranges count]);
    for (NSInteger i = 0; i < curWord && i < rcount; i++) {
        NSRange r = [ranges[i] rangeValue];
        if (r.location == NSNotFound || r.length == 0) continue;
        [path appendPath:[self maskPathForWordRange:r inLayoutManager:lm textContainer:tc fraction:1.0]];
    }
    if (curWord >= 0 && curWord < rcount) {
        NSRange r = [ranges[curWord] rangeValue];
        if (r.location != NSNotFound && r.length > 0) {
            [path appendPath:[self maskPathForWordRange:r inLayoutManager:lm textContainer:tc fraction:curFrac]];
        }
    } else if (curWord >= rcount && display.length > 0) {
        [path appendPath:[UIBezierPath bezierPathWithRect:cell.wipeLabel.bounds]];
    }
    cell.wipeMask.frame = cell.wipeLabel.bounds;
    cell.wipeMask.path = path.CGPath;
}

// Legacy geometric wipe (kept for the mask plumbing). Active lines now use
// per-word run coloring (applyWordColorsToCell) or line-level brightening;
// this helper is no longer on the render path.
// Sliding fill progress for the active line: smooth left-to-right wipe.
// Uses real per-word timestamps when the provider supplied them, otherwise
// glides across the whole line duration so the speed still follows the song.
- (CGFloat)wipeProgressForLyricAtIndex:(NSInteger)index currentTime:(double)currentTime {
    if (index < 0 || index >= self.lyrics.count) return 0.0;
    NSDictionary *lyric = self.lyrics[index];
    double nowMs = currentTime * 1000.0;
    NSArray *parts = lyric[@"parts"];
    if ([lyric[@"wordSynced"] boolValue] && [parts count] > 0) {
        NSInteger n = [parts count];
        for (NSInteger i = 0; i < n; i++) {
            NSDictionary *p = parts[i];
            double s = [p[@"startTimeMs"] doubleValue];
            double d = MAX([p[@"durationMs"] doubleValue], 1.0);
            if (nowMs < s) return (CGFloat)i / (CGFloat)n;
            if (nowMs < s + d) {
                double frac = (nowMs - s) / d;
                return (CGFloat)((double)i + frac) / (CGFloat)n;
            }
        }
        return 1.0;
    }
    double startMs = [lyric[@"startTimeMs"] doubleValue];
    if (startMs <= 0) startMs = [lyric[@"time"] doubleValue] * 1000.0;
    double endMs = 0;
    if (index + 1 < self.lyrics.count) {
        NSDictionary *next = self.lyrics[index + 1];
        endMs = [next[@"startTimeMs"] doubleValue];
        if (endMs <= 0) endMs = [next[@"time"] doubleValue] * 1000.0;
    }
    if (endMs <= startMs) {
        double durMs = [lyric[@"durationMs"] doubleValue];
        if (durMs <= 0) durMs = [lyric[@"duration"] doubleValue] * 1000.0;
        endMs = startMs + (durMs > 0 ? durMs : 4000.0);
    }
    if (endMs <= startMs) return 1.0;
    return (CGFloat)MIN(MAX((nowMs - startMs) / (endMs - startMs), 0.0), 1.0);
}

- (void)configureCell:(YTMULyricsCell *)cell atIndex:(NSInteger)index isActive:(BOOL)isActive currentTime:(double)currentTime {
    if (index < 0 || index >= self.lyrics.count) return;

    NSDictionary *lyric = self.lyrics[index];
    NSString *displayText = [self normalizedLyricText:lyric[@"text"]];
    BOOL hasWords = [lyric[@"wordSynced"] boolValue] && [(NSArray *)lyric[@"parts"] count] > 0;
    if (hasWords) displayText = [self wbwDisplayTextForLyric:lyric ranges:NULL];
    cell.lyricLabel.alpha = 1.0;
    cell.lyricLabel.transform = CGAffineTransformIdentity;

    if (!self.isSynced) {
        // Plain unsynced lyrics: display every line clearly without dimming.
        cell.lyricLabel.attributedText = nil;
        cell.lyricLabel.text = displayText;
        cell.lyricLabel.textColor = [UIColor whiteColor];
        cell.lyricLabel.layer.shadowColor = [UIColor blackColor].CGColor;
        cell.lyricLabel.layer.shadowOffset = CGSizeMake(0, 2);
        cell.lyricLabel.layer.shadowRadius = 4.0;
        cell.lyricLabel.layer.shadowOpacity = 0.7;
        cell.lyricLabel.layer.masksToBounds = NO;
        [cell clearWipe];

        cell.transLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.75];
    } else if (isActive) {
        if (hasWords) {
            // Word-by-word mask reveal from real per-word timestamps.
            [self applyWordColorsToCell:cell lyric:lyric index:index currentTime:currentTime force:YES];
        } else {
            // Line-by-line: the whole line lights up at once, no fake sweep.
            cell.lyricLabel.attributedText = nil;
            cell.lyricLabel.text = displayText;
            cell.lyricLabel.textColor = [UIColor whiteColor];
            [cell clearWipe];
        }

        cell.lyricLabel.layer.shadowColor = [UIColor blackColor].CGColor;
        cell.lyricLabel.layer.shadowOffset = CGSizeMake(0, 2);
        cell.lyricLabel.layer.shadowRadius = 4.0;
        cell.lyricLabel.layer.shadowOpacity = 0.75;
        cell.lyricLabel.layer.masksToBounds = NO;

        cell.transLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.7];
    } else {
        cell.lyricLabel.attributedText = nil;
        cell.lyricLabel.text = displayText;
        cell.lyricLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.2];
        cell.lyricLabel.layer.shadowOpacity = 0.32;
        [cell clearWipe];

        cell.transLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.25];
    }

    NSString *translated = lyric[@"translated"];
    if (translated && translated.length > 0) {
        cell.transLabel.text = translated;
        cell.transLabel.hidden = NO;
    } else {
        cell.transLabel.text = @"";
        cell.transLabel.hidden = YES;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    YTMULyricsCell *cell = [tableView dequeueReusableCellWithIdentifier:@"YTMULyricsCell" forIndexPath:indexPath];

    double currentTime = 0;
    if (g_activePlayer && [g_activePlayer respondsToSelector:@selector(currentVideoMediaTime)]) {
        currentTime = [g_activePlayer currentVideoMediaTime];
    } else {
        currentTime = g_currentPlaybackTime;
    }

    BOOL isActive = self.isSynced && (indexPath.row == self.currentIndex);
    [self configureCell:cell atIndex:indexPath.row isActive:isActive currentTime:currentTime];

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (!self.isSynced) return;

    NSDictionary *lyric = self.lyrics[indexPath.row];
    NSNumber *time = lyric[@"time"];

    if (time && [time doubleValue] >= 0) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"YTMUSeekToTime" object:time];

        NSInteger oldIndex = self.currentIndex;
        self.currentIndex = indexPath.row;
        g_currentPlaybackTime = [time doubleValue];

        if (oldIndex >= 0 && oldIndex < self.lyrics.count && oldIndex != indexPath.row) {
            YTMULyricsCell *oldCell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:oldIndex inSection:0]];
            if (oldCell) {
                [self configureCell:oldCell atIndex:oldIndex isActive:NO currentTime:g_currentPlaybackTime];
            }
        }
        YTMULyricsCell *newCell = [self.tableView cellForRowAtIndexPath:indexPath];
        if (newCell) {
            [self configureCell:newCell atIndex:indexPath.row isActive:YES currentTime:g_currentPlaybackTime];
        }
    }
}

@end


static UIViewController *topMostViewController(void) {
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

static BOOL isLyricsEngagementPanel(UIViewController *vc) {
    if (!vc) return NO;
    id obj = (id)vc;

    // 1. Check panelIdentifier or identifier property
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

    // 2. Check model description
    if ([obj respondsToSelector:@selector(model)]) {
        id model = [obj performSelector:@selector(model)];
        if (model) {
            NSString *desc = [model description].lowercaseString;
            if ([desc containsString:@"lyric"]) return YES;
        }
    }

    // 3. Check vc title
    if (vc.title && (
        [vc.title containsString:@"歌詞"] ||
        [vc.title containsString:@"歌词"] ||
        [vc.title.lowercaseString containsString:@"lyric"])) {
        return YES;
    }

    // 4. Check subviews for YTEngagementPanelHeaderView title label
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

static BOOL isLyricsViewVisibleOnScreen(void) {
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

static void openLyricsFromViewController(UIViewController *parentVC) {
    sendDebugLog(@"[MUSIC] openLyricsFromViewController called");
    // Resolve video ID now — didActivateVideo may have missed, leaving nil
    NSString *resolvedVideoID = YTMUResolveCurrentVideoID();
    if (!resolvedVideoID) {
        sendDebugLog(@"[WARN] openLyrics: no video ID could be resolved");
    }

    if (g_activeEngagementPanelContainer) {
        NSArray *panelIDs = @[@"PAmusic_watch_lyrics_panel", @"music_watch_lyrics_panel", @"lyrics"];
        for (NSString *pid in panelIDs) {
            if ([g_activeEngagementPanelContainer respondsToSelector:@selector(showEngagementPanelWithIdentifier:animated:)]) {
                [g_activeEngagementPanelContainer performSelector:@selector(showEngagementPanelWithIdentifier:animated:) withObject:pid withObject:(id)kCFBooleanTrue];
                break;
            } else if ([g_activeEngagementPanelContainer respondsToSelector:@selector(showEngagementPanelWithIdentifier:)]) {
                [g_activeEngagementPanelContainer performSelector:@selector(showEngagementPanelWithIdentifier:) withObject:pid];
                break;
            } else if ([g_activeEngagementPanelContainer respondsToSelector:@selector(openEngagementPanelWithIdentifier:animated:)]) {
                [g_activeEngagementPanelContainer performSelector:@selector(openEngagementPanelWithIdentifier:animated:) withObject:pid withObject:(id)kCFBooleanTrue];
                break;
            }
        }
    }

    // Fallback: if native panel didn't open on screen within 0.2s, present YTMULyricsViewController as bottom sheet
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (isLyricsViewVisibleOnScreen()) {
            sendDebugLog(@"[MUSIC] Native lyrics panel already visible on screen, skipping fallback");
            return;
        }

        UIViewController *top = topMostViewController();
        if (!top) return;

        if ([top isKindOfClass:[YTMULyricsViewController class]] || [top.presentedViewController isKindOfClass:[YTMULyricsViewController class]]) {
            // Sheet is already up (possibly stale from the previous song):
            // refresh it for the current video instead of doing nothing.
            YTMULyricsViewController *existing = [top isKindOfClass:[YTMULyricsViewController class]]
                ? (YTMULyricsViewController *)top
                : (YTMULyricsViewController *)top.presentedViewController;
            NSString *existingVideoID = YTMUResolveCurrentVideoID() ?: resolvedVideoID;
            if (existingVideoID) [existing fetchLyricsForVideo:existingVideoID];
            return;
        }

        sendDebugLog(@"[MUSIC] Presenting fallback YTMULyricsViewController bottom sheet");
        YTMULyricsViewController *lyricsVC = [[YTMULyricsViewController alloc] init];
        lyricsVC.isModal = YES;
        lyricsVC.modalPresentationStyle = UIModalPresentationPageSheet;
        if (@available(iOS 15.0, *)) {
            UISheetPresentationController *sheet = lyricsVC.sheetPresentationController;
            sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent];
            sheet.prefersGrabberVisible = YES;
        }
        NSString *tapVideoID = YTMUResolveCurrentVideoID() ?: resolvedVideoID;
        if (tapVideoID) {
            [lyricsVC fetchLyricsForVideo:tapVideoID];
        }
        [top presentViewController:lyricsVC animated:YES completion:^{
            if (!tapVideoID) {
                UILabel *statusLabel = [lyricsVC.tableView.tableHeaderView viewWithTag:8888];
                if (statusLabel) statusLabel.text = @"No video playing";
            }
        }];
    });
}


%hook YTEngagementPanelContainerViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    g_activeEngagementPanelContainer = self;
}

- (void)viewDidLoad {
    %orig;
    g_activeEngagementPanelContainer = self;
}

%end


%hook YTEngagementPanelViewControllerImpl

- (void)viewWillAppear:(BOOL)animated {
    %orig;

    UIViewController *vc = (UIViewController *)self;
    if (isLyricsEngagementPanel(vc)) {
        UIView *contentContainer = nil;
        for (UIView *sub in vc.view.subviews) {
            if (![NSStringFromClass([sub class]) isEqualToString:@"YTEngagementPanelHeaderView"]) {
                contentContainer = sub;
                break;
            }
        }

        if (contentContainer) {
            UIView *lyricsView = [contentContainer viewWithTag:9999];
            YTMULyricsViewController *lyricsVC = objc_getAssociatedObject(contentContainer, @selector(lyricsVC));

            if (!lyricsView || !lyricsVC) {
                lyricsVC = [[YTMULyricsViewController alloc] init];
                lyricsVC.view.tag = 9999;
                lyricsVC.view.frame = contentContainer.bounds;
                lyricsVC.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                lyricsVC.view.hidden = YES;
                [contentContainer addSubview:lyricsVC.view];
                objc_setAssociatedObject(contentContainer, @selector(lyricsVC), lyricsVC, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }

            lyricsVC.view.frame = contentContainer.bounds;

            NSString *panelVideoID = YTMUResolveCurrentVideoID();
            if (panelVideoID) {
                [lyricsVC fetchLyricsForVideo:panelVideoID];
            }
        }
    }
}


- (void)viewDidLayoutSubviews {
    %orig;

    UIViewController *vc = (UIViewController *)self;
    if (isLyricsEngagementPanel(vc)) {
        UIView *contentContainer = nil;
        for (UIView *sub in vc.view.subviews) {
            if (![NSStringFromClass([sub class]) isEqualToString:@"YTEngagementPanelHeaderView"]) {
                contentContainer = sub;
                break;
            }
        }

        if (contentContainer) {
            UIView *lyricsView = [contentContainer viewWithTag:9999];
            YTMULyricsViewController *lyricsVC = objc_getAssociatedObject(contentContainer, @selector(lyricsVC));

            if (!lyricsView || !lyricsVC) {
                lyricsVC = [[YTMULyricsViewController alloc] init];
                lyricsVC.view.tag = 9999;
                lyricsVC.view.frame = contentContainer.bounds;
                lyricsVC.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                lyricsVC.view.hidden = YES;
                [contentContainer addSubview:lyricsVC.view];
                objc_setAssociatedObject(contentContainer, @selector(lyricsVC), lyricsVC, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                if (g_currentVideoID) {
                    [lyricsVC fetchLyricsForVideo:g_currentVideoID];
                }
            }

            if (lyricsView && !lyricsView.hidden) {
                [contentContainer bringSubviewToFront:lyricsView];
                lyricsView.frame = contentContainer.bounds;
                for (UIView *sub in contentContainer.subviews) {
                    if (sub.tag != 9999) {
                        sub.hidden = YES;
                    }
                }
            } else if (lyricsView) {
                lyricsView.frame = contentContainer.bounds;
            }
        }
    }
}

%end


// Central lyrics-renderer check: text, accessibility, description, and the
// command's browseEndpoint.browseId (catches icon-only chips with no text).
static BOOL YTMUIsLyricsRenderer(YTIButtonRenderer *renderer) {
    if (!renderer) return NO;
    if (renderer.text) {
        NSString *t = nil;
        if ([renderer.text respondsToSelector:@selector(runs)]) {
            NSArray *runs = [renderer.text performSelector:@selector(runs)];
            if (runs && runs.count > 0) {
                NSMutableString *ms = [NSMutableString string];
                for (id r in runs) {
                    if ([r respondsToSelector:@selector(text)]) {
                        NSString *rt = [r performSelector:@selector(text)];
                        if (rt) [ms appendString:rt];
                    }
                }
                t = ms;
            }
        }
        if (!t && [renderer.text respondsToSelector:@selector(simpleText)]) {
            t = [renderer.text performSelector:@selector(simpleText)];
        }
        if (t && ([t containsString:@"歌詞"] || [t containsString:@"歌词"] || [t.lowercaseString containsString:@"lyric"])) {
            return YES;
        }
    }
    if (renderer.accessibilityData) {
        NSString *accDesc = [renderer.accessibilityData description];
        if ([accDesc containsString:@"歌詞"] || [accDesc containsString:@"歌词"] || [accDesc.lowercaseString containsString:@"lyric"]) {
            return YES;
        }
    }
    if (renderer.accessibility) {
        NSString *accDesc = [renderer.accessibility description];
        if ([accDesc containsString:@"歌詞"] || [accDesc containsString:@"歌词"] || [accDesc.lowercaseString containsString:@"lyric"]) {
            return YES;
        }
    }
    @try {
        NSString *browseId = renderer.command.browseEndpoint.browseId;
        if (browseId.length && [browseId.lowercaseString containsString:@"lyric"]) {
            return YES;
        }
    } @catch (NSException *e) {}
    NSString *desc = [renderer description];
    if ([desc containsString:@"PAmusic_watch_lyrics_panel"] || [desc.lowercaseString containsString:@"lyrics_panel"] || [desc.lowercaseString containsString:@"lyrics"]) {
        return YES;
    }
    return NO;
}

// Unlock lyrics button when YTM has no native lyrics
%hook YTIButtonRenderer

- (BOOL)isDisabled {
    if (YTMUIsLyricsRenderer(self)) {
        return NO;
    }
    return %orig;
}

- (void)setIsDisabled:(BOOL)disabled {
    if (YTMUIsLyricsRenderer(self)) {
        %orig(NO);
        return;
    }
    %orig(disabled);
}

%end


// Aggressively lock lyrics controls to always enabled, unhidden, and full opacity ("while true set true")
%hook UIControl

- (void)setEnabled:(BOOL)enabled {
    if (!enabled && objc_getAssociatedObject(self, @selector(ytmu_isLyricsButton))) {
        %orig(YES);
        return;
    }
    %orig(enabled);
}

%end

%hook UIView

- (void)setUserInteractionEnabled:(BOOL)enabled {
    if (!enabled && objc_getAssociatedObject(self, @selector(ytmu_isLyricsButton))) {
        %orig(YES);
        return;
    }
    %orig(enabled);
}

- (void)setAlpha:(CGFloat)alpha {
    if (alpha < 0.8 && objc_getAssociatedObject(self, @selector(ytmu_isLyricsButton))) {
        %orig(1.0);
        return;
    }
    %orig(alpha);
}

- (void)setHidden:(BOOL)hidden {
    if (hidden && objc_getAssociatedObject(self, @selector(ytmu_isLyricsButton))) {
        %orig(NO);
        return;
    }
    %orig(hidden);
}

%end


// Unlock lyrics button tap in Elements (ELM) — mirrors Downloading.x:
// exact node-key match first, NowPlaying ancestor required.
%hook ELMTouchCommandPropertiesHandler

- (void)handleTap {
    if (class_getInstanceVariable([self class], "_controller") == NULL) {
        return %orig;
    }
    if (class_getInstanceVariable([self class], "_tapRecognizer") == NULL) {
        return %orig;
    }

    ELMNodeController *node = [self valueForKey:@"_controller"];
    UIGestureRecognizer *tapRecognizer = [self valueForKey:@"_tapRecognizer"];

    NSString *key = nil;
    if ([node respondsToSelector:@selector(key)]) {
        @try { key = [node key]; } @catch (NSException *e) { key = nil; }
    }
    NSString *nodeDesc = [node description] ?: @"";
    BOOL keyMatch = key.length > 0 && [key.lowercaseString containsString:@"lyric"];
    BOOL descMatch = [nodeDesc containsString:@"lyric"] || [nodeDesc containsString:@"format_quote"] || [nodeDesc containsString:@"queue_music"];
    if (!keyMatch && !descMatch) {
        return %orig;
    }

    UIViewController *vc = [tapRecognizer.view _viewControllerForAncestor];
    if (![vc isKindOfClass:%c(YTMNowPlayingViewController)]) {
        return %orig;
    }

    sendDebugLog([NSString stringWithFormat:@"[MUSIC] Lyrics ELM tap key=%@ vc=%@", key ?: @"(nil)", NSStringFromClass([vc class])]);
    openLyricsFromViewController(vc);
    return;
}

%end


// Hook YTMActionRowView to unlock lyrics chip
%hook YTMActionRowView

- (void)layoutSubviews {
    %orig;
    UIViewController *vc = [self _viewControllerForAncestor];
    if (vc && [vc respondsToSelector:@selector(ytmu_makeLyricsViewClickable:)]) {
        for (UIView *sub in self.subviews) {
            [(YTMNowPlayingViewController *)vc ytmu_makeLyricsViewClickable:sub];
        }
    }
}

%end


// Make the lyrics button and bottom view in Now Playing always active & clickable
%hook YTMNowPlayingViewController

- (void)viewDidLayoutSubviews {
    %orig;
    for (UIView *sub in self.view.subviews) {
        [self ytmu_makeLyricsViewClickable:sub];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    [self ytmu_keepLyricsButtonActive];
}

%new
- (void)ytmu_keepLyricsButtonActive {
    for (UIView *sub in self.view.subviews) {
        [self ytmu_makeLyricsViewClickable:sub];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        for (UIView *sub in self.view.subviews) {
            [self ytmu_makeLyricsViewClickable:sub];
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        for (UIView *sub in self.view.subviews) {
            [self ytmu_makeLyricsViewClickable:sub];
        }
    });
}

%new
- (void)ytmu_makeLyricsViewClickable:(UIView *)v {
    if (!v) return;

    BOOL isLyrics = NO;
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *lbl = (UILabel *)v;
        NSString *txt = lbl.text ?: lbl.attributedText.string;
        if (txt) {
            NSString *low = txt.lowercaseString;
            if ([txt containsString:@"歌詞"] || [txt containsString:@"歌词"] || [low containsString:@"lyric"] || [low containsString:@"unavailable"] || [txt containsString:@"沒有歌詞"] || [txt containsString:@"没有歌词"] || [txt containsString:@"無歌詞"] || [txt containsString:@"無提供歌詞"]) {
                isLyrics = YES;
            }
        }
    }
    if (!isLyrics && v.accessibilityLabel) {
        NSString *low = v.accessibilityLabel.lowercaseString;
        if ([low containsString:@"歌詞"] || [low containsString:@"歌词"] || [low containsString:@"lyric"]) {
            isLyrics = YES;
        }
    }
    if (!isLyrics && v.accessibilityIdentifier) {
        NSString *low = v.accessibilityIdentifier.lowercaseString;
        if ([low containsString:@"lyric"]) {
            isLyrics = YES;
        }
    }
    if (!isLyrics && [v respondsToSelector:@selector(titleForState:)]) {
        NSString *title = [(UIButton *)v titleForState:UIControlStateNormal];
        if (title) {
            NSString *low = title.lowercaseString;
            if ([title containsString:@"歌詞"] || [title containsString:@"歌词"] || [low containsString:@"lyric"]) {
                isLyrics = YES;
            }
        }
    }

    if (isLyrics) {
        // Trace up to the button container view (chip or tab)
        UIView *btn = v;
        while (btn.superview && btn.superview != self.view && btn.superview.bounds.size.width < 250) {
            btn = btn.superview;
        }

        // Own-button mode: hide the official chip and show ours in its
        // place. Falls through to the legacy unlock path when replacement
        // is impossible (e.g. ELM texture node with no container view).
        if (YTMULyricsPreference(@"lyricsOwnButton", YES) && [self ytmu_replaceLyricsChip:btn]) {
            return;
        }

        // Tag button and all subviews with ytmu_isLyricsButton so hooks persistently force them active
        objc_setAssociatedObject(btn, @selector(ytmu_isLyricsButton), @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        btn.userInteractionEnabled = YES;
        btn.alpha = 1.0;
        btn.hidden = NO;
        if (btn.superview) {
            btn.superview.userInteractionEnabled = YES;
        }
        for (UIView *child in btn.subviews) {
            objc_setAssociatedObject(child, @selector(ytmu_isLyricsButton), @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            child.userInteractionEnabled = YES;
            child.alpha = 1.0;
            child.hidden = NO;
        }

        if ([btn isKindOfClass:[UIControl class]]) {
            [(UIControl *)btn setEnabled:YES];
            [(UIControl *)btn addTarget:self action:@selector(ytmu_didTapLyricsButtonAction:) forControlEvents:UIControlEventTouchUpInside];
        }

        // UIControls already receive the target/action above. Attaching both a
        // target and a recognizer made one tap open the lyrics panel twice.
        if (![btn isKindOfClass:[UIControl class]] && !objc_getAssociatedObject(btn, @selector(ytmu_didTapLyricsBar:))) {
            UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(ytmu_didTapLyricsBar:)];
            tap.cancelsTouchesInView = NO;
            [btn addGestureRecognizer:tap];
            objc_setAssociatedObject(btn, @selector(ytmu_didTapLyricsBar:), tap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }

        // Also attach tap recognizer directly to label / subview as a direct touch target
        if (v != btn && !objc_getAssociatedObject(v, @selector(ytmu_didTapLyricsBar:))) {
            v.userInteractionEnabled = YES;
            objc_setAssociatedObject(v, @selector(ytmu_isLyricsButton), @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            UITapGestureRecognizer *lblTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(ytmu_didTapLyricsBar:)];
            lblTap.cancelsTouchesInView = NO;
            [v addGestureRecognizer:lblTap];
            objc_setAssociatedObject(v, @selector(ytmu_didTapLyricsBar:), lblTap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }

    for (UIView *child in v.subviews) {
        [self ytmu_makeLyricsViewClickable:child];
    }
}

%new
- (BOOL)ytmu_replaceLyricsChip:(UIView *)official {
    UIView *parent = official.superview;
    if (!parent) return NO;
    // Never fight ourselves, and never swallow a large container: only a
    // chip-sized view gets replaced (layout rescans heal anything else).
    if ([official isKindOfClass:[UIButton class]] && official.tag == 9777) return YES;
    if (official.bounds.size.width >= 250 || official.bounds.size.width <= 0) return NO;

    // Untag so our force-visible hooks let the official chip stay hidden.
    objc_setAssociatedObject(official, @selector(ytmu_isLyricsButton), nil);
    for (UIView *child in official.subviews) {
        objc_setAssociatedObject(child, @selector(ytmu_isLyricsButton), nil);
    }
    official.hidden = YES;

    // Reuse the official label text when we can find it.
    NSString *chipTitle = @"歌詞";
    if ([official isKindOfClass:[UILabel class]] && ((UILabel *)official).text.length) {
        chipTitle = ((UILabel *)official).text;
    } else {
        for (UIView *child in official.subviews) {
            if ([child isKindOfClass:[UILabel class]] && ((UILabel *)child).text.length) {
                chipTitle = ((UILabel *)child).text;
                break;
            }
        }
    }

    UIButton *own = (UIButton *)[parent viewWithTag:9777];
    if (![own isKindOfClass:[UIButton class]]) {
        own = [UIButton buttonWithType:UIButtonTypeSystem];
        own.tag = 9777;
        [own setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        own.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        own.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
        own.layer.masksToBounds = YES;
        [own addTarget:self action:@selector(ytmu_didTapLyricsButtonAction:) forControlEvents:UIControlEventTouchUpInside];
        [parent addSubview:own];
    }
    [own setTitle:chipTitle forState:UIControlStateNormal];
    own.frame = official.frame;
    own.autoresizingMask = official.autoresizingMask;
    own.layer.cornerRadius = MAX(official.bounds.size.height / 2.0, 8.0);
    own.hidden = NO;
    return YES;
}

%new
- (void)ytmu_didTapLyricsButtonAction:(id)sender {
    sendDebugLog(@"[MUSIC] Lyrics button tapped via UIControl");
    openLyricsFromViewController((UIViewController *)self);
}

%new
- (void)ytmu_didTapLyricsBar:(UITapGestureRecognizer *)gesture {
    sendDebugLog(@"[MUSIC] Lyrics chip tapped via UITapGestureRecognizer");
    openLyricsFromViewController((UIViewController *)self);
}

%end

%hook YTPlayerViewController

- (void)viewDidLoad {
    %orig;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ytmu_handleSeek:) name:@"YTMUSeekToTime" object:nil];
}

%new
- (void)ytmu_handleSeek:(NSNotification *)notif {
    NSNumber *timeObj = notif.object;
    if (!timeObj) return;

    double time = [timeObj doubleValue];
    NSLog(@"[YTMU-Seek] Attempting to seek to: %f", time);

    if ([self respondsToSelector:@selector(seekToTime:)]) {
        [self seekToTime:time];
    } else if ([self respondsToSelector:@selector(seekToTime:toleranceBefore:toleranceAfter:)]) {
        [self seekToTime:time toleranceBefore:0 toleranceAfter:0];
    } else {
        NSLog(@"[YTMU-Seek] ERROR: YTPlayerViewController does not respond to standard seek methods.");
    }
}

%end
