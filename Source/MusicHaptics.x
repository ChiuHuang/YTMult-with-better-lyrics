#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreHaptics/CoreHaptics.h>
#import <MediaPlayer/MediaPlayer.h>
#import "LyricsShared.h"

// Forward declaration for iOS 18 MAMusicHapticsManager (checked dynamically)
@interface MAMusicHapticsManager : NSObject
+ (instancetype)sharedManager;
@property (nonatomic, readonly) BOOL isActive;
@end

static BOOL YTMU(NSString *key) {
    NSDictionary *dict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    return [dict[key] boolValue];
}

static NSInteger YTMUInt(NSString *key, NSInteger dflt) {
    NSDictionary *dict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    id val = dict[key];
    return val ? [val integerValue] : dflt;
}

@interface YTMUMusicHapticsManager : NSObject
@property (nonatomic, strong) CHHapticEngine *engine;
@property (nonatomic, assign) BOOL isEngineRunning;
@property (nonatomic, copy) NSString *currentISRC;
@property (nonatomic, assign) NSTimeInterval lastTriggerTime;
+ (instancetype)sharedInstance;
- (BOOL)isSystemMusicHapticsActive;
- (void)triggerSyllableHapticWithDuration:(NSTimeInterval)duration;
- (void)triggerBeatHaptic;
- (void)updateISRC:(NSString *)isrc;
@end

@implementation YTMUMusicHapticsManager

+ (instancetype)sharedInstance {
    static YTMUMusicHapticsManager *s_instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_instance = [[self alloc] init];
    });
    return s_instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lastTriggerTime = 0.0;
        [self setupCoreHaptics];
        [self observeSystemHaptics];
    }
    return self;
}

- (void)setupCoreHaptics {
    if (![CHHapticEngine capabilitiesForHardware].supportsHaptics) {
        return;
    }
    NSError *error = nil;
    self.engine = [[CHHapticEngine alloc] initAndReturnError:&error];
    if (error) {
        self.engine = nil;
        return;
    }
    self.engine.playsHapticsOnly = YES;
    __weak typeof(self) weakSelf = self;
    self.engine.resetHandler = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf startEngineIfNeeded];
        }
    };
    self.engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) {
            strongSelf.isEngineRunning = NO;
        }
    };
    [self startEngineIfNeeded];
}

- (void)startEngineIfNeeded {
    if (!self.engine || self.isEngineRunning) return;
    NSError *err = nil;
    [self.engine startAndReturnError:&err];
    self.isEngineRunning = (err == nil);
}

- (void)observeSystemHaptics {
    Class mamClass = NSClassFromString(@"MAMusicHapticsManager");
    if (mamClass) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(systemHapticsChanged:)
                                                     name:@"MAMusicHapticsManagerActiveStatusDidChangeNotification"
                                                   object:nil];
    }
}

- (void)systemHapticsChanged:(NSNotification *)note {
    // System status toggled in iOS Settings -> Accessibility -> Music Haptics
}

- (BOOL)isSystemMusicHapticsActive {
    Class mamClass = NSClassFromString(@"MAMusicHapticsManager");
    if (!mamClass) return NO;
    @try {
        id manager = [mamClass performSelector:@selector(sharedManager)];
        if ([manager respondsToSelector:@selector(isActive)]) {
            return [manager isActive];
        }
    } @catch (NSException *e) {}
    return NO;
}

- (void)updateISRC:(NSString *)isrc {
    self.currentISRC = isrc;
    if (isrc.length) {
        MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
        NSDictionary *now = center.nowPlayingInfo;
        if (now) {
            NSMutableDictionary *mut = [now mutableCopy];
            mut[@"MPNowPlayingInfoPropertyInternationalStandardRecordingCode"] = isrc;
            center.nowPlayingInfo = mut;
        }
    }
}

