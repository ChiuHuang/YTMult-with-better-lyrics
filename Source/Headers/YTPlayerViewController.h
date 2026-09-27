#import <UIKit/UIKit.h>
#import "YTPlayerResponse.h"

@interface YTPlayerViewController : UIViewController
@property (nonatomic, assign, readonly) YTPlayerResponse *playerResponse;
@property (readonly, nonatomic) NSString *contentVideoID;
@property (nonatomic, assign, readonly) CGFloat currentVideoTotalMediaTime;
@property (nonatomic, strong) NSMutableDictionary *sponsorBlockValues;

- (void)seekToTime:(CGFloat)time;
- (NSString *)currentVideoID;
- (CGFloat)currentVideoMediaTime;
- (void)skipSegment;
- (double)ytmu_introEndInSegments:(NSArray *)segments;
- (void)ytmu_applyLyricsOffsetForVideoID:(NSString *)videoID offset:(double)offset reason:(NSString *)reason;
- (void)pause;
- (void)play;
- (void)togglePlayPause;
@end
