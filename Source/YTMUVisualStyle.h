#ifndef YTMUVisualStyle_h
#define YTMUVisualStyle_h

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import "YTMULiquidGlassPreferences.h"

// Shared visual tokens for the menu, player, and lyrics surfaces.
static inline UIColor *YTMULGSage(void) {
    return [UIColor colorWithRed:0.62 green:0.69 blue:0.53 alpha:1.0];
}
static inline UIColor *YTMULGOlive(void) {
    return [UIColor colorWithRed:0.16 green:0.20 blue:0.12 alpha:1.0];
}
static inline UIColor *YTMULGAccentRed(void) {
    return [UIColor colorWithRed:1.0 green:0.12 blue:0.20 alpha:1.0];
}
static inline UIColor *YTMULGGlassFill(void) {
    return [YTMULGOlive() colorWithAlphaComponent:0.24];
}
static inline UIColor *YTMULGGlassBorder(CGFloat alpha) {
    return [YTMULGSage() colorWithAlphaComponent:alpha];
}
static inline UIColor *YTMULGBlendColor(UIColor *base, UIColor *tint, CGFloat amount) {
    CGFloat br = 0, bg = 0, bb = 0, ba = 0, tr = 0, tg = 0, tb = 0;
    if (![base getRed:&br green:&bg blue:&bb alpha:&ba] ||
        ![tint getRed:&tr green:&tg blue:&tb alpha:NULL]) return base;
    CGFloat t = MIN(1.0, MAX(0.0, amount));
    return [UIColor colorWithRed:br * (1.0 - t) + tr * t
                           green:bg * (1.0 - t) + tg * t
                            blue:bb * (1.0 - t) + tb * t
                           alpha:ba];
}

// SONG-DERIVED GLASS. Every player-page chrome colour reads the artwork mean
// through YTMULGArtworkTint() and keeps the cover's HUE -- no sage, no olive.
// The old surfaces blended 22-36% toward the fixed sage/olive palette, which
// is a yellow cast no blue cover survives (the "why does a blue cover have
// yellow glass" report), and the play/selected controls were a constant red
// the song never asked for. Near-grey covers (saturation < .12) return the
// OLD neutral so nothing is invented: a grey pixel's hue is meaningless, and
// the old saturation floor would have turned Suki's grey-white red. No
// artwork sampled yet means the same neutral, so the pre-first-frame look is
// exactly what shipped before.
static inline BOOL YTMUSongHue(UIColor *mean, CGFloat *hOut, CGFloat *sOut, CGFloat *bOut) {
    if (!mean) return NO;
    CGFloat h = 0, s = 0, b = 0, a = 0;
    if (![mean getHue:&h saturation:&s brightness:&b alpha:&a]) return NO;
    if (s < .12) return NO;
    if (hOut) *hOut = h;
    if (sOut) *sOut = s;
    if (bOut) *bOut = b;
    return YES;
}
static inline UIColor *YTMUSongGlassFill(CGFloat alpha) {
    CGFloat h = 0, s = 0, b = 0;
    if (!YTMUSongHue(YTMULGArtworkTint(), &h, &s, &b)) return YTMULGGlassFill();
    // Glassy band: darker than the cover so the white ink above it keeps its
    // contrast, saturation capped well below neon.
    return [UIColor colorWithHue:h saturation:MIN(.58, MAX(.20, s * .85))
                       brightness:MIN(.60, MAX(.14, b * .75)) alpha:alpha];
}
static inline UIColor *YTMUSongGlassBorder(CGFloat alpha) {
    CGFloat h = 0, s = 0, b = 0;
    if (!YTMUSongHue(YTMULGArtworkTint(), &h, &s, &b)) return YTMULGGlassBorder(alpha);
    return [UIColor colorWithHue:h saturation:MIN(.62, MAX(.22, s * .90))
                       brightness:MIN(.70, MAX(.24, b * .95)) alpha:alpha];
}
static inline UIColor *YTMUSongAccent(CGFloat alpha) {
    CGFloat h = 0, s = 0, b = 0;
    if (!YTMUSongHue(YTMULGArtworkTint(), &h, &s, &b)) return [YTMULGAccentRed() colorWithAlphaComponent:alpha];
    // Vivid: this is the play button / selected tab, the one loud spot the
    // old red owned. Lifted above the glass band instead of pasted over it.
    return [UIColor colorWithHue:h saturation:MIN(.92, MAX(.55, s * 1.20))
                       brightness:MIN(.92, MAX(.42, b * 1.40)) alpha:alpha];
}
static inline UIColor *YTMULGLyricAccent(BOOL lightBackdrop) {
    // The word-by-word wipe is the SUNG text, so it reads as the brightest ink
    // on the panel. It is deliberately not the brand red: a red wipe turns a
    // normal lyric sheet into an error state and fights the artwork.
    return lightBackdrop ? [UIColor colorWithWhite:0.08 alpha:1.0]
                         : [UIColor colorWithRed:0.98 green:0.97 blue:0.94 alpha:1.0];
}

