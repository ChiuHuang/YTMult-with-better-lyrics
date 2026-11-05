#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
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
// so the only thing missing was a look at it. Two layers deliver that look:
// the transport hooks below (NSURLSession / AVURLAsset) for what little still
// crosses them, and the response hooks further down this file, which read the
// URL out of the YTPlayerResponse the watch VC holds while a song plays. Every
// googlevideo audio URL is kept here, keyed by video id, and ffmpeg copies it.
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

// ---------------------------------------------------------------------------
// RUNTIME PROBE. The capture file (devfecab41d, 300 records over two days)
// settled the assumption this capture was built on: youtubei API calls,
// thumbnails and watchtime stats all cross NSURLSession, but a googlevideo
// media URL NEVER does -- the app's media stack speaks through its own
// transport, invisible to the hooks above. The next hook target is therefore
// whatever private session the player really uses, and the runtime is the one
// that knows its name. One probe per badge tap when the capture came up
// empty: the member names of the player/watch/now-playing classes (keyword
// filtered) plus which ivars are populated with which class. Uploaded through
// the paired debug channel (YTMUDebugDeviceNoteProbe), so only an enrolled
// device can ask for -- or receive -- this.
// ---------------------------------------------------------------------------

static BOOL YTMUProbeKeyword(NSString *name) {
    if (!name.length) return NO;
    static NSArray *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[@"respon", @"stream", @"format", @"media", @"manifest",
                 @"url", @"URL", @"egment", @"layback", @"ata"];
    });
    for (NSString *key in keys) {
        if ([name containsString:key]) return YES;
    }
    return NO;
}

static void YTMUDebugProbeAddClass(NSMutableDictionary *payload, Class startCls,
                                   id instance, NSString *label, NSMutableSet *seen) {
    for (Class cls = startCls; cls; cls = class_getSuperclass(cls)) {
        if (cls == [NSObject class]) break;
        NSString *clsName = NSStringFromClass(cls);
        if (!clsName.length || [seen containsObject:clsName]) return;
        [seen addObject:clsName];

        NSMutableArray *lines = [NSMutableArray array];
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            NSString *sel = NSStringFromSelector(method_getName(methods[i]));
            if (YTMUProbeKeyword(sel)) [lines addObject:[@"m: " stringByAppendingString:sel]];
        }
        free(methods);
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *cname = ivar_getName(ivars[i]);
            NSString *name = cname ? [NSString stringWithUTF8String:cname] : nil;
            if (!name.length) continue;
            const char *tenc = ivar_getTypeEncoding(ivars[i]);
            NSString *type = (tenc && tenc[0]) ? [NSString stringWithUTF8String:tenc] : @"?";
            NSString *line = [NSString stringWithFormat:@"i: %@ (%@)", name, type];
            // Object-typed ivars are safe to READ on a live instance (gated on
            // the encoding's leading '@'), and the class of the value is the
            // one bit we actually need: is there a response object at all, and
            // under which name its records live in THIS build.
            if (instance && [type hasPrefix:@"@"]) {
                @try {
                    id value = object_getIvar(instance, ivars[i]);
                    line = [line stringByAppendingFormat:@" = %@",
                            value ? NSStringFromClass([value class]) : @"nil"];
                } @catch (NSException *e) {
                    line = [line stringByAppendingString:@" = <refused>"];
                }
            }
            [lines addObject:line];
        }
        free(ivars);
        payload[label] = @{@"cls": clsName, @"items": [lines copy]};
        label = [label stringByAppendingString:@"^"];
    }
}


// ---------------------------------------------------------------------------
// SECOND CAPTURE LAYER -- the runtime object, not the transport.
//
// The runtime probe settled where the app actually keeps the resolved stream:
// YTMWatchViewController._currentPlayerResponse is a live YTPlayerResponse
// while a song plays, the delegate callbacks
// -playbackControllerDidActivateVideo:withPlayerResponse: and
// -playbackControllerDidLoadPlayerWithPlaybackData: hand that response over
// once per song load, and the RESPONSE carries the media URLs the transport
// never speaks: playerData.streamingData.adaptiveFormatsArray is one
// YTIFormatStream (URL:) per itag, and hlsManifestURL the legacy HLS playlist
// the sheet code already knew how to parse.
//
// YTMUPlayerResponseSafe exists because a property can vanish between builds,
// and the probe dump had also proven THIS build's player VC answers a
// playerResponse read with an unrecognized-selector crash. Every step here
// teaches the same lesson twice: respondsToSelector first, ivar scan second,
// matching by the CLASS of the value so a renamed property still finds its
// object.
// ---------------------------------------------------------------------------

