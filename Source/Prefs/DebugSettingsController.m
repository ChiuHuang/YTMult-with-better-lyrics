#import "DebugSettingsController.h"
#import "../LyricsShared.h"
#import "../Headers/Localization.h"

// YTMUDebugUploadAllowed / YTMUAppSettingBool come from ../LyricsShared.h
// (defined in LyricsCore.x); this page is only a consumer.

#ifndef TWEAK_VERSION
#define TWEAK_VERSION 0
#endif
// Comes from <rootless.h> via Localization.h in the sibling settings pages;
// defined here too so this file does not depend on that include chain.
#ifndef OS_STRINGIFY
#define OS_STRINGIFY_(x) #x
#define OS_STRINGIFY(x) OS_STRINGIFY_(x)
#endif

// Section 0 has a fixed shape: title on the left, the live value right-aligned
// in the accessory, and an optional second line under the title.
static NSString *const kYTMUDebugStreamCellID = @"debugStream";
static NSString *const kYTMUDebugUploadCellID = @"debugUpload";
static NSString *const kYTMUDebugActionCellID = @"debugAction";

static const CGFloat kYTMUDebugValueMaxWidth = 190.0;
static const NSUInteger kYTMUDebugLastLineMaxChars = 48;

// One dictionary read per row, values are short by construction; only the
// streamed line can be long, so it is the only string that needs trimming.
static NSString *YTMUDebugTrimmed(NSString *text, NSUInteger maxChars) {
    if (text.length <= maxChars) return text;
    return [[text substringToIndex:maxChars] stringByAppendingString:@"..."];
}

@interface DebugSettingsController ()
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, strong) NSDictionary *streamStatus;
@end

@implementation DebugSettingsController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = LOC(@"DEBUG_SETTINGS");
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
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
    self.streamStatus = YTMUDebugStreamStatus();
    if (self.refreshTimer) return;
    // Block form: a selector-based timer retains its target, so the page could
    // never be deallocated while it is on screen.
    __weak typeof(self) weakSelf = self;
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
        [weakSelf ytmu_refreshStatus];
    }];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

- (void)dealloc {
    [_refreshTimer invalidate];
}

#pragma mark - Live status

- (NSDictionary *)status {
    if (!self.streamStatus) self.streamStatus = YTMUDebugStreamStatus();
    return self.streamStatus;
}

- (void)ytmu_refreshStatus {
    self.streamStatus = YTMUDebugStreamStatus();
    // Only the six live rows move; sections 1 and 2 hold user state and must
    // never be rebuilt under a finger (it would drop a switch drag).
    if (!self.tableView.window) return;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0]
                     withRowAnimation:UITableViewRowAnimationNone];
}

- (UILabel *)ytmu_valueLabelWithText:(NSString *)text monospaced:(BOOL)monospaced {
    UILabel *label = [[UILabel alloc] init];
    label.text = text.length ? text : @"--";
    label.font = monospaced ? [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightRegular]
                            : [UIFont systemFontOfSize:14];
    label.textColor = [UIColor secondaryLabelColor];
    label.textAlignment = NSTextAlignmentRight;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.7;
    label.lineBreakMode = NSLineBreakByTruncatingMiddle;
    CGFloat width = [label sizeThatFits:CGSizeMake(kYTMUDebugValueMaxWidth, 20)].width;
    label.frame = CGRectMake(0, 0, MIN(width, kYTMUDebugValueMaxWidth), 22);
    return label;
}

