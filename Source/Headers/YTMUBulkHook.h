// Swizzle one selector across a list of class names, at runtime.
//
// Why this exists: the Liquid Glass V2 files originally wrapped %hook in a
// macro (S(YTMLoadingView) S(YTMEmptyStateView) ...). %hook is expanded
// TEXTUALLY by the Logos preprocessor, so every expansion produced the SAME
// generated symbol (_logos_method$_ungrouped$C$layoutSubviews) and the SAME
// objc_getClass("C") -- twelve duplicate symbols and a class that does not
// exist. Logos only works with a literal class name, so any list-shaped hook
// has to be done at runtime instead.
//
// Call through YTMUCallOrig, never a Logos %orig: there is no %orig here.
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
// runtime (NSClassFromString, method_getImplementation, method_setImplementation,
// class_getSuperclass) and message (SEL). Kept in this order: UIKit first so
// <objc/message.h> cannot clash with it on older SDKs.
#import <objc/runtime.h>
#import <objc/message.h>

// The whole body is guarded, NOT just the two accessors. Three .xm files
// include this header into one binary, and a `static inline` function that
// escapes the guard becomes three definitions of the same name -- fine in
// each object file, a duplicate-symbol error at link.
#ifndef YTMU_BULKHOOK_H
#define YTMU_BULKHOOK_H

// Class(NSValue of the Class pointer) -> { selectorName -> NSValue of IMP }
static inline NSMutableDictionary *YTMUBulkHookOrigs(void) {
    static NSMutableDictionary *origs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ origs = [NSMutableDictionary dictionary]; });
    return origs;
}

// Class(NSValue of Class) -> { @"key": featureKeyOrRadius }
static inline NSMutableDictionary *YTMUBulkHookClassKeys(void) {
    static NSMutableDictionary *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ keys = [NSMutableDictionary dictionary]; });
    return keys;
}

static inline void YTMUBulkHook(NSArray<NSString *> *classNames, SEL sel, IMP replacement) {
    NSString *selName = NSStringFromSelector(sel);
    NSMutableDictionary *origs = YTMUBulkHookOrigs();
    for (NSString *name in classNames) {
        Class cls = NSClassFromString(name);
        if (!cls) continue;                       // class not in this YT build
        // Already hooked: swapping again would chain the replacement to
        // itself and recurse on the first layout pass.
        if (origs[[NSValue valueWithPointer:(__bridge const void *)cls]]) continue;
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) continue;
        NSMutableDictionary *perClass = [NSMutableDictionary dictionary];
        // The cast to `const void *` is REQUIRED, not cosmetic. These files
        // are .xm, so they compile as Objective-C++ where an IMP (a function
        // pointer) will not implicitly convert to `const void *`.
        perClass[selName] = [NSValue valueWithPointer:(const void *)method_getImplementation(m)];
        origs[[NSValue valueWithPointer:(__bridge const void *)cls]] = perClass;
        method_setImplementation(m, replacement);
    }
}

// The original IMP for `obj`, walking up the hierarchy: a hooked superclass
// still counts when the runtime hands us a subclass instance.
static inline IMP YTMUOrigIMPFor(id obj, SEL sel) {
    NSMutableDictionary *origs = YTMUBulkHookOrigs();
    NSString *selName = NSStringFromSelector(sel);
    for (Class c = [obj class]; c; c = class_getSuperclass(c)) {
        NSMutableDictionary *perClass = origs[[NSValue valueWithPointer:(__bridge const void *)c]];
        NSValue *v = perClass[selName];
        if (v) return (IMP)v.pointerValue;
    }
    return NULL;
}

static inline void YTMUCallOrig(id obj, SEL sel) {
    IMP orig = YTMUOrigIMPFor(obj, sel);
    if (!orig) return;
    ((void (*)(id, SEL))orig)(obj, sel);
}

// Per-class extra data (a feature key, a corner radius), recorded at hook
// time so the shared replacement body can look it up from `self`.
static inline void YTMUBulkHookSetKey(NSString *className, NSString *key) {
    Class cls = NSClassFromString(className);
    if (!cls) return;
    NSMutableDictionary *d = YTMUBulkHookClassKeys();
    d[[NSValue valueWithPointer:(__bridge const void *)cls]] = @{@"key": key};
}

static inline NSString *YTMUBulkHookKeyFor(id obj) {
    NSMutableDictionary *d = YTMUBulkHookClassKeys();
    for (Class c = [obj class]; c; c = class_getSuperclass(c)) {
        NSDictionary *e = d[[NSValue valueWithPointer:(__bridge const void *)c]];
        NSString *k = e[@"key"];
        if (k) return k;
    }
    return nil;
}

#endif  // YTMU_BULKHOOK_H
