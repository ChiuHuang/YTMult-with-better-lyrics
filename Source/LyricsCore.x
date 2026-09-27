#import "LyricsShared.h"
#import <CommonCrypto/CommonDigest.h>

BOOL _safe_cache_component(NSString *s);
BOOL YTMUAppSettingBool(NSString *key, BOOL dflt);
void YTMUAutoSyncIfDue(void);

@interface NSObject (YTMUQueuePrecache)
- (NSArray *)queueItems;
- (NSString *)videoId;
- (NSString *)contentVideoId;
@end

double g_currentPlaybackTime = 0.0;
NSString *g_currentVideoID = nil;
__weak YTPlayerViewController *g_activePlayer = nil;
__weak UIButton *g_ytmuOwnLyricsButton = nil;
__weak UIViewController *g_activeNowPlayingVC = nil;
NSMutableDictionary *g_lyricsCache = nil;
NSString *g_globalLoadingVideoID = nil;
BOOL g_globalLoadingInFlight = NO;
NSDate *g_loadingSince = nil;
__weak id g_activeEngagementPanelContainer = nil;

// ============================================================
// Provider lyrics held in RAM on the device
// ============================================================
// Every provider a song's full fetch raced is kept here, in memory, keyed by
// video id then provider name. Nothing here is ever written to disk: the only
// provider lyrics that get cached are the ones the user actually selects
// (YTMULyricsCacheSave, called from the select path). Bounded LRU so a long
// listening session cannot grow without limit; the next song re-fills.
NSMutableDictionary *g_providerLyricsRAM = nil;  // vid -> {provider: lyrics}
static NSMutableArray *g_providerRAMOrder = nil; // vids, oldest first
static const NSUInteger YTMU_PROVIDER_RAM_VIDEOS = 8;

static void ytmu_providerRAMInit(void) {
    if (!g_providerLyricsRAM) g_providerLyricsRAM = [NSMutableDictionary dictionary];
    if (!g_providerRAMOrder) g_providerRAMOrder = [NSMutableArray array];
}

void YTMUProviderLyricsStore(NSString *videoID, NSArray *entries) {
    if (!videoID.length || ![entries isKindOfClass:[NSArray class]] || entries.count == 0) return;
    ytmu_providerRAMInit();
    NSMutableDictionary *byProvider = [NSMutableDictionary dictionary];
    for (NSDictionary *e in entries) {
        if (![e isKindOfClass:[NSDictionary class]]) continue;
        NSString *prov = e[@"provider"];
        NSArray *lyrics = e[@"lyrics"];
        if (![prov isKindOfClass:[NSString class]] || !prov.length) continue;
        if (![lyrics isKindOfClass:[NSArray class]] || lyrics.count == 0) continue;
        byProvider[prov] = lyrics;
    }
    if (byProvider.count == 0) return;
    g_providerLyricsRAM[videoID] = byProvider;
    [g_providerRAMOrder removeObject:videoID];
    [g_providerRAMOrder addObject:videoID];
    while (g_providerRAMOrder.count > YTMU_PROVIDER_RAM_VIDEOS) {
        NSString *old = g_providerRAMOrder.firstObject;
        [g_providerRAMOrder removeObjectAtIndex:0];
        if (old.length) [g_providerLyricsRAM removeObjectForKey:old];
    }
}

NSArray *YTMUProviderLyricsForProvider(NSString *videoID, NSString *provider) {
    if (!videoID.length || !provider.length) return nil;
    NSDictionary *byProvider = g_providerLyricsRAM[videoID];
    NSArray *lyrics = byProvider[provider];
    return [lyrics isKindOfClass:[NSArray class]] ? lyrics : nil;
}

NSUInteger YTMUProviderLyricsCount(NSString *videoID) {
    return [g_providerLyricsRAM[videoID] count];
}

void YTMUProviderLyricsDrop(NSString *videoID) {
    if (!videoID.length) return;
    [g_providerLyricsRAM removeObjectForKey:videoID];
    [g_providerRAMOrder removeObject:videoID];
}

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
// Central gate for every device->server debug upload (log POSTs, DEBUG_
// pings, screenshot dumps). Default OFF on all three inputs: the local
// master toggle, the log-level segment, and the server remote switch.
BOOL YTMUDebugUploadAllowed(NSString *level) {
    if (!YTMULyricsPreference(@"sendDebugLogsToServer", NO)) return NO;
    if (!YTMUAppSettingBool(@"upload_logs", YES)) return NO;
    NSDictionary *settings = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    NSInteger cfg = MIN(MAX([settings[@"debugLogLevel"] integerValue], 0), 2);
    if (cfg <= 0) return NO;
    if (cfg == 1) {
        NSString *low = [[NSString stringWithFormat:@"%@", level ?: @""] lowercaseString];
        return [low containsString:@"error"] || [low containsString:@"fail"] || [low containsString:@"warn"];
    }
    return YES;
}

