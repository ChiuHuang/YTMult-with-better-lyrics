#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "YTMULiquidGlassPreferences.h"

static NSString *const YTMUThemeChanged = @"YTMUThemeChanged";
static UIColor *YTMUPrimaryColor;
static UIColor *YTMUSecondaryColor;
static const void *kThemeGradient = &kThemeGradient;

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
    if (!image || image.size.width < 80 || image.size.height < 80) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIColor *average = YTMUAverage(image); if (!average) return;
        UIColor *primary = YTMUColor(average,.18,.90), *secondary = YTMUColor(average,.02,.48);
        dispatch_async(dispatch_get_main_queue(), ^{ YTMUPrimaryColor=primary; YTMUSecondaryColor=secondary;
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
- (void)layoutSubviews { %orig; YTMUApplyTheme(self,NO); YTMUStyleLyricsEntries(self); }
%end
@interface YTMContentViewController:UIViewController@end
%hook YTMContentViewController
- (void)viewDidLayoutSubviews { %orig; YTMUApplyTheme(self.view,YES); }
%end
