#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
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
#import "LyricsShared.h"

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

// Same reasoning for the two plain reads the old code did unguarded.
static NSString *YTMUPlayerVideoIDSafe(YTPlayerViewController *vc) {
    if (!vc) return nil;
    @try {
        if ([vc respondsToSelector:@selector(contentVideoID)]) return [vc contentVideoID];
        if ([vc respondsToSelector:@selector(currentVideoID)]) return [vc currentVideoID];
    } @catch (NSException *e) {
    }
    return nil;
}

static NSInteger YTMUPlayerDurationSafe(YTPlayerViewController *vc) {
    if (!vc || ![vc respondsToSelector:@selector(currentVideoTotalMediaTime)]) return 0;
    @try {
        return (NSInteger)lround([vc currentVideoTotalMediaTime]);
    } @catch (NSException *e) {
        return 0;
    }
}

// ---------------------------------------------------------------------------
// CAPTURED PLAYBACK STREAMS -- there is no yt-dlp here on purpose.
//
// yt-dlp cannot run in this process (iOS forbids fork/exec, and there is no
// CPython to embed), and the server-side alternative would need the user's
// cookies. It is also unnecessary: the app has ALREADY resolved the audio
// stream for the song it is playing -- that is where the sound comes from --
// so the only thing missing was a look at it. Every googlevideo audio URL that
// crosses NSURLSession / AVURLAsset is kept here, keyed by video id, and
// ffmpeg copies it to a file.
//
// The URL as the app sends it addresses ONE DASH chunk (rn=/sq=/range=).
// Dropping those three params makes the same URL serve the whole track, which
// is exactly what "-i <url> -c copy track.m4a" needs.
// ---------------------------------------------------------------------------

static NSMutableDictionary *YTMUStreamStore(void) {
    static NSMutableDictionary *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ store = [NSMutableDictionary dictionary]; });
    return store;
}

static NSString *YTMUQueryParam(NSString *query, NSString *key) {
    if (!query.length || !key.length) return nil;
    for (NSString *pair in [query componentsSeparatedByString:@"&"]) {
        NSRange eq = [pair rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        if ([[pair substringToIndex:eq.location] isEqualToString:key]) {
            return [pair substringFromIndex:eq.location + 1];
        }
    }
    return nil;
}

static NSString *YTMUCleanStreamURL(NSString *raw) {
    if (!raw.length) return nil;
    NSMutableArray *keep = [NSMutableArray array];
    for (NSString *pair in [raw componentsSeparatedByString:@"&"]) {
        if (!pair.length) continue;
        NSRange eq = [pair rangeOfString:@"="];
        NSString *key = (eq.location == NSNotFound) ? pair : [pair substringToIndex:eq.location];
        if ([key isEqualToString:@"rn"] || [key isEqualToString:@"sq"] || [key isEqualToString:@"range"]) continue;
        [keep addObject:pair];
    }
    return [keep componentsJoinedByString:@"&"];
}

void YTMUDownloadCaptureStreamURL(NSURL *url) {
    if (!url) return;
    NSString *full = url.absoluteString;
    if (!full.length) return;
    NSString *host = url.host;
    if (![host containsString:@"googlevideo.com"]) return;
    // Audio only. A video URL here would copy a video track into an .m4a, and
    // YT Music does fetch video mime types for the cover art / mini player.
    if (![full containsString:@"mime=audio"]) return;
    NSString *videoID = YTMUQueryParam(full, @"id") ?: YTMUQueryParam(full, @"v");
    NSMutableDictionary *store = YTMUStreamStore();
    @synchronized(store) {
        if (videoID.length) store[videoID] = full;
        store[@"*"] = full;   // newest audio URL seen, whatever song it was
    }
    NSLog(@"[YTMU-DL] captured audio stream vid=%@ host=%@", videoID.length ? videoID : @"?", host);
}

// The song's own URL, else the last one seen: a queue that has already
// preloaded the next track resolves it before the badge is ever tapped.
static NSString *YTMUCapturedStreamURL(NSString *videoID) {
    NSMutableDictionary *store = YTMUStreamStore();
    @synchronized(store) {
        NSString *url = videoID.length ? store[videoID] : nil;
        return url.length ? url : store[@"*"];
    }
}

@interface UIView ()
- (UIViewController *)_viewControllerForAncestor;
@end

// LyricsShared.h already declares this class (and -handleTap), so a second
// full @interface for it is a duplicate-definition error now that the header is
// imported here. The %new helpers only need a declaration, so they live in a
// category -- same shape LyricsShared.h uses for SponsorBlock's %new methods.
@interface ELMTouchCommandPropertiesHandler (YTMUDownload)
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

    // playerResponse is no longer REQUIRED. The audio URL the app resolved for
    // the song it is playing is enough, and the cover action (the only thing
    // that truly needs the response) simply is not offered without it.
    NSString *captured = YTMUCapturedStreamURL(g_currentVideoID);
    if (!playerResponse && !captured.length) {
        YTAlertView *alertView = [%c(YTAlertView) infoDialog];
        alertView.title = LOC(@"DONT_RUSH");
        alertView.subtitle = LOC(@"DONT_RUSH_DESC");
        [alertView show];
        return;
    }

    if (playerResponse && YTMU(@"downloadAudio") && YTMU(@"downloadCoverImage")) {
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

        [sheetController presentFromViewController:playingVC animated:YES completion:nil];
        return;
    }

    if (YTMU(@"downloadAudio")) {
        [self downloadAudio:playerVC];
        return;
    }
    if (playerResponse && YTMU(@"downloadCoverImage")) {
        [self downloadCoverImage:playerVC];
    }
}

