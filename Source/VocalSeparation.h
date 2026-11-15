#import <Foundation/Foundation.h>
#import <CoreML/CoreML.h>

typedef NS_ENUM(NSInteger, YTMUVocalSeparationMode) {
    YTMUVocalSeparationModeVocalOnly = 0,
    YTMUVocalSeparationModeNormal = 1,
    YTMUVocalSeparationModeBackgroundOnly = 2,
};

@interface YTMUVocalSeparationManager : NSObject
@property (atomic, strong, readonly) MLModel *coreMLModel;
@property (atomic, assign, readonly) BOOL isModelReady;
@property (atomic, assign, readonly) BOOL isModelLoading;
@property (atomic, strong, readonly) NSError *modelLoadError;
@property (nonatomic, assign) float vocalVolume;
@property (nonatomic, assign) float backgroundVolume;
@property (nonatomic, assign, readonly) BOOL isSingEnabled;
@property (nonatomic, assign) YTMUVocalSeparationMode selectedMode;

+ (instancetype)sharedInstance;
- (NSString *)modelPackagePath;
- (BOOL)hasModelOnDisk;
- (void)loadModelIfAvailableWithCompletion:(void (^)(BOOL ready, NSError *error))completion;
@end
