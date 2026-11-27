// Sing renders separate PCM off-thread and follows the original player's
// media clock. Never install a render tap or pause the master clock.
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import "LyricsShared.h"
#import "VocalSeparation.h"

static NSMutableSet<NSString *> *YTMUSingProbeEvents;
static NSHashTable<AVPlayer *> *sPlayers;
static __weak AVPlayer *sOriginal;
static BOOL sPreviousMute;
static AVAudioPlayer *sStem;
static NSString *sTrack, *sStatus;
static NSInteger sMode, sPlayingWindow = -1;
static NSUInteger sGeneration;
static BOOL sRendering;
static NSMutableDictionary<NSNumber *, NSData *> *sWindows;
static NSTimeInterval sRetryAfter;

static void YTMUSingStatus(NSString *state, double position, double drift) {
    if ([sStatus isEqualToString:state]) return;
    sStatus = state;
    YTMUDebugDeviceNoteLog(@"sing", [NSString stringWithFormat:@"%@ mode=%ld time=%.2f drift=%.3f muted=%d", state, (long)sMode, position, drift, sOriginal.muted]);
}

static void YTMUReleaseStem(void) {
    [sStem stop];
    sStem = nil;
    sPlayingWindow = -1;
    if (sOriginal) sOriginal.muted = sPreviousMute;
    sOriginal = nil;
}

// Each window carries its absolute sample position. The tail is zero padded
// for the fixed-size model, but the player receives only the valid frames.
static NSData *YTMURenderWindow(NSString *path, NSInteger window, NSInteger mode, YTMUMDXSeparator *separator, NSError **err) {
    AVAudioFile *file = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:path] commonFormat:AVAudioPCMFormatFloat32 interleaved:YES error:err];
    AVAudioFramePosition start = (AVAudioFramePosition)window * YTMUMDXWindowFrames;
    if (!file || start >= file.length || file.processingFormat.channelCount != 2 || file.processingFormat.sampleRate != YTMUMDXSampleRate) return nil;
    file.framePosition = start;
    AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat frameCapacity:YTMUMDXWindowFrames];
    if (![file readIntoBuffer:buf error:err] || !buf.frameLength) return nil;
    NSUInteger n = buf.frameLength, size = YTMUMDXWindowFrames * sizeof(float);
    NSMutableData *samples = [NSMutableData dataWithLength:size * 6];
    float *in = samples.mutableBytes, *v = in + 2 * YTMUMDXWindowFrames, *b = v + 2 * YTMUMDXWindowFrames;
    memcpy(in, buf.audioBufferList->mBuffers[0].mData, n * 2 * sizeof(float));
    if (![separator separateInterleavedStereo:in frames:YTMUMDXWindowFrames vocalsLeft:v vocalsRight:v+YTMUMDXWindowFrames instrumentalLeft:b instrumentalRight:b+YTMUMDXWindowFrames error:err]) return nil;
    float *stem = mode == YTMUVocalSeparationModeVocalOnly ? v : b;
    // Stereo PCM WAV; AVAudioPlayer retains this one in-memory window.
    uint32_t bytes = (uint32_t)n * 4, riff = bytes + 36;
    uint8_t header[44] = {'R','I','F','F',0,0,0,0,'W','A','V','E','f','m','t',' ',16,0,0,0,1,0,2,0,0x44,0xac,0,0,0x10,0xb1,2,0,4,0,16,0,'d','a','t','a',0,0,0,0};
    memcpy(header+4, &riff, 4); memcpy(header+40, &bytes, 4);
    NSMutableData *wav = [NSMutableData dataWithLength:44+bytes];
    memcpy(wav.mutableBytes, header, 44);
    int16_t *pcm = (int16_t *)((uint8_t *)wav.mutableBytes + 44);
    for (NSUInteger i=0; i<n; ++i) for (NSUInteger ch=0; ch<2; ++ch)
        pcm[2*i+ch] = (int16_t)lrintf(fmaxf(-1.f, fminf(1.f, stem[ch*YTMUMDXWindowFrames+i])) * 32767.f);
    return wav;
}

