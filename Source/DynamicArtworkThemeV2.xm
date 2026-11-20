#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "YTMULiquidGlassPreferences.h"
#import "YTMUVisualStyle.h"

static NSString *const YTMUThemeChanged = @"YTMUThemeChanged";
static UIColor *YTMUPrimaryColor;
static UIColor *YTMUSecondaryColor;
static UIColor *YTMURawArtworkAverage;
static char kThemeGradientKey;
static const void *kThemeGradient = &kThemeGradientKey;
// Dedupe/throttle for the setImage: hook below. Both are written from whatever
// thread set the image and read only to decide whether to skip work, so a torn
// read can at worst publish once more or once less -- no invariant depends on
// them. The image is one retained artwork, not a cache.
static UIImage *YTMULastThemeImage;
static UIImage *YTMULastRequestedImage;
static CFTimeInterval YTMULastRequestedAt;
// The mini player uses a CROPPED thumbnail (mostly the blue dress); the full
// player's carousel shows the whole cover (gold frame included, warmer). Both
// setImage: calls reach the same publish path, so a late mini thumbnail used
// to repaint the full player with the crop's average. Rank the sources: a
// full-player page always outranks the mini thumbnail.
static NSInteger YTMULastRequestedRank = -1;
static NSInteger YTMUAppliedRank = -1;
static UIImage *YTMUAppliedImage;

extern "C" UIImage *YTMULGCurrentArtwork(void) { return YTMULastThemeImage; }
extern "C" UIColor *YTMULGCurrentArtworkMean(void) { return YTMURawArtworkAverage; }
// The CLEAN artwork colour: the same 1x1 sample YTMURawArtworkAverage holds,
// exposed under a name that says "use this as the song tint". Kept separate
// from YTMULGCurrentArtworkMean so every olive-blended reader is greppable --
// the point of this accessor is that its readers DON'T blend.
extern "C" UIColor *YTMULGArtworkTint(void) { return YTMURawArtworkAverage; }

