#import "LyricsSettingsController.h"
#import "../LyricsShared.h"

// Lightweight progress overlay for the cache sync feature. UIAlertController
// doesn't officially support adding a UIProgressView, so this is a small
// dedicated card instead of hacking subviews into an alert.
@interface YTMUSyncProgressOverlay : UIView
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *itemLabel;
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) UILabel *countLabel;
@property (nonatomic, copy) void (^onCancel)(void);
@end

@implementation YTMUSyncProgressOverlay

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.35];

        UIView *card = [[UIView alloc] init];
        card.translatesAutoresizingMaskIntoConstraints = NO;
        card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        card.layer.cornerRadius = 14;
        card.layer.masksToBounds = YES;
        [self addSubview:card];

        self.titleLabel = [[UILabel alloc] init];
        self.titleLabel.font = [UIFont boldSystemFontOfSize:16];
        self.titleLabel.textColor = [UIColor labelColor];
        self.titleLabel.textAlignment = NSTextAlignmentCenter;
        self.titleLabel.text = @"Syncing lyrics cache";

        self.itemLabel = [[UILabel alloc] init];
        self.itemLabel.font = [UIFont systemFontOfSize:13];
        self.itemLabel.textColor = [UIColor secondaryLabelColor];
        self.itemLabel.textAlignment = NSTextAlignmentCenter;
        self.itemLabel.numberOfLines = 1;
        self.itemLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        self.itemLabel.text = @"Checking server cache…";

        self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        self.progressView.progress = 0.0;

        self.countLabel = [[UILabel alloc] init];
        self.countLabel.font = [UIFont systemFontOfSize:12];
        self.countLabel.textColor = [UIColor tertiaryLabelColor];
        self.countLabel.textAlignment = NSTextAlignmentCenter;

        UIButton *cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [cancelButton setTitle:@"Cancel" forState:UIControlStateNormal];
        cancelButton.titleLabel.font = [UIFont systemFontOfSize:14];
        [cancelButton addTarget:self action:@selector(ytmu_cancelTapped) forControlEvents:UIControlEventTouchUpInside];

        for (UIView *v in @[self.titleLabel, self.itemLabel, self.progressView, self.countLabel, cancelButton]) {
            v.translatesAutoresizingMaskIntoConstraints = NO;
            [card addSubview:v];
        }

        [NSLayoutConstraint activateConstraints:@[
            [card.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [card.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [card.widthAnchor constraintEqualToConstant:280],

            [self.titleLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:20],
            [self.titleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
            [self.titleLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

            [self.itemLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:10],
            [self.itemLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
            [self.itemLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

            [self.progressView.topAnchor constraintEqualToAnchor:self.itemLabel.bottomAnchor constant:14],
            [self.progressView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
            [self.progressView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

            [self.countLabel.topAnchor constraintEqualToAnchor:self.progressView.bottomAnchor constant:8],
            [self.countLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
            [self.countLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

            [cancelButton.topAnchor constraintEqualToAnchor:self.countLabel.bottomAnchor constant:12],
            [cancelButton.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
            [cancelButton.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
        ]];
    }
    return self;
}

- (void)ytmu_cancelTapped {
    if (self.onCancel) self.onCancel();
}

- (void)dismissAnimated {
    [UIView animateWithDuration:0.2 animations:^{
        self.alpha = 0.0;
    } completion:^(BOOL finished) {
        [self removeFromSuperview];
    }];
}

@end

@interface LyricsSettingsController ()
@property (nonatomic, strong) NSArray *previewLyrics;
@end

@implementation LyricsSettingsController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Lyrics System";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"]];
    if (!d[@"lyricsCacheEnabled"]) d[@"lyricsCacheEnabled"] = @YES;
    if (!d[@"lyricsCacheMaxCount"]) d[@"lyricsCacheMaxCount"] = @200;
    if (!d[@"lyricsCacheMaxSizeMB"]) d[@"lyricsCacheMaxSizeMB"] = @50;
    if (!d[@"lyricsAlwaysOn"]) d[@"lyricsAlwaysOn"] = @YES;
    if (!d[@"sendLyricsScreenshotDebug"]) d[@"sendLyricsScreenshotDebug"] = @NO;
    if (!d[@"sendDebugLogsToServer"]) d[@"sendDebugLogsToServer"] = @NO;
    if (!d[@"debugLogLevel"]) d[@"debugLogLevel"] = @0;
    if (!d[@"lyricsFpsMeter"]) d[@"lyricsFpsMeter"] = @YES;
    if (!d[@"lyricsPrecacheQueue"]) d[@"lyricsPrecacheQueue"] = @YES;
    if (!d[@"lyricsAutoUpdate"]) d[@"lyricsAutoUpdate"] = @YES;
    if (!d[@"lyricsApiEndpoint"]) d[@"lyricsApiEndpoint"] = @"https://ytmtranslate.chiuhuang.dev";
    if (!d[@"lyricsTargetLang"]) d[@"lyricsTargetLang"] = @"zh-TW";
    if (!d[@"lyricsAutoZhConvert"]) d[@"lyricsAutoZhConvert"] = @YES;
    [[NSUserDefaults standardUserDefaults] setObject:d forKey:@"YTMUltimate"];
    [self loadPreview];
}

- (void)loadPreview {
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"YTMU_LyricsCache"];
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    if (files.count == 0) {
        self.previewLyrics = @[@{@"text": @"No cached lyrics yet", @"translated": @"Play a song to cache lyrics"}];
        return;
    }
    // pick most recent
    NSString *latest = nil;
    NSDate *latestDate = [NSDate distantPast];
    for (NSString *f in files) {
        NSString *fp = [dir stringByAppendingPathComponent:f];
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:fp error:nil];
        NSDate *mod = attr[NSFileModificationDate];
        if ([mod compare:latestDate] == NSOrderedDescending) {
            latestDate = mod;
            latest = fp;
        }
    }
    if (latest) {
        NSData *data = [NSData dataWithContentsOfFile:latest];
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSArray *ly = dict[@"lyrics"];
        if ([ly count] > 20) ly = [ly subarrayWithRange:NSMakeRange(0, 20)];
        self.previewLyrics = ly;
        if (!self.previewLyrics.count) self.previewLyrics = @[@{@"text": @"Empty cache file"}];
    }
}

- (NSDictionary *)cacheStats {
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"YTMU_LyricsCache"];
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil] ?: @[];
    unsigned long long total = 0;
    for (NSString *f in files) {
        NSString *fp = [dir stringByAppendingPathComponent:f];
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:fp error:nil];
        total += [attr fileSize];
    }
    return @{@"count": @(files.count), @"size": @(total)};
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 6; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 9;
    if (section == 1) return 3;
    if (section == 2) return 3;
    if (section == 3) return (NSInteger)self.previewLyrics.count + 1;
    if (section == 4) return 5;
    if (section == 5) return 1;
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"Lyrics Display";
    if (section == 1) return @"Translation";
    if (section == 2) return @"Client Cache";
    if (section == 3) return @"Preview (most recent cached)";
    if (section == 4) return @"Actions";
    if (section == 5) return @"Timing Offset";
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"Always show translated lyrics auto-opens the panel, storage is on-device, and debug uploads default to off.";
    if (section == 1) return @"Server used to fetch and translate lyrics, and the language lyrics get translated into. Lines already in that Chinese script (Simplified or Traditional) are never sent to the translator — they just get their script normalized. Auto-convert inlines the script change (e.g. zh-CN to zh-TW) right into the lyrics and skips the translate row; lines already in your language never show a duplicate translate row. Examples: zh-TW, zh-CN, en, ja, ko.";
    if (section == 2) return @"Limits are enforced automatically on save. Count limit removes oldest first. Size limit removes oldest until under limit.";
    if (section == 3) return @"Preview shows up to 20 lines from the newest cached file.";
    if (section == 4) return @"Sync pulls songs already translated on the server straight into your local cache — it never re-runs translation, so it's fast and free even for a large backlog.";
    if (section == 5) return @"Per-song timing offset in seconds. Positive = lyrics ahead of audio. Range: -30 to +30 seconds. Applies to current song only.";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"]];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
    else {
        // Full reset: recycled cells otherwise leak icons, colors and fonts
        // from other rows (e.g. random icons on lyric preview rows).
        for (UIView *v in cell.contentView.subviews) [v removeFromSuperview];
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.backgroundColor = nil;
        cell.textLabel.textColor = nil;
        cell.textLabel.font = nil;
        cell.textLabel.numberOfLines = 1;
        cell.detailTextLabel.textColor = nil;
        cell.detailTextLabel.font = nil;
        cell.imageView.image = nil;
    }
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

    if (indexPath.section == 0) {
        if (indexPath.row == 7) {
            cell.textLabel.text = @"Log level";
            cell.detailTextLabel.text = @"Off = no uploads, Errors = failures only, All = info + warnings + errors";
            cell.imageView.image = [UIImage systemImageNamed:@"waveform.badge.exclamationmark"];
            UISegmentedControl *segment = [[UISegmentedControl alloc] initWithItems:@[@"Off", @"Err", @"All"]];
            segment.selectedSegmentIndex = MIN(MAX([dict[@"debugLogLevel"] integerValue], 0), 2);
            segment.accessibilityIdentifier = @"debugLogLevel";
            [segment addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = segment;
            return cell;
        }
        NSArray *items = @[
            @{@"title": @"Always show translated lyrics", @"desc": @"Auto-show custom panel when lyrics load", @"key": @"lyricsAlwaysOn"},
            @{@"title": @"Enable client cache", @"desc": @"Store lyrics on device (recommended)", @"key": @"lyricsCacheEnabled"},
            @{@"title": @"Selectable lyrics", @"desc": @"Allow selecting / copying text inside the lyrics panel", @"key": @"selectableLyrics"},
            @{@"title": @"FPS meter on volume down", @"desc": @"Volume-down toggles lyric render-rate readout (also lowers volume)", @"key": @"lyricsFpsMeter"},
            @{@"title": @"Precache queue (next 5)", @"desc": @"Pre-fetch lyrics for upcoming songs when queue changes", @"key": @"lyricsPrecacheQueue"},
            @{@"title": @"Auto update lyrics", @"desc": @"Check server for upgraded lyrics when cached lyrics are shown", @"key": @"lyricsAutoUpdate"},
            @{@"title": @"Send debug to server", @"desc": @"Upload debug events to ytmtranslate.chiuhuang.dev", @"key": @"sendDebugLogsToServer"},
            @{@"title": @"Send screenshot debug data", @"desc": @"Upload a UI hierarchy only after you take a screenshot", @"key": @"sendLyricsScreenshotDebug"}
        ];
        NSInteger idx = indexPath.row;
        if (idx > 6) idx -= 1; // rows past the Log level segment shift down one
        NSDictionary *it = items[idx];
        cell.textLabel.text = it[@"title"];
        cell.detailTextLabel.text = it[@"desc"];
        cell.imageView.image = [UIImage systemImageNamed:@[@"quote.bubble", @"internaldrive", @"textformat.abc", @"speedometer", @"arrow.triangle.2.circlepath", @"arrow.2.circlepath", @"antenna.radiowaves.left.and.right", @"ladybug"][idx]];
        UISwitch *sw = [[UISwitch alloc] init];
        sw.accessibilityIdentifier = it[@"key"];
        sw.on = [dict[it[@"key"]] boolValue];
        [sw addTarget:self action:@selector(toggleSwitch:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        return cell;
    }
    if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"API endpoint";
            cell.detailTextLabel.text = @"Server for fetching + translating lyrics";
            UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 200, 32)];
            tf.text = dict[@"lyricsApiEndpoint"] ?: @"https://ytmtranslate.chiuhuang.dev";
            tf.borderStyle = UITextBorderStyleRoundedRect;
            tf.keyboardType = UIKeyboardTypeURL;
            tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
            tf.autocorrectionType = UITextAutocorrectionTypeNo;
            tf.textAlignment = NSTextAlignmentRight;
            tf.adjustsFontSizeToFitWidth = YES;
            tf.minimumFontSize = 11;
            tf.accessibilityIdentifier = @"lyricsApiEndpoint";
            tf.delegate = self;
            tf.inputAccessoryView = [self KBToolbar:tf];
            cell.accessoryView = tf;
            cell.imageView.image = [UIImage systemImageNamed:@"server.rack"];
            return cell;
        }
        if (indexPath.row == 1) {
            cell.textLabel.text = @"Translate to";
            cell.detailTextLabel.text = @"Language code, e.g. zh-TW, zh-CN, en, ja, ko";
            UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 100, 32)];
            tf.text = dict[@"lyricsTargetLang"] ?: @"zh-TW";
            tf.borderStyle = UITextBorderStyleRoundedRect;
            tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
            tf.autocorrectionType = UITextAutocorrectionTypeNo;
            tf.textAlignment = NSTextAlignmentRight;
            tf.accessibilityIdentifier = @"lyricsTargetLang";
            tf.delegate = self;
            tf.inputAccessoryView = [self KBToolbar:tf];
            cell.accessoryView = tf;
            cell.imageView.image = [UIImage systemImageNamed:@"character.book.closed"];
            return cell;
        }
        if (indexPath.row == 2) {
            cell.textLabel.text = @"Auto-convert zh-CN to zh-TW";
            cell.detailTextLabel.text = @"Show Simplified lyrics as Traditional your language is already set to; no translate row";
            cell.imageView.image = [UIImage systemImageNamed:@"textformat.alt"];
            UISwitch *sw = [[UISwitch alloc] init];
            sw.accessibilityIdentifier = @"lyricsAutoZhConvert";
            sw.on = [dict[@"lyricsAutoZhConvert"] boolValue];
            [sw addTarget:self action:@selector(toggleSwitch:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            return cell;
        }
    }
    if (indexPath.section == 2) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Max cached songs";
            cell.detailTextLabel.text = @"Number of videoIDs to keep";
            UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 80, 32)];
            tf.text = [NSString stringWithFormat:@"%@", dict[@"lyricsCacheMaxCount"] ?: @200];
            tf.borderStyle = UITextBorderStyleRoundedRect;
            tf.keyboardType = UIKeyboardTypeNumberPad;
            tf.textAlignment = NSTextAlignmentRight;
            tf.accessibilityIdentifier = @"lyricsCacheMaxCount";
            tf.delegate = self;
            tf.inputAccessoryView = [self KBToolbar:tf];
            cell.accessoryView = tf;
            cell.imageView.image = [UIImage systemImageNamed:@"number"];
            return cell;
        }
        if (indexPath.row == 1) {
            cell.textLabel.text = @"Max size (MB)";
            cell.detailTextLabel.text = @"Total cache size limit";
            UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 80, 32)];
            tf.text = [NSString stringWithFormat:@"%@", dict[@"lyricsCacheMaxSizeMB"] ?: @50];
            tf.borderStyle = UITextBorderStyleRoundedRect;
            tf.keyboardType = UIKeyboardTypeNumberPad;
            tf.textAlignment = NSTextAlignmentRight;
            tf.accessibilityIdentifier = @"lyricsCacheMaxSizeMB";
            tf.delegate = self;
            tf.inputAccessoryView = [self KBToolbar:tf];
            cell.accessoryView = tf;
            cell.imageView.image = [UIImage systemImageNamed:@"externaldrive"];
            return cell;
        }
        if (indexPath.row == 2) {
            NSDictionary *stats = [self cacheStats];
            cell.textLabel.text = @"Current usage";
            unsigned long long sz = [stats[@"size"] unsignedLongLongValue];
            NSString *szStr = [NSByteCountFormatter stringFromByteCount:sz countStyle:NSByteCountFormatterCountStyleFile];
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ files • %@", stats[@"count"], szStr];
            cell.imageView.image = [UIImage systemImageNamed:@"chart.bar.doc.horizontal"];
            cell.accessoryType = UITableViewCellAccessoryNone;
            return cell;
        }
    }
    if (indexPath.section == 3) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Refresh preview";
            cell.textLabel.textColor = [UIColor systemBlueColor];
            cell.imageView.image = [UIImage systemImageNamed:@"eye"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
        NSDictionary *line = self.previewLyrics[indexPath.row - 1];
        cell.textLabel.text = line[@"text"] ?: @"";
        cell.textLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        cell.textLabel.numberOfLines = 0;
        cell.detailTextLabel.text = line[@"translated"] ?: @"";
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
        cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        return cell;
    }
    if (indexPath.section == 4) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Clear all cached lyrics";
            cell.textLabel.textColor = [UIColor systemRedColor];
            cell.imageView.image = [UIImage systemImageNamed:@"trash"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
        if (indexPath.row == 1) {
            cell.textLabel.text = @"Enforce limits now";
            cell.textLabel.textColor = [UIColor systemOrangeColor];
            cell.imageView.image = [UIImage systemImageNamed:@"hammer"];
            return cell;
        }
        if (indexPath.row == 2) {
            cell.textLabel.text = @"Sync cache from server";
            cell.detailTextLabel.text = @"Pull already-translated songs into local cache";
            cell.textLabel.textColor = [UIColor systemBlueColor];
            cell.imageView.image = [UIImage systemImageNamed:@"arrow.triangle.2.circlepath"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
        if (indexPath.row == 3) {
            cell.textLabel.text = @"Sync & download (batch)";
            cell.detailTextLabel.text = @"Hash local cache, fetch missing/upgraded lyrics in one request";
            cell.textLabel.textColor = [UIColor systemBlueColor];
            cell.imageView.image = [UIImage systemImageNamed:@"arrow.2.squarepath"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
        if (indexPath.row == 4) {
            cell.textLabel.text = @"Sync a YouTube Music playlist";
            cell.detailTextLabel.text = @"Fetch lyrics for all tracks in a playlist, tag unlyriced";
            cell.textLabel.textColor = [UIColor systemPurpleColor];
            cell.imageView.image = [UIImage systemImageNamed:@"music.note.list"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
    }
    if (indexPath.section == 5) {
        cell.textLabel.text = @"Current song offset";
        cell.detailTextLabel.text = @"Adjust lyrics timing for this song only";
        cell.imageView.image = [UIImage systemImageNamed:@"clock.arrow.circlepath"];
        UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 80, 32)];
        NSString *vid = g_currentVideoID ?: @"";
        double offset = YTMULyricsOffsetForVideoID(vid);
        tf.text = [NSString stringWithFormat:@"%.1f", offset];
        tf.borderStyle = UITextBorderStyleRoundedRect;
        tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        tf.textAlignment = NSTextAlignmentRight;
        tf.accessibilityIdentifier = [NSString stringWithFormat:@"lyricsOffset_%@", vid];
        tf.delegate = self;
        tf.inputAccessoryView = [self KBToolbar:tf];
        cell.accessoryView = tf;
        return cell;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 3 && indexPath.row == 0) {
        [self loadPreview];
        [tableView reloadSections:[NSIndexSet indexSetWithIndex:3] withRowAnimation:UITableViewRowAnimationAutomatic];
        return;
    }
    if (indexPath.section == 4 && indexPath.row == 0) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Clear cache" message:@"Remove all cached lyrics from device?" preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"Clear" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *act){
            NSString *dir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"YTMU_LyricsCache"];
            [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
            [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"YTMUClearMemoryCache" object:nil];
            [self loadPreview];
            [self.tableView reloadData];
        }]];
        [self presentViewController:a animated:YES completion:nil];
    }
    if (indexPath.section == 4 && indexPath.row == 1) {
        // enforce limits by touching a save with nil to trigger cleanup - or manually
        NSString *dir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"YTMU_LyricsCache"];
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil] ?: @[];
        // trigger save logic by removing oldest until under limits
        NSDictionary *stats = [self cacheStats];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Enforced" message:[NSString stringWithFormat:@"Checked %lu files, total %@", (unsigned long)files.count, [NSByteCountFormatter stringFromByteCount:[stats[@"size"] unsignedLongLongValue] countStyle:NSByteCountFormatterCountStyleFile]] preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationNone];
    }
    if (indexPath.section == 4 && indexPath.row == 2) {
        [self startCacheSync];
    }
    if (indexPath.section == 4 && indexPath.row == 3) {
        [self startBatchSync];
    }
    if (indexPath.section == 4 && indexPath.row == 4) {
        [self startPlaylistSync];
    }
}

- (void)toggleSwitch:(UISwitch *)sender {
    NSString *key = sender.accessibilityIdentifier;
    if (!key.length) return;
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"]];
    d[key] = @(sender.isOn);
    [[NSUserDefaults standardUserDefaults] setObject:d forKey:@"YTMUltimate"];
}

- (void)segmentChanged:(UISegmentedControl *)sender {
    NSString *key = sender.accessibilityIdentifier;
    if (!key.length) return;
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"]];
    d[key] = @(sender.selectedSegmentIndex);
    [[NSUserDefaults standardUserDefaults] setObject:d forKey:@"YTMUltimate"];
}

#pragma mark - Sync cache from server
//
// Pulls the list of songs the server has already fetched+translated
// (GET /api/cache/list) and, for anything not already sitting in the local
// on-device cache, fetches it via the normal GET /api/lyrics path with
// force=0. Because the server already has it cached, that call returns
// straight from disk on the server side too -- this never re-runs
// translation, it's just copying already-done work down to the device.

- (NSString *)ytmu_apiBase {
    NSDictionary *s = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    NSString *base = s[@"lyricsApiEndpoint"];
    if (![base isKindOfClass:[NSString class]] || !base.length) return @"https://ytmtranslate.chiuhuang.dev";
    while ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];
    return base;
}

- (NSString *)ytmu_targetLang {
    NSDictionary *s = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    NSString *lang = s[@"lyricsTargetLang"];
    return ([lang isKindOfClass:[NSString class]] && lang.length) ? lang : @"zh-TW";
}

- (NSString *)ytmu_cachePathForVideoID:(NSString *)vid {
    if (!vid.length) return nil;
    // vid comes from the (user-configurable) server's response, so validate
    // it against an allowlist rather than just stripping "/" -- this is the
    // local on-device cache directory and it must never be escapable via a
    // crafted video_id, regardless of what server the user points this at.
    static NSCharacterSet *disallowed = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableCharacterSet *allowed = [NSMutableCharacterSet alphanumericCharacterSet];
        [allowed addCharactersInString:@"_-"];
        disallowed = [allowed invertedSet];
    });
    if ([vid rangeOfCharacterFromSet:disallowed].location != NSNotFound) return nil;
    if (vid.length > 64) return nil;
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"YTMU_LyricsCache"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [[dir stringByAppendingPathComponent:vid] stringByAppendingPathExtension:@"json"];
}

- (void)startCacheSync {
    NSString *base = [self ytmu_apiBase];
    NSString *lang = [self ytmu_targetLang];
    NSString *listURLStr = [NSString stringWithFormat:@"%@/api/cache/list?lang=%@&limit=500", base,
                             [lang stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];
    NSURL *listURL = [NSURL URLWithString:listURLStr];
    if (!listURL) return;

    YTMUSyncProgressOverlay *overlay = [[YTMUSyncProgressOverlay alloc] initWithFrame:self.view.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.alpha = 0.0;
    [self.view addSubview:overlay];
    [UIView animateWithDuration:0.15 animations:^{ overlay.alpha = 1.0; }];

    __block BOOL cancelled = NO;
    __block NSOperationQueue *syncQueue = nil;
    __weak YTMUSyncProgressOverlay *weakOverlay = overlay;
    overlay.onCancel = ^{
        cancelled = YES;
        [syncQueue cancelAllOperations];
        [weakOverlay dismissAnimated];
    };

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *listTask = [[NSURLSession sharedSession] dataTaskWithURL:listURL
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSArray *items = nil;
        if (data && !error) {
            NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([root isKindOfClass:[NSDictionary class]]) items = root[@"items"];
        }
        if (cancelled) return;
        if (![items isKindOfClass:[NSArray class]]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [overlay dismissAnimated];
                UIAlertController *fail = [UIAlertController alertControllerWithTitle:@"Sync failed"
                    message:error ? error.localizedDescription : @"Server did not return a valid cache list."
                    preferredStyle:UIAlertControllerStyleAlert];
                [fail addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [weakSelf presentViewController:fail animated:YES completion:nil];
            });
            return;
        }

        // Skip anything already sitting in the local cache -- only download the gap.
        // Also skip anything whose video_id doesn't pass the path-safety check
        // (nil path), rather than treating "no path" as "not cached yet".
        NSMutableArray *toFetch = [NSMutableArray array]; // array of {video_id, display}
        for (NSDictionary *item in items) {
            NSString *vid = item[@"video_id"];
            if (![vid isKindOfClass:[NSString class]] || !vid.length) continue;
            NSString *path = [weakSelf ytmu_cachePathForVideoID:vid];
            if (!path) continue;
            if ([[NSFileManager defaultManager] fileExistsAtPath:path]) continue;
            NSString *song = [item[@"song"] isKindOfClass:[NSString class]] ? item[@"song"] : @"";
            NSString *artist = [item[@"artist"] isKindOfClass:[NSString class]] ? item[@"artist"] : @"";
            NSString *display = song.length ? (artist.length ? [NSString stringWithFormat:@"%@ — %@", song, artist] : song) : vid;
            [toFetch addObject:@{@"video_id": vid, @"display": display}];
        }

        if (toFetch.count == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [overlay dismissAnimated];
                UIAlertController *done = [UIAlertController alertControllerWithTitle:@"Already up to date"
                    message:[NSString stringWithFormat:@"Server has %lu song(s) cached for %@ -- all already on this device.", (unsigned long)items.count, lang]
                    preferredStyle:UIAlertControllerStyleAlert];
                [done addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [weakSelf presentViewController:done animated:YES completion:nil];
            });
            return;
        }

        NSInteger total = toFetch.count;
        dispatch_async(dispatch_get_main_queue(), ^{
            overlay.itemLabel.text = @"Starting…";
            overlay.progressView.progress = 0.0;
            overlay.countLabel.text = [NSString stringWithFormat:@"0 of %ld", (long)total];
        });

        __block NSInteger fetched = 0, failed = 0;
        dispatch_group_t group = dispatch_group_create();
        // NSOperationQueue gives each in-flight fetch its own thread from its own
        // pool, so blocking that thread on a semaphore signaled by the
        // NSURLSession completion handler (which runs on URLSession's own
        // internal queue) can't deadlock -- unlike blocking inside the
        // completion handler's own queue, which could be serial.
        NSOperationQueue *queue = [[NSOperationQueue alloc] init];
        queue.maxConcurrentOperationCount = 4;
        syncQueue = queue;

        for (NSDictionary *entry in toFetch) {
            NSString *vid = entry[@"video_id"];
            NSString *display = entry[@"display"];
            dispatch_group_enter(group);
            [queue addOperationWithBlock:^{
                if (cancelled) { dispatch_group_leave(group); return; }
                dispatch_async(dispatch_get_main_queue(), ^{
                    overlay.itemLabel.text = display;
                });
                dispatch_semaphore_t done = dispatch_semaphore_create(0);
                NSString *songURLStr = [NSString stringWithFormat:@"%@/api/lyrics?v=%@&lang=%@%@", base, vid,
                                         [lang stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
                                         YTMULyricsPreference(@"lyricsAutoZhConvert", YES) ? @"&az=1" : @""];
                NSURL *songURL = [NSURL URLWithString:songURLStr];
                __block BOOL ok = NO;
                if (!songURL) {
                    dispatch_semaphore_signal(done);
                } else {
                    NSURLSessionDataTask *songTask = [[NSURLSession sharedSession] dataTaskWithURL:songURL
                        completionHandler:^(NSData *songData, NSURLResponse *songResp, NSError *songErr) {
                        if (songData && !songErr) {
                            NSDictionary *songRoot = [NSJSONSerialization JSONObjectWithData:songData options:0 error:nil];
                            NSArray *lyrics = [songRoot isKindOfClass:[NSDictionary class]] ? songRoot[@"lyrics"] : nil;
                            if ([lyrics isKindOfClass:[NSArray class]] && lyrics.count > 0) {
                                NSDictionary *toSave = @{@"lyrics": lyrics, @"ts": @([[NSDate date] timeIntervalSince1970]), @"videoID": vid, @"cv": @(YTMULyricsCacheFormatVersion())};
                                NSData *out = [NSJSONSerialization dataWithJSONObject:toSave options:0 error:nil];
                                NSString *path = [weakSelf ytmu_cachePathForVideoID:vid];
                                ok = out && path && [out writeToFile:path atomically:YES];
                            }
                        }
                        dispatch_semaphore_signal(done);
                    }];
                    [songTask resume];
                    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (ok) fetched++; else failed++;
                    overlay.progressView.progress = (float)(fetched + failed) / (float)total;
                    overlay.countLabel.text = [NSString stringWithFormat:@"%ld of %ld%@", (long)(fetched + failed), (long)total,
                                                failed > 0 ? [NSString stringWithFormat:@" • %ld failed", (long)failed] : @""];
                });
                dispatch_group_leave(group);
            }];
        }

        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            if (cancelled) return; // overlay already dismissed by the cancel handler
            [overlay dismissAnimated];
            UIAlertController *doneAlert = [UIAlertController alertControllerWithTitle:@"Sync complete"
                message:[NSString stringWithFormat:@"Downloaded %ld new song(s)%@.", (long)fetched,
                         failed > 0 ? [NSString stringWithFormat:@" (%ld failed)", (long)failed] : @""]
                preferredStyle:UIAlertControllerStyleAlert];
            [doneAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [weakSelf presentViewController:doneAlert animated:YES completion:nil];
            [weakSelf loadPreview];
            [weakSelf.tableView reloadData];
        });
    }];
    [listTask resume];
}

// ============================================================
// Batch sync: hash local cache -> POST /api/lyrics/sync -> save need[]
// -> poll regen job if server is regenerating missing lyrics.
// ============================================================

- (void)startBatchSync {
    NSString *base   = [self ytmu_apiBase];
    NSString *lang   = [self ytmu_targetLang];
    BOOL autoZh      = YTMULyricsPreference(@"lyricsAutoZhConvert", YES);
    NSInteger cv     = YTMULyricsCacheFormatVersion();

    // Collect all cache entries (video_id + hash + cv) from LyricsCore.
    NSArray *cacheEntries = YTMULyricsCacheEntries();
    if (!cacheEntries.count) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Nothing to sync"
            message:@"Local lyrics cache is empty." preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }

    YTMUSyncProgressOverlay *overlay = [[YTMUSyncProgressOverlay alloc] initWithFrame:self.view.bounds];
    overlay.titleLabel.text  = @"Batch sync";
    overlay.itemLabel.text   = [NSString stringWithFormat:@"Hashing %lu cached songs…", (unsigned long)cacheEntries.count];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.alpha = 0.0;
    [self.view addSubview:overlay];
    [UIView animateWithDuration:0.15 animations:^{ overlay.alpha = 1.0; }];

    __block BOOL cancelled = NO;
    __weak YTMUSyncProgressOverlay *weakOverlay = overlay;
    __weak typeof(self) weakSelf = self;
    overlay.onCancel = ^{
        cancelled = YES;
        [weakOverlay dismissAnimated];
    };

    // Build entries array for the POST body.
    NSMutableArray *entries = [NSMutableArray arrayWithCapacity:cacheEntries.count];
    for (NSDictionary *e in cacheEntries) {
        NSString *vid  = e[@"video_id"];
        NSString *hash = e[@"hash"];
        if (!vid.length || !hash.length) continue;
        NSInteger entryCV = [e[@"cv"] integerValue] ?: cv;
        [entries addObject:@{@"video_id": vid, @"hash": hash, @"cv": @(entryCV), @"tier": e[@"tier"] ?: @""}];
    }

    NSDictionary *body = @{
        @"lang":       lang,
        @"auto_zh":    @(autoZh),
        @"entries":    entries,
        @"regenerate": @YES,
        @"max_items":  @500,
    };
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if (!bodyData) {
        [overlay dismissAnimated];
        return;
    }

    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/api/lyrics/sync", base]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = bodyData;

    dispatch_async(dispatch_get_main_queue(), ^{
        weakOverlay.itemLabel.text = @"Uploading hashes…";
    });

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (cancelled) return;
        if (!data || error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakOverlay dismissAnimated];
                UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Sync failed"
                    message:error.localizedDescription ?: @"No response from server."
                    preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [weakSelf presentViewController:a animated:YES completion:nil];
            });
            return;
        }
        NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![root isKindOfClass:[NSDictionary class]]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakOverlay dismissAnimated];
                UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Sync failed"
                    message:@"Unexpected response from server." preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [weakSelf presentViewController:a animated:YES completion:nil];
            });
            return;
        }

        NSArray *need      = root[@"need"]      ?: @[];
        NSArray *missing   = root[@"missing"]   ?: @[];
        NSString *jobID    = root[@"job_id"];
        NSInteger okCount  = [root[@"ok_count"] integerValue];

        // Save all need[] entries to local cache.
        NSInteger saved = 0;
        for (NSDictionary *entry in need) {
            NSString *vid    = entry[@"videoID"];
            NSArray  *lyrics = entry[@"lyrics"];
            if (!vid.length || ![lyrics isKindOfClass:[NSArray class]] || !lyrics.count) continue;
            NSString *path = [weakSelf ytmu_cachePathForVideoID:vid];
            if (!path) continue;
            NSDictionary *toSave = @{
                @"lyrics":  lyrics,
                @"ts":      @([[NSDate date] timeIntervalSince1970]),
                @"videoID": vid,
                @"cv":      entry[@"cv"] ?: @(cv),
            };
            NSData *out = [NSJSONSerialization dataWithJSONObject:toSave options:0 error:nil];
            if (out && [out writeToFile:path atomically:YES]) saved++;
        }

        if (!jobID || !jobID.length || missing.count == 0) {
            // No regen job needed — show summary and done.
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakOverlay dismissAnimated];
                NSString *msg = [NSString stringWithFormat:@"Up-to-date: %ld  Updated: %ld  Missing (no server data): %ld",
                                 (long)okCount, (long)saved, (long)missing.count];
                UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Batch sync complete"
                    message:msg preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [weakSelf presentViewController:a animated:YES completion:nil];
                [weakSelf loadPreview];
                [weakSelf.tableView reloadData];
            });
            return;
        }

        // Poll the regen job.
        dispatch_async(dispatch_get_main_queue(), ^{
            weakOverlay.itemLabel.text = [NSString stringWithFormat:@"Server regenerating %lu missing…", (unsigned long)missing.count];
            weakOverlay.progressView.progress = 0.0;
            weakOverlay.countLabel.text       = [NSString stringWithFormat:@"0 of %lu", (unsigned long)missing.count];
        });

        NSString *statusURLStr = [NSString stringWithFormat:@"%@/api/lyrics/sync/status/%@", base, jobID];
        NSURL *statusURL = [NSURL URLWithString:statusURLStr];
        NSString *stopURLStr   = [NSString stringWithFormat:@"%@/api/lyrics/sync/stop/%@", base, jobID];
        NSURL *stopURL = [NSURL URLWithString:stopURLStr];

        // Register cancel: also stop the server-side job.
        weakOverlay.onCancel = ^{
            cancelled = YES;
            if (stopURL) {
                NSMutableURLRequest *stopReq = [NSMutableURLRequest requestWithURL:stopURL];
                stopReq.HTTPMethod = @"POST";
                NSURLSessionDataTask *stopTask = [[NSURLSession sharedSession] dataTaskWithRequest:stopReq
                    completionHandler:^(NSData *d, NSURLResponse *r, NSError *e){}];
                [stopTask resume];
            }
            [weakOverlay dismissAnimated];
        };

        __block NSInteger regenSaved = saved;
        // Recursive poll block (runs on a background queue).
        // Use weak/strong pair to avoid ARC retain cycle (-Warc-retain-cycles).
        dispatch_queue_t bgQ = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        __block __weak void (^weakPoll)(void);
        void (^strongPoll)(void);
        weakPoll = strongPoll = ^{
            if (cancelled) return;
            void (^localPoll)(void) = weakPoll; // keep alive for the duration
            NSURLSessionDataTask *pollTask = [[NSURLSession sharedSession] dataTaskWithURL:statusURL
                completionHandler:^(NSData *sd, NSURLResponse *sr, NSError *se) {
                if (cancelled) return;
                NSDictionary *status = nil;
                if (sd) status = [NSJSONSerialization JSONObjectWithData:sd options:0 error:nil];
                NSString *state   = status[@"state"] ?: @"running";
                NSInteger done    = [status[@"done"] integerValue];
                NSInteger total2  = [status[@"total"] integerValue] ?: (NSInteger)missing.count;
                NSInteger succ    = [status[@"succeeded"] integerValue];

                // Fetch and save any newly completed items we haven't stored yet.
                NSArray *results  = status[@"results"] ?: @[];
                for (NSDictionary *r in results) {
                    if (![r[@"status"] isEqualToString:@"regenerated"]) continue;
                    NSString *vid2 = r[@"video_id"];
                    if (!vid2.length) continue;
                    NSString *path2 = [weakSelf ytmu_cachePathForVideoID:vid2];
                    if (!path2 || [[NSFileManager defaultManager] fileExistsAtPath:path2]) continue;
                    NSString *lURLStr = [NSString stringWithFormat:@"%@/api/lyrics?v=%@&lang=%@%@",
                                         base, vid2,
                                         [lang stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
                                         autoZh ? @"&az=1" : @""];
                    NSURL *lURL = [NSURL URLWithString:lURLStr];
                    if (!lURL) continue;
                    dispatch_semaphore_t sem2 = dispatch_semaphore_create(0);
                    NSURLSessionDataTask *lTask = [[NSURLSession sharedSession] dataTaskWithURL:lURL
                        completionHandler:^(NSData *ld, NSURLResponse *lr, NSError *le) {
                        if (ld && !le) {
                            NSDictionary *lRoot = [NSJSONSerialization JSONObjectWithData:ld options:0 error:nil];
                            NSArray *ly2 = [lRoot isKindOfClass:[NSDictionary class]] ? lRoot[@"lyrics"] : nil;
                            if ([ly2 isKindOfClass:[NSArray class]] && ly2.count) {
                                NSDictionary *ts2 = @{@"lyrics": ly2, @"ts": @([[NSDate date] timeIntervalSince1970]), @"videoID": vid2, @"cv": @(cv)};
                                NSData *out2 = [NSJSONSerialization dataWithJSONObject:ts2 options:0 error:nil];
                                if (out2 && [out2 writeToFile:path2 atomically:YES]) regenSaved++;
                            }
                        }
                        dispatch_semaphore_signal(sem2);
                    }];
                    [lTask resume];
                    dispatch_semaphore_wait(sem2, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
                }

                dispatch_async(dispatch_get_main_queue(), ^{
                    weakOverlay.progressView.progress = total2 > 0 ? (float)done / (float)total2 : 1.0;
                    weakOverlay.countLabel.text = [NSString stringWithFormat:@"%ld of %ld done (%ld saved)", (long)done, (long)total2, (long)regenSaved];
                });

                if ([state isEqualToString:@"complete"] || [state isEqualToString:@"stopped"]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [weakOverlay dismissAnimated];
                        NSString *msg = [NSString stringWithFormat:@"Up-to-date: %ld  Downloaded: %ld  Regenerated+saved: %ld  Missing: %ld",
                                         (long)okCount, (long)saved, (long)succ, (long)(missing.count - succ)];
                        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Batch sync complete"
                            message:msg preferredStyle:UIAlertControllerStyleAlert];
                        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                        [weakSelf presentViewController:a animated:YES completion:nil];
                        [weakSelf loadPreview];
                        [weakSelf.tableView reloadData];
                    });
                    return;
                }
                // Still running — wait 2s then poll again.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), bgQ, localPoll);
            }];
            [pollTask resume];
        };
        dispatch_async(bgQ, strongPoll);
    }];
    [task resume];
}

// ============================================================
// Playlist sync: prompt for URL/ID -> POST /api/playlist/sync
// -> poll status -> show found list, hide unlyriced.
// ============================================================

- (void)startPlaylistSync {
    NSString *base = [self ytmu_apiBase];
    NSString *lang = [self ytmu_targetLang];
    BOOL autoZh    = YTMULyricsPreference(@"lyricsAutoZhConvert", YES);

    UIAlertController *prompt = [UIAlertController alertControllerWithTitle:@"Sync playlist"
        message:@"Paste a YouTube Music playlist URL or ID:"
        preferredStyle:UIAlertControllerStyleAlert];
    [prompt addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"PLxxxxxxxx or https://music.youtube.com/playlist?list=PL…";
        tf.keyboardType = UIKeyboardTypeURL;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    __weak typeof(self) weakSelf = self;
    [prompt addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [prompt addAction:[UIAlertAction actionWithTitle:@"Sync" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
        NSString *input = [prompt.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!input.length) return;
        [weakSelf _doPlaylistSync:input base:base lang:lang autoZh:autoZh];
    }]];
    [self presentViewController:prompt animated:YES completion:nil];
}

- (void)_doPlaylistSync:(NSString *)playlistInput base:(NSString *)base lang:(NSString *)lang autoZh:(BOOL)autoZh {
    YTMUSyncProgressOverlay *overlay = [[YTMUSyncProgressOverlay alloc] initWithFrame:self.view.bounds];
    overlay.titleLabel.text  = @"Playlist sync";
    overlay.itemLabel.text   = @"Contacting server…";
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.alpha = 0.0;
    [self.view addSubview:overlay];
    [UIView animateWithDuration:0.15 animations:^{ overlay.alpha = 1.0; }];

    __block BOOL cancelled = NO;
    __weak YTMUSyncProgressOverlay *weakOverlay = overlay;
    __weak typeof(self) weakSelf = self;

    NSDictionary *body = @{
        @"playlist_id": playlistInput,
        @"lang":        lang,
        @"auto_zh":     @(autoZh),
    };
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if (!bodyData) { [overlay dismissAnimated]; return; }

    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/api/playlist/sync", base]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = bodyData;
    req.timeoutInterval = 30;

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (cancelled) return;
        if (!data || error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakOverlay dismissAnimated];
                UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Playlist sync failed"
                    message:error.localizedDescription ?: @"No response." preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [weakSelf presentViewController:a animated:YES completion:nil];
            });
            return;
        }
        NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString *jobID = [root isKindOfClass:[NSDictionary class]] ? root[@"job_id"] : nil;
        if (!jobID.length) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakOverlay dismissAnimated];
                NSString *errMsg = root[@"error"] ?: @"Server did not return a job_id.";
                UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Playlist sync failed"
                    message:errMsg preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [weakSelf presentViewController:a animated:YES completion:nil];
            });
            return;
        }

        NSURL *statusURL = [NSURL URLWithString:[NSString stringWithFormat:@"%@/api/playlist/sync/status/%@", base, jobID]];
        NSURL *stopURL   = [NSURL URLWithString:[NSString stringWithFormat:@"%@/api/playlist/sync/stop/%@", base, jobID]];
        weakOverlay.onCancel = ^{
            cancelled = YES;
            if (stopURL) {
                NSMutableURLRequest *sr = [NSMutableURLRequest requestWithURL:stopURL];
                sr.HTTPMethod = @"POST";
                NSURLSessionDataTask *stopTask2 = [[NSURLSession sharedSession] dataTaskWithRequest:sr
                    completionHandler:^(NSData *d, NSURLResponse *r, NSError *e){}];
                [stopTask2 resume];
            }
            [weakOverlay dismissAnimated];
        };

        dispatch_async(dispatch_get_main_queue(), ^{
            weakOverlay.itemLabel.text = @"Fetching playlist tracks…";
        });

        dispatch_queue_t bgQ = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        __block __weak void (^weakPoll2)(void);
        void (^strongPoll2)(void);
        weakPoll2 = strongPoll2 = ^{
            if (cancelled) return;
            void (^localPoll2)(void) = weakPoll2;
            NSURLSessionDataTask *pollTask2 = [[NSURLSession sharedSession] dataTaskWithURL:statusURL
                completionHandler:^(NSData *sd, NSURLResponse *sr2, NSError *se) {
                if (cancelled) return;
                NSDictionary *st = nil;
                if (sd) st = [NSJSONSerialization JSONObjectWithData:sd options:0 error:nil];
                NSString *state   = st[@"state"]  ?: @"running";
                NSInteger done    = [st[@"done"]   integerValue];
                NSInteger total   = [st[@"total"]  integerValue];
                NSInteger found   = [st[@"found"]  integerValue];
                NSString *current = st[@"current"] ?: @"";

                dispatch_async(dispatch_get_main_queue(), ^{
                    weakOverlay.itemLabel.text = current.length ? current : state;
                    if (total > 0) {
                        weakOverlay.progressView.progress = (float)done / (float)total;
                        weakOverlay.countLabel.text = [NSString stringWithFormat:@"%ld / %ld tracks  •  %ld found", (long)done, (long)total, (long)found];
                    }
                });

                if ([state isEqualToString:@"complete"] || [state isEqualToString:@"stopped"]) {
                    NSArray *tracks       = st[@"tracks"]   ?: @[];
                    NSMutableArray *foundList     = [NSMutableArray array];
                    NSMutableArray *unlyricedList = [NSMutableArray array];
                    for (NSDictionary *t in tracks) {
                        NSString *tag   = t[@"tag"]   ?: @"";
                        NSString *title = t[@"title"] ?: t[@"video_id"] ?: @"";
                        if ([tag isEqualToString:@"found"])     [foundList addObject:title];
                        else if ([tag isEqualToString:@"unlyriced"]) [unlyricedList addObject:title];
                    }
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [weakOverlay dismissAnimated];
                        NSMutableString *msg = [NSMutableString string];
                        [msg appendFormat:@"%ld found, %ld unlyriced, %ld errors.\n",
                             (long)foundList.count, (long)unlyricedList.count,
                             (long)([st[@"error_count"] integerValue])];
                        if (foundList.count > 0 && foundList.count <= 10) {
                            [msg appendString:@"\nFound:\n"];
                            for (NSString *s in foundList) [msg appendFormat:@"  %@\n", s];
                        }
                        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Playlist sync complete"
                            message:msg preferredStyle:UIAlertControllerStyleAlert];
                        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                        [weakSelf presentViewController:a animated:YES completion:nil];
                        [weakSelf loadPreview];
                        [weakSelf.tableView reloadData];
                    });
                    return;
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), bgQ, localPoll2);
            }];
            [pollTask2 resume];
        };
        dispatch_async(bgQ, strongPoll2);
    }];
    [task resume];
}


- (void)textFieldDidEndEditing:(UITextField *)textField {
    NSString *key = textField.accessibilityIdentifier;
    if (!key.length) return;


    if ([key isEqualToString:@"lyricsApiEndpoint"]) {
        NSString *urlStr = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        // Strip a trailing slash so URL concatenation elsewhere never double-slashes.
        while ([urlStr hasSuffix:@"/"]) urlStr = [urlStr substringToIndex:urlStr.length - 1];
        NSURL *url = [NSURL URLWithString:urlStr];
        BOOL valid = url && url.scheme && url.host && ([url.scheme isEqualToString:@"https"] || [url.scheme isEqualToString:@"http"]);
        if (!valid) urlStr = @"https://ytmtranslate.chiuhuang.dev";
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"]];
        d[key] = urlStr;
        [[NSUserDefaults standardUserDefaults] setObject:d forKey:@"YTMUltimate"];
        textField.text = urlStr;
        return;
    }

    if ([key isEqualToString:@"lyricsTargetLang"]) {
        NSString *lang = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!lang.length) lang = @"zh-TW";
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"]];
        d[key] = lang;
        [[NSUserDefaults standardUserDefaults] setObject:d forKey:@"YTMUltimate"];
        textField.text = lang;
        return;
    }

    if ([key hasPrefix:@"lyricsOffset_"]) {
        NSString *vid = [key substringFromIndex:13];
        double offset = [textField.text doubleValue];
        if (offset > 30.0) offset = 30.0;
        if (offset < -30.0) offset = -30.0;
        YTMULyricsSetOffsetForVideoID(vid, offset);
        textField.text = [NSString stringWithFormat:@"%.1f", offset];
        return;
    }

    NSInteger v = [textField.text integerValue];
    if (v <= 0) v = ([key isEqualToString:@"lyricsCacheMaxCount"] ? 200 : 50);
    if ([key isEqualToString:@"lyricsCacheMaxCount"] && v > 2000) v = 2000;
    if ([key isEqualToString:@"lyricsCacheMaxSizeMB"] && v > 500) v = 500;
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"]];
    d[key] = @(v);
    [[NSUserDefaults standardUserDefaults] setObject:d forKey:@"YTMUltimate"];
    textField.text = [NSString stringWithFormat:@"%ld", (long)v];
}

- (UIView *)KBToolbar:(UITextField *)textField {
    UIToolbar *tb = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, self.view.frame.size.width, 44)];
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(hideKeyboard)];
    tb.items = @[flex, done];
    return tb;
}
- (void)hideKeyboard { [self.view endEditing:YES]; }

@end
