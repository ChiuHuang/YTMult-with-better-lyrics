#import "YTMUltimateSettingsController.h"

#ifndef TWEAK_GIT_COMMIT
#define TWEAK_GIT_COMMIT "unknown"
#endif

@implementation YTMUltimateSettingsController

- (void)viewDidLoad {
    [super viewDidLoad];

    UIBarButtonItem *closeButton = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"xmark"]
                                                                    style:UIBarButtonItemStylePlain
                                                                   target:self
                                                                   action:@selector(closeButtonTapped:)];

    UIBarButtonItem *applyButton = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"checkmark"]
                                                                    style:UIBarButtonItemStylePlain
                                                                   target:self
                                                                   action:@selector(applyButtonTapped:)];

    self.navigationItem.leftBarButtonItem = closeButton;
    self.navigationItem.rightBarButtonItem = applyButton;

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.tableView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.tableView.widthAnchor constraintEqualToAnchor:self.view.widthAnchor],
        [self.tableView.heightAnchor constraintEqualToAnchor:self.view.heightAnchor]
    ]];

    //Init isEnabled for first time
    NSMutableDictionary *YTMUltimateDict = [NSMutableDictionary dictionaryWithDictionary:[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"]];
    if (!YTMUltimateDict[@"YTMUltimateIsEnabled"]) {
        [YTMUltimateDict setObject:@(1) forKey:@"YTMUltimateIsEnabled"];
    }
    if (!YTMUltimateDict[@"lyricsAlwaysOn"]) YTMUltimateDict[@"lyricsAlwaysOn"] = @YES;
    if (!YTMUltimateDict[@"sendLyricsScreenshotDebug"]) YTMUltimateDict[@"sendLyricsScreenshotDebug"] = @NO;
    if (!YTMUltimateDict[@"sendDebugLogsToServer"]) YTMUltimateDict[@"sendDebugLogsToServer"] = @NO;
    if (!YTMUltimateDict[@"debugLogLevel"]) YTMUltimateDict[@"debugLogLevel"] = @1;
    [[NSUserDefaults standardUserDefaults] setObject:YTMUltimateDict forKey:@"YTMUltimate"];

}

#pragma mark - Table view stuff
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewAutomaticDimension;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 5;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 2) return @"Lyrics & Diagnostics";
    return section == 4 ? LOC(@"LINKS") : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        return LOC(@"RESTART_FOOTER");
    } if (section == 4) {
        NSDictionary *infoDictionary = [[NSBundle mainBundle] infoDictionary];
        NSString *appVersion = infoDictionary[@"CFBundleShortVersionString"];
        return [NSString stringWithFormat:@"\nYouTubeMusic: v%@\nYTMusicUltimate: v%@\nBuild: %@", appVersion, @(OS_STRINGIFY(TWEAK_VERSION)), @TWEAK_GIT_COMMIT];
    }

    return nil;
}

- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section {
    if (section == 4) {
        UITableViewHeaderFooterView *footer = (UITableViewHeaderFooterView *)view;
        footer.textLabel.textAlignment = NSTextAlignmentCenter;
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section{
    switch (section) {
        case 0:
            return 1;
        case 1:
            return 5;
        case 2:
            return 2;
        case 3:
            return 1;
        case 4:
            return 5;
        default:
            return 0;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
    }

    else {
        for (UIView *subview in cell.contentView.subviews) {
            [subview removeFromSuperview];
        }
    }

    NSMutableDictionary *YTMUltimateDict = [NSMutableDictionary dictionaryWithDictionary:[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"]];

    if (indexPath.section == 0) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"masterSection"];

        cell.textLabel.text = LOC(@"ENABLED");
        cell.textLabel.adjustsFontSizeToFitWidth = YES;
        cell.textLabel.textColor = [UIColor colorWithRed:230/255.0 green:75/255.0 blue:75/255.0 alpha:255/255.0];
        cell.imageView.image = [UIImage systemImageNamed:@"power"];
        cell.imageView.tintColor = [UIColor colorWithRed:230/255.0 green:75/255.0 blue:75/255.0 alpha:255/255.0];

        ABCSwitch *masterSwitch = [[NSClassFromString(@"ABCSwitch") alloc] init];
        masterSwitch.onTintColor = [UIColor colorWithRed:230/255.0 green:75/255.0 blue:75/255.0 alpha:255/255.0];
        [masterSwitch addTarget:self action:@selector(toggleMasterSwitch:) forControlEvents:UIControlEventValueChanged];
        masterSwitch.on = [YTMUltimateDict[@"YTMUltimateIsEnabled"] boolValue];
        cell.accessoryView = masterSwitch;

        return cell;
    }

    if (indexPath.section == 1) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"settingsSection"];

        NSArray *settingsData = @[
            @{@"title": LOC(@"PREMIUM_SETTINGS"), @"image": @"flame"},
            @{@"title": LOC(@"PLAYER_SETTINGS"), @"image": @"play.rectangle"},
            @{@"title": LOC(@"THEME_SETTINGS"), @"image": @"paintbrush"},
            @{@"title": LOC(@"NAVBAR_SETTINGS"), @"image": @"sidebar.trailing"},
            @{@"title": LOC(@"TABBAR_SETTINGS"), @"image": @"dock.rectangle"}
        ];

        NSDictionary *settingData = settingsData[indexPath.row];

        cell.textLabel.text = settingData[@"title"];
        cell.detailTextLabel.numberOfLines = 0;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.imageView.image = [UIImage systemImageNamed:settingData[@"image"]];

        return cell;
    }

    if (indexPath.section == 2) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"lyricsSection"];
        NSArray *settings = @[
            @{@"title": @"Always show translated lyrics", @"detail": @"Show the custom lyrics panel when lyrics load.", @"key": @"lyricsAlwaysOn", @"type": @"switch", @"image": @"quote.bubble"},
            @{@"title": @"Send screenshot debug data", @"detail": @"Upload a UI hierarchy only after you take a screenshot.", @"key": @"sendLyricsScreenshotDebug", @"type": @"switch", @"image": @"ladybug"},
            @{@"title": @"Push debug logs to API", @"detail": @"Upload debug events and exceptions to ytmtranslate.chiuhuang.dev.", @"key": @"sendDebugLogsToServer", @"type": @"switch", @"image": @"arrow.up.circle"},
            @{@"title": @"Log level", @"detail": @"Off = no uploads, Errors = failures only, All = info + warnings + errors.", @"key": @"debugLogLevel", @"type": @"segmented", @"image": @"waveform.badge.exclamationmark"}
        ];
        NSDictionary *setting = settings[indexPath.row];
        cell.textLabel.text = setting[@"title"];
        cell.detailTextLabel.text = setting[@"detail"];
        cell.detailTextLabel.numberOfLines = 0;
        cell.imageView.image = [UIImage systemImageNamed:setting[@"image"]];

        if ([setting[@"type"] isEqualToString:@"switch"]) {
            UISwitch *toggle = [[UISwitch alloc] init];
            toggle.accessibilityIdentifier = setting[@"key"];
            toggle.on = [YTMUltimateDict[setting[@"key"]] boolValue];
            [toggle addTarget:self action:@selector(toggleSetting:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
        } else {
            UISegmentedControl *segment = [[UISegmentedControl alloc] initWithItems:@[@"Off", @"Err", @"All"]];
            segment.selectedSegmentIndex = MIN(MAX([YTMUltimateDict[setting[@"key"]] integerValue], 0), 2);
            segment.accessibilityIdentifier = setting[@"key"];
            [segment addTarget:self action:@selector(segmentSettingChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = segment;
        }
        return cell;
    }

    if (indexPath.section == 3) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cacheSection"];

        cell.textLabel.text = LOC(@"CLEAR_CACHE");

        UILabel *cache = [[UILabel alloc] init];
        cache.text = [self getCacheSize];
        cache.textColor = [UIColor secondaryLabelColor];
        cache.font = [UIFont systemFontOfSize:16];
        cache.textAlignment = NSTextAlignmentRight;
        [cache sizeToFit];

        cell.accessoryView = cache;
        cell.imageView.image = [UIImage systemImageNamed:@"trash"];
        cell.imageView.tintColor = [UIColor redColor];

        return cell;
    }

    if (indexPath.section == 4) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"linkSection"];

        NSArray *settingsData = @[
            @{@"text": [NSString stringWithFormat:LOC(@"TWITTER"), @"Ginsu"],  @"detail": LOC(@"TWITTER_DESC"), @"image": @"ginsu-24@2x"},
            @{@"text": [NSString stringWithFormat:LOC(@"TWITTER"), @"Dayanch96"], @"detail": LOC(@"TWITTER_DESC"), @"image": @"dayanch96-24@2x"},
            @{@"text": LOC(@"DISCORD"), @"detail": LOC(@"DISCORD_DESC"), @"image": @"discord-24@2x"},
            @{@"text": LOC(@"SOURCE_CODE"), @"detail": LOC(@"SOURCE_CODE_DESC"), @"image": @"github-24@2x"},
            @{@"text": @"Check for updates", @"detail": @"Compare this build's commit with the latest online build.", @"image": @"arrow.triangle.2.circlepath"}
        ];

        NSDictionary *settingData = settingsData[indexPath.row];

        cell.textLabel.text = settingData[@"text"];
        cell.textLabel.textColor = [UIColor systemBlueColor];
        cell.textLabel.adjustsFontSizeToFitWidth = YES;
        cell.detailTextLabel.text = settingData[@"detail"];
        cell.detailTextLabel.numberOfLines = 0;

        if (indexPath.row == 4) {
            cell.imageView.image = [UIImage systemImageNamed:settingData[@"image"]];
        } else {
            UIImage *image = [UIImage imageWithContentsOfFile:[NSBundle.ytmu_defaultBundle pathForResource:settingData[@"image"] ofType:@"png" inDirectory:@"icons"]];
            cell.imageView.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
        }
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

        return cell;
    }

    return cell;
}

