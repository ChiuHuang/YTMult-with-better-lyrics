#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "YTMULiquidGlassPreferences.h"

static BOOL YTMUSheetsEnabled(void){return YTMULGFeatureEnabled(@"sheetsV2Enabled");}
static const void*kSheetBlur=&kSheetBlur;
static void YTMUStyleSheetRoot(UIView*root){
 if(!root||CGRectIsEmpty(root.bounds))return;
 UIVisualEffectView*b=objc_getAssociatedObject(root,kSheetBlur);
 if(!b){b=[[UIVisualEffectView alloc]initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];b.userInteractionEnabled=NO;b.clipsToBounds=YES;[root insertSubview:b atIndex:0];objc_setAssociatedObject(root,kSheetBlur,b,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
 b.frame=root.bounds;b.layer.cornerRadius=28;b.layer.cornerCurve=kCACornerCurveContinuous;b.layer.borderWidth=.75;b.layer.borderColor=[UIColor colorWithWhite:1 alpha:.18].CGColor;[root sendSubviewToBack:b];root.backgroundColor=UIColor.clearColor;root.clipsToBounds=YES;
}
@interface YTActionSheetDialogViewController:UIViewController@end
%hook YTActionSheetDialogViewController
-(void)viewDidLayoutSubviews{%orig;if(!YTMUSheetsEnabled())return;YTMUStyleSheetRoot(self.view);for(UIView*v in self.view.subviews){if([v isKindOfClass:UITableView.class]||[v isKindOfClass:UICollectionView.class]||[v isKindOfClass:UIScrollView.class]){v.backgroundColor=UIColor.clearColor;((UIScrollView*)v).showsVerticalScrollIndicator=NO;}}}
%end
@interface YTBottomSheetController:UIViewController@end
%hook YTBottomSheetController
-(void)viewDidLayoutSubviews{%orig;if(!YTMUSheetsEnabled())return;self.view.backgroundColor=UIColor.clearColor;self.view.clipsToBounds=NO;}
%end
@interface YTActionSheetCell:UICollectionViewCell@end
%hook YTActionSheetCell
-(void)layoutSubviews{%orig;if(!YTMUSheetsEnabled())return;self.backgroundColor=UIColor.clearColor;self.contentView.backgroundColor=[UIColor colorWithWhite:1 alpha:.035];self.contentView.layer.cornerRadius=14;self.contentView.layer.cornerCurve=kCACornerCurveContinuous;self.contentView.layer.masksToBounds=YES;}
%end
