#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "YTMULiquidGlassPreferences.h"
#import "Headers/YTMUBulkHook.h"

static const void *kState = &kState;
static void State(UIView *h) {
    if (!YTMULGFeatureEnabled(@"globalStatesV2Enabled") || CGRectIsEmpty(h.bounds)) return;
    UIVisualEffectView *b = objc_getAssociatedObject(h, kState);
    if (!b) {
        UIBlurEffectStyle s = UIAccessibilityIsReduceTransparencyEnabled()
            ? UIBlurEffectStyleSystemMaterialDark : UIBlurEffectStyleSystemUltraThinMaterialDark;
        b = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:s]];
        b.userInteractionEnabled = NO;
        [h insertSubview:b atIndex:0];
        objc_setAssociatedObject(h, kState, b, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    b.frame = CGRectInset(h.bounds, 20, 18);
    b.layer.cornerRadius = 24;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    b.clipsToBounds = YES;
    b.layer.borderWidth = .7;
    b.layer.borderColor = [UIColor colorWithWhite:1 alpha:.16].CGColor;
    [h sendSubviewToBack:b];
    h.backgroundColor = UIColor.clearColor;
}

// Runtime hook, not %hook in a macro: Logos expands %hook textually, so a
// macro over a class list emits the same generated symbol and the same
// objc_getClass("C") every time. See Headers/YTMUBulkHook.h.
static void YTMUStatesLayoutSubviews(id self, SEL _cmd) {
    YTMUCallOrig(self, _cmd);
    if ([self isKindOfClass:[UIView class]]) State((UIView *)self);
}

%ctor {
    YTMUBulkHook(@[@"YTMLoadingView", @"YTMEmptyStateView", @"YTMContentUnavailableView",
                   @"YTMRestrictedContentView", @"YTMOfflineView",
                   @"YTMAuthenticationRequiredView", @"YTMServerErrorView",
                   @"YTMUInstrumentalLyricsView", @"YTMULyricsUnavailableView",
                   @"YTMUUnsupportedVersionView", @"YTMURemoteDisabledView",
                   @"YTMRefreshErrorView"],
                  @selector(layoutSubviews),
                  (IMP)YTMUStatesLayoutSubviews);
}
