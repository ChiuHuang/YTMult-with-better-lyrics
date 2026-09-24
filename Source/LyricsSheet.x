#import "LyricsShared.h"

static inline BOOL __attribute__((unused)) YTMUIsCJKChar(unichar c) {
    return ((c >= 0x3040 && c <= 0x309F) ||
            (c >= 0x30A0 && c <= 0x30FF) ||
            (c >= 0x31F0 && c <= 0x31FF) ||
            (c >= 0x3400 && c <= 0x4DBF) ||
            (c >= 0x4E00 && c <= 0x9FFF) ||
            (c >= 0xF900 && c <= 0xFAFF) ||
            (c >= 0x3000 && c <= 0x303F) ||
            (c >= 0xFF61 && c <= 0xFF9F) ||
            (c >= 0xFF00 && c <= 0xFFEF));
}

// Dynamic ink: white in dark mode, black in light mode. Deployment target is
// iOS 13 so colorWithDynamicProvider is always available at runtime.
UIColor *YTMUAdaptiveInk(CGFloat darkAlpha, CGFloat lightAlpha) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        if (tc.userInterfaceStyle == UIUserInterfaceStyleLight)
            return [[UIColor blackColor] colorWithAlphaComponent:lightAlpha];
        return [[UIColor whiteColor] colorWithAlphaComponent:darkAlpha];
    }];
}
UIColor *YTMUAdaptiveFill(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        if (tc.userInterfaceStyle == UIUserInterfaceStyleLight)
            return [[UIColor blackColor] colorWithAlphaComponent:0.10];
        return [[UIColor whiteColor] colorWithAlphaComponent:0.15];
    }];
}
UIColor *YTMUAdaptiveShadow(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        if (tc.userInterfaceStyle == UIUserInterfaceStyleLight)
            return [[UIColor darkGrayColor] colorWithAlphaComponent:0.35];
        return [[UIColor blackColor] colorWithAlphaComponent:0.8];
    }];
}
BOOL YTMUInterfaceIsLight(UIView *v) {
    return v.traitCollection.userInterfaceStyle == UIUserInterfaceStyleLight;
}

%hook YTMLightweightMusicDescriptionShelfCell

- (void)layoutSubviews {
    %orig;

    UILabel *descriptionLabel = [self valueForKey:@"_descriptionLabel"];
    if (descriptionLabel) {
        CGRect f = descriptionLabel.frame;
        if (f.origin.x < 18) {
            CGFloat diff = 18 - f.origin.x;
            f.origin.x = 18;
            f.size.width = MAX(0, f.size.width - diff);
            descriptionLabel.frame = f;
        }
    }

    if ([self respondsToSelector:@selector(lyrics)] && self.lyrics) {
        CGRect f = self.lyrics.frame;
        if (f.origin.x < 18) {
            CGFloat diff = 18 - f.origin.x;
            f.origin.x = 18;
            f.size.width = MAX(0, f.size.width - diff);
            self.lyrics.frame = f;
        }
        self.lyrics.textContainerInset = UIEdgeInsetsMake(0, 4, 0, 4);
    }
}

- (void)setRenderer:(id)renderer {
    %orig;

    sendDebugLog(@"[OK] 成功進入歌詞 Cell (YTMLightweightMusicDescriptionShelfCell)");

    UILabel *descriptionLabel = [self valueForKey:@"_descriptionLabel"];
    if (!descriptionLabel) {
        sendDebugLog(@"[WARN]️ 找不到 _descriptionLabel");
        return;
    }

    if (!g_lyricsCache) {
        g_lyricsCache = [[NSMutableDictionary alloc] init];
    }

    NSString *videoID = g_currentVideoID;
    if (!videoID) return;

    if (g_lyricsCache[videoID]) {
        NSString *translatedText = g_lyricsCache[videoID];
        descriptionLabel.text = translatedText;

        if ([self respondsToSelector:@selector(lyrics)] && self.lyrics) {
            self.lyrics.text = translatedText;
        }
        return;
    }

    sendDebugLog([NSString stringWithFormat:@"準備向伺服器要歌詞: %@", videoID]);

    NSString *serverURL = [NSString stringWithFormat:@"%@/api/lyrics?v=%@&lang=%@%@", YTMUApiBase(), videoID, YTMUUrlEncode(YTMUTargetLang()), YTMUAutoZhParam()];
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:serverURL]];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && data) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (json && json[@"translated_lyrics"]) {
                NSString *newLyrics = json[@"translated_lyrics"];
                g_lyricsCache[videoID] = newLyrics;

                dispatch_async(dispatch_get_main_queue(), ^{
                    if ([g_currentVideoID isEqualToString:videoID]) {
                        descriptionLabel.text = newLyrics;

                        if ([self respondsToSelector:@selector(lyrics)] && self.lyrics) {
                            self.lyrics.text = newLyrics;
                        }
                        [self setNeedsLayout];
                    }
                });
            }
        }
    }] resume];
}

%end


@implementation YTMULyricsCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        self.lyricLabel = [[UILabel alloc] init];
        self.lyricLabel.numberOfLines = 0;
        self.lyricLabel.font = [UIFont boldSystemFontOfSize:22];
        self.lyricLabel.textColor = YTMUAdaptiveInk(0.45, 0.55);
        self.lyricLabel.layer.shadowColor = YTMUAdaptiveShadow().CGColor;
        self.lyricLabel.layer.shadowOffset = CGSizeMake(0, 2);
        self.lyricLabel.layer.shadowRadius = 4.0;
        self.lyricLabel.layer.masksToBounds = NO;
        self.lyricLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:self.lyricLabel];

        self.wipeLabel = [[UILabel alloc] init];
        self.wipeLabel.numberOfLines = 0;
        self.wipeLabel.font = [UIFont boldSystemFontOfSize:22];
        self.wipeLabel.textColor = YTMUAdaptiveInk(1.0, 1.0);
        self.wipeLabel.layer.shadowColor = YTMUAdaptiveShadow().CGColor;
        self.wipeLabel.layer.shadowOffset = CGSizeMake(0, 2);
        self.wipeLabel.layer.shadowRadius = 4.0;
        self.wipeLabel.layer.shadowOpacity = 0.75;
        self.wipeLabel.layer.masksToBounds = NO;
        self.wipeLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.wipeLabel.userInteractionEnabled = YES;
        [self.contentView addSubview:self.wipeLabel];

        // Word-level tap-to-seek gesture
        UITapGestureRecognizer *tapGR = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(ytmu_handleWordTap:)];
        [self.wipeLabel addGestureRecognizer:tapGR];

        self.wipeMask = [CAShapeLayer layer];
        self.wipeMask.fillColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
            return tc.userInterfaceStyle == UIUserInterfaceStyleLight ? [UIColor blackColor] : [UIColor whiteColor];
        }].CGColor;
        self.wipeMask.frame = CGRectZero;
        self.wipeLabel.layer.mask = self.wipeMask;
        _wipeProgress = 0.0;

        self.transLabel = [[UILabel alloc] init];
        self.transLabel.numberOfLines = 0;
        self.transLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        self.transLabel.textColor = YTMUAdaptiveInk(0.32, 0.5);
        self.transLabel.layer.shadowColor = YTMUAdaptiveShadow().CGColor;
        self.transLabel.layer.shadowOffset = CGSizeMake(0, 1);
        self.transLabel.layer.shadowRadius = 2.0;
        self.transLabel.layer.shadowOpacity = 0.35;
        self.transLabel.layer.masksToBounds = NO;
        self.transLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:self.transLabel];

        [NSLayoutConstraint activateConstraints:@[
            [self.lyricLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12],
            [self.lyricLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:20],
            [self.lyricLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-20],

            [self.wipeLabel.topAnchor constraintEqualToAnchor:self.lyricLabel.topAnchor],
            [self.wipeLabel.leadingAnchor constraintEqualToAnchor:self.lyricLabel.leadingAnchor],
            [self.wipeLabel.trailingAnchor constraintEqualToAnchor:self.lyricLabel.trailingAnchor],
            [self.wipeLabel.bottomAnchor constraintEqualToAnchor:self.lyricLabel.bottomAnchor],

            [self.transLabel.topAnchor constraintEqualToAnchor:self.lyricLabel.bottomAnchor constant:5],
            [self.transLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:20],
            [self.transLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-20],
            [self.transLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-12]
        ]];
    }
    return self;
}

- (void)setWipeProgress:(CGFloat)progress {
    _wipeProgress = MIN(MAX(progress, 0.0), 1.0);
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.wipeMask.frame = self.wipeLabel.bounds;
}

- (void)clearWipe {
    _wipeProgress = 0.0;
    self.wipeLabel.text = nil;
    self.wipeLabel.attributedText = nil;
    self.wipeMask.path = nil;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    _wipeProgress = 0.0;
    self.lyricLabel.alpha = 1.0;
    self.lyricLabel.transform = CGAffineTransformIdentity;
    self.wipeLabel.text = nil;
    self.wipeLabel.attributedText = nil;
    self.wipeMask.path = nil;
    self.lyricLabel.attributedText = nil;
}

- (void)ytmu_handleWordTap:(UITapGestureRecognizer *)gesture {
    CGPoint point = [gesture locationInView:self.wipeLabel];
    YTMULyricsViewController *vc = (YTMULyricsViewController *)[self _viewControllerForAncestor];
    if (!vc || !vc.isSynced) return;
    NSIndexPath *indexPath = [vc.tableView indexPathForCell:self];
    if (!indexPath) return;
    NSDictionary *lyric = vc.lyrics[indexPath.row];
    NSArray *parts = lyric[@"parts"];
    if (![lyric[@"wordSynced"] boolValue] || parts.count == 0) return;
    UIFont *font = self.wipeLabel.font;
    if (!font) font = [UIFont boldSystemFontOfSize:22];
    NSArray *ranges = nil;
    NSString *display = [vc wbwDisplayTextForLyric:lyric ranges:&ranges];
    if (ranges.count == 0) return;
    
    NSTextStorage *ts = [[NSTextStorage alloc] initWithString:display attributes:@{NSFontAttributeName: font}];
    NSLayoutManager *lm = [[NSLayoutManager alloc] init];
    NSTextContainer *tc = [[NSTextContainer alloc] initWithSize:self.wipeLabel.bounds.size];
    tc.lineFragmentPadding = 0;
    tc.maximumNumberOfLines = 0;
    tc.lineBreakMode = NSLineBreakByWordWrapping;
    [lm addTextContainer:tc];
    [ts addLayoutManager:lm];
    [lm ensureLayoutForTextContainer:tc];
    
    NSInteger charIndex = [lm characterIndexForPoint:point inTextContainer:tc fractionOfDistanceBetweenInsertionPoints:NULL];
    for (NSInteger i = 0; i < ranges.count; i++) {
        NSRange r = [ranges[i] rangeValue];
        if (r.location != NSNotFound && r.length > 0 && NSLocationInRange(charIndex, r)) {
            NSDictionary *part = parts[i];
            double startMs = [part[@"startTimeMs"] doubleValue];
            double seekTime = startMs / 1000.0;
            [[NSNotificationCenter defaultCenter] postNotificationName:@"YTMUSeekToTime" object:@(seekTime)];
            break;
        }
    }
}

