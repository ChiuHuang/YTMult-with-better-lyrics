// Temporary read-only discovery hook for Sing. It records the app's mixer to
// hardware-output connections without replacing or editing any audio buffers.
#import <AudioToolbox/AudioToolbox.h>
#import <stdatomic.h>
#import <string.h>
#import "LyricsShared.h"

static atomic_uint YTMUSingAudioProbeCount;
static const unsigned int YTMUSingAudioProbeLimit = 16;

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

%hookf(OSStatus, AudioUnitSetProperty,
       AudioUnit unit, AudioUnitPropertyID property, AudioUnitScope scope, AudioUnitElement element,
       const void *data, UInt32 dataSize) {
    AudioUnitConnection connection = {0};
    BOOL isConnection = property == kAudioUnitProperty_MakeConnection &&
                       scope == kAudioUnitScope_Input && element == 0 && data &&
                       dataSize >= sizeof(connection);
    if (isConnection) memcpy(&connection, data, sizeof(connection));

    OSStatus status = %orig(unit, property, scope, element, data, dataSize);
    if (status != noErr || !isConnection || !connection.sourceAudioUnit) return status;

    AudioComponentDescription destination = {0}, source = {0};
    if (!YTMUSingAudioDescription(unit, &destination) || destination.componentType != kAudioUnitType_Output ||
        (destination.componentSubType != kAudioUnitSubType_RemoteIO &&
         destination.componentSubType != kAudioUnitSubType_VoiceProcessingIO) ||
        !YTMUSingAudioDescription(connection.sourceAudioUnit, &source)) return status;

    unsigned int number = atomic_fetch_add_explicit(&YTMUSingAudioProbeCount, 1, memory_order_relaxed);
    if (number >= YTMUSingAudioProbeLimit) return status;
    AudioStreamBasicDescription sourceFormat = YTMUSingAudioFormat(connection.sourceAudioUnit,
                                                                    kAudioUnitScope_Output,
                                                                    connection.sourceOutputNumber);
    AudioStreamBasicDescription outputInputFormat = YTMUSingAudioFormat(unit, kAudioUnitScope_Input, 0);
    NSString *message = [NSString stringWithFormat:
        @"[YTMU-Sing-Audio] connection %u: source=%p type=%08x subtype=%08x bus=%u format=%@ -> output=%p subtype=%08x input=%@ maxFrames=%u",
        number + 1, connection.sourceAudioUnit, (unsigned)source.componentType, (unsigned)source.componentSubType,
        (unsigned)connection.sourceOutputNumber, YTMUSingAudioFormatText(sourceFormat), unit,
        (unsigned)destination.componentSubType, YTMUSingAudioFormatText(outputInputFormat),
        (unsigned)YTMUSingMaximumFramesPerSlice(unit)];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSLog(@"%@", message);
        sendDebugLog(message);
    });
    return status;
}

%ctor {
    %init;
}
