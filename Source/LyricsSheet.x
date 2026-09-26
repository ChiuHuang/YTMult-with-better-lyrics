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

// Background-derived ink: the sheet sits on blurred artwork, which can be
// bright white while the OS is in dark mode (or dark while in light mode),
// so trait-based ink washes out. The artwork is sampled once per song (see
// ytmu_probeArtworkBrightness:); until sampled, fall back to the OS theme.
static int g_ytmu_bgLight = -1; // -1 unknown, 0 dark bg, 1 light bg

static BOOL YTMUBgIsLight(UIView *refView) {
    if (g_ytmu_bgLight >= 0) return g_ytmu_bgLight == 1;
    if (refView) return YTMUInterfaceIsLight(refView);
    return NO;
}

// Same alpha tuning as YTMUAdaptiveInk, keyed on background brightness
// instead of the OS theme.
static UIColor *YTMULyricInk(CGFloat darkAlpha, CGFloat lightAlpha, UIView *refView) {
    BOOL light = YTMUBgIsLight(refView);
    return [(light ? [UIColor blackColor] : [UIColor whiteColor])
            colorWithAlphaComponent:(light ? lightAlpha : darkAlpha)];
}
static UIColor *YTMULyricShadow(UIView *refView) {
    if (YTMUBgIsLight(refView))
        return [[UIColor darkGrayColor] colorWithAlphaComponent:0.35];
    return [[UIColor blackColor] colorWithAlphaComponent:0.8];
}
// Mean luminance of a thumbnail; -1 when unsampleable.
static CGFloat YTMUArtworkLuminance(UIImage *img) {
    if (!img) return -1;
    CGImageRef cg = img.CGImage;
    if (!cg) return -1;
    // Fixed-size buffer: a const size_t extent would be a VLA, which cannot
    // take an initializer in C.
    uint8_t px[8 * 8 * 4] = {0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) return -1;
    CGContextRef ctx = CGBitmapContextCreate(px, 8, 8, 8, 8 * 4, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return -1;
    CGContextDrawImage(ctx, CGRectMake(0, 0, 8, 8), cg);
    CGContextRelease(ctx);
    double r = 0, g = 0, b = 0;
    for (size_t i = 0; i < 64; i++) {
        r += px[i * 4] / 255.0;
        g += px[i * 4 + 1] / 255.0;
        b += px[i * 4 + 2] / 255.0;
    }
    r /= 64.0; g /= 64.0; b /= 64.0;
    return (CGFloat)(0.299 * r + 0.587 * g + 0.114 * b);
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
        self.lyricLabel.textColor = YTMULyricInk(0.45, 0.55, self.contentView);
        self.lyricLabel.layer.shadowColor = YTMULyricShadow(self.contentView).CGColor;
        self.lyricLabel.layer.shadowOffset = CGSizeMake(0, 2);
        self.lyricLabel.layer.shadowRadius = 4.0;
        self.lyricLabel.layer.masksToBounds = NO;
        self.lyricLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:self.lyricLabel];

        self.wipeLabel = [[UILabel alloc] init];
        self.wipeLabel.numberOfLines = 0;
        self.wipeLabel.font = [UIFont boldSystemFontOfSize:22];
        self.wipeLabel.textColor = YTMULyricInk(1.0, 1.0, self.contentView);
        self.wipeLabel.layer.shadowColor = YTMULyricShadow(self.contentView).CGColor;
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
        self.transLabel.textColor = YTMULyricInk(0.32, 0.5, self.contentView);
        self.transLabel.layer.shadowColor = YTMULyricShadow(self.contentView).CGColor;
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
- (void)ytmu_probeArtworkBrightness:(UIImage *)img;
- (void)ytmu_refreshBgDerivedInk;
- (void)ytmu_applyArtworkImage:(UIImage *)img forVideoID:(NSString *)videoID;
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
- (void)ytmu_applyLandscapeTheme;
- (NSString *)ytmu_formatTime:(CGFloat)seconds;
- (void)ytmu_toolbarReload:(UIButton *)sender;
- (void)ytmu_headerMenu:(UIButton *)sender;
- (void)ytmu_openProviderMenuFromView:(UIView *)sender;
- (void)ytmu_beginProviderProbeWithJWT:(NSString *)jwt fromView:(UIView *)sender;
- (void)ytmu_pollProviderJob:(NSTimer *)timer;
- (void)ytmu_stopProviderPoll;
- (void)ytmu_showProviderMenu:(NSArray *)candidates saved:(NSString *)saved fromView:(UIView *)sender;
- (void)ytmu_selectProvider:(NSString *)provider;
- (void)ytmu_postJSON:(NSString *)path body:(NSDictionary *)body completion:(void (^)(NSDictionary *json, NSError *error))completion;
- (void)ytmu_getJSON:(NSString *)path completion:(void (^)(NSDictionary *json, NSError *error))completion;
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
    statusLabel.textColor = YTMULyricInk(0.7, 0.75, self.view);
    statusLabel.textAlignment = NSTextAlignmentCenter;
    statusLabel.font = [UIFont systemFontOfSize:14];
    statusLabel.tag = 8888;
    [header addSubview:statusLabel];

    // Header action button: an icon that opens the actions menu
    // (provider list with live probing state, reload, close).
    UIButton *menuBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    menuBtn.frame = CGRectMake(self.view.bounds.size.width - 52, 10, 36, 36);
    menuBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    menuBtn.tintColor = YTMUAdaptiveInk(0.9, 0.9);
    if (@available(iOS 13.0, *)) {
        UIImage *menuImg = [UIImage systemImageNamed:@"list.bullet"];
        if (menuImg) {
            [menuBtn setImage:menuImg forState:UIControlStateNormal];
            [menuBtn setTitle:@"" forState:UIControlStateNormal];
        } else {
            [menuBtn setTitle:@"..." forState:UIControlStateNormal];
            [menuBtn setTitleColor:YTMUAdaptiveInk(0.9, 0.9) forState:UIControlStateNormal];
        }
    } else {
        [menuBtn setTitle:@"..." forState:UIControlStateNormal];
        [menuBtn setTitleColor:YTMUAdaptiveInk(0.9, 0.9) forState:UIControlStateNormal];
    }
    menuBtn.backgroundColor = YTMUAdaptiveFill();
    menuBtn.layer.cornerRadius = 18;
    [menuBtn addTarget:self action:@selector(ytmu_headerMenu:) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:menuBtn];
    self.headerMenuButton = menuBtn;

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

    // --- Landscape split-view: Image-2 style ---
    // No opaque columns: the fullscreen blurred artwork (ambient) shows
    // through everywhere, the album floats as a rounded card with shadow,
    // and lyrics sit directly on the blur. Light/dark follows the OS via
    // the adaptive inks and ytmu_applyLandscapeTheme (blur style swap).
    self.landscapeArtPanel = [[UIView alloc] initWithFrame:CGRectZero];
    self.landscapeArtPanel.backgroundColor = [UIColor clearColor];
    self.landscapeArtPanel.clipsToBounds = NO;
    self.landscapeArtPanel.hidden = YES;
    self.landscapeArtPanel.userInteractionEnabled = YES;
    [self.view addSubview:self.landscapeArtPanel];

    self.landscapeArtImageView = [[UIImageView alloc] initWithFrame:CGRectZero];
    self.landscapeArtImageView.contentMode = UIViewContentModeScaleAspectFill;
    self.landscapeArtImageView.clipsToBounds = YES;
    self.landscapeArtImageView.backgroundColor = YTMUAdaptiveFill();
    self.landscapeArtImageView.userInteractionEnabled = NO;
    self.landscapeArtImageView.layer.cornerRadius = 10;
    self.landscapeArtImageView.layer.masksToBounds = YES;
    [self.landscapeArtPanel addSubview:self.landscapeArtImageView];

    // Right panel is unused in the Image-2 layout (lyrics float on the
    // ambient blur); kept hidden so no seam can appear.
    self.landscapeRightPanel = [[UIView alloc] initWithFrame:CGRectZero];
    self.landscapeRightPanel.backgroundColor = [UIColor clearColor];
    self.landscapeRightPanel.hidden = YES;
    self.landscapeRightPanel.userInteractionEnabled = NO;

    // Landscape left column container: transparent, holds title, artist,
    // progress + times, and the minimal transport row.
    self.landscapeInfoPanel = [[UIView alloc] initWithFrame:CGRectZero];
    self.landscapeInfoPanel.backgroundColor = [UIColor clearColor];
    self.landscapeInfoPanel.hidden = YES;
    self.landscapeInfoPanel.layer.cornerRadius = 0;
    self.landscapeInfoPanel.layer.masksToBounds = NO;
    self.landscapeInfoPanel.userInteractionEnabled = YES;
    [self.landscapeArtPanel addSubview:self.landscapeInfoPanel];

    self.landscapeTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.landscapeTitleLabel.font = [UIFont boldSystemFontOfSize:15];
    self.landscapeTitleLabel.textColor = YTMULyricInk(1.0, 1.0, self.view);
    self.landscapeTitleLabel.numberOfLines = 1;
    self.landscapeTitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.landscapeInfoPanel addSubview:self.landscapeTitleLabel];

    self.landscapeArtistLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.landscapeArtistLabel.font = [UIFont systemFontOfSize:12];
    self.landscapeArtistLabel.textColor = YTMULyricInk(0.6, 0.6, self.view);
    self.landscapeArtistLabel.numberOfLines = 1;
    self.landscapeArtistLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.landscapeInfoPanel addSubview:self.landscapeArtistLabel];

    self.landscapeProgressTrack = [[UIView alloc] initWithFrame:CGRectZero];
    self.landscapeProgressTrack.backgroundColor = YTMUAdaptiveInk(0.25, 0.2);
    self.landscapeProgressTrack.layer.cornerRadius = 1.5;
    self.landscapeProgressTrack.layer.masksToBounds = YES;
    [self.landscapeInfoPanel addSubview:self.landscapeProgressTrack];

    self.landscapeProgressFill = [[UIView alloc] initWithFrame:CGRectZero];
    self.landscapeProgressFill.backgroundColor = YTMUAdaptiveInk(0.95, 0.9);
    self.landscapeProgressFill.layer.cornerRadius = 1.5;
    self.landscapeProgressFill.layer.masksToBounds = YES;
    [self.landscapeProgressTrack addSubview:self.landscapeProgressFill];

    self.landscapeProgressKnob = [[UIView alloc] initWithFrame:CGRectZero];
    self.landscapeProgressKnob.backgroundColor = YTMUAdaptiveInk(1.0, 1.0);
    self.landscapeProgressKnob.layer.cornerRadius = 4;
    self.landscapeProgressKnob.layer.masksToBounds = YES;
    self.landscapeProgressKnob.userInteractionEnabled = NO;
    [self.landscapeInfoPanel addSubview:self.landscapeProgressKnob];

    self.landscapeElapsedLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.landscapeElapsedLabel.font = [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightRegular];
    self.landscapeElapsedLabel.textColor = YTMULyricInk(0.6, 0.6, self.view);
    self.landscapeElapsedLabel.text = @"0:00";
    [self.landscapeInfoPanel addSubview:self.landscapeElapsedLabel];

    self.landscapeTotalLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.landscapeTotalLabel.font = [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightRegular];
    self.landscapeTotalLabel.textColor = YTMULyricInk(0.6, 0.6, self.view);
    self.landscapeTotalLabel.textAlignment = NSTextAlignmentRight;
    self.landscapeTotalLabel.text = @"0:00";
    [self.landscapeInfoPanel addSubview:self.landscapeTotalLabel];

    // Minimal icon transport (Image-2): plain prev/next glyphs, play/pause
    // as a filled circle. Colors follow the OS theme via the icon setters.
    self.landscapePrevButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.landscapePrevButton.tintColor = YTMUAdaptiveInk(0.9, 0.9);
    self.landscapePrevButton.backgroundColor = [UIColor clearColor];
    self.landscapePrevButton.tag = 7101;
    self.landscapePrevButton.accessibilityLabel = @"Previous track";
    self.landscapePrevButton.userInteractionEnabled = YES;
    self.landscapePrevButton.exclusiveTouch = NO;
    [self.landscapePrevButton addTarget:self action:@selector(ytmu_landscapePrev:) forControlEvents:UIControlEventTouchUpInside];
    [self.landscapeInfoPanel addSubview:self.landscapePrevButton];

    self.landscapePlayButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.landscapePlayButton.tintColor = [UIColor whiteColor];
    self.landscapePlayButton.backgroundColor = YTMUAdaptiveInk(1.0, 0.9);
    self.landscapePlayButton.layer.masksToBounds = YES;
    self.landscapePlayButton.tag = 7102;
    self.landscapePlayButton.accessibilityLabel = @"Play or pause";
    self.landscapePlayButton.userInteractionEnabled = YES;
    self.landscapePlayButton.exclusiveTouch = NO;
    [self.landscapePlayButton addTarget:self action:@selector(ytmu_landscapePlayPause:) forControlEvents:UIControlEventTouchUpInside];
    [self.landscapeInfoPanel addSubview:self.landscapePlayButton];

    self.landscapeNextButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.landscapeNextButton.tintColor = YTMUAdaptiveInk(0.9, 0.9);
    self.landscapeNextButton.backgroundColor = [UIColor clearColor];
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
    self.landscapeExitButton.tintColor = YTMUAdaptiveInk(0.9, 0.9);
    if (@available(iOS 13.0, *)) {
        UIImage *xmark = [UIImage systemImageNamed:@"xmark"];
        if (xmark) {
            [self.landscapeExitButton setImage:xmark forState:UIControlStateNormal];
            [self.landscapeExitButton setTitle:@"" forState:UIControlStateNormal];
        } else {
            [self.landscapeExitButton setTitle:@"X" forState:UIControlStateNormal];
            [self.landscapeExitButton setTitleColor:YTMUAdaptiveInk(0.9, 0.9) forState:UIControlStateNormal];
            self.landscapeExitButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        }
    } else {
        [self.landscapeExitButton setTitle:@"X" forState:UIControlStateNormal];
        [self.landscapeExitButton setTitleColor:YTMUAdaptiveInk(0.9, 0.9) forState:UIControlStateNormal];
        self.landscapeExitButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    }
    self.landscapeExitButton.backgroundColor = YTMUAdaptiveFill();
    self.landscapeExitButton.layer.cornerRadius = 16;
    self.landscapeExitButton.hidden = YES;
    [self.landscapeExitButton addTarget:self action:@selector(dismissModal) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.landscapeExitButton];

    // Bottom-right floating toolbar (Image-2): provider list + reload icons.
    self.landscapeToolbar = [[UIView alloc] initWithFrame:CGRectZero];
    self.landscapeToolbar.backgroundColor = YTMUAdaptiveFill();
    self.landscapeToolbar.layer.cornerRadius = 17;
    self.landscapeToolbar.layer.masksToBounds = YES;
    self.landscapeToolbar.hidden = YES;
    [self.view addSubview:self.landscapeToolbar];

    self.landscapeProviderButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.landscapeProviderButton.tintColor = YTMUAdaptiveInk(0.9, 0.9);
    if (@available(iOS 13.0, *)) {
        UIImage *pImg = [UIImage systemImageNamed:@"list.bullet"];
        if (pImg) [self.landscapeProviderButton setImage:pImg forState:UIControlStateNormal];
    }
    if (!self.landscapeProviderButton.imageView.image) {
        [self.landscapeProviderButton setTitle:@"..." forState:UIControlStateNormal];
        [self.landscapeProviderButton setTitleColor:YTMUAdaptiveInk(0.9, 0.9) forState:UIControlStateNormal];
    }
    self.landscapeProviderButton.accessibilityLabel = @"Lyric providers";
    [self.landscapeProviderButton addTarget:self action:@selector(ytmu_openProviderMenuFromView:) forControlEvents:UIControlEventTouchUpInside];
    [self.landscapeToolbar addSubview:self.landscapeProviderButton];

    self.landscapeReloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.landscapeReloadButton.tintColor = YTMUAdaptiveInk(0.9, 0.9);
    if (@available(iOS 13.0, *)) {
        UIImage *rImg = [UIImage systemImageNamed:@"arrow.clockwise"];
        if (rImg) [self.landscapeReloadButton setImage:rImg forState:UIControlStateNormal];
    }
    if (!self.landscapeReloadButton.imageView.image) {
        [self.landscapeReloadButton setTitle:@"R" forState:UIControlStateNormal];
        [self.landscapeReloadButton setTitleColor:YTMUAdaptiveInk(0.9, 0.9) forState:UIControlStateNormal];
    }
    self.landscapeReloadButton.accessibilityLabel = @"Reload lyrics";
    [self.landscapeReloadButton addTarget:self action:@selector(ytmu_toolbarReload:) forControlEvents:UIControlEventTouchUpInside];
    [self.landscapeToolbar addSubview:self.landscapeReloadButton];

    self.fpsLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 64, 140, 24)];
    self.fpsLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
    self.fpsLabel.textColor = YTMULyricInk(0.7, 0.75, self.view);
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
    CGFloat totalTime = 0;
    CGFloat curTime = 0;
    if (g_activePlayer && [g_activePlayer respondsToSelector:@selector(currentVideoTotalMediaTime)]) {
        totalTime = g_activePlayer.currentVideoTotalMediaTime;
        curTime = g_activePlayer.currentVideoMediaTime;
        if (totalTime > 0) progress = (CGFloat)(curTime / totalTime);
    } else if (g_currentPlaybackTime > 0) {
        progress = 0; // unknown total; leave at 0 unless total known
    }
    if (progress < 0) progress = 0;
    if (progress > 1) progress = 1;
    CGFloat trackW = self.landscapeProgressTrack.bounds.size.width;
    CGFloat fillW = floor(trackW * progress);
    CGRect f = self.landscapeProgressFill.frame;
    f.size.width = fillW;
    f.size.height = 3;
    f.origin = CGPointZero;
    self.landscapeProgressFill.frame = f;
    if (self.landscapeElapsedLabel) self.landscapeElapsedLabel.text = [self ytmu_formatTime:curTime];
    if (self.landscapeTotalLabel) self.landscapeTotalLabel.text = [self ytmu_formatTime:totalTime];
    if (self.landscapeProgressKnob) {
        CGFloat knobS = 8;
        CGFloat knobX = fillW - knobS / 2.0;
        if (knobX < 0) knobX = 0;
        if (knobX > trackW - knobS) knobX = trackW - knobS;
        CGRect kf = self.landscapeProgressKnob.frame;
        kf.origin.x = self.landscapeProgressTrack.frame.origin.x + knobX;
        kf.origin.y = self.landscapeProgressTrack.frame.origin.y + (3 - knobS) / 2.0;
        kf.size.width = knobS;
        kf.size.height = knobS;
        self.landscapeProgressKnob.frame = kf;
    }
}