@end


static BOOL __attribute__((unused)) YTMUIsLandscapeBounds(CGSize size) {
    return size.width > size.height;
}

// Private selectors used across the controller
@interface YTMULyricsViewController (LandscapePrivate)
- (void)ytmu_updateLandscapeMetadata;
- (void)ytmu_updateLandscapeMetadataFromNowPlayingLabels;
- (void)ytmu_collectNowPlayingLabelsIn:(UIView *)view depth:(NSInteger)depth out:(NSMutableArray *)out;
- (void)ytmu_updateLandscapeProgress;
- (void)ytmu_landscapePrev:(UIButton *)sender;
- (void)ytmu_landscapeNext:(UIButton *)sender;
- (void)ytmu_landscapePlayPause:(UIButton *)sender;
- (void)ytmu_setLandscapePlaying:(BOOL)playing;
- (void)ytmu_setLandscapeTransportIcons;
- (BOOL)ytmu_tryTapPlayPauseIn:(UIView *)view depth:(NSInteger)depth;
@end

BOOL YTMUIsInterfaceLandscape(void) {
    UIInterfaceOrientation o = UIInterfaceOrientationUnknown;
    if (@available(iOS 13.0, *)) {
        UIWindow *win = [UIApplication sharedApplication].keyWindow;
        if (!win) {
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                if (w.isKeyWindow || w.rootViewController) { win = w; break; }
            }
        }
        o = win.windowScene.interfaceOrientation;
    }
    if (o != UIInterfaceOrientationUnknown) {
        return UIInterfaceOrientationIsLandscape(o);
    }
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = (UIWindowScene *)[UIApplication sharedApplication].connectedScenes.anyObject;
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            return UIInterfaceOrientationIsLandscape(scene.interfaceOrientation);
        }
    }
    CGSize s = [UIScreen mainScreen].bounds.size;
    return s.width > s.height;
}

static void YTMUInvokeNoArgs(id obj, SEL sel) {
    if (!obj || ![obj respondsToSelector:sel]) return;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [obj performSelector:sel];
#pragma clang diagnostic pop
}

@implementation YTMULyricsViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.currentIndex = -1;
    self.suppressWordSeekRow = -1;
    self.view.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        return tc.userInterfaceStyle == UIUserInterfaceStyleLight ? [UIColor systemBackgroundColor] : [[UIColor blackColor] colorWithAlphaComponent:0.95];
    }];

    self.artworkImageView = [[UIImageView alloc] initWithFrame:self.view.bounds];
    self.artworkImageView.contentMode = UIViewContentModeScaleAspectFill;
    self.artworkImageView.clipsToBounds = YES;
    self.artworkImageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view insertSubview:self.artworkImageView atIndex:0];

    UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:(YTMUInterfaceIsLight(self.view) ? UIBlurEffectStyleLight : UIBlurEffectStyleDark)];
    self.blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    self.blurView.frame = self.view.bounds;
    self.blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view insertSubview:self.blurView aboveSubview:self.artworkImageView];

    self.darkOverlay = [[UIView alloc] initWithFrame:self.view.bounds];
    self.darkOverlay.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        if (tc.userInterfaceStyle == UIUserInterfaceStyleLight)
            return [[UIColor blackColor] colorWithAlphaComponent:0.30];
        return [[UIColor blackColor] colorWithAlphaComponent:0.48];
    }];
    self.darkOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view insertSubview:self.darkOverlay aboveSubview:self.blurView];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.showsVerticalScrollIndicator = NO;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 85.0;
    self.tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.tableView.contentInset = UIEdgeInsetsMake(20, 0, 350, 0);
    [self.tableView registerClass:[YTMULyricsCell class] forCellReuseIdentifier:@"YTMULyricsCell"];

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 54)];
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UILabel *statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 10, self.view.bounds.size.width, 36)];
    statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    statusLabel.textColor = YTMUAdaptiveInk(0.7, 0.75);
    statusLabel.textAlignment = NSTextAlignmentCenter;
    statusLabel.font = [UIFont systemFontOfSize:14];
    statusLabel.tag = 8888;
    [header addSubview:statusLabel];

    UIButton *reloadBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    reloadBtn.frame = CGRectMake(self.view.bounds.size.width - 105, 10, 85, 34);
    reloadBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [reloadBtn setTitle:@"Reload" forState:UIControlStateNormal];
    [reloadBtn setTitleColor:YTMUAdaptiveInk(0.9, 0.9) forState:UIControlStateNormal];
    reloadBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    reloadBtn.titleLabel.adjustsFontSizeToFitWidth = YES;
    reloadBtn.titleLabel.minimumScaleFactor = 0.7;
    reloadBtn.backgroundColor = YTMUAdaptiveFill();
    reloadBtn.layer.cornerRadius = 17;
    [reloadBtn addTarget:self action:@selector(forceReloadLyrics) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:reloadBtn];

    if (self.isModal || self.presentingViewController) {
        UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        closeBtn.frame = CGRectMake(16, 10, 36, 36);
        [closeBtn setTitle:@"X" forState:UIControlStateNormal];
        [closeBtn setTitleColor:YTMUAdaptiveInk(1.0, 1.0) forState:UIControlStateNormal];
        closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:18];
        closeBtn.backgroundColor = YTMUAdaptiveFill();
        closeBtn.layer.cornerRadius = 18;
        [closeBtn addTarget:self action:@selector(dismissModal) forControlEvents:UIControlEventTouchUpInside];
        [header addSubview:closeBtn];
    }

    // Offset controls are hidden from the header UI (per-song offset still
    // applies internally via YTMULyricsOffsetForVideoID when set).
    self.offsetButton = nil;

    self.tableView.tableHeaderView = header;

    [self.view addSubview:self.tableView];

    // --- Landscape split-view panels ---
    // Both panels share one opaque dark background so there is no visible
    // seam between the album side and the lyrics side. The fullscreen
    // blurred video/artwork background is hidden in landscape, so album art
    // sits on the same solid color as the lyrics (no letterbox contrast).
    static const CGFloat kYTMULandscapePanelAlpha = 0.92;
    self.landscapeArtPanel = [[UIView alloc] initWithFrame:CGRectZero];
    self.landscapeArtPanel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:kYTMULandscapePanelAlpha];
    self.landscapeArtPanel.clipsToBounds = YES;
    self.landscapeArtPanel.hidden = YES;
    self.landscapeArtPanel.userInteractionEnabled = YES;
    [self.view addSubview:self.landscapeArtPanel];

    self.landscapeArtImageView = [[UIImageView alloc] initWithFrame:CGRectZero];
    self.landscapeArtImageView.contentMode = UIViewContentModeScaleAspectFit;
    self.landscapeArtImageView.clipsToBounds = YES;
    self.landscapeArtImageView.backgroundColor = [UIColor clearColor];
    self.landscapeArtImageView.userInteractionEnabled = NO;
    [self.landscapeArtPanel addSubview:self.landscapeArtImageView];

    // Right panel: same solid tint as the left panel (seamless transition)
    self.landscapeRightPanel = [[UIView alloc] initWithFrame:CGRectZero];
    self.landscapeRightPanel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:kYTMULandscapePanelAlpha];
    self.landscapeRightPanel.clipsToBounds = YES;
    self.landscapeRightPanel.hidden = YES;
    self.landscapeRightPanel.userInteractionEnabled = NO;
    [self.view addSubview:self.landscapeRightPanel];

    // Landscape left info: title, artist, progress, transport
    self.landscapeInfoPanel = [[UIView alloc] initWithFrame:CGRectZero];
    self.landscapeInfoPanel.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12];
    self.landscapeInfoPanel.hidden = YES;
    self.landscapeInfoPanel.layer.cornerRadius = 12;
    self.landscapeInfoPanel.layer.masksToBounds = YES;
    self.landscapeInfoPanel.userInteractionEnabled = YES;
    [self.landscapeArtPanel addSubview:self.landscapeInfoPanel];

    self.landscapeTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.landscapeTitleLabel.font = [UIFont boldSystemFontOfSize:15];
    self.landscapeTitleLabel.textColor = [UIColor whiteColor];
    self.landscapeTitleLabel.numberOfLines = 1;
    self.landscapeTitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.landscapeInfoPanel addSubview:self.landscapeTitleLabel];

    self.landscapeArtistLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.landscapeArtistLabel.font = [UIFont systemFontOfSize:12];
    self.landscapeArtistLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.75];
    self.landscapeArtistLabel.numberOfLines = 1;
    self.landscapeArtistLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.landscapeInfoPanel addSubview:self.landscapeArtistLabel];

    self.landscapeProgressTrack = [[UIView alloc] initWithFrame:CGRectZero];
    self.landscapeProgressTrack.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.25];
    self.landscapeProgressTrack.layer.cornerRadius = 2;
    self.landscapeProgressTrack.layer.masksToBounds = YES;
    [self.landscapeInfoPanel addSubview:self.landscapeProgressTrack];

    self.landscapeProgressFill = [[UIView alloc] initWithFrame:CGRectZero];
    self.landscapeProgressFill.backgroundColor = [UIColor whiteColor];
    self.landscapeProgressFill.layer.cornerRadius = 2;
    self.landscapeProgressFill.layer.masksToBounds = YES;
    [self.landscapeProgressTrack addSubview:self.landscapeProgressFill];

    self.landscapePrevButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.landscapePrevButton.tintColor = [UIColor whiteColor];
    self.landscapePrevButton.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    self.landscapePrevButton.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
    self.landscapePrevButton.layer.cornerRadius = 18;
    self.landscapePrevButton.tag = 7101;
    self.landscapePrevButton.accessibilityLabel = @"Previous track";
    self.landscapePrevButton.userInteractionEnabled = YES;
    self.landscapePrevButton.exclusiveTouch = NO;
    [self.landscapePrevButton addTarget:self action:@selector(ytmu_landscapePrev:) forControlEvents:UIControlEventTouchUpInside];
    [self.landscapeInfoPanel addSubview:self.landscapePrevButton];

    self.landscapePlayButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.landscapePlayButton.tintColor = [UIColor whiteColor];
    self.landscapePlayButton.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    self.landscapePlayButton.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.22];
    self.landscapePlayButton.layer.cornerRadius = 20;
    self.landscapePlayButton.tag = 7102;
    self.landscapePlayButton.accessibilityLabel = @"Play or pause";
    self.landscapePlayButton.userInteractionEnabled = YES;
    self.landscapePlayButton.exclusiveTouch = NO;
    [self.landscapePlayButton addTarget:self action:@selector(ytmu_landscapePlayPause:) forControlEvents:UIControlEventTouchUpInside];
    [self.landscapeInfoPanel addSubview:self.landscapePlayButton];

    self.landscapeNextButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.landscapeNextButton.tintColor = [UIColor whiteColor];
    self.landscapeNextButton.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    self.landscapeNextButton.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
    self.landscapeNextButton.layer.cornerRadius = 18;
    self.landscapeNextButton.tag = 7103;
    self.landscapeNextButton.accessibilityLabel = @"Next track";
    self.landscapeNextButton.userInteractionEnabled = YES;
    self.landscapeNextButton.exclusiveTouch = NO;
    [self.landscapeNextButton addTarget:self action:@selector(ytmu_landscapeNext:) forControlEvents:UIControlEventTouchUpInside];
    [self.landscapeInfoPanel addSubview:self.landscapeNextButton];
    self.landscapeIsPlaying = YES;
    [self ytmu_setLandscapeTransportIcons];

    // Exit: top-right icon button (xmark symbol, "X" text fallback)
    self.landscapeExitButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.landscapeExitButton.tintColor = [UIColor whiteColor];
    if (@available(iOS 13.0, *)) {
        UIImage *xmark = [UIImage systemImageNamed:@"xmark"];
        if (xmark) {
            [self.landscapeExitButton setImage:xmark forState:UIControlStateNormal];
            [self.landscapeExitButton setTitle:@"" forState:UIControlStateNormal];
        } else {
            [self.landscapeExitButton setTitle:@"X" forState:UIControlStateNormal];
            [self.landscapeExitButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            self.landscapeExitButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        }
    } else {
        [self.landscapeExitButton setTitle:@"X" forState:UIControlStateNormal];
        [self.landscapeExitButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        self.landscapeExitButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    }
    self.landscapeExitButton.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.20];
    self.landscapeExitButton.layer.cornerRadius = 16;
    self.landscapeExitButton.hidden = YES;
    [self.landscapeExitButton addTarget:self action:@selector(dismissModal) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.landscapeExitButton];

    self.fpsLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 64, 140, 24)];
    self.fpsLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
    self.fpsLabel.textColor = YTMUAdaptiveInk(0.7, 0.75);
    self.fpsLabel.hidden = YES;
    self.fpsLabel.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
    [self.view addSubview:self.fpsLabel];
    self.fpsTicks = 0;
    self.fpsWindowStart = 0;
    self.lastVolume = -1;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ytmu_volumeChanged:) name:@"AVSystemController_SystemVolumeDidChangeNotification" object:nil];

    self.lyrics = @[];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleSongChange:) name:@"YTMUSongDidChange" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleLyricsDidLoad:) name:@"YTMULyricsDidLoad" object:nil];

    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(updatePlaybackTime)];
    if (@available(iOS 15.0, *)) {
        self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(60, 120, 120);
    } else if ([self.displayLink respondsToSelector:@selector(setPreferredFramesPerSecond:)]) {
        self.displayLink.preferredFramesPerSecond = 120;
    }
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

    [self ytmu_refreshOffsetLabel];
}

