// Streaming lyrics client.
//
// Two halves of the same feature:
//
//  1. YTMULyricsSSEClient reads the server's GET /api/lyrics/stream SSE feed
//     and turns it into callbacks. This is the ONE lyrics route the phone uses:
//     the server races every provider concurrently and pushes `lyrics` each time
//     one beats the current best score (line-synced can land before word-synced,
//     and both land long before the translation finishes), then pushes every
//     translated line as the model writes it. So the panel shows lyrics first,
//     upgrades them while the reader is already looking at them, and fills the
//     translation in live instead of popping it in after ~7s.
//
//     The old route was /api/lyrics/tstream, and the difference is the whole
//     point: tstream ran the provider pipeline to completion and pushed `lyrics`
//     ONCE afterwards. It streamed the translation but had nothing to stream
//     FROM until the race was already over. It and the blocking `?fast=1` probe
//     are both gone from this path.
//
//  2. The typewriter reveal paints the translated row (the line under the
//     lyric) letter by letter at YTMUTypewriterCPS() characters per second.
//     The label always holds the FULL text and a gradient mask grows across
//     it, so the row height never changes mid-reveal -- swapping the string
//     itself would resize rows under the reader's thumb on every frame.
//
// Server contract (server/routes_stream.py, api_lyrics_stream):
//   meta   -> {song, artist, duration, lookup_ms, art, art_maxres}
//   status -> {provider, ok, synced, wbw_lines, score, elapsed_ms} one per
//              provider as it finishes. NOT read here; the Debug page counts
//              events instead. Note this is the race route's shape, not
//              tstream's `{providers: [...]}` -- the race reports each provider
//              the moment it lands because that is the whole point of it.
//   lyrics -> {stage: raw|machine|cached|final, cached: true|false, lyrics,
//              source, synced, providers, ...}
//              `raw` is untranslated and may be replaced by a better provider.
//              `machine` (tstream=0 only) is the Google interim over the same
//              rows. `final`/`cached` are stable and are the only stages the
//              device writes to its on-disk cache or animates.
//   tline  -> {i, row, text, done}   `text` is CUMULATIVE for that row:
//                                      overwrite, never append. done=true
//                                      means the model finished that line.
//   done   -> {ok, source, synced, stages, translated}
#import "LyricsShared.h"

#pragma mark - Diagnostics

// One small shared snapshot of what the streaming path is doing, read by the
// Debug settings page. Written from the stream callbacks (main thread only),
// so the page can poll it without touching the controller.
static NSMutableDictionary *g_streamStatus = nil;

static void YTMUStatusSet(NSString *key, id value) {
    if (!g_streamStatus) g_streamStatus = [NSMutableDictionary dictionary];
    if (value) g_streamStatus[key] = value;
    else [g_streamStatus removeObjectForKey:key];
}

static void YTMUStatusBump(NSString *key) {
    if (!g_streamStatus) g_streamStatus = [NSMutableDictionary dictionary];
    g_streamStatus[key] = @([g_streamStatus[key] integerValue] + 1);
}

NSDictionary *YTMUDebugStreamStatus(void) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSDictionary *status = g_streamStatus;
    if (status) {
        [out addEntriesFromDictionary:status];
    }
    // Live values the page shows next to the recorded ones.
    out[@"cps"] = @(YTMUTypewriterCPS());
    out[@"streamEnabled"] = @(YTMULyricsStreamTranslateEnabled());
    out[@"lang"] = YTMUTargetLang();
    out[@"endpoint"] = YTMUApiBase();
    out[@"nowPlaying"] = g_currentVideoID ?: @"";
    out[@"debugUpload"] = @(YTMUDebugUploadAllowed(@"info"));
    return out;
}

#pragma mark - SSE reader

@interface YTMULyricsSSEClient : NSObject <NSURLSessionDataDelegate>
- (instancetype)initWithURL:(NSURL *)url
                   onEvent:(void (^)(NSString *name, NSDictionary *json))onEvent
                   onError:(void (^)(void))onError
                   onClose:(void (^)(void))onClose;
- (void)cancel;
@end

@implementation YTMULyricsSSEClient {
    NSURLSession *_session;
    NSURLSessionDataTask *_task;
    NSMutableData *_buffer;   // unconsumed bytes
    NSUInteger _consumed;     // bytes of _buffer already scanned
    BOOL _cancelled;
    BOOL _sawFrame;
    void (^_onEvent)(NSString *, NSDictionary *);
    void (^_onError)(void);
    void (^_onClose)(void);
}

