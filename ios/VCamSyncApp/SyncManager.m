#import "SyncManager.h"
#import "AppContainerMirror.h"
#import "../shared/VCamProtocol.h"
#import <CommonCrypto/CommonDigest.h>
#import <UIKit/UIKit.h>
#import <arpa/inet.h>
#import <math.h>
#import <netinet/in.h>
#import <string.h>
#import <sys/select.h>
#import <sys/socket.h>
#import <unistd.h>

NSString *const VCamSyncDidUpdateNotification = @"VCamSyncDidUpdateNotification";

static NSString *vcam_sha256_file(NSString *path) {
    NSInputStream *stream = [NSInputStream inputStreamWithFileAtPath:path];
    if (!stream) return @"";
    [stream open];
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    uint8_t buf[32768];
    while ([stream hasBytesAvailable]) {
        NSInteger n = [stream read:buf maxLength:sizeof(buf)];
        if (n <= 0) break;
        CC_SHA256_Update(&ctx, buf, (CC_LONG)n);
    }
    [stream close];

    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

@interface SyncManager () <NSURLSessionWebSocketDelegate>
@property (nonatomic, copy) NSString *host;
@property (nonatomic, assign) NSInteger port;
@property (nonatomic, copy) NSString *token;
@property (nonatomic, copy) NSString *pcName;
@property (nonatomic, copy) NSString *deviceID;

@property (nonatomic, assign) BOOL isConnected;
@property (nonatomic, assign) BOOL isSyncing;
@property (nonatomic, copy) NSString *statusText;
@property (nonatomic, strong) NSDictionary *currentManifest;
@property (nonatomic, strong) NSDictionary *currentState;

@property (nonatomic, strong) NSURLSession *httpSession;
@property (nonatomic, strong) NSURLSession *wsSession;
@property (nonatomic, strong) NSURLSessionWebSocketTask *wsTask;
@property (nonatomic, strong) dispatch_queue_t syncQueue;
@property (nonatomic, assign) NSInteger reconnectAttempt;
@property (nonatomic, assign) BOOL manualDisconnect;
@property (nonatomic, strong) NSTimer *pingTimer;
@end

@implementation SyncManager

+ (instancetype)sharedManager {
    static SyncManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SyncManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _syncQueue = dispatch_queue_create("com.vcamsync.syncqueue", DISPATCH_QUEUE_SERIAL);
        NSURLSessionConfiguration *httpCfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        httpCfg.timeoutIntervalForRequest = 15.0;
        httpCfg.timeoutIntervalForResource = 120.0;
        _httpSession = [NSURLSession sessionWithConfiguration:httpCfg];

        NSURLSessionConfiguration *wsCfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        _wsSession = [NSURLSession sessionWithConfiguration:wsCfg delegate:self delegateQueue:nil];

        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        _host = [ud stringForKey:@"vcam_host"] ?: @"";
        _port = [ud integerForKey:@"vcam_port"] ?: 18760;
        _token = [ud stringForKey:@"vcam_token"] ?: @"";
        _pcName = [ud stringForKey:@"vcam_pc_name"] ?: @"";
        _deviceID = [ud stringForKey:@"vcam_device_id"];
        if (!_deviceID || _deviceID.length == 0) {
            _deviceID = [NSUUID UUID].UUIDString;
            [ud setObject:_deviceID forKey:@"vcam_device_id"];
            [ud synchronize];
        }
        _statusText = [self hasConfiguration] ? @"等待连接电脑..." : @"未配对电脑，请扫码或搜索";

        [self loadLocalCachedManifestAndState];
    }
    return self;
}

- (void)loadLocalCachedManifestAndState {
    NSString *qPath = [VCamMasterDirectory stringByAppendingPathComponent:VCamQueueFilename];
    NSString *sPath = [VCamMasterDirectory stringByAppendingPathComponent:VCamStateFilename];
    NSData *qd = [NSData dataWithContentsOfFile:qPath];
    if (qd) {
        id p = [NSJSONSerialization JSONObjectWithData:qd options:0 error:nil];
        if ([p isKindOfClass:[NSDictionary class]]) {
            self.currentManifest = p;
        }
    }
    NSData *sd = [NSData dataWithContentsOfFile:sPath];
    if (sd) {
        id p = [NSJSONSerialization JSONObjectWithData:sd options:0 error:nil];
        if ([p isKindOfClass:[NSDictionary class]]) {
            self.currentState = p;
        }
    }
}

