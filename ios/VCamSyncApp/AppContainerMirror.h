#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCamInstalledApp : NSObject
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSString *containerPath;
@property (nonatomic, assign) BOOL selected;
@end

@interface AppContainerMirror : NSObject

+ (instancetype)sharedMirror;

- (void)ensureMasterDirectories;
- (NSArray<VCamInstalledApp *> *)discoverInstalledUserApps;

- (NSArray<NSString *> *)selectedBundleIDs;
- (void)saveSelectedBundleIDs:(NSArray<NSString *> *)bundleIDs;
- (NSArray<NSDictionary *> *)selectedTargetAppSummaries;

- (NSArray<NSString *> *)mirrorMasterStoreToSelectedAppsError:(NSError *_Nullable *_Nullable)error;
- (void)syncStateDictionaryToMasterAndTargets:(NSDictionary *)stateDict;
- (void)startWatchingHookStateChangesWithHandler:(void (^)(NSDictionary *stateDict))handler;

@end

NS_ASSUME_NONNULL_END
