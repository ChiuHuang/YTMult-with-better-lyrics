#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

static BOOL YTMUShouldPushDebugLogs(void) {
    NSDictionary *settings = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    id value = settings[@"sendDebugLogsToServer"] ?: settings[@"sendLyricsScreenshotDebug"];
    return value ? [value boolValue] : NO;
}

static NSInteger YTMUDebugLogLevel(void) {
    NSDictionary *settings = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    id value = settings[@"debugLogLevel"];
    if (!value) return 1; // default: errors only
    return [value integerValue];
}

static NSString *YTMUISODateString(void) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'";
    return [formatter stringFromDate:[NSDate date]];
}

static void YTMUPushDebugLog(NSString *event, NSString *level, NSString *message, NSDictionary *payload) {
    if (!YTMUShouldPushDebugLogs()) return;

    NSInteger logLevel = YTMUDebugLogLevel();
    if (logLevel == 0) return;
    if ([level isEqualToString:@"error"] && logLevel < 1) return;
    if ([level isEqualToString:@"warn"] && logLevel < 2) return;
    if ([level isEqualToString:@"info"] && logLevel < 3) return;

    NSMutableDictionary *body = [@{
        @"type": @"APP_LOG",
        @"event": event ?: @"unknown",
        @"level": level ?: @"info",
        @"message": message ?: @"",
        @"timestamp": YTMUISODateString()
    } mutableCopy];
    if (payload) {
        body[@"payload"] = payload;
    }

    NSError *jsonError = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonError];
    if (!jsonData || jsonError) return;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://ytmtranslate.chiuhuang.dev/log"];
    req.HTTPMethod = @"POST";
    req.HTTPBody = jsonData;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req] resume];
}

static void YTMUCrashHandler(NSException *exception) {
    YTMUPushDebugLog(@"crash", @"error", exception.reason ?: @"Uncaught exception", @{
        @"name": exception.name ?: @"NSException",
        @"callstack": exception.callStackSymbols ?: @[]
    });
    NSUncaughtExceptionHandler *previous = NSGetUncaughtExceptionHandler();
    if (previous) previous(exception);
}

static void YTMUSignalHandler(int signalNumber) {
    YTMUPushDebugLog(@"signal", @"error", [NSString stringWithFormat:@"Signal %d", signalNumber], @{ @"signal": @(signalNumber) });
    signal(signalNumber, SIG_DFL);
    raise(signalNumber);
}

@interface YTMUTurnstileManager : NSObject <WKScriptMessageHandler>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, copy) NSString *jwtToken;
@property (nonatomic, strong) NSMutableArray *completionHandlers;
+ (instancetype)sharedManager;
- (void)getJWTTokenWithCompletion:(void(^)(NSString *token))completion;
@end

@implementation YTMUTurnstileManager

+ (instancetype)sharedManager {
    static YTMUTurnstileManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[YTMUTurnstileManager alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        static dispatch_once_t crashHookOnce;
        dispatch_once(&crashHookOnce, ^{
            NSSetUncaughtExceptionHandler(&YTMUCrashHandler);
            signal(SIGABRT, YTMUSignalHandler);
            signal(SIGBUS, YTMUSignalHandler);
            signal(SIGILL, YTMUSignalHandler);
            signal(SIGSEGV, YTMUSignalHandler);
            signal(SIGTRAP, YTMUSignalHandler);
        });

        self.completionHandlers = [NSMutableArray array];

        WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
        [config.userContentController addScriptMessageHandler:self name:@"turnstile"];

        self.webView = [[WKWebView alloc] initWithFrame:CGRectMake(-1000, -1000, 300, 300) configuration:config];
        self.webView.hidden = YES;

        dispatch_async(dispatch_get_main_queue(), ^{
            UIWindow *window = [UIApplication sharedApplication].keyWindow;
            if (window) {
                [window addSubview:self.webView];
            }
        });
    }
    return self;
}

