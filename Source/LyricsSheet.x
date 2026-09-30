#import "LyricsShared.h"
// LOC() for the duet marker strings. It resolves against the tweak's own bundle
// (Source/Utils/NSBundle+YTMU.m), NOT the main bundle -- plain NSLocalizedString
// would miss every key here and return the key name itself.
#import "Localization.h"

static inline BOOL __attribute__((unused)) YTMUIsCJKChar(unichar c) {
    return ((c >= 0x3040 && c <= 0x309F) ||
            (c >= 0x30A0 && c <= 0x30FF) ||
            (c >= 0x31F0 && c <= 0x31FF) ||
            (c >= 0x3400 && c <= 0x4DBF) ||
            (c >= 0x4E00 && c <= 0x9FFF) ||
            (c >= 0xF900 && c <= 0xFAFF) ||
            (c >= 0x3000 && c <= 0x303F) ||
            (c >= 0xFF61 && c <= 0xFF9F) ||
            (c >= 0xFF00 && c <= 0xFFEF));
}

// Dynamic ink: white in dark mode, black in light mode. Deployment target is
// iOS 13 so colorWithDynamicProvider is always available at runtime.
// NOTE: lyrics chrome must use the YTMULyric* background-derived inks below,
// not these theme-based ones: the sheet sits on blurred artwork whose
// brightness is independent of the OS theme.
UIColor *YTMUAdaptiveInk(CGFloat darkAlpha, CGFloat lightAlpha) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        if (tc.userInterfaceStyle == UIUserInterfaceStyleLight)
            return [[UIColor blackColor] colorWithAlphaComponent:lightAlpha];
        return [[UIColor whiteColor] colorWithAlphaComponent:darkAlpha];
    }];
}
UIColor *YTMUAdaptiveFill(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        if (tc.userInterfaceStyle == UIUserInterfaceStyleLight)
            return [[UIColor blackColor] colorWithAlphaComponent:0.10];
        return [[UIColor whiteColor] colorWithAlphaComponent:0.15];
    }];
}
UIColor *YTMUAdaptiveShadow(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        if (tc.userInterfaceStyle == UIUserInterfaceStyleLight)
            return [[UIColor darkGrayColor] colorWithAlphaComponent:0.35];
        return [[UIColor blackColor] colorWithAlphaComponent:0.8];
    }];
}
BOOL YTMUInterfaceIsLight(UIView *v) {
    return v.traitCollection.userInterfaceStyle == UIUserInterfaceStyleLight;
}

// Dynamic lyric type scale: one size per song from the longest line, so
// long lines fit without wrapping and rows never resize mid-song (no jump).
// Shadows stay absolute (never scaled) so they can't jump either.
static CGFloat s_lyricFontSize = 28.0;
static CGFloat YTMULyricMainFontSize(void) { return s_lyricFontSize; }
static CGFloat YTMULyricTransFontSize(void) { return s_lyricFontSize * 19.0 / 28.0; }

// Background-derived ink: the sheet sits on blurred artwork, which can be
// bright white while the OS is in dark mode (or dark while in light mode),
// so trait-based ink washes out. The artwork is sampled once per song (see
// ytmu_probeArtworkBrightness:); until sampled, fall back to the OS theme.
static int g_ytmu_bgLight = -1; // -1 unknown, 0 dark bg, 1 light bg

static BOOL YTMUBgIsLight(UIView *refView) {
    if (g_ytmu_bgLight >= 0) return g_ytmu_bgLight == 1;
    if (refView) return YTMUInterfaceIsLight(refView);
    return NO;
}

// Mean artwork color for the current song, nil until the first cover lands.
// Sampled once per song in ytmu_probeArtworkBrightness: and read by every
// YTMULyricInk call (per cell configure, per chrome refresh), so it must
// never be resampled from inside the ink itself.
static UIColor *s_ytmuArtworkMean = nil;
static void YTMUSetArtworkMeanColor(UIColor *mean) {
    s_ytmuArtworkMean = mean;
}
static CGFloat YTMUColorLuma(CGFloat r, CGFloat g, CGFloat b) {
    return 0.299 * r + 0.587 * g + 0.114 * b;
}
// Luminance of the backdrop the ink sits on, from the brightness bucket: the
// light wash lands near white, the dark one near black.
static CGFloat YTMULyricBackdropLuma(UIView *refView) {
    return YTMUBgIsLight(refView) ? 0.90 : 0.08;
}
// Same alpha tuning as YTMUAdaptiveInk, keyed on background brightness
// instead of the OS theme, then pulled a little toward the artwork so the
// lyrics read as part of the cover instead of pasted pure black/white on it.
// A tinted ink that lands too close to the backdrop falls back to the plain
// one; with no cover sampled yet this returns the old color untouched.
static UIColor *YTMULyricInk(CGFloat darkAlpha, CGFloat lightAlpha, UIView *refView) {
    BOOL light = YTMUBgIsLight(refView);
    CGFloat alpha = light ? lightAlpha : darkAlpha;
    UIColor *plain = [(light ? [UIColor blackColor] : [UIColor whiteColor])
                      colorWithAlphaComponent:alpha];
    UIColor *mean = s_ytmuArtworkMean;
    if (!mean) return plain;
    CGFloat ar = 0, ag = 0, ab = 0;
    if (![mean getRed:&ar green:&ag blue:&ab alpha:NULL]) return plain;
    CGFloat r, g, b;
    if (light) {
        // Pure black is too flat on the light wash: take the artwork's own hue
        // at a darkness its luminance asks for (0.18..0.45), never at 0.
        CGFloat k = 0.18 + 0.27 * YTMUColorLuma(ar, ag, ab);
        r = ar * k; g = ag * k; b = ab * k;
    } else {
        // 14% toward the artwork hue: the text stays as light as the pure
        // white it replaces, so the contrast it had is preserved.
        const CGFloat k = 0.14;
        r = 1.0 - (1.0 - ar) * k;
        g = 1.0 - (1.0 - ag) * k;
        b = 1.0 - (1.0 - ab) * k;
    }
    if (fabs(YTMUColorLuma(r, g, b) - YTMULyricBackdropLuma(refView)) < 0.18) return plain;
    return [UIColor colorWithRed:r green:g blue:b alpha:alpha];
}
static UIColor *YTMULyricShadow(UIView *refView) {
    if (YTMUBgIsLight(refView))
        return [[UIColor darkGrayColor] colorWithAlphaComponent:0.35];
    return [[UIColor blackColor] colorWithAlphaComponent:0.8];
}
// Same idea as YTMULyricInk for pill/track fills.
static UIColor *YTMULyricFill(UIView *refView) {
    BOOL light = YTMUBgIsLight(refView);
    return [(light ? [UIColor blackColor] : [UIColor whiteColor])
            colorWithAlphaComponent:(light ? 0.10 : 0.15)];
}
// Base wash + blur style, also keyed on background brightness (not the OS
// theme). Snapshots: re-resolve via ytmu_refreshBgDerivedInk when the probe
// lands (until then YTMUBgIsLight falls back to the OS theme).
static UIColor *YTMUBgBaseColor(UIView *refView) {
    if (YTMUBgIsLight(refView)) return [UIColor systemBackgroundColor];
    return [[UIColor blackColor] colorWithAlphaComponent:0.95];
}
static UIBlurEffectStyle YTMUBgBlurStyle(UIView *refView) {
    return YTMUBgIsLight(refView) ? UIBlurEffectStyleLight : UIBlurEffectStyleDark;
}
// Scrim over the blur. Light enough to let the cover read through, dark
// enough for the white ink; keyed on the same brightness bucket as the wash
// above. Both copies (viewDidLoad + ytmu_refreshBgDerivedInk) read it, so the
// two can never drift apart.
static CGFloat YTMUBgOverlayAlpha(UIView *refView) {
    return YTMUBgIsLight(refView) ? 0.22 : 0.40;
}
static UIColor *YTMUBgOverlayColor(UIView *refView) {
    return [[UIColor blackColor] colorWithAlphaComponent:YTMUBgOverlayAlpha(refView)];
}
// Mean artwork color for the song-tinted background wash.
static UIColor *YTMUArtworkAverageColor(UIImage *img) {
    CGImageRef cg = img.CGImage;
    if (!cg) return nil;
    uint8_t px[8 * 8 * 4] = {0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) return nil;
    CGContextRef ctx = CGBitmapContextCreate(px, 8, 8, 8, 8 * 4, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;
    CGContextDrawImage(ctx, CGRectMake(0, 0, 8, 8), cg);
    CGContextRelease(ctx);
    unsigned long r = 0, g = 0, b = 0;
    int n = 0;
    for (int i = 0; i < 64; i++) {
        if (px[i * 4 + 3] < 16) continue;
        r += px[i * 4]; g += px[i * 4 + 1]; b += px[i * 4 + 2]; n++;
    }
    if (!n) return nil;
    return [UIColor colorWithRed:r / (CGFloat)n / 255.0
                           green:g / (CGFloat)n / 255.0
                            blue:b / (CGFloat)n / 255.0 alpha:1.0];
}

// Mean luminance of a thumbnail; -1 when unsampleable.
static CGFloat YTMUArtworkLuminance(UIImage *img) {
    if (!img) return -1;
    CGImageRef cg = img.CGImage;
    if (!cg) return -1;
    // Fixed-size buffer: a const size_t extent would be a VLA, which cannot
    // take an initializer in C.
    uint8_t px[8 * 8 * 4] = {0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) return -1;
    CGContextRef ctx = CGBitmapContextCreate(px, 8, 8, 8, 8 * 4, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return -1;
    CGContextDrawImage(ctx, CGRectMake(0, 0, 8, 8), cg);
    CGContextRelease(ctx);
    double r = 0, g = 0, b = 0;
    for (size_t i = 0; i < 64; i++) {
        r += px[i * 4] / 255.0;
        g += px[i * 4 + 1] / 255.0;
        b += px[i * 4 + 2] / 255.0;
    }
    r /= 64.0; g /= 64.0; b /= 64.0;
    return (CGFloat)(0.299 * r + 0.587 * g + 0.114 * b);
}

// One timing for the whole "a line arrives" gesture: the table scroll and the
// activation pop run on the same curve and the same clock, so the line lands
// and lights up as one motion. It also bounds how long a scroll may be treated
// as in flight (see ytmu_scrollToRow:instant:).
static const NSTimeInterval YTMUTransitionDuration = 0.28;
// Restrained activation pop: the old 1.04 / alpha 0.3 / 0.5s read as a jump.
// Applied to a LINE-SYNCED row only; a word-synced row's arrival motion is the
// per-word sway below, which is what braccato's own themes do (its karaoke
// preset sets line-scale off and leaves the wobble on).
static const CGFloat YTMUPopScale = 1.018;
static const CGFloat YTMUPopStartAlpha = 0.6;

// The rest of this block is braccato parity (better-lyrics/braccato, cloned to
// the temp dir for reference). Its numbers are in packages/core/src/styles/
// variables.css and its timings in engine.ts; nothing is vendored.
static const NSTimeInterval YTMUHighlightFadeInDuration = 0.33;   // variables.css:90
static const NSTimeInterval YTMUHighlightFadeOutDuration = 0.50;  // variables.css:94
// braccato rests the sung line at 37% of the viewport, not the middle, so the
// lines still to come have somewhere to go. engine.ts:125.
static const CGFloat YTMUScrollTargetRatio = 0.37;
// Highlight glow: a drop-shadow that starts fat around the word being sung and
// shrinks away over 1.2x that word's own time, never under 1.2s.
// variables.css:105-108.
static const CGFloat YTMUHighlightGlowRadius = 12.8;
static const CGFloat YTMUHighlightGlowRatio = 1.2;
static const NSTimeInterval YTMUHighlightGlowMinDuration = 1.2;
// Word wobble, applied per WORD as a whole-line sway. braccato's own keyframes
// are translateX(0.05em) + scaleX(1.025) at 12.5%, settling at 75%, over 1s
// (variables.css:111-120). Only the translate half survives here: our lyric
// labels are full-width with Natural alignment, so a scaleX about the label
// centre would drag the glyphs toward the middle instead of squashing the word
// -- that needs one layer per word, which is not built.
static const NSTimeInterval YTMUWobbleDuration = 1.0;
static const CGFloat YTMUWobblePeakOffset = 0.125;
static const CGFloat YTMUWobbleSettleOffset = 0.75;
static const CGFloat YTMUWobblePeakEm = 0.05;
// Karaoke swipe overshoot: the leading edge runs past the word and is pulled
// back over the last fifth of it, so the highlight visibly catches up.
// variables.css:101-104 does the same thing with animated gradient stops
// (-0.2/-0.1 -> 1.4/1.5).
static const CGFloat YTMUSwipeOvershoot = 0.28;
static const CGFloat YTMUSwipeOvershootTail = 0.22;
static const NSTimeInterval YTMUWaveOscillationDuration = 1.25;  // variables.css:139
// Distance ladder: opacity by how far a row sits from the sung line. braccato's
// Sustain theme pairs each step with a blur; the blur needs an effect view per
// row and reads as a notification card, so only the opacity moves.
static const CGFloat YTMUDistanceLadder[6] = { 1.0, 0.88, 0.72, 0.52, 0.28, 0.0 };
static const NSInteger YTMUDistanceLadderSteps = 5;
// Row of the animated scroll currently in flight, -1 when the table is at
// rest. A second target arriving inside the transition would queue behind the
// first and the two fight, so the caller jumps instead (see the method below).
static NSInteger s_scrollInFlightRow = -1;
static NSTimeInterval s_scrollStartedAt = 0;
static void YTMUResetScrollTracking(void) {
    s_scrollInFlightRow = -1;
    s_scrollStartedAt = 0;
}

// Provider tier icons (concept: better-lyrics lyricsDock syncTypeIcons —
// 3 top bars + full-width bottom bar, full-vs-dim count encodes richness,
// same sync colors). Redrawn from scratch with UIBezierPath; no upstream
// SVG data is copied in.
static UIColor *YTMUTierColor(NSString *tier) {
    if ([tier isEqualToString:@"wbw"])
        return [UIColor colorWithRed:0xAA / 255.0 green:0xD1 / 255.0 blue:0xFF / 255.0 alpha:1.0];
    if ([tier isEqualToString:@"line"])
        return [UIColor colorWithRed:0xC9 / 255.0 green:0xF8 / 255.0 blue:0xDA / 255.0 alpha:1.0];
    return [[UIColor whiteColor] colorWithAlphaComponent:0.7]; // plain / unknown
}

static UIImage *YTMUTierIcon(NSString *tier, CGFloat size) {
    if (size <= 0) size = 18;
    // Full bars in left->right order; the bottom bar always stays dim.
    // wbw = 2 (word), line = 3, plain/unknown = 0.
    NSInteger full = 0;
    if ([tier isEqualToString:@"wbw"]) full = 2;
    else if ([tier isEqualToString:@"line"]) full = 3;
    UIColor *base = YTMUTierColor(tier);
    CGFloat baseAlpha = CGColorGetAlpha(base.CGColor);
    CGFloat s = size / 1024.0;
    CGRect bars[4] = {
        CGRectMake(0, 239 * s, 277 * s, 233 * s),
        CGRectMake(337 * s, 240 * s, 219 * s, 233 * s),
        CGRectMake(636 * s, 239 * s, 390 * s, 233 * s),
        CGRectMake(0, 552 * s, 1024 * s, 233 * s),
    };
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size, size), NO, 0);
    for (int i = 0; i < 4; i++) {
        BOOL isFull = (i < 3 && i < full);
        UIColor *c = isFull ? base : [base colorWithAlphaComponent:baseAlpha * 0.5];
        [c setFill];
        [[UIBezierPath bezierPathWithRoundedRect:bars[i] cornerRadius:48 * s] fill];
    }
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [img imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

%hook YTMLightweightMusicDescriptionShelfCell

- (void)layoutSubviews {
    %orig;

    UILabel *descriptionLabel = [self valueForKey:@"_descriptionLabel"];
    if (descriptionLabel) {
        CGRect f = descriptionLabel.frame;
        if (f.origin.x < 18) {
            CGFloat diff = 18 - f.origin.x;
            f.origin.x = 18;
            f.size.width = MAX(0, f.size.width - diff);
            descriptionLabel.frame = f;
        }
    }

    if ([self respondsToSelector:@selector(lyrics)] && self.lyrics) {
        CGRect f = self.lyrics.frame;
        if (f.origin.x < 18) {
            CGFloat diff = 18 - f.origin.x;
            f.origin.x = 18;
            f.size.width = MAX(0, f.size.width - diff);
            self.lyrics.frame = f;
        }
        self.lyrics.textContainerInset = UIEdgeInsetsMake(0, 4, 0, 4);
    }
}

- (void)setRenderer:(id)renderer {
    %orig;

    sendDebugLog(@"[OK] 成功進入歌詞 Cell (YTMLightweightMusicDescriptionShelfCell)");

    UILabel *descriptionLabel = [self valueForKey:@"_descriptionLabel"];
    if (!descriptionLabel) {
        sendDebugLog(@"[WARN] 找不到 _descriptionLabel");
        return;
    }

    if (!g_lyricsCache) {
        g_lyricsCache = [[NSMutableDictionary alloc] init];
    }

    NSString *videoID = g_currentVideoID;
    if (!videoID) return;

    if (g_lyricsCache[videoID]) {
        NSString *translatedText = g_lyricsCache[videoID];
        descriptionLabel.text = translatedText;

        if ([self respondsToSelector:@selector(lyrics)] && self.lyrics) {
            self.lyrics.text = translatedText;
        }
        return;
    }

    sendDebugLog([NSString stringWithFormat:@"準備向伺服器要歌詞: %@", videoID]);

    NSString *serverURL = [NSString stringWithFormat:@"%@/api/lyrics?v=%@&lang=%@%@", YTMUApiBase(), videoID, YTMUUrlEncode(YTMUTargetLang()), YTMUAutoZhParam()];
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:serverURL]];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && data) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (json && json[@"translated_lyrics"]) {
                NSString *newLyrics = json[@"translated_lyrics"];
                g_lyricsCache[videoID] = newLyrics;

                dispatch_async(dispatch_get_main_queue(), ^{
                    if ([g_currentVideoID isEqualToString:videoID]) {
                        descriptionLabel.text = newLyrics;

                        if ([self respondsToSelector:@selector(lyrics)] && self.lyrics) {
                            self.lyrics.text = newLyrics;
                        }
                        [self setNeedsLayout];
                    }
                });
            }
        }
    }] resume];
}

%end


// Lyric row gutters. Portrait and the fullscreen landscape layout share this
// one table, so the margins are cell constraints built once at init (never
// recomputed per row or per payload): they therefore hold through a song
// change, a raw -> final swap and a rotation with no jump. The landscape
// album column butts against the table, which is why the left side is deeper.
static CGFloat YTMULyricGutterLeading(void) { return 64.0; }
static CGFloat YTMULyricGutterTrailing(void) { return 40.0; }

// Row vertical padding, held in one place so -ytmu_setRowCollapsed: can take it
// to zero. A hidden label still reports its intrinsic size through its
// constraints, so an "empty" row keeps a full lyric line's height unless the
// padding itself is collapsed.
static const CGFloat YTMURowPadTop = 14.0;
// Gap between a lyric line and its translation. 6pt read as a single glued
// string at 0.68x scale -- "Every single morning ((Huh)" followed by
// "（哈）每一個清晨" looked like one mangled line rather than two. The
// translation is already visually distinct (smaller, dimmer), it just needed
// room to be read as its own line.
static const CGFloat YTMURowPadGap = 10.0;
static const CGFloat YTMURowPadBottom = 14.0;
// Gap above a duet voice marker. Smaller than YTMURowPadTop on purpose: the
// marker belongs to the row it introduces, so it sits closer to the content
// edge and the lyric line below it keeps the same rhythm as every other line.
static const CGFloat YTMUSingerPadTop = 8.0;

// ---------------------------------------------------------------------------
// Duet display mode. Two answers to the same question, both asked for, so both
// ship and the user picks one in Lyrics settings:
//
//   kYTMUDuetOff      nothing
//   kYTMUDuetAlign    the second voice goes right-aligned, a shared line sits
//                     centred (drives lyricLabel.textAlignment, via
//                     YTMUVoiceAlignment below)
//   kYTMUDuetLabel    a small caps marker above the line, printed only where the
//                     singer changes (drives singerLabel)
//
// Default is ALIGN: the user picked it over the label on sight, then asked for
// the label back as a setting. The two are mutually exclusive at the single
// decision point -- YTMUVoiceAlignment returns Natural outside align mode -- so
// a row is never both right-aligned and carrying a marker.
// ---------------------------------------------------------------------------
typedef NS_ENUM(NSInteger, YTMUDuetDisplay) {
    kYTMUDuetOff = 0,
    kYTMUDuetAlign = 1,
    kYTMUDuetLabel = 2,
};

// Read from the local YTMUltimate pref dictionary, NOT the server app-settings
// table -- it is a per-device display choice like lyricsFullscreenAutoOpen, and
// there is no YTMUAppSettingInt to call (that was invented and does not exist).
// Cached behind NSUserDefaultsDidChangeNotification because -configureCell asks
// on every row on every activation change, and dictionaryForKey: is a
// deserialisation each time.
static YTMUDuetDisplay YTMUDuetDisplayMode(void) {
    static dispatch_once_t once;
    static BOOL dirty = YES;
    static YTMUDuetDisplay cached = kYTMUDuetAlign;
    dispatch_once(&once, ^{
        [[NSNotificationCenter defaultCenter]
            addObserverForName:NSUserDefaultsDidChangeNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *note) { dirty = YES; }];
    });
    if (dirty) {
        id v = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"][@"lyricsDuetDisplay"];
        NSInteger n = [v respondsToSelector:@selector(integerValue)] ? [v integerValue] : kYTMUDuetAlign;
        if (n < kYTMUDuetOff || n > kYTMUDuetLabel) n = kYTMUDuetAlign;
        cached = (YTMUDuetDisplay)n;
        dirty = NO;
    }
    return cached;
}

// The voice a line is sung by, as a comparable key, or nil when the file said
// nothing about it. `duet` is its own key rather than "singer 1 as well": both
// voices on one line is a different fact from either of them singing it.
//
// The server fills these in from the TTML's ttm:agent (server/parsers_ttml.py),
// nearest-wins over <p> -> <div> -> <body>. `singer` is an INDEX into the person
// agents declared in <head>, and the file gives no names -- the agents are empty
// elements -- so this never invents one.
static NSString *YTMUSingerVoiceKey(NSDictionary *lyric) {
    if (![lyric isKindOfClass:[NSDictionary class]]) return nil;
    if ([lyric[@"duet"] boolValue]) return @"both";
    id s = lyric[@"singer"];
    if (![s isKindOfClass:[NSNumber class]]) return nil;
    return [NSString stringWithFormat:@"p%ld", (long)[s integerValue]];
}

// Marker text for one row. The NUMBER is all the file gives us.
static NSString *YTMUSingerMarkerText(NSDictionary *lyric) {
    if ([lyric[@"duet"] boolValue]) return LOC(@"LYRICS_SINGER_BOTH");
    id s = lyric[@"singer"];
    if (![s isKindOfClass:[NSNumber class]]) return nil;
    NSInteger idx = [s integerValue];
    if (idx < 0 || idx > 15) return nil;
    return [NSString stringWithFormat:LOC(@"LYRICS_SINGER_N"), (long)(idx + 1)];
}

// ---------------------------------------------------------------------------
// Duet display is ALIGNMENT and nothing else: the second voice's lines go
// right-aligned and a shared line sits centred. See YTMUVoiceAlignment below,
// which -configureCell: applies to all three labels plus the instrumental
// ribbon.
//
// The alternative was a small caps "Singer 2" marker above the line, printed
// only where the singer changes. Its scaffolding was built and then removed: the
// user picked alignment on sight, and keeping the label meant a fourth vertical
// padding constraint on every row, a marker that had to be collapsed to zero
// height to stay out of a solo track's layout, and two localized strings, all
// for nothing. Do not re-add it without asking.
//
// The data is on the wire either way: server/parsers_ttml.py fills `singer` and
// `duet` in from the TTML's ttm:agent (commit 72225e9), so nothing server-side
// needs revisiting.

// The instrumental ribbon, as a pair of shapes. BOTH must have identical command
// structure -- same move, same four quads, same two lines, same close -- because
// CoreAnimation only interpolates between two CGPaths whose command sequences
// match. A mismatched pair snaps at the halfway point instead of flowing
// (braccato says the same of its own path() pair).
//
// Proportions are braccato's `M -4 3 Q 1 2 5 3 Q 10 4 14 3 Q 18 2 22 3 Q 26 4
// 30 3 L 30 4 L -4 4 Z`, mapped onto x in [0, width] and y in [0, amp] with y
// growing downward so y = amp is the baseline the wave flattens onto.
static UIBezierPath *YTMUWavePath(CGFloat width, CGFloat amp, BOOL high) {
    UIBezierPath *p = [UIBezierPath bezierPath];
    CGFloat w = MAX(width, 2.0);
    CGFloat a = MAX(amp, 2.0);
    CGFloat mid = a * 0.5;
    CGFloat crestY = high ? 0.0 : a;
    CGFloat troughY = high ? a : 0.0;
    [p moveToPoint:CGPointMake(0.0, mid)];
    [p addQuadCurveToPoint:CGPointMake(w * 0.2647, mid) controlPoint:CGPointMake(w * 0.1470, crestY)];
    [p addQuadCurveToPoint:CGPointMake(w * 0.5290, mid) controlPoint:CGPointMake(w * 0.4118, troughY)];
    [p addQuadCurveToPoint:CGPointMake(w * 0.7647, mid) controlPoint:CGPointMake(w * 0.6470, crestY)];
    [p addQuadCurveToPoint:CGPointMake(w * 1.0000, mid) controlPoint:CGPointMake(w * 0.8820, troughY)];
    [p addLineToPoint:CGPointMake(w, a)];
    [p addLineToPoint:CGPointMake(0.0, a)];
    [p closePath];
    return p;
}

@interface YTMULyricsCell (SheetRows)
// Returns YES when the row's height state actually changed, so the caller can
// ask the table to re-measure the self-sizing row.
- (BOOL)ytmu_setRowCollapsed:(BOOL)collapsed;
// (Re)arms the wave's repeating path animation. Defined below -layoutSubviews,
// which calls it, and declared here so that call is not an implicit method
// lookup.
- (void)ytmu_armWaveOscillation;
@end

@implementation YTMULyricsCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        self.lyricLabel = [[UILabel alloc] init];
        self.lyricLabel.numberOfLines = 0;
        self.lyricLabel.font = [UIFont boldSystemFontOfSize:YTMULyricMainFontSize()];
        self.lyricLabel.textColor = YTMULyricInk(0.45, 0.55, self.contentView);
        self.lyricLabel.layer.shadowColor = YTMULyricShadow(self.contentView).CGColor;
        self.lyricLabel.layer.shadowOffset = CGSizeMake(0, 2);
        self.lyricLabel.layer.shadowRadius = 4.0;
        self.lyricLabel.layer.masksToBounds = NO;
        // Rasterize text+shadow once per content change instead of
        // re-rendering the shadow every tick while the wipe mask animates
        // (the mask composites on top of the cached bitmap, cheaply).
        self.lyricLabel.layer.shouldRasterize = YES;
        self.lyricLabel.layer.rasterizationScale = [UIScreen mainScreen].scale;
        self.lyricLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:self.lyricLabel];

        self.wipeLabel = [[UILabel alloc] init];
        self.wipeLabel.numberOfLines = 0;
        self.wipeLabel.font = [UIFont boldSystemFontOfSize:YTMULyricMainFontSize()];
        self.wipeLabel.textColor = YTMULyricInk(1.0, 1.0, self.contentView);
        self.wipeLabel.layer.shadowColor = YTMULyricShadow(self.contentView).CGColor;
        // Centred, because this shadow is now the animated highlight glow rather
        // than a drop: the constant downward drop that keeps the bright text
        // readable over artwork lives in the attributed string's NSShadow, so
        // this one is free to swell around the word being sung. See
        // -applyWordColorsToCell:...force:.
        self.wipeLabel.layer.shadowOffset = CGSizeZero;
        self.wipeLabel.layer.shadowRadius = 0.0;
        self.wipeLabel.layer.shadowOpacity = 0.0;
        self.wipeLabel.layer.masksToBounds = NO;
        self.wipeLabel.layer.shouldRasterize = YES;
        self.wipeLabel.layer.rasterizationScale = [UIScreen mainScreen].scale;
        self.wipeLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.wipeLabel.userInteractionEnabled = YES;
        [self.contentView addSubview:self.wipeLabel];

        // Word-level tap-to-seek gesture
        UITapGestureRecognizer *tapGR = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(ytmu_handleWordTap:)];
        [self.wipeLabel addGestureRecognizer:tapGR];

        self.wipeMask = [CAShapeLayer layer];
        // A mask only reads alpha, so any opaque color masks identically;
        // keep it static white (no OS-theme dependency).
        self.wipeMask.fillColor = [UIColor whiteColor].CGColor;
        self.wipeMask.frame = CGRectZero;
        // The highlight is not binary. Completed glyphs are fully opaque and
        // the currently sung edge uses a moving alpha feather.
        CAGradientLayer *wipeFeather = [CAGradientLayer layer];
        wipeFeather.name = @"YTMULyricsWipeFeather";
        wipeFeather.colors = @[(id)[UIColor whiteColor].CGColor,
                               (id)[UIColor colorWithWhite:1 alpha:0.86].CGColor,
                               (id)[UIColor colorWithWhite:1 alpha:0.52].CGColor,
                               (id)[UIColor colorWithWhite:1 alpha:0.18].CGColor,
                               (id)[UIColor clearColor].CGColor];
        wipeFeather.locations = @[@0.0, @0.25, @0.55, @0.82, @1.0];
        wipeFeather.startPoint = CGPointMake(0.0, 0.5);
        wipeFeather.endPoint = CGPointMake(1.0, 0.5);
        wipeFeather.actions = @{@"position":[NSNull null], @"bounds":[NSNull null], @"frame":[NSNull null], @"hidden":[NSNull null]};
        [self.wipeMask addSublayer:wipeFeather];
        self.wipeLabel.layer.mask = self.wipeMask;
        _wipeProgress = 0.0;

        self.transLabel = [[UILabel alloc] init];
        self.transLabel.numberOfLines = 0;
        self.transLabel.font = [UIFont systemFontOfSize:YTMULyricTransFontSize() weight:UIFontWeightMedium];
        self.transLabel.textColor = YTMULyricInk(0.35, 0.5, self.contentView);
        self.transLabel.layer.shadowColor = YTMULyricShadow(self.contentView).CGColor;
        self.transLabel.layer.shadowOffset = CGSizeMake(0, 1);
        self.transLabel.layer.shadowRadius = 2.0;
        self.transLabel.layer.shadowOpacity = 0.35;
        self.transLabel.layer.masksToBounds = NO;
        self.transLabel.layer.shouldRasterize = YES;
        self.transLabel.layer.rasterizationScale = [UIScreen mainScreen].scale;
        self.transLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:self.transLabel];

        // Instrumental-gap ribbon. A bare shape layer on the content view: it is
        // the only lyric decoration that draws its own geometry, and it is
        // present on at most one row at a time.
        self.waveLayer = [CAShapeLayer layer];
        self.waveLayer.fillColor = [UIColor clearColor].CGColor;
        self.waveLayer.strokeColor = nil;
        // Baseline-anchored so the flatten in -layoutSubviews collapses the wave
        // downward onto y = amp instead of shrinking it about its middle.
        self.waveLayer.anchorPoint = CGPointMake(0.0, 1.0);
        self.waveLayer.hidden = YES;
        _waveWidth = 0.0;
        _waveProgress = 0.0;
        // Must start at 1.0, not the CGFloat zero value: -ytmu_setDistanceAlpha:
        // early-outs when the requested value already matches, so a zero here
        // would make the FIRST ladder pass on a fresh cell a no-op for a row
        // that should be at 0.0 -- and it would stay fully bright, five lines
        // from the sung one, until something else touched it.
        _distanceAlpha = 1.0;
        [self.contentView.layer addSublayer:self.waveLayer];

        // Voice marker for the kYTMUDuetLabel mode. Pinned to zero height unless
        // a duet actually changes singer on this row, so a solo track -- or a
        // song shown in align mode -- takes no extra vertical space at all.
        self.singerLabel = [[UILabel alloc] init];
        self.singerLabel.numberOfLines = 1;
        self.singerLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightBold];
        self.singerLabel.textColor = YTMULyricInk(0.55, 0.6, self.contentView);
        self.singerLabel.layer.shadowColor = YTMULyricShadow(self.contentView).CGColor;
        self.singerLabel.layer.shadowOffset = CGSizeMake(0, 1);
        self.singerLabel.layer.shadowRadius = 2.0;
        self.singerLabel.layer.shadowOpacity = 0.4;
        self.singerLabel.layer.masksToBounds = NO;
        self.singerLabel.layer.shouldRasterize = YES;
        self.singerLabel.layer.rasterizationScale = [UIScreen mainScreen].scale;
        self.singerLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:self.singerLabel];

        // Content sits well in from both edges; see YTMULyricGutter* above.
        CGFloat gutterLead = YTMULyricGutterLeading();
        CGFloat gutterTrail = YTMULyricGutterTrailing();
        [NSLayoutConstraint activateConstraints:@[
            [self.lyricLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:gutterLead],
            [self.lyricLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-gutterTrail],

            [self.wipeLabel.topAnchor constraintEqualToAnchor:self.lyricLabel.topAnchor],
            [self.wipeLabel.leadingAnchor constraintEqualToAnchor:self.lyricLabel.leadingAnchor],
            [self.wipeLabel.trailingAnchor constraintEqualToAnchor:self.lyricLabel.trailingAnchor],
            [self.wipeLabel.bottomAnchor constraintEqualToAnchor:self.lyricLabel.bottomAnchor],

            [self.transLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:gutterLead],
            [self.transLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-gutterTrail],

            [self.singerLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:gutterLead],
            [self.singerLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-gutterTrail]
        ]];
        // The three vertical padding constraints are kept (not inline) because
        // -ytmu_setRowCollapsed: rewrites their constants: an instrumental
        // marker that is not its turn must take no vertical space. The fourth
        // one pins the translation label to zero for the same reason -- the
        // ONLY height constraint on that anchor, so nothing can conflict with it
        // and normal rows keep sizing themselves.
        NSLayoutConstraint *singerPadTop = [self.singerLabel.topAnchor
            constraintEqualToAnchor:self.contentView.topAnchor constant:YTMUSingerPadTop];
        NSLayoutConstraint *padTop = [self.lyricLabel.topAnchor
            constraintEqualToAnchor:self.singerLabel.bottomAnchor constant:YTMURowPadTop];
        NSLayoutConstraint *padGap = [self.transLabel.topAnchor
            constraintEqualToAnchor:self.lyricLabel.bottomAnchor constant:YTMURowPadGap];
        NSLayoutConstraint *padBottom = [self.transLabel.bottomAnchor
            constraintEqualToAnchor:self.contentView.bottomAnchor constant:-YTMURowPadBottom];
        [NSLayoutConstraint activateConstraints:@[singerPadTop, padTop, padGap, padBottom]];
        NSLayoutConstraint *flat = [self.transLabel.heightAnchor constraintEqualToConstant:0.0];
        flat.active = NO;
        // singerFlat does for the voice marker what `flat` does for the
        // translation label: pins it to zero height, so it starts ACTIVE and a
        // solo track costs nothing. padTop now hangs off singerLabel.bottom
        // instead of contentView.top, which is what lets a marker become its own
        // line above the lyric; its constant keeps the same meaning, so the
        // `changed` test in -ytmu_setRowCollapsed: is untouched.
        NSLayoutConstraint *singerFlat = [self.singerLabel.heightAnchor constraintEqualToConstant:0.0];
        singerFlat.active = YES;
        // FIVE entries now, and the guard in -ytmu_setRowCollapsed: checks the
        // count. Growing this array without growing that guard is the silent way
        // to turn row collapsing off for every row in the sheet: it returns NO,
        // no constraint breaks, and the only symptom is that a collapsed
        // instrumental row keeps a full line of height.
        objc_setAssociatedObject(self, @selector(ytmu_setRowCollapsed:),
                                 @[padTop, padGap, padBottom, flat, singerFlat],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return self;
}

