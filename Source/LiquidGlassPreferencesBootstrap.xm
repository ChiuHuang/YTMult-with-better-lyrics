#import <Foundation/Foundation.h>
#import "YTMULiquidGlassPreferences.h"

// Fills in every key the Liquid Glass stack reads, so "unset" never means two
// different things: the eight V2 keys land ON (the new look) and the two V1
// keys land OFF (V1 is the fallback, see YTMULiquidGlassPreferences.h). Only
// nil keys are written, so an existing value -- including a user's deliberate
// NO or a leftover V1 YES -- is never overwritten, and the V2 gate in
// YTMULGV1Allowed decides which generation runs. Run once per process, in
// %ctor, before any hook can read a key.
%ctor {
    @autoreleasepool {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSMutableDictionary *p = [[defaults dictionaryForKey:@"YTMUltimate"] mutableCopy] ?: [NSMutableDictionary dictionary];
        BOOL changed = NO;
        for (NSDictionary<NSString *, NSNumber *> *seed in @[YTMULGDefaultPreferences(), YTMULGV1DefaultPreferences()]) {
            [seed enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSNumber *value, BOOL *stop) {
                if (p[key] == nil) { p[key] = value; changed = YES; }
            }];
        }
        if (changed) [defaults setObject:p forKey:@"YTMUltimate"];
    }
}
