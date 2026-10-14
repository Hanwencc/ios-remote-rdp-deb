#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <IOSurface/IOSurfaceRef.h>
#import <VideoToolbox/VideoToolbox.h>
#import <ImageIO/ImageIO.h>
#import "Engine.h"
#include <dlfcn.h>
#include <mach/mach.h>
#include <unistd.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 1 && !(argc == 4 && strcmp(argv[1], "--tap") == 0)) {
            fprintf(stderr, "Unsupported native probe arguments\n"); return 2;
        }
        if (argc == 4 && strcmp(argv[1], "--tap") == 0) {
            char *xEnd, *yEnd;
            double x = strtod(argv[2], &xEnd), y = strtod(argv[3], &yEnd);
            if (!*argv[2] || !*argv[3] || *xEnd || *yEnd) {
                fprintf(stderr, "Invalid native test tap coordinates\n"); return 2;
            }
            RIEngine *engine = [[RIEngine alloc] initWithConfig:@{@"fps": @60, @"width": @1440, @"bitrate": @4000000}];
            for (NSString *phase in @[@"down", @"up"]) {
                NSString *error = [engine touch:@{@"phase": phase, @"id": @1, @"x": @(x), @"y": @(y), @"epoch": @1}];
                if (error) { fprintf(stderr, "%s\n", error.UTF8String); return 2; }
                if ([phase isEqual:@"down"]) usleep(100000);
            }
            puts("Native test tap dispatched");
            return 0;
        }
        CGRect bounds = UIScreen.mainScreen.nativeBounds;
        printf("screen %.0fx%.0f scale %.2f\n", bounds.size.width, bounds.size.height,
               UIScreen.mainScreen.nativeScale);
        const char *paths[] = {
            "/System/Library/Frameworks/QuartzCore.framework/QuartzCore",
            "/System/Library/Frameworks/IOKit.framework/IOKit",
            "/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices",
            "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
            "/System/Library/PrivateFrameworks/ScreenshotServices.framework/ScreenshotServices"
        };
        for (auto path : paths) {
            void *handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
            printf("framework %s %s\n", path, handle ? "loaded" : dlerror());
        }
        const char *symbols[] = {
            "CARenderServerRenderDisplay", "CARenderServerGetServerPort",
            "IOHIDEventSystemClientCreate", "IOHIDEventSystemClientDispatchEvent",
            "IOHIDEventCreateDigitizerEvent", "IOHIDEventCreateDigitizerFingerEvent",
            "IOHIDEventSetIntegerValue", "IOHIDEventSetFloatValue", "IOHIDEventAppendEvent",
            "BKSHIDEventSetDigitizerInfo", "BKSHIDEventSendToFocusedProcess",
            "BKSDisplayServicesGetMainScreenInfo", "UIGetScreenImage"
        };
        for (auto symbol : symbols) printf("symbol %s %p\n", symbol, dlsym(RTLD_DEFAULT, symbol));
        auto wake = (void (*)())dlsym(RTLD_DEFAULT, "SBSUndimScreen");
        printf("wake %p\n", wake);
        if (wake) { wake(); usleep(500000); }
        auto matching = (CFMutableDictionaryRef (*)(const char *))dlsym(RTLD_DEFAULT, "IOServiceMatching");
        auto service = (uint32_t (*)(mach_port_t, CFDictionaryRef))dlsym(RTLD_DEFAULT, "IOServiceGetMatchingService");
        auto open = (kern_return_t (*)(uint32_t, task_port_t, uint32_t, uint32_t *))dlsym(RTLD_DEFAULT, "IOServiceOpen");
        if (matching && service && open) {
            uint32_t object = service(0, matching("IOSurfaceRoot")), connection = 0;
            kern_return_t result = open(object, mach_task_self(), 0, &connection);
            printf("IOSurfaceRoot service %u open 0x%x connection %u\n", object, result, connection);
        }
        auto hidCreate = (CFTypeRef (*)(CFAllocatorRef))dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
        auto hidServices = (CFArrayRef (*)(CFTypeRef))dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCopyServices");
        auto hidProperty = (CFTypeRef (*)(CFTypeRef, CFStringRef))dlsym(RTLD_DEFAULT, "IOHIDServiceClientCopyProperty");
        auto hidRegistry = (CFTypeRef (*)(CFTypeRef))dlsym(RTLD_DEFAULT, "IOHIDServiceClientGetRegistryID");
        if (hidCreate && hidServices && hidProperty && hidRegistry) {
            CFTypeRef client = hidCreate(NULL);
            CFArrayRef services = hidServices(client);
            for (CFIndex i = 0; services && i < CFArrayGetCount(services); ++i) {
                CFTypeRef item = CFArrayGetValueAtIndex(services, i);
                CFTypeRef page = hidProperty(item, CFSTR("PrimaryUsagePage"));
                CFTypeRef usage = hidProperty(item, CFSTR("PrimaryUsage"));
                if (page && CFEqual(page, (__bridge CFTypeRef)@13)) {
                    CFTypeRef registry = hidRegistry(item);
                    printf("digitizer registry %s page %s usage %s\n",
                        registry ? [[(__bridge id)registry description] UTF8String] : "?",
                        page ? [[(__bridge id)page description] UTF8String] : "?",
                        usage ? [[(__bridge id)usage description] UTF8String] : "?");
                }
                if (page) CFRelease(page); if (usage) CFRelease(usage);
            }
            if (services) CFRelease(services); if (client) CFRelease(client);
        }
        int width = (int)bounds.size.width, height = (int)bounds.size.height;
        if (width <= 0 || height <= 0) return 2;
        NSDictionary *properties = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
        CVPixelBufferRef pixel = NULL;
        CVReturn created = CVPixelBufferCreate(NULL, width, height, kCVPixelFormatType_32BGRA,
            (__bridge CFDictionaryRef)properties, &pixel);
        IOSurfaceRef surface = pixel ? CVPixelBufferGetIOSurface(pixel) : NULL;
        printf("pixel create %d surface %p\n", created, surface);
        if (!surface) {
            NSDictionary *raw = @{
                @"IOSurfaceWidth": @(width), @"IOSurfaceHeight": @(height),
                @"IOSurfaceBytesPerElement": @4,
                @"IOSurfaceBytesPerRow": @((width * 4 + 63) & ~63),
                @"IOSurfaceAllocSize": @(((width * 4 + 63) & ~63) * height),
                @"IOSurfacePixelFormat": @(kCVPixelFormatType_32BGRA)
            };
            surface = IOSurfaceCreate((__bridge CFDictionaryRef)raw);
            printf("raw surface %p properties %s\n", surface, [[raw description] UTF8String]);
        }
        using Render = void (*)(mach_port_t, CFStringRef, IOSurfaceRef, int, int);
        Render render = (Render)dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
        if (!surface || !render) return 3;
        IOSurfaceLock(surface, 0, NULL);
        auto serverPort = (mach_port_t (*)())dlsym(RTLD_DEFAULT, "CARenderServerGetServerPort");
        render(serverPort ? serverPort() : 0, CFSTR("LCD"), surface, 0, 0);
        uint8_t *bytes = (uint8_t *)IOSurfaceGetBaseAddress(surface);
        size_t stride = IOSurfaceGetBytesPerRow(surface);
        uint64_t sum = 0, nonzero = 0;
        for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
            size_t n = y * stride + x * 4;
            sum += bytes[n] + bytes[n+1] + bytes[n+2];
            if (bytes[n] || bytes[n+1] || bytes[n+2]) ++nonzero;
        }
        printf("capture rgb sum %llu nonzero pixels %llu\n", sum, nonzero);
        CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(bytes, width, height, 8, stride,
            color, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
        CGImageRef image = CGBitmapContextCreateImage(context);
        CGImageDestinationRef destination = CGImageDestinationCreateWithURL(
            (CFURLRef)[NSURL fileURLWithPath:@"/var/mobile/remoteipad-probe.png"],
            CFSTR("public.png"), 1, NULL);
        CGImageDestinationAddImage(destination, image, NULL);
        printf("png %d\n", CGImageDestinationFinalize(destination));
        CFRelease(destination); CGImageRelease(image); CGContextRelease(context);
        CGColorSpaceRelease(color); IOSurfaceUnlock(surface, 0, NULL);
        if (pixel) CFRelease(pixel); else CFRelease(surface);
        VTCompressionSessionRef session = NULL;
        NSDictionary *spec = @{@"RequireHardwareAcceleratedVideoEncoder": @YES};
        OSStatus result = VTCompressionSessionCreate(NULL, 1440, 1080, kCMVideoCodecType_H264,
            (__bridge CFDictionaryRef)spec, NULL, NULL, NULL, NULL, &session);
        printf("encoder create %d\n", (int)result);
        if (session) {
            CFTypeRef hardware = NULL;
            OSStatus status = VTSessionCopyProperty(session,
                CFSTR("UsingHardwareAcceleratedVideoEncoder"), NULL, &hardware);
            printf("hardware query %d value %s\n", (int)status,
                hardware ? [[(__bridge id)hardware description] UTF8String] : "unavailable");
            if (hardware) CFRelease(hardware);
            VTCompressionSessionInvalidate(session); CFRelease(session);
        }
        return nonzero ? 0 : 4;
    }
}