- (void)getJWTTokenWithCompletion:(void(^)(NSString *token))completion {
    if (self.jwtToken) {
        YTMUPushDebugLog(@"turnstile", @"info", @"Reusing cached JWT token", @{ @"cached": @YES });
        if (completion) completion(self.jwtToken);
        return;
    }

    void (^safeCompletion)(NSString *) = completion ?: ^(NSString *token) {};
    [self.completionHandlers addObject:[safeCompletion copy]];

    if (self.completionHandlers.count == 1) {
        YTMUPushDebugLog(@"turnstile", @"info", @"Starting Turnstile challenge", @{ @"phase": @"start" });
        NSString *html = @"<html><head><meta name='viewport' content='width=device-width, initial-scale=1.0'></head><body style='margin:0;padding:0;background:#000;'><iframe id='tframe' src='https://lyrics.api.dacubeking.com/challenge' style='width:100%;height:100%;border:none;'></iframe><script>window.addEventListener('message', function(e) { try { if (!e.data || typeof e.data !== 'object') return; if (e.data.type === 'turnstile-token' || e.data.type === 'turnstile-error' || e.data.type === 'turnstile-timeout') { window.webkit.messageHandlers.turnstile.postMessage(e.data); } } catch (err) {} });</script></body></html>";
        [self.webView loadHTMLString:html baseURL:[NSURL URLWithString:@"https://lyrics.api.dacubeking.com/"]];
    }
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if ([message.name isEqualToString:@"turnstile"]) {
        NSDictionary *data = message.body ?: @{};
        NSString *type = data[@"type"] ?: @"unknown";
        YTMUPushDebugLog(@"turnstile", @"info", @"Bridge message received", @{ @"type": type, @"payload": data });

        if ([type isEqualToString:@"turnstile-token"]) {
            NSString *token = data[@"token"];
            NSLog(@"[YTMU-Turnstile] Got token: %@", token);
            YTMUPushDebugLog(@"turnstile", @"info", @"Turnstile token received", @{ @"tokenLength": @(token.length) });
            [self verifyTurnstileToken:token];
        } else if ([type isEqualToString:@"turnstile-error"] || [type isEqualToString:@"turnstile-timeout"]) {
            NSLog(@"[YTMU-Turnstile] Error: %@", data);
            YTMUPushDebugLog(@"turnstile", @"error", @"Turnstile challenge failed", data);
            [self resolveHandlersWithToken:nil];
        }
    }
}

- (void)verifyTurnstileToken:(NSString *)token {
    if (!token || token.length == 0) {
        YTMUPushDebugLog(@"turnstile", @"error", @"Empty Turnstile token", @{});
        [self resolveHandlersWithToken:nil];
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://lyrics.api.dacubeking.com/verify-turnstile"]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSDictionary *body = @{ @"token": token };
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSString *jwtField = json[@"jwt"] ?: json[@"jwtToken"];
            if (jwtField) {
                self.jwtToken = jwtField;
                NSLog(@"[YTMU-Turnstile] Got JWT! (field=%@)", json[@"jwt"] ? @"jwt" : @"jwtToken");
                YTMUPushDebugLog(@"turnstile", @"info", @"JWT verification succeeded", @{ @"field": json[@"jwt"] ? @"jwt" : @"jwtToken", @"tokenLength": @(jwtField.length) });
                [self resolveHandlersWithToken:self.jwtToken];
                return;
            }
            YTMUPushDebugLog(@"turnstile", @"error", @"JWT verification response missing token", json ?: @{});
        } else {
            YTMUPushDebugLog(@"turnstile", @"error", @"JWT verification request failed", @{ @"error": error.localizedDescription ?: @"unknown" });
        }
        NSLog(@"[YTMU-Turnstile] JWT verification failed: %@", error);
        [self resolveHandlersWithToken:nil];
    }] resume];
}

- (void)resolveHandlersWithToken:(NSString *)token {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray *handlers = [self.completionHandlers copy];
        [self.completionHandlers removeAllObjects];
        YTMUPushDebugLog(@"turnstile", @"info", @"Resolving JWT completion handlers", @{ @"handlerCount": @(handlers.count), @"jwtPresent": @(token != nil) });
        for (void(^handler)(NSString *) in handlers) {
            handler(token);
        }
    });
}
@end
