#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreHaptics/CoreHaptics.h>
#import <MediaPlayer/MediaPlayer.h>
#import <stdatomic.h>
#import <math.h>
#import <stdint.h>
#import <mach/mach_time.h>
#import <string.h>
#import "LyricsShared.h"

static NSMutableArray<NSString *> *YTMUISRCRecentLogLines;
static atomic_uint_fast64_t YTMUAudioLastHostTime;
static atomic_uint_fast32_t YTMUAudioOnsetSequence;
static atomic_uint_fast32_t YTMUAudioPeakBits;
static mach_timebase_info_data_t YTMUHostTimebase;
static uint64_t YTMUHostTimeNow(void) {
    return mach_absolute_time();
}

static uint64_t YTMUHostTicksToNanos(uint64_t ticks) {
    return YTMUHostTimebase.denom ? (ticks * YTMUHostTimebase.numer) / YTMUHostTimebase.denom : 0;
}

static float YTMUFloatFromBits(uint32_t value) {
    union { float f; uint32_t u; } bits = {.u = value};
    return bits.f;
}

static void YTMULogISRC(NSString *message) {
    if (!message.length) return;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ YTMUISRCRecentLogLines = [NSMutableArray array]; });
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"%@ %@",
                      [formatter stringFromDate:[NSDate date]], message];
    @synchronized (YTMUISRCRecentLogLines) {
        [YTMUISRCRecentLogLines addObject:line];
        if (YTMUISRCRecentLogLines.count > 60) {
            [YTMUISRCRecentLogLines removeObjectsInRange:NSMakeRange(0, YTMUISRCRecentLogLines.count - 60)];
        }
    }
    NSLog(@"[YTMU-ISRC] %@", message);
    sendDebugLog([@"[ISRC] " stringByAppendingString:message]);
}

// Both the player metadata hook and asynchronous lookup must use the same key;
// otherwise each Now Playing refresh can make an in-flight result look stale.
static NSString *YTMUISRCTrackKey(NSString *title, NSString *artist, NSString *videoID) {
    return [NSString stringWithFormat:@"v2|%@|%@|%@",
            [title.lowercaseString stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet],
            [artist.lowercaseString stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet],
            videoID ?: @""];
}

static void YTMUReportISRCStatus(NSString *videoID, NSString *title, NSString *artist,
                                 NSString *source, NSString *state, NSString *isrc) {
    if (!title.length && !artist.length && !videoID.length) return;
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/api/isrc/report", YTMUApiBase()]];
    if (!url) return;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                          cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                      timeoutInterval:3.0];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSMutableDictionary *body = [@{@"video_id": videoID ?: @"", @"title": title ?: @"",
                                   @"artist": artist ?: @"", @"source": source ?: @"none",
                                   @"state": state ?: @"lookup failed"} mutableCopy];
    if (isrc.length) body[@"isrc"] = [isrc uppercaseString];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if (request.HTTPBody) [[[NSURLSession sharedSession] dataTaskWithRequest:request] resume];
}

// MAMusicHapticsManager — MediaAccessibility (iOS 18+)
// System drives haptic playback automatically via ISRC lookup on Apple servers.
// We supply the ISRC by querying MusicBrainz on each song change, while our
// own CoreHaptics engine provides real-time syllable and beat haptics.
@interface MAMusicHapticsManager : NSObject
+ (instancetype)sharedManager;
@property (nonatomic, readonly) BOOL isActive;
- (void)checkHapticTrackAvailabilityForMedia:(NSString *)isrc
                           completionHandler:(void(^)(BOOL available))handler;
@end

// ---- Preference helpers ----
static BOOL YTMU(NSString *key) {
    NSDictionary *dict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    // Default musicHaptics to YES if not set yet
    if (dict && dict[key] != nil) {
        return [dict[key] boolValue];
    }
    if ([key isEqualToString:@"musicHaptics"]) return YES;
    return NO;
}
static NSInteger YTMUInt(NSString *key, NSInteger dflt) {
    NSDictionary *dict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    id val = dict[key];
    return val ? [val integerValue] : dflt;
}

static NSString *YTMUNormalizedMusicText(NSString *value) {
    NSString *lower = [[value lowercaseString] stringByFoldingWithOptions:NSDiacriticInsensitiveSearch
                                                                    locale:[NSLocale currentLocale]];
    NSArray *parts = [lower componentsSeparatedByCharactersInSet:
                      [[NSCharacterSet alphanumericCharacterSet] invertedSet]];
    return [[parts filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]]
            componentsJoinedByString:@" "];
}

static NSString *YTMUArtistCredit(NSDictionary *recording) {
    NSMutableArray *names = [NSMutableArray array];
    for (id entry in [recording[@"artist-credit"] isKindOfClass:[NSArray class]] ? recording[@"artist-credit"] : @[]) {
        if ([entry isKindOfClass:[NSDictionary class]]) {
            NSString *name = entry[@"name"];
            NSDictionary *artist = [entry[@"artist"] isKindOfClass:[NSDictionary class]] ? entry[@"artist"] : nil;
            if (!name.length) name = artist[@"name"];
            if (name.length) [names addObject:name];
        }
    }
    return [names componentsJoinedByString:@" "];
}

// ---- Manager ----
@interface YTMUMusicHapticsManager : NSObject
@property (nonatomic, strong) CHHapticEngine *engine;
@property (nonatomic, assign) BOOL isEngineRunning;
@property (nonatomic, copy)   NSString *currentISRC;
@property (nonatomic, copy)   NSString *lastISRCTrackKey;
@property (nonatomic, copy)   NSString *currentTitle;
@property (nonatomic, copy)   NSString *currentArtist;
@property (nonatomic, copy)   NSString *currentVideoID;
@property (nonatomic, copy)   NSString *isrcSource;
@property (nonatomic, copy)   NSString *isrcLookupState;
@property (nonatomic, assign) NSTimeInterval lastTriggerTime;
@property (nonatomic, assign) BOOL systemHasTrackForCurrentSong;
@property (nonatomic, copy)   NSString *lastQueriedKey;
@property (nonatomic, copy)   NSString *currentLookupKey;
@property (nonatomic, strong) NSMutableDictionary *isrcCache;
@property (nonatomic, assign) BOOL lookupInFlight;
@property (nonatomic, copy) NSDictionary *pendingISRCRequest;
@property (nonatomic, strong) NSTimer *audioHapticsTimer;
@property (nonatomic, assign) uint32_t lastAudioOnsetSequence;
@property (nonatomic, assign) BOOL audioTapReadable;
+ (instancetype)sharedInstance;
- (BOOL)isSystemMusicHapticsActive;
- (void)triggerSyllableHapticWithDuration:(NSTimeInterval)duration;
- (void)triggerBeatHaptic;
- (void)updateISRC:(NSString *)isrc;
- (void)lookupISRCForTitle:(NSString *)title artist:(NSString *)artist videoID:(NSString *)videoID;
- (void)scheduleISRCLookupForTitle:(NSString *)title artist:(NSString *)artist videoID:(NSString *)videoID;
- (void)lookupMusicBrainzForTitle:(NSString *)title artist:(NSString *)artist key:(NSString *)key;
- (BOOL)shouldUseNativeMusicHaptics;
- (void)setupAudioHapticsMonitor;
- (void)audioHapticsMonitorTick;
- (void)triggerAudioTransientWithPeak:(float)peak;
- (void)completeISRCRequest;
- (void)playTransientWithIntensity:(float)intensity sharpness:(float)sharpness;
@end

@implementation YTMUMusicHapticsManager

+ (instancetype)sharedInstance {
    static YTMUMusicHapticsManager *s = nil;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [[self alloc] init]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lastTriggerTime = 0.0;
        _systemHasTrackForCurrentSong = NO;
        _lookupInFlight = NO;
        _isrcCache = [NSMutableDictionary dictionary];
        [self setupCoreHaptics];
        [self observeSystemHaptics];
        dispatch_async(dispatch_get_main_queue(), ^{ [self setupAudioHapticsMonitor]; });
    }
    return self;
}

// ---- CoreHaptics setup ----
- (void)setupCoreHaptics {
    if (![CHHapticEngine capabilitiesForHardware].supportsHaptics) {
        NSLog(@"[YTMU-Haptics] Device hardware does not support CoreHaptics");
        return;
    }
    NSError *err = nil;
    self.engine = [[CHHapticEngine alloc] initAndReturnError:&err];
    if (err || !self.engine) {
        NSLog(@"[YTMU-Haptics] Failed to init CHHapticEngine: %@", err);
        self.engine = nil;
        return;
    }
    __weak typeof(self) ws = self;
    self.engine.resetHandler = ^{
        NSLog(@"[YTMU-Haptics] CHHapticEngine reset handler triggered");
        [ws startEngineIfNeeded];
    };
    self.engine.stoppedHandler = ^(CHHapticEngineStoppedReason r) {
        NSLog(@"[YTMU-Haptics] CHHapticEngine stopped (reason %ld)", (long)r);
        __strong typeof(ws) s = ws;
        if (s) s.isEngineRunning = NO;
    };
}

- (void)startEngineIfNeeded {
    if (!self.engine || self.isEngineRunning) return;
    NSError *err = nil;
    [self.engine startAndReturnError:&err];
    self.isEngineRunning = (err == nil);
    if (err) {
        NSLog(@"[YTMU-Haptics] CHHapticEngine start failed: %@", err);
    } else {
        NSLog(@"[YTMU-Haptics] CHHapticEngine started successfully");
    }
}

// ---- System Music Haptics observation ----
- (void)observeSystemHaptics {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(systemHapticsStatusChanged:)
                                                 name:@"MAMusicHapticsManagerActiveStatusDidChangeNotification"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidBecomeActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
}

- (void)systemHapticsStatusChanged:(NSNotification *)note {
    NSLog(@"[YTMU-Haptics] System Music Haptics active status changed: active=%d", [self isSystemMusicHapticsActive]);
}

- (void)appDidBecomeActive:(NSNotification *)note {
    if (self.currentISRC.length) {
        [self checkSystemTrackAvailabilityForISRC:self.currentISRC];
    }
}