- (UITableViewCell *)ytmu_streamCellForTableView:(UITableView *)tableView row:(NSInteger)row {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kYTMUDebugStreamCellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kYTMUDebugStreamCellID];
        cell.detailTextLabel.numberOfLines = 0;
    }
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = nil;
    cell.textLabel.textColor = [UIColor labelColor];
    cell.detailTextLabel.text = nil;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
    cell.detailTextLabel.numberOfLines = 0;

    NSDictionary *status = [self status];
    NSString *state = status[@"state"];
    NSString *video = status[@"video"];
    NSString *error = status[@"error"];

    if (row == 0) {
        cell.textLabel.text = LOC(@"DEBUG_STATE");
        cell.imageView.image = [UIImage systemImageNamed:@"antenna.radiowaves.left.and.right"];
        cell.accessoryView = [self ytmu_valueLabelWithText:state.length ? state : LOC(@"DEBUG_IDLE")
                                                monospaced:NO];
        // The state itself already sits on the right; the line under it carries
        // whatever explains it: the error in red, else the stage breakdown.
        if (error.length) {
            cell.detailTextLabel.text = error;
            cell.detailTextLabel.textColor = [UIColor systemRedColor];
            cell.detailTextLabel.numberOfLines = 2;
        } else if ([status[@"stages"] length]) {
            cell.detailTextLabel.text = status[@"stages"];
        }
        return cell;
    }

    if (row == 1) {
        cell.textLabel.text = LOC(@"DEBUG_VIDEO");
        cell.imageView.image = [UIImage systemImageNamed:@"music.note"];
        cell.accessoryView = [self ytmu_valueLabelWithText:video monospaced:NO];
        // A stream that finished for the previous song while the player moved
        // on is the confusing case, so name the current video next to it.
        NSString *nowPlaying = status[@"nowPlaying"];
        if (nowPlaying.length && ![nowPlaying isEqualToString:video]) {
            cell.detailTextLabel.text = [NSString stringWithFormat:LOC(@"DEBUG_NOW_PLAYING"), nowPlaying];
        }
        return cell;
    }

    if (row == 2) {
        cell.textLabel.text = LOC(@"DEBUG_PROGRESS");
        cell.imageView.image = [UIImage systemImageNamed:@"number"];
        cell.accessoryView = [self ytmu_valueLabelWithText:[NSString stringWithFormat:@"%@ / %@",
                                                                 status[@"events"] ?: @0,
                                                                 status[@"lines"] ?: @0]
                                                monospaced:YES];
        if (status[@"lastElapsed"]) {
            cell.detailTextLabel.text = [NSString stringWithFormat:LOC(@"DEBUG_LAST_EVENT"),
                                         status[@"lastElapsed"]];
            cell.detailTextLabel.font = [UIFont monospacedDigitSystemFontOfSize:12
                                                                        weight:UIFontWeightRegular];
        }
        return cell;
    }

    if (row == 3) {
        cell.textLabel.text = LOC(@"DEBUG_LAST_LINE");
        cell.imageView.image = [UIImage systemImageNamed:@"quote.bubble"];
        if (status[@"lastRow"]) {
            cell.accessoryView = [self ytmu_valueLabelWithText:[NSString stringWithFormat:@"#%@", status[@"lastRow"]]
                                                    monospaced:YES];
        }
        cell.detailTextLabel.text = YTMUDebugTrimmed(status[@"lastText"], kYTMUDebugLastLineMaxChars);
        return cell;
    }

    if (row == 4) {
        cell.textLabel.text = LOC(@"DEBUG_REVEAL");
        cell.imageView.image = [UIImage systemImageNamed:@"speedometer"];
        double cps = [status[@"cps"] doubleValue];
        // %g keeps a whole 30 as "30" and a hand-tuned 2.5 as "2.5".
        cell.accessoryView = [self ytmu_valueLabelWithText:[NSString stringWithFormat:@"%g cps%@", cps,
                                                                 cps > 0 ? @"" : @" (off)"]
                                                monospaced:YES];
        return cell;
    }

    // Endpoint. The URL is too long for the right column, so the language and
    // the stream switch take the value slot and the URL goes underneath.
    cell.textLabel.text = LOC(@"DEBUG_ENDPOINT");
    cell.imageView.image = [UIImage systemImageNamed:@"server.rack"];
    cell.accessoryView = [self ytmu_valueLabelWithText:[NSString stringWithFormat:@"%@ · %@",
                                                                 status[@"lang"] ?: @"?",
                                                                 [status[@"streamEnabled"] boolValue] ? @"on" : @"off"]
                                            monospaced:NO];
    cell.detailTextLabel.text = status[@"endpoint"];
    cell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    return cell;
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 6;
    if (section == 1) return 3;
    if (section == 2) return 2;
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return LOC(@"DEBUG_STREAM");
    if (section == 1) return LOC(@"DEBUG_UPLOAD");
    if (section == 2) return LOC(@"DEBUG_ACTIONS");
    return nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewAutomaticDimension;
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 2;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) return [self ytmu_streamCellForTableView:tableView row:indexPath.row];
    if (indexPath.section == 1) return [self ytmu_uploadCellForTableView:tableView row:indexPath.row];
    return [self ytmu_actionCellForTableView:tableView row:indexPath.row];
}

