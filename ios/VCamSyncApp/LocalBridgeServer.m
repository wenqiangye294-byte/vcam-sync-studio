#import "LocalBridgeServer.h"
#import "../shared/VCamProtocol.h"
#import <arpa/inet.h>
#import <netinet/in.h>
#import <string.h>
#import <sys/socket.h>
#import <unistd.h>

@interface LocalBridgeServer ()
@property (nonatomic, assign) int listenFD;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, strong) dispatch_queue_t serverQueue;
@end

@implementation LocalBridgeServer

+ (instancetype)sharedServer {
    static LocalBridgeServer *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[LocalBridgeServer alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _listenFD = -1;
        _serverQueue = dispatch_queue_create("com.vcamsync.localbridge", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)start {
    dispatch_async(self.serverQueue, ^{
        if (self.running) return;
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) return;

        int yes = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        addr.sin_port = htons(VCamLocalBridgePort);

        if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 16) != 0) {
            close(fd);
            return;
        }

        self.listenFD = fd;
        self.running = YES;
        [self acceptLoop];
    });
}

- (void)stop {
    self.running = NO;
    if (self.listenFD >= 0) {
        close(self.listenFD);
        self.listenFD = -1;
    }
}

- (void)acceptLoop {
    while (self.running && self.listenFD >= 0) {
        struct sockaddr_in cli;
        socklen_t len = sizeof(cli);
        int clientFD = accept(self.listenFD, (struct sockaddr *)&cli, &len);
        if (clientFD < 0) {
            if (!self.running) break;
            continue;
        }
        int noSigPipe = 1;
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [self handleClientFD:clientFD];
        });
    }
}

- (void)handleClientFD:(int)clientFD {
    NSMutableData *buf = [NSMutableData data];
    uint8_t tmp[4096];
    NSRange headerEnd = NSMakeRange(NSNotFound, 0);
    NSData *sep = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];

    while (buf.length < 262144) {
        ssize_t n = recv(clientFD, tmp, sizeof(tmp), 0);
        if (n <= 0) break;
        [buf appendBytes:tmp length:(NSUInteger)n];
        headerEnd = [buf rangeOfData:sep options:0 range:NSMakeRange(0, buf.length)];
        if (headerEnd.location != NSNotFound) break;
    }

    if (headerEnd.location == NSNotFound) {
        close(clientFD);
        return;
    }

    NSData *headerData = [buf subdataWithRange:NSMakeRange(0, headerEnd.location)];
    NSString *headerStr = [[NSString alloc] initWithData:headerData encoding:NSUTF8StringEncoding] ?: @"";
    NSArray<NSString *> *lines = [headerStr componentsSeparatedByString:@"\r\n"];
    NSString *requestLine = lines.firstObject ?: @"";
    NSInteger contentLength = 0;
    for (NSString *line in lines) {
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location != NSNotFound) {
            NSString *k = [[line substringToIndex:colon.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].lowercaseString;
            if ([k isEqualToString:@"content-length"]) {
                contentLength = [[line substringFromIndex:colon.location + 1] integerValue];
            }
        }
    }

    NSUInteger bodyStart = headerEnd.location + sep.length;
    while ((NSInteger)(buf.length - bodyStart) < contentLength && buf.length < 524288) {
        ssize_t n = recv(clientFD, tmp, sizeof(tmp), 0);
        if (n <= 0) break;
        [buf appendBytes:tmp length:(NSUInteger)n];
    }

    if ([requestLine containsString:@"POST /api/hook/event"] && contentLength > 0 && buf.length >= bodyStart + (NSUInteger)contentLength) {
        NSData *bodyData = [buf subdataWithRange:NSMakeRange(bodyStart, (NSUInteger)contentLength)];
        id parsed = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:nil];
        if ([parsed isKindOfClass:[NSDictionary class]] && self.onHookEvent) {
            self.onHookEvent(parsed);
        }
    }

    const char *resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\nConnection: close\r\n\r\n{\"ok\":true}";
    send(clientFD, resp, strlen(resp), 0);
    close(clientFD);
}

@end