- (NSString *)getCacheSize {
    NSString *cachePath = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSArray *filesArray = [[NSFileManager defaultManager] subpathsOfDirectoryAtPath:cachePath error:nil];

    unsigned long long int folderSize = 0;
    for (NSString *fileName in filesArray) {
        NSString *filePath = [cachePath stringByAppendingPathComponent:fileName];
        NSDictionary *fileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:nil];
        folderSize += [fileAttributes fileSize];
    }

    NSByteCountFormatter *formatter = [[NSByteCountFormatter alloc] init];
    formatter.countStyle = NSByteCountFormatterCountStyleFile;

    return [formatter stringFromByteCount:folderSize];
}

#pragma mark - UITableViewDelegate
- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 0 ? NO : YES;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 1) {
        NSArray *controllers = @[[PremiumSettingsController class],
                                 [PlayerSettingsController class],
                                 [ThemeSettingsController class],
                                 [NavBarSettingsController class],
                                 [OtherSettingsController class]];

        if (indexPath.row >= 0 && indexPath.row < controllers.count) {
            UIViewController *controller = [[controllers[indexPath.row] alloc] init];
            [self.navigationController pushViewController:controller animated:YES];
        }
    }

    if (indexPath.section == 3 && indexPath.row == 0) {
        UIActivityIndicatorView *activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        activityIndicator.color = [UIColor labelColor];
        [activityIndicator startAnimating];
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        cell.accessoryView = activityIndicator;

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSString *cachePath = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
            [[NSFileManager defaultManager] removeItemAtPath:cachePath error:nil];

            dispatch_async(dispatch_get_main_queue(), ^{
                [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:0 inSection:3]] withRowAnimation:UITableViewRowAnimationNone];
            });
        });
    }

    if (indexPath.section == 4 && indexPath.row == 4) {
        [self checkForUpdates];
    } else if (indexPath.section == 4) {
        NSArray *urls = @[@"https://twitter.com/ginsudev",
                        @"https://twitter.com/dayanch96",
                        @"https://discord.gg/VN9ZSeMhEW",
                        @"https://github.com/dayanch96/YTMusicUltimate"];

        if (indexPath.row >= 0 && indexPath.row < urls.count) {
            NSURL *url = [NSURL URLWithString:urls[indexPath.row]];
            if ([[UIApplication sharedApplication] canOpenURL:url]) {
                [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
            }
        }
    }

    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

#pragma mark - Nav bar stuff
- (NSString *)title {
    return @"YTMusicUltimate";
}

- (void)closeButtonTapped:(id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)applyButtonTapped:(id)sender {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:LOC(@"WARNING") message:LOC(@"APPLY_MESSAGE") preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:LOC(@"CANCEL") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:LOC(@"YES") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[UIApplication sharedApplication] performSelector:@selector(suspend)];
            [NSThread sleepForTimeInterval:1.0];
            exit(0);
        });
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)toggleMasterSwitch:(UISwitch *)sender {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *twitchDvnDict = [NSMutableDictionary dictionaryWithDictionary:[defaults dictionaryForKey:@"YTMUltimate"]];

    [twitchDvnDict setObject:@([sender isOn]) forKey:@"YTMUltimateIsEnabled"];
    [defaults setObject:twitchDvnDict forKey:@"YTMUltimate"];
}

