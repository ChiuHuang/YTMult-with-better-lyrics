#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "YTMULiquidGlassPreferences.h"

static BOOL YTMUHomeV2Enabled(void){return YTMULGFeatureEnabled(@"homeV2Enabled");}
static void YTMURoundBrowseImages(UIView*root){Class c=NSClassFromString(@"YTImageView");for(UIView*v in root.subviews){if(c&&[v isKindOfClass:c]){CGFloat w=CGRectGetWidth(v.bounds),h=CGRectGetHeight(v.bounds);if(w>=80&&h>=80){CGFloat r=MIN(18,MIN(w,h)*.09);v.layer.cornerRadius=r;v.layer.cornerCurve=kCACornerCurveContinuous;v.layer.masksToBounds=YES;v.layer.borderWidth=.5;v.layer.borderColor=[UIColor colorWithWhite:1 alpha:.12].CGColor;}}YTMURoundBrowseImages(v);}}
@interface YTMBrowseContainerView:UIView@end
%hook YTMBrowseContainerView
-(void)layoutSubviews{%orig;if(!YTMUHomeV2Enabled())return;self.backgroundColor=UIColor.clearColor;YTMURoundBrowseImages(self);for(UIView*v in self.subviews)if([v isKindOfClass:UIScrollView.class])v.backgroundColor=UIColor.clearColor;}
%end
@interface YTMChipCloudScrollableChipView:UIView@end
%hook YTMChipCloudScrollableChipView
-(void)layoutSubviews{%orig;if(!YTMUHomeV2Enabled()||CGRectIsEmpty(self.bounds))return;self.backgroundColor=[UIColor colorWithWhite:1 alpha:.075];self.layer.cornerRadius=MIN(16,CGRectGetHeight(self.bounds)*.35);self.layer.cornerCurve=kCACornerCurveContinuous;self.layer.borderWidth=.6;self.layer.borderColor=[UIColor colorWithWhite:1 alpha:.14].CGColor;self.layer.masksToBounds=YES;}
%end
@interface YTMCarouselShelfHeaderView:UIView@end
%hook YTMCarouselShelfHeaderView
-(void)layoutSubviews{%orig;if(!YTMUHomeV2Enabled())return;self.backgroundColor=UIColor.clearColor;}
%end
@interface YTMLightweightMusicCarouselShelfCell:UICollectionViewCell@end
%hook YTMLightweightMusicCarouselShelfCell
-(void)layoutSubviews{%orig;if(!YTMUHomeV2Enabled())return;self.backgroundColor=UIColor.clearColor;self.contentView.backgroundColor=UIColor.clearColor;self.contentView.layer.cornerCurve=kCACornerCurveContinuous;}
%end
