#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "YTMULiquidGlassPreferences.h"

static NSString *const YTMUThemeChanged = @"YTMUThemeChanged";
static UIColor *YTMUPrimaryColor;
static UIColor *YTMUSecondaryColor;
static const void *kThemeGradient = &kThemeGradient;
// Dedupe/throttle for the setImage: hook below. Both are written from whatever
// thread set the image and read only to decide whether to skip work, so a torn
// read can at worst publish once more or once less -- no invariant depends on
// them. The image is one retained artwork, not a cache.
static UIImage *YTMULastThemeImage;
static CFTimeInterval YTMULastThemeAt;

// wholeAppSongThemeEnabled / playerSongThemeEnabled, both ANDed with the
// tweak master and the iOS 13 material gate by the shared helper.
static BOOL YTMUThemePref(NSString *key) {
    return YTMULGFeatureEnabled(key);
}
static BOOL YTMUArtworkAncestor(UIView *view) {
    for (UIView *v = view; v; v = v.superview) {
        NSString *name = NSStringFromClass(v.class);
        if ([name isEqualToString:@"YTMPlayerCarouselCell"] || [name isEqualToString:@"YTMMiniPlayerView"]) return YES;
    }
    return NO;
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
static void YTMUPublishTheme(UIImage *image) {
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
    if (image == YTMULastThemeImage && now - YTMULastThemeAt < 1.0) return;
    YTMULastThemeImage = image; YTMULastThemeAt = now;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIColor *average = YTMUAverage(image); if (!average) return;
        UIColor *primary = YTMUColor(average,.18,.90), *secondary = YTMUColor(average,.02,.48);
        dispatch_async(dispatch_get_main_queue(), ^{
            // Only announce an actual change: the notification has no observer
            // in the tweak today, and a repaint on an identical colour is pure
            // layout churn on a song change.
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
    UIColor *p=YTMUPrimaryColor?:[UIColor colorWithRed:.16 green:.12 blue:.22 alpha:1];
    UIColor *s=YTMUSecondaryColor?:[UIColor colorWithWhite:.02 alpha:1];
    gradient.frame=host.bounds; gradient.startPoint=CGPointMake(.15,0); gradient.endPoint=CGPointMake(.85,1);
    gradient.colors=@[(id)[p colorWithAlphaComponent:(wholeApp?.52:.82)].CGColor,(id)[s colorWithAlphaComponent:.96].CGColor,(id)UIColor.blackColor.CGColor];
    gradient.locations=wholeApp?@[@0,@.46,@1]:@[@0,@.62,@1]; host.backgroundColor=UIColor.blackColor;
}

static void YTMUStyleLyricsEntries(UIView *root) {
    for (UIView *view in root.subviews) {
        BOOL marked = view.tag == 9777 || view.tag == 9778 || objc_getAssociatedObject(view, @selector(ytmu_isLyricsButton));
        if (marked && !view.hidden && !CGRectIsEmpty(view.bounds)) {
            view.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
            view.layer.cornerRadius = MIN(18.0, CGRectGetHeight(view.bounds) * 0.5);
            view.layer.cornerCurve = kCACornerCurveContinuous;
            view.layer.borderWidth = 0.75;
            view.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.20].CGColor;
        }
        YTMUStyleLyricsEntries(view);
    }
}

%hook UIImageView
- (void)setImage:(UIImage *)image { %orig; if (image && YTMUArtworkAncestor(self)) YTMUPublishTheme(image); }
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
