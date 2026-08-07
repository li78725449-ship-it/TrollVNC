/*
  TRGatewayClient.mm - 内网群控网关注册/心跳客户端（BSD socket / TCP JSON 行协议）
  协议：
    -> {"type":"register","deviceId":"<uuid>","name":"<name>","vncPort":5901}
    <- {"type":"ack","deviceId":"...","name":"..."}
    -> {"type":"hello"}   每 30s
  断线退避重连（2s 起，上限 30s）。
*/
#import "TRGatewayClient.h"
#import "Logging.h"
#import <UIKit/UIKit.h>

#import <arpa/inet.h>
#import <netdb.h>
#import <netinet/in.h>
#import <sys/socket.h>`n#import <sys/select.h>`n#import <sys/time.h>`n#import <time.h>
#import <unistd.h>

static NSString *const kDefaultsSuite = @"com.82flex.trollvnc";
static NSString *const kDeviceUUIDKey = @"DeviceUUID";
static NSString *const kGatewayHostKey = @"GatewayHost";
static NSString *const kGatewayPortKey = @"GatewayPort";
static NSString *const kDesktopNameKey = @"DesktopName";
static NSString *const kPortKey = @"Port";

static const NSTimeInterval kHelloInterval = 30.0;
static const NSTimeInterval kReadTimeout = 5.0;
static const NSTimeInterval kMinRetryDelay = 2.0;
static const NSTimeInterval kMaxRetryDelay = 30.0;

@interface TRGatewayClient () {
    NSUserDefaults *_defaults;
    NSThread *_workerThread;
    BOOL _started;
    NSTimeInterval _retryDelay;
    NSString *_deviceId;
    NSString *_deviceName;
    NSInteger _vncPort;
}

- (NSString *)_gatewayHost;
- (NSInteger)_gatewayPort;
- (NSString *)_deviceId;
- (NSString *)_deviceName;
- (NSInteger)_vncPort;
- (void)_workerMain;
- (BOOL)_connectAndRun;
- (void)_sendHello:(int)fd;
- (NSString *)_jsonEscape:(NSString *)s;

@end

@implementation TRGatewayClient

+ (instancetype)sharedClient {
    static TRGatewayClient *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[TRGatewayClient alloc] init];
    });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _defaults = [[NSUserDefaults alloc] initWithSuiteName:kDefaultsSuite];
        _retryDelay = kMinRetryDelay;
    }
    return self;
}

#pragma mark - 配置

- (NSString *)_gatewayHost {
    NSString *host = [_defaults stringForKey:kGatewayHostKey];
    return host.length ? host : nil;
}

- (NSInteger)_gatewayPort {
    NSInteger port = [_defaults integerForKey:kGatewayPortKey];
    return (port > 0 && port < 65536) ? port : 18081;
}

- (NSString *)_deviceId {
    if (_deviceId) return _deviceId;
    NSString *uuid = [_defaults stringForKey:kDeviceUUIDKey];
    if (!uuid.length) {
        uuid = [[NSUUID UUID] UUIDString];
        [_defaults setObject:uuid forKey:kDeviceUUIDKey];
        [_defaults synchronize];
        TVLog(@"[gw] generated DeviceUUID: %@", uuid);
    }
    _deviceId = uuid;
    return _deviceId;
}

- (NSString *)_deviceName {
    if (_deviceName) return _deviceName;
    // 优先使用设备真实名称（如"张三的 iPhone"），保证注册名/桌面名一致
    NSString *realName = [[UIDevice currentDevice] name];
    NSString *dn = [_defaults stringForKey:kDesktopNameKey];
    if (dn.length && ![dn isEqualToString:@"TrollVNC"]) {
        _deviceName = dn;
    } else if (realName.length) {
        _deviceName = realName;
        // 同步到 DesktopName，使 mDNS/Bonjour 与 VNC 桌面名也是真实名称
        [_defaults setObject:realName forKey:kDesktopNameKey];
        [_defaults synchronize];
    } else {
        _deviceName = @"TrollVNC";
    }
    return _deviceName;
}

