#import <UIKit/UIKit.h>
#import "../Headers/Localization.h"

@interface DebugSettingsController : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView *tableView;
@end