// Zero-height row (an instrumental marker outside its own window) or the
// normal auto-sized one. Only the vertical padding moves, so horizontal
// gutters and the automatic row height of a normal line are untouched.
- (BOOL)ytmu_setRowCollapsed:(BOOL)collapsed {
    NSArray *pack = objc_getAssociatedObject(self, @selector(ytmu_setRowCollapsed:));
    // A count mismatch here returns NO, i.e. the row silently stops collapsing
    // -- no constraint breaks and nothing is logged -- so this number has to
    // match the array in -init exactly. It was 4 until the duet voice marker
    // added singerFlat.
    if (pack.count != 5) return NO;
    NSLayoutConstraint *padTop = pack[0];
    NSLayoutConstraint *padGap = pack[1];
    NSLayoutConstraint *padBottom = pack[2];
    NSLayoutConstraint *flat = pack[3];
    NSLayoutConstraint *singerFlat = pack[4];
    BOOL changed = (padTop.constant != (collapsed ? 0.0 : YTMURowPadTop)) || (flat.active != collapsed);
    padTop.constant = collapsed ? 0.0 : YTMURowPadTop;
    padGap.constant = collapsed ? 0.0 : YTMURowPadGap;
    padBottom.constant = collapsed ? 0.0 : -YTMURowPadBottom;
    if (flat.active != collapsed) flat.active = collapsed;
    // A collapsed row is an instrumental marker, which nobody sings, so the
    // voice marker goes flat with it. On expand it is left alone: -configureCell
    // sets the real marker (or nil) immediately afterwards.
    if (collapsed && (singerFlat.active == NO || self.singerLabel.text.length)) {
        self.singerLabel.text = @"";
        singerFlat.active = YES;
        changed = YES;
    }
    [self setNeedsUpdateConstraints];
    [self setNeedsLayout];
    return changed;
}

// Show or clear this row's voice marker. Passing nil is the normal case and
// must be safe to call on every configure, including on a recycled cell that
// still holds the previous song's marker.
- (void)ytmu_setSingerMarker:(NSString *)text {
    BOOL show = text.length > 0;
    self.singerLabel.text = show ? text : @"";
    NSArray *pack = objc_getAssociatedObject(self, @selector(ytmu_setRowCollapsed:));
    if (pack.count != 5) return;
    NSLayoutConstraint *singerFlat = pack[4];
    // singerFlat ACTIVE == pinned to zero height, so it is active when hidden.
    if (singerFlat.active == !show) return;
    singerFlat.active = !show;
    [self setNeedsUpdateConstraints];
    [self setNeedsLayout];
}



- (void)setWipeProgress:(CGFloat)progress {
    _wipeProgress = MIN(MAX(progress, 0.0), 1.0);
    [self setNeedsLayout];
}

// --- braccato parity: the arrival/departure cross-fade -------------------------
//
// The revealed layer (wipeLabel) and the resting layer (lyricLabel) are both
// full copies of the line, so a highlight fade is just a fade between them: the
// active colour lives on the reveal layer on BOTH kinds of row now, which is
// what a line-synced row never had before (it swapped textColor, so it SNAPPED).
//
// Explicit CAAnimation rather than a UIView block, so the caller's value is the
// model value and a re-fade mid-flight retargets from what is on screen instead
// of jumping back to 0 or 1.
- (void)ytmu_fadeHighlightTo:(CGFloat)alpha duration:(NSTimeInterval)duration {
    CALayer *layer = self.wipeLabel.layer;
    CALayer *presented = (CALayer *)layer.presentationLayer;
    CGFloat from = presented ? (CGFloat)presented.opacity : (CGFloat)layer.opacity;
    [layer removeAnimationForKey:@"ytmuHighlightFade"];
    alpha = MIN(MAX(alpha, 0.0), 1.0);
    if (fabs(from - alpha) < 0.001) {
        layer.opacity = (float)alpha;
        return;
    }
    CABasicAnimation *anim = [CABasicAnimation animationWithKeyPath:@"opacity"];
    anim.fromValue = @(from);
    anim.toValue = @(alpha);
    anim.duration = MAX(duration, 0.0);
    anim.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    anim.fillMode = kCAFillModeForwards;
    anim.removedOnCompletion = NO;
    layer.opacity = (float)alpha;
    [layer addAnimation:anim forKey:@"ytmuHighlightFade"];
}

// The mask that reveals everything, for a row whose highlight is not word-timed.
// Written explicitly rather than left nil: a CAShapeLayer with a nil path is not
// a documented "show all" and has behaved differently across iOS versions.
- (void)ytmu_showFullWipe {
    CALayer *feather = nil;
    for (CALayer *sub in self.wipeMask.sublayers) {
        if ([sub.name isEqualToString:@"YTMULyricsWipeFeather"]) { feather = sub; break; }
    }
    feather.hidden = YES;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.wipeMask.frame = self.wipeLabel.bounds;
    self.wipeMask.path = [UIBezierPath bezierPathWithRect:self.wipeLabel.bounds].CGPath;
    [CATransaction commit];
}

// The arrival. Starts the reveal layer at nothing unless a fade is already in
// flight, so a line cannot simply appear at full brightness. A row whose
// fade-OUT is still running -- a fast line, or a tap-seek straight back -- is
// retargeted from whatever is actually on screen instead, which is what stops a
// visible dip on the way in.
- (void)ytmu_beginHighlightArrivalWithDuration:(NSTimeInterval)duration {
    CALayer *layer = self.wipeLabel.layer;
    if (![layer animationForKey:@"ytmuHighlightFade"]) {
        layer.opacity = 0.0;
    }
    [self ytmu_fadeHighlightTo:1.0 duration:duration];
}

- (void)ytmu_setDistanceAlpha:(CGFloat)alpha {
    alpha = MIN(MAX(alpha, 0.0), 1.0);
    if (fabs(alpha - self.distanceAlpha) < 0.005) return;
    _distanceAlpha = alpha;
    // contentView, not the cell: the cell's own alpha would fight
    // UITableView's selection/highlight plumbing and the row separators.
    self.contentView.alpha = alpha;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.wipeMask.frame = self.wipeLabel.bounds;
    if (!self.waveActive) {
        if (!self.waveLayer.hidden) self.waveLayer.hidden = YES;
        return;
    }
    CGRect lb = self.lyricLabel.bounds;
    CGFloat width = CGRectGetWidth(lb);
    CGFloat amp = (self.lyricLabel.font ? self.lyricLabel.font.pointSize : 22.0) * 0.30;
    if (width <= 2.0 || amp <= 2.0) {
        if (!self.waveLayer.hidden) self.waveLayer.hidden = YES;
        return;
    }
    self.waveLayer.hidden = NO;

    // Laid out from the label's CENTRE, never its frame: the arrival pop and the
    // word wobble both put a transform on this label, and a transformed view's
    // frame is undefined.
    CGPoint lc = self.lyricLabel.center;
    CGFloat x = lc.x - width * 0.5;
    if (self.ytmu_textAlign == NSTextAlignmentRight) x = lc.x + width * 0.5 - width;
    else if (self.ytmu_textAlign == NSTextAlignmentCenter) x = lc.x - width * 0.5;

    // Geometry is rebuilt only when the width really moved: a running `path`
    // animation would otherwise keep drawing the shape it captured, and
    // rebuilding it every layout pass would restart the oscillation 60 times a
    // second.
    if (fabs(width - self.waveWidth) > 0.5) {
        self.waveWidth = width;
        [self.waveLayer removeAnimationForKey:@"ytmuWaveOscillation"];
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.waveLayer.bounds = CGRectMake(0.0, 0.0, width, amp);
        self.waveLayer.path = YTMUWavePath(width, amp, YES).CGPath;
        [CATransaction commit];
        [self ytmu_armWaveOscillation];
    }
    // braccato flattens the wave across the gap's own length, ease-in, from a
    // 1.2x overshoot at the start down to flat.
    CGFloat t = MIN(MAX(self.waveProgress, 0.0), 1.0);
    CGFloat scaleY = 1.2 * (1.0 - t * t);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.wipeMask.frame = self.wipeLabel.bounds;
    self.waveLayer.position = CGPointMake(x, lc.y);
    self.waveLayer.transform = CATransform3DMakeScale(1.0, MAX(scaleY, 0.0001), 1.0);
    [CATransaction commit];
}

// The wave breathes whether or not the audio is playing (it is a repeating
// WAAPI animation there too), so it needs no clock of ours -- which also means
// it freezes by itself when playback pauses, since the render tree stops.
- (void)ytmu_armWaveOscillation {
    if (UIAccessibilityIsReduceMotionEnabled()) return;
    CGFloat width = self.waveLayer.bounds.size.width;
    CGFloat amp = self.waveLayer.bounds.size.height;
    if (width <= 2.0 || amp <= 2.0) return;
    CABasicAnimation *osc = [CABasicAnimation animationWithKeyPath:@"path"];
    osc.fromValue = (__bridge id)YTMUWavePath(width, amp, YES).CGPath;
    osc.toValue = (__bridge id)YTMUWavePath(width, amp, NO).CGPath;
    osc.duration = YTMUWaveOscillationDuration;
    osc.autoreverses = YES;
    osc.repeatCount = HUGE_VALF;
    osc.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [self.waveLayer addAnimation:osc forKey:@"ytmuWaveOscillation"];
}

- (void)clearWipe {
    _wipeProgress = 0.0;
    self.wipeLabel.text = nil;
    self.wipeLabel.attributedText = nil;
    self.wipeMask.path = nil;
    self.lastColorKey = nil;
    // A cell is reconfigured (not only recycled) on every activation change and
    // on reloadData, so the typewriter mask has to be dropped here too --
    // otherwise a half-revealed row survives a reconfigure of the same cell.
    [self ytmu_clearType];
    // Likewise a half-finished cross-fade: the reveal layer has to go back to
    // fully opaque, or the next row to use it inherits the previous line's fade
    // and appears dim for no reason.
    [self.wipeLabel.layer removeAnimationForKey:@"ytmuHighlightFade"];
    self.wipeLabel.layer.opacity = 1.0;
    self.wipeLabel.alpha = 1.0;
    self.wipeLabel.transform = CGAffineTransformIdentity;
    self.lyricLabel.transform = CGAffineTransformIdentity;
    self.lyricLabel.alpha = 1.0;
    // The glow is per-word state too: leaving it on a blanked row would light a
    // halo around nothing.
    self.wipeLabel.layer.shadowRadius = 0.0;
    self.wipeLabel.layer.shadowOpacity = 0.0;
    self.waveActive = NO;
    self.waveLayer.hidden = YES;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    _wipeProgress = 0.0;
    self.lyricLabel.alpha = 1.0;
    self.lyricLabel.transform = CGAffineTransformIdentity;
    self.wipeLabel.text = nil;
    self.wipeLabel.attributedText = nil;
    self.wipeMask.path = nil;
    self.lyricLabel.attributedText = nil;
    self.lastColorKey = nil;
    // A collapsed (zero-height) row must never be recycled as a normal line.
    [self ytmu_setRowCollapsed:NO];
    // ...and a duet voice marker must never survive into another row, let alone
    // another song. -configureCell sets the real one on the way out.
    [self ytmu_setSingerMarker:nil];
    // A half-revealed translation must never survive into another row.
    [self ytmu_clearType];
    // Same for the highlight cross-fade, the distance ladder and the ribbon:
    // all three are per-row state a recycled cell would otherwise carry.
    [self.wipeLabel.layer removeAnimationForKey:@"ytmuHighlightFade"];
    self.wipeLabel.layer.opacity = 1.0;
    self.wipeLabel.alpha = 1.0;
    self.wipeLabel.transform = CGAffineTransformIdentity;
    _distanceAlpha = 1.0;
    self.contentView.alpha = 1.0;
    self.waveActive = NO;
    self.waveWidth = 0.0;
    [self.waveLayer removeAnimationForKey:@"ytmuWaveOscillation"];
    self.waveLayer.hidden = YES;
}

- (void)ytmu_handleWordTap:(UITapGestureRecognizer *)gesture {
    CGPoint point = [gesture locationInView:self.wipeLabel];
    YTMULyricsViewController *vc = (YTMULyricsViewController *)[self _viewControllerForAncestor];
    if (!vc || !vc.isSynced) return;
    NSIndexPath *indexPath = [vc.tableView indexPathForCell:self];
    if (!indexPath) return;
    NSDictionary *lyric = vc.lyrics[indexPath.row];
    NSArray *parts = lyric[@"parts"];
    if (![lyric[@"wordSynced"] boolValue] || parts.count == 0) return;
    UIFont *font = self.wipeLabel.font;
    if (!font) font = [UIFont boldSystemFontOfSize:YTMULyricMainFontSize()];
    NSArray *ranges = nil;
    NSString *display = [vc wbwDisplayTextForLyric:lyric ranges:&ranges];
    if (ranges.count == 0) return;
    
    NSTextStorage *ts = [[NSTextStorage alloc] initWithString:display attributes:@{NSFontAttributeName: font}];
    NSLayoutManager *lm = [[NSLayoutManager alloc] init];
    NSTextContainer *tc = [[NSTextContainer alloc] initWithSize:self.wipeLabel.bounds.size];
    tc.lineFragmentPadding = 0;
    tc.maximumNumberOfLines = 0;
    tc.lineBreakMode = NSLineBreakByWordWrapping;
    [lm addTextContainer:tc];
    [ts addLayoutManager:lm];
    [lm ensureLayoutForTextContainer:tc];
    
    NSInteger charIndex = [lm characterIndexForPoint:point inTextContainer:tc fractionOfDistanceBetweenInsertionPoints:NULL];
    for (NSInteger i = 0; i < ranges.count; i++) {
        NSRange r = [ranges[i] rangeValue];
        if (r.location != NSNotFound && r.length > 0 && NSLocationInRange(charIndex, r)) {
            NSDictionary *part = parts[i];
            double startMs = [part[@"startTimeMs"] doubleValue];
            double seekTime = startMs / 1000.0;
            [[NSNotificationCenter defaultCenter] postNotificationName:@"YTMUSeekToTime" object:@(seekTime)];
            YTMULyricsViewController *seekVC = (YTMULyricsViewController *)[self _viewControllerForAncestor];
            if ([seekVC isKindOfClass:[YTMULyricsViewController class]]) {
                g_currentPlaybackTime = seekTime;
                seekVC.clockRawTime = seekTime;
                seekVC.clockRawWall = CACurrentMediaTime();
            }
            break;
        }
    }
}

@end


static BOOL __attribute__((unused)) YTMUIsLandscapeBounds(CGSize size) {
    return size.width > size.height;
}

// Exactly ONE close affordance per configuration. The portrait sheet header
// carries its own "X" (created only for the modal sheet) and the fullscreen
// layout has landscapeExitButton; both were visible at the same time in
// landscape, and the header's menu button also overlapped the exit button at
// the top-right corner. The header close button is therefore found by tag
// (LyricsShared.h owns the ivars and is not edited from here) and the header's
// two buttons are hidden for the whole time the landscape branch runs -- never
// destroyed, the portrait branch shows them again.
static const NSInteger YTMUHeaderCloseTag = 8889;
static UIButton *YTMUHeaderCloseButton(UIView *header) {
    if (!header) return nil;
    UIView *found = [header viewWithTag:YTMUHeaderCloseTag];
    return [found isKindOfClass:[UIButton class]] ? (UIButton *)found : nil;
}

// The engagement panel's own chrome. YTEngagementPanelHeaderView (title + the
// panel's dismiss control) is a SIBLING of the content container our view lives
// in, so ytmu_assertOnTop -- which only walks our own superview -- never saw it
// and its X stayed on screen next to ours. Hidden with our siblings while our
// lyrics fill the panel, restored on the way out.
static UIView *YTMUPanelHeaderSibling(UIView *container) {
    UIView *parent = container.superview;
    if (!parent) return nil;
    for (UIView *sub in parent.subviews) {
        if (sub == container) continue;
        if ([NSStringFromClass([sub class]) isEqualToString:@"YTEngagementPanelHeaderView"]) return sub;
    }
    return nil;
}

// Fullscreen retranslate button. LyricsShared.h owns the ivars and must not
// be edited from here, so the button is found through the toolbar by tag (the
// same pattern the album-card shadow uses with 7104).
static const NSInteger YTMURetranslateTag = 7105;
static UIButton *YTMURetranslateButton(UIView *toolbar) {
    return (UIButton *)[toolbar viewWithTag:YTMURetranslateTag];
}
// Latched while a retranslate is in flight, so the button cannot re-enter and
// the finishing path runs exactly once (payload landed, failure, watchdog).
static BOOL s_retranslateRunning = NO;

// Per-instance state that LyricsShared.h has no property for. Associated
// objects (not function statics: with a modal sheet AND the embedded panel
// live at once a static is shared by both, which is how the blur style got
// stuck on the first instance that ever resolved one).
//   s_ytmuArtRequestKey  video id whose cover this instance already asked for
//   s_ytmuBlurStyleKey   last blur style this instance applied
//   s_ytmuBlurHaveKey    whether that last style is meaningful
//   s_ytmuClosedByRotationKey  this instance was closed by the rotate-to-
//                              portrait path or by the auto-open switch going
//                              off, and no late payload may un-hide it again
static char s_ytmuArtRequestKey;
static char s_ytmuBlurStyleKey;
static char s_ytmuBlurHaveKey;
static char s_ytmuClosedByRotationKey;

// Private selectors used across the controller
@interface YTMULyricsViewController (LandscapePrivate)
- (void)ytmu_assertOnTop;
- (void)ytmu_collapseHostingPanel;
- (void)ytmu_restoreHostingPanelChrome;
- (void)ytmu_collapseRevealedNativeLyrics;
- (UIViewController *)ytmu_resolveHostingPanel;
- (BOOL)ytmu_tryCollapseTarget:(id)target;
- (void)ytmu_closeFullscreenWithReason:(NSString *)reason;
- (void)ytmu_enforceFullscreenAutoOpen;
- (void)ytmu_settingsChanged:(NSNotification *)note;
- (void)ytmu_applyHeaderButtonsForLandscape:(BOOL)landscape;
- (void)ytmu_requestArtworkOnce:(NSString *)videoID;
- (NSString *)ytmu_artworkTargetVideoID;
- (void)ytmu_refreshChromeInk;
- (void)ytmu_resolveProviderIndexSaved:(NSString *)saved;
- (void)ytmu_applyProviderAtIndex:(NSInteger)idx;
- (void)ytmu_stepProvider:(UIButton *)sender;
- (NSString *)ytmu_currentTier;
- (UIMenu *)ytmu_providerMenu;
- (void)ytmu_refreshProviderSwitcher;
- (void)ytmu_setProbing:(BOOL)probing;
- (void)ytmu_scrollToRow:(NSInteger)row instant:(BOOL)instant;
- (void)ytmu_retranslateTapped:(UIButton *)sender;
- (void)ytmu_endRetranslate:(BOOL)ok;
- (BOOL)ytmuIsInstrumentalLyric:(NSDictionary *)lyric;
- (void)ytmu_probeArtworkBrightness:(UIImage *)img;
- (void)ytmu_applySongTint:(UIImage *)img;
- (void)ytmu_refreshBgDerivedInk;
- (void)ytmu_applyArtworkImage:(UIImage *)img forVideoID:(NSString *)videoID;
- (void)ytmu_updateLandscapeMetadata;
- (void)ytmu_updateLandscapeMetadataFromNowPlayingLabels;
- (void)ytmu_collectNowPlayingLabelsIn:(UIView *)view depth:(NSInteger)depth out:(NSMutableArray *)out;
- (void)ytmu_updateLandscapeProgress;
- (void)ytmu_landscapePrev:(UIButton *)sender;
- (void)ytmu_landscapeNext:(UIButton *)sender;
- (void)ytmu_landscapePlayPause:(UIButton *)sender;
- (void)ytmu_setLandscapePlaying:(BOOL)playing;
- (void)ytmu_setLandscapeTransportIcons;
- (BOOL)ytmu_tryTapPlayPauseIn:(UIView *)view depth:(NSInteger)depth;
- (void)ytmu_applyLandscapeTheme;
- (NSString *)ytmu_formatTime:(CGFloat)seconds;
- (void)ytmu_toolbarReload:(UIButton *)sender;
- (void)ytmu_headerMenu:(UIButton *)sender;
- (void)ytmu_openProviderMenuFromView:(UIView *)sender;
- (void)ytmu_beginProviderProbeWithJWT:(NSString *)jwt fromView:(UIView *)sender;
- (void)ytmu_pollProviderJob:(NSTimer *)timer;
- (void)ytmu_stopProviderPoll;
- (void)ytmu_showProviderMenu:(NSArray *)candidates saved:(NSString *)saved fromView:(UIView *)sender;
- (void)ytmu_selectProvider:(NSString *)provider;
- (void)ytmu_postJSON:(NSString *)path body:(NSDictionary *)body completion:(void (^)(NSDictionary *json, NSError *error))completion;
- (void)ytmu_getJSON:(NSString *)path completion:(void (^)(NSDictionary *json, NSError *error))completion;
- (NSString *)ytmu_cleanVideoTitle:(NSString *)raw;
- (void)ytmu_requestSongMetaForVideo:(NSString *)videoID;
- (void)ytmu_wireStepperPress:(UIButton *)button;
- (void)ytmu_stepperPressIn:(UIButton *)button;
- (void)ytmu_stepperPressOut:(UIButton *)button;
- (void)ytmu_applyProviderMeta:(NSDictionary *)dict forVideoID:(NSString *)videoID;
- (void)ytmu_loadProviderMetaForVideo:(NSString *)videoID;
- (void)ytmu_loadProviderLyricsForVideo:(NSString *)videoID;
- (void)ytmu_startFullFetchForVideoID:(NSString *)videoID force:(BOOL)force from:(NSString *)from;
@end

BOOL YTMUIsInterfaceLandscape(void) {
    UIInterfaceOrientation o = UIInterfaceOrientationUnknown;
    if (@available(iOS 13.0, *)) {
        UIWindow *win = [UIApplication sharedApplication].keyWindow;
        if (!win) {
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                if (w.isKeyWindow || w.rootViewController) { win = w; break; }
            }
        }
        o = win.windowScene.interfaceOrientation;
    }
    if (o != UIInterfaceOrientationUnknown) {
        return UIInterfaceOrientationIsLandscape(o);
    }
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = (UIWindowScene *)[UIApplication sharedApplication].connectedScenes.anyObject;
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            return UIInterfaceOrientationIsLandscape(scene.interfaceOrientation);
        }
    }
    CGSize s = [UIScreen mainScreen].bounds.size;
    return s.width > s.height;
}

static void YTMUInvokeNoArgs(id obj, SEL sel) {
    if (!obj || ![obj respondsToSelector:sel]) return;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [obj performSelector:sel];
#pragma clang diagnostic pop
}

// "This instance was closed and must stay closed." Latched by the
// rotate-to-portrait close and by the auto-open switch going off while the
// panel is up, and consulted by every path that can bring the view back:
// updateLyrics: un-hides on any payload, and YTMULyricsDidLoad is a
// PROCESS-WIDE notification filtered only by video id, so a sibling
// instance's fetch used to resurrect a panel the user had just dismissed.
// Per-instance on purpose (associated object, not a file static) for the same
// reason as the other keys above: the modal and the embedded panel are
// frequently alive at the same time.
static BOOL YTMUIsClosedByRotation(id target) {
    if (!target) return NO;
    return [objc_getAssociatedObject(target, &s_ytmuClosedByRotationKey) boolValue];
}
static void YTMUSetClosedByRotation(id target, BOOL closed) {
    if (!target) return;
    objc_setAssociatedObject(target, &s_ytmuClosedByRotationKey, @(closed), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Orientation generation. Every orientation DECISION bumps it, and the two
// self-rescheduling retry chains (the landscape open chain and the post-tap
// fallback present) carry the value they were armed with: a decision that
// lands while a chain is mid-flight invalidates it instead of racing it.
// Without this, a chain armed for a landscape that is being rotated away still
// gets ~2.75s of retries to present behind the close.
static NSUInteger s_ytmuOrientationGeneration = 0;
static NSUInteger YTMUBumpOrientationGeneration(void) {
    return ++s_ytmuOrientationGeneration;
}
static NSUInteger YTMUCurrentOrientationGeneration(void) {
    return s_ytmuOrientationGeneration;
}

// The landscape fullscreen is a feature with a switch, not a behaviour: a
// missing key means ON, so an install that predates the settings row keeps
// auto-opening exactly as before.
static BOOL YTMULandscapeAutoOpenEnabled(void) {
    return YTMULyricsPreference(@"lyricsFullscreenAutoOpen", YES);
}

// True when `view` really lives inside `ancestor`'s view hierarchy. The
// nextResponder walk answers the NEAREST controller, so the collapse path
// needs this before it acts on a host: a controller that merely sits above us
// in the responder chain owns something else entirely.
static BOOL YTMUViewIsInsideView(UIView *view, UIView *ancestor) {
    if (!view || !ancestor) return NO;
    for (UIView *v = view; v; v = v.superview) {
        if (v == ancestor) return YES;
    }
    return NO;
}

// The tag-9999 view (our embedded lyrics) if one is really on screen. The
// close path uses it as the "is a lyrics-shaped view still up" test, which is
// what isLyricsViewVisibleOnScreen() answers but hands back the view itself.
static UIView *YTMULyricsTaggedViewOnScreen(void) {
    UIWindow *win = [UIApplication sharedApplication].keyWindow;
    if (!win) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow || w.rootViewController) { win = w; break; }
        }
    }
    if (!win) return nil;
    UIView *tagged = [win viewWithTag:9999];
    if (!tagged || tagged.hidden || tagged.alpha < 0.05 || !tagged.window) return nil;
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    CGRect r = [tagged convertRect:tagged.bounds toView:nil];
    CGRect isect = CGRectIntersection(screenBounds, r);
    if (!(isect.size.width > 50 && isect.size.height > 100)) return nil;
    return tagged;
}

@implementation YTMULyricsViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.currentIndex = -1;
    self.activeIndexes = nil;
    self.suppressWordSeekRow = -1;
    self.view.backgroundColor = YTMUBgBaseColor(self.view);

    self.artworkImageView = [[UIImageView alloc] initWithFrame:self.view.bounds];
    self.artworkImageView.contentMode = UIViewContentModeScaleAspectFill;
    self.artworkImageView.clipsToBounds = YES;
    self.artworkImageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view insertSubview:self.artworkImageView atIndex:0];

    UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:YTMUBgBlurStyle(self.view)];
    self.blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    self.blurView.frame = self.view.bounds;
    self.blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view insertSubview:self.blurView aboveSubview:self.artworkImageView];

    self.darkOverlay = [[UIView alloc] initWithFrame:self.view.bounds];
    // Dim the ambient blur for contrast; keyed on background brightness so
    // bright covers get the lighter wash and dark covers the heavier one.
    // Snapshot: refreshed with the bucket in ytmu_refreshBgDerivedInk.
    self.darkOverlay.backgroundColor = YTMUBgOverlayColor(self.view);
    self.darkOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view insertSubview:self.darkOverlay aboveSubview:self.blurView];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.showsVerticalScrollIndicator = NO;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 85.0;
    self.tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.tableView.contentInset = UIEdgeInsetsMake(20, 0, 350, 0);
    [self.tableView registerClass:[YTMULyricsCell class] forCellReuseIdentifier:@"YTMULyricsCell"];

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 54)];
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UILabel *statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 10, self.view.bounds.size.width, 36)];
    statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    statusLabel.textColor = YTMULyricInk(0.7, 0.75, self.view);
    statusLabel.textAlignment = NSTextAlignmentCenter;
    statusLabel.font = [UIFont systemFontOfSize:14];
    statusLabel.tag = 8888;
    [header addSubview:statusLabel];

    // Header action button: an icon that opens the actions menu
    // (provider list with live probing state, reload, close).
    UIButton *menuBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    menuBtn.frame = CGRectMake(self.view.bounds.size.width - 52, 10, 36, 36);
    menuBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    menuBtn.tintColor = YTMULyricInk(0.9, 0.9, self.view);
    if (@available(iOS 13.0, *)) {
        UIImage *menuImg = [UIImage systemImageNamed:@"list.bullet"];
        if (menuImg) {
            [menuBtn setImage:menuImg forState:UIControlStateNormal];
            [menuBtn setTitle:@"" forState:UIControlStateNormal];
        } else {
            [menuBtn setTitle:@"..." forState:UIControlStateNormal];
            [menuBtn setTitleColor:YTMULyricInk(0.9, 0.9, self.view) forState:UIControlStateNormal];
        }
    } else {
        [menuBtn setTitle:@"..." forState:UIControlStateNormal];
        [menuBtn setTitleColor:YTMULyricInk(0.9, 0.9, self.view) forState:UIControlStateNormal];
    }
    menuBtn.backgroundColor = YTMULyricFill(self.view);
    menuBtn.layer.cornerRadius = 18;
    [menuBtn addTarget:self action:@selector(ytmu_headerMenu:) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:menuBtn];
    self.headerMenuButton = menuBtn;

    if (self.isModal || self.presentingViewController) {
        UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        closeBtn.tag = YTMUHeaderCloseTag;
        closeBtn.accessibilityLabel = @"Close lyrics";
        closeBtn.frame = CGRectMake(16, 10, 36, 36);
        [closeBtn setTitle:@"X" forState:UIControlStateNormal];
        [closeBtn setTitleColor:YTMULyricInk(1.0, 1.0, self.view) forState:UIControlStateNormal];
        closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:18];
        closeBtn.backgroundColor = YTMULyricFill(self.view);
        closeBtn.layer.cornerRadius = 18;
        [closeBtn addTarget:self action:@selector(dismissModal) forControlEvents:UIControlEventTouchUpInside];
        [header addSubview:closeBtn];
    }

    // Offset controls are hidden from the header UI (per-song offset still
    // applies internally via YTMULyricsOffsetForVideoID when set).
    self.offsetButton = nil;

    self.tableView.tableHeaderView = header;

    [self.view addSubview:self.tableView];

    // --- Landscape split-view: Image-2 style ---
    // No opaque columns: the fullscreen blurred artwork (ambient) shows
    // through everywhere, the album floats as a rounded card with shadow,
    // and lyrics sit directly on the blur. Light/dark follows the OS via
    // the adaptive inks and ytmu_applyLandscapeTheme (blur style swap).
    self.landscapeArtPanel = [[UIView alloc] initWithFrame:CGRectZero];
    self.landscapeArtPanel.backgroundColor = [UIColor clearColor];
    self.landscapeArtPanel.clipsToBounds = NO;
    self.landscapeArtPanel.hidden = YES;
    self.landscapeArtPanel.userInteractionEnabled = YES;
    [self.view addSubview:self.landscapeArtPanel];

    self.landscapeArtImageView = [[UIImageView alloc] initWithFrame:CGRectZero];
    self.landscapeArtImageView.contentMode = UIViewContentModeScaleAspectFill;
    self.landscapeArtImageView.clipsToBounds = YES;
    self.landscapeArtImageView.backgroundColor = YTMULyricFill(self.view);
    self.landscapeArtImageView.userInteractionEnabled = NO;
    self.landscapeArtImageView.layer.cornerRadius = 10;
    self.landscapeArtImageView.layer.masksToBounds = YES;
    [self.landscapeArtPanel addSubview:self.landscapeArtImageView];

    // Right panel is unused in the Image-2 layout (lyrics float on the
    // ambient blur); kept hidden so no seam can appear.
    self.landscapeRightPanel = [[UIView alloc] initWithFrame:CGRectZero];
    self.landscapeRightPanel.backgroundColor = [UIColor clearColor];
    self.landscapeRightPanel.hidden = YES;
    self.landscapeRightPanel.userInteractionEnabled = NO;

    // Landscape left column container: transparent, holds title, artist,
    // progress + times, and the minimal transport row.
    self.landscapeInfoPanel = [[UIView alloc] initWithFrame:CGRectZero];
    self.landscapeInfoPanel.backgroundColor = [UIColor clearColor];
    self.landscapeInfoPanel.hidden = YES;
    self.landscapeInfoPanel.layer.cornerRadius = 0;
    self.landscapeInfoPanel.layer.masksToBounds = NO;
    self.landscapeInfoPanel.userInteractionEnabled = YES;
    [self.landscapeArtPanel addSubview:self.landscapeInfoPanel];

    self.landscapeTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.landscapeTitleLabel.font = [UIFont boldSystemFontOfSize:15];
    self.landscapeTitleLabel.textColor = YTMULyricInk(1.0, 1.0, self.view);
    self.landscapeTitleLabel.numberOfLines = 1;
    self.landscapeTitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.landscapeInfoPanel addSubview:self.landscapeTitleLabel];

    self.landscapeArtistLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.landscapeArtistLabel.font = [UIFont systemFontOfSize:12];
    self.landscapeArtistLabel.textColor = YTMULyricInk(0.6, 0.6, self.view);
    self.landscapeArtistLabel.numberOfLines = 1;
    self.landscapeArtistLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.landscapeInfoPanel addSubview:self.landscapeArtistLabel];

    self.landscapeProgressTrack = [[UIView alloc] initWithFrame:CGRectZero];
    self.landscapeProgressTrack.backgroundColor = YTMULyricInk(0.25, 0.2, self.view);
    self.landscapeProgressTrack.layer.cornerRadius = 1.5;
    self.landscapeProgressTrack.layer.masksToBounds = YES;
    [self.landscapeInfoPanel addSubview:self.landscapeProgressTrack];

    self.landscapeProgressFill = [[UIView alloc] initWithFrame:CGRectZero];
    self.landscapeProgressFill.backgroundColor = YTMULyricInk(0.95, 0.9, self.view);
    self.landscapeProgressFill.layer.cornerRadius = 1.5;
    self.landscapeProgressFill.layer.masksToBounds = YES;
    [self.landscapeProgressTrack addSubview:self.landscapeProgressFill];

    self.landscapeProgressKnob = [[UIView alloc] initWithFrame:CGRectZero];
    self.landscapeProgressKnob.backgroundColor = YTMULyricInk(1.0, 1.0, self.view);
    self.landscapeProgressKnob.layer.cornerRadius = 4;
    self.landscapeProgressKnob.layer.masksToBounds = YES;
    self.landscapeProgressKnob.userInteractionEnabled = NO;
    [self.landscapeInfoPanel addSubview:self.landscapeProgressKnob];

    self.landscapeElapsedLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.landscapeElapsedLabel.font = [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightRegular];
    self.landscapeElapsedLabel.textColor = YTMULyricInk(0.6, 0.6, self.view);
    self.landscapeElapsedLabel.text = @"0:00";
    [self.landscapeInfoPanel addSubview:self.landscapeElapsedLabel];

    self.landscapeTotalLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.landscapeTotalLabel.font = [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightRegular];
    self.landscapeTotalLabel.textColor = YTMULyricInk(0.6, 0.6, self.view);
    self.landscapeTotalLabel.textAlignment = NSTextAlignmentRight;
    self.landscapeTotalLabel.text = @"0:00";
    [self.landscapeInfoPanel addSubview:self.landscapeTotalLabel];

    // Minimal icon transport (Image-2): plain prev/next glyphs, play/pause
    // as a filled circle. Colors follow the OS theme via the icon setters.
    self.landscapePrevButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.landscapePrevButton.tintColor = YTMULyricInk(0.9, 0.9, self.view);
    self.landscapePrevButton.backgroundColor = [UIColor clearColor];
    self.landscapePrevButton.tag = 7101;
    self.landscapePrevButton.accessibilityLabel = @"Previous track";
    self.landscapePrevButton.userInteractionEnabled = YES;
    self.landscapePrevButton.exclusiveTouch = NO;
    [self.landscapePrevButton addTarget:self action:@selector(ytmu_landscapePrev:) forControlEvents:UIControlEventTouchUpInside];
    [self.landscapeInfoPanel addSubview:self.landscapePrevButton];

    self.landscapePlayButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.landscapePlayButton.tintColor = YTMULyricInk(1.0, 1.0, self.view);
    self.landscapePlayButton.backgroundColor = YTMULyricInk(1.0, 0.9, self.view);
    self.landscapePlayButton.layer.masksToBounds = YES;
    self.landscapePlayButton.tag = 7102;
    self.landscapePlayButton.accessibilityLabel = @"Play or pause";
    self.landscapePlayButton.userInteractionEnabled = YES;
    self.landscapePlayButton.exclusiveTouch = NO;
    [self.landscapePlayButton addTarget:self action:@selector(ytmu_landscapePlayPause:) forControlEvents:UIControlEventTouchUpInside];
    [self.landscapeInfoPanel addSubview:self.landscapePlayButton];

    self.landscapeNextButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.landscapeNextButton.tintColor = YTMULyricInk(0.9, 0.9, self.view);
    self.landscapeNextButton.backgroundColor = [UIColor clearColor];
    self.landscapeNextButton.layer.cornerRadius = 18;
    self.landscapeNextButton.tag = 7103;
    self.landscapeNextButton.accessibilityLabel = @"Next track";
    self.landscapeNextButton.userInteractionEnabled = YES;
    self.landscapeNextButton.exclusiveTouch = NO;
    [self.landscapeNextButton addTarget:self action:@selector(ytmu_landscapeNext:) forControlEvents:UIControlEventTouchUpInside];
    [self.landscapeInfoPanel addSubview:self.landscapeNextButton];
    self.landscapeIsPlaying = YES;
    [self ytmu_setLandscapeTransportIcons];

    // Exit: top-right icon button (xmark symbol, "X" text fallback)
    self.landscapeExitButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.landscapeExitButton.tintColor = YTMULyricInk(0.9, 0.9, self.view);
    if (@available(iOS 13.0, *)) {
        UIImage *xmark = [UIImage systemImageNamed:@"xmark"];
        if (xmark) {
            [self.landscapeExitButton setImage:xmark forState:UIControlStateNormal];
            [self.landscapeExitButton setTitle:@"" forState:UIControlStateNormal];
        } else {
            [self.landscapeExitButton setTitle:@"X" forState:UIControlStateNormal];
            [self.landscapeExitButton setTitleColor:YTMULyricInk(0.9, 0.9, self.view) forState:UIControlStateNormal];
            self.landscapeExitButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        }
    } else {
        [self.landscapeExitButton setTitle:@"X" forState:UIControlStateNormal];
        [self.landscapeExitButton setTitleColor:YTMULyricInk(0.9, 0.9, self.view) forState:UIControlStateNormal];
        self.landscapeExitButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    }
    self.landscapeExitButton.backgroundColor = YTMULyricFill(self.view);
    self.landscapeExitButton.layer.cornerRadius = 16;
    self.landscapeExitButton.hidden = YES;
    [self.landscapeExitButton addTarget:self action:@selector(dismissModal) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.landscapeExitButton];

    // Bottom-right floating toolbar (Image-2): provider list + reload icons.
    self.landscapeToolbar = [[UIView alloc] initWithFrame:CGRectZero];
    self.landscapeToolbar.backgroundColor = YTMULyricFill(self.view);
    self.landscapeToolbar.layer.cornerRadius = 17;
    self.landscapeToolbar.layer.masksToBounds = YES;
    self.landscapeToolbar.hidden = YES;
    [self.view addSubview:self.landscapeToolbar];

    self.landscapeProviderButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.landscapeProviderButton.tintColor = YTMULyricInk(0.9, 0.9, self.view);
    if (@available(iOS 13.0, *)) {
        UIImage *pImg = [UIImage systemImageNamed:@"list.bullet"];
        if (pImg) [self.landscapeProviderButton setImage:pImg forState:UIControlStateNormal];
    }
    if (!self.landscapeProviderButton.imageView.image) {
        [self.landscapeProviderButton setTitle:@"..." forState:UIControlStateNormal];
        [self.landscapeProviderButton setTitleColor:YTMULyricInk(0.9, 0.9, self.view) forState:UIControlStateNormal];
    }
    self.landscapeProviderButton.accessibilityLabel = @"Lyric providers";
    [self.landscapeProviderButton addTarget:self action:@selector(ytmu_openProviderMenuFromView:) forControlEvents:UIControlEventTouchUpInside];
    [self.landscapeToolbar addSubview:self.landscapeProviderButton];

    self.landscapeReloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.landscapeReloadButton.tintColor = YTMULyricInk(0.9, 0.9, self.view);
    if (@available(iOS 13.0, *)) {
        UIImage *rImg = [UIImage systemImageNamed:@"arrow.clockwise"];
        if (rImg) [self.landscapeReloadButton setImage:rImg forState:UIControlStateNormal];
    }
    if (!self.landscapeReloadButton.imageView.image) {
        [self.landscapeReloadButton setTitle:@"R" forState:UIControlStateNormal];
        [self.landscapeReloadButton setTitleColor:YTMULyricInk(0.9, 0.9, self.view) forState:UIControlStateNormal];
    }
    self.landscapeReloadButton.accessibilityLabel = @"Reload lyrics";
    [self.landscapeReloadButton addTarget:self action:@selector(ytmu_toolbarReload:) forControlEvents:UIControlEventTouchUpInside];
    [self.landscapeToolbar addSubview:self.landscapeReloadButton];

    // Retranslate the current song through the current provider: same force
    // fetch the reload path uses, but it keeps the on-screen lyrics and the
    // caches, so nothing flashes empty while the new translation streams in.
    UIButton *retranslateBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    retranslateBtn.tag = YTMURetranslateTag;
    retranslateBtn.tintColor = YTMULyricInk(0.9, 0.9, self.view);
    if (@available(iOS 13.0, *)) {
        // iOS 13 symbol only; a nil image falls through to the text title.
        UIImage *tImg = [UIImage systemImageNamed:@"globe"];
        if (tImg) {
            [retranslateBtn setImage:tImg forState:UIControlStateNormal];
            [retranslateBtn setTitle:@"" forState:UIControlStateNormal];
        }
    }
    if (!retranslateBtn.imageView.image) {
        [retranslateBtn setTitle:@"T" forState:UIControlStateNormal];
        [retranslateBtn setTitleColor:YTMULyricInk(0.9, 0.9, self.view) forState:UIControlStateNormal];
        retranslateBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    }
    retranslateBtn.accessibilityLabel = @"Retranslate lyrics";
    [retranslateBtn addTarget:self action:@selector(ytmu_retranslateTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.landscapeToolbar addSubview:retranslateBtn];

    // Provider switcher (Image-1 style): [<] [list] [name i/n] [>] so the
    // source can be flipped anytime without re-probing. Stepper tags are
    // the signed step (-1/+1), handled by ytmu_stepProvider:.
    self.providerPrevButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.providerPrevButton.tag = -1;
    if (@available(iOS 13.0, *)) {
        UIImage *pImg = [UIImage systemImageNamed:@"chevron.left"];
        if (pImg) [self.providerPrevButton setImage:pImg forState:UIControlStateNormal];
    }
    if (!self.providerPrevButton.imageView.image) {
        [self.providerPrevButton setTitle:@"<" forState:UIControlStateNormal];
    }
    self.providerPrevButton.accessibilityLabel = @"Previous lyric provider";
    [self.providerPrevButton addTarget:self action:@selector(ytmu_stepProvider:) forControlEvents:UIControlEventTouchUpInside];
    [self ytmu_wireStepperPress:self.providerPrevButton];
    [self.landscapeToolbar addSubview:self.providerPrevButton];

    self.providerNextButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.providerNextButton.tag = 1;
    if (@available(iOS 13.0, *)) {
        UIImage *nImg = [UIImage systemImageNamed:@"chevron.right"];
        if (nImg) [self.providerNextButton setImage:nImg forState:UIControlStateNormal];
    }
    if (!self.providerNextButton.imageView.image) {
        [self.providerNextButton setTitle:@">" forState:UIControlStateNormal];
    }
    self.providerNextButton.accessibilityLabel = @"Next lyric provider";
    [self.providerNextButton addTarget:self action:@selector(ytmu_stepProvider:) forControlEvents:UIControlEventTouchUpInside];
    [self ytmu_wireStepperPress:self.providerNextButton];
    [self.landscapeToolbar addSubview:self.providerNextButton];

    self.providerSwitcherLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.providerSwitcherLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    self.providerSwitcherLabel.textAlignment = NSTextAlignmentCenter;
    self.providerSwitcherLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.providerSwitcherLabel.text = @"—";
    self.providerSwitcherLabel.userInteractionEnabled = NO;
    [self.landscapeToolbar addSubview:self.providerSwitcherLabel];

    self.providerCache = [NSMutableDictionary dictionary];
    self.providerCandidates = nil;
    self.providerIndex = -1;
    // Typewriter reveal + streaming translation state (Source/LyricsStream.x).
    self.typeState = [NSMutableDictionary dictionary];
    self.typeRows = [NSMutableSet set];
    self.typeLastWall = 0;
    self.tstreamClient = nil;
    self.tstreamVideoID = nil;

    self.fpsLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 64, 140, 24)];
    self.fpsLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
    self.fpsLabel.textColor = YTMULyricInk(0.7, 0.75, self.view);
    self.fpsLabel.hidden = YES;
    self.fpsLabel.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
    [self.view addSubview:self.fpsLabel];
    self.fpsTicks = 0;
    self.fpsWindowStart = 0;
    self.lastVolume = -1;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ytmu_volumeChanged:) name:@"AVSystemController_SystemVolumeDidChangeNotification" object:nil];

    self.lyrics = @[];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleSongChange:) name:@"YTMUSongDidChange" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleLyricsDidLoad:) name:@"YTMULyricsDidLoad" object:nil];
    // The auto-open switch can be flipped while this panel is up (from the
    // settings page), and the user expects it to go away rather than stay
    // stranded until the next rotation. The tick re-checks at ~1/s as a backstop
    // for a write that does not raise the notification.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(ytmu_settingsChanged:)
                                                 name:NSUserDefaultsDidChangeNotification
                                               object:nil];

    // Two-rate tick: the link runs at 120fps so ANIMATIONS (wipe mask,
    // activation pop, scrolling) stay smooth, but lyric STATE work stays
    // cheap -- incremental scan, rasterized labels, TextKit layout only on
    // content change, mask-path rewrite only when the word quantum changes.
    // (braccato's web engine is built the same way: near-zero per-frame
    // work, cached measurement, culled lines.)
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(updatePlaybackTime)];
    if (@available(iOS 15.0, *)) {
        self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(60, 120, 120);
    } else if ([self.displayLink respondsToSelector:@selector(setPreferredFramesPerSecond:)]) {
        self.displayLink.preferredFramesPerSecond = 120;
    }
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

    [self ytmu_refreshOffsetLabel];
    // Apply background-keyed chrome once up front (falls back to the OS
    // theme until the first artwork brightness probe lands).
    [self ytmu_refreshChromeInk];
    [self ytmu_refreshProviderSwitcher];
}

- (void)ytmu_refreshOffsetLabel {
    if (!self.offsetButton) return;
    double offset = (g_currentVideoID.length) ? YTMULyricsOffsetForVideoID(g_currentVideoID) : 0.0;
    if (fabs(offset) < 0.05) {
        [self.offsetButton setTitle:@"±0.0s" forState:UIControlStateNormal];
    } else {
        [self.offsetButton setTitle:[NSString stringWithFormat:@"%+.1fs", offset] forState:UIControlStateNormal];
    }
}

- (void)ytmu_nudgeOffset:(UIButton *)sender {
    double delta = (sender.tag == 0) ? -0.5 : 0.5;
    double offset = YTMULyricsOffsetForVideoID(g_currentVideoID);
    offset += delta;
    if (offset > 30.0) offset = 30.0;
    if (offset < -30.0) offset = -30.0;
    YTMULyricsSetOffsetForVideoID(g_currentVideoID, offset);
    [self ytmu_refreshOffsetLabel];
}

- (void)ytmu_resetOffset {
    YTMULyricsSetOffsetForVideoID(g_currentVideoID, 0.0);
    [self ytmu_refreshOffsetLabel];
}

- (void)dismissModal {
    if (self.presentingViewController || self.navigationController.presentingViewController) {
        [self dismissViewControllerAnimated:YES completion:nil];
        // Whatever this sheet was covering is about to become visible. If it is
        // another lyrics surface, the user is left looking at two of them and
        // the second one has no close control they know about, so it goes too.
        // Deferred past the dismissal animation: the panel only becomes the
        // top-most controller once our view is out of the way.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self ytmu_collapseRevealedNativeLyrics];
        });
        return;
    }
    // Embedded (engagement panel tag 9999): leaving means putting the panel
    // back exactly as we found it. ytmu_assertOnTop hides our siblings (and the
    // panel's own header, so only one close control is ever on screen) and
    // nothing un-hid them before, which left a blank panel after leaving.
    // The whole branch is behind the superview test: with no container we are
    // not embedded in anything (the panel already dropped us, or this was a
    // sheet that never landed in one), and un-hiding a panel we never touched
    // or collapsing a host that does not own us would take an unrelated view
    // down on the way out.
    if (self.view.superview) {
        [self ytmu_restoreHostingPanelChrome];
        self.view.hidden = YES;
        sendDebugLog(@"[MUSIC] landscape exit: hid embedded lyrics view");
        // The panel itself has to go too, otherwise a landscape user who
        // reached this state through the embedded panel is left looking at it.
        // Safe by construction: if no collapse selector answers, the panel
        // simply shows its own content again, with its own close control back
        // in the header.
        [self ytmu_collapseHostingPanel];
    }
}

// Close the fullscreen, whoever asked for it (rotate to portrait, the auto-open
// switch going off, and the exit buttons keep their own path through
// dismissModal). Two things this adds on top of the dismissal itself:
//
//   1. The "stay closed" latch. updateLyrics: un-hides the view on any
//      payload, and YTMULyricsDidLoad is process-wide and filtered only by
//      video id, so a fetch belonging to a sibling instance landed here after
//      the close and brought the panel straight back.
//   2. The state a close must release. Left latched, the next open sits at
//      "Waiting..." until the 45s fetch-slot reclaim, because this instance
//      still owns the instance slot and possibly the process-wide one.
- (void)ytmu_closeFullscreenWithReason:(NSString *)reason {
    if (YTMUIsClosedByRotation(self)) {
        sendDebugLog(@"[MUSIC] landscape fullscreen already closed, ignoring repeat close");
        return;
    }
    YTMUSetClosedByRotation(self, YES);
    sendDebugLog([NSString stringWithFormat:@"[MUSIC] landscape fullscreen closing: %@",
                  reason.length ? reason : @"unspecified"]);

    // Producers first, in the order that stops them from repainting a view
    // that is on its way out: the provider probe, the retranslate latch (which
    // also restores the toolbar) and the translate stream. The stream is
    // cancelled BEFORE the dismissal, so a line cannot land between the close
    // and the teardown.
    [self ytmu_stopProviderPoll];
    [self ytmu_setProbing:NO];
    if (s_retranslateRunning) [self ytmu_endRetranslate:NO];
    [self ytmu_cancelTranslateStream];

    self.isLoading = NO;
    self.loadingSince = nil;
    // Only the instance that claimed the process-wide slot may hand it back: a
    // sibling instance fetching the same song would otherwise lose its own.
    NSString *mine = self.loadingVideoID;
    if (g_globalLoadingInFlight && mine.length && [g_globalLoadingVideoID isEqualToString:mine]) {
        YTMUReleaseGlobalFetch();
    }
    // Visible: from here the view is never on screen again for this instance
    // (dismissModal hides the embedded one, the dismissal takes the modal's
    // view out of the window), and every re-show path now checks the latch.
    [self dismissModal];
}

// The auto-open switch has the final word over the panel it owns. Read from the
// tick (~1/s) and from the settings-changed notification, so switching it off
// while the fullscreen is up takes the panel down immediately instead of
// stranding it until the next rotation.
- (void)ytmu_enforceFullscreenAutoOpen {
    if (YTMULandscapeAutoOpenEnabled()) return;
    // The switch governs the LANDSCAPE fullscreen only: a portrait bottom sheet
    // opened by a tap belongs to that tap, and must survive the switch.
    if (!YTMUIsInterfaceLandscape()) return;
    if (YTMUIsClosedByRotation(self)) return;
    if (self.view.hidden || self.view.alpha < 0.05 || !self.view.window) return;
    [self ytmu_closeFullscreenWithReason:@"lyricsFullscreenAutoOpen switched off"];
}

- (void)ytmu_settingsChanged:(NSNotification *)note {
    // App defaults churn (YT writes its own keys constantly), so keep this to
    // one dictionary read and a pointer-free decision. NSUserDefaults posts on
    // whichever thread wrote; the work itself is main-thread UI.
    if ([NSThread isMainThread]) {
        [self ytmu_enforceFullscreenAutoOpen];
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self ytmu_enforceFullscreenAutoOpen];
    });
}

// Undo everything ytmu_assertOnTop hid while our lyrics were on top. The panel
// header is a sibling of the content container, so it is restored separately.
- (void)ytmu_restoreHostingPanelChrome {
    UIView *container = self.view.superview;
    if (!container) return;
    for (UIView *sub in container.subviews) {
        if (sub != self.view && sub.tag != 9999) sub.hidden = NO;
    }
    // The re-order below is meaningless without a parent, and the header is a
    // child of it: bail rather than un-hide views in a container the window has
    // already torn down.
    UIView *parent = container.superview;
    if (!parent) return;
    UIView *panelHeader = YTMUPanelHeaderSibling(container);
    if (panelHeader) {
        panelHeader.hidden = NO;
        [parent bringSubviewToFront:panelHeader];
    }
    [parent bringSubviewToFront:container];
}

// The panel our view is embedded in, or nil. _viewControllerForAncestor
// answers the NEAREST controller, which for our own view is this very
// controller (and for the embedded instance the next hop up is whatever sheet
// happens to be above us), so walk the responder chain and keep the first
// controller that is neither us nor a sibling of ours AND that demonstrably
// contains our view. A host we cannot prove owns us is a host we must not
// collapse: that was how the last-resort dismissal could take an unrelated
// view controller down with it.
- (UIViewController *)ytmu_resolveHostingPanel {
    for (UIView *v = self.view; v; v = v.superview) {
        // nextResponder is typed UIResponder *, so the class test and the cast
        // both have to happen here.
        id responder = [v nextResponder];
        if (![responder isKindOfClass:[UIViewController class]]) continue;
        UIViewController *vc = (UIViewController *)responder;
        if ((UIViewController *)self == vc) continue;
        if ([vc isKindOfClass:[YTMULyricsViewController class]]) continue;
        if (!YTMUViewIsInsideView(self.view, vc.view)) continue;
        return vc;
    }
    return nil;
}

// One guarded pass of the collapse selector list over one target. Every hop is
// behind respondsToSelector + @try, and the call is wrapped: an unknown YT
// selector must never cost the user their way out of the panel. YES when a
// selector actually answered, so the caller knows whether to keep looking.
- (BOOL)ytmu_tryCollapseTarget:(id)target {
    if (!target) return NO;
    SEL oneArgBool[] = {
        @selector(dismissEngagementPanelAnimated:),
        @selector(closeEngagementPanelAnimated:),
        @selector(hideEngagementPanelAnimated:),
    };
    SEL noArg[] = {
        @selector(collapseEngagementPanel),
        @selector(dismissEngagementPanel),
    };
    for (NSUInteger i = 0; i < sizeof(oneArgBool) / sizeof(oneArgBool[0]); i++) {
        if (![target respondsToSelector:oneArgBool[i]]) continue;
        @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [target performSelector:oneArgBool[i] withObject:@YES];
#pragma clang diagnostic pop
            sendDebugLog([NSString stringWithFormat:@"[MUSIC] landscape exit: collapsed panel via %@",
                          NSStringFromSelector(oneArgBool[i])]);
            return YES;
        } @catch (NSException *e) {
            sendDebugLog(@"[WARN] landscape exit: panel collapse selector threw");
        }
    }
    for (NSUInteger i = 0; i < sizeof(noArg) / sizeof(noArg[0]); i++) {
        if (![target respondsToSelector:noArg[i]]) continue;
        @try {
            YTMUInvokeNoArgs(target, noArg[i]);
            sendDebugLog([NSString stringWithFormat:@"[MUSIC] landscape exit: collapsed panel via %@",
                          NSStringFromSelector(noArg[i])]);
            return YES;
        } @catch (NSException *e) {
            sendDebugLog(@"[WARN] landscape exit: panel collapse selector threw");
        }
    }
    return NO;
}

// Collapse/dismiss the panel our view is embedded in.
- (void)ytmu_collapseHostingPanel {
    UIViewController *host = [self ytmu_resolveHostingPanel];
    if (!host) {
        sendDebugLog(@"[MUSIC] landscape exit: no host view controller, panel left as-is");
        return;
    }
    NSMutableArray *targets = [NSMutableArray array];
    [targets addObject:host];
    id container = g_activeEngagementPanelContainer;
    if (container && ![container isEqual:host]) [targets addObject:container];
    for (id target in targets) {
        if ([self ytmu_tryCollapseTarget:target]) return;
    }
    // Last resort: the panel VC is itself presented, so dismissing it is the
    // one exit that always exists. Gated on the host really containing our view
    // (the resolver proved that) and on it not already going away: with the
    // view detached -- the panel collapsed itself first, say -- there is
    // nothing of ours left in it, and dismissing it would take a controller
    // the user never had on screen down with them.
    if (YTMUViewIsInsideView(self.view, host.view) && !host.isBeingDismissed &&
        (host.presentedViewController || host.presentingViewController)) {
        [host dismissViewControllerAnimated:YES completion:nil];
        sendDebugLog(@"[MUSIC] landscape exit: dismissed hosting panel");
        return;
    }
    sendDebugLog(@"[MUSIC] landscape exit: no collapse selector, native panel left visible");
}

// Nothing lyrics-shaped may survive our fullscreen. Closing it can uncover the
// native panel we were covering (tag 9999's host, the engagement panel behind
// the sheet, or a lyrics panel presented under us), and a second lyrics view
// with no close control of its own is worse than no lyrics view at all. Runs
// after the dismissal animation, so the thing we are looking for is on top by
// then.
//
// Two ways to tell something is still up: our own tag-9999 view is on screen,
// or the top-most controller IS a lyrics panel. Both are proofs, not guesses,
// which is what lets the dismissal fallback below stay safe.
//
// Reachability, most precise first: the controller that owns the tag-9999 view,
// the tracked engagement panel container, and the top-most controller when it
// is itself a lyrics panel. Same guarded selector pass as the hosting-panel
// collapse, and the same "refuse unless it owns us" rule on the dismissal.
- (void)ytmu_collapseRevealedNativeLyrics {
    UIView *tagged = YTMULyricsTaggedViewOnScreen();
    UIViewController *top = topMostViewController();
    BOOL topIsLyricsPanel = isLyricsEngagementPanel(top);
    if (!tagged && !topIsLyricsPanel) {
        sendDebugLog(@"[MUSIC] landscape exit: nothing lyrics-shaped left behind, no collapse needed");
        return;
    }
    NSMutableArray *targets = [NSMutableArray array];
    UIViewController *panelHost = nil;
    for (UIView *v = tagged; v && !panelHost; v = v.superview) {
        id responder = [v nextResponder];
        if (![responder isKindOfClass:[UIViewController class]]) continue;
        UIViewController *vc = (UIViewController *)responder;
        if ([vc isKindOfClass:[YTMULyricsViewController class]]) continue;
        if (!YTMUViewIsInsideView(tagged, vc.view)) continue;
        panelHost = vc;
    }
    if (panelHost) [targets addObject:panelHost];
    id container = g_activeEngagementPanelContainer;
    if (container && ![container isEqual:panelHost]) [targets addObject:container];
    if (top && topIsLyricsPanel && ![targets containsObject:top]) [targets addObject:top];

    for (id target in targets) {
        if ([self ytmu_tryCollapseTarget:target]) return;
    }
    // Fallbacks, each behind a proof: the controller that demonstrably contains
    // the lyrics view, or a top-most controller already identified as a lyrics
    // panel. Never this controller, and never a view controller we cannot show
    // is lyrics-shaped.
    UIViewController *dismissible = panelHost ?: (topIsLyricsPanel ? top : nil);
    UIView *proof = tagged ?: top.view;
    if (dismissible && dismissible != (UIViewController *)self && !dismissible.isBeingDismissed &&
        YTMUViewIsInsideView(proof, dismissible.view) &&
        (dismissible.presentedViewController || dismissible.presentingViewController)) {
        [dismissible dismissViewControllerAnimated:YES completion:nil];
        sendDebugLog([NSString stringWithFormat:@"[MUSIC] landscape exit: dismissed revealed %@",
                      panelHost ? @"native lyrics panel" : @"lyrics panel"]);
        return;
    }
    sendDebugLog(@"[WARN] landscape exit: a lyrics view is still on screen and no collapse path answered");
}

// Video titles carry qualifiers the track name does not ("(Official Video)",
// "- Topic", "【MV】", "| 4K"). Keep the first segment, drop the bracketed
// qualifiers, so the full screen header reads like the song it is.
- (NSString *)ytmu_cleanVideoTitle:(NSString *)raw {
    if (!raw.length) return nil;
    NSString *head = raw;
    NSRange bar = [raw rangeOfString:@"|"];
    if (bar.location != NSNotFound) head = [raw substringToIndex:bar.location];
    head = [head stringByReplacingOccurrencesOfString:@" - Topic" withString:@""];
    NSCharacterSet *brackets = [NSCharacterSet characterSetWithCharactersInString:@"()[]【】「」"];
    NSMutableString *out = [NSMutableString string];
    NSUInteger i = 0;
    while (i < head.length) {
        unichar c = [head characterAtIndex:i];
        if (![brackets characterIsMember:c]) {
            [out appendFormat:@"%C", c];
            i++;
            continue;
        }
        NSUInteger close = i + 1;
        while (close < head.length && ![brackets characterIsMember:[head characterAtIndex:close]]) close++;
        NSString *inner = (close < head.length)
            ? [head substringWithRange:NSMakeRange(i + 1, close - i - 1)] : @"";
        NSString *low = inner.lowercaseString;
        BOOL qualifier = ([low containsString:@"official"] || [low containsString:@"video"] ||
                          [low containsString:@"lyric"] || [low containsString:@"mv"] ||
                          [low containsString:@"歌詞"] || [low containsString:@"歌词"] ||
                          [low containsString:@"audio"] || [low containsString:@"hd"] ||
                          [low containsString:@"hq"] || [low containsString:@"m/v"] ||
                          [low containsString:@"visualizer"]);
        if (!qualifier) [out appendString:inner];  // 【初音ミク】 is part of the name
        i = (close < head.length) ? close + 1 : close;
    }
    NSString *cleaned = [out stringByTrimmingCharactersInSet:
                         [NSCharacterSet characterSetWithCharactersInString:@" -|·"]];
    return cleaned.length ? cleaned : raw;
}