- (BOOL)isSystemMusicHapticsActive {
    Class cls = NSClassFromString(@"MAMusicHapticsManager");
    if (!cls) return NO;
    @try {
        id mgr = [cls performSelector:@selector(sharedManager)];
        if ([mgr respondsToSelector:@selector(isActive)]) {
            NSNumber *v = [mgr valueForKey:@"isActive"];
            return [v boolValue];
        }
    } @catch (__unused NSException *e) {}
    return NO;
}

- (void)completeISRCRequest {
    self.lookupInFlight = NO;
    NSDictionary *pending = self.pendingISRCRequest;
    if (!pending) return;
    if (![self.currentLookupKey isEqualToString:pending[@"key"]]) {
        self.pendingISRCRequest = nil;
        return;
    }
    self.pendingISRCRequest = nil;
    NSString *title = pending[@"title"];
    NSString *artist = pending[@"artist"];
    NSString *videoID = pending[@"videoID"];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self lookupISRCForTitle:title artist:artist videoID:videoID];
    });
}

- (void)checkSystemTrackAvailabilityForISRC:(NSString *)isrc {
    if (!isrc.length) { self.systemHasTrackForCurrentSong = NO; return; }
    Class cls = NSClassFromString(@"MAMusicHapticsManager");
    if (!cls) { self.systemHasTrackForCurrentSong = NO; return; }
    @try {
        id mgr = [cls performSelector:@selector(sharedManager)];
        SEL sel = NSSelectorFromString(@"checkHapticTrackAvailabilityForMedia:completionHandler:");
        if ([mgr respondsToSelector:sel]) {
            __weak typeof(self) ws = self;
            void (^cb)(BOOL) = ^(BOOL avail) {
                __strong typeof(ws) s = ws;
                if (s) {
                    s.systemHasTrackForCurrentSong = avail;
                    NSLog(@"[YTMU-Haptics] checkHapticTrackAvailability for %@: %d", isrc, avail);
                }
            };
            NSMethodSignature *sig = [mgr methodSignatureForSelector:sel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:mgr];
            [inv setSelector:sel];
            [inv setArgument:&isrc atIndex:2];
            [inv setArgument:&cb atIndex:3];
            [inv invoke];
        }
    } @catch (__unused NSException *e) {
        self.systemHasTrackForCurrentSong = NO;
    }
}

// ---- Playgeet first, server-cached by video ID, then MusicBrainz ----
// setNowPlayingInfo can fire during a song change with the NEW title while the
// player still reports the PREVIOUS song's video id (YTMUResolveCurrentVideoID
// lags the now-playing dict by about a second on every transition -- the
// 2026-11-16 capture shows each song's first report under the previous vid).
// A lookup started on that pair asks the server about the wrong video id, and
// the server's video-id cache answers with the previous song's ISRC, which the
// device then attaches to this song. Debounce instead: fire the lookup a
// second later and re-read the manager's CURRENT title/artist/vid, which the
// corrected setNowPlayingInfo call has settled by then.
- (void)scheduleISRCLookupForTitle:(NSString *)title artist:(NSString *)artist videoID:(NSString *)videoID {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.currentTitle = title;
        self.currentArtist = artist;
        self.currentVideoID = videoID ?: @"";
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSString *t = self.currentTitle;
            NSString *a = self.currentArtist;
            NSString *v = self.currentVideoID;
            if (!t.length || !a.length) return;
            [self lookupISRCForTitle:t artist:a videoID:v];
        });
    });
}

