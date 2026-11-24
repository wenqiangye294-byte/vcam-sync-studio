#import "VCamQueueStore.h"
#import "../shared/VCamProtocol.h"
#import <notify.h>

NSString *const VCamQueueStoreDidChangeNotification = @"VCamQueueStoreDidChangeNotification";

@interface VCamQueueStore ()
@property (nonatomic, strong) NSLock *lock;
@property (nonatomic, copy) NSString *resolvedBaseDir;
@property (nonatomic, strong) NSDate *lastQueueModDate;
@property (nonatomic, strong) NSDate *lastStateModDate;
@property (nonatomic, strong) NSArray<NSDictionary *> *photos;
@property (nonatomic, strong) NSArray<NSDictionary *> *videos;
@property (nonatomic, copy) NSString *cachedPhotoPath;
@property (nonatomic, strong) NSData *cachedPhotoData;
@property (nonatomic, strong) NSURLSession *bridgeSession;
@property (nonatomic, assign) int notifyToken;

@property (nonatomic, assign) BOOL isEnabled;
@property (nonatomic, assign) BOOL showHUD;
@property (nonatomic, assign) BOOL loopPhotos;
@property (nonatomic, assign) BOOL loopVideos;
@property (nonatomic, copy) NSString *fillMode;
@property (nonatomic, assign) NSInteger rotation;
@property (nonatomic, assign) BOOL mirror;
@property (nonatomic, copy) NSString *videoReplaceMode;
@property (nonatomic, assign) NSInteger revision;
@property (nonatomic, copy) NSString *productID;
@property (nonatomic, copy) NSString *productName;
@property (nonatomic, assign) NSInteger photoCursor;
@property (nonatomic, assign) NSInteger videoCursor;
@end

@implementation VCamQueueStore

+ (instancetype)sharedStore {
    static VCamQueueStore *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VCamQueueStore alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
        _fillMode = @"fill";
        _videoReplaceMode = @"full";
        _productID = @"";
        _productName = @"";
        _isEnabled = YES;
        _showHUD = YES;
        _photos = @[];
        _videos = @[];

        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest = 1.5;
        cfg.timeoutIntervalForResource = 2.0;
        _bridgeSession = [NSURLSession sessionWithConfiguration:cfg];

        _resolvedBaseDir = [self detectBaseDirectory];
        [self loadFromDiskLocked];

        __weak typeof(self) weakSelf = self;
        int token = 0;
        notify_register_dispatch(
            VCamDarwinNotifyQueueUpdated,
            &token,
            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
            ^(int t) {
                (void)t;
                [weakSelf forceReload];
            }
        );
        _notifyToken = token;
    }
    return self;
}

- (void)dealloc {
    if (_notifyToken != 0) {
        notify_cancel(_notifyToken);
        _notifyToken = 0;
    }
}

- (NSString *)detectBaseDirectory {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *sandboxDir = [NSHomeDirectory() stringByAppendingPathComponent:VCamAppRelativeSubdir];
    NSString *sandboxQueue = [sandboxDir stringByAppendingPathComponent:VCamQueueFilename];
    if ([fm fileExistsAtPath:sandboxQueue]) {
        return sandboxDir;
    }

    NSString *masterQueue = [VCamMasterDirectory stringByAppendingPathComponent:VCamQueueFilename];
    if ([fm fileExistsAtPath:masterQueue] || [fm isReadableFileAtPath:VCamMasterDirectory]) {
        return VCamMasterDirectory;
    }

    return sandboxDir;
}

- (NSString *)activeBaseDirectory {
    [self.lock lock];
    NSString *dir = [self.resolvedBaseDir copy];
    [self.lock unlock];
    return dir;
}