- (void)ytmu_refreshOffsetLabel {
    if (!self.offsetButton) return;
    double offset = (g_currentVideoID.length) ? YTMULyricsOffsetForVideoID(g_currentVideoID) : 0.0;
    if (fabs(offset) < 0.05) {
        [self.offsetButton setTitle:@"±0.0s" forState:UIControlStateNormal];
    } else {
        [self.offsetButton setTitle:[NSString stringWithFormat:@"%+.1fs", offset] forState:UIControlStateNormal];
    }
}

- (void)ytmu_nudgeOffset:(UIButton *)sender {
    double delta = (sender.tag == 0) ? -0.5 : 0.5;
    double offset = YTMULyricsOffsetForVideoID(g_currentVideoID);
    offset += delta;
    if (offset > 30.0) offset = 30.0;
    if (offset < -30.0) offset = -30.0;
    YTMULyricsSetOffsetForVideoID(g_currentVideoID, offset);
    [self ytmu_refreshOffsetLabel];
}

- (void)ytmu_resetOffset {
    YTMULyricsSetOffsetForVideoID(g_currentVideoID, 0.0);
    [self ytmu_refreshOffsetLabel];
}

- (void)dismissModal {
    if (self.presentingViewController || self.navigationController.presentingViewController) {
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    // Embedded (engagement panel tag 9999): hide so landscape can re-present cleanly
    if (self.view.superview) {
        self.view.hidden = YES;
        sendDebugLog(@"[MUSIC] landscape exit: hid embedded lyrics view");
    }
}

- (void)ytmu_updateLandscapeMetadata {
    NSString *title = nil;
    NSString *artist = nil;
    @try {
        YTPlayerViewController *player = g_activePlayer;
        if (player && [player respondsToSelector:@selector(playerResponse)]) {
            YTPlayerResponse *resp = player.playerResponse;
            if (resp && [resp respondsToSelector:@selector(playerData)]) {
                YTIPlayerResponse *data = resp.playerData;
                if (data && [data respondsToSelector:@selector(videoDetails)]) {
                    YTIVideoDetails *details = data.videoDetails;
                    if (details) {
                        if ([details respondsToSelector:@selector(title)]) title = details.title;
                        if ([details respondsToSelector:@selector(author)]) artist = details.author;
                    }
                }
            }
        }
    } @catch (NSException *e) {
        title = nil;
        artist = nil;
    }
    // Only overwrite with real values; never blank out a known title/artist
    // (playerResponse can be momentarily nil during track transitions).
    if (title.length) {
        self.landscapeTitleLabel.text = title;
    } else if (!self.landscapeTitleLabel.text.length) {
        self.landscapeTitleLabel.text = @"Now Playing";
    }
    if (artist.length) {
        self.landscapeArtistLabel.text = artist;
    }
    // playerResponse path can stay nil (e.g. response not parsed yet) — fall
    // back to the visible now-playing labels so title/artist still show.
    if (!title.length || !artist.length) {
        [self ytmu_updateLandscapeMetadataFromNowPlayingLabels];
    }
}

- (void)ytmu_collectNowPlayingLabelsIn:(UIView *)view depth:(NSInteger)depth out:(NSMutableArray *)out {
    if (!view || depth > 7) return;
    if ([view isKindOfClass:[UILabel class]]) {
        NSString *txt = [((UILabel *)view).text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (txt.length >= 2 && txt.length <= 100) {
            NSString *low = txt.lowercaseString;
            BOOL junk = ([txt containsString:@"歌詞"] || [txt containsString:@"歌词"] ||
                         [low containsString:@"lyric"] || [low containsString:@"unavailable"] ||
                         [txt containsString:@"沒有歌詞"] || [txt containsString:@"没有歌词"] ||
                         [txt isEqualToString:@"Now Playing"]);
            // Skip time labels like "1:23" / "1:23 / 4:56".
            if (!junk) {
                NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"0123456789: /-"];
                if ([txt rangeOfCharacterFromSet:[allowed invertedSet]].location == NSNotFound) junk = YES;
            }
            if (!junk) {
                CGRect r = [view convertRect:view.bounds toView:nil];
                [out addObject:@{@"text": txt, @"y": @(r.origin.y)}];
            }
        }
    }
    for (UIView *sub in view.subviews) {
        [self ytmu_collectNowPlayingLabelsIn:sub depth:depth + 1 out:out];
    }
}

- (void)ytmu_updateLandscapeMetadataFromNowPlayingLabels {
    UIViewController *np = g_activeNowPlayingVC;
    if (!np || !np.isViewLoaded) return;
    BOOL needTitle = (self.landscapeTitleLabel.text.length == 0 ||
                      [self.landscapeTitleLabel.text isEqualToString:@"Now Playing"]);
    BOOL needArtist = (self.landscapeArtistLabel.text.length == 0);
    if (!needTitle && !needArtist) return;
    NSMutableArray *found = [NSMutableArray array];
    [self ytmu_collectNowPlayingLabelsIn:np.view depth:0 out:found];
    if (found.count == 0) return;
    // Topmost label first: title usually sits above artist.
    [found sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"y"] compare:b[@"y"]];
    }];
    NSMutableArray *ordered = [NSMutableArray array];
    for (NSDictionary *d in found) {
        if (![ordered containsObject:d[@"text"]]) [ordered addObject:d[@"text"]];
    }
    if (needTitle && ordered.count > 0) {
        self.landscapeTitleLabel.text = ordered[0];
    }
    if (needArtist && ordered.count > 1) {
        self.landscapeArtistLabel.text = ordered[1];
    }
}

- (void)ytmu_updateLandscapeProgress {
    if (!self.landscapeProgressFill || !self.landscapeProgressTrack) return;
    CGFloat progress = 0;
    if (g_activePlayer && [g_activePlayer respondsToSelector:@selector(currentVideoTotalMediaTime)]) {
        CGFloat total = g_activePlayer.currentVideoTotalMediaTime;
        CGFloat cur = g_activePlayer.currentVideoMediaTime;
        if (total > 0) progress = (CGFloat)(cur / total);
    } else if (g_currentPlaybackTime > 0) {
        progress = 0; // unknown total; leave at 0 unless total known
    }
    if (progress < 0) progress = 0;
    if (progress > 1) progress = 1;
    CGFloat trackW = self.landscapeProgressTrack.bounds.size.width;
    CGRect f = self.landscapeProgressFill.frame;
    f.size.width = floor(trackW * progress);
    f.size.height = 4;
    f.origin = CGPointZero;
    self.landscapeProgressFill.frame = f;
}

