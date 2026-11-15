#import <Foundation/Foundation.h>
#import <CoreML/CoreML.h>
#import "YTMUMDXSeparator.h"

typedef NS_ENUM(NSInteger, YTMUVocalSeparationMode) {
    YTMUVocalSeparationModeVocalOnly = 0,
    YTMUVocalSeparationModeNormal = 1,
    YTMUVocalSeparationModeBackgroundOnly = 2,
};

@interface YTMUVocalSeparationManager : NSObject
@property (atomic, strong, readonly) MLModel *coreMLModel;
@property (atomic, strong, readonly) YTMUMDXSeparator *separator;
@property (atomic, assign, readonly) BOOL isModelReady;
@property (atomic, assign, readonly) BOOL isModelLoading;
@property (atomic, strong, readonly) NSError *modelLoadError;
@property (atomic, assign) float vocalVolume;
@property (atomic, assign) float backgroundVolume;
@property (atomic, assign, readonly) BOOL isSingEnabled;
@property (nonatomic, assign) YTMUVocalSeparationMode selectedMode;

+ (instancetype)sharedInstance;
- (NSString *)modelPackagePath;
- (BOOL)hasModelOnDisk;
- (void)loadModelIfAvailableWithCompletion:(void (^)(BOOL ready, NSError *error))completion;
@end
