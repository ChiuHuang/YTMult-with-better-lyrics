#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "YTMULiquidGlassPreferences.h"

static BOOL PlayerV2(void){return YTMULGFeatureEnabled(@"fullPlayerV2Enabled");}
// The associated-object keys. They must be the ADDRESS of something with static
// storage duration, and each key must be a DISTINCT address -- two variables
// initialized from their own names would be two addresses holding the same
// value, which is not what a unique key is. A `static const void *kGlass =
// &kGlass;` cannot even compile: forming `void **` out of a `const void *` is
// an error, and the whole file died at :7 before a single hook was installed.
static char kGlassKey;
static char kAnimatedKey;
static const void *kGlass = &kGlassKey;
static const void *kAnimated = &kAnimatedKey;

// NEUTRAL GLASS. This file used to hardcode a magenta border (1,.62,.94) and a
// violet shadow (.54,.20,.78 / .72,.28,1) on the artwork card, every header
// capsule, every transport button and the tab bar. A constant cannot match a
// cover: it read as hot pink on Midnight Future's blue, as purple on Suki's
// grey-white and as green on the Jack U collages, and that mismatch -- not the
// blur -- is what made the player look broken. Nothing here derives a colour
// from the artwork any more, because the decision (user, this session) is that
// the chrome stays neutral and lets the cover be the only colour on screen:
// border = white at a per-surface alpha, every shadow = black.
// Source/QueueLiquidGlassV2.xm is the one place a song colour is wanted, and it
// samples the row's own thumbnail instead of picking a constant.

