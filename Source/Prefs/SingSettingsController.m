#import "SingSettingsController.h"
#import "../LyricsShared.h"
#import "../Headers/Localization.h"
#import "../Utils/YTMUZipExtractor.h"
#import "../VocalSeparation.h"

@interface SingSettingsController ()
@property (nonatomic, strong) UIProgressView *downloadProgressView;
@property (nonatomic, strong) UILabel *downloadStatusLabel;
@property (nonatomic, strong) NSURLSessionDownloadTask *activeDownloadTask;
@property (nonatomic, copy)   NSString *downloadStatusText;
@property (nonatomic, strong) NSTimer *refreshTimer;
@end

@implementation SingSettingsController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = LOC(@"SING_SETTINGS");
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
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
    __weak typeof(self) ws = self;
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(NSTimer * _Nonnull timer) {
        [ws.tableView reloadSections:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1, 2)] withRowAnimation:UITableViewRowAnimationNone];
    }];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

#pragma mark - Table view data source

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewAutomaticDimension;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    // Section 0: Music Haptics
    // Section 1: Sing / Vocal Separation
    // Section 2: Diagnostics & Test
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    // Sing is unfinished: empty section until unlocked from Debug.
    if (section == 0) return 5; // toggle + intensity + fallback + taptic speaker + taptic test
    if (section == 1) return YTMUSingUnlocked() ? 2 : 0; // sing toggle + model download
    if (section == 2) return 4; // Now Playing, ISRC, System Haptics, Test Motor
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return LOC(@"MUSIC_HAPTICS");
    if (section == 1) return YTMUSingUnlocked() ? LOC(@"SING_SECTION_HEADER") : nil;
    if (section == 2) return @"Diagnostics & Test";
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return LOC(@"MUSIC_HAPTICS_FOOTER");
    if (section == 1) return YTMUSingUnlocked() ? LOC(@"SING_FOOTER") : nil;
    if (section == 2) return @"";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
    }

    NSMutableDictionary *YTMUltimateDict = [NSMutableDictionary dictionaryWithDictionary:
        [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"]];

    // ---- Section 0: Music Haptics ----
    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"hapticsBoolCell"];
            cell.textLabel.text = LOC(@"MUSIC_HAPTICS");
            cell.textLabel.adjustsFontSizeToFitWidth = YES;
            cell.detailTextLabel.text = LOC(@"MUSIC_HAPTICS_DESC");
            cell.detailTextLabel.numberOfLines = 0;
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

            ABCSwitch *sw = [[NSClassFromString(@"ABCSwitch") alloc] init];
            sw.onTintColor = [UIColor colorWithRed:30.0/255.0 green:150.0/255.0 blue:245.0/255.0 alpha:1.0];
            [sw addTarget:self action:@selector(toggleHapticsSwitch:) forControlEvents:UIControlEventValueChanged];
            id val = YTMUltimateDict[@"musicHaptics"];
            sw.on = (val != nil) ? [val boolValue] : YES; // Default ON
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }

        if (indexPath.row == 1) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"hapticsIntensityCell"];
            cell.textLabel.text = LOC(@"MUSIC_HAPTICS_INTENSITY");
            cell.textLabel.adjustsFontSizeToFitWidth = YES;

            UISegmentedControl *ctrl = [[UISegmentedControl alloc] initWithItems:@[
                LOC(@"MUSIC_HAPTICS_LIGHT"),
                LOC(@"MUSIC_HAPTICS_MEDIUM"),
                LOC(@"MUSIC_HAPTICS_STRONG")
            ]];
            id val = YTMUltimateDict[@"musicHapticsIntensity"];
            ctrl.selectedSegmentIndex = val ? [val integerValue] : 1;
            [ctrl addTarget:self action:@selector(controlHapticsIntensitySelect:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = ctrl;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }

        if (indexPath.row == 2) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"hapticsFallbackCell"];
            cell.textLabel.text = LOC(@"MUSIC_HAPTICS_FALLBACK");
            cell.textLabel.adjustsFontSizeToFitWidth = YES;
            cell.detailTextLabel.text = LOC(@"MUSIC_HAPTICS_FALLBACK_DESC");
            cell.detailTextLabel.numberOfLines = 0;
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

            ABCSwitch *sw = [[NSClassFromString(@"ABCSwitch") alloc] init];
            sw.onTintColor = [UIColor colorWithRed:30.0/255.0 green:150.0/255.0 blue:245.0/255.0 alpha:1.0];
            [sw addTarget:self action:@selector(toggleFallbackSwitch:) forControlEvents:UIControlEventValueChanged];
            id val = YTMUltimateDict[@"musicHapticsFallback"];
            sw.on = (val != nil) ? [val boolValue] : YES; // Default ON
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }

        if (indexPath.row == 3) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"hapticsTapticCell"];
            cell.textLabel.text = LOC(@"MUSIC_HAPTICS_TAPTIC");
            cell.textLabel.adjustsFontSizeToFitWidth = YES;
            cell.detailTextLabel.text = LOC(@"MUSIC_HAPTICS_TAPTIC_DESC");
            cell.detailTextLabel.numberOfLines = 0;
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

            ABCSwitch *sw = [[NSClassFromString(@"ABCSwitch") alloc] init];
            sw.onTintColor = [UIColor colorWithRed:30.0/255.0 green:150.0/255.0 blue:245.0/255.0 alpha:1.0];
            [sw addTarget:self action:@selector(toggleTapticSwitch:) forControlEvents:UIControlEventValueChanged];
            id val = YTMUltimateDict[@"tapticSpeaker"];
            sw.on = (val != nil) ? [val boolValue] : NO; // Default OFF
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }

        if (indexPath.row == 4) {
            cell.textLabel.text = LOC(@"MUSIC_HAPTICS_TAPTIC_TEST");
            cell.textLabel.textColor = [UIColor systemBlueColor];
            cell.textLabel.adjustsFontSizeToFitWidth = YES;
            cell.detailTextLabel.text = LOC(@"MUSIC_HAPTICS_TAPTIC_TEST_DESC");
            cell.detailTextLabel.numberOfLines = 0;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            return cell;
        }
    }

    // ---- Section 1: Sing / Vocal Separation ----
    if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"singBoolCell"];
            cell.textLabel.text = LOC(@"SING_ENABLED");
            cell.textLabel.adjustsFontSizeToFitWidth = YES;
            cell.detailTextLabel.text = LOC(@"SING_ENABLED_DESC");
            cell.detailTextLabel.numberOfLines = 0;
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

            BOOL modelReady = [self isSingModelReady];

            ABCSwitch *sw = [[NSClassFromString(@"ABCSwitch") alloc] init];
            sw.onTintColor = [UIColor colorWithRed:30.0/255.0 green:150.0/255.0 blue:245.0/255.0 alpha:1.0];
            [sw addTarget:self action:@selector(toggleSingSwitch:) forControlEvents:UIControlEventValueChanged];
            sw.on = modelReady && [YTMUVocalSeparationManager sharedInstance].isSingEnabled;
            sw.enabled = modelReady;
            sw.alpha = modelReady ? 1.0 : 0.4;
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }

        if (indexPath.row == 1) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"singDownloadCell"];
            BOOL modelReady = [self isSingModelReady];
            BOOL modelLoading = [YTMUVocalSeparationManager sharedInstance].isModelLoading;
            BOOL downloading = (self.activeDownloadTask != nil);

            if (modelReady) {
                cell.textLabel.text = LOC(@"SING_MODEL_READY");
                cell.textLabel.textColor = [UIColor systemGreenColor];
                cell.detailTextLabel.text = nil;
                cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
                cell.accessoryType = UITableViewCellAccessoryCheckmark;
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
            } else if (downloading) {
                cell.textLabel.text = self.downloadStatusText ?: LOC(@"SING_MODEL_DOWNLOADING");
                cell.textLabel.textColor = [UIColor secondaryLabelColor];
                cell.detailTextLabel.text = nil;
                cell.accessoryType = UITableViewCellAccessoryNone;

                UIProgressView *pv = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
                pv.frame = CGRectMake(0, 0, 100, 10);
                pv.progress = 0.0;
                self.downloadProgressView = pv;
                cell.accessoryView = pv;
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
            } else if (modelLoading) {
                cell.textLabel.text = @"Preparing…";
                cell.detailTextLabel.text = nil;
                cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
                cell.accessoryView = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
                [(UIActivityIndicatorView *)cell.accessoryView startAnimating];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
            } else if ([[YTMUVocalSeparationManager sharedInstance] hasModelOnDisk]) {
                NSError *loadError = [YTMUVocalSeparationManager sharedInstance].modelLoadError;
                cell.textLabel.text = loadError ? @"Retry loading AI model" : @"Load downloaded AI model";
                cell.textLabel.textColor = [UIColor systemBlueColor];
                cell.detailTextLabel.text = nil;
                cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            } else {
                cell.textLabel.text = LOC(@"SING_MODEL_DOWNLOAD");
                cell.textLabel.textColor = [UIColor systemBlueColor];
                cell.detailTextLabel.text = nil;
                cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
                cell.accessoryType = UITableViewCellAccessoryNone;
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            }
            return cell;
        }
    }

    // ---- Section 2: Diagnostics & Test ----
    if (indexPath.section == 2) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"diagCell"];
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Now Playing";
            NSString *title = YTMUCurrentNowPlayingTitle();
            NSString *artist = YTMUCurrentNowPlayingArtist();
            if (title.length) {
                cell.detailTextLabel.text = artist.length ? [NSString stringWithFormat:@"%@ - %@", artist, title] : title;
            } else {
                cell.detailTextLabel.text = @"(No track)";
            }
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }
        if (indexPath.row == 1) {
            cell.textLabel.text = @"ISRC Code";
            NSString *isrc = YTMUCurrentNowPlayingISRC();
            cell.detailTextLabel.text = isrc.length ? isrc : @"(None / Looking up)";
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }
        if (indexPath.row == 2) {
            cell.textLabel.text = @"iOS 18 System Haptics";
            BOOL active = YTMUIsSystemMusicHapticsActive();
            BOOL track = YTMUHasSystemHapticTrack();
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ (system track: %@)",
                                         active ? @"Active" : @"Inactive",
                                         track ? @"yes" : @"no"];
            cell.detailTextLabel.textColor = active ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }
        if (indexPath.row == 3) {
            cell.textLabel.text = @"Test Haptic Pulse";
            cell.textLabel.textColor = [UIColor systemBlueColor];
            cell.detailTextLabel.text = nil;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            return cell;
        }
    }

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 1 && indexPath.row == 1) {
        if (![self isSingModelReady] && self.activeDownloadTask == nil) {
            YTMUVocalSeparationManager *manager = [YTMUVocalSeparationManager sharedInstance];
            if (manager.hasModelOnDisk) {
                [manager loadModelIfAvailableWithCompletion:^(BOOL ready, NSError *error) {
                    self.downloadStatusText = ready ? nil : [NSString stringWithFormat:@"Model load failed: %@", error.localizedDescription ?: @"Core ML rejected the package"];
                    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1]
                                  withRowAnimation:UITableViewRowAnimationAutomatic];
                }];
            } else {
                [self startModelDownload];
            }
        }
    }

    if (indexPath.section == 0 && indexPath.row == 4) {
        if (!YTMUTapticSpeakerPlay()) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:LOC(@"MUSIC_HAPTICS_TAPTIC_TEST")
                message:@"No song is playing (or its video id is unknown). Play a song first."
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
    }

    if (indexPath.section == 2 && indexPath.row == 3) {
        // Test haptic pulses sequentially
        YTMUTestHapticPulse(0); // light
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            YTMUTestHapticPulse(1); // medium
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.50 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            YTMUTestHapticPulse(2); // strong
        });
    }
}

