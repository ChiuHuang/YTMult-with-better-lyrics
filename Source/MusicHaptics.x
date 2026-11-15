#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreHaptics/CoreHaptics.h>
#import <MediaPlayer/MediaPlayer.h>
#import <AudioToolbox/AudioToolbox.h>
#import <substrate.h>
#import <stdatomic.h>
#import <math.h>
#import <stdint.h>
#import <mach/mach_time.h>
#import <string.h>
#import "LyricsShared.h"

static NSMutableArray<NSString *> *YTMUISRCRecentLogLines;
static atomic_bool YTMUAudioCaptureEnabled;
static atomic_uint_fast64_t YTMUAudioLastHostTime;
static atomic_uint_fast32_t YTMUAudioOnsetSequence;
static atomic_uint_fast32_t YTMUAudioRMSBits;
static atomic_uint_fast32_t YTMUAudioPeakBits;
static atomic_uint_fast32_t YTMUAudioPreviousRMSBits;
static atomic_uint_fast32_t YTMUAudioNoiseFloorBits;
static mach_timebase_info_data_t YTMUHostTimebase;
static atomic_uintptr_t YTMUMusicOutputUnits[8];
static atomic_uint YTMUMusicOutputBuses[8];
static OSStatus (*YTMUOriginalAudioUnitRender)(AudioUnit, AudioUnitRenderActionFlags *,
                                               const AudioTimeStamp *, UInt32, UInt32,
                                               AudioBufferList *);

static BOOL YTMUAudioUnitDescription(AudioUnit unit, AudioComponentDescription *description) {
    if (!unit || !description) return NO;
    AudioComponent component = AudioComponentInstanceGetComponent(unit);
    if (!component) return NO;
    memset(description, 0, sizeof(*description));
    return AudioComponentGetDescription(component, description) == noErr;
}

static BOOL YTMUIsPlayerMixerUnit(AudioUnit unit) {
    AudioComponentDescription desc = {0};
    if (!YTMUAudioUnitDescription(unit, &desc) || desc.componentType != kAudioUnitType_Mixer) return NO;
    return desc.componentSubType == kAudioUnitSubType_MultiChannelMixer ||
           desc.componentSubType == kAudioUnitSubType_MatrixMixer;
}

void YTMUMusicHapticsRegisterMixer(AudioUnit sourceUnit, UInt32 sourceOutputBus) {
    if (!sourceUnit || !YTMUIsPlayerMixerUnit(sourceUnit)) return;
    uintptr_t source = (uintptr_t)sourceUnit;
    for (NSUInteger i = 0; i < sizeof(YTMUMusicOutputUnits) / sizeof(YTMUMusicOutputUnits[0]); i++) {
        if (atomic_load_explicit(&YTMUMusicOutputUnits[i], memory_order_acquire) == source &&
            atomic_load_explicit(&YTMUMusicOutputBuses[i], memory_order_relaxed) == sourceOutputBus) return;
    }
    for (NSUInteger i = 0; i < sizeof(YTMUMusicOutputUnits) / sizeof(YTMUMusicOutputUnits[0]); i++) {
        uintptr_t empty = 0;
        if (atomic_compare_exchange_strong_explicit(&YTMUMusicOutputUnits[i], &empty, source,
                                                    memory_order_acq_rel, memory_order_relaxed)) {
            atomic_store_explicit(&YTMUMusicOutputBuses[i], sourceOutputBus, memory_order_release);
            return;
        }
    }
}

static BOOL YTMUIsTrackedPlayerMixer(AudioUnit unit, UInt32 outputBus) {
    uintptr_t candidate = (uintptr_t)unit;
    for (NSUInteger i = 0; i < sizeof(YTMUMusicOutputUnits) / sizeof(YTMUMusicOutputUnits[0]); i++) {
        if (atomic_load_explicit(&YTMUMusicOutputUnits[i], memory_order_acquire) == candidate &&
            atomic_load_explicit(&YTMUMusicOutputBuses[i], memory_order_relaxed) == outputBus) return YES;
    }
    return NO;
}

static uint64_t YTMUHostTimeNow(void) {
    return mach_absolute_time();
}

