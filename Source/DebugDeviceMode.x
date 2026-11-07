#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "LyricsShared.h"

// ---------------------------------------------------------------------------
// DEBUG DEVICE MODE.
//
// A device may only push captured traffic to the server after the operator
// generated a one-time code on the dashboard and the code was typed in HERE.
// That is the whole consent model: nothing uploads because the tweak feels
// like it -- an enrolled device is something a human deliberately paired, and
// a normal user cannot upload at all (no code, no token).
//
// What is captured is the app's OWN requests (method + URL, no bodies, no
// cookies, no headers). That is the useful half for this project: it answers
// "which endpoint does YT actually hit" and "did the audio stream URL ever
// appear", which is exactly what the download capture depends on. It does NOT
// proxy or rewrite the app's traffic -- a relay would change what the app
// sees, and nothing here is allowed to change playback.
// ---------------------------------------------------------------------------

static NSString *const kYTMUDebugTokenKey = @"YTMUDebugDeviceToken";
static NSString *const kYTMUDebugDeviceIDKey = @"YTMUDebugDeviceID";
static NSString *const kYTMUDebugPrefKey = @"debugDeviceMode";

static const NSUInteger kYTMUDebugBufferMax = 200;
static const NSTimeInterval kYTMUDebugFlushInterval = 15.0;
static const NSUInteger kYTMUDebugURLLimit = 900;

static NSMutableArray *YTMUDebugRecords(void) {
    static NSMutableArray *records;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ records = [NSMutableArray array]; });
    return records;
}

static NSUInteger g_ytmuDebugSent = 0;
static NSString *g_ytmuDebugLastError = nil;
static NSString *g_ytmuDebugLastSent = nil;

static BOOL YTMUDebugHasToken(void) {
    return [[NSUserDefaults standardUserDefaults] stringForKey:kYTMUDebugTokenKey].length > 0;
}

BOOL YTMUDebugDeviceEnabled(void) {
    NSDictionary *settings = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    return [settings[kYTMUDebugPrefKey] boolValue];
}

// Our own upload/enroll calls must never be captured: they point at the API
// base, which is also where they would land again.
static BOOL YTMUDebugSkipURL(NSString *url) {
    if (!url.length) return YES;
    NSString *base = YTMUApiBase();
    if (base.length && [url hasPrefix:base]) return YES;
    return NO;
}

static void YTMUDebugFlush(void);

static void YTMUDebugStartFlushTimer(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            // Block form: a selector timer would retain its target forever.
            [NSTimer scheduledTimerWithTimeInterval:kYTMUDebugFlushInterval repeats:YES block:^(NSTimer *timer) {
                YTMUDebugFlush();
            }];
        });
    });
}

static void YTMUDebugFlush(void) {
    if (!YTMUDebugDeviceEnabled()) return;
    NSString *token = [[NSUserDefaults standardUserDefaults] stringForKey:kYTMUDebugTokenKey];
    if (!token.length) return;
    NSArray *batch = nil;
    NSMutableArray *records = YTMUDebugRecords();
    @synchronized(records) {
        if (!records.count) return;
        batch = [records copy];
        [records removeAllObjects];
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"records": batch} options:0 error:nil];
    if (!json) return;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:[NSString stringWithFormat:@"%@/api/debug/upload", YTMUApiBase()]]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 20;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:token forHTTPHeaderField:@"X-YTMU-Debug-Token"];
    request.HTTPBody = json;
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]]
            ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (status == 401) {
            // Revoked or unknown token: forget it so the device stops trying.
            // A refusal (403) is not this: that would mean "known device, not
            // allowed", which this route never answers for a token it took.
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:kYTMUDebugTokenKey];
            NSLog(@"[YTMU-DEBUG] token rejected (401), forgotten");
            return;
        }
        if (error || status >= 400) {
            g_ytmuDebugLastError = [NSString stringWithFormat:@"%ld %@", (long)status, error.localizedDescription ?: @""];
            NSLog(@"[YTMU-DEBUG] upload failed: %@", g_ytmuDebugLastError);
            return;
        }
        g_ytmuDebugSent += batch.count;
        g_ytmuDebugLastError = nil;
        g_ytmuDebugLastSent = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                            dateStyle:NSDateFormatterNoStyle
                                                            timeStyle:NSDateFormatterMediumStyle];
        NSLog(@"[YTMU-DEBUG] uploaded %lu record(s)", (unsigned long)batch.count);
    }] resume];
}

// One probe the operator asked for (see YTMUDebugProbeRuntime in
// Downloading.x): posts immediately, not on the next 15s tick, because the
// operator is sitting on the badge tap waiting for this exact record. The
// payload is runtime metadata only -- class and member names -- and still
// reaches the server only through the same paired-device token as traffic.
void YTMUDebugDeviceNoteProbe(NSString *label, NSString *vid, NSDictionary *payload) {
    if (!YTMUDebugDeviceEnabled() || !YTMUDebugHasToken()) return;
    @try {
        NSDictionary *record = @{
            @"t": [NSDate date].description ?: @"",
            @"kind": @"probe",
            @"m": @"PROBE",
            @"u": [NSString stringWithFormat:@"probe://%@", label ?: @"runtime"],
            @"vid": vid ?: @"",
            @"d": payload ?: @{},
        };
        NSMutableArray *records = YTMUDebugRecords();
        @synchronized(records) { [records addObject:record]; }
        YTMUDebugStartFlushTimer();
        YTMUDebugFlush();
    } @catch (NSException *e) {
    }
}

