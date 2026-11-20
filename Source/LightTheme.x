// Light theme foundation.
//
// YTMusic is a dark-only app, but the tweak owns a growing number of
// surfaces (the artwork gradient, the lyrics panel, search cards). When
// this switch is on those surfaces must follow the iOS light/dark
// appearance instead of forcing dark, and it takes priority over the
// older OLED dark switch. The first increment wires the pref, the window
// appearance and OUR surfaces; YT's own hard-coded dark views are a
// separate, later pass.

#import <UIKit/UIKit.h>
#import "LyricsShared.h"

static NSDictionary *YTMULightThemePrefs(void) {
    return [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
}

BOOL YTMULightThemeEnabled(void) {
    NSDictionary *d = YTMULightThemePrefs();
    return [d[@"YTMUltimateIsEnabled"] boolValue] && [d[@"lightThemeEnabled"] boolValue];
}

// A window's overrideUserInterfaceStyle masks the OS setting. UIScreen's
// trait collection is not masked by a window override, so it is the
// honest answer to "what does the user's system look like right now".
static UIUserInterfaceStyle YTMUSystemInterfaceStyle(void) {
    UITraitCollection *tc = [UIScreen mainScreen].traitCollection;
    if (tc && tc.userInterfaceStyle != UIUserInterfaceStyleUnspecified) {
        return tc.userInterfaceStyle;
    }
    return UIUserInterfaceStyleDark;
}

BOOL YTMULightThemeActive(void) {
    return YTMULightThemeEnabled() && YTMUSystemInterfaceStyle() == UIUserInterfaceStyleLight;
}

void YTMUApplyLightThemeAppearance(void) {
    BOOL enabled = YTMULightThemeEnabled();
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        // Unspecified = follow the system; Dark restores the app's normal
        // appearance when the switch is off (YT ships dark-only).
        UIUserInterfaceStyle want = enabled ? UIUserInterfaceStyleUnspecified : UIUserInterfaceStyleDark;
        if (w.overrideUserInterfaceStyle != want) w.overrideUserInterfaceStyle = want;
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:@"YTMULightThemeDidChange" object:nil];
}

%ctor {
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
        object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        YTMUApplyLightThemeAppearance();
    }];
}
