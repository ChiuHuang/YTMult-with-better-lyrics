#import "LyricsSettingsController.h"

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
    if (section == 4) return 2;
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
}

- (void)toggleSwitch:(UISwitch *)sender {
    NSString *key = sender.accessibilityIdentifier;
    if (!key.length) return;
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"]];
    d[key] = @(sender.isOn);
    [[NSUserDefaults standardUserDefaults] setObject:d forKey:@"YTMUltimate"];
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
