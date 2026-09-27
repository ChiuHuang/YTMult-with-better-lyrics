#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "YTMULiquidGlassPreferences.h"
static BOOL YTMUFullEnabled(void){return YTMULGFeatureEnabled(@"fullPlayerV2Enabled");}
static const void*kHeaderGroups=&kHeaderGroups;static const void*kControlBlur=&kControlBlur;
static UIVisualEffectView*YTMUGlass(UIView*h){UIVisualEffectView*b=[[UIVisualEffectView alloc]initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];b.userInteractionEnabled=NO;b.clipsToBounds=YES;b.layer.borderWidth=.75;b.layer.borderColor=[UIColor colorWithWhite:1 alpha:.2].CGColor;[h insertSubview:b atIndex:0];return b;}
@interface YTMPlayerHeaderView:UIView@end
%hook YTMPlayerHeaderView
- (void)layoutSubviews{%orig;if(!YTMUFullEnabled()||CGRectGetWidth(self.bounds)<300)return;NSArray*g=objc_getAssociatedObject(self,kHeaderGroups);if(!g){g=@[YTMUGlass(self),YTMUGlass(self),YTMUGlass(self)];objc_setAssociatedObject(self,kHeaderGroups,g,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}NSArray*frames=@[[NSValue valueWithCGRect:CGRectMake(12,0,40,40)],[NSValue valueWithCGRect:CGRectMake(166,2,96,36)],[NSValue valueWithCGRect:CGRectMake(316,0,104,40)]];for(NSUInteger i=0;i<3;i++){UIVisualEffectView*b=g[i];b.frame=[frames[i]CGRectValue];b.layer.cornerRadius=CGRectGetHeight(b.bounds)/2;b.layer.cornerCurve=kCACornerCurveContinuous;}for(UIView*v in self.subviews)if([v isKindOfClass:UIVisualEffectView.class]&&![g containsObject:v]&&CGRectGetWidth(v.frame)>250)v.hidden=YES;self.backgroundColor=UIColor.clearColor;}
%end
@interface YTMPlayerCarouselCell:UICollectionViewCell@end
%hook YTMPlayerCarouselCell
- (void)layoutSubviews{%orig;if(!YTMUFullEnabled()||CGRectGetWidth(self.bounds)<300)return;Class c=NSClassFromString(@"YTImageView");for(UIView*v in self.contentView.subviews)if(c&&[v isKindOfClass:c]&&CGRectGetWidth(v.bounds)>=300){self.contentView.layer.shadowColor=UIColor.blackColor.CGColor;self.contentView.layer.shadowOpacity=.3;self.contentView.layer.shadowRadius=22;self.contentView.layer.shadowOffset=CGSizeMake(0,12);v.layer.cornerRadius=28;v.layer.cornerCurve=kCACornerCurveContinuous;v.layer.masksToBounds=YES;v.layer.borderWidth=.75;v.layer.borderColor=[UIColor colorWithWhite:1 alpha:.17].CGColor;}}
%end
@interface YTMPlayerControlsView:UIView@end
%hook YTMPlayerControlsView
- (void)layoutSubviews{%orig;if(!YTMUFullEnabled()||CGRectGetWidth(self.bounds)<360)return;for(UIView*v in self.subviews){if(v.hidden||CGRectGetWidth(v.bounds)<36)continue;NSString*n=NSStringFromClass(v.class);if(![n containsString:@"Button"])continue;UIVisualEffectView*b=objc_getAssociatedObject(v,kControlBlur);if(!b){b=YTMUGlass(v);objc_setAssociatedObject(v,kControlBlur,b,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}b.frame=v.bounds;b.layer.cornerRadius=MIN(CGRectGetWidth(v.bounds),CGRectGetHeight(v.bounds))/2;[v sendSubviewToBack:b];v.backgroundColor=UIColor.clearColor;}}
%end
