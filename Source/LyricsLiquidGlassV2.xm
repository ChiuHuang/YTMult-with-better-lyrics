#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "YTMULiquidGlassPreferences.h"
@interface YTMULyricsCell:UITableViewCell@property(nonatomic,strong)UILabel*lyricLabel;@property(nonatomic,strong)UILabel*transLabel;@property(nonatomic,strong)UILabel*wipeLabel;@end
@interface YTMULyricsViewController:UIViewController@property(nonatomic,strong)UITableView*tableView;@property(nonatomic,strong)UIImageView*artworkImageView;@property(nonatomic,strong)UIVisualEffectView*blurView;@property(nonatomic,strong)UIView*darkOverlay;@end
static BOOL YTMULyricsV2(void){return YTMULGFeatureEnabled(@"lyricsV2Enabled");}
static const void*kLyricGlass=&kLyricGlass;
static void YTMULyricCard(UIView*h,CGRect f,CGFloat r){UIVisualEffectView*b=objc_getAssociatedObject(h,kLyricGlass);if(!b){b=[[UIVisualEffectView alloc]initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];b.userInteractionEnabled=NO;[h insertSubview:b atIndex:0];objc_setAssociatedObject(h,kLyricGlass,b,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}b.frame=f;b.layer.cornerRadius=r;b.layer.cornerCurve=kCACornerCurveContinuous;b.clipsToBounds=YES;b.layer.borderWidth=.6;b.layer.borderColor=[UIColor colorWithWhite:1 alpha:.14].CGColor;[h sendSubviewToBack:b];}
// OWNERSHIP SPLIT (do not "fix" this by re-adding the lines below).
// This hook runs AFTER %orig, so every property it touches WINS over
// Source/LyricsSheet.x, which tunes the same properties on every layout pass.
// The V2 zip hardcoded all of them, which silently undid three explicit
// requests: the dark-overlay alphas 0.22/0.40 (LyricsSheet.x:818/3085
// YTMUBgOverlayColor), the artwork-derived backdrop (LyricsSheet.x:800/1856/
// 3084 YTMUBgBaseColor) and the per-row bottom padding (LyricsSheet.x:832 +
// the bottomPad recompute at 2738/2769). It also dimmed artworkImageView to
// .46 while YTMULyricInk derives the lyric ink from the artwork's own mean
// colour, so the tint was computed against a backdrop the user never sees.
//
// So the glass card (the actual V2 look) plus the table chrome stay here, and
// the four values LyricsSheet owns are left to LyricsSheet.
%hook YTMULyricsViewController
- (void)viewDidLayoutSubviews{%orig;if(!YTMULyricsV2())return;if(self.artworkImageView){self.artworkImageView.frame=self.view.bounds;self.artworkImageView.contentMode=UIViewContentModeScaleAspectFill;}self.blurView.frame=self.view.bounds;self.blurView.alpha=.82;self.darkOverlay.frame=self.view.bounds;self.tableView.backgroundColor=UIColor.clearColor;self.tableView.separatorStyle=UITableViewCellSeparatorStyleNone;self.tableView.showsVerticalScrollIndicator=NO;}
%end
%hook YTMULyricsCell
- (void)layoutSubviews{%orig;if(!YTMULyricsV2()||CGRectGetWidth(self.bounds)<240)return;self.backgroundColor=UIColor.clearColor;self.contentView.backgroundColor=UIColor.clearColor;YTMULyricCard(self.contentView,CGRectInset(self.contentView.bounds,12,4),20);self.lyricLabel.numberOfLines=0;self.transLabel.numberOfLines=0;self.wipeLabel.numberOfLines=0;}
%end
