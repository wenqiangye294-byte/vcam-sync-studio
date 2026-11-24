#import "MainViewController.h"
#import "AppContainerMirror.h"
#import "QRScannerViewController.h"
#import "SyncManager.h"
#import "TargetAppsViewController.h"
#import "../shared/VCamProtocol.h"

@interface MainViewController ()
@property (nonatomic, strong) UILabel *statusBannerLabel;
@property (nonatomic, strong) UIScrollView *previewStrip;
@end

@implementation MainViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"VCamSync 虚拟相机";
    self.navigationController.navigationBar.prefersLargeTitles = YES;

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"立即同步"
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(onTapSync)];

    [self buildHeaderBanner];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onSyncUpdated)
                                                 name:VCamSyncDidUpdateNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)buildHeaderBanner {
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 136)];
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(16, 8, self.view.bounds.size.width - 32, 120)];
    card.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    card.layer.cornerRadius = 14.0;

    UILabel *banner = [[UILabel alloc] initWithFrame:CGRectMake(14, 10, card.bounds.size.width - 28, 22)];
    banner.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    banner.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    banner.textColor = [UIColor systemBlueColor];

    UIScrollView *strip = [[UIScrollView alloc] initWithFrame:CGRectMake(14, 38, card.bounds.size.width - 28, 72)];
    strip.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    strip.showsHorizontalScrollIndicator = NO;

    [card addSubview:banner];
    [card addSubview:strip];
    [header addSubview:card];

    self.statusBannerLabel = banner;
    self.previewStrip = strip;
    self.tableView.tableHeaderView = header;
    [self refreshHeaderBanner];
}

- (void)refreshHeaderBanner {
    SyncManager *sm = [SyncManager sharedManager];
    self.statusBannerLabel.text = sm.statusText;

    for (UIView *v in self.previewStrip.subviews) {
        [v removeFromSuperview];
    }

    NSDictionary *prod = sm.currentManifest[@"product"];
    NSArray *photos = [prod[@"photos"] isKindOfClass:[NSArray class]] ? prod[@"photos"] : @[];
    NSArray *videos = [prod[@"videos"] isKindOfClass:[NSArray class]] ? prod[@"videos"] : @[];
    NSInteger pCursor = sm.currentState ? [sm.currentState[@"photo_cursor"] integerValue] : [prod[@"photo_cursor"] integerValue];

    if (photos.count == 0 && videos.count == 0) {
        UILabel *empty = [[UILabel alloc] initWithFrame:CGRectMake(0, 14, 280, 40)];
        empty.text = @"暂无已同步图片/视频，请在电脑端上传素材";
        empty.font = [UIFont systemFontOfSize:12.5];
        empty.textColor = [UIColor secondaryLabelColor];
        [self.previewStrip addSubview:empty];
        self.previewStrip.contentSize = CGSizeMake(280, 72);
        return;
    }

    CGFloat x = 0;
    NSString *mediaDir = [VCamMasterDirectory stringByAppendingPathComponent:VCamMediaSubdir];
    for (NSUInteger i = 0; i < photos.count; i++) {
        NSDictionary *item = photos[i];
        NSString *fn = item[@"filename"];
        NSString *path = [mediaDir stringByAppendingPathComponent:fn ?: @""];
        UIImage *img = [UIImage imageWithContentsOfFile:path];

        UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(x, 4, 60, 60)];
        iv.contentMode = UIViewContentModeScaleAspectFill;
        iv.clipsToBounds = YES;
        iv.layer.cornerRadius = 8;
        iv.backgroundColor = [UIColor tertiarySystemFillColor];
        iv.image = img;

        if ((NSInteger)i == pCursor) {
            iv.layer.borderColor = [UIColor systemBlueColor].CGColor;
            iv.layer.borderWidth = 2.5;
        }

        UILabel *badge = [[UILabel alloc] initWithFrame:CGRectMake(3, 3, 22, 16)];
        badge.text = [NSString stringWithFormat:@"%lu", (unsigned long)(i + 1)];
        badge.font = [UIFont boldSystemFontOfSize:10];
        badge.textAlignment = NSTextAlignmentCenter;
        badge.textColor = [UIColor whiteColor];
        badge.backgroundColor = ((NSInteger)i == pCursor)
            ? [UIColor systemBlueColor]
            : [UIColor colorWithWhite:0 alpha:0.65];
        badge.layer.cornerRadius = 5;
        badge.clipsToBounds = YES;
        [iv addSubview:badge];

        [self.previewStrip addSubview:iv];
        x += 68;
    }

    if (videos.count > 0) {
        UILabel *vTag = [[UILabel alloc] initWithFrame:CGRectMake(x, 4, 72, 60)];
        vTag.numberOfLines = 2;
        vTag.text = [NSString stringWithFormat:@"视频\n%lu 个", (unsigned long)videos.count];
        vTag.textAlignment = NSTextAlignmentCenter;
        vTag.font = [UIFont boldSystemFontOfSize:12];
        vTag.textColor = [UIColor whiteColor];
        vTag.backgroundColor = [UIColor systemIndigoColor];
        vTag.layer.cornerRadius = 8;
        vTag.clipsToBounds = YES;
        [self.previewStrip addSubview:vTag];
        x += 80;
    }

    self.previewStrip.contentSize = CGSizeMake(MAX(x, self.previewStrip.bounds.size.width), 72);
}

