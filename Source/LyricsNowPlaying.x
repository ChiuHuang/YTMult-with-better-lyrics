#import "LyricsShared.h"

%hook YTMNowPlayingViewController

- (void)viewDidLayoutSubviews {
    %orig;
    g_activeNowPlayingVC = self;
    [self ytmuPlaceLyricsBesideThreeDot];
    for (UIView *sub in self.view.subviews) {
        [self ytmu_makeLyricsViewClickable:sub];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    g_activeNowPlayingVC = self;
    [self ytmu_keepLyricsButtonActive];
}

%new
- (void)ytmu_keepLyricsButtonActive {
    [self ytmuPlaceLyricsBesideThreeDot];
    for (UIView *sub in self.view.subviews) {
        [self ytmu_makeLyricsViewClickable:sub];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self ytmuPlaceLyricsBesideThreeDot];
        for (UIView *sub in self.view.subviews) {
            [self ytmu_makeLyricsViewClickable:sub];
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self ytmuPlaceLyricsBesideThreeDot];
        for (UIView *sub in self.view.subviews) {
            [self ytmu_makeLyricsViewClickable:sub];
        }
    });
}

%new
- (void)ytmu_makeLyricsViewClickable:(UIView *)v {
    if (!v) return;

    BOOL isLyrics = NO;
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *lbl = (UILabel *)v;
        NSString *txt = lbl.text ?: lbl.attributedText.string;
        if (txt) {
            NSString *low = txt.lowercaseString;
            if ([txt containsString:@"歌詞"] || [txt containsString:@"歌词"] || [low containsString:@"lyric"] || [low containsString:@"unavailable"] || [txt containsString:@"沒有歌詞"] || [txt containsString:@"没有歌词"] || [txt containsString:@"無歌詞"] || [txt containsString:@"無提供歌詞"]) {
                isLyrics = YES;
            }
        }
    }
    if (!isLyrics && v.accessibilityLabel) {
        NSString *low = v.accessibilityLabel.lowercaseString;
        if ([low containsString:@"歌詞"] || [low containsString:@"歌词"] || [low containsString:@"lyric"]) {
            isLyrics = YES;
        }
    }
    if (!isLyrics && v.accessibilityIdentifier) {
        NSString *low = v.accessibilityIdentifier.lowercaseString;
        if ([low containsString:@"lyric"]) {
            isLyrics = YES;
        }
    }
    if (!isLyrics && [v respondsToSelector:@selector(titleForState:)]) {
        NSString *title = [(UIButton *)v titleForState:UIControlStateNormal];
        if (title) {
            NSString *low = title.lowercaseString;
            if ([title containsString:@"歌詞"] || [title containsString:@"歌词"] || [low containsString:@"lyric"]) {
                isLyrics = YES;
            }
        }
    }

    if (isLyrics) {
        UIView *btn = v;
        while (btn.superview && btn.superview != self.view && btn.superview.bounds.size.width < 250) {
            btn = btn.superview;
        }

        objc_setAssociatedObject(btn, @selector(ytmu_isLyricsButton), @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        btn.userInteractionEnabled = YES;
        btn.alpha = 1.0;
        btn.hidden = NO;
        if (btn.superview) {
            btn.superview.userInteractionEnabled = YES;
        }
        for (UIView *child in btn.subviews) {
            objc_setAssociatedObject(child, @selector(ytmu_isLyricsButton), @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            child.userInteractionEnabled = YES;
            child.alpha = 1.0;
            child.hidden = NO;
        }

        if ([btn isKindOfClass:[UIControl class]]) {
            [(UIControl *)btn setEnabled:YES];
            [(UIControl *)btn addTarget:self action:@selector(ytmu_didTapLyricsButtonAction:) forControlEvents:UIControlEventTouchUpInside];
        }

        if (![btn isKindOfClass:[UIControl class]] && !objc_getAssociatedObject(btn, @selector(ytmu_didTapLyricsBar:))) {
            UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(ytmu_didTapLyricsBar:)];
            tap.cancelsTouchesInView = NO;
            [btn addGestureRecognizer:tap];
            objc_setAssociatedObject(btn, @selector(ytmu_didTapLyricsBar:), tap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }

        if (v != btn && !objc_getAssociatedObject(v, @selector(ytmu_didTapLyricsBar:))) {
            v.userInteractionEnabled = YES;
            objc_setAssociatedObject(v, @selector(ytmu_isLyricsButton), @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            UITapGestureRecognizer *lblTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(ytmu_didTapLyricsBar:)];
            lblTap.cancelsTouchesInView = NO;
            [v addGestureRecognizer:lblTap];
            objc_setAssociatedObject(v, @selector(ytmu_didTapLyricsBar:), lblTap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }

    for (UIView *child in v.subviews) {
        [self ytmu_makeLyricsViewClickable:child];
    }
}

// OUR OWN LYRICS CHIP IS GONE, and this is why, because it was not a fallback.
//
// It used to be built and parked exactly on top of the official button, with the
// official one left visible underneath as a "fallback". In practice that is two
// chips in one spot, and the one a tap lands on is whichever view UIKit hit --
// which is how the screenshots came to show a chip that looked slightly doubled
// and behaved slightly wrong. Our panel opened from either, so the duplicate
// bought nothing: -ytmu_makeLyricsViewClickable already un-disables the official
// button, un-hides it, and wires our target to it. The button the reader can see
// is now the only button, and it is the one that works.

%new
- (void)ytmu_didTapLyricsButtonAction:(id)sender {
    // Landscape auto-opens lyrics on rotation; button must not re-trigger there.
    if (YTMUIsInterfaceLandscape()) {
        sendDebugLog(@"[MUSIC] Lyrics button ignored in landscape (auto-open path)");
        return;
    }
    sendDebugLog(@"[MUSIC] Lyrics button tapped via UIControl");
    openLyricsFromViewController((UIViewController *)self);
}

%new
- (void)ytmu_didTapLyricsBar:(UITapGestureRecognizer *)gesture {
    if (YTMUIsInterfaceLandscape()) {
        sendDebugLog(@"[MUSIC] Lyrics chip ignored in landscape (auto-open path)");
        return;
    }
    sendDebugLog(@"[MUSIC] Lyrics chip tapped via UITapGestureRecognizer");
    openLyricsFromViewController((UIViewController *)self);
}

%new
- (UIView *)ytmu_findThreeDotControl:(UIView *)v {
    // Check UIControl and also UIView with gesture recognizers (some 3-dot
    // buttons are plain UIViews with a tap recognizer, not UIControl subclasses).
    BOOL isCandidate = [v isKindOfClass:[UIControl class]];
    if (!isCandidate && v.gestureRecognizers.count > 0) {
        for (UIGestureRecognizer *gr in v.gestureRecognizers) {
            if ([gr isKindOfClass:[UITapGestureRecognizer class]]) { isCandidate = YES; break; }
        }
    }
    if (isCandidate) {
        NSString *label = [v accessibilityLabel].lowercaseString ?: @"";
        NSString *ident = v.accessibilityIdentifier ? [v.accessibilityIdentifier lowercaseString] : @"";
        NSString *hint = [v accessibilityHint].lowercaseString ?: @"";
        BOOL match = (label.length && ([label containsString:@"more"] || [label containsString:@"menu"] || [label containsString:@"option"] || [label containsString:@"更多"])) ||
            (ident.length && ([ident containsString:@"more"] || [ident containsString:@"menu"] || [ident containsString:@"option"] || [ident containsString:@"overflow"] || [ident containsString:@"ellipsis"])) ||
            (hint.length && [hint containsString:@"更多"]);
        if (match) {
            sendDebugLog([NSString stringWithFormat:@"[3DOT] FOUND: class=%@ label=\"%@\" ident=\"%@\" hint=\"%@\" frame=(%.0f,%.0f;%.0f,%.0f)",
                NSStringFromClass([v class]), [v accessibilityLabel] ?: @"", [v accessibilityIdentifier] ?: @"", [v accessibilityHint] ?: @"",
                v.frame.origin.x, v.frame.origin.y, v.frame.size.width, v.frame.size.height]);
            return v;
        }
    }
    for (UIView *child in v.subviews) {
        UIView *found = [self ytmu_findThreeDotControl:child];
        if (found) return found;
    }
    return nil;
}

%new
- (void)ytmuPlaceLyricsBesideThreeDot {
    static NSInteger lastLoggedCount = -1;
    NSInteger count = self.view.subviews.count;
    if (count != lastLoggedCount) {
        sendDebugLog([NSString stringWithFormat:@"[3DOT] Searching %ld subviews in %@", (long)count, NSStringFromClass([self class])]);
        lastLoggedCount = count;
    }
    // The 3-dot button lives in the parent container (YTMWatchView), NOT inside
    // YTMNowPlayingView — same family as the cast MDCFloatingButton. Search both
    // self.view (NowPlayingView) and self.view.superview (the watch container).
    UIView *threeDot = nil;
    for (UIView *sub in self.view.subviews) {
        threeDot = [self ytmu_findThreeDotControl:sub];
        if (threeDot) break;
    }
    if (!threeDot && self.view.superview) {
        for (UIView *sub in self.view.superview.subviews) {
            threeDot = [self ytmu_findThreeDotControl:sub];
            if (threeDot) break;
        }
    }
    if (!threeDot) return;
    if (!threeDot.superview || !self.view) return;
    // Our own lyrics chip is no longer drawn here: the native lyrics button is
    // already un-hidden and wired by -ytmu_makeLyricsViewClickable, so a second
    // chip only duplicated the entry and pushed the action row off-screen.
}

%end

%hook YTPlayerViewController

- (void)viewDidLoad {
    %orig;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ytmu_handleSeek:) name:@"YTMUSeekToTime" object:nil];
}

%new
- (void)ytmu_handleSeek:(NSNotification *)notif {
    NSNumber *timeObj = notif.object;
    if (!timeObj) return;

    double time = [timeObj doubleValue];
    NSLog(@"[YTMU-Seek] Attempting to seek to: %f", time);

    if ([self respondsToSelector:@selector(seekToTime:)]) {
        [self seekToTime:time];
    } else if ([self respondsToSelector:@selector(seekToTime:toleranceBefore:toleranceAfter:)]) {
        [self seekToTime:time toleranceBefore:0 toleranceAfter:0];
    } else {
        NSLog(@"[YTMU-Seek] ERROR: YTPlayerViewController does not respond to standard seek methods.");
    }
}

%end