#pragma mark - Model helpers

- (NSString *)singModelPath {
    return [[YTMUVocalSeparationManager sharedInstance] modelPackagePath];
}

- (BOOL)isSingModelReady {
    return [YTMUVocalSeparationManager sharedInstance].isModelReady;
}

- (void)startModelDownload {
    self.activeDownloadTask = nil;
    self.downloadStatusText = @"Starting download...";
    [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:1 inSection:1]]
                          withRowAnimation:UITableViewRowAnimationAutomatic];

    NSURL *url = [NSURL URLWithString:@"https://chiuhuang.dev/mdx23c_instvoc_hq"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)" forHTTPHeaderField:@"User-Agent"];

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg delegate:nil delegateQueue:[NSOperationQueue mainQueue]];

    __weak typeof(self) weakSelf = self;
    NSURLSessionDownloadTask *task = [session downloadTaskWithRequest:req
        completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            if (error || !location) {
                weakSelf.activeDownloadTask = nil;
                weakSelf.downloadStatusText = [NSString stringWithFormat:@"Download failed: %@", error.localizedDescription];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:1 inSection:1]]
                                              withRowAnimation:UITableViewRowAnimationAutomatic];
                    UIAlertController *alert = [UIAlertController alertControllerWithTitle:LOC(@"SING_DOWNLOAD_FAILED")
                                                                                   message:error.localizedDescription
                                                                            preferredStyle:UIAlertControllerStyleAlert];
                    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                    [weakSelf presentViewController:alert animated:YES completion:nil];
                });
                return;
            }

            weakSelf.downloadStatusText = @"Extracting model files...";
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:1 inSection:1]]
                                          withRowAnimation:UITableViewRowAnimationNone];
            });

            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                NSString *dest = [weakSelf singModelPath];
                NSString *destDir = [dest stringByDeletingLastPathComponent];
                NSError *mkdirErr = nil;
                [[NSFileManager defaultManager] createDirectoryAtPath:destDir
                                          withIntermediateDirectories:YES
                                                           attributes:nil
                                                                error:&mkdirErr];

                NSString *zipPath = [destDir stringByAppendingPathComponent:@"mdx23c_instvoc_hq.zip"];
                [[NSFileManager defaultManager] removeItemAtPath:zipPath error:nil];
                [[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:zipPath] error:nil];

                // Extract ZIP using YTMUZipExtractor
                NSError *unzipErr = nil;
                BOOL unzipped = [YTMUZipExtractor unzipFileAtPath:zipPath toDestination:destDir error:&unzipErr];
                NSLog(@"[YTMU-Sing] Model unzip result: %d, err: %@", unzipped, unzipErr);

                // Clean up zip file
                [[NSFileManager defaultManager] removeItemAtPath:zipPath error:nil];

                if (!unzipped) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        weakSelf.activeDownloadTask = nil;
                        weakSelf.downloadStatusText = [NSString stringWithFormat:@"Extraction failed: %@", unzipErr.localizedDescription ?: @"invalid model archive"];
                        [weakSelf.tableView reloadSections:[NSIndexSet indexSetWithIndex:1]
                                          withRowAnimation:UITableViewRowAnimationAutomatic];
                    });
                    return;
                }
                [[YTMUVocalSeparationManager sharedInstance] loadModelIfAvailableWithCompletion:^(BOOL ready, NSError *loadError) {
                    weakSelf.activeDownloadTask = nil;
                    weakSelf.downloadStatusText = ready ? nil : [NSString stringWithFormat:@"Model load failed: %@", loadError.localizedDescription ?: @"Core ML rejected the package"];
                    [weakSelf.tableView reloadSections:[NSIndexSet indexSetWithIndex:1]
                                      withRowAnimation:UITableViewRowAnimationAutomatic];
                }];
            });
        }];

    [task addObserver:self forKeyPath:@"countOfBytesReceived" options:NSKeyValueObservingOptionNew context:NULL];
    [task addObserver:self forKeyPath:@"countOfBytesExpectedToReceive" options:NSKeyValueObservingOptionNew context:NULL];

    self.activeDownloadTask = task;
    [task resume];

    [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:1 inSection:1]]
                          withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ([keyPath isEqualToString:@"countOfBytesReceived"] || [keyPath isEqualToString:@"countOfBytesExpectedToReceive"]) {
        NSURLSessionDownloadTask *t = self.activeDownloadTask;
        if (t) {
            float progress = 0.0;
            if (t.countOfBytesExpectedToReceive > 0) {
                progress = (float)t.countOfBytesReceived / (float)t.countOfBytesExpectedToReceive;
            }
            double mbReceived = (double)t.countOfBytesReceived / (1024.0 * 1024.0);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.downloadProgressView.progress = progress;
                self.downloadStatusText = [NSString stringWithFormat:@"Downloading... (%.1f MB)", mbReceived];
            });
        }
    }
}

