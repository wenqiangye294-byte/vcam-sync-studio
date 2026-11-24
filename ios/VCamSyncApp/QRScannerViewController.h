#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface QRScannerViewController : UIViewController

@property (nonatomic, copy, nullable) void (^onScanCode)(NSString *code);

@end

NS_ASSUME_NONNULL_END
