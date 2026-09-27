#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "YTMULiquidGlassPreferences.h"
static BOOL YTMUQueueV2(void){return YTMULGFeatureEnabled(@"queueV2Enabled");}
static const void*kQueueGlass=&kQueueGlass;
static void YTMUQueueCard(UIView*h){UIVisualEffectView*b=objc_getAssociatedObject(h,kQueueGlass);if(!b){b=[[UIVisualEffectView alloc]initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];b.userInteractionEnabled=NO;[h insertSubview:b atIndex:0];objc_setAssociatedObject(h,kQueueGlass,b,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}b.frame=CGRectInset(h.bounds,4,3);b.layer.cornerRadius=16;b.layer.cornerCurve=kCACornerCurveContinuous;b.clipsToBounds=YES;b.layer.borderWidth=.6;b.layer.borderColor=[UIColor colorWithWhite:1 alpha:.12].CGColor;[h sendSubviewToBack:b];}
@interface YTMQueueCollectionViewController:UIViewController@end
%hook YTMQueueCollectionViewController
- (void)viewDidLayoutSubviews{%orig;if(!YTMUQueueV2())return;self.view.backgroundColor=UIColor.clearColor;for(UIView*v in self.view.subviews)if([v isKindOfClass:UICollectionView.class]){v.backgroundColor=UIColor.clearColor;((UICollectionView*)v).contentInset=UIEdgeInsetsMake(12,12,92,12);}}
%end
@interface YTMPlaylistPanelVideoCell:UICollectionViewCell@end
%hook YTMPlaylistPanelVideoCell
- (void)layoutSubviews{%orig;if(!YTMUQueueV2()||CGRectGetWidth(self.bounds)<340||CGRectGetHeight(self.bounds)<60)return;self.backgroundColor=UIColor.clearColor;self.contentView.backgroundColor=UIColor.clearColor;YTMUQueueCard(self.contentView);for(UIView*v in self.contentView.subviews)if([NSStringFromClass(v.class)isEqualToString:@"YTImageView"]&&CGRectGetWidth(v.bounds)<=64){v.layer.cornerRadius=10;v.layer.cornerCurve=kCACornerCurveContinuous;v.layer.masksToBounds=YES;}}
%end