static uint64_t YTMUHostTicksToNanos(uint64_t ticks) {
    return YTMUHostTimebase.denom ? (ticks * YTMUHostTimebase.numer) / YTMUHostTimebase.denom : 0;
}

static uint32_t YTMUFloatBits(float value) {
    union { float f; uint32_t u; } bits = {.f = value};
    return bits.u;
}

static float YTMUFloatFromBits(uint32_t value) {
    union { float f; uint32_t u; } bits = {.u = value};
    return bits.f;
}

// This hook only measures the final PCM render buffers. It does no allocation,
// locking, logging, UIKit, or haptic work on Core Audio's render thread.
static void YTMUObserveRenderedAudio(AudioBufferList *buffers, UInt32 frameCount) {
    if (!buffers || !frameCount) return;
    double squareSum = 0.0;
    float peak = 0.0f;
    uint64_t sampleCount = 0;
    for (UInt32 b = 0; b < buffers->mNumberBuffers; b++) {
        AudioBuffer *buffer = &buffers->mBuffers[b];
        if (!buffer->mData || !buffer->mDataByteSize) continue;
        uint32_t channels = buffer->mNumberChannels ? buffer->mNumberChannels : 1;
        uint64_t expected = (uint64_t)frameCount * channels;
        uint32_t bytesPerSample = (uint32_t)(buffer->mDataByteSize / expected);
        if (bytesPerSample == 4) {
            const float *samples = (const float *)buffer->mData;
            uint64_t count = MIN(expected, buffer->mDataByteSize / sizeof(float));
            for (uint64_t i = 0; i < count; i++) {
                float value = samples[i];
                if (!isfinite(value)) continue;
                float magnitude = fabsf(value);
                squareSum += (double)value * value;
                peak = MAX(peak, magnitude);
                sampleCount++;
            }
        } else if (bytesPerSample == 2) {
            const int16_t *samples = (const int16_t *)buffer->mData;
            uint64_t count = MIN(expected, buffer->mDataByteSize / sizeof(int16_t));
            for (uint64_t i = 0; i < count; i++) {
                float value = (float)samples[i] / 32768.0f;
                float magnitude = fabsf(value);
                squareSum += (double)value * value;
                peak = MAX(peak, magnitude);
                sampleCount++;
            }
        }
    }
    if (!sampleCount) return;
    float rms = sqrtf((float)(squareSum / (double)sampleCount));
    atomic_store_explicit(&YTMUAudioRMSBits, YTMUFloatBits(rms), memory_order_relaxed);
    atomic_store_explicit(&YTMUAudioPeakBits, YTMUFloatBits(peak), memory_order_relaxed);
    atomic_store_explicit(&YTMUAudioLastHostTime, YTMUHostTimeNow(), memory_order_release);
    if (!atomic_load_explicit(&YTMUAudioCaptureEnabled, memory_order_relaxed)) return;

    float previous = YTMUFloatFromBits(atomic_load_explicit(&YTMUAudioPreviousRMSBits, memory_order_relaxed));
    float floor = YTMUFloatFromBits(atomic_load_explicit(&YTMUAudioNoiseFloorBits, memory_order_relaxed));
    if (!isfinite(previous)) previous = 0.0f;
    if (!isfinite(floor)) floor = 0.0f;
    float threshold = MAX(0.018f, floor * 1.45f);
    if (rms > threshold && previous <= threshold && peak > 0.035f) {
        atomic_fetch_add_explicit(&YTMUAudioOnsetSequence, 1, memory_order_relaxed);
    }
    // Slow envelope tracking makes the transient detector adapt to song level.
    float nextFloor = floor + (rms - floor) * (rms < floor ? 0.08f : 0.008f);
    atomic_store_explicit(&YTMUAudioNoiseFloorBits, YTMUFloatBits(nextFloor), memory_order_relaxed);
    atomic_store_explicit(&YTMUAudioPreviousRMSBits, YTMUFloatBits(rms), memory_order_relaxed);
}