- (void)ytmu_setLandscapePlaying:(BOOL)playing {
    self.landscapeIsPlaying = playing;
    if (@available(iOS 13.0, *)) {
        UIImage *img = [UIImage systemImageNamed:playing ? @"pause.fill" : @"play.fill"];
        if (img) {
            [self.landscapePlayButton setImage:img forState:UIControlStateNormal];
            [self.landscapePlayButton setTitle:@"" forState:UIControlStateNormal];
            return;
        }
    }
    [self.landscapePlayButton setImage:nil forState:UIControlStateNormal];
    [self.landscapePlayButton setTitle:playing ? @"pause" : @"play" forState:UIControlStateNormal];
    [self.landscapePlayButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
}

- (void)ytmu_setLandscapeTransportIcons {
    if (@available(iOS 13.0, *)) {
        UIImage *prev = [UIImage systemImageNamed:@"backward.fill"];
        UIImage *next = [UIImage systemImageNamed:@"forward.fill"];
        if (prev) {
            [self.landscapePrevButton setImage:prev forState:UIControlStateNormal];
            [self.landscapePrevButton setTitle:@"" forState:UIControlStateNormal];
        } else {
            [self.landscapePrevButton setTitle:@"prev" forState:UIControlStateNormal];
            [self.landscapePrevButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        }
        if (next) {
            [self.landscapeNextButton setImage:next forState:UIControlStateNormal];
            [self.landscapeNextButton setTitle:@"" forState:UIControlStateNormal];
        } else {
            [self.landscapeNextButton setTitle:@"next" forState:UIControlStateNormal];
            [self.landscapeNextButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        }
    } else {
        [self.landscapePrevButton setTitle:@"prev" forState:UIControlStateNormal];
        [self.landscapePrevButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [self.landscapeNextButton setTitle:@"next" forState:UIControlStateNormal];
        [self.landscapeNextButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    }
    [self ytmu_setLandscapePlaying:self.landscapeIsPlaying];
}

- (void)ytmu_landscapePrev:(UIButton *)sender {
    UIViewController *np = g_activeNowPlayingVC;
    if (np && [np respondsToSelector:@selector(didTapPrevButton)]) {
        YTMUInvokeNoArgs(np, @selector(didTapPrevButton));
        sendDebugLog(@"[MUSIC] landscape prev via now-playing VC");
        return;
    }
    UIViewController *top = topMostViewController();
    if (top && [top respondsToSelector:@selector(didTapPrevButton)]) {
        YTMUInvokeNoArgs(top, @selector(didTapPrevButton));
        sendDebugLog(@"[MUSIC] landscape prev via top VC");
        return;
    }
    sendDebugLog(@"[MUSIC] landscape prev: no handler (nowPlayingVC nil or missing selector)");
}

- (void)ytmu_landscapeNext:(UIButton *)sender {
    UIViewController *np = g_activeNowPlayingVC;
    if (np && [np respondsToSelector:@selector(didTapNextButton)]) {
        YTMUInvokeNoArgs(np, @selector(didTapNextButton));
        sendDebugLog(@"[MUSIC] landscape next via now-playing VC");
        return;
    }
    UIViewController *top = topMostViewController();
    if (top && [top respondsToSelector:@selector(didTapNextButton)]) {
        YTMUInvokeNoArgs(top, @selector(didTapNextButton));
        sendDebugLog(@"[MUSIC] landscape next via top VC");
        return;
    }
    sendDebugLog(@"[MUSIC] landscape next: no handler (nowPlayingVC nil or missing selector)");
}

- (void)ytmu_landscapePlayPause:(UIButton *)sender {
    // Drive playback through the player directly: explicit pause/play based
    // on our tracked state beats toggle selectors that may not exist on the
    // current now-playing VC. Player first, now-playing VC as fallback.
    BOOL wantPause = self.landscapeIsPlaying;
    YTPlayerViewController *player = g_activePlayer;
    if (player) {
        SEL playPause = wantPause ? @selector(pause) : @selector(play);
        if ([player respondsToSelector:playPause]) {
            YTMUInvokeNoArgs(player, playPause);
            [self ytmu_setLandscapePlaying:!self.landscapeIsPlaying];
            sendDebugLog(wantPause ? @"[MUSIC] landscape pause via player" : @"[MUSIC] landscape play via player");
            return;
        }
        if ([player respondsToSelector:@selector(togglePlayPause)]) {
            YTMUInvokeNoArgs(player, @selector(togglePlayPause));
            [self ytmu_setLandscapePlaying:!self.landscapeIsPlaying];
            sendDebugLog(@"[MUSIC] landscape play/pause via player toggle");
            return;
        }
    }
    UIViewController *np = g_activeNowPlayingVC;
    if (np && [np respondsToSelector:@selector(didTapPlayPauseButton)]) {
        YTMUInvokeNoArgs(np, @selector(didTapPlayPauseButton));
        [self ytmu_setLandscapePlaying:!self.landscapeIsPlaying];
        sendDebugLog(@"[MUSIC] landscape play/pause via now-playing VC");
        return;
    }
    if (np && [np respondsToSelector:@selector(togglePlayPause)]) {
        YTMUInvokeNoArgs(np, @selector(togglePlayPause));
        [self ytmu_setLandscapePlaying:!self.landscapeIsPlaying];
        sendDebugLog(@"[MUSIC] landscape play/pause via now-playing toggle");
        return;
    }
    // Fallback: send touch to any play/pause control under now-playing view
    UIView *npView = (np && np.isViewLoaded) ? np.view : nil;
    if (npView) {
        for (UIView *sub in npView.subviews) {
            if ([self ytmu_tryTapPlayPauseIn:sub depth:0]) {
                [self ytmu_setLandscapePlaying:!self.landscapeIsPlaying];
                sendDebugLog(@"[MUSIC] landscape play/pause via now-playing sub-control");
                return;
            }
        }
    }
    UIViewController *top = topMostViewController();
    if (top && top != (UIViewController *)self && [top respondsToSelector:@selector(didTapPlayPauseButton)]) {
        YTMUInvokeNoArgs(top, @selector(didTapPlayPauseButton));
        [self ytmu_setLandscapePlaying:!self.landscapeIsPlaying];
        sendDebugLog(@"[MUSIC] landscape play/pause via top VC");
        return;
    }
    sendDebugLog(@"[MUSIC] landscape play/pause: no handler (nowPlayingVC nil or missing selector)");
}

- (BOOL)ytmu_tryTapPlayPauseIn:(UIView *)view depth:(NSInteger)depth {
    if (!view || depth > 8) return NO;
    if ([view isKindOfClass:[UIControl class]]) {
        NSString *label = view.accessibilityLabel.lowercaseString ?: @"";
        NSString *ident = view.accessibilityIdentifier.lowercaseString ?: @"";
        if ([label containsString:@"pause"] || [label containsString:@"play"] ||
            [ident containsString:@"pause"] || [ident containsString:@"play"]) {
            [(UIControl *)view sendActionsForControlEvents:UIControlEventTouchUpInside];
            return YES;
        }
    }
    for (UIView *sub in view.subviews) {
        if ([self ytmu_tryTapPlayPauseIn:sub depth:depth + 1]) return YES;
    }
    return NO;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGFloat W = self.view.bounds.size.width;
    CGFloat H = self.view.bounds.size.height;
    BOOL landscape = (W > H);

    if (landscape) {
        // --- Landscape: smaller video/art left + right lyrics panel ---
        // Hide the fullscreen blurred video/artwork background so the album
        // image sits on the same solid color as the lyrics panel.
        self.artworkImageView.hidden = YES;
        self.blurView.hidden = YES;
        self.darkOverlay.hidden = YES;

        // Keep both panels on one identical background (no seam).
        UIColor *panelBG = [[UIColor blackColor] colorWithAlphaComponent:0.92];
        self.landscapeArtPanel.backgroundColor = panelBG;
        self.landscapeRightPanel.backgroundColor = panelBG;

        // Show landscape panels
        self.landscapeArtPanel.hidden = NO;
        self.landscapeRightPanel.hidden = NO;
        self.landscapeInfoPanel.hidden = NO;
        self.landscapeExitButton.hidden = NO;

        // Sync artwork image whenever it changes
        if (self.artworkImageView.image && self.landscapeArtImageView.image != self.artworkImageView.image) {
            self.landscapeArtImageView.image = self.artworkImageView.image;
        }

        // Left panel: 44% of width, full height — background behind smaller video
        CGFloat leftW = roundf(W * 0.44f);
        CGFloat rightW = W - leftW;
        self.landscapeArtPanel.frame = CGRectMake(0, 0, leftW, H);

        // Smaller video area: inset from top/sides, leave room for info panel
        CGFloat vidTop = 48.0;
        CGFloat infoH = 118.0;
        CGFloat vidBottomPad = infoH + 16.0;
        CGFloat vidX = 12.0;
        CGFloat vidW = leftW - (vidX * 2.0);
        CGFloat vidH = MAX(80.0, H - vidTop - vidBottomPad);
        // Prefer 16:9 when it fits
        CGFloat idealH = floor(vidW * 9.0 / 16.0);
        if (idealH < vidH) vidH = idealH;
        self.landscapeArtImageView.frame = CGRectMake(vidX, vidTop, vidW, vidH);
        self.landscapeArtImageView.contentMode = UIViewContentModeScaleAspectFit;
        self.landscapeArtImageView.layer.cornerRadius = 8;
        self.landscapeArtImageView.layer.masksToBounds = YES;

        // Info panel under the video: title, artist, bar, transport
        CGFloat infoY = CGRectGetMaxY(self.landscapeArtImageView.frame) + 12.0;
        self.landscapeInfoPanel.frame = CGRectMake(vidX, infoY, vidW, infoH);

        CGFloat pad = 10.0;
        self.landscapeTitleLabel.frame = CGRectMake(pad, 8, vidW - pad * 2, 20);
        self.landscapeArtistLabel.frame = CGRectMake(pad, 30, vidW - pad * 2, 16);

        CGFloat barY = 54;
        self.landscapeProgressTrack.frame = CGRectMake(pad, barY, vidW - pad * 2, 4);
        CGFloat progress = 0;
        if (g_activePlayer && [g_activePlayer respondsToSelector:@selector(currentVideoTotalMediaTime)]) {
            CGFloat total = g_activePlayer.currentVideoTotalMediaTime;
            CGFloat cur = g_activePlayer.currentVideoMediaTime;
            if (total > 0) progress = (CGFloat)(cur / total);
        }
        if (progress < 0) progress = 0;
        if (progress > 1) progress = 1;
        CGFloat trackW = self.landscapeProgressTrack.bounds.size.width;
        self.landscapeProgressFill.frame = CGRectMake(0, 0, floor(trackW * progress), 4);

        CGFloat btnY = 68;
        CGFloat btnH = 36;
        CGFloat btnW = 64;
        CGFloat playS = 40;
        CGFloat gap = 12;
        CGFloat totalBtnW = btnW + playS + btnW + gap * 2;
        CGFloat btnX0 = floor((vidW - totalBtnW) / 2.0);
        self.landscapePrevButton.frame = CGRectMake(btnX0, btnY, btnW, btnH);
        self.landscapePlayButton.frame = CGRectMake(btnX0 + btnW + gap, btnY + floor((btnH - playS) / 2.0), playS, playS);
        self.landscapeNextButton.frame = CGRectMake(btnX0 + btnW + gap + playS + gap, btnY, btnW, btnH);
        self.landscapePlayButton.layer.cornerRadius = playS / 2.0;
        self.landscapePrevButton.layer.cornerRadius = btnH / 2.0;
        self.landscapeNextButton.layer.cornerRadius = btnH / 2.0;

        // Top-right exit over the whole sheet (upper right of screen)
        CGFloat safeTop = 0;
        if (@available(iOS 11.0, *)) {
            safeTop = self.view.safeAreaInsets.top;
        }
        CGFloat exitTop = (safeTop > 0 ? safeTop + 6.0 : 12.0);
        CGFloat exitS = 32;
        self.landscapeExitButton.frame = CGRectMake(W - exitS - 12.0, exitTop, exitS, exitS);
        self.landscapeExitButton.layer.cornerRadius = exitS / 2.0;
        [self.view bringSubviewToFront:self.landscapeExitButton];

        // Keep title/artist fresh
        [self ytmu_updateLandscapeMetadata];

        // Right panel behind table
        self.landscapeRightPanel.frame = CGRectMake(leftW, 0, rightW, H);

        // tableView occupies right panel
        self.tableView.frame = CGRectMake(leftW, 0, rightW, H);
        [self.view bringSubviewToFront:self.landscapeArtPanel];
        [self.view bringSubviewToFront:self.tableView];
        [self.view bringSubviewToFront:self.fpsLabel];
        [self.view bringSubviewToFront:self.landscapeExitButton];
        [self.landscapeArtPanel bringSubviewToFront:self.landscapeInfoPanel];
        self.landscapeArtPanel.userInteractionEnabled = YES;
        self.landscapeInfoPanel.userInteractionEnabled = YES;

        // Smaller bottom inset in landscape (less scroll space needed)
        CGFloat bottomPad = MAX(120.0, H * 0.30f);
        UIEdgeInsets current = self.tableView.contentInset;
        if (fabs(current.bottom - bottomPad) > 1.0) {
            self.tableView.contentInset = UIEdgeInsetsMake(current.top, 0, bottomPad, 0);
            self.tableView.scrollIndicatorInsets = UIEdgeInsetsMake(0, 0, bottomPad, 0);
        }
        UIView *footer = self.tableView.tableFooterView;
        if (!footer || fabs(footer.frame.size.height - bottomPad) > 1.0) {
            UIView *f = [[UIView alloc] initWithFrame:CGRectMake(0, 0, rightW, bottomPad)];
            f.backgroundColor = [UIColor clearColor];
            self.tableView.tableFooterView = f;
        }
    } else {
        // --- Portrait: full-screen blurred artwork background ---
        self.artworkImageView.hidden = NO;
        self.blurView.hidden = NO;
        self.darkOverlay.hidden = NO;
        self.landscapeArtPanel.hidden = YES;
        self.landscapeRightPanel.hidden = YES;
        self.landscapeInfoPanel.hidden = YES;
        self.landscapeExitButton.hidden = YES;

        // Restore tableView to full bounds
        self.tableView.frame = self.view.bounds;

        CGFloat visibleHeight = H;
        CGFloat bottomPad = MAX(350.0, visibleHeight * 0.60);

        UIEdgeInsets current = self.tableView.contentInset;
        if (fabs(current.bottom - bottomPad) > 1.0) {
            self.tableView.contentInset = UIEdgeInsetsMake(current.top, 0, bottomPad, 0);
            self.tableView.scrollIndicatorInsets = UIEdgeInsetsMake(0, 0, bottomPad, 0);
        }
        UIView *existingFooter = self.tableView.tableFooterView;
        if (!existingFooter || fabs(existingFooter.frame.size.height - bottomPad) > 1.0) {
            UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, bottomPad)];
            footer.backgroundColor = [UIColor clearColor];
            self.tableView.tableFooterView = footer;
        }
    }

    // Header width sync (both orientations)
    UIView *header = self.tableView.tableHeaderView;
    if (header && fabs(header.frame.size.width - self.tableView.bounds.size.width) > 1.0) {
        header.frame = CGRectMake(0, 0, self.tableView.bounds.size.width, 54);
        self.tableView.tableHeaderView = header;
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.displayLink invalidate];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self ytmu_updateLandscapeMetadata];
    NSString *vid = YTMUResolveCurrentVideoID();
    if (vid && (![vid isEqualToString:self.loadingVideoID] || (self.lyrics.count == 0 && !self.isLoading))) {
        [self fetchLyricsForVideo:vid];
    }
}

- (void)handleLyricsDidLoad:(NSNotification *)notif {
    NSString *videoID = notif.object;
    NSArray *lyrics = notif.userInfo[@"lyrics"];
    if (videoID && lyrics && [videoID isEqualToString:g_currentVideoID]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UILabel *statusLabel = [self.tableView.tableHeaderView viewWithTag:8888];
            if (statusLabel) statusLabel.text = @"";
            [self updateLyrics:lyrics];
        });
    }
}

