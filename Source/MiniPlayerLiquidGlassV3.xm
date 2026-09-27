#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "YTMULiquidGlassPreferences.h"
static const void *kMiniBlur=&kMiniBlur; static const void *kMiniTheme=&kMiniTheme;
// V2 master key, deliberately NOT V1's `liquidGlassEnabled`; V1's mini-player
// hook stands down while this is on (YTMULGV1Allowed in
// Source/YTMULiquidGlassPreferences.h).
static BOOL YTMUMiniEnabled(void){return YTMULGFeatureEnabled(@"liquidGlassV2Enabled");}

static void YTMUMiniSongTheme(UIView *host){if(!YTMULGFeatureEnabled(@"playerSongThemeEnabled"))return;CAGradientLayer*g=objc_getAssociatedObject(host,kMiniTheme);if(!g){g=[CAGradientLayer layer];[host.layer insertSublayer:g atIndex:0];objc_setAssociatedObject(host,kMiniTheme,g,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}g.frame=host.bounds;g.colors=@[(id)[UIColor colorWithWhite:.16 alpha:.76].CGColor,(id)UIColor.blackColor.CGColor];g.startPoint=CGPointMake(0,0);g.endPoint=CGPointMake(1,1);}
static UIImageView *YTMULoadedImage(UIView *root){NSMutableArray*q=[NSMutableArray arrayWithObject:root];while(q.count){UIView*v=q.firstObject;[q removeObjectAtIndex:0];[q addObjectsFromArray:v.subviews];if([v isKindOfClass:UIImageView.class]&&((UIImageView*)v).image)return(UIImageView*)v;}return nil;}
static void YTMUMiniTree(UIView *root){Class image=NSClassFromString(@"YTImageView");for(UIView*v in root.subviews){if(image&&[v isKindOfClass:image]){CGFloat w=CGRectGetWidth(v.bounds),h=CGRectGetHeight(v.bounds);if(w>=38&&w<=56&&h>=38&&h<=56){UIImageView*loaded=YTMULoadedImage(v);if(loaded){v.hidden=NO;v.alpha=1;loaded.hidden=NO;loaded.alpha=1;CGFloat scale=MIN(1,40.0/MAX(1,w));v.transform=CGAffineTransformMakeScale(scale,scale);v.layer.cornerRadius=10.0/scale;v.layer.cornerCurve=kCACornerCurveContinuous;v.layer.masksToBounds=YES;}}}YTMUMiniTree(v);}}
@interface YTMMiniPlayerView:UIView@end
%hook YTMMiniPlayerView
- (void)didMoveToWindow{%orig;if(!YTMUMiniEnabled())return;self.backgroundColor=UIColor.clearColor;self.clipsToBounds=NO;self.layer.shadowColor=UIColor.blackColor.CGColor;self.layer.shadowOpacity=.25;self.layer.shadowRadius=13;self.layer.shadowOffset=CGSizeMake(0,6);}
- (void)layoutSubviews{%orig;if(!YTMUMiniEnabled())return;UIVisualEffectView*b=objc_getAssociatedObject(self,kMiniBlur);if(!b){b=[[UIVisualEffectView alloc]initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];b.userInteractionEnabled=NO;b.clipsToBounds=YES;[self insertSubview:b atIndex:0];objc_setAssociatedObject(self,kMiniBlur,b,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}b.frame=CGRectInset(self.bounds,8,2);b.layer.cornerRadius=22;b.layer.cornerCurve=kCACornerCurveContinuous;b.layer.borderWidth=.75;b.layer.borderColor=[UIColor colorWithWhite:1 alpha:.2].CGColor;[self sendSubviewToBack:b];YTMUMiniSongTheme(self);YTMUMiniTree(self);dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.35*NSEC_PER_SEC)),dispatch_get_main_queue(),^{YTMUMiniTree(self);});}
%end
