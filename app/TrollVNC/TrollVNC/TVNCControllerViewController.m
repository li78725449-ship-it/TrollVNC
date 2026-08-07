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

#import "TVNCControllerViewController.h"
#import "TVNCViewerViewController.h"

static NSString *const kDefaultsSuite = @"com.82flex.trollvnc";
static const NSInteger kConsolePort = 8080; // trollvnc-farm FARM_PORT 默认
static NSString *const kLayoutKey = @"TVNCControllerLayoutIndex"; // 0-11: 横屏1..6, 竖屏1..6

#pragma mark - 设备卡片 Cell（v1 占位画面）

@interface TVNCDeviceCardCell : UICollectionViewCell
@property(nonatomic, strong) UIView *screenArea;
@property(nonatomic, strong) UIImageView *screenIcon;
@property(nonatomic, strong) UILabel *tagLabel;
@property(nonatomic, strong) UILabel *nameLabel;
@property(nonatomic, strong) UIView *dotView;
- (void)configureWithDevice:(NSDictionary *)d;
@end

@implementation TVNCDeviceCardCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.contentView.layer.cornerRadius = 16;
        self.contentView.layer.borderWidth = 1;
        self.contentView.layer.borderColor = [UIColor separatorColor].CGColor;
        self.contentView.clipsToBounds = YES;
        self.contentView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.08;
        self.layer.shadowOffset = CGSizeMake(0, 6);
        self.layer.shadowRadius = 12;

        _screenArea = [[UIView alloc] init];
        _screenArea.translatesAutoresizingMaskIntoConstraints = NO;
        _screenArea.backgroundColor = [UIColor colorWithWhite:0.94 alpha:1];
        [self.contentView addSubview:_screenArea];

        _screenIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"iphone"]];
        _screenIcon.translatesAutoresizingMaskIntoConstraints = NO;
        _screenIcon.contentMode = UIViewContentModeScaleAspectFit;
        _screenIcon.tintColor = [UIColor systemGrayColor];
        [_screenArea addSubview:_screenIcon];

        _tagLabel = [[UILabel alloc] init];
        _tagLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _tagLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
        _tagLabel.textColor = [UIColor systemBlueColor];
        _tagLabel.textAlignment = NSTextAlignmentCenter;
        _tagLabel.layer.cornerRadius = 8;
        _tagLabel.layer.borderWidth = 1;
        _tagLabel.layer.borderColor = [UIColor systemBlueColor].CGColor;
        _tagLabel.layer.masksToBounds = YES;
        [self.contentView addSubview:_tagLabel];

        _nameLabel = [[UILabel alloc] init];
        _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _nameLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        _nameLabel.textColor = [UIColor labelColor];
        _nameLabel.numberOfLines = 1;
        [self.contentView addSubview:_nameLabel];

        _dotView = [[UIView alloc] init];
        _dotView.translatesAutoresizingMaskIntoConstraints = NO;
        _dotView.layer.cornerRadius = 5;
        [self.contentView addSubview:_dotView];

        [NSLayoutConstraint activateConstraints:@[
            [_screenArea.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [_screenArea.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [_screenArea.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
            [_screenArea.bottomAnchor constraintEqualToAnchor:self.tagLabel.topAnchor constant:-10],

            [_screenIcon.centerXAnchor constraintEqualToAnchor:_screenArea.centerXAnchor],
            [_screenIcon.centerYAnchor constraintEqualToAnchor:_screenArea.centerYAnchor],
            [_screenIcon.widthAnchor constraintEqualToConstant:34],
            [_screenIcon.heightAnchor constraintEqualToConstant:40],

            [_tagLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:10],
            [_tagLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-10],
            [_tagLabel.widthAnchor constraintEqualToConstant:38],
            [_tagLabel.heightAnchor constraintEqualToConstant:20],

            [_dotView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-10],
            [_dotView.centerYAnchor constraintEqualToAnchor:_tagLabel.centerYAnchor],
            [_dotView.widthAnchor constraintEqualToConstant:10],
            [_dotView.heightAnchor constraintEqualToConstant:10],

            [_nameLabel.leadingAnchor constraintEqualToAnchor:_tagLabel.trailingAnchor constant:8],
            [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_dotView.leadingAnchor constant:-8],
            [_nameLabel.centerYAnchor constraintEqualToAnchor:_tagLabel.centerYAnchor],
        ]];
    }
    return self;
}

- (void)configureWithDevice:(NSDictionary *)d {
    BOOL online = [d[@"online"] boolValue];
    self.nameLabel.text = d[@"name"] ?: d[@"id"] ?: @"?";
    self.tagLabel.text = @"直连";
    self.tagLabel.textColor = [UIColor systemBlueColor];
    self.tagLabel.layer.borderColor = [UIColor systemBlueColor].CGColor;
    self.dotView.backgroundColor = online ? [UIColor systemGreenColor] : [UIColor systemGrayColor];
    self.screenArea.backgroundColor = [UIColor colorWithWhite:online ? 0.93 : 0.96 alpha:1];
    self.screenIcon.tintColor = online ? [UIColor systemGrayColor] : [UIColor systemGray3Color];
}

@end

#pragma mark - 控制端

@interface TVNCControllerViewController () <UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate>

@property(nonatomic, strong) NSMutableArray<UIButton *> *chips;
@property(nonatomic, strong) UIButton *layoutBtn;
@property(nonatomic, strong) UIView *layoutPanel;
@property(nonatomic, strong) NSMutableArray<UIButton *> *layoutButtons;
@property(nonatomic, strong) UICollectionView *collectionView;
@property(nonatomic, strong) UILabel *emptyLabel;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *devices; // 全部设备
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *shown;   // 过滤后
@property(nonatomic, assign) NSInteger filterIndex; // 0 全部 / 1 直连 / 2 中继
@property(nonatomic, assign) NSInteger layoutIndex; // 0-11: 横屏1..6 / 竖屏1..6
@property(nonatomic, strong) NSUserDefaults *defaults;

@end

@implementation TVNCControllerViewController

- (instancetype)init {
    self = [super init];
    if (self) {
        _defaults = [[NSUserDefaults alloc] initWithSuiteName:kDefaultsSuite];
        _devices = [NSMutableArray array];
        _shown = [NSMutableArray array];
        _filterIndex = 0;
        id savedObj = [_defaults objectForKey:kLayoutKey];
        if (savedObj == nil) {
            _layoutIndex = 7; // 默认 竖屏2
        } else {
            NSInteger saved = [_defaults integerForKey:kLayoutKey];
            _layoutIndex = (saved < 0 || saved > 11) ? 7 : saved;
        }
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.title = @"控制端";

    // 顶部过滤：全部 / 直连 / 中继
    UIStackView *filter = [[UIStackView alloc] init];
    filter.translatesAutoresizingMaskIntoConstraints = NO;
    filter.axis = UILayoutConstraintAxisHorizontal;
    filter.spacing = 8;
    filter.distribution = UIStackViewDistributionFill;
    self.chips = [NSMutableArray array];
    NSArray<NSString *> *titles = @[@"全部", @"直连", @"中继"];
    for (NSInteger i = 0; i < titles.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
        cfg.title = titles[i];
        cfg.baseForegroundColor = [UIColor labelColor];
        cfg.contentInsets = NSDirectionalEdgeInsetsMake(8, 16, 8, 16);
        cfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        UIBackgroundConfiguration *bg = [UIBackgroundConfiguration clearConfiguration];
        bg.strokeColor = [UIColor separatorColor];
        bg.strokeWidth = 1;
        cfg.background = bg;
        b.configuration = cfg;
        b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        [b setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [b setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        b.tag = i;
        [b addTarget:self action:@selector(chipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.chips addObject:b];
        [filter addArrangedSubview:b];
    }
    [self updateChipAppearance];

    // 布局选择器：图标按钮 + 下拉菜单（12 项带 ✓）
    self.layoutBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.layoutBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [self.layoutBtn setImage:[UIImage systemImageNamed:@"square.grid.2x2"] forState:UIControlStateNormal];
    self.layoutBtn.tintColor = [UIColor labelColor];
    self.layoutBtn.layer.cornerRadius = 18;
    self.layoutBtn.layer.borderWidth = 1;
    self.layoutBtn.layer.borderColor = [UIColor separatorColor].CGColor;
    self.layoutBtn.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    [self.layoutBtn addTarget:self action:@selector(layoutTapped:) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *topRow = [[UIStackView alloc] init];
    topRow.translatesAutoresizingMaskIntoConstraints = NO;
    topRow.axis = UILayoutConstraintAxisHorizontal;
    topRow.spacing = 8;
    [topRow addArrangedSubview:filter];
    [topRow addArrangedSubview:self.layoutBtn];
    [self.view addSubview:topRow];

    UICollectionViewFlowLayout *fl = [[UICollectionViewFlowLayout alloc] init];
    fl.minimumInteritemSpacing = 12;
    fl.minimumLineSpacing = 12;
    fl.sectionInset = UIEdgeInsetsMake(12, 16, 16, 16);
    self.collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:fl];
    self.collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    self.collectionView.backgroundColor = [UIColor clearColor];
    [self.collectionView registerClass:[TVNCDeviceCardCell class] forCellWithReuseIdentifier:@"card"];
    [self.view addSubview:self.collectionView];

    // 纯手动下拉刷新（无轮询）
    UIRefreshControl *rc = [[UIRefreshControl alloc] init];
    [rc addTarget:self action:@selector(refreshDevices) forControlEvents:UIControlEventValueChanged];
    self.collectionView.refreshControl = rc;

    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.font = [UIFont systemFontOfSize:14];
    self.emptyLabel.textColor = [UIColor secondaryLabelColor];
    self.emptyLabel.text = @"暂无设备\n点右上角刷新，从网关拉取设备目录";
    [self.view addSubview:self.emptyLabel];

    [NSLayoutConstraint activateConstraints:@[
        [topRow.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [topRow.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [topRow.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.layoutBtn.widthAnchor constraintEqualToConstant:36],
        [self.layoutBtn.heightAnchor constraintEqualToConstant:36],
        [self.collectionView.topAnchor constraintEqualToAnchor:topRow.bottomAnchor constant:4],
        [self.collectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.collectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.collectionView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.emptyLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:32],
        [self.emptyLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-32],
    ]];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                                           target:self
                                                                                           action:@selector(refreshDevices)];
    [self refreshDevices];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshDevices];
}

#pragma mark - 布局菜单

- (void)setupLayoutPanel {
    __weak typeof(self) weakSelf = self;

    self.layoutPanel = [[UIView alloc] init];
    self.layoutPanel.translatesAutoresizingMaskIntoConstraints = NO;
    self.layoutPanel.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.layoutPanel.layer.cornerRadius = 14;
    self.layoutPanel.layer.borderWidth = 1;
    self.layoutPanel.layer.borderColor = [UIColor separatorColor].CGColor;
    self.layoutPanel.layer.shadowColor = [UIColor blackColor].CGColor;
    self.layoutPanel.layer.shadowOpacity = 0.15;
    self.layoutPanel.layer.shadowOffset = CGSizeMake(0, 8);
    self.layoutPanel.layer.shadowRadius = 16;
    self.layoutPanel.hidden = YES;
    [self.view addSubview:self.layoutPanel];

    NSArray<NSString *> *names = @[
        @"横屏 1", @"横屏 2", @"横屏 3", @"横屏 4", @"横屏 5", @"横屏 6",
        @"竖屏 1", @"竖屏 2", @"竖屏 3", @"竖屏 4", @"竖屏 5", @"竖屏 6",
    ];
    self.layoutButtons = [NSMutableArray array];
    UIStackView *left = [[UIStackView alloc] init];
    left.translatesAutoresizingMaskIntoConstraints = NO;
    left.axis = UILayoutConstraintAxisVertical;
    left.spacing = 6;
    UIStackView *right = [[UIStackView alloc] init];
    right.translatesAutoresizingMaskIntoConstraints = NO;
    right.axis = UILayoutConstraintAxisVertical;
    right.spacing = 6;

    for (NSInteger i = 0; i < 12; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.translatesAutoresizingMaskIntoConstraints = NO;
        [b setTitle:names[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        b.layer.cornerRadius = 8;
        b.tag = (int)i;
        [b addTarget:self action:@selector(layoutOptionTapped:) forControlEvents:UIControlEventTouchUpInside];
        [b setContentEdgeInsets:UIEdgeInsetsMake(7, 10, 7, 10)];
        [self.layoutButtons addObject:b];
        [b.heightAnchor constraintEqualToConstant:32].active = YES;
        if (i < 6) {
            [left addArrangedSubview:b];
        } else {
            [right addArrangedSubview:b];
        }
    }
    [self.layoutPanel addSubview:left];
    [self.layoutPanel addSubview:right];

    [NSLayoutConstraint activateConstraints:@[
        [self.layoutPanel.trailingAnchor constraintEqualToAnchor:self.layoutBtn.trailingAnchor],
        [self.layoutPanel.topAnchor constraintEqualToAnchor:self.layoutBtn.bottomAnchor constant:8],
        [left.topAnchor constraintEqualToAnchor:self.layoutPanel.topAnchor constant:10],
        [left.leadingAnchor constraintEqualToAnchor:self.layoutPanel.leadingAnchor constant:10],
        [left.bottomAnchor constraintEqualToAnchor:self.layoutPanel.bottomAnchor constant:-10],
        [left.widthAnchor constraintEqualToConstant:92],
        [right.topAnchor constraintEqualToAnchor:self.layoutPanel.topAnchor constant:10],
        [right.leadingAnchor constraintEqualToAnchor:left.trailingAnchor constant:6],
        [right.trailingAnchor constraintEqualToAnchor:self.layoutPanel.trailingAnchor constant:-10],
        [right.bottomAnchor constraintEqualToAnchor:self.layoutPanel.bottomAnchor constant:-10],
        [right.widthAnchor constraintEqualToAnchor:left.widthAnchor],
    ]];

    [self refreshLayoutPanelChecks];

    // 点击面板外关闭
    UITapGestureRecognizer *dismiss = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissLayoutPanel)];
    dismiss.cancelsTouchesInView = NO;
    dismiss.delegate = self;
    [self.view addGestureRecognizer:dismiss];
}

- (void)layoutTapped:(UIButton *)sender {
    BOOL show = self.layoutPanel.hidden;
    if (show) {
        [self refreshLayoutPanelChecks];
    }
    self.layoutPanel.hidden = !show;
}

- (void)layoutOptionTapped:(UIButton *)sender {
    [self setLayoutIndex:sender.tag];
    self.layoutPanel.hidden = YES;
}

- (void)dismissLayoutPanel {
    self.layoutPanel.hidden = YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if (touch.view == self.layoutPanel || [touch.view isDescendantOfView:self.layoutPanel]) {
        return NO; // 面板内不拦截
    }
    if (touch.view == self.layoutBtn || [touch.view isDescendantOfView:self.layoutBtn]) {
        return NO; // 布局按钮自身（切换开关）
    }
    return YES;
}

- (void)refreshLayoutPanelChecks {
    for (UIButton *b in self.layoutButtons) {
        BOOL on = (b.tag == self.layoutIndex);
        b.selected = on;
        if (on) {
            b.backgroundColor = [UIColor systemBlueColor];
            b.tintColor = [UIColor whiteColor];
            [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            [b setImage:[UIImage systemImageNamed:@"checkmark"] forState:UIControlStateNormal];
        } else {
            b.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
            b.tintColor = [UIColor labelColor];
            [b setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
            [b setImage:nil forState:UIControlStateNormal];
        }
    }
}

- (void)setLayoutIndex:(NSInteger)index {
    if (index < 0 || index > 11) index = 7;
    self.layoutIndex = index;
    [self.defaults setInteger:index forKey:kLayoutKey];
    [self.defaults synchronize];
    [self refreshLayoutPanelChecks];
    @try {
        [self.collectionView.collectionViewLayout invalidateLayout];
    } @catch (NSException *e) {
        NSLog(@"[TVNC] layout invalidate failed: %@ %@", e.name, e.reason);
    }
}

- (NSInteger)layoutColumns {
    return (self.layoutIndex < 6) ? (self.layoutIndex + 1) : (self.layoutIndex - 5);
}

- (BOOL)layoutIsLandscape {
    return self.layoutIndex < 6;
}

#pragma mark - 设备目录（网关 /api/devices）

- (void)refreshDevices {
    [self.collectionView.refreshControl endRefreshing];
    NSString *host = [self.defaults stringForKey:@"GatewayHost"];
    if (!host.length) {
        self.emptyLabel.text = @"未配置网关\n请先在 设置 → 网关 填写网关地址";
        [self applyFilter];
        return;
    }
    NSInteger consolePort = [self.defaults integerForKey:@"TVNCConsolePort"];
    if (consolePort <= 0) consolePort = kConsolePort;
    NSString *urlStr = [NSString stringWithFormat:@"http://%@:%ld/api/devices", host, (long)consolePort];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    NSString *token = [self.defaults stringForKey:@"GatewayToken"];
    if (token.length) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    }
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
                                                                 completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSArray *list = nil;
        if (!err && data) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]]) list = json[@"devices"];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf handleDevices:list error:err];
        });
    }];
    [task resume];
}