typedef BOOL (^YTMUIvarPredicate)(id value);

// The first object-typed ivar found on the instance (walking up the hierarchy)
// whose value passes the predicate. Reading a live object's object ivars is
// safe; the @catch is only there for a wild ivar the encoding got wrong.
static id YTMUFirstIvarValue(id obj, YTMUIvarPredicate match) {
    if (!obj) return nil;
    for (Class cls = object_getClass(obj); cls; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *tenc = ivar_getTypeEncoding(ivars[i]);
            if (!tenc || tenc[0] != '@') continue;
            @try {
                id value = object_getIvar(obj, ivars[i]);
                if (value && match(value)) return value;
            } @catch (NSException *e) {
            }
        }
        free(ivars);
    }
    return nil;
}

// The property if it answers, else what the ivar scan finds. The getter path
// goes through objc_msgSend directly: performSelector with a runtime-chosen
// selector trips the ARC leak warning, and -Werror is on.
static id YTMUGetterOrValue(id obj, SEL getter, YTMUIvarPredicate match) {
    if (!obj) return nil;
    if (getter && [obj respondsToSelector:getter]) {
        @try {
            id value = ((id (*)(id, SEL))objc_msgSend)(obj, getter);
            if (value) return value;
        } @catch (NSException *e) {
        }
    }
    return YTMUFirstIvarValue(obj, match);
}

static id YTMUResponseData(id response) {
    return YTMUGetterOrValue(response, @selector(playerData),
        ^BOOL (id v) { return [v isKindOfClass:%c(YTIPlayerResponse)]; });
}

static id YTMUStreamingDataFrom(id data) {
    return YTMUGetterOrValue(data, @selector(streamingData),
        ^BOOL (id v) { return [v isKindOfClass:%c(YTIStreamingData)]; });
}

static NSArray *YTMUAdaptiveFormatsFrom(id streaming) {
    if (!streaming) return nil;
    if ([streaming respondsToSelector:@selector(adaptiveFormatsArray)]) {
        @try {
            id arr = ((id (*)(id, SEL))objc_msgSend)(streaming, @selector(adaptiveFormatsArray));
            if ([arr isKindOfClass:[NSArray class]]) return arr;
        } @catch (NSException *e) {
        }
    }
    return YTMUFirstIvarValue(streaming, ^BOOL (id v) { return [v isKindOfClass:[NSArray class]]; });
}

static NSString *YTMUAudioURLFromManifest(NSURL *manifest) {
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

// The best audio URL out of a streamingData object: itag 140 (m4a 128k) when
// the format list carries it, else the first mime=audio entry, else the HLS
// playlist parsed the legacy way. Same host filter as the transport capture --
// a response-holding object may carry URLs other than googlevideo.
static NSString *YTMUAudioURLFromStreaming(id streaming) {
    if (!streaming) return nil;
    NSString *best = nil, *any = nil;
    for (id fmt in YTMUAdaptiveFormatsFrom(streaming)) {
        if (![fmt respondsToSelector:@selector(URL)]) continue;
        NSString *uStr = ((NSString *(*)(id, SEL))objc_msgSend)(fmt, @selector(URL));
        if (![uStr isKindOfClass:[NSString class]]) continue;
        NSURL *u = [NSURL URLWithString:uStr];
        if (!u || ![u.host containsString:@"googlevideo.com"]) continue;
        if (![uStr containsString:@"mime=audio"]) continue;
        if (!any) any = uStr;
        if (!best && [uStr containsString:@"itag=140"]) best = uStr;
        if (best) break;
    }
    if (best) return best;
    if (any) return any;

    NSString *manifest = nil;
    if ([streaming respondsToSelector:@selector(hlsManifestURL)]) {
        @try {
            manifest = ((NSString *(*)(id, SEL))objc_msgSend)(streaming, @selector(hlsManifestURL));
        } @catch (NSException *e) {
        }
    }
    if (manifest.length) {
        NSString *parsed = YTMUAudioURLFromManifest([NSURL URLWithString:manifest]);
        if (parsed.length) return parsed;
    }
    return nil;
}

// When a response arrives and yields no audio URL, that miss is the
// information: one drill-down probe per video+class (never a stream) records
// what each level actually looks like in THIS build, so the next extraction
// change is decided on data, not hope.
static void YTMUDebugNoteResponseProbe(id response, NSString *vid) {
    if (!response) return;
    static NSMutableSet *noted;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ noted = [NSMutableSet set]; });
    NSString *key = [NSString stringWithFormat:@"%@|%@", vid ?: @"", NSStringFromClass([response class])];
    @synchronized(noted) {
        if ([noted containsObject:key]) return;
        [noted addObject:key];
    }
    @try {
        id data = YTMUResponseData(response);
        id streaming = YTMUStreamingDataFrom(data);
        NSArray *fmts = YTMUAdaptiveFormatsFrom(streaming);
        unsigned int fmtCount = 0;
        NSMutableArray *urls = [NSMutableArray array];
        for (id fmt in fmts) {
            fmtCount++;
            if (urls.count >= 3) continue;
            if (![fmt respondsToSelector:@selector(URL)]) continue;
            NSString *uStr = ((NSString *(*)(id, SEL))objc_msgSend)(fmt, @selector(URL));
            if ([uStr isKindOfClass:[NSString class]] && uStr.length) {
                [urls addObject:(uStr.length > 160 ? [uStr substringToIndex:160] : uStr)];
            }
        }
        NSMutableArray *lines = [NSMutableArray array];
        [lines addObject:[NSString stringWithFormat:@"data=%@", data ? NSStringFromClass([data class]) : @"nil"]];
        [lines addObject:[NSString stringWithFormat:@"streaming=%@", streaming ? NSStringFromClass([streaming class]) : @"nil"]];
        [lines addObject:[NSString stringWithFormat:@"fmts=%u", fmtCount]];
        for (NSString *u in urls) [lines addObject:[@"url: " stringByAppendingString:u]];
        YTMUDebugDeviceNoteProbe(@"response-drill", vid, @{
            @"levels": @{@"cls": NSStringFromClass([response class]), @"items": [lines copy]},
        });
        NSLog(@"[YTMU-DL] response yielded no audio stream, drill probe posted (vid=%@)", vid ?: @"?");
    } @catch (NSException *e) {
    }
}