- (instancetype)initWithURL:(NSURL *)url
                   onEvent:(void (^)(NSString *, NSDictionary *))onEvent
                   onError:(void (^)(void))onError
                   onClose:(void (^)(void))onClose {
    self = [super init];
    if (!self) return nil;
    _onEvent = [onEvent copy];
    _onError = [onError copy];
    _onClose = [onClose copy];
    _buffer = [NSMutableData data];

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    // SSE has no natural end: the gap between two events can exceed a minute
    // while the model thinks, so only the resource timeout is bounded.
    cfg.timeoutIntervalForRequest = 120.0;
    cfg.timeoutIntervalForResource = 900.0;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 120.0;
    [req setValue:@"text/event-stream" forHTTPHeaderField:@"Accept"];
    [req setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];

    // Serial delegate queue: the frame parser touches _buffer/_consumed, so
    // chunks must be handled one at a time.
    NSOperationQueue *queue = [[NSOperationQueue alloc] init];
    queue.maxConcurrentOperationCount = 1;
    queue.name = @"ytmu.sse";
    _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:queue];
    _task = [_session dataTaskWithRequest:req];
    [_task resume];
    return self;
}

- (void)cancel {
    @synchronized (self) {
        if (_cancelled) return;
        _cancelled = YES;
    }
    [_task cancel];
    [_session invalidateAndCancel];
}

#pragma mark NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    NSInteger code = [(NSHTTPURLResponse *)response statusCode];
    if (code != 200) {
        // Error page, redirect or captive portal: nothing to stream, so let
        // the caller fall back to the blocking JSON fetch.
        [dataTask cancel];
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    if (!data.length) return;
    @synchronized (self) {
        [_buffer appendData:data];
    }
    [self drainBuffer];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    BOOL cancelled;
    @synchronized (self) { cancelled = _cancelled; }
    // A cancelled task is the normal song-change path, not a failure. An error
    // with nothing delivered at all IS a failure: the caller falls back to the
    // blocking fetch so the lyrics still show up.
    //
    // Exactly ONE terminal callback per run: firing both would make the caller
    // start a retry and then immediately cancel that retry (and open a third).
    BOOL failed = (error && !cancelled && !_sawFrame);
    [_session finishTasksAndInvalidate];
    if (failed) {
        if (_onError) {
            void (^handler)(void) = _onError;
            dispatch_async(dispatch_get_main_queue(), ^{ handler(); });
        }
        return;
    }
    if (_onClose) {
        void (^handler)(void) = _onClose;
        dispatch_async(dispatch_get_main_queue(), ^{ handler(); });
    }
}

#pragma mark Frame parsing

// Byte-level on purpose: decoding each chunk as UTF-8 would corrupt a CJK
// character that straddles a chunk boundary, which is exactly what a fast
// token stream produces. Frames are located by their delimiter first and only
// decoded once complete.
- (void)drainBuffer {
    while (YES) {
        NSData *frame = nil;
        @synchronized (self) {
            if (_consumed >= _buffer.length) break;
            NSRange search = NSMakeRange(_consumed, _buffer.length - _consumed);
            NSRange lf = [_buffer rangeOfData:[NSData dataWithBytes:"\n\n" length:2]
                                      options:0 range:search];
            NSRange crlf = [_buffer rangeOfData:[NSData dataWithBytes:"\r\n\r\n" length:4]
                                        options:0 range:search];
            NSRange hit;
            if (lf.location == NSNotFound) {
                hit = crlf;
            } else if (crlf.location == NSNotFound) {
                hit = lf;
            } else {
                hit = (lf.location <= crlf.location) ? lf : crlf;
            }
            if (hit.location == NSNotFound) break;
            frame = [_buffer subdataWithRange:NSMakeRange(_consumed, hit.location - _consumed)];
            _consumed = NSMaxRange(hit);
        }
        [self handleFrame:frame];
    }
    @synchronized (self) {
        if (_consumed > 0) {
            [_buffer replaceBytesInRange:NSMakeRange(0, _consumed) withBytes:NULL length:0];
            _consumed = 0;
        }
    }
}

- (void)handleFrame:(NSData *)frame {
    if (!frame.length) return;
    NSString *text = [[NSString alloc] initWithData:frame encoding:NSUTF8StringEncoding];
    if (!text.length) {
        // Our own server always sends UTF-8, so this means a proxy mangled the
        // bytes. Loud on purpose: a silently dropped `lyrics` frame would leave
        // the panel waiting until the 45s fetch watchdog reclaims the slot.
        sendDebugLog(@"[WARN] SSE frame undecodable, dropped");
        return;
    }
    NSString *event = nil;
    NSMutableArray<NSString *> *dataLines = [NSMutableArray array];
    for (NSString *raw in [text componentsSeparatedByString:@"\n"]) {
        NSString *line = raw;
        if ([line hasSuffix:@"\r"]) line = [line substringToIndex:line.length - 1];
        if ([line hasPrefix:@"event:"]) {
            event = [[line substringFromIndex:6]
                     stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        } else if ([line hasPrefix:@"data:"]) {
            NSString *chunk = [line substringFromIndex:5];
            if ([chunk hasPrefix:@" "]) chunk = [chunk substringFromIndex:1];
            [dataLines addObject:chunk];
        }
        // ':' lines are keepalive comments -- ignored on purpose, they exist
        // to stop proxies from closing an idle connection.
    }
    if (!event.length || !dataLines.count) return;
    NSString *body = [dataLines componentsJoinedByString:@"\n"];
    NSData *bodyData = [body dataUsingEncoding:NSUTF8StringEncoding];
    if (!bodyData.length) return;
    NSError *err = nil;
    id json = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:&err];
    if (![json isKindOfClass:[NSDictionary class]]) return;
    _sawFrame = YES;
    NSDictionary *payload = [(NSDictionary *)json copy];
    NSString *name = [event copy];
    void (^handler)(NSString *, NSDictionary *) = _onEvent;
    if (!handler) return;
    dispatch_async(dispatch_get_main_queue(), ^{ handler(name, payload); });
}

