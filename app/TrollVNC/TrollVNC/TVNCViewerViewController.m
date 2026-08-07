/*
 This file is part of TrollVNC
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/>.
*/

#import "TVNCViewerViewController.h"

#import <rfb/rfbclient.h>
#import <stdlib.h>
#import <string.h>

// SASL 静态插件链接桩：libsasl2 的 dlopen.o 引用了各机制插件的 init 符号，但本仓库的
// libsasl2.a 不含插件实现。内网自用不使用 SASL 认证，运行时不会调用这些函数；
// 仅提供符号以满足链接（若未来启用 SASL，需替换为真实插件实现）。
void *plain_client_plug_init(void) { return NULL; }
void *plain_server_plug_init(void) { return NULL; }
void *anonymous_client_plug_init(void) { return NULL; }
void *anonymous_server_plug_init(void) { return NULL; }
void *scram_client_plug_init(void) { return NULL; }
void *scram_server_plug_init(void) { return NULL; }
void *otp_client_plug_init(void) { return NULL; }
void *otp_server_plug_init(void) { return NULL; }
void *sasldb_auxprop_plug_init(void) { return NULL; }

static void *const kViewerClientTag = &kViewerClientTag;

#pragma mark - C 回调（libvncclient）

static rfbBool TVNCViewerMallocFrameBuffer(rfbClient *client) {
    size_t bytes = (size_t)client->width * (size_t)client->height * (size_t)(client->format.bitsPerPixel / 8);
    if (bytes == 0) return FALSE;
    client->frameBuffer = malloc(bytes);
    return client->frameBuffer ? TRUE : FALSE;
}

static void TVNCViewerFinishedUpdate(rfbClient *client) {
    TVNCViewerViewController *vc = (__bridge TVNCViewerViewController *)rfbClientGetClientData(client, kViewerClientTag);
    [vc markFrameReady];
}

@interface TVNCViewerViewController ()

@property(nonatomic, copy) NSString *host;
@property(nonatomic, assign) int port;
@property(nonatomic, copy) NSString *deviceName;

@property(nonatomic, strong) UIImageView *screenView;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIButton *gearBtn;   // 悬浮 ⚙（可拖动）
@property(nonatomic, assign) BOOL gearPlaced;

@property(nonatomic, assign) BOOL connected;
@property(nonatomic, assign) BOOL stopRequested;
@property(nonatomic, assign) BOOL frameReady;
@property(nonatomic, strong) NSThread *rfbThread;
@property(nonatomic, assign) rfbClient *client;            // 仅在 RFB 线程访问
@property(nonatomic, strong) NSMutableArray *pendingEvents; // void(^)(rfbClient*)
@property(nonatomic, assign) NSTimeInterval lastRender;

@end

@implementation TVNCViewerViewController

- (instancetype)initWithHost:(NSString *)host port:(int)port name:(NSString *)name {
    self = [super init];
    if (self) {
        _host = [host copy];
        _port = port;
        _deviceName = [name copy] ?: [host copy];
        _pendingEvents = [NSMutableArray array];
        self.hidesBottomBarWhenPushed = YES; // 全屏：隐藏底部 Tab
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    self.screenView = [[UIImageView alloc] init];
    self.screenView.translatesAutoresizingMaskIntoConstraints = NO;
    self.screenView.contentMode = UIViewContentModeScaleAspectFit;
    self.screenView.backgroundColor = [UIColor blackColor];
    self.screenView.userInteractionEnabled = YES;
    [self.view addSubview:self.screenView];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner.color = [UIColor whiteColor];
    [self.view addSubview:self.spinner];
    [self.spinner startAnimating];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.textColor = [UIColor whiteColor];
    self.statusLabel.font = [UIFont systemFontOfSize:13];
    self.statusLabel.text = [NSString stringWithFormat:@"连接 %@:%d …", self.host, self.port];
    [self.view addSubview:self.statusLabel];

    [self setupGearButton];
    [self setupGestures];

    [NSLayoutConstraint activateConstraints:@[
        // 全屏画面（隐藏导航/Tab 后占满）
        [self.screenView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.screenView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.screenView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.screenView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.screenView.centerXAnchor],
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.screenView.centerYAnchor],
        [self.statusLabel.centerXAnchor constraintEqualToAnchor:self.screenView.centerXAnchor],
        [self.statusLabel.topAnchor constraintEqualToAnchor:self.spinner.bottomAnchor constant:12],
    ]];

    self.rfbThread = [[NSThread alloc] initWithTarget:self selector:@selector(rfbLoop) object:nil];
    [self.rfbThread start];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setNavigationBarHidden:YES animated:animated];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!self.gearPlaced) {
        self.gearPlaced = YES;
        CGFloat s = self.gearBtn.bounds.size.width;
        CGRect f = self.gearBtn.frame;
        f.origin.x = self.view.bounds.size.width - s - 16;
        f.origin.y = self.view.bounds.size.height - s - 56;
        self.gearBtn.frame = f;
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.navigationController setNavigationBarHidden:NO animated:animated];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    self.stopRequested = YES;
}

