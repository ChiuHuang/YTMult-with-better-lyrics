#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "YTMULiquidGlassPreferences.h"
static const void*kCard=&kCard;
static void Card(UIView*h,CGFloat r){UIVisualEffectView*b=objc_getAssociatedObject(h,kCard);if(!b){b=[[UIVisualEffectView alloc]initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];b.userInteractionEnabled=NO;[h insertSubview:b atIndex:0];objc_setAssociatedObject(h,kCard,b,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}b.frame=CGRectInset(h.bounds,5,3);b.layer.cornerRadius=r;b.layer.cornerCurve=kCACornerCurveContinuous;b.clipsToBounds=YES;b.layer.borderWidth=.65;b.layer.borderColor=[UIColor colorWithWhite:1 alpha:.14].CGColor;[h sendSubviewToBack:b];h.backgroundColor=UIColor.clearColor;}
static void ClearTree(UIView*r,NSInteger d){if(!r||d>8)return;Class c=NSClassFromString(@"YTImageView");for(UIView*v in r.subviews){if([v isKindOfClass:UIScrollView.class])v.backgroundColor=UIColor.clearColor;if(c&&[v isKindOfClass:c]){CGFloat w=CGRectGetWidth(v.bounds),h=CGRectGetHeight(v.bounds);if(w>=44&&h>=44){v.layer.cornerRadius=MIN(18,MIN(w,h)*.14);v.layer.cornerCurve=kCACornerCurveContinuous;v.layer.masksToBounds=YES;}continue;}ClearTree(v,d+1);}}
static void Screen(UIViewController*c,NSString*k){if(!YTMULGFeatureEnabled(k)||!c.view.window)return;c.view.backgroundColor=UIColor.clearColor;ClearTree(c.view,0);}
#define VC(C,K) @interface C:UIViewController@end %hook C - (void)viewDidLayoutSubviews{%orig;Screen(self,K);}%end
VC(YTMSearchViewController,@"searchV2Enabled") VC(YTMSearchResultsViewController,@"searchV2Enabled") VC(YTMLibraryViewController,@"libraryV2Enabled") VC(YTMLibraryTabViewController,@"libraryV2Enabled") VC(YTMAlbumViewController,@"albumV2Enabled") VC(YTMArtistViewController,@"artistV2Enabled") VC(YTMPlaylistViewController,@"playlistV2Enabled") VC(YTMDownloadsViewController,@"downloadsV2Enabled") VC(YTMDownloadManagerViewController,@"downloadsV2Enabled")
#undef VC
@interface YTMSearchBoxView:UIView@end
%hook YTMSearchBoxView
- (void)layoutSubviews{%orig;if(YTMULGFeatureEnabled(@"searchV2Enabled")){Card(self,MIN(22,CGRectGetHeight(self.bounds)/2));}}
%end
@interface YTMEntityHeaderView:UIView@end
%hook YTMEntityHeaderView
- (void)layoutSubviews{%orig;if(YTMULGFeatureEnabled(@"entityPagesV2Enabled")){self.backgroundColor=UIColor.clearColor;ClearTree(self,0);}}
%end
@interface YTMPlaylistReorderView:UIView@end
%hook YTMPlaylistReorderView
- (void)layoutSubviews{%orig;if(!YTMULGFeatureEnabled(@"playlistV2Enabled")||!self.superview)return;CGRect f=self.frame;CGFloat t=CGRectGetWidth(self.superview.bounds)-CGRectGetMaxX(f);if(t>14){f.origin.x+=MIN(18,t-10);self.frame=f;}}
%end
