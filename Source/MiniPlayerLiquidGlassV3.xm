#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "YTMULiquidGlassPreferences.h"
#import "YTMUVisualStyle.h"
// V2 master key, deliberately NOT V1's `liquidGlassEnabled`; V1's mini-player
// hook stands down while this is on (YTMULGV1Allowed in
// Source/YTMULiquidGlassPreferences.h).
static BOOL YTMUMiniEnabled(void){return YTMULGFeatureEnabled(@"liquidGlassV2Enabled");}
static char kMiniGlassKey;

static UIVisualEffectView *YTMUMiniGlass(UIView *host) {
    UIVisualEffectView *glass = objc_getAssociatedObject(host, &kMiniGlassKey);
    if (!glass) {
        glass = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
        glass.userInteractionEnabled = NO;
        glass.contentView.backgroundColor = YTMULGGlassFill();
        glass.layer.cornerRadius = 18;
        glass.layer.cornerCurve = kCACornerCurveContinuous;
        glass.layer.borderWidth = .75;
        glass.layer.borderColor = YTMULGGlassBorder(.38).CGColor;
        glass.clipsToBounds = YES;
        [host insertSubview:glass atIndex:0];
        objc_setAssociatedObject(host, &kMiniGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    glass.frame = CGRectInset(host.bounds, 1, 2);
    [host sendSubviewToBack:glass];
    YTMULGApplyDither(host, glass, .48);
    return glass;
}

static UIImageView *YTMULoadedImage(UIView *root){NSMutableArray*q=[NSMutableArray arrayWithObject:root];while(q.count){UIView*v=q.firstObject;[q removeObjectAtIndex:0];[q addObjectsFromArray:v.subviews];if([v isKindOfClass:UIImageView.class]&&((UIImageView*)v).image)return(UIImageView*)v;}return nil;}
// The mini player now shares the olive glass surface and dither detail used by
// the pivot bar and full player. The artwork tint behind the page remains live.
static void YTMUMiniTree(UIView *root){Class image=NSClassFromString(@"YTImageView");for(UIView*v in root.subviews){if(image&&[v isKindOfClass:image]){CGFloat w=CGRectGetWidth(v.bounds),h=CGRectGetHeight(v.bounds);if(w>=38&&w<=56&&h>=38&&h<=56){UIImageView*loaded=YTMULoadedImage(v);if(loaded){v.hidden=NO;v.alpha=1;loaded.hidden=NO;loaded.alpha=1;CGFloat scale=MIN(1,40.0/MAX(1,w));v.transform=CGAffineTransformMakeScale(scale,scale);v.layer.cornerRadius=10.0/scale;v.layer.cornerCurve=kCACornerCurveContinuous;v.layer.masksToBounds=YES;}}}YTMUMiniTree(v);}}
@interface YTMMiniPlayerView:UIView@end
%hook YTMMiniPlayerView
- (void)didMoveToWindow{%orig;if(!YTMUMiniEnabled())return;self.clipsToBounds=NO;(void)YTMUMiniGlass(self);self.layer.shadowColor=UIColor.blackColor.CGColor;self.layer.shadowOpacity=.25;self.layer.shadowRadius=13;self.layer.shadowOffset=CGSizeMake(0,6);}
- (void)layoutSubviews{%orig;if(!YTMUMiniEnabled())return;self.clipsToBounds=NO;(void)YTMUMiniGlass(self);YTMUMiniTree(self);dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.35*NSEC_PER_SEC)),dispatch_get_main_queue(),^{YTMUMiniTree(self);});}
%end
