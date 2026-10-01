#include "GSVolBar.h"

static BOOL YTMU(NSString *key) {
    NSDictionary *YTMUltimateDict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    return [YTMUltimateDict[key] boolValue];
}

// A FUNCTION, not a file-scope initializer. `static BOOL volumeBar = f();` is
// not a constant expression, so it cannot initialize an object with static
// storage duration -- clang rejects it outright. Calling it at each use also
// means the pref is read live rather than frozen at load time, which is what a
// settings toggle needs.
static BOOL YTMUVolumeBarEnabled(void) {
    return YTMU(@"YTMUltimateIsEnabled") && YTMU(@"volBar");
}

@interface YTMWatchView: UIView
@property (readonly, nonatomic) BOOL isExpanded;
@property (nonatomic, strong) UIView *tabView;
@property (nonatomic) long long currentLayout;
@property (nonatomic, strong) GSVolBar *volumeBar;

- (void)updateVolBarVisibility;
@end

%hook YTMWatchView
%property (nonatomic, strong) GSVolBar *volumeBar;

- (instancetype)initWithColorScheme:(id)scheme {
    self = %orig;

    if (self && YTMUVolumeBarEnabled()) {
        self.volumeBar = [[GSVolBar alloc] initWithFrame:CGRectMake(self.frame.size.width / 2 - (self.frame.size.width / 2) / 2, 0, self.frame.size.width / 2, 25)];

        [self addSubview:self.volumeBar];
    }

    return self;
}

- (void)layoutSubviews {
    %orig;

    if (YTMUVolumeBarEnabled()) {
        self.volumeBar.frame = CGRectMake(self.frame.size.width / 2 - (self.frame.size.width / 2) / 2, CGRectGetMinY(self.tabView.frame) - 25, self.frame.size.width / 2, 25);
    }
}

- (void)updateColorsAfterLayoutChangeTo:(long long)arg1 {
    %orig;

    if (YTMUVolumeBarEnabled()) {
        [self updateVolBarVisibility];
    }
}

- (void)updateColorsBeforeLayoutChangeTo:(long long)arg1 {
    %orig;

    if (YTMUVolumeBarEnabled()) {
        self.volumeBar.hidden = YES;
    }
}

%new
- (void)updateVolBarVisibility {
    if (YTMUVolumeBarEnabled()) {
        dispatch_async(dispatch_get_main_queue(), ^(void){
            self.volumeBar.hidden = !(self.isExpanded && self.currentLayout == 2);
        });
    }
}

%end