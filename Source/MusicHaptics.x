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

// ---- Manager ----
@interface YTMUMusicHapticsManager : NSObject
@property (nonatomic, strong) CHHapticEngine *engine;
@property (nonatomic, assign) BOOL isEngineRunning;
@property (nonatomic, copy)   NSString *currentISRC;
@property (nonatomic, copy)   NSString *currentTitle;
@property (nonatomic, copy)   NSString *currentArtist;
@property (nonatomic, assign) NSTimeInterval lastTriggerTime;
@property (nonatomic, assign) BOOL systemHasTrackForCurrentSong;
@property (nonatomic, copy)   NSString *lastQueriedKey;
@property (nonatomic, strong) NSMutableDictionary *isrcCache;
@property (nonatomic, assign) BOOL lookupInFlight;
+ (instancetype)sharedInstance;
- (BOOL)isSystemMusicHapticsActive;
- (void)triggerSyllableHapticWithDuration:(NSTimeInterval)duration;
- (void)triggerBeatHaptic;
- (void)updateISRC:(NSString *)isrc;
- (void)lookupISRCForTitle:(NSString *)title artist:(NSString *)artist;
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

// ---- MusicBrainz ISRC lookup ----
- (void)lookupISRCForTitle:(NSString *)title artist:(NSString *)artist {
    if (!title.length || !artist.length) return;

    NSString *key = [NSString stringWithFormat:@"%@|%@",
                     [title lowercaseString], [artist lowercaseString]];

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
    self.lookupInFlight = YES;

    self.systemHasTrackForCurrentSong = NO;
    self.currentISRC = nil;

    NSCharacterSet *allowed = [NSCharacterSet URLQueryAllowedCharacterSet];
    NSString *encTitle  = [title  stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    NSString *encArtist = [artist stringByAddingPercentEncodingWithAllowedCharacters:allowed];

    NSString *query = [NSString stringWithFormat:
        @"https://musicbrainz.org/ws/2/recording/?query=recording:%%22%@%%22+AND+artist:%%22%@%%22&inc=isrcs&limit=3&fmt=json",
        encTitle, encArtist];
    NSURL *url = [NSURL URLWithString:query];

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

            NSArray *recordings = json[@"recordings"];
            NSString *foundISRC = nil;

            for (NSDictionary *rec in recordings) {
                NSArray *isrcs = rec[@"isrcs"];
                if ([isrcs isKindOfClass:[NSArray class]] && isrcs.count > 0) {
                    foundISRC = isrcs[0];
                    break;
                }
            }

            s.isrcCache[key] = foundISRC ?: @"";
            NSLog(@"[YTMU-Haptics] MusicBrainz result for '%@': ISRC=%@", key, foundISRC ?: @"(none)");
            sendDebugLog([NSString stringWithFormat:@"[Haptics] MusicBrainz ISRC result: %@", foundISRC ?: @"(none)"]);

            if (foundISRC.length) {
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

// ---- Haptic triggers ----
- (void)triggerSyllableHapticWithDuration:(NSTimeInterval)duration {
    if (!YTMU(@"musicHaptics")) return;

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - self.lastTriggerTime < 0.070) return;
    self.lastTriggerTime = now;

    NSInteger intensity = YTMUInt(@"musicHapticsIntensity", 1);
    float fi = (intensity == 0) ? 0.40f : ((intensity == 2) ? 0.85f : 0.55f);
    float fs = (intensity == 0) ? 0.45f : ((intensity == 2) ? 0.75f : 0.60f);
    if (duration > 0.4) fi = MIN(1.0f, fi + 0.15f);

    NSLog(@"[YTMU-Haptics] Trigger syllable haptic (dur=%.2f, intensity=%.2f)", duration, fi);
    [self playTransientWithIntensity:fi sharpness:fs];
}

- (void)triggerBeatHaptic {
    if (!YTMU(@"musicHaptics")) return;

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - self.lastTriggerTime < 0.100) return;
    self.lastTriggerTime = now;

    NSInteger intensity = YTMUInt(@"musicHapticsIntensity", 1);
    float fi = (intensity == 0) ? 0.45f : ((intensity == 2) ? 0.90f : 0.65f);
    float fs = (intensity == 0) ? 0.50f : ((intensity == 2) ? 0.80f : 0.65f);

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
                        CHHapticPatternKeyEventDuration:   @(0.04),
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
    float fi = (intensity == 0) ? 0.40f : ((intensity == 2) ? 0.90f : 0.65f);
    float fs = (intensity == 0) ? 0.45f : ((intensity == 2) ? 0.80f : 0.65f);
    [[YTMUMusicHapticsManager sharedInstance] playTransientWithIntensity:fi sharpness:fs];
}

// ---- Hook: intercept every setNowPlayingInfo: call ----
%hook MPNowPlayingInfoCenter
- (void)setNowPlayingInfo:(NSDictionary *)nowPlayingInfo {
    if (!nowPlayingInfo) { %orig(nil); return; }

    NSString *title  = nowPlayingInfo[@"title"]  ?: nowPlayingInfo[@"MPMediaItemPropertyTitle"];
    NSString *artist = nowPlayingInfo[@"artist"] ?: nowPlayingInfo[@"MPMediaItemPropertyArtist"];

    if (title.length && artist.length) {
        YTMUMusicHapticsManager *mgr = [YTMUMusicHapticsManager sharedInstance];
        mgr.currentTitle = title;
        mgr.currentArtist = artist;
        [mgr lookupISRCForTitle:title artist:artist];
    }

    NSString *isrc = [YTMUMusicHapticsManager sharedInstance].currentISRC;
    NSString *existing = nowPlayingInfo[@"MPNowPlayingInfoPropertyInternationalStandardRecordingCode"];

    if (isrc.length && !existing.length) {
        NSMutableDictionary *mut = [nowPlayingInfo mutableCopy];
        mut[@"MPNowPlayingInfoPropertyInternationalStandardRecordingCode"] = isrc;
        %orig(mut);
        return;
    }

    if (existing.length) {
        [[YTMUMusicHapticsManager sharedInstance] updateISRC:existing];
    }

    %orig(nowPlayingInfo);
}
%end