- (void)lookupISRCForTitle:(NSString *)title artist:(NSString *)artist videoID:(NSString *)videoID {
    if (!title.length || !artist.length) return;

    self.currentTitle = title;
    self.currentArtist = artist;
    self.currentVideoID = videoID ?: @"";

    // Bump local lookup cache so prior provider misses do not suppress the
    // new Playgeet-first lookup.
    NSString *key = YTMUISRCTrackKey(title, artist, videoID);
    self.currentLookupKey = key;

    if ([key isEqualToString:self.lastQueriedKey]) return;

    NSString *cached = self.isrcCache[key];
    if (cached) {
        self.lastQueriedKey = key;
        self.isrcSource = @"ISRC cache";
        self.isrcLookupState = cached.length ? @"Resolved from cache" : @"No ISRC in cache";
        [self updateISRC:cached];
        YTMULogISRC([NSString stringWithFormat:@"ISRC cache %@ for %@", cached.length ? @"hit" : @"miss", videoID.length ? videoID : key]);
        YTMUReportISRCStatus(videoID, title, artist, @"playgeet cache",
                             cached.length ? @"resolved" : @"no ISRC found", cached);
        return;
    }

    if ([self.isrcCache objectForKey:key] != nil) {
        self.isrcSource = @"ISRC cache";
        self.isrcLookupState = @"No ISRC in cache";
        YTMUReportISRCStatus(videoID, title, artist, @"playgeet cache", @"no ISRC found", nil);
        return; // previous miss
    }

    if (self.lookupInFlight) {
        self.isrcLookupState = @"Waiting for previous lookup";
        YTMULogISRC([NSString stringWithFormat:@"Skipped %@; another lookup is still running", videoID.length ? videoID : key]);
        self.pendingISRCRequest = @{@"title": [title copy], @"artist": [artist copy],
                                   @"videoID": [videoID copy] ?: @"", @"key": key};
        YTMUReportISRCStatus(videoID, title, artist,
                             videoID.length == 11 ? @"playgeet" : @"musicbrainz",
                             @"waiting for previous lookup", nil);
        return;
    }
    self.lastQueriedKey = key;
    self.currentLookupKey = key;
    self.lookupInFlight = YES;

    self.systemHasTrackForCurrentSong = NO;
    self.currentISRC = nil;
    self.isrcSource = videoID.length == 11 ? @"Playgeet → Soundcharts → MusicBrainz" : @"MusicBrainz";
    self.isrcLookupState = videoID.length == 11 ? @"Looking up Playgeet" : @"Looking up MusicBrainz (no video ID)";
    YTMULogISRC([NSString stringWithFormat:@"Lookup started videoID=%@ source=%@",
                 videoID.length ? videoID : @"(none)", self.isrcSource]);
    YTMUReportISRCStatus(videoID, title, artist,
                         videoID.length == 11 ? @"soundcharts" : @"musicbrainz",
                         videoID.length == 11 ? @"client lookup started" : @"looking up MusicBrainz", nil);

    if (videoID.length == 11) {
        NSString *urlString = [NSString stringWithFormat:@"%@/api/isrc/lookup", YTMUApiBase()];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]
                                                               cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                           timeoutInterval:5.0];
        request.HTTPMethod = @"POST";
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        NSError *bodyError = nil;
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"video_id": videoID,
                                                                      @"title": title ?: @"",
                                                                      @"artist": artist ?: @""}
                                                           options:0 error:&bodyError];
        if (bodyError || !request.HTTPBody) {
            self.lookupInFlight = NO;
            self.isrcLookupState = @"Could not create ISRC lookup; trying MusicBrainz";
            YTMULogISRC([NSString stringWithFormat:@"ISRC request serialization failed (%@)", bodyError.localizedDescription ?: @"unknown error"]);
            [self lookupMusicBrainzForTitle:title artist:artist key:key];
            return;
        }
        self.isrcLookupState = @"Looking up Playgeet (Soundcharts fallback)";
        __weak typeof(self) weakSelf = self;
        [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSString *isrc = [json[@"isrc"] isKindOfClass:[NSString class]] ? [json[@"isrc"] uppercaseString] : nil;
            if (isrc.length != 12) isrc = nil;
            if (isrc.length) {
                NSString *source = [json[@"source"] isKindOfClass:[NSString class]] ? json[@"source"] : @"unknown";
                YTMULogISRC([NSString stringWithFormat:@"%@ resolved videoID=%@ ISRC=%@", source, videoID, isrc]);
                dispatch_async(dispatch_get_main_queue(), ^{
                    // The video id that started this lookup can be stale: during
                    // a song change the now-playing dict names the new track
                    // while the player still reports the previous vid, and the
                    // server's cache is keyed by video id -- such a request
                    // answers with the PREVIOUS song's ISRC. Only cache and
                    // attach when the player still names the video this
                    // lookup asked about.
                    NSString *vidNow = YTMUResolveCurrentVideoID() ?: @"";
                    BOOL vidStillCurrent = videoID.length != 11 || [vidNow isEqualToString:videoID];
                    if (vidStillCurrent) strongSelf.isrcCache[key] = isrc;
                    if (vidStillCurrent && [strongSelf.currentLookupKey isEqualToString:key]) {
                        strongSelf.isrcSource = source;
                        strongSelf.isrcLookupState = @"Resolved";
                        YTMUReportISRCStatus(videoID, title, artist, [source containsString:@"playgeet"] ? @"playgeet" : @"soundcharts", @"resolved", isrc);
                        [strongSelf updateISRC:isrc];
                    }
                });
                [strongSelf completeISRCRequest];
                return;
            }
            NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
            YTMULogISRC([NSString stringWithFormat:@"Playgeet/Soundcharts returned no ISRC (HTTP %ld, %@); falling back to MusicBrainz",
                         (long)status, error.localizedDescription ?: @"no transport error"]);
            if ([strongSelf.currentLookupKey isEqualToString:key]) {
                strongSelf.isrcLookupState = error ? @"ISRC lookup failed; trying MusicBrainz" : @"No ISRC from Playgeet/Soundcharts; trying MusicBrainz";
                YTMUReportISRCStatus(videoID, title, artist, @"playgeet", @"waiting for Playgeet", nil);
                [strongSelf lookupMusicBrainzForTitle:title artist:artist key:key];
            } else {
                [strongSelf completeISRCRequest];
            }
        }] resume];
        return;
    }

    [self lookupMusicBrainzForTitle:title artist:artist key:key];
}

