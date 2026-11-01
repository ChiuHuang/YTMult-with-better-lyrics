#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "YTMULiquidGlassPreferences.h"
// No feature key of its own: this only takes the shadows off surfaces the V2
// glass leaves behind, so it follows the tweak master plus the material gate.
static BOOL YTMUVideoCompatEnabled(void){return YTMULGTweakEnabled()&&YTMULGAvailable();}

static char kYTMUVideoOverlayLastBounds;
// The carousel's VIDEO page: the overlay drops into the SAME mount as the
// 1:1 album cover, so the card keeps the square shape and border of the
// cover while the 16:9 content sits letterboxed inside it -- black bands
// above and below (the "borders are still from the 1:1 image" report). Three
// fixes, all on the overlay itself so the ring MOVES with the video instead
// of living on a static host behind it:
//   1. the card look -- 28pt continuous radius, clipped, thin white ring the
//      artwork card wears;
//   2. the content is COVER-SCALED into the card (skip when it already
//      covers: 16:9 content in a real 16:9 mount is a no-op), which removes
//      the bands by cropping, never by stretching;
//   3. a fade-in when the overlay first gets a frame, so the video move
//      reads as a transition instead of a pop-in. The border riding the same
//      layer keeps it glued to the overlay during every subsequent move.
// The square-ish gate (aspect within 1.35) keeps landscape/fullscreen video
// surfaces out of the cover-card styling.
static void YTMUVideoOverlayCropContent(UIView *host) {
    if (CGRectIsEmpty(host.bounds)) return;
    CGFloat w = CGRectGetWidth(host.bounds), h = CGRectGetHeight(host.bounds);
    UIView *content = nil;
    CGFloat best = 0;
    for (UIView *v in host.subviews) {
        if ([NSStringFromClass(v.class) isEqualToString:@"YTMPlayerControlsView"]) continue;
        if ([v isKindOfClass:UIImageView.class] || [v isKindOfClass:UILabel.class]) continue;
        CGFloat a = CGRectGetWidth(v.frame) * CGRectGetHeight(v.frame);
        if (a > best) { best = a; content = v; }
    }
    if (!content) return;
    CGFloat cw = CGRectGetWidth(content.frame), ch = CGRectGetHeight(content.frame);
    if (cw < 1.0 || ch < 1.0) return;
    CGFloat over = (w * h) / (cw * ch);
    if (over < 1.08) {
        // The largest child already covers the card -- the letterbox (if any)
        // lives INSIDE it, recursing one level so a black wrapper holding
        // the smaller video view still gets its content grown.
        YTMUVideoOverlayCropContent(content);
        return;
    }
    CGFloat sc = MAX(w / cw, h / ch);
    content.frame = CGRectMake(0, 0, cw * sc, ch * sc);
    content.center = CGPointMake(w / 2.0, h / 2.0);
}

@interface YTMVideoOverlayView:UIView@end
%hook YTMVideoOverlayView
-(void)layoutSubviews{
    %orig;
    if(!YTMUVideoCompatEnabled())return;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    for(UIView*v in self.subviews){
        if([NSStringFromClass(v.class)isEqualToString:@"YTMPlayerControlsView"]&&CGRectGetWidth(v.bounds)<360){v.backgroundColor=UIColor.clearColor;v.layer.shadowOpacity=0;}
    }
    CGFloat w = CGRectGetWidth(self.bounds), h = CGRectGetHeight(self.bounds);
    if (w < 200.0 || h < 200.0) return;
    CGFloat ratio = (w > h) ? w / h : h / w;
    if (ratio > 1.35) return;
    self.layer.cornerRadius = 28.0;
    self.layer.masksToBounds = YES;
    self.layer.borderWidth = 0.8;
    self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.22].CGColor;
    YTMUVideoOverlayCropContent(self);
    NSValue *prev = objc_getAssociatedObject(self, &kYTMUVideoOverlayLastBounds);
    BOOL newlyAppeared = (!prev || CGRectIsEmpty([prev CGRectValue])) && !CGRectIsEmpty(self.bounds);
    objc_setAssociatedObject(self, &kYTMUVideoOverlayLastBounds,
        [NSValue valueWithCGRect:self.bounds], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (newlyAppeared) {
        CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
        fade.fromValue = @0.30;
        fade.toValue = @1.0;
        fade.duration = 0.32;
        fade.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [self.layer addAnimation:fade forKey:@"ytmuVideoFadeIn"];
    }
}
%end
@interface YTInlinePlayerDoubleTapArrowsView:UIView@end
%hook YTInlinePlayerDoubleTapArrowsView
-(void)layoutSubviews{%orig;if(!YTMUVideoCompatEnabled())return;self.backgroundColor=UIColor.clearColor;}
%end
