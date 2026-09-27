#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "YTMULiquidGlassPreferences.h"
// No feature key of its own: this only takes the shadows off surfaces the V2
// glass leaves behind, so it follows the tweak master plus the material gate.
static BOOL YTMUVideoCompatEnabled(void){return YTMULGTweakEnabled()&&YTMULGAvailable();}
@interface YTMVideoOverlayView:UIView@end
%hook YTMVideoOverlayView
-(void)layoutSubviews{%orig;if(!YTMUVideoCompatEnabled())return;self.layer.cornerCurve=kCACornerCurveContinuous;for(UIView*v in self.subviews){if([NSStringFromClass(v.class)isEqualToString:@"YTMPlayerControlsView"]&&CGRectGetWidth(v.bounds)<360){v.backgroundColor=UIColor.clearColor;v.layer.shadowOpacity=0;}}}
%end
@interface YTInlinePlayerDoubleTapArrowsView:UIView@end
%hook YTInlinePlayerDoubleTapArrowsView
-(void)layoutSubviews{%orig;if(!YTMUVideoCompatEnabled())return;self.backgroundColor=UIColor.clearColor;}
%end
