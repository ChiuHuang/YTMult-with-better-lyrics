#ifndef LyricsShared_h
#define LyricsShared_h

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "YTMUTurnstileManager.h"
#import "Headers/YTPlayerViewController.h"
#import "Headers/YTIButtonRenderer.h"
#import "Headers/YTMNowPlayingViewController.h"
#import "Headers/ELMNodeController.h"
#import "Headers/YTMActionRowView.h"

#ifndef TWEAK_GIT_COMMIT
#define TWEAK_GIT_COMMIT "unknown"
#endif

@interface UIView ()
- (UIViewController *)_viewControllerForAncestor;
@end

@interface ELMTouchCommandPropertiesHandler : NSObject
- (void)handleTap;
@end

@interface YTIButtonRenderer ()
- (BOOL)isDisabled;
@end

@interface YTMNowPlayingViewController (YTMULyrics)
- (void)ytmu_makeLyricsViewClickable:(UIView *)v;
- (void)ytmu_didTapLyricsBar:(UITapGestureRecognizer *)gesture;
- (BOOL)ytmu_replaceLyricsChip:(UIView *)official;
@end

@interface YTPlayerViewController (YTMUExt)
- (double)currentMediaTime;
- (void)seekToTime:(double)time toleranceBefore:(double)before toleranceAfter:(double)after;
@end

@interface YTFormattedStringLabel : UILabel
@end

@interface YTMLightweightMusicDescriptionShelfCell : UIView
@property (retain, nonatomic) UITextView *lyrics;
@end

@interface YTMULyricsCell : UITableViewCell
@property (nonatomic, strong) UILabel *lyricLabel;
@property (nonatomic, strong) UILabel *transLabel;
@property (nonatomic, strong) UILabel *wipeLabel;
@property (nonatomic, strong) CAShapeLayer *wipeMask;
@property (nonatomic, assign) CGFloat wipeProgress;
- (void)setWipeProgress:(CGFloat)progress;
- (void)clearWipe;
@end

@interface YTMULyricsViewController : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray *lyrics;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) NSInteger currentIndex;
@property (nonatomic, assign) BOOL isLoading;
@property (nonatomic, copy) NSString *loadingVideoID;
@property (nonatomic, strong) UIImageView *artworkImageView;
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIView *darkOverlay;
@property (nonatomic, assign) BOOL isModal;
@property (nonatomic, assign) BOOL isSynced;
@property (nonatomic, strong) NSString *lastColorKey;
@property (nonatomic, copy) NSString *cachedWordLayoutKey;
@property (nonatomic, strong) NSArray *cachedWordRects;
@property (nonatomic, strong) NSDate *loadingSince;
@property (nonatomic, copy) NSString *artworkVideoID;
@property (nonatomic, strong) UILabel *fpsLabel;
@property (nonatomic, strong) UIButton *offsetButton;
@property (nonatomic, assign) NSInteger suppressWordSeekRow;
@property (nonatomic, assign) NSInteger fpsTicks;
@property (nonatomic, assign) NSTimeInterval fpsWindowStart;
@property (nonatomic, assign) float lastVolume;
- (void)updateLyrics:(NSArray *)newLyrics;
- (void)fetchLyricsForVideo:(NSString *)videoID;
- (void)loadArtworkForVideo:(NSString *)videoID;
- (void)forceReloadLyrics;
- (void)dismissModal;
- (NSString *)wbwDisplayTextForLyric:(NSDictionary *)lyric ranges:(NSArray **)outRanges;
@end

@interface YTPlayerViewController (YTMU_Lyrics)
- (CGFloat)currentVideoMediaTime;
@end

@interface YTMNowPlayingViewController (YTMU_Lyrics)
- (void)ytmu_keepLyricsButtonActive;
- (void)ytmu_makeLyricsViewClickable:(UIView *)v;
- (void)ytmu_didTapLyricsButtonAction:(id)sender;
- (void)ytmu_didTapLyricsBar:(UITapGestureRecognizer *)gesture;
@end

extern double g_currentPlaybackTime;
extern NSString *g_currentVideoID;
extern __weak YTPlayerViewController *g_activePlayer;
extern __weak UIButton *g_ytmuOwnLyricsButton;
extern NSMutableDictionary *g_lyricsCache;
extern NSString *g_globalLoadingVideoID;
extern BOOL g_globalLoadingInFlight;
extern NSDate *g_loadingSince;
extern __weak id g_activeEngagementPanelContainer;

void YTMUReleaseGlobalFetch(void);
BOOL YTMULyricsPreference(NSString *key, BOOL fallback);
double YTMULyricsOffsetForVideoID(NSString *videoID);
void YTMULyricsSetOffsetForVideoID(NSString *videoID, double offset);
NSString *YTMUApiBase(void);
NSString *YTMUTargetLang(void);
NSString *YTMUUrlEncode(NSString *s);
NSString *YTMUAutoZhParam(void);
NSString *YTMULyricsTier(NSArray *lyrics);
void sendDebugLog(NSString *msg);
void sendDebugLogWithPayload(NSString *event, NSString *msg, NSDictionary *payload);
NSString *YTMULyricsCacheDirectory(void);
NSString *YTMULyricsCachePathForVideoID(NSString *vid);
BOOL YTMULyricsCacheEnabled(void);
NSInteger YTMULyricsCacheMaxCount(void);
NSInteger YTMULyricsCacheMaxSizeMB(void);
NSInteger YTMULyricsCacheFormatVersion(void);
NSInteger YTMULyricsCacheVersionForVideoID(NSString *videoID);
void YTMULyricsCacheSave(NSString *videoID, NSArray *lyrics);
NSArray *YTMULyricsCacheLoad(NSString *videoID);
NSDictionary *YTMULyricsCacheStats(void);
void YTMULyricsCacheClearAll(void);
void YTMULyricsPrecacheQueue(NSArray *videoIDs, NSString *lang, BOOL useFull);
NSString *YTMUResolveCurrentVideoID(void);
UIViewController *topMostViewController(void);
BOOL isLyricsEngagementPanel(UIViewController *vc);
BOOL isLyricsViewVisibleOnScreen(void);
void openLyricsFromViewController(UIViewController *parentVC);

UIColor *YTMUAdaptiveInk(CGFloat darkAlpha, CGFloat lightAlpha);
UIColor *YTMUAdaptiveFill(void);
UIColor *YTMUAdaptiveShadow(void);
BOOL YTMUInterfaceIsLight(UIView *v);

#endif
