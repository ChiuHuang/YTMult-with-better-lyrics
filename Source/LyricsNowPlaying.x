#import "LyricsShared.h"

%hook YTMNowPlayingViewController

- (void)viewDidLayoutSubviews {
    %orig;
    [self ytmuPlaceLyricsBesideThreeDot];
    for (UIView *sub in self.view.subviews) {
        [self ytmu_makeLyricsViewClickable:sub];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
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

        if ([self ytmu_replaceLyricsChip:btn]) {
            return;
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

%new
- (BOOL)ytmu_replaceLyricsChip:(UIView *)official {
    UIView *parent = official.superview;
    if (!parent) return NO;
    if ([official isKindOfClass:[UIButton class]] && official.tag == 9777) return YES;
    if (official.bounds.size.width >= 250 || official.bounds.size.width <= 0) return NO;

    objc_setAssociatedObject(official, @selector(ytmu_isLyricsButton), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    for (UIView *child in official.subviews) {
        objc_setAssociatedObject(child, @selector(ytmu_isLyricsButton), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    official.hidden = YES;

    NSString *chipTitle = @"歌詞";
    if ([official isKindOfClass:[UILabel class]] && ((UILabel *)official).text.length) {
        chipTitle = ((UILabel *)official).text;
    } else {
        for (UIView *child in official.subviews) {
            if ([child isKindOfClass:[UILabel class]] && ((UILabel *)child).text.length) {
                chipTitle = ((UILabel *)child).text;
                break;
            }
        }
    }

    UIButton *own = (UIButton *)[parent viewWithTag:9777];
    if (![own isKindOfClass:[UIButton class]]) {
        own = g_ytmuOwnLyricsButton;
    }
    if (![own isKindOfClass:[UIButton class]]) {
        own = [UIButton buttonWithType:UIButtonTypeSystem];
        own.tag = 9777;
        [own setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        own.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        own.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
        own.layer.masksToBounds = YES;
        [own addTarget:self action:@selector(ytmu_didTapLyricsButtonAction:) forControlEvents:UIControlEventTouchUpInside];
        g_ytmuOwnLyricsButton = own;
    }
    objc_setAssociatedObject(own, @selector(ytmu_isLyricsButton), @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (own.superview != parent) {
        [parent addSubview:own];
    }
    [own setTitle:chipTitle forState:UIControlStateNormal];
    own.frame = official.frame;
    own.autoresizingMask = official.autoresizingMask;
    own.layer.cornerRadius = MAX(official.bounds.size.height / 2.0, 8.0);
    own.hidden = NO;
    own.userInteractionEnabled = YES;
    own.alpha = 1.0;
    return YES;
}

%new
- (void)ytmu_didTapLyricsButtonAction:(id)sender {
    sendDebugLog(@"[MUSIC] Lyrics button tapped via UIControl");
    openLyricsFromViewController((UIViewController *)self);
}

%new
- (void)ytmu_didTapLyricsBar:(UITapGestureRecognizer *)gesture {
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
    if (!threeDot) {
        // Fallback: place the button top-right when 3-dot is not found.
        // Log the subview tree once so we can see what IS there.
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            NSMutableString *tree = [NSMutableString stringWithFormat:@"[3DOT] NOT FOUND — top subviews of %@:", NSStringFromClass([self class])];
            for (UIView *sub in self.view.subviews) {
                [tree appendFormat:@"\n  %@ frame=(%.0f,%.0f;%.0f,%.0f) accLabel=\"%@\" accId=\"%@\"",
                    NSStringFromClass([sub class]),
                    sub.frame.origin.x, sub.frame.origin.y, sub.frame.size.width, sub.frame.size.height,
                    [sub accessibilityLabel] ?: @"", [sub accessibilityIdentifier] ?: @""];
            }
            sendDebugLog(tree);
        });
        // Place button at fixed top-right position (below status bar / nav bar)
        UIButton *own = (UIButton *)[self.view viewWithTag:9778];
        if (![own isKindOfClass:[UIButton class]]) {
            own = [UIButton buttonWithType:UIButtonTypeSystem];
            own.tag = 9778;
            [own setTitle:@"歌詞" forState:UIControlStateNormal];
            [own setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            own.titleLabel.font = [UIFont boldSystemFontOfSize:13];
            own.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
            own.layer.masksToBounds = YES;
            objc_setAssociatedObject(own, @selector(ytmu_isLyricsButton), @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [own addTarget:self action:@selector(ytmu_didTapLyricsButtonAction:) forControlEvents:UIControlEventTouchUpInside];
            [self.view addSubview:own];
        }
        CGFloat btnW = 56.0, btnH = 32.0;
        CGFloat safeTop = 0;
        if (@available(iOS 11.0, *)) {
            safeTop = self.view.safeAreaInsets.top;
        }
        CGFloat topPad = (safeTop > 0 ? safeTop + 6.0 : 46.0);
        own.frame = CGRectMake(self.view.bounds.size.width - btnW - 12.0, topPad, btnW, btnH);
        own.layer.cornerRadius = btnH / 2.0;
        own.hidden = NO;
        own.alpha = 1.0;
        own.userInteractionEnabled = YES;
        [self.view bringSubviewToFront:own];
        return;
    }
    if (!threeDot.superview || !self.view) return;

    // Add the button to the same container as the 3-dot, so z-ordering is correct.
    UIView *btnContainer = threeDot.superview;
    UIButton *own = (UIButton *)[btnContainer viewWithTag:9778];
    if (![own isKindOfClass:[UIButton class]]) {
        own = [UIButton buttonWithType:UIButtonTypeSystem];
        own.tag = 9778;
        [own setTitle:@"歌詞" forState:UIControlStateNormal];
        [own setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        own.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        own.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
        own.layer.masksToBounds = YES;
        objc_setAssociatedObject(own, @selector(ytmu_isLyricsButton), @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [own addTarget:self action:@selector(ytmu_didTapLyricsButtonAction:) forControlEvents:UIControlEventTouchUpInside];
        [btnContainer addSubview:own];
    }
    CGRect threeFrame = [threeDot.superview convertRect:threeDot.frame toView:btnContainer];
    CGFloat btnW = 56.0, btnH = 32.0;
    own.frame = CGRectMake(threeFrame.origin.x - btnW - 8.0,
                           threeFrame.origin.y + (threeFrame.size.height - btnH) / 2.0 - 8.0,
                           btnW, btnH);
    own.layer.cornerRadius = btnH / 2.0;
    own.hidden = NO;
    own.alpha = 1.0;
    own.userInteractionEnabled = YES;
    [btnContainer bringSubviewToFront:own];
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