%new
- (void)downloadAudio:(YTPlayerViewController *)playerVC {
    YTPlayerResponse *playerResponse = YTMUPlayerResponseSafe(playerVC);
    YTIPlayerResponse *data = (playerResponse && [playerResponse respondsToSelector:@selector(playerData)])
        ? playerResponse.playerData : nil;
    YTIVideoDetails *details = (data && [data respondsToSelector:@selector(videoDetails)])
        ? data.videoDetails : nil;

    NSString *title = details ? [details.title stringByReplacingOccurrencesOfString:@"/" withString:@""] : nil;
    NSString *author = details ? [details.author stringByReplacingOccurrencesOfString:@"/" withString:@""] : nil;

    // 1) the stream the app itself resolved and is downloading right now
    NSString *urlStr = YTMUCapturedStreamURL(g_currentVideoID);
    if (urlStr.length) {
        urlStr = YTMUCleanStreamURL(urlStr);
    } else if (data && [data respondsToSelector:@selector(streamingData)]) {
        // 2) legacy HLS manifest out of playerResponse, kept for a YT build
        //    where nothing was captured. Reached only when the property still
        //    exists; a build without it never gets past YTMUPlayerResponseSafe.
        NSString *manifest = data.streamingData.hlsManifestURL;
        if (manifest.length) urlStr = [self getURLFromManifest:[NSURL URLWithString:manifest]];
    }

    if (!urlStr.length) {
        YTAlertView *alertView = [%c(YTAlertView) infoDialog];
        alertView.title = LOC(@"DONT_RUSH");
        alertView.subtitle = LOC(@"DONT_RUSH_DESC");
        [alertView show];
        return;
    }

    NSString *videoID = g_currentVideoID.length ? g_currentVideoID : YTMUPlayerVideoIDSafe(playerVC);
    NSString *name = (author.length && title.length)
        ? [NSString stringWithFormat:@"%@ - %@", author, title]
        : (videoID.length ? videoID : LOC(@"DOWNLOAD_AUDIO"));

    FFMpegDownloader *ffmpeg = [[FFMpegDownloader alloc] init];
    ffmpeg.tempName = videoID.length ? videoID : @"track";
    ffmpeg.mediaName = name;
    ffmpeg.duration = YTMUPlayerDurationSafe(playerVC);
    [ffmpeg downloadAudio:urlStr];

    // Cover: needs the player response for both the names and the thumbnails,
    // so a capture-only download just leaves it out.
    if (!(author.length && title.length)) return;
    NSMutableArray *thumbnailsArray = details.thumbnail.thumbnailsArray;
    YTIThumbnailDetails_Thumbnail *thumbnail = [thumbnailsArray lastObject];
    NSData *imageData = thumbnail.URL.length ? [NSData dataWithContentsOfURL:[NSURL URLWithString:thumbnail.URL]] : nil;
    if (imageData) {
        NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
        NSURL *coverURL = [documentsURL URLByAppendingPathComponent:[NSString stringWithFormat:@"YTMusicUltimate/%@ - %@.png", author, title]];
        [imageData writeToURL:coverURL atomically:YES];
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
    dispatch_async(dispatch_get_main_queue(), ^{\
        hud.mode = MBProgressHUDModeIndeterminate;\
    });

    YTPlayerResponse *playerResponse = YTMUPlayerResponseSafe(playerVC);

    NSMutableArray *thumbnailsArray = (playerResponse && [playerResponse respondsToSelector:@selector(playerData)])
        ? playerResponse.playerData.videoDetails.thumbnail.thumbnailsArray : nil;
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

    dispatch_async(dispatch_get_main_queue(), ^{\
        [hud hideAnimated:YES];\
    });
}
%end

// The transport layer of the app's media pipeline. NSURLSession is the one
// every AVPlayer path ends in even when the demuxer is custom, and AVURLAsset
// catches a stack that hands the URL straight to AVFoundation.
//
// This is the ONLY place the transport is hooked: the download capture above
// and the debug device capture (Source/DebugDeviceMode.x, a buffer that only
// exists once a device is paired) both read from here. A second file hooking
// the same selectors would be two chained replacements where one is enough,
// and the download capture has to run whether or not debug mode is on.
static void YTMUTransportNote(NSURL *url, NSString *method) {
    YTMUDownloadCaptureStreamURL(url);
    YTMUDebugDeviceNoteRequest(url, method);
}

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    YTMUTransportNote(request.URL, request.HTTPMethod);
    return %orig;
}
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    YTMUTransportNote(request.URL, request.HTTPMethod);
    return %orig;
}
- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url {
    YTMUTransportNote(url, @"GET");
    return %orig;
}
- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    YTMUTransportNote(url, @"GET");
    return %orig;
}
%end

%hook AVURLAsset
- (instancetype)initWithURL:(NSURL *)URL options:(NSDictionary<NSString *, id> *)options {
    YTMUTransportNote(URL, @"ASSET");
    return %orig;
}
%end