- (NSInteger)_vncPort {
    if (_vncPort == 0) {
        NSInteger port = [_defaults integerForKey:kPortKey];
        _vncPort = (port > 0 && port < 65536) ? port : 5901;
    }
    return _vncPort;
}

- (NSString *)_jsonEscape:(NSString *)s {
    NSMutableString *ms = [s mutableCopy];
    [ms replaceOccurrencesOfString:@"\\" withString:@"\\\\" options:0 range:NSMakeRange(0, ms.length)];
    [ms replaceOccurrencesOfString:@"\"" withString:@"\\\"" options:0 range:NSMakeRange(0, ms.length)];
    return ms;
}

#pragma mark - 生命周期

- (void)start {
    if (_started) return;
    if (![self _gatewayHost]) {
        TVLog(@"[gw] no gateway host configured, registration disabled");
        return;
    }
    _started = YES;
    _workerThread = [[NSThread alloc] initWithTarget:self selector:@selector(_workerMain) object:nil];
    [_workerThread setName:@"com.82flex.trollvnc.gateway-client"];
    [_workerThread start];
    TVLog(@"[gw] registration worker started -> %@:%ld", [self _gatewayHost], (long)[self _gatewayPort]);
}

- (void)stop {
    _started = NO;
    if (_workerThread) {
        // 线程内阻塞在 socket 读，最多 kReadTimeout 后退出
        [_workerThread cancel];
        _workerThread = nil;
    }
}

- (void)_workerMain {
    while (_started && ![[NSThread currentThread] isCancelled]) {
        @autoreleasepool {
            BOOL ok = [self _connectAndRun];
            if (!ok && _started) {
                TVLog(@"[gw] connection lost, retry in %.0fs", _retryDelay);
                usleep((useconds_t)(_retryDelay * 1e6));
                _retryDelay = MIN(_retryDelay * 2, kMaxRetryDelay);
            }
        }
    }
}

- (BOOL)_connectAndRun {
    NSString *host = [self _gatewayHost];
    if (!host.length) return NO;

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;

    struct hostent *he = gethostbyname(host.UTF8String);
    if (!he) {
        close(fd);
        return NO;
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)[self _gatewayPort]);
    memcpy(&addr.sin_addr, he->h_addr, he->h_length);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return NO;
    }
    TVLog(@"[gw] connected to %@:%ld", host, (long)[self _gatewayPort]);

    // register
    NSString *reg = [NSString stringWithFormat:
        @"{\"type\":\"register\",\"deviceId\":\"%@\",\"name\":\"%@\",\"vncPort\":%ld}\n",
        [self _jsonEscape:[self _deviceId]], [self _jsonEscape:[self _deviceName]], (long)[self _vncPort]];
    const char *regBytes = reg.UTF8String;
    if (write(fd, regBytes, strlen(regBytes)) < 0) {
        close(fd);
        return NO;
    }

    _retryDelay = kMinRetryDelay;

    // 读线程循环：读 ack/任意数据；每 kHelloInterval 发 hello；select 超时检测
    char buf[512];
    time_t lastHello = time(NULL);
    while (_started && ![[NSThread currentThread] isCancelled]) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(fd, &rfds);
        struct timeval tv;
        tv.tv_sec = (time_t)kReadTimeout;
        tv.tv_usec = 0;
        int sel = select(fd + 1, &rfds, NULL, NULL, &tv);
        if (sel < 0) {
            close(fd);
            return NO;
        }
        if (sel == 0) {
            // 超时：每 kHelloInterval 发一次 hello（保活+探测）
            time_t now = time(NULL);
            if (now - lastHello >= (time_t)kHelloInterval) {
                [self _sendHello:fd];
                lastHello = now;
            }
            continue;
        }
        ssize_t n = read(fd, buf, sizeof(buf) - 1);
        if (n <= 0) {
            close(fd);
            return NO;
        }
        buf[n] = '\0';
        // ack 等消息暂只用于保活确认，无需处理
        (void)buf;
    }

    close(fd);
    return YES;
}

- (void)_sendHello:(int)fd {
    const char *hello = "{\"type\":\"hello\"}\n";
    ssize_t n = write(fd, hello, strlen(hello));
    if (n < 0) {
        // 写失败说明连接已断，read 循环会尽快退出
    }
}

@end