- (void)onSyncUpdated {
    [self refreshHeaderBanner];
    [self.tableView reloadData];
}

- (void)onTapSync {
    [[SyncManager sharedManager] syncNow];
}

#pragma mark - TableView DataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 4;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    switch (section) {
        case 0: return @"1. 电脑端局域网配对";
        case 1: return @"2. 目标 App 同步（纯巨魔 TrollFools 必选）";
        case 2: return @"3. 队列进度与实时控制";
        default: return @"4. 模式说明";
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    switch (section) {
        case 0: return 4;
        case 1: return 2;
        case 2: return 5;
        default: return 1;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    SyncManager *sm = [SyncManager sharedManager];

    if (indexPath.section == 0) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"PairCell"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"PairCell"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.textLabel.textColor = [UIColor labelColor];

        if (indexPath.row == 0) {
            cell.textLabel.text = @"当前配对电脑";
            cell.detailTextLabel.text = [sm hasConfiguration]
                ? [NSString stringWithFormat:@"%@ (%@:%ld)", sm.pcName, sm.host, (long)sm.port]
                : @"未配置";
            cell.accessoryType = UITableViewCellAccessoryNone;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"扫码配对电脑";
            cell.detailTextLabel.text = @"推荐";
            cell.textLabel.textColor = [UIColor systemBlueColor];
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"自动搜索局域网电脑 (Wi-Fi)";
            cell.detailTextLabel.text = @"UDP 18766";
        } else {
            cell.textLabel.text = @"手动输入 IP 与密钥";
            cell.detailTextLabel.text = @"";
        }
        return cell;
    }

    if (indexPath.section == 1) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"TargetCell"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"TargetCell"];
        NSArray *summaries = [[AppContainerMirror sharedMirror] selectedTargetAppSummaries];
        if (indexPath.row == 0) {
            cell.textLabel.text = @"选择要替换相机的目标 App";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"已选 %lu 个", (unsigned long)summaries.count];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.textLabel.textColor = [UIColor systemBlueColor];
        } else {
            cell.textLabel.text = @"当前同步目标";
            NSMutableArray *names = [NSMutableArray array];
            for (NSDictionary *s in summaries) [names addObject:s[@"name"] ?: s[@"bundle_id"]];
            cell.detailTextLabel.text = names.count > 0 ? [names componentsJoinedByString:@"、"] : @"未选择（越狱环境可忽略）";
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.textLabel.textColor = [UIColor labelColor];
        }
        return cell;
    }

    if (indexPath.section == 2) {
        NSDictionary *prod = sm.currentManifest[@"product"];
        NSArray *photos = [prod[@"photos"] isKindOfClass:[NSArray class]] ? prod[@"photos"] : @[];
        NSArray *videos = [prod[@"videos"] isKindOfClass:[NSArray class]] ? prod[@"videos"] : @[];
        NSInteger pCur = sm.currentState ? [sm.currentState[@"photo_cursor"] integerValue] : [prod[@"photo_cursor"] integerValue];
        BOOL enabled = sm.currentState ? [sm.currentState[@"enabled"] boolValue] : (sm.currentManifest ? [sm.currentManifest[@"enabled"] boolValue] : YES);
        BOOL showHUD = sm.currentManifest ? [sm.currentManifest[@"show_hud"] boolValue] : YES;

        if (indexPath.row == 0) {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"QueueInfoCell"];
            if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"QueueInfoCell"];
            cell.textLabel.text = [NSString stringWithFormat:@"商品：%@", prod[@"name"] ?: @"等待同步"];
            cell.detailTextLabel.text = [NSString stringWithFormat:@"点击拍照：%@ · 长按录制：%lu 个视频",
                                         photos.count > 0 ? [NSString stringWithFormat:@"第 %ld / %lu 张", (long)(pCur + 1), (unsigned long)photos.count] : @"0 张",
                                         (unsigned long)videos.count];
            cell.accessoryType = UITableViewCellAccessoryNone;
            return cell;
        }
        if (indexPath.row == 1 || indexPath.row == 2) {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"StepCell"];
            if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"StepCell"];
            cell.textLabel.textColor = [UIColor systemBlueColor];
            cell.textLabel.text = (indexPath.row == 1) ? @"切换到下一张图片" : @"重置拍照队列到第 1 张";
            return cell;
        }

        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"SwitchCell"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"SwitchCell"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *sw = [[UISwitch alloc] init];
        if (indexPath.row == 3) {
            cell.textLabel.text = @"启用虚拟相机输出替换";
            sw.on = enabled;
            [sw addTarget:self action:@selector(onToggleEnabled:) forControlEvents:UIControlEventValueChanged];
        } else {
            cell.textLabel.text = @"在拍照页面显示悬浮快捷控制条";
            sw.on = showHUD;
            [sw addTarget:self action:@selector(onToggleHUD:) forControlEvents:UIControlEventValueChanged];
        }
        cell.accessoryView = sw;
        return cell;
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"TipCell"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"TipCell"];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = @"iOS 16.2 纯巨魔 / 越狱通用同步端";
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.text = @"• 纯巨魔：用 TrollFools 将 VCamHook.dylib 注入目标 App，并在上方「选择目标 App」勾选对应 App。\n• 越狱环境（Dopamine）：安装 VCamTweak-rootless.deb 后直接生效，无需额外注入。";
    return cell;
}

