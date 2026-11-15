// Read-only discovery hook for Sing. It logs player mixer connections without
// querying stream formats or touching rendered audio buffers.
#import <AudioToolbox/AudioToolbox.h>
#import <substrate.h>
#import <string.h>
#import "LyricsShared.h"

static OSStatus (*YTMUOriginalAudioUnitSetProperty)(AudioUnit, AudioUnitPropertyID,
                                                    AudioUnitScope, AudioUnitElement,
                                                    const void *, UInt32);

static BOOL YTMUSingAudioDescription(AudioUnit unit, AudioComponentDescription *description) {
    if (!unit || !description) return NO;
    AudioComponent component = AudioComponentInstanceGetComponent(unit);
    if (!component) return NO;
    memset(description, 0, sizeof(*description));
    return AudioComponentGetDescription(component, description) == noErr;
}

static void YTMUSingInspectConnection(AudioUnit outputUnit, AudioUnit sourceUnit,
                                      AudioUnitElement sourceBus) {
    AudioComponentDescription output = {0}, source = {0};
    if (!YTMUSingAudioDescription(outputUnit, &output) ||
        output.componentType != kAudioUnitType_Output ||
        (output.componentSubType != kAudioUnitSubType_RemoteIO &&
         output.componentSubType != kAudioUnitSubType_VoiceProcessingIO) ||
        !YTMUSingAudioDescription(sourceUnit, &source)) return;

    // Music Haptics independently samples the registered mixer through its
    // existing AudioUnitRender hook; this probe only identifies the graph edge.
    YTMUMusicHapticsRegisterMixer(sourceUnit, sourceBus);
    NSString *message = [NSString stringWithFormat:
        @"[YTMU-Sing-Audio] player graph connection: source=%p type=%08x subtype=%08x bus=%u -> output=%p subtype=%08x",
        sourceUnit, (unsigned)source.componentType, (unsigned)source.componentSubType,
        (unsigned)sourceBus, outputUnit, (unsigned)output.componentSubType];
    NSLog(@"%@", message);
    sendDebugLog(message);
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

    // Never query AudioUnit properties from this hook. On iOS 27 beta that
    // re-enters AudioToolbox's converter registry and crashes during setup.
    AudioUnit outputUnit = unit;
    AudioUnit sourceUnit = connection.sourceAudioUnit;
    AudioUnitElement sourceBus = connection.sourceOutputNumber;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        YTMUSingInspectConnection(outputUnit, sourceUnit, sourceBus);
    });
    return status;
}

__attribute__((constructor)) static void YTMUInstallAudioUnitProbe(void) {
    MSHookFunction((void *)AudioUnitSetProperty, (void *)YTMUAudioUnitSetPropertyProbe,
                   (void **)&YTMUOriginalAudioUnitSetProperty);
}