@end

#pragma mark - Character counting helpers

// Composed-character counts, so a reveal never cuts a surrogate pair or an
// emoji in half the way a raw UTF-16 offset would.
static NSUInteger YTMUCharacterCount(NSString *s) {
    if (!s.length) return 0;
    __block NSUInteger n = 0;
    [s enumerateSubstringsInRange:NSMakeRange(0, s.length)
                          options:NSStringEnumerationByComposedCharacterSequences
                       usingBlock:^(NSString *sub, NSRange r, NSRange er, BOOL *stop) { n++; }];
    return n;
}

// Characters both strings share from the front. Used when a streamed line is
// rewritten (the model's strict echo retry, the OpenCC script pass): the
// reveal continues from where it was instead of snapping back to zero.
static NSUInteger YTMUCommonCharacterCount(NSString *a, NSString *b) {
    if (!a.length || !b.length) return 0;
    __block NSUInteger n = 0;
    __block BOOL mismatched = NO;
    [a enumerateSubstringsInRange:NSMakeRange(0, a.length)
                          options:NSStringEnumerationByComposedCharacterSequences
                       usingBlock:^(NSString *sub, NSRange r, NSRange er, BOOL *stop) {
        if (mismatched || NSMaxRange(er) > b.length) { mismatched = YES; *stop = YES; return; }
        if (![[a substringWithRange:r] isEqualToString:[b substringWithRange:r]]) {
            mismatched = YES;
            *stop = YES;
            return;
        }
        n++;
    }];
    return n;
}

#pragma mark - Cell reveal mask

// Declared once in Source/LyricsShared.h (see the note on the view
// controller's category below).
@implementation YTMULyricsCell (Typewriter)

// fraction 0 hides the row's text, 1 shows all of it. The mask lives on the
// translation label only: the main line keeps the word-by-word wipe, and a row
// with no translation (already in the target language, instrumental) has
// nothing to reveal.
- (void)ytmu_setTypeFraction:(CGFloat)fraction {
    UILabel *label = self.transLabel;
    if (fraction >= 0.999 || !label || label.hidden || !label.text.length) {
        [self ytmu_clearType];
        return;
    }
    // Not laid out yet (first tick after dequeue): the mask frame would be
    // zero-sized and hide the row entirely, so wait for the next tick instead
    // of guessing a width.
    if (label.bounds.size.width <= 1.0) return;
    if (fraction < 0) fraction = 0;
    if (!self.typeMask) {
        CAGradientLayer *mask = [CAGradientLayer layer];
        // Opaque up to the leading edge, then a short ramp to fully hidden, so
        // the character being typed fades in instead of popping.
        mask.colors = @[(id)[UIColor blackColor].CGColor,
                        (id)[UIColor blackColor].CGColor,
                        (id)[UIColor clearColor].CGColor,
                        (id)[UIColor clearColor].CGColor];
        mask.startPoint = CGPointMake(0.0, 0.5);
        mask.endPoint = CGPointMake(1.0, 0.5);
        label.layer.mask = mask;
        self.typeMask = mask;
    }
    // Character count -> points: the label is stretched by its constraints, so
    // map against the laid-out TEXT width, not the label width, or short lines
    // would reveal at the wrong rate.
    CGFloat avail = label.bounds.size.width;
    if (avail <= 1.0) avail = [UIScreen mainScreen].bounds.size.width - 76.0;
    CGSize fits = [label sizeThatFits:CGSizeMake(avail, CGFLOAT_MAX)];
    CGFloat textWidth = MIN(fits.width, avail);
    if (textWidth <= 1.0) textWidth = avail;
    CGFloat edge = textWidth * fraction;
    CGFloat soft = MIN(14.0, textWidth * 0.15);
    CGFloat w = MAX(label.bounds.size.width, 1.0);
    CGFloat fadeStart = MIN(1.0, MAX(0.0, (edge - soft) / w));
    CGFloat edgePos = MIN(1.0, MAX(fadeStart, edge / w));
    // The tick already drives this at display rate: implicit animations would
    // just lag a frame behind and keep the mask installed after a song change.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.typeMask.frame = label.bounds;
    self.typeMask.locations = @[@0.0, @(fadeStart), @(edgePos), @1.0];
    [CATransaction commit];
}

- (void)ytmu_clearType {
    if (!self.typeMask) return;
    self.transLabel.layer.mask = nil;
    self.typeMask = nil;
}

@end

#pragma mark - View controller: stream + typewriter

