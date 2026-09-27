#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "YTMULiquidGlassPreferences.h"
// V2 master key, deliberately NOT V1's `liquidGlassEnabled`; V1's mini-player
// hook stands down while this is on (YTMULGV1Allowed in
// Source/YTMULiquidGlassPreferences.h).
static BOOL YTMUMiniEnabled(void){return YTMULGFeatureEnabled(@"liquidGlassV2Enabled");}

static UIImageView *YTMULoadedImage(UIView *root){NSMutableArray*q=[NSMutableArray arrayWithObject:root];while(q.count){UIView*v=q.firstObject;[q removeObjectAtIndex:0];[q addObjectsFromArray:v.subviews];if([v isKindOfClass:UIImageView.class]&&((UIImageView*)v).image)return(UIImageView*)v;}return nil;}
// NO BACKGROUND, ON PURPOSE. This view used to carry its own frosted card (a
// UIVisualEffectView at index 0) plus a white-to-black song gradient on top of
// it, so the bar read as a separate slab sitting on the page instead of part
// of it. The song colour is supposed to come from the app's own backdrop, so
// the bar is transparent and the whole-app tint in
// Source/DynamicArtworkThemeV2.xm reads straight through it. Do not re-add a
// card here. What stays is the artwork treatment below and the soft drop
// shadow, which follows the subviews' own alpha (the thumbnail and the labels)
// and therefore still renders with a clear backgroundColor.
static void YTMUMiniTree(UIView *root){Class image=NSClassFromString(@"YTImageView");for(UIView*v in root.subviews){if(image&&[v isKindOfClass:image]){CGFloat w=CGRectGetWidth(v.bounds),h=CGRectGetHeight(v.bounds);if(w>=38&&w<=56&&h>=38&&h<=56){UIImageView*loaded=YTMULoadedImage(v);if(loaded){v.hidden=NO;v.alpha=1;loaded.hidden=NO;loaded.alpha=1;CGFloat scale=MIN(1,40.0/MAX(1,w));v.transform=CGAffineTransformMakeScale(scale,scale);v.layer.cornerRadius=10.0/scale;v.layer.cornerCurve=kCACornerCurveContinuous;v.layer.masksToBounds=YES;}}}YTMUMiniTree(v);}}
@interface YTMMiniPlayerView:UIView@end
%hook YTMMiniPlayerView
- (void)didMoveToWindow{%orig;if(!YTMUMiniEnabled())return;self.backgroundColor=UIColor.clearColor;self.clipsToBounds=NO;self.layer.shadowColor=UIColor.blackColor.CGColor;self.layer.shadowOpacity=.25;self.layer.shadowRadius=13;self.layer.shadowOffset=CGSizeMake(0,6);}
- (void)layoutSubviews{%orig;if(!YTMUMiniEnabled())return;YTMUMiniTree(self);dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.35*NSEC_PER_SEC)),dispatch_get_main_queue(),^{YTMUMiniTree(self);});}
%end
