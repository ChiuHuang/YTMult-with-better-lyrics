#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "YTMULiquidGlassPreferences.h"
#import "YTMUVisualStyle.h"
@interface YTMULyricsViewController:UIViewController@property(nonatomic,strong)UITableView*tableView;@property(nonatomic,strong)UIImageView*artworkImageView;@property(nonatomic,strong)UIVisualEffectView*blurView;@property(nonatomic,strong)UIView*darkOverlay;@end
// What this key controls now, and only this: the ambient artwork backdrop
// (how much of the blurred cover reads through the wash) plus the table
// chrome. The per-row "glass card" that used to live here is GONE and must
// not come back -- one rounded frosted box per lyric line read as a stack of
// notification cards, and it fought the whole point of the panel, which is
// text floating on a song-tinted backdrop. See the ownership note below for
// the values Source/LyricsSheet.x owns and this file must not touch.
static BOOL YTMULyricsV2(void){return YTMULGFeatureEnabled(@"lyricsV2Enabled");}

// OWNERSHIP SPLIT (do not "fix" this by re-adding anything below).
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
// So the backdrop strength and the table chrome stay here, and the four values
// LyricsSheet owns are left to LyricsSheet.
%hook YTMULyricsViewController
- (void)viewDidLayoutSubviews{%orig;if(!YTMULyricsV2())return;if(self.artworkImageView){self.artworkImageView.frame=self.view.bounds;self.artworkImageView.contentMode=UIViewContentModeScaleAspectFill;}self.blurView.frame=self.view.bounds;self.blurView.alpha=.82;self.darkOverlay.frame=self.view.bounds;YTMULGApplyDither(self.view,self.darkOverlay,.48);self.tableView.backgroundColor=UIColor.clearColor;self.tableView.separatorStyle=UITableViewCellSeparatorStyleNone;self.tableView.showsVerticalScrollIndicator=NO;}
%end