- (BOOL)hasConfiguration {
    return self.host.length > 0 && self.port > 0 && self.token.length > 0;
}

- (void)notifyUI {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:VCamSyncDidUpdateNotification object:self];
    });
}

- (BOOL)parseAndApplyPairingURL:(NSString *)urlString {
    if (!urlString || urlString.length == 0) return NO;
    NSURLComponents *comp = [NSURLComponents componentsWithString:urlString];
    if (!comp) return NO;
    if (![comp.scheme.lowercaseString isEqualToString:@"vcamsync"]) return NO;

    NSString *host = nil;
    NSInteger port = 18760;
    NSString *token = nil;
    NSString *name = @"VCam-PC";
    for (NSURLQueryItem *item in comp.queryItems) {
        if ([item.name isEqualToString:@"host"]) host = item.value;
        else if ([item.name isEqualToString:@"port"] && item.value.integerValue > 0) port = item.value.integerValue;
        else if ([item.name isEqualToString:@"token"]) token = item.value;
        else if ([item.name isEqualToString:@"name"] && item.value.length > 0) name = item.value;
    }
    if (host.length == 0 || token.length == 0) return NO;
    [self configureHost:host port:port token:token pcName:name];
    return YES;
}

- (void)configureHost:(NSString *)host port:(NSInteger)port token:(NSString *)token pcName:(NSString *)pcName {
    self.host = host ?: @"";
    self.port = port > 0 ? port : 18760;
    self.token = token ?: @"";
    self.pcName = pcName.length > 0 ? pcName : host;

    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setObject:self.host forKey:@"vcam_host"];
    [ud setInteger:self.port forKey:@"vcam_port"];
    [ud setObject:self.token forKey:@"vcam_token"];
    [ud setObject:self.pcName forKey:@"vcam_pc_name"];
    [ud synchronize];

    [self disconnect];
    self.manualDisconnect = NO;
    self.reconnectAttempt = 0;
    [self connectIfConfigured];
}

- (void)connectIfConfigured {
    if (![self hasConfiguration]) {
        self.statusText = @"未配对电脑，请扫码或搜索";
        [self notifyUI];
        return;
    }
    self.manualDisconnect = NO;
    [self openWebSocket];
    [self syncNow];
}

- (void)disconnect {
    self.manualDisconnect = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.pingTimer invalidate];
        self.pingTimer = nil;
    });
    if (self.wsTask) {
        [self.wsTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
        self.wsTask = nil;
    }
    self.isConnected = NO;
    [self notifyUI];
}

- (void)openWebSocket {
    if (![self hasConfiguration] || self.manualDisconnect) return;
    if (self.wsTask && self.wsTask.state == NSURLSessionTaskStateRunning) return;

    NSString *devName = [UIDevice currentDevice].name ?: @"iPhone";
    NSString *iosVer = [UIDevice currentDevice].systemVersion ?: @"16.2";

    NSURLComponents *comp = [[NSURLComponents alloc] init];
    comp.scheme = @"ws";
    comp.host = self.host;
    comp.port = @(self.port);
    comp.path = @"/ws/device";
    comp.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"token" value:self.token],
        [NSURLQueryItem queryItemWithName:@"device_id" value:self.deviceID],
        [NSURLQueryItem queryItemWithName:@"device_name" value:devName],
        [NSURLQueryItem queryItemWithName:@"ios_version" value:iosVer]
    ];
    NSURL *wsURL = comp.URL;
    if (!wsURL) return;

    self.statusText = [NSString stringWithFormat:@"正在连接 %@...", self.host];
    [self notifyUI];

    self.wsTask = [self.wsSession webSocketTaskWithURL:wsURL];
    [self.wsTask resume];
    [self receiveNextWSMessage];
}