// How many rows may reveal at the same time. One slot per active line plus one
// lookahead line: two keeps the translation column in motion across a line
// break (the next line starts typing while the current one finishes) without
// turning the whole column into a wall of half-typed text.
static const NSUInteger YTMU_TYPEWRITER_MAX_CONCURRENT = 2;

// NOTE: the (Typewriter) category DECLARATIONS live in Source/LyricsShared.h,
// once, for this file and Source/LyricsSheet.x both. Repeating them here was
// -Werror,-Wobjc-duplicate-category-definition. Declaring the four methods this
// file only CALLS (ytmuIsInstrumentalLyric:, ytmu_applyProviderMeta:...,
// ytmu_updateLandscapeMetadata, fetchFullLyricsForVideo:...) here is what
// produced the four -Werror,-Wincomplete-implementation errors: a declaration
// in a category obliges the @implementation of that same category in the same
// file, and those four are defined in LyricsSheet.x's primary @implementation.
//
// Everything below is private to this file -- no other file calls it, so it
// needs no declaration at all (clang sees every method in an @implementation
// regardless of order).
@implementation YTMULyricsViewController (Typewriter)

#pragma mark Stream lifecycle

- (void)ytmu_cancelTranslateStream {
    YTMULyricsSSEClient *client = (YTMULyricsSSEClient *)self.tstreamClient;
    self.tstreamClient = nil;
    self.tstreamVideoID = nil;
    // A fresh song gets a fresh chance at streaming; the latch is per-video.
    self.tstreamFallbackUsed = NO;
    [client cancel];
}

- (void)ytmu_openTranslateStream:(NSString *)videoID jwt:(NSString *)jwt force:(BOOL)force {
    if (!videoID.length) return;
    [self ytmu_cancelTranslateStream];
    self.tstreamVideoID = videoID;
    self.tstreamGotLyrics = NO;
    self.tstreamGotFinal = NO;

    // /api/lyrics/stream, and it is now the ONLY lyrics route the phone uses.
    //
    // It used to be /api/lyrics/tstream, which is a different endpoint with one
    // crucial difference: tstream runs the whole provider pipeline to completion
    // and pushes `lyrics` ONCE, after it, so the translation streamed but the
    // lyrics did not -- there was nothing to stream FROM until the race was
    // already over. This route races the providers concurrently and pushes every
    // improvement as it lands, which is the ladder the panel actually wants.
    //
    // `tstream` here is the translation style, not the endpoint: 1 (default) is
    // Cohere's own token stream, one `tline` per line as it is written; 0 is the
    // Google interim plus one blocking Cohere pass. That is the user's "streamed
    // translation" setting expressed as a query param, so turning the setting off
    // no longer means taking a different route -- it means a different answer on
    // the same one.
    BOOL streamTranslate = YTMULyricsStreamTranslateEnabled();
    NSMutableString *url = [NSMutableString stringWithFormat:@"%@/api/lyrics/stream?v=%@&lang=%@%@&tstream=%d",
                            YTMUApiBase(), YTMUUrlEncode(videoID),
                            YTMUUrlEncode(YTMUTargetLang()), YTMUAutoZhParam(),
                            streamTranslate ? 1 : 0];
    if (force) [url appendString:@"&force=1"];
    if (jwt.length) [url appendFormat:@"&jwt=%@", YTMUUrlEncode(jwt)];
    sendDebugLog([NSString stringWithFormat:@"[MUSIC] Streaming %@ for %@",
                  streamTranslate ? @"lyrics + translation" : @"lyrics", videoID]);
    YTMUStatusSet(@"video", videoID);
    YTMUStatusSet(@"state", @"opening");
    YTMUStatusSet(@"url", url);
    YTMUStatusSet(@"events", @0);
    YTMUStatusSet(@"lines", @0);
    [g_streamStatus removeObjectForKey:@"error"];

    __weak YTMULyricsViewController *weakSelf = self;
    YTMULyricsSSEClient *client = [[YTMULyricsSSEClient alloc]
        initWithURL:[NSURL URLWithString:url]
        onEvent:^(NSString *name, NSDictionary *json) {
            [weakSelf ytmu_handleStreamEvent:name json:json forVideoID:videoID];
        }
        onError:^{
            [weakSelf ytmu_streamFallbackForVideoID:videoID jwt:jwt];
        }
        onClose:^{
            [weakSelf ytmu_streamFallbackForVideoID:videoID jwt:jwt];
        }];
    self.tstreamClient = client;
}

// The stream is an optimization, never a hard dependency: if it dies before any
// lyrics arrived, the blocking JSON fetch takes over so the song still paints.
- (void)ytmu_streamFallbackForVideoID:(NSString *)videoID jwt:(NSString *)jwt {
    if (![self.tstreamVideoID isEqualToString:videoID]) return;  // already handled or stale
    if (self.tstreamGotLyrics) return;                            // partial result beats nothing
    if (self.tstreamFallbackUsed) return;                         // one fallback per video
    if (![self.loadingVideoID isEqualToString:videoID]) return;
    sendDebugLog(@"[WARN] Stream translation failed, falling back to blocking fetch");
    YTMUStatusSet(@"state", @"fallback");
    YTMUStatusSet(@"error", @"stream closed before any lyrics");
    [self ytmu_cancelTranslateStream];
    // Latched AFTER the cancel (which clears it) and BEFORE the fetch: without
    // it the fetch would route straight back into the stream and a
    // deterministic failure (400, dead endpoint) would reconnect forever.
    self.tstreamFallbackUsed = YES;
    [self fetchFullLyricsForVideo:videoID jwt:jwt force:NO];
}

