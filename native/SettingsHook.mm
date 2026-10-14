#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#include <dlfcn.h>
#include "Paths.hpp"
#include "SettingsAppearance.hpp"

extern "C" void MSHookMessageEx(Class, SEL, IMP, IMP *);
static void (*originalAppear)(PSListController *, SEL, BOOL);
static void appear(PSListController *self, SEL selector, BOOL animated) {
    originalAppear(self, selector, animated);
    NSString *name = NSStringFromClass(self.class);
    if (![name isEqual:@"PSGGeneralController"]) return;
    if ([self specifierForID:@"com.xyhelper.remoteipad.general"]) return;
    NSBundle *bundle = [NSBundle bundleWithPath:[NSString stringWithUTF8String:paths::bundle]];
    NSError *error = nil;
    if (![bundle loadAndReturnError:&error]) { NSLog(@"RemoteIPad preferences load failed: %@", error); return; }
    Class detail = NSClassFromString(@"RIPreferencesController");
    if (!detail) { NSLog(@"RemoteIPad preferences class missing"); return; }
    PSSpecifier *item = settingsAppearance::entry(self, detail);
    [self addSpecifier:item animated:NO];
    NSLog(@"RemoteIPad: General entry inserted");
}
__attribute__((constructor)) static void initialize() {
    dlopen("/System/Library/PrivateFrameworks/Preferences.framework/Preferences", RTLD_NOW);
    Class controller = NSClassFromString(@"PSListController");
    if (!controller) { NSLog(@"RemoteIPad: PSListController unavailable"); return; }
    MSHookMessageEx(controller, @selector(viewWillAppear:), (IMP)appear, (IMP *)&originalAppear);
}