static NSString *YTMULyricsOffsetKey(NSString *videoID) {
    return [NSString stringWithFormat:@"lyricsTimingOffset_%@", videoID];
}
// Automatic shift for a video whose head is a skipped non-music intro
// (SponsorBlock music_offtopic at 0). Kept in its own key so a manual
// nudge never eats it, unskip can drop it, and the settings field can
// show both numbers separately.
static NSString *YTMULyricsSponsorOffsetKey(NSString *videoID) {
    return [NSString stringWithFormat:@"lyricsSponsorOffset_%@", videoID];
}
// Per-tick callers (30fps lyric loop) must not deserialize NSUserDefaults
// every frame: cache the value per video, invalidate on set.
static NSString *g_offsetVideoID = nil;
static double g_offsetValue = 0.0;
static void YTMULyricsOffsetCacheDrop(void) {
    g_offsetVideoID = nil;
    g_offsetValue = 0.0;
}
static void YTMULyricsOffsetStore(NSString *key, double value) {
    NSMutableDictionary *d = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"] mutableCopy];
    if (!d) d = [NSMutableDictionary dictionary];
    if (value == 0.0) [d removeObjectForKey:key];
    else d[key] = @(value);
    [[NSUserDefaults standardUserDefaults] setObject:d forKey:@"YTMUltimate"];
    YTMULyricsOffsetCacheDrop();
}
double YTMULyricsManualOffsetForVideoID(NSString *videoID) {
    if (!videoID.length) return 0.0;
    NSDictionary *settings = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    return [settings[YTMULyricsOffsetKey(videoID)] doubleValue];
}
double YTMULyricsSponsorOffsetForVideoID(NSString *videoID) {
    if (!videoID.length) return 0.0;
    NSDictionary *settings = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    return [settings[YTMULyricsSponsorOffsetKey(videoID)] doubleValue];
}
// Total the lyric loop applies: playback time + manual + intro skip.
double YTMULyricsOffsetForVideoID(NSString *videoID) {
    if (!videoID.length) return 0.0;
    if (g_offsetVideoID && [videoID isEqualToString:g_offsetVideoID]) return g_offsetValue;
    NSDictionary *settings = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    double v = [settings[YTMULyricsOffsetKey(videoID)] doubleValue]
             + [settings[YTMULyricsSponsorOffsetKey(videoID)] doubleValue];
    g_offsetVideoID = [videoID copy];
    g_offsetValue = v;
    return v;
}
void YTMULyricsSetOffsetForVideoID(NSString *videoID, double offset) {
    if (!videoID.length) return;
    if (offset > 30.0) offset = 30.0;
    if (offset < -30.0) offset = -30.0;
    YTMULyricsOffsetStore(YTMULyricsOffsetKey(videoID), offset);
}
void YTMULyricsSetSponsorOffsetForVideoID(NSString *videoID, double offset) {
    if (!videoID.length) return;
    if (offset > 0.0) offset = 0.0;
    if (offset < -900.0) offset = -900.0;
    YTMULyricsOffsetStore(YTMULyricsSponsorOffsetKey(videoID), offset);
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

NSDictionary *YTMUAppSettings(void) {
    NSDictionary *cached = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUAppSettings"];
    return [cached isKindOfClass:[NSDictionary class]] ? cached : @{};
}
BOOL YTMUAppSettingBool(NSString *key, BOOL dflt) {
    id v = YTMUAppSettings()[key];
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
    if ([v isKindOfClass:[NSString class]]) {
        if ([v caseInsensitiveCompare:@"true"] == NSOrderedSame || [v isEqualToString:@"1"]) return YES;
        if ([v caseInsensitiveCompare:@"false"] == NSOrderedSame || [v isEqualToString:@"0"]) return NO;
    }
    return dflt;
}
void YTMUFetchAppSettings(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSTimeInterval last = [ud doubleForKey:@"YTMUAppSettingsFetchedAt"];
    if (last > 0 && [[NSDate date] timeIntervalSince1970] - last < 3600) return;
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/api/app/settings", YTMUApiBase()]];
    if (!url) return;
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
        if (err || !data) return;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSDictionary *s = json[@"settings"];
        if (![s isKindOfClass:[NSDictionary class]]) return;
        NSUserDefaults *ud2 = [NSUserDefaults standardUserDefaults];
        [ud2 setObject:s forKey:@"YTMUAppSettings"];
        [ud2 setDouble:[[NSDate date] timeIntervalSince1970] forKey:@"YTMUAppSettingsFetchedAt"];
    }] resume];
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
    if (!YTMUDebugUploadAllowed(@"info")) return;
    NSString *encodedMsg = YTMUUrlEncode(full);
    NSString *serverURL = [NSString stringWithFormat:@"%@/api/lyrics?v=DEBUG_%@", YTMUApiBase(), encodedMsg];
    [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:serverURL]] resume];
}
void __attribute__((unused)) sendDebugLogWithPayload(NSString *event, NSString *msg, NSDictionary *payload) {
    if (!YTMUDebugUploadAllowed(@"info")) {
        sendDebugLog([NSString stringWithFormat:@"%@: %@ %@", event, msg, payload ?: @{}]);
        return;
    }
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
BOOL YTMULyricsIsUsable(NSArray *lyrics, NSDictionary *dict) {
    // Mirrors the server's is_not_found_result: empty, flagged, error-source,
    // or single "No lyrics found" line. Guards both disk and memory caches.
    if (![lyrics isKindOfClass:[NSArray class]] || lyrics.count == 0) return NO;
    if ([dict[@"not_found"] boolValue]) return NO;
    id src = dict[@"source"];
    if ([src isKindOfClass:[NSString class]] &&
        ([src isEqualToString:@"none"] || [src isEqualToString:@"error"])) return NO;
    if (lyrics.count == 1 && [lyrics[0] isKindOfClass:[NSDictionary class]]) {
        id t = lyrics[0][@"text"];
        if ([t isKindOfClass:[NSString class]] && [t containsString:@"No lyrics found"]) return NO;
    }
    return YES;
}
void YTMULyricsCacheSave(NSString *videoID, NSArray *lyrics) {
    if (!YTMULyricsCacheEnabled() || !videoID.length) return;
    NSString *path = YTMULyricsCachePathForVideoID(videoID);
    if (!path) return;
    // Never persist not-found/empty results: drop any stale file instead so
    // a later fetch retries instead of serving a cached miss forever.
    if (![lyrics isKindOfClass:[NSArray class]] || lyrics.count == 0) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        return;
    }
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

#pragma mark - Canonical lyrics hashing (matches server lyrics_content_hash)

typedef NSMutableData *MutableDataRef;

static void _append_int32_be(MutableDataRef buf, int32_t v) {
    uint8_t bytes[4] = { (v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF };
    [buf appendBytes:bytes length:4];
}
static void _append_int8(MutableDataRef buf, int8_t v) {
    [buf appendBytes:&v length:1];
}


static NSData *YTMULyricsCanonicalData(NSArray *lyrics) {
    if (!lyrics || lyrics.count == 0) return [NSData data];
    // Sort by startTimeMs
    NSArray *sorted = [lyrics sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        int64_t aStart = [a[@"startTimeMs"] longLongValue] ?: (int64_t)round([a[@"time"] doubleValue] * 1000);
        int64_t bStart = [b[@"startTimeMs"] longLongValue] ?: (int64_t)round([b[@"time"] doubleValue] * 1000);
        return aStart < bStart ? NSOrderedAscending : (aStart > bStart ? NSOrderedDescending : NSOrderedSame);
    }];
    MutableDataRef buf = [NSMutableData data];
    for (NSDictionary *line in sorted) {
        int64_t start = [line[@"startTimeMs"] longLongValue] ?: (int64_t)round([line[@"time"] doubleValue] * 1000);
        int64_t dur = [line[@"durationMs"] longLongValue] ?: (int64_t)round([line[@"duration"] doubleValue] * 1000);
        NSString *text = line[@"text"] ?: @"";
        NSString *trans = line[@"translated"] ?: @"";
        int8_t ws = [line[@"wordSynced"] boolValue] ? 1 : 0;
        NSArray *parts = line[@"parts"] ?: @[];
        NSData *textData = [text dataUsingEncoding:NSUTF8StringEncoding];
        NSData *transData = [trans dataUsingEncoding:NSUTF8StringEncoding];
        _append_int32_be(buf, (int32_t)start);
        _append_int32_be(buf, (int32_t)dur);
        _append_int32_be(buf, (int32_t)textData.length);
        [buf appendData:textData];
        _append_int32_be(buf, (int32_t)transData.length);
        [buf appendData:transData];
        _append_int8(buf, ws);
        _append_int32_be(buf, (int32_t)parts.count);
        for (NSDictionary *p in parts) {
            NSString *words = p[@"words"] ?: @"";
            NSData *wordsData = [words dataUsingEncoding:NSUTF8StringEncoding];
            int64_t pStart = [p[@"startTimeMs"] longLongValue];
            int64_t pDur = [p[@"durationMs"] longLongValue];
            _append_int32_be(buf, (int32_t)wordsData.length);
            [buf appendData:wordsData];
            _append_int32_be(buf, (int32_t)pStart);
            _append_int32_be(buf, (int32_t)pDur);
        }
    }
    return [buf copy];
}

NSString *YTMULyricsContentHash(NSString *videoID) {
    NSArray *lyrics = YTMULyricsCacheLoad(videoID);
    if (!lyrics) return nil;
    NSData *canon = YTMULyricsCanonicalData(lyrics);
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(canon.bytes, (CC_LONG)canon.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

NSArray *YTMULyricsCacheEntries(void) {
    NSMutableArray *entries = [NSMutableArray array];
    NSString *dir = YTMULyricsCacheDirectory();
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil] ?: @[];
    for (NSString *f in files) {
        if (![f hasSuffix:@".json"]) continue;
        NSString *vid = [f stringByDeletingPathExtension];
        NSArray *lyrics = YTMULyricsCacheLoad(vid);
        if (!lyrics) continue;
        NSData *data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:f]];
        NSInteger cv = 0;
        if (data) {
            NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            cv = [dict[@"cv"] integerValue];
        }
        NSString *hash = YTMULyricsContentHash(vid);
        NSString *tier = YTMULyricsTier(lyrics);
        [entries addObject:@{@"video_id": vid, @"hash": hash ?: @"", @"cv": @(cv), @"tier": tier}];
    }
    return [entries copy];
}

