#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "FFMpegDownloader.h"
#import "Headers/YTUIResources.h"
#import "Headers/YTMActionSheetController.h"
#import "Headers/YTMActionRowView.h"
#import "Headers/YTIPlayerOverlayRenderer.h"
#import "Headers/YTIPlayerOverlayActionSupportedRenderers.h"
#import "Headers/YTMNowPlayingViewController.h"
#import "Headers/YTPlayerView.h"
#import "Headers/YTIThumbnailDetails_Thumbnail.h"
#import "Headers/YTIFormatStream.h"
#import "Headers/YTAlertView.h"
#import "Headers/ELMNodeController.h"

static BOOL YTMU(NSString *key) {
    NSDictionary *YTMUltimateDict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    return [YTMUltimateDict[key] boolValue];
}

// THE DOWNLOAD-BADGE CRASH: -[YTPlayerViewController playerResponse]
// unrecognized selector. The header declares the property, but the runtime
// class has to actually implement it -- a YT build where the ivar/property
// was renamed or moved makes the plain `playerVC.playerResponse` read a
// guaranteed crash, on the badge tap path the user most often reaches.
// readOnly: ask the runtime first, catch whatever survives that.
static YTPlayerResponse *YTMUPlayerResponseSafe(YTPlayerViewController *vc) {
    if (!vc || ![vc respondsToSelector:@selector(playerResponse)]) return nil;
    @try {
        return vc.playerResponse;
    } @catch (NSException *e) {
        return nil;
    }
}

@interface UIView ()
- (UIViewController *)_viewControllerForAncestor;
@end

@interface ELMTouchCommandPropertiesHandler : NSObject
- (void)downloadAudio:(YTPlayerViewController *)playerResponse;
- (void)downloadCoverImage:(YTPlayerViewController *)playerResponse;
- (NSString *)getURLFromManifest:(NSURL *)manifest;
@end

%hook ELMTouchCommandPropertiesHandler
- (void)handleTap {

    if (class_getInstanceVariable([self class], "_controller") == NULL) {
        return %orig;
    }


    if (class_getInstanceVariable([self class], "_tapRecognizer") == NULL) {
        return %orig;
    }

    ELMNodeController *node = [self valueForKey:@"_controller"];
    UIGestureRecognizer *tapRecognizer = [self valueForKey:@"_tapRecognizer"];

    if (![node.key isEqualToString:@"music_download_badge_1"]) {
        return %orig;
    }

    if (![tapRecognizer.view._viewControllerForAncestor isKindOfClass:%c(YTMNowPlayingViewController)]) {
        return %orig;
    }

    YTMNowPlayingViewController *playingVC = (YTMNowPlayingViewController *)tapRecognizer.view._viewControllerForAncestor;
    // Type-check the parent instead of blind-casting: a container YT built
    // above the now-playing VC must not be treated as the watch VC just
    // because the ivar layout happens to decode.
    UIViewController *parent = playingVC.parentViewController;
    if (![parent isKindOfClass:%c(YTMWatchViewController)]) {
        return %orig;
    }
    YTMWatchViewController *watchVC = (YTMWatchViewController *)parent;
    YTPlayerViewController *playerVC = watchVC.playerViewController;
    YTPlayerResponse *playerResponse = YTMUPlayerResponseSafe(playerVC);

    if (playerResponse) {
        YTMActionSheetController *sheetController = [%c(YTMActionSheetController) musicActionSheetController];
        sheetController.sourceView = tapRecognizer.view;
        [sheetController addHeaderWithTitle:LOC(@"SELECT_ACTION") subtitle:nil];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"DOWNLOAD_AUDIO") iconImage:[%c(YTUIResources) audioOutline] style:0 handler:^ {
            [self downloadAudio:playerVC];
        }]];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"DOWNLOAD_COVER") iconImage:[%c(YTUIResources) outlineImageWithColor:[UIColor whiteColor]] style:0 handler:^ {
            [self downloadCoverImage:playerVC];
        }]];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"DOWNLOAD_PREMIUM") iconImage:[%c(YTUIResources) downloadOutline] secondaryIconImage:[%c(YTUIResources) youtubePremiumBadgeLight] accessibilityIdentifier:nil handler:^ {
            return %orig;
        }]];

        if (YTMU(@"downloadAudio") && YTMU(@"downloadCoverImage")) {
            [sheetController presentFromViewController:playingVC animated:YES completion:nil];
        } else if (YTMU(@"downloadAudio")) {
            [self downloadAudio:playerVC];
        } else if (YTMU(@"downloadCoverImage")) {
            [self downloadCoverImage:playerVC];
        }
    } else {
        YTAlertView *alertView = [%c(YTAlertView) infoDialog];
        alertView.title = LOC(@"DONT_RUSH");
        alertView.subtitle = LOC(@"DONT_RUSH_DESC");
        [alertView show];
    }
}