void YTMUSingPlaybackTick(void) {
    if (!sTrack && !YTMUSingStreamIsActive()) return;
    YTMUVocalSeparationManager *mgr = [YTMUVocalSeparationManager sharedInstance];
    NSString *vid = g_currentVideoID;
    NSString *path = mgr.isSingEnabled ? YTMUSingPreparedAudio(vid) : nil;
    NSInteger mode = mgr.selectedMode;
    if (!path || ![sTrack isEqualToString:path] || sMode != mode) {
        if (sTrack || path) {
            YTMUReleaseStem();
            sGeneration++; sRetryAfter = 0;
            sWindows = [NSMutableDictionary dictionary];
            sTrack = path; sMode = mode;
            YTMUSingStatus(path ? @"Input selected" : @"Original restored", g_currentPlaybackTime, 0);
        }
        if (!path) return;
    }
    double yt = [g_activePlayer respondsToSelector:@selector(currentVideoMediaTime)] ? [g_activePlayer currentVideoMediaTime] : g_currentPlaybackTime;
    double duration = [g_activePlayer respondsToSelector:@selector(currentVideoTotalMediaTime)] ? [g_activePlayer currentVideoTotalMediaTime] : 0.;
    AVPlayer *match = nil;
    for (AVPlayer *p in sPlayers) {
        if (!p.currentItem || p.currentItem.status != AVPlayerItemStatusReadyToPlay || p.timeControlStatus != AVPlayerTimeControlStatusPlaying || p.rate <= 0) continue;
        double pos = CMTimeGetSeconds(p.currentTime);
        double itemDuration = CMTimeGetSeconds(p.currentItem.duration);
        if (duration > 0 && isfinite(itemDuration) && fabs(itemDuration-duration)>2.) continue;
        if (!isfinite(pos) || !isfinite(yt) || fabs(pos-yt) > 0.65) continue;
        if (match) { match = nil; break; }
        match = p;
    }
    if (match != sOriginal || !match) YTMUReleaseStem();
    if (!match || (match.muted && match != sOriginal)) { YTMUSingStatus(@"Waiting for matching playing AVPlayer", yt, 0); return; }
    double t = MAX(0., CMTimeGetSeconds(match.currentTime));
    NSInteger index = (NSInteger)floor(t * YTMUMDXSampleRate / YTMUMDXWindowFrames);
    double offset = t - (double)index * YTMUMDXWindowFrames / YTMUMDXSampleRate;
    for (NSNumber *key in sWindows.allKeys) if (key.integerValue < index || key.integerValue > index+1) [sWindows removeObjectForKey:key];
    NSData *wav = sWindows[@(index)];
    NSInteger target = wav ? index+1 : index;
    if (!sWindows[@(target)] && !sRendering && CACurrentMediaTime() >= sRetryAfter) {
        sRendering = YES;
        NSUInteger generation = sGeneration;
        YTMUMDXSeparator *separator = mgr.separator;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
            NSError *err = nil;
            NSData *data = YTMURenderWindow(path,target,mode,separator,&err);
            dispatch_async(dispatch_get_main_queue(), ^{
                sRendering = NO;
                if (generation != sGeneration) return;
                if (data) sWindows[@(target)] = data;
                else {
                    sRetryAfter = CACurrentMediaTime()+3;
                    YTMUDebugDeviceNoteLog(@"sing", [NSString stringWithFormat:@"Window %ld unavailable code=%ld", (long)target, (long)err.code]);
                }
            });
        });
    }
    if (!wav) { YTMUReleaseStem(); YTMUSingStatus(@"Waiting for separated audio", t, 0); return; }
    if (index != sPlayingWindow || !sStem.isPlaying) {
        YTMUReleaseStem();
        NSError *err = nil;
        AVAudioPlayer *audio = [[AVAudioPlayer alloc] initWithData:wav error:&err];
        if (!audio || offset >= audio.duration) { YTMUSingStatus(@"Stem window unavailable", t, 0); return; }
        audio.enableRate = YES; audio.rate = match.rate; audio.volume = match.volume;
        audio.currentTime = offset;
        if (![audio play]) { YTMUSingStatus(@"Stem start failed", t, 0); return; }
        sOriginal = match; sPreviousMute = match.muted; match.muted = YES;
        sStem = audio; sPlayingWindow = index;
        YTMUSingStatus(@"Stem playing; original muted", t, 0);
    } else {
        double drift = sStem.currentTime-offset;
        if (fabs(drift)>0.12) { sStem.currentTime = offset; YTMUSingStatus(@"Stem realigned", t, drift); }
        if (sStem.rate != match.rate) sStem.rate = match.rate;
        sStem.volume = match.volume;
    }
}

static NSString *YTMUClassName(id object) {
    return object ? NSStringFromClass([object class]) : @"(none)";
}

static void YTMURecordSingPlayer(AVPlayer *player, NSString *event) {
    if (!player || !event.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!sPlayers) sPlayers = [NSHashTable weakObjectsHashTable];
        [sPlayers addObject:player];
        YTMUVocalSeparationManager *manager = [YTMUVocalSeparationManager sharedInstance];
        if (!YTMUSingUnlocked() || manager.selectedMode == YTMUVocalSeparationModeNormal) return;

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
        NSData *payloadData = [NSJSONSerialization dataWithJSONObject:details options:0 error:nil];
        NSString *payloadText = payloadData ? [[NSString alloc] initWithData:payloadData encoding:NSUTF8StringEncoding] : @"{}";
        // The owner-debug uploader drops [YTMU...] lines to avoid recursively
        // uploading its own diagnostics, so keep this user-facing probe line
        // outside that reserved prefix while retaining the manual opt-in gate.
        NSString *debugLine = [NSString stringWithFormat:@"Sing player probe: %@ payload=%@", message, payloadText];
        NSLog(@"%@", debugLine);
        // The general /log uploader is intentionally Off by default. Route
        // this single, low-volume discovery event through the existing paired
        // owner-debug capture too; that channel still enforces its own opt-in,
        // pairing token, budget, and line cap before sending anything.
        YTMUDebugDeviceNoteLog(@"sing-player-path", debugLine);
        sendDebugLogWithPayload(@"sing-player-path", message, details);
    });
}

%hook AVPlayer
- (void)setRate:(float)rate {
    %orig;
    if (rate > 0) YTMURecordSingPlayer(self, @"rate");
}
- (void)playImmediatelyAtRate:(float)rate {
    %orig;
    YTMURecordSingPlayer(self, @"play-immediately");
}
- (void)replaceCurrentItemWithPlayerItem:(AVPlayerItem *)item {
    %orig;
    YTMURecordSingPlayer(self, @"replace-current-item");
}

- (void)play {
    %orig;
    YTMURecordSingPlayer(self, @"play");
}
%end