- (void)onToggleEnabled:(UISwitch *)sw {
    [[SyncManager sharedManager] setVirtualCameraEnabled:sw.isOn];
}

- (void)onToggleHUD:(UISwitch *)sw {
    [[SyncManager sharedManager] setHUDVisible:sw.isOn];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        if (indexPath.row == 1) {
            QRScannerViewController *qr = [[QRScannerViewController alloc] init];
            qr.onScanCode = ^(NSString *code) {
                if (![[SyncManager sharedManager] parseAndApplyPairingURL:code]) {
                    [self showSimpleAlert:@"二维码无效" message:@"请扫描电脑端工作台右侧生成的配对二维码。"];
                }
            };
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:qr];
            nav.modalPresentationStyle = UIModalPresentationFullScreen;
            [self presentViewController:nav animated:YES completion:nil];
        } else if (indexPath.row == 2) {
            [self runLANDiscovery];
        } else if (indexPath.row == 3) {
            [self showManualPairAlert];
        }
    } else if (indexPath.section == 1 && indexPath.row == 0) {
        TargetAppsViewController *vc = [[TargetAppsViewController alloc] init];
        vc.onSelectionSaved = ^{
            [self.tableView reloadData];
        };
        [self.navigationController pushViewController:vc animated:YES];
    } else if (indexPath.section == 2) {
        if (indexPath.row == 1) {
            [[SyncManager sharedManager] stepPhotoCursorBy:1 reset:NO];
        } else if (indexPath.row == 2) {
            [[SyncManager sharedManager] stepPhotoCursorBy:0 reset:YES];
        }
    }
}

- (void)runLANDiscovery {
    UIAlertController *loading = [UIAlertController alertControllerWithTitle:@"正在搜索局域网..."
                                                                     message:@"请确保手机与电脑处于同一 Wi-Fi"
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:loading animated:YES completion:nil];

    [[SyncManager sharedManager] discoverPCsOnLANWithCompletion:^(NSArray<NSDictionary *> *pcs) {
        [loading dismissViewControllerAnimated:YES completion:^{
            if (pcs.count == 0) {
                [self showSimpleAlert:@"未发现电脑端" message:@"请确认电脑端工作台已启动，并保持同一局域网 Wi-Fi（或点击「扫码配对」/运行电脑端防火墙放行脚本）。"];
                return;
            }
            UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择局域网电脑"
                                                                         message:nil
                                                                  preferredStyle:UIAlertControllerStyleActionSheet];
            for (NSDictionary *pc in pcs) {
                NSString *title = [NSString stringWithFormat:@"%@ (%@:%@)", pc[@"name"], pc[@"host"], pc[@"port"]];
                [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                    (void)action;
                    [[SyncManager sharedManager] configureHost:pc[@"host"]
                                                          port:[pc[@"port"] integerValue]
                                                         token:pc[@"token"]
                                                        pcName:pc[@"name"]];
                }]];
            }
            [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:sheet animated:YES completion:nil];
        }];
    }];
}

- (void)showManualPairAlert {
    SyncManager *sm = [SyncManager sharedManager];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"手动连接电脑"
                                                                message:@"输入电脑工作台显示的局域网 IP、端口和配对密钥"
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"电脑 IP，例如 192.168.1.100";
        tf.text = sm.host;
        tf.keyboardType = UIKeyboardTypeURL;
    }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"端口，默认 18760";
        tf.text = [NSString stringWithFormat:@"%ld", (long)(sm.port > 0 ? sm.port : 18760)];
        tf.keyboardType = UIKeyboardTypeNumberPad;
    }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"配对密钥 (token)";
        tf.text = sm.token;
    }];

    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"连接" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        (void)action;
        NSString *host = ac.textFields[0].text ?: @"";
        NSInteger port = ac.textFields[1].text.integerValue ?: 18760;
        NSString *token = ac.textFields[2].text ?: @"";
        if (host.length > 0 && token.length > 0) {
            [[SyncManager sharedManager] configureHost:host port:port token:token pcName:host];
        }
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)showSimpleAlert:(NSString *)title message:(NSString *)msg {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end
