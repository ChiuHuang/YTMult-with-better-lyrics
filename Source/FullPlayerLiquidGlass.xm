#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#pragma mark - Full-player Liquid Glass preferences

static BOOL YTMUFullGlassEnabled(void) {
    NSDictionary *prefs = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    id explicitValue = prefs[@"fullPlayerLiquidGlassEnabled"];
    return [prefs[@"YTMUltimateIsEnabled"] boolValue] && (explicitValue == nil || [explicitValue boolValue]);
}

static const void *kYTMUFullBlurKey = &kYTMUFullBlurKey;
static const void *kYTMUFullTintKey = &kYTMUFullTintKey;
static const void *kYTMUFullBorderKey = &kYTMUFullBorderKey;

static UIVisualEffectView *YTMUFullBlur(UIView *host, UIBlurEffectStyle style) {
    UIVisualEffectView *blur = objc_getAssociatedObject(host, kYTMUFullBlurKey);
    if (!blur) {
        blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:style]];
        blur.userInteractionEnabled = NO;
        blur.clipsToBounds = YES;
        [host insertSubview:blur atIndex:0];
        objc_setAssociatedObject(host, kYTMUFullBlurKey, blur, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        UIView *tint = [[UIView alloc] initWithFrame:CGRectZero];
        tint.userInteractionEnabled = NO;
        tint.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.065];
        [blur.contentView addSubview:tint];
        objc_setAssociatedObject(host, kYTMUFullTintKey, tint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return blur;
}

static CAShapeLayer *YTMUFullBorder(UIView *host) {
    CAShapeLayer *border = objc_getAssociatedObject(host, kYTMUFullBorderKey);
    if (!border) {
        border = [CAShapeLayer layer];
        border.fillColor = UIColor.clearColor.CGColor;
        border.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.20].CGColor;
        border.lineWidth = 0.75;
        [host.layer addSublayer:border];
        objc_setAssociatedObject(host, kYTMUFullBorderKey, border, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return border;
}

static void YTMUStyleFullGlassSurface(UIView *host, CGRect frame, CGFloat radius, UIBlurEffectStyle style) {
    UIVisualEffectView *blur = YTMUFullBlur(host, style);
    blur.frame = frame;
    blur.layer.cornerRadius = radius;
    blur.layer.cornerCurve = kCACornerCurveContinuous;

    UIView *tint = objc_getAssociatedObject(host, kYTMUFullTintKey);
    tint.frame = blur.bounds;
    tint.layer.cornerRadius = radius;
    tint.layer.cornerCurve = kCACornerCurveContinuous;
    [host sendSubviewToBack:blur];

    CAShapeLayer *border = YTMUFullBorder(host);
    border.frame = host.bounds;
    border.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(frame, 0.5, 0.5)
                                               cornerRadius:MAX(0.0, radius - 0.5)].CGPath;
}

static void YTMUStyleFullPlayerButton(UIView *button, BOOL primary) {
    if (button.hidden || CGRectGetWidth(button.bounds) < 36.0 || CGRectGetHeight(button.bounds) < 36.0) return;

    CGFloat radius = MIN(CGRectGetWidth(button.bounds), CGRectGetHeight(button.bounds)) * 0.5;
    UIVisualEffectView *blur = YTMUFullBlur(button, primary ? UIBlurEffectStyleSystemChromeMaterialDark : UIBlurEffectStyleSystemUltraThinMaterialDark);
    blur.frame = button.bounds;
    blur.layer.cornerRadius = radius;

    UIView *tint = objc_getAssociatedObject(button, kYTMUFullTintKey);
    tint.frame = blur.bounds;
    tint.layer.cornerRadius = radius;
    tint.backgroundColor = [UIColor colorWithWhite:1.0 alpha:(primary ? 0.16 : 0.055)];
    [button sendSubviewToBack:blur];

    button.backgroundColor = UIColor.clearColor;
    button.layer.cornerRadius = radius;
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = primary ? 0.30 : 0.14;
    button.layer.shadowRadius = primary ? 14.0 : 7.0;
    button.layer.shadowOffset = CGSizeMake(0.0, primary ? 7.0 : 3.0);

    CAShapeLayer *border = YTMUFullBorder(button);
    border.frame = button.bounds;
    border.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(button.bounds, 0.5, 0.5)
                                               cornerRadius:MAX(0.0, radius - 0.5)].CGPath;
}

