#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import "Headers/Localization.h"
#import "Headers/YTMToastController.h"
#import "Headers/YTPlayerViewController.h"
#import "LyricsShared.h"

#define ytmuBool(key) [[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"][key] boolValue]
#define ytmuInt(key) [[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"][key] integerValue]

// Only a non-music segment sitting at the very head of the video can be
// absorbed by one constant shift: the song then starts at the segment end.
// A mid-song segment needs a piecewise timeline, so those stay untouched.
#define YTMU_INTRO_SEGMENT_MAX_START 5.0

%hook YTPlayerViewController
%property (nonatomic, strong) NSMutableDictionary *sponsorBlockValues;

- (void)playbackController:(id)arg1 didActivateVideo:(id)arg2 withPlaybackData:(id)arg3 {
    %orig;

    if (!ytmuBool(@"sponsorBlock")) return;

    self.sponsorBlockValues = [NSMutableDictionary dictionary];

    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://sponsor.ajay.app/api/skipSegments?videoID=%@&categories=%@", self.currentVideoID, @"%5B%22music_offtopic%22%5D"]]];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error) {
            // The API answers with a list of segment dicts (it was typed
            // NSDictionary * here, which is what the loop below iterates).
            NSArray *jsonResponse = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([NSJSONSerialization isValidJSONObject:jsonResponse]) {
                NSMutableDictionary *segments = [NSMutableDictionary dictionary];
                for (NSDictionary *segmentDict in jsonResponse) {
                    NSString *uuid = segmentDict[@"UUID"];
                    [segments setObject:@(1) forKey:uuid];
                }

                [self.sponsorBlockValues setObject:jsonResponse forKey:self.currentVideoID];
                [self.sponsorBlockValues setObject:segments forKey:@"segments"];

                // Lyrics run on the song's own timeline, so an intro that
                // gets skipped has to be shifted out of the way. Applied as
                // soon as the segment list lands, not only when the skip
                // fires, and reset to 0 when the video has no intro (the
                // list is authoritative, so stale shifts cannot survive).
                [self ytmu_applyLyricsOffsetForVideoID:self.currentVideoID
                                                offset:-[self ytmu_introEndInSegments:jsonResponse]
                                                reason:@"segment list"];
            }
        }
    }] resume];
}

- (void)singleVideo:(id)video currentVideoTimeDidChange:(id)time {
    %orig;

    [self skipSegment];
}

- (void)potentiallyMutatedSingleVideo:(id)video currentVideoTimeDidChange:(id)time {
    %orig;

    [self skipSegment];
}

%new
- (double)ytmu_introEndInSegments:(NSArray *)segments {
    double introEnd = 0.0;
    for (NSDictionary *segmentDict in segments) {
        if (![segmentDict isKindOfClass:[NSDictionary class]]) continue;
        if (![segmentDict[@"category"] isEqual:@"music_offtopic"]) continue;
        NSArray *pair = segmentDict[@"segment"];
        if (![pair isKindOfClass:[NSArray class]] || pair.count < 2) continue;
        double start = [pair[0] doubleValue];
        double end = [pair[1] doubleValue];
        if (start <= YTMU_INTRO_SEGMENT_MAX_START && end > start && end > introEnd) {
            introEnd = end;
        }
    }
    return introEnd;
}

// Store the intro skip as this video's lyrics offset. The lyric loop adds
// it to the playback clock, so -(intro end) makes song time 0 land exactly
// where the seek landed. Manual nudges live under their own key and sum
// with this one. The video id is passed in, not read off self: the skip
// toast can outlive the track it belongs to.
%new
- (void)ytmu_applyLyricsOffsetForVideoID:(NSString *)videoID offset:(double)offset reason:(NSString *)reason {
    if (!videoID.length) return;
    if (offset > 0.0) offset = 0.0;
    if (offset < -900.0) offset = -900.0;
    if (offset != 0.0 && !ytmuBool(@"lyricsSponsorOffset")) offset = 0.0;
    if (YTMULyricsSponsorOffsetForVideoID(videoID) == offset) return;
    YTMULyricsSetSponsorOffsetForVideoID(videoID, offset);
    sendDebugLog([NSString stringWithFormat:@"[SB] lyrics offset %.1fs for %@ (%@)", offset, videoID, reason]);
}