// wholeAppSongThemeEnabled / playerSongThemeEnabled, both ANDed with the
// tweak master and the iOS 13 material gate by the shared helper.
static BOOL YTMUThemePref(NSString *key) {
    return YTMULGFeatureEnabled(key);
}
static CGFloat YTMUCarouselCellScore(UICollectionView *cv, UICollectionViewCell *cell) {
    CGRect r = [cv convertRect:cell.frame fromView:cell.superview ?: cv];
    return fabs(CGRectGetMidX(r) - CGRectGetMidX(cv.bounds)) / MAX(1.0, r.size.width)
         + fabs(CGRectGetMidY(r) - CGRectGetMidY(cv.bounds)) / MAX(1.0, r.size.height);
}
// The carousel publishes NEIGHBOUR pages too: every Up-next card is its own
// YTMPlayerCarouselCell, its artwork is a related video's MV still. When the
// player sheet is pulled down the viewport gets short, and a neighbour can
// pass a 50%-visible test while the real page no longer does -- the backdrop
// then wears the neighbour's palette. Pick the cell closest to the visible
// centre instead; only that one may publish, whatever the sheet height.
static BOOL YTMUCarouselPageCurrent(UIView *view) {
    UICollectionViewCell *cell = nil;
    UICollectionView *cv = nil;
    for (UIView *v = view; v; v = v.superview) {
        if (!cv && [v isKindOfClass:[UICollectionView class]]) cv = (UICollectionView *)v;
        if ([v isKindOfClass:[UICollectionViewCell class]]) { cell = (UICollectionViewCell *)v; break; }
    }
    if (!cell) return YES;
    if (!cv) return YES;
    if (CGRectIsEmpty(cell.frame) || cell.frame.size.width < 1.0) return YES;
    CGRect cellInCv = [cv convertRect:cell.frame fromView:cell.superview ?: cv];
    if (CGRectIsEmpty(CGRectIntersection(cellInCv, cv.bounds))) return NO;
    CGFloat score = YTMUCarouselCellScore(cv, cell);
    UICollectionViewCell *closest = cell;
    for (UICollectionViewCell *other in cv.visibleCells) {
        if (other == cell) continue;
        CGRect r = [cv convertRect:other.frame fromView:other.superview ?: cv];
        if (CGRectIsEmpty(CGRectIntersection(r, cv.bounds))) continue;
        CGFloat s = YTMUCarouselCellScore(cv, other);
        if (s < score) { score = s; closest = other; }
    }
    return closest == cell && score <= 0.75;
}
static BOOL YTMUCarouselPageJudged(UIView *view) {
    for (UIView *v = view; v; v = v.superview) {
        if ([v isKindOfClass:[UICollectionViewCell class]]) {
            UICollectionViewCell *cell = (UICollectionViewCell *)v;
            return !CGRectIsEmpty(cell.frame) && cell.frame.size.width >= 1.0;
        }
    }
    return YES; // no carousel cell (mini player) -- always judgeable
}
// 2 = full-player carousel page, 1 = mini thumbnail, -1 = not our artwork.
static NSInteger YTMUThemeSourceRank(UIView *view) {
    for (UIView *v = view; v; v = v.superview) {
        NSString *name = NSStringFromClass(v.class);
        if ([name isEqualToString:@"YTMPlayerCarouselCell"]) {
            return YTMUCarouselPageCurrent(view) ? 2 : -1;
        }
        if ([name isEqualToString:@"YTMMiniPlayerView"]) return 1;
    }
    return -1;
}
// A hidden or offscreen image view must never repaint the visible player.
static BOOL YTMUThemeViewVisible(UIView *view) {
    if (!view.window || view.hidden || view.alpha < 0.05) return NO;
    CGRect r = [view convertRect:view.bounds toView:nil];
    return !CGRectIsEmpty(r) && CGRectGetWidth(r) >= 0.5 && CGRectGetHeight(r) >= 0.5;
}
static UIColor *YTMUAverage(UIImage *image) {
    if (!image.CGImage) return nil;
    unsigned char pixel[4] = {0};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixel, 1, 1, 8, 4, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!context) return nil;
    CGContextDrawImage(context, CGRectMake(0, 0, 1, 1), image.CGImage);
    CGContextRelease(context);
    return [UIColor colorWithRed:pixel[0]/255.0 green:pixel[1]/255.0 blue:pixel[2]/255.0 alpha:1.0];
}
static UIColor *YTMUColor(UIColor *color, CGFloat saturation, CGFloat brightness) {
    CGFloat h=0,s=0,b=0,a=0;
    if (![color getHue:&h saturation:&s brightness:&b alpha:&a]) return color;
    return [UIColor colorWithHue:h saturation:MIN(.82,MAX(.30,s+saturation)) brightness:MIN(.78,MAX(.20,b*brightness)) alpha:1];
}
static void YTMUPublishTheme(UIImage *image, NSInteger sourceRank) {
    if (sourceRank < 1) return;
    // 24pt, not 80: the mini player's thumbnail is a 40pt image (YT loads it at
    // screen scale, so UIImage.size is 40 points, not 120) and it is the ONLY
    // artwork on screen while the user browses the home tab. The old 80pt
    // floor threw it away, so YTMUPrimaryColor stayed nil everywhere except
    // the open full player -- which is exactly why the full player was tinted
    // and the whole app was not. The ancestor check below, not the size, is
    // what keeps this to real cover art.
    if (!image || image.size.width < 24 || image.size.height < 24) return;
    // This runs from a %hook on UIImageView -setImage:, so it is on the path of
    // EVERY image the app ever sets. Three reasons to bail before the bitmap
    // draw: both theme switches are off (the only reader, YTMUApplyTheme,
    // returns early without them); this exact artwork was just published (YT
    // re-sets the same thumbnail on every relayout); or a burst of images is
    // still in flight, in which case only the last one is worth sampling.
    if (!YTMUThemePref(@"wholeAppSongThemeEnabled") && !YTMUThemePref(@"playerSongThemeEnabled")) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (image == YTMULastRequestedImage && sourceRank <= YTMULastRequestedRank && now - YTMULastRequestedAt < 1.0) return;
    YTMULastRequestedImage = image; YTMULastRequestedAt = now; YTMULastRequestedRank = sourceRank;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIColor *average = YTMUAverage(image); if (!average) return;
        // No sage/olive blend on the artwork-derived pair any more: 22-30% of
        // those constants is the yellow cast a blue cover carried into the
        // whole player gradient. YTMUColor's own clamps (sat .30-.82,
        // brightness .20-.78) are the only shaping; a near-grey cover keeps
        // its grey because YTMUSongHue's .12 floor gates the CHROME helpers,
        // not this gradient.
        UIColor *primary = YTMUColor(average, .18, .90);
        UIColor *secondary = YTMUColor(average, .02, .48);
        dispatch_async(dispatch_get_main_queue(), ^{
            // A lower-ranked source (mini thumbnail) must never overwrite the
            // full player's cover, even when its conversion finishes later.
            // A new image pointer starts a fresh song's ranking.
            if (image != YTMUAppliedImage) {
                YTMUAppliedImage = image;
                YTMUAppliedRank = -1;
            }
            if (sourceRank < YTMUAppliedRank) return;
            YTMUAppliedRank = sourceRank;
            // YTMULGCurrentArtwork() feeds the blurred artwork backdrop.
            // Publishing it at REQUEST time let a lower-ranked thumbnail that
            // lost the palette race still replace the cover in that backdrop.
            YTMULastThemeImage = image;
            // Only announce an actual change: the notification has no observer
            // in the tweak today, and a repaint on an identical colour is pure
            // layout churn on a song change.
            YTMURawArtworkAverage = average;
            if ([YTMUPrimaryColor isEqual:primary]) return;
            YTMUPrimaryColor=primary; YTMUSecondaryColor=secondary;
            [[NSNotificationCenter defaultCenter] postNotificationName:YTMUThemeChanged object:nil]; });
    });
}
static void YTMUApplyTheme(UIView *host, BOOL wholeApp) {
    if (!YTMUThemePref(wholeApp ? @"wholeAppSongThemeEnabled" : @"playerSongThemeEnabled")) return;
    CAGradientLayer *gradient = objc_getAssociatedObject(host,kThemeGradient);
    if (!gradient) { gradient=[CAGradientLayer layer]; [host.layer insertSublayer:gradient atIndex:0];
        objc_setAssociatedObject(host,kThemeGradient,gradient,OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    // Neutral dark when no artwork has been sampled yet. This used to be
    // (.16,.12,.22) -- a violet -- the one thing on this surface that can be
    // wrong for EVERY cover at once: it is what shows on the player between the
    // player opening and the thumbnail landing, so the whole screen washes
    // purple before it has any colour to match. Neutral reads as "no colour
    // yet" and is replaced a frame later by the real one.
    UIColor *p=YTMUPrimaryColor?:[UIColor colorWithWhite:.11 alpha:1];
    UIColor *s=YTMUSecondaryColor?:[UIColor colorWithWhite:.02 alpha:1];
    gradient.frame=host.bounds; gradient.startPoint=CGPointMake(.15,0); gradient.endPoint=CGPointMake(.85,1);
    gradient.colors=@[(id)[p colorWithAlphaComponent:(wholeApp?.52:.82)].CGColor,(id)[s colorWithAlphaComponent:.96].CGColor,(id)UIColor.blackColor.CGColor];
    gradient.locations=wholeApp?@[@0,@.46,@1]:@[@0,@.62,@1]; host.backgroundColor=UIColor.blackColor;
    CGFloat r = 0, g = 0, b = 0;
    [YTMURawArtworkAverage getRed:&r green:&g blue:&b alpha:NULL];
    BOOL light = YTMURawArtworkAverage && (0.299 * r + 0.587 * g + 0.114 * b) > .55;
    YTMULGApplyArtworkBackdrop(host, light ? .22 : .40,
        light ? UIBlurEffectStyleLight : UIBlurEffectStyleDark);
}

static void YTMUStyleLyricsEntries(UIView *root) {
    for (UIView *view in root.subviews) {
        BOOL marked = view.tag == 9777 || view.tag == 9778 || objc_getAssociatedObject(view, @selector(ytmu_isLyricsButton));
        if (marked && !view.hidden && !CGRectIsEmpty(view.bounds)) {
            // NEUTRAL, not song glass: the chips sit straight on the artwork
            // backdrop and a song-hued fill competed with the cover (the same
            // "glass colour is wrong" report). They must stay readable, so a
            // translucent black backs the white ink instead of the song hue.
            view.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:.42];
            view.layer.cornerRadius = MIN(18.0, CGRectGetHeight(view.bounds) * 0.5);
            view.layer.cornerCurve = kCACornerCurveContinuous;
            view.layer.borderWidth = 0.0;
        }
        YTMUStyleLyricsEntries(view);
    }
}

%hook UIImageView
- (void)setImage:(UIImage *)image {
    %orig;
    if (!image) return;
    NSInteger rank = YTMUThemeSourceRank(self);
    if (rank < 1) return;
    // A cell image set before layout (or before the view joins a window) used
    // to publish immediately. Defer one main-queue turn, then re-check
    // visibility and the page geometry -- never publish on "unknown".
    if (!YTMUThemeViewVisible(self) || !YTMUCarouselPageJudged(self)) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || !YTMUThemeViewVisible(strongSelf)) return;
            NSInteger deferredRank = YTMUThemeSourceRank(strongSelf);
            if (deferredRank >= 1) YTMUPublishTheme(image, deferredRank);
        });
        return;
    }
    YTMUPublishTheme(image, rank);
}
%end
@interface YTMNowPlayingView:UIView@end
%hook YTMNowPlayingView
- (void)layoutSubviews { %orig; YTMUStyleLyricsEntries(self); }
%end
// The song tint is painted on the whole PLAYER, not on the metadata block.
// It used to go on YTMNowPlayingView, which is only the title/artist/chips
// strip, so it rendered as a hard-edged rectangle floating in the middle of a
// black screen with the transport row sitting on flat black below it. The
// colours and the three stops are unchanged -- only the host grew, so the same
// gradient now runs from behind the album art down past the transport
// controls.
//
// YTMNowPlayingView must therefore NOT be a theme host any more: its own
// opaque backgroundColor would cover the controller's gradient and put the
// rectangle straight back. Only the chip styling stays behind, on the same
// host it always had -- it must NOT move to the controller, because
// -ytmuPlaceLyricsBesideThreeDot sets that chip's cornerRadius to a full pill
// on every pass, and the two would start fighting over views that used to be
// out of each other's reach.
@interface YTMNowPlayingViewController:UIViewController@end
%hook YTMNowPlayingViewController
- (void)viewDidLayoutSubviews { %orig; if (CGRectGetWidth(self.view.bounds) < 300) return; YTMUApplyTheme(self.view, NO); }
%end
@interface YTMContentViewController:UIViewController@end
%hook YTMContentViewController
- (void)viewDidLayoutSubviews { %orig; YTMUApplyTheme(self.view,YES); }
%end
