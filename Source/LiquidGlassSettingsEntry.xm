#import <UIKit/UIKit.h>
#import "Prefs/YTMUltimateSettingsController.h"
#import "Prefs/LiquidGlassSettingsController.h"
#import "Headers/Localization.h"
#import "YTMULiquidGlassPreferences.h"

// The main settings page is a plain UIViewController presented inside a
// UINavigationController (Source/Settings.x pushes it with
// `initWithRootViewController:`), so it has no toolbarItems and no
// UIToolbar to hang a button off. The Liquid Glass page is therefore a
// trailing section in its table instead: one row, one cell, one push. It is
// appended AFTER every existing section, so the row arithmetic of the sections
// above it -- which other files keep editing -- cannot shift.

// Logos does not make a %new method visible to the type checker at other call
// sites in the same hook, hence this declaration.
@interface YTMUltimateSettingsController (YTMULiquidGlassEntry)
- (void)ytmu_openLiquidGlassSettings;
@end

static NSString *const kYTMULGEntryCellID = @"ytmuLiquidGlassSettings";

static UITableViewCell *YTMULGEntryCell(UITableView *tableView) {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kYTMULGEntryCellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kYTMULGEntryCellID];
    }
    cell.textLabel.text = LOC(@"LG_MASTER");
    cell.detailTextLabel.text = LOC(@"LG_MASTER_DESC");
    cell.detailTextLabel.numberOfLines = 0;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.imageView.image = [UIImage systemImageNamed:@"circle.lefthalf.filled"];
    cell.accessibilityLabel = LOC(@"LG_ENTRY_BUTTON");
    return cell;
}

// The new section is always the LAST one and holds exactly one row. The count
// comes from the hooked numberOfSectionsInTableView: below (which is %orig + 1),
// so this stays correct without caching anything and without adding to any
// existing section's row count. A no-op (returns NO) when the material system
// is unavailable, which is the only case where the section was never created.
static BOOL YTMULGEntryRow(YTMUltimateSettingsController *controller, UITableView *tableView, NSIndexPath *indexPath) {
    if (!YTMULGAvailable()) return NO;
    if (!controller || !tableView || !indexPath) return NO;
    if ([indexPath section] != (NSInteger)[controller numberOfSectionsInTableView:tableView] - 1) return NO;
    return [indexPath row] == 0;
}

static NSInteger YTMULGEntrySection(YTMUltimateSettingsController *controller, UITableView *tableView) {
    if (!YTMULGAvailable()) return -1;
    return (NSInteger)[controller numberOfSectionsInTableView:tableView] - 1;
}

%hook YTMUltimateSettingsController

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    NSInteger original = %orig;
    return YTMULGAvailable() ? original + 1 : original;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == YTMULGEntrySection(self, tableView)) return 1;
    return %orig;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == YTMULGEntrySection(self, tableView)) return LOC(@"LG_TITLE");
    return %orig;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (YTMULGEntryRow(self, tableView, indexPath)) return YTMULGEntryCell(tableView);
    return %orig;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (YTMULGEntryRow(self, tableView, indexPath)) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        [self ytmu_openLiquidGlassSettings];
        return;
    }
    %orig;
}

%new
- (void)ytmu_openLiquidGlassSettings {
    UINavigationController *nav = self.navigationController;
    if (!nav) return;
    LiquidGlassSettingsController *controller = [[LiquidGlassSettingsController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    [nav pushViewController:controller animated:YES];
}

%end
