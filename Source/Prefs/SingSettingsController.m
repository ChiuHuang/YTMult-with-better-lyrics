#import "SingSettingsController.h"
#import "../LyricsShared.h"
#import "../Headers/Localization.h"

// YTMUTriggerBeatHaptic / YTMUTriggerSyllableHaptic are declared in LyricsShared.h.

@interface SingSettingsController ()
@property (nonatomic, strong) UIProgressView *downloadProgressView;
@property (nonatomic, strong) UILabel *downloadStatusLabel;
@property (nonatomic, strong) NSURLSessionDownloadTask *activeDownloadTask;
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

#pragma mark - Table view data source

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewAutomaticDimension;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    // Section 0: Music Haptics
    // Section 1: Sing / Vocal Separation
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 2; // toggle + intensity
    if (section == 1) return 2; // sing toggle + model download
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return LOC(@"MUSIC_HAPTICS");
    if (section == 1) return LOC(@"SING_SECTION_HEADER");
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return LOC(@"MUSIC_HAPTICS_FOOTER");
    if (section == 1) return LOC(@"SING_FOOTER");
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
            sw.on = [YTMUltimateDict[@"musicHaptics"] boolValue];
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
            sw.on = modelReady && [YTMUltimateDict[@"singEnabled"] boolValue];
            sw.enabled = modelReady;
            if (!modelReady) {
                sw.alpha = 0.4;
            }
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }

        if (indexPath.row == 1) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"singDownloadCell"];
            BOOL modelReady = [self isSingModelReady];
            BOOL downloading = (self.activeDownloadTask != nil);

            if (modelReady) {
                cell.textLabel.text = LOC(@"SING_MODEL_READY");
                cell.textLabel.textColor = [UIColor systemGreenColor];
                cell.detailTextLabel.text = nil;
                cell.accessoryType = UITableViewCellAccessoryCheckmark;
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
            } else if (downloading) {
                cell.textLabel.text = LOC(@"SING_MODEL_DOWNLOADING");
                cell.textLabel.textColor = [UIColor secondaryLabelColor];
                cell.detailTextLabel.text = nil;
                cell.accessoryType = UITableViewCellAccessoryNone;

                // Progress view in accessory area
                UIProgressView *pv = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
                pv.frame = CGRectMake(0, 0, 100, 10);
                pv.progress = 0.0;
                self.downloadProgressView = pv;
                cell.accessoryView = pv;
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
            } else {
                cell.textLabel.text = LOC(@"SING_MODEL_DOWNLOAD");
                cell.textLabel.textColor = [UIColor systemBlueColor];
                cell.detailTextLabel.text = nil;
                cell.accessoryType = UITableViewCellAccessoryNone;
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            }
            return cell;
        }
    }

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 1 && indexPath.row == 1) {
        if (![self isSingModelReady] && self.activeDownloadTask == nil) {
            [self startModelDownload];
        }
    }
}

#pragma mark - Model helpers

- (NSString *)singModelPath {
    NSString *appSupport = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [appSupport stringByAppendingPathComponent:@"YTMUltimate/mdx23c_instvoc_hq.mlpackage"];
}

- (BOOL)isSingModelReady {
    return [[NSFileManager defaultManager] fileExistsAtPath:[self singModelPath]];
}

- (void)startModelDownload {
    self.activeDownloadTask = nil;
    [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:1 inSection:1]]
                          withRowAnimation:UITableViewRowAnimationAutomatic];

    NSURL *url = [NSURL URLWithString:@"https://chiuhuang.dev/mdx23c_instvoc_hq"];
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg delegate:nil delegateQueue:[NSOperationQueue mainQueue]];

    __weak typeof(self) weakSelf = self;
    NSURLSessionDownloadTask *task = [session downloadTaskWithURL:url
        completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            if (error || !location) {
                weakSelf.activeDownloadTask = nil;
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

            // Move the downloaded ZIP; extraction is handled by VocalSeparation on first use
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

            // Notify VocalSeparation to extract the ZIP on next access
            [[NSNotificationCenter defaultCenter] postNotificationName:@"YTMUSingModelZIPReady"
                                                                object:zipPath];

            weakSelf.activeDownloadTask = nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf.tableView reloadSections:[NSIndexSet indexSetWithIndex:1]
                                  withRowAnimation:UITableViewRowAnimationAutomatic];
            });
        }];

    // Observe progress via KVO
    __weak NSURLSessionDownloadTask *weakTask = task;
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
        if (t && t.countOfBytesExpectedToReceive > 0) {
            float progress = (float)t.countOfBytesReceived / (float)t.countOfBytesExpectedToReceive;
            dispatch_async(dispatch_get_main_queue(), ^{
                self.downloadProgressView.progress = progress;
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
    if (sender.isOn) {
        YTMUTriggerBeatHaptic();
    }
}

- (void)controlHapticsIntensitySelect:(UISegmentedControl *)sender {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:[defaults dictionaryForKey:@"YTMUltimate"]];
    d[@"musicHapticsIntensity"] = @(sender.selectedSegmentIndex);
    [defaults setObject:d forKey:@"YTMUltimate"];
    YTMUTriggerBeatHaptic();
}

- (void)toggleSingSwitch:(ABCSwitch *)sender {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:[defaults dictionaryForKey:@"YTMUltimate"]];
    d[@"singEnabled"] = @(sender.isOn);
    [defaults setObject:d forKey:@"YTMUltimate"];
}

@end