- (void)ytmu_setLandscapePlaying:(BOOL)playing {
    self.landscapeIsPlaying = playing;
    // Filled circle (theme ink) with a contrasting glyph, Image-2 style.
    self.landscapePlayButton.backgroundColor = YTMUAdaptiveInk(0.95, 0.9);
    self.landscapePlayButton.tintColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        return tc.userInterfaceStyle == UIUserInterfaceStyleLight ? [UIColor whiteColor] : [UIColor blackColor];
    }];
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
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold];
        UIImage *prev = [[UIImage systemImageNamed:@"backward.fill"] imageWithConfiguration:cfg];
        UIImage *next = [[UIImage systemImageNamed:@"forward.fill"] imageWithConfiguration:cfg];
        if (prev) {
            [self.landscapePrevButton setImage:prev forState:UIControlStateNormal];
            [self.landscapePrevButton setTitle:@"" forState:UIControlStateNormal];
        } else {
            [self.landscapePrevButton setTitle:@"prev" forState:UIControlStateNormal];
            [self.landscapePrevButton setTitleColor:YTMUAdaptiveInk(0.9, 0.9) forState:UIControlStateNormal];
        }
        if (next) {
            [self.landscapeNextButton setImage:next forState:UIControlStateNormal];
            [self.landscapeNextButton setTitle:@"" forState:UIControlStateNormal];
        } else {
            [self.landscapeNextButton setTitle:@"next" forState:UIControlStateNormal];
            [self.landscapeNextButton setTitleColor:YTMUAdaptiveInk(0.9, 0.9) forState:UIControlStateNormal];
        }
    } else {
        [self.landscapePrevButton setTitle:@"prev" forState:UIControlStateNormal];
        [self.landscapePrevButton setTitleColor:YTMUAdaptiveInk(0.9, 0.9) forState:UIControlStateNormal];
        [self.landscapeNextButton setTitle:@"next" forState:UIControlStateNormal];
        [self.landscapeNextButton setTitleColor:YTMUAdaptiveInk(0.9, 0.9) forState:UIControlStateNormal];
    }
    [self ytmu_setLandscapePlaying:self.landscapeIsPlaying];
}