- (void)ytmu_updateLandscapeMetadata {
    // Safety net for the cover: every path that refreshes this header (the song
    // change, the stream's meta event, a layout pass) also makes sure the new
    // song's artwork is on its way, so the fullscreen card never waits for the
    // lyrics. ytmu_requestArtworkOnce: makes it a no-op once asked for.
    [self ytmu_requestArtworkOnce:[self ytmu_artworkTargetVideoID]];
    // Priority: server song info (the real track name/artist, the same
    // metadata the lyrics were fetched with) > player video details > the
    // visible now-playing labels. playerResponse is frequently nil and its
    // title is the video title, so it never outranks the server's.
    NSString *title = self.lastSongTitle.length ? self.lastSongTitle : nil;
    NSString *artist = self.lastSongArtist.length ? self.lastSongArtist : nil;
    if (!title.length || !artist.length) {
        @try {
            YTPlayerViewController *player = g_activePlayer;
            if (player && [player respondsToSelector:@selector(playerResponse)]) {
                YTPlayerResponse *resp = player.playerResponse;
                if (resp && [resp respondsToSelector:@selector(playerData)]) {
                    YTIPlayerResponse *data = resp.playerData;
                    if (data && [data respondsToSelector:@selector(videoDetails)]) {
                        YTIVideoDetails *details = data.videoDetails;
                        if (details) {
                            if (!title.length && [details respondsToSelector:@selector(title)]) {
                                title = [self ytmu_cleanVideoTitle:details.title];
                            }
                            if (!artist.length && [details respondsToSelector:@selector(author)]) {
                                artist = [self ytmu_cleanVideoTitle:details.author];
                            }
                        }
                    }
                }
            }
        } @catch (NSException *e) {
            // Keep whatever we already had; a throwing accessor is not a
            // reason to blank the header.
        }
    }
    // Still missing something (offline, or the player objects are empty):
    // scrape the now-playing labels. It only fills gaps, never overwrites.
    if (!title.length || !artist.length) {
        [self ytmu_updateLandscapeMetadataFromNowPlayingLabels];
        if (!title.length && self.landscapeTitleLabel.text.length &&
            ![self.landscapeTitleLabel.text isEqualToString:@"Now Playing"]) {
            title = self.landscapeTitleLabel.text;
        }
        if (!artist.length && self.landscapeArtistLabel.text.length) {
            artist = self.landscapeArtistLabel.text;
        }
    }
    // Never blank a known value: playerResponse goes nil mid-transition.
    // Scraped label text is NOT promoted into lastSongTitle/lastSongArtist:
    // that pair is the server's real track metadata and must stay clean (it
    // also decides whether a metadata re-fetch is still needed).
    if (title.length) {
        if (![self.landscapeTitleLabel.text isEqualToString:title]) {
            self.landscapeTitleLabel.text = title;
        }
    } else if (!self.landscapeTitleLabel.text.length) {
        self.landscapeTitleLabel.text = @"Now Playing";
    }
    if (artist.length) {
        if (![self.landscapeArtistLabel.text isEqualToString:artist]) {
            self.landscapeArtistLabel.text = artist;
        }
    }
}

// One metadata round trip per song change: the server knows the real track
// name for any video id, so the full screen header is never left on
// "Now Playing" waiting for playerResponse to arrive.
- (void)ytmu_requestSongMetaForVideo:(NSString *)videoID {
    if (!videoID.length) return;
    if ([videoID isEqualToString:self.songMetaVideoID] &&
        (self.lastSongTitle.length || self.lastSongArtist.length)) {
        return;
    }
    self.songMetaVideoID = videoID;
    NSString *path = [NSString stringWithFormat:@"/api/lyrics/song?v=%@&lang=%@",
                      YTMUUrlEncode(videoID), YTMUUrlEncode(YTMUTargetLang())];
    [self ytmu_getJSON:path completion:^(NSDictionary *json, NSError *error) {
        if (error || ![json[@"ok"] boolValue]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![videoID isEqualToString:YTMUResolveCurrentVideoID()] &&
                ![videoID isEqualToString:self.loadingVideoID]) {
                return; // metadata for a song that already moved on
            }
            id s = json[@"song"], a = json[@"artist"];
            BOOL changed = NO;
            if ([s isKindOfClass:[NSString class]] && ((NSString *)s).length &&
                ![s isEqualToString:self.lastSongTitle]) {
                self.lastSongTitle = s;
                changed = YES;
            }
            if ([a isKindOfClass:[NSString class]] && ((NSString *)a).length &&
                ![a isEqualToString:self.lastSongArtist]) {
                self.lastSongArtist = a;
                changed = YES;
            }
            if (changed) [self ytmu_updateLandscapeMetadata];
        });
    }];
}

- (void)ytmu_collectNowPlayingLabelsIn:(UIView *)view depth:(NSInteger)depth out:(NSMutableArray *)out {
    if (!view || depth > 7) return;
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *lbl = (UILabel *)view;
        NSString *txt = [lbl.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        // Zero-size / hidden / fully transparent labels are placeholders
        // (collapsed cells, our own injected chip copies): never a song name.
        BOOL visible = (lbl.bounds.size.width > 1.0 && lbl.bounds.size.height > 1.0 &&
                        !lbl.hidden && lbl.alpha > 0.05);
        if (txt.length >= 2 && txt.length <= 100 && visible) {
            NSString *low = txt.lowercaseString;
            // The live badge is a real label but never the song title: keep it
            // flagged so it can only land in the artist slot.
            BOOL isLive = ([txt containsString:@"直播"] ||
                           [low isEqualToString:@"live"] || [low hasPrefix:@"live "]);
            // Audio-quality rows ("網頁 44.1 kHz 採樣率", "Lossless") sit in the
            // same hierarchy and are never the song name.
            BOOL quality = ([low containsString:@"khz"] || [low containsString:@"kbps"] ||
                            [low containsString:@"lossless"] || [low containsString:@"web:"] ||
                            [low containsString:@"web "] || [low containsString:@"串流"] ||
                            [low containsString:@"采样"] || [low containsString:@"採樣"] ||
                            [low containsString:@"音质"] || [low containsString:@"音質"] ||
                            [low containsString:@"web/"]);
            BOOL junk = quality ||
                        ([txt containsString:@"歌詞"] || [txt containsString:@"歌词"] ||
                         [low containsString:@"lyric"] || [low containsString:@"unavailable"] ||
                         [txt containsString:@"沒有歌詞"] || [txt containsString:@"没有歌词"] ||
                         [txt isEqualToString:@"Now Playing"]);
            // Skip time labels like "1:23" / "1:23 / 4:56".
            if (!junk) {
                NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"0123456789: /-"];
                if ([txt rangeOfCharacterFromSet:[allowed invertedSet]].location == NSNotFound) junk = YES;
            }
            if (!junk) {
                CGRect r = [lbl convertRect:lbl.bounds toView:nil];
                [out addObject:@{@"text": txt, @"y": @(r.origin.y),
                                 @"size": @(lbl.font.pointSize), @"live": @(isLive)}];
            }
        }
    }
    for (UIView *sub in view.subviews) {
        [self ytmu_collectNowPlayingLabelsIn:sub depth:depth + 1 out:out];
    }
}

- (void)ytmu_updateLandscapeMetadataFromNowPlayingLabels {
    BOOL needTitle = (self.landscapeTitleLabel.text.length == 0 ||
                      [self.landscapeTitleLabel.text isEqualToString:@"Now Playing"]);
    BOOL needArtist = (self.landscapeArtistLabel.text.length == 0);
    if (!needTitle && !needArtist) return;
    // The now-playing VC is the primary source, but it can be swapped out
    // (expanded/collapsed player); the topmost VC covers those cases.
    NSMutableArray<UIViewController *> *roots = [NSMutableArray array];
    UIViewController *np = g_activeNowPlayingVC;
    if (np.isViewLoaded) [roots addObject:np];
    UIViewController *top = topMostViewController();
    if (top.isViewLoaded && top != np && top != (UIViewController *)self) [roots addObject:top];
    NSMutableArray *found = [NSMutableArray array];
    for (UIViewController *vc in roots) {
        [self ytmu_collectNowPlayingLabelsIn:vc.view depth:0 out:found];
        for (UIViewController *child in vc.childViewControllers) {
            if (child.isViewLoaded) [self ytmu_collectNowPlayingLabelsIn:child.view depth:0 out:found];
        }
    }
    if (found.count == 0) return;
    // Biggest type is the title (the now-playing screen sizes it largest),
    // the artist is the next one down. Falling back to pure vertical order
    // when every label shares a font size.
    [found sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        double sa = [a[@"size"] doubleValue], sb = [b[@"size"] doubleValue];
        if (sa > sb) return NSOrderedAscending;
        if (sb > sa) return NSOrderedDescending;
        return [a[@"y"] compare:b[@"y"]];
    }];
    // Dedupe, keeping the live flag: the title must be a real (non-live)
    // label, the artist slot may fall back to the live badge.
    NSMutableArray *ordered = [NSMutableArray array];
    for (NSDictionary *d in found) {
        if (![ordered containsObject:d[@"text"]]) [ordered addObject:d];
    }
    NSString *pickedTitle = nil;
    NSString *pickedArtist = nil;
    for (NSDictionary *d in ordered) {
        if ([d[@"live"] boolValue]) {
            if (!pickedArtist) pickedArtist = d[@"text"];
            continue;
        }
        if (!pickedTitle) { pickedTitle = d[@"text"]; continue; }
        if (!pickedArtist) pickedArtist = d[@"text"];
    }
    if (needTitle && pickedTitle) self.landscapeTitleLabel.text = pickedTitle;
    if (needArtist && pickedArtist) self.landscapeArtistLabel.text = pickedArtist;
}

- (void)ytmu_updateLandscapeProgress {
    if (!self.landscapeProgressFill || !self.landscapeProgressTrack) return;
    CGFloat progress = 0;
    CGFloat totalTime = 0;
    CGFloat curTime = 0;
    if (g_activePlayer && [g_activePlayer respondsToSelector:@selector(currentVideoTotalMediaTime)]) {
        totalTime = g_activePlayer.currentVideoTotalMediaTime;
        curTime = g_activePlayer.currentVideoMediaTime;
        if (totalTime > 0) progress = (CGFloat)(curTime / totalTime);
    } else if (g_currentPlaybackTime > 0) {
        progress = 0; // unknown total; leave at 0 unless total known
    }
    if (progress < 0) progress = 0;
    if (progress > 1) progress = 1;
    CGFloat trackW = self.landscapeProgressTrack.bounds.size.width;
    CGFloat fillW = floor(trackW * progress);
    CGRect f = self.landscapeProgressFill.frame;
    f.size.width = fillW;
    f.size.height = 3;
    f.origin = CGPointZero;
    self.landscapeProgressFill.frame = f;
    if (self.landscapeElapsedLabel) {
        NSString *et = [self ytmu_formatTime:curTime];
        if (![self.landscapeElapsedLabel.text isEqualToString:et]) self.landscapeElapsedLabel.text = et;
    }
    if (self.landscapeTotalLabel) {
        NSString *tt = [self ytmu_formatTime:totalTime];
        if (![self.landscapeTotalLabel.text isEqualToString:tt]) self.landscapeTotalLabel.text = tt;
    }
    if (self.landscapeProgressKnob) {
        CGFloat knobS = 8;
        CGFloat knobX = fillW - knobS / 2.0;
        if (knobX < 0) knobX = 0;
        if (knobX > trackW - knobS) knobX = trackW - knobS;
        CGRect kf = self.landscapeProgressKnob.frame;
        kf.origin.x = self.landscapeProgressTrack.frame.origin.x + knobX;
        kf.origin.y = self.landscapeProgressTrack.frame.origin.y + (3 - knobS) / 2.0;
        kf.size.width = knobS;
        kf.size.height = knobS;
        self.landscapeProgressKnob.frame = kf;
    }
}

- (void)ytmu_setLandscapePlaying:(BOOL)playing {
    self.landscapeIsPlaying = playing;
    // Filled circle + contrasting glyph, keyed on background brightness
    // (not the OS theme): dark bg -> white circle + black glyph, light bg
    // -> black circle + white glyph.
    BOOL light = YTMUBgIsLight(self.view);
    self.landscapePlayButton.backgroundColor = [(light ? [UIColor blackColor] : [UIColor whiteColor])
        colorWithAlphaComponent:(light ? 0.9 : 0.95)];
    self.landscapePlayButton.tintColor = (light ? [UIColor whiteColor] : [UIColor blackColor]);
    if (@available(iOS 13.0, *)) {
        UIImage *img = [UIImage systemImageNamed:playing ? @"pause.fill" : @"play.fill"];
        if (img) {
            [self.landscapePlayButton setImage:img forState:UIControlStateNormal];
            [self.landscapePlayButton setTitle:@"" forState:UIControlStateNormal];
            return;
        }
    }
    [self.landscapePlayButton setImage:nil forState:UIControlStateNormal];
    [self.landscapePlayButton setTitle:playing ? @"pause" : @"play" forState:UIControlStateNormal];
    [self.landscapePlayButton setTitleColor:self.landscapePlayButton.tintColor forState:UIControlStateNormal];
}

- (void)ytmu_setLandscapeTransportIcons {
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold];
        UIImage *prev = [[UIImage systemImageNamed:@"backward.fill"] imageWithConfiguration:cfg];
        UIImage *next = [[UIImage systemImageNamed:@"forward.fill"] imageWithConfiguration:cfg];
        if (prev) {
            [self.landscapePrevButton setImage:prev forState:UIControlStateNormal];
            [self.landscapePrevButton setTitle:@"" forState:UIControlStateNormal];
        } else {
            [self.landscapePrevButton setTitle:@"prev" forState:UIControlStateNormal];
            [self.landscapePrevButton setTitleColor:YTMULyricInk(0.9, 0.9, self.view) forState:UIControlStateNormal];
        }
        if (next) {
            [self.landscapeNextButton setImage:next forState:UIControlStateNormal];
            [self.landscapeNextButton setTitle:@"" forState:UIControlStateNormal];
        } else {
            [self.landscapeNextButton setTitle:@"next" forState:UIControlStateNormal];
            [self.landscapeNextButton setTitleColor:YTMULyricInk(0.9, 0.9, self.view) forState:UIControlStateNormal];
        }
    } else {
        [self.landscapePrevButton setTitle:@"prev" forState:UIControlStateNormal];
        [self.landscapePrevButton setTitleColor:YTMULyricInk(0.9, 0.9, self.view) forState:UIControlStateNormal];
        [self.landscapeNextButton setTitle:@"next" forState:UIControlStateNormal];
        [self.landscapeNextButton setTitleColor:YTMULyricInk(0.9, 0.9, self.view) forState:UIControlStateNormal];
    }
    [self ytmu_setLandscapePlaying:self.landscapeIsPlaying];
}

- (NSString *)ytmu_formatTime:(CGFloat)seconds {
    if (!(seconds > 0)) return @"0:00";
    NSInteger total = (NSInteger)seconds;
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(total / 60), (long)(total % 60)];
}

- (void)ytmu_applyLandscapeTheme {
    // Ambient blur follows the sampled artwork brightness (not the OS
    // theme). No-ops when the bucket is unchanged so every-layout calls
    // don't restart the 0.25s crossfade.
    // The snapshot is per INSTANCE: it used to be a function static, so with a
    // modal sheet and the embedded panel both live the second one never
    // applied its own style (it matched the first instance's).
    if (!self.blurView) return;
    UIBlurEffectStyle style = YTMUBgBlurStyle(self.view);
    NSNumber *lastStyle = objc_getAssociatedObject(self, &s_ytmuBlurStyleKey);
    NSNumber *haveStyle = objc_getAssociatedObject(self, &s_ytmuBlurHaveKey);
    if (haveStyle.boolValue && lastStyle.integerValue == (NSInteger)style) return;
    objc_setAssociatedObject(self, &s_ytmuBlurStyleKey, @(style), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &s_ytmuBlurHaveKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIBlurEffect *effect = [UIBlurEffect effectWithStyle:style];
    [UIView animateWithDuration:0.25 animations:^{
        self.blurView.effect = effect;
    }];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    // Chrome is background-derived, so OS theme flips are ignored once an
    // artwork probe has landed; only re-resolve while still unknown.
    if (@available(iOS 13.0, *)) {
        if (self.traitCollection.userInterfaceStyle != previousTraitCollection.userInterfaceStyle &&
            g_ytmu_bgLight < 0) {
            self.view.backgroundColor = YTMUBgBaseColor(self.view);
            [self ytmu_applyLandscapeTheme];
        }
    }
}

- (void)ytmu_landscapePrev:(UIButton *)sender {
    UIViewController *np = g_activeNowPlayingVC;
    if (np && [np respondsToSelector:@selector(didTapPrevButton)]) {
        YTMUInvokeNoArgs(np, @selector(didTapPrevButton));
        sendDebugLog(@"[MUSIC] landscape prev via now-playing VC");
        return;
    }
    UIViewController *top = topMostViewController();
    if (top && [top respondsToSelector:@selector(didTapPrevButton)]) {
        YTMUInvokeNoArgs(top, @selector(didTapPrevButton));
        sendDebugLog(@"[MUSIC] landscape prev via top VC");
        return;
    }
    sendDebugLog(@"[MUSIC] landscape prev: no handler (nowPlayingVC nil or missing selector)");
}

- (void)ytmu_landscapeNext:(UIButton *)sender {
    UIViewController *np = g_activeNowPlayingVC;
    if (np && [np respondsToSelector:@selector(didTapNextButton)]) {
        YTMUInvokeNoArgs(np, @selector(didTapNextButton));
        sendDebugLog(@"[MUSIC] landscape next via now-playing VC");
        return;
    }
    UIViewController *top = topMostViewController();
    if (top && [top respondsToSelector:@selector(didTapNextButton)]) {
        YTMUInvokeNoArgs(top, @selector(didTapNextButton));
        sendDebugLog(@"[MUSIC] landscape next via top VC");
        return;
    }
    sendDebugLog(@"[MUSIC] landscape next: no handler (nowPlayingVC nil or missing selector)");
}

- (void)ytmu_landscapePlayPause:(UIButton *)sender {
    // Drive playback through the player directly: explicit pause/play based
    // on our tracked state beats toggle selectors that may not exist on the
    // current now-playing VC. Player first, now-playing VC as fallback.
    BOOL wantPause = self.landscapeIsPlaying;
    YTPlayerViewController *player = g_activePlayer;
    if (player) {
        SEL playPause = wantPause ? @selector(pause) : @selector(play);
        if ([player respondsToSelector:playPause]) {
            YTMUInvokeNoArgs(player, playPause);
            [self ytmu_setLandscapePlaying:!self.landscapeIsPlaying];
            sendDebugLog(wantPause ? @"[MUSIC] landscape pause via player" : @"[MUSIC] landscape play via player");
            return;
        }
        if ([player respondsToSelector:@selector(togglePlayPause)]) {
            YTMUInvokeNoArgs(player, @selector(togglePlayPause));
            [self ytmu_setLandscapePlaying:!self.landscapeIsPlaying];
            sendDebugLog(@"[MUSIC] landscape play/pause via player toggle");
            return;
        }
    }
    UIViewController *np = g_activeNowPlayingVC;
    if (np && [np respondsToSelector:@selector(didTapPlayPauseButton)]) {
        YTMUInvokeNoArgs(np, @selector(didTapPlayPauseButton));
        [self ytmu_setLandscapePlaying:!self.landscapeIsPlaying];
        sendDebugLog(@"[MUSIC] landscape play/pause via now-playing VC");
        return;
    }
    if (np && [np respondsToSelector:@selector(togglePlayPause)]) {
        YTMUInvokeNoArgs(np, @selector(togglePlayPause));
        [self ytmu_setLandscapePlaying:!self.landscapeIsPlaying];
        sendDebugLog(@"[MUSIC] landscape play/pause via now-playing toggle");
        return;
    }
    // Fallback: send touch to any play/pause control under now-playing view
    UIView *npView = (np && np.isViewLoaded) ? np.view : nil;
    if (npView) {
        for (UIView *sub in npView.subviews) {
            if ([self ytmu_tryTapPlayPauseIn:sub depth:0]) {
                [self ytmu_setLandscapePlaying:!self.landscapeIsPlaying];
                sendDebugLog(@"[MUSIC] landscape play/pause via now-playing sub-control");
                return;
            }
        }
    }
    UIViewController *top = topMostViewController();
    if (top && top != (UIViewController *)self && [top respondsToSelector:@selector(didTapPlayPauseButton)]) {
        YTMUInvokeNoArgs(top, @selector(didTapPlayPauseButton));
        [self ytmu_setLandscapePlaying:!self.landscapeIsPlaying];
        sendDebugLog(@"[MUSIC] landscape play/pause via top VC");
        return;
    }
    sendDebugLog(@"[MUSIC] landscape play/pause: no handler (nowPlayingVC nil or missing selector)");
}

- (BOOL)ytmu_tryTapPlayPauseIn:(UIView *)view depth:(NSInteger)depth {
    if (!view || depth > 8) return NO;
    if ([view isKindOfClass:[UIControl class]]) {
        NSString *label = view.accessibilityLabel.lowercaseString ?: @"";
        NSString *ident = view.accessibilityIdentifier.lowercaseString ?: @"";
        if ([label containsString:@"pause"] || [label containsString:@"play"] ||
            [ident containsString:@"pause"] || [ident containsString:@"play"]) {
            [(UIControl *)view sendActionsForControlEvents:UIControlEventTouchUpInside];
            return YES;
        }
    }
    for (UIView *sub in view.subviews) {
        if ([self ytmu_tryTapPlayPauseIn:sub depth:depth + 1]) return YES;
    }
    return NO;
}

#pragma mark - Provider actions menu

- (void)ytmu_headerMenu:(UIButton *)sender {
    [self ytmu_openProviderMenuFromView:sender];
}

- (void)ytmu_toolbarReload:(UIButton *)sender {
    [self forceReloadLyrics];
}

// Retranslate the CURRENT song through the CURRENT provider. Unlike the
// reload button this keeps g_lyricsCache, self.lyrics and every provider
// candidate: the old translation stays on screen while the forced fetch runs,
// so nothing flashes empty and the switcher keeps its index. The button is
// the action only -- the compact [<] [>] + name switcher next to it stays in
// its normal collapsed form (refreshed here, never expanded).
- (void)ytmu_retranslateTapped:(UIButton *)sender {
    NSString *videoID = g_currentVideoID;
    if (!videoID.length || s_retranslateRunning) return;
    // The fetch only runs for the video the sheet is already on; a song that
    // changed under us is handled by handleSongChange: instead.
    if (self.loadingVideoID.length && ![self.loadingVideoID isEqualToString:videoID]) return;
    UILabel *statusLabel = [self.tableView.tableHeaderView viewWithTag:8888];
    if (self.isLoading) {
        // A fetch is already running for this song; the 45s reclaim in
        // fetchLyricsForVideo: covers a dead one.
        if (statusLabel) statusLabel.text = @"Loading...";
        return;
    }
    s_retranslateRunning = YES;
    [self ytmu_refreshProviderSwitcher];
    [self ytmu_setProbing:YES];
    if (statusLabel) statusLabel.text = @"Retranslating...";
    // Same slot bookkeeping forceReloadLyrics uses, so a re-entrant
    // fetchLyricsForVideo: for this video waits instead of duplicating the
    // request, and its 45s reclaim still applies.
    self.isLoading = YES;
    self.loadingSince = [NSDate date];
    self.loadingVideoID = videoID;
    sendDebugLog([NSString stringWithFormat:@"[MUSIC] retranslate requested for %@", videoID]);

    // No Turnstile gate: fire it now and let the server pool cover the JWT.
    // The 10s "JWT timeout" fallback that used to race this is gone -- there is
    // no second fetch to fall back to, so the request is never duplicated and
    // the toolbar can never sit dimmed waiting on a challenge.
    [self ytmu_startFullFetchForVideoID:videoID force:YES from:@"retranslate"];
    // Same 45s watchdog the fetch slots use: a stream or a full fetch that
    // never reports back must not leave the toolbar dimmed forever.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!s_retranslateRunning) return;
        sendDebugLog(@"[WARN] retranslate watchdog expired, restoring toolbar");
        [self ytmu_endRetranslate:NO];
    });
}

// Single exit for the retranslate: unlatch, restore the chrome and say what
// happened. The payload itself is applied by the normal fetch path
// (updateLyrics: + the YTMULyricsDidLoad notification), so a server answer
// identical to what is on screen still ends cleanly.
- (void)ytmu_endRetranslate:(BOOL)ok {
    s_retranslateRunning = NO;
    [self ytmu_setProbing:NO];
    // The fetch paths release the slot themselves; this covers the ones that
    // died without a terminal event (a stream that never sent `done`).
    self.isLoading = NO;
    self.loadingSince = nil;
    UILabel *statusLabel = [self.tableView.tableHeaderView viewWithTag:8888];
    // Only own the status line while it still shows our marker: a long
    // translation can outrun the 45s watchdog, and by then the fetch path has
    // its own text there.
    BOOL ours = [statusLabel.text isEqualToString:@"Retranslating..."];
    if (statusLabel && (ok || ours)) statusLabel.text = ok ? @"" : @"[WARN] Retranslate failed";
}

- (void)ytmu_postJSON:(NSString *)path body:(NSDictionary *)body completion:(void (^)(NSDictionary *json, NSError *error))completion {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@%@", YTMUApiBase(), path]];
    if (!url) {
        if (completion) completion(nil, [NSError errorWithDomain:@"YTMU" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"bad URL"}]);
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.timeoutInterval = 20.0;
    if (body) req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
        NSDictionary *json = nil;
        if (data && !err) json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (completion) completion(json, err);
    }] resume];
}

- (void)ytmu_getJSON:(NSString *)path completion:(void (^)(NSDictionary *json, NSError *error))completion {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@%@", YTMUApiBase(), path]];
    if (!url) {
        if (completion) completion(nil, [NSError errorWithDomain:@"YTMU" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"bad URL"}]);
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 15.0;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
        NSDictionary *json = nil;
        if (data && !err) json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (completion) completion(json, err);
    }] resume];
}

- (void)ytmu_openProviderMenuFromView:(UIView *)sender {
    NSString *vid = YTMUResolveCurrentVideoID() ?: g_currentVideoID;
    if (!vid.length) {
        sendDebugLog(@"[MUSIC] provider menu: no video ID");
        return;
    }
    // Tapping early in a song: pull the provider lyrics now so the switch
    // that follows paints from RAM instead of waiting on the network.
    [self ytmu_loadProviderLyricsForVideo:vid];
    // Switch anytime: on iOS 14+ the armed UIMenu opens on tap with zero
    // re-probe, so this path only fires while unarmed (or iOS 13 fallback).
    NSDictionary *hit = self.providerCache[vid];
    NSArray *cached = hit[@"cands"];
    if ([cached isKindOfClass:[NSArray class]] && cached.count > 0) {
        self.providerCandidates = cached;
        NSString *saved = ([hit[@"saved"] isKindOfClass:[NSString class]]) ? hit[@"saved"] : nil;
        [self ytmu_resolveProviderIndexSaved:saved];
        [self ytmu_refreshProviderSwitcher];
        [self ytmu_showProviderMenu:cached saved:saved fromView:sender];
        return;
    }
    if (self.providerPollTimer) {
        sendDebugLog(@"[MUSIC] provider probe already running (no popup)");
        return;
    }
    [self ytmu_setProbing:YES];
    __block BOOL jwtDone = NO;
    [[YTMUTurnstileManager sharedManager] getJWTTokenWithCompletion:^(NSString *jwt) {
        if (jwtDone) return;
        jwtDone = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self ytmu_beginProviderProbeWithJWT:jwt fromView:sender];
        });
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!jwtDone) {
            jwtDone = YES;
            [self ytmu_beginProviderProbeWithJWT:nil fromView:sender];
        }
    });
}

- (void)ytmu_beginProviderProbeWithJWT:(NSString *)jwt fromView:(UIView *)sender {
    NSString *vid = YTMUResolveCurrentVideoID() ?: g_currentVideoID;
    if (!vid.length) { [self ytmu_setProbing:NO]; return; }
    NSMutableDictionary *body = [@{@"video_id": vid, @"lang": YTMUTargetLang()} mutableCopy];
    if (jwt.length) body[@"jwt"] = jwt;
    UIView *anchor = (sender && sender.window) ? sender : self.view;
    objc_setAssociatedObject(self, @selector(ytmu_openProviderMenuFromView:), anchor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self ytmu_postJSON:@"/api/lyrics/providers/start" body:body completion:^(NSDictionary *json, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *jobID = json[@"job_id"];
            if (![json[@"ok"] boolValue] || !jobID.length) {
                sendDebugLog(@"[MUSIC] provider probe start failed");
                [self ytmu_setProbing:NO];
                return;
            }
            [self ytmu_stopProviderPoll];
            self.providerJobID = jobID;
            self.providerProbeVideoID = vid;
            // No popup while probing: the provider buttons dim (see
            // ytmu_setProbing:) and the compact menu arms on them when
            // candidates land (tap to expand).
            self.providerPollTimer = [NSTimer scheduledTimerWithTimeInterval:1.2 target:self selector:@selector(ytmu_pollProviderJob:) userInfo:nil repeats:YES];
        });
    }];
}

- (void)ytmu_pollProviderJob:(NSTimer *)timer {
    if (!self.providerJobID.length) {
        [self ytmu_stopProviderPoll];
        return;
    }
    NSString *path = [NSString stringWithFormat:@"/api/lyrics/providers/status/%@", self.providerJobID];
    [self ytmu_getJSON:path completion:^(NSDictionary *json, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || ![json[@"ok"] boolValue]) {
                [self ytmu_stopProviderPoll];
                [self ytmu_setProbing:NO];
                sendDebugLog(@"[MUSIC] provider probe poll failed");
                return;
            }
            NSString *state = json[@"state"] ?: @"";
            NSArray *cands = json[@"candidates"] ?: @[];
            if ([state isEqualToString:@"complete"] || [state isEqualToString:@"error"]) {
                [self ytmu_stopProviderPoll];
                [self ytmu_setProbing:NO];
                UIView *anchor = objc_getAssociatedObject(self, @selector(ytmu_openProviderMenuFromView:));
                id saved = json[@"saved"];
                NSString *savedName = ([saved isKindOfClass:[NSString class]]) ? saved : nil;
                if ([state isEqualToString:@"complete"]) {
                    // Pin to the video probed, not whatever is playing now:
                    // a mid-probe song change must not file candidates under
                    // the wrong video.
                    NSString *vid = self.providerProbeVideoID;
                    if (!vid.length) vid = YTMUResolveCurrentVideoID() ?: g_currentVideoID;
                    if (vid.length && [cands isKindOfClass:[NSArray class]]) {
                        if (!self.providerCache) self.providerCache = [NSMutableDictionary dictionary];
                        self.providerCache[vid] = @{@"cands": cands, @"saved": savedName ?: @""};
                    }
                    self.providerCandidates = cands;
                    [self ytmu_resolveProviderIndexSaved:savedName];
                    [self ytmu_refreshProviderSwitcher];
                    if (@available(iOS 14.0, *)) {
                        // Compact menu is live on the buttons now; UIMenu has
                        // no programmatic open, so it waits for the next tap.
                        sendDebugLog(@"[MUSIC] provider probe complete (menu ready)");
                    } else {
                        [self ytmu_showProviderMenu:cands saved:savedName fromView:anchor];
                    }
                } else {
                    sendDebugLog(@"[MUSIC] provider probe error (no popup)");
                }
            }
        });
    }];
}

- (void)ytmu_stopProviderPoll {
    [self.providerPollTimer invalidate];
    self.providerPollTimer = nil;
    self.providerJobID = nil;
}

// Arm the switcher from a provider list the server already holds in RAM.
// Every fetch/probe leaves one behind, so the menu is ready the moment a
// song starts playing -- no re-probe, no popup, and nothing new written to
// disk. dict is any payload carrying {providers, saved}.
- (void)ytmu_applyProviderMeta:(NSDictionary *)dict forVideoID:(NSString *)videoID {
    if (!videoID.length || ![dict isKindOfClass:[NSDictionary class]]) return;
    NSArray *cands = dict[@"providers"];
    if (![cands isKindOfClass:[NSArray class]] || cands.count == 0) return;
    if (!self.providerCache) self.providerCache = [NSMutableDictionary dictionary];
    id savedRaw = dict[@"saved"];
    NSString *saved = ([savedRaw isKindOfClass:[NSString class]]) ? savedRaw : @"";
    self.providerCache[videoID] = @{@"cands": cands, @"saved": saved};
    NSString *cur = YTMUResolveCurrentVideoID() ?: g_currentVideoID;
    if (!cur.length || ![cur isEqualToString:videoID]) return;  // prefetched track
    self.providerCandidates = cands;
    // The provider actually serving the lyrics wins over the stored choice.
    [self ytmu_resolveProviderIndexSaved:(self.lastProvider.length ? self.lastProvider : saved)];
    [self ytmu_refreshProviderSwitcher];
}

// One cheap RAM read: fills the switcher for a song whose lyrics came from
// the device cache (no fetch ran, so no payload carried the list).
- (void)ytmu_loadProviderMetaForVideo:(NSString *)videoID {
    if (!videoID.length) return;
    NSDictionary *hit = self.providerCache[videoID];
    if ([hit[@"cands"] count] > 0) {
        [self ytmu_applyProviderMeta:hit forVideoID:videoID];
        return;
    }
    if ([videoID isEqualToString:self.providerMetaVideoID]) return;  // already asked
    self.providerMetaVideoID = videoID;
    NSString *path = [NSString stringWithFormat:@"/api/lyrics/providers/candidates?v=%@&lang=%@",
                      YTMUUrlEncode(videoID), YTMUUrlEncode(YTMUTargetLang())];
    [self ytmu_getJSON:path completion:^(NSDictionary *json, NSError *error) {
        if (error || ![json[@"ok"] boolValue]) return;
        if (![json[@"found"] boolValue]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![videoID isEqualToString:self.providerMetaVideoID]) return;
            [self ytmu_applyProviderMeta:json forVideoID:videoID];
        });
    }];
}