#pragma mark - Artwork card

@interface YTMPlayerCarouselCell : UICollectionViewCell
@end

%hook YTMPlayerCarouselCell

- (void)layoutSubviews {
    %orig;
    if (!YTMUFullGlassEnabled() || self.hidden || CGRectGetWidth(self.bounds) < 300.0) return;

    self.backgroundColor = UIColor.clearColor;
    self.contentView.backgroundColor = UIColor.clearColor;
    self.clipsToBounds = NO;
    self.contentView.clipsToBounds = NO;

    Class imageClass = NSClassFromString(@"YTImageView");
    for (UIView *view in self.contentView.subviews) {
        if (imageClass && [view isKindOfClass:imageClass] && CGRectGetWidth(view.bounds) >= 300.0) {
            view.layer.cornerRadius = 28.0;
            view.layer.cornerCurve = kCACornerCurveContinuous;
            view.layer.masksToBounds = YES;
            view.layer.borderWidth = 0.75;
            view.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
            view.layer.shadowColor = UIColor.blackColor.CGColor;
            view.layer.shadowOpacity = 0.32;
            view.layer.shadowRadius = 22.0;
            view.layer.shadowOffset = CGSizeMake(0.0, 12.0);
        }
    }
}

%end

#pragma mark - Main transport controls

@interface YTMPlayerControlsView : UIView
@end

%hook YTMPlayerControlsView

- (void)layoutSubviews {
    %orig;
    if (!YTMUFullGlassEnabled() || CGRectGetWidth(self.bounds) < 360.0) return;

    Class floatingClass = NSClassFromString(@"MDCFloatingButton");
    Class shuffleClass = NSClassFromString(@"YTMShuffleButton");
    Class loopClass = NSClassFromString(@"YTMMDCLoopButton");

    for (UIView *view in self.subviews) {
        BOOL supported = (floatingClass && [view isKindOfClass:floatingClass]) ||
                         (shuffleClass && [view isKindOfClass:shuffleClass]) ||
                         (loopClass && [view isKindOfClass:loopClass]);
        if (!supported || view.hidden) continue;

        BOOL primary = CGRectGetWidth(view.bounds) >= 68.0;
        YTMUStyleFullPlayerButton(view, primary);
    }
}

%end

#pragma mark - Header capsule

@interface YTMPlayerHeaderView : UIView
@end

%hook YTMPlayerHeaderView

- (void)layoutSubviews {
    %orig;
    if (!YTMUFullGlassEnabled() || CGRectGetWidth(self.bounds) < 300.0 || CGRectGetHeight(self.bounds) < 36.0) return;

    CGRect capsule = CGRectInset(self.bounds, 12.0, 2.0);
    CGFloat radius = MIN(24.0, CGRectGetHeight(capsule) * 0.5);
    YTMUStyleFullGlassSurface(self, capsule, radius, UIBlurEffectStyleSystemUltraThinMaterialDark);
    self.backgroundColor = UIColor.clearColor;
    self.clipsToBounds = NO;
    self.layer.shadowColor = UIColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0.16;
    self.layer.shadowRadius = 10.0;
    self.layer.shadowOffset = CGSizeMake(0.0, 5.0);
}

%end

#pragma mark - Audio/video switch

@interface YTMAVSwitch : UIView
@end

%hook YTMAVSwitch

- (void)layoutSubviews {
    %orig;
    if (!YTMUFullGlassEnabled() || CGRectGetWidth(self.bounds) < 80.0) return;

    CGFloat radius = CGRectGetHeight(self.bounds) * 0.5;
    YTMUStyleFullGlassSurface(self, self.bounds, radius, UIBlurEffectStyleSystemThinMaterialDark);
    self.backgroundColor = UIColor.clearColor;
}

%end
