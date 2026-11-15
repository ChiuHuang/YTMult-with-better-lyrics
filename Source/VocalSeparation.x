#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreML/CoreML.h>
#import <Accelerate/Accelerate.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import "LyricsShared.h"
#import "Headers/YTMNowPlayingView.h"
#import "VocalSeparation.h"

// The audio-stage architecture is informed by Vitrine (Clone5030/vitrine,
// GPL-3.0); this YTMusic implementation is independently written. This
// repository's GPL-3.0 license applies to this file as well.
static NSString *const YTMUVocalSeparationModelDidChange = @"YTMUVocalSeparationModelDidChange";
static NSString *const YTMUVocalSeparationModeDidChange = @"YTMUVocalSeparationModeDidChange";

@interface YTMUVocalSeparationManager ()
@property (atomic, strong, readwrite) MLModel *coreMLModel;
@property (atomic, strong, readwrite) YTMUMDXSeparator *separator;
@property (atomic, assign, readwrite) BOOL isModelReady;
@property (atomic, assign, readwrite) BOOL isModelLoading;
@property (atomic, strong, readwrite) NSError *modelLoadError;
@end

@implementation YTMUVocalSeparationManager

+ (instancetype)sharedInstance {
    static YTMUVocalSeparationManager *s_instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_instance = [[self alloc] init];
    });
    return s_instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _vocalVolume = 1.0f;
        _backgroundVolume = 1.0f;
        NSNumber *savedMode = [[NSUserDefaults standardUserDefaults] objectForKey:@"YTMUVocalSeparationMode"];
        _selectedMode = savedMode ? (YTMUVocalSeparationMode)MIN(2, MAX(0, savedMode.integerValue)) : YTMUVocalSeparationModeNormal;
        [self setSelectedMode:_selectedMode];
        [self checkModelStatus];
    }
    return self;
}

- (void)setSelectedMode:(YTMUVocalSeparationMode)selectedMode {
    YTMUVocalSeparationMode nextMode = (YTMUVocalSeparationMode)MIN(2, MAX(0, selectedMode));
    BOOL changed = _selectedMode != nextMode;
    _selectedMode = nextMode;
    // These gains are consumed by the separator's output mix once the player
    // audio stage is attached: vocals-only, original, background-only.
    self.vocalVolume = _selectedMode == YTMUVocalSeparationModeBackgroundOnly ? 0.0f : 1.0f;
    self.backgroundVolume = _selectedMode == YTMUVocalSeparationModeVocalOnly ? 0.0f : 1.0f;
    [[NSUserDefaults standardUserDefaults] setInteger:_selectedMode forKey:@"YTMUVocalSeparationMode"];
    if (changed) [[NSNotificationCenter defaultCenter] postNotificationName:YTMUVocalSeparationModeDidChange object:self];
}

- (BOOL)isSingEnabled {
    return self.isModelReady && self.selectedMode != YTMUVocalSeparationModeNormal;
}