static OSStatus YTMUAudioUnitRenderHook(AudioUnit unit, AudioUnitRenderActionFlags *flags,
                                        const AudioTimeStamp *timeStamp, UInt32 outputBus,
                                        UInt32 frameCount, AudioBufferList *ioData) {
    OSStatus status = YTMUOriginalAudioUnitRender(unit, flags, timeStamp, outputBus, frameCount, ioData);
    if (status == noErr && YTMUIsTrackedPlayerMixer(unit, outputBus) &&
        atomic_load_explicit(&YTMUAudioCaptureEnabled, memory_order_relaxed)) {
        YTMUObserveRenderedAudio(ioData, frameCount);
    }
    return status;
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

// ---- Soundcharts first, then our independent MusicBrainz matcher ----
- (void)lookupISRCForTitle:(NSString *)title artist:(NSString *)artist videoID:(NSString *)videoID {
    if (!title.length || !artist.length) return;

    self.currentTitle = title;
    self.currentArtist = artist;
    self.currentVideoID = videoID ?: @"";

    NSString *key = [NSString stringWithFormat:@"%@|%@|%@",
                     [title lowercaseString], [artist lowercaseString], videoID ?: @""];
    self.currentLookupKey = key;

    if ([key isEqualToString:self.lastQueriedKey]) return;

    NSString *cached = self.isrcCache[key];
    if (cached) {
        self.lastQueriedKey = key;
        self.isrcSource = @"MusicBrainz cache";
        self.isrcLookupState = cached.length ? @"Resolved from cache" : @"No ISRC in cache";
        [self updateISRC:cached];
        YTMULogISRC([NSString stringWithFormat:@"MusicBrainz cache %@ for %@", cached.length ? @"hit" : @"miss", videoID.length ? videoID : key]);
        YTMUReportISRCStatus(videoID, title, artist, @"musicbrainz cache",
                             cached.length ? @"resolved" : @"no ISRC found", cached);
        return;
    }

    if ([self.isrcCache objectForKey:key] != nil) {
        self.isrcSource = @"MusicBrainz cache";
        self.isrcLookupState = @"No ISRC in cache";
        YTMUReportISRCStatus(videoID, title, artist, @"musicbrainz cache", @"no ISRC found", nil);
        return; // previous miss
    }

    if (self.lookupInFlight) {
        self.isrcLookupState = @"Waiting for previous lookup";
        YTMULogISRC([NSString stringWithFormat:@"Skipped %@; another lookup is still running", videoID.length ? videoID : key]);
        self.pendingISRCRequest = @{@"title": [title copy], @"artist": [artist copy],
                                   @"videoID": [videoID copy] ?: @"", @"key": key};
        YTMUReportISRCStatus(videoID, title, artist,
                             videoID.length == 11 ? @"soundcharts" : @"musicbrainz",
                             @"waiting for previous lookup", nil);
        return;
    }
    self.lastQueriedKey = key;
    self.currentLookupKey = key;
    self.lookupInFlight = YES;

    self.systemHasTrackForCurrentSong = NO;
    self.currentISRC = nil;
    self.isrcSource = videoID.length == 11 ? @"Soundcharts → MusicBrainz" : @"MusicBrainz";
    self.isrcLookupState = videoID.length == 11 ? @"Looking up Soundcharts" : @"Looking up MusicBrainz (no video ID)";
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
            self.isrcLookupState = @"Could not create Soundcharts request; trying MusicBrainz";
            YTMULogISRC([NSString stringWithFormat:@"Soundcharts request serialization failed (%@)", bodyError.localizedDescription ?: @"unknown error"]);
            [self lookupMusicBrainzForTitle:title artist:artist key:key];
            return;
        }
        self.isrcLookupState = @"Looking up Soundcharts";
        __weak typeof(self) weakSelf = self;
        [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSString *isrc = [json[@"isrc"] isKindOfClass:[NSString class]] ? [json[@"isrc"] uppercaseString] : nil;
            if (isrc.length != 12) isrc = nil;
            if (isrc.length) {
                strongSelf.isrcCache[key] = isrc;
                YTMULogISRC([NSString stringWithFormat:@"Soundcharts resolved videoID=%@ ISRC=%@", videoID, isrc]);
                if ([strongSelf.currentLookupKey isEqualToString:key]) {
                    strongSelf.isrcSource = @"Soundcharts";
                    strongSelf.isrcLookupState = @"Resolved";
                    YTMUReportISRCStatus(videoID, title, artist, @"soundcharts", @"resolved", isrc);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if ([strongSelf.currentLookupKey isEqualToString:key]) [strongSelf updateISRC:isrc];
                    });
                }
                [strongSelf completeISRCRequest];
                return;
            }
            NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
            YTMULogISRC([NSString stringWithFormat:@"Soundcharts returned no ISRC (HTTP %ld, %@); falling back to MusicBrainz",
                         (long)status, error.localizedDescription ?: @"no transport error"]);
            if ([strongSelf.currentLookupKey isEqualToString:key]) {
                strongSelf.isrcLookupState = error ? @"Soundcharts request failed; trying MusicBrainz" : @"Soundcharts had no ISRC; trying MusicBrainz";
                YTMUReportISRCStatus(videoID, title, artist, @"soundcharts", @"waiting for Soundcharts", nil);
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

            s.isrcCache[requestKey] = foundISRC ?: @"";
            BOOL resultStillCurrent = [s.currentLookupKey isEqualToString:requestKey];
            if (resultStillCurrent) {
                s.isrcSource = @"MusicBrainz";
                s.isrcLookupState = foundISRC.length ? @"Resolved" : @"No ISRC found";
                YTMULogISRC([NSString stringWithFormat:@"MusicBrainz result videoID=%@ ISRC=%@",
                             requestVideoID.length ? requestVideoID : @"(none)", foundISRC ?: @"(none)"]);
                YTMUReportISRCStatus(requestVideoID, requestTitle, requestArtist, @"musicbrainz",
                                     foundISRC.length ? @"resolved" : @"no ISRC found", foundISRC);
            }

            if (foundISRC.length && resultStillCurrent) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if ([s.currentLookupKey isEqualToString:requestKey]) [s updateISRC:foundISRC];
                });
            }
            [s completeISRCRequest];
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
    atomic_store_explicit(&YTMUAudioCaptureEnabled, shouldCapture, memory_order_relaxed);
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
    // AudioUnitRender. Once the tap is readable, the audio envelope owns cues.
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
        atomic_store_explicit(&YTMUAudioCaptureEnabled, false, memory_order_relaxed);
        %orig(nil);
        return;
    }

    NSString *title  = nowPlayingInfo[@"title"]  ?: nowPlayingInfo[@"MPMediaItemPropertyTitle"];
    NSString *artist = nowPlayingInfo[@"artist"] ?: nowPlayingInfo[@"MPMediaItemPropertyArtist"];
    NSString *videoID = YTMUResolveCurrentVideoID();
    NSString *existing = nowPlayingInfo[@"MPNowPlayingInfoPropertyInternationalStandardRecordingCode"];
    NSDictionary *infoToSend = nowPlayingInfo;

    if (title.length && artist.length) {
        YTMUMusicHapticsManager *mgr = [YTMUMusicHapticsManager sharedInstance];
        NSString *trackKey = [NSString stringWithFormat:@"%@|%@|%@", [title lowercaseString], [artist lowercaseString], videoID ?: @""];
        BOOL audioTrackChanged = ![mgr.currentTitle isEqualToString:title] || ![mgr.currentArtist isEqualToString:artist];
        BOOL playbackISRCChanged = ![mgr.lastISRCTrackKey isEqualToString:trackKey] || ![mgr.currentISRC isEqualToString:existing];
        if (audioTrackChanged) {
            mgr.audioTapReadable = NO;
            mgr.lastAudioOnsetSequence = atomic_load_explicit(&YTMUAudioOnsetSequence, memory_order_relaxed);
            atomic_store_explicit(&YTMUAudioPreviousRMSBits, YTMUFloatBits(0.0f), memory_order_relaxed);
            atomic_store_explicit(&YTMUAudioNoiseFloorBits, YTMUFloatBits(0.0f), memory_order_relaxed);
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

%ctor {
    mach_timebase_info(&YTMUHostTimebase);
    MSHookFunction((void *)AudioUnitRender, (void *)YTMUAudioUnitRenderHook,
                   (void **)&YTMUOriginalAudioUnitRender);
    %init;
}