static void ytmu_precachePost(NSArray *validVids, NSString *lang, BOOL full) {
    if (!validVids.count) return;
    NSString *urlStr = [NSString stringWithFormat:@"%@/api/lyrics/precache", YTMUApiBase()];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return;

    NSMutableDictionary *body = [NSMutableDictionary dictionary];
    body[@"video_ids"] = validVids;
    body[@"lang"] = lang ?: YTMUTargetLang();
    if (full) body[@"full"] = @YES;

    NSString *jwt = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"][@"ytmuJwtToken"];
    if (jwt && jwt.length) body[@"jwt"] = jwt;

    NSData *jsonBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if (!jsonBody) return;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = jsonBody;
    req.timeoutInterval = 10.0;

    NSString *tag = full ? @"all" : @"fast";
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
        sendDebugLog([NSString stringWithFormat:@"[PRECACHE] Queued %@ videos (%@, job: %@)",
                      @(validVids.count), tag, json[@"job_id"] ?: @"?"]);
    }] resume];
}

void YTMULyricsPrecacheQueue(NSArray *videoIDs, NSString *lang, BOOL useFull) {
    if (!videoIDs || videoIDs.count == 0) return;
    if (!lang.length) lang = YTMUTargetLang();

    NSMutableArray *validVids = [NSMutableArray array];
    for (NSString *vid in videoIDs) {
        if ([vid isKindOfClass:[NSString class]] && vid.length && _safe_cache_component(vid)) {
            [validVids addObject:vid];
            if (validVids.count >= 20) break;
        }
    }
    if (validVids.count == 0) return;

    if (useFull) {
        ytmu_precachePost(validVids, lang, YES);
        return;
    }
    // The track that plays next gets the full pipeline: every provider is
    // raced (so the server holds the whole list in RAM and the switcher is
    // armed the moment it starts) and only the winner is cached. The rest of
    // the queue stays on the cheap fast path.
    ytmu_precachePost(@[validVids.firstObject], lang, YES);
    if (validVids.count > 1) {
        ytmu_precachePost([validVids subarrayWithRange:NSMakeRange(1, validVids.count - 1)], lang, NO);
    }
    YTMUPrefetchProviderLyrics(validVids, lang);
}

