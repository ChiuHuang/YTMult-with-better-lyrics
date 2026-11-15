// Temporary read-only discovery hook for Sing. It records the app's mixer to
// hardware-output connections without replacing or editing any audio buffers.
#import <AudioToolbox/AudioToolbox.h>
#import <substrate.h>
#import <stdatomic.h>
#import <string.h>
#import "LyricsShared.h"

static atomic_uint YTMUSingAudioProbeCount;
typedef struct {
    _Atomic(uintptr_t) unit;
    atomic_uint logged;
} YTMUSingObservedOutput;
static YTMUSingObservedOutput YTMUSingObservedOutputs[4];
static const unsigned int YTMUSingAudioProbeLimit = 16;
static OSStatus (*YTMUOriginalAudioUnitSetProperty)(AudioUnit, AudioUnitPropertyID,
                                                    AudioUnitScope, AudioUnitElement,
                                                    const void *, UInt32);

static OSStatus YTMUSingOutputNotify(void *context, AudioUnitRenderActionFlags *flags,
                                     const AudioTimeStamp *timestamp, UInt32 bus,
                                     UInt32 frames, AudioBufferList *data) {
    (void)timestamp;
    if (!flags || !(*flags & kAudioUnitRenderAction_PostRender) || !data) return noErr;
    YTMUSingObservedOutput *probe = context;
    if (!probe || atomic_exchange_explicit(&probe->logged, 1, memory_order_relaxed)) return noErr;
    NSMutableString *shape = [NSMutableString stringWithFormat:
        @"[YTMU-Sing-Audio] output render: bus=%u frames=%u buffers=%u silence=%d",
        (unsigned)bus, (unsigned)frames, (unsigned)data->mNumberBuffers,
        ((*flags & kAudioUnitRenderAction_OutputIsSilence) != 0)];
    for (UInt32 i = 0; i < data->mNumberBuffers; i++) {
        const AudioBuffer *buffer = &data->mBuffers[i];
        [shape appendFormat:@" b%u=%uch/%uB", (unsigned)i, (unsigned)buffer->mNumberChannels,
         (unsigned)buffer->mDataByteSize];
    }
    NSString *message = [shape copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSLog(@"%@", message);
        sendDebugLog(message);
    });
    return noErr;
}

static void YTMUSingObserveOutput(AudioUnit output) {
    if (!output) return;
    for (NSUInteger i = 0; i < sizeof(YTMUSingObservedOutputs) / sizeof(YTMUSingObservedOutputs[0]); i++) {
        uintptr_t expected = 0;
        if (atomic_compare_exchange_strong_explicit(&YTMUSingObservedOutputs[i].unit, &expected,
                (uintptr_t)output, memory_order_relaxed, memory_order_relaxed)) {
            OSStatus status = AudioUnitAddRenderNotify(output, YTMUSingOutputNotify,
                                                       &YTMUSingObservedOutputs[i]);
            if (status != noErr) {
                atomic_store_explicit(&YTMUSingObservedOutputs[i].unit, 0, memory_order_relaxed);
                NSString *message = [NSString stringWithFormat:
                    @"[YTMU-Sing-Audio] could not attach output format probe (status=%d)", (int)status];
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ sendDebugLog(message); });
            }
            return;
        }
        if (expected == (uintptr_t)output) return;
    }
}

static BOOL YTMUSingAudioDescription(AudioUnit unit, AudioComponentDescription *description) {
    if (!unit || !description) return NO;
    AudioComponent component = AudioComponentInstanceGetComponent(unit);
    if (!component) return NO;
    memset(description, 0, sizeof(*description));
    return AudioComponentGetDescription(component, description) == noErr;
}

static AudioStreamBasicDescription YTMUSingAudioFormat(AudioUnit unit, AudioUnitScope scope, AudioUnitElement element) {
    AudioStreamBasicDescription format = {0};
    UInt32 size = sizeof(format);
    if (!unit || AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, scope, element, &format, &size) != noErr) {
        memset(&format, 0, sizeof(format));
    }
    return format;
}

static void YTMUSingInspectConnection(AudioUnit unit, AudioUnit sourceUnit, AudioUnitElement sourceBus);

