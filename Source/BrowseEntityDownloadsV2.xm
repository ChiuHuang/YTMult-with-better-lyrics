#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "YTMULiquidGlassPreferences.h"
#import "YTMUVisualStyle.h"
#import "Headers/YTMUBulkHook.h"

static char kCardKey;
static char kSearchSeparatorKey;
static void YTMUStyleSearchPage(UIView *root, BOOL resultsPage);
static void YTMUStyleSearchPageDepth(UIView *root, BOOL resultsPage, NSInteger depth);

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
    // Only when the order is actually wrong -- same rule as the dither layer
    // below: a reorder is a setNeedsLayout on the host, and this runs from
    // layoutSubviews of the search box every pass.
    if (h.subviews.firstObject != b) [h sendSubviewToBack:b];
    h.backgroundColor = UIColor.clearColor;
    YTMULGApplyDither(h, b, .30);
}

static void ClearTree(UIView *r, NSInteger d) {
    if (!r || d > 8) return;
    Class c = NSClassFromString(@"YTImageView");
    for (UIView *v in r.subviews) {
        if ([v isKindOfClass:UIScrollView.class]) v.backgroundColor = UIColor.clearColor;
        // The results page still painted WHITE below the glass field: some
        // wrapper view carries an explicit systemBackground (white until
        // dark mode is forced) and the scroll-view clear above never touches
        // it. Pointer compare only -- YTM's own dark fills are REAL colours
        // with distinct storage and must survive; nil-defaulted views never
        // match and cost nothing.
        if (v.backgroundColor == UIColor.whiteColor ||
            [v.backgroundColor isEqual:[UIColor systemBackgroundColor]]) {
            v.backgroundColor = UIColor.clearColor;
        }
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

// Is this controller instance REALLY a search page? YTLightweightCollection
// ViewController is in the search hook map because the result list runs on
// it, but the same class also hosts NON-search pages (the home feed) -- so
// every keyed mutation guarded only by the feature key painted the home
// page with the search treatment. The instance and its RESPONSE wrapper
// (YTMLightweightSearch~) do not always say "Search" in their own class
// name, so decide by the presentation chain: any ancestor carrying
// "Search" makes this a search page; no such ancestor -> not ours, do not
// touch the controller at all.
static BOOL YTMUIsSearchHostedInstance(UIViewController *c) {
    for (UIViewController *vc = c; vc; vc = vc.parentViewController) {
        if ([NSStringFromClass(vc.class) containsString:@"Search"]) return YES;
    }
    return NO;
}

// The feature key differs per controller, so it is recorded at hook time and
// read back from `self` inside the one shared replacement.
static void Screen(UIViewController *c, NSString *k) {
    if (!k.length) return;
    if (!YTMULGFeatureEnabled(k) || !c.view.window) return;
    // GATE BEFORE ANYTHING, before even the transparentise + tree clear:
    // a home-feed instance of YTLightweightCollectionViewController resolves
    // the search key by class, but it is not a search page. The clear, the
    // ink, the force-dark and the walk below are search-only by design -- on
    // home they must not exist at all (the home page went GREEN the moment
    // the page base became ours).
    if ([k isEqualToString:@"searchV2Enabled"] && !YTMUIsSearchHostedInstance(c)) return;
    c.view.backgroundColor = UIColor.clearColor;
    ClearTree(c.view, 0);
    if ([k isEqualToString:@"searchV2Enabled"]) {
        NSString *controllerName = NSStringFromClass(c.class);
        BOOL resultsPage = [controllerName containsString:@"Results"] ||
                           [controllerName containsString:@"SearchResponse"];
        // containsString("SearchResponse") alone would have still caught the
        // lightweight list (its class is
        // YTMLightweightSearchSuggestionsResponseViewController), but hooking
        // the list hosts separately is what brings them into the walk at all.
        c.view.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        // THE BUG, found by toggling this very setting: the white page is OUR
        // product, not the app's. Screen() transparentised the controller and
        // the walk only ever killed two EXACT pointer-compared fills, so the
        // app's real page background was never going dark -- while
        // YTMUStyleSearchText painted every label in the tree white on top of
        // it. White on white. The fix stops guessing what the app drew and
        // OWNS the base: our own dark ink under the whole page, so the
        // clearings below reveal US and the white text has a dark canvas.
        // THE INK IS NEUTRAL, not olive: an olive fill covering the whole
        // viewport reads as a GREEN page (the user's report). The glass
        // capsule keeps its green fill (alpha .24 on top of a dark page);
        // only the page canvas is a near-black neutral.
        c.view.backgroundColor = YTMUPageInk();
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
        // White caret: it sits inside the green glass box, and the red caret
        // was the same "unrelated accent" complaint as the ring around it.
        field.tintColor = UIColor.whiteColor;
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
    return YTMUStyleSearchPageDepth(root, resultsPage, 0);
}

// Depth-capped: this walks the WHOLE page on every layout pass of the search
// controller, and a result page's tree is deep (collection cells carry their
// own content hierarchies). Without a cap a pathological or very deep tree is
// a stack overflow waiting for a layout storm; 24 covers every real YT page
// with room to spare.
static void YTMUStyleSearchPageDepth(UIView *root, BOOL resultsPage, NSInteger depth) {
    if (!root || depth > 24) return;
    YTMUStyleSearchText(root);
    // Same white-kill as ClearTree: the depth cap here is 24, so an
    // explicitly-white wrapper DEEPER than ClearTree's 8 still gets caught.
    if (root.backgroundColor == UIColor.whiteColor ||
        [root.backgroundColor isEqual:[UIColor systemBackgroundColor]]) {
        root.backgroundColor = UIColor.clearColor;
    }
    // Round FOUR, resolved lightness instead of pointer references: the exact
    // semantic compares missed every fill that is merely LIGHT (grey
    // wrappers, resolved Material colours) and those are exactly what kept
    // shining over the dark base. A neutral, opaque, bright fill is page
    // chrome by definition -- kill it to clear so the page's own dark base
    // shows. Vivid or dark colours, and our own patterned views, survive.
    CGFloat lr = 0, lg = 0, lb = 0, la = 0;
    if ([root.backgroundColor getRed:&lr green:&lg blue:&lb alpha:&la]) {
        CGFloat lo = MIN(MIN(lr, lg), lb), hi = MAX(MAX(lr, lg), lb);
        if (la >= .5 && (hi - lo) <= .06 && hi >= .72) {
            root.backgroundColor = UIColor.clearColor;
        }
    }
    // WHITE FIX, third round: the search result rows are AsyncDisplayKit —
    // _ASCollectionViewCell / _ASDisplayView, and the white fill the Build
    // 316 screenshots still show is painted BY THE NODE (ASDK rasterizes the
    // node's own background colour into the layer contents, so nothing a
    // UIKit-level walk sets on the view survives). Yes the result was this:
    // the fresh dump shows YTLightweightBrowseBackgroundView hidden=YES
    // (that fix landed) and the page STILL white — the fill lives in the
    // node stack. Read the view's node back and flatten its white there,
    // where ASDK will honour it and re-render.
    static Class asViewClass;
    static dispatch_once_t asOnce;
    dispatch_once(&asOnce, ^{ asViewClass = NSClassFromString(@"_ASDisplayView") ?: NSClassFromString(@"ASDisplayView"); });
    if (asViewClass && [root isKindOfClass:asViewClass]) {
        SEL nodeSel = NSSelectorFromString(@"node");
        if ([root respondsToSelector:nodeSel]) {
            id node = ((id (*)(id, SEL))objc_msgSend)(root, nodeSel);
            if (node) {
                SEL bgSel = NSSelectorFromString(@"backgroundColor");
                if ([node respondsToSelector:bgSel]) {
                    id col = ((id (*)(id, SEL))objc_msgSend)(node, bgSel);
                    // The exact semantic compares survived three rounds of the
                    // user's screenshots, so the node fill is a bypass, a
                    // resolved near-white, which the same resolved-lightness
                    // rule as the view level now catches. Patterned node
                    // colours answer NO and are skipped.
                    BOOL nodeKill = col == UIColor.whiteColor ||
                                    [col isEqual:[UIColor systemBackgroundColor]] ||
                                    [col isEqual:[UIColor secondarySystemBackgroundColor]];
                    CGFloat nr = 0, ng = 0, nb = 0, na = 0;
                    if (!nodeKill && [col getRed:&nr green:&ng blue:&nb alpha:&na]) {
                        CGFloat lo = MIN(MIN(nr, ng), nb), hi = MAX(MAX(nr, ng), nb);
                        nodeKill = (na >= .5 && (hi - lo) <= .06 && hi >= .72);
                    }
                    if (nodeKill) {
                        SEL setBgSel = NSSelectorFromString(@"setBackgroundColor:");
                        if ([node respondsToSelector:setBgSel]) {
                            ((void (*)(id, SEL, id))objc_msgSend)(node, setBgSel, UIColor.clearColor);
                        }
                    }
                }
            }
        }
    }
    for (UIView *v in root.subviews) {
        if ([v isKindOfClass:UITableView.class]) {
            UITableView *table = (UITableView *)v;
            table.backgroundColor = UIColor.clearColor;
            table.separatorColor = [UIColor colorWithWhite:1 alpha:.12];
            table.separatorInset = UIEdgeInsetsMake(0, 16, 0, 16);
            table.showsVerticalScrollIndicator = NO;
            // WHITE FIX, second round: the fill the dump showed is BACKDROP,
            // not a background colour -- a UITableView can carry YT's own
            // backgroundView too. Nil them.
            table.backgroundView = nil;
        } else if ([v isKindOfClass:UICollectionView.class]) {
            UICollectionView *collection = (UICollectionView *)v;
            collection.backgroundColor = UIColor.clearColor;
            collection.backgroundView = nil;
            collection.showsVerticalScrollIndicator = NO;
        } else if ([NSStringFromClass(v.class) containsString:@"BrowseBackground"]) {
            // The search pages' backdrop: YTLightweightAsyncCollectionView ->
            // YTLightweightBrowseBackgroundView -> a 428x428 decorative
            // YTImageView. THE WHITE. It is an IMAGE BACKDROP, not a fill, so
            // the earlier systemBackground kill and the trait force-dark
            // never touched it -- hide the backdrop outright. Search pages
            // only: album/playlist pages keep theirs.
            v.hidden = YES;
        }

        if (resultsPage && ([v isKindOfClass:UITableViewCell.class] || [v isKindOfClass:UICollectionViewCell.class])) {
            YTMUStyleSearchResultsRow(v);
        }
        YTMUStyleSearchPageDepth(v, resultsPage, depth + 1);
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
        // Glass border, not red: the green glass capsule was the one element
        // the user called "pretty", and the red ring around it was the same
        // accent as YT's own -- unrelated to anything the reader chose.
        searchBox.layer.borderColor = YTMULGGlassBorder(.38).CGColor;
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
        // The RESULT LIST itself lives under the suggestions chain: the dump
        // hierarchy is YTMSearchViewController -> YTMSearchSuggestionsView-
        // Controller -> YTMLightweightSearchSuggestionsResponseViewController
        // -> YTLightweightCollectionViewController, and none of these three
        // was hooked -- so the whole list kept ITS OWN white background (the
        // "why is the background white" report) no matter what the response
        // page's walk cleared. Hooking the list hosts puts them under the
        // same clear + walk as every other search page.
        @"YTMSearchSuggestionsViewController": @"searchV2Enabled",
        @"YTMLightweightSearchSuggestionsResponseViewController": @"searchV2Enabled",
        @"YTLightweightCollectionViewController": @"searchV2Enabled",
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
