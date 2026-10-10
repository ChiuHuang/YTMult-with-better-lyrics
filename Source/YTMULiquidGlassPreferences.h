#ifndef YTMULiquidGlassPreferences_h
#define YTMULiquidGlassPreferences_h

#import <Foundation/Foundation.h>

// YTMUAppSettingBool is DEFINED in LyricsCore.x, which Theos compiles as
// Objective-C (C linkage). Every Liquid Glass .xm is Objective-C++ and pulls
// this header in, so the declaration has to carry C linkage explicitly or
// the call mangles to _Z18YTMUAppSettingBoolP10NSString8ObjCBool and the V2
// stack fails to link. LiquidGlass.xm imports BOTH this header and
// LyricsShared.h (where the same function is declared inside its own
// extern "C" block) -- two declarations of one name with different language
// linkage in a single scope is ill-formed, so both must agree.
@class UIImage;
@class UIColor;

#ifdef __cplusplus
extern "C" {
#endif

UIImage *YTMULGCurrentArtwork(void);
UIColor *YTMULGCurrentArtworkMean(void);

// Declared flush (no leading whitespace) so the C-linkage guard and the
// declaration can be read -- and grepped -- as one block.
BOOL YTMUAppSettingBool(NSString *key, BOOL dflt);
BOOL YTMULGServerAllows(NSString *key);
void YTMUAppSettingsInvalidateCache(void);

#ifdef __cplusplus
}
#endif

// ---------------------------------------------------------------------------
// V1 / V2 coexistence policy. This block is the whole contract; everything
// else in the Liquid Glass V2 stack only reads keys through the helpers here.
//
// The tweak already shipped V1 Liquid Glass:
//   Source/LiquidGlass.xm          master key `liquidGlassEnabled`
//                                  (only hooks YTMMiniPlayerView)
//   Source/FullPlayerLiquidGlass.xm  key `fullPlayerLiquidGlassEnabled`
//                                  (hooks YTMPlayerCarouselCell,
//                                  YTMPlayerControlsView,
//                                  YTMPlayerHeaderView, YTMAVSwitch)
// Both read their key as "on when unset". The V2 stack hooks the SAME classes
// (YTMMiniPlayerView, YTMPlayerHeaderView, YTMPlayerCarouselCell,
// YTMPlayerControlsView), so with both generations live you get two blur
// layers, two corner radii, two artwork cards and two layoutSubviews hooks
// fighting over one view on every layout pass.
//
// Policy, smallest form that cannot produce a stuck state:
//  1. The V2 master key is `liquidGlassV2Enabled`, NOT `liquidGlassEnabled`,
//     so no V2 key ever collides with a V1 key and every key keeps exactly
//     one meaning on every install, old or new. (This renames one V2 key; no
//     V1 key was touched.)
//  2. Each V1 predicate additionally requires its V2 replacement to be OFF
//     (YTMULGV1Allowed below), so V1 is a fallback generation, never a
//     second layer on top of V2.
//  3. The bootstrap writes an explicit value for all twelve keys, so "unset"
//     can never mean two different things: the ten V2 keys default ON (the new
//     look) and the two V1 keys default OFF. Changing the V1 default from
//     "on" to "off" is deliberate and is the product decision here: it means
//     "Liquid Glass off" really turns material off instead of silently
//     falling back to the old glass, and V1 is reachable again by setting its
//     own key to YES with the matching V2 key off.
// V1 stays compiled (it is not dead code, it is the fallback). Nothing else in
// the V2 stack may read a key directly, so no copy of a predicate can drift
// away from this policy.
// ---------------------------------------------------------------------------

// Every Liquid Glass key lives in this one dictionary (the whole tweak shares
// it, see Prefs/YTMUltimateSettingsController.m).
static inline BOOL YTMULGPreference(NSString *key, BOOL fallback) {
    NSDictionary *p = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    id value = p[key];
    return value == nil ? fallback : [value boolValue];
}