- (UITableViewCell *)ytmu_uploadCellForTableView:(UITableView *)tableView row:(NSInteger)row {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kYTMUDebugUploadCellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kYTMUDebugUploadCellID];
        cell.detailTextLabel.numberOfLines = 0;
    }
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.textColor = [UIColor labelColor];

    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"]];

    if (row == 0) {
        cell.textLabel.text = LOC(@"DEBUG_LOG_LEVEL");
        cell.detailTextLabel.text = LOC(@"DEBUG_LOG_LEVEL_DESC");
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.imageView.image = [UIImage systemImageNamed:@"waveform.badge.exclamationmark"];
        UISegmentedControl *segment = [[UISegmentedControl alloc] initWithItems:@[@"Off", @"Err", @"All"]];
        segment.selectedSegmentIndex = MIN(MAX([dict[@"debugLogLevel"] integerValue], 0), 2);
        segment.accessibilityIdentifier = @"debugLogLevel";
        [segment addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = segment;
        return cell;
    }

    NSString *key = row == 1 ? @"sendDebugLogsToServer" : @"sendLyricsScreenshotDebug";
    NSString *title = row == 1 ? LOC(@"DEBUG_SEND") : LOC(@"DEBUG_SCREENSHOT");
    NSString *desc = row == 1 ? LOC(@"DEBUG_SEND_DESC") : LOC(@"DEBUG_SCREENSHOT_DESC");
    cell.textLabel.text = title;
    cell.imageView.image = [UIImage systemImageNamed:row == 1 ? @"ladybug" : @"camera"];
    cell.detailTextLabel.text = [self ytmu_uploadNoteForDescription:desc];

    // Only the server-side switch can make these rows permanently unusable.
    // Gating on YTMUDebugUploadAllowed() instead would grey them out by
    // default, since that also returns NO while the master toggle in this same
    // row is still off -- the user could never turn uploads on.
    BOOL serverAllows = YTMUAppSettingBool(@"upload_logs", YES);
    UISwitch *sw = [[UISwitch alloc] init];
    sw.accessibilityIdentifier = key;
    sw.on = [dict[key] boolValue];
    sw.enabled = serverAllows;
    [sw addTarget:self action:@selector(toggleSwitch:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    if (!serverAllows) {
        cell.textLabel.textColor = [UIColor tertiaryLabelColor];
        cell.detailTextLabel.textColor = [UIColor tertiaryLabelColor];
    } else {
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }
    return cell;
}

- (NSString *)ytmu_uploadNoteForDescription:(NSString *)desc {
    if (!YTMUAppSettingBool(@"upload_logs", YES)) return LOC(@"DEBUG_UPLOAD_OFF");
    if (!YTMUDebugUploadAllowed(@"info")) {
        return [NSString stringWithFormat:LOC(@"DEBUG_UPLOAD_BLOCKED"), desc];
    }
    return desc;
}

- (UITableViewCell *)ytmu_actionCellForTableView:(UITableView *)tableView row:(NSInteger)row {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kYTMUDebugActionCellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kYTMUDebugActionCellID];
        cell.detailTextLabel.numberOfLines = 0;
    }
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.textLabel.textColor = [UIColor systemBlueColor];
    cell.detailTextLabel.text = nil;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    if (row == 0) {
        cell.textLabel.text = LOC(@"DEBUG_COPY");
        cell.imageView.image = [UIImage systemImageNamed:@"square.and.arrow.up"];
    } else {
        cell.textLabel.text = LOC(@"DEBUG_TEST_LOG");
        cell.imageView.image = [UIImage systemImageNamed:@"paperplane"];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 2) return;
    if (indexPath.row == 0) {
        [self ytmu_copyDiagnostics];
        return;
    }
    [self ytmu_sendTestLog];
}

#pragma mark - Switch / segment

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
    // The upload rows and their gating depend on the new level.
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1]
                     withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark - Actions

- (void)ytmu_copyDiagnostics {
    NSDictionary *status = [self status];
    UIDevice *device = [UIDevice currentDevice];
    NSMutableString *block = [NSMutableString string];
    [block appendString:@"YTMUltimate debug snapshot\n"];
    [block appendFormat:@"when: %@\n", [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                                    dateStyle:NSDateFormatterMediumStyle
                                                                    timeStyle:NSDateFormatterMediumStyle]];
    [block appendFormat:@"tweak: %@ (%@)\n", @OS_STRINGIFY(TWEAK_VERSION), @TWEAK_GIT_COMMIT];
    [block appendFormat:@"device: %@ (iOS %@)\n", device.model, device.systemVersion];
    [block appendFormat:@"endpoint: %@\n", YTMUApiBase()];
    [block appendFormat:@"lang: %@\n", YTMUTargetLang()];
    [block appendString:@"--- stream status ---\n"];
    // Sorted so two snapshots of the same state are diffable by eye.
    for (NSString *key in [status.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        [block appendFormat:@"%@ = %@\n", key, status[key]];
    }
    [UIPasteboard generalPasteboard].string = block;
    [self ytmu_alertWithTitle:LOC(@"DEBUG_COPIED") message:nil];
}

- (void)ytmu_sendTestLog {
    sendDebugLog(@"[MUSIC] Debug test log from settings");
    NSString *message = YTMUDebugUploadAllowed(@"info") ? LOC(@"DEBUG_TEST_SENT")
                                                         : LOC(@"DEBUG_TEST_BLOCKED");
    [self ytmu_alertWithTitle:LOC(@"DEBUG_TEST_LOG") message:message];
}

- (void)ytmu_alertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
