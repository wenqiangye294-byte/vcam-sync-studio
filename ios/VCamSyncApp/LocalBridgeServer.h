#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LocalBridgeServer : NSObject

+ (instancetype)sharedServer;

@property (nonatomic, copy, nullable) void (^onHookEvent)(NSDictionary *eventDict);

- (void)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
