#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreHaptics/CoreHaptics.h>
#import <MediaPlayer/MediaPlayer.h>
#import "LyricsShared.h"

// MAMusicHapticsManager — MediaAccessibility private/public (iOS 18+)
// The system drives haptic playback automatically when:
//   1. MusicHapticsSupported = YES in Info.plist
//   2. MPNowPlayingInfoCenter carries @"MPNowPlayingInfoPropertyInternationalStandardRecordingCode"
// We do NOT fire our own CoreHaptics when the system is active and has an ISRC track.
// Our CoreHaptics engine is a FALLBACK for songs with no Apple haptic track.

@interface MAMusicHapticsManager : NSObject
+ (instancetype)sharedManager;
@property (nonatomic, readonly) BOOL isActive;
// iOS 18.2+ added checkHapticTrackAvailabilityForMedia:completionHandler:
- (void)checkHapticTrackAvailabilityForMedia:(NSString *)isrc
                           completionHandler:(void(^)(BOOL available))handler;
@end

// ---- Preference helpers ----
static BOOL YTMU(NSString *key) {
    NSDictionary *dict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    return [dict[key] boolValue];
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
@property (nonatomic, assign) NSTimeInterval lastTriggerTime;
@property (nonatomic, assign) BOOL systemHasTrackForCurrentSong; // YES if MAMusicHaptics has a track
+ (instancetype)sharedInstance;
- (BOOL)isSystemMusicHapticsActive;
- (void)triggerSyllableHapticWithDuration:(NSTimeInterval)duration;
- (void)triggerBeatHaptic;
- (void)updateISRC:(NSString *)isrc;
- (void)setCurrentVideoID:(NSString *)vid;
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
        [self setupCoreHaptics];
        [self observeSystemHaptics];
    }
    return self;
}

// ---- CoreHaptics setup (fallback engine) ----
- (void)setupCoreHaptics {
    if (![CHHapticEngine capabilitiesForHardware].supportsHaptics) return;
    NSError *err = nil;
    self.engine = [[CHHapticEngine alloc] initAndReturnError:&err];
    if (err || !self.engine) { self.engine = nil; return; }
    // Do NOT set playsHapticsOnly = YES — that flag can interfere with
    // MAMusicHapticsManager's exclusive haptic output on some devices.
    __weak typeof(self) ws = self;
    self.engine.resetHandler = ^{
        __strong typeof(ws) s = ws;
        if (s) [s startEngineIfNeeded];
    };
    self.engine.stoppedHandler = ^(CHHapticEngineStoppedReason r) {
        __strong typeof(ws) s = ws;
        if (s) s.isEngineRunning = NO;
    };
    // Don't start the engine eagerly; start it on first use to avoid
    // competing with system haptics at launch.
}

- (void)startEngineIfNeeded {
    if (!self.engine || self.isEngineRunning) return;
    NSError *err = nil;
    [self.engine startAndReturnError:&err];
    self.isEngineRunning = (err == nil);
}

// ---- System Music Haptics observation ----
- (void)observeSystemHaptics {
    // The notification name is published in the MAMusicHapticsManager public header (iOS 18+)
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(systemHapticsStatusChanged:)
                                                 name:@"MAMusicHapticsManagerActiveStatusDidChangeNotification"
                                               object:nil];
    // Also observe app becoming active (re-check system state)
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidBecomeActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
}

- (void)systemHapticsStatusChanged:(NSNotification *)note {
    // System Music Haptics was toggled; nothing extra needed —
    // our fallback logic reads isSystemMusicHapticsActive at trigger time.
}

- (void)appDidBecomeActive:(NSNotification *)note {
    // Re-check track availability for the current ISRC when foregrounded.
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
            NSNumber *actVal = [mgr valueForKey:@"isActive"];
            return [actVal boolValue];
        }
    } @catch (__unused NSException *e) {}
    return NO;
}

- (void)checkSystemTrackAvailabilityForISRC:(NSString *)isrc {
    if (!isrc.length) {
        self.systemHasTrackForCurrentSong = NO;
        return;
    }
    Class cls = NSClassFromString(@"MAMusicHapticsManager");
    if (!cls) {
        self.systemHasTrackForCurrentSong = NO;
        return;
    }
    @try {
        id mgr = [cls performSelector:@selector(sharedManager)];
        SEL checkSel = NSSelectorFromString(@"checkHapticTrackAvailabilityForMedia:completionHandler:");
        if ([mgr respondsToSelector:checkSel]) {
            __weak typeof(self) ws = self;
            void (^cb)(BOOL) = ^(BOOL avail) {
                __strong typeof(ws) s = ws;
                if (s) s.systemHasTrackForCurrentSong = avail;
            };
            // Use NSInvocation to call with block argument safely
            NSMethodSignature *sig = [mgr methodSignatureForSelector:checkSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:mgr];
            [inv setSelector:checkSel];
            [inv setArgument:&isrc atIndex:2];
            [inv setArgument:&cb atIndex:3];
            [inv invoke];
        } else {
            // iOS 18.0/18.1: no availability check API — assume YES if system is active
            self.systemHasTrackForCurrentSong = [self isSystemMusicHapticsActive];
        }
    } @catch (__unused NSException *e) {
        self.systemHasTrackForCurrentSong = NO;
    }
}

