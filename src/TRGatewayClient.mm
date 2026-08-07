/*
  TRGatewayClient.mm - 见 TRGatewayClient.h
*/
#import "TRGatewayClient.h"
#import "Logging.h"

static NSString *const kDefaultsSuite = @"com.82flex.trollvnc";
static NSString *const kDeviceUUIDKey = @"DeviceUUID";
static NSString *const kGatewayURLKey = @"GatewayURL";
static NSString *const kGatewayHostKey = @"GatewayHost";
static NSString *const kGatewayPortKey = @"GatewayPort";
static NSString *const kGatewayTokenKey = @"GatewayToken";
static NSString *const kDesktopNameKey = @"DesktopName";
static NSString *const kPortKey = @"Port";

static const NSTimeInterval kHelloInterval = 30.0;

@interface TRGatewayClient () {
    NSUserDefaults *_defaults;
    NSURLSession *_session;
    NSURLSessionWebSocketTask *_task;
    NSTimer *_helloTimer;
    NSTimer *_retryTimer;
    BOOL _started;
    BOOL _connected;
    NSTimeInterval _retryDelay;
    NSString *_deviceId;
    NSString *_deviceName;
    NSInteger _vncPort;
}

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
        _retryDelay = 2.0;
    }
    return self;
}

#pragma mark - 配置读取

- (NSString *)_gatewayURL {
    NSString *url = [_defaults stringForKey:kGatewayURLKey];
    if (url.length) return url;

    NSString *host = [_defaults stringForKey:kGatewayHostKey];
    NSInteger port = [_defaults integerForKey:kGatewayPortKey];
    if (host.length && port > 0) {
        return [NSString stringWithFormat:@"ws://%@:%ld", host, (long)port];
    }
    return nil;
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
    _deviceName = [_defaults stringForKey:kDesktopNameKey];
    if (!_deviceName.length) _deviceName = @"TrollVNC";
    return _deviceName;
}

- (NSInteger)_vncPort {
    if (_vncPort == 0) {
        NSInteger port = [_defaults integerForKey:kPortKey];
        _vncPort = (port > 0 && port < 65536) ? port : 5901;
    }
    return _vncPort;
}

#pragma mark - 生命周期

- (void)start {
    if (_started) return;
    _started = YES;

    NSString *base = [self _gatewayURL];
    if (!base.length) {
        TVLog(@"[gw] no gateway configured, registration disabled");
        return;
    }

    NSURLComponents *comp = [NSURLComponents componentsWithString:base];
    comp.path = @"/ws/register";
    NSMutableArray<NSURLQueryItem *> *q = [NSMutableArray array];
    [q addObject:[NSURLQueryItem queryItemWithName:@"deviceId" value:[self _deviceId]]];
    [q addObject:[NSURLQueryItem queryItemWithName:@"name" value:[self _deviceName]]];
    [q addObject:[NSURLQueryItem queryItemWithName:@"vncPort" value:[NSString stringWithFormat:@"%ld", (long)[self _vncPort]]]];
    NSString *token = [_defaults stringForKey:kGatewayTokenKey];
    if (token.length) [q addObject:[NSURLQueryItem queryItemWithName:@"token" value:token]];
    comp.queryItems = q;

    NSURL *url = comp.URL;
    if (!url) {
        TVLog(@"[gw] invalid gateway URL");
        return;
    }

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 60;
    _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    _task = [_session webSocketTaskWithURL:url];
    TVLog(@"[gw] connecting to %@", url.absoluteString);
    [_task resume];
    [self _receive];
}

- (void)stop {
    _started = NO;
    [_helloTimer invalidate];
    _helloTimer = nil;
    [_retryTimer invalidate];
    _retryTimer = nil;
    [_task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
    [_session invalidateAndCancel];
    _task = nil;
    _session = nil;
    _connected = NO;
}

- (void)_receive {
    __weak typeof(self) weakSelf = self;
    [_task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *_Nullable message, NSError *_Nullable error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (error) return; // 断开/超时由 delegate 处理
        // 目前只关心连接保持；服务端 ack 可留日志
        [self _receive]; // 继续收下一条
    }];
}

- (void)_sendHello {
    if (!_task || _task.state != NSURLSessionTaskStateRunning) return;
    NSString *hello = @"{\"type\":\"hello\"}";
    [_task sendMessage:[NSURLSessionWebSocketMessage messageWithString:hello]
      completionHandler:^(NSError *_Nullable error) {
          if (error) {
              TVLog(@"[gw] hello send failed: %@", error.localizedDescription);
          }
      }];
}

- (void)_scheduleReconnect {
    if (!_started) return;
    [_helloTimer invalidate];
    _helloTimer = nil;
    _connected = NO;

    [_retryTimer invalidate];
    _retryTimer = [NSTimer scheduledTimerWithTimeInterval:_retryDelay target:self
                                                selector:@selector(_retryNow) userInfo:nil repeats:NO];
    _retryDelay = MIN(_retryDelay * 2, 30.0);
    TVLog(@"[gw] reconnect in %.0fs", _retryDelay);
}

- (void)_retryNow {
    _retryTimer = nil;
    if (!_started) return;
    [_task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
    _task = nil;
    [_session invalidateAndCancel];
    _session = nil;

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 60;
    _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];

    NSUserDefaults *d = _defaults;
    NSString *base = [d stringForKey:kGatewayURLKey];
    if (!base.length) {
        NSString *host = [d stringForKey:kGatewayHostKey];
        NSInteger port = [d integerForKey:kGatewayPortKey];
        if (host.length && port > 0) base = [NSString stringWithFormat:@"ws://%@:%ld", host, (long)port];
    }
    if (!base.length) return;

    NSURLComponents *comp = [NSURLComponents componentsWithString:base];
    comp.path = @"/ws/register";
    NSMutableArray<NSURLQueryItem *> *q = [NSMutableArray array];
    [q addObject:[NSURLQueryItem queryItemWithName:@"deviceId" value:[self _deviceId]]];
    [q addObject:[NSURLQueryItem queryItemWithName:@"name" value:[self _deviceName]]];
    [q addObject:[NSURLQueryItem queryItemWithName:@"vncPort" value:[NSString stringWithFormat:@"%ld", (long)[self _vncPort]]]];
    NSString *token = [d stringForKey:kGatewayTokenKey];
    if (token.length) [q addObject:[NSURLQueryItem queryItemWithName:@"token" value:token]];
    comp.queryItems = q;

    _task = [_session webSocketTaskWithURL:comp.URL];
    TVLog(@"[gw] reconnecting...");
    [_task resume];
    [self _receive];
}

#pragma mark - NSURLSessionWebSocketDelegate

- (void)URLSession:(NSURLSession *)session
      webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
    didOpenWithProtocol:(nullable NSString *)protocol {
    _connected = YES;
    _retryDelay = 2.0;
    TVLog(@"[gw] registered: %@ (%@)", [self _deviceName], [self _deviceId]);
    [self _sendHello];
    [_helloTimer invalidate];
    _helloTimer = [NSTimer scheduledTimerWithTimeInterval:kHelloInterval target:self
                                                 selector:@selector(_sendHello) userInfo:nil repeats:YES];
}

- (void)URLSession:(NSURLSession *)session
      webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
    didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode reason:(nullable NSData *)reason {
    TVLog(@"[gw] connection closed (code=%ld)", (long)closeCode);
    [self _scheduleReconnect];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(nullable NSError *)error {
    if (error) TVLog(@"[gw] connection error: %@", error.localizedDescription);
    if (_connected) {
        [self _scheduleReconnect];
    }
}

@end