- (void)dealloc {
    self.stopRequested = YES;
}

#pragma mark - 悬浮 ⚙（可拖动 + 竖排菜单）

- (void)setupGearButton {
    CGFloat s = 52;
    self.gearBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.gearBtn setImage:[UIImage systemImageNamed:@"gearshape.fill"] forState:UIControlStateNormal];
    self.gearBtn.tintColor = [UIColor whiteColor];
    self.gearBtn.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.85];
    self.gearBtn.layer.cornerRadius = s / 2;
    self.gearBtn.layer.borderWidth = 1;
    self.gearBtn.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
    self.gearBtn.frame = CGRectMake(self.view.bounds.size.width - s - 16, self.view.bounds.size.height - s - 56, s, s);
    [self.view addSubview:self.gearBtn];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragGear:)];
    [self.gearBtn addGestureRecognizer:pan];

    __weak typeof(self) weakSelf = self;
    NSArray<NSArray *> *ops = @[
        @[ @"home", @"Home", @"house.fill" ],
        @[ @"power", @"电源", @"power" ],
        @[ @"volup", @"音量+", @"speaker.wave.2.fill" ],
        @[ @"voldn", @"音量−", @"speaker.wave.1.fill" ],
        @[ @"mute", @"静音", @"speaker.slash.fill" ],
        @[ @"briup", @"亮度+", @"sun.max.fill" ],
        @[ @"bridn", @"亮度−", @"sun.min.fill" ],
        @[ @"keyboard", @"键盘", @"keyboard" ],
        @[ @"clipboard", @"剪贴板", @"doc.on.clipboard.fill" ],
    ];
    NSMutableArray<UIMenuElement *> *children = [NSMutableArray array];
    for (NSArray *op in ops) {
        NSInteger tag = [self tagForOp:op[0]];
        UIAction *a = [UIAction actionWithTitle:op[1]
                                          image:[UIImage systemImageNamed:op[2]]
                                     identifier:nil
                                        handler:^(__kindof UIAction *action) {
                                            [weakSelf menuOpTapped:tag];
                                        }];
        [children addObject:a];
    }
    UIAction *end = [UIAction actionWithTitle:@"结束控制"
                                        image:[UIImage systemImageNamed:@"xmark.circle.fill"]
                                   identifier:nil
                                      handler:^(__kindof UIAction *action) {
                                          [weakSelf stopAndExit];
                                      }];
    end.attributes = UIMenuElementAttributesDestructive;
    [children addObject:end];

    self.gearBtn.menu = [UIMenu menuWithTitle:@"控制" children:children];
    self.gearBtn.showsMenuAsPrimaryAction = YES;
}

- (void)dragGear:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateChanged || g.state == UIGestureRecognizerStateEnded) {
        CGPoint t = [g translationInView:self.view];
        CGPoint c = self.gearBtn.center;
        c.x += t.x;
        c.y += t.y;
        CGFloat s = self.gearBtn.bounds.size.width;
        CGFloat top = s / 2 + self.view.safeAreaInsets.top;
        CGFloat bottom = self.view.bounds.size.height - s / 2 - self.view.safeAreaInsets.bottom;
        c.x = MAX(s / 2, MIN(self.view.bounds.size.width - s / 2, c.x));
        c.y = MAX(top, MIN(bottom, c.y));
        self.gearBtn.center = c;
        [g setTranslation:CGPointZero inView:self.view];
    }
}

