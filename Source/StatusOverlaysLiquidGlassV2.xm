#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "YTMULiquidGlassPreferences.h"
#import "Headers/YTMUBulkHook.h"

static const void *kStatus = &kStatus;
static void Status(UIView *h, CGFloat r) {
    if (!YTMULGFeatureEnabled(@"statusOverlaysV2Enabled") || CGRectIsEmpty(h.bounds)) return;
    UIVisualEffectView *b = objc_getAssociatedObject(h, kStatus);
    if (!b) {
        b = [[UIVisualEffectView alloc] initWithEffect:
             [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
        b.userInteractionEnabled = NO;
        [h insertSubview:b atIndex:0];
        objc_setAssociatedObject(h, kStatus, b, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    b.frame = h.bounds;
    b.layer.cornerRadius = r;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    b.clipsToBounds = YES;
    b.layer.borderWidth = .7;
    b.layer.borderColor = [UIColor colorWithWhite:1 alpha:.17].CGColor;
    [h sendSubviewToBack:b];
    h.backgroundColor = UIColor.clearColor;
}

// The radius differs per class, so it is recorded at hook time and read back
// from `self` inside the one shared replacement.
static void YTMUStatusLayoutSubviews(id self, SEL _cmd) {
    YTMUCallOrig(self, _cmd);
    if (![self isKindOfClass:[UIView class]]) return;
    NSString *r = YTMUBulkHookKeyFor(self);
    Status((UIView *)self, r ? r.doubleValue : 20.0);
}

%ctor {
    NSDictionary *radii = @{@"YTMToastView": @18, @"YTAlertView": @24,
                            @"YTMProgressHUDView": @20,
                            @"YTMULyricsProviderLoadingView": @20,
                            @"YTMOfflineStatusView": @18, @"YTMNetworkErrorView": @24};
    [radii enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSNumber *r, BOOL *stop) {
        YTMUBulkHookSetKey(name, r.stringValue);
    }];
    YTMUBulkHook(radii.allKeys, @selector(layoutSubviews), (IMP)YTMUStatusLayoutSubviews);
}