- (void)toggleSetting:(UISwitch *)sender {
    NSString *key = sender.accessibilityIdentifier;
    if (!key.length) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *settings = [NSMutableDictionary dictionaryWithDictionary:[defaults dictionaryForKey:@"YTMUltimate"]];
    settings[key] = @(sender.isOn);
    [defaults setObject:settings forKey:@"YTMUltimate"];
}

- (void)segmentSettingChanged:(UISegmentedControl *)sender {
    NSString *key = sender.accessibilityIdentifier;
    if (!key.length) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *settings = [NSMutableDictionary dictionaryWithDictionary:[defaults dictionaryForKey:@"YTMUltimate"]];
    settings[key] = @(sender.selectedSegmentIndex);
    [defaults setObject:settings forKey:@"YTMUltimate"];
}

- (void)checkForUpdates {
    NSString *currentCommit = @TWEAK_GIT_COMMIT;
    NSString *escapedCommit = [currentCommit stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://ytmtranslate.chiuhuang.dev/api/update?commit=%@", escapedCommit]];
    UIAlertController *loading = [UIAlertController alertControllerWithTitle:@"Checking for updates" message:@"Comparing this build with the latest online commit…" preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:loading animated:YES completion:nil];
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [loading dismissViewControllerAnimated:YES completion:nil];
            NSDictionary *result = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSString *latest = result[@"latest_commit"] ?: @"unknown";
            BOOL updateAvailable = [result[@"update_available"] boolValue];
            NSString *message;
            if (error || !result) {
                message = @"Could not reach the update service. Try again later.";
            } else if (updateAvailable) {
                message = [NSString stringWithFormat:@"An update is available.\n\nThis build: %@\nLatest: %@", currentCommit, latest];
            } else {
                message = [NSString stringWithFormat:@"You are on the latest build.\n\nCommit: %@", latest];
            }
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:updateAvailable ? @"Update available" : @"Up to date" message:message preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            if (updateAvailable) {
                [alert addAction:[UIAlertAction actionWithTitle:@"Open downloads" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://github.com/ChiuHuang/ytmusicultimate"] options:@{} completionHandler:nil];
                }]];
            }
            [self presentViewController:alert animated:YES completion:nil];
        });
    }] resume];
}

@end