- (void)lookupMusicBrainzForTitle:(NSString *)title artist:(NSString *)artist key:(NSString *)key {
    // Artist strings from YouTube Music frequently combine featured artists
    // differently from MusicBrainz (e.g. "X, Y" vs "X feat. Y"). Search by
    // exact recording title, then rank candidates against every credited artist.
    NSString *safeTitle = [[title stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
                           stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    NSString *requestTitle = [title copy] ?: @"";
    NSString *requestArtist = [artist copy] ?: @"";
    NSString *requestVideoID = [self.currentVideoID copy] ?: @"";
    NSString *requestKey = [key copy] ?: @"";
    BOOL requestIsCurrent = [self.currentLookupKey isEqualToString:requestKey];
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://musicbrainz.org/ws/2/recording/"];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"query" value:[NSString stringWithFormat:@"recording:\"%@\"", safeTitle]],
        [NSURLQueryItem queryItemWithName:@"inc" value:@"isrcs"],
        [NSURLQueryItem queryItemWithName:@"limit" value:@"25"],
        [NSURLQueryItem queryItemWithName:@"fmt" value:@"json"]
    ];
    NSURL *url = components.URL;

    if (requestIsCurrent) {
        self.isrcSource = @"MusicBrainz";
        self.isrcLookupState = @"Looking up MusicBrainz";
        YTMUReportISRCStatus(requestVideoID, requestTitle, requestArtist,
                             @"musicbrainz", @"looking up MusicBrainz", nil);
    }
    YTMULogISRC([NSString stringWithFormat:@"Trying MusicBrainz videoID=%@",
                 requestVideoID.length ? requestVideoID : @"(none)"]);

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReturnCacheDataElseLoad
                                                   timeoutInterval:8.0];
    [req setValue:@"YTMusicUltimate/1.0 (ct@chiuhuang.dev)" forHTTPHeaderField:@"User-Agent"];

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    __weak typeof(self) ws = self;
    NSURLSessionDataTask *task = [session dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            __strong typeof(ws) s = ws;
            if (!s) return;

            if (err || !data) {
                NSLog(@"[YTMU-Haptics] MusicBrainz query failed: %@", err);
                if ([s.currentLookupKey isEqualToString:requestKey]) {
                    s.isrcLookupState = [NSString stringWithFormat:@"MusicBrainz request failed: %@", err.localizedDescription ?: @"no response"];
                    YTMULogISRC(s.isrcLookupState);
                    YTMUReportISRCStatus(requestVideoID, requestTitle, requestArtist, @"error", @"lookup failed", nil);
                }
                [s completeISRCRequest];
                return;
            }

            NSError *jsonErr = nil;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                                 options:0
                                                                   error:&jsonErr];
            if (jsonErr || !json) {
                NSLog(@"[YTMU-Haptics] MusicBrainz JSON parse failed: %@", jsonErr);
                if ([s.currentLookupKey isEqualToString:requestKey]) {
                    s.isrcLookupState = [NSString stringWithFormat:@"MusicBrainz response parse failed: %@", jsonErr.localizedDescription ?: @"invalid JSON"];
                    YTMULogISRC(s.isrcLookupState);
                    YTMUReportISRCStatus(requestVideoID, requestTitle, requestArtist, @"error", @"lookup failed", nil);
                }
                [s completeISRCRequest];
                return;
            }

            NSArray *recordings = [json[@"recordings"] isKindOfClass:[NSArray class]] ? json[@"recordings"] : @[];
            NSString *wantedTitle = YTMUNormalizedMusicText(requestTitle);
            NSString *wantedArtist = YTMUNormalizedMusicText(requestArtist);
            NSString *foundISRC = nil;
            NSInteger bestScore = NSIntegerMin;
            for (NSDictionary *rec in recordings) {
                NSArray *isrcs = [rec[@"isrcs"] isKindOfClass:[NSArray class]] ? rec[@"isrcs"] : @[];
                if (!isrcs.count) continue;
                NSString *candidateTitle = YTMUNormalizedMusicText([rec[@"title"] isKindOfClass:[NSString class]] ? rec[@"title"] : @"");
                NSString *candidateArtist = YTMUNormalizedMusicText(YTMUArtistCredit(rec) ?: @"");
                if (!candidateTitle.length || !wantedTitle.length) continue;
                NSInteger score = [candidateTitle isEqualToString:wantedTitle] ? 100 :
                                  ([candidateTitle containsString:wantedTitle] || [wantedTitle containsString:candidateTitle] ? 40 : 0);
                BOOL artistMatch = NO;
                if ([candidateArtist isEqualToString:wantedArtist]) { score += 80; artistMatch = YES; }
                else if (wantedArtist.length && ([candidateArtist containsString:wantedArtist] || [wantedArtist containsString:candidateArtist])) { score += 50; artistMatch = YES; }
                else {
                    for (NSString *part in [wantedArtist componentsSeparatedByString:@" "]) {
                        if (part.length > 2 && [candidateArtist containsString:part]) { score += 8; artistMatch = YES; }
                    }
                }
                if (!artistMatch) continue;
                score += [rec[@"score"] integerValue] / 10;
                if (score > bestScore) {
                    bestScore = score;
                    foundISRC = [isrcs.firstObject isKindOfClass:[NSString class]] ? isrcs.firstObject : nil;
                }
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                // Same stale-vid guard as the Playgeet path: a lookup that
                // started under the PREVIOUS song's video id (the now-playing
                // dict leads the player's reported vid by about a second on a
                // song change) must not cache or attach anything.
                NSString *vidNow = YTMUResolveCurrentVideoID() ?: @"";
                BOOL vidStillCurrent = requestVideoID.length != 11 || [vidNow isEqualToString:requestVideoID];
                if (vidStillCurrent) s.isrcCache[requestKey] = foundISRC ?: @"";
                BOOL resultStillCurrent = [s.currentLookupKey isEqualToString:requestKey];
                if (resultStillCurrent) {
                    s.isrcSource = @"MusicBrainz";
                    s.isrcLookupState = foundISRC.length ? @"Resolved" : @"No ISRC found";
                    YTMULogISRC([NSString stringWithFormat:@"MusicBrainz result videoID=%@ ISRC=%@",
                                 requestVideoID.length ? requestVideoID : @"(none)", foundISRC ?: @"(none)"]);
                    YTMUReportISRCStatus(requestVideoID, requestTitle, requestArtist, @"musicbrainz",
                                         foundISRC.length ? @"resolved" : @"no ISRC found", foundISRC);
                }

                if (foundISRC.length && vidStillCurrent && resultStillCurrent) {
                    [s updateISRC:foundISRC];
                }
                [s completeISRCRequest];
            });
        }];
    [task resume];
}

