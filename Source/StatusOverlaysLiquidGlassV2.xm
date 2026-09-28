#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "YTMULiquidGlassPreferences.h"
static const void*kStatus=&kStatus;
static void Status(UIView*h,CGFloat r){if(!YTMULGFeatureEnabled(@"statusOverlaysV2Enabled")||CGRectIsEmpty(h.bounds))return;UIVisualEffectView*b=objc_getAssociatedObject(h,kStatus);if(!b){b=[[UIVisualEffectView alloc]initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];b.userInteractionEnabled=NO;[h insertSubview:b atIndex:0];objc_setAssociatedObject(h,kStatus,b,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}b.frame=h.bounds;b.layer.cornerRadius=r;b.layer.cornerCurve=kCACornerCurveContinuous;b.clipsToBounds=YES;b.layer.borderWidth=.7;b.layer.borderColor=[UIColor colorWithWhite:1 alpha:.17].CGColor;[h sendSubviewToBack:b];h.backgroundColor=UIColor.clearColor;}
#define V(C,R) @interface C:UIView@end %hook C - (void)layoutSubviews{%orig;Status(self,R);}%end
V(YTMToastView,18) V(YTAlertView,24) V(YTMProgressHUDView,20) V(YTMULyricsProviderLoadingView,20) V(YTMOfflineStatusView,18) V(YTMNetworkErrorView,24)
#undef V
