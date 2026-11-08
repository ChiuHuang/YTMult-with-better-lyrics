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
        glass.layer.cornerRadius = 18;
        glass.layer.cornerCurve = kCACornerCurveContinuous;
        glass.layer.borderWidth = .75;
        glass.clipsToBounds = YES;
        [host insertSubview:glass atIndex:0];
        objc_setAssociatedObject(host, &kMiniGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    glass.frame = CGRectInset(host.bounds, 1, 2);
    // NEUTRAL GLASS NOW: the song-derived fill was the third colour pass and
    // still never matched the big player's artwork backdrop (the "color is
    // still wrong" report), so the fill is gone and the blur carries the
    // surface. Border is the same white the artwork ring uses; the dither
    // detail below survives.
    glass.contentView.backgroundColor = UIColor.clearColor;
    glass.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.26].CGColor;
    [host sendSubviewToBack:glass];
    YTMULGApplyDither(host, glass, .48);
    return glass;
}

static UIImageView *YTMULoadedImage(UIView *root){NSMutableArray*q=[NSMutableArray arrayWithObject:root];while(q.count){UIView*v=q.firstObject;[q removeObjectAtIndex:0];[q addObjectsFromArray:v.subviews];if([v isKindOfClass:UIImageView.class]&&((UIImageView*)v).image)return(UIImageView*)v;}return nil;}
// The swipe carousel (art + title pages, the left ~332pt of the bar) paints an
// OPAQUE background of its own, and a bar-wide glass dish sent to the back of
// YTMMiniPlayerView is covered across all of it -- which is how the glass
// survived ONLY around the right-side buttons (the "trimmed out, only the
// icons kept" screenshot). Clear the collection/scroll surfaces the same way
// the V1 cleaner did, so the dish reads across the whole bar.
static void YTMUMiniClearBg(UIView *root){Class swipe=NSClassFromString(@"YTLightweightSwipeContentScrollView");for(UIView*v in root.subviews){if([v isKindOfClass:UICollectionView.class]||(swipe&&[v isKindOfClass:swipe])){v.backgroundColor=UIColor.clearColor;v.opaque=NO;}YTMUMiniClearBg(v);}}
// The mini player shares the glass surface and dither detail used by the
// pivot bar and full player, tinted by the SONG via YTMUSongGlassFill/Border
// (the artwork it displays is itself a theme publisher through
// DynamicArtworkThemeV2's mini-player path, and the song helpers fall back to
// the olive constants before the first sample). The thumbnail radius is the
// EFFECTIVE radius (radius/scale compensates the transform squash); 10pt on a
// 40pt tile was 25% -> "curved a lil too much", 7pt (17.5%) keeps the
// squircle shape at a level that does not read as a coin.
static void YTMUMiniTree(UIView *root){Class image=NSClassFromString(@"YTImageView");for(UIView*v in root.subviews){if(image&&[v isKindOfClass:image]){CGFloat w=CGRectGetWidth(v.bounds),h=CGRectGetHeight(v.bounds);if(w>=38&&w<=56&&h>=38&&h<=56){UIImageView*loaded=YTMULoadedImage(v);if(loaded){v.hidden=NO;v.alpha=1;loaded.hidden=NO;loaded.alpha=1;CGFloat scale=MIN(1,40.0/MAX(1,w));v.transform=CGAffineTransformMakeScale(scale,scale);v.layer.cornerRadius=7.0/scale;v.layer.cornerCurve=kCACornerCurveContinuous;v.layer.masksToBounds=YES;}}}YTMUMiniTree(v);}}
// The mini bar's progress line: 1pt and all-but-invisible (a review said
// "no progress bar"), and its paint wells are the same plain UIViews the full
// player's scrubber uses. Raise it to 2pt and colour it exactly like the big
// one: elapsed = the song accent, unplayed = translucent white. The
// full player's own scrubber hook skips a <2pt scrubber, so this styling
// belongs here, inside the pass that owns the bar's layout.
static void YTMUMiniScrubber(UIView *host) {
    Class scrub = NSClassFromString(@"YTMStoryboardScrubber");
    if (!scrub) return;
    for (UIView *v in host.subviews) {
        if (![v isKindOfClass:scrub]) continue;
        if (CGRectGetWidth(v.bounds) < 100.0) continue;
        CGRect f = v.frame;
        // Bottom edge of the bar, 2pt tall; the original 1pt line's y.
        v.frame = CGRectMake(CGRectGetMinX(f), CGRectGetHeight(host.bounds) - 2.0, CGRectGetWidth(f), 2.0);
        UIColor *played = YTMUSongAccent(.95);
        UIColor *track = [UIColor.whiteColor colorWithAlphaComponent:.25];
        for (UIView *wrap in v.subviews) {
            if ([wrap isKindOfClass:UIImageView.class]) continue;
            if (CGRectGetHeight(wrap.bounds) > 8.0 || CGRectGetWidth(wrap.bounds) < 100.0) continue;
            wrap.backgroundColor = track;
            for (UIView *t in wrap.subviews) {
                if ([t isKindOfClass:UIImageView.class]) continue;
                CGFloat tw = CGRectGetWidth(t.frame), th = CGRectGetHeight(t.bounds);
                if (th < 0.5 || th > 10.0) continue;
                t.backgroundColor = (CGRectGetMinX(t.frame) <= 0.5 && tw > 0.5) ? played : track;
            }
        }
    }
}

@interface YTMMiniPlayerView:UIView@end
%hook YTMMiniPlayerView
- (void)didMoveToWindow{%orig;if(!YTMUMiniEnabled())return;self.clipsToBounds=NO;(void)YTMUMiniGlass(self);self.layer.shadowColor=UIColor.blackColor.CGColor;self.layer.shadowOpacity=.25;self.layer.shadowRadius=13;self.layer.shadowOffset=CGSizeMake(0,6);}
- (void)layoutSubviews{%orig;if(!YTMUMiniEnabled())return;self.clipsToBounds=NO;(void)YTMUMiniGlass(self);YTMUMiniClearBg(self);YTMUMiniTree(self);YTMUMiniScrubber(self);dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.35*NSEC_PER_SEC)),dispatch_get_main_queue(),^{YTMUMiniClearBg(self);YTMUMiniTree(self);YTMUMiniScrubber(self);});}
%end
