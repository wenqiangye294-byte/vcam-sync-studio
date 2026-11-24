#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TargetAppsViewController : UITableViewController

@property (nonatomic, copy, nullable) void (^onSelectionSaved)(void);

@end

NS_ASSUME_NONNULL_END
