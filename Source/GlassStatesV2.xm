#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "YTMULiquidGlassPreferences.h"
static const void*kState=&kState;
static void State(UIView*h){if(!YTMULGFeatureEnabled(@"globalStatesV2Enabled")||CGRectIsEmpty(h.bounds))return;UIVisualEffectView*b=objc_getAssociatedObject(h,kState);if(!b){UIBlurEffectStyle s=UIAccessibilityIsReduceTransparencyEnabled()?UIBlurEffectStyleSystemMaterialDark:UIBlurEffectStyleSystemUltraThinMaterialDark;b=[[UIVisualEffectView alloc]initWithEffect:[UIBlurEffect effectWithStyle:s]];b.userInteractionEnabled=NO;[h insertSubview:b atIndex:0];objc_setAssociatedObject(h,kState,b,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}b.frame=CGRectInset(h.bounds,20,18);b.layer.cornerRadius=24;b.layer.cornerCurve=kCACornerCurveContinuous;b.clipsToBounds=YES;b.layer.borderWidth=.7;b.layer.borderColor=[UIColor colorWithWhite:1 alpha:.16].CGColor;[h sendSubviewToBack:b];h.backgroundColor=UIColor.clearColor;}
#define S(C) @interface C:UIView@end %hook C - (void)layoutSubviews{%orig;State(self);}%end
S(YTMLoadingView) S(YTMEmptyStateView) S(YTMContentUnavailableView) S(YTMRestrictedContentView) S(YTMOfflineView) S(YTMAuthenticationRequiredView) S(YTMServerErrorView) S(YTMUInstrumentalLyricsView) S(YTMULyricsUnavailableView) S(YTMUUnsupportedVersionView) S(YTMURemoteDisabledView) S(YTMRefreshErrorView)
#undef S
