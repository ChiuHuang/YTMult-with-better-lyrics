#import "LyricsShared.h"

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


%hook UIControl

- (void)setEnabled:(BOOL)enabled {
    if (!enabled && objc_getAssociatedObject(self, @selector(ytmu_isLyricsButton))) {
        %orig(YES);
        return;
    }
    %orig(enabled);
}

%end

%hook UIView

- (void)setUserInteractionEnabled:(BOOL)enabled {
    if (!enabled && objc_getAssociatedObject(self, @selector(ytmu_isLyricsButton))) {
        %orig(YES);
        return;
    }
    %orig(enabled);
}

- (void)setAlpha:(CGFloat)alpha {
    if (alpha < 0.8 && objc_getAssociatedObject(self, @selector(ytmu_isLyricsButton))) {
        %orig(1.0);
        return;
    }
    %orig(alpha);
}

- (void)setHidden:(BOOL)hidden {
    if (hidden && objc_getAssociatedObject(self, @selector(ytmu_isLyricsButton))) {
        %orig(NO);
        return;
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

    sendDebugLog([NSString stringWithFormat:@"[MUSIC] Lyrics ELM tap key=%@ vc=%@", key ?: @"(nil)", NSStringFromClass([vc class])]);
    openLyricsFromViewController(vc);
    return;
}

%end


%hook YTMActionRowView

- (void)layoutSubviews {
    %orig;
    UIViewController *vc = [self _viewControllerForAncestor];
    if (vc && [vc respondsToSelector:@selector(ytmu_makeLyricsViewClickable:)]) {
        for (UIView *sub in self.subviews) {
            [(YTMNowPlayingViewController *)vc ytmu_makeLyricsViewClickable:sub];
        }
    }
}

%end
