#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#pragma mark - Preferences

static BOOL YTMULiquidGlassEnabled(void) {
    NSDictionary *preferences = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    BOOL masterEnabled = [preferences[@"YTMUltimateIsEnabled"] boolValue];
    id explicitValue = preferences[@"liquidGlassEnabled"];
    return masterEnabled && (explicitValue == nil || [explicitValue boolValue]);
}

#pragma mark - Associated object keys

static const void *kYTMUGlassBlurKey = &kYTMUGlassBlurKey;
static const void *kYTMUGlassTintKey = &kYTMUGlassTintKey;
static const void *kYTMUGlassBorderKey = &kYTMUGlassBorderKey;

#pragma mark - Glass helpers

static UIVisualEffectView *YTMUInstallGlassBlur(UIView *view, UIBlurEffectStyle style) {
    UIVisualEffectView *blur = objc_getAssociatedObject(view, kYTMUGlassBlurKey);
    if (!blur) {
        blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:style]];
        blur.userInteractionEnabled = NO;
        blur.clipsToBounds = YES;
        [view insertSubview:blur atIndex:0];
        objc_setAssociatedObject(view, kYTMUGlassBlurKey, blur, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        UIView *tint = [[UIView alloc] initWithFrame:CGRectZero];
        tint.userInteractionEnabled = NO;
        tint.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.075];
        [blur.contentView addSubview:tint];
        objc_setAssociatedObject(view, kYTMUGlassTintKey, tint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return blur;
}

static CAShapeLayer *YTMUInstallGlassBorder(UIView *view) {
    CAShapeLayer *border = objc_getAssociatedObject(view, kYTMUGlassBorderKey);
    if (!border) {
        border = [CAShapeLayer layer];
        border.fillColor = UIColor.clearColor.CGColor;
        border.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;
        border.lineWidth = 0.75;
        [view.layer addSublayer:border];
        objc_setAssociatedObject(view, kYTMUGlassBorderKey, border, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return border;
}

static void YTMUStyleGlassButton(UIView *button) {
    if (button.hidden || CGRectGetWidth(button.bounds) < 32.0 || CGRectGetHeight(button.bounds) < 32.0) return;

    CGFloat diameter = MIN(CGRectGetWidth(button.bounds), CGRectGetHeight(button.bounds));
    CGFloat radius = diameter * 0.5;
    UIVisualEffectView *blur = YTMUInstallGlassBlur(button, UIBlurEffectStyleSystemUltraThinMaterialDark);
    blur.frame = button.bounds;
    blur.layer.cornerRadius = radius;

    UIView *tint = objc_getAssociatedObject(button, kYTMUGlassTintKey);
    tint.frame = blur.bounds;
    tint.layer.cornerRadius = radius;

    button.backgroundColor = UIColor.clearColor;
    button.layer.cornerRadius = radius;
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.20;
    button.layer.shadowRadius = 8.0;
    button.layer.shadowOffset = CGSizeMake(0.0, 4.0);

    CAShapeLayer *border = YTMUInstallGlassBorder(button);
    border.frame = button.bounds;
    border.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(button.bounds, 0.5, 0.5)
                                               cornerRadius:MAX(0.0, radius - 0.5)].CGPath;
}

static void YTMUStyleMiniPlayerArtwork(UIView *root) {
    Class imageViewClass = NSClassFromString(@"YTImageView");
    for (UIView *view in root.subviews) {
        if (imageViewClass && [view isKindOfClass:imageViewClass]) {
            CGSize size = view.bounds.size;
            if (size.width >= 38.0 && size.width <= 56.0 && size.height >= 38.0 && size.height <= 56.0) {
                view.layer.cornerRadius = 12.0;
                view.layer.cornerCurve = kCACornerCurveContinuous;
                view.layer.masksToBounds = YES;
                view.layer.borderWidth = 0.5;
                view.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
            }
        }
        YTMUStyleMiniPlayerArtwork(view);
    }
}

#pragma mark - Mini player

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
    self.layer.shadowOpacity = 0.28;
    self.layer.shadowRadius = 14.0;
    self.layer.shadowOffset = CGSizeMake(0.0, 7.0);
}

- (void)layoutSubviews {
    %orig;
    if (!YTMULiquidGlassEnabled()) return;

    CGRect glassFrame = CGRectInset(self.bounds, 8.0, 2.0);
    CGFloat radius = MIN(22.0, CGRectGetHeight(glassFrame) * 0.5);

    UIVisualEffectView *blur = YTMUInstallGlassBlur(self, UIBlurEffectStyleSystemUltraThinMaterialDark);
    blur.frame = glassFrame;
    blur.layer.cornerRadius = radius;
    blur.layer.cornerCurve = kCACornerCurveContinuous;

    UIView *tint = objc_getAssociatedObject(self, kYTMUGlassTintKey);
    tint.frame = blur.bounds;
    tint.layer.cornerRadius = radius;
    tint.layer.cornerCurve = kCACornerCurveContinuous;

    CAShapeLayer *border = YTMUInstallGlassBorder(self);
    border.frame = self.bounds;
    border.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(glassFrame, 0.5, 0.5)
                                               cornerRadius:MAX(0.0, radius - 0.5)].CGPath;

    Class floatingButtonClass = NSClassFromString(@"MDCFloatingButton");
    for (UIView *subview in self.subviews) {
        if (floatingButtonClass && [subview isKindOfClass:floatingButtonClass]) {
            YTMUStyleGlassButton(subview);
        }
    }

    YTMUStyleMiniPlayerArtwork(self);

    // The stock one-pixel scrubber/divider fights the floating-card silhouette.
    Class scrubberClass = NSClassFromString(@"YTMStoryboardScrubber");
    for (UIView *subview in self.subviews) {
        if (scrubberClass && [subview isKindOfClass:scrubberClass] && CGRectGetHeight(subview.bounds) <= 2.0) {
            subview.alpha = 0.0;
        }
    }
}

%end

#pragma mark - Mini-player queue cell cleanup

@interface YTMPlaylistPanelVideoCell : UICollectionViewCell
@end

%hook YTMPlaylistPanelVideoCell

- (void)layoutSubviews {
    %orig;
    if (!YTMULiquidGlassEnabled()) return;

    // Only touch compact carousel cells, not the full queue rows.
    if (CGRectGetHeight(self.bounds) > 70.0 || CGRectGetWidth(self.bounds) > 360.0) return;

    self.backgroundColor = UIColor.clearColor;
    self.contentView.backgroundColor = UIColor.clearColor;

    // The first two direct UIImageViews are stock full-cell background plates.
    // Artwork is nested under YTImageView and remains visible.
    for (UIView *subview in self.subviews) {
        if ([subview isKindOfClass:UIImageView.class] &&
            CGRectGetWidth(subview.bounds) >= CGRectGetWidth(self.bounds)) {
            subview.hidden = YES;
        }
    }
}

%end