#pragma mark Stream events

- (void)ytmu_handleStreamEvent:(NSString *)name json:(NSDictionary *)json forVideoID:(NSString *)videoID {
    YTMUStatusBump(@"events");
    if (!json || ![self.loadingVideoID isEqualToString:videoID]) return;
    if ([name isEqualToString:@"meta"]) {
        id fs = json[@"song"], fa = json[@"artist"];
        if ([fs isKindOfClass:[NSString class]] && ((NSString *)fs).length) self.lastSongTitle = fs;
        if ([fa isKindOfClass:[NSString class]] && ((NSString *)fa).length) self.lastSongArtist = fa;
        [self ytmu_updateLandscapeMetadata];
        return;
    }
    if ([name isEqualToString:@"lyrics"]) {
        NSArray *lyrics = json[@"lyrics"];
        if (![lyrics isKindOfClass:[NSArray class]] || !YTMULyricsIsUsable(lyrics, json)) return;
        NSString *stage = [json[@"stage"] isKindOfClass:[NSString class]] ? json[@"stage"] : @"raw";
        BOOL isFinal = [stage isEqualToString:@"final"];
        // `cached` is the server's own verdict on this request. `raw` and
        // `final` only exist on the live path (a cache hit short-circuits to
        // stage=cached with no tline), so either one proves the translation is
        // being produced as the client watches and the reveal is worth running.
        // Absent on an older server build: fall back to the stage, which is
        // never 'cached' for a payload that is still being translated.
        id cachedFlag = json[@"cached"];
        BOOL fromCache = (cachedFlag != nil) ? [cachedFlag boolValue]
                                             : [stage isEqualToString:@"cached"];
        // The stage matters now, and not only the cached flag. On tstream=0 the
        // server pushes `machine` (the Google interim) and then re-pushes the
        // same rows as `final` once Cohere answers -- two fills of the same
        // cells, about a second apart. Animating the reveal onto the interim
        // types a line out and then types the real one over it, which is exactly
        // the flicker the streamed path avoids by not sending an interim at all.
        // So the reveal runs only where the text is not about to be replaced.
        BOOL stable = isFinal || [stage isEqualToString:@"cached"];
        if (!fromCache && stable && YTMULyricsStreamTranslateEnabled()) {
            self.typewriterLive = YES;
        }
        if (!self.tstreamGotLyrics) {
            UILabel *statusLabel = [self.tableView.tableHeaderView viewWithTag:8888];
            statusLabel.text = @"";
        }
        self.tstreamGotLyrics = YES;
        if (isFinal) self.tstreamGotFinal = YES;
        id fs = json[@"song"], fa = json[@"artist"], fp = json[@"source"];
        if ([fs isKindOfClass:[NSString class]] && ((NSString *)fs).length) self.lastSongTitle = fs;
        if ([fa isKindOfClass:[NSString class]] && ((NSString *)fa).length) self.lastSongArtist = fa;
        if ([fp isKindOfClass:[NSString class]] && ((NSString *)fp).length) self.lastProvider = fp;
        [self ytmu_applyProviderMeta:json forVideoID:videoID];
        [self ytmu_updateLandscapeMetadata];
        // A `raw` payload is untranslated and will be replaced by the streaming
        // tline updates, so only a stable payload (final or cached) is written
        // to the on-disk cache -- otherwise the next play of this song reads
        // back a half-translated file. The RAM cache takes the first payload of
        // any stage so a second VC has something to show.
        //
        // `machine` and `final` are the same rows with the same line count, so
        // promoting either of them into the RAM cache is harmless; only the disk
        // write has to wait for the stage that will not be replaced.
        BOOL promotable = stable;
        if (!g_lyricsCache) g_lyricsCache = [[NSMutableDictionary alloc] init];
        if (promotable || !g_lyricsCache[videoID]) {
            g_lyricsCache[videoID] = lyrics;
            if (promotable) YTMULyricsCacheSave(videoID, lyrics);
        }
        BOOL firstPaint = (self.lyrics.count == 0);
        [self updateLyrics:lyrics];
        if (firstPaint) {
            [[NSNotificationCenter defaultCenter] postNotificationName:@"YTMULyricsDidLoad"
                                                                object:videoID
                                                              userInfo:@{@"lyrics": lyrics}];
        }
        return;
    }
    if ([name isEqualToString:@"tline"]) {
        NSInteger row = [json[@"row"] integerValue];
        id text = json[@"text"];
        if (![text isKindOfClass:[NSString class]]) return;
        // A translated line landing in real time: nothing about this request
        // came out of a cache, so the reveal may run. Gated on the setting for
        // the same reason as the `lyrics` push above -- with streamed
        // translation turned off there is nothing to reveal character by
        // character, the rows simply arrive.
        if (YTMULyricsStreamTranslateEnabled()) self.typewriterLive = YES;
        if ([json[@"done"] boolValue]) YTMUStatusBump(@"lines");
        YTMUStatusSet(@"lastRow", @(row));
        YTMUStatusSet(@"lastText", text);
        YTMUStatusSet(@"lastElapsed", json[@"elapsed_ms"]);
        [self ytmu_applyTranslateLine:(NSString *)text toRow:row];
        return;
    }
    if ([name isEqualToString:@"done"]) {
        BOOL ok = [json[@"ok"] boolValue];
        // Cancel rather than just dropping the reference: the server is done
        // writing, and this also clears tstreamVideoID so the close callback
        // cannot re-enter the fallback.
        [self ytmu_cancelTranslateStream];
        self.isLoading = NO;
        self.loadingSince = nil;
        if ([g_globalLoadingVideoID isEqualToString:videoID]) {
            YTMUReleaseGlobalFetch();
        }
        YTMUStatusSet(@"state", ok ? @"done" : @"failed");
        YTMUStatusSet(@"stages", [json[@"stages"] componentsJoinedByString:@" -> "]);
        if (!ok && !self.tstreamGotLyrics) {
            UILabel *statusLabel = [self.tableView.tableHeaderView viewWithTag:8888];
            statusLabel.text = @"[WARN] 找不到歌詞 / No lyrics found";
            self.lyrics = @[];
            [self.tableView reloadData];
        }
        return;
    }
}