// ---- ISRC / video ID ----
- (void)updateISRC:(NSString *)isrc {
    if ([isrc isEqualToString:self.currentISRC]) return;
    self.currentISRC = isrc;
    self.systemHasTrackForCurrentSong = NO; // reset until check completes

    if (isrc.length) {
        // Inject ISRC into the live NowPlayingInfo so the system can fetch the haptic track.
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
}

- (void)setCurrentVideoID:(NSString *)vid {
    // We don't have ISRC lookup yet; mark as no system track.
    // A future MusicBrainz / YTM metadata hook can call updateISRC: when it has the code.
    if (vid.length == 0) {
        self.currentISRC = nil;
        self.systemHasTrackForCurrentSong = NO;
    }
}

// ---- Decide whether to fire our fallback haptic ----
// Return YES if the system Music Haptics is handling this song — we stay silent.
- (BOOL)shouldDeferToSystem {
    return [self isSystemMusicHapticsActive] && self.systemHasTrackForCurrentSong;
}

// ---- Haptic triggers ----
- (void)triggerSyllableHapticWithDuration:(NSTimeInterval)duration {
    if (!YTMU(@"musicHaptics")) return;
    // If the system is running haptics for this song, skip our custom haptics.
    if ([self shouldDeferToSystem]) return;

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - self.lastTriggerTime < 0.070) return; // 70 ms debounce
    self.lastTriggerTime = now;

    NSInteger intensity = YTMUInt(@"musicHapticsIntensity", 1);
    float fi = (intensity == 0) ? 0.40f : ((intensity == 2) ? 0.85f : 0.55f);
    float fs = (intensity == 0) ? 0.45f : ((intensity == 2) ? 0.75f : 0.60f);
    if (duration > 0.4) fi = MIN(1.0f, fi + 0.15f);
    [self playTransientWithIntensity:fi sharpness:fs];
}

- (void)triggerBeatHaptic {
    if (!YTMU(@"musicHaptics")) return;
    if ([self shouldDeferToSystem]) return;

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - self.lastTriggerTime < 0.100) return; // 100 ms debounce
    self.lastTriggerTime = now;

    NSInteger intensity = YTMUInt(@"musicHapticsIntensity", 1);
    float fi = (intensity == 0) ? 0.45f : ((intensity == 2) ? 0.90f : 0.65f);
    float fs = (intensity == 0) ? 0.50f : ((intensity == 2) ? 0.80f : 0.65f);
    [self playTransientWithIntensity:fi sharpness:fs];
}

- (void)playTransientWithIntensity:(float)intensity sharpness:(float)sharpness {
    // Try CoreHaptics first
    [self startEngineIfNeeded];
    if (self.engine && self.isEngineRunning) {
        NSDictionary *hapticDict = @{
            CHHapticPatternKeyPattern: @[
                @{
                    CHHapticPatternKeyEvent: @{
                        CHHapticPatternKeyEventType:     CHHapticEventTypeHapticTransient,
                        CHHapticPatternKeyTime:           @(0.0),
                        CHHapticPatternKeyEventDuration:  @(0.04),
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

// ---- Hook: inject ISRC whenever YTM sets NowPlaying info ----
// YTM never sets an ISRC. We inject ours if we have one.
// This is the critical path: without an ISRC, MAMusicHapticsManager cannot
// look up the haptic track on Apple's servers.
%hook MPNowPlayingInfoCenter
- (void)setNowPlayingInfo:(NSDictionary *)nowPlayingInfo {
    if (!nowPlayingInfo) { %orig(nil); return; }

    NSString *isrc = [YTMUMusicHapticsManager sharedInstance].currentISRC;
    NSString *existing = nowPlayingInfo[@"MPNowPlayingInfoPropertyInternationalStandardRecordingCode"];

    if (isrc.length && !existing.length) {
        NSMutableDictionary *mut = [nowPlayingInfo mutableCopy];
        mut[@"MPNowPlayingInfoPropertyInternationalStandardRecordingCode"] = isrc;
        %orig(mut);
        return;
    }

    // If YTM itself provided an ISRC (future-proofing), store it so we know the system can use it.
    if (existing.length && ![[YTMUMusicHapticsManager sharedInstance].currentISRC isEqualToString:existing]) {
        [[YTMUMusicHapticsManager sharedInstance] updateISRC:existing];
    }

    %orig(nowPlayingInfo);
}
%end