static UIVisualEffectView*Glass(UIView*h,UIBlurEffectStyle style){
    UIVisualEffectView*g=objc_getAssociatedObject(h,kGlass);
    if(!g){g=[[UIVisualEffectView alloc]initWithEffect:[UIBlurEffect effectWithStyle:style]];g.userInteractionEnabled=NO;g.backgroundColor=UIColor.clearColor;g.contentView.backgroundColor=UIColor.clearColor;g.clipsToBounds=YES;[h insertSubview:g atIndex:0];objc_setAssociatedObject(h,kGlass,g,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
    return g;
}
static void ApplyGlass(UIView*h,CGRect f,CGFloat r,CGFloat border){
    UIVisualEffectView*g=Glass(h,UIBlurEffectStyleSystemUltraThinMaterialDark);
    g.hidden=NO;g.frame=f;g.layer.cornerRadius=r;g.layer.cornerCurve=kCACornerCurveContinuous;
    g.layer.borderWidth=.7;g.layer.borderColor=[UIColor colorWithWhite:1 alpha:border].CGColor;
    [h sendSubviewToBack:g];h.backgroundColor=UIColor.clearColor;h.layer.backgroundColor=UIColor.clearColor.CGColor;
}
// A real circle, tap target untouched. The header icons are NOT all square --
// the cast button's bounds are wider than they are tall -- so MIN(w,h)/2 on its
// own renders a pill, and the old MIN(22,...) cap turned every icon bigger than
// 44pt into a rounded RECTANGLE. That cap is what made the cast button a
// square. The blur is instead a centred square of side MIN(w,h,44): same frame,
// same hit area, circle on screen. Capped at 44 so a wide button cannot grow a
// circle bigger than the header it sits in.
static void ApplyCircle(UIView*h,CGFloat border){
    CGFloat side=MIN(MIN(CGRectGetWidth(h.bounds),CGRectGetHeight(h.bounds)),44.0);
    if(side<8)return;// laid out but not sized yet: a 0x0 blur is not a circle
    ApplyGlass(h,CGRectMake((CGRectGetWidth(h.bounds)-side)/2.0,(CGRectGetHeight(h.bounds)-side)/2.0,side,side),side/2.0,border);
}
static void ApplyDrop(UIView*v,CGFloat opacity,CGFloat radius,CGFloat dy){
    v.layer.shadowColor=UIColor.blackColor.CGColor;v.layer.shadowOpacity=opacity;v.layer.shadowRadius=radius;v.layer.shadowOffset=CGSizeMake(0,dy);
}
static BOOL IsButton(UIView*v){return [v isKindOfClass:UIButton.class]||[NSStringFromClass(v.class) containsString:@"Button"];}
static BOOL IsPlay(UIView*v){NSString*s=[NSString stringWithFormat:@"%@ %@",v.accessibilityLabel?:@"",v.accessibilityIdentifier?:@""].lowercaseString;return [s containsString:@"play"]||[s containsString:@"pause"];}
static BOOL IsArtwork(UIView*v){Class c=NSClassFromString(@"YTImageView");return (c&&[v isKindOfClass:c])||([v isKindOfClass:UIImageView.class]&&((UIImageView*)v).image);}
static BOOL KeepBg(NSString*n){return [n hasPrefix:@"YTMGradientScrim"]||[n hasPrefix:@"YTPlayerView"]||[n hasPrefix:@"MLHAMIO"]||[n hasPrefix:@"YTMVideoOverlay"]||[n hasPrefix:@"MPV"]||[n hasPrefix:@"YTVolumeBar"]||[n hasPrefix:@"YTVRCaptionOverlay"];}
static void ClearRoot(UIView*r,NSInteger d){if(!r||d>7)return;for(UIView*v in r.subviews){NSString*n=NSStringFromClass(v.class);if(KeepBg(n))continue;if([v isKindOfClass:UIVisualEffectView.class])continue;if(!IsArtwork(v)&&![v isKindOfClass:UILabel.class]&&!IsButton(v)&&![n containsString:@"Slider"]&&![n containsString:@"Scrubber"]){v.backgroundColor=UIColor.clearColor;v.opaque=NO;}ClearRoot(v,d+1);}}
static void Enter(UIView*v){if([objc_getAssociatedObject(v,kAnimated)boolValue])return;objc_setAssociatedObject(v,kAnimated,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);if(UIAccessibilityIsReduceMotionEnabled())return;v.alpha=0;v.transform=CGAffineTransformMakeScale(.975,.975);[UIView animateWithDuration:.38 delay:0 usingSpringWithDamping:.84 initialSpringVelocity:.22 options:0 animations:^{v.alpha=1;v.transform=CGAffineTransformIdentity;}completion:nil];}

@interface YTMNowPlayingViewController:UIViewController@end
%hook YTMNowPlayingViewController
- (void)viewDidAppear:(BOOL)a{%orig;if(PlayerV2())Enter(self.view);}
- (void)viewDidLayoutSubviews{%orig;if(!PlayerV2()||CGRectGetWidth(self.view.bounds)<300)return;self.view.backgroundColor=UIColor.clearColor;[self.view setOpaque:NO];ClearRoot(self.view,0);}
%end

@interface YTMPlayerHeaderView:UIView@end
%hook YTMPlayerHeaderView
- (void)layoutSubviews{
    %orig;if(!PlayerV2()||CGRectGetWidth(self.bounds)<300)return;
    self.backgroundColor=UIColor.clearColor;self.opaque=NO;
    NSMutableArray*buttons=[NSMutableArray array];for(UIView*v in self.subviews)if(IsButton(v)&&!v.hidden&&CGRectGetWidth(v.bounds)>=30)[buttons addObject:v];
    for(UIView*v in buttons){ApplyCircle(v,.26);ApplyDrop(v,.20,8,3);}
    // Audio / Video stays one grouped glass switch when present: it is a
    // two-up control, so a pill is the right shape there, not a circle.
    for(UIView*v in self.subviews){NSString*n=NSStringFromClass(v.class);if([n containsString:@"Switch"]||[n containsString:@"Segment"]){ApplyGlass(v,v.bounds,MIN(23,CGRectGetHeight(v.bounds)/2),.26);}}
}
%end

@interface YTMPlayerCarouselCell:UICollectionViewCell@end
%hook YTMPlayerCarouselCell
- (void)prepareForReuse{%orig;self.contentView.alpha=1;self.contentView.transform=CGAffineTransformIdentity;[self setNeedsLayout];}
- (void)didMoveToWindow{%orig;[self setNeedsLayout];if(self.window)[self layoutIfNeeded];}
- (void)layoutSubviews{
    %orig;if(!PlayerV2()||CGRectGetWidth(self.bounds)<300)return;
    self.backgroundColor=UIColor.clearColor;self.contentView.backgroundColor=UIColor.clearColor;self.contentView.opaque=NO;self.clipsToBounds=NO;
    NSMutableArray*queue=[NSMutableArray arrayWithObject:self.contentView];
    while(queue.count){UIView*v=queue.firstObject;[queue removeObjectAtIndex:0];[queue addObjectsFromArray:v.subviews];if(IsArtwork(v)&&CGRectGetWidth(v.bounds)>=240&&CGRectGetHeight(v.bounds)>=240){v.layer.cornerRadius=28;v.layer.cornerCurve=kCACornerCurveContinuous;v.layer.masksToBounds=YES;v.layer.borderWidth=.8;v.layer.borderColor=[UIColor colorWithWhite:1 alpha:.22].CGColor;ApplyDrop(v.superview,.30,24,12);}}
}
%end

@interface YTMNowPlayingView:UIView@end
%hook YTMNowPlayingView
- (void)layoutSubviews{
    %orig;if(!PlayerV2())return;self.backgroundColor=UIColor.clearColor;self.opaque=NO;
    for(UIView*v in self.subviews){
        if([v isKindOfClass:UILabel.class]){UILabel*l=(UILabel*)v;if(l.font.pointSize>=18)l.font=[UIFont systemFontOfSize:MAX(22,l.font.pointSize) weight:UIFontWeightBold];l.layer.shadowColor=UIColor.blackColor.CGColor;l.layer.shadowOpacity=.28;l.layer.shadowRadius=4;l.layer.shadowOffset=CGSizeMake(0,1);}
        if(IsButton(v)&&!v.hidden&&CGRectGetWidth(v.bounds)>=34){CGFloat r=MIN(20,CGRectGetHeight(v.bounds)/2);ApplyGlass(v,v.bounds,r,.24);}
    }
}
%end

@interface YTMPlayerControlsView:UIView@end
%hook YTMPlayerControlsView
- (void)layoutSubviews{
    %orig;if(!PlayerV2()||CGRectGetWidth(self.bounds)<360)return;self.backgroundColor=UIColor.clearColor;
    // Play/pause is separated from the rest by a brighter edge and a deeper
    // drop, not by size: the old 1.08x transform was rewritten on every layout
    // pass (YT animates this button itself, so it fought the tap animation) and
    // YT already draws it larger than its siblings.
    for(UIView*v in self.subviews){if(!IsButton(v)||v.hidden||CGRectGetWidth(v.bounds)<34)continue;BOOL play=IsPlay(v);CGFloat d=MIN(CGRectGetWidth(v.bounds),CGRectGetHeight(v.bounds));ApplyGlass(v,v.bounds,d/2,play?.34:.20);ApplyDrop(v,play?.30:.10,play?15:5,play?6:2);}
}
%end

@interface YTMTimeControl:UIView@end
%hook YTMTimeControl
- (void)layoutSubviews{%orig;if(!PlayerV2())return;self.backgroundColor=UIColor.clearColor;self.layer.cornerCurve=kCACornerCurveContinuous;for(UIView*v in self.subviews){NSString*n=NSStringFromClass(v.class);if([n containsString:@"Slider"]||[n containsString:@"Scrubber"]){v.layer.cornerRadius=MIN(3,CGRectGetHeight(v.bounds)/2);v.layer.cornerCurve=kCACornerCurveContinuous;}}}
%end

@interface YTMPlayerTabView:UIView@end
%hook YTMPlayerTabView
- (void)layoutSubviews{
    %orig;if(!PlayerV2()||CGRectIsEmpty(self.bounds))return;ApplyGlass(self,CGRectInset(self.bounds,8,4),26,.20);
    for(UIView*v in self.subviews){if(IsButton(v)&&!v.hidden){BOOL selected=(v.accessibilityTraits&UIAccessibilityTraitSelected)!=0;if(selected){ApplyGlass(v,CGRectInset(v.bounds,2,2),MIN(22,CGRectGetHeight(v.bounds)/2),.40);}else{UIVisualEffectView*g=objc_getAssociatedObject(v,kGlass);g.hidden=YES;v.backgroundColor=UIColor.clearColor;}}}
}
%end

@interface YTMAVSwitch:UIView@end
%hook YTMAVSwitch
- (void)layoutSubviews{%orig;if(!PlayerV2()||CGRectIsEmpty(self.bounds))return;ApplyGlass(self,self.bounds,MIN(22,CGRectGetHeight(self.bounds)/2),.26);}
%end