- (void)receiveNextWSMessage {
    __weak typeof(self) weakSelf = self;
    NSURLSessionWebSocketTask *task = self.wsTask;
    if (!task) return;
    [task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage * _Nullable message, NSError * _Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (error) {
            [strongSelf handleWSClosed];
            return;
        }
        if (message.type == NSURLSessionWebSocketMessageTypeString && message.string.length > 0) {
            NSData *data = [message.string dataUsingEncoding:NSUTF8StringEncoding];
            id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([parsed isKindOfClass:[NSDictionary class]]) {
                NSString *evt = parsed[@"event"];
                if ([evt isEqualToString:@"manifest_updated"] || [evt isEqualToString:@"force_sync"]) {
                    NSDictionary *manifest = [parsed[@"manifest"] isKindOfClass:[NSDictionary class]] ? parsed[@"manifest"] : nil;
                    [strongSelf syncWithManifest:manifest];
                }
            }
        }
        [strongSelf receiveNextWSMessage];
    }];
}

- (void)handleWSClosed {
    self.isConnected = NO;
    self.wsTask = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.pingTimer invalidate];
        self.pingTimer = nil;
    });
    if (self.manualDisconnect) {
        self.statusText = @"已断开";
        [self notifyUI];
        return;
    }

    self.reconnectAttempt += 1;
    NSTimeInterval delay = MIN(10.0, pow(2.0, MIN(4, self.reconnectAttempt - 1)));
    self.statusText = [NSString stringWithFormat:@"连接已断开，%.0fs 后重连...", delay];
    [self notifyUI];

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf openWebSocket];
    });
}

#pragma mark - NSURLSessionWebSocketDelegate

- (void)URLSession:(NSURLSession *)session
     webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
didOpenWithProtocol:(NSString *)protocol {
    (void)session;
    (void)webSocketTask;
    (void)protocol;
    self.isConnected = YES;
    self.reconnectAttempt = 0;
    self.statusText = [NSString stringWithFormat:@"已连接 %@ (%@)", self.pcName, self.host];
    [self notifyUI];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.pingTimer invalidate];
        __weak typeof(self) weakSelf = self;
        self.pingTimer = [NSTimer scheduledTimerWithTimeInterval:20.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
            (void)timer;
            [weakSelf sendWSPayload:@{@"type": @"ping"}];
        }];
    });
}

- (void)URLSession:(NSURLSession *)session
     webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
  didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode
            reason:(NSData *)reason {
    (void)session;
    (void)webSocketTask;
    (void)closeCode;
    (void)reason;
    [self handleWSClosed];
}

- (void)sendWSPayload:(NSDictionary *)dict {
    if (!self.wsTask || self.wsTask.state != NSURLSessionTaskStateRunning) {
        return;
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    if (!data) return;
    NSString *jsonStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!jsonStr) return;
    NSURLSessionWebSocketMessage *msg = [[NSURLSessionWebSocketMessage alloc] initWithString:jsonStr];
    [self.wsTask sendMessage:msg completionHandler:^(NSError * _Nullable error) {
        (void)error;
    }];
}

- (void)postDeviceEventDict:(NSDictionary *)payload {
    NSMutableDictionary *enriched = [payload mutableCopy];
    enriched[@"device_id"] = self.deviceID;
    enriched[@"device_name"] = [UIDevice currentDevice].name ?: @"iPhone";
    enriched[@"ios_version"] = [UIDevice currentDevice].systemVersion ?: @"16.2";

    if (self.isConnected && self.wsTask && self.wsTask.state == NSURLSessionTaskStateRunning) {
        [self sendWSPayload:enriched];
        return;
    }
    if (![self hasConfiguration]) return;

    NSURLComponents *comp = [[NSURLComponents alloc] init];
    comp.scheme = @"http";
    comp.host = self.host;
    comp.port = @(self.port);
    comp.path = @"/api/sync/device/event";
    comp.queryItems = @[[NSURLQueryItem queryItemWithName:@"token" value:self.token]];
    NSURL *url = comp.URL;
    if (!url) return;

    NSData *body = [NSJSONSerialization dataWithJSONObject:enriched options:0 error:nil];
    if (!body) return;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = body;
    [[self.httpSession dataTaskWithRequest:req] resume];
}