- (NSString *)ytmu_formatTime:(CGFloat)seconds {
    if (!(seconds > 0)) return @"0:00";
    NSInteger total = (NSInteger)seconds;
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(total / 60), (long)(total % 60)];
}

- (void)ytmu_applyLandscapeTheme {
    // OS theme change: swap the ambient blur so the whole sheet (album
    // column + lyrics) follows light/dark together with the adaptive inks.
    if (!self.blurView) return;
    UIBlurEffectStyle style = YTMUInterfaceIsLight(self.view) ? UIBlurEffectStyleLight : UIBlurEffectStyleDark;
    UIBlurEffect *effect = [UIBlurEffect effectWithStyle:style];
    [UIView animateWithDuration:0.25 animations:^{
        self.blurView.effect = effect;
    }];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (@available(iOS 13.0, *)) {
        if (self.traitCollection.userInterfaceStyle != previousTraitCollection.userInterfaceStyle) {
            [self ytmu_applyLandscapeTheme];
        }
    }
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

#pragma mark - Provider actions menu

- (void)ytmu_headerMenu:(UIButton *)sender {
    [self ytmu_openProviderMenuFromView:sender];
}

- (void)ytmu_toolbarReload:(UIButton *)sender {
    [self forceReloadLyrics];
}

- (void)ytmu_postJSON:(NSString *)path body:(NSDictionary *)body completion:(void (^)(NSDictionary *json, NSError *error))completion {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@%@", YTMUApiBase(), path]];
    if (!url) {
        if (completion) completion(nil, [NSError errorWithDomain:@"YTMU" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"bad URL"}]);
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.timeoutInterval = 20.0;
    if (body) req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
        NSDictionary *json = nil;
        if (data && !err) json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (completion) completion(json, err);
    }] resume];
}

- (void)ytmu_getJSON:(NSString *)path completion:(void (^)(NSDictionary *json, NSError *error))completion {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@%@", YTMUApiBase(), path]];
    if (!url) {
        if (completion) completion(nil, [NSError errorWithDomain:@"YTMU" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"bad URL"}]);
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 15.0;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
        NSDictionary *json = nil;
        if (data && !err) json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (completion) completion(json, err);
    }] resume];
}

- (void)ytmu_openProviderMenuFromView:(UIView *)sender {
    NSString *vid = YTMUResolveCurrentVideoID() ?: g_currentVideoID;
    if (!vid.length) {
        sendDebugLog(@"[MUSIC] provider menu: no video ID");
        return;
    }
    if (self.providerPollTimer) return; // a probe is already running
    __block BOOL jwtDone = NO;
    [[YTMUTurnstileManager sharedManager] getJWTTokenWithCompletion:^(NSString *jwt) {
        if (jwtDone) return;
        jwtDone = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self ytmu_beginProviderProbeWithJWT:jwt fromView:sender];
        });
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!jwtDone) {
            jwtDone = YES;
            [self ytmu_beginProviderProbeWithJWT:nil fromView:sender];
        }
    });
}

- (void)ytmu_beginProviderProbeWithJWT:(NSString *)jwt fromView:(UIView *)sender {
    NSString *vid = YTMUResolveCurrentVideoID() ?: g_currentVideoID;
    if (!vid.length) return;
    NSMutableDictionary *body = [@{@"video_id": vid, @"lang": YTMUTargetLang()} mutableCopy];
    if (jwt.length) body[@"jwt"] = jwt;
    UIView *anchor = (sender && sender.window) ? sender : self.view;
    objc_setAssociatedObject(self, @selector(ytmu_openProviderMenuFromView:), anchor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self ytmu_postJSON:@"/api/lyrics/providers/start" body:body completion:^(NSDictionary *json, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *jobID = json[@"job_id"];
            if (![json[@"ok"] boolValue] || !jobID.length) {
                sendDebugLog(@"[MUSIC] provider probe start failed");
                return;
            }
            [self ytmu_stopProviderPoll];
            self.providerJobID = jobID;
            UIAlertController *loading = [UIAlertController alertControllerWithTitle:@"Probing providers" message:@"Starting..." preferredStyle:UIAlertControllerStyleAlert];
            [loading addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
                [self ytmu_stopProviderPoll];
            }]];
            self.providerLoadingAlert = loading;
            [self presentViewController:loading animated:YES completion:nil];
            self.providerPollTimer = [NSTimer scheduledTimerWithTimeInterval:1.2 target:self selector:@selector(ytmu_pollProviderJob:) userInfo:nil repeats:YES];
        });
    }];
}

- (void)ytmu_pollProviderJob:(NSTimer *)timer {
    if (!self.providerJobID.length) {
        [self ytmu_stopProviderPoll];
        return;
    }
    NSString *path = [NSString stringWithFormat:@"/api/lyrics/providers/status/%@", self.providerJobID];
    [self ytmu_getJSON:path completion:^(NSDictionary *json, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || ![json[@"ok"] boolValue]) {
                [self ytmu_stopProviderPoll];
                if (self.providerLoadingAlert) {
                    [self.providerLoadingAlert dismissViewControllerAnimated:YES completion:nil];
                    self.providerLoadingAlert = nil;
                }
                return;
            }
            NSString *state = json[@"state"] ?: @"";
            NSArray *cands = json[@"candidates"] ?: @[];
            if (self.providerLoadingAlert) {
                self.providerLoadingAlert.message = [NSString stringWithFormat:@"Found %lu so far…", (unsigned long)cands.count];
            }
            if ([state isEqualToString:@"complete"] || [state isEqualToString:@"error"]) {
                [self ytmu_stopProviderPoll];
                UIView *anchor = objc_getAssociatedObject(self, @selector(ytmu_openProviderMenuFromView:));
                UIAlertController *loading = self.providerLoadingAlert;
                self.providerLoadingAlert = nil;
                id saved = json[@"saved"];
                void (^show)(void) = ^{
                    if ([state isEqualToString:@"complete"]) {
                        [self ytmu_showProviderMenu:cands saved:([saved isKindOfClass:[NSString class]] ? saved : nil) fromView:anchor];
                    }
                };
                if (loading) [loading dismissViewControllerAnimated:YES completion:show];
                else show();
            }
        });
    }];
}

- (void)ytmu_stopProviderPoll {
    [self.providerPollTimer invalidate];
    self.providerPollTimer = nil;
    self.providerJobID = nil;
}

- (void)ytmu_showProviderMenu:(NSArray *)candidates saved:(NSString *)saved fromView:(UIView *)sender {
    NSString *vid = YTMUResolveCurrentVideoID() ?: g_currentVideoID;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Lyrics providers" message:vid preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *c in candidates) {
        if (![c isKindOfClass:[NSDictionary class]]) continue;
        NSString *prov = c[@"provider"];
        if (![prov isKindOfClass:[NSString class]] || !prov.length) continue;
        NSString *tier = ([c[@"tier"] isKindOfClass:[NSString class]]) ? c[@"tier"] : @"";
        NSInteger lines = [c[@"lines"] integerValue];
        BOOL isSaved = (saved.length > 0 && [prov isEqualToString:saved]);
        NSString *title = [NSString stringWithFormat:@"%@%@ — %@ · %ld lines", isSaved ? @"[saved] " : @"", prov, tier, (long)lines];
        [menu addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self ytmu_selectProvider:prov];
        }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"Best available (auto)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self forceReloadLyrics];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *pop = menu.popoverPresentationController;
    if (pop) {
        UIView *anchor = (sender && sender.window) ? sender : self.view;
        pop.sourceView = anchor;
        pop.sourceRect = anchor.bounds;
        pop.permittedArrowDirections = UIPopoverArrowDirectionAny;
    }
    [self presentViewController:menu animated:YES completion:nil];
}

- (void)ytmu_selectProvider:(NSString *)provider {
    NSString *vid = YTMUResolveCurrentVideoID() ?: g_currentVideoID;
    if (!vid.length || !provider.length) return;
    NSDictionary *body = @{@"video_id": vid, @"lang": YTMUTargetLang(), @"provider": provider};
    [self ytmu_postJSON:@"/api/lyrics/providers/select" body:body completion:^(NSDictionary *json, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSDictionary *data = json[@"data"];
            NSArray *lyrics = data[@"lyrics"];
            if ([json[@"ok"] boolValue] && [lyrics isKindOfClass:[NSArray class]] && lyrics.count > 0) {
                if (!g_lyricsCache) g_lyricsCache = [[NSMutableDictionary alloc] init];
                g_lyricsCache[vid] = lyrics;
                YTMULyricsCacheSave(vid, lyrics);
                self.loadingVideoID = vid;
                self.isLoading = NO;
                UILabel *statusLabel = [self.tableView.tableHeaderView viewWithTag:8888];
                if (statusLabel) statusLabel.text = @"";
                [self updateLyrics:lyrics];
                [[NSNotificationCenter defaultCenter] postNotificationName:@"YTMULyricsDidLoad" object:vid userInfo:@{@"lyrics": lyrics}];
                sendDebugLog([NSString stringWithFormat:@"[MUSIC] provider selected: %@", provider]);
            } else {
                sendDebugLog([NSString stringWithFormat:@"[MUSIC] provider select failed: %@", provider]);
            }
        });
    }];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGFloat W = self.view.bounds.size.width;
    CGFloat H = self.view.bounds.size.height;
    BOOL landscape = (W > H);

    if (landscape) {
        // --- Landscape, Image-2 style: fullscreen ambient blur, floating
        // album card left, lyrics right, minimal transport, toolbar.
        self.artworkImageView.hidden = NO;
        self.blurView.hidden = NO;
        self.darkOverlay.hidden = NO;
        [self ytmu_applyLandscapeTheme];

        // Show landscape chrome (right panel stays hidden: no seam by design)
        self.landscapeArtPanel.hidden = NO;
        self.landscapeRightPanel.hidden = YES;
        self.landscapeInfoPanel.hidden = NO;
        self.landscapeExitButton.hidden = NO;
        self.landscapeToolbar.hidden = NO;

        // Sync artwork image whenever it changes
        if (self.artworkImageView.image && self.landscapeArtImageView.image != self.artworkImageView.image) {
            self.landscapeArtImageView.image = self.artworkImageView.image;
            // Cached/file path bypasses loadArtwork: still sample it (cheap;
            // no-ops when the bright/dark bucket is unchanged).
            [self ytmu_probeArtworkBrightness:self.artworkImageView.image];
        }

        CGFloat safeTop = 0, safeBottom = 0;
        if (@available(iOS 11.0, *)) {
            safeTop = self.view.safeAreaInsets.top;
            safeBottom = self.view.safeAreaInsets.bottom;
        }
        // Narrow left column like the reference: ~30%, clamped.
        CGFloat leftW = roundf(MIN(MAX(W * 0.30f, 260.0f), 360.0f));
        CGFloat rightW = W - leftW;
        self.landscapeArtPanel.frame = CGRectMake(0, 0, leftW, H);

        // Album card: square, rounded, floating with shadow.
        CGFloat colX = 16.0;
        CGFloat colW = leftW - colX * 2.0;
        CGFloat artS = colW;
        CGFloat colH = artS + 10.0 + 20.0 + 2.0 + 16.0 + 8.0 + 12.0 + 4.0 + 8.0 + 48.0;
        CGFloat artY = floor((H - colH) / 2.0);
        if (artY < safeTop + 8.0) artY = safeTop + 8.0;
        CGRect artFrame = CGRectMake(colX, artY, artS, artS);
        self.landscapeArtImageView.frame = artFrame;
        self.landscapeArtImageView.contentMode = UIViewContentModeScaleAspectFill;
        self.landscapeArtImageView.layer.cornerRadius = 10;
        self.landscapeArtImageView.layer.masksToBounds = YES;
        UIView *artShadow = [self.landscapeArtPanel viewWithTag:7104];
        if (!artShadow) {
            artShadow = [[UIView alloc] init];
            artShadow.tag = 7104;
            artShadow.backgroundColor = [UIColor blackColor];
            artShadow.userInteractionEnabled = NO;
            [self.landscapeArtPanel insertSubview:artShadow belowSubview:self.landscapeArtImageView];
        }
        artShadow.frame = artFrame;
        artShadow.layer.cornerRadius = 10;
        artShadow.layer.shadowColor = [[UIColor blackColor] CGColor];
        artShadow.layer.shadowOpacity = 0.35;
        artShadow.layer.shadowRadius = 14;
        artShadow.layer.shadowOffset = CGSizeMake(0, 8);

        // Title / artist under the card.
        self.landscapeInfoPanel.frame = CGRectMake(colX, artY + artS + 10.0, colW, colH - artS - 10.0);
        self.landscapeTitleLabel.frame = CGRectMake(0, 0, colW, 20);
        self.landscapeArtistLabel.frame = CGRectMake(0, 22, colW, 16);

        // Time labels + thin progress bar + knob.
        CGFloat timesY = 46;
        self.landscapeElapsedLabel.frame = CGRectMake(0, timesY, 60, 12);
        self.landscapeTotalLabel.frame = CGRectMake(colW - 60, timesY, 60, 12);
        CGFloat barY = timesY + 16;
        self.landscapeProgressTrack.frame = CGRectMake(0, barY, colW, 3);
        CGFloat progress = 0;
        CGFloat totalTime = 0;
        CGFloat curTime = 0;
        if (g_activePlayer && [g_activePlayer respondsToSelector:@selector(currentVideoTotalMediaTime)]) {
            totalTime = g_activePlayer.currentVideoTotalMediaTime;
            curTime = g_activePlayer.currentVideoMediaTime;
            if (totalTime > 0) progress = (CGFloat)(curTime / totalTime);
        }
        if (progress < 0) progress = 0;
        if (progress > 1) progress = 1;
        CGFloat trackW = self.landscapeProgressTrack.bounds.size.width;
        CGFloat fillW = floor(trackW * progress);
        self.landscapeProgressFill.frame = CGRectMake(0, 0, fillW, 3);
        self.landscapeElapsedLabel.text = [self ytmu_formatTime:curTime];
        self.landscapeTotalLabel.text = [self ytmu_formatTime:totalTime];
        CGFloat knobS = 8;
        CGFloat knobX = fillW - knobS / 2.0;
        if (knobX < 0) knobX = 0;
        if (knobX > trackW - knobS) knobX = trackW - knobS;
        self.landscapeProgressKnob.frame = CGRectMake(knobX, barY + (3 - knobS) / 2.0, knobS, knobS);

        // Centered minimal transport: prev, filled-circle play, next.
        CGFloat tY = barY + 14;
        CGFloat iconS = 44, playD = 48, tGap = 24;
        CGFloat totalBtnW = iconS + playD + iconS + tGap * 2;
        CGFloat btnX0 = floor((colW - totalBtnW) / 2.0);
        self.landscapePrevButton.frame = CGRectMake(btnX0, tY + 2, iconS, iconS);
        self.landscapePlayButton.frame = CGRectMake(btnX0 + iconS + tGap, tY, playD, playD);
        self.landscapeNextButton.frame = CGRectMake(btnX0 + iconS + tGap + playD + tGap, tY + 2, iconS, iconS);
        self.landscapePlayButton.layer.cornerRadius = playD / 2.0;

        // Top-right exit circle.
        CGFloat exitTop = (safeTop > 0 ? safeTop + 6.0 : 12.0);
        CGFloat exitS = 32;
        self.landscapeExitButton.frame = CGRectMake(W - exitS - 12.0, exitTop, exitS, exitS);
        self.landscapeExitButton.layer.cornerRadius = exitS / 2.0;

        // Bottom-right floating toolbar: provider list + reload.
        CGFloat toolBtnS = 34, toolPad = 4;
        CGFloat toolW = toolBtnS * 2 + toolPad * 2 + 4;
        CGFloat toolH = toolBtnS + 6;
        CGFloat toolY = H - safeBottom - toolH - 12.0;
        self.landscapeToolbar.frame = CGRectMake(W - toolW - 16.0, toolY, toolW, toolH);
        self.landscapeToolbar.layer.cornerRadius = toolH / 2.0;
        self.landscapeProviderButton.frame = CGRectMake(toolPad + 2, 3, toolBtnS, toolBtnS);
        self.landscapeReloadButton.frame = CGRectMake(toolPad + 2 + toolBtnS + 4, 3, toolBtnS, toolBtnS);

        // Keep title/artist fresh
        [self ytmu_updateLandscapeMetadata];

        // tableView floats on the ambient blur, right of the column
        self.tableView.frame = CGRectMake(leftW, 0, rightW, H);
        [self.view bringSubviewToFront:self.landscapeArtPanel];
        [self.view bringSubviewToFront:self.tableView];
        [self.view bringSubviewToFront:self.fpsLabel];
        [self.view bringSubviewToFront:self.landscapeToolbar];
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
        self.landscapeToolbar.hidden = YES;

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
    [self.providerPollTimer invalidate];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self ytmu_assertOnTop];
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
            [self ytmu_stopProviderPoll];
            if (self.providerLoadingAlert) {
                [self.providerLoadingAlert dismissViewControllerAnimated:NO completion:nil];
                self.providerLoadingAlert = nil;
            }
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

// Sample new artwork; when the background flips bright/dark, re-resolve
// every background-derived color so text keeps contrasting with the blur
// instead of following the OS theme.
- (void)ytmu_probeArtworkBrightness:(UIImage *)img {
    CGFloat lum = YTMUArtworkLuminance(img);
    if (lum < 0) return;
    int light = (lum > 0.55) ? 1 : 0;
    if (light == g_ytmu_bgLight) return;
    g_ytmu_bgLight = light;
    sendDebugLog([NSString stringWithFormat:@"[MUSIC] bg luminance %.2f -> %@ ink", lum, light ? @"black" : @"white"]);
    [self ytmu_refreshBgDerivedInk];
}

- (void)ytmu_refreshBgDerivedInk {
    if (self.landscapeTitleLabel) self.landscapeTitleLabel.textColor = YTMULyricInk(1.0, 1.0, self.view);
    if (self.landscapeArtistLabel) self.landscapeArtistLabel.textColor = YTMULyricInk(0.6, 0.6, self.view);
    if (self.landscapeElapsedLabel) self.landscapeElapsedLabel.textColor = YTMULyricInk(0.6, 0.6, self.view);
    if (self.landscapeTotalLabel) self.landscapeTotalLabel.textColor = YTMULyricInk(0.6, 0.6, self.view);
    // reloadData keeps the scroll offset; cells re-resolve ink in configureCell.
    if (self.tableView) [self.tableView reloadData];
}

- (void)ytmu_applyArtworkImage:(UIImage *)img forVideoID:(NSString *)videoID {
    if (!img) return;
    if (![self.loadingVideoID isEqualToString:videoID]) return;
    [UIView transitionWithView:self.artworkImageView duration:0.4 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
        self.artworkImageView.image = img;
    } completion:nil];
    self.landscapeArtImageView.image = img;
    self.artworkVideoID = videoID;
    [self ytmu_probeArtworkBrightness:img];
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
                    [self ytmu_applyArtworkImage:img forVideoID:videoID];
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
                        [self ytmu_applyArtworkImage:img2 forVideoID:videoID];
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
                    if ([dict[@"pro"] boolValue]) {
                        // Server served the full cached result for this fast
                        // request: treat it as final, skip the full fetch.
                        if (!g_lyricsCache) g_lyricsCache = [[NSMutableDictionary alloc] init];
                        g_lyricsCache[videoID] = dict[@"lyrics"];
                        YTMULyricsCacheSave(videoID, dict[@"lyrics"]);
                        self.isLoading = NO;
                        self.loadingSince = nil;
                        if ([g_globalLoadingVideoID isEqualToString:videoID]) {
                            YTMUReleaseGlobalFetch();
                        }
                        return;
                    }
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