- (void)handleSongChange:(NSNotification *)notif {
    NSString *videoID = notif.object;
    if (videoID) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self.loadingVideoID isEqualToString:videoID]) {
                self.currentIndex = -1;
                UILabel *statusLabel = [self.tableView.tableHeaderView viewWithTag:8888];
                statusLabel.text = @"";
                self.lyrics = @[];
                [self.tableView reloadData];
                self.artworkVideoID = nil;
            }
            [self ytmu_updateLandscapeMetadata];
            [self fetchLyricsForVideo:videoID];
        });
    }
}

- (void)ytmu_volumeChanged:(NSNotification *)notif {
    if (!YTMULyricsPreference(@"lyricsFpsMeter", YES)) return;
    id param = notif.userInfo[@"AVSystemController_AudioVolumeNotificationParameter"];
    float vol = -1;
    if ([param isKindOfClass:[NSNumber class]]) {
        vol = [param floatValue];
    } else if ([param isKindOfClass:[NSDictionary class]]) {
        id v = ((NSDictionary *)param)[@"Volume"];
        if ([v isKindOfClass:[NSNumber class]]) vol = [v floatValue];
    }
    if (vol < 0) return;
    float prev = self.lastVolume;
    self.lastVolume = vol;
    if (prev >= 0 && vol < prev - 0.001) {
        self.fpsLabel.hidden = !self.fpsLabel.hidden;
        if (!self.fpsLabel.hidden) {
            self.fpsTicks = 0;
            self.fpsWindowStart = CACurrentMediaTime();
            self.fpsLabel.text = @"... fps";
        }
        sendDebugLog(@"[FPS] readout toggled by volume-down");
    }
}

- (void)loadArtworkForVideo:(NSString *)videoID {
    if (!videoID || videoID.length == 0) return;

    NSString *maxURL = [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/maxresdefault.jpg", videoID];
    [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:maxURL] completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
        NSHTTPURLResponse *httpRes = (NSHTTPURLResponse *)res;
        if (!err && data && httpRes.statusCode == 200) {
            UIImage *img = [UIImage imageWithData:data];
            if (img) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if ([self.loadingVideoID isEqualToString:videoID]) {
                        [UIView transitionWithView:self.artworkImageView duration:0.4 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
                            self.artworkImageView.image = img;
                        } completion:nil];
                        self.landscapeArtImageView.image = img;
                        self.artworkVideoID = videoID;
                    }
                });
                return;
            }
        }
        NSString *hqURL = [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/hqdefault.jpg", videoID];
        [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:hqURL] completionHandler:^(NSData *d2, NSURLResponse *r2, NSError *e2) {
            if (!e2 && d2) {
                UIImage *img2 = [UIImage imageWithData:d2];
                if (img2) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if ([self.loadingVideoID isEqualToString:videoID]) {
                            [UIView transitionWithView:self.artworkImageView duration:0.4 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
                                self.artworkImageView.image = img2;
                            } completion:nil];
                            self.landscapeArtImageView.image = img2;
                            self.artworkVideoID = videoID;
                        }
                    });
                }
            }
        }] resume];
    }] resume];
}

- (void)fetchFullLyricsForVideo:(NSString *)videoID jwt:(NSString *)jwt force:(BOOL)force {
    if (![self.loadingVideoID isEqualToString:videoID]) {
        self.isLoading = NO;
        self.loadingSince = nil;
        if ([g_globalLoadingVideoID isEqualToString:videoID]) {
            YTMUReleaseGlobalFetch();
        }
        return;
    }

    NSString *fullURL = [NSString stringWithFormat:@"%@/api/lyrics?v=%@&lang=%@%@", YTMUApiBase(), videoID, YTMUUrlEncode(YTMUTargetLang()), YTMUAutoZhParam()];
    if (force) {
        fullURL = [fullURL stringByAppendingString:@"&force=1"];
    }
    if (jwt) {
        fullURL = [fullURL stringByAppendingFormat:@"&jwt=%@", jwt];
    }

    [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:fullURL] completionHandler:^(NSData *fullData, NSURLResponse *fullRes, NSError *fullErr) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.isLoading = NO;
            self.loadingSince = nil;
            if ([g_globalLoadingVideoID isEqualToString:videoID]) {
                YTMUReleaseGlobalFetch();
            }

            if (![self.loadingVideoID isEqualToString:videoID]) return;

            UILabel *statusLabel = [self.tableView.tableHeaderView viewWithTag:8888];
            if (fullData && !fullErr) {
                NSDictionary *fullDict = [NSJSONSerialization JSONObjectWithData:fullData options:0 error:nil];
                if (fullDict && fullDict[@"lyrics"]) {
                    statusLabel.text = @"";
                    if (!g_lyricsCache) g_lyricsCache = [[NSMutableDictionary alloc] init];
                    g_lyricsCache[videoID] = fullDict[@"lyrics"];
                    YTMULyricsCacheSave(videoID, fullDict[@"lyrics"]);
                    [self updateLyrics:fullDict[@"lyrics"]];
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"YTMULyricsDidLoad"
                                                                        object:videoID
                                                                      userInfo:@{@"lyrics": fullDict[@"lyrics"]}];
                } else if (self.lyrics.count == 0) {
                    statusLabel.text = @"[WARN]️ 找不到歌詞 / No lyrics found";
                    if (self.isModal) self.view.hidden = NO;
                    self.lyrics = @[];
                    [self.tableView reloadData];
                }
            } else if (self.lyrics.count == 0) {
                statusLabel.text = @"[WARN]️ 網路錯誤 / Network error";
                if (self.isModal) self.view.hidden = NO;
                self.lyrics = @[];
                [self.tableView reloadData];
            }
        });
    }] resume];
}

- (void)ytmuCheckServerUpgradeForVideoID:(NSString *)videoID {
    if (!videoID.length) return;
    if (!YTMULyricsPreference(@"lyricsAutoUpdate", YES)) return;
    NSArray *tierLyrics = g_lyricsCache[videoID] ?: YTMULyricsCacheLoad(videoID);
    if (!tierLyrics) return;
    static NSMutableDictionary *g_upgradeLastCheck = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_upgradeLastCheck = [NSMutableDictionary dictionary];
    });
    NSDate *last = g_upgradeLastCheck[videoID];
    if (last && [[NSDate date] timeIntervalSinceDate:last] < 300) return;
    g_upgradeLastCheck[videoID] = [NSDate date];

    NSString *tier = YTMULyricsTier(tierLyrics);
    NSInteger cacheVersion = YTMULyricsCacheVersionForVideoID(videoID);
    NSString *url = [NSString stringWithFormat:@"%@/api/lyrics/check?v=%@&lang=%@&ct=%@&cv=%ld",
                     YTMUApiBase(), videoID, YTMUUrlEncode(YTMUTargetLang()), tier, (long)cacheVersion];
    [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:url]
        completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!data || err) return;
            NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([dict[@"upgrade"] boolValue]) {
                sendDebugLog(@"[MUSIC] Server has a better lyrics tier, upgrading");
                [[YTMUTurnstileManager sharedManager] getJWTTokenWithCompletion:^(NSString *jwt) {
                    [self fetchFullLyricsForVideo:videoID jwt:jwt force:NO];
                }];
            }
        });
    }] resume];
}