#pragma mark - Manifest & Media Sync

- (void)syncNow {
    [self syncWithManifest:nil];
}

- (void)syncWithManifest:(nullable NSDictionary *)manifestOpt {
    if (![self hasConfiguration]) return;
    dispatch_async(self.syncQueue, ^{
        self.isSyncing = YES;
        self.statusText = @"正在从电脑拉取队列与素材...";
        [self notifyUI];

        NSDictionary *manifest = manifestOpt;
        if (!manifest) {
            manifest = [self fetchManifestSynchronously];
        }
        if (!manifest || ![manifest[@"product"] isKindOfClass:[NSDictionary class]]) {
            self.isSyncing = NO;
            self.statusText = self.isConnected ? @"同步拉取失败，请检查网络" : @"等待连接电脑...";
            [self notifyUI];
            return;
        }

        [[AppContainerMirror sharedMirror] ensureMasterDirectories];
        NSString *mediaDir = [VCamMasterDirectory stringByAppendingPathComponent:VCamMediaSubdir];
        NSDictionary *prod = manifest[@"product"];
        NSMutableArray *allItems = [NSMutableArray array];
        if ([prod[@"photos"] isKindOfClass:[NSArray class]]) [allItems addObjectsFromArray:prod[@"photos"]];
        if ([prod[@"videos"] isKindOfClass:[NSArray class]]) [allItems addObjectsFromArray:prod[@"videos"]];

        NSMutableSet<NSString *> *neededFiles = [NSMutableSet set];
        BOOL allDownloaded = YES;
        for (NSDictionary *item in allItems) {
            NSString *fn = item[@"filename"];
            NSString *sha = item[@"sha256"];
            NSString *relURL = item[@"url"];
            if (![fn isKindOfClass:[NSString class]] || fn.length == 0) continue;
            [neededFiles addObject:fn];

            NSString *dstPath = [mediaDir stringByAppendingPathComponent:fn];
            BOOL ok = NO;
            if ([[NSFileManager defaultManager] fileExistsAtPath:dstPath]) {
                NSString *curSha = vcam_sha256_file(dstPath);
                if (sha.length == 0 || [curSha isEqualToString:sha]) {
                    ok = YES;
                }
            }
            if (!ok && [relURL isKindOfClass:[NSString class]] && relURL.length > 0) {
                ok = [self downloadRelativeURL:relURL toPath:dstPath expectedSHA256:sha];
            }
            if (!ok) {
                allDownloaded = NO;
            }
        }

        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *existing in [fm contentsOfDirectoryAtPath:mediaDir error:nil]) {
            if (![neededFiles containsObject:existing]) {
                [fm removeItemAtPath:[mediaDir stringByAppendingPathComponent:existing] error:nil];
            }
        }

        NSString *qPath = [VCamMasterDirectory stringByAppendingPathComponent:VCamQueueFilename];
        NSData *qData = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted error:nil];
        if (qData) {
            [qData writeToFile:qPath options:NSDataWritingAtomic error:nil];
        }

        NSInteger rev = [manifest[@"revision"] integerValue];
        NSDictionary *newState = @{
            @"revision": @(rev),
            @"product_id": prod[@"id"] ?: @"",
            @"photo_cursor": prod[@"photo_cursor"] ?: @0,
            @"video_cursor": prod[@"video_cursor"] ?: @0,
            @"enabled": manifest[@"enabled"] ?: @YES,
            @"updated_at": @([[NSDate date] timeIntervalSince1970])
        };
        NSString *sPath = [VCamMasterDirectory stringByAppendingPathComponent:VCamStateFilename];
        NSData *sData = [NSJSONSerialization dataWithJSONObject:newState options:NSJSONWritingPrettyPrinted error:nil];
        if (sData) {
            [sData writeToFile:sPath options:NSDataWritingAtomic error:nil];
        }

        self.currentManifest = manifest;
        self.currentState = newState;

        [[AppContainerMirror sharedMirror] mirrorMasterStoreToSelectedAppsError:nil];

        self.isSyncing = NO;
        self.statusText = allDownloaded
            ? [NSString stringWithFormat:@"已同步 v%ld · %@", (long)rev, prod[@"name"] ?: @""]
            : [NSString stringWithFormat:@"部分素材下载失败 (v%ld)", (long)rev];

        [self postDeviceEventDict:@{
            @"event_type": @"sync_status",
            @"sync_revision": @(rev),
            @"sync_status": allDownloaded ? @"ready" : @"partial",
            @"target_apps": [[AppContainerMirror sharedMirror] selectedTargetAppSummaries]
        }];
        [self notifyUI];
    });
}