- (void)menuOpTapped:(NSInteger)tag {
    if (tag == 8) { // 键盘
        [self keyboardTapped];
        return;
    }
    if (tag == 9) { // 剪贴板
        [self clipboardTapped];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [self enqueueRFBEvent:^(rfbClient *c) {
        [weakSelf performOp:tag client:c];
    }];
}

#pragma mark - 操作映射

- (NSInteger)tagForOp:(NSString *)op {
    if ([op isEqualToString:@"home"]) return 1;
    if ([op isEqualToString:@"power"]) return 2;
    if ([op isEqualToString:@"volup"]) return 3;
    if ([op isEqualToString:@"voldn"]) return 4;
    if ([op isEqualToString:@"mute"]) return 5;
    if ([op isEqualToString:@"briup"]) return 6;
    if ([op isEqualToString:@"bridn"]) return 7;
    if ([op isEqualToString:@"keyboard"]) return 8;
    return 9; // clipboard
}

- (void)performOp:(NSInteger)op client:(rfbClient *)c {
    switch (op) {
        case 1: SendKeyEvent(c, 0xff50, TRUE); SendKeyEvent(c, 0xff50, FALSE); break;          // Home
        case 2: SendPointerEvent(c, 1, 1, 2); SendPointerEvent(c, 1, 1, 0); break;             // 电源（中键）
        case 3: SendKeyEvent(c, 0x1008ff13, TRUE); SendKeyEvent(c, 0x1008ff13, FALSE); break;  // 音量+
        case 4: SendKeyEvent(c, 0x1008ff11, TRUE); SendKeyEvent(c, 0x1008ff11, FALSE); break;  // 音量−
        case 5: SendKeyEvent(c, 0x1008ff12, TRUE); SendKeyEvent(c, 0x1008ff12, FALSE); break;  // 静音
        case 6: SendKeyEvent(c, 0x1008ff03, TRUE); SendKeyEvent(c, 0x1008ff03, FALSE); break;  // 亮度+
        case 7: SendKeyEvent(c, 0x1008ff05, TRUE); SendKeyEvent(c, 0x1008ff05, FALSE); break;  // 亮度−
    }
}

- (void)keyboardTapped {
    if (!self.connected) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"发送按键文本"
                                                               message:@"将文本作为按键发送到设备"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"输入要发送的文本";
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [a addAction:[UIAlertAction actionWithTitle:@"发送" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *text = a.textFields.firstObject.text ?: @"";
        [weakSelf sendText:text];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)sendText:(NSString *)text {
    if (!text.length) return;
    __weak typeof(self) weakSelf = self;
    [self enqueueRFBEvent:^(rfbClient *c) {
        for (NSUInteger i = 0; i < text.length; i++) {
            unichar ch = [text characterAtIndex:i];
            if (ch < 0x20 || ch > 0x7E) continue; // v1 仅 ASCII 可见字符
            SendKeyEvent(c, (uint32_t)ch, TRUE);
            SendKeyEvent(c, (uint32_t)ch, FALSE);
        }
    }];
}

- (void)clipboardTapped {
    if (!self.connected) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"写入设备剪贴板"
                                                               message:nil
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"粘贴要写入设备的内容";
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [a addAction:[UIAlertAction actionWithTitle:@"写入" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *text = a.textFields.firstObject.text ?: @"";
        [weakSelf sendClipboard:text];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)sendClipboard:(NSString *)text {
    __weak typeof(self) weakSelf = self;
    [self enqueueRFBEvent:^(rfbClient *c) {
        const char *utf8 = text.UTF8String ?: "";
        SendClientCutTextUTF8(c, (char *)utf8, (int)strlen(utf8));
    }];
}

#pragma mark - 手势

- (void)setupGestures {
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    [self.screenView addGestureRecognizer:tap];
}

- (void)handleTap:(UITapGestureRecognizer *)g {
    if (!self.connected) return;
    CGPoint p = [g locationInView:self.screenView];
    __weak typeof(self) weakSelf = self;
    [self enqueueRFBEvent:^(rfbClient *c) {
        CGPoint f = [weakSelf mapPoint:p toClient:c];
        SendPointerEvent(c, (int)f.x, (int)f.y, 1);
        SendPointerEvent(c, (int)f.x, (int)f.y, 0);
    }];
}

- (CGPoint)mapPoint:(CGPoint)viewPoint toClient:(rfbClient *)c {
    if (!c || c->width <= 0 || c->height <= 0) return CGPointZero;
    CGFloat vw = self.screenView.bounds.size.width;
    CGFloat vh = self.screenView.bounds.size.height;
    CGFloat fw = c->width, fh = c->height;
    CGFloat scale = MIN(vw / fw, vh / fh);
    if (scale <= 0) return CGPointZero;
    CGFloat ox = (vw - fw * scale) / 2;
    CGFloat oy = (vh - fh * scale) / 2;
    CGFloat fx = (viewPoint.x - ox) / scale;
    CGFloat fy = (viewPoint.y - oy) / scale;
    fx = MAX(0, MIN(fw - 1, fx));
    fy = MAX(0, MIN(fh - 1, fy));
    return CGPointMake(fx, fy);
}

#pragma mark - RFB 事件队列（主线程入队，RFB 线程消费）

- (void)enqueueRFBEvent:(void (^)(rfbClient *c))block {
    @synchronized(self) {
        [self.pendingEvents addObject:block];
    }
}

- (NSArray *)drainRFBEvents {
    NSArray *events;
    @synchronized(self) {
        if (!self.pendingEvents.count) return nil;
        events = [self.pendingEvents copy];
        [self.pendingEvents removeAllObjects];
    }
    return events;
}

#pragma mark - RFB 线程

- (void)rfbLoop {
    @autoreleasepool {
        int argc = 1;
        char arg0[] = "viewer";
        char *argv[] = { arg0, NULL };
        rfbClient *client = rfbGetClient(8, 3, 4);
        if (!client) {
            [self failWithMessage:@"初始化客户端失败"];
            return;
        }
        client->serverHost = strdup(self.host.UTF8String);
        client->serverPort = self.port;
        client->MallocFrameBuffer = TVNCViewerMallocFrameBuffer;
        client->FinishedFrameBufferUpdate = TVNCViewerFinishedUpdate;
        rfbClientSetClientData(client, kViewerClientTag, (__bridge void *)self);

        if (!rfbInitClient(client, &argc, argv)) {
            rfbClientCleanup(client);
            [self failWithMessage:@"连接失败或设备不可达"];
            return;
        }
        self.client = client;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.connected = YES;
            self.statusLabel.text = [NSString stringWithFormat:@"已连接 %@", self.deviceName];
            [self.spinner stopAnimating];
        });
        // 首次全量请求
        SendFramebufferUpdateRequest(client, 0, 0, client->width, client->height, FALSE);

        while (!self.stopRequested) {
            int sel = WaitForMessage(client, 100000); // 100ms
            if (sel < 0) break;
            if (sel > 0) {
                if (!HandleRFBServerMessage(client)) break;
                SendIncrementalFramebufferUpdateRequest(client);
            }
            // 消费主线程下发的事件
            NSArray *events = [self drainRFBEvents];
            for (void (^b)(rfbClient *) in events) {
                b(client);
            }
            // 渲染新帧（限频 ~15fps）
            if (self.frameReady && !self.stopRequested) {
                NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
                if (now - self.lastRender >= 0.066) {
                    self.lastRender = now;
                    self.frameReady = NO;
                    [self renderFrame:client];
                }
            }
        }
        rfbClientCleanup(client);
        self.client = NULL;
        if (!self.stopRequested) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.statusLabel.text = @"已断开";
                [self.spinner stopAnimating];
                [self toastAndPop:@"连接已断开"];
            });
        }
    }
}

- (void)markFrameReady {
    self.frameReady = YES;
}

- (void)renderFrame:(rfbClient *)client {
    if (!client->frameBuffer) return;
    int w = client->width, h = client->height;
    int bpp = client->format.bitsPerPixel / 8;
    if (w <= 0 || h <= 0 || bpp < 3) return;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo info = (client->format.redShift == 0)
        ? (kCGImageAlphaNoneSkipLast | kCGBitmapByteOrderDefault)
        : (kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGContextRef ctx = CGBitmapContextCreate(client->frameBuffer, (size_t)w, (size_t)h, 8, (size_t)w * bpp, cs, info);
    if (!ctx) {
        CGColorSpaceRelease(cs);
        return;
    }
    CGImageRef cg = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    if (!cg) return;
    UIImage *img = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.stopRequested) self.screenView.image = img;
    });
}

#pragma mark - 失败/退出

- (void)failWithMessage:(NSString *)msg {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.spinner stopAnimating];
        self.statusLabel.text = msg;
        [self toastAndPop:msg];
    });
}

- (void)toastAndPop:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:nil
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [self.navigationController popViewControllerAnimated:YES];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)stopAndExit {
    self.stopRequested = YES;
    [self.navigationController popViewControllerAnimated:YES];
}

@end
