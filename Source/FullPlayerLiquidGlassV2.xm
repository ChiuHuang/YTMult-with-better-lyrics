#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "YTMULiquidGlassPreferences.h"

static BOOL PlayerV2(void){return YTMULGFeatureEnabled(@"fullPlayerV2Enabled");}
static const void*kGlass=&kGlass,*kTint=&kTint,*kAnimated=&kAnimated;

static UIVisualEffectView*Glass(UIView*h,UIBlurEffectStyle style){
    UIVisualEffectView*g=objc_getAssociatedObject(h,kGlass);
    if(!g){g=[[UIVisualEffectView alloc]initWithEffect:[UIBlurEffect effectWithStyle:style]];g.userInteractionEnabled=NO;g.backgroundColor=UIColor.clearColor;g.contentView.backgroundColor=UIColor.clearColor;g.clipsToBounds=YES;[h insertSubview:g atIndex:0];objc_setAssociatedObject(h,kGlass,g,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
    return g;
}
static void ApplyGlass(UIView*h,CGRect f,CGFloat r,CGFloat border){UIVisualEffectView*g=Glass(h,UIBlurEffectStyleSystemUltraThinMaterialDark);g.hidden=NO;g.frame=f;g.layer.cornerRadius=r;g.layer.cornerCurve=kCACornerCurveContinuous;g.layer.borderWidth=.7;g.layer.borderColor=[UIColor colorWithRed:1 green:.62 blue:.94 alpha:border].CGColor;[h sendSubviewToBack:g];h.backgroundColor=UIColor.clearColor;h.layer.backgroundColor=UIColor.clearColor.CGColor;}
static BOOL IsButton(UIView*v){return [v isKindOfClass:UIButton.class]||[NSStringFromClass(v.class) containsString:@"Button"];}
static BOOL IsPlay(UIView*v){NSString*s=[NSString stringWithFormat:@"%@ %@",v.accessibilityLabel?:@"",v.accessibilityIdentifier?:@""].lowercaseString;return [s containsString:@"play"]||[s containsString:@"pause"];}
static BOOL IsArtwork(UIView*v){Class c=NSClassFromString(@"YTImageView");return (c&&[v isKindOfClass:c])||([v isKindOfClass:UIImageView.class]&&((UIImageView*)v).image);}
static BOOL KeepBg(NSString*n){return [n hasPrefix:@"YTMGradientScrim"]||[n hasPrefix:@"YTPlayerView"]||[n hasPrefix:@"MLHAMIO"]||[n hasPrefix:@"YTMVideoOverlay"]||[n hasPrefix:@"MPV"]||[n hasPrefix:@"YTVolumeBar"]||[n hasPrefix:@"YTVRCaptionOverlay"];}
static void ClearRoot(UIView*r,NSInteger d){if(!r||d>7)return;for(UIView*v in r.subviews){NSString*n=NSStringFromClass(v.class);if(KeepBg(n))continue;if([v isKindOfClass:UIVisualEffectView.class])continue;if(!IsArtwork(v)&&![v isKindOfClass:UILabel.class]&&!IsButton(v)&&![n containsString:@"Slider"]&&![n containsString:@"Scrubber"]){v.backgroundColor=UIColor.clearColor;v.opaque=NO;}ClearRoot(v,d+1);}}
static void Enter(UIView*v){if([objc_getAssociatedObject(v,kAnimated)boolValue])return;objc_setAssociatedObject(v,kAnimated,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);if(UIAccessibilityIsReduceMotionEnabled())return;v.alpha=0;v.transform=CGAffineTransformMakeScale(.975,.975);[UIView animateWithDuration:.38 delay:0 usingSpringWithDamping:.84 initialSpringVelocity:.22 options:0 animations:^{v.alpha=1;v.transform=CGAffineTransformIdentity;}completion:nil];}

@interface YTMNowPlayingViewController:UIViewController@end
%hook YTMNowPlayingViewController
- (void)viewDidAppear:(BOOL)a{%orig;if(PlayerV2())Enter(self.view);}
- (void)viewDidLayoutSubviews{%orig;if(!PlayerV2()||CGRectGetWidth(self.view.bounds)<300)return;self.view.backgroundColor=UIColor.clearColor;self.view.opaque=NO;ClearRoot(self.view,0);}
%end

@interface YTMPlayerHeaderView:UIView@end
%hook YTMPlayerHeaderView
- (void)layoutSubviews{
    %orig;if(!PlayerV2()||CGRectGetWidth(self.bounds)<300)return;
    self.backgroundColor=UIColor.clearColor;self.opaque=NO;
    NSMutableArray*buttons=[NSMutableArray array];for(UIView*v in self.subviews)if(IsButton(v)&&!v.hidden&&CGRectGetWidth(v.bounds)>=30)[buttons addObject:v];
    for(UIView*v in buttons){CGFloat r=MIN(22,MIN(CGRectGetWidth(v.bounds),CGRectGetHeight(v.bounds))/2);ApplyGlass(v,v.bounds,r,.28);v.layer.shadowColor=UIColor.blackColor.CGColor;v.layer.shadowOpacity=.16;v.layer.shadowRadius=7;v.layer.shadowOffset=CGSizeMake(0,3);}
    // Audio / Video stays one grouped glass switch when present.
    for(UIView*v in self.subviews){NSString*n=NSStringFromClass(v.class);if([n containsString:@"Switch"]||[n containsString:@"Segment"]){ApplyGlass(v,v.bounds,MIN(23,CGRectGetHeight(v.bounds)/2),.30);}}
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
    while(queue.count){UIView*v=queue.firstObject;[queue removeObjectAtIndex:0];[queue addObjectsFromArray:v.subviews];if(IsArtwork(v)&&CGRectGetWidth(v.bounds)>=240&&CGRectGetHeight(v.bounds)>=240){v.layer.cornerRadius=28;v.layer.cornerCurve=kCACornerCurveContinuous;v.layer.masksToBounds=YES;v.layer.borderWidth=.8;v.layer.borderColor=[UIColor colorWithRed:1 green:.63 blue:.95 alpha:.34].CGColor;v.superview.layer.shadowColor=[UIColor colorWithRed:.54 green:.20 blue:.78 alpha:1].CGColor;v.superview.layer.shadowOpacity=.32;v.superview.layer.shadowRadius=24;v.superview.layer.shadowOffset=CGSizeMake(0,12);}}
}
%end

@interface YTMNowPlayingView:UIView@end
%hook YTMNowPlayingView
- (void)layoutSubviews{
    %orig;if(!PlayerV2())return;self.backgroundColor=UIColor.clearColor;self.opaque=NO;
    for(UIView*v in self.subviews){
        if([v isKindOfClass:UILabel.class]){UILabel*l=(UILabel*)v;if(l.font.pointSize>=18)l.font=[UIFont systemFontOfSize:MAX(22,l.font.pointSize) weight:UIFontWeightBold];l.layer.shadowColor=UIColor.blackColor.CGColor;l.layer.shadowOpacity=.28;l.layer.shadowRadius=4;l.layer.shadowOffset=CGSizeMake(0,1);}
        if(IsButton(v)&&!v.hidden&&CGRectGetWidth(v.bounds)>=34){CGFloat r=MIN(20,CGRectGetHeight(v.bounds)/2);ApplyGlass(v,v.bounds,r,.26);}
    }
}
%end

@interface YTMPlayerControlsView:UIView@end
%hook YTMPlayerControlsView
- (void)layoutSubviews{
    %orig;if(!PlayerV2()||CGRectGetWidth(self.bounds)<360)return;self.backgroundColor=UIColor.clearColor;
    for(UIView*v in self.subviews){if(!IsButton(v)||v.hidden||CGRectGetWidth(v.bounds)<34)continue;BOOL play=IsPlay(v);CGFloat d=MIN(CGRectGetWidth(v.bounds),CGRectGetHeight(v.bounds));CGFloat r=d/2;ApplyGlass(v,v.bounds,r,play?.48:.24);v.layer.shadowColor=[UIColor colorWithRed:.72 green:.28 blue:1 alpha:1].CGColor;v.layer.shadowOpacity=play?.34:.10;v.layer.shadowRadius=play?15:5;v.layer.shadowOffset=CGSizeMake(0,play?6:2);v.transform=(play&&!UIAccessibilityIsReduceMotionEnabled())?CGAffineTransformMakeScale(1.08,1.08):CGAffineTransformIdentity;}
}
%end

@interface YTMTimeControl:UIView@end
%hook YTMTimeControl
- (void)layoutSubviews{%orig;if(!PlayerV2())return;self.backgroundColor=UIColor.clearColor;self.layer.cornerCurve=kCACornerCurveContinuous;for(UIView*v in self.subviews){NSString*n=NSStringFromClass(v.class);if([n containsString:@"Slider"]||[n containsString:@"Scrubber"]){v.layer.cornerRadius=MIN(3,CGRectGetHeight(v.bounds)/2);v.layer.cornerCurve=kCACornerCurveContinuous;}}}
%end

@interface YTMPlayerTabView:UIView@end
%hook YTMPlayerTabView
- (void)layoutSubviews{
    %orig;if(!PlayerV2()||CGRectIsEmpty(self.bounds))return;ApplyGlass(self,CGRectInset(self.bounds,8,4),26,.24);
    for(UIView*v in self.subviews){if(IsButton(v)&&!v.hidden){BOOL selected=(v.accessibilityTraits&UIAccessibilityTraitSelected)!=0;if(selected){ApplyGlass(v,CGRectInset(v.bounds,2,2),MIN(22,CGRectGetHeight(v.bounds)/2),.50);}else{UIVisualEffectView*g=objc_getAssociatedObject(v,kGlass);g.hidden=YES;v.backgroundColor=UIColor.clearColor;}}}
}
%end

@interface YTMAVSwitch:UIView@end
%hook YTMAVSwitch
- (void)layoutSubviews{%orig;if(!PlayerV2()||CGRectIsEmpty(self.bounds))return;ApplyGlass(self,self.bounds,MIN(22,CGRectGetHeight(self.bounds)/2),.32);}
%end
