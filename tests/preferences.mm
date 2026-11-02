#import "../native/Preferences.mm"
#include <cstdio>
#include <cstring>
#include <cmath>

static BOOL expect(RIPreferencesController *controller, NSString *metric, NSString *expected) {
    PSSpecifier *item = [PSSpecifier preferenceSpecifierNamed:metric target:controller
        set:NULL get:@selector(value:) detail:nil cell:PSTitleValueCell edit:nil];
    [item setProperty:metric forKey:@"metric"];
    id actual = [controller value:item];
    if ([actual isEqual:expected]) return YES;
    fprintf(stderr, "FAIL %s: expected %s, got %s\n", metric.UTF8String,
        expected.UTF8String, [[actual description] UTF8String]);
    return NO;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc > 2 || (argc == 2 && strcmp(argv[1], "--icon") != 0)) {
            fprintf(stderr, "Use no arguments or --icon\n");
            return 1;
        }
        RIPreferencesController *controller = [RIPreferencesController new];
        PSSpecifier *entry = settingsAppearance::entry(controller, RIPreferencesController.class);
        UIImage *icon = [entry propertyForKey:PSIconImageKey];
        NSData *png = icon ? UIImagePNGRepresentation(icon) : nil;
        if (![entry.name isEqual:@"XYHelper Remote RDP"] ||
            ![[entry propertyForKey:@"id"] isEqual:@"com.xyhelper.remoteipad.general"] ||
            !icon || !CGSizeEqualToSize(icon.size, CGSizeMake(29, 29)) ||
            icon.renderingMode != UIImageRenderingModeAlwaysOriginal || !png.length) {
            fprintf(stderr, "FAIL Settings entry title or icon\n");
            return 1;
        }
        if (argc == 2) {
            puts([png base64EncodedStringWithOptions:0].UTF8String);
            return 0;
        }
        RILatencyController *probe = [RILatencyController new];
        [probe loadViewIfNeeded];
        [probe tap];
        CGFloat red = 0, green = 0, blue = 0, alpha = 0;
        if (![probe.panel.backgroundColor getRed:&red green:&green blue:&blue alpha:&alpha] ||
            probe.taps != 1 || std::abs(red - 0.12) > 0.001 || std::abs(green - 0.80) > 0.001 ||
            std::abs(blue - 0.30) > 0.001 || alpha != 1) {
            fprintf(stderr, "FAIL response latency test panel\n");
            return 1;
        }
        [probe tap];
        if (probe.taps != 2 || ![probe.counter.text isEqual:@"点击次数：2"]) {
            fprintf(stderr, "FAIL response latency test counter\n");
            return 1;
        }
        NSMutableDictionary *state = [@{@"updatedAt": @([NSDate date].timeIntervalSince1970),
            @"protocol": @"rdp-nla-avc420", @"capture": @"ready", @"service": @"running",
            @"hardware": @YES, @"inputAvailable": @YES, @"clientConnected": @YES,
            @"keyboardAvailable": @YES, @"unicodeInputAvailable": @YES,
            @"clipboardReady": @YES, @"inputError": @"",
            @"listening": @YES, @"gfxReady": @YES, @"width": @1080, @"height": @1440,
            @"fps": @59.8, @"bitrate": @4000000, @"captureMs": @2.5, @"error": @""} mutableCopy];
        controller.state = state;
        BOOL passed = YES;
        for (NSArray *test in @[
            @[@"protocol", @"RDP / NLA / AVC420"], @[@"service", @"运行中"],
            @[@"capture", @"已就绪"], @[@"hardware", @"使用中"],
            @[@"inputAvailable", @"可用"], @[@"clientConnected", @"已连接"],
            @[@"keyboardAvailable", @"可用"], @[@"unicodeInputAvailable", @"可用"],
            @[@"clipboardReady", @"已就绪"], @[@"inputError", @"无"],
            @[@"listening", @"监听中"], @[@"gfxReady", @"已就绪"],
            @[@"resolution", @"1080 × 1440 px"], @[@"fps", @"59.8 FPS"],
            @[@"bitrate", @"4.0 Mbps"], @[@"captureMs", @"2.5 ms"], @[@"error", @"无"]
        ]) passed &= expect(controller, test[0], test[1]);
        [state addEntriesFromDictionary:@{@"capture": @"idle", @"hardware": @NO,
            @"clientConnected": @NO, @"gfxReady": @NO, @"fps": @0}];
        for (NSArray *test in @[
            @[@"capture", @"空闲（未采集）"], @[@"hardware", @"未启用"],
            @[@"clientConnected", @"未连接"], @[@"gfxReady", @"未就绪"],
            @[@"resolution", @"未启动"], @[@"captureMs", @"未启动"], @[@"fps", @"0.0 FPS"]
        ]) passed &= expect(controller, test[0], test[1]);
        for (NSArray *test in @[@[@"initializing", @"初始化中"], @[@"unavailable", @"采集接口不可用"]]) {
            state[@"capture"] = test[0];
            passed &= expect(controller, @"capture", test[1]);
        }
        [state removeObjectForKey:@"fps"];
        passed &= expect(controller, @"fps", @"未报告");
        state[@"updatedAt"] = @([NSDate date].timeIntervalSince1970 - 6);
        passed &= expect(controller, @"fps", @"服务未运行 / 状态过期");
        if (!passed) return 1;
        puts("PASS: Settings entry name/icon, RDP localization, units, idle metrics and expired status");
        return 0;
    }
}