// ---- ISRC injection ----
- (void)updateISRC:(NSString *)isrc {
    if ([isrc isEqualToString:self.currentISRC]) return;
    self.currentISRC = isrc;
    self.lastISRCTrackKey = self.currentLookupKey;
    self.systemHasTrackForCurrentSong = NO;

    if (!isrc.length) return;

    NSLog(@"[YTMU-Haptics] Updating NowPlayingInfo with ISRC: %@", isrc);
    // A lookup that started under the previous song's key can still be in
    // flight when the now-playing dict moves on. Re-verify at fire time that
    // this ISRC still belongs to the track being published -- the system
    // now-playing dict is what the lock screen reads, and a stale write is
    // how the previous song's ISRC ends up on it.
    NSString *keyAtResolve = [self.currentLookupKey copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (keyAtResolve.length && ![self.currentLookupKey isEqualToString:keyAtResolve]) return;
        MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
        NSDictionary *now = center.nowPlayingInfo;
        if (now) {
            NSMutableDictionary *mut = [now mutableCopy];
            mut[@"MPNowPlayingInfoPropertyInternationalStandardRecordingCode"] = isrc;
            center.nowPlayingInfo = mut;
        }
    });

    [self checkSystemTrackAvailabilityForISRC:isrc];
}

- (BOOL)shouldUseNativeMusicHaptics {
    // Defer only when iOS confirms an exact native haptic track for this ISRC.
    // Merely having Music Haptics enabled must never silence our fallback.
    return self.currentISRC.length > 0 && self.systemHasTrackForCurrentSong &&
           [self isSystemMusicHapticsActive];
}

- (void)setupAudioHapticsMonitor {
    if (self.audioHapticsTimer) return;
    self.lastAudioOnsetSequence = atomic_load_explicit(&YTMUAudioOnsetSequence, memory_order_relaxed);
    __weak typeof(self) weakSelf = self;
    self.audioHapticsTimer = [NSTimer timerWithTimeInterval:0.025 repeats:YES block:^(__unused NSTimer *timer) {
        [weakSelf audioHapticsMonitorTick];
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.audioHapticsTimer forMode:NSRunLoopCommonModes];
}

- (void)audioHapticsMonitorTick {
    BOOL shouldCapture = self.currentTitle.length > 0 && YTMU(@"musicHaptics");
    if (!shouldCapture) {
        self.audioTapReadable = NO;
        self.lastAudioOnsetSequence = atomic_load_explicit(&YTMUAudioOnsetSequence, memory_order_relaxed);
        return;
    }

    uint64_t lastHostTime = atomic_load_explicit(&YTMUAudioLastHostTime, memory_order_acquire);
    uint64_t now = YTMUHostTimeNow();
    self.audioTapReadable = lastHostTime && now >= lastHostTime &&
        YTMUHostTicksToNanos(now - lastHostTime) < 1500000000ULL;
    if (!self.audioTapReadable) return;

    uint32_t sequence = atomic_load_explicit(&YTMUAudioOnsetSequence, memory_order_relaxed);
    if (sequence == self.lastAudioOnsetSequence) return;
    self.lastAudioOnsetSequence = sequence;
    if ([self shouldUseNativeMusicHaptics]) return;
    float peak = YTMUFloatFromBits(atomic_load_explicit(&YTMUAudioPeakBits, memory_order_relaxed));
    [self triggerAudioTransientWithPeak:peak];
}

- (void)triggerAudioTransientWithPeak:(float)peak {
    if (!YTMU(@"musicHaptics") || [self shouldUseNativeMusicHaptics]) return;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - self.lastTriggerTime < 0.105) return;
    self.lastTriggerTime = now;

    NSInteger intensity = YTMUInt(@"musicHapticsIntensity", 1);
    float base = intensity == 0 ? 0.40f : (intensity == 2 ? 1.0f : 0.65f);
    float sharpness = intensity == 0 ? 0.45f : (intensity == 2 ? 1.0f : 0.65f);
    float energyScale = MIN(1.0f, MAX(0.72f, peak * 1.65f));
    // Preserve the user's strongest setting at full actuator intensity;
    // energy scaling only softens the Light and Medium profiles.
    float finalIntensity = intensity == 2 ? 1.0f : MIN(1.0f, base * energyScale);
    [self playTransientWithIntensity:finalIntensity sharpness:sharpness];
}

