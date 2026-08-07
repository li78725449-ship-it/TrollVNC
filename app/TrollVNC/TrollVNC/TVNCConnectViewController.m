/*
 This file is part of TrollVNC
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors
 ... license ...
*/

#import "TVNCConnectViewController.h"
#import "TVNCServiceCoordinator.h"
#import "Control.h"
#import "TVNCUtil.h"
#import "TVNCClientListController.h"
#import <sys/socket.h>

#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <netinet/in.h>
#import <string.h>
#import <UIKit/UIKit.h>

static NSString *const kDefaultsSuite = @"com.82flex.trollvnc";

#pragma mark - 工具

static NSString *TVNCEn0IPv4(void) {
    struct ifaddrs *ifaList = NULL;
    if (getifaddrs(&ifaList) != 0 || !ifaList) return nil;
    NSString *ip = nil;
    for (struct ifaddrs *ifa = ifaList; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || !ifa->ifa_name) continue;
        if (strcmp(ifa->ifa_name, "en0") != 0) continue;
        if (!(ifa->ifa_flags & IFF_UP) || (ifa->ifa_flags & IFF_LOOPBACK)) continue;
        if (ifa->ifa_addr->sa_family != AF_INET) continue;
        struct sockaddr_in *sin = (struct sockaddr_in *)ifa->ifa_addr;
        char buf[INET_ADDRSTRLEN] = {0};
        if (inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf))) {
            ip = [NSString stringWithUTF8String:buf];
            break;
        }
    }
    freeifaddrs(ifaList);
    return ip;
}

// 二维码生成（安全版：@try 保护 + 由调用方在后台线程执行）
static UIImage *TVNCQRCodeImage(NSString *content) {
    if (!content.length) return nil;
    @try {
        NSData *data = [content dataUsingEncoding:NSISOLatin1StringEncoding];
        if (!data) return nil;
        CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
        [filter setValue:data forKey:@"inputMessage"];
        [filter setValue:@"M" forKey:@"inputCorrectionLevel"];
        CIImage *out = filter.outputImage;
        if (!out) return nil;
        CIImage *scaled = [out imageByApplyingTransform:CGAffineTransformMakeScale(10, 10)];
        CIContext *ctx = [CIContext contextWithOptions:@{}];
        CGImageRef cg = [ctx createCGImage:scaled fromRect:scaled.extent];
        UIImage *img = cg ? [UIImage imageWithCGImage:cg] : nil;
        if (cg) CGImageRelease(cg);
        return img;
    } @catch (NSException *e) {
        NSLog(@"[TVNC] QR generation failed: %@ %@", e.name, e.reason);
        return nil;
    }
}

#pragma mark - 渐变 Hero 卡（layoutSubviews 更新渐变 frame，确保可见）

@interface TVNCGradientCard : UIView
@property(nonatomic, strong) CAGradientLayer *grad;
@end

@implementation TVNCGradientCard
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _grad = [CAGradientLayer layer];
        _grad.colors = @[
            (id)[UIColor colorWithRed:0.16 green:0.35 blue:0.98 alpha:1].CGColor,
            (id)[UIColor colorWithRed:0.24 green:0.52 blue:1.0 alpha:1].CGColor,
            (id)[UIColor colorWithRed:0.42 green:0.72 blue:1.0 alpha:1].CGColor,
        ];
        _grad.startPoint = CGPointMake(0, 0);
        _grad.endPoint = CGPointMake(1, 1);
        [self.layer addSublayer:_grad];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    self.grad.frame = self.bounds;
}
@end

#pragma mark - 连接页

@interface TVNCConnectViewController ()

@property(nonatomic, strong) UIView *statusDot;              // Hero 网关绿点
@property(nonatomic, strong) UILabel *gatewayLabel;          // Hero 网关 ip:端口
@property(nonatomic, strong) UILabel *nameLabel;             // Hero 设备名
@property(nonatomic, strong) UISegmentedControl *modeSegment;
@property(nonatomic, strong) UIView *contentCard;
@property(nonatomic, strong) UIImageView *qrImageView;
@property(nonatomic, strong) UILabel *qrAddrLabel;
@property(nonatomic, strong) UIStackView *statusPill;
@property(nonatomic, strong) UIView *statusDotView;
@property(nonatomic, strong) UILabel *statusPillLabel;
@property(nonatomic, strong) UILabel *clientsCountLabel;
@property(nonatomic, strong) TVNCClientListController *clientsVC;
@property(nonatomic, strong) NSUserDefaults *defaults;

