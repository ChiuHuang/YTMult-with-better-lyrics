#ifndef YTMUVisualStyle_h
#define YTMUVisualStyle_h

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

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
static inline UIColor *YTMULGLyricAccent(BOOL lightBackdrop) {
    return lightBackdrop ? [UIColor colorWithRed:0.64 green:0.06 blue:0.12 alpha:1.0] : YTMULGAccentRed();
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
        [host insertSubview:texture aboveSubview:backgroundView];
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
    tint.backgroundColor = mean ? [YTMULGBlendColor(mean, YTMULGOlive(), .28) colorWithAlphaComponent:.34] : UIColor.clearColor;
    wash.frame = host.bounds;
    UIColor *shade = YTMULGBlendColor(UIColor.blackColor, YTMULGOlive(), .36);
    wash.backgroundColor = [shade colorWithAlphaComponent:overlayAlpha];
    if (artwork.superview != host) [host insertSubview:artwork atIndex:0];
    [host insertSubview:blur aboveSubview:artwork];
    [host insertSubview:tint aboveSubview:blur];
    [host insertSubview:wash aboveSubview:tint];
    host.backgroundColor = UIColor.blackColor;
    YTMULGApplyDither(host, wash, .48);
}

#endif
