#import <Foundation/Foundation.h>
#import <CoreML/CoreML.h>

NS_ASSUME_NONNULL_BEGIN

// One fixed MDX23C window: 5.92 seconds at 44.1 kHz.
enum {
    YTMUMDXSampleRate = 44100,
    YTMUMDXFFTSize = 8192,
    YTMUMDXHopSize = 1024,
    YTMUMDXBinCount = 4096,
    YTMUMDXFrameCount = 256,
    YTMUMDXWindowFrames = 261120,
};

@interface YTMUMDXSeparator : NSObject
- (nullable instancetype)initWithModel:(MLModel *)model error:(NSError * _Nullable * _Nullable)error;

// Model inference is deliberately an off-render-thread operation. `input` is
// interleaved stereo PCM at 44.1 kHz; the four outputs are planar stems.
- (BOOL)separateInterleavedStereo:(const float *)input
                            frames:(NSUInteger)frames
                        vocalsLeft:(float *)vocalsLeft
                       vocalsRight:(float *)vocalsRight
                  instrumentalLeft:(float *)instrumentalLeft
                 instrumentalRight:(float *)instrumentalRight
                             error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