- (void)handleDevices:(NSArray *)list error:(NSError *)err {
    [self.collectionView.refreshControl endRefreshing];
    if (![list isKindOfClass:[NSArray class]]) {
        self.emptyLabel.text = err ? [NSString stringWithFormat:@"拉取设备目录失败\n%@", err.localizedDescription]
                                   : @"网关返回异常\n请检查网关是否运行";
    } else {
        [self.devices removeAllObjects];
        for (NSDictionary *d in list) {
            if (![d isKindOfClass:[NSDictionary class]]) continue;
            if ([d[@"source"] isEqualToString:@"register"] || d[@"host"]) {
                [self.devices addObject:d];
            }
        }
        if (!self.devices.count) {
            self.emptyLabel.text = @"暂无设备\n（仅显示已注册到网关的设备）";
        }
    }
    [self applyFilter];
}

- (void)applyFilter {
    [self.shown removeAllObjects];
    for (NSDictionary *d in self.devices) {
        if (self.filterIndex == 1 && ![d[@"online"] boolValue]) continue; // 直连=在线
        if (self.filterIndex == 2) continue;                              // 中继=远期
        [self.shown addObject:d];
    }
    BOOL hasAny = self.devices.count > 0;
    BOOL hasShown = self.shown.count > 0;
    self.collectionView.hidden = !hasShown;
    self.emptyLabel.hidden = hasShown || !hasAny;
    if (!hasShown && hasAny) {
        self.emptyLabel.text = @"当前过滤条件下无设备";
        self.emptyLabel.hidden = NO;
    }
    [self.collectionView reloadData];
}