static inline UIImage *YTMULGDitherPattern(void) {
    static UIImage *pattern;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(8, 8), NO, 1.0);
        CGContextRef context = UIGraphicsGetCurrentContext();
        CGContextSetFillColorWithColor(context, [YTMULGSage() colorWithAlphaComponent:0.22].CGColor);
        CGContextFillRect(context, CGRectMake(0, 0, 1, 1));
        CGContextSetFillColorWithColor(context, [YTMULGAccentRed() colorWithAlphaComponent:0.16].CGColor);
        CGContextFillRect(context, CGRectMake(4, 4, 1, 1));
        pattern = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    });
    return pattern;
}

// A sparse dither layer keeps the background texture consistent without
// intercepting touches or covering the controls above it.
static inline void YTMULGApplyDither(UIView *host, UIView *backgroundView, CGFloat opacity) {
    if (!host) return;
    static char key;
    UIImageView *texture = objc_getAssociatedObject(host, &key);
    if (!texture) {
        texture = [[UIImageView alloc] initWithFrame:host.bounds];
        texture.tag = 7318;
        texture.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        texture.userInteractionEnabled = NO;
        texture.backgroundColor = [UIColor colorWithPatternImage:YTMULGDitherPattern()];
        objc_setAssociatedObject(host, &key, texture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    texture.frame = host.bounds;
    texture.alpha = opacity;
    if (texture.superview != host) {
        if (backgroundView.superview == host) [host insertSubview:texture aboveSubview:backgroundView];
        else [host insertSubview:texture atIndex:0];
    } else if (backgroundView.superview == host) {
        // Only reorder when the order is actually WRONG. An insert is a
        // didChangeSubviewIndexPath + setNeedsLayout on the host; this helper
        // runs from layoutSubviews (the search box calls it every pass), so an
        // unconditional insert re-triggered layout every pass and made the
        // host churn against its own hook.
        NSUInteger ti = [host.subviews indexOfObject:texture];
        NSUInteger bi = [host.subviews indexOfObject:backgroundView];
        if (ti != NSNotFound && bi != NSNotFound && ti < bi) {
            [host insertSubview:texture aboveSubview:backgroundView];
        }
    }
}

static inline void YTMULGApplyArtworkBackdrop(UIView *host, CGFloat overlayAlpha, UIBlurEffectStyle blurStyle) {
    if (!host) return;
    static char key;
    NSMutableDictionary *views = objc_getAssociatedObject(host, &key);
    if (!views) {
        UIImageView *artwork = [[UIImageView alloc] initWithFrame:host.bounds];
        artwork.tag = 7319;
        artwork.contentMode = UIViewContentModeScaleAspectFill;
        artwork.clipsToBounds = YES;
        artwork.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
        blur.userInteractionEnabled = NO;
        blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        UIView *tint = [[UIView alloc] initWithFrame:host.bounds];
        tint.tag = 7320;
        tint.userInteractionEnabled = NO;
        tint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        UIView *wash = [[UIView alloc] initWithFrame:host.bounds];
        wash.tag = 7321;
        wash.userInteractionEnabled = NO;
        wash.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        views = [@{@"artwork": artwork, @"blur": blur, @"tint": tint, @"wash": wash, @"blurStyle": @(blurStyle)} mutableCopy];
        objc_setAssociatedObject(host, &key, views, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIImageView *artwork = views[@"artwork"];
    UIVisualEffectView *blur = views[@"blur"];
    UIView *tint = views[@"tint"];
    UIView *wash = views[@"wash"];
    UIImage *image = YTMULGCurrentArtwork();
    UIColor *mean = YTMULGCurrentArtworkMean();
    artwork.frame = host.bounds;
    artwork.image = image;
    artwork.hidden = image == nil;
    blur.frame = host.bounds;
    blur.alpha = image ? .82 : 0.0;
    NSNumber *previousStyle = views[@"blurStyle"];
    if (previousStyle.integerValue != blurStyle) {
        blur.effect = [UIBlurEffect effectWithStyle:blurStyle];
        views[@"blurStyle"] = @(blurStyle);
    }
    tint.frame = host.bounds;
    // Both layers used to blend the sampled colour 28-36% toward olive --
    // dark yellow-green -- which is how a blue cover's background acquired a
    // yellow cast. The tint IS the song colour now (the blur already holds
    // the artwork, so the tint only has to push its hue one step closer), and
    // the wash is plain black: its job is contrast, not colour.
    tint.backgroundColor = mean ? [mean colorWithAlphaComponent:.34] : UIColor.clearColor;
    wash.frame = host.bounds;
    wash.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:overlayAlpha];
    if (artwork.superview != host) [host insertSubview:artwork atIndex:0];
    [host insertSubview:blur aboveSubview:artwork];
    [host insertSubview:tint aboveSubview:blur];
    [host insertSubview:wash aboveSubview:tint];
    host.backgroundColor = UIColor.blackColor;
    YTMULGApplyDither(host, wash, .48);
}

#endif