- (nullable NSDictionary *)fetchManifestSynchronously {
    NSURLComponents *comp = [[NSURLComponents alloc] init];
    comp.scheme = @"http";
    comp.host = self.host;
    comp.port = @(self.port);
    comp.path = @"/api/sync/manifest";
    comp.queryItems = @[[NSURLQueryItem queryItemWithName:@"token" value:self.token]];
    NSURL *url = comp.URL;
    if (!url) return nil;

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSDictionary *result = nil;
    NSURLSessionDataTask *task = [self.httpSession dataTaskWithURL:url completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (!error && http.statusCode == 200 && data) {
            id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([parsed isKindOfClass:[NSDictionary class]]) {
                result = parsed;
            }
        }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)));
    return result;
}

- (BOOL)downloadRelativeURL:(NSString *)relURL toPath:(NSString *)dstPath expectedSHA256:(NSString *)expectedSha {
    NSURLComponents *comp = [[NSURLComponents alloc] init];
    comp.scheme = @"http";
    comp.host = self.host;
    comp.port = @(self.port);
    comp.path = relURL;
    comp.queryItems = @[[NSURLQueryItem queryItemWithName:@"token" value:self.token]];
    NSURL *url = comp.URL;
    if (!url) return NO;

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL success = NO;
    NSURLSessionDownloadTask *task = [self.httpSession downloadTaskWithURL:url completionHandler:^(NSURL * _Nullable location, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (!error && location && (http.statusCode == 200 || http.statusCode == 206)) {
            NSFileManager *fm = [NSFileManager defaultManager];
            [fm removeItemAtPath:dstPath error:nil];
            NSError *moveErr = nil;
            if ([fm moveItemAtPath:location.path toPath:dstPath error:&moveErr]) {
                if (expectedSha.length == 0 || [vcam_sha256_file(dstPath) isEqualToString:expectedSha]) {
                    success = YES;
                }
            }
        }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_SEC)));
    return success;
}

#pragma mark - LAN UDP Auto Discovery