- (NSString *)modelDirectoryPath {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *base = [paths firstObject];
    NSString *dir = [base stringByAppendingPathComponent:@"YTMUltimate"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

- (NSString *)modelPackagePath {
    return [[self modelDirectoryPath] stringByAppendingPathComponent:@"mdx23c_instvoc_hq.mlpackage"];
}

- (NSString *)compiledModelPath {
    return [[self modelDirectoryPath] stringByAppendingPathComponent:@"mdx23c_instvoc_hq.mlmodelc"];
}

- (BOOL)hasModelOnDisk {
    NSString *compiled = [self compiledModelPath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:compiled]) return YES;
    NSString *pkg = [self modelPackagePath];
    return [[NSFileManager defaultManager] fileExistsAtPath:pkg];
}

- (void)checkModelStatus {
    if (![self hasModelOnDisk]) return;
    [self loadModelIfAvailableWithCompletion:nil];
}

- (BOOL)loadOrCompileModel:(NSError **)loadError {
    NSString *compiled = [self compiledModelPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;
    NSURL *modelURL = nil;

    if ([fm fileExistsAtPath:compiled]) {
        modelURL = [NSURL fileURLWithPath:compiled];
    } else {
        NSString *pkg = [self modelPackagePath];
        if ([fm fileExistsAtPath:pkg]) {
            NSURL *pkgURL = [NSURL fileURLWithPath:pkg];
            NSURL *tempCompiledURL = [MLModel compileModelAtURL:pkgURL error:&error];
            if (!error && tempCompiledURL) {
                NSURL *destURL = [NSURL fileURLWithPath:compiled];
                [fm removeItemAtURL:destURL error:nil];
                [fm moveItemAtURL:tempCompiledURL toURL:destURL error:&error];
                if (!error) modelURL = destURL;
            }
        }
    }

    if (modelURL) {
        MLModelConfiguration *config = [[MLModelConfiguration alloc] init];
        config.computeUnits = MLComputeUnitsAll; // Use ANE + GPU + CPU
        MLModel *model = [MLModel modelWithContentsOfURL:modelURL configuration:config error:&error];
        if (model) {
            YTMUMDXSeparator *separator = [[YTMUMDXSeparator alloc] initWithModel:model error:&error];
            if (separator) {
                self.coreMLModel = model;
                self.separator = separator;
            }
        }
    }
    if (loadError) *loadError = error;
    self.isModelReady = (self.separator != nil);
    return self.isModelReady;
}

- (void)loadModelIfAvailableWithCompletion:(void (^)(BOOL ready, NSError *error))completion {
    if (self.isModelLoading) return;
    self.isModelLoading = YES;
    self.modelLoadError = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        BOOL ready = [self loadOrCompileModel:&error];
        self.modelLoadError = error;
        self.isModelLoading = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:YTMUVocalSeparationModelDidChange object:self];
            if (completion) completion(ready, error);
        });
    });
}

@end

// A right-edge player control that stays as a small mic button until opened.
// The chosen mode is centred on Normal; the two separated stems sit either side.
@interface YTMUVocalSeparationBar : UIView
@property (nonatomic, assign, getter=isExpanded) BOOL expanded;
- (void)layoutForPlayerSize:(CGSize)size;
@end

@implementation YTMUVocalSeparationBar {
    UIVisualEffectView *_panel;
    UIButton *_handle;
    UIButton *_close;
    UILabel *_title;
    NSArray<UIButton *> *_modeButtons;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.clipsToBounds = NO;

    _panel = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
    _panel.layer.cornerRadius = 24;
    _panel.layer.cornerCurve = kCACornerCurveContinuous;
    _panel.layer.masksToBounds = YES;
    _panel.layer.borderWidth = 1;
    _panel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    _panel.hidden = YES;
    [self addSubview:_panel];

    _title = [[UILabel alloc] init];
    _title.text = @"SING";
    _title.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    _title.textColor = UIColor.whiteColor;
    [_panel.contentView addSubview:_title];

    _close = [UIButton buttonWithType:UIButtonTypeSystem];
    [_close setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
    _close.tintColor = [UIColor colorWithWhite:1 alpha:0.78];
    [_close addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventTouchUpInside];
    [_panel.contentView addSubview:_close];

    NSArray *labels = @[@"Vocals only", @"Normal", @"Background only"];
    NSMutableArray *buttons = [NSMutableArray arrayWithCapacity:labels.count];
    [labels enumerateObjectsUsingBlock:^(NSString *label, NSUInteger idx, BOOL *stop) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = (NSInteger)idx;
        button.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        button.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 8);
        button.layer.cornerRadius = 13;
        button.layer.cornerCurve = kCACornerCurveContinuous;
        [button setTitle:label forState:UIControlStateNormal];
        [button setTitleColor:[UIColor colorWithWhite:1 alpha:0.76] forState:UIControlStateNormal];
        [button addTarget:self action:@selector(modePicked:) forControlEvents:UIControlEventTouchUpInside];
        [_panel.contentView addSubview:button];
        [buttons addObject:button];
    }];
    _modeButtons = buttons;

    _handle = [UIButton buttonWithType:UIButtonTypeSystem];
    [_handle setImage:[UIImage systemImageNamed:@"mic.fill"] forState:UIControlStateNormal];
    _handle.tintColor = UIColor.whiteColor;
    _handle.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.9];
    _handle.layer.cornerRadius = 25;
    _handle.layer.cornerCurve = kCACornerCurveContinuous;
    _handle.layer.borderWidth = 1;
    _handle.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.22].CGColor;
    _handle.layer.shadowColor = UIColor.blackColor.CGColor;
    _handle.layer.shadowOpacity = 0.24;
    _handle.layer.shadowRadius = 12;
    _handle.layer.shadowOffset = CGSizeMake(0, 4);
    [_handle addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_handle];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(modelDidChange:)
                                                 name:YTMUVocalSeparationModelDidChange object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(modelDidChange:)
                                                 name:YTMUVocalSeparationModeDidChange object:nil];
    [self refreshSelection];
    return self;
}

