#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "YTMULiquidGlassPreferences.h"
#import "YTMUVisualStyle.h"
#import "Headers/YTMUBulkHook.h"

static char kCardKey;
static char kSearchSeparatorKey;
static void YTMUStyleSearchPage(UIView *root, BOOL resultsPage);

static void Card(UIView *h, CGFloat r) {
    UIVisualEffectView *b = objc_getAssociatedObject(h, &kCardKey);
    if (!b) {
        b = [[UIVisualEffectView alloc] initWithEffect:
             [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
        b.userInteractionEnabled = NO;
        b.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        b.contentView.backgroundColor = YTMULGGlassFill();
        [h insertSubview:b atIndex:0];
        objc_setAssociatedObject(h, &kCardKey, b, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    b.frame = CGRectInset(h.bounds, 5, 3);
    b.layer.cornerRadius = r;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    b.clipsToBounds = YES;
    b.layer.borderWidth = .75;
    b.layer.borderColor = YTMULGGlassBorder(.38).CGColor;
    [h sendSubviewToBack:b];
    h.backgroundColor = UIColor.clearColor;
    YTMULGApplyDither(h, b, .30);
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
    if ([k isEqualToString:@"searchV2Enabled"]) {
        BOOL resultsPage = [NSStringFromClass(c.class) containsString:@"Results"];
        YTMUStyleSearchPage(c.view, resultsPage);
    }
}

// Match spoti.pw's dark search composition while keeping YTM's native browse
// content intact: red-accented glass field, bright text, and restrained list
// separators. Spotify's source uses Encore cells; YTM is styled by its observed
// controllers and UIKit types instead.
static void YTMUStyleSearchText(UIView *root) {
    if ([root isKindOfClass:UILabel.class]) {
        ((UILabel *)root).textColor = UIColor.whiteColor;
    } else if ([root isKindOfClass:UITextField.class]) {
        UITextField *field = (UITextField *)root;
        field.textColor = UIColor.whiteColor;
        field.tintColor = YTMULGAccentRed();
        if (field.placeholder.length) {
            field.attributedPlaceholder = [[NSAttributedString alloc] initWithString:field.placeholder
                attributes:@{NSForegroundColorAttributeName:[UIColor colorWithWhite:1 alpha:.58]}];
        }
    } else if ([root isKindOfClass:UIImageView.class]) {
        ((UIImageView *)root).tintColor = UIColor.whiteColor;
    } else if ([root isKindOfClass:UISegmentedControl.class]) {
        UISegmentedControl *segments = (UISegmentedControl *)root;
        segments.tintColor = UIColor.whiteColor;
        if (@available(iOS 13.0, *)) segments.selectedSegmentTintColor = [YTMULGAccentRed() colorWithAlphaComponent:.26];
    } else if ([root isKindOfClass:UIButton.class] &&
               ((root.accessibilityTraits & UIAccessibilityTraitSelected) != 0 || ((UIButton *)root).selected)) {
        root.tintColor = YTMULGAccentRed();
        root.backgroundColor = [YTMULGAccentRed() colorWithAlphaComponent:.16];
        root.layer.cornerRadius = MIN(18, CGRectGetHeight(root.bounds) * .5);
        root.layer.cornerCurve = kCACornerCurveContinuous;
        root.layer.borderWidth = .65;
        root.layer.borderColor = [YTMULGAccentRed() colorWithAlphaComponent:.40].CGColor;
    }
}

static void YTMUStyleSearchResultsRow(UIView *row) {
    row.backgroundColor = UIColor.clearColor;
    if ([row isKindOfClass:UITableViewCell.class]) {
        UITableViewCell *cell = (UITableViewCell *)row;
        cell.contentView.backgroundColor = UIColor.clearColor;
        cell.backgroundView.backgroundColor = UIColor.clearColor;
        cell.selectedBackgroundView.backgroundColor = [YTMULGAccentRed() colorWithAlphaComponent:.10];
    } else if ([row isKindOfClass:UICollectionViewCell.class]) {
        ((UICollectionViewCell *)row).contentView.backgroundColor = UIColor.clearColor;
        return;
    }

    UIView *separator = objc_getAssociatedObject(row, &kSearchSeparatorKey);
    if (!separator) {
        separator = [UIView new];
        separator.userInteractionEnabled = NO;
        separator.backgroundColor = [UIColor colorWithWhite:1 alpha:.12];
        separator.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
        objc_setAssociatedObject(row, &kSearchSeparatorKey, separator, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [row addSubview:separator];
    }
    CGFloat scale = UIScreen.mainScreen.scale ?: 2;
    separator.frame = CGRectMake(16, MAX(0, CGRectGetHeight(row.bounds) - 1 / scale),
                                 MAX(0, CGRectGetWidth(row.bounds) - 16), 1 / scale);
}

static void YTMUStyleSearchPage(UIView *root, BOOL resultsPage) {
    if (!root) return;
    YTMUStyleSearchText(root);
    for (UIView *v in root.subviews) {
        if ([v isKindOfClass:UITableView.class]) {
            UITableView *table = (UITableView *)v;
            table.backgroundColor = UIColor.clearColor;
            table.separatorColor = [UIColor colorWithWhite:1 alpha:.12];
            table.separatorInset = UIEdgeInsetsMake(0, 16, 0, 16);
            table.showsVerticalScrollIndicator = NO;
        } else if ([v isKindOfClass:UICollectionView.class]) {
            ((UICollectionView *)v).backgroundColor = UIColor.clearColor;
            ((UICollectionView *)v).showsVerticalScrollIndicator = NO;
        }

        if (resultsPage && ([v isKindOfClass:UITableViewCell.class] || [v isKindOfClass:UICollectionViewCell.class])) {
            YTMUStyleSearchResultsRow(v);
        }
        YTMUStyleSearchPage(v, resultsPage);
    }
}

static void YTMUEntityViewDidLayoutSubviews(id self, SEL _cmd) {
    YTMUCallOrig(self, _cmd);
    if (![self isKindOfClass:[UIViewController class]]) return;
    Screen((UIViewController *)self, YTMUBulkHookKeyFor(self));
}

static void YTMUSearchBoxLayoutSubviews(id self, SEL _cmd) {
    YTMUCallOrig(self, _cmd);
    if (YTMULGFeatureEnabled(@"searchV2Enabled") && [self isKindOfClass:[UIView class]]) {
        UIView *searchBar = (UIView *)self;
        UIView *searchBox = nil;
        for (UIView *child in searchBar.subviews) {
            if ([child isKindOfClass:UIView.class] && CGRectGetHeight(child.bounds) >= 40 && CGRectGetHeight(child.bounds) <= 52) {
                searchBox = child;
                break;
            }
        }
        if (!searchBox) searchBox = searchBar;
        Card(searchBox, MIN(22, CGRectGetHeight(searchBox.bounds) / 2));
        YTMUStyleSearchText(searchBox);
        searchBox.layer.cornerRadius = MIN(24, CGRectGetHeight(searchBox.bounds) / 2);
        searchBox.layer.cornerCurve = kCACornerCurveContinuous;
        searchBox.layer.borderWidth = .65;
        searchBox.layer.borderColor = YTMULGAccentRed().CGColor;
        searchBox.clipsToBounds = YES;
    }
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
        @"YTMSearchResponseViewController": @"searchV2Enabled",
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

    YTMUBulkHook(@[@"YTMSearchBoxView", @"YTMSearchBarViewV2"], @selector(layoutSubviews),
                 (IMP)YTMUSearchBoxLayoutSubviews);
    YTMUBulkHook(@[@"YTMEntityHeaderView"], @selector(layoutSubviews),
                 (IMP)YTMUEntityHeaderLayoutSubviews);
    YTMUBulkHook(@[@"YTMPlaylistReorderView"], @selector(layoutSubviews),
                 (IMP)YTMUPlaylistReorderLayoutSubviews);
}