#pragma mark - 卡片墙

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.shown.count;
}

- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)collectionView
                           cellForItemAtIndexPath:(NSIndexPath *)ip {
    TVNCDeviceCardCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"card" forIndexPath:ip];
    [cell configureWithDevice:self.shown[ip.row]];
    return cell;
}

- (CGSize)collectionView:(UICollectionView *)collectionView
                  layout:(UICollectionViewLayout *)collectionViewLayout
  sizeForItemAtIndexPath:(NSIndexPath *)ip {
    NSInteger cols = MAX(1, [self layoutColumns]);
    CGFloat total = collectionView.bounds.size.width;
    if (total <= 0) total = self.view.bounds.size.width;
    if (total <= 0) total = 320;
    CGFloat spacing = 12;
    CGFloat insets = 16 * 2 + spacing * (cols - 1);
    CGFloat w = (total - insets) / cols;
    if (w < 60) w = 60;
    CGFloat ratio = [self layoutIsLandscape] ? (9.0 / 16.0) : (16.0 / 9.0);
    return CGSizeMake(w, floor(w * ratio));
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)ip {
    [collectionView deselectItemAtIndexPath:ip animated:YES];
    NSDictionary *d = self.shown[ip.row];
    NSString *host = d[@"host"];
    if (!host.length) return;
    int port = (int)([d[@"port"] integerValue] ?: 5901);
    TVNCViewerViewController *viewer = [[TVNCViewerViewController alloc] initWithHost:host port:port name:d[@"name"] ?: host];
    [self.navigationController pushViewController:viewer animated:YES];
}

#pragma mark - 过滤

- (void)chipTapped:(UIButton *)sender {
    self.filterIndex = sender.tag;
    for (UIButton *b in self.chips) {
        b.selected = (b == sender);
    }
    [self updateChipAppearance];
    [self applyFilter];
}

- (void)updateChipAppearance {
    for (UIButton *b in self.chips) {
        UIButtonConfiguration *cfg = [b.configuration copy];
        if (b.selected) {
            cfg.baseBackgroundColor = [UIColor systemBlueColor];
            cfg.baseForegroundColor = [UIColor whiteColor];
            cfg.background.strokeColor = [UIColor systemBlueColor];
        } else {
            cfg.baseBackgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
            cfg.baseForegroundColor = [UIColor labelColor];
            cfg.background.strokeColor = [UIColor separatorColor];
        }
        b.configuration = cfg;
    }
}

@end
