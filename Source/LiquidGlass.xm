#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "LyricsShared.h"

static BOOL YTMULiquidGlassEnabled(void) {
    NSDictionary *prefs = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    id explicitValue = prefs[@"liquidGlassEnabled"];
    return [prefs[@"YTMUltimateIsEnabled"] boolValue] && (explicitValue == nil || [explicitValue boolValue]);
}

static const void *kYTMUGlassBlurKey = &kYTMUGlassBlurKey;
static const void *kYTMUGlassTintKey = &kYTMUGlassTintKey;
static const void *kYTMUGlassBorderKey = &kYTMUGlassBorderKey;

static UIVisualEffectView *YTMUBlurForView(UIView *view) {
    UIVisualEffectView *blur = objc_getAssociatedObject(view, kYTMUGlassBlurKey);
    if (!blur) {
        blur = [[UIVisualEffectView alloc] initWithEffect:
                [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
        blur.userInteractionEnabled = NO;
        blur.clipsToBounds = YES;
        [view insertSubview:blur atIndex:0];
        objc_setAssociatedObject(view, kYTMUGlassBlurKey, blur, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        UIView *tint = [[UIView alloc] initWithFrame:CGRectZero];
        tint.userInteractionEnabled = NO;
        tint.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.07];
        [blur.contentView addSubview:tint];
        objc_setAssociatedObject(view, kYTMUGlassTintKey, tint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return blur;
}

static CAShapeLayer *YTMUBorderForView(UIView *view) {
    CAShapeLayer *border = objc_getAssociatedObject(view, kYTMUGlassBorderKey);
    if (!border) {
        border = [CAShapeLayer layer];
        border.fillColor = UIColor.clearColor.CGColor;
        border.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.20].CGColor;
        border.lineWidth = 0.75;
        [view.layer addSublayer:border];
        objc_setAssociatedObject(view, kYTMUGlassBorderKey, border, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return border;
}

static void YTMUStyleGlassButton(UIView *button) {
    if (button.hidden || CGRectGetWidth(button.bounds) < 32.0) return;
    CGFloat radius = MIN(CGRectGetWidth(button.bounds), CGRectGetHeight(button.bounds)) * 0.5;
    UIVisualEffectView *blur = YTMUBlurForView(button);
    blur.frame = button.bounds;
    blur.layer.cornerRadius = radius;
    UIView *tint = objc_getAssociatedObject(button, kYTMUGlassTintKey);
    tint.frame = blur.bounds;
    tint.layer.cornerRadius = radius;
    [button sendSubviewToBack:blur];

    button.backgroundColor = UIColor.clearColor;
    button.layer.cornerRadius = radius;
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.18;
    button.layer.shadowRadius = 7.0;
    button.layer.shadowOffset = CGSizeMake(0.0, 3.0);

    CAShapeLayer *border = YTMUBorderForView(button);
    border.frame = button.bounds;
    border.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(button.bounds, 0.5, 0.5)
                                               cornerRadius:MAX(0.0, radius - 0.5)].CGPath;
}

// Nudge the mini player's right-side buttons (cast + play/pause) left a little
// so the pair stops hugging the screen edge. Frame-based, not a transform: the
// parent layout hook re-applies it every pass and YT's own collapse/expand
// animations stay intact.
static const CGFloat kYTMUMiniButtonShiftX = 6.0;

static BOOL YTMUIsMiniPlayerButton(UIView *view) {
    Class floatingClass = NSClassFromString(@"MDCFloatingButton");
    if (floatingClass && [view isKindOfClass:floatingClass]) return YES;
    if (![view isKindOfClass:UIControl.class]) return NO;
    CGFloat width = CGRectGetWidth(view.bounds);
    CGFloat height = CGRectGetHeight(view.bounds);
    if (width < 28.0 || width > 88.0) return NO;
    return fabs(width - height) <= 4.0;
}

static void YTMUShiftMiniPlayerButton(UIView *button) {
    CGRect frame = button.frame;
    CGFloat x = MAX(0.0, CGRectGetMinX(frame) - kYTMUMiniButtonShiftX);
    button.frame = CGRectMake(x, CGRectGetMinY(frame), CGRectGetWidth(frame), CGRectGetHeight(frame));
}

static void YTMUCleanMiniPlayerTree(UIView *root, CGFloat compactWidth) {
    Class ytImageClass = NSClassFromString(@"YTImageView");
    Class swipeClass = NSClassFromString(@"YTLightweightSwipeContentScrollView");
    Class inkClass = NSClassFromString(@"MDCInkView");

    for (UIView *view in root.subviews) {
        if ([view isKindOfClass:UICollectionView.class] ||
            (swipeClass && [view isKindOfClass:swipeClass])) {
            view.backgroundColor = UIColor.clearColor;
            view.opaque = NO;
        }

        if ([view isKindOfClass:UIImageView.class]) {
            CGFloat width = CGRectGetWidth(view.bounds);
            CGFloat height = CGRectGetHeight(view.bounds);
            if (width >= compactWidth - 8.0 && height >= 56.0 && height <= 76.0) {
                view.hidden = YES;
                view.alpha = 0.0;
            }
        }

        if (ytImageClass && [view isKindOfClass:ytImageClass]) {
            CGFloat width = CGRectGetWidth(view.bounds);
            if (width >= 38.0 && width <= 56.0) {
                view.layer.cornerRadius = 12.0;
                view.layer.cornerCurve = kCACornerCurveContinuous;
                view.layer.masksToBounds = YES;
                view.layer.borderWidth = 0.5;
                view.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
            }
        }

        if (inkClass && [view isKindOfClass:inkClass]) view.backgroundColor = UIColor.clearColor;
        YTMUCleanMiniPlayerTree(view, compactWidth);
    }
}

@interface YTMMiniPlayerView : UIView
@end

%hook YTMMiniPlayerView

- (void)didMoveToWindow {
    %orig;
    if (!YTMULiquidGlassEnabled()) return;
    self.backgroundColor = UIColor.clearColor;
    self.clipsToBounds = NO;
    self.layer.masksToBounds = NO;
    self.layer.shadowColor = UIColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0.26;
    self.layer.shadowRadius = 13.0;
    self.layer.shadowOffset = CGSizeMake(0.0, 6.0);
}

- (void)layoutSubviews {
    %orig;
    if (!YTMULiquidGlassEnabled()) return;

    CGRect glassFrame = CGRectInset(self.bounds, 8.0, 2.0);
    CGFloat radius = MIN(22.0, CGRectGetHeight(glassFrame) * 0.5);
    UIVisualEffectView *blur = YTMUBlurForView(self);
    blur.frame = glassFrame;
    blur.layer.cornerRadius = radius;
    blur.layer.cornerCurve = kCACornerCurveContinuous;
    UIView *tint = objc_getAssociatedObject(self, kYTMUGlassTintKey);
    tint.frame = blur.bounds;
    tint.layer.cornerRadius = radius;
    tint.layer.cornerCurve = kCACornerCurveContinuous;

    CGFloat compactWidth = MAX(1.0, CGRectGetWidth(self.bounds) - 96.0);
    YTMUCleanMiniPlayerTree(self, compactWidth);
    [self sendSubviewToBack:blur];

    CAShapeLayer *border = YTMUBorderForView(self);
    border.frame = self.bounds;
    border.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(glassFrame, 0.5, 0.5)
                                               cornerRadius:MAX(0.0, radius - 0.5)].CGPath;

    Class buttonClass = NSClassFromString(@"MDCFloatingButton");
    Class scrubberClass = NSClassFromString(@"YTMStoryboardScrubber");
    NSMutableString *dump = nil;
    for (UIView *view in self.subviews) {
        if (buttonClass && [view isKindOfClass:buttonClass]) YTMUStyleGlassButton(view);
        if (scrubberClass && [view isKindOfClass:scrubberClass] && CGRectGetHeight(view.bounds) <= 2.0) {
            view.alpha = 0.0;
        }
        if (YTMUIsMiniPlayerButton(view)) {
            if (!dump) dump = [NSMutableString stringWithString:@"[MINI] shifted buttons:"];
            [dump appendFormat:@"\n  %@ frame=(%.0f,%.0f;%.0f,%.0f) label=\"%@\"",
                NSStringFromClass([view class]),
                CGRectGetMinX(view.frame), CGRectGetMinY(view.frame),
                CGRectGetWidth(view.frame), CGRectGetHeight(view.frame),
                [view accessibilityLabel] ?: @""];
            YTMUShiftMiniPlayerButton(view);
        }
    }
    if (dump) {
        // One log line per distinct button set -- layoutSubviews runs on every
        // collapse/expand and song change, no per-pass spam.
        static NSString *lastDump = nil;
        if (![dump isEqualToString:lastDump]) {
            lastDump = [dump copy];
            sendDebugLog(dump);
        }
    }
}

%end