- (void)reloadIfNeeded {
    [self.lock lock];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *currentQueue = [self.resolvedBaseDir stringByAppendingPathComponent:VCamQueueFilename];
    if (![fm fileExistsAtPath:currentQueue]) {
        self.resolvedBaseDir = [self detectBaseDirectory];
        currentQueue = [self.resolvedBaseDir stringByAppendingPathComponent:VCamQueueFilename];
    }
    NSString *currentState = [self.resolvedBaseDir stringByAppendingPathComponent:VCamStateFilename];

    NSDictionary *qAttrs = [fm attributesOfItemAtPath:currentQueue error:nil];
    NSDictionary *sAttrs = [fm attributesOfItemAtPath:currentState error:nil];
    NSDate *qMod = qAttrs[NSFileModificationDate];
    NSDate *sMod = sAttrs[NSFileModificationDate];

    BOOL changed = NO;
    if (qMod && (!self.lastQueueModDate || ![qMod isEqualToDate:self.lastQueueModDate])) {
        changed = YES;
    }
    if (sMod && (!self.lastStateModDate || ![sMod isEqualToDate:self.lastStateModDate])) {
        changed = YES;
    }
    if (changed) {
        [self loadFromDiskLocked];
    }
    [self.lock unlock];

    if (changed) {
        [self notifyUIListeners];
    }
}

- (void)forceReload {
    [self.lock lock];
    self.resolvedBaseDir = [self detectBaseDirectory];
    [self loadFromDiskLocked];
    [self.lock unlock];
    [self notifyUIListeners];
}

- (void)loadFromDiskLocked {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *queuePath = [self.resolvedBaseDir stringByAppendingPathComponent:VCamQueueFilename];
    NSString *statePath = [self.resolvedBaseDir stringByAppendingPathComponent:VCamStateFilename];

    NSDictionary *qAttrs = [fm attributesOfItemAtPath:queuePath error:nil];
    self.lastQueueModDate = qAttrs[NSFileModificationDate];

    NSData *qData = [NSData dataWithContentsOfFile:queuePath];
    NSDictionary *queueDict = nil;
    if (qData) {
        id parsed = [NSJSONSerialization JSONObjectWithData:qData options:0 error:nil];
        if ([parsed isKindOfClass:[NSDictionary class]]) {
            queueDict = parsed;
        }
    }

    NSDictionary *sAttrs = [fm attributesOfItemAtPath:statePath error:nil];
    self.lastStateModDate = sAttrs[NSFileModificationDate];
    NSData *sData = [NSData dataWithContentsOfFile:statePath];
    NSDictionary *stateDict = nil;
    if (sData) {
        id parsed = [NSJSONSerialization JSONObjectWithData:sData options:0 error:nil];
        if ([parsed isKindOfClass:[NSDictionary class]]) {
            stateDict = parsed;
        }
    }

    if (queueDict) {
        self.revision = [queueDict[@"revision"] integerValue];
        self.isEnabled = queueDict[@"enabled"] ? [queueDict[@"enabled"] boolValue] : YES;
        self.showHUD = queueDict[@"show_hud"] ? [queueDict[@"show_hud"] boolValue] : YES;
        self.loopPhotos = [queueDict[@"loop_photos"] boolValue];
        self.loopVideos = queueDict[@"loop_videos"] ? [queueDict[@"loop_videos"] boolValue] : YES;
        self.fillMode = [queueDict[@"fill_mode"] isKindOfClass:[NSString class]] ? queueDict[@"fill_mode"] : @"fill";
        self.rotation = [queueDict[@"rotation"] integerValue];
        self.mirror = [queueDict[@"mirror"] boolValue];
        self.videoReplaceMode = [queueDict[@"video_replace_mode"] isKindOfClass:[NSString class]] ? queueDict[@"video_replace_mode"] : @"full";

        NSDictionary *prod = [queueDict[@"product"] isKindOfClass:[NSDictionary class]] ? queueDict[@"product"] : nil;
        if (prod) {
            self.productID = [prod[@"id"] isKindOfClass:[NSString class]] ? prod[@"id"] : @"";
            self.productName = [prod[@"name"] isKindOfClass:[NSString class]] ? prod[@"name"] : @"";
            self.photos = [prod[@"photos"] isKindOfClass:[NSArray class]] ? prod[@"photos"] : @[];
            self.videos = [prod[@"videos"] isKindOfClass:[NSArray class]] ? prod[@"videos"] : @[];
            self.photoCursor = [prod[@"photo_cursor"] integerValue];
            self.videoCursor = [prod[@"video_cursor"] integerValue];
        } else {
            self.photos = @[];
            self.videos = @[];
            self.photoCursor = 0;
            self.videoCursor = 0;
        }
    }

    if (stateDict && [stateDict[@"revision"] integerValue] == self.revision) {
        NSString *stateProdID = [stateDict[@"product_id"] isKindOfClass:[NSString class]] ? stateDict[@"product_id"] : @"";
        if (stateProdID.length == 0 || [stateProdID isEqualToString:self.productID]) {
            if (stateDict[@"photo_cursor"]) {
                self.photoCursor = [stateDict[@"photo_cursor"] integerValue];
            }
            if (stateDict[@"video_cursor"]) {
                self.videoCursor = [stateDict[@"video_cursor"] integerValue];
            }
            if (stateDict[@"enabled"]) {
                self.isEnabled = [stateDict[@"enabled"] boolValue];
            }
        }
    }

    if (self.photos.count > 0) {
        self.photoCursor = MAX(0, MIN(self.photoCursor, (NSInteger)self.photos.count - 1));
    } else {
        self.photoCursor = 0;
    }
    if (self.videos.count > 0) {
        self.videoCursor = MAX(0, MIN(self.videoCursor, (NSInteger)self.videos.count - 1));
    } else {
        self.videoCursor = 0;
    }

    self.cachedPhotoPath = nil;
    self.cachedPhotoData = nil;
}