- (void)dealloc {
    @try {
        [self.activeDownloadTask removeObserver:self forKeyPath:@"countOfBytesReceived"];
        [self.activeDownloadTask removeObserver:self forKeyPath:@"countOfBytesExpectedToReceive"];
    } @catch (__unused NSException *e) {}
}

#pragma mark - Action handlers

- (void)toggleHapticsSwitch:(ABCSwitch *)sender {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:[defaults dictionaryForKey:@"YTMUltimate"]];
    d[@"musicHaptics"] = @(sender.isOn);
    [defaults setObject:d forKey:@"YTMUltimate"];
    NSLog(@"[YTMU-Haptics] User toggled musicHaptics: %d", sender.isOn);
    if (sender.isOn) {
        YTMUTriggerBeatHaptic();
    }
}

- (void)controlHapticsIntensitySelect:(UISegmentedControl *)sender {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:[defaults dictionaryForKey:@"YTMUltimate"]];
    d[@"musicHapticsIntensity"] = @(sender.selectedSegmentIndex);
    [defaults setObject:d forKey:@"YTMUltimate"];
    NSLog(@"[YTMU-Haptics] User set intensity: %ld", (long)sender.selectedSegmentIndex);
    YTMUTriggerBeatHaptic();
}

- (void)toggleFallbackSwitch:(ABCSwitch *)sender {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:[defaults dictionaryForKey:@"YTMUltimate"]];
    d[@"musicHapticsFallback"] = @(sender.isOn);
    [defaults setObject:d forKey:@"YTMUltimate"];
    NSLog(@"[YTMU-Haptics] User toggled haptic fallback: %d", sender.isOn);
    if (sender.isOn) {
        YTMUTriggerBeatHaptic();
    }
}

- (void)toggleTapticSwitch:(ABCSwitch *)sender {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:[defaults dictionaryForKey:@"YTMUltimate"]];
    d[@"tapticSpeaker"] = @(sender.isOn);
    [defaults setObject:d forKey:@"YTMUltimate"];
    NSLog(@"[YTMU-Haptics] User toggled taptic speaker: %d", sender.isOn);
    if (!sender.isOn) {
        YTMUTapticSpeakerStop();
    }
}

- (void)toggleSingSwitch:(ABCSwitch *)sender {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:[defaults dictionaryForKey:@"YTMUltimate"]];
    YTMUVocalSeparationManager *manager = [YTMUVocalSeparationManager sharedInstance];
    if (sender.isOn && manager.selectedMode == YTMUVocalSeparationModeNormal) {
        manager.selectedMode = YTMUVocalSeparationModeVocalOnly;
    } else if (!sender.isOn) {
        manager.selectedMode = YTMUVocalSeparationModeNormal;
    }
    d[@"singEnabled"] = @(sender.isOn);
    [defaults setObject:d forKey:@"YTMUltimate"];
}

@end