// Pull every provider's raw lyrics for a song, once, and park them in device
// RAM. Switching the source then paints instantly (no network, no re-race);
// the select call that follows brings the translation and caches that one
// provider. Nothing here touches the disk cache.
- (void)ytmu_loadProviderLyricsForVideo:(NSString *)videoID {
    if (!videoID.length) return;
    if (YTMUProviderLyricsCount(videoID) > 0) return;
    if ([videoID isEqualToString:self.providerDataVideoID]) return;  // already asked
    self.providerDataVideoID = videoID;
    NSString *path = [NSString stringWithFormat:@"/api/lyrics/providers/data?v=%@&lang=%@",
                      YTMUUrlEncode(videoID), YTMUUrlEncode(YTMUTargetLang())];
    [self ytmu_getJSON:path completion:^(NSDictionary *json, NSError *error) {
        if (error || ![json[@"ok"] boolValue] || ![json[@"found"] boolValue]) return;
        NSArray *entries = json[@"providers"];
        if (![entries isKindOfClass:[NSArray class]] || entries.count == 0) return;
        YTMUProviderLyricsStore(videoID, entries);
        sendDebugLog([NSString stringWithFormat:@"[MUSIC] %lu provider(s) for %@ held in RAM",
                      (unsigned long)YTMUProviderLyricsCount(videoID), videoID]);
    }];
}

// Point the switcher at the saved choice, else at the provider serving the
// current lyrics, else unknown (-1: no mark). Never auto-applies and never
// pretends index 0 is current when the on-screen lyrics came from elsewhere.
- (void)ytmu_resolveProviderIndexSaved:(NSString *)saved {
    NSInteger idx = -1;
    NSArray *cands = self.providerCandidates;
    if (saved.length) {
        for (NSInteger i = 0; i < cands.count; i++) {
            id p = cands[i][@"provider"];
            if ([p isKindOfClass:[NSString class]] && [p isEqualToString:saved]) { idx = i; break; }
        }
    }
    if (idx < 0 && self.lastProvider.length) {
        for (NSInteger i = 0; i < cands.count; i++) {
            id p = cands[i][@"provider"];
            if ([p isKindOfClass:[NSString class]] && [p isEqualToString:self.lastProvider]) { idx = i; break; }
        }
    }
    self.providerIndex = (idx >= 0) ? idx : -1;
}

- (void)ytmu_applyProviderAtIndex:(NSInteger)idx {
    // TODO(app-anim): animate the lyrics swap (crossfade + scroll to top)
    // and pulse the switcher label when the provider changes mid-song.
    NSArray *cands = self.providerCandidates;
    if (idx < 0 || idx >= cands.count) return;
    id p = cands[idx][@"provider"];
    if (![p isKindOfClass:[NSString class]] || !((NSString *)p).length) return;
    self.providerIndex = idx;
    [self ytmu_refreshProviderSwitcher];
    // Paint from device RAM first (instant, untranslated), then let the select
    // call deliver the translation and cache this one provider. The RAM copy
    // is never cached: it dies with the process.
    NSArray *ramLyrics = YTMUProviderLyricsForProvider(self.loadingVideoID, (NSString *)p);
    if (ramLyrics.count > 0) {
        // Deliberately NOT g_lyricsCache / YTMULyricsCacheSave: the file cache
        // only ever holds the provider the server confirmed.
        self.currentIndex = -1;
        self.activeIndexes = nil;
        self.lastColorKey = nil;
        // Switching provider is not a live translation: this copy (and the one
        // /providers/select returns) arrives whole, so it paints whole. Without
        // this a live fetch that armed the reveal earlier in the song would
        // carry the animation over to a provider the user switched to.
        self.typewriterLive = NO;
        [self updateLyrics:ramLyrics];
    }
    [self ytmu_selectProvider:(NSString *)p];
}

- (void)ytmu_stepProvider:(UIButton *)sender {
    NSArray *cands = self.providerCandidates;
    if (cands.count < 2) return;
    NSInteger idx = self.providerIndex;
    if (idx < 0) idx = 0;
    idx = (idx + sender.tag + cands.count) % cands.count;
    sendDebugLog([NSString stringWithFormat:@"[MUSIC] provider step -> %ld/%lu", (long)idx + 1, (unsigned long)cands.count]);
    [self ytmu_applyProviderAtIndex:idx];
}

// Stepper press feedback: [<] and [>] widen into a filled pill while held
// and spring back on release/cancel. Transform-based so the next layout pass
// (which owns the frames) can never cut the animation short.
- (void)ytmu_wireStepperPress:(UIButton *)button {
    if (!button) return;
    button.layer.masksToBounds = YES;
    [button addTarget:self action:@selector(ytmu_stepperPressIn:)
     forControlEvents:UIControlEventTouchDown];
    [button addTarget:self action:@selector(ytmu_stepperPressOut:)
     forControlEvents:UIControlEventTouchUpInside];
    [button addTarget:self action:@selector(ytmu_stepperPressOut:)
     forControlEvents:UIControlEventTouchUpOutside];
    [button addTarget:self action:@selector(ytmu_stepperPressOut:)
     forControlEvents:UIControlEventTouchCancel];
    [button addTarget:self action:@selector(ytmu_stepperPressOut:)
     forControlEvents:UIControlEventTouchDragExit];
}

- (void)ytmu_stepperPressIn:(UIButton *)button {
    if (!button) return;
    CGFloat h = MAX(button.bounds.size.height, 1.0);
    // z-order outside the animation block: it must snap, not fade.
    button.layer.zPosition = 20;
    UIColor *pill = YTMULyricInk(0.22, 0.22, self.view);
    [UIView animateWithDuration:0.16 delay:0
        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
        animations:^{
            button.transform = CGAffineTransformMakeScale(1.34, 1.14);
            button.layer.cornerRadius = h / 2.0;
            button.backgroundColor = pill;
        } completion:nil];
}

- (void)ytmu_stepperPressOut:(UIButton *)button {
    if (!button) return;
    [UIView animateWithDuration:0.36 delay:0
        usingSpringWithDamping:0.6 initialSpringVelocity:0.7
        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
        animations:^{
            button.transform = CGAffineTransformIdentity;
            button.backgroundColor = [UIColor clearColor];
        } completion:^(BOOL finished) {
            button.layer.cornerRadius = 0;
            button.layer.zPosition = 0;
        }];
}

// Tier of the provider serving the current lyrics (better-lyrics dock
// trigger shows the current sync-type icon): last-serving match first,
// then the switcher index, then best-first. Nil when nothing is known.
- (NSString *)ytmu_currentTier {
    NSArray *cands = self.providerCandidates;
    if (![cands isKindOfClass:[NSArray class]] || cands.count == 0) return nil;
    for (NSDictionary *c in cands) {
        if (![c isKindOfClass:[NSDictionary class]]) continue;
        id p = c[@"provider"];
        if (self.lastProvider.length && [p isKindOfClass:[NSString class]] && [p isEqualToString:self.lastProvider]) {
            id t = c[@"tier"];
            return ([t isKindOfClass:[NSString class]] && ((NSString *)t).length) ? t : @"plain";
        }
    }
    NSDictionary *cur = nil;
    if (self.providerIndex >= 0 && self.providerIndex < (NSInteger)cands.count) cur = cands[self.providerIndex];
    else cur = cands[0];
    if (![cur isKindOfClass:[NSDictionary class]]) return @"plain";
    id t = cur[@"tier"];
    return ([t isKindOfClass:[NSString class]] && ((NSString *)t).length) ? t : @"plain";
}

// Compact anchored provider menu (Image-1 style, iOS 14+): rows carry the
// provider name + tier icon in better-lyrics sync colors, with the detail
// (index, tier, line count) as subtitle, current row checked, auto row on
// top. iOS 13 falls back to ytmu_showProviderMenu's sheet.
- (UIMenu *)ytmu_providerMenu {
    NSArray *cands = self.providerCandidates;
    if (![cands isKindOfClass:[NSArray class]] || cands.count == 0) return nil;
    __weak typeof(self) weakSelf = self;
    NSMutableArray *rows = [NSMutableArray array];
    UIImage *autoImg = nil;
    if (@available(iOS 13.0, *)) autoImg = [UIImage systemImageNamed:@"sparkles"];
    UIAction *autoAction = [UIAction actionWithTitle:@"Best available (auto)" image:autoImg identifier:nil handler:^(__unused UIAction *a) {
        [weakSelf forceReloadLyrics];
    }];
    autoAction.state = (self.providerIndex < 0) ? UIMenuElementStateOn : UIMenuElementStateOff;
    [rows addObject:autoAction];
    for (NSInteger i = 0; i < (NSInteger)cands.count; i++) {
        NSDictionary *c = cands[i];
        if (![c isKindOfClass:[NSDictionary class]]) continue;
        NSString *prov = c[@"provider"];
        if (![prov isKindOfClass:[NSString class]] || !prov.length) continue;
        NSString *tier = ([c[@"tier"] isKindOfClass:[NSString class]]) ? c[@"tier"] : @"";
        NSInteger lines = [c[@"lines"] integerValue];
        NSInteger rowIdx = i;
        UIAction *a = [UIAction actionWithTitle:prov image:YTMUTierIcon(tier, 18) identifier:nil handler:^(__unused UIAction *act) {
            [weakSelf ytmu_applyProviderAtIndex:rowIdx];
        }];
        a.state = (i == self.providerIndex) ? UIMenuElementStateOn : UIMenuElementStateOff;
        if (@available(iOS 15.0, *)) {
            a.subtitle = [NSString stringWithFormat:@"%ld/%lu · %@ · %ld lines",
                (long)i + 1, (unsigned long)cands.count, tier.length ? tier : @"?", (long)lines];
        }
        [rows addObject:a];
    }
    return [UIMenu menuWithTitle:@"" children:rows];
}

- (void)ytmu_refreshProviderSwitcher {
    NSArray *cands = self.providerCandidates;
    NSString *name = nil;
    if (self.providerIndex >= 0 && self.providerIndex < cands.count) {
        id p = cands[self.providerIndex][@"provider"];
        if ([p isKindOfClass:[NSString class]]) name = p;
    }
    if (self.providerSwitcherLabel) {
        if (name.length && cands.count > 0) {
            self.providerSwitcherLabel.text = [NSString stringWithFormat:@"%@ %ld/%lu", name, (long)self.providerIndex + 1, (unsigned long)cands.count];
        } else if (name.length) {
            self.providerSwitcherLabel.text = name;
        } else {
            self.providerSwitcherLabel.text = @"—";
        }
    }
    BOOL multi = cands.count > 1;
    self.providerPrevButton.enabled = multi;
    self.providerNextButton.enabled = multi;
    self.providerPrevButton.alpha = multi ? 1.0 : 0.4;
    self.providerNextButton.alpha = multi ? 1.0 : 0.4;
    // Collapsed trigger: current tier icon (better-lyrics dock style).
    NSString *tier = [self ytmu_currentTier];
    UIImage *tierIcon = tier ? YTMUTierIcon(tier, 20) : nil;
    if (tierIcon) {
        [self.headerMenuButton setImage:tierIcon forState:UIControlStateNormal];
        [self.landscapeProviderButton setImage:tierIcon forState:UIControlStateNormal];
    } else if (@available(iOS 13.0, *)) {
        UIImage *listImg = [UIImage systemImageNamed:@"list.bullet"];
        if (listImg) {
            [self.headerMenuButton setImage:listImg forState:UIControlStateNormal];
            [self.landscapeProviderButton setImage:listImg forState:UIControlStateNormal];
        }
    }
    // Compact anchored menu (iOS 14+); tap expands it, so the touchUpInside
    // probe path only fires while no candidates are known.
    if (@available(iOS 14.0, *)) {
        UIMenu *menu = [self ytmu_providerMenu];
        self.headerMenuButton.menu = menu;
        self.headerMenuButton.showsMenuAsPrimaryAction = (menu != nil);
        self.landscapeProviderButton.menu = menu;
        self.landscapeProviderButton.showsMenuAsPrimaryAction = (menu != nil);
    }
}

- (void)ytmu_setProbing:(BOOL)probing {
    CGFloat a = probing ? 0.45 : 1.0;
    self.headerMenuButton.alpha = a;
    self.headerMenuButton.enabled = !probing;
    self.landscapeProviderButton.alpha = a;
    self.landscapeProviderButton.enabled = !probing;
    self.landscapeReloadButton.alpha = a;
    self.providerPrevButton.enabled = !probing;
    self.providerNextButton.enabled = !probing;
    UIButton *retranslate = YTMURetranslateButton(self.landscapeToolbar);
    if (retranslate) {
        retranslate.alpha = a;
        retranslate.enabled = !probing;
    }
    if (self.providerSwitcherLabel && probing) self.providerSwitcherLabel.text = @"…";
    if (!probing) [self ytmu_refreshProviderSwitcher];
}

- (void)ytmu_showProviderMenu:(NSArray *)candidates saved:(NSString *)saved fromView:(UIView *)sender {
    NSString *vid = YTMUResolveCurrentVideoID() ?: g_currentVideoID;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Lyrics providers" message:vid preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSInteger i = 0; i < candidates.count; i++) {
        NSDictionary *c = candidates[i];
        if (![c isKindOfClass:[NSDictionary class]]) continue;
        NSString *prov = c[@"provider"];
        if (![prov isKindOfClass:[NSString class]] || !prov.length) continue;
        NSString *tier = ([c[@"tier"] isKindOfClass:[NSString class]]) ? c[@"tier"] : @"";
        NSInteger lines = [c[@"lines"] integerValue];
        BOOL isCurrent = (i == self.providerIndex);
        BOOL isSaved = (saved.length > 0 && [prov isEqualToString:saved]);
        NSString *title = [NSString stringWithFormat:@"%@%@%ld/%lu %@ — %@ · %ld lines",
            isCurrent ? @"[>] " : @"", isSaved ? @"[saved] " : @"",
            (long)i + 1, (unsigned long)candidates.count, prov, tier, (long)lines];
        NSInteger rowIdx = i;
        [menu addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self ytmu_applyProviderAtIndex:rowIdx];
        }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"Best available (auto)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self forceReloadLyrics];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *pop = menu.popoverPresentationController;
    if (pop) {
        UIView *anchor = (sender && sender.window) ? sender : self.view;
        pop.sourceView = anchor;
        pop.sourceRect = anchor.bounds;
        pop.permittedArrowDirections = UIPopoverArrowDirectionAny;
    }
    [self presentViewController:menu animated:YES completion:nil];
}

- (void)ytmu_selectProvider:(NSString *)provider {
    NSString *vid = YTMUResolveCurrentVideoID() ?: g_currentVideoID;
    if (!vid.length || !provider.length) return;
    // Remember the pre-apply index so a failed round-trip can put the
    // switcher back instead of advertising lyrics that never loaded.
    NSInteger prevIndex = self.providerIndex;
    NSDictionary *body = @{@"video_id": vid, @"lang": YTMUTargetLang(), @"provider": provider};
    [self ytmu_postJSON:@"/api/lyrics/providers/select" body:body completion:^(NSDictionary *json, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSDictionary *data = json[@"data"];
            NSArray *lyrics = data[@"lyrics"];
            if ([json[@"ok"] boolValue] && [lyrics isKindOfClass:[NSArray class]] && lyrics.count > 0) {
                if (!g_lyricsCache) g_lyricsCache = [[NSMutableDictionary alloc] init];
                g_lyricsCache[vid] = lyrics;
                YTMULyricsCacheSave(vid, lyrics);
                // Only adopt the id this select was issued for while it is still
                // the song on screen: writing it back unconditionally rolled
                // loadingVideoID back to the previous video after a song skip,
                // which is what let the OLD song's artwork answer through the
                // guard in ytmu_applyArtworkImage:forVideoID:.
                NSString *curVideo = YTMUResolveCurrentVideoID() ?: g_currentVideoID;
                if (!curVideo.length || [vid isEqualToString:curVideo]) {
                    self.loadingVideoID = vid;
                }
                self.isLoading = NO;
                self.lastProvider = provider;
                id s = data[@"song"], a = data[@"artist"];
                if ([s isKindOfClass:[NSString class]] && ((NSString *)s).length) self.lastSongTitle = s;
                if ([a isKindOfClass:[NSString class]] && ((NSString *)a).length) self.lastSongArtist = a;
                for (NSInteger i = 0; i < self.providerCandidates.count; i++) {
                    id p = self.providerCandidates[i][@"provider"];
                    if ([p isKindOfClass:[NSString class]] && [p isEqualToString:provider]) { self.providerIndex = i; break; }
                }
                [self ytmu_refreshProviderSwitcher];
                UILabel *statusLabel = [self.tableView.tableHeaderView viewWithTag:8888];
                if (statusLabel) statusLabel.text = @"";
                // Same reasoning as the RAM paint above: /providers/select
                // returns a finished, translated payload, never a live one.
                self.typewriterLive = NO;
                [self updateLyrics:lyrics];
                [[NSNotificationCenter defaultCenter] postNotificationName:@"YTMULyricsDidLoad" object:vid userInfo:@{@"lyrics": lyrics}];
                sendDebugLog([NSString stringWithFormat:@"[MUSIC] provider selected: %@", provider]);
            } else {
                self.providerIndex = prevIndex;
                [self ytmu_refreshProviderSwitcher];
                sendDebugLog([NSString stringWithFormat:@"[MUSIC] provider select failed: %@", provider]);
            }
        });
    }];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGFloat W = self.view.bounds.size.width;
    CGFloat H = self.view.bounds.size.height;
    BOOL landscape = (W > H);
    // Gap between the album column and the lyrics table, mirrored on the
    // right edge. Declared here because the toolbar's max width uses it too.
    const CGFloat kLyricsGap = 24.0;

    if (landscape) {
        // --- Landscape, Image-2 style: fullscreen ambient blur, floating
        // album card left, lyrics right, minimal transport, toolbar.
        self.artworkImageView.hidden = NO;
        self.blurView.hidden = NO;
        self.darkOverlay.hidden = NO;
        [self ytmu_applyLandscapeTheme];

        // Show landscape chrome (right panel stays hidden: no seam by design)
        self.landscapeArtPanel.hidden = NO;
        self.landscapeRightPanel.hidden = YES;
        self.landscapeInfoPanel.hidden = NO;
        self.landscapeExitButton.hidden = NO;
        self.landscapeToolbar.hidden = NO;
        // One close affordance per configuration: in landscape that is
        // landscapeExitButton, so the portrait header's "X" and its menu button
        // (which sat on top of the exit button) both step aside. They are
        // hidden, not removed -- the portrait branch brings them back.
        [self ytmu_applyHeaderButtonsForLandscape:YES];

        // Sync artwork image whenever it changes
        if (self.artworkImageView.image && self.landscapeArtImageView.image != self.artworkImageView.image) {
            self.landscapeArtImageView.image = self.artworkImageView.image;
            // Cached/file path bypasses loadArtwork: still sample it (cheap;
            // no-ops when the bright/dark bucket is unchanged).
            [self ytmu_probeArtworkBrightness:self.artworkImageView.image];
        }

        CGFloat safeTop = 0, safeBottom = 0;
        if (@available(iOS 11.0, *)) {
            safeTop = self.view.safeAreaInsets.top;
            safeBottom = self.view.safeAreaInsets.bottom;
        }
        // Narrow left column like the reference: ~30%, clamped.
        CGFloat leftW = roundf(MIN(MAX(W * 0.30f, 260.0f), 360.0f));
        CGFloat rightW = W - leftW;
        self.landscapeArtPanel.frame = CGRectMake(0, 0, leftW, H);

        // Album card: square, rounded, floating with shadow.
        CGFloat colX = 16.0;
        CGFloat colW = leftW - colX * 2.0;
        CGFloat artS = colW;
        CGFloat colH = artS + 10.0 + 20.0 + 2.0 + 16.0 + 8.0 + 12.0 + 4.0 + 8.0 + 48.0;
        CGFloat artY = floor((H - colH) / 2.0);
        if (artY < safeTop + 8.0) artY = safeTop + 8.0;
        CGRect artFrame = CGRectMake(colX, artY, artS, artS);
        self.landscapeArtImageView.frame = artFrame;
        self.landscapeArtImageView.contentMode = UIViewContentModeScaleAspectFill;
        self.landscapeArtImageView.layer.cornerRadius = 10;
        self.landscapeArtImageView.layer.masksToBounds = YES;
        UIView *artShadow = [self.landscapeArtPanel viewWithTag:7104];
        if (!artShadow) {
            artShadow = [[UIView alloc] init];
            artShadow.tag = 7104;
            artShadow.backgroundColor = [UIColor blackColor];
            artShadow.userInteractionEnabled = NO;
            [self.landscapeArtPanel insertSubview:artShadow belowSubview:self.landscapeArtImageView];
        }
        artShadow.frame = artFrame;
        artShadow.layer.cornerRadius = 10;
        artShadow.layer.shadowColor = [[UIColor blackColor] CGColor];
        artShadow.layer.shadowOpacity = 0.35;
        artShadow.layer.shadowRadius = 14;
        artShadow.layer.shadowOffset = CGSizeMake(0, 8);

        // Title / artist under the card.
        self.landscapeInfoPanel.frame = CGRectMake(colX, artY + artS + 10.0, colW, colH - artS - 10.0);
        self.landscapeTitleLabel.frame = CGRectMake(0, 0, colW, 20);
        self.landscapeArtistLabel.frame = CGRectMake(0, 22, colW, 16);

        // Time labels + thin progress bar + knob.
        CGFloat timesY = 46;
        self.landscapeElapsedLabel.frame = CGRectMake(0, timesY, 60, 12);
        self.landscapeTotalLabel.frame = CGRectMake(colW - 60, timesY, 60, 12);
        CGFloat barY = timesY + 16;
        self.landscapeProgressTrack.frame = CGRectMake(0, barY, colW, 3);
        CGFloat progress = 0;
        CGFloat totalTime = 0;
        CGFloat curTime = 0;
        if (g_activePlayer && [g_activePlayer respondsToSelector:@selector(currentVideoTotalMediaTime)]) {
            totalTime = g_activePlayer.currentVideoTotalMediaTime;
            curTime = g_activePlayer.currentVideoMediaTime;
            if (totalTime > 0) progress = (CGFloat)(curTime / totalTime);
        }
        if (progress < 0) progress = 0;
        if (progress > 1) progress = 1;
        CGFloat trackW = self.landscapeProgressTrack.bounds.size.width;
        CGFloat fillW = floor(trackW * progress);
        self.landscapeProgressFill.frame = CGRectMake(0, 0, fillW, 3);
        self.landscapeElapsedLabel.text = [self ytmu_formatTime:curTime];
        self.landscapeTotalLabel.text = [self ytmu_formatTime:totalTime];
        CGFloat knobS = 8;
        CGFloat knobX = fillW - knobS / 2.0;
        if (knobX < 0) knobX = 0;
        if (knobX > trackW - knobS) knobX = trackW - knobS;
        self.landscapeProgressKnob.frame = CGRectMake(knobX, barY + (3 - knobS) / 2.0, knobS, knobS);

        // Centered minimal transport: prev, filled-circle play, next.
        CGFloat tY = barY + 14;
        CGFloat iconS = 44, playD = 48, tGap = 24;
        CGFloat totalBtnW = iconS + playD + iconS + tGap * 2;
        CGFloat btnX0 = floor((colW - totalBtnW) / 2.0);
        self.landscapePrevButton.frame = CGRectMake(btnX0, tY + 2, iconS, iconS);
        self.landscapePlayButton.frame = CGRectMake(btnX0 + iconS + tGap, tY, playD, playD);
        self.landscapeNextButton.frame = CGRectMake(btnX0 + iconS + tGap + playD + tGap, tY + 2, iconS, iconS);
        self.landscapePlayButton.layer.cornerRadius = playD / 2.0;

        // Top-right exit circle.
        CGFloat exitTop = (safeTop > 0 ? safeTop + 6.0 : 12.0);
        CGFloat exitS = 32;
        self.landscapeExitButton.frame = CGRectMake(W - exitS - 12.0, exitTop, exitS, exitS);
        self.landscapeExitButton.layer.cornerRadius = exitS / 2.0;

        // Bottom-right floating toolbar: provider switcher ([<][list][name
        // i/n][>]) + reload + retranslate. Six controls on one pill, so the
        // paddings are tight; the name label is what gives first when the
        // screen is too narrow for the full pill (never a second row, never
        // an unreachable control).
        CGFloat toolBtnS = 32, toolSmallS = 28, toolLabelW = 84, toolPad = 3, toolGap = 3;
        CGFloat toolFixed = toolPad * 2 + 2 + toolGap * 5 + toolBtnS * 3 + toolSmallS * 2;
        CGFloat toolMax = MAX(160.0, W - (leftW + kLyricsGap) - 16.0);
        if (toolLabelW > toolMax - toolFixed) toolLabelW = MAX(0.0, toolMax - toolFixed);
        CGFloat toolW = toolFixed + toolLabelW;
        CGFloat toolH = toolBtnS + 6;
        CGFloat yBig = floor((toolH - toolBtnS) / 2.0);
        CGFloat ySmall = floor((toolH - toolSmallS) / 2.0);
        CGFloat toolY = H - safeBottom - toolH - 12.0;
        self.landscapeToolbar.frame = CGRectMake(W - toolW - 16.0, toolY, toolW, toolH);
        self.landscapeToolbar.layer.cornerRadius = toolH / 2.0;
        CGFloat tx = toolPad + 2;
        self.providerPrevButton.frame = CGRectMake(tx, ySmall, toolSmallS, toolSmallS); tx += toolSmallS + toolGap;
        self.landscapeProviderButton.frame = CGRectMake(tx, yBig, toolBtnS, toolBtnS); tx += toolBtnS + toolGap;
        self.providerNextButton.frame = CGRectMake(tx, ySmall, toolSmallS, toolSmallS); tx += toolSmallS + toolGap;
        self.providerSwitcherLabel.frame = CGRectMake(tx, yBig, toolLabelW, toolBtnS); tx += toolLabelW + toolGap;
        self.landscapeReloadButton.frame = CGRectMake(tx, yBig, toolBtnS, toolBtnS); tx += toolBtnS + toolGap;
        UIButton *retranslate = YTMURetranslateButton(self.landscapeToolbar);
        if (retranslate) retranslate.frame = CGRectMake(tx, yBig, toolBtnS, toolBtnS);

        // Keep title/artist fresh
        [self ytmu_updateLandscapeMetadata];

        // tableView floats on the ambient blur, right of the column, with a
        // gutter on BOTH sides so the lyrics never crowd the album card or the
        // screen edge (the cell adds its own gutter on top of this one).
        CGFloat lyricsGap = kLyricsGap;
        self.tableView.frame = CGRectMake(leftW + lyricsGap, 0, MAX(80.0, rightW - lyricsGap * 2.0), H);
        [self.view bringSubviewToFront:self.landscapeArtPanel];
        [self.view bringSubviewToFront:self.tableView];
        [self.view bringSubviewToFront:self.fpsLabel];
        [self.view bringSubviewToFront:self.landscapeToolbar];
        [self.view bringSubviewToFront:self.landscapeExitButton];
        [self.landscapeArtPanel bringSubviewToFront:self.landscapeInfoPanel];
        self.landscapeArtPanel.userInteractionEnabled = YES;
        self.landscapeInfoPanel.userInteractionEnabled = YES;
        // YT re-shows the panel's own header whenever it lays the panel out, so
        // the embedded case re-asserts on every pass (this is also the first
        // pass after a rotation, before the first tick).
        [self ytmu_assertOnTop];

        // Smaller bottom inset in landscape (less scroll space needed)
        CGFloat bottomPad = MAX(120.0, H * 0.30f);
        UIEdgeInsets current = self.tableView.contentInset;
        if (fabs(current.bottom - bottomPad) > 1.0) {
            self.tableView.contentInset = UIEdgeInsetsMake(current.top, 0, bottomPad, 0);
            self.tableView.scrollIndicatorInsets = UIEdgeInsetsMake(0, 0, bottomPad, 0);
        }
        UIView *footer = self.tableView.tableFooterView;
        if (!footer || fabs(footer.frame.size.height - bottomPad) > 1.0) {
            UIView *f = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, bottomPad)];
            f.backgroundColor = [UIColor clearColor];
            self.tableView.tableFooterView = f;
        }
    } else {
        // --- Portrait: full-screen blurred artwork background ---
        self.artworkImageView.hidden = NO;
        self.blurView.hidden = NO;
        self.darkOverlay.hidden = NO;
        self.landscapeArtPanel.hidden = YES;
        self.landscapeRightPanel.hidden = YES;
        self.landscapeInfoPanel.hidden = YES;
        self.landscapeExitButton.hidden = YES;
        self.landscapeToolbar.hidden = YES;
        // Back to the portrait sheet chrome: the header's own "X" and menu
        // button are the single close affordance here.
        [self ytmu_applyHeaderButtonsForLandscape:NO];

        // Restore tableView to full bounds
        self.tableView.frame = self.view.bounds;

        CGFloat visibleHeight = H;
        CGFloat bottomPad = MAX(350.0, visibleHeight * 0.60);

        UIEdgeInsets current = self.tableView.contentInset;
        if (fabs(current.bottom - bottomPad) > 1.0) {
            self.tableView.contentInset = UIEdgeInsetsMake(current.top, 0, bottomPad, 0);
            self.tableView.scrollIndicatorInsets = UIEdgeInsetsMake(0, 0, bottomPad, 0);
        }
        UIView *existingFooter = self.tableView.tableFooterView;
        if (!existingFooter || fabs(existingFooter.frame.size.height - bottomPad) > 1.0) {
            UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, bottomPad)];
            footer.backgroundColor = [UIColor clearColor];
            self.tableView.tableFooterView = footer;
        }
    }

    // Header width sync (both orientations)
    UIView *header = self.tableView.tableHeaderView;
    if (header && fabs(header.frame.size.width - self.tableView.bounds.size.width) > 1.0) {
        header.frame = CGRectMake(0, 0, self.tableView.bounds.size.width, 54);
        self.tableView.tableHeaderView = header;
    }
}

// Rotating INTO landscape is the auto-open path's business (the device
// orientation observer), never ours. Rotating back to portrait closes us: the
// landscape fullscreen is a landscape layout, and surviving the rotation left a
// fullscreen PORTRAIT sheet the user never asked for.
//
// This is the INTERFACE orientation hook, which is what makes it safe where
// UIDeviceOrientationDidChangeNotification is not: a face-up jitter in
// landscape never gets here, so it can never close the panel.
- (void)viewWillTransitionToSize:(CGSize)toSize
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:toSize withTransitionCoordinator:coordinator];
    if (toSize.width > toSize.height) return;

    // Both configurations reach this (the embedded instance's view is inside
    // the rotating window), but only an instance that is actually the thing on
    // screen may act. A parked, hidden embedded instance is just sitting in the
    // panel: closing it would restore chrome and collapse a panel the user is
    // happily using.
    if (self.view.hidden || self.view.alpha < 0.05 || !self.view.window) return;
    // Only the fullscreen presentation is "the fullscreen": the tap fallback is
    // a page sheet, which has always followed the rotation and keeps doing so.
    if (self.isModal && self.modalPresentationStyle != UIModalPresentationFullScreen) return;
    // Anything presented above us owns the screen right now. A sibling lyrics
    // instance closes itself (one rotation must not tear the same panel down
    // twice), and a foreign sheet above us -- the settings page, say -- must
    // never have the view under it pulled out from underneath it.
    if (self.presentedViewController) return;
    UIViewController *topMost = topMostViewController();
    if (topMost != self && [topMost isKindOfClass:[YTMULyricsViewController class]]) {
        sendDebugLog(@"[MUSIC] rotate to portrait: another lyrics instance is on top, standing down");
        return;
    }

    // Bump now, not at completion: a chain armed for the landscape orientation
    // that is ending must be dead before anything can present behind the close.
    // The value is re-checked in the completion block, so a decision taken
    // since (a rotate back to landscape) wins over this one.
    NSUInteger generation = YTMUBumpOrientationGeneration();
    void (^close)(void) = ^{
        if (generation != YTMUCurrentOrientationGeneration()) {
            sendDebugLog(@"[MUSIC] rotate to portrait: superseded by a newer orientation decision");
            return;
        }
        // Re-check the INTERFACE: a rotation back to landscape inside the same
        // gesture (or one that started before this close landed) must keep the
        // panel up, not close it and let the stale chain re-present it.
        if (YTMUIsInterfaceLandscape()) {
            sendDebugLog(@"[MUSIC] rotate to portrait: interface is landscape again, keeping the panel");
            return;
        }
        [self ytmu_closeFullscreenWithReason:@"rotated back to portrait"];
    };
    if (coordinator) {
        [coordinator animateAlongsideTransition:nil
                                    completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
            close();
        }];
    } else {
        // No coordinator: fall back to one rotation-animation's worth of delay
        // so we never dismiss mid-rotation.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            close();
        });
    }
}

// The song whose cover this instance is showing or has claimed: the DISPLAY
// intent first, then the loading slot, then the global. Deliberately not
// loadingVideoID alone -- ytmu_selectProvider writes that one back from the id
// it captured at tap time, so a provider tap plus a song skip pointed the art
// path at the previous song.
- (NSString *)ytmu_artworkTargetVideoID {
    NSString *vid = self.artworkVideoID;
    if (!vid.length) vid = self.loadingVideoID;
    if (!vid.length) vid = g_currentVideoID;
    return vid;
}