- (void)triggerSyllableHapticWithDuration:(NSTimeInterval)duration {
    if (!YTMU(@"musicHaptics")) return;
    
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    // Minimum 70ms debounce between rapid syllables to prevent motor fatigue
    if (now - self.lastTriggerTime < 0.070) {
        return;
    }
    self.lastTriggerTime = now;

    NSInteger intensitySetting = YTMUInt(@"musicHapticsIntensity", 1); // 0: light, 1: med, 2: strong
    float baseIntensity = 0.55f;
    float baseSharpness = 0.60f;
    if (intensitySetting == 0) {
        baseIntensity = 0.40f;
        baseSharpness = 0.45f;
    } else if (intensitySetting == 2) {
        baseIntensity = 0.85f;
        baseSharpness = 0.75f;
    }

    // Scale intensity slightly with syllable duration (longer vocal emphasis gets slightly firmer tap)
    if (duration > 0.4) {
        baseIntensity = MIN(1.0f, baseIntensity + 0.15f);
    }

    [self playTransientHapticWithIntensity:baseIntensity sharpness:baseSharpness];
}

- (void)triggerBeatHaptic {
    if (!YTMU(@"musicHaptics")) return;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - self.lastTriggerTime < 0.100) return;
    self.lastTriggerTime = now;

    NSInteger intensitySetting = YTMUInt(@"musicHapticsIntensity", 1);
    float baseIntensity = (intensitySetting == 0) ? 0.45f : ((intensitySetting == 2) ? 0.90f : 0.65f);
    float baseSharpness = (intensitySetting == 0) ? 0.50f : ((intensitySetting == 2) ? 0.80f : 0.65f);

    [self playTransientHapticWithIntensity:baseIntensity sharpness:baseSharpness];
}

- (void)playTransientHapticWithIntensity:(float)intensity sharpness:(float)sharpness {
    if (self.engine) {
        if (!self.isEngineRunning) {
            [self startEngineIfNeeded];
        }
        if (self.isEngineRunning) {
            NSDictionary *hapticDict = @{
                CHHapticPatternKeyPattern: @[
                    @{
                        CHHapticPatternKeyEvent: @{
                            CHHapticPatternKeyEventType: CHHapticEventTypeHapticTransient,
                            CHHapticPatternKeyTime: @(0.0),
                            CHHapticPatternKeyEventDuration: @(0.04),
                            CHHapticPatternKeyEventParameters: @[
                                @{ CHHapticPatternKeyParameterID: CHHapticEventParameterIDHapticIntensity, CHHapticPatternKeyParameterValue: @(intensity) },
                                @{ CHHapticPatternKeyParameterID: CHHapticEventParameterIDHapticSharpness, CHHapticPatternKeyParameterValue: @(sharpness) }
                            ]
                        }
                    }
                ]
            };
            NSError *pError = nil;
            CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithDictionary:hapticDict error:&pError];
            if (pattern) {
                id<CHHapticPatternPlayer> player = [self.engine createPlayerWithPattern:pattern error:nil];
                [player startAtTime:CHHapticTimeImmediate error:nil];
                return;
            }
        }
    }

    // Fallback: UIKit Impact Feedback Generator
    UIImpactFeedbackStyle style = UIImpactFeedbackStyleLight;
    if (intensity > 0.75f) {
        style = UIImpactFeedbackStyleHeavy;
    } else if (intensity > 0.50f) {
        style = UIImpactFeedbackStyleMedium;
    }
    UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:style];
    [gen prepare];
    [gen impactOccurred];
}

@end

// Public functions callable from LyricsSheet and other TUs
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

// Hook MPNowPlayingInfoCenter to supply ISRC for iOS 18 Music Haptics
%hook MPNowPlayingInfoCenter
- (void)setNowPlayingInfo:(NSDictionary *)nowPlayingInfo {
    if (!nowPlayingInfo) {
        %orig(nil);
        return;
    }
    NSString *isrc = [YTMUMusicHapticsManager sharedInstance].currentISRC;
    if (isrc.length && !nowPlayingInfo[@"MPNowPlayingInfoPropertyInternationalStandardRecordingCode"]) {
        NSMutableDictionary *mut = [nowPlayingInfo mutableCopy];
        mut[@"MPNowPlayingInfoPropertyInternationalStandardRecordingCode"] = isrc;
        %orig(mut);
        return;
    }
    %orig(nowPlayingInfo);
}
%end
