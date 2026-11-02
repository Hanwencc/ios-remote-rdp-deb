#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>

int main() {
    @autoreleasepool {
        VTCompressionSessionRef encoder = nullptr;
        NSDictionary *spec = @{@"RequireHardwareAcceleratedVideoEncoder": @YES};
        OSStatus status = VTCompressionSessionCreate(nullptr, 1080, 1440, kCMVideoCodecType_H264,
            (__bridge CFDictionaryRef)spec, nullptr, nullptr, nullptr, nullptr, &encoder);
        if (status) { NSLog(@"Encoder property probe create failed: %d", int(status)); return 1; }
        NSDictionary *settings = @{
            (id)kVTCompressionPropertyKey_RealTime: @YES,
            (id)kVTCompressionPropertyKey_AllowFrameReordering: @NO,
            (id)kVTCompressionPropertyKey_ProfileLevel: (id)kVTProfileLevel_H264_Baseline_AutoLevel,
            (id)kVTCompressionPropertyKey_AverageBitRate: @4000000,
            (id)kVTCompressionPropertyKey_ExpectedFrameRate: @60,
            (id)kVTCompressionPropertyKey_MaxKeyFrameInterval: @120
        };
        status = VTSessionSetProperties(encoder, (__bridge CFDictionaryRef)settings);
        CFDictionaryRef supported = nullptr;
        if (!status) status = VTSessionCopySupportedPropertyDictionary(encoder, &supported);
        if (status || !supported) {
            NSLog(@"Encoder property probe setup failed: %d", int(status));
            VTCompressionSessionInvalidate(encoder); CFRelease(encoder);
            return 1;
        }
        NSMutableDictionary *report = [NSMutableDictionary dictionary];
        NSDictionary *metadata = (__bridge NSDictionary *)supported;
        for (NSString *key in @[@"UsingHardwareAcceleratedVideoEncoder", @"MaxFrameDelayCount",
                               @"RealTime", @"AllowFrameReordering", @"ProfileLevel"]) {
            CFTypeRef value = nullptr;
            status = VTSessionCopyProperty(encoder, (__bridge CFStringRef)key, nullptr, &value);
            NSMutableDictionary *item = [@{@"readStatus": @(status), @"supported": @(metadata[key] != nil)} mutableCopy];
            if (value) { item[@"value"] = (__bridge id)value; CFRelease(value); }
            if (metadata[key]) item[@"metadata"] = metadata[key];
            report[key] = item;
        }
        for (NSNumber *requested in @[@0, @1]) {
            status = VTSessionSetProperty(encoder, kVTCompressionPropertyKey_MaxFrameDelayCount,
                (__bridge CFTypeRef)requested);
            CFTypeRef value = nullptr;
            OSStatus readStatus = VTSessionCopyProperty(encoder, kVTCompressionPropertyKey_MaxFrameDelayCount,
                nullptr, &value);
            NSMutableDictionary *item = [@{@"requested": requested, @"setStatus": @(status),
                @"readStatus": @(readStatus)} mutableCopy];
            if (value) { item[@"readback"] = (__bridge id)value; CFRelease(value); }
            report[[NSString stringWithFormat:@"frameDelay%@", requested]] = item;
        }
        CFRelease(supported);
        VTCompressionSessionInvalidate(encoder); CFRelease(encoder);
        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:&error];
        if (!data) { NSLog(@"Encoder property probe serialization failed: %@", error); return 1; }
        puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
        return 0;
    }
}