- (void)fetchLyricsForVideo:(NSString *)videoID {
    if (!videoID || videoID.length == 0) return;

    if (!g_lyricsCache) {
        g_lyricsCache = [[NSMutableDictionary alloc] init];
    }

    if (g_lyricsCache[videoID]) {
        UILabel *statusLabel = [self.tableView.tableHeaderView viewWithTag:8888];
        statusLabel.text = @"";
        self.loadingVideoID = videoID;
        self.isLoading = NO;
        [self loadArtworkForVideo:videoID];
        [self updateLyrics:g_lyricsCache[videoID]];
        [self ytmuCheckServerUpgradeForVideoID:videoID];
        return;
    }
    if (YTMULyricsCacheEnabled()) {
        NSArray *fileCached = YTMULyricsCacheLoad(videoID);
        if (fileCached) {
            if (!g_lyricsCache) g_lyricsCache = [[NSMutableDictionary alloc] init];
            g_lyricsCache[videoID] = fileCached;
            UILabel *statusLabel = [self.tableView.tableHeaderView viewWithTag:8888];
            statusLabel.text = @"";
            self.loadingVideoID = videoID;
            self.isLoading = NO;
            [self loadArtworkForVideo:videoID];
            [self updateLyrics:fileCached];
            [self ytmuCheckServerUpgradeForVideoID:videoID];
            return;
        }
    }

    UILabel *statusLabel = [self.tableView.tableHeaderView viewWithTag:8888];
    statusLabel.text = @"Loading...";

    if (![videoID isEqualToString:self.loadingVideoID]) {
        self.currentIndex = -1;
        self.lyrics = @[];
        [self.tableView reloadData];
        if (self.isModal) self.view.hidden = NO;
    }

    if (g_globalLoadingInFlight && [g_globalLoadingVideoID isEqualToString:videoID]) {
        if (g_loadingSince && [[NSDate date] timeIntervalSinceDate:g_loadingSince] > 45) {
            sendDebugLog(@"[WARN] Reclaiming stale global fetch slot");
            YTMUReleaseGlobalFetch();
        } else {
            statusLabel.text = @"Waiting...";
            return;
        }
    }
    if (self.isLoading && [self.loadingVideoID isEqualToString:videoID]) {
        if (self.loadingSince && [[NSDate date] timeIntervalSinceDate:self.loadingSince] <= 45) {
            statusLabel.text = @"Waiting...";
            return;
        }
        sendDebugLog(@"[WARN] Reclaiming stale instance fetch slot");
    }

    g_globalLoadingInFlight = YES;
    g_globalLoadingVideoID = videoID;
    g_loadingSince = [NSDate date];
    self.isLoading = YES;
    self.loadingVideoID = videoID;
    self.loadingSince = [NSDate date];

    [self loadArtworkForVideo:videoID];

    NSString *fastURL = [NSString stringWithFormat:@"%@/api/lyrics?v=%@&fast=1&lang=%@%@", YTMUApiBase(), videoID, YTMUUrlEncode(YTMUTargetLang()), YTMUAutoZhParam()];
    [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:fastURL] completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self.loadingVideoID isEqualToString:videoID]) return;
            if (data && !err) {
                NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if (dict && dict[@"lyrics"]) {
                    statusLabel.text = @"";
                    [self updateLyrics:dict[@"lyrics"]];
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"YTMULyricsDidLoad"
                                                                        object:videoID
                                                                      userInfo:@{@"lyrics": dict[@"lyrics"]}];
                }
            }

            __block BOOL jwtResolved = NO;
            [[YTMUTurnstileManager sharedManager] getJWTTokenWithCompletion:^(NSString *jwt) {
                if (jwtResolved) return;
                jwtResolved = YES;
                [self fetchFullLyricsForVideo:videoID jwt:jwt force:NO];
            }];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (!jwtResolved && [self.loadingVideoID isEqualToString:videoID]) {
                    jwtResolved = YES;
                    sendDebugLog(@"[WARN] JWT timeout, full fetch without JWT");
                    [self fetchFullLyricsForVideo:videoID jwt:nil force:NO];
                }
            });
        });
    }] resume];
}

- (void)updatePlaybackTime {
    self.fpsTicks++;
    NSTimeInterval fpsNow = CACurrentMediaTime();
    if (fpsNow - self.fpsWindowStart >= 1.0) {
        NSInteger fps = (NSInteger)(self.fpsTicks / MAX(fpsNow - self.fpsWindowStart, 0.001));
        self.fpsTicks = 0;
        self.fpsWindowStart = fpsNow;
        if (self.fpsLabel && !self.fpsLabel.hidden) {
            NSInteger maxFps = (NSInteger)[UIScreen mainScreen].maximumFramesPerSecond;
            self.fpsLabel.text = [NSString stringWithFormat:@"%ld/%ld fps", (long)fps, (long)maxFps];
            sendDebugLog([NSString stringWithFormat:@"[FPS] lyric render rate %ld fps (panel max %ld)", (long)fps, (long)maxFps]);
        }
    }
    if (self.landscapeInfoPanel && !self.landscapeInfoPanel.hidden) {
        [self ytmu_updateLandscapeProgress];
        // playerResponse can arrive after the panel opens; keep retrying
        // until a real title/artist is shown.
        BOOL needTitle = (self.landscapeTitleLabel.text.length == 0 ||
                          [self.landscapeTitleLabel.text isEqualToString:@"Now Playing"]);
        if (needTitle || self.landscapeArtistLabel.text.length == 0) {
            [self ytmu_updateLandscapeMetadata];
        }
    }
    if (!self.isSynced || self.lyrics.count == 0) return;

    double currentTime = 0;
    if (g_activePlayer) {
        if ([g_activePlayer respondsToSelector:@selector(currentVideoMediaTime)]) {
            currentTime = [g_activePlayer currentVideoMediaTime];
        } else if ([g_activePlayer respondsToSelector:@selector(currentMediaTime)]) {
            currentTime = [g_activePlayer currentMediaTime];
        }
    }
    if (currentTime > 0) {
        g_currentPlaybackTime = currentTime;
    } else {
        currentTime = g_currentPlaybackTime;
    }

    // Apply per-song timing offset
    if (g_currentVideoID.length) {
        double offset = YTMULyricsOffsetForVideoID(g_currentVideoID);
        if (offset != 0.0) {
            currentTime += offset;
        }
    }

    if (currentTime <= 0) return;

    NSInteger newIndex = -1;
    for (NSInteger i = 0; i < self.lyrics.count; i++) {
        NSDictionary *lyric = self.lyrics[i];
        double time = [lyric[@"time"] doubleValue];

        if (currentTime >= time) {
            newIndex = i;
        } else {
            break;
        }
    }

    if (newIndex != self.currentIndex) {
        NSInteger oldIndex = self.currentIndex;
        self.currentIndex = newIndex;

        if (oldIndex >= 0 && oldIndex < self.lyrics.count) {
            YTMULyricsCell *oldCell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:oldIndex inSection:0]];
            if (oldCell) {
                [self configureCell:oldCell atIndex:oldIndex isActive:NO currentTime:currentTime];
            }
        }

        if (newIndex >= 0 && newIndex < self.lyrics.count) {
            YTMULyricsCell *newCell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:newIndex inSection:0]];
            if (newCell) {
                [self configureCell:newCell atIndex:newIndex isActive:YES currentTime:currentTime];
                NSDictionary *nl = self.lyrics[newIndex];
                if (!([nl[@"wordSynced"] boolValue] && [(NSArray *)nl[@"parts"] count] > 0)) {
                    newCell.lyricLabel.alpha = 0.3;
                }
                newCell.lyricLabel.transform = CGAffineTransformMakeScale(1.04, 1.04);
                [UIView animateWithDuration:0.5 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
                    newCell.lyricLabel.alpha = 1.0;
                    newCell.lyricLabel.transform = CGAffineTransformIdentity;
                } completion:nil];
            }

            if (!self.tableView.isDragging && !self.tableView.isDecelerating) {
                NSIndexPath *indexPath = [NSIndexPath indexPathForRow:newIndex inSection:0];
                [self.tableView scrollToRowAtIndexPath:indexPath atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
            }
        }
    } else if (newIndex >= 0) {
        YTMULyricsCell *cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:newIndex inSection:0]];
        if (cell) {
            NSDictionary *lyric = self.lyrics[newIndex];
            if ([lyric[@"wordSynced"] boolValue] && [(NSArray *)lyric[@"parts"] count] > 0) {
                [self applyWordColorsToCell:cell lyric:lyric index:newIndex currentTime:currentTime force:NO];
            }
        }
    }
}

- (void)forceReloadLyrics {
    if (!g_currentVideoID) return;

    if (g_lyricsCache) {
        [g_lyricsCache removeObjectForKey:g_currentVideoID];
    }
    self.lyrics = @[];
    [self.tableView reloadData];

    UILabel *statusLabel = [self.tableView.tableHeaderView viewWithTag:8888];
    statusLabel.text = @"Force Reloading...";

    g_globalLoadingInFlight = YES;
    g_globalLoadingVideoID = g_currentVideoID;
    g_loadingSince = [NSDate date];
    self.isLoading = YES;
    self.loadingVideoID = g_currentVideoID;
    self.loadingSince = [NSDate date];

    [self loadArtworkForVideo:g_currentVideoID];

    __block BOOL jwtResolved = NO;
    [[YTMUTurnstileManager sharedManager] getJWTTokenWithCompletion:^(NSString *jwt) {
        if (jwtResolved) return;
        jwtResolved = YES;
        [self fetchFullLyricsForVideo:g_currentVideoID jwt:jwt force:YES];
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!jwtResolved && [self.loadingVideoID isEqualToString:g_currentVideoID]) {
            jwtResolved = YES;
            sendDebugLog(@"[WARN] JWT timeout, force reload without JWT");
            [self fetchFullLyricsForVideo:g_currentVideoID jwt:nil force:YES];
        }
    });
}