- (void)writeStateLocked {
    if (self.resolvedBaseDir.length == 0) {
        return;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:self.resolvedBaseDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSDictionary *state = @{
        @"revision": @(self.revision),
        @"product_id": self.productID ?: @"",
        @"photo_cursor": @(self.photoCursor),
        @"video_cursor": @(self.videoCursor),
        @"enabled": @(self.isEnabled),
        @"updated_at": @([[NSDate date] timeIntervalSince1970])
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted error:nil];
    if (!data) {
        return;
    }
    NSString *statePath = [self.resolvedBaseDir stringByAppendingPathComponent:VCamStateFilename];
    [data writeToFile:statePath options:NSDataWritingAtomic error:nil];
    NSDictionary *attrs = [fm attributesOfItemAtPath:statePath error:nil];
    self.lastStateModDate = attrs[NSFileModificationDate];
}

- (void)notifyUIListeners {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:VCamQueueStoreDidChangeNotification object:self];
    });
}

- (void)postEventToBridgeWithType:(NSString *)eventType
                      photoCursor:(NSInteger)photoCursor
                      videoCursor:(NSInteger)videoCursor
                          enabled:(BOOL)enabled
                         revision:(NSInteger)revision
                        productID:(NSString *)productID
                           itemID:(NSString *)itemID
                           reason:(NSString *)reason {
    notify_post(VCamDarwinNotifyCursorAdvanced);

    NSString *urlString = [NSString stringWithFormat:@"http://127.0.0.1:%u/api/hook/event", VCamLocalBridgePort];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        return;
    }
    NSDictionary *body = @{
        @"event_type": eventType ?: @"cursor_changed",
        @"product_id": productID ?: @"",
        @"photo_cursor": @(photoCursor),
        @"video_cursor": @(videoCursor),
        @"enabled": @(enabled),
        @"sync_revision": @(revision),
        @"item_id": itemID ?: @"",
        @"message": reason ?: @""
    };
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if (!jsonData) {
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = jsonData;

    NSURLSessionDataTask *task = [self.bridgeSession dataTaskWithRequest:req];
    [task resume];
}

- (NSInteger)photoCount {
    [self.lock lock];
    NSInteger c = (NSInteger)self.photos.count;
    [self.lock unlock];
    return c;
}