- (void)ytmu_applyHeaderButtonsForLandscape:(BOOL)landscape {
    // The table header belongs to the portrait sheet. In landscape it is
    // covered by the fullscreen chrome, and its two buttons are hidden so the
    // only close control on screen is landscapeExitButton.
    UIButton *headerClose = YTMUHeaderCloseButton(self.tableView.tableHeaderView);
    if (headerClose) headerClose.hidden = landscape;
    if (self.headerMenuButton) self.headerMenuButton.hidden = landscape;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.displayLink invalidate];
    [self.providerPollTimer invalidate];
    [self ytmu_cancelTranslateStream];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Appearing IS a new open, so the rotate/pref close latch is dropped here:
    // it guards the close, not the lifetime of the instance (the embedded one
    // outlives every close and is reused by the panel).
    YTMUSetClosedByRotation(self, NO);
    [self ytmu_assertOnTop];
    NSString *vid = YTMUResolveCurrentVideoID();
    if (vid) {
        [self ytmu_requestSongMetaForVideo:vid];
        [self ytmu_loadProviderMetaForVideo:vid];
    }
    [self ytmu_updateLandscapeMetadata];
    if (vid && (![vid isEqualToString:self.loadingVideoID] || (self.lyrics.count == 0 && !self.isLoading))) {
        [self fetchLyricsForVideo:vid];
    }
}

- (void)handleLyricsDidLoad:(NSNotification *)notif {
    // A closed instance stays closed. This notification is process-wide and
    // filtered only by video id, so a fetch belonging to a sibling instance
    // (the modal and the embedded panel are both alive during a rotation) used
    // to re-show a panel the user had just dismissed.
    if (YTMUIsClosedByRotation(self)) return;
    NSString *videoID = notif.object;
    NSArray *lyrics = notif.userInfo[@"lyrics"];
    if (videoID && lyrics && [videoID isEqualToString:g_currentVideoID]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UILabel *statusLabel = [self.tableView.tableHeaderView viewWithTag:8888];
            if (statusLabel) statusLabel.text = @"";
            [self updateLyrics:lyrics];
            // A retranslate is over as soon as a payload lands (the watchdog
            // covers the case where the server answered from cache and the
            // notification never fires).
            if (s_retranslateRunning) [self ytmu_endRetranslate:YES];
        });
    }
}

- (void)handleSongChange:(NSNotification *)notif {
    NSString *videoID = notif.object;
    if (videoID) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self ytmu_stopProviderPoll];
            [self ytmu_setProbing:NO];
            [self ytmu_cancelTranslateStream];
            [self ytmu_typeResetAll];
            // Disarm the reveal: a new song's translation is a cached payload
            // until a live fetch proves otherwise, and a leftover YES from the
            // previous song would animate this one for no reason.
            self.typewriterLive = NO;
            // One gate for everything a new song must forget, keyed on the song
            // that actually changed -- the DISPLAY ids, not loadingVideoID.
            // That field is rewritten by other writers (ytmu_selectProvider
            // writes back the id it captured at tap time), so a conditional
            // built on it could be skipped and the previous song's cover,
            // brightness bucket and ink tint all survived the change; the
            // pointer compare in viewDidLayoutSubviews then made the stale art
            // permanent.
            BOOL songChanged = (![self.displayedVideoID isEqualToString:videoID] ||
                                ![self.artworkVideoID isEqualToString:videoID]);
            if (songChanged) {
                self.currentIndex = -1;
                UILabel *statusLabel = [self.tableView.tableHeaderView viewWithTag:8888];
                statusLabel.text = @"";
                self.lyrics = @[];
                [self.tableView reloadData];
                // Art + background state, unconditional inside the change: the
                // new song claims the display intent first, then the old cover
                // is dropped from both image views.
                self.artworkVideoID = videoID;
                self.artworkImageView.image = nil;
                self.landscapeArtImageView.image = nil;
                g_ytmu_bgLight = -1;
                s_ytmuArtworkMean = nil;
                // Back to unsampled ink until the new cover lands, instead of
                // showing the previous song's tint on the chrome and lyrics.
                [self ytmu_refreshBgDerivedInk];
                // New song: drop stale per-song state so the retry chains
                // refill it (stale title/artist otherwise stick forever,
                // and the switcher would point at the old video's index).
                // The extrapolated media clock must restart too, or the new
                // song opens at the old song's position.
                self.clockRawTime = 0;
                self.clockRawWall = 0;
                self.activeIndexes = nil;
                self.lastColorKey = nil;
                YTMUResetScrollTracking();
                self.cachedWordLayoutKey = nil;
                self.cachedWordRects = nil;
                self.isLoading = NO;
                self.loadingSince = nil;
                self.landscapeTitleLabel.text = @"";
                self.landscapeArtistLabel.text = @"";
                self.lastSongTitle = nil;
                self.lastSongArtist = nil;
                self.songMetaVideoID = nil;
                self.lastProvider = nil;
                self.providerCandidates = nil;
                self.providerIndex = -1;
                [self ytmu_refreshProviderSwitcher];
            }
            // Cover and header text first, in parallel with everything below --
            // never after the lyrics response, the JWT or a server round trip.
            // The URL is the same one the server hands out from
            // GET /api/lyrics/image (i.ytimg.com/vi/<id>/maxresdefault.jpg with
            // the hqdefault fallback), so this costs no extra request and does
            // not need the stream's meta event to carry art.
            [self ytmu_requestArtworkOnce:videoID];
            [self ytmu_updateLandscapeMetadata];
            // Metadata + provider list come from the server for the new song:
            // two tiny reads, no provider traffic. They land whether the
            // lyrics come from the network, the server cache or the device
            // file cache. The lyrics of every provider then move into device
            // RAM so the source switcher is instant.
            [self ytmu_requestSongMetaForVideo:videoID];
            [self ytmu_loadProviderMetaForVideo:videoID];
            [self ytmu_loadProviderLyricsForVideo:videoID];
            [self fetchLyricsForVideo:videoID];
        });
    }
}

- (void)ytmu_volumeChanged:(NSNotification *)notif {
    if (!YTMULyricsPreference(@"lyricsFpsMeter", YES)) return;
    id param = notif.userInfo[@"AVSystemController_AudioVolumeNotificationParameter"];
    float vol = -1;
    if ([param isKindOfClass:[NSNumber class]]) {
        vol = [param floatValue];
    } else if ([param isKindOfClass:[NSDictionary class]]) {
        id v = ((NSDictionary *)param)[@"Volume"];
        if ([v isKindOfClass:[NSNumber class]]) vol = [v floatValue];
    }
    if (vol < 0) return;
    float prev = self.lastVolume;
    self.lastVolume = vol;
    if (prev >= 0 && vol < prev - 0.001) {
        self.fpsLabel.hidden = !self.fpsLabel.hidden;
        if (!self.fpsLabel.hidden) {
            self.fpsTicks = 0;
            self.fpsWindowStart = CACurrentMediaTime();
            self.fpsLabel.text = @"... fps";
        }
        sendDebugLog(@"[FPS] readout toggled by volume-down");
    }
}

// Sample new artwork; when the background flips bright/dark, re-resolve
// every background-derived color so text keeps contrasting with the blur
// instead of following the OS theme.
- (void)ytmu_probeArtworkBrightness:(UIImage *)img {
    CGFloat lum = YTMUArtworkLuminance(img);
    if (lum < 0) return;
    // The mean color is what tints the ink, so re-resolve whenever IT moves,
    // not only when the bright/dark bucket flips: two songs in the same
    // brightness band still have to swap the hue of their lyrics.
    UIColor *mean = YTMUArtworkAverageColor(img);
    BOOL meanMoved = (mean != s_ytmuArtworkMean) && ![mean isEqual:s_ytmuArtworkMean];
    YTMUSetArtworkMeanColor(mean);
    int light = (lum > 0.55) ? 1 : 0;
    if (light == g_ytmu_bgLight && !meanMoved) return;
    g_ytmu_bgLight = light;
    sendDebugLog([NSString stringWithFormat:@"[MUSIC] bg luminance %.2f -> %@ ink (tint %@)", lum, light ? @"black" : @"white", mean ? @"artwork" : @"none"]);
    [self ytmu_refreshBgDerivedInk];
}

- (void)ytmu_refreshChromeInk {
    // Buttons, pills, and transport chrome follow the blurred-artwork
    // brightness (not the OS theme) so they stay readable on any cover.
    // Re-run whenever the bg bucket changes; snapshots are static colors.
    UIView *ref = self.view;
    UIColor *ink = YTMULyricInk(0.9, 0.9, ref);
    UIColor *fill = YTMULyricFill(ref);
    void (^tintBtn)(UIButton *) = ^(UIButton *b) {
        if (!b) return;
        b.tintColor = ink;
        [b setTitleColor:ink forState:UIControlStateNormal];
    };
    if (self.headerMenuButton) {
        tintBtn(self.headerMenuButton);
        self.headerMenuButton.backgroundColor = fill;
    }
    if (self.landscapeArtImageView) self.landscapeArtImageView.backgroundColor = fill;
    if (self.landscapeProgressTrack) self.landscapeProgressTrack.backgroundColor = YTMULyricInk(0.25, 0.2, ref);
    if (self.landscapeProgressFill) self.landscapeProgressFill.backgroundColor = YTMULyricInk(0.95, 0.9, ref);
    if (self.landscapeProgressKnob) self.landscapeProgressKnob.backgroundColor = YTMULyricInk(1.0, 1.0, ref);
    tintBtn(self.landscapePrevButton);
    tintBtn(self.landscapeNextButton);
    tintBtn(self.landscapeReloadButton);
    tintBtn(YTMURetranslateButton(self.landscapeToolbar));
    tintBtn(self.landscapeProviderButton);
    tintBtn(self.providerPrevButton);
    tintBtn(self.providerNextButton);
    tintBtn(self.landscapeExitButton);
    if (self.landscapeToolbar) self.landscapeToolbar.backgroundColor = fill;
    if (self.landscapeExitButton) self.landscapeExitButton.backgroundColor = fill;
    if (self.providerSwitcherLabel) self.providerSwitcherLabel.textColor = YTMULyricInk(0.75, 0.75, ref);
    UILabel *statusLabel = [self.tableView.tableHeaderView viewWithTag:8888];
    if (statusLabel) statusLabel.textColor = YTMULyricInk(0.7, 0.75, ref);
    if (self.fpsLabel) self.fpsLabel.textColor = YTMULyricInk(0.7, 0.75, ref);
    [self ytmu_setLandscapePlaying:self.landscapeIsPlaying];
}

- (void)ytmu_refreshBgDerivedInk {
    self.view.backgroundColor = YTMUBgBaseColor(self.view);
    if (self.darkOverlay) self.darkOverlay.backgroundColor = YTMUBgOverlayColor(self.view);
    [self ytmu_applyLandscapeTheme];
    if (self.landscapeTitleLabel) self.landscapeTitleLabel.textColor = YTMULyricInk(1.0, 1.0, self.view);
    if (self.landscapeArtistLabel) self.landscapeArtistLabel.textColor = YTMULyricInk(0.6, 0.6, self.view);
    if (self.landscapeElapsedLabel) self.landscapeElapsedLabel.textColor = YTMULyricInk(0.6, 0.6, self.view);
    if (self.landscapeTotalLabel) self.landscapeTotalLabel.textColor = YTMULyricInk(0.6, 0.6, self.view);
    [self ytmu_refreshChromeInk];
    // reloadData keeps the scroll offset; cells re-resolve ink in configureCell.
    if (self.tableView) [self.tableView reloadData];
}

- (void)ytmu_applyArtworkImage:(UIImage *)img forVideoID:(NSString *)videoID {
    if (!img || !videoID.length) return;
    // Guarded on the DISPLAY INTENT (artworkVideoID, then the live player id),
    // never on loadingVideoID: that one is written by the two cache branches,
    // the network branch, forceReloadLyrics and ytmu_selectProvider -- which
    // writes back the id it captured at tap time, so a provider tap followed by
    // a song skip rolled it back to the previous video. A late response for the
    // old song was therefore accepted, painted the OLD cover into both image
    // views and stamped artworkVideoID, which made the pointer compare in
    // viewDidLayoutSubviews a permanent no-op.
    if (![videoID isEqualToString:self.artworkVideoID]) {
        NSString *cur = YTMUResolveCurrentVideoID();
        if (cur.length && [videoID isEqualToString:cur]) {
            // The song on screen that this instance had not claimed yet (the
            // view was built after the fetch started): adopt it, never drop a
            // current song's cover.
            self.artworkVideoID = videoID;
        } else {
            sendDebugLog([NSString stringWithFormat:@"[MUSIC] artwork dropped for %@ (display %@ / current %@)",
                          videoID, self.artworkVideoID ?: @"(nil)", cur ?: @"(nil)"]);
            return;
        }
    }
    // The fullscreen card is written first and directly: it must not depend on
    // artworkImageView (or on the layout pointer compare) to show the new
    // song's cover.
    self.landscapeArtImageView.image = img;
    [UIView transitionWithView:self.artworkImageView duration:0.4 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
        self.artworkImageView.image = img;
    } completion:nil];
    self.artworkVideoID = videoID;
    [self ytmu_probeArtworkBrightness:img];
    [self ytmu_applySongTint:img];
}

// Ask for a song's cover at most once per instance, so the several paths that
// want artwork (song change, the fetch branches, the updateLyrics: safety net)
// cannot pile up duplicate image requests for the same song.
- (void)ytmu_requestArtworkOnce:(NSString *)videoID {
    if (!videoID.length) return;
    NSString *asked = objc_getAssociatedObject(self, &s_ytmuArtRequestKey);
    if (asked.length && [asked isEqualToString:videoID]) return;
    objc_setAssociatedObject(self, &s_ytmuArtRequestKey, [videoID copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
    [self loadArtworkForVideo:videoID];
}

- (void)ytmu_applySongTint:(UIImage *)img {
    // Translucent wash of the song's own color over the blurred artwork, so
    // the whole lyrics UI (portrait + landscape share self.view) follows
    // the cover. Animated so song changes cross-fade instead of popping.
    if (!img || !self.view || !self.blurView) return;
    // Reuse the mean the brightness probe already sampled; only pay for a
    // sample here when the tint runs without one (and keep it for the ink).
    UIColor *avg = s_ytmuArtworkMean;
    if (!avg) {
        avg = YTMUArtworkAverageColor(img);
        YTMUSetArtworkMeanColor(avg);
    }
    if (!avg) return;
    if (!self.songTintView) {
        UIView *t = [[UIView alloc] initWithFrame:self.view.bounds];
        t.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        t.userInteractionEnabled = NO;
        t.backgroundColor = [UIColor clearColor];
        [self.view insertSubview:t aboveSubview:self.blurView];
        self.songTintView = t;
    }
    [UIView animateWithDuration:0.6 animations:^{
        self.songTintView.backgroundColor = [avg colorWithAlphaComponent:0.28];
    }];
}

- (void)loadArtworkForVideo:(NSString *)videoID {
    if (!videoID || videoID.length == 0) return;

    NSString *maxURL = [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/maxresdefault.jpg", videoID];
    [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:maxURL] completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
        NSHTTPURLResponse *httpRes = (NSHTTPURLResponse *)res;
        if (!err && data && httpRes.statusCode == 200) {
            UIImage *img = [UIImage imageWithData:data];
            if (img) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self ytmu_applyArtworkImage:img forVideoID:videoID];
                });
                return;
            }
        }
        NSString *hqURL = [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/hqdefault.jpg", videoID];
        [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:hqURL] completionHandler:^(NSData *d2, NSURLResponse *r2, NSError *e2) {
            if (!e2 && d2) {
                UIImage *img2 = [UIImage imageWithData:d2];
                if (img2) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self ytmu_applyArtworkImage:img2 forVideoID:videoID];
                    });
                }
            }
        }] resume];
    }] resume];
}

// The ONLY way a full fetch is started. Turnstile is never a gate here.
//
// The server falls back to its own shared JWT pool whenever a request carries
// no `jwt` param (server/pipeline.py does `if not jwt_token: jwt_token =
// pick_jwt()`), and that pool is kept warm by every device that contributes a
// token on any /api/lyrics request. So a missing token costs us NOTHING: the
// request just goes out immediately and the server picks one. Waiting for a
// local challenge instead meant a cold start sat idle for up to 10s on the
// very request that is also the SSE translation stream (see
// YTMULyricsStreamTranslateEnabled in fetchFullLyricsForVideo: below), which
// is the whole point of that fetch.
//
// Route taken:
//   cached token  a token is already on the manager, so it rides along for free
//   pool          none cached, so the request goes out with none and the server
//                 pool answers it; the challenge is kicked off in the
//                 background purely to keep the manager warm for later requests
//                 and to contribute a token to that pool on the next call.
//                 Fire-and-forget: the completion is nil, so a token that
//                 arrives later never triggers a second fetch.
- (void)ytmu_startFullFetchForVideoID:(NSString *)videoID force:(BOOL)force from:(NSString *)from {
    NSString *cached = [YTMUTurnstileManager sharedManager].jwtToken;
    BOOL haveCached = (cached.length > 0);
    sendDebugLog([NSString stringWithFormat:@"[MUSIC] full fetch without waiting for Turnstile (%@, %@)",
                  haveCached ? @"cached token" : @"pool", from ?: @"fetch"]);
    [self fetchFullLyricsForVideo:videoID jwt:(haveCached ? cached : nil) force:force];
    if (haveCached) return;
    [[YTMUTurnstileManager sharedManager] getJWTTokenWithCompletion:nil];
}

- (void)fetchFullLyricsForVideo:(NSString *)videoID jwt:(NSString *)jwt force:(BOOL)force {
    if (![self.loadingVideoID isEqualToString:videoID]) {
        self.isLoading = NO;
        self.loadingSince = nil;
        if ([g_globalLoadingVideoID isEqualToString:videoID]) {
            YTMUReleaseGlobalFetch();
        }
        return;
    }

    // Streamed translation: the same server-side work, but the ranked lyrics
    // land first and every translated line arrives as the model writes it (see
    // Source/LyricsStream.x). Falls back to the blocking JSON fetch if the
    // stream dies before delivering anything.
    if (YTMULyricsStreamTranslateEnabled() && !self.tstreamFallbackUsed) {
        [self ytmu_openTranslateStream:videoID jwt:jwt force:force];
        return;
    }

    NSString *fullURL = [NSString stringWithFormat:@"%@/api/lyrics?v=%@&lang=%@%@", YTMUApiBase(), videoID, YTMUUrlEncode(YTMUTargetLang()), YTMUAutoZhParam()];
    if (force) {
        fullURL = [fullURL stringByAppendingString:@"&force=1"];
    }
    if (jwt) {
        fullURL = [fullURL stringByAppendingFormat:@"&jwt=%@", jwt];
    }

    [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:fullURL] completionHandler:^(NSData *fullData, NSURLResponse *fullRes, NSError *fullErr) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.isLoading = NO;
            self.loadingSince = nil;
            if ([g_globalLoadingVideoID isEqualToString:videoID]) {
                YTMUReleaseGlobalFetch();
            }

            if (![self.loadingVideoID isEqualToString:videoID]) return;

            UILabel *statusLabel = [self.tableView.tableHeaderView viewWithTag:8888];
            if (fullData && !fullErr) {
                NSDictionary *fullDict = [NSJSONSerialization JSONObjectWithData:fullData options:0 error:nil];
                if (YTMULyricsIsUsable(fullDict[@"lyrics"], fullDict)) {
                    statusLabel.text = @"";
                    // Same rule as the fast request: only a live pipeline may
                    // animate. This branch is the stream-off / stream-dead
                    // path, where the translation lands in one piece, so the
                    // reveal is off unless the server ran one just now.
                    id cf = fullDict[@"cached"];
                    self.typewriterLive = (cf != nil) && ![cf boolValue];
                    if (!g_lyricsCache) g_lyricsCache = [[NSMutableDictionary alloc] init];
                    g_lyricsCache[videoID] = fullDict[@"lyrics"];
                    YTMULyricsCacheSave(videoID, fullDict[@"lyrics"]);
                    id fs = fullDict[@"song"], fa = fullDict[@"artist"], fp = fullDict[@"source"];
                    if ([fs isKindOfClass:[NSString class]] && ((NSString *)fs).length) self.lastSongTitle = fs;
                    if ([fa isKindOfClass:[NSString class]] && ((NSString *)fa).length) self.lastSongArtist = fa;
                    if ([fp isKindOfClass:[NSString class]] && ((NSString *)fp).length) self.lastProvider = fp;
                    [self ytmu_applyProviderMeta:fullDict forVideoID:videoID];
                    [self ytmu_updateLandscapeMetadata];
                    [self updateLyrics:fullDict[@"lyrics"]];
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"YTMULyricsDidLoad"
                                                                        object:videoID
                                                                      userInfo:@{@"lyrics": fullDict[@"lyrics"]}];
                } else if (self.lyrics.count == 0) {
                    statusLabel.text = @"[WARN] 找不到歌詞 / No lyrics found";
                    if (self.isModal) self.view.hidden = NO;
                    self.lyrics = @[];
                    [self.tableView reloadData];
                }
            } else if (self.lyrics.count == 0) {
                statusLabel.text = @"[WARN] 網路錯誤 / Network error";
                if (self.isModal) self.view.hidden = NO;
                self.lyrics = @[];
                [self.tableView reloadData];
            }
        });
    }] resume];
}

- (void)ytmuCheckServerUpgradeForVideoID:(NSString *)videoID {
    if (!videoID.length) return;
    if (!YTMULyricsPreference(@"lyricsAutoUpdate", YES)) return;
    NSArray *tierLyrics = g_lyricsCache[videoID] ?: YTMULyricsCacheLoad(videoID);
    if (!tierLyrics) return;
    static NSMutableDictionary *g_upgradeLastCheck = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_upgradeLastCheck = [NSMutableDictionary dictionary];
    });
    NSDate *last = g_upgradeLastCheck[videoID];
    if (last && [[NSDate date] timeIntervalSinceDate:last] < 300) return;
    g_upgradeLastCheck[videoID] = [NSDate date];

    NSString *tier = YTMULyricsTier(tierLyrics);
    NSInteger cacheVersion = YTMULyricsCacheVersionForVideoID(videoID);
    NSString *url = [NSString stringWithFormat:@"%@/api/lyrics/check?v=%@&lang=%@&ct=%@&cv=%ld",
                     YTMUApiBase(), videoID, YTMUUrlEncode(YTMUTargetLang()), tier, (long)cacheVersion];
    [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:url]
        completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!data || err) return;
            // Stale check landing after a song change must not full-fetch
            // a video that is no longer playing.
            if (![videoID isEqualToString:YTMUResolveCurrentVideoID()]) return;
            NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            // This call also carries the song metadata and the provider list
            // the server holds for this video: both fill in on the pure
            // cache-hit path, where no lyrics fetch ever runs.
            id cs = dict[@"song"], ca = dict[@"artist"];
            if ([cs isKindOfClass:[NSString class]] && ((NSString *)cs).length) self.lastSongTitle = cs;
            if ([ca isKindOfClass:[NSString class]] && ((NSString *)ca).length) self.lastSongArtist = ca;
            [self ytmu_applyProviderMeta:dict forVideoID:videoID];
            [self ytmu_updateLandscapeMetadata];
            if ([dict[@"upgrade"] boolValue]) {
                sendDebugLog(@"[MUSIC] Server has a better lyrics tier, upgrading");
                // Same still-current check the old Turnstile completion did,
                // just moved in front of the call instead of inside it: a
                // stale check must not fetch for a song that already moved on.
                if (![videoID isEqualToString:YTMUResolveCurrentVideoID()]) return;
                [self ytmu_startFullFetchForVideoID:videoID force:NO from:@"upgrade"];
            }
        });
    }] resume];
}

- (void)fetchLyricsForVideo:(NSString *)videoID {
    if (!videoID || videoID.length == 0) return;

    // Being asked for lyrics again is an open, so the close latch goes: the
    // re-open path (settings toggle, the panel coming back, a song change)
    // lands here and must be able to paint again.
    YTMUSetClosedByRotation(self, NO);

    if (!g_lyricsCache) {
        g_lyricsCache = [[NSMutableDictionary alloc] init];
    }

    // Display intent, claimed before any branch (including the two early
    // "Waiting..." returns below): every art/metadata response is validated
    // against this id, so a late answer for the previous song is dropped and
    // the song on screen is never dropped.
    self.artworkVideoID = videoID;

    // Metadata + provider list first, so the full screen header and the
    // switcher are right even when the lyrics turn out to be a cache hit.
    [self ytmu_requestSongMetaForVideo:videoID];
    [self ytmu_loadProviderMetaForVideo:videoID];
    [self ytmu_loadProviderLyricsForVideo:videoID];

    if (g_lyricsCache[videoID]) {
        UILabel *statusLabel = [self.tableView.tableHeaderView viewWithTag:8888];
        statusLabel.text = @"";
        self.loadingVideoID = videoID;
        self.isLoading = NO;
        // RAM cache hit: the translation already exists, so it paints whole.
        self.typewriterLive = NO;
        [self ytmu_requestArtworkOnce:videoID];
        [self updateLyrics:g_lyricsCache[videoID]];
        [self ytmuCheckServerUpgradeForVideoID:videoID];
        return;
    }
    if (YTMULyricsCacheEnabled()) {
        NSArray *fileCached = YTMULyricsCacheLoad(videoID);
        if (fileCached) {
            if (!g_lyricsCache) g_lyricsCache = [[NSMutableDictionary alloc] init];
            g_lyricsCache[videoID] = fileCached;
            UILabel *statusLabel = [self.tableView.tableHeaderView viewWithTag:8888];
            statusLabel.text = @"";
            self.loadingVideoID = videoID;
            self.isLoading = NO;
            self.typewriterLive = NO;  // on-device cache hit, same reasoning
            [self ytmu_requestArtworkOnce:videoID];
            [self updateLyrics:fileCached];
            [self ytmuCheckServerUpgradeForVideoID:videoID];
            return;
        }
    }

    UILabel *statusLabel = [self.tableView.tableHeaderView viewWithTag:8888];
    statusLabel.text = @"Loading...";

    if (![videoID isEqualToString:self.loadingVideoID]) {
        self.currentIndex = -1;
        self.activeIndexes = nil;
        self.lyrics = @[];
        [self.tableView reloadData];
        if (self.isModal) self.view.hidden = NO;
    }

    if (g_globalLoadingInFlight && [g_globalLoadingVideoID isEqualToString:videoID]) {
        if (g_loadingSince && [[NSDate date] timeIntervalSinceDate:g_loadingSince] > 45) {
            sendDebugLog(@"[WARN] Reclaiming stale global fetch slot");
            YTMUReleaseGlobalFetch();
        } else {
            statusLabel.text = @"Waiting...";
            return;
        }
    }
    if (self.isLoading && [self.loadingVideoID isEqualToString:videoID]) {
        if (self.loadingSince && [[NSDate date] timeIntervalSinceDate:self.loadingSince] <= 45) {
            statusLabel.text = @"Waiting...";
            return;
        }
        sendDebugLog(@"[WARN] Reclaiming stale instance fetch slot");
    }

    g_globalLoadingInFlight = YES;
    g_globalLoadingVideoID = videoID;
    g_loadingSince = [NSDate date];
    self.isLoading = YES;
    self.loadingVideoID = videoID;
    self.loadingSince = [NSDate date];

    [self ytmu_requestArtworkOnce:videoID];

    NSString *fastURL = [NSString stringWithFormat:@"%@/api/lyrics?v=%@&fast=1&lang=%@%@", YTMUApiBase(), videoID, YTMUUrlEncode(YTMUTargetLang()), YTMUAutoZhParam()];
    [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:fastURL] completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self.loadingVideoID isEqualToString:videoID]) {
                // Stale response for a previous video: release the slots it
                // claimed instead of wedging later fetches until reclaim.
                self.isLoading = NO;
                self.loadingSince = nil;
                if ([g_globalLoadingVideoID isEqualToString:videoID]) {
                    YTMUReleaseGlobalFetch();
                }
                return;
            }
            if (data && !err) {
                NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if (YTMULyricsIsUsable(dict[@"lyrics"], dict)) {
                    statusLabel.text = @"";
                    // Server says cached:1 -> the lines came off disk (full key,
                    // fast key or a node), so there is nothing being written and
                    // nothing to reveal. cached:0 -> a live pipeline ran and the
                    // translation arrived with the response, which is the one
                    // case a reveal is still honest about.
                    id cf = dict[@"cached"];
                    self.typewriterLive = (cf != nil) && ![cf boolValue];
                    id fs = dict[@"song"], fa = dict[@"artist"];
                    if ([fs isKindOfClass:[NSString class]] && ((NSString *)fs).length) self.lastSongTitle = fs;
                    if ([fa isKindOfClass:[NSString class]] && ((NSString *)fa).length) self.lastSongArtist = fa;
                    [self ytmu_applyProviderMeta:dict forVideoID:videoID];
                    [self ytmu_updateLandscapeMetadata];
                    [self updateLyrics:dict[@"lyrics"]];
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"YTMULyricsDidLoad"
                                                                        object:videoID
                                                                      userInfo:@{@"lyrics": dict[@"lyrics"]}];
                    if ([dict[@"pro"] boolValue]) {
                        // Server served the full cached result for this fast
                        // request: treat it as final, skip the full fetch.
                        // Same bookkeeping as the full path (provider + song
                        // feed the switcher index and the title fallback).
                        if (!g_lyricsCache) g_lyricsCache = [[NSMutableDictionary alloc] init];
                        g_lyricsCache[videoID] = dict[@"lyrics"];
                        YTMULyricsCacheSave(videoID, dict[@"lyrics"]);
                        id fp = dict[@"source"];
                        if ([fp isKindOfClass:[NSString class]] && ((NSString *)fp).length) self.lastProvider = fp;
                        self.isLoading = NO;
                        self.loadingSince = nil;
                        if ([g_globalLoadingVideoID isEqualToString:videoID]) {
                            YTMUReleaseGlobalFetch();
                        }
                        return;
                    }
                }
            }

            // Upgrade needed. Go straight at it: no Turnstile gate, no 10s
            // wait for a local challenge. fetchFullLyricsForVideo: re-checks
            // loadingVideoID on its own (and releases the slots it claimed if
            // the song moved on), so the guard the old timeout branch did is
            // still covered.
            [self ytmu_startFullFetchForVideoID:videoID force:NO from:@"fast"];
        });
    }] resume];
}

- (void)ytmu_assertOnTop {
    // Embed only (tag 9999): YT reorders/unhides its engagement-panel
    // content at any time (song change, layout passes), which buries the
    // lyrics view again after updateLyrics put it on top. Modal sheets are
    // presented above YT by UIKit and need nothing here.
    if (self.isModal) return;
    if (self.view.tag != 9999) return;
    UIView *contentContainer = self.view.superview;
    if (!contentContainer) return;
    if ([contentContainer.subviews lastObject] != self.view) {
        [contentContainer bringSubviewToFront:self.view];
    }
    // Never blank the panel: only hide YT siblings while our view is
    // actually visible AND showing lyrics (lyricsAlwaysOn off + hidden or
    // empty sheet = native panel).
    if (self.view.hidden || self.view.alpha < 0.05 || !self.view.window) return;
    if (self.lyrics.count == 0) return;
    for (UIView *sub in contentContainer.subviews) {
        if (sub != self.view && sub.tag != 9999 && !sub.hidden) sub.hidden = YES;
    }
    // The panel's own header (with its dismiss control) lives one level up, so
    // the loop above never reached it and its X stayed visible next to our
    // fullscreen exit button -- the third close control. Hidden with the same
    // rule, restored by ytmu_restoreHostingPanelChrome.
    UIView *panelHeader = YTMUPanelHeaderSibling(contentContainer);
    if (panelHeader && !panelHeader.hidden) panelHeader.hidden = YES;
}

- (BOOL)ytmu_lyricHasTiming:(NSDictionary *)lyric {
    if ([lyric[@"startTimeMs"] doubleValue] > 0) return YES;
    if ([lyric[@"time"] doubleValue] > 0) return YES;
    if ([lyric[@"durationMs"] doubleValue] > 0) return YES;
    if ([lyric[@"duration"] doubleValue] > 0) return YES;
    if ([lyric[@"wordSynced"] boolValue]) {
        for (NSDictionary *p in (NSArray *)lyric[@"parts"]) {
            if ([p[@"startTimeMs"] doubleValue] > 0) return YES;
        }
    }
    return NO;
}

- (double)ytmu_startMsForLyric:(NSDictionary *)lyric {
    double s = [lyric[@"startTimeMs"] doubleValue];
    if (s <= 0) s = [lyric[@"time"] doubleValue] * 1000.0;
    return MAX(s, 0.0);
}

- (BOOL)ytmu_lyricAtIndexHasTiming:(NSInteger)index {
    NSDictionary *lyric = self.lyrics[index];
    if ([self ytmu_lyricHasTiming:lyric]) return YES;
    // Leading [00:00.00] opener carries start 0 with no other keys; in a
    // synced list that is a real timestamp, not missing data.
    return index == 0 && [self ytmu_startMsForLyric:lyric] == 0;
}

