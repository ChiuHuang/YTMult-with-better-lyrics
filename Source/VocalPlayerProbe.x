// Low-risk discovery for Sing: observe AVPlayer item wiring only while Sing
// is selected. This deliberately does not install an audio tap, inspect an
// AudioUnit, or read/copy rendered audio. The player path must be identified
// before the separator can be attached without repeating the Core Audio crash.
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import "LyricsShared.h"
#import "VocalSeparation.h"

static NSMutableSet<NSString *> *YTMUSingProbeEvents;

static NSString *YTMUClassName(id object) {
    return object ? NSStringFromClass([object class]) : @"(none)";
}

static void YTMURecordSingPlayer(AVPlayer *player, NSString *event) {
    if (!player || !event.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        YTMUVocalSeparationManager *manager = [YTMUVocalSeparationManager sharedInstance];
        if (manager.selectedMode == YTMUVocalSeparationModeNormal) return;

        AVPlayerItem *item = player.currentItem;
        if (!item) return;

        NSString *identity = [NSString stringWithFormat:@"%p:%p:%@", player, item, event];
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{ YTMUSingProbeEvents = [NSMutableSet set]; });
        @synchronized (YTMUSingProbeEvents) {
            if ([YTMUSingProbeEvents containsObject:identity]) return;
            [YTMUSingProbeEvents addObject:identity];
            if (YTMUSingProbeEvents.count > 96) [YTMUSingProbeEvents removeAllObjects];
        }

        AVAudioMix *mix = item.audioMix;
        NSUInteger inputCount = mix.inputParameters.count;
        NSDictionary *details = @{
            @"playerClass": YTMUClassName(player),
            @"itemClass": YTMUClassName(item),
            @"assetClass": YTMUClassName(item.asset),
            @"audioMixClass": YTMUClassName(mix),
            @"audioMixInputCount": @(inputCount),
            @"itemStatus": @(item.status),
        };
        NSString *message = [NSString stringWithFormat:
                            @"AVPlayer path event=%@ player=%@ item=%@ asset=%@ mix=%@ inputs=%lu status=%ld",
                            event, details[@"playerClass"], details[@"itemClass"],
                            details[@"assetClass"], details[@"audioMixClass"],
                            (unsigned long)inputCount, (long)item.status];
        NSLog(@"[YTMU-Sing-Probe] %@", message);
        sendDebugLogWithPayload(@"sing-player-path", message, details);
    });
}

%hook AVPlayer
- (void)replaceCurrentItemWithPlayerItem:(AVPlayerItem *)item {
    %orig;
    YTMURecordSingPlayer(self, @"replace-current-item");
}

- (void)play {
    %orig;
    YTMURecordSingPlayer(self, @"play");
}
%end