- (NSInteger)videoCount {
    [self.lock lock];
    NSInteger c = (NSInteger)self.videos.count;
    [self.lock unlock];
    return c;
}

- (BOOL)shouldReplaceVideoStream {
    [self reloadIfNeeded];
    [self.lock lock];
    BOOL active = self.isEnabled && (self.isRecordingVideo ? (self.videos.count > 0) : (self.photos.count > 0 || self.videos.count > 0));
    [self.lock unlock];
    return active;
}

- (nullable NSURL *)mediaURLLockedForArray:(NSArray<NSDictionary *> *)items cursor:(NSInteger)cursor {
    if (items.count == 0) {
        return nil;
    }
    NSInteger idx = MAX(0, MIN(cursor, (NSInteger)items.count - 1));
    NSDictionary *item = items[(NSUInteger)idx];
    NSString *filename = item[@"filename"];
    if (![filename isKindOfClass:[NSString class]] || filename.length == 0) {
        return nil;
    }
    NSString *mediaDir = [self.resolvedBaseDir stringByAppendingPathComponent:VCamMediaSubdir];
    NSString *fullPath = [mediaDir stringByAppendingPathComponent:filename];
    if (![[NSFileManager defaultManager] fileExistsAtPath:fullPath]) {
        return nil;
    }
    return [NSURL fileURLWithPath:fullPath];
}

- (nullable NSURL *)currentPhotoURL {
    [self reloadIfNeeded];
    [self.lock lock];
    NSURL *url = self.isEnabled ? [self mediaURLLockedForArray:self.photos cursor:self.photoCursor] : nil;
    [self.lock unlock];
    return url;
}

- (nullable NSData *)currentPhotoJPEGData {
    [self reloadIfNeeded];
    [self.lock lock];
    NSData *result = nil;
    if (self.isEnabled) {
        NSURL *url = [self mediaURLLockedForArray:self.photos cursor:self.photoCursor];
        if (url) {
            if ([self.cachedPhotoPath isEqualToString:url.path] && self.cachedPhotoData) {
                result = self.cachedPhotoData;
            } else {
                NSData *raw = [NSData dataWithContentsOfURL:url];
                if (raw.length > 0) {
                    self.cachedPhotoPath = url.path;
                    self.cachedPhotoData = raw;
                    result = raw;
                }
            }
        }
    }
    [self.lock unlock];
    return result;
}

- (nullable NSURL *)currentVideoURL {
    [self reloadIfNeeded];
    [self.lock lock];
    NSURL *url = self.isEnabled ? [self mediaURLLockedForArray:self.videos cursor:self.videoCursor] : nil;
    [self.lock unlock];
    return url;
}

- (void)advancePhotoCursorWithReason:(NSString *)reason {
    [self.lock lock];
    NSInteger count = (NSInteger)self.photos.count;
    NSString *itemID = @"";
    if (count > 0) {
        NSInteger cur = MAX(0, MIN(self.photoCursor, count - 1));
        NSDictionary *item = self.photos[(NSUInteger)cur];
        if ([item[@"id"] isKindOfClass:[NSString class]]) {
            itemID = item[@"id"];
        }
        NSInteger nxt = cur + 1;
        if (nxt >= count) {
            nxt = self.loopPhotos ? 0 : (count - 1);
        }
        self.photoCursor = nxt;
        [self writeStateLocked];
    }
    NSInteger pCur = self.photoCursor;
    NSInteger vCur = self.videoCursor;
    BOOL enabled = self.isEnabled;
    NSInteger rev = self.revision;
    NSString *pid = [self.productID copy];
    [self.lock unlock];

    [self notifyUIListeners];
    [self postEventToBridgeWithType:@"photo_captured"
                        photoCursor:pCur
                        videoCursor:vCur
                            enabled:enabled
                           revision:rev
                          productID:pid
                             itemID:itemID
                             reason:reason ?: @"拍照完成"];
}

