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
// %new helpers from SponsorBlock.x: Logos does not make them visible to the
// type checker inside the hook body, so the call sites need the declaration.
- (double)ytmu_introEndInSegments:(NSArray *)segments;
- (void)ytmu_applyLyricsOffsetForVideoID:(NSString *)videoID offset:(double)offset reason:(NSString *)reason;
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
@property (nonatomic, copy) NSString *cachedWordLayoutKey;
@property (nonatomic, strong) NSArray *cachedWordRects;
@property (nonatomic, copy) NSString *lastColorKey;
// Typewriter reveal mask (Source/LyricsStream.x drives it). The label keeps
// its FULL text the whole time, so the row height never changes mid-reveal.
@property (nonatomic, strong) CAGradientLayer *typeMask;
- (void)setWipeProgress:(CGFloat)progress;
- (void)clearWipe;
@end

// (Typewriter) category for the cell -- see the note on the view controller's
// copy below. fraction 0 hides the text, 1 shows all of it.
@interface YTMULyricsCell (Typewriter)
- (void)ytmu_setTypeFraction:(CGFloat)fraction;
- (void)ytmu_clearType;
@end

@interface YTMULyricsViewController : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray *lyrics;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) NSInteger currentIndex;
@property (nonatomic, strong) NSIndexSet *activeIndexes;
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
@property (nonatomic, copy) NSString *displayedVideoID;
@property (nonatomic, strong) UIView *songTintView;
@property (nonatomic, strong) UILabel *fpsLabel;
@property (nonatomic, strong) UIButton *offsetButton;
@property (nonatomic, assign) NSInteger suppressWordSeekRow;
@property (nonatomic, strong) UIView *landscapeArtPanel;
@property (nonatomic, strong) UIImageView *landscapeArtImageView;
@property (nonatomic, strong) UIView *landscapeRightPanel;
@property (nonatomic, strong) UIView *landscapeInfoPanel;
@property (nonatomic, strong) UILabel *landscapeTitleLabel;
@property (nonatomic, strong) UILabel *landscapeArtistLabel;
@property (nonatomic, strong) UIView *landscapeProgressTrack;
@property (nonatomic, strong) UIView *landscapeProgressFill;
@property (nonatomic, strong) UIView *landscapeProgressKnob;
@property (nonatomic, strong) UILabel *landscapeElapsedLabel;
@property (nonatomic, strong) UILabel *landscapeTotalLabel;
@property (nonatomic, strong) UIButton *landscapeExitButton;
@property (nonatomic, strong) UIButton *landscapePrevButton;
@property (nonatomic, strong) UIButton *landscapePlayButton;
@property (nonatomic, strong) UIButton *landscapeNextButton;
@property (nonatomic, strong) UIView *landscapeToolbar;
@property (nonatomic, strong) UIButton *landscapeProviderButton;
@property (nonatomic, strong) UIButton *landscapeReloadButton;
@property (nonatomic, strong) UIButton *headerMenuButton;
@property (nonatomic, copy) NSString *providerJobID;
@property (nonatomic, copy) NSString *providerProbeVideoID;
@property (nonatomic, strong) NSTimer *providerPollTimer;
@property (nonatomic, strong) NSArray *providerCandidates;
@property (nonatomic, assign) NSInteger providerIndex;
@property (nonatomic, strong) NSMutableDictionary *providerCache;
@property (nonatomic, strong) UILabel *providerSwitcherLabel;
@property (nonatomic, strong) UIButton *providerPrevButton;
@property (nonatomic, strong) UIButton *providerNextButton;
@property (nonatomic, copy) NSString *lastProvider;
@property (nonatomic, copy) NSString *lastSongTitle;
@property (nonatomic, copy) NSString *lastSongArtist;
@property (nonatomic, copy) NSString *songMetaVideoID;
@property (nonatomic, copy) NSString *providerMetaVideoID;
@property (nonatomic, copy) NSString *providerDataVideoID;
@property (nonatomic, assign) double clockRawTime;
@property (nonatomic, assign) NSTimeInterval clockRawWall;
@property (nonatomic, assign) BOOL landscapeIsPlaying;
@property (nonatomic, assign) NSInteger fpsTicks;
@property (nonatomic, assign) NSTimeInterval fpsWindowStart;
@property (nonatomic, assign) float lastVolume;
// --- Streaming translation (Source/LyricsStream.x) ---
@property (nonatomic, strong) id tstreamClient;
@property (nonatomic, copy) NSString *tstreamVideoID;
@property (nonatomic, assign) BOOL tstreamGotLyrics;
@property (nonatomic, assign) BOOL tstreamGotFinal;
// Latched when the stream failed and the blocking fetch took over: without it
// a deterministic failure (400 from a bad lang, a dead endpoint) would re-enter
// the stream path forever.
@property (nonatomic, assign) BOOL tstreamFallbackUsed;
// --- Typewriter reveal state, keyed by lyric row ---
@property (nonatomic, strong) NSMutableDictionary *typeState;
@property (nonatomic, strong) NSMutableSet *typeRows;
@property (nonatomic, assign) NSTimeInterval typeLastWall;
- (void)updateLyrics:(NSArray *)newLyrics;
- (void)fetchLyricsForVideo:(NSString *)videoID;
- (void)loadArtworkForVideo:(NSString *)videoID;
- (void)forceReloadLyrics;
- (void)dismissModal;
- (NSString *)wbwDisplayTextForLyric:(NSDictionary *)lyric ranges:(NSArray **)outRanges;
@end