// One streamed translated line. The array is the single source of truth (the
// tick reads the text back out of it), and the visible cell is patched
// directly: a full configureCell would redo the word-timing TextKit pass for
// every token.
- (void)ytmu_applyTranslateLine:(NSString *)text toRow:(NSInteger)row {
    if (row < 0 || row >= self.lyrics.count) return;
    NSDictionary *line = self.lyrics[row];
    if (![line isKindOfClass:[NSDictionary class]]) return;
    NSMutableDictionary *updated = [line mutableCopy];
    if (text.length) updated[@"translated"] = text;
    else [updated removeObjectForKey:@"translated"];
    NSMutableArray *lyrics = [self.lyrics mutableCopy];
    lyrics[row] = updated;
    self.lyrics = lyrics;

    // A rewritten line invalidates the reveal bookkeeping; the tick rebuilds it
    // from the new text and keeps whatever was already shown.
    YTMULyricsCell *cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]];
    if (!cell) return;  // offscreen: the final payload repaints it
    NSString *rawText = [updated[@"text"] isKindOfClass:[NSString class]] ? updated[@"text"] : @"";
    if (text.length && ![text isEqualToString:rawText] && ![self ytmuIsInstrumentalLyric:updated]) {
        cell.transLabel.text = text;
        cell.transLabel.hidden = NO;
        if (![self ytmu_isRowActive:row]) [cell ytmu_clearType];
    } else {
        cell.transLabel.text = @"";
        cell.transLabel.hidden = YES;
        [cell ytmu_clearType];
    }
}

#pragma mark Typewriter state

// The state containers are created on demand: the properties are declared in
// LyricsShared.h for the header's sake, and no ivar backdoor is available from
// this translation unit (a category cannot synthesize one).
- (NSMutableDictionary *)ytmu_typeStates {
    if (!self.typeState) self.typeState = [NSMutableDictionary dictionary];
    return self.typeState;
}

- (NSMutableSet *)ytmu_typeRowSet {
    if (!self.typeRows) self.typeRows = [NSMutableSet set];
    return self.typeRows;
}

- (void)ytmu_typeResetAll {
    self.typeState = [NSMutableDictionary dictionary];
    self.typeRows = [NSMutableSet set];
    self.typeLastWall = 0;
    for (UITableViewCell *cell in self.tableView.visibleCells) {
        if ([cell isKindOfClass:[YTMULyricsCell class]]) [(YTMULyricsCell *)cell ytmu_clearType];
    }
}

- (BOOL)ytmu_isRowActive:(NSInteger)row {
    // Same rule as -cellForRowAtIndexPath, plus its guards: a row only counts
    // as active while the payload is timed, otherwise a stale currentIndex
    // could keep a reveal running on a plain-lyrics payload.
    if (row < 0 || row >= self.lyrics.count || !self.isSynced) return NO;
    if (self.activeIndexes && self.activeIndexes.count > 0) {
        return [self.activeIndexes containsIndex:(NSUInteger)row];
    }
    return row == self.currentIndex;
}

// The text a row reveals: its translation when there is one. Rows whose text is
// already in the target language carry no translation, and instrumental rows
// are an icon -- neither has anything to type out.
- (NSString *)ytmu_revealTextForLyric:(NSDictionary *)lyric {
    if (![lyric isKindOfClass:[NSDictionary class]]) return nil;
    if ([self ytmuIsInstrumentalLyric:lyric]) return nil;
    NSString *text = [lyric[@"text"] isKindOfClass:[NSString class]] ? lyric[@"text"] : @"";
    NSString *translated = [lyric[@"translated"] isKindOfClass:[NSString class]] ? lyric[@"translated"] : @"";
    if (!translated.length || [translated isEqualToString:text]) return nil;
    return translated;
}

