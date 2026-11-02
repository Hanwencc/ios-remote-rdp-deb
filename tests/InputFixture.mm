#import <UIKit/UIKit.h>
#include <cstring>

@interface NSObject (RIInputFixtureRegistration)
+ (instancetype)defaultWorkspace;
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
- (NSURL *)bundleURL;
- (NSURL *)dataContainerURL;
- (BOOL)unregisterApplication:(NSURL *)url;
@end

static NSString *const statePath = @"/var/mobile/Library/Caches/com.xyhelper.remoteipad-input-test.plist";

@interface RIInputFixture : UIResponder <UIApplicationDelegate, UITextViewDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) UITextView *text;
@end

@implementation RIInputFixture
- (void)save {
    NSError *error = nil;
    NSDictionary *state = @{@"text": self.text.text ?: @"", @"focused": @(self.text.isFirstResponder)};
    if (![state writeToURL:[NSURL fileURLWithPath:statePath] error:&error])
        NSLog(@"RemoteIPad input fixture write failed: %@", error);
}
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *controller = [UIViewController new];
    self.text = [[UITextView alloc] initWithFrame:CGRectInset(self.window.bounds, 40, 100)];
    self.text.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.text.font = [UIFont systemFontOfSize:24];
    self.text.autocorrectionType = UITextAutocorrectionTypeNo;
    self.text.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.text.smartInsertDeleteType = UITextSmartInsertDeleteTypeNo;
    self.text.spellCheckingType = UITextSpellCheckingTypeNo;
    self.text.smartQuotesType = UITextSmartQuotesTypeNo;
    self.text.smartDashesType = UITextSmartDashesTypeNo;
    self.text.delegate = self;
    controller.view.backgroundColor = UIColor.whiteColor;
    [controller.view addSubview:self.text];
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    [self.text becomeFirstResponder];
    [self save];
    return YES;
}
- (void)applicationDidBecomeActive:(UIApplication *)application {
    [self.text becomeFirstResponder];
    [self save];
}
- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url options:(NSDictionary *)options {
    if ([url.host isEqual:@"reset"]) self.text.text = @"";
    [self.text becomeFirstResponder];
    [self save];
    return YES;
}
- (void)textViewDidChange:(UITextView *)textView { [self save]; }
- (void)textViewDidBeginEditing:(UITextView *)textView { [self save]; }
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 2 && !strcmp(argv[1], "--unregister")) {
            Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
            Class proxyClass = NSClassFromString(@"LSApplicationProxy");
            if (![workspaceClass respondsToSelector:@selector(defaultWorkspace)] ||
                ![proxyClass respondsToSelector:@selector(applicationProxyForIdentifier:)]) {
                fprintf(stderr, "Fixture LaunchServices API unavailable\n"); return 1;
            }
            id workspace = [workspaceClass defaultWorkspace];
            id proxy = [proxyClass applicationProxyForIdentifier:@"com.xyhelper.remoteipad.input-test"];
            NSURL *url = [proxy bundleURL];
            NSURL *container = [proxy dataContainerURL];
            NSString *expected = [@"/var/jb/Applications/RemoteIPadInputTest.app" stringByResolvingSymlinksInPath];
            if (!url || ![url.path.stringByResolvingSymlinksInPath isEqual:expected]) {
                fprintf(stderr, "Fixture registration path mismatch\n"); return 1;
            }
            if (![workspace respondsToSelector:@selector(unregisterApplication:)]) {
                fprintf(stderr, "Fixture unregister API unavailable\n"); return 1;
            }
            NSString *containerPath = container.path.stringByResolvingSymlinksInPath;
            NSDictionary *metadata = containerPath ? [NSDictionary dictionaryWithContentsOfFile:
                [containerPath stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]] : nil;
            NSString *containerRoot = [@"/var/mobile/Containers/Data/Application" stringByResolvingSymlinksInPath];
            if (![[containerPath stringByDeletingLastPathComponent] isEqual:containerRoot] ||
                ![[NSUUID alloc] initWithUUIDString:containerPath.lastPathComponent] ||
                ![metadata[@"MCMMetadataIdentifier"] isEqual:@"com.xyhelper.remoteipad.input-test"]) {
                fprintf(stderr, "Fixture container identity mismatch; nothing removed\n"); return 1;
            }
            if (![workspace unregisterApplication:url]) {
                fprintf(stderr, "Fixture unregister failed; files retained for cleanup\n"); return 1;
            }
            NSError *error = nil;
            if (![[NSFileManager defaultManager] removeItemAtPath:containerPath error:&error]) {
                fprintf(stderr, "Fixture container cleanup failed: %s\n", error.localizedDescription.UTF8String);
                return 1;
            }
            puts("Fixture unregistered using its exact LaunchServices URL.");
            return 0;
        }
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(RIInputFixture.class));
    }
}
