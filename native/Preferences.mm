#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSViewController.h>
#include "Management.hpp"
#include "SettingsAppearance.hpp"

@interface RILatencyController : PSViewController
@property(nonatomic, strong) UIButton *panel;
@property(nonatomic, strong) UILabel *counter;
@property(nonatomic) NSUInteger taps;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *inputAges;
@property(nonatomic, strong) dispatch_queue_t diagnosticQueue;
@end

@implementation RILatencyController
- (void)loadView {
    UIView *view = [UIView new];
    view.backgroundColor = UIColor.systemBackgroundColor;
    self.view = view;
    self.inputAges = [NSMutableArray array];
    self.diagnosticQueue = dispatch_queue_create("com.xyhelper.remoteipad.latency-probe", DISPATCH_QUEUE_SERIAL);
    UILabel *instructions = [UILabel new];
    instructions.text = @"点击色块立即切换红绿，用于测量 Windows 点击到画面回显的延迟。自动测试期间请勿移动鼠标、遮挡或调整远程桌面窗口。";
    instructions.numberOfLines = 0;
    self.counter = [UILabel new];
    self.counter.text = @"点击次数：0";
    self.panel = [UIButton buttonWithType:UIButtonTypeCustom];
    self.panel.backgroundColor = [UIColor colorWithRed:0.85 green:0.12 blue:0.12 alpha:1];
    self.panel.accessibilityLabel = @"响应延迟测试色块";
    [self.panel addTarget:self action:@selector(probeTap:event:) forControlEvents:UIControlEventTouchUpInside];
    for (UIView *item in @[instructions, self.counter, self.panel]) {
        item.translatesAutoresizingMaskIntoConstraints = NO;
        [view addSubview:item];
    }
    UILayoutGuide *safe = view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [instructions.topAnchor constraintEqualToAnchor:safe.topAnchor constant:24],
        [instructions.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [instructions.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],
        [self.counter.topAnchor constraintEqualToAnchor:instructions.bottomAnchor constant:20],
        [self.counter.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [self.panel.topAnchor constraintEqualToAnchor:self.counter.bottomAnchor constant:24],
        [self.panel.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [self.panel.widthAnchor constraintEqualToConstant:200],
        [self.panel.heightAnchor constraintEqualToConstant:200]
    ]];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"响应延迟测试";
}
- (void)tap {
    ++self.taps;
    [UIView performWithoutAnimation:^{
        self.panel.backgroundColor = self.taps % 2 ?
            [UIColor colorWithRed:0.12 green:0.80 blue:0.30 alpha:1] :
            [UIColor colorWithRed:0.85 green:0.12 blue:0.12 alpha:1];
        self.counter.text = [NSString stringWithFormat:@"点击次数：%lu", (unsigned long)self.taps];
    }];
}
- (void)probeTap:(UIButton *)sender event:(UIEvent *)event {
    UITouch *touch = event.allTouches.anyObject;
    double age = touch ? (CACurrentMediaTime() - touch.timestamp) * 1000 : -1;
    [self tap];
    if (age < 0) { NSLog(@"RemoteIPad latency test: input timestamp unavailable"); return; }
    [self.inputAges addObject:@(age)];
    if (self.inputAges.count > 202) [self.inputAges removeObjectAtIndex:0];
    NSMutableArray *ancestors = [NSMutableArray array];
    for (UIView *view = sender; view; view = view.superview) {
        if ([view isKindOfClass:UIScrollView.class])
            [ancestors addObject:@{@"class": NSStringFromClass(view.class),
                @"delaysContentTouches": @(((UIScrollView *)view).delaysContentTouches)}];
        for (UIGestureRecognizer *gesture in view.gestureRecognizers) {
            if (gesture.delaysTouchesBegan || gesture.delaysTouchesEnded)
                [ancestors addObject:@{@"class": NSStringFromClass(gesture.class),
                    @"delaysTouchesBegan": @(gesture.delaysTouchesBegan),
                    @"delaysTouchesEnded": @(gesture.delaysTouchesEnded)}];
        }
    }
    NSDictionary *snapshot = @{@"updatedAt": @([NSDate date].timeIntervalSince1970),
        @"taps": @(self.taps), @"inputEventToActionMs": [self.inputAges copy],
        @"touchDelayingAncestors": ancestors};
    dispatch_async(self.diagnosticQueue, ^{
        NSError *error = nil;
        NSURL *url = [NSURL fileURLWithPath:@"/var/mobile/Library/Caches/com.xyhelper.remoteipad-latency.plist"];
        if (![snapshot writeToURL:url error:&error])
            NSLog(@"RemoteIPad latency test: cannot write timing diagnostics: %@", error);
    });
}
@end

@interface RIPreferencesController : PSListController
@property(nonatomic, strong) NSTimer *refresh;
@property(nonatomic, strong) NSDictionary *state;
@property(nonatomic) BOOL updating;
@end

@implementation RIPreferencesController
- (NSArray *)specifiers {
    self.state = [NSDictionary dictionaryWithContentsOfFile:
        [NSString stringWithUTF8String:paths::status]];
    NSMutableArray *items = [NSMutableArray array];
    PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:@"局域网 RDP"
        target:nil set:NULL get:NULL detail:nil cell:PSGroupCell edit:nil];
    [group setProperty:@"使用 Windows 远程桌面连接 iPad 的局域网 IP，固定端口 3389，通过 NLA 验证账号密码。关闭后停止监听、断开会话并释放采集、编码和触控，仅保留本机管理。保存账号密码后需重新连接。"
                forKey:@"footerText"];
    [items addObject:group];
    BOOL fresh = self.state &&
        [NSDate date].timeIntervalSince1970 - [self.state[@"updatedAt"] doubleValue] <= 5;
    PSSpecifier *toggle = [PSSpecifier preferenceSpecifierNamed:@"启用 RDP 服务" target:self
        set:@selector(setEnabled:specifier:) get:@selector(enabled:) detail:nil cell:PSSwitchCell edit:nil];
    [toggle setProperty:@(fresh && [self.state[@"transportAvailable"] boolValue] && !self.updating) forKey:@"enabled"];
    [items addObject:toggle];
    PSSpecifier *credentials = [PSSpecifier preferenceSpecifierNamed:@"修改 RDP 账号密码"
        target:self set:NULL get:NULL detail:nil cell:PSButtonCell edit:nil];
    credentials.buttonAction = @selector(editCredentials);
    [credentials setProperty:@(fresh && !self.updating) forKey:@"enabled"];
    [items addObject:credentials];
    PSSpecifier *probe = [PSSpecifier preferenceSpecifierNamed:@"响应延迟测试" target:self
        set:NULL get:NULL detail:RILatencyController.class cell:PSLinkCell edit:nil];
    [items addObject:probe];
    PSSpecifier *statusGroup = [PSSpecifier preferenceSpecifierNamed:@"运行状态"
        target:nil set:NULL get:NULL detail:nil cell:PSGroupCell edit:nil];
    [statusGroup setProperty:@"画面和鼠标共用一个 RDP 会话，左键支持点按和拖动；不提供文本键盘、滚轮、多指或音频。编码帧率不是客户端显示帧率；采集与提交耗时不含异步编码完成、网络传输或客户端呈现。触控接口可用仅表示注入能力。状态超过 5 秒未更新时，请检查越狱和后台管理进程。"
                     forKey:@"footerText"];
    [items addObject:statusGroup];
    NSArray *fields = @[
        @[@"version", @"软件版本"], @[@"service", @"RDP 服务"],
        @[@"protocol", @"连接协议"], @[@"port", @"RDP 端口"],
        @[@"username", @"RDP 用户名"], @[@"listening", @"端口监听"],
        @[@"clientConnected", @"RDP 客户端"], @[@"gfxReady", @"图形通道"],
        @[@"capture", @"采集管线"], @[@"hardware", @"H.264 硬件编码"],
        @[@"inputAvailable", @"触控接口可用"], @[@"resolution", @"视频分辨率"],
        @[@"fps", @"编码帧率"], @[@"bitrate", @"目标视频码率"],
        @[@"captureMs", @"采集与提交耗时"], @[@"error", @"最近错误"]
    ];
    for (NSArray *field in fields) {
        PSSpecifier *item = [PSSpecifier preferenceSpecifierNamed:field[1] target:self
            set:NULL get:@selector(value:) detail:nil cell:PSTitleValueCell edit:nil];
        [item setProperty:field[0] forKey:@"metric"];
        [items addObject:item];
    }
    _specifiers = items;
    return _specifiers;
}
- (id)enabled:(PSSpecifier *)specifier {
    return self.state[@"enabled"];
}
- (void)submit:(NSDictionary *)request {
    if (self.updating) return;
    self.updating = YES;
    [self reloadSpecifiers];
    __weak RIPreferencesController *weak = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSDictionary *reply = management::request(request, &error);
        NSString *failure = error.localizedDescription ?: reply[@"error"];
        if (!reply && !failure) failure = @"后台管理请求失败";
        if (reply && !failure && ![reply[@"ok"] isEqual:@YES]) failure = @"后台管理响应无效";
        dispatch_async(dispatch_get_main_queue(), ^{
            RIPreferencesController *controller = weak;
            if (!controller) return;
            controller.updating = NO;
            [controller reloadSpecifiers];
            if (failure) {
                NSLog(@"RemoteIPad settings operation failed: %@", failure);
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"操作失败"
                    message:failure preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                [controller presentViewController:alert animated:YES completion:nil];
            }
        });
    });
}
- (void)setEnabled:(id)value specifier:(PSSpecifier *)specifier {
    [self submit:@{@"op": @"setEnabled", @"enabled": @([value boolValue])}];
}
- (void)editCredentials {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"修改 RDP 账号"
        message:@"用户名 1–64 位（不含冒号、反斜杠或换行），新密码 12–256 位。保存后所有 RDP 连接断开，需要重新登录。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"RDP 用户名";
        field.text = self.state[@"username"];
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"新的 RDP 密码（至少 12 位）";
        field.secureTextEntry = YES;
        field.textContentType = UITextContentTypeNewPassword;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak RIPreferencesController *weak = self;
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *) {
        UIAlertController *dialog = weakAlert;
        NSDictionary *request = @{@"op": @"setCredentials", @"username": dialog.textFields[0].text ?: @"",
            @"password": dialog.textFields[1].text ?: @""};
        dialog.textFields[1].text = @"";
        [weak submit:request];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (id)value:(PSSpecifier *)specifier {
    if (!self.state || [NSDate date].timeIntervalSince1970 - [self.state[@"updatedAt"] doubleValue] > 5)
        return @"服务未运行 / 状态过期";
    NSString *metric = [specifier propertyForKey:@"metric"];
    id value = self.state[metric];
    if ([metric isEqual:@"service"])
        return [value isEqual:@"disabled"] ? @"已关闭（管理进程保留）" :
            [value isEqual:@"running"] ? @"运行中" :
            [value isEqual:@"failed"] ? @"启动失败，请查看错误" : [value description];
    if ([metric isEqual:@"protocol"] && [value isEqual:@"rdp-nla-avc420"])
        return @"RDP / NLA / AVC420";
    if ([metric isEqual:@"capture"] && value) {
        NSDictionary *names = @{@"initializing": @"初始化中", @"idle": @"空闲（未采集）",
            @"ready": @"已就绪", @"unavailable": @"采集接口不可用"};
        return names[value] ?: [value description];
    }
    NSDictionary *booleans = @{@"hardware": @[@"使用中", @"未启用"],
        @"inputAvailable": @[@"可用", @"不可用"], @"clientConnected": @[@"已连接", @"未连接"],
        @"listening": @[@"监听中", @"未监听"], @"gfxReady": @[@"已就绪", @"未就绪"]};
    NSArray *labels = booleans[metric];
    if (labels && value) return labels[[value boolValue] ? 0 : 1];
    if ([metric isEqual:@"resolution"]) {
        if (![self.state[@"capture"] isEqual:@"ready"]) return @"未启动";
        NSNumber *width = self.state[@"width"], *height = self.state[@"height"];
        return width && height ? [NSString stringWithFormat:@"%@ × %@ px", width, height] : @"未报告";
    }
    if ([metric isEqual:@"captureMs"] && ![self.state[@"capture"] isEqual:@"ready"])
        return @"未启动";
    if ([@[@"fps", @"captureMs"] containsObject:metric] && value)
        return [NSString stringWithFormat:@"%.1f %@", [value doubleValue],
            [metric isEqual:@"fps"] ? @"FPS" : @"ms"];
    if ([metric isEqual:@"bitrate"] && value)
        return [NSString stringWithFormat:@"%.1f Mbps", [value doubleValue] / 1000000];
    if ([metric isEqual:@"error"] && [value isEqual:@""]) return @"无";
    return value ? [value description] : @"未报告";
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.title = settingsAppearance::title;
    [self reloadSpecifiers];
    __weak RIPreferencesController *weak = self;
    self.refresh = [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *) {
        [weak reloadSpecifiers];
    }];
}
- (void)viewWillDisappear:(BOOL)animated {
    [self.refresh invalidate]; self.refresh = nil;
    [super viewWillDisappear:animated];
}
@end