// ---- Haptic triggers ----
- (void)triggerSyllableHapticWithDuration:(NSTimeInterval)duration {
    if (!YTMU(@"musicHaptics")) return;
    if ([self shouldUseNativeMusicHaptics]) return;
    // Lyric timing remains the fallback only when no live player PCM reaches
    // A live audio tap may own cues when the platform provides one safely.
    if (self.audioTapReadable) return;

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - self.lastTriggerTime < 0.070) return;
    self.lastTriggerTime = now;

    NSInteger intensity = YTMUInt(@"musicHapticsIntensity", 1);
    float fi = (intensity == 0) ? 0.40f : ((intensity == 2) ? 1.00f : 0.55f);
    float fs = (intensity == 0) ? 0.45f : ((intensity == 2) ? 1.00f : 0.60f);
    if (duration > 0.4) fi = MIN(1.0f, fi + 0.15f);

    NSLog(@"[YTMU-Haptics] Trigger syllable haptic (dur=%.2f, intensity=%.2f)", duration, fi);
    [self playTransientWithIntensity:fi sharpness:fs];
}

- (void)triggerBeatHaptic {
    if (!YTMU(@"musicHaptics")) return;
    if ([self shouldUseNativeMusicHaptics]) return;
    if (self.audioTapReadable) return;

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - self.lastTriggerTime < 0.100) return;
    self.lastTriggerTime = now;

    NSInteger intensity = YTMUInt(@"musicHapticsIntensity", 1);
    float fi = (intensity == 0) ? 0.45f : ((intensity == 2) ? 1.00f : 0.65f);
    float fs = (intensity == 0) ? 0.50f : ((intensity == 2) ? 1.00f : 0.65f);

    NSLog(@"[YTMU-Haptics] Trigger beat haptic (intensity=%.2f)", fi);
    [self playTransientWithIntensity:fi sharpness:fs];
}

- (void)playTransientWithIntensity:(float)intensity sharpness:(float)sharpness {
    [self startEngineIfNeeded];
    if (self.engine && self.isEngineRunning) {
        NSDictionary *hapticDict = @{
            CHHapticPatternKeyPattern: @[
                @{
                    CHHapticPatternKeyEvent: @{
                        CHHapticPatternKeyEventType:      CHHapticEventTypeHapticTransient,
                        CHHapticPatternKeyTime:            @(0.0),
                        CHHapticPatternKeyEventDuration:   @(intensity >= 0.95f ? 0.08 : 0.04),
                        CHHapticPatternKeyEventParameters: @[
                            @{ CHHapticPatternKeyParameterID:    CHHapticEventParameterIDHapticIntensity,
                               CHHapticPatternKeyParameterValue: @(intensity) },
                            @{ CHHapticPatternKeyParameterID:    CHHapticEventParameterIDHapticSharpness,
                               CHHapticPatternKeyParameterValue: @(sharpness) }
                        ]
                    }
                }
            ]
        };
        NSError *err = nil;
        CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithDictionary:hapticDict error:&err];
        if (pattern && !err) {
            id<CHHapticPatternPlayer> player = [self.engine createPlayerWithPattern:pattern error:nil];
            [player startAtTime:CHHapticTimeImmediate error:nil];
            return;
        }
    }
    // UIKit fallback
    UIImpactFeedbackStyle style = (intensity > 0.75f) ? UIImpactFeedbackStyleHeavy
                                : (intensity > 0.50f) ? UIImpactFeedbackStyleMedium
                                                      : UIImpactFeedbackStyleLight;
    UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:style];
    [gen prepare];
    [gen impactOccurred];
}

@end

// ---- Public functions ----
void YTMUTriggerSyllableHaptic(double durationSec) {
    [[YTMUMusicHapticsManager sharedInstance] triggerSyllableHapticWithDuration:durationSec];
}
void YTMUTriggerBeatHaptic(void) {
    [[YTMUMusicHapticsManager sharedInstance] triggerBeatHaptic];
}
void YTMUUpdateNowPlayingISRC(NSString *isrc) {
    [[YTMUMusicHapticsManager sharedInstance] updateISRC:isrc];
}
BOOL YTMUIsSystemMusicHapticsActive(void) {
    return [[YTMUMusicHapticsManager sharedInstance] isSystemMusicHapticsActive];
}
NSString *YTMUCurrentNowPlayingISRC(void) {
    return [YTMUMusicHapticsManager sharedInstance].currentISRC;
}
NSString *YTMUCurrentNowPlayingTitle(void) {
    return [YTMUMusicHapticsManager sharedInstance].currentTitle;
}
NSString *YTMUCurrentNowPlayingArtist(void) {
    return [YTMUMusicHapticsManager sharedInstance].currentArtist;
}
void YTMUTestHapticPulse(NSInteger intensity) {
    float fi = (intensity == 0) ? 0.40f : ((intensity == 2) ? 1.00f : 0.65f);
    float fs = (intensity == 0) ? 0.45f : ((intensity == 2) ? 1.00f : 0.65f);
    [[YTMUMusicHapticsManager sharedInstance] playTransientWithIntensity:fi sharpness:fs];
}