%new
- (void)downloadAudio:(YTPlayerViewController *)playerVC {
    YTPlayerResponse *playerResponse = YTMUPlayerResponseSafe(playerVC);
    YTIPlayerResponse *data = [playerResponse respondsToSelector:@selector(playerData)] ? playerResponse.playerData : nil;

    if (!playerResponse || !data) {
        YTAlertView *alertView = [%c(YTAlertView) infoDialog];
        alertView.title = LOC(@"OOPS");
        alertView.subtitle = LOC(@"DONT_RUSH_DESC");
        [alertView show];
        return;
    }

    NSString *title = [playerResponse.playerData.videoDetails.title stringByReplacingOccurrencesOfString:@"/" withString:@""];
    NSString *author = [playerResponse.playerData.videoDetails.author stringByReplacingOccurrencesOfString:@"/" withString:@""];
    NSString *urlStr = playerResponse.playerData.streamingData.hlsManifestURL;

    FFMpegDownloader *ffmpeg = [[FFMpegDownloader alloc] init];
    ffmpeg.tempName = playerVC.contentVideoID;
    ffmpeg.mediaName = [NSString stringWithFormat:@"%@ - %@", author, title];
    ffmpeg.duration = round(playerVC.currentVideoTotalMediaTime);

    
    NSString *extractedURL = [self getURLFromManifest:[NSURL URLWithString:urlStr]];
    
    if (extractedURL.length > 0) {
        [ffmpeg downloadAudio:extractedURL];

        NSMutableArray *thumbnailsArray = playerResponse.playerData.videoDetails.thumbnail.thumbnailsArray;
        YTIThumbnailDetails_Thumbnail *thumbnail = [thumbnailsArray lastObject];
        NSData *imageData = [NSData dataWithContentsOfURL:[NSURL URLWithString:thumbnail.URL]];

        if (imageData) {
            NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
            NSURL *coverURL = [documentsURL URLByAppendingPathComponent:[NSString stringWithFormat:@"YTMusicUltimate/%@ - %@.png", author, title]];
            [imageData writeToURL:coverURL atomically:YES];
        }
    } else {
        YTAlertView *alertView = [%c(YTAlertView) infoDialog];
        alertView.title = LOC(@"OOPS");
        alertView.subtitle = LOC(@"LINK_NOT_FOUND");
        [alertView show];
    }
}

%new
- (NSString *)getURLFromManifest:(NSURL *)manifest {
    if (!manifest) return nil;  // dataWithContentsOfURL: is nonnull-annotated; a nil manifest must not reach it
    NSData *manifestData = [NSData dataWithContentsOfURL:manifest];
    NSString *manifestString = [[NSString alloc] initWithData:manifestData encoding:NSUTF8StringEncoding];
    NSArray *manifestLines = [manifestString componentsSeparatedByString:@"\n"];

    NSArray *groupIDS = @[@"234", @"233"]; // Our priority to find group id 234
    for (NSString *groupID in groupIDS) {
        for (NSString *line in manifestLines) {
            NSString *searchString = [NSString stringWithFormat:@"TYPE=AUDIO,GROUP-ID=\"%@\"", groupID];
            if ([line containsString:searchString]) {
                NSRange startRange = [line rangeOfString:@"https://"];
                NSRange endRange = [line rangeOfString:@"index.m3u8"];

                if (startRange.location != NSNotFound && endRange.location != NSNotFound) {
                    NSRange targetRange = NSMakeRange(startRange.location, NSMaxRange(endRange) - startRange.location);
                    return [line substringWithRange:targetRange];
                }
            }
        }
    }

    return nil;
}

%new
- (void)downloadCoverImage:(YTPlayerViewController *)playerVC {
    MBProgressHUD *hud = [MBProgressHUD showHUDAddedTo:[UIApplication sharedApplication].keyWindow animated:YES];
    dispatch_async(dispatch_get_main_queue(), ^{
        hud.mode = MBProgressHUDModeIndeterminate;
    });

    YTPlayerResponse *playerResponse = YTMUPlayerResponseSafe(playerVC);

    NSMutableArray *thumbnailsArray = [playerResponse respondsToSelector:@selector(playerData)] ? playerResponse.playerData.videoDetails.thumbnail.thumbnailsArray : nil;
    if (!thumbnailsArray.count) {
        [MBProgressHUD hideHUDForView:[UIApplication sharedApplication].keyWindow animated:YES];
        YTAlertView *alertView = [%c(YTAlertView) infoDialog];
        alertView.title = LOC(@"OOPS");
        alertView.subtitle = LOC(@"DONT_RUSH_DESC");
        [alertView show];
        return;
    }
    YTIThumbnailDetails_Thumbnail *thumbnail = [thumbnailsArray lastObject];
    NSString *thumbnailURL = [thumbnail.URL stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"w%u-h%u-", thumbnail.width, thumbnail.width] withString:@"w2048-h2048-"];

    FFMpegDownloader *ffmpeg = [[FFMpegDownloader alloc] init];
    [ffmpeg downloadImage:[NSURL URLWithString:thumbnailURL]];

    dispatch_async(dispatch_get_main_queue(), ^{
        [hud hideAnimated:YES];
    });
}
%end