// May this row occupy a reveal slot? Two ways to be disqualified: nothing to
// reveal (instrumental icon, text already in the target language, no
// translation yet) and already fully typed -- the finished state is kept as a
// tombstone precisely so a line that typed out is not picked again and starts
// over from zero on the next tick.
- (BOOL)ytmu_rowCanReveal:(NSInteger)row {
    if (row < 0 || row >= self.lyrics.count) return NO;
    // boolValue, not a plain test: the tombstone stores @NO when the text is
    // rewritten, and an @NO NSNumber is a non-nil object.
    // The subscript is its own statement because the chained form --
    // if ([[self ytmu_typeStates][@(row)] objectForKey:@"done"] boolValue) --
    // failed to compile: clang reported "expected ')'" pointing at the if (,
    // with the caret after boolValue. Splitting it is unambiguous and costs
    // nothing. (Note: subscripting a message-send result is legal in general,
    // Source/SponsorBlock.x:8 and Source/LyricsCore.x:559 both do it, so this
    // is about that particular nesting, not a general rule.)
    NSDictionary *state = [self ytmu_typeStates][@(row)];
    if ([state[@"done"] boolValue]) return NO;
    return [[self ytmu_revealTextForLyric:self.lyrics[row]] length] > 0;
}

// The rows allowed to reveal on this tick, capped at
// YTMU_TYPEWRITER_MAX_CONCURRENT. Two rules, in order:
//
//  1. Every row the clock currently considers active keeps its slot, so an
//     overlapping duet types both lines at once (unchanged behaviour).
//  2. A free slot goes to the first not-yet-finished row after the LAST active
//     one. The old one-slot-at-a-time rule left the panel frozen for the tail
//     of every line, then typed the next line alone: the reveal read as a
//     stutter instead of a stream.
//
// Rows are never taken from before the anchor (that is an active row's business)
// and a row that cannot reveal is skipped, not queued forever, so the free slot
// always lands on a row that can actually type.
- (NSArray<NSNumber *> *)ytmu_revealCandidateRows {
    NSMutableArray<NSNumber *> *candidates = [NSMutableArray array];
    // Typewriter off: nothing may reveal, which also makes the tick drop the
    // masks of whatever is still in flight.
    if (YTMUTypewriterCPS() <= 0.0) return candidates;
    NSUInteger cap = YTMU_TYPEWRITER_MAX_CONCURRENT;
    NSInteger anchor = -1;
    NSIndexSet *active = self.activeIndexes;
    if (active && active.count > 0) {
        if (active.lastIndex != NSNotFound) anchor = (NSInteger)active.lastIndex;
        for (NSUInteger i = [active firstIndex]; i != NSNotFound && candidates.count < cap; i = [active indexGreaterThanIndex:i]) {
            NSInteger row = (NSInteger)i;
            if ([self ytmu_rowCanReveal:row]) [candidates addObject:@(row)];
        }
    } else if ([self ytmu_isRowActive:self.currentIndex]) {
        anchor = self.currentIndex;
        if ([self ytmu_rowCanReveal:self.currentIndex]) [candidates addObject:@(self.currentIndex)];
    }
    // No active row means a gap in the timing: there is no anchor to look ahead
    // from, and scanning from row 0 would type the first line of the song.
    if (candidates.count >= cap || anchor < 0) return candidates;
    for (NSInteger row = anchor + 1; row < (NSInteger)self.lyrics.count && candidates.count < cap; row++) {
        if ([self ytmu_rowCanReveal:row]) [candidates addObject:@(row)];
    }
    return candidates;
}

- (void)ytmu_typeRow:(NSInteger)row activate:(BOOL)activate {
    if (row < 0 || row >= self.lyrics.count) return;
    YTMULyricsCell *cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]];
    if (!cell) return;
    // Not a live translation: the row is not allowed to reveal at all. This has
    // to be checked here and not only in the tick, because -ytmu_advanceRow: is
    // called directly with dt=0, which would leave `shown` at 0 and install a
    // mask that hides the whole translation of a cache hit until the next tick
    // decides otherwise.
    if (!activate || YTMUTypewriterCPS() <= 0.0 || !self.typewriterLive) {
        [[self ytmu_typeRowSet] removeObject:@(row)];
        [[self ytmu_typeStates] removeObjectForKey:@(row)];
        [cell ytmu_clearType];
        return;
    }
    [self ytmu_advanceRow:row cell:cell now:CACurrentMediaTime() dt:0];
}

