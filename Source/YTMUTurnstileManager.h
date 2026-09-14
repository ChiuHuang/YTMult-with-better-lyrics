#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

@interface YTMUTurnstileManager : NSObject <WKScriptMessageHandler>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, copy) NSString *jwtToken;
@property (nonatomic, strong) NSMutableArray *completionHandlers;
+ (instancetype)sharedManager;
- (void)getJWTTokenWithCompletion:(void(^)(NSString *token))completion;
@end
