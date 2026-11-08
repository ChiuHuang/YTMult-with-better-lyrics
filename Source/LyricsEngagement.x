#import "LyricsShared.h"

// ---- THE LYRICS CHUNK MARKER (one definition) ----
// Privacy hooks (control enabled, chip visible) key off a `ytmu_isLyricsButton`
// associated marker. This is the ONE place that decides where that marker
// lives, so switching from `a `%`` walk won't disagree.
//
// HISTORY THAT SHAPED IT:
//  - The old climb stopped at 250pt (LyricsNowPlaying) / 90% of the window
//    (here); on a 428pt phone both surface at the whole action-row BAR, so
//    the marker sat on chrome nowhere near the chip and the per-`UIView`
//    forced-YES hooks then fought YT's popup-drag transitions (dimming the
//    background) -- the chip visibly "escaped" out of the dimming before
//    everything else around it. The stop is a CHIP SIZE now and nothing
//    above the chip is marked, so a dim reaches the row like anything else.
//  - Marking only the tile (not the path) let YT disable an INTERMEDIATE
//    control the tile's marker never covered -- the chip sometimes stayed
//    greyed out. Any node on the path may be the one YT tries to disable.
//  - The chip's label text can ARRIVE LATE (after the layout pass that
//    searched for it): the text-arrival hook below re-asserts the mark on
//    the same rules.
BOOL YTMUTextLooksLyrics(NSString *text) {
    if (!text.length || text.length > 2048) return NO;
    if ([text containsString:@"歌詞"] || [text containsString:@"歌词"]) return YES;
    return [[text lowercaseString] containsString:@"lyric"];
}

// Defined below; the chip mark walks into it.
void YTMUMarkLyricsSubtree(UIView *root, NSInteger depth);

