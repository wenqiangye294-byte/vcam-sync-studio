#import "AppContainerMirror.h"
#import "../shared/VCamProtocol.h"
#import <notify.h>
#import <objc/message.h>
#import <sys/stat.h>

@implementation VCamInstalledApp
@end

static void vcam_chmod_recursive(NSString *path, mode_t dirMode, mode_t fileMode) {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir]) {
        return;
    }
    chmod(path.fileSystemRepresentation, isDir ? dirMode : fileMode);
    if (isDir) {
        NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:path error:nil];
        for (NSString *item in items) {
            vcam_chmod_recursive([path stringByAppendingPathComponent:item], dirMode, fileMode);
        }
    }
}

@interface AppContainerMirror ()
@property (nonatomic, strong) NSLock *lock;
@property (nonatomic, assign) int cursorNotifyToken;
@property (nonatomic, copy) void (^cursorObserver)(NSDictionary *stateDict);
@end

@implementation AppContainerMirror

+ (instancetype)sharedMirror {
    static AppContainerMirror *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AppContainerMirror alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
        [self ensureMasterDirectories];
    }
    return self;
}

- (void)dealloc {
    if (_cursorNotifyToken != 0) {
        notify_cancel(_cursorNotifyToken);
        _cursorNotifyToken = 0;
    }
}

- (void)ensureMasterDirectories {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *mediaDir = [VCamMasterDirectory stringByAppendingPathComponent:VCamMediaSubdir];
    [fm createDirectoryAtPath:VCamMasterDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:mediaDir withIntermediateDirectories:YES attributes:nil error:nil];
    chmod(VCamMasterDirectory.fileSystemRepresentation, 0777);
    chmod(mediaDir.fileSystemRepresentation, 0777);
}

- (NSDictionary<NSString *, NSString *> *)displayNamesByBundleID {
    NSMutableDictionary<NSString *, NSString *> *map = [NSMutableDictionary dictionary];
    Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
    if (!wsClass) {
        return map;
    }
    SEL defaultSel = NSSelectorFromString(@"defaultWorkspace");
    if (![wsClass respondsToSelector:defaultSel]) {
        return map;
    }
    id workspace = ((id (*)(id, SEL))objc_msgSend)(wsClass, defaultSel);
    SEL allAppsSel = NSSelectorFromString(@"allInstalledApplications");
    if (!workspace || ![workspace respondsToSelector:allAppsSel]) {
        return map;
    }
    NSArray *proxies = ((id (*)(id, SEL))objc_msgSend)(workspace, allAppsSel);
    SEL idSel = NSSelectorFromString(@"applicationIdentifier");
    SEL nameSel = NSSelectorFromString(@"localizedName");
    for (id proxy in proxies) {
        NSString *bid = [proxy respondsToSelector:idSel] ? ((id (*)(id, SEL))objc_msgSend)(proxy, idSel) : nil;
        NSString *name = [proxy respondsToSelector:nameSel] ? ((id (*)(id, SEL))objc_msgSend)(proxy, nameSel) : nil;
        if ([bid isKindOfClass:[NSString class]] && bid.length > 0) {
            if ([name isKindOfClass:[NSString class]] && name.length > 0) {
                map[bid] = name;
            }
        }
    }
    return map;
}

- (NSDictionary<NSString *, NSString *> *)containerPathsByBundleID {
    NSMutableDictionary<NSString *, NSString *> *containers = [NSMutableDictionary dictionary];
    NSString *root = @"/var/mobile/Containers/Data/Application";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *uuids = [fm contentsOfDirectoryAtPath:root error:nil];
    for (NSString *uuidDir in uuids) {
        NSString *appContainer = [root stringByAppendingPathComponent:uuidDir];
        NSString *metaPath = [appContainer stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:metaPath];
        NSString *bid = meta[@"MCMMetadataIdentifier"];
        if ([bid isKindOfClass:[NSString class]] && bid.length > 0) {
            containers[bid] = appContainer;
        }
    }
    return containers;
}

- (NSArray<VCamInstalledApp *> *)discoverInstalledUserApps {
    NSDictionary<NSString *, NSString *> *names = [self displayNamesByBundleID];
    NSDictionary<NSString *, NSString *> *containers = [self containerPathsByBundleID];
    NSSet<NSString *> *selected = [NSSet setWithArray:[self selectedBundleIDs]];

    NSMutableArray<VCamInstalledApp *> *results = [NSMutableArray array];
    for (NSString *bid in containers) {
        if ([bid isEqualToString:VCamCompanionBundleID]) {
            continue;
        }
        if ([bid hasPrefix:@"com.apple."]) {
            continue;
        }
        VCamInstalledApp *app = [[VCamInstalledApp alloc] init];
        app.bundleID = bid;
        app.displayName = names[bid] ?: bid;
        app.containerPath = containers[bid];
        app.selected = [selected containsObject:bid];
        [results addObject:app];
    }

    [results sortUsingComparator:^NSComparisonResult(VCamInstalledApp *a, VCamInstalledApp *b) {
        if (a.selected != b.selected) {
            return a.selected ? NSOrderedAscending : NSOrderedDescending;
        }
        return [a.displayName localizedCaseInsensitiveCompare:b.displayName];
    }];
    return results;
}