- (void)discoverPCsOnLANWithCompletion:(void (^)(NSArray<NSDictionary *> *pcs))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableDictionary<NSString *, NSDictionary *> *found = [NSMutableDictionary dictionary];
        int fd = socket(AF_INET, SOCK_DGRAM, 0);
        if (fd >= 0) {
            int broadcast = 1;
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcast, sizeof(broadcast));

            struct sockaddr_in bindAddr;
            memset(&bindAddr, 0, sizeof(bindAddr));
            bindAddr.sin_family = AF_INET;
            bindAddr.sin_addr.s_addr = htonl(INADDR_ANY);
            bindAddr.sin_port = 0;
            bind(fd, (struct sockaddr *)&bindAddr, sizeof(bindAddr));

            struct sockaddr_in bcastAddr;
            memset(&bcastAddr, 0, sizeof(bcastAddr));
            bcastAddr.sin_family = AF_INET;
            bcastAddr.sin_addr.s_addr = htonl(INADDR_BROADCAST);
            bcastAddr.sin_port = htons(VCamDiscoveryUDPPort);

            const char *probe = "{\"type\":\"vcamsync_discover\",\"v\":1}";
            sendto(fd, probe, strlen(probe), 0, (struct sockaddr *)&bcastAddr, sizeof(bcastAddr));
            usleep(180000);
            sendto(fd, probe, strlen(probe), 0, (struct sockaddr *)&bcastAddr, sizeof(bcastAddr));

            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.6];
            while ([deadline timeIntervalSinceNow] > 0) {
                fd_set readfds;
                FD_ZERO(&readfds);
                FD_SET(fd, &readfds);
                struct timeval tv;
                tv.tv_sec = 0;
                tv.tv_usec = 250000;
                int sel = select(fd + 1, &readfds, NULL, NULL, &tv);
                if (sel <= 0) continue;

                char buf[4096];
                struct sockaddr_in sender;
                socklen_t slen = sizeof(sender);
                ssize_t n = recvfrom(fd, buf, sizeof(buf) - 1, 0, (struct sockaddr *)&sender, &slen);
                if (n <= 0) continue;
                buf[n] = '\0';

                NSData *data = [NSData dataWithBytes:buf length:(NSUInteger)n];
                id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if ([parsed isKindOfClass:[NSDictionary class]] && [parsed[@"type"] isEqualToString:@"vcamsync_announce"]) {
                    char ipBuf[INET_ADDRSTRLEN] = {0};
                    inet_ntop(AF_INET, &sender.sin_addr, ipBuf, sizeof(ipBuf));
                    NSString *senderIP = [NSString stringWithUTF8String:ipBuf] ?: @"";
                    NSString *host = [parsed[@"host"] isKindOfClass:[NSString class]] ? parsed[@"host"] : senderIP;
                    NSInteger port = [parsed[@"port"] integerValue] ?: 18760;
                    NSString *token = [parsed[@"token"] isKindOfClass:[NSString class]] ? parsed[@"token"] : @"";
                    NSString *name = [parsed[@"name"] isKindOfClass:[NSString class]] ? parsed[@"name"] : host;
                    if (token.length > 0 && host.length > 0) {
                        NSString *key = [NSString stringWithFormat:@"%@:%ld", host, (long)port];
                        found[key] = @{
                            @"host": host,
                            @"port": @(port),
                            @"token": token,
                            @"name": name
                        };
                    }
                }
            }
            close(fd);
        }

        NSArray<NSDictionary *> *list = [found.allValues copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(list);
        });
    });
}

#pragma mark - Controls & Hook Telemetry

- (void)stepPhotoCursorBy:(NSInteger)delta reset:(BOOL)reset {
    NSDictionary *prod = self.currentManifest[@"product"];
    NSArray *photos = [prod[@"photos"] isKindOfClass:[NSArray class]] ? prod[@"photos"] : @[];
    if (photos.count == 0) return;

    BOOL loopPhotos = [self.currentManifest[@"loop_photos"] boolValue];
    NSInteger cur = self.currentState ? [self.currentState[@"photo_cursor"] integerValue] : [prod[@"photo_cursor"] integerValue];
    NSInteger nxt = reset ? 0 : (cur + delta);
    if (loopPhotos) {
        nxt = ((nxt % (NSInteger)photos.count) + (NSInteger)photos.count) % (NSInteger)photos.count;
    } else {
        nxt = MAX(0, MIN(nxt, (NSInteger)photos.count - 1));
    }

    NSMutableDictionary *newState = [(self.currentState ?: @{}) mutableCopy];
    newState[@"revision"] = self.currentManifest[@"revision"] ?: @1;
    newState[@"product_id"] = prod[@"id"] ?: @"";
    newState[@"photo_cursor"] = @(nxt);
    newState[@"video_cursor"] = newState[@"video_cursor"] ?: (prod[@"video_cursor"] ?: @0);
    newState[@"enabled"] = newState[@"enabled"] ?: (self.currentManifest[@"enabled"] ?: @YES);
    newState[@"updated_at"] = @([[NSDate date] timeIntervalSince1970]);
    self.currentState = newState;

    [[AppContainerMirror sharedMirror] syncStateDictionaryToMasterAndTargets:newState];
    [self postDeviceEventDict:@{
        @"event_type": @"cursor_changed",
        @"product_id": prod[@"id"] ?: @"",
        @"photo_cursor": @(nxt),
        @"video_cursor": newState[@"video_cursor"],
        @"sync_revision": newState[@"revision"],
        @"message": reset ? @"手机端重置拍照顺序到第 1 张" : [NSString stringWithFormat:@"手机端切换照片至第 %ld 张", (long)(nxt + 1)]
    }];
    [self notifyUI];
}