static UInt32 YTMUSingMaximumFramesPerSlice(AudioUnit unit) {
    UInt32 frames = 0, size = sizeof(frames);
    if (!unit || AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
                                      kAudioUnitScope_Global, 0, &frames, &size) != noErr) return 0;
    return frames;
}

static NSString *YTMUSingAudioFormatText(AudioStreamBasicDescription format) {
    if (format.mFormatID != kAudioFormatLinearPCM) return @"non-PCM/unknown";
    return [NSString stringWithFormat:@"%.0fHz/%uch/%ubit/flags=%08x", format.mSampleRate,
            (unsigned)format.mChannelsPerFrame, (unsigned)format.mBitsPerChannel, (unsigned)format.mFormatFlags];
}

static OSStatus YTMUAudioUnitSetPropertyProbe(AudioUnit unit, AudioUnitPropertyID property,
                                             AudioUnitScope scope, AudioUnitElement element,
                                             const void *data, UInt32 dataSize) {
    AudioUnitConnection connection = {0};
    BOOL isConnection = property == kAudioUnitProperty_MakeConnection &&
                       scope == kAudioUnitScope_Input && element == 0 && data &&
                       dataSize >= sizeof(connection);
    if (isConnection) memcpy(&connection, data, sizeof(connection));

    OSStatus status = YTMUOriginalAudioUnitSetProperty(unit, property, scope, element, data, dataSize);
    if (status != noErr || !isConnection || !connection.sourceAudioUnit) return status;

    // AudioUnitSetProperty is called while Core Audio is configuring its graph.
    // Querying stream formats or adding a render notify from inside this hook
    // can re-enter AudioToolbox's converter registry during that setup. Defer
    // discovery work off the hook stack and past the graph's setup call.
    AudioUnit outputUnit = unit;
    AudioUnit sourceUnit = connection.sourceAudioUnit;
    AudioUnitElement sourceBus = connection.sourceOutputNumber;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        YTMUSingInspectConnection(outputUnit, sourceUnit, sourceBus);
    });
    return status;
}

static void YTMUSingInspectConnection(AudioUnit unit, AudioUnit sourceUnit, AudioUnitElement sourceBus) {
    AudioComponentDescription destination = {0}, source = {0};
    if (!YTMUSingAudioDescription(unit, &destination) || destination.componentType != kAudioUnitType_Output ||
        (destination.componentSubType != kAudioUnitSubType_RemoteIO &&
         destination.componentSubType != kAudioUnitSubType_VoiceProcessingIO) ||
        !YTMUSingAudioDescription(sourceUnit, &source)) return;

    // Share the exact player mixer/output-bus pair with Music Haptics. Its
    // AudioUnitRender hook then ignores Core Haptics and unrelated audio units.
    YTMUMusicHapticsRegisterMixer(sourceUnit, sourceBus);

    unsigned int number = atomic_fetch_add_explicit(&YTMUSingAudioProbeCount, 1, memory_order_relaxed);
    if (number >= YTMUSingAudioProbeLimit) return;
    AudioStreamBasicDescription sourceFormat = YTMUSingAudioFormat(sourceUnit,
                                                                    kAudioUnitScope_Output,
                                                                    sourceBus);
    AudioStreamBasicDescription outputInputFormat = YTMUSingAudioFormat(unit, kAudioUnitScope_Input, 0);
    NSString *message = [NSString stringWithFormat:
        @"[YTMU-Sing-Audio] connection %u: source=%p type=%08x subtype=%08x bus=%u format=%@ -> output=%p subtype=%08x input=%@ maxFrames=%u",
        number + 1, sourceUnit, (unsigned)source.componentType, (unsigned)source.componentSubType,
        (unsigned)sourceBus, YTMUSingAudioFormatText(sourceFormat), unit,
        (unsigned)destination.componentSubType, YTMUSingAudioFormatText(outputInputFormat),
        (unsigned)YTMUSingMaximumFramesPerSlice(unit)];
    YTMUSingObserveOutput(unit);
    NSLog(@"%@", message);
    sendDebugLog(message);
}

__attribute__((constructor)) static void YTMUInstallAudioUnitProbe(void) {
    MSHookFunction((void *)AudioUnitSetProperty, (void *)YTMUAudioUnitSetPropertyProbe,
                   (void **)&YTMUOriginalAudioUnitSetProperty);
}