- (void)updateLyrics:(NSArray *)newLyrics {
    self.lyrics = newLyrics;

    BOOL hasTimestamp = NO;
    for (NSDictionary *l in newLyrics) {
        if ([l[@"time"] doubleValue] > 0.0) {
            hasTimestamp = YES;
            break;
        }
    }
    self.isSynced = hasTimestamp;
    if (!self.isSynced) {
        self.currentIndex = -1;
    }
    self.lastColorKey = nil;
    self.cachedWordLayoutKey = nil;
    self.cachedWordRects = nil;

    NSString *artVid = self.loadingVideoID;
    if (!artVid) artVid = g_currentVideoID;
    if (artVid && ![artVid isEqualToString:self.artworkVideoID]) {
        if (!self.loadingVideoID) self.loadingVideoID = artVid;
        [self loadArtworkForVideo:artVid];
    }

    [self.tableView reloadData];

    if (newLyrics.count > 0 && (self.isModal || YTMULyricsPreference(@"lyricsAlwaysOn", YES))) {
        self.view.hidden = NO;
        if (!self.isModal && self.view.tag == 9999) {
            UIView *contentContainer = self.view.superview;
            if (contentContainer) {
                [contentContainer bringSubviewToFront:self.view];
                for (UIView *sub in contentContainer.subviews) {
                    if (sub != self.view && sub.tag != 9999) sub.hidden = YES;
                }
            }
        }
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.lyrics.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewAutomaticDimension;
}

- (NSString *)normalizedLyricText:(NSString *)raw {
    if (!raw || raw.length == 0) return @"";
    NSArray *tokens = [raw componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSMutableArray *nonEmpty = [NSMutableArray array];
    for (NSString *t in tokens) {
        if (t.length > 0) [nonEmpty addObject:t];
    }
    NSString *joined = [nonEmpty componentsJoinedByString:@" "];
    NSMutableString *out = [NSMutableString stringWithCapacity:joined.length];
    for (NSUInteger i = 0; i < joined.length; i++) {
        unichar c = [joined characterAtIndex:i];
        if (c == ' ' && i > 0 && i + 1 < joined.length) {
            unichar prev = [joined characterAtIndex:i - 1];
            unichar next = [joined characterAtIndex:i + 1];
            if (YTMUIsCJKChar(prev) && YTMUIsCJKChar(next)) continue;
        }
        [out appendFormat:@"%C", c];
    }
    return out;
}

- (NSString *)wbwDisplayTextForLyric:(NSDictionary *)lyric ranges:(NSArray **)outRanges {
    NSArray *parts = lyric[@"parts"];
    NSCharacterSet *wsTrim = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSMutableString *concat = [NSMutableString string];
    for (NSDictionary *p in parts) {
        NSString *rawW = (NSString *)(p[@"words"] ?: @"");
        NSString *w = [rawW stringByTrimmingCharactersInSet:wsTrim];
        if (w.length == 0) continue;
        if (concat.length > 0) {
            unichar prev = [concat characterAtIndex:concat.length - 1];
            unichar next = [w characterAtIndex:0];
            NSString *sep = (YTMUIsCJKChar(prev) && YTMUIsCJKChar(next)) ? @"" : @" ";
            [concat appendString:sep];
        }
        [concat appendString:w];
    }
    NSString *display = [self normalizedLyricText:([concat length] ? concat : lyric[@"text"])];
    if (outRanges) {
        NSMutableArray *ranges = [NSMutableArray array];
        NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
        NSUInteger cursor = 0;
        for (NSDictionary *p in parts) {
            NSString *w = [((NSString *)(p[@"words"] ?: @"")) stringByTrimmingCharactersInSet:ws];
            if (w.length == 0) continue;
            if (cursor > display.length) cursor = display.length;
            NSRange found = [display rangeOfString:w options:0 range:NSMakeRange(cursor, display.length - cursor)];
            if (found.location == NSNotFound) {
                [ranges addObject:[NSValue valueWithRange:NSMakeRange(NSNotFound, 0)]];
                continue;
            }
            [ranges addObject:[NSValue valueWithRange:found]];
            cursor = NSMaxRange(found);
            while (cursor < display.length && [ws characterIsMember:[display characterAtIndex:cursor]]) cursor++;
        }
        *outRanges = ranges;
    }
    return display;
}

- (UIBezierPath *)maskPathForWordRange:(NSRange)r inLayoutManager:(NSLayoutManager *)lm textContainer:(NSTextContainer *)tc fraction:(double)frac {
    NSRange glyphs = [lm glyphRangeForCharacterRange:r actualCharacterRange:NULL];
    CGRect b = [lm boundingRectForGlyphRange:glyphs inTextContainer:tc];
    if (frac < 1.0) b.size.width *= MAX(frac, 0.0);
    return [UIBezierPath bezierPathWithRect:CGRectInset(b, -1, -2)];
}

- (void)applyWordColorsToCell:(YTMULyricsCell *)cell lyric:(NSDictionary *)lyric index:(NSInteger)index currentTime:(double)currentTime force:(BOOL)force {
    NSArray *parts = lyric[@"parts"];
    if ([parts count] == 0) return;
    CGFloat width = cell.wipeLabel.bounds.size.width;
    if (width <= 0) return;
    double nowMs = currentTime * 1000.0;
    NSInteger partCount = [parts count];
    NSInteger curWord = partCount;
    double curFrac = 1.0;
    double priorDurSum = 0;
    NSInteger priorDurCount = 0;
    for (NSInteger i = 0; i < partCount; i++) {
        NSDictionary *p = parts[i];
        double rawDur = MAX([p[@"durationMs"] doubleValue], 1.0);
        double s = [p[@"startTimeMs"] doubleValue];
        double d = MAX(rawDur, 120.0);
        if (i == partCount - 1 && d > 1400.0) {
            double avg = (priorDurCount > 0) ? (priorDurSum / (double)priorDurCount) : 400.0;
            d = MIN(d, MAX(avg * 1.5, 500.0));
            d = MIN(d, 1400.0);
        } else {
            priorDurSum += d;
            priorDurCount++;
        }
        if (nowMs < s) { curWord = i; curFrac = 0.0; break; }
        if (nowMs < s + d) { curWord = i; curFrac = (nowMs - s) / d; break; }
    }
    NSInteger fracQ = (NSInteger)(curFrac * 24.0);
    NSString *key = [NSString stringWithFormat:@"%p:%ld:%ld:%ld:%.0f", cell, (long)index, (long)curWord, (long)fracQ, (double)width];
    if (!force && [key isEqualToString:self.lastColorKey]) return;

    UIFont *font = cell.wipeLabel.font;
    if (!font) font = [UIFont boldSystemFontOfSize:22];
    NSArray *ranges = nil;
    NSString *display = [self wbwDisplayTextForLyric:lyric ranges:&ranges];
    NSString *layoutKey = [NSString stringWithFormat:@"%ld|%.1f|%@", (long)index, (double)width, display];
    if (![layoutKey isEqualToString:self.cachedWordLayoutKey]) {
        cell.lyricLabel.attributedText = nil;
        cell.lyricLabel.text = display;
        cell.lyricLabel.textColor = YTMUAdaptiveInk(0.2, 0.2);

        NSShadow *sh = [[NSShadow alloc] init];
        sh.shadowColor = YTMUAdaptiveShadow();
        sh.shadowOffset = CGSizeMake(0, 2);
        sh.shadowBlurRadius = 4;
        cell.wipeLabel.attributedText = [[NSAttributedString alloc] initWithString:display
            attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: YTMUAdaptiveInk(1.0, 1.0), NSShadowAttributeName: sh}];

        NSTextStorage *ts = [[NSTextStorage alloc] initWithString:display attributes:@{NSFontAttributeName: font}];
        NSLayoutManager *lm = [[NSLayoutManager alloc] init];
        NSTextContainer *tc = [[NSTextContainer alloc] initWithSize:CGSizeMake(width, CGFLOAT_MAX)];
        tc.lineFragmentPadding = 0;
        tc.maximumNumberOfLines = 0;
        tc.lineBreakMode = NSLineBreakByWordWrapping;
        [lm addTextContainer:tc];
        [ts addLayoutManager:lm];
        [lm ensureLayoutForTextContainer:tc];

        NSMutableArray *rects = [NSMutableArray arrayWithCapacity:[ranges count]];
        for (NSValue *v in ranges) {
            NSRange r = [v rangeValue];
            if (r.location == NSNotFound || r.length == 0) {
                [rects addObject:[NSValue valueWithCGRect:CGRectNull]];
                continue;
            }
            NSRange glyphs = [lm glyphRangeForCharacterRange:r actualCharacterRange:NULL];
            CGRect b = [lm boundingRectForGlyphRange:glyphs inTextContainer:tc];
            [rects addObject:[NSValue valueWithCGRect:CGRectInset(b, -1, -2)]];
        }
        self.cachedWordRects = rects;
        self.cachedWordLayoutKey = layoutKey;
    }
    self.lastColorKey = key;

    UIBezierPath *path = [UIBezierPath bezierPath];
    NSInteger rcount = MIN(partCount, (NSInteger)[self.cachedWordRects count]);
    for (NSInteger i = 0; i < curWord && i < rcount; i++) {
        CGRect b = [self.cachedWordRects[i] CGRectValue];
        if (CGRectIsNull(b)) continue;
        [path appendPath:[UIBezierPath bezierPathWithRect:b]];
    }
    if (curWord >= 0 && curWord < rcount) {
        CGRect b = [self.cachedWordRects[curWord] CGRectValue];
        if (!CGRectIsNull(b)) {
            b.size.width *= MAX(curFrac, 0.0);
            [path appendPath:[UIBezierPath bezierPathWithRect:b]];
        }
    } else if (curWord >= rcount && display.length > 0) {
        [path appendPath:[UIBezierPath bezierPathWithRect:cell.wipeLabel.bounds]];
    }
    cell.wipeMask.frame = cell.wipeLabel.bounds;
    cell.wipeMask.path = path.CGPath;
}

- (CGFloat)wipeProgressForLyricAtIndex:(NSInteger)index currentTime:(double)currentTime {
    if (index < 0 || index >= self.lyrics.count) return 0.0;
    NSDictionary *lyric = self.lyrics[index];
    double nowMs = currentTime * 1000.0;
    NSArray *parts = lyric[@"parts"];
    if ([lyric[@"wordSynced"] boolValue] && [parts count] > 0) {
        NSInteger n = [parts count];
        double priorDurSum = 0;
        NSInteger priorDurCount = 0;
        for (NSInteger i = 0; i < n; i++) {
            NSDictionary *p = parts[i];
            double s = [p[@"startTimeMs"] doubleValue];
            double rawDur = MAX([p[@"durationMs"] doubleValue], 1.0);
            double d = MAX(rawDur, 120.0);
            if (i == n - 1 && d > 1400.0) {
                double avg = (priorDurCount > 0) ? (priorDurSum / (double)priorDurCount) : 400.0;
                d = MIN(d, MAX(avg * 1.5, 500.0));
                d = MIN(d, 1400.0);
            } else {
                priorDurSum += d;
                priorDurCount++;
            }
            if (nowMs < s) return (CGFloat)i / (CGFloat)n;
            if (nowMs < s + d) {
                double frac = (nowMs - s) / d;
                return (CGFloat)((double)i + frac) / (CGFloat)n;
            }
        }
        return 1.0;
    }
    double startMs = [lyric[@"startTimeMs"] doubleValue];
    if (startMs <= 0) startMs = [lyric[@"time"] doubleValue] * 1000.0;
    double endMs = 0;
    if (index + 1 < self.lyrics.count) {
        NSDictionary *next = self.lyrics[index + 1];
        endMs = [next[@"startTimeMs"] doubleValue];
        if (endMs <= 0) endMs = [next[@"time"] doubleValue] * 1000.0;
    }
    if (endMs <= startMs) {
        double durMs = [lyric[@"durationMs"] doubleValue];
        if (durMs <= 0) durMs = [lyric[@"duration"] doubleValue] * 1000.0;
        endMs = startMs + (durMs > 0 ? durMs : 4000.0);
    }
    if (endMs <= startMs) return 1.0;
    return (CGFloat)MIN(MAX((nowMs - startMs) / (endMs - startMs), 0.0), 1.0);
}

- (void)configureCell:(YTMULyricsCell *)cell atIndex:(NSInteger)index isActive:(BOOL)isActive currentTime:(double)currentTime {
    if (index < 0 || index >= self.lyrics.count) return;

    NSDictionary *lyric = self.lyrics[index];
    NSString *displayText = [self normalizedLyricText:lyric[@"text"]];
    BOOL hasWords = [lyric[@"wordSynced"] boolValue] && [(NSArray *)lyric[@"parts"] count] > 0;
    if (hasWords) displayText = [self wbwDisplayTextForLyric:lyric ranges:NULL];
    cell.lyricLabel.alpha = 1.0;
    cell.lyricLabel.transform = CGAffineTransformIdentity;

    if (!self.isSynced) {
        cell.lyricLabel.attributedText = nil;
        cell.lyricLabel.text = displayText;
        cell.lyricLabel.textColor = YTMUAdaptiveInk(1.0, 1.0);
        cell.lyricLabel.layer.shadowColor = YTMUAdaptiveShadow().CGColor;
        cell.lyricLabel.layer.shadowOffset = CGSizeMake(0, 2);
        cell.lyricLabel.layer.shadowRadius = 4.0;
        cell.lyricLabel.layer.shadowOpacity = 0.7;
        cell.lyricLabel.layer.masksToBounds = NO;
        [cell clearWipe];

        cell.transLabel.textColor = YTMUAdaptiveInk(0.75, 0.75);
    } else if (isActive) {
        if (hasWords) {
            [self applyWordColorsToCell:cell lyric:lyric index:index currentTime:currentTime force:YES];
        } else {
            cell.lyricLabel.attributedText = nil;
            cell.lyricLabel.text = displayText;
            cell.lyricLabel.textColor = YTMUAdaptiveInk(1.0, 1.0);
            [cell clearWipe];
        }

        cell.lyricLabel.layer.shadowColor = YTMUAdaptiveShadow().CGColor;
        cell.lyricLabel.layer.shadowOffset = CGSizeMake(0, 2);
        cell.lyricLabel.layer.shadowRadius = 4.0;
        cell.lyricLabel.layer.shadowOpacity = 0.75;
        cell.lyricLabel.layer.masksToBounds = NO;

        cell.transLabel.textColor = YTMUAdaptiveInk(0.7, 0.7);
    } else {
        cell.lyricLabel.attributedText = nil;
        cell.lyricLabel.text = displayText;
        cell.lyricLabel.textColor = YTMUAdaptiveInk(0.2, 0.2);
        cell.lyricLabel.layer.shadowOpacity = 0.32;
        [cell clearWipe];

        cell.transLabel.textColor = YTMUAdaptiveInk(0.25, 0.25);
    }

    NSString *translated = lyric[@"translated"];
    NSString *rawText = [lyric[@"text"] isKindOfClass:[NSString class]] ? lyric[@"text"] : @"";
    if (translated && translated.length > 0 && ![translated isEqualToString:rawText]) {
        cell.transLabel.text = translated;
        cell.transLabel.hidden = NO;
    } else {
        cell.transLabel.text = @"";
        cell.transLabel.hidden = YES;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    YTMULyricsCell *cell = [tableView dequeueReusableCellWithIdentifier:@"YTMULyricsCell" forIndexPath:indexPath];

    double currentTime = 0;
    if (g_activePlayer && [g_activePlayer respondsToSelector:@selector(currentVideoMediaTime)]) {
        currentTime = [g_activePlayer currentVideoMediaTime];
    } else {
        currentTime = g_currentPlaybackTime;
    }

    // Apply per-song timing offset
    if (g_currentVideoID.length) {
        double offset = YTMULyricsOffsetForVideoID(g_currentVideoID);
        if (offset != 0.0) {
            currentTime += offset;
        }
    }

    BOOL isActive = self.isSynced && (indexPath.row == self.currentIndex);
    [self configureCell:cell atIndex:indexPath.row isActive:isActive currentTime:currentTime];

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (!self.isSynced) return;

    NSDictionary *lyric = self.lyrics[indexPath.row];
    NSNumber *time = lyric[@"time"];

    if (time && [time doubleValue] >= 0) {
        double seekTime = [time doubleValue];
        // Adjust for per-song offset
        if (g_currentVideoID.length) {
            double offset = YTMULyricsOffsetForVideoID(g_currentVideoID);
            if (offset != 0.0) {
                seekTime -= offset;
            }
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:@"YTMUSeekToTime" object:@(seekTime)];

        NSInteger oldIndex = self.currentIndex;
        self.currentIndex = indexPath.row;
        g_currentPlaybackTime = seekTime;

        if (oldIndex >= 0 && oldIndex < self.lyrics.count && oldIndex != indexPath.row) {
            YTMULyricsCell *oldCell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:oldIndex inSection:0]];
            if (oldCell) {
                [self configureCell:oldCell atIndex:oldIndex isActive:NO currentTime:g_currentPlaybackTime];
            }
        }
        YTMULyricsCell *newCell = [self.tableView cellForRowAtIndexPath:indexPath];
        if (newCell) {
            [self configureCell:newCell atIndex:indexPath.row isActive:YES currentTime:g_currentPlaybackTime];
        }
    }
}