// The tweak's own master switch (row 0 of the main settings page). Every V1 and
// V2 predicate is ANDed with it, so turning the tweak off kills both
// generations.
//
// `ui.tweak` is the REMOTE half of the same switch, and it reads nil on purpose:
// YTMULGServerAllows(nil) is the one call shape that checks the glass master and
// then stops, without looking up a per-surface key (there is no "ui." + "").
// That keeps this header free of a second remote-read helper while still letting
// the server kill the whole stack for one build without spelling out eighteen
// per-surface keys. YTMULGServerAllows is declared in the extern "C" block at
// the top of this header, so this definition can call it here.
static inline BOOL YTMULGTweakEnabled(void) {
    NSDictionary *p = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    if (![p[@"YTMUltimateIsEnabled"] boolValue]) return NO;
    return YTMULGServerAllows(nil);
}

// The whole V2 stack is built on the iOS 13 material system
// (UIBlurEffectStyleSystemChromeMaterialDark, kCACornerCurveContinuous,
// UIVisualEffectView chrome). The Makefile targets 13.0 so this is always
// true in the shipped build; it is checked at runtime anyway so the entry row
// and the V1 gate stay a no-op if the floor ever moves.
static inline BOOL YTMULGAvailable(void) {
    NSOperatingSystemVersion required;
    required.majorVersion = 13;
    required.minorVersion = 0;
    required.patchVersion = 0;
    return [[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:required];
}

// One V2 feature switch (used by every V2 file) + the tweak master.
//
// The remote gate LIVES in LyricsCore.x, not here, for two reasons:
//   - it is called on every layout pass of ~40 hooked classes, so the map has
//     to be read through a cache; a static inline in this header would give
//     each of the 15 .xm files its own uncached copy;
//   - the user's local opt-out and the fail-open defaults are policy that must
//     be stated once.
// See YTMULGServerAllows() in Source/LyricsCore.x.
BOOL YTMULGServerAllows(NSString *key);

static inline BOOL YTMULGFeatureEnabled(NSString *v2Key) {
    return YTMULGTweakEnabled() && YTMULGAvailable() && YTMULGPreference(v2Key, YES) && YTMULGServerAllows(v2Key);
}

// The V1 counterpart of a V2 key: V1 only runs when its V2 replacement is off.
// This is the gate Source/LiquidGlass.xm and Source/FullPlayerLiquidGlass.xm
// call; a V1 predicate that does not call it can double-apply against V2.
static inline BOOL YTMULGV1Allowed(NSString *v2Key) {
    return YTMULGTweakEnabled() && YTMULGAvailable() && !YTMULGPreference(v2Key, YES);
}

// The ten V2 keys, all on by default. `liquidGlassV2Enabled` is the V2 master
// (mini player V3); `fullPlayerV2Enabled` is the full player; the rest are the
// per-surface V2 look plus the artwork theme pair.
static inline NSDictionary<NSString *, NSNumber *> *YTMULGDefaultPreferences(void) {
    return @{
        @"liquidGlassV2Enabled": @YES,
        @"fullPlayerV2Enabled": @YES,
        @"lyricsV2Enabled": @YES,
        @"queueV2Enabled": @YES,
        @"sheetsV2Enabled": @YES,
        @"homeV2Enabled": @YES,
        @"pivotBarV2Enabled": @YES,
        @"lyricsEntryButtonEnabled": @YES,
        @"playerSongThemeEnabled": @YES,
        @"wholeAppSongThemeEnabled": @YES,
        @"searchV2Enabled": @YES,
        @"libraryV2Enabled": @YES,
        @"entityPagesV2Enabled": @YES,
        @"albumV2Enabled": @YES,
        @"artistV2Enabled": @YES,
        @"playlistV2Enabled": @YES,
        @"downloadsV2Enabled": @YES,
        @"statusOverlaysV2Enabled": @YES,
        @"globalStatesV2Enabled": @YES,
        @"videoV2Enabled": @YES,
        @"landscapePlayerV2Enabled": @YES,
        @"lyricsProviderAllFetchEnabled": @YES,
        @"materialIntensity": @0.72,
        @"backgroundImageStrength": @0.48,
        @"reduceTransparencyFallbackEnabled": @YES,
        @"reduceGlassMotionEnabled": @YES
    };
}

// The two V1 keys, off by default (see point 3 above). The bootstrap only
// fills keys that are nil, so a user who already turned V1 off keeps that and
// a user who wants the old look back can set these to YES.
static inline NSDictionary<NSString *, NSNumber *> *YTMULGV1DefaultPreferences(void) {
    return @{
        @"liquidGlassEnabled": @NO,
        @"fullPlayerLiquidGlassEnabled": @NO
    };
}

#endif