- (void)setVirtualCameraEnabled:(BOOL)enabled {
    NSMutableDictionary *newState = [(self.currentState ?: @{}) mutableCopy];
    newState[@"revision"] = self.currentManifest[@"revision"] ?: @1;
    newState[@"product_id"] = self.currentManifest[@"product"][@"id"] ?: @"";
    newState[@"photo_cursor"] = newState[@"photo_cursor"] ?: @0;
    newState[@"video_cursor"] = newState[@"video_cursor"] ?: @0;
    newState[@"enabled"] = @(enabled);
    newState[@"updated_at"] = @([[NSDate date] timeIntervalSince1970]);
    self.currentState = newState;

    [[AppContainerMirror sharedMirror] syncStateDictionaryToMasterAndTargets:newState];
    [self postDeviceEventDict:@{
        @"event_type": @"cursor_changed",
        @"product_id": newState[@"product_id"],
        @"photo_cursor": newState[@"photo_cursor"],
        @"video_cursor": newState[@"video_cursor"],
        @"sync_revision": newState[@"revision"],
        @"message": enabled ? @"手机端已开启虚拟相机输出" : @"手机端已暂停虚拟相机输出"
    }];
    [self notifyUI];
}

- (void)setHUDVisible:(BOOL)showHUD {
    if (!self.currentManifest) return;
    NSMutableDictionary *mut = [self.currentManifest mutableCopy];
    mut[@"show_hud"] = @(showHUD);
    self.currentManifest = mut;

    NSString *qPath = [VCamMasterDirectory stringByAppendingPathComponent:VCamQueueFilename];
    NSData *qData = [NSJSONSerialization dataWithJSONObject:mut options:NSJSONWritingPrettyPrinted error:nil];
    if (qData) {
        [qData writeToFile:qPath options:NSDataWritingAtomic error:nil];
    }
    [[AppContainerMirror sharedMirror] mirrorMasterStoreToSelectedAppsError:nil];
    [self notifyUI];
}

- (void)handleHookEvent:(NSDictionary *)eventDict {
    if (!eventDict) return;
    NSMutableDictionary *newState = [(self.currentState ?: @{}) mutableCopy];
    if (eventDict[@"photo_cursor"]) newState[@"photo_cursor"] = eventDict[@"photo_cursor"];
    if (eventDict[@"video_cursor"]) newState[@"video_cursor"] = eventDict[@"video_cursor"];
    if (eventDict[@"enabled"]) newState[@"enabled"] = eventDict[@"enabled"];
    if (eventDict[@"sync_revision"]) newState[@"revision"] = eventDict[@"sync_revision"];
    if (eventDict[@"product_id"]) newState[@"product_id"] = eventDict[@"product_id"];
    newState[@"updated_at"] = @([[NSDate date] timeIntervalSince1970]);
    self.currentState = newState;

    [[AppContainerMirror sharedMirror] syncStateDictionaryToMasterAndTargets:newState];
    [self postDeviceEventDict:eventDict];
    [self notifyUI];
}

- (void)notifyTargetAppsUpdated {
    [self postDeviceEventDict:@{
        @"event_type": @"target_apps_updated",
        @"target_apps": [[AppContainerMirror sharedMirror] selectedTargetAppSummaries],
        @"sync_revision": self.currentManifest[@"revision"] ?: @0
    }];
    [self notifyUI];
}

@end