- (NSArray<NSString *> *)selectedBundleIDs {
    [self.lock lock];
    NSString *targetsPath = [VCamMasterDirectory stringByAppendingPathComponent:VCamTargetsFilename];
    NSData *data = [NSData dataWithContentsOfFile:targetsPath];
    NSArray *arr = nil;
    if (data) {
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([parsed isKindOfClass:[NSArray class]]) {
            arr = parsed;
        }
    }
    if (!arr) {
        arr = [[NSUserDefaults standardUserDefaults] arrayForKey:@"vcam_selected_bundle_ids"];
    }
    [self.lock unlock];

    NSMutableArray<NSString *> *clean = [NSMutableArray array];
    for (id item in arr ?: @[]) {
        if ([item isKindOfClass:[NSString class]] && ((NSString *)item).length > 0) {
            [clean addObject:item];
        }
    }
    return clean;
}

- (void)saveSelectedBundleIDs:(NSArray<NSString *> *)bundleIDs {
    [self ensureMasterDirectories];
    [self.lock lock];
    NSArray *unique = [[NSSet setWithArray:bundleIDs ?: @[]] allObjects];
    NSArray *sorted = [unique sortedArrayUsingSelector:@selector(compare:)];
    [[NSUserDefaults standardUserDefaults] setObject:sorted forKey:@"vcam_selected_bundle_ids"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    NSString *targetsPath = [VCamMasterDirectory stringByAppendingPathComponent:VCamTargetsFilename];
    NSData *json = [NSJSONSerialization dataWithJSONObject:sorted options:NSJSONWritingPrettyPrinted error:nil];
    if (json) {
        [json writeToFile:targetsPath options:NSDataWritingAtomic error:nil];
        chmod(targetsPath.fileSystemRepresentation, 0666);
    }
    [self.lock unlock];
}

- (NSArray<NSDictionary *> *)selectedTargetAppSummaries {
    NSArray<NSString *> *selected = [self selectedBundleIDs];
    NSDictionary<NSString *, NSString *> *names = [self displayNamesByBundleID];
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (NSString *bid in selected) {
        [out addObject:@{
            @"bundle_id": bid,
            @"name": names[bid] ?: bid
        }];
    }
    return out;
}

- (NSArray<NSString *> *)mirrorMasterStoreToSelectedAppsError:(NSError **)error {
    [self ensureMasterDirectories];
    NSFileManager *fm = [NSFileManager defaultManager];

    NSString *masterQueue = [VCamMasterDirectory stringByAppendingPathComponent:VCamQueueFilename];
    NSString *masterState = [VCamMasterDirectory stringByAppendingPathComponent:VCamStateFilename];
    NSString *masterMediaDir = [VCamMasterDirectory stringByAppendingPathComponent:VCamMediaSubdir];

    NSMutableSet<NSString *> *activeFilenames = [NSMutableSet set];
    NSData *qData = [NSData dataWithContentsOfFile:masterQueue];
    if (qData) {
        id parsed = [NSJSONSerialization JSONObjectWithData:qData options:0 error:nil];
        if ([parsed isKindOfClass:[NSDictionary class]]) {
            NSDictionary *prod = parsed[@"product"];
            if ([prod isKindOfClass:[NSDictionary class]]) {
                for (NSString *key in @[@"photos", @"videos"]) {
                    NSArray *arr = [prod[key] isKindOfClass:[NSArray class]] ? prod[key] : @[];
                    for (NSDictionary *item in arr) {
                        NSString *fn = item[@"filename"];
                        if ([fn isKindOfClass:[NSString class]] && fn.length > 0) {
                            [activeFilenames addObject:fn];
                        }
                    }
                }
            }
        }
    }

    NSArray<NSString *> *selected = [self selectedBundleIDs];
    NSDictionary<NSString *, NSString *> *containers = [self containerPathsByBundleID];
    NSMutableArray<NSString *> *mirroredApps = [NSMutableArray array];

    for (NSString *bid in selected) {
        NSString *container = containers[bid];
        if (!container) {
            continue;
        }
        NSString *targetRoot = [container stringByAppendingPathComponent:VCamAppRelativeSubdir];
        NSString *targetMedia = [targetRoot stringByAppendingPathComponent:VCamMediaSubdir];
        NSError *dirErr = nil;
        if (![fm createDirectoryAtPath:targetMedia withIntermediateDirectories:YES attributes:nil error:&dirErr]) {
            if (error && !*error) {
                *error = dirErr;
            }
            continue;
        }
        chmod([container stringByAppendingPathComponent:@"Library"].fileSystemRepresentation, 0777);
        chmod([container stringByAppendingPathComponent:@"Library/Caches"].fileSystemRepresentation, 0777);
        chmod(targetRoot.fileSystemRepresentation, 0777);
        chmod(targetMedia.fileSystemRepresentation, 0777);

        // Clean stale files
        NSArray<NSString *> *existingFiles = [fm contentsOfDirectoryAtPath:targetMedia error:nil];
        for (NSString *fn in existingFiles) {
            if (![activeFilenames containsObject:fn]) {
                [fm removeItemAtPath:[targetMedia stringByAppendingPathComponent:fn] error:nil];
            }
        }

        // Copy needed media files
        for (NSString *fn in activeFilenames) {
            NSString *srcFile = [masterMediaDir stringByAppendingPathComponent:fn];
            NSString *dstFile = [targetMedia stringByAppendingPathComponent:fn];
            if (![fm fileExistsAtPath:srcFile]) {
                continue;
            }
            NSDictionary *srcAttr = [fm attributesOfItemAtPath:srcFile error:nil];
            NSDictionary *dstAttr = [fm attributesOfItemAtPath:dstFile error:nil];
            BOOL needsCopy = (dstAttr == nil) || ([srcAttr fileSize] != [dstAttr fileSize]);
            if (needsCopy) {
                [fm removeItemAtPath:dstFile error:nil];
                [fm copyItemAtPath:srcFile toPath:dstFile error:nil];
            }
            chmod(dstFile.fileSystemRepresentation, 0666);
        }

        if (qData) {
            NSString *dstQueue = [targetRoot stringByAppendingPathComponent:VCamQueueFilename];
            [qData writeToFile:dstQueue options:NSDataWritingAtomic error:nil];
            chmod(dstQueue.fileSystemRepresentation, 0666);
        }
        NSData *sData = [NSData dataWithContentsOfFile:masterState];
        if (sData) {
            NSString *dstState = [targetRoot stringByAppendingPathComponent:VCamStateFilename];
            [sData writeToFile:dstState options:NSDataWritingAtomic error:nil];
            chmod(dstState.fileSystemRepresentation, 0666);
        }
        [mirroredApps addObject:bid];
    }

    vcam_chmod_recursive(VCamMasterDirectory, 0777, 0666);
    notify_post(VCamDarwinNotifyQueueUpdated);
    return mirroredApps;
}

- (void)syncStateDictionaryToMasterAndTargets:(NSDictionary *)stateDict {
    if (!stateDict) return;
    [self ensureMasterDirectories];
    NSData *data = [NSJSONSerialization dataWithJSONObject:stateDict options:NSJSONWritingPrettyPrinted error:nil];
    if (!data) return;

    NSString *masterState = [VCamMasterDirectory stringByAppendingPathComponent:VCamStateFilename];
    [data writeToFile:masterState options:NSDataWritingAtomic error:nil];
    chmod(masterState.fileSystemRepresentation, 0666);

    NSDictionary<NSString *, NSString *> *containers = [self containerPathsByBundleID];
    for (NSString *bid in [self selectedBundleIDs]) {
        NSString *container = containers[bid];
        if (!container) continue;
        NSString *targetRoot = [container stringByAppendingPathComponent:VCamAppRelativeSubdir];
        [[NSFileManager defaultManager] createDirectoryAtPath:targetRoot withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *dstState = [targetRoot stringByAppendingPathComponent:VCamStateFilename];
        [data writeToFile:dstState options:NSDataWritingAtomic error:nil];
        chmod(dstState.fileSystemRepresentation, 0666);
    }
    notify_post(VCamDarwinNotifyQueueUpdated);
}

- (void)startWatchingHookStateChangesWithHandler:(void (^)(NSDictionary *stateDict))handler {
    self.cursorObserver = handler;
    if (self.cursorNotifyToken != 0) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    int token = 0;
    notify_register_dispatch(
        VCamDarwinNotifyCursorAdvanced,
        &token,
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
        ^(int t) {
            (void)t;
            [weakSelf handleExternalCursorAdvance];
        }
    );
    self.cursorNotifyToken = token;
}

- (void)handleExternalCursorAdvance {
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    [candidates addObject:[VCamMasterDirectory stringByAppendingPathComponent:VCamStateFilename]];
    NSDictionary<NSString *, NSString *> *containers = [self containerPathsByBundleID];
    for (NSString *bid in [self selectedBundleIDs]) {
        NSString *c = containers[bid];
        if (c) {
            [candidates addObject:[[c stringByAppendingPathComponent:VCamAppRelativeSubdir] stringByAppendingPathComponent:VCamStateFilename]];
        }
    }

    NSDictionary *newest = nil;
    double newestTs = -1.0;
    for (NSString *path in candidates) {
        NSData *d = [NSData dataWithContentsOfFile:path];
        if (!d) continue;
        id parsed = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if ([parsed isKindOfClass:[NSDictionary class]]) {
            double ts = [parsed[@"updated_at"] doubleValue];
            if (ts > newestTs) {
                newestTs = ts;
                newest = parsed;
            }
        }
    }
    if (newest) {
        [self syncStateDictionaryToMasterAndTargets:newest];
        if (self.cursorObserver) {
            self.cursorObserver(newest);
        }
    }
}

@end
