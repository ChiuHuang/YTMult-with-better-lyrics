#import "LiquidGlassSettingsController.h"
#import "../YTMULiquidGlassPreferences.h"
#import "../Headers/Localization.h"

@interface LiquidGlassSettingsController ()
@property(nonatomic,strong) NSArray<NSArray<NSDictionary *> *> *groups;
@end

@implementation LiquidGlassSettingsController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = LOC(@"LG_TITLE");
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    // Every key here is one of the ten keys seeded by
    // LiquidGlassPreferencesBootstrap.xm; the V1 keys that gate the old
    // generation (liquidGlassEnabled, fullPlayerLiquidGlassEnabled) are
    // deliberately not rows -- see the policy block in
    // YTMULiquidGlassPreferences.h.
    self.groups = @[
        @[
            @{@"title":LOC(@"LG_MASTER"), @"key":@"liquidGlassV2Enabled", @"subtitle":LOC(@"LG_MASTER_DESC")},
            @{@"title":LOC(@"LG_SONG_THEME_WHOLE"), @"key":@"wholeAppSongThemeEnabled", @"subtitle":LOC(@"LG_SONG_THEME_WHOLE_DESC")},
            @{@"title":LOC(@"LG_SONG_THEME_PLAYER"), @"key":@"playerSongThemeEnabled", @"subtitle":LOC(@"LG_SONG_THEME_PLAYER_DESC")}
        ],
        @[
            @{@"title":LOC(@"LG_FULLPLAYER_V2"), @"key":@"fullPlayerV2Enabled", @"subtitle":LOC(@"LG_FULLPLAYER_V2_DESC")},
            @{@"title":LOC(@"LG_LYRICS_V2"), @"key":@"lyricsV2Enabled", @"subtitle":LOC(@"LG_LYRICS_V2_DESC")},
            @{@"title":LOC(@"LG_LYRICS_BUTTON"), @"key":@"lyricsEntryButtonEnabled", @"subtitle":LOC(@"LG_LYRICS_BUTTON_DESC")},
            @{@"title":LOC(@"LG_QUEUE_V2"), @"key":@"queueV2Enabled", @"subtitle":LOC(@"LG_QUEUE_V2_DESC")}
        ],
        @[
            @{@"title":LOC(@"LG_HOME_V2"), @"key":@"homeV2Enabled", @"subtitle":LOC(@"LG_HOME_V2_DESC")},
            @{@"title":LOC(@"LG_PIVOT_V2"), @"key":@"pivotBarV2Enabled", @"subtitle":LOC(@"LG_PIVOT_V2_DESC")},
            @{@"title":LOC(@"LG_SHEETS_V2"), @"key":@"sheetsV2Enabled", @"subtitle":LOC(@"LG_SHEETS_V2_DESC")}
        ]
    ];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return self.groups.count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.groups[section].count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[LOC(@"LG_SECTION_THEME"), LOC(@"LG_SECTION_PLAYER"), LOC(@"LG_SECTION_APP")][(NSUInteger)section];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"YTMULiquidGlassSwitch";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    NSDictionary *item = self.groups[indexPath.section][indexPath.row];
    cell.textLabel.text = item[@"title"];
    cell.detailTextLabel.text = item[@"subtitle"];
    cell.detailTextLabel.numberOfLines = 2;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UISwitch *toggle = [UISwitch new];
    toggle.on = YTMULGPreference(item[@"key"], YES);
    toggle.accessibilityIdentifier = item[@"key"];
    [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    return cell;
}

- (void)toggleChanged:(UISwitch *)sender {
    NSString *key = sender.accessibilityIdentifier;
    if (!key.length) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary *p = [[defaults dictionaryForKey:@"YTMUltimate"] mutableCopy] ?: [NSMutableDictionary dictionary];
    p[key] = @(sender.isOn);
    [defaults setObject:p forKey:@"YTMUltimate"];
}

@end
