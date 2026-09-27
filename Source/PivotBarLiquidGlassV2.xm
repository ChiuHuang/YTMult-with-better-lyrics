#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "YTMULiquidGlassPreferences.h"
static BOOL YTMUPivotV2Enabled(void){return YTMULGFeatureEnabled(@"pivotBarV2Enabled");}
static const void*kPivotBlur=&kPivotBlur;
@interface YTPivotBarView:UIView@end
%hook YTPivotBarView
-(void)layoutSubviews{%orig;if(!YTMUPivotV2Enabled()||CGRectIsEmpty(self.bounds))return;UIVisualEffectView*b=objc_getAssociatedObject(self,kPivotBlur);if(!b){b=[[UIVisualEffectView alloc]initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];b.userInteractionEnabled=NO;[self insertSubview:b atIndex:0];objc_setAssociatedObject(self,kPivotBlur,b,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}b.frame=CGRectInset(self.bounds,8,5);b.layer.cornerRadius=24;b.layer.cornerCurve=kCACornerCurveContinuous;b.clipsToBounds=YES;b.layer.borderWidth=.75;b.layer.borderColor=[UIColor colorWithWhite:1 alpha:.16].CGColor;[self sendSubviewToBack:b];self.backgroundColor=UIColor.clearColor;self.clipsToBounds=NO;}
%end
@interface YTPivotBarItemView:UIView@end
%hook YTPivotBarItemView
-(void)layoutSubviews{%orig;if(!YTMUPivotV2Enabled())return;self.backgroundColor=UIColor.clearColor;for(UIView*v in self.subviews)if([v isKindOfClass:UIImageView.class]){v.layer.shadowColor=UIColor.blackColor.CGColor;v.layer.shadowOpacity=.22;v.layer.shadowRadius=3;v.layer.shadowOffset=CGSizeMake(0,1);}}
%end