// 反向连接页
@property(nonatomic, strong) UISegmentedControl *reverseSegment;
@property(nonatomic, strong) UILabel *reverseIdLabel;
@property(nonatomic, strong) UITextField *reverseServerField;
@property(nonatomic, strong) UITextField *reverseIdField;
@property(nonatomic, strong) UITextField *reverseIntervalField;
@property(nonatomic, strong) UIButton *reverseDialButton;
@property(nonatomic, assign) BOOL reverseDialing;
@property(nonatomic, assign) BOOL reverseConnected;

@end

@implementation TVNCConnectViewController

- (instancetype)init {
    self = [super init];
    if (self) {
        _defaults = [[NSUserDefaults alloc] initWithSuiteName:kDefaultsSuite];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.title = @"连接";
    [self setupStatusPill];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    [scroll addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:16],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-16],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-16],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-32],
    ]];

    [stack addArrangedSubview:[self makeHeroCard]];
    [stack addArrangedSubview:[self makeModeCard]];

    self.contentCard = [[UIView alloc] init];
    self.contentCard.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:self.contentCard];

    [stack addArrangedSubview:[self makeClientsCard]];
    [self refreshContentCard];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshStatus)
                                                 name:TVNCServiceStatusDidChangeNotification
                                               object:nil];
    [self refreshStatus];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self refreshStatus];
    [self generateQRAsync];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateStatusPill];
}

#pragma mark - 右上角状态胶囊

- (void)setupStatusPill {
    self.statusDotView = [[UIView alloc] init];
    self.statusDotView.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusDotView.layer.cornerRadius = 4;

    self.statusPillLabel = [[UILabel alloc] init];
    self.statusPillLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.statusPillLabel.textColor = [UIColor labelColor];

    UIStackView *pill = [[UIStackView alloc] initWithArrangedSubviews:@[self.statusDotView, self.statusPillLabel]];
    pill.axis = UILayoutConstraintAxisHorizontal;
    pill.spacing = 6;
    pill.alignment = UIStackViewAlignmentCenter;
    pill.layoutMarginsRelativeArrangement = YES;
    pill.layoutMargins = UIEdgeInsetsMake(6, 12, 6, 12);
    pill.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    pill.layer.cornerRadius = 15;
    pill.layer.borderWidth = 1;
    pill.layer.borderColor = [UIColor separatorColor].CGColor;
    pill.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusPill = pill;
    [NSLayoutConstraint activateConstraints:@[
        [self.statusDotView.widthAnchor constraintEqualToConstant:8],
        [self.statusDotView.heightAnchor constraintEqualToConstant:8],
    ]];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:pill];
}

- (void)updateStatusPill {
    BOOL reverse = (self.modeSegment.selectedSegmentIndex == 1);
    BOOL connected = reverse ? self.reverseConnected
                             : [[TVNCServiceCoordinator sharedCoordinator] isServiceRunning];
    self.statusDotView.backgroundColor = connected ? [UIColor systemGreenColor] : [UIColor systemGrayColor];
    self.statusPillLabel.text = connected ? @"已连接" : @"未连接";
}

#pragma mark - Hero