// Prefetch every provider's lyrics for the tracks that are about to play, into
// device RAM. The server already raced them (see YTMULyricsPrecacheQueue), so
// this is one small read per track and no provider traffic at all: when the
// next song starts its switcher is already warm. RAM only -- nothing on disk.
void YTMUPrefetchProviderLyrics(NSArray *videoIDs, NSString *lang) {
    if (!videoIDs.count) return;
    NSMutableArray *todo = [NSMutableArray array];
    for (NSString *vid in videoIDs) {
        if (![vid isKindOfClass:[NSString class]] || !vid.length) continue;
        if (!_safe_cache_component(vid)) continue;
        if (YTMUProviderLyricsCount(vid) > 0) continue;  // already warm
        [todo addObject:vid];
        if (todo.count >= 2) break;
    }
    if (todo.count == 0) return;
    NSString *target = lang.length ? lang : YTMUTargetLang();
    // The full precache is still running for the first track, so give it a
    // moment to land the snapshot before asking for it.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        for (NSString *vid in todo) {
            NSString *urlStr = [NSString stringWithFormat:@"%@/api/lyrics/providers/data?v=%@&lang=%@",
                                YTMUApiBase(), vid, target];
            NSURL *url = [NSURL URLWithString:urlStr];
            if (!url) continue;
            [[[NSURLSession sharedSession] dataTaskWithURL:url
                completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
                if (err || !data) return;
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                NSArray *entries = json[@"providers"];
                if (![json[@"found"] boolValue] || ![entries isKindOfClass:[NSArray class]]) return;
                YTMUProviderLyricsStore(vid, entries);
                sendDebugLog([NSString stringWithFormat:@"[MUSIC] prefetch %lu provider(s) into RAM for %@",
                              (unsigned long)YTMUProviderLyricsCount(vid), vid]);
            }] resume];
        }
    });
}

