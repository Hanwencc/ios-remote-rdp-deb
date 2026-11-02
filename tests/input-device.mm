#import "../native/Engine.h"
#import <UIKit/UIKit.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        RIEngine *engine = [[RIEngine alloc] initWithConfig:@{@"fps": @60, @"width": @1440, @"bitrate": @4000000}];
        NSString *failure = nil;
        if (argc == 3 && !strcmp(argv[1], "--text")) {
            failure = [engine text:[NSString stringWithUTF8String:argv[2]]];
        } else if (argc == 3 && !strcmp(argv[1], "--key")) {
            char *end = nullptr;
            unsigned long key = strtoul(argv[2], &end, 0);
            if (!*argv[2] || *end || !key || key > 0xe7) return 2;
            failure = [engine key:uint16_t(key) down:YES];
            if (!failure) failure = [engine key:uint16_t(key) down:NO];
            [engine releaseKeys];
        } else {
            fprintf(stderr, "Usage: input-device --text TEXT | --key HID_USAGE\n");
            return 2;
        }
        if (failure) { fprintf(stderr, "%s\n", failure.UTF8String); return 1; }
        puts("Input event dispatched; verify actual fixture text separately.");
        return 0;
    }
}
