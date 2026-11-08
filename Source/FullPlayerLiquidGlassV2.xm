#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "YTMULiquidGlassPreferences.h"
#import "YTMUVisualStyle.h"
#import "LyricsShared.h"

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

// SONG-GLASS, second attempt. The first attempt here was a constant (magenta
// border, violet shadow) that read as hot pink on Midnight Future's blue and
// as purple on Suki's grey-white. The second was "neutral chrome": the
// constant moved into YTMULGGlassFill/YTMULGGlassBorder -- sage/olive, a
// yellow-green the cover still cannot match -- and the play/selected controls
// kept a hardcoded red. A blue cover got yellow glass and red buttons, which
// is the same complaint one colour palette later. NOW every player chrome
// colour derives from the sampled artwork through the YTMUSongGlass* helpers
// in YTMUVisualStyle.h: the cover's hue, clamped into a glassy band for the
// fills and lifted for the play/selected accents; the olive/sage/red
// constants survive ONLY as the no-artwork or near-grey fallback. Shadows
// stay black (a coloured shadow is the violet-magenta mistake again) and
// YTMPlayerCarouselCell's artwork ring stays white for the same reason.
// Source/QueueLiquidGlassV2.xm is the other place a song colour is wanted,
// and it samples the row's own thumbnail instead of the published mean.

static UIVisualEffectView*Glass(UIView*h,UIBlurEffectStyle style){
    UIVisualEffectView*g=objc_getAssociatedObject(h,kGlass);
    // NEUTRAL GLASS NOW: the song-derived fill never reliably matched the
    // player's own artwork backdrop (the "color is still wrong" report), so
    // the fill is transparent and the border is the same white the artwork
    // ring wears. The song accent survives exactly where it is MEANT to be
    // loud: the play button and the selected tab.
    if(!g){g=[[UIVisualEffectView alloc]initWithEffect:[UIBlurEffect effectWithStyle:style]];g.userInteractionEnabled=NO;g.backgroundColor=UIColor.clearColor;g.contentView.backgroundColor=UIColor.clearColor;g.clipsToBounds=YES;[h insertSubview:g atIndex:0];objc_setAssociatedObject(h,kGlass,g,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
    return g;
}
static void ApplyGlass(UIView*h,CGRect f,CGFloat r,CGFloat border){
    UIVisualEffectView*g=Glass(h,UIBlurEffectStyleSystemChromeMaterialDark);
    g.hidden=NO;g.frame=f;g.layer.cornerRadius=r;g.layer.cornerCurve=kCACornerCurveContinuous;
    g.layer.borderWidth=.7;g.layer.borderColor=[UIColor colorWithWhite:1 alpha:border].CGColor;
    // Per-pass work stays frame-only now: YT reuses these views across songs,
    // and the old re-tint made the next track wear the previous track's
    // colour. With a transparent fill there is nothing left to re-tint.
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
// The seek bar must be skipped as a SUBTREE, not as a node. YTMStoryboardScrubber
// does not paint itself: its track is three plain UIViews inside it (dump
// 22-38-55, song 25.49s of 3:27 = 12.3% and the "elapsed" child measured 47pt
// of the 388pt track) -- a node-only exemption still recursed into those
// children and cleared their backgroundColor, so the bar went transparent and
// the full player showed no progress bar at all. Same for a Slider.
static void ClearRoot(UIView*r,NSInteger d){if(!r||d>7)return;for(UIView*v in r.subviews){NSString*n=NSStringFromClass(v.class);if((v.tag>=7318&&v.tag<=7321)||KeepBg(n))continue;if([v isKindOfClass:UIVisualEffectView.class])continue;if([n containsString:@"Slider"]||[n containsString:@"Scrubber"])continue;if(!IsArtwork(v)&&![v isKindOfClass:UILabel.class]&&!IsButton(v)){v.backgroundColor=UIColor.clearColor;v.opaque=NO;}ClearRoot(v,d+1);}}
static void Enter(UIView*v){if([objc_getAssociatedObject(v,kAnimated)boolValue])return;objc_setAssociatedObject(v,kAnimated,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);if(UIAccessibilityIsReduceMotionEnabled())return;v.alpha=0;v.transform=CGAffineTransformMakeScale(.975,.975);[UIView animateWithDuration:.38 delay:0 usingSpringWithDamping:.84 initialSpringVelocity:.22 options:0 animations:^{v.alpha=1;v.transform=CGAffineTransformIdentity;}completion:nil];}

// YTMNowPlayingViewController's interface arrives via LyricsShared.h's stub
// header import (Headers/YTMNowPlayingViewController.h); do not re-declare it
// here -- a second full interface is a duplicate-definition error.
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
    while(queue.count){UIView*v=queue.firstObject;[queue removeObjectAtIndex:0];[queue addObjectsFromArray:v.subviews];if(IsArtwork(v)&&CGRectGetWidth(v.bounds)>=240&&CGRectGetHeight(v.bounds)>=240){v.layer.cornerRadius=28;v.layer.cornerCurve=kCACornerCurveContinuous;v.layer.masksToBounds=YES;v.layer.borderWidth=.8;v.layer.borderColor=[UIColor colorWithWhite:1 alpha:.22].CGColor;ApplyDrop(v.superview,.30,24,12);
        // LANDSCAPE CROP: in landscape the artwork mount is 16:9 while the
        // album cover is 1:1, and YT letterboxes it -- black (or the ambient
        // ambient-tint fill) bars stick out around the square art. AspectFill
        // crops instead of fitting; when the aspects already match (every
        // portrait square mount) fill and fit are identical, so this is a
        // landscape-only difference and needs no orientation check.</think><tool_call>edit<arg_key>newString</arg_key><arg_value>    while(queue.count){UIView*v=queue.firstObject;[queue removeObjectAtIndex:0];[queue addObjectsFromArray:v.subviews];if(IsArtwork(v)&&CGRectGetWidth(v.bounds)>=240&&CGRectGetHeight(v.bounds)>=240){v.layer.cornerRadius=28;v.layer.cornerCurve=kCACornerCurveContinuous;v.layer.masksToBounds=YES;v.layer.borderWidth=.8;v.layer.borderColor=[UIColor colorWithWhite:1 alpha:.22].CGColor;ApplyDrop(v.superview,.30,24,12);
        // LANDSCAPE CROP: in landscape the artwork mount is 16:9 while the
        // album cover is 1:1, and YT letterboxes the fit -- black (or YT's
        // ambient tint) bars stick out around the square art. AspectFill
        // crops instead of fitting; when the aspects already match (a
        // portrait square mount, or a real 16:9 MV still) fill and fit
        // render identically, so no orientation check is needed.
        ((UIImageView*)v).contentMode=UIViewContentModeScaleAspectFill;
        // The black base behind the card must wear the SAME radius, or its
        // own corners peek out past the artwork's clip and the card reads
        // as "image radius != base radius". cornerRadius rounds a layer's
        // background paint WITHOUT masksToBounds, so this must not set
        // clipping here -- the drop shadow lives on these views and a clip
        // would amputate it.
        for(UIView*base=v.superview;base&&base!=self.contentView&&base!=self;base=base.superview){base.layer.cornerRadius=28;base.layer.cornerCurve=kCACornerCurveContinuous;}}}
}
%end

@interface YTMNowPlayingView:UIView@end
%hook YTMNowPlayingView
- (void)layoutSubviews{
    %orig;if(!PlayerV2())return;self.backgroundColor=UIColor.clearColor;self.opaque=NO;
    for(UIView*v in self.subviews){
        if([v isKindOfClass:UILabel.class]){UILabel*l=(UILabel*)v;if(l.font.pointSize>=18)l.font=[UIFont systemFontOfSize:MAX(22,l.font.pointSize) weight:UIFontWeightBold];l.layer.shadowColor=UIColor.blackColor.CGColor;l.layer.shadowOpacity=.28;l.layer.shadowRadius=4;l.layer.shadowOffset=CGSizeMake(0,1);}
        if(IsButton(v)&&!v.hidden&&CGRectGetWidth(v.bounds)>=34){CGFloat r=MIN(20,CGRectGetHeight(v.bounds)/2);ApplyGlass(v,v.bounds,r,.24);}
        // The ACTION CHIP row (like / dislike / lyrics / comments / queue):
        // pill-shaped chips in this view get the song glass too -- the first
        // screenshot's circle wrapped the whole row and the chips stayed
        // stock dark grey while everything around them followed the cover.
        // The pill predicate (height in range, corner radius ~half height)
        // keeps plain icon buttons and labels out.
        if(!v.hidden&&CGRectGetHeight(v.bounds)>=30&&CGRectGetHeight(v.bounds)<=50){
            CGFloat cr=v.layer.cornerRadius; CGFloat h=CGRectGetHeight(v.bounds);
            // Guard, not decoration: v may already BE a glass view (recursing
            // into one would build glass-on-glass), and the LYRICS chip is
            // styled by DynamicArtworkThemeV2's YTMUStyleLyricsEntries on this
            // same view -- that hook sets the chip's backgroundColor itself,
            // so glassing it here too only sets the two passes fighting over
            // one background (clear vs song fill) every layout.
            BOOL lyricChip=(v.tag==9777||v.tag==9778||objc_getAssociatedObject(v,@selector(ytmu_isLyricsButton))!=nil);
            if(cr>=h*0.44&&![v isKindOfClass:UIVisualEffectView.class]&&!lyricChip){
                UIVisualEffectView*g=Glass(v,UIBlurEffectStyleSystemChromeMaterialDark);
                g.hidden=NO;g.frame=v.bounds;g.layer.cornerRadius=h/2;g.layer.cornerCurve=kCACornerCurveContinuous;
                g.contentView.backgroundColor=UIColor.clearColor;
                g.layer.borderColor=[UIColor colorWithWhite:1 alpha:.24].CGColor;g.layer.borderWidth=.6;
                // the glass sits AT index 0 (behind YT's own pill paint);
                // behind an OPAQUE stock background it is invisible, so
                // clear the host's own fill and let the glass carry it.
                v.backgroundColor=UIColor.clearColor;v.layer.backgroundColor=UIColor.clearColor.CGColor;
                [v sendSubviewToBack:g];
            }
        }
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
    // The RED on next/prev/pause was never this hook's glass (only Play got
    // the accent): it is YT's own icon tint -- the button tintColor inherits
    // into the template glyphs and YT's accent is red. Set the glyph ink in
    // the same pass: the song's vivid accent when there is a sampled colour,
    // plain white when there is not. tintColor reaches template subimages
    // through the normal inheritance, so one write per button covers the
    // glyph whatever view actually draws it.
    CGFloat hInk = 0, sInk = 0, bInk = 0;
    UIColor *ink = YTMUSongHue(YTMULGArtworkTint(), &hInk, &sInk, &bInk)
        ? YTMUSongAccent(1.0) : UIColor.whiteColor;
    for(UIView*v in self.subviews){if(!IsButton(v)||v.hidden||CGRectGetWidth(v.bounds)<34)continue;BOOL play=IsPlay(v);CGFloat d=MIN(CGRectGetWidth(v.bounds),CGRectGetHeight(v.bounds));ApplyGlass(v,v.bounds,d/2,play?.58:.26);UIVisualEffectView*g=objc_getAssociatedObject(v,kGlass);g.contentView.backgroundColor=play?YTMUSongAccent(.26):UIColor.clearColor;if(play)g.layer.borderColor=YTMUSongAccent(.56).CGColor;v.tintColor=ink;ApplyDrop(v,play?.30:.10,play?15:5,play?6:2);}
}
%end

@interface YTMTimeControl:UIView@end
%hook YTMTimeControl
- (void)layoutSubviews{%orig;if(!PlayerV2())return;self.backgroundColor=UIColor.clearColor;self.layer.cornerCurve=kCACornerCurveContinuous;for(UIView*v in self.subviews){NSString*n=NSStringFromClass(v.class);if([n containsString:@"Slider"]||[n containsString:@"Scrubber"]){v.layer.cornerRadius=MIN(3,CGRectGetHeight(v.bounds)/2);v.layer.cornerCurve=kCACornerCurveContinuous;}}}
%end

// NO RECOLOR: the song accent on the seek bar was reviewed out the same way
// the mini bar's was ("don't make it change color"); YT's own fill/track
// colors stand, and this hook no longer touches any backgroundColor. What the
// hook STILL owns:
//
// THE 1-STEP-PER-SECOND BAR: YT writes the elapsed fill from
// didReceivePlaybackPositionTime, which fires about once per second, so the
// fill JUMPS a second at a time. The player clock itself is continuous while
// playing (and frozen while paused -- the same source the lyrics tick reads),
// so a per-frame CADisplayLink reads it and moves the fill itself. The song
// duration is never asked for: it falls out of YT's own fill write
// (elapsed / fillRatio), cached and refreshed whenever a fill we did not write
// is seen -- which is exactly YT's ~1s pulse, a seek, or a new song. Only
// FRAMES are written here, never colors.
static char kScrubLinkKey;
static char kScrubStateKey;
// The drag knob the report asked for ("no knob, can't tell it's draggable"):
// one injected circle per scrubber, kept on top, its center riding the ELAPSED
// fill's leading edge -- the same quantity the interpolator already computes,
// so the knob costs nothing extra to track. The stock thumb plate is a
// 96x96 hidden singleton this hook deliberately does not touch; ours is
// visible chrome sized against the 2-4pt bar (12pt), not against YT's plate.
static char kScrubKnobKey;
static void YTMUApplyScrubKnob(UIView *scrub, CGPoint center) {
    UIView *knob = objc_getAssociatedObject(scrub, &kScrubKnobKey);
    if (!knob) {
        knob = [[UIView alloc] initWithFrame:CGRectZero];
        knob.layer.cornerRadius = 6.0;
        knob.layer.cornerCurve = kCACornerCurveContinuous;
        knob.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.92];
        knob.layer.borderColor = [UIColor colorWithWhite:0.0 alpha:0.25].CGColor;
        knob.layer.borderWidth = 0.5;
        knob.layer.shadowColor = UIColor.blackColor.CGColor;
        knob.layer.shadowOpacity = 0.25;
        knob.layer.shadowRadius = 3.0;
        knob.layer.shadowOffset = CGSizeMake(0, 1);
        knob.userInteractionEnabled = NO;   // scrubbing stays YT's gesture
        [scrub addSubview:knob];
        objc_setAssociatedObject(scrub, &kScrubKnobKey, knob, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (knob.hidden) { knob.hidden = NO; [scrub bringSubviewToFront:knob]; }
    if (fabs(center.x - knob.center.x) < 0.25 && fabs(center.y - knob.center.y) < 0.25) return;
    knob.center = center;
}
static BOOL YTMUInMiniPlayer(UIView *v) {
    for (UIView *u = v; u; u = u.superview) {
        if ([NSStringFromClass(u.class) isEqualToString:@"YTMMiniPlayerView"]) return YES;
    }
    return NO;
}
// Attached once per scrubber instance; (60, rate, rate) honors the 60/120
// preference live on each tick re-read.
static void YTMUAttachScrubberLink(UIView *scrub) {
    CADisplayLink *link = objc_getAssociatedObject(scrub, &kScrubLinkKey);
    if (!link) {
        link = [CADisplayLink displayLinkWithTarget:scrub
                                           selector:@selector(ytmu_scrubTick:)];
        [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        objc_setAssociatedObject(scrub, &kScrubLinkKey, link, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (@available(iOS 15.0, *)) {
        NSInteger rate = YTMUAnimFrameRate();
        link.preferredFrameRateRange = CAFrameRateRangeMake(60, rate, rate);
    }
}

@interface YTMStoryboardScrubber:UIView@end
%hook YTMStoryboardScrubber
- (void)layoutSubviews{
    %orig;
    if(!PlayerV2())return;
    if(CGRectGetHeight(self.bounds)<2.0||CGRectGetWidth(self.bounds)<100.0)return;
    // The mini bar's raised line is styled by MiniPlayerLiquidGlassV3 and must
    // stay stock-colored (the song accent there was a complaint) -- excluded
    // as a SUBTREE so this hook gives it neither the link nor the knob.
    if(YTMUInMiniPlayer(self))return;
    YTMUAttachScrubberLink(self);
}
%new
- (void)ytmu_scrubTick:(CADisplayLink *)link {
    if (!g_activePlayer) return;
    double elapsed = 0.0;
    if ([g_activePlayer respondsToSelector:@selector(currentVideoMediaTime)]) {
        elapsed = [g_activePlayer currentVideoMediaTime];
    } else if ([g_activePlayer respondsToSelector:@selector(currentMediaTime)]) {
        elapsed = [g_activePlayer currentMediaTime];
    }
    if (elapsed <= 0.0) return;
    NSMutableDictionary *state = objc_getAssociatedObject(self, &kScrubStateKey);
    if (!state) {
        state = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(self, &kScrubStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    double lastRaw = [state[@"raw"] doubleValue];
    double lastWritten = [state[@"written"] doubleValue];
    BOOL rebase = NO;
    if (fabs(elapsed - lastRaw) > 1.5) rebase = YES;  // seek or song change
    state[@"raw"] = @(elapsed);
    CGPoint knobCenter = CGRectZero.origin;
    BOOL knobFound = NO;
    for (UIView *wrap in self.subviews) {
        if ([wrap isKindOfClass:UIImageView.class]) continue;
        CGFloat trackW = CGRectGetWidth(wrap.frame);
        if (CGRectGetHeight(wrap.bounds) > 8.0 || trackW < 100.0) continue;
        for (UIView *fill in wrap.subviews) {
            if ([fill isKindOfClass:UIImageView.class]) continue;
            CGFloat th = CGRectGetHeight(fill.bounds);
            if (th < 0.5 || th > 10.0) continue;
            CGFloat fx = CGRectGetMinX(fill.frame);
            if (fx > 0.5) continue;                 // the trailing filler, not the elapsed bar
            CGFloat fw = CGRectGetWidth(fill.frame);
            CGFloat ratio = fw / trackW;            // YT's own last-written position
            // YT wrote this fill since we last did: its geometry is the truth,
            // so re-derive the duration from it. Avoid a 0-fill base (song
            // start): the first pulse with width comes within a second.
            if (fw > 1.0 && (ratio <= 1.0) &&
                (rebase ? (fabs(fw - lastWritten) > 0.6)
                        : (fabs(fw - lastWritten) > 0.3))) {
                double duration = elapsed / ratio;
                if (duration > 1.0) state[@"dur"] = @(duration);
            }
            double duration = [state[@"dur"] doubleValue];
            if (duration <= 1.0) continue;          // no reliable base yet
            CGFloat newW = (CGFloat)(trackW * (elapsed / duration));
            if (newW < 0.5) newW = 0.5;
            if (newW > trackW) newW = trackW;
            if (fabs(newW - fw) >= 0.25) {
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                fill.frame = CGRectMake(fx, CGRectGetMinY(fill.frame), newW, th);
                [CATransaction commit];
                state[@"written"] = @(newW);
            }
            // Knob rides the fill's leading edge in SCRUBBER coordinates: the
            // fill frame is in wrap space, so offset by the wrap's origin.
            CGFloat kx = CGRectGetMinX(wrap.frame) + newW;
            CGFloat ky = CGRectGetMinY(wrap.frame) + CGRectGetHeight(wrap.frame) / 2.0;
            knobCenter = CGPointMake(kx, ky);
            knobFound = YES;
        }
    }
    if (knobFound) {
        CGFloat kx = MIN(MAX(knobCenter.x, 6.0), CGRectGetWidth(self.bounds) - 6.0);
        YTMUApplyScrubKnob(self, CGPointMake(kx, knobCenter.y));
    }
}
%end

@interface YTMPlayerTabView:UIView@end
%hook YTMPlayerTabView
- (void)layoutSubviews{
    %orig;if(!PlayerV2()||CGRectIsEmpty(self.bounds))return;ApplyGlass(self,CGRectInset(self.bounds,8,4),26,.20);
    for(UIView*v in self.subviews){if(IsButton(v)&&!v.hidden){BOOL selected=(v.accessibilityTraits&UIAccessibilityTraitSelected)!=0;if(selected){ApplyGlass(v,CGRectInset(v.bounds,2,2),MIN(22,CGRectGetHeight(v.bounds)/2),.56);UIVisualEffectView*g=objc_getAssociatedObject(v,kGlass);g.contentView.backgroundColor=YTMUSongAccent(.20);g.layer.borderColor=YTMUSongAccent(.58).CGColor;}else{UIVisualEffectView*g=objc_getAssociatedObject(v,kGlass);g.hidden=YES;v.backgroundColor=UIColor.clearColor;}}}
}
%end

@interface YTMAVSwitch:UIView@end
%hook YTMAVSwitch
- (void)layoutSubviews{%orig;if(!PlayerV2()||CGRectIsEmpty(self.bounds))return;ApplyGlass(self,self.bounds,MIN(22,CGRectGetHeight(self.bounds)/2),.26);}
%end