// One shipped record per badge tap: player, watch and now-playing VCs, each
// walking its own hierarchy. Returned strings never contain URLs/data beyond
// names, and only a paired device can receive them.
static void YTMUDebugProbeRuntime(id player, id watch, id nowPlaying, NSString *vid) {
    if (!YTMUDebugDeviceEnabled()) return;
    @try {
        NSMutableDictionary *payload = [NSMutableDictionary dictionary];
        NSMutableSet *seen = [NSMutableSet set];
        YTMUDebugProbeAddClass(payload, player ? [player class] : Nil, player, @"player", seen);
        YTMUDebugProbeAddClass(payload, watch ? [watch class] : Nil, watch, @"watch", seen);
        YTMUDebugProbeAddClass(payload, nowPlaying ? [nowPlaying class] : Nil, nowPlaying, @"now", seen);
        if (!payload.count) return;
        YTMUDebugDeviceNoteProbe(@"player-runtime", vid, payload);
        NSLog(@"[YTMU-DL] runtime probe posted (vid=%@)", vid ?: @"?");
    } @catch (NSException *e) {
        NSLog(@"[YTMU-DL] probe failed: %@", e);
    }
}

// The one place a response is turned into a capture: extract the best audio
// URL, keep it keyed by the video id it belongs to (the URL's own id param
// when the caller had none), and note a drill probe when the response held
// no audio at all.
static void YTMUConsumeResponse(id response, NSString *vid) {
    if (!response) return;
    @try {
        NSString *url = YTMUAudioURLFromStreaming(YTMUStreamingDataFrom(YTMUResponseData(response)));
        if (url.length) {
            NSString *key = vid.length ? vid : YTMUQueryParam(url, @"id");
            NSMutableDictionary *store = YTMUStreamStore();
            @synchronized(store) {
                if (key.length) store[key] = url;
                store[@"*"] = url;
            }
            NSLog(@"[YTMU-DL] captured audio stream from player response vid=%@", key ?: @"?");
        } else {
            YTMUDebugNoteResponseProbe(response, vid);
        }
    } @catch (NSException *e) {
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
- (void)downloadAudio:(YTPlayerViewController *)playerVC response:(YTPlayerResponse *)playerResponse;
- (void)downloadCoverImage:(YTPlayerViewController *)playerVC response:(YTPlayerResponse *)playerResponse;
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
    if (!playerResponse) {
        // This build's player VC has no playerResponse selector (the crash b6697c0
        // was the proof); the watch VC keeps its own -- the runtime probe saw
        // _currentPlayerResponse = YTPlayerResponse, populated. An ivar read
        // cannot raise the way a selector can.
        playerResponse = (YTPlayerResponse *)YTMUFirstIvarValue(watchVC, ^BOOL (id v) {
            return [v isKindOfClass:%c(YTPlayerResponse)];
        });
    }

    // The response hook usually captured before this tap ever happens; when the
    // capture is still empty, one catch-up extraction from the response in hand
    // writes the store without waiting for the next song.
    NSString *captured = YTMUCapturedStreamURL(g_currentVideoID);
    if (!captured.length && playerResponse) {
        YTMUConsumeResponse(playerResponse, g_currentVideoID);
        captured = YTMUCapturedStreamURL(g_currentVideoID);
    }
    if (!playerResponse && !captured.length) {
        // Empty capture is not just "play longer" any more: the capture file
        // proved the media stack never crosses NSURLSession. The miss is the
        // information -- post the runtime probe through the paired debug
        // channel so the next hook target comes from the device, not a guess.
        YTMUDebugProbeRuntime(playerVC, watchVC, playingVC, g_currentVideoID);
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
            [self downloadAudio:playerVC response:playerResponse];
        }]];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"DOWNLOAD_COVER") iconImage:[%c(YTUIResources) outlineImageWithColor:[UIColor whiteColor]] style:0 handler:^ {
            [self downloadCoverImage:playerVC response:playerResponse];
        }]];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"DOWNLOAD_PREMIUM") iconImage:[%c(YTUIResources) downloadOutline] secondaryIconImage:[%c(YTUIResources) youtubePremiumBadgeLight] accessibilityIdentifier:nil handler:^ {
            return %orig;
        }]];

        [sheetController presentFromViewController:playingVC animated:YES completion:nil];
        return;
    }

    if (YTMU(@"downloadAudio")) {
        [self downloadAudio:playerVC response:playerResponse];
        return;
    }
    if (playerResponse && YTMU(@"downloadCoverImage")) {
        [self downloadCoverImage:playerVC response:playerResponse];
    }
}