// ---- Hook: intercept every setNowPlayingInfo: call ----
%hook MPNowPlayingInfoCenter
- (void)setNowPlayingInfo:(NSDictionary *)nowPlayingInfo {
    if (!nowPlayingInfo) {
        %orig(nil);
        return;
    }

    NSString *title  = nowPlayingInfo[@"title"]  ?: nowPlayingInfo[@"MPMediaItemPropertyTitle"];
    NSString *artist = nowPlayingInfo[@"artist"] ?: nowPlayingInfo[@"MPMediaItemPropertyArtist"];
    NSString *videoID = YTMUResolveCurrentVideoID();
    NSString *existing = nowPlayingInfo[@"MPNowPlayingInfoPropertyInternationalStandardRecordingCode"];
    NSDictionary *infoToSend = nowPlayingInfo;
    __block NSString *trackKey = nil;

    if (title.length && artist.length) {
        YTMUMusicHapticsManager *mgr = [YTMUMusicHapticsManager sharedInstance];
        trackKey = YTMUISRCTrackKey(title, artist, videoID);
        BOOL audioTrackChanged = ![mgr.currentTitle isEqualToString:title] || ![mgr.currentArtist isEqualToString:artist];
        BOOL playbackISRCChanged = ![mgr.lastISRCTrackKey isEqualToString:trackKey] || ![mgr.currentISRC isEqualToString:existing];
        if (audioTrackChanged) {
            mgr.audioTapReadable = NO;
            mgr.lastAudioOnsetSequence = atomic_load_explicit(&YTMUAudioOnsetSequence, memory_order_relaxed);
        }
        mgr.currentLookupKey = trackKey;
        if (existing.length && mgr.lastISRCTrackKey.length &&
            ![mgr.lastISRCTrackKey isEqualToString:trackKey] &&
            [existing isEqualToString:mgr.currentISRC]) {
            // The prior song's ISRC can survive if the player copies its info dictionary.
            existing = nil;
            NSMutableDictionary *clean = [nowPlayingInfo mutableCopy];
            [clean removeObjectForKey:@"MPNowPlayingInfoPropertyInternationalStandardRecordingCode"];
            infoToSend = clean;
        }
        if (mgr.lastQueriedKey.length && ![mgr.lastQueriedKey isEqualToString:trackKey]) {
            // Never attach the previous song's ISRC while this track is being resolved.
            mgr.currentISRC = nil;
            mgr.systemHasTrackForCurrentSong = NO;
        }
        mgr.currentTitle = title;
        mgr.currentArtist = artist;
        mgr.currentVideoID = videoID ?: @"";
        if (existing.length) {
            // Prefer an ISRC if the playback service supplied one; otherwise
            // resolve by YouTube ID via the server and then MusicBrainz.
            mgr.lastQueriedKey = trackKey;
            mgr.pendingISRCRequest = nil;
            mgr.isrcSource = @"Playback metadata";
            mgr.isrcLookupState = @"Playback ISRC available";
            [mgr updateISRC:existing];
            mgr.lastISRCTrackKey = trackKey;
            if (playbackISRCChanged) {
                YTMULogISRC([NSString stringWithFormat:@"Playback supplied ISRC videoID=%@ ISRC=%@",
                             videoID.length ? videoID : @"(none)", existing]);
                YTMUReportISRCStatus(videoID, title, artist, @"playback", @"playback ISRC available", existing);
            }
        } else {
            [mgr scheduleISRCLookupForTitle:title artist:artist videoID:videoID];
        }
    }

    YTMUMusicHapticsManager *isrcMgr = [YTMUMusicHapticsManager sharedInstance];
    NSString *isrc = isrcMgr.currentISRC;

    // Inject our own resolved ISRC only while it belongs to the track this
    // call publishes. lastISRCTrackKey names the track the last ISRC was
    // injected FOR and is deliberately NOT reset when currentISRC is cleared
    // above on a song change -- it still names the previous song there, which
    // is what keeps a residual currentISRC out of the system now-playing dict
    // until the new track's lookup resolves and updateISRC re-stamps it.
    if (isrc.length && trackKey.length && [isrcMgr.lastISRCTrackKey isEqualToString:trackKey] && !existing.length) {
        NSMutableDictionary *mut = [infoToSend mutableCopy];
        mut[@"MPNowPlayingInfoPropertyInternationalStandardRecordingCode"] = isrc;
        %orig(mut);
        return;
    }

    if (existing.length) {
        [[YTMUMusicHapticsManager sharedInstance] updateISRC:existing];
    }

    %orig(infoToSend);
}
%end

%ctor {
    mach_timebase_info(&YTMUHostTimebase);
    %init;
}
