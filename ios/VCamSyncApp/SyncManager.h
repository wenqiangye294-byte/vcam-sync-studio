#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const VCamSyncDidUpdateNotification;

@interface SyncManager : NSObject

+ (instancetype)sharedManager;

@property (nonatomic, readonly, copy) NSString *host;
@property (nonatomic, readonly) NSInteger port;
@property (nonatomic, readonly, copy) NSString *token;
@property (nonatomic, readonly, copy) NSString *pcName;
@property (nonatomic, readonly, copy) NSString *deviceID;
@property (nonatomic, readonly) BOOL isConnected;
@property (nonatomic, readonly) BOOL isSyncing;
@property (nonatomic, readonly, copy) NSString *statusText;
@property (nonatomic, readonly, strong, nullable) NSDictionary *currentManifest;
@property (nonatomic, readonly, strong, nullable) NSDictionary *currentState;

- (BOOL)hasConfiguration;
- (BOOL)parseAndApplyPairingURL:(NSString *)urlString;
- (void)configureHost:(NSString *)host port:(NSInteger)port token:(NSString *)token pcName:(NSString *)pcName;

- (void)connectIfConfigured;
- (void)disconnect;
- (void)syncNow;

- (void)discoverPCsOnLANWithCompletion:(void (^)(NSArray<NSDictionary *> *pcs))completion;

- (void)stepPhotoCursorBy:(NSInteger)delta reset:(BOOL)reset;
- (void)setVirtualCameraEnabled:(BOOL)enabled;
- (void)setHUDVisible:(BOOL)showHUD;
- (void)handleHookEvent:(NSDictionary *)eventDict;
- (void)notifyTargetAppsUpdated;

@end

NS_ASSUME_NONNULL_END