- (double)ytmu_endMsForLyricAtIndex:(NSInteger)index {
    if (index < 0 || index >= self.lyrics.count) return 0;
    NSDictionary *lyric = self.lyrics[index];
    // A start of exactly 0 is valid (first line at [00:00.00]); lines with
    // no timing keys at all are untimed and never active.
    if (![self ytmu_lyricAtIndexHasTiming:index]) return 0;
    double start = [self ytmu_startMsForLyric:lyric];
    // Explicit duration from the payload.
    double explicitEnd = 0;
    double durMs = [lyric[@"durationMs"] doubleValue];
    if (durMs <= 0) durMs = [lyric[@"duration"] doubleValue] * 1000.0;
    if (durMs > 0) explicitEnd = start + durMs;
    // Word span end for word-synced lines (same 120ms floor as the wipe).
    double wordEnd = 0;
    NSArray *parts = lyric[@"parts"];
    if ([lyric[@"wordSynced"] boolValue] && [parts count] > 0) {
        for (NSDictionary *p in parts) {
            double s = [p[@"startTimeMs"] doubleValue];
            double d = MAX([p[@"durationMs"] doubleValue], 1.0);
            d = MAX(d, 120.0);
            if (s > 0 && s + d > wordEnd) wordEnd = s + d;
        }
    }
    double explicit = MAX(explicitEnd, wordEnd);
    if (explicit > start) return explicit;
    // No explicit timing: line runs until the next line starts (sequential
    // lines never overlap, so only truly overlapping payloads multi-light).
    if (index + 1 < self.lyrics.count) {
        double next = [self ytmu_startMsForLyric:self.lyrics[index + 1]];
        if (next > start) return next;
    }
    double fallback = durMs > 0 ? durMs : 4000.0;
    return start + fallback;
}

- (NSIndexSet *)ytmu_activeIndexesAtMs:(double)nowMs {
    NSMutableIndexSet *set = [NSMutableIndexSet indexSet];
    for (NSInteger i = 0; i < self.lyrics.count; i++) {
        NSDictionary *lyric = self.lyrics[i];
        if (![self ytmu_lyricAtIndexHasTiming:i]) continue;
        double start = [self ytmu_startMsForLyric:lyric];
        if (nowMs < start) continue;
        double end = [self ytmu_endMsForLyricAtIndex:i];
        if (end > start && nowMs < end) [set addIndex:i];
    }
    return set;
}

// Single entry point for every programmatic lyric scroll (line advance,
// tap-to-seek). `instant` forces the jump the far-jump rule asks for; on top
// of that a target arriving while an animated scroll is still in flight also
// jumps, which settles the running scroll instead of queueing a second one
// behind it. Runs on the same clock as the activation pop (the UIKit scroll
// settles in about one transition), so the line arrives and lights up as one
// motion.
//
// The resting position is braccato's: the sung line sits at 37% of the VISIBLE
// height rather than dead centre, which leaves the lines still to come room
// below it. That needs a computed offset, not -scrollToRowAtIndexPath:, because
// the table has a header and the table's own `Middle` ignores it.
- (void)ytmu_scrollToRow:(NSInteger)row instant:(BOOL)instant {
    if (row < 0 || row >= (NSInteger)self.lyrics.count || !self.tableView) return;
    NSTimeInterval now = CACurrentMediaTime();
    BOOL settling = (s_scrollInFlightRow >= 0 && s_scrollInFlightRow != row &&
                     (now - s_scrollStartedAt) < YTMUTransitionDuration);
    BOOL animate = (!instant && !settling);
    if (animate) {
        s_scrollInFlightRow = row;
        s_scrollStartedAt = now;
    } else {
        YTMUResetScrollTracking();
    }
    UITableView *tv = self.tableView;
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:row inSection:0];
    CGRect target = [tv rectForRowAtIndexPath:indexPath];
    CGFloat visible = CGRectGetHeight(tv.bounds);
    if (CGRectIsNull(target) || visible <= 1.0) {
        // Not laid out yet (or no rows): the old call is the safe fallback, it
        // asks the table to resolve the geometry itself.
        [tv scrollToRowAtIndexPath:indexPath atScrollPosition:UITableViewScrollPositionMiddle animated:animate];
        return;
    }
    UIEdgeInsets insets = tv.adjustedContentInset;
    CGFloat desired = CGRectGetMinY(target) + insets.top - visible * YTMUScrollTargetRatio;
    CGFloat lo = -insets.top;
    CGFloat hi = MAX(lo, tv.contentSize.height + insets.bottom - visible);
    desired = MIN(MAX(desired, lo), hi);
    CGPoint offset = CGPointMake(tv.contentOffset.x, desired);
    if (!animate) {
        [tv setContentOffset:offset animated:NO];
        return;
    }
    [UIView animateWithDuration:YTMUTransitionDuration
                          delay:0.0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{ [tv setContentOffset:offset animated:NO]; }
                     completion:nil];
}

- (void)updatePlaybackTime {
    self.fpsTicks++;
    NSTimeInterval fpsNow = CACurrentMediaTime();
    if (fpsNow - self.fpsWindowStart >= 1.0) {
        NSInteger fps = (NSInteger)(self.fpsTicks / MAX(fpsNow - self.fpsWindowStart, 0.001));
        self.fpsTicks = 0;
        self.fpsWindowStart = fpsNow;
        if (self.fpsLabel && !self.fpsLabel.hidden) {
            NSInteger maxFps = (NSInteger)[UIScreen mainScreen].maximumFramesPerSecond;
            self.fpsLabel.text = [NSString stringWithFormat:@"%ld/%ld fps", (long)fps, (long)maxFps];
            sendDebugLog([NSString stringWithFormat:@"[FPS] lyric render rate %ld fps (panel max %ld)", (long)fps, (long)maxFps]);
        }
    }
    // Self-healing z-order (~1/sec at the 120fps tick): YT reshuffles panel
    // subviews behind our back; the check itself is a pointer compare so
    // per-frame cost is ~zero. No-op for modal sheets (see ytmu_assertOnTop).
    static int ytmuTopAssertTick = 0;
    if ((++ytmuTopAssertTick % 120) == 0) {
        [self ytmu_assertOnTop];
    }
    // Backstop for the auto-open switch (the settings notification is the fast
    // path): same ~1/s rate, one NSUserDefaults dictionary read.
    static int ytmuAutoOpenTick = 0;
    if ((++ytmuAutoOpenTick % 120) == 0) {
        [self ytmu_enforceFullscreenAutoOpen];
    }
    if (self.landscapeInfoPanel && !self.landscapeInfoPanel.hidden) {
        [self ytmu_updateLandscapeProgress];
        // playerResponse can arrive after the panel opens; keep retrying
        // until a real title/artist is shown (throttled: ~1/sec at 120fps).
        static int landscapeMetaRetryTick = 0;
        BOOL needTitle = (self.landscapeTitleLabel.text.length == 0 ||
                          [self.landscapeTitleLabel.text isEqualToString:@"Now Playing"]);
        if ((needTitle || self.landscapeArtistLabel.text.length == 0) &&
            (landscapeMetaRetryTick++ % 120) == 0) {
            [self ytmu_updateLandscapeMetadata];
        }
    }
    if (!self.isSynced || self.lyrics.count == 0) {
        // Nothing to reveal without timing: drop any mask and state the tick
        // would otherwise never get to clean up (it returns here too).
        if (self.typeState.count) [self ytmu_typeResetAll];
        return;
    }

    double currentTime = 0;
    NSTimeInterval tickNow = CACurrentMediaTime();
    double rawTime = 0;
    if (g_activePlayer) {
        if ([g_activePlayer respondsToSelector:@selector(currentVideoMediaTime)]) {
            rawTime = [g_activePlayer currentVideoMediaTime];
        } else if ([g_activePlayer respondsToSelector:@selector(currentMediaTime)]) {
            rawTime = [g_activePlayer currentMediaTime];
        }
    }
    if (rawTime > 0) {
        // Extrapolated media clock (braccato tickView parity): the player
        // clock updates discretely, so rebasing on every sample and
        // extrapolating locally keeps the wipe smooth between samples.
        // A clock that stops advancing (paused/stall) freezes after 0.2s
        // instead of running ahead; seeks rebase via the sample jump.
        if (fabs(rawTime - self.clockRawTime) > 0.0005) {
            self.clockRawTime = rawTime;
            self.clockRawWall = tickNow;
        }
        if (tickNow - self.clockRawWall < 0.2) {
            currentTime = self.clockRawTime + (tickNow - self.clockRawWall);
        } else {
            currentTime = self.clockRawTime;
        }
        g_currentPlaybackTime = currentTime;
    } else {
        currentTime = g_currentPlaybackTime;
    }

    // Apply per-song timing offset
    if (g_currentVideoID.length) {
        double offset = YTMULyricsOffsetForVideoID(g_currentVideoID);
        if (offset != 0.0) {
            currentTime += offset;
        }
    }

    if (currentTime <= 0) return;

    // Multi-line active set: every line whose [start, end) window covers
    // now lights up, so overlapping payloads (duets, backing vocals, TTML
    // with explicit durations past the next start) highlight 2+ lines at
    // once. Sequential line-timed lyrics still collapse to a single line
    // because each line ends where the next starts.
    double nowMs = currentTime * 1000.0;
    NSIndexSet *newActive = [self ytmu_activeIndexesAtMs:nowMs];
    NSInteger newIndex = (NSInteger)newActive.lastIndex;
    if (newIndex == NSNotFound) newIndex = -1;
    NSIndexSet *oldActive = self.activeIndexes ?: [NSIndexSet indexSet];
    NSInteger oldIndex = self.currentIndex;

    if (![newActive isEqualToIndexSet:oldActive]) {
        self.activeIndexes = newActive;
        self.currentIndex = newIndex;

        NSMutableIndexSet *deactivated = [oldActive mutableCopy];
        [deactivated removeIndexes:newActive];
        NSMutableIndexSet *activated = [newActive mutableCopy];
        [activated removeIndexes:oldActive];
        for (NSUInteger i = [deactivated firstIndex]; i != NSNotFound; i = [deactivated indexGreaterThanIndex:i]) {
            YTMULyricsCell *oldCell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:(NSInteger)i inSection:0]];
            if (oldCell) {
                [self configureCell:oldCell atIndex:(NSInteger)i isActive:NO currentTime:currentTime];
            }
            // Leaving the active set finishes the reveal: a line must never be
            // left half-typed behind the reader.
            [self ytmu_typeRow:(NSInteger)i activate:NO];
        }
        for (NSUInteger i = [activated firstIndex]; i != NSNotFound; i = [activated indexGreaterThanIndex:i]) {
            YTMULyricsCell *newCell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:(NSInteger)i inSection:0]];
            if (newCell) {
                [self configureCell:newCell atIndex:(NSInteger)i isActive:YES currentTime:currentTime];
                NSDictionary *nl = self.lyrics[i];
                BOOL wordSynced = [nl[@"wordSynced"] boolValue] && [(NSArray *)nl[@"parts"] count] > 0;
                // The arrival motion, and it differs by payload the way braccato's
                // own themes differ:
                //   word-synced -> NO pop. The row's arrival gesture is the
                //     per-word sway driven in -applyWordColorsToCell, and a pop
                //     under it would fight the mask for 0.28s.
                //   line-synced -> the restrained pop, on BOTH label copies so
                //     the dim base and the bright reveal scale as one. That also
                //     fixes the old restriction: scaling the base label used to
                //     be skipped on word-synced rows because applyWordColors
                //     repaints it every tick, but a transform rides on top of
                //     that repaint and is dropped by the next configure.
                if (UIAccessibilityIsReduceMotionEnabled()) {
                    [newCell ytmu_fadeHighlightTo:1.0 duration:0.0];
                } else if (wordSynced) {
                    [newCell ytmu_beginHighlightArrivalWithDuration:YTMUHighlightFadeInDuration];
                } else {
                    newCell.lyricLabel.alpha = YTMUPopStartAlpha;
                    newCell.lyricLabel.transform = CGAffineTransformMakeScale(YTMUPopScale, YTMUPopScale);
                    newCell.wipeLabel.transform = newCell.lyricLabel.transform;
                    [UIView animateWithDuration:YTMUTransitionDuration delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
                        newCell.lyricLabel.alpha = 1.0;
                        newCell.lyricLabel.transform = CGAffineTransformIdentity;
                        newCell.wipeLabel.transform = CGAffineTransformIdentity;
                    } completion:nil];
                    [newCell ytmu_beginHighlightArrivalWithDuration:YTMUHighlightFadeInDuration];
                }
            }
            // Starts the letter-by-letter reveal of the translation under the
            // new current line (no-op when the typewriter is off).
            [self ytmu_typeRow:(NSInteger)i activate:YES];
        }

        if (newIndex >= 0 && newIndex < self.lyrics.count) {
            if (!self.tableView.isDragging && !self.tableView.isDecelerating && !self.tableView.isTracking) {
                // Near: smooth-scroll with the song. Far (tap-jump / seek):
                // jump instantly instead of stacking competing animated
                // scrolls, which reads as jank on old phones. Same rule for
                // the tap-to-seek path (ytmu_scrollToRow:instant: owns both).
                BOOL far = (oldIndex >= 0 && labs(newIndex - oldIndex) > 3);
                [self ytmu_scrollToRow:newIndex instant:far];
            }
        }
        // Distance ladder, over every visible row rather than a band around the
        // sung line: a seek moves the active line by twenty rows at once, and a
        // band would leave the rows in between holding whatever brightness the
        // last pass through the band gave them.
        for (UITableViewCell *visible in self.tableView.visibleCells) {
            if (![visible isKindOfClass:[YTMULyricsCell class]]) continue;
            NSIndexPath *ip = [self.tableView indexPathForCell:visible];
            if (!ip) continue;
            NSInteger distance = labs((NSInteger)ip.row - newIndex);
            NSInteger step = MIN(distance, YTMUDistanceLadderSteps);
            [(YTMULyricsCell *)visible ytmu_setDistanceAlpha:YTMUDistanceLadder[step]];
        }
    } else if (newActive.count > 0) {
        // Same set: keep every active word-synced wipe advancing.
        for (NSUInteger i = [newActive firstIndex]; i != NSNotFound; i = [newActive indexGreaterThanIndex:i]) {
            YTMULyricsCell *cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:(NSInteger)i inSection:0]];
            if (cell) {
                NSDictionary *lyric = self.lyrics[i];
                if ([lyric[@"wordSynced"] boolValue] && [(NSArray *)lyric[@"parts"] count] > 0) {
                    [self applyWordColorsToCell:cell lyric:lyric index:(NSInteger)i currentTime:currentTime force:NO];
                }
            }
        }
    }
    // Typewriter: advances every row still revealing. Runs last so a line that
    // became current in THIS tick starts moving in the same frame instead of
    // sitting invisible for one (configureCell above dropped its mask).
    [self ytmu_typeStep];
}

