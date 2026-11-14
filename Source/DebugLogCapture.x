#import <Foundation/Foundation.h>
#import "LyricsShared.h"

// ---------------------------------------------------------------------------
// APP LOG CAPTURE (owner-debug only).
//
// On a device the app's own log is invisible: NSLog output goes to stderr,
// which nobody reads without Xcode, and os_log goes to the unified store that
// this process cannot enumerate in C (OSLogStore is a Swift-only API). Both
// streams do funnel through two exported C functions before anything is
// stored, and a function hook on those sees every line the app writes.
//
// A paired, debug-enabled device sends them into the same buffer as the
// traffic capture (YTMUDebugDeviceNoteLog in Source/DebugDeviceMode.x, which
// owns the consent gate and the per-window budget). Nothing is decoded here:
// NSLog is fully formatted by the hook, while an os_log record keeps its
// FORMAT STRING because the packed argument buffer is a private encoding, not
// text -- the class/endpoint names in that string are the point, the values
// are usually a video id we already have.
//
// INSTALL-TIME GATE: the hooks are only installed when the pref is on
// (Debug page > App log capture). They wrap two functions the app calls from
// launch on, from every thread it has, so a stable install must never pay
// for them -- and a bisect of the on-open crash starts by NOT installing.
// A respring applies the toggle, same as every other launch-time setting.
// ---------------------------------------------------------------------------

// libsystem_trace, no public header: every app that uses the os_log() macro
// links it, because the macro expands to a call to THIS function.
extern void _os_log_impl(void *dso, void *log, unsigned char type, const char *format, void *buf, unsigned int size);

// Two thread-local flags:
//  - inCapture: recording a line must never log (that recursion is unbounded);
//  - forwarding: our NSLog replacement writes through NSLogv, which on modern
//    iOS reaches the unified log again -- that second visit is the same line,
//    so the os_log hook must not record it a second time.
static __thread BOOL g_ytmuLogInCapture = NO;
static __thread BOOL g_ytmuLogForwarding = NO;

static const char *YTMUOSLogTypeName(unsigned char type) {
    switch (type) {
        case 0: return "default";
        case 1: return "info";
        case 2: return "debug";
        case 3: return "error";
        case 4: return "fault";
        default: return "log";
    }
}

static void YTMUCaptureAppLog(NSString *src, NSString *text) {
    if (g_ytmuLogInCapture) return;
    g_ytmuLogInCapture = YES;
    @try {
        YTMUDebugDeviceNoteLog(src, text);
    } @catch (NSException *e) {
    }
    g_ytmuLogInCapture = NO;
}

%group YTMULogCapture

// NSLog(format, ...) is a thin wrapper over NSLogv, so the hook formats the
// line itself and hands the original variadic list to NSLogv -- %orig cannot
// forward `...`, and calling NSLogv (not the hooked symbol) is not recursion.
%hookf(void, NSLog, NSString *format, ...) {
    va_list args, forward;
    va_start(args, format);
    va_copy(forward, args);
    NSString *text = [[NSString alloc] initWithFormat:format ?: @"" arguments:args];
    va_end(args);
    if (text.length) YTMUCaptureAppLog(@"nslog", text);
    g_ytmuLogForwarding = YES;
    NSLogv(format, forward);
    g_ytmuLogForwarding = NO;
    va_end(forward);
}

%hookf(void, _os_log_impl, void *dso, void *log, unsigned char type, const char *format, void *buf, unsigned int size) {
    if (!g_ytmuLogForwarding && format) {
        NSString *text = [NSString stringWithUTF8String:format];
        if (text.length) YTMUCaptureAppLog([NSString stringWithUTF8String:YTMUOSLogTypeName(type)], text);
    }
    %orig;
}

%end

// Install only when the pref says so. Missing key = off: a build that gains
// this file must not change the behaviour of installs that never asked.
%ctor {
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    if ([d[@"sendAppLogCapture"] boolValue]) {
        %init(YTMULogCapture);
    }
}
