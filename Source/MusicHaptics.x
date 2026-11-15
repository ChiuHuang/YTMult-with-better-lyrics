#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreHaptics/CoreHaptics.h>
#import <MediaPlayer/MediaPlayer.h>
#import "LyricsShared.h"

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
@property (nonatomic, assign) NSTimeInterval lastTriggerTime;
@property (nonatomic, assign) BOOL systemHasTrackForCurrentSong;
@property (nonatomic, copy)   NSString *lastQueriedKey;
@property (nonatomic, copy)   NSString *currentLookupKey;
@property (nonatomic, strong) NSMutableDictionary *isrcCache;
@property (nonatomic, assign) BOOL lookupInFlight;
+ (instancetype)sharedInstance;
- (BOOL)isSystemMusicHapticsActive;
- (void)triggerSyllableHapticWithDuration:(NSTimeInterval)duration;
- (void)triggerBeatHaptic;
- (void)updateISRC:(NSString *)isrc;
- (void)lookupISRCForTitle:(NSString *)title artist:(NSString *)artist videoID:(NSString *)videoID;
- (void)lookupMusicBrainzForTitle:(NSString *)title artist:(NSString *)artist key:(NSString *)key;
- (BOOL)shouldUseNativeMusicHaptics;
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

// ---- Soundcharts first, then our independent MusicBrainz matcher ----
- (void)lookupISRCForTitle:(NSString *)title artist:(NSString *)artist videoID:(NSString *)videoID {
    if (!title.length || !artist.length) return;

    NSString *key = [NSString stringWithFormat:@"%@|%@|%@",
                     [title lowercaseString], [artist lowercaseString], videoID ?: @""];

    if ([key isEqualToString:self.lastQueriedKey]) return;

    NSString *cached = self.isrcCache[key];
    if (cached) {
        self.lastQueriedKey = key;
        [self updateISRC:cached];
        NSLog(@"[YTMU-Haptics] MusicBrainz ISRC cache hit for '%@': %@", key, cached);
        return;
    }

    if ([self.isrcCache objectForKey:key] != nil) return; // previous miss

    if (self.lookupInFlight) return;
    self.lastQueriedKey = key;
    self.currentLookupKey = key;
    self.lookupInFlight = YES;

    self.systemHasTrackForCurrentSong = NO;
    self.currentISRC = nil;

    if (videoID.length == 11) {
        NSString *urlString = [NSString stringWithFormat:@"%@/api/isrc/lookup", YTMUApiBase()];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]
                                                               cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                           timeoutInterval:5.0];
        request.HTTPMethod = @"POST";
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        NSError *bodyError = nil;
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"video_id": videoID}
                                                           options:0 error:&bodyError];
        if (bodyError || !request.HTTPBody) {
            self.lookupInFlight = NO;
            [self lookupMusicBrainzForTitle:title artist:artist key:key];
            return;
        }
        NSLog(@"[YTMU-Haptics] Looking up Soundcharts ISRC for YouTube video %@", videoID);
        __weak typeof(self) weakSelf = self;
        [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSString *isrc = [json[@"isrc"] isKindOfClass:[NSString class]] ? [json[@"isrc"] uppercaseString] : nil;
            if (isrc.length != 12) isrc = nil;
            if (isrc.length) {
                strongSelf.lookupInFlight = NO;
                strongSelf.isrcCache[key] = isrc;
                NSLog(@"[YTMU-Haptics] Soundcharts resolved ISRC %@ for %@", isrc, videoID);
                if ([strongSelf.currentLookupKey isEqualToString:key]) {
                    dispatch_async(dispatch_get_main_queue(), ^{ [strongSelf updateISRC:isrc]; });
                }
                return;
            }
            NSLog(@"[YTMU-Haptics] Soundcharts returned no ISRC; trying MusicBrainz (HTTP %@)",
                  response ? @(((NSHTTPURLResponse *)response).statusCode) : (error ? @"error" : @"no response"));
            [strongSelf lookupMusicBrainzForTitle:title artist:artist key:key];
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
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://musicbrainz.org/ws/2/recording/"];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"query" value:[NSString stringWithFormat:@"recording:\"%@\"", safeTitle]],
        [NSURLQueryItem queryItemWithName:@"inc" value:@"isrcs"],
        [NSURLQueryItem queryItemWithName:@"limit" value:@"25"],
        [NSURLQueryItem queryItemWithName:@"fmt" value:@"json"]
    ];
    NSURL *url = components.URL;

    NSLog(@"[YTMU-Haptics] Querying MusicBrainz for '%@' by '%@'", title, artist);
    sendDebugLog([NSString stringWithFormat:@"[Haptics] Querying MusicBrainz for '%@' - '%@'", title, artist]);

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

            s.lookupInFlight = NO;

            if (err || !data) {
                NSLog(@"[YTMU-Haptics] MusicBrainz query failed: %@", err);
                return;
            }

            NSError *jsonErr = nil;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                                 options:0
                                                                   error:&jsonErr];
            if (jsonErr || !json) {
                NSLog(@"[YTMU-Haptics] MusicBrainz JSON parse failed: %@", jsonErr);
                return;
            }

            NSArray *recordings = [json[@"recordings"] isKindOfClass:[NSArray class]] ? json[@"recordings"] : @[];
            NSString *wantedTitle = YTMUNormalizedMusicText(title);
            NSString *wantedArtist = YTMUNormalizedMusicText(artist);
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

            s.isrcCache[key] = foundISRC ?: @"";
            NSLog(@"[YTMU-Haptics] MusicBrainz result for '%@': ISRC=%@", key, foundISRC ?: @"(none)");
            sendDebugLog([NSString stringWithFormat:@"[Haptics] MusicBrainz ISRC result: %@", foundISRC ?: @"(none)"]);

            if (foundISRC.length && [s.currentLookupKey isEqualToString:key]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [s updateISRC:foundISRC];
                });
            }
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
    dispatch_async(dispatch_get_main_queue(), ^{
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

// ---- Haptic triggers ----
- (void)triggerSyllableHapticWithDuration:(NSTimeInterval)duration {
    if (!YTMU(@"musicHaptics")) return;
    if ([self shouldUseNativeMusicHaptics]) return;

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
    if (!nowPlayingInfo) { %orig(nil); return; }

    NSString *title  = nowPlayingInfo[@"title"]  ?: nowPlayingInfo[@"MPMediaItemPropertyTitle"];
    NSString *artist = nowPlayingInfo[@"artist"] ?: nowPlayingInfo[@"MPMediaItemPropertyArtist"];
    NSString *videoID = YTMUResolveCurrentVideoID();
    NSString *existing = nowPlayingInfo[@"MPNowPlayingInfoPropertyInternationalStandardRecordingCode"];
    NSDictionary *infoToSend = nowPlayingInfo;

    if (title.length && artist.length) {
        YTMUMusicHapticsManager *mgr = [YTMUMusicHapticsManager sharedInstance];
        NSString *trackKey = [NSString stringWithFormat:@"%@|%@|%@", [title lowercaseString], [artist lowercaseString], videoID ?: @""];
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
        if (existing.length) {
            // Prefer an ISRC if the playback service supplied one; otherwise
            // resolve by YouTube ID via the server and then MusicBrainz.
            mgr.lastQueriedKey = trackKey;
            [mgr updateISRC:existing];
        } else {
            [mgr lookupISRCForTitle:title artist:artist videoID:videoID];
        }
    }

    NSString *isrc = [YTMUMusicHapticsManager sharedInstance].currentISRC;

    if (isrc.length && !existing.length) {
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
