#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCamFloatingHUD : NSObject

+ (instancetype)sharedHUD;
- (void)attachAndRefresh;

@end

NS_ASSUME_NONNULL_END