%new
- (void)downloadAudio:(YTPlayerViewController *)playerVC response:(YTPlayerResponse *)response {
    YTPlayerResponse *playerResponse = response ?: YTMUPlayerResponseSafe(playerVC);
    YTIPlayerResponse *data = YTMUResponseData(playerResponse);
    YTIVideoDetails *details = (data && [data respondsToSelector:@selector(videoDetails)])
        ? data.videoDetails : nil;

    NSString *title = details ? [details.title stringByReplacingOccurrencesOfString:@"/" withString:@""] : nil;
    NSString *author = details ? [details.author stringByReplacingOccurrencesOfString:@"/" withString:@""] : nil;

    // 1) the capture: one of the response hooks or the transport layer usually
    //    stored the URL long before the badge was tapped
    NSString *urlStr = YTMUCapturedStreamURL(g_currentVideoID);
    if (urlStr.length) {
        urlStr = YTMUCleanStreamURL(urlStr);
    } else if (playerResponse) {
        // 2) catch-up: extract straight out of the response in hand
        YTMUConsumeResponse(playerResponse, g_currentVideoID);
        urlStr = YTMUCleanStreamURL(YTMUCapturedStreamURL(g_currentVideoID));
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
- (void)downloadCoverImage:(YTPlayerViewController *)playerVC response:(YTPlayerResponse *)response {
    MBProgressHUD *hud = [MBProgressHUD showHUDAddedTo:[UIApplication sharedApplication].keyWindow animated:YES];
    dispatch_async(dispatch_get_main_queue(), ^{\
        hud.mode = MBProgressHUDModeIndeterminate;\
    });

    YTPlayerResponse *playerResponse = response ?: YTMUPlayerResponseSafe(playerVC);

    YTIPlayerResponse *data = YTMUResponseData(playerResponse);
    YTIVideoDetails *details = (data && [data respondsToSelector:@selector(videoDetails)])
        ? data.videoDetails : nil;
    NSMutableArray *thumbnailsArray = (details && [details respondsToSelector:@selector(thumbnail)])
        ? details.thumbnail.thumbnailsArray : nil;
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

// The response layer, hooked exactly once and in the file that owns the
// capture store: both delegate callbacks land on YTMWatchViewController once
// per song load with the YTIPlayerResponse-shaped data in the second argument.
// %orig runs first -- this hook may never change what the app does with its
// own response.
%hook YTMWatchViewController
- (void)playbackControllerDidActivateVideo:(id)video withPlayerResponse:(id)response {
    %orig;
    YTMUConsumeResponse(response, nil);
}
- (void)playbackControllerDidLoadPlayerWithPlaybackData:(id)playbackData {
    %orig;
    YTMUConsumeResponse(playbackData, nil);
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