- (void)advanceVideoCursorWithReason:(NSString *)reason {
    [self.lock lock];
    NSInteger count = (NSInteger)self.videos.count;
    NSString *itemID = @"";
    if (count > 0) {
        NSInteger cur = MAX(0, MIN(self.videoCursor, count - 1));
        NSDictionary *item = self.videos[(NSUInteger)cur];
        if ([item[@"id"] isKindOfClass:[NSString class]]) {
            itemID = item[@"id"];
        }
        NSInteger nxt = cur + 1;
        if (nxt >= count) {
            nxt = self.loopVideos ? 0 : (count - 1);
        }
        self.videoCursor = nxt;
        [self writeStateLocked];
    }
    NSInteger pCur = self.photoCursor;
    NSInteger vCur = self.videoCursor;
    BOOL enabled = self.isEnabled;
    NSInteger rev = self.revision;
    NSString *pid = [self.productID copy];
    [self.lock unlock];

    [self notifyUIListeners];
    [self postEventToBridgeWithType:@"video_recorded"
                        photoCursor:pCur
                        videoCursor:vCur
                            enabled:enabled
                           revision:rev
                          productID:pid
                             itemID:itemID
                             reason:reason ?: @"长按录制完成"];
}

- (void)stepPhotoCursorBy:(NSInteger)delta {
    [self.lock lock];
    NSInteger count = (NSInteger)self.photos.count;
    if (count > 0) {
        NSInteger nxt = self.photoCursor + delta;
        if (self.loopPhotos) {
            nxt = ((nxt % count) + count) % count;
        } else {
            nxt = MAX(0, MIN(nxt, count - 1));
        }
        self.photoCursor = nxt;
        [self writeStateLocked];
    }
    NSInteger pCur = self.photoCursor;
    NSInteger vCur = self.videoCursor;
    BOOL enabled = self.isEnabled;
    NSInteger rev = self.revision;
    NSString *pid = [self.productID copy];
    [self.lock unlock];

    [self notifyUIListeners];
    [self postEventToBridgeWithType:@"cursor_changed"
                        photoCursor:pCur
                        videoCursor:vCur
                            enabled:enabled
                           revision:rev
                          productID:pid
                             itemID:@""
                             reason:@"手机悬浮条手动切换图片"];
}

- (void)stepVideoCursorBy:(NSInteger)delta {
    [self.lock lock];
    NSInteger count = (NSInteger)self.videos.count;
    if (count > 0) {
        NSInteger nxt = self.videoCursor + delta;
        if (self.loopVideos) {
            nxt = ((nxt % count) + count) % count;
        } else {
            nxt = MAX(0, MIN(nxt, count - 1));
        }
        self.videoCursor = nxt;
        [self writeStateLocked];
    }
    NSInteger pCur = self.photoCursor;
    NSInteger vCur = self.videoCursor;
    BOOL enabled = self.isEnabled;
    NSInteger rev = self.revision;
    NSString *pid = [self.productID copy];
    [self.lock unlock];

    [self notifyUIListeners];
    [self postEventToBridgeWithType:@"cursor_changed"
                        photoCursor:pCur
                        videoCursor:vCur
                            enabled:enabled
                           revision:rev
                          productID:pid
                             itemID:@""
                             reason:@"手机悬浮条手动切换视频"];
}

- (void)toggleEnabled {
    [self.lock lock];
    self.isEnabled = !self.isEnabled;
    [self writeStateLocked];
    NSInteger pCur = self.photoCursor;
    NSInteger vCur = self.videoCursor;
    BOOL enabled = self.isEnabled;
    NSInteger rev = self.revision;
    NSString *pid = [self.productID copy];
    [self.lock unlock];

    [self notifyUIListeners];
    [self postEventToBridgeWithType:@"cursor_changed"
                        photoCursor:pCur
                        videoCursor:vCur
                            enabled:enabled
                           revision:rev
                          productID:pid
                             itemID:@""
                             reason:enabled ? @"悬浮条开启虚拟相机" : @"悬浮条暂停虚拟相机"];
}

@end