%new
- (void)skipSegment {
    if (ytmuBool(@"sponsorBlock") && [NSJSONSerialization isValidJSONObject:self.sponsorBlockValues]) {
        NSDictionary *sponsorBlockValues = [self.sponsorBlockValues objectForKey:self.currentVideoID];
        NSMutableDictionary *segmentSkipValues = [self.sponsorBlockValues objectForKey:@"segments"];

        for (NSDictionary *jsonDictionary in sponsorBlockValues) {
            NSString *uuid = [jsonDictionary objectForKey:@"UUID"];
            NSNumber *segmentSkipValue = [segmentSkipValues objectForKey:uuid];

            if (segmentSkipValue && [segmentSkipValue isEqual:@(1)]
                && [[jsonDictionary objectForKey:@"category"] isEqual:@"music_offtopic"]
                && self.currentVideoMediaTime >= [[jsonDictionary objectForKey:@"segment"][0] floatValue]
                && self.currentVideoMediaTime <= ([[jsonDictionary objectForKey:@"segment"][1] floatValue] - 1)) {

                [segmentSkipValues setObject:@(0) forKey:uuid];
                [self.sponsorBlockValues setObject:segmentSkipValues forKey:@"segments"];

                double segmentStart = [[jsonDictionary objectForKey:@"segment"][0] floatValue];
                double segmentEnd = [[jsonDictionary objectForKey:@"segment"][1] floatValue];
                NSString *videoID = [self.currentVideoID copy];
                // Mid-song offtopic cannot be folded into one constant
                // shift (see YTMU_INTRO_SEGMENT_MAX_START), so those never
                // touch the lyrics.
                BOOL isIntro = (segmentStart <= YTMU_INTRO_SEGMENT_MAX_START);

                GOOHUDMessageAction *unskipAction = [[%c(GOOHUDMessageAction) alloc] init];
                unskipAction.title = LOC(@"UNSKIP");
                [unskipAction setHandler:^ {
                    [self seekToTime:segmentStart];

                    // Back inside the intro, so the shift goes away with it.
                    [self ytmu_applyLyricsOffsetForVideoID:videoID offset:0 reason:@"unskip"];
                }];
                
                GOOHUDMessageAction *skipAction = [[%c(GOOHUDMessageAction) alloc] init];
                skipAction.title = LOC(@"SKIP");
                [skipAction setHandler:^ {
                    [self seekToTime:segmentEnd];

                    if (isIntro) {
                        [self ytmu_applyLyricsOffsetForVideoID:videoID offset:-segmentEnd reason:@"intro skip"];
                    }

                    [[%c(YTMToastController) alloc] showMessage:LOC(@"SEGMENT_SKIPPED") HUDMessageAction:unskipAction infoType:0 duration:ytmuInt(@"sbDuration")];
                }];

                if (ytmuInt(@"sbSkipMode") == 0) {
                    [self seekToTime:segmentEnd];

                    if (isIntro) {
                        [self ytmu_applyLyricsOffsetForVideoID:videoID offset:-segmentEnd reason:@"intro skip"];
                    }

                    [[%c(YTMToastController) alloc] showMessage:LOC(@"SEGMENT_SKIPPED") HUDMessageAction:unskipAction infoType:0 duration:ytmuInt(@"sbDuration")];
                }

                else {
                    [[%c(YTMToastController) alloc] showMessage:LOC(@"FOUND_SEGMENT") HUDMessageAction:skipAction infoType:0 duration:ytmuInt(@"sbDuration")];
                }
            }
        }
    }
}
%end

%ctor {
    NSMutableDictionary *mutableDict = [NSMutableDictionary dictionaryWithDictionary:[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"]];

    if (mutableDict[@"sbSkipMode"] == nil) {
        [mutableDict setObject:@(0) forKey:@"sbSkipMode"];
    }

    if (mutableDict[@"sbDuration"] == nil) {
        [mutableDict setObject:@(10) forKey:@"sbDuration"];
    }

    // Shift the lyrics by whatever intro gets skipped, so the first line
    // lands on the first second of the song instead of N seconds late.
    if (mutableDict[@"lyricsSponsorOffset"] == nil) {
        [mutableDict setObject:@(YES) forKey:@"lyricsSponsorOffset"];
    }

    [[NSUserDefaults standardUserDefaults] setObject:mutableDict forKey:@"YTMUltimate"];
}