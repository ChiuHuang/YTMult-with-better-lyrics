#import "LyricsSettingsController.h"

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
    if (!d[@"lyricsFpsMeter"]) d[@"lyricsFpsMeter"] = @YES;
    if (!d[@"lyricsOwnButton"]) d[@"lyricsOwnButton"] = @YES;
    if (!d[@"lyricsApiEndpoint"]) d[@"lyricsApiEndpoint"] = @"https://ytmtranslate.chiuhuang.dev";
    if (!d[@"lyricsTargetLang"]) d[@"lyricsTargetLang"] = @"zh-TW";
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

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 5; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 5;
    if (section == 1) return 2;
    if (section == 2) return 3;
    if (section == 3) return (NSInteger)self.previewLyrics.count + 1;
    if (section == 4) return 3;
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"Lyrics Display";
    if (section == 1) return @"Translation";
    if (section == 2) return @"Client Cache";
    if (section == 3) return @"Preview (most recent cached)";
    if (section == 4) return @"Actions";
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"Always On shows translated panel when lyrics load. Cache stores lyrics on device for offline and faster load.";
    if (section == 1) return @"Server used to fetch and translate lyrics, and the language lyrics get translated into. Lines already in that Chinese script (Simplified or Traditional) are never sent to the translator — they just get their script normalized. Examples: zh-TW, zh-CN, en, ja, ko.";
    if (section == 2) return @"Limits are enforced automatically on save. Count limit removes oldest first. Size limit removes oldest until under limit.";
    if (section == 3) return @"Preview shows up to 20 lines from the newest cached file.";
    if (section == 4) return @"Sync pulls songs already translated on the server straight into your local cache — it never re-runs translation, so it's fast and free even for a large backlog.";
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
        NSArray *items = @[
            @{@"title": @"Always show translated lyrics", @"desc": @"Auto-show custom panel when lyrics load", @"key": @"lyricsAlwaysOn"},
            @{@"title": @"Enable client cache", @"desc": @"Store lyrics on device (recommended)", @"key": @"lyricsCacheEnabled"},
            @{@"title": @"Send debug to server", @"desc": @"Upload debug events to ytmtranslate.chiuhuang.dev", @"key": @"sendDebugLogsToServer"},
            @{@"title": @"FPS meter on volume down", @"desc": @"Volume-down toggles lyric render-rate readout (also lowers volume)", @"key": @"lyricsFpsMeter"},
            @{@"title": @"Replace lyrics chip", @"desc": @"Hide official chip, show our own button instead", @"key": @"lyricsOwnButton"}
        ];
        NSDictionary *it = items[indexPath.row];
        cell.textLabel.text = it[@"title"];
        cell.detailTextLabel.text = it[@"desc"];
        cell.imageView.image = [UIImage systemImageNamed:(indexPath.row==0?@"quote.bubble": indexPath.row==1?@"internaldrive": indexPath.row==2?@"antenna.radiowaves.left.and.right": indexPath.row==3?@"speedometer":@"hand.tap")];
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
}

- (void)toggleSwitch:(UISwitch *)sender {
    NSString *key = sender.accessibilityIdentifier;
    if (!key.length) return;
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"]];
    d[key] = @(sender.isOn);
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
    overlay.onCancel = ^{
        cancelled = YES;
        [syncQueue cancelAllOperations];
        [overlay dismissAnimated];
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
                NSString *songURLStr = [NSString stringWithFormat:@"%@/api/lyrics?v=%@&lang=%@", base, vid,
                                         [lang stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];
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
                                NSDictionary *toSave = @{@"lyrics": lyrics, @"ts": @([[NSDate date] timeIntervalSince1970]), @"videoID": vid};
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