// Marks the chip and everything INSIDE it, and re-enables every control in
// there (goes through our setEnabled hook, which is a no-op for non-chips).
// Returns the chip: the highest ancestor whose parent is still chip-sized.
// The stop is a SIZE, not "the first surface": a chip is one cell of the
// action row (~96pt) while the row is 388-428pt wide, and the row keeps
// containing other chips. Nothing above the chip carries the marker, so the
// forced-alpha/hidden hooks below can never freeze chrome.
UIView *YTMUMarkLyricsPath(UIView *leaf) {
    if (!leaf) return nil;
    UIView *chip = leaf;
    while (chip.superview) {
        UIView *p = chip.superview;
        if (p.bounds.size.width > 240.0 || p.bounds.size.height > 120.0) break;
        chip = p;
    }
    objc_setAssociatedObject(chip, @selector(ytmu_isLyricsButton), @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    YTMUMarkLyricsSubtree(chip, 6);
    for (UIView *n = leaf; n; n = n.superview) {
        if ([n isKindOfClass:[UIControl class]]) [(UIControl *)n setEnabled:YES];
        if (n == chip) break;
    }
    return chip;
}

// Subtree marking, depth-capped. The tile reached path-level covers its
// children; recursion here is bounded because cells deep in a sheet could
// otherwise walk the whole window.
void YTMUMarkLyricsSubtree(UIView *root, NSInteger depth) {
    if (!root || depth <= 0) return;
    for (UIView *c in root.subviews) {
        objc_setAssociatedObject(c, @selector(ytmu_isLyricsButton), @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        YTMUMarkLyricsSubtree(c, depth - 1);
    }
}

// Cell/tile REUSE: the same view can later carry a non-lyrics action, and a
// stale marker would then keep forcing YES on the wrong row. Strip the
// marker key (only this association; objc_removeAssociatedObjects would kill
// unrelated systems' data).
void YTMUClearLyricsMarkersFrom(UIView *root, NSInteger depth) {
    if (!root || depth <= 0) return;
    objc_setAssociatedObject(root, @selector(ytmu_isLyricsButton), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    for (UIView *c in root.subviews) YTMUClearLyricsMarkersFrom(c, depth - 1);
}

// The lyrics entry button is YTM's OWN button; there is no owning pref
// anymore. The four hooks below force it un-hideable (YT disables and hides
// it to gate lyrics on subscription), and lyricsEntryButtonEnabled -- the
// old opt-out key that let the button disappear again on some installs --
// is retired: the checked setting was removed and the forcing always runs.
%hook YTEngagementPanelContainerViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    g_activeEngagementPanelContainer = self;
}

- (void)viewDidLoad {
    %orig;
    g_activeEngagementPanelContainer = self;
}

%end


%hook YTEngagementPanelViewControllerImpl

- (void)viewWillAppear:(BOOL)animated {
    %orig;

    UIViewController *vc = (UIViewController *)self;
    if (isLyricsEngagementPanel(vc)) {
        UIView *contentContainer = nil;
        for (UIView *sub in vc.view.subviews) {
            if (![NSStringFromClass([sub class]) isEqualToString:@"YTEngagementPanelHeaderView"]) {
                contentContainer = sub;
                break;
            }
        }

        if (contentContainer) {
            UIView *lyricsView = [contentContainer viewWithTag:9999];
            YTMULyricsViewController *lyricsVC = objc_getAssociatedObject(contentContainer, @selector(lyricsVC));

            if (!lyricsView || !lyricsVC) {
                lyricsVC = [[YTMULyricsViewController alloc] init];
                lyricsVC.view.tag = 9999;
                lyricsVC.view.frame = contentContainer.bounds;
                lyricsVC.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                lyricsVC.view.hidden = YES;
                [contentContainer addSubview:lyricsVC.view];
                objc_setAssociatedObject(contentContainer, @selector(lyricsVC), lyricsVC, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }

            lyricsVC.view.frame = contentContainer.bounds;

            NSString *panelVideoID = YTMUResolveCurrentVideoID();
            if (panelVideoID) {
                [lyricsVC fetchLyricsForVideo:panelVideoID];
            }
        }
    }
}


- (void)viewDidLayoutSubviews {
    %orig;

    UIViewController *vc = (UIViewController *)self;
    if (isLyricsEngagementPanel(vc)) {
        UIView *contentContainer = nil;
        for (UIView *sub in vc.view.subviews) {
            if (![NSStringFromClass([sub class]) isEqualToString:@"YTEngagementPanelHeaderView"]) {
                contentContainer = sub;
                break;
            }
        }

        if (contentContainer) {
            UIView *lyricsView = [contentContainer viewWithTag:9999];
            YTMULyricsViewController *lyricsVC = objc_getAssociatedObject(contentContainer, @selector(lyricsVC));

            if (!lyricsView || !lyricsVC) {
                lyricsVC = [[YTMULyricsViewController alloc] init];
                lyricsVC.view.tag = 9999;
                lyricsVC.view.frame = contentContainer.bounds;
                lyricsVC.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                lyricsVC.view.hidden = YES;
                [contentContainer addSubview:lyricsVC.view];
                objc_setAssociatedObject(contentContainer, @selector(lyricsVC), lyricsVC, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                if (g_currentVideoID) {
                    [lyricsVC fetchLyricsForVideo:g_currentVideoID];
                }
            }

            if (lyricsView && !lyricsView.hidden) {
                [contentContainer bringSubviewToFront:lyricsView];
                lyricsView.frame = contentContainer.bounds;
                for (UIView *sub in contentContainer.subviews) {
                    if (sub.tag != 9999) {
                        sub.hidden = YES;
                    }
                }
            } else if (lyricsView) {
                lyricsView.frame = contentContainer.bounds;
            }
        }
    }
}

%end


static BOOL YTMUIsLyricsRenderer(YTIButtonRenderer *renderer) {
    if (!renderer) return NO;
    if (renderer.text) {
        NSString *t = nil;
        if ([renderer.text respondsToSelector:@selector(runs)]) {
            NSArray *runs = [renderer.text performSelector:@selector(runs)];
            if (runs && runs.count > 0) {
                NSMutableString *ms = [NSMutableString string];
                for (id r in runs) {
                    if ([r respondsToSelector:@selector(text)]) {
                        NSString *rt = [r performSelector:@selector(text)];
                        if (rt) [ms appendString:rt];
                    }
                }
                t = ms;
            }
        }
        if (!t && [renderer.text respondsToSelector:@selector(simpleText)]) {
            t = [renderer.text performSelector:@selector(simpleText)];
        }
        if (t && ([t containsString:@"歌詞"] || [t containsString:@"歌词"] || [t.lowercaseString containsString:@"lyric"])) {
            return YES;
        }
    }
    if (renderer.accessibilityData) {
        NSString *accDesc = [renderer.accessibilityData description];
        if ([accDesc containsString:@"歌詞"] || [accDesc containsString:@"歌词"] || [accDesc.lowercaseString containsString:@"lyric"]) {
            return YES;
        }
    }
    if (renderer.accessibility) {
        NSString *accDesc = [renderer.accessibility description];
        if ([accDesc containsString:@"歌詞"] || [accDesc containsString:@"歌词"] || [accDesc.lowercaseString containsString:@"lyric"]) {
            return YES;
        }
    }
    @try {
        NSString *browseId = renderer.command.browseEndpoint.browseId;
        if (browseId.length && [browseId.lowercaseString containsString:@"lyric"]) {
            return YES;
        }
    } @catch (NSException *e) {}
    NSString *desc = [renderer description];
    if ([desc containsString:@"PAmusic_watch_lyrics_panel"] || [desc.lowercaseString containsString:@"lyrics_panel"] || [desc.lowercaseString containsString:@"lyrics"]) {
        return YES;
    }
    return NO;
}

%hook YTIButtonRenderer

- (BOOL)isDisabled {
    if (YTMUIsLyricsRenderer(self)) {
        return NO;
    }
    return %orig;
}

- (void)setIsDisabled:(BOOL)disabled {
    if (YTMUIsLyricsRenderer(self)) {
        %orig(NO);
        return;
    }
    %orig(disabled);
}

%end


// A chip whose text had not arrived when the layout pass ran (or one YT built
// fresh afterwards) never got the marker, and YT is then free to grey it --
// that is the "sometimes the lyrics button is disabled" report. Disabling is
// a rare event, so the text read is paid for HERE instead of on every pass,
// and the mark is applied on the spot so the rest of the forcing follows.
static BOOL YTMUControlLooksLikeLyrics(UIControl *c) {
    if (!c) return NO;
    if (YTMUTextLooksLyrics(c.accessibilityLabel)) return YES;
    if (YTMUTextLooksLyrics(c.accessibilityIdentifier)) return YES;
    @try {
        if ([c respondsToSelector:@selector(titleForState:)]) {
            if (YTMUTextLooksLyrics([(UIButton *)c titleForState:UIControlStateNormal])) return YES;
        }
    } @catch (NSException *e) {}
    for (UIView *s in c.subviews) {
        if ([s isKindOfClass:[UILabel class]] && YTMUTextLooksLyrics(((UILabel *)s).text)) return YES;
        if (YTMUTextLooksLyrics(s.accessibilityLabel)) return YES;
    }
    return NO;
}

// The action-row chips of YT 9.35 are ASDK views: no UILabel, no UIControl,
// so neither the layout walk (it reads text) nor -setEnabled: (it needs a
// UIControl) is ever reached for them -- the chip YT disables by HIDING its
// cell stayed hidden, which is the "lyrics button is disabled" report. The
// same question is asked of a plain UIView here, and the probe is bounded: a
// chip is small, and that size gate is also what keeps YT's own "no lyrics"
// toast (a 412pt snackbar carrying the word 歌詞) from being forced on.
#define YTMU_LYRICS_CHIP_MAX_W 240.0
#define YTMU_LYRICS_CHIP_MAX_H 60.0

static BOOL YTMUViewLooksLikeLyrics(UIView *v, NSInteger depth) {
    if (!v || depth < 0) return NO;
    if (YTMUTextLooksLyrics(v.accessibilityLabel)) return YES;
    if (YTMUTextLooksLyrics(v.accessibilityIdentifier)) return YES;
    if ([v isKindOfClass:[UILabel class]] && YTMUTextLooksLyrics(((UILabel *)v).text)) return YES;
    for (id e in v.accessibilityElements) {
        if ([e respondsToSelector:@selector(accessibilityLabel)] &&
            YTMUTextLooksLyrics([e accessibilityLabel])) return YES;
    }
    for (UIView *c in v.subviews) {
        if (YTMUViewLooksLikeLyrics(c, depth - 1)) return YES;
    }
    return NO;
}

static BOOL YTMUIsChipSized(UIView *v) {
    CGFloat w = CGRectGetWidth(v.bounds), h = CGRectGetHeight(v.bounds);
    return w > 0.0 && h > 0.0 && w <= YTMU_LYRICS_CHIP_MAX_W && h <= YTMU_LYRICS_CHIP_MAX_H;
}

// A view YT is about to hide/dim that is chip-sized and reads as lyrics IS the
// entry: mark it (which makes every hook below refuse) and keep it on screen.
static BOOL YTMURescueLyricsChip(UIView *v) {
    if (!v || !YTMUIsChipSized(v)) return NO;
    if (!YTMUViewLooksLikeLyrics(v, 2)) return NO;
    YTMUMarkLyricsPath(v);
    return YES;
}

%hook UIControl

- (void)setEnabled:(BOOL)enabled {
    if (!enabled) {
        if (objc_getAssociatedObject(self, @selector(ytmu_isLyricsButton))) {
            %orig(YES);
            return;
        }
        if (YTMUControlLooksLikeLyrics(self)) {
            YTMUMarkLyricsPath(self);
            %orig(YES);
            return;
        }
    }
    %orig(enabled);
}

%end

%hook UIView

- (void)setUserInteractionEnabled:(BOOL)enabled {
    if (!enabled) {
        if (objc_getAssociatedObject(self, @selector(ytmu_isLyricsButton))) {
            %orig(YES);
            return;
        }
        if (YTMURescueLyricsChip(self)) {
            %orig(YES);
            return;
        }
    }
    %orig(enabled);
}

- (void)setAlpha:(CGFloat)alpha {
    if (alpha < 0.8) {
        if (objc_getAssociatedObject(self, @selector(ytmu_isLyricsButton))) {
            %orig(1.0);
            return;
        }
        if (YTMURescueLyricsChip(self)) {
            %orig(1.0);
            return;
        }
    }
    %orig(alpha);
}

- (void)setHidden:(BOOL)hidden {
    if (hidden) {
        if (objc_getAssociatedObject(self, @selector(ytmu_isLyricsButton))) {
            %orig(NO);
            return;
        }
        if (YTMURescueLyricsChip(self)) {
            %orig(NO);
            return;
        }
    }
    %orig(hidden);
}

%end


%hook ELMTouchCommandPropertiesHandler

- (void)handleTap {
    if (class_getInstanceVariable([self class], "_controller") == NULL) {
        return %orig;
    }
    if (class_getInstanceVariable([self class], "_tapRecognizer") == NULL) {
        return %orig;
    }

    ELMNodeController *node = [self valueForKey:@"_controller"];
    UIGestureRecognizer *tapRecognizer = [self valueForKey:@"_tapRecognizer"];

    NSString *key = nil;
    if ([node respondsToSelector:@selector(key)]) {
        @try { key = [node key]; } @catch (NSException *e) { key = nil; }
    }

    // TODO: Replace with exact key from device logs (like music_download_badge_1 in Downloading.x)
    // if (![key isEqualToString:@"EXACT_LYRICS_ELM_KEY_HERE"]) {
    //     return %orig;
    // }

    NSString *nodeDesc = [node description] ?: @"";
    BOOL keyMatch = key.length > 0 && [key.lowercaseString containsString:@"lyric"];
    BOOL descMatch = [nodeDesc containsString:@"lyric"] || [nodeDesc containsString:@"format_quote"] || [nodeDesc containsString:@"queue_music"];
    if (!keyMatch && !descMatch) {
        return %orig;
    }

    UIViewController *vc = [tapRecognizer.view _viewControllerForAncestor];
    if (![vc isKindOfClass:%c(YTMNowPlayingViewController)]) {
        return %orig;
    }

    // Identity from the node itself, not from its text: whatever view the
    // lyrics command was tapped on IS the chip, so mark it now and the forced
    // hidden/alpha/enabled hooks cover it from here on.
    if (tapRecognizer.view) YTMUMarkLyricsPath(tapRecognizer.view);

    sendDebugLog([NSString stringWithFormat:@"[MUSIC] Lyrics ELM tap key=%@ vc=%@", key ?: @"(nil)", NSStringFromClass([vc class])]);
    if (YTMUIsInterfaceLandscape()) {
        sendDebugLog(@"[MUSIC] Lyrics ELM tap ignored in landscape (auto-open path)");
        return;
    }
    openLyricsFromViewController(vc);
    return;
}

%end


%hook YTMActionRowView

- (void)layoutSubviews {
    %orig;
    // The row keeps its renderers NEXT TO its buttons (_actionButtons /
    // _actionButtonsFromRenderers), so the lyrics chip can be identified from
    // the renderer's command instead of from a label it may never have. This
    // is the only path here that does not depend on text arriving at all.
    @try {
        NSArray *renderers = [self valueForKey:@"_actionButtonsFromRenderers"];
        NSArray *buttons = [self valueForKey:@"_actionButtons"];
        if ([renderers isKindOfClass:[NSArray class]] && [buttons isKindOfClass:[NSArray class]]) {
            NSUInteger n = MIN(renderers.count, buttons.count);
            for (NSUInteger i = 0; i < n; i++) {
                id r = renderers[i];
                id b = buttons[i];
                if (![r isKindOfClass:[YTIButtonRenderer class]]) continue;
                if (!YTMUIsLyricsRenderer((YTIButtonRenderer *)r)) continue;
                if (![b isKindOfClass:[UIView class]]) continue;
                [(UIView *)b setAlpha:1.0];
                [(UIView *)b setHidden:NO];
                [(UIView *)b setUserInteractionEnabled:YES];
                YTMUMarkLyricsPath((UIView *)b);
            }
        }
    } @catch (NSException *e) {}

    UIViewController *vc = [self _viewControllerForAncestor];
    if (vc && [vc respondsToSelector:@selector(ytmu_makeLyricsViewClickable:)]) {
        for (UIView *sub in self.subviews) {
            [(YTMNowPlayingViewController *)vc ytmu_makeLyricsViewClickable:sub];
        }
    }
}

%end