- (void)layoutForPlayerSize:(CGSize)size {
    CGFloat width = self.isExpanded ? 196 : 52;
    CGFloat height = self.isExpanded ? 176 : 52;
    CGFloat top = MAX(80, MIN(size.height - height - 80, size.height * 0.52 - height * 0.5));
    self.frame = CGRectMake(size.width - width - 10, top, width, height);
    _handle.frame = CGRectMake(width - 52, (height - 52) * 0.5, 52, 52);
    _panel.frame = self.bounds;
    _title.frame = CGRectMake(16, 11, 100, 24);
    _close.frame = CGRectMake(width - 46, 8, 34, 30);
    for (NSUInteger i = 0; i < _modeButtons.count; i++) {
        _modeButtons[i].frame = CGRectMake(10, 43 + (CGFloat)i * 40, width - 20, 36);
    }
    [self refreshSelection];
}

- (void)modelDidChange:(NSNotification * __unused)notification {
    [self refreshSelection];
}

- (void)toggle:(UIButton *)sender {
    if (self.isExpanded) {
        _panel.hidden = NO;
        [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseIn animations:^{
            _panel.alpha = 0;
            _panel.transform = CGAffineTransformMakeTranslation(18, 0);
        } completion:^(BOOL finished) {
            self.expanded = NO;
            _panel.hidden = YES;
            _panel.alpha = 1;
            _panel.transform = CGAffineTransformIdentity;
            self.frame = CGRectMake(CGRectGetMaxX(self.frame) - 52, self.frame.origin.y, 52, 52);
            _handle.hidden = NO;
        }];
        return;
    }
    self.expanded = YES;
    _panel.hidden = NO;
    _handle.hidden = YES;
    _panel.alpha = 0;
    _panel.transform = CGAffineTransformMakeTranslation(24, 0);
    CGSize parentSize = self.superview.bounds.size;
    [self layoutForPlayerSize:parentSize];
    _panel.alpha = 0;
    _panel.transform = CGAffineTransformMakeTranslation(24, 0);
    [UIView animateWithDuration:0.42 delay:0 usingSpringWithDamping:0.76 initialSpringVelocity:0.45 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
        _panel.alpha = 1;
        _panel.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)modePicked:(UIButton *)sender {
    // Segment order follows the requested 1/3, 2/3, 3/3 positions.
    [YTMUVocalSeparationManager sharedInstance].selectedMode = (YTMUVocalSeparationMode)sender.tag;
    [self refreshSelection];
}

- (void)refreshSelection {
    YTMUVocalSeparationManager *manager = [YTMUVocalSeparationManager sharedInstance];
    NSInteger selected = manager.selectedMode;
    _title.text = manager.isModelReady ? @"SING" : @"MODEL NEEDED";
    for (UIButton *button in _modeButtons) {
        BOOL active = button.tag == selected;
        button.enabled = manager.isModelReady;
        button.backgroundColor = active ? [UIColor colorWithRed:0.66 green:0.90 blue:0.20 alpha:0.95] : UIColor.clearColor;
        [button setTitleColor:active ? [UIColor colorWithWhite:0.06 alpha:1] : [UIColor colorWithWhite:1 alpha:0.76] forState:UIControlStateNormal];
        if (!manager.isModelReady) button.alpha = 0.45;
        else button.alpha = 1;
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:YTMUVocalSeparationModelDidChange object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:YTMUVocalSeparationModeDidChange object:nil];
}
@end

static char kYTMUVocalSeparationBarKey;

%hook YTMNowPlayingView
- (void)layoutSubviews {
    %orig;
    YTMUVocalSeparationBar *bar = objc_getAssociatedObject(self, &kYTMUVocalSeparationBarKey);
    if (!bar) {
        bar = [[YTMUVocalSeparationBar alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(self, &kYTMUVocalSeparationBarKey, bar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self addSubview:bar];
    }
    [bar layoutForPlayerSize:self.bounds.size];
    [self bringSubviewToFront:bar];
}
%end