@end


static void __attribute__((unused)) YTMUAttemptFallbackPresent(NSString *resolvedVideoID, int attempt) {
    if (isLyricsViewVisibleOnScreen()) {
        sendDebugLog(@"[MUSIC] Native lyrics panel already visible on screen, skipping fallback");
        return;
    }

    UIViewController *top = topMostViewController();
    if (!top) return;

    if ([top isKindOfClass:[YTMULyricsViewController class]] || [top.presentedViewController isKindOfClass:[YTMULyricsViewController class]]) {
        YTMULyricsViewController *existing = [top isKindOfClass:[YTMULyricsViewController class]]
            ? (YTMULyricsViewController *)top
            : (YTMULyricsViewController *)top.presentedViewController;
        NSString *existingVideoID = YTMUResolveCurrentVideoID() ?: resolvedVideoID;
        if (existingVideoID) [existing fetchLyricsForVideo:existingVideoID];
        return;
    }

    if (attempt < 3) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            YTMUAttemptFallbackPresent(resolvedVideoID, attempt + 1);
        });
        return;
    }

    if (top.presentedViewController || top.isBeingPresented || top.isBeingDismissed) {
        sendDebugLog(@"[WARN] fallback suppressed: top view controller is busy presenting");
        return;
    }

    sendDebugLog(@"[MUSIC] Presenting fallback YTMULyricsViewController bottom sheet");
    YTMULyricsViewController *lyricsVC = [[YTMULyricsViewController alloc] init];
    lyricsVC.isModal = YES;
    lyricsVC.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = lyricsVC.sheetPresentationController;
        sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent];
        sheet.prefersGrabberVisible = YES;
    }
    NSString *tapVideoID = YTMUResolveCurrentVideoID() ?: resolvedVideoID;
    if (tapVideoID) {
        [lyricsVC fetchLyricsForVideo:tapVideoID];
    }
    [top presentViewController:lyricsVC animated:YES completion:^{
        if (!tapVideoID) {
            UILabel *statusLabel = [lyricsVC.tableView.tableHeaderView viewWithTag:8888];
            if (statusLabel) statusLabel.text = @"No video playing";
        }
    }];
}

void openLyricsFromViewController(UIViewController *parentVC) {
    sendDebugLog(@"[MUSIC] openLyricsFromViewController called");
    NSString *resolvedVideoID = YTMUResolveCurrentVideoID();
    if (!resolvedVideoID) {
        sendDebugLog(@"[WARN] openLyrics: no video ID could be resolved");
    }

    if (g_activeEngagementPanelContainer) {
        NSArray *panelIDs = @[@"PAmusic_watch_lyrics_panel", @"music_watch_lyrics_panel", @"lyrics"];
        for (NSString *pid in panelIDs) {
            if ([g_activeEngagementPanelContainer respondsToSelector:@selector(showEngagementPanelWithIdentifier:animated:)]) {
                [g_activeEngagementPanelContainer performSelector:@selector(showEngagementPanelWithIdentifier:animated:) withObject:pid withObject:(id)kCFBooleanTrue];
            } else if ([g_activeEngagementPanelContainer respondsToSelector:@selector(showEngagementPanelWithIdentifier:)]) {
                [g_activeEngagementPanelContainer performSelector:@selector(showEngagementPanelWithIdentifier:) withObject:pid];
            } else if ([g_activeEngagementPanelContainer respondsToSelector:@selector(openEngagementPanelWithIdentifier:animated:)]) {
                [g_activeEngagementPanelContainer performSelector:@selector(openEngagementPanelWithIdentifier:animated:) withObject:pid withObject:(id)kCFBooleanTrue];
            } else {
                sendDebugLog(@"[WARN] engagement panel container responds to none of the known show/open selectors");
                break;
            }
        }
    } else {
        sendDebugLog(@"[WARN] openLyrics: no active engagement panel container captured, native panel path skipped entirely");
    }

    YTMUAttemptFallbackPresent(resolvedVideoID, 0);
}

void openLyricsFullscreenForLandscape(void) {
    if (isLyricsViewVisibleOnScreen()) {
        sendDebugLog(@"[MUSIC] landscape open: lyrics already visible");
        return;
    }
    if (!YTMUIsInterfaceLandscape()) return;

    UIViewController *top = topMostViewController();
    if (!top) return;
    if ([top isKindOfClass:[YTMULyricsViewController class]]) return;
    if ([top.presentedViewController isKindOfClass:[YTMULyricsViewController class]]) return;
    if (top.presentedViewController || top.isBeingPresented || top.isBeingDismissed) {
        sendDebugLog(@"[WARN] landscape open suppressed: top busy");
        return;
    }

    NSString *vid = YTMUResolveCurrentVideoID();
    if (!vid) {
        sendDebugLog(@"[WARN] landscape open: no video ID");
        return;
    }

    sendDebugLog(@"[MUSIC] landscape auto-presenting fullscreen lyrics");
    YTMULyricsViewController *lyricsVC = [[YTMULyricsViewController alloc] init];
    lyricsVC.isModal = YES;
    lyricsVC.modalPresentationStyle = UIModalPresentationFullScreen;
    lyricsVC.modalPresentationCapturesStatusBarAppearance = YES;
    [lyricsVC fetchLyricsForVideo:vid];
    [top presentViewController:lyricsVC animated:YES completion:nil];
}

static void YTMULandscapeOrientationChanged(NSNotification *note) {
    UIDeviceOrientation o = [UIDevice currentDevice].orientation;
    if (o != UIDeviceOrientationLandscapeLeft && o != UIDeviceOrientationLandscapeRight) {
        return;
    }
    // Defer past the rotation animation so top VC is stable
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!YTMUIsInterfaceLandscape()) return;
        if (isLyricsViewVisibleOnScreen()) return;
        NSString *vid = YTMUResolveCurrentVideoID();
        if (!vid.length) return;
        openLyricsFullscreenForLandscape();
    });
}

void YTMURegisterLandscapeAutoOpen(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIDeviceOrientationDidChangeNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            YTMULandscapeOrientationChanged(note);
        }];
    });
}
