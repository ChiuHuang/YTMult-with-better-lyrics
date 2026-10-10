#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "YTMULiquidGlassPreferences.h"
#import "YTMUVisualStyle.h"

static BOOL YTMUPivotV2Enabled(void) { return YTMULGFeatureEnabled(@"pivotBarV2Enabled"); }
static char kPivotBlurKey;

@interface YTPivotBarView : UIView @end
%hook YTPivotBarView
-(void)layoutSubviews {
    %orig;
    if (!YTMUPivotV2Enabled() || CGRectIsEmpty(self.bounds)) return;
    UIVisualEffectView *blur = objc_getAssociatedObject(self, &kPivotBlurKey);
    if (!blur) {
        blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
        blur.userInteractionEnabled = NO;
        blur.contentView.backgroundColor = YTMULGGlassFill();
        [self insertSubview:blur atIndex:0];
        objc_setAssociatedObject(self, &kPivotBlurKey, blur, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    blur.frame = CGRectInset(self.bounds, 8, 5);
    blur.layer.cornerRadius = 24;
    blur.layer.cornerCurve = kCACornerCurveContinuous;
    blur.clipsToBounds = YES;
    blur.layer.borderWidth = .75;
    blur.layer.borderColor = YTMULGGlassBorder(.38).CGColor;
    [self sendSubviewToBack:blur];
    YTMULGApplyDither(self, blur, .48);
    self.backgroundColor = UIColor.clearColor;
    self.clipsToBounds = NO;
}
%end

@interface YTPivotBarItemView : UIView @end
%hook YTPivotBarItemView
-(void)layoutSubviews {
    %orig;
    if (!YTMUPivotV2Enabled()) return;
    self.backgroundColor = UIColor.clearColor;
    BOOL selected = (self.accessibilityTraits & UIAccessibilityTraitSelected) != 0;
    for (UIView *view in self.subviews) {
        if (![view isKindOfClass:UIImageView.class]) continue;
        UIImageView *icon = (UIImageView *)view;
        icon.tintColor = selected ? YTMULGAccentRed() : YTMULGSage();
        icon.layer.shadowColor = UIColor.blackColor.CGColor;
        icon.layer.shadowOpacity = .22;
        icon.layer.shadowRadius = 3;
        icon.layer.shadowOffset = CGSizeMake(0, 1);
    }
}
%end