- (UIView *)makeHeroCard {
    TVNCGradientCard *card = [[TVNCGradientCard alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.cornerRadius = 24;
    card.clipsToBounds = YES;

    self.nameLabel = [[UILabel alloc] init];
    self.nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.nameLabel.font = [UIFont boldSystemFontOfSize:21];
    self.nameLabel.textColor = [UIColor whiteColor];
    self.nameLabel.text = [[UIDevice currentDevice] name];

    // 第 2 行：绿色圆点 + 网关 ip:端口（状态已移至右上角胶囊）
    self.statusDot = [[UIView alloc] init];
    self.statusDot.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusDot.layer.cornerRadius = 4;
    self.statusDot.backgroundColor = [UIColor systemGreenColor];

    self.gatewayLabel = [[UILabel alloc] init];
    self.gatewayLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.gatewayLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    self.gatewayLabel.textColor = [UIColor colorWithWhite:1 alpha:0.94];
    self.gatewayLabel.numberOfLines = 1;
    self.gatewayLabel.adjustsFontSizeToFitWidth = YES;
    self.gatewayLabel.minimumScaleFactor = 0.6;

    [card addSubview:self.nameLabel];
    [card addSubview:self.statusDot];
    [card addSubview:self.gatewayLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.nameLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:22],
        [self.nameLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:22],
        [self.nameLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-22],

        [self.statusDot.topAnchor constraintEqualToAnchor:self.nameLabel.bottomAnchor constant:16],
        [self.statusDot.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:22],
        [self.statusDot.widthAnchor constraintEqualToConstant:8],
        [self.statusDot.heightAnchor constraintEqualToConstant:8],
        [self.statusDot.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-22],

        [self.gatewayLabel.leadingAnchor constraintEqualToAnchor:self.statusDot.trailingAnchor constant:8],
        [self.gatewayLabel.centerYAnchor constraintEqualToAnchor:self.statusDot.centerYAnchor],
        [self.gatewayLabel.trailingAnchor constraintLessThanOrEqualToAnchor:card.trailingAnchor constant:-22],
    ]];
    return card;
}

#pragma mark - 模式分段

- (UIView *)makeModeCard {
    UIView *card = [self newCard];
    self.modeSegment = [[UISegmentedControl alloc] initWithItems:@[@"内网直连", @"反向连接"]];
    self.modeSegment.translatesAutoresizingMaskIntoConstraints = NO;
    self.modeSegment.selectedSegmentIndex = 0;
    [self.modeSegment addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged];
    [card addSubview:self.modeSegment];
    [NSLayoutConstraint activateConstraints:@[
        [self.modeSegment.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [self.modeSegment.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [self.modeSegment.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
        [self.modeSegment.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12],
    ]];
    return card;
}

- (void)modeChanged:(UISegmentedControl *)seg {
    BOOL reverse = (seg.selectedSegmentIndex == 1);
    if (!reverse) {
        // 切回内网直连 = 断开反向连接并重启服务（模式互斥）
        NSString *mode = [self.defaults stringForKey:@"ReverseMode"];
        if ([mode isEqualToString:@"viewer"] || [mode isEqualToString:@"repeater"]) {
            [self.defaults setObject:@"none" forKey:@"ReverseMode"];
            [self.defaults synchronize];
            self.reverseDialing = NO;
            self.reverseConnected = NO;
            TVNCRestartVNCService();
        }
        self.clientsVC.reverseMode = NO;
        [self.clientsVC refreshNow];
        [self refreshContentCard];
        [self generateQRAsync];
    } else {
        // 切到反向连接：清掉直连视图状态，列表只看反向对端
        self.clientsVC.reverseMode = YES;
        [self.clientsVC refreshNow];
        [self refreshContentCard];
    }
    [self updateStatusPill];
    [self updateReverseDialUI];
}

#pragma mark - 内容卡切换（内网直连 / 反向连接）

- (void)refreshContentCard {
    if (!self.contentCard) return;
    for (UIView *v in [self.contentCard.subviews copy]) {
        [v removeFromSuperview];
    }
    BOOL reverse = (self.modeSegment.selectedSegmentIndex == 1);
    UIView *card = reverse ? [self makeReverseCard] : [self makeDirectCard];
    [self.contentCard addSubview:card];
    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:self.contentCard.topAnchor],
        [card.leadingAnchor constraintEqualToAnchor:self.contentCard.leadingAnchor],
        [card.trailingAnchor constraintEqualToAnchor:self.contentCard.trailingAnchor],
        [card.bottomAnchor constraintEqualToAnchor:self.contentCard.bottomAnchor],
    ]];
}

