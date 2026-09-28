#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "YTMULiquidGlassPreferences.h"
#import "Headers/YTMUBulkHook.h"

static const void *kCard = &kCard;
static void Card(UIView *h, CGFloat r) {
    UIVisualEffectView *b = objc_getAssociatedObject(h, kCard);
    if (!b) {
        b = [[UIVisualEffectView alloc] initWithEffect:
             [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
        b.userInteractionEnabled = NO;
        [h insertSubview:b atIndex:0];
        objc_setAssociatedObject(h, kCard, b, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    b.frame = CGRectInset(h.bounds, 5, 3);
    b.layer.cornerRadius = r;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    b.clipsToBounds = YES;
    b.layer.borderWidth = .65;
    b.layer.borderColor = [UIColor colorWithWhite:1 alpha:.14].CGColor;
    [h sendSubviewToBack:b];
    h.backgroundColor = UIColor.clearColor;
}

static void ClearTree(UIView *r, NSInteger d) {
    if (!r || d > 8) return;
    Class c = NSClassFromString(@"YTImageView");
    for (UIView *v in r.subviews) {
        if ([v isKindOfClass:UIScrollView.class]) v.backgroundColor = UIColor.clearColor;
        if (c && [v isKindOfClass:c]) {
            CGFloat w = CGRectGetWidth(v.bounds), h = CGRectGetHeight(v.bounds);
            if (w >= 44 && h >= 44) {
                v.layer.cornerRadius = MIN(18, MIN(w, h) * .14);
                v.layer.cornerCurve = kCACornerCurveContinuous;
                v.layer.masksToBounds = YES;
            }
            continue;
        }
        ClearTree(v, d + 1);
    }
}

// The feature key differs per controller, so it is recorded at hook time and
// read back from `self` inside the one shared replacement.
static void Screen(UIViewController *c, NSString *k) {
    if (!YTMULGFeatureEnabled(k) || !c.view.window) return;
    c.view.backgroundColor = UIColor.clearColor;
    ClearTree(c.view, 0);
}

static void YTMUEntityViewDidLayoutSubviews(id self, SEL _cmd) {
    YTMUCallOrig(self, _cmd);
    if (![self isKindOfClass:[UIViewController class]]) return;
    Screen((UIViewController *)self, YTMUBulkHookKeyFor(self));
}

static void YTMUSearchBoxLayoutSubviews(id self, SEL _cmd) {
    YTMUCallOrig(self, _cmd);
    if (YTMULGFeatureEnabled(@"searchV2Enabled") && [self isKindOfClass:[UIView class]])
        Card((UIView *)self, MIN(22, CGRectGetHeight([(UIView *)self bounds]) / 2));
}

static void YTMUEntityHeaderLayoutSubviews(id self, SEL _cmd) {
    YTMUCallOrig(self, _cmd);
    if (![self isKindOfClass:[UIView class]]) return;
    if (YTMULGFeatureEnabled(@"entityPagesV2Enabled")) {
        UIView *v = (UIView *)self;
        v.backgroundColor = UIColor.clearColor;
        ClearTree(v, 0);
    }
}

static void YTMUPlaylistReorderLayoutSubviews(id self, SEL _cmd) {
    YTMUCallOrig(self, _cmd);
    if (![self isKindOfClass:[UIView class]]) return;
    UIView *v = (UIView *)self;
    if (!YTMULGFeatureEnabled(@"playlistV2Enabled") || !v.superview) return;
    CGRect f = v.frame;
    CGFloat t = CGRectGetWidth(v.superview.bounds) - CGRectGetMaxX(f);
    if (t > 14) { f.origin.x += MIN(18, t - 10); v.frame = f; }
}

%ctor {
    NSDictionary *controllers = @{
        @"YTMSearchViewController": @"searchV2Enabled",
        @"YTMSearchResultsViewController": @"searchV2Enabled",
        @"YTMLibraryViewController": @"libraryV2Enabled",
        @"YTMLibraryTabViewController": @"libraryV2Enabled",
        @"YTMAlbumViewController": @"albumV2Enabled",
        @"YTMArtistViewController": @"artistV2Enabled",
        @"YTMPlaylistViewController": @"playlistV2Enabled",
        @"YTMDownloadsViewController": @"downloadsV2Enabled",
        @"YTMDownloadManagerViewController": @"downloadsV2Enabled",
    };
    [controllers enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *key, BOOL *stop) {
        YTMUBulkHookSetKey(name, key);
    }];
    YTMUBulkHook(controllers.allKeys, @selector(viewDidLayoutSubviews),
                 (IMP)YTMUEntityViewDidLayoutSubviews);

    YTMUBulkHook(@[@"YTMSearchBoxView"], @selector(layoutSubviews),
                 (IMP)YTMUSearchBoxLayoutSubviews);
    YTMUBulkHook(@[@"YTMEntityHeaderView"], @selector(layoutSubviews),
                 (IMP)YTMUEntityHeaderLayoutSubviews);
    YTMUBulkHook(@[@"YTMPlaylistReorderView"], @selector(layoutSubviews),
                 (IMP)YTMUPlaylistReorderLayoutSubviews);
}