// The five methods below are implemented in Source/LyricsStream.x as
// @implementation YTMULyricsViewController (Typewriter) -- the matching
// YTMULyricsCell (Typewriter) pair is above. They must NOT be declared in the
// primary @interface: a primary declaration obliges EVERY @implementation of
// that class to define the method, and a definition in a category in another
// file does not satisfy it, so LyricsSheet.x fails with
// -Werror,-Wincomplete-implementation. A category declaration carries no such
// requirement, which is why LyricsStream.x forward-declares them the same way.
//
// The PROPERTIES stay in the primary @interface on purpose: clang
// auto-synthesizes their accessors and ivars in LyricsSheet.x, and a property
// declared in a category gets no synthesis at all.
@interface YTMULyricsViewController (Typewriter)
- (void)ytmu_openTranslateStream:(NSString *)videoID jwt:(NSString *)jwt force:(BOOL)force;
- (void)ytmu_cancelTranslateStream;
- (void)ytmu_typeRow:(NSInteger)row activate:(BOOL)activate;
- (void)ytmu_typeResetAll;
- (void)ytmu_typeStep;
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
extern __weak UIViewController *g_activeNowPlayingVC;
extern NSMutableDictionary *g_lyricsCache;
extern NSString *g_globalLoadingVideoID;
extern BOOL g_globalLoadingInFlight;
extern NSDate *g_loadingSince;
extern __weak id g_activeEngagementPanelContainer;

// Everything below is defined in the .x (C) translation units. A .xm file
// (Logos compiles it as C++) that includes this header would otherwise
// reference them with C++ linkage and fail at link time with
// `Undefined symbols ... declaration possibly missing 'extern "C"'`.
#ifdef __cplusplus
extern "C" {
#endif

void YTMUReleaseGlobalFetch(void);
// Device-side RAM store for every provider's lyrics (never persisted).
void YTMUProviderLyricsStore(NSString *videoID, NSArray *entries);
NSArray *YTMUProviderLyricsForProvider(NSString *videoID, NSString *provider);
NSUInteger YTMUProviderLyricsCount(NSString *videoID);
void YTMUProviderLyricsDrop(NSString *videoID);
BOOL YTMULyricsPreference(NSString *key, BOOL fallback);
double YTMULyricsOffsetForVideoID(NSString *videoID);
void YTMULyricsSetOffsetForVideoID(NSString *videoID, double offset);
double YTMULyricsManualOffsetForVideoID(NSString *videoID);
double YTMULyricsSponsorOffsetForVideoID(NSString *videoID);
void YTMULyricsSetSponsorOffsetForVideoID(NSString *videoID, double offset);
NSString *YTMUApiBase(void);
NSString *YTMUTargetLang(void);
NSString *YTMUUrlEncode(NSString *s);
NSString *YTMUAutoZhParam(void);
NSString *YTMULyricsTier(NSArray *lyrics);
void sendDebugLog(NSString *msg);
void sendDebugLogWithPayload(NSString *event, NSString *msg, NSDictionary *payload);
BOOL YTMUDebugUploadAllowed(NSString *level);
BOOL YTMUAppSettingBool(NSString *key, BOOL dflt);
NSString *YTMULyricsCacheDirectory(void);
NSString *YTMULyricsCachePathForVideoID(NSString *vid);
BOOL YTMULyricsCacheEnabled(void);
NSInteger YTMULyricsCacheMaxCount(void);
NSInteger YTMULyricsCacheMaxSizeMB(void);
NSInteger YTMULyricsCacheFormatVersion(void);
NSInteger YTMULyricsCacheVersionForVideoID(NSString *videoID);
void YTMULyricsCacheSave(NSString *videoID, NSArray *lyrics);
BOOL YTMULyricsIsUsable(NSArray *lyrics, NSDictionary *dict);
NSArray *YTMULyricsCacheLoad(NSString *videoID);
NSDictionary *YTMULyricsCacheStats(void);
void YTMULyricsCacheClearAll(void);
NSString *YTMULyricsContentHash(NSString *videoID);
NSArray  *YTMULyricsCacheEntries(void);
void YTMULyricsPrecacheQueue(NSArray *videoIDs, NSString *lang, BOOL useFull);
void YTMUPrefetchProviderLyrics(NSArray *videoIDs, NSString *lang);
// Streaming translation + typewriter reveal. CPS (characters per second) is
// cached because the lyric tick reads it every frame; the settings page calls
// the setter so a change takes effect without a respring.
double YTMUTypewriterCPS(void);
void YTMUTypewriterCPSSet(double cps);
BOOL YTMULyricsStreamTranslateEnabled(void);
// Live snapshot of the streaming path for the Debug settings page.
NSDictionary *YTMUDebugStreamStatus(void);
void YTMUAutoSyncIfDue(void);
NSString *YTMUResolveCurrentVideoID(void);
UIViewController *topMostViewController(void);
BOOL isLyricsEngagementPanel(UIViewController *vc);
BOOL isLyricsViewVisibleOnScreen(void);
void openLyricsFromViewController(UIViewController *parentVC);
void openLyricsFullscreenForLandscape(void);
void YTMURegisterLandscapeAutoOpen(void);
BOOL YTMUIsInterfaceLandscape(void);

UIColor *YTMUAdaptiveInk(CGFloat darkAlpha, CGFloat lightAlpha);
UIColor *YTMUAdaptiveFill(void);
UIColor *YTMUAdaptiveShadow(void);
BOOL YTMUInterfaceIsLight(UIView *v);

#ifdef __cplusplus
}
#endif

#endif