#pragma mark - 反向连接卡

- (UIView *)makeReverseCard {
    UIView *card = [self newCard];
    UILabel *title = [self cardTitle:@"反向连接（需监听 VNC）"];
    [card addSubview:title];

    self.reverseSegment = [[UISegmentedControl alloc] initWithItems:@[@"客户端", @"中继器"]];
    self.reverseSegment.translatesAutoresizingMaskIntoConstraints = NO;
    NSString *mode = [self.defaults stringForKey:@"ReverseMode"];
    self.reverseSegment.selectedSegmentIndex = ([mode isEqualToString:@"repeater"]) ? 1 : 0;
    [self.reverseSegment addTarget:self action:@selector(reverseTypeChanged:) forControlEvents:UIControlEventValueChanged];
    [card addSubview:self.reverseSegment];

    // 字段纵向栈（隐藏行会自动折叠）
    UIStackView *fieldStack = [[UIStackView alloc] init];
    fieldStack.translatesAutoresizingMaskIntoConstraints = NO;
    fieldStack.axis = UILayoutConstraintAxisVertical;
    fieldStack.spacing = 8;

    UILabel *serverLabel = [self fieldLabel:@"服务器地址"];
    self.reverseServerField = [self fieldInput];
    self.reverseServerField.placeholder = @"host:port";
    self.reverseServerField.keyboardType = UIKeyboardTypeURL;
    self.reverseServerField.text = [self.defaults stringForKey:@"ReverseSocket"] ?: @"";

    self.reverseIdLabel = [self fieldLabel:@"中继 ID"];
    self.reverseIdField = [self fieldInput];
    self.reverseIdField.placeholder = @"仅中继器模式需要";
    self.reverseIdField.keyboardType = UIKeyboardTypeNumberPad;
    NSNumber *rid = [self.defaults objectForKey:@"ReverseRepeaterID"];
    if (rid) self.reverseIdField.text = [NSString stringWithFormat:@"%@", rid];

    UILabel *intervalLabel = [self fieldLabel:@"重拨间隔（秒）"];
    self.reverseIntervalField = [self fieldInput];
    self.reverseIntervalField.placeholder = @"0 = 关闭";
    self.reverseIntervalField.keyboardType = UIKeyboardTypeNumberPad;
    NSNumber *retry = [self.defaults objectForKey:@"ReverseRetrySec"];
    if (retry) self.reverseIntervalField.text = [NSString stringWithFormat:@"%@", retry];

    [fieldStack addArrangedSubview:serverLabel];
    [fieldStack addArrangedSubview:self.reverseServerField];
    [fieldStack addArrangedSubview:self.reverseIdLabel];
    [fieldStack addArrangedSubview:self.reverseIdField];
    [fieldStack addArrangedSubview:intervalLabel];
    [fieldStack addArrangedSubview:self.reverseIntervalField];
    [card addSubview:fieldStack];

    BOOL repeater = (self.reverseSegment.selectedSegmentIndex == 1);
    self.reverseIdLabel.hidden = !repeater;
    self.reverseIdField.hidden = !repeater;

    // 拨号按钮（带边框）
    self.reverseDialButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.reverseDialButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.reverseDialButton.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [self.reverseDialButton setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
    [self.reverseDialButton setTitleColor:[UIColor tertiaryLabelColor] forState:UIControlStateDisabled];
    self.reverseDialButton.layer.cornerRadius = 10;
    self.reverseDialButton.layer.borderWidth = 1;
    self.reverseDialButton.layer.borderColor = [UIColor systemBlueColor].CGColor;
    [self.reverseDialButton setContentEdgeInsets:UIEdgeInsetsMake(8, 40, 8, 40)];
    [self.reverseDialButton addTarget:self action:@selector(dialReverse:) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:self.reverseDialButton];

    // 提示
    UILabel *hint = [[UILabel alloc] init];
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    hint.font = [UIFont systemFontOfSize:12];
    hint.textColor = [UIColor secondaryLabelColor];
    hint.textAlignment = NSTextAlignmentCenter;
    hint.text = @"反向模式会关闭 5901 / 5801 / Bonjour";
    [card addSubview:hint];

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [title.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],

        [self.reverseSegment.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:12],
        [self.reverseSegment.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [self.reverseSegment.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],

        [fieldStack.topAnchor constraintEqualToAnchor:self.reverseSegment.bottomAnchor constant:14],
        [fieldStack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [fieldStack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],

        [self.reverseDialButton.topAnchor constraintEqualToAnchor:fieldStack.bottomAnchor constant:18],
        [self.reverseDialButton.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [self.reverseDialButton.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [self.reverseDialButton.heightAnchor constraintEqualToConstant:46],

        [hint.topAnchor constraintEqualToAnchor:self.reverseDialButton.bottomAnchor constant:10],
        [hint.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [hint.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [hint.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
    ]];

    [self updateReverseDialUI];
    return card;
}

- (void)reverseTypeChanged:(UISegmentedControl *)seg {
    BOOL repeater = (seg.selectedSegmentIndex == 1);
    self.reverseIdLabel.hidden = !repeater;
    self.reverseIdField.hidden = !repeater;
}

- (void)dialReverse:(UIButton *)sender {
    NSString *server = [self.reverseServerField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!server.length) {
        [self toast:@"请填写服务器地址（host:port）"];
        return;
    }
    NSString *mode = (self.reverseSegment.selectedSegmentIndex == 1) ? @"repeater" : @"viewer";
    [self.defaults setObject:mode forKey:@"ReverseMode"];
    [self.defaults setObject:server forKey:@"ReverseSocket"];
    [self.defaults setInteger:[self.reverseIdField.text integerValue] forKey:@"ReverseRepeaterID"];
    double retry = [self.reverseIntervalField.text doubleValue];
    if (retry < 0) retry = 0;
    [self.defaults setDouble:retry forKey:@"ReverseRetrySec"];
    [self.defaults synchronize];

    self.reverseDialing = YES;
    [sender setTitle:@"拨号中…" forState:UIControlStateNormal];
    sender.enabled = NO;
    TVNCRestartVNCService();

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.reverseDialing = NO;
        [strongSelf updateReverseDialUI];
    });
}

- (void)updateReverseDialUI {
    if (!self.reverseDialButton) return;
    if (self.reverseDialing) {
        [self.reverseDialButton setTitle:@"拨号中…" forState:UIControlStateNormal];
        self.reverseDialButton.enabled = NO;
        return;
    }
    if (self.reverseConnected) {
        [self.reverseDialButton setTitle:@"已连接" forState:UIControlStateNormal];
        self.reverseDialButton.enabled = NO;
        self.reverseDialButton.layer.borderColor = [UIColor systemGrayColor].CGColor;
    } else {
        [self.reverseDialButton setTitle:@"拨号" forState:UIControlStateNormal];
        self.reverseDialButton.enabled = YES;
        self.reverseDialButton.layer.borderColor = [UIColor systemBlueColor].CGColor;
    }
}

- (UILabel *)fieldLabel:(NSString *)t {
    UILabel *l = [[UILabel alloc] init];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    l.textColor = [UIColor secondaryLabelColor];
    l.text = t;
    return l;
}

- (UITextField *)fieldInput {
    UITextField *f = [[UITextField alloc] init];
    f.translatesAutoresizingMaskIntoConstraints = NO;
    f.borderStyle = UITextBorderStyleRoundedRect;
    f.font = [UIFont systemFontOfSize:15];
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    return f;
}

#pragma mark - 扫码直连卡

- (UIView *)makeDirectCard {
    UIView *card = [self newCard];
    UILabel *title = [self cardTitle:@"扫码直连"];
    [card addSubview:title];

    self.qrImageView = [[UIImageView alloc] init];
    self.qrImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.qrImageView.contentMode = UIViewContentModeScaleAspectFit;
    self.qrImageView.backgroundColor = [UIColor whiteColor];
    self.qrImageView.layer.cornerRadius = 8;
    self.qrImageView.layer.masksToBounds = YES;

    self.qrAddrLabel = [[UILabel alloc] init];
    self.qrAddrLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.qrAddrLabel.font = [UIFont boldSystemFontOfSize:16];
    self.qrAddrLabel.textColor = [UIColor labelColor];
    self.qrAddrLabel.textAlignment = NSTextAlignmentCenter;

    UILabel *hint = [[UILabel alloc] init];
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    hint.font = [UIFont systemFontOfSize:12];
    hint.textColor = [UIColor secondaryLabelColor];
    hint.textAlignment = NSTextAlignmentCenter;
    hint.text = @"内网设备扫码即可连接";

    [card addSubview:self.qrImageView];
    [card addSubview:self.qrAddrLabel];
    [card addSubview:hint];

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [title.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [self.qrImageView.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:14],
        [self.qrImageView.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [self.qrImageView.widthAnchor constraintEqualToConstant:170],
        [self.qrImageView.heightAnchor constraintEqualToConstant:170],
        [self.qrAddrLabel.topAnchor constraintEqualToAnchor:self.qrImageView.bottomAnchor constant:12],
        [self.qrAddrLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [self.qrAddrLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [hint.topAnchor constraintEqualToAnchor:self.qrAddrLabel.bottomAnchor constant:6],
        [hint.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [hint.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [hint.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
    ]];

    return card;
}

- (void)generateQRAsync {
    NSInteger httpPort = [self.defaults integerForKey:@"HttpPort"];
    NSString *ip = TVNCEn0IPv4();
    if (httpPort <= 0 || !ip.length) {
        self.qrAddrLabel.text = httpPort <= 0 ? @"HTTP 网页未开启（设置 → 直连参数 → HTTP 端口）" : @"未获取到 IP";
        self.qrImageView.hidden = YES;
        return;
    }
    NSString *url = [NSString stringWithFormat:@"http://%@:%ld", ip, (long)httpPort];
    self.qrAddrLabel.text = url;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIImage *qr = TVNCQRCodeImage(url);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (qr) {
                self.qrImageView.image = qr;
                self.qrImageView.hidden = NO;
            } else {
                self.qrImageView.hidden = YES;
            }
        });
    });
}

#pragma mark - 客户端入口卡

- (UIView *)makeClientsCard {
    UIView *card = [self newCard];
    UILabel *title = [self cardTitle:@"客户端"];
    [card addSubview:title];

    self.clientsCountLabel = [[UILabel alloc] init];
    self.clientsCountLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.clientsCountLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.clientsCountLabel.textColor = [UIColor secondaryLabelColor];
    self.clientsCountLabel.text = @"在线 0 · 冻结 0";
    [card addSubview:self.clientsCountLabel];

    UIButton *disconnectAll = [UIButton buttonWithType:UIButtonTypeSystem];
    disconnectAll.translatesAutoresizingMaskIntoConstraints = NO;
    [disconnectAll setTitle:@"全部断开" forState:UIControlStateNormal];
    disconnectAll.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [disconnectAll setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    [disconnectAll addTarget:self action:@selector(disconnectAllClients) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:disconnectAll];

    // 内嵌客户端列表（子控制器，卡片内直接显示与管理）
    UIView *tableContainer = [[UIView alloc] init];
    tableContainer.translatesAutoresizingMaskIntoConstraints = NO;
    tableContainer.layer.cornerRadius = 12;
    tableContainer.clipsToBounds = YES;
    [card addSubview:tableContainer];

    TVNCClientListController *clientsVC = [[TVNCClientListController alloc] init];
    NSBundle *resBundle = [NSBundle bundleWithPath:[[NSBundle mainBundle] pathForResource:@"TrollVNCPrefs"
                                                                                   ofType:@"bundle"]];
    clientsVC.bundle = resBundle ?: [NSBundle mainBundle];
    clientsVC.primaryColor = [UIColor systemBlueColor];
    clientsVC.embedded = YES;
    __weak typeof(self) weakSelf = self;
    clientsVC.onCountChange = ^(NSInteger online, NSInteger frozen) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf) {
            strongSelf.clientsCountLabel.text =
                [NSString stringWithFormat:@"在线 %ld · 冻结 %ld", (long)online, (long)frozen];
        }
    };
    clientsVC.onReverseConnectionChange = ^(BOOL connected) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf) {
            strongSelf.reverseConnected = connected;
            [strongSelf updateStatusPill];
            [strongSelf updateReverseDialUI];
        }
    };
    [self addChildViewController:clientsVC];
    clientsVC.view.translatesAutoresizingMaskIntoConstraints = NO;
    [tableContainer addSubview:clientsVC.view];
    [clientsVC didMoveToParentViewController:self];
    self.clientsVC = clientsVC;

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [self.clientsCountLabel.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [self.clientsCountLabel.leadingAnchor constraintEqualToAnchor:title.trailingAnchor constant:8],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:disconnectAll.leadingAnchor constant:-8],
        [disconnectAll.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [disconnectAll.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [tableContainer.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:10],
        [tableContainer.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:8],
        [tableContainer.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-8],
        [tableContainer.heightAnchor constraintEqualToConstant:260],
        [tableContainer.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8],

        [clientsVC.view.topAnchor constraintEqualToAnchor:tableContainer.topAnchor],
        [clientsVC.view.leadingAnchor constraintEqualToAnchor:tableContainer.leadingAnchor],
        [clientsVC.view.trailingAnchor constraintEqualToAnchor:tableContainer.trailingAnchor],
        [clientsVC.view.bottomAnchor constraintEqualToAnchor:tableContainer.bottomAnchor],
    ]];
    return card;
}

- (void)disconnectAllClients {
    if (self.modeSegment.selectedSegmentIndex == 1) {
        // 反向模式：全部断开 = 复位反向连接（写 none + 重启），同步清理右上角/拨号按钮/列表
        [self.defaults setObject:@"none" forKey:@"ReverseMode"];
        [self.defaults synchronize];
        self.reverseDialing = NO;
        self.reverseConnected = NO;
        TVNCRestartVNCService();
        [self updateStatusPill];
        [self updateReverseDialUI];
    } else {
        [self.clientsVC disconnectAllClients];
    }
}

#pragma mark - U3 操作

- (NSString *)directURL {
    NSInteger httpPort = [self.defaults integerForKey:@"HttpPort"];
    NSString *ip = TVNCEn0IPv4();
    if (httpPort <= 0 || !ip.length) return nil;
    return [NSString stringWithFormat:@"http://%@:%ld", ip, (long)httpPort];
}

- (void)copyDirectURL {
    NSString *url = [self directURL];
    if (!url) return;
    [UIPasteboard generalPasteboard].string = url;
    [self toast:[NSString stringWithFormat:@"已复制 %@", url]];
}

- (void)openDirectURL {
    NSString *url = [self directURL];
    if (!url) return;
    NSURL *u = [NSURL URLWithString:url];
    if (u && [[UIApplication sharedApplication] canOpenURL:u]) {
        [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
    }
}

- (void)toast:(NSString *)text {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:nil
                                                               message:text
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:a animated:YES completion:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [a dismissViewControllerAnimated:YES completion:nil];
    });
}

#pragma mark - 状态

- (void)refreshStatus {
    NSString *host = [self.defaults stringForKey:@"GatewayHost"];
    NSInteger consolePort = [self.defaults integerForKey:@"TVNCConsolePort"];
    if (consolePort <= 0) consolePort = 8080;
    if (host.length) {
        self.gatewayLabel.text = [NSString stringWithFormat:@"网关 %@:%ld", host, (long)consolePort];
    } else {
        self.gatewayLabel.text = @"网关未配置（设置 → 网关）";
    }
    [self updateReverseDialUI];
}

#pragma mark - 卡片工厂

- (UIView *)newCard {
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    card.layer.cornerRadius = 18;
    card.layer.borderWidth = 1;
    card.layer.borderColor = [UIColor separatorColor].CGColor;
    return card;
}

- (UILabel *)cardTitle:(NSString *)t {
    UILabel *l = [[UILabel alloc] init];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.font = [UIFont boldSystemFontOfSize:15];
    l.text = t;
    l.textColor = [UIColor labelColor];
    return l;
}

@end