// Called from the transport hooks only, and cheap by construction: disabled or
// unenrolled devices pay one NSUserDefaults read per request and nothing else.
void YTMUDebugDeviceNoteRequest(NSURL *url, NSString *method) {
    @try {
        if (!YTMUDebugDeviceEnabled() || !YTMUDebugHasToken()) return;
        NSString *full = url.absoluteString;
        if (YTMUDebugSkipURL(full)) return;
        if (full.length > kYTMUDebugURLLimit) full = [full substringToIndex:kYTMUDebugURLLimit];
        NSDictionary *record = @{
            @"t": [NSDate date].description ?: @"",
            @"m": method.length ? method : @"GET",
            @"u": full,
            @"vid": g_currentVideoID ?: @"",
        };
        NSMutableArray *records = YTMUDebugRecords();
        @synchronized(records) {
            [records addObject:record];
            if (records.count > kYTMUDebugBufferMax) {
                [records removeObjectsInRange:NSMakeRange(0, records.count - kYTMUDebugBufferMax)];
            }
        }
        YTMUDebugStartFlushTimer();
    } @catch (NSException *e) {
    }
}

// The enrolled token itself, for the one purpose the dashboard cannot serve
// (the server stores only its hash): the user copies it from the Debug page
// and uses it as the credential of the read endpoint
// (GET /api/debug/fetch, X-YTMU-Debug-Token) to pull the device capture and
// the server log tail from anywhere. Only answers when a token is at all.
NSString *YTMUDebugDeviceToken(void) {
    return [[NSUserDefaults standardUserDefaults] stringForKey:kYTMUDebugTokenKey] ?: @"";
}

NSDictionary *YTMUDebugDeviceStatus(void) {
    NSUInteger pending = 0;
    NSMutableArray *records = YTMUDebugRecords();
    @synchronized(records) { pending = records.count; }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *deviceID = [defaults stringForKey:kYTMUDebugDeviceIDKey];
    return @{
        @"on": @(YTMUDebugDeviceEnabled()),
        @"token": YTMUDebugHasToken() ? @"enrolled" : @"none",
        @"device": deviceID.length ? deviceID : @"",
        @"pending": @(pending),
        @"sent": @(g_ytmuDebugSent),
        @"error": g_ytmuDebugLastError ?: @"",
        @"last": g_ytmuDebugLastSent ?: @"",
    };
}

void YTMUDebugDeviceSetEnabled(BOOL on) {
    NSMutableDictionary *settings = [NSMutableDictionary dictionaryWithDictionary:
        [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"] ?: @{}];
    settings[kYTMUDebugPrefKey] = @(on);
    [[NSUserDefaults standardUserDefaults] setObject:settings forKey:@"YTMUltimate"];
    if (on) YTMUDebugStartFlushTimer();
}

void YTMUDebugDeviceForget(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults removeObjectForKey:kYTMUDebugTokenKey];
    [defaults removeObjectForKey:kYTMUDebugDeviceIDKey];
    NSMutableArray *records = YTMUDebugRecords();
    @synchronized(records) { [records removeAllObjects]; }
    NSLog(@"[YTMU-DEBUG] device token forgotten");
}

void YTMUDebugDeviceEnroll(NSString *otp, void (^done)(BOOL ok, NSString *message)) {
    NSString *code = [(otp ?: @"") stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (code.length != 6) {
        if (done) done(NO, @"6 digits");
        return;
    }
#ifndef TWEAK_BUILD
#define TWEAK_BUILD 0
#endif
    UIDevice *device = [UIDevice currentDevice];
    NSDictionary *body = @{
        @"otp": code,
        @"name": device.name ?: @"device",
        @"ios": device.systemVersion ?: @"",
        @"build": [NSString stringWithFormat:@"%d", TWEAK_BUILD],
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if (!json) {
        if (done) done(NO, @"encode failed");
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:[NSString stringWithFormat:@"%@/api/debug/enroll", YTMUApiBase()]]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 20;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = json;
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]]
            ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSDictionary *parsed = nil;
        if (data.length) {
            id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([object isKindOfClass:[NSDictionary class]]) parsed = (NSDictionary *)object;
        }
        NSString *token = [parsed[@"token"] isKindOfClass:[NSString class]] ? parsed[@"token"] : nil;
        NSString *deviceID = [parsed[@"id"] isKindOfClass:[NSString class]] ? parsed[@"id"] : nil;
        NSString *reason = [parsed[@"error"] isKindOfClass:[NSString class]] ? parsed[@"error"] : nil;
        if (token.length) {
            NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
            [defaults setObject:token forKey:kYTMUDebugTokenKey];
            if (deviceID.length) [defaults setObject:deviceID forKey:kYTMUDebugDeviceIDKey];
            NSLog(@"[YTMU-DEBUG] enrolled as %@ (HTTP %ld)", deviceID ?: @"?", (long)status);
            if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(YES, deviceID ?: @""); });
            return;
        }
        NSString *message = reason.length ? reason : (error.localizedDescription ?: [NSString stringWithFormat:@"HTTP %ld", (long)status]);
        NSLog(@"[YTMU-DEBUG] enroll refused: %@", message);
        if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(NO, message); });
    }] resume];
}

// NOTE: this file deliberately installs NO hook. The transport observation
// lives in ONE place -- Source/Downloading.x, which hooks NSURLSession and
// AVURLAsset and calls YTMUDownloadCaptureStreamURL (its own audio-stream
// capture) plus YTMUDebugDeviceNoteRequest (this buffer). Two files hooking
// the same selector would be a chain of two replacements where one is enough,
// and the download capture has to run whether or not debug mode is on.