- (void)ytmu_assertOnTop {
    // Embed only (tag 9999): YT reorders/unhides its engagement-panel
    // content at any time (song change, layout passes), which buries the
    // lyrics view again after updateLyrics put it on top. Modal sheets are
    // presented above YT by UIKit and need nothing here.
    if (self.isModal) return;
    if (self.view.tag != 9999) return;
    UIView *contentContainer = self.view.superview;
    if (!contentContainer) return;
    if ([contentContainer.subviews lastObject] != self.view) {
        [contentContainer bringSubviewToFront:self.view];
    }
    // Never blank the panel: only hide YT siblings while our view is
    // actually visible (lyricsAlwaysOn off + hidden sheet = native panel).
    if (self.view.hidden || self.view.alpha < 0.05 || !self.view.window) return;
    for (UIView *sub in contentContainer.subviews) {
        if (sub != self.view && sub.tag != 9999 && !sub.hidden) sub.hidden = YES;
    }
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
    // Self-healing z-order (~1/sec): YT reshuffles panel subviews behind
    // our back; the check itself is a pointer compare so per-frame cost is
    // ~zero. No-op for modal sheets (see ytmu_assertOnTop).
    static int ytmuTopAssertTick = 0;
    if ((++ytmuTopAssertTick % 90) == 0) {
        [self ytmu_assertOnTop];
    }
    if (self.landscapeInfoPanel && !self.landscapeInfoPanel.hidden) {
        [self ytmu_updateLandscapeProgress];
        // playerResponse can arrive after the panel opens; keep retrying
        // until a real title/artist is shown (throttled: ~1/sec).
        static int landscapeMetaRetryTick = 0;
        BOOL needTitle = (self.landscapeTitleLabel.text.length == 0 ||
                          [self.landscapeTitleLabel.text isEqualToString:@"Now Playing"]);
        if ((needTitle || self.landscapeArtistLabel.text.length == 0) &&
            (landscapeMetaRetryTick++ % 60) == 0) {
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
        // Instrumental gap rows carry startTimeMs only (no time key).
        if (time <= 0) time = [lyric[@"startTimeMs"] doubleValue] / 1000.0;

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
        [self ytmu_assertOnTop];
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
        cell.lyricLabel.textColor = YTMULyricInk(0.2, 0.2, self.view);

        NSShadow *sh = [[NSShadow alloc] init];
        sh.shadowColor = YTMULyricShadow(self.view);
        sh.shadowOffset = CGSizeMake(0, 2);
        sh.shadowBlurRadius = 4;
        cell.wipeLabel.attributedText = [[NSAttributedString alloc] initWithString:display
            attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: YTMULyricInk(1.0, 1.0, self.view), NSShadowAttributeName: sh}];

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

- (BOOL)ytmuIsInstrumentalLyric:(NSDictionary *)lyric {
    if ([lyric[@"isInstrumental"] boolValue]) return YES;
    id raw = lyric[@"text"];
    if (![raw isKindOfClass:[NSString class]]) return NO;
    NSString *t = [(NSString *)raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [t isEqualToString:@"[instrumental]"] || [t isEqualToString:@"[MUSIC] Instrumental"];
}

- (void)configureCell:(YTMULyricsCell *)cell atIndex:(NSInteger)index isActive:(BOOL)isActive currentTime:(double)currentTime {
    if (index < 0 || index >= self.lyrics.count) return;

    NSDictionary *lyric = self.lyrics[index];
    if ([self ytmuIsInstrumentalLyric:lyric]) {
        // Instrumental gap: music-note icon row (mirrors the braccato
        // preview icon). No wipe mask, no word timing, no translation row.
        // Font/alignment are reset explicitly in the text branch below
        // because cells are reused.
        cell.lyricLabel.attributedText = nil;
        cell.lyricLabel.text = @"\u266A";
        cell.lyricLabel.font = [UIFont boldSystemFontOfSize:28];
        cell.lyricLabel.textAlignment = NSTextAlignmentCenter;
        cell.lyricLabel.alpha = 1.0;
        cell.lyricLabel.transform = CGAffineTransformIdentity;
        cell.lyricLabel.textColor = YTMULyricInk(isActive ? 1.0 : 0.2, isActive ? 1.0 : 0.2, self.view);
        cell.lyricLabel.layer.shadowColor = YTMULyricShadow(self.view).CGColor;
        cell.lyricLabel.layer.shadowOffset = CGSizeMake(0, 2);
        cell.lyricLabel.layer.shadowRadius = 4.0;
        cell.lyricLabel.layer.shadowOpacity = isActive ? 0.75 : 0.32;
        cell.lyricLabel.layer.masksToBounds = NO;
        [cell clearWipe];
        cell.transLabel.text = @"";
        cell.transLabel.hidden = YES;
        return;
    }
    NSString *displayText = [self normalizedLyricText:lyric[@"text"]];
    cell.lyricLabel.font = [UIFont boldSystemFontOfSize:22];
    cell.lyricLabel.textAlignment = NSTextAlignmentNatural;
    BOOL hasWords = [lyric[@"wordSynced"] boolValue] && [(NSArray *)lyric[@"parts"] count] > 0;
    if (hasWords) displayText = [self wbwDisplayTextForLyric:lyric ranges:NULL];
    cell.lyricLabel.alpha = 1.0;
    cell.lyricLabel.transform = CGAffineTransformIdentity;

    if (!self.isSynced) {
        cell.lyricLabel.attributedText = nil;
        cell.lyricLabel.text = displayText;
        cell.lyricLabel.textColor = YTMULyricInk(1.0, 1.0, self.view);
        cell.lyricLabel.layer.shadowColor = YTMULyricShadow(self.view).CGColor;
        cell.lyricLabel.layer.shadowOffset = CGSizeMake(0, 2);
        cell.lyricLabel.layer.shadowRadius = 4.0;
        cell.lyricLabel.layer.shadowOpacity = 0.7;
        cell.lyricLabel.layer.masksToBounds = NO;
        [cell clearWipe];

        cell.transLabel.textColor = YTMULyricInk(0.75, 0.75, self.view);
    } else if (isActive) {
        if (hasWords) {
            [self applyWordColorsToCell:cell lyric:lyric index:index currentTime:currentTime force:YES];
        } else {
            cell.lyricLabel.attributedText = nil;
            cell.lyricLabel.text = displayText;
            cell.lyricLabel.textColor = YTMULyricInk(1.0, 1.0, self.view);
            [cell clearWipe];
        }

        cell.lyricLabel.layer.shadowColor = YTMULyricShadow(self.view).CGColor;
        cell.lyricLabel.layer.shadowOffset = CGSizeMake(0, 2);
        cell.lyricLabel.layer.shadowRadius = 4.0;
        cell.lyricLabel.layer.shadowOpacity = 0.75;
        cell.lyricLabel.layer.masksToBounds = NO;

        cell.transLabel.textColor = YTMULyricInk(0.7, 0.7, self.view);
    } else {
        cell.lyricLabel.attributedText = nil;
        cell.lyricLabel.text = displayText;
        cell.lyricLabel.textColor = YTMULyricInk(0.2, 0.2, self.view);
        cell.lyricLabel.layer.shadowOpacity = 0.32;
        [cell clearWipe];

        cell.transLabel.textColor = YTMULyricInk(0.25, 0.25, self.view);
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
    double seekBase = time ? [time doubleValue] : -1;
    if (seekBase < 0) seekBase = [lyric[@"startTimeMs"] doubleValue] / 1000.0;

    if (seekBase >= 0) {
        double seekTime = seekBase;
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

// Bounded retry chain: a single deferred attempt misses whenever the
// interface hasn't finished rotating, the top VC is mid-presentation, or
// the video ID isn't resolved yet. Keep trying while the phone stays
// landscape; every attempt re-checks visibility first so we never double
// present.
static void YTMUAttemptLandscapeOpenChain(int left) {
    if (left <= 0) return;
    if (isLyricsViewVisibleOnScreen()) return;
    if (!YTMUIsInterfaceLandscape()) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            YTMUAttemptLandscapeOpenChain(left - 1);
        });
        return;
    }
    NSString *vid = YTMUResolveCurrentVideoID();
    UIViewController *top = topMostViewController();
    if (!vid.length || !top || top.presentedViewController || top.isBeingPresented || top.isBeingDismissed) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            YTMUAttemptLandscapeOpenChain(left - 1);
        });
        return;
    }
    openLyricsFullscreenForLandscape();
}

static void YTMULandscapeOrientationChanged(NSNotification *note) {
    UIDeviceOrientation o = [UIDevice currentDevice].orientation;
    BOOL deviceLandscape = (o == UIDeviceOrientationLandscapeLeft || o == UIDeviceOrientationLandscapeRight);
    if (!deviceLandscape) {
        // Missed earlier (flat rotation, late observer, already landscape on
        // entry): if the interface is landscape anyway, still try.
        if (!YTMUIsInterfaceLandscape()) return;
        YTMUAttemptLandscapeOpenChain(2);
        return;
    }
    // Defer past the rotation animation so top VC is stable, then retry.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        YTMUAttemptLandscapeOpenChain(4);
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