BOOL _safe_cache_component(NSString *s) {
    if (!s || !s.length) return NO;
    NSCharacterSet *invalid = [NSCharacterSet characterSetWithCharactersInString:@":/\\?%*|\"<>"];
    return [s rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

void YTMUAutoSyncIfDue(void) {
    // Silent background batch sync: hash local cache -> POST /api/lyrics/sync
    // -> save need[] entries. No UI, no regen job, 6h throttle, on by default.
    if (!YTMULyricsPreference(@"lyricsAutoSync", YES)) return;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - [ud doubleForKey:@"YTMUAutoSyncAt"] < 6 * 3600) return;
    NSArray *cacheEntries = YTMULyricsCacheEntries();
    if (!cacheEntries.count) return;
    [ud setDouble:now forKey:@"YTMUAutoSyncAt"];
    NSMutableArray *entries = [NSMutableArray array];
    for (NSDictionary *e in cacheEntries) {
        NSString *vid = e[@"video_id"];
        NSString *hash = e[@"hash"];
        if (!vid.length || !hash.length) continue;
        [entries addObject:@{@"video_id": vid, @"hash": hash,
                             @"cv": e[@"cv"] ?: @(YTMULyricsCacheFormatVersion()),
                             @"tier": e[@"tier"] ?: @""}];
        if (entries.count >= 500) break;
    }
    if (!entries.count) return;
    NSDictionary *body = @{@"lang": YTMUTargetLang(),
                           @"auto_zh": @(YTMULyricsPreference(@"lyricsAutoZhConvert", YES)),
                           @"entries": entries,
                           @"regenerate": @NO,
                           @"max_items": @500};
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if (!bodyData) return;
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/api/lyrics/sync", YTMUApiBase()]];
    if (!url) return;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = bodyData;
    req.timeoutInterval = 30.0;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
        if (err || !data) return;
        NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![root isKindOfClass:[NSDictionary class]]) return;
        NSInteger saved = 0;
        for (NSDictionary *entry in root[@"need"]) {
            if (![entry isKindOfClass:[NSDictionary class]]) continue;
            NSString *vid = entry[@"videoID"];
            NSArray *lyrics = entry[@"lyrics"];
            if (!vid.length || !YTMULyricsIsUsable(lyrics, entry)) continue;
            YTMULyricsCacheSave(vid, lyrics);
            if (!g_lyricsCache) g_lyricsCache = [[NSMutableDictionary alloc] init];
            g_lyricsCache[vid] = lyrics;
            saved++;
        }
        sendDebugLog([NSString stringWithFormat:@"[SYNC] background auto-sync saved %ld", (long)saved]);
    }] resume];
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
    if (!YTMUDebugUploadAllowed(@"info")) return;
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
        YTMUFetchAppSettings();
        YTMUAutoSyncIfDue();
    });
    return result;
}
%end

%ctor {
    %init;
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationUserDidTakeScreenshotNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if (YTMULyricsPreference(@"sendLyricsScreenshotDebug", NO) && YTMUDebugUploadAllowed(@"info")) {
            sendUIDump();
        }
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:@"YTMUClearMemoryCache" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if (g_lyricsCache) [g_lyricsCache removeAllObjects];
    }];
    void (^prewarmJWT)(NSNotification *) = ^(NSNotification *note) {
        [[YTMUTurnstileManager sharedManager] getJWTTokenWithCompletion:nil];
        YTMUFetchAppSettings();
        YTMUAutoSyncIfDue();
    };
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:prewarmJWT];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:prewarmJWT];
    YTMURegisterLandscapeAutoOpen();
}