// Called from the lyric tick. Advances the rows the candidate set allows this
// tick: the active ones plus, while a slot is free, the next unfinished line.
// A line types as it becomes current, and anything that leaves the set snaps to
// fully visible so nothing is left half-revealed behind the reader.
- (void)ytmu_typeStep {
    if (!self.isSynced || self.lyrics.count == 0 || !self.typewriterLive) {
        // No timing, or nothing live to reveal: drop the masks and the state
        // instead of leaving a row frozen half-typed. A cached payload is the
        // common case here (re-opening a song the device or the server already
        // has), and animating it was pure decoration over text that was never
        // being written.
        if (self.typeState.count) [self ytmu_typeResetAll];
        return;
    }
    // The wall clock is read BEFORE the idle check: with nothing typing,
    // typeLastWall would otherwise freeze and the next line's first tick would
    // see the whole pause as one dt (clamped to 0.2s = an instant pop).
    NSTimeInterval now = CACurrentMediaTime();
    NSTimeInterval dt = (self.typeLastWall > 0) ? (now - self.typeLastWall) : 0;
    self.typeLastWall = now;
    // A stall (backgrounded app, long GC) must not dump the whole line at once.
    if (dt < 0) dt = 0;
    if (dt > 0.2) dt = 0.2;

    NSArray<NSNumber *> *candidates = [self ytmu_revealCandidateRows];
    NSMutableDictionary *states = [self ytmu_typeStates];
    NSMutableSet *rows = [self ytmu_typeRowSet];
    // Idle fast path: nothing in flight and nothing queued, so there is no mask
    // to drop and no row to advance (the finished tombstones may stay).
    if (candidates.count == 0 && rows.count == 0) return;
    // Whatever dropped out of the set finishes instantly: a deactivated row, one
    // the seek jumped past, or a queued line the lookahead no longer picks. The
    // state goes with the mask, because keeping it would re-hide a line that is
    // already showing in full the moment it came back into the set.
    for (NSNumber *key in [rows copy]) {
        if ([candidates containsObject:key]) continue;
        [rows removeObject:key];
        [states removeObjectForKey:key];
        NSInteger row = (NSInteger)key.integerValue;
        if (row < 0 || row >= self.lyrics.count) continue;
        YTMULyricsCell *cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]];
        if (cell) [cell ytmu_clearType];
    }
    for (NSNumber *key in candidates) {
        NSInteger row = (NSInteger)key.integerValue;
        YTMULyricsCell *cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]];
        // Offscreen (or scrolled away mid-reveal): the reveal simply waits, the
        // state survives and the line resumes where it stopped.
        if (!cell) continue;
        [self ytmu_advanceRow:row cell:cell now:now dt:dt];
    }
}

- (void)ytmu_advanceRow:(NSInteger)row cell:(YTMULyricsCell *)cell now:(NSTimeInterval)now dt:(NSTimeInterval)dt {
    NSString *full = [self ytmu_revealTextForLyric:self.lyrics[row]];
    NSNumber *key = @(row);
    NSMutableDictionary *states = [self ytmu_typeStates];
    NSMutableSet *rows = [self ytmu_typeRowSet];
    if (!full.length) {
        [rows removeObject:key];
        [states removeObjectForKey:key];
        [cell ytmu_clearType];
        return;
    }
    NSMutableDictionary *state = states[key];
    if (!state) {
        state = [@{@"full": full,
                   @"total": @(YTMUCharacterCount(full)),
                   @"shown": @0.0,
                   @"last": @(now)} mutableCopy];
        states[key] = state;
    } else if (![state[@"full"] isEqualToString:full]) {
        // Streamed growth keeps the reveal; a rewrite (echo retry, script
        // conversion) keeps the common prefix and re-hides the rest.
        NSString *old = state[@"full"];
        double shown = [state[@"shown"] doubleValue];
        double oldTotal = [state[@"total"] doubleValue];
        double total = (double)YTMUCharacterCount(full);
        if (![full hasPrefix:old]) {
            double common = (double)YTMUCommonCharacterCount(old, full);
            if (common < oldTotal) shown = MIN(shown, common);
        }
        state[@"full"] = full;
        state[@"total"] = @(total);
        state[@"shown"] = @(MIN(shown, total));
        // New text means something new to type, even for a row that had
        // already finished: drop the tombstone or the candidate scan would skip
        // the grown tail forever.
        state[@"done"] = @NO;
    }
    double total = [state[@"total"] doubleValue];
    double shown = [state[@"shown"] doubleValue];
    if (shown < total) {
        // Per row, not per panel: two rows revealing at once each get the full
        // YTMUTypewriterCPS(), otherwise doubling the concurrent rows would
        // halve the speed the user asked for.
        shown = MIN(total, shown + YTMUTypewriterCPS() * dt);
        state[@"shown"] = @(shown);
    }
    if (shown >= total - 0.001) {
        [rows removeObject:key];
        // The state survives as a tombstone (shown == total, done) so the
        // lookahead scan can tell "typed out already" from "never started".
        // Deleting it would make the next-row scan pick this row again and
        // restart it from zero on the following tick.
        state[@"done"] = @YES;
        [cell ytmu_clearType];
        return;
    }
    [rows addObject:key];
    [cell ytmu_setTypeFraction:(CGFloat)(shown / MAX(total, 1.0))];
}

@end