- (void)forceReloadLyrics {
    if (!g_currentVideoID) return;

    if (g_lyricsCache) {
        [g_lyricsCache removeObjectForKey:g_currentVideoID];
    }
    self.lyrics = @[];
    [self.tableView reloadData];
    // Reload invalidates anything the switcher knew: candidates, index,
    // and per-song metadata all refill from the fresh fetch.
    self.providerCandidates = nil;
    self.providerIndex = -1;
    [self.providerCache removeObjectForKey:g_currentVideoID];
    self.providerMetaVideoID = nil;
    self.providerDataVideoID = nil;
    YTMUProviderLyricsDrop(g_currentVideoID);
    [self ytmu_refreshProviderSwitcher];
    self.lastProvider = nil;
    self.lastSongTitle = nil;
    self.lastSongArtist = nil;
    self.songMetaVideoID = nil;
    [self ytmu_requestSongMetaForVideo:g_currentVideoID];
    [self ytmu_loadProviderMetaForVideo:g_currentVideoID];
    self.clockRawTime = 0;
    self.clockRawWall = 0;
    self.activeIndexes = nil;
    YTMUResetScrollTracking();

    UILabel *statusLabel = [self.tableView.tableHeaderView viewWithTag:8888];
    statusLabel.text = @"Force Reloading...";

    g_globalLoadingInFlight = YES;
    g_globalLoadingVideoID = g_currentVideoID;
    g_loadingSince = [NSDate date];
    self.isLoading = YES;
    self.loadingVideoID = g_currentVideoID;
    self.loadingSince = [NSDate date];
    // The cover is re-asked for (the request guard keys on the song, and a
    // force reload must not skip the re-sample that re-keys the ink), and the
    // display intent follows the song being reloaded.
    self.artworkVideoID = g_currentVideoID;
    objc_setAssociatedObject(self, &s_ytmuArtRequestKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [self ytmu_requestArtworkOnce:g_currentVideoID];

    // Force still forces; it just no longer waits on Turnstile. force=1 makes
    // the server re-race every provider, and the server pool supplies the JWT.
    // The id is snapshotted here (the old timeout branch re-read the global up
    // to 10s later) and fetchFullLyricsForVideo: validates it against
    // loadingVideoID, which was just set to the same value above.
    [self ytmu_startFullFetchForVideoID:g_currentVideoID force:YES from:@"force"];
}

- (void)updateLyrics:(NSArray *)newLyrics {
    NSUInteger previousLineCount = self.lyrics.count;
    self.lyrics = newLyrics;

    // One type size per song from the longest line, so rows never resize
    // mid-song. Deliberately narrow: the old 20..28pt span made every song
    // change jump the type by up to 8pt. The knee now sits at 28 chars and
    // the floor is 24pt, so the worst-case swing is 4pt and only very long
    // lines shrink at all. Set before reloadData.
    NSUInteger maxLen = 0;
    for (NSDictionary *l in newLyrics) {
        if (![l isKindOfClass:[NSDictionary class]]) continue;
        NSString *t = [self normalizedLyricText:l[@"text"]];
        if (t.length > maxLen) maxLen = t.length;
        // The translation wraps too, but at ~0.68x the size, so compare it on
        // the scale it will actually be drawn at. Measuring the raw character
        // count let a long translation overflow a full-width main line and
        // wrap under an already-shrunken one.
        NSString *tr = l[@"translated"];
        if ([tr isKindOfClass:[NSString class]] && tr.length) {
            NSUInteger effective = (NSUInteger)ceil((double)tr.length * YTMULyricTransFontSize() / 28.0);
            if (effective > maxLen) maxLen = effective;
        }
    }
    CGFloat size = 28.0;
    if (maxLen > 28) {
        CGFloat over = (CGFloat)MIN(maxLen, (NSUInteger)56) - 28.0;
        size = 28.0 - 4.0 * (over / 28.0);
    }
    size = MAX(24.0, MIN(28.0, floor(size * 2.0) / 2.0));
    s_lyricFontSize = size;

    BOOL hasTimestamp = NO;
    for (NSDictionary *l in newLyrics) {
        if ([l[@"time"] doubleValue] > 0.0 || [l[@"startTimeMs"] doubleValue] > 0.0) {
            hasTimestamp = YES;
            break;
        }
    }
    self.isSynced = hasTimestamp;
    if (!self.isSynced) {
        self.currentIndex = -1;
    }
    self.activeIndexes = nil;
    self.lastColorKey = nil;
    // Every row back to full brightness. The distance ladder is only re-applied
    // on an activation CHANGE, so without this a song that follows a synced one
    // inherits the previous song's faded rows and shows nothing at all.
    for (UITableViewCell *visible in self.tableView.visibleCells) {
        if ([visible isKindOfClass:[YTMULyricsCell class]]) {
            [(YTMULyricsCell *)visible ytmu_setDistanceAlpha:1.0];
        }
    }
    self.cachedWordLayoutKey = nil;
    self.cachedWordRects = nil;

    // The cover belongs to the song the art path is aimed at (the display
    // intent, not loadingVideoID -- see ytmu_artworkTargetVideoID). Keyed on the
    // request guard as well, so a "Waiting..." fetch path (which returns before
    // the load) still gets its cover from here exactly once.
    NSString *artVid = [self ytmu_artworkTargetVideoID];
    if (artVid.length) {
        NSString *asked = objc_getAssociatedObject(self, &s_ytmuArtRequestKey);
        if (!(asked.length && [asked isEqualToString:artVid])) {
            if (!self.loadingVideoID) self.loadingVideoID = artVid;
            [self ytmu_requestArtworkOnce:artVid];
        }
    }

    // Song change (portrait sheet and landscape share this table): dissolve
    // instead of a hard reload so row-height changes don't jump.
    NSString *vid = self.loadingVideoID ?: g_currentVideoID;
    BOOL songChanged = vid.length && ![vid isEqualToString:self.displayedVideoID];
    self.displayedVideoID = [vid copy];
    // Reveal bookkeeping is per row index, so it only survives a payload that
    // keeps the same song AND the same line count -- a streamed `raw` payload
    // followed by `final` must not restart lines that are already typing.
    if (songChanged || newLyrics.count != previousLineCount) {
        [self ytmu_typeResetAll];
    }
    if (songChanged && newLyrics.count > 0) {
        [UIView transitionWithView:self.tableView duration:0.28
                           options:UIViewAnimationOptionTransitionCrossDissolve
                        animations:^{ [self.tableView reloadData]; }
                        completion:nil];
    } else {
        [self.tableView reloadData];
    }

    // A closed instance must not come back. Everything above still runs (the
    // rows are kept warm for the next open), but the un-hide below is the one
    // line that puts a view the user just dismissed back on screen.
    if (YTMUIsClosedByRotation(self)) {
        sendDebugLog(@"[MUSIC] lyrics payload landed on a closed view, staying hidden");
        return;
    }
    if (newLyrics.count > 0 && (self.isModal || YTMULyricsPreference(@"lyricsAlwaysOn", YES))) {
        self.view.hidden = NO;
        [self ytmu_assertOnTop];
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.lyrics.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewAutomaticDimension;
}

- (NSString *)normalizedLyricText:(NSString *)raw {
    if (!raw || raw.length == 0) return @"";
    NSArray *tokens = [raw componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSMutableArray *nonEmpty = [NSMutableArray array];
    for (NSString *t in tokens) {
        if (t.length > 0) [nonEmpty addObject:t];
    }
    NSString *joined = [nonEmpty componentsJoinedByString:@" "];
    NSMutableString *out = [NSMutableString stringWithCapacity:joined.length];
    for (NSUInteger i = 0; i < joined.length; i++) {
        unichar c = [joined characterAtIndex:i];
        if (c == ' ' && i > 0 && i + 1 < joined.length) {
            unichar prev = [joined characterAtIndex:i - 1];
            unichar next = [joined characterAtIndex:i + 1];
            if (YTMUIsCJKChar(prev) && YTMUIsCJKChar(next)) continue;
        }
        [out appendFormat:@"%C", c];
    }
    return out;
}

- (NSString *)wbwDisplayTextForLyric:(NSDictionary *)lyric ranges:(NSArray **)outRanges {
    NSArray *parts = lyric[@"parts"];
    NSCharacterSet *wsTrim = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSMutableString *concat = [NSMutableString string];
    for (NSDictionary *p in parts) {
        NSString *rawW = (NSString *)(p[@"words"] ?: @"");
        NSString *w = [rawW stringByTrimmingCharactersInSet:wsTrim];
        if (w.length == 0) continue;
        // `space: false` marks a part the source glued to the previous one (a
        // word Apple split down the middle, "foll" + "ow"). Joining those with a
        // space is what printed "foll ow" on the device even after the server
        // text was fixed, because the display text is rebuilt from parts and the
        // server text is not what is drawn.
        id sp = p[@"space"];
        BOOL glued = (sp != nil && sp != NSNull.null && ![sp boolValue]);
        if (concat.length > 0 && !glued) {
            unichar prev = [concat characterAtIndex:concat.length - 1];
            unichar next = [w characterAtIndex:0];
            NSString *sep = (YTMUIsCJKChar(prev) && YTMUIsCJKChar(next)) ? @"" : @" ";
            [concat appendString:sep];
        }
        [concat appendString:w];
    }
    NSString *display = [self normalizedLyricText:([concat length] ? concat : lyric[@"text"])];
    if (outRanges) {
        NSMutableArray *ranges = [NSMutableArray array];
        NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
        NSUInteger cursor = 0;
        for (NSDictionary *p in parts) {
            NSString *w = [((NSString *)(p[@"words"] ?: @"")) stringByTrimmingCharactersInSet:ws];
            if (w.length == 0) continue;
            if (cursor > display.length) cursor = display.length;
            NSRange found = [display rangeOfString:w options:0 range:NSMakeRange(cursor, display.length - cursor)];
            if (found.location == NSNotFound) {
                [ranges addObject:[NSValue valueWithRange:NSMakeRange(NSNotFound, 0)]];
                continue;
            }
            [ranges addObject:[NSValue valueWithRange:found]];
            cursor = NSMaxRange(found);
            while (cursor < display.length && [ws characterIsMember:[display characterAtIndex:cursor]]) cursor++;
        }
        *outRanges = ranges;
    }
    return display;
}

- (UIBezierPath *)maskPathForWordRange:(NSRange)r inLayoutManager:(NSLayoutManager *)lm textContainer:(NSTextContainer *)tc fraction:(double)frac {
    NSRange glyphs = [lm glyphRangeForCharacterRange:r actualCharacterRange:NULL];
    CGRect b = [lm boundingRectForGlyphRange:glyphs inTextContainer:tc];
    if (frac < 1.0) b.size.width *= MAX(frac, 0.0);
    return [UIBezierPath bezierPathWithRect:CGRectInset(b, -1, -2)];
}

- (void)applyWordColorsToCell:(YTMULyricsCell *)cell lyric:(NSDictionary *)lyric index:(NSInteger)index currentTime:(double)currentTime force:(BOOL)force {
    NSArray *parts = lyric[@"parts"];
    if ([parts count] == 0) return;
    CGFloat width = cell.wipeLabel.bounds.size.width;
    if (width <= 0) return;
    double nowMs = currentTime * 1000.0;
    NSInteger partCount = [parts count];
    NSInteger curWord = partCount;
    double curFrac = 1.0;
    double priorDurSum = 0;
    NSInteger priorDurCount = 0;
    for (NSInteger i = 0; i < partCount; i++) {
        NSDictionary *p = parts[i];
        double rawDur = MAX([p[@"durationMs"] doubleValue], 1.0);
        double s = [p[@"startTimeMs"] doubleValue];
        double d = MAX(rawDur, 120.0);
        if (i == partCount - 1 && d > 1400.0) {
            double avg = (priorDurCount > 0) ? (priorDurSum / (double)priorDurCount) : 400.0;
            d = MIN(d, MAX(avg * 1.5, 500.0));
            d = MIN(d, 1400.0);
        } else {
            priorDurSum += d;
            priorDurCount++;
        }
        if (nowMs < s) { curWord = i; curFrac = 0.0; break; }
        if (nowMs < s + d) { curWord = i; curFrac = (nowMs - s) / d; break; }
    }
    NSInteger fracQ = (NSInteger)(curFrac * 24.0);
    NSString *key = [NSString stringWithFormat:@"%ld:%ld:%ld:%.0f", (long)index, (long)curWord, (long)fracQ, (double)width];

    // braccato's word wobble, as a whole-line sway on the pair of label copies
    // (they share a frame, so they move as one and the mask rides along).
    // translateX(0.05em) peaking a twelfth of the way into the word, easing back
    // to rest by three quarters of it. The scaleX half of braccato's keyframe is
    // deliberately absent: our labels are full-width, so a scaleX about their
    // centre would slide the glyphs rather than squash the word.
    //
    // Deliberately BEFORE the quantization early-out below: a transform that is
    // only written when the mask is rewritten can be stranded mid-sway on the
    // ticks where the mask is not, since a word's fraction stops changing once it
    // is fully sung.
    CGFloat shift = 0.0;
    if (curWord >= 0 && curWord < partCount && !UIAccessibilityIsReduceMotionEnabled()) {
        NSDictionary *cur = parts[curWord];
        double wordStart = [cur[@"startTimeMs"] doubleValue];
        double wordDur = MAX([cur[@"durationMs"] doubleValue], 1.0);
        double span = MIN(wordDur, YTMUWobbleDuration * 1000.0);
        if (span > 0.0) {
            double t = (nowMs - wordStart) / span;
            CGFloat em = (cell.wipeLabel.font ? cell.wipeLabel.font.pointSize : 22.0) * YTMUWobblePeakEm;
            if (t >= 0.0 && t < YTMUWobblePeakOffset) {
                double s = t / YTMUWobblePeakOffset;
                shift = (CGFloat)(em * (s * s * (3.0 - 2.0 * s)));
            } else if (t < YTMUWobbleSettleOffset) {
                double u = (t - YTMUWobblePeakOffset) / (YTMUWobbleSettleOffset - YTMUWobblePeakOffset);
                shift = (CGFloat)(em * (1.0 - (u * u * (3.0 - 2.0 * u))));
            }
        }
    }
    if (fabs(shift) > 0.01) {
        cell.lyricLabel.transform = CGAffineTransformMakeTranslation(shift, 0.0);
        cell.wipeLabel.transform = CGAffineTransformMakeTranslation(shift, 0.0);
    } else if (!CGAffineTransformIsIdentity(cell.lyricLabel.transform)) {
        // Compared rather than assigned: writing an identity transform to a
        // label that already has one marks its layer for a layout pass.
        cell.lyricLabel.transform = CGAffineTransformIdentity;
        cell.wipeLabel.transform = CGAffineTransformIdentity;
    }

    if (!force && [key isEqualToString:cell.lastColorKey]) return;

    UIFont *font = cell.wipeLabel.font;
    if (!font) font = [UIFont boldSystemFontOfSize:YTMULyricMainFontSize()];
    NSArray *ranges = nil;
    NSString *display = [self wbwDisplayTextForLyric:lyric ranges:&ranges];
    NSString *layoutKey = [NSString stringWithFormat:@"%ld|%.1f|%@", (long)index, (double)width, display];
    if (![layoutKey isEqualToString:cell.cachedWordLayoutKey]) {
        cell.lyricLabel.attributedText = nil;
        cell.lyricLabel.text = display;
        cell.lyricLabel.textColor = YTMULyricInk(0.40, 0.48, self.view);

        NSShadow *sh = [[NSShadow alloc] init];
        sh.shadowColor = YTMULyricShadow(self.view);
        sh.shadowOffset = CGSizeMake(0, 2);
        sh.shadowBlurRadius = 4;
        cell.wipeLabel.attributedText = [[NSAttributedString alloc] initWithString:display
            attributes:@{NSFontAttributeName: font,
                         NSForegroundColorAttributeName: YTMULyricInk(1.0, 1.0, self.view),
                         NSShadowAttributeName: sh,
                         NSKernAttributeName: @0.08}];

        NSTextStorage *ts = [[NSTextStorage alloc] initWithString:display attributes:@{NSFontAttributeName: font}];
        NSLayoutManager *lm = [[NSLayoutManager alloc] init];
        NSTextContainer *tc = [[NSTextContainer alloc] initWithSize:CGSizeMake(width, CGFLOAT_MAX)];
        tc.lineFragmentPadding = 0;
        tc.maximumNumberOfLines = 0;
        tc.lineBreakMode = NSLineBreakByWordWrapping;
        [lm addTextContainer:tc];
        [ts addLayoutManager:lm];
        [lm ensureLayoutForTextContainer:tc];

        NSMutableArray *rects = [NSMutableArray arrayWithCapacity:[ranges count]];
        for (NSValue *v in ranges) {
            NSRange r = [v rangeValue];
            if (r.location == NSNotFound || r.length == 0) {
                [rects addObject:[NSValue valueWithCGRect:CGRectNull]];
                continue;
            }
            NSRange glyphs = [lm glyphRangeForCharacterRange:r actualCharacterRange:NULL];
            CGRect b = [lm boundingRectForGlyphRange:glyphs inTextContainer:tc];
            [rects addObject:[NSValue valueWithCGRect:CGRectInset(b, -1, -2)]];
        }
        cell.cachedWordRects = rects;
        cell.cachedWordLayoutKey = layoutKey;
    }
    cell.lastColorKey = key;

    UIBezierPath *path = [UIBezierPath bezierPath];
    NSInteger rcount = MIN(partCount, (NSInteger)[cell.cachedWordRects count]);
    for (NSInteger i = 0; i < curWord && i < rcount; i++) {
        CGRect b = [cell.cachedWordRects[i] CGRectValue];
        if (CGRectIsNull(b)) continue;
        [path appendPath:[UIBezierPath bezierPathWithRect:b]];
    }

    CAGradientLayer *wipeFeather = nil;
    for (CALayer *layer in cell.wipeMask.sublayers) {
        if ([layer.name isEqualToString:@"YTMULyricsWipeFeather"] &&
            [layer isKindOfClass:CAGradientLayer.class]) {
            wipeFeather = (CAGradientLayer *)layer;
            break;
        }
    }
    wipeFeather.hidden = YES;

    CGRect curWordRect = CGRectNull;
    if (curWord >= 0 && curWord < rcount) {
        CGRect wordRect = [cell.cachedWordRects[curWord] CGRectValue];
        if (!CGRectIsNull(wordRect)) {
            curWordRect = wordRect;
            CGFloat fraction = MIN(1.0, MAX(0.0, curFrac));
            BOOL rtl = cell.wipeLabel.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
            // braccato's overshoot: the leading edge runs past the word and is
            // pulled back over the last fifth of it, so the highlight visibly
            // catches up instead of stopping dead at the last glyph.
            CGFloat overshoot = 0.0;
            if (fraction >= 1.0 - YTMUSwipeOvershootTail && fraction <= 1.0) {
                CGFloat t = (fraction - (1.0 - YTMUSwipeOvershootTail)) / YTMUSwipeOvershootTail;
                overshoot = YTMUSwipeOvershoot * wordRect.size.width * (1.0 - t);
            }
            CGFloat revealedWidth = wordRect.size.width * fraction + overshoot;
            // The SOLID run is still capped at the word: only the feather is
            // allowed past the end, so the glow in the gap after the word never
            // doubles as a premature reveal of the next one.
            CGFloat solidWidth = MIN(wordRect.size.width, MAX(0.0, revealedWidth - MIN(22.0, MAX(8.0, wordRect.size.width * 0.38))));

            if (solidWidth > 0.0) {
                CGRect solid = wordRect;
                solid.size.width = solidWidth;
                if (rtl) solid.origin.x = CGRectGetMaxX(wordRect) - solidWidth;
                [path appendPath:[UIBezierPath bezierPathWithRect:solid]];
            }
            if (revealedWidth > 0.0 && wipeFeather) {
                CGFloat featherWidth = MIN(22.0, MAX(8.0, wordRect.size.width * 0.38));
                CGFloat visibleFeather = MIN(featherWidth, revealedWidth);
                CGRect feather = wordRect;
                feather.size.width = visibleFeather;
                if (rtl) {
                    feather.origin.x = CGRectGetMaxX(wordRect) - revealedWidth;
                    wipeFeather.startPoint = CGPointMake(1.0, 0.5);
                    wipeFeather.endPoint = CGPointMake(0.0, 0.5);
                } else {
                    feather.origin.x += revealedWidth - visibleFeather;
                    wipeFeather.startPoint = CGPointMake(0.0, 0.5);
                    wipeFeather.endPoint = CGPointMake(1.0, 0.5);
                }
                wipeFeather.frame = CGRectIntegral(feather);
                wipeFeather.hidden = NO;
            }
        }
    } else if (curWord >= rcount && display.length > 0) {
        [path appendPath:[UIBezierPath bezierPathWithRect:cell.wipeLabel.bounds]];
    }

    // braccato's highlight glow: a shadow that starts fat around the word being
    // sung and shrinks away over 1.2x that word's own time, never under 1.2s.
    // A mask clips the shadow it is applied to, so the mask has to be widened to
    // let the blur out -- and widened CAREFULLY, because an unclamped widening
    // is also a widening of the reveal and would light the next word early.
    CGFloat glow = 0.0;
    if (curWord >= 0 && curWord < partCount && !CGRectIsNull(curWordRect)) {
        NSDictionary *cur = parts[curWord];
        double wordStart = [cur[@"startTimeMs"] doubleValue];
        double wordDur = MAX([cur[@"durationMs"] doubleValue], 120.0);
        if (curWord == partCount - 1 && wordDur > 1400.0) {
            double avg = (priorDurCount > 0) ? (priorDurSum / (double)priorDurCount) : 400.0;
            wordDur = MIN(wordDur, MAX(avg * 1.5, 500.0));
        }
        double glowMs = MAX(wordDur * YTMUHighlightGlowRatio, YTMUHighlightGlowMinDuration * 1000.0);
        double glowT = MIN(MAX((nowMs - wordStart) / glowMs, 0.0), 1.0);
        glow = YTMUHighlightGlowRadius * (1.0 - glowT) * (1.0 - glowT);
        if (glow > 0.5) {
            // Never past the midpoint of the gap on either side, so the next
            // word (and the one before, which is already lit) stay untouched.
            CGFloat growL = glow, growR = glow;
            if (curWord + 1 < rcount) {
                CGRect nextRect = [cell.cachedWordRects[curWord + 1] CGRectValue];
                if (!CGRectIsNull(nextRect)) growL = MIN(growL, MAX(0.0, (curWordRect.minX - nextRect.maxX) * 0.5));
            }
            if (curWord > 0 && curWord - 1 < rcount) {
                CGRect prevRect = [cell.cachedWordRects[curWord - 1] CGRectValue];
                if (!CGRectIsNull(prevRect)) growR = MIN(growR, MAX(0.0, (prevRect.minX - curWordRect.maxX) * 0.5));
            }
            // And never more than half the word's own height vertically, which
            // is what keeps a wrapped line's next fragment out of it.
            CGFloat growV = MIN(glow, curWordRect.size.height * 0.5);
            CGRect glowRect = CGRectMake(curWordRect.minX - growL, curWordRect.minY - growV,
                                         curWordRect.size.width + growL + growR,
                                         curWordRect.size.height + growV * 2.0);
            [path appendPath:[UIBezierPath bezierPathWithRect:glowRect]];
        }
    }
    // Radius 0 with a non-nil shadow colour still draws a hard silhouette, so the
    // opacity has to fall with it or every word leaves a doubled glyph.
    cell.wipeLabel.layer.shadowRadius = glow;
    cell.wipeLabel.layer.shadowOpacity = 0.75 * MIN(1.0, glow / 2.0);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    cell.wipeMask.frame = cell.wipeLabel.bounds;
    cell.wipeMask.path = path.CGPath;
    [CATransaction commit];
}

- (CGFloat)wipeProgressForLyricAtIndex:(NSInteger)index currentTime:(double)currentTime {
    if (index < 0 || index >= self.lyrics.count) return 0.0;
    NSDictionary *lyric = self.lyrics[index];
    double nowMs = currentTime * 1000.0;
    NSArray *parts = lyric[@"parts"];
    if ([lyric[@"wordSynced"] boolValue] && [parts count] > 0) {
        NSInteger n = [parts count];
        double priorDurSum = 0;
        NSInteger priorDurCount = 0;
        for (NSInteger i = 0; i < n; i++) {
            NSDictionary *p = parts[i];
            double s = [p[@"startTimeMs"] doubleValue];
            double rawDur = MAX([p[@"durationMs"] doubleValue], 1.0);
            double d = MAX(rawDur, 120.0);
            if (i == n - 1 && d > 1400.0) {
                double avg = (priorDurCount > 0) ? (priorDurSum / (double)priorDurCount) : 400.0;
                d = MIN(d, MAX(avg * 1.5, 500.0));
                d = MIN(d, 1400.0);
            } else {
                priorDurSum += d;
                priorDurCount++;
            }
            if (nowMs < s) return (CGFloat)i / (CGFloat)n;
            if (nowMs < s + d) {
                double frac = (nowMs - s) / d;
                return (CGFloat)((double)i + frac) / (CGFloat)n;
            }
        }
        return 1.0;
    }
    double startMs = [lyric[@"startTimeMs"] doubleValue];
    if (startMs <= 0) startMs = [lyric[@"time"] doubleValue] * 1000.0;
    double endMs = 0;
    if (index + 1 < self.lyrics.count) {
        NSDictionary *next = self.lyrics[index + 1];
        endMs = [next[@"startTimeMs"] doubleValue];
        if (endMs <= 0) endMs = [next[@"time"] doubleValue] * 1000.0;
    }
    if (endMs <= startMs) {
        double durMs = [lyric[@"durationMs"] doubleValue];
        if (durMs <= 0) durMs = [lyric[@"duration"] doubleValue] * 1000.0;
        endMs = startMs + (durMs > 0 ? durMs : 4000.0);
    }
    if (endMs <= startMs) return 1.0;
    return (CGFloat)MIN(MAX((nowMs - startMs) / (endMs - startMs), 0.0), 1.0);
}

- (BOOL)ytmuIsInstrumentalLyric:(NSDictionary *)lyric {
    if ([lyric[@"isInstrumental"] boolValue]) return YES;
    id raw = lyric[@"text"];
    if (![raw isKindOfClass:[NSString class]]) return NO;
    NSString *t = [(NSString *)raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [t isEqualToString:@"[instrumental]"] || [t isEqualToString:@"[MUSIC] Instrumental"];
}

// Which side of the row a line belongs on, from the per-line `singer` index
// (0-based, into the ttm:agent person list in declaration order) and `duet` for
// a group agent. Both are already on the wire -- server/parsers_ttml.py emits
// them from ttm:agent (commit 72225e9) -- so a duet moves its lines onto their
// own side. That was the user's call, made in place of the three label designs
// that were offered -- and then they asked for the label back as a setting, so
// both ship. See the block comment above for why the label half is gone.
//
// GATED ON THE PREF here, and this is the single point that keeps the two modes
// exclusive: in label mode (or off) it returns Natural, so a row is never both
// right-aligned AND carrying a "Singer 2" marker.
static NSTextAlignment YTMUVoiceAlignment(NSDictionary *lyric) {
    if (YTMUDuetDisplayMode() != kYTMUDuetAlign) return NSTextAlignmentNatural;
    if (![lyric isKindOfClass:[NSDictionary class]]) return NSTextAlignmentNatural;
    if ([lyric[@"duet"] boolValue]) return NSTextAlignmentCenter;
    id s = lyric[@"singer"];
    if (![s isKindOfClass:[NSNumber class]]) return NSTextAlignmentNatural;
    // Anything past the lead voice goes right. A solo track has no `singer` key
    // at all (an agent that is declared but never referenced gets no key on
    // purpose), so it is untouched.
    return [s integerValue] >= 1 ? NSTextAlignmentRight : NSTextAlignmentNatural;
}

// Does this payload distinguish voices AT ALL? A solo track declares exactly one
// person agent, so every line is singer 0, and printing "Singer 1" above all 50
// of them would be noise rather than information. Cached per array identity
// because -configureCell runs on every activation change and every scroll.
//
// The static holds the last payload's array for the life of the process. That is
// one lyrics array, and it is what the open sheet is holding anyway.
- (BOOL)ytmu_payloadHasMultipleVoices {
    static NSArray *cachedRows = nil;
    static NSUInteger cachedCount = NSNotFound;
    static BOOL cachedAnswer = NO;
    NSArray *rows = self.lyrics;
    if (rows != cachedRows || rows.count != cachedCount) {
        cachedRows = rows;
        cachedCount = rows.count;
        NSInteger topVoice = -1;
        BOOL anyDuet = NO;
        for (id row in rows) {
            NSString *key = YTMUSingerVoiceKey(row);
            if (!key) continue;
            if ([key isEqualToString:@"both"]) { anyDuet = YES; break; }
            // Keys are 1-based ("p1" -> 1), so anything above zero is a second
            // voice.
            topVoice = MAX(topVoice, [key integerValue]);
        }
        cachedAnswer = anyDuet || topVoice >= 1;
    }
    return cachedAnswer;
}

// The marker for this row, or nil when the row does not start a new vocal run.
// Printed on a voice CHANGE, not on every line: Die With A Smile changes voice 18
// times across 50 lines, and a label on all 50 would bury the lyrics.
- (NSString *)ytmu_singerMarkerForRow:(NSInteger)index {
    if (YTMUDuetDisplayMode() != kYTMUDuetLabel) return nil;
    if (![self ytmu_payloadHasMultipleVoices]) return nil;
    if (index < 0 || index >= (NSInteger)self.lyrics.count) return nil;
    NSString *mine = YTMUSingerVoiceKey(self.lyrics[index]);
    if (!mine) return nil;
    // Walk back over rows the file was silent about -- a synthetic instrumental
    // gap carries no voice -- so a gap in the middle of a run does not print a
    // duplicate marker for the voice that was already announced. Bounded:
    // gaps are short, and an unbounded walk would be O(n) per configure.
    NSInteger floorIndex = MAX((NSInteger)0, index - 16);
    for (NSInteger i = index - 1; i >= floorIndex; i--) {
        NSString *prev = YTMUSingerVoiceKey(self.lyrics[i]);
        if (!prev) continue;
        if ([prev isEqualToString:mine]) return nil;
        break;
    }
    return YTMUSingerMarkerText(self.lyrics[index]);
}

- (void)configureCell:(YTMULyricsCell *)cell atIndex:(NSInteger)index isActive:(BOOL)isActive currentTime:(double)currentTime {
    if (index < 0 || index >= self.lyrics.count) return;

    NSDictionary *lyric = self.lyrics[index];
    if ([self ytmuIsInstrumentalLyric:lyric]) {
        // Instrumental gap: a wave ribbon, shown ONLY while playback is inside
        // this row's own window (the same isActive the lyric rows use). It
        // oscillates between two shapes and flattens across the gap, which is
        // braccato's instrumental style; the old static music-note glyph is
        // gone. An untimed payload has no window at all, so the wave stays up
        // for the whole song there -- it is the only content of its row.
        // An inactive marker COLLAPSES to zero height (ytmu_setRowCollapsed:)
        // so it cannot steal a line from the lyrics; it still counts for
        // timing/active-set purposes and tapping it still seeks.
        BOOL showNote = isActive || !self.isSynced;
        if ([cell ytmu_setRowCollapsed:!showNote]) [self.tableView setNeedsLayout];
        cell.lyricLabel.attributedText = nil;
        cell.lyricLabel.text = @"";
        cell.lyricLabel.font = [UIFont boldSystemFontOfSize:28];
        cell.ytmu_textAlign = YTMUVoiceAlignment(lyric);
        cell.lyricLabel.textAlignment = cell.ytmu_textAlign;
        cell.wipeLabel.textAlignment = cell.ytmu_textAlign;
        cell.transLabel.textAlignment = cell.ytmu_textAlign;
        cell.lyricLabel.alpha = 1.0;
        cell.lyricLabel.transform = CGAffineTransformIdentity;
        cell.lyricLabel.textColor = YTMULyricInk(1.0, 1.0, self.view);
        cell.lyricLabel.layer.shadowColor = YTMULyricShadow(self.view).CGColor;
        cell.lyricLabel.layer.shadowOffset = CGSizeMake(0, 2);
        cell.lyricLabel.layer.shadowRadius = 4.0;
        cell.lyricLabel.layer.shadowOpacity = showNote ? 0.75 : 0.32;
        cell.lyricLabel.layer.masksToBounds = NO;
        [cell clearWipe];
        cell.transLabel.text = @"";
        cell.transLabel.hidden = YES;
        // An instrumental gap is not sung by anyone, so it never carries a voice
        // marker -- and this row may be a recycled cell still holding the
        // previous row's marker.
        [cell ytmu_setSingerMarker:nil];
        cell.waveActive = showNote;
        if (showNote) {
            // Flatten across the gap: 0 the instant it opens, 1 as it closes.
            double startMs = [self ytmu_startMsForLyric:lyric];
            double endMs = [self ytmu_endMsForLyricAtIndex:index];
            CGFloat progress = 0.0;
            if (endMs > startMs) {
                progress = (CGFloat)((currentTime * 1000.0 - startMs) / (endMs - startMs));
            }
            cell.waveProgress = MIN(MAX(progress, 0.0), 1.0);
            cell.waveLayer.fillColor = [YTMULyricInk(1.0, 1.0, self.view) CGColor];
            [cell setNeedsLayout];
        } else {
            cell.waveLayer.hidden = YES;
        }
        return;
    }
    NSString *displayText = [self normalizedLyricText:lyric[@"text"]];
    // A normal line is never collapsed, whatever the cell held before it.
    [cell ytmu_setRowCollapsed:NO];
    // The voice marker, on the rows where the singer actually changes, and only
    // in label mode -- YTMUVoiceAlignment returns Natural there, so exactly one
    // of the two duet styles ever draws. Placed after the collapse call, which
    // forces the marker flat when a row collapses.
    [cell ytmu_setSingerMarker:[self ytmu_singerMarkerForRow:index]];
    cell.lyricLabel.font = [UIFont boldSystemFontOfSize:YTMULyricMainFontSize()];
    cell.wipeLabel.font = [UIFont boldSystemFontOfSize:YTMULyricMainFontSize()];
    cell.transLabel.font = [UIFont systemFontOfSize:YTMULyricTransFontSize() weight:UIFontWeightMedium];
    cell.ytmu_textAlign = YTMUVoiceAlignment(lyric);
    cell.lyricLabel.textAlignment = cell.ytmu_textAlign;
    cell.wipeLabel.textAlignment = cell.ytmu_textAlign;
    cell.transLabel.textAlignment = cell.ytmu_textAlign;
    BOOL hasWords = [lyric[@"wordSynced"] boolValue] && [(NSArray *)lyric[@"parts"] count] > 0;
    if (hasWords) displayText = [self wbwDisplayTextForLyric:lyric ranges:NULL];
    cell.lyricLabel.alpha = 1.0;
    // A reconfigure is the only place a half-finished pop or sway can be
    // dropped, and both live on the pair of copies.
    if (!CGAffineTransformIsIdentity(cell.lyricLabel.transform)) {
        cell.lyricLabel.transform = CGAffineTransformIdentity;
    }
    if (!CGAffineTransformIsIdentity(cell.wipeLabel.transform)) {
        cell.wipeLabel.transform = CGAffineTransformIdentity;
    }

    if (!self.isSynced) {
        cell.lyricLabel.attributedText = nil;
        cell.lyricLabel.text = displayText;
        cell.lyricLabel.textColor = YTMULyricInk(1.0, 1.0, self.view);
        cell.lyricLabel.layer.shadowColor = YTMULyricShadow(self.view).CGColor;
        cell.lyricLabel.layer.shadowOffset = CGSizeMake(0, 2);
        cell.lyricLabel.layer.shadowRadius = 4.0;
        cell.lyricLabel.layer.shadowOpacity = 0.7;
        cell.lyricLabel.layer.masksToBounds = NO;
        [cell clearWipe];

        cell.transLabel.textColor = YTMULyricInk(0.75, 0.75, self.view);
    } else if (isActive) {
        if (hasWords) {
            [self applyWordColorsToCell:cell lyric:lyric index:index currentTime:currentTime force:YES];
        } else {
            // The ACTIVE colour lives on the reveal layer on both kinds of row
            // now, so a line arriving is a cross-fade between two copies instead
            // of an instant textColor swap. This branch used to be the reason a
            // line-synced song snapped rather than faded.
            cell.lyricLabel.attributedText = nil;
            cell.lyricLabel.text = displayText;
            cell.lyricLabel.textColor = YTMULyricInk(0.45, 0.45, self.view);
            cell.wipeLabel.attributedText = nil;
            cell.wipeLabel.text = displayText;
            cell.wipeLabel.textColor = YTMULyricInk(1.0, 1.0, self.view);
            [cell ytmu_showFullWipe];
            cell.lastColorKey = nil;
        }

        cell.lyricLabel.layer.shadowColor = YTMULyricShadow(self.view).CGColor;
        cell.lyricLabel.layer.shadowOffset = CGSizeMake(0, 2);
        cell.lyricLabel.layer.shadowRadius = 4.0;
        cell.lyricLabel.layer.shadowOpacity = 0.75;
        cell.lyricLabel.layer.masksToBounds = NO;

        cell.transLabel.textColor = YTMULyricInk(0.85, 0.85, self.view);
    } else {
        cell.lyricLabel.attributedText = nil;
        cell.lyricLabel.text = displayText;
        cell.lyricLabel.textColor = YTMULyricInk(0.45, 0.45, self.view);
        cell.lyricLabel.layer.shadowOpacity = 0.32;

        // Leaving the active set FADES the highlight down instead of blanking
        // it, so a line dims rather than snaps. The revealed text is kept for
        // the length of the fade; the next reconfigure, a reload or a recycle
        // drops it through -clearWipe.
        if (cell.wipeLabel.text.length > 0) {
            [cell ytmu_fadeHighlightTo:0.0 duration:YTMUHighlightFadeOutDuration];
        } else {
            [cell clearWipe];
        }

        cell.transLabel.textColor = YTMULyricInk(0.35, 0.35, self.view);
    }

    NSString *translated = lyric[@"translated"];
    NSString *rawText = [lyric[@"text"] isKindOfClass:[NSString class]] ? lyric[@"text"] : @"";
    if (translated && translated.length > 0 && ![translated isEqualToString:rawText]) {
        cell.transLabel.text = translated;
        cell.transLabel.hidden = NO;
    } else {
        cell.transLabel.text = @"";
        cell.transLabel.hidden = YES;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    YTMULyricsCell *cell = [tableView dequeueReusableCellWithIdentifier:@"YTMULyricsCell" forIndexPath:indexPath];

    double currentTime = 0;
    if (g_activePlayer && [g_activePlayer respondsToSelector:@selector(currentVideoMediaTime)]) {
        currentTime = [g_activePlayer currentVideoMediaTime];
    } else {
        currentTime = g_currentPlaybackTime;
    }

    // Apply per-song timing offset
    if (g_currentVideoID.length) {
        double offset = YTMULyricsOffsetForVideoID(g_currentVideoID);
        if (offset != 0.0) {
            currentTime += offset;
        }
    }

    BOOL isActive = NO;
    if (self.isSynced && indexPath.row >= 0 && indexPath.row < self.lyrics.count) {
        if (self.activeIndexes && self.activeIndexes.count > 0) {
            isActive = [self.activeIndexes containsIndex:(NSUInteger)indexPath.row];
        } else {
            isActive = (indexPath.row == self.currentIndex);
        }
    }
    [self configureCell:cell atIndex:indexPath.row isActive:isActive currentTime:currentTime];

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (!self.isSynced) return;

    NSDictionary *lyric = self.lyrics[indexPath.row];
    NSNumber *time = lyric[@"time"];
    double seekBase = time ? [time doubleValue] : -1;
    if (seekBase < 0) seekBase = [lyric[@"startTimeMs"] doubleValue] / 1000.0;

    if (seekBase >= 0) {
        double seekTime = seekBase;
        // Adjust for per-song offset
        if (g_currentVideoID.length) {
            double offset = YTMULyricsOffsetForVideoID(g_currentVideoID);
            if (offset != 0.0) {
                seekTime -= offset;
            }
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:@"YTMUSeekToTime" object:@(seekTime)];

        NSIndexSet *oldActive = self.activeIndexes ?: [NSIndexSet indexSet];
        self.currentIndex = indexPath.row;
        g_currentPlaybackTime = seekTime;
        // Rebase the extrapolated clock too, or the next tick extrapolates
        // from the pre-seek sample and snaps the highlight back.
        self.clockRawTime = seekTime;
        self.clockRawWall = CACurrentMediaTime();

        double nowMs = seekTime * 1000.0;
        if (g_currentVideoID.length) {
            nowMs += YTMULyricsOffsetForVideoID(g_currentVideoID) * 1000.0;
        }
        NSIndexSet *newActive = [self ytmu_activeIndexesAtMs:nowMs];
        if (newActive.count == 0) {
            newActive = [NSIndexSet indexSetWithIndex:(NSUInteger)indexPath.row];
        }
        self.activeIndexes = newActive;
        NSMutableIndexSet *deactivated = [oldActive mutableCopy];
        [deactivated removeIndexes:newActive];
        for (NSUInteger i = [deactivated firstIndex]; i != NSNotFound; i = [deactivated indexGreaterThanIndex:i]) {
            YTMULyricsCell *oldCell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:(NSInteger)i inSection:0]];
            if (oldCell) {
                [self configureCell:oldCell atIndex:(NSInteger)i isActive:NO currentTime:g_currentPlaybackTime];
            }
        }
        for (NSUInteger i = [newActive firstIndex]; i != NSNotFound; i = [newActive indexGreaterThanIndex:i]) {
            YTMULyricsCell *newCell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:(NSInteger)i inSection:0]];
            if (newCell) {
                [self configureCell:newCell atIndex:(NSInteger)i isActive:YES currentTime:g_currentPlaybackTime];
                // Same arrival as the tick's, so a tap-to-seek lights the line it
                // lands on rather than snapping it. Reduced motion skips it.
                if (!UIAccessibilityIsReduceMotionEnabled()) {
                    [newCell ytmu_beginHighlightArrivalWithDuration:YTMUHighlightFadeInDuration];
                } else {
                    [newCell ytmu_fadeHighlightTo:1.0 duration:0.0];
                }
            }
        }
        // Same distance ladder as the tick, for the same reason: a tap can move
        // the sung line twenty rows and a stale brightness would survive.
        for (UITableViewCell *visible in self.tableView.visibleCells) {
            if (![visible isKindOfClass:[YTMULyricsCell class]]) continue;
            NSIndexPath *ip = [self.tableView indexPathForCell:visible];
            if (!ip) continue;
            NSInteger distance = labs((NSInteger)ip.row - (NSInteger)indexPath.row);
            NSInteger step = MIN(distance, YTMUDistanceLadderSteps);
            [(YTMULyricsCell *)visible ytmu_setDistanceAlpha:YTMUDistanceLadder[step]];
        }
        // A tap is always a far jump: settle on the tapped line now, so the
        // next tick does not animate a scroll from the pre-tap position and
        // the pop and the scroll land together.
        [self ytmu_scrollToRow:indexPath.row instant:YES];
    }
}

@end


// Post-tap fallback: present the bottom sheet when the native panel path did
// not put anything on screen. Retries three times at 0.2s, so it is a
// self-rescheduling chain too and needs the same cancellation as the landscape
// chain: the generation it was armed with must still be the current one.
static void __attribute__((unused)) YTMUAttemptFallbackPresent(NSString *resolvedVideoID, int attempt, NSUInteger generation) {
    if (generation != YTMUCurrentOrientationGeneration()) {
        sendDebugLog(@"[MUSIC] fallback present cancelled: a newer orientation decision won");
        return;
    }
    if (isLyricsViewVisibleOnScreen()) {
        sendDebugLog(@"[MUSIC] Native lyrics panel already visible on screen, skipping fallback");
        return;
    }

    UIViewController *top = topMostViewController();
    if (!top) return;

    if ([top isKindOfClass:[YTMULyricsViewController class]] || [top.presentedViewController isKindOfClass:[YTMULyricsViewController class]]) {
        YTMULyricsViewController *existing = [top isKindOfClass:[YTMULyricsViewController class]]
            ? (YTMULyricsViewController *)top
            : (YTMULyricsViewController *)top.presentedViewController;
        NSString *existingVideoID = YTMUResolveCurrentVideoID() ?: resolvedVideoID;
        if (existingVideoID) [existing fetchLyricsForVideo:existingVideoID];
        return;
    }

    if (attempt < 3) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            YTMUAttemptFallbackPresent(resolvedVideoID, attempt + 1, generation);
        });
        return;
    }

    if (top.presentedViewController || top.isBeingPresented || top.isBeingDismissed) {
        sendDebugLog(@"[WARN] fallback suppressed: top view controller is busy presenting");
        return;
    }

    sendDebugLog(@"[MUSIC] Presenting fallback YTMULyricsViewController bottom sheet");
    YTMULyricsViewController *lyricsVC = [[YTMULyricsViewController alloc] init];
    lyricsVC.isModal = YES;
    lyricsVC.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = lyricsVC.sheetPresentationController;
        sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent];
        sheet.prefersGrabberVisible = YES;
    }
    NSString *tapVideoID = YTMUResolveCurrentVideoID() ?: resolvedVideoID;
    if (tapVideoID) {
        [lyricsVC fetchLyricsForVideo:tapVideoID];
    }
    [top presentViewController:lyricsVC animated:YES completion:^{
        if (!tapVideoID) {
            UILabel *statusLabel = [lyricsVC.tableView.tableHeaderView viewWithTag:8888];
            if (statusLabel) statusLabel.text = @"No video playing";
        }
    }];
}

void openLyricsFromViewController(UIViewController *parentVC) {
    sendDebugLog(@"[MUSIC] openLyricsFromViewController called");
    NSString *resolvedVideoID = YTMUResolveCurrentVideoID();
    if (!resolvedVideoID) {
        sendDebugLog(@"[WARN] openLyrics: no video ID could be resolved");
    }

    if (g_activeEngagementPanelContainer) {
        NSArray *panelIDs = @[@"PAmusic_watch_lyrics_panel", @"music_watch_lyrics_panel", @"lyrics"];
        for (NSString *pid in panelIDs) {
            if ([g_activeEngagementPanelContainer respondsToSelector:@selector(showEngagementPanelWithIdentifier:animated:)]) {
                [g_activeEngagementPanelContainer performSelector:@selector(showEngagementPanelWithIdentifier:animated:) withObject:pid withObject:(id)kCFBooleanTrue];
            } else if ([g_activeEngagementPanelContainer respondsToSelector:@selector(showEngagementPanelWithIdentifier:)]) {
                [g_activeEngagementPanelContainer performSelector:@selector(showEngagementPanelWithIdentifier:) withObject:pid];
            } else if ([g_activeEngagementPanelContainer respondsToSelector:@selector(openEngagementPanelWithIdentifier:animated:)]) {
                [g_activeEngagementPanelContainer performSelector:@selector(openEngagementPanelWithIdentifier:animated:) withObject:pid withObject:(id)kCFBooleanTrue];
            } else {
                sendDebugLog(@"[WARN] engagement panel container responds to none of the known show/open selectors");
                break;
            }
        }
    } else {
        sendDebugLog(@"[WARN] openLyrics: no active engagement panel container captured, native panel path skipped entirely");
    }

    YTMUAttemptFallbackPresent(resolvedVideoID, 0, YTMUCurrentOrientationGeneration());
}

void openLyricsFullscreenForLandscape(void) {
    if (isLyricsViewVisibleOnScreen()) {
        sendDebugLog(@"[MUSIC] landscape open: lyrics already visible");
        return;
    }
    if (!YTMUIsInterfaceLandscape()) return;
    // Read at the present site too, not only where the chain is armed: this is
    // the last gate before a view controller exists, and the switch may have
    // been flipped while a chain was mid-flight.
    if (!YTMULandscapeAutoOpenEnabled()) {
        sendDebugLog(@"[MUSIC] landscape open suppressed: lyricsFullscreenAutoOpen is off");
        return;
    }

    UIViewController *top = topMostViewController();
    if (!top) return;
    if ([top isKindOfClass:[YTMULyricsViewController class]]) return;
    if ([top.presentedViewController isKindOfClass:[YTMULyricsViewController class]]) return;
    if (top.presentedViewController || top.isBeingPresented || top.isBeingDismissed) {
        sendDebugLog(@"[WARN] landscape open suppressed: top busy");
        return;
    }

    NSString *vid = YTMUResolveCurrentVideoID();
    if (!vid) {
        sendDebugLog(@"[WARN] landscape open: no video ID");
        return;
    }

    sendDebugLog(@"[MUSIC] landscape auto-presenting fullscreen lyrics");
    YTMULyricsViewController *lyricsVC = [[YTMULyricsViewController alloc] init];
    lyricsVC.isModal = YES;
    lyricsVC.modalPresentationStyle = UIModalPresentationFullScreen;
    lyricsVC.modalPresentationCapturesStatusBarAppearance = YES;
    [lyricsVC fetchLyricsForVideo:vid];
    [top presentViewController:lyricsVC animated:YES completion:nil];
}

// Bounded retry chain: a single deferred attempt misses whenever the
// interface hasn't finished rotating, the top VC is mid-presentation, or
// the video ID isn't resolved yet. Keep trying while the phone stays
// landscape; every attempt re-checks visibility first so we never double
// present.
//
// `generation` is the orientation decision that armed it. A newer decision --
// a rotate back to portrait, a close, the switch going off -- bumps the
// generation, and a stale chain stops instead of spending its remaining ~2.75s
// of retries looking for a chance to present.
static void YTMUAttemptLandscapeOpenChain(int left, NSUInteger generation) {
    if (left <= 0) return;
    if (generation != YTMUCurrentOrientationGeneration()) {
        sendDebugLog(@"[MUSIC] landscape open chain cancelled: superseded by a newer decision");
        return;
    }
    // Re-read per step: the switch can go off while the chain is in flight.
    if (!YTMULandscapeAutoOpenEnabled()) {
        sendDebugLog(@"[MUSIC] landscape open chain cancelled: lyricsFullscreenAutoOpen is off");
        return;
    }
    if (isLyricsViewVisibleOnScreen()) return;
    if (!YTMUIsInterfaceLandscape()) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            YTMUAttemptLandscapeOpenChain(left - 1, generation);
        });
        return;
    }
    NSString *vid = YTMUResolveCurrentVideoID();
    UIViewController *top = topMostViewController();
    if (!vid.length || !top || top.presentedViewController || top.isBeingPresented || top.isBeingDismissed) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            YTMUAttemptLandscapeOpenChain(left - 1, generation);
        });
        return;
    }
    openLyricsFullscreenForLandscape();
}

// The single arming point. The device notification PRECEDES the interface
// rotation, so the interface is only trusted after a deferral longer than a
// rotation animation: a face-up jitter in landscape must not arm a chain, and
// a rotate to portrait must not re-arm one for the landscape it just left.
static void YTMULandscapeArm(int budget) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!YTMULandscapeAutoOpenEnabled()) {
            sendDebugLog(@"[MUSIC] landscape open not armed: lyricsFullscreenAutoOpen is off");
            // A decision not to open still invalidates whatever a previous
            // orientation armed, so its chain cannot present behind the switch.
            YTMUBumpOrientationGeneration();
            return;
        }
        if (!YTMUIsInterfaceLandscape()) {
            sendDebugLog(@"[MUSIC] landscape open not armed: interface is portrait");
            YTMUBumpOrientationGeneration();
            return;
        }
        NSUInteger generation = YTMUBumpOrientationGeneration();
        YTMUAttemptLandscapeOpenChain(budget, generation);
    });
}

static void YTMULandscapeOrientationChanged(NSNotification *note) {
    UIDeviceOrientation o = [UIDevice currentDevice].orientation;
    BOOL deviceLandscape = (o == UIDeviceOrientationLandscapeLeft || o == UIDeviceOrientationLandscapeRight);
    if (!deviceLandscape) {
        // Missed earlier (flat rotation, late observer, already landscape on
        // entry): try anyway, but only once the interface has settled -- this
        // branch also catches the device going flat in an existing landscape,
        // where arming immediately used to re-arm on every jitter.
        YTMULandscapeArm(2);
        return;
    }
    YTMULandscapeArm(4);
}

void YTMURegisterLandscapeAutoOpen(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIDeviceOrientationDidChangeNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            YTMULandscapeOrientationChanged(note);
        }];
    });
}
