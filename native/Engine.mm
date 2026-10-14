#import "Engine.h"
#include "LatencyFlow.hpp"
#import <UIKit/UIKit.h>
#import <IOSurface/IOSurfaceRef.h>
#import <VideoToolbox/VideoToolbox.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <atomic>
#include <map>
#include <mutex>
#include <cmath>
#include <vector>

using HID = CFTypeRef;
using HIDClient = CFTypeRef;
struct Touch { double x, y; uint32_t index; };

@interface RIEngine () {
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    CVPixelBufferPoolRef _pool;
    VTCompressionSessionRef _encoder;
    RIEncodedHandler _handler;
    NSMutableDictionary *_state;
    std::mutex _stateMutex;
    std::mutex _inputMutex;
    std::map<uint32_t, Touch> _touches;
    std::atomic<bool> _streaming, _keyRequested;
    std::atomic<int> _inFlight;
    std::atomic<uint32_t> _epoch, _sequence;
    std::atomic<uint32_t> _capturePressure;
    int _sourceWidth, _sourceHeight, _width, _height, _fps, _bitrate;
    double _fpsStarted;
    double _lastWake;
    double _timingStart;
    double _renderTotal, _submitTotal;
    double _encodedTimeTotal, _encodedTimeMax;
    unsigned _timingCount;
    std::atomic<uint64_t> _ticks, _skipped, _submitted, _backpressureSkipped;
    unsigned _fpsFrames;
    void (*_render)(mach_port_t, CFStringRef, IOSurfaceRef, int, int);
    mach_port_t (*_port)();
    void (*_wake)();
    HIDClient _hidClient;
    HID (*_hand)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t,
                 uint32_t, double, double, double, double, double, Boolean, Boolean, uint32_t);
    HID (*_finger)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                   double, double, double, double, double, Boolean, Boolean, uint32_t);
    void (*_integer)(HID, uint32_t, CFIndex);
    void (*_append)(HID, HID, uint32_t);
    void (*_dispatch)(HIDClient, HID);
    HID (*_keyboard)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, Boolean, uint32_t);
    void (*_sender)(HID, uint64_t);
    uint64_t _senderID;
}
- (void)tick;
- (void)encoded:(CMSampleBufferRef)sample status:(OSStatus)status;
@end

static void output(void *context, void *, OSStatus status, VTEncodeInfoFlags,
                   CMSampleBufferRef sample) {
    @autoreleasepool { [(__bridge RIEngine *)context encoded:sample status:status]; }
}

@implementation RIEngine
- (instancetype)initWithConfig:(NSDictionary *)config {
    if (!(self = [super init])) return nil;
    _fps = [config[@"fps"] intValue];
    _bitrate = [config[@"bitrate"] intValue];
    _width = [config[@"width"] intValue];
    _epoch = 1;
    _state = [@{@"capture": @"initializing", @"hardware": @NO, @"fps": @0,
                @"frames": @0, @"epoch": @1, @"error": @""} mutableCopy];
    dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
    _queue = dispatch_queue_create("com.xyhelper.remoteipad.capture", attributes);
    dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW | RTLD_GLOBAL);
    dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_GLOBAL);
    dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
           RTLD_NOW | RTLD_GLOBAL);
    _render = (decltype(_render))dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
    if (!_render) {
        _state[@"capture"] = @"unavailable";
        _state[@"error"] = @"System capture API unavailable";
        NSLog(@"RemoteIPad: system capture API unavailable");
    }
    _port = (decltype(_port))dlsym(RTLD_DEFAULT, "CARenderServerGetServerPort");
    _wake = (decltype(_wake))dlsym(RTLD_DEFAULT, "SBSUndimScreen");
    _hand = (decltype(_hand))dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerEvent");
    _finger = (decltype(_finger))dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEvent");
    _integer = (decltype(_integer))dlsym(RTLD_DEFAULT, "IOHIDEventSetIntegerValue");
    _append = (decltype(_append))dlsym(RTLD_DEFAULT, "IOHIDEventAppendEvent");
    _dispatch = (decltype(_dispatch))dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientDispatchEvent");
    _keyboard = (decltype(_keyboard))dlsym(RTLD_DEFAULT, "IOHIDEventCreateKeyboardEvent");
    _sender = (decltype(_sender))dlsym(RTLD_DEFAULT, "IOHIDEventSetSenderID");
    auto createClient = (HIDClient (*)(CFAllocatorRef))dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
    if (createClient) _hidClient = createClient(NULL);
    auto services = (CFArrayRef (*)(HIDClient))dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCopyServices");
    auto property = (CFTypeRef (*)(CFTypeRef, CFStringRef))dlsym(RTLD_DEFAULT, "IOHIDServiceClientCopyProperty");
    auto registry = (CFTypeRef (*)(CFTypeRef))dlsym(RTLD_DEFAULT, "IOHIDServiceClientGetRegistryID");
    if (_hidClient && services && property && registry) {
        CFArrayRef list = services(_hidClient);
        for (CFIndex i = 0; list && i < CFArrayGetCount(list); ++i) {
            CFTypeRef item = CFArrayGetValueAtIndex(list, i);
            CFTypeRef page = property(item, CFSTR("PrimaryUsagePage"));
            CFTypeRef usage = property(item, CFSTR("PrimaryUsage"));
            if (page && usage && CFEqual(page, (__bridge CFTypeRef)@13) &&
                CFEqual(usage, (__bridge CFTypeRef)@4)) {
                CFTypeRef number = registry(item);
                if (number && CFGetTypeID(number) == CFNumberGetTypeID())
                    CFNumberGetValue((CFNumberRef)number, kCFNumberSInt64Type, &_senderID);
            }
            if (page) CFRelease(page); if (usage) CFRelease(usage);
        }
        if (list) CFRelease(list);
    }
    _state[@"inputAvailable"] = @(_hidClient && _hand && _finger && _integer &&
                                  _append && _dispatch && _sender && _senderID);
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT, _queue);
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              NSEC_PER_SEC, NSEC_PER_MSEC);
    __weak RIEngine *weak = self;
    dispatch_source_set_event_handler(_timer, ^{ @autoreleasepool { [weak tick]; } });
    dispatch_resume(_timer);
    return self;
}
- (void)setEncodedHandler:(RIEncodedHandler)handler {
    dispatch_sync(_queue, ^{ self->_handler = [handler copy]; });
}
- (void)setStreaming:(BOOL)streaming {
    _streaming = streaming;
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              streaming ? NSEC_PER_SEC / _fps : NSEC_PER_SEC, NSEC_PER_MSEC);
    if (streaming) {
        _keyRequested = true;
        if (_wake) _wake();
        dispatch_async(_queue, ^{
            std::lock_guard<std::mutex> guard(self->_stateMutex);
            self->_fpsStarted = CACurrentMediaTime();
            self->_fpsFrames = 0;
            self->_encodedTimeTotal = self->_encodedTimeMax = 0;
        });
    } else {
        [self releaseTouches];
        dispatch_async(_queue, ^{
            if (self->_streaming) return;
            [self destroyEncoder];
            std::lock_guard<std::mutex> guard(self->_stateMutex);
            self->_state[@"fps"] = @0;
            self->_state[@"capture"] = @"idle";
            self->_state[@"hardware"] = @NO;
        });
    }
}
- (void)requestKeyframe { _keyRequested = true; }
- (void)setCapturePressure:(unsigned)queued blocked:(BOOL)blocked {
    _capturePressure = latencyFlow::capturePressure(queued, blocked);
}
- (void)error:(NSString *)message {
    std::lock_guard<std::mutex> guard(_stateMutex);
    if (![_state[@"error"] isEqual:message]) NSLog(@"RemoteIPad: %@", message);
    _state[@"error"] = message;
}
- (void)destroyEncoder {
    if (_encoder) {
        VTCompressionSessionCompleteFrames(_encoder, kCMTimeInvalid);
        VTCompressionSessionInvalidate(_encoder);
        CFRelease(_encoder); _encoder = NULL;
    }
    if (_pool) { CFRelease(_pool); _pool = NULL; }
}
- (BOOL)prepare:(CGRect)bounds {
    [self releaseTouches];
    [self destroyEncoder];
    _sourceWidth = (int)bounds.size.width;
    _sourceHeight = (int)bounds.size.height;
    int longEdge = MAX(_sourceWidth, _sourceHeight);
    int outputLong = MIN(_width, longEdge);
    int width = int(double(_sourceWidth) * outputLong / longEdge) & ~1;
    int height = int(double(_sourceHeight) * outputLong / longEdge) & ~1;
    _height = height;
    NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @YES};
    NSMutableDictionary *poolAttributes = [attributes mutableCopy];
    poolAttributes[(id)kCVPixelBufferWidthKey] = @(_sourceWidth);
    poolAttributes[(id)kCVPixelBufferHeightKey] = @(_sourceHeight);
    poolAttributes[(id)kCVPixelBufferPixelFormatTypeKey] = @(kCVPixelFormatType_32BGRA);
    CVReturn result = CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)poolAttributes, &_pool);
    if (result) { [self error:[NSString stringWithFormat:@"Pixel pool failed: %d", result]]; return NO; }
    NSDictionary *spec = @{@"RequireHardwareAcceleratedVideoEncoder": @YES};
    OSStatus status = VTCompressionSessionCreate(NULL, width, height, kCMVideoCodecType_H264,
        (__bridge CFDictionaryRef)spec, NULL, NULL, output, (__bridge void *)self, &_encoder);
    if (status) { [self error:[NSString stringWithFormat:@"Encoder create failed: %d", (int)status]]; return NO; }
    NSDictionary *settings = @{
        (id)kVTCompressionPropertyKey_RealTime: @YES,
        (id)kVTCompressionPropertyKey_AllowFrameReordering: @NO,
        (id)kVTCompressionPropertyKey_ProfileLevel: (id)kVTProfileLevel_H264_Baseline_AutoLevel,
        (id)kVTCompressionPropertyKey_AverageBitRate: @(_bitrate),
        (id)kVTCompressionPropertyKey_ExpectedFrameRate: @(_fps),
        (id)kVTCompressionPropertyKey_MaxKeyFrameInterval: @(_fps * 2)
    };
    status = VTSessionSetProperties(_encoder, (__bridge CFDictionaryRef)settings);
    if (status) { [self error:[NSString stringWithFormat:@"Encoder settings failed: %d", (int)status]]; return NO; }
    CFTypeRef hardware = NULL;
    status = VTSessionCopyProperty(_encoder, CFSTR("UsingHardwareAcceleratedVideoEncoder"), NULL, &hardware);
    BOOL accelerated = !status && hardware && CFEqual(hardware, kCFBooleanTrue);
    if (hardware) CFRelease(hardware);
    if (!accelerated) { [self error:@"Hardware encoder could not be confirmed"]; return NO; }
    status = VTCompressionSessionPrepareToEncodeFrames(_encoder);
    if (status) { [self error:[NSString stringWithFormat:@"Encoder preparation failed: %d", (int)status]]; return NO; }
    ++_epoch;
    _keyRequested = true;
    _fpsStarted = CACurrentMediaTime();
    _timingStart = _fpsStarted;
    _fpsFrames = 0;
    _encodedTimeTotal = _encodedTimeMax = 0;
    {
        std::lock_guard<std::mutex> guard(_stateMutex);
        [_state addEntriesFromDictionary:@{@"capture": @"ready", @"hardware": @YES,
            @"width": @(width), @"height": @(height), @"sourceWidth": @(_sourceWidth),
            @"sourceHeight": @(_sourceHeight), @"epoch": @(_epoch.load()),
            @"targetFps": @(_fps), @"bitrate": @(_bitrate), @"error": @""}];
    }
    return YES;
}
- (void)tick {
    if (!_streaming || !_handler || !_render) return;
    ++_ticks;
    if (_inFlight >= 2) { ++_skipped; return; }
    if (!latencyFlow::admitCapture(_inFlight.load(), _capturePressure.load())) {
        ++_backpressureSkipped; return;
    }
    CGRect bounds = UIScreen.mainScreen.nativeBounds;
    if (bounds.size.width <= 0 || bounds.size.height <= 0) { [self error:@"Screen dimensions unavailable"]; return; }
    if (!_encoder || _sourceWidth != bounds.size.width || _sourceHeight != bounds.size.height) {
        if (![self prepare:bounds]) { [self destroyEncoder]; _streaming = false; return; }
    }
    double started = CACurrentMediaTime();
    if (_wake && started - _lastWake > 10) { _wake(); _lastWake = started; }
    CVPixelBufferRef pixel = NULL;
    NSDictionary *limit = @{(id)kCVPixelBufferPoolAllocationThresholdKey: @3};
    CVReturn result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(NULL, _pool,
        (__bridge CFDictionaryRef)limit, &pixel);
    if (result == kCVReturnWouldExceedAllocationThreshold) return;
    if (result) { [self error:[NSString stringWithFormat:@"Capture buffer failed: %d", result]]; return; }
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(pixel);
    if (!surface) { CFRelease(pixel); [self error:@"Capture IOSurface unavailable"]; return; }
    kern_return_t locked = IOSurfaceLock(surface, 0, NULL);
    if (locked) { CFRelease(pixel); [self error:[NSString stringWithFormat:@"IOSurface lock failed: %d", locked]]; return; }
    _render(_port ? _port() : 0, CFSTR("LCD"), surface, 0, 0);
    IOSurfaceUnlock(surface, 0, NULL);
    double rendered = CACurrentMediaTime();
    uint64_t microseconds = uint64_t(started * 1000000);
    NSDictionary *properties = _keyRequested.exchange(false) ?
        @{(id)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES} : nil;
    ++_inFlight;
    ++_submitted;
    OSStatus status = VTCompressionSessionEncodeFrame(_encoder, pixel,
        CMTimeMake(microseconds, 1000000), CMTimeMake(1, _fps),
        (__bridge CFDictionaryRef)properties, NULL, NULL);
    CFRelease(pixel);
    if (status) { --_inFlight; [self error:[NSString stringWithFormat:@"Encoding failed: %d", (int)status]]; }
    double finished = CACurrentMediaTime();
    std::lock_guard<std::mutex> guard(_stateMutex);
    _state[@"captureMs"] = @((finished - started) * 1000);
    _renderTotal += rendered - started;
    _submitTotal += finished - rendered;
    ++_timingCount;
    if (finished - _timingStart >= 1) {
        _state[@"renderAverageMs"] = @(_renderTotal * 1000 / _timingCount);
        _state[@"submitAverageMs"] = @(_submitTotal * 1000 / _timingCount);
        _renderTotal = _submitTotal = 0; _timingCount = 0; _timingStart = finished;
    }
}
- (void)encoded:(CMSampleBufferRef)sample status:(OSStatus)status {
    if (status || !sample || !CMSampleBufferDataIsReady(sample)) {
        --_inFlight;
        [self error:[NSString stringWithFormat:@"Encoder output failed: %d", (int)status]];
        return;
    }
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
    BOOL key = !attachments || !CFArrayGetCount(attachments) ||
        !CFDictionaryContainsKey((CFDictionaryRef)CFArrayGetValueAtIndex(attachments, 0),
                                 kCMSampleAttachmentKey_NotSync);
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
    if (!format || CMFormatDescriptionGetMediaSubType(format) != kCMVideoCodecType_H264 ||
        !block || !CMBlockBufferGetDataLength(block)) {
        --_inFlight; [self error:@"Encoder H.264 sample unavailable"]; return;
    }
    uint64_t timestamp = uint64_t(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) * 1000000);
    double encodedMs = MAX(0.0, (CACurrentMediaTime() - double(timestamp) / 1000000) * 1000);
    _handler(sample, key, timestamp, _epoch.load(), ++_sequence);
    --_inFlight;
    double now = CACurrentMediaTime();
    {
        std::lock_guard<std::mutex> guard(_stateMutex);
        _state[@"frames"] = @(_sequence.load());
        _state[@"lastFrameAt"] = @([NSDate date].timeIntervalSince1970);
        _encodedTimeTotal += encodedMs;
        _encodedTimeMax = MAX(_encodedTimeMax, encodedMs);
        if (++_fpsFrames && now - _fpsStarted >= 1) {
            _state[@"fps"] = @(_fpsFrames / (now - _fpsStarted));
            _state[@"captureToEncodedAverageMs"] = @(_encodedTimeTotal / _fpsFrames);
            _state[@"captureToEncodedMaxMs"] = @(_encodedTimeMax);
            _encodedTimeTotal = _encodedTimeMax = 0;
            _fpsFrames = 0; _fpsStarted = now;
        }
    }
}
- (NSDictionary *)status {
    std::lock_guard<std::mutex> guard(_stateMutex);
    NSMutableDictionary *copy = [_state mutableCopy];
    copy[@"streaming"] = @(_streaming.load());
    copy[@"inFlight"] = @(_inFlight.load());
    copy[@"captureTicks"] = @(_ticks.load());
    copy[@"skippedTicks"] = @(_skipped.load());
    copy[@"captureBackpressureSkippedTicks"] = @(_backpressureSkipped.load());
    copy[@"submittedFrames"] = @(_submitted.load());
    copy[@"updatedAt"] = @([NSDate date].timeIntervalSince1970);
    return copy;
}
- (NSString *)touch:(NSDictionary *)message {
    if (!_hidClient || !_hand || !_finger || !_integer || !_append || !_dispatch || !_sender || !_senderID)
        return @"Touch injection unavailable";
    NSNumber *identifier = message[@"id"], *xValue = message[@"x"], *yValue = message[@"y"];
    NSString *phase = message[@"phase"];
    if (![identifier isKindOfClass:NSNumber.class] || ![xValue isKindOfClass:NSNumber.class] ||
        ![yValue isKindOfClass:NSNumber.class] || ![phase isKindOfClass:NSString.class] ||
        ![message[@"epoch"] isKindOfClass:NSNumber.class]) return @"Invalid touch message";
    double x = xValue.doubleValue, y = yValue.doubleValue;
    if (!std::isfinite(x) || !std::isfinite(y) || x < 0 || x > 1 || y < 0 || y > 1 ||
        identifier.longLongValue < 0 || identifier.unsignedLongLongValue >= UINT32_MAX)
        return @"Invalid touch coordinates or identifier";
    if ([message[@"epoch"] unsignedIntValue] != _epoch.load()) return @"Stale screen orientation";
    BOOL down = [phase isEqual:@"down"], move = [phase isEqual:@"move"];
    BOOL up = [phase isEqual:@"up"] || [phase isEqual:@"cancel"];
    if (!down && !move && !up) return @"Invalid touch phase";
    std::lock_guard<std::mutex> guard(_inputMutex);
    uint32_t identifierValue = identifier.unsignedIntValue;
    if (down && (_touches.count(identifierValue) || _touches.size() >= 5)) return @"Touch already active or limit exceeded";
    if (!down && !_touches.count(identifierValue)) return @"Touch is not active";
    auto next = _touches;
    if (down) {
        uint32_t index = 1;
        for (;;) {
            bool used = false;
            for (auto touch : next) if (touch.second.index == index) used = true;
            if (!used) break;
            ++index;
        }
        next[identifierValue] = {x, y, index};
    } else {
        next[identifierValue].x = x;
        next[identifierValue].y = y;
    }
    uint32_t mask = move ? 4 : 3;
    uint64_t time = mach_absolute_time();
    BOOL touching = !up || next.size() > 1;
    HID parent = _hand(NULL, time, 3, 0, 0, mask, 0, 0, 0, 0, 0, 0, touching, touching, 0);
    if (!parent) return @"Digitizer allocation failed";
    _integer(parent, (11 << 16) + 23, 1);
    _integer(parent, (11 << 16) + 25, 1);
    _integer(parent, 4, 1);
    _sender(parent, _senderID);
    for (auto entry : next) {
        BOOL touching = !(up && entry.first == identifierValue);
        HID child = _finger(NULL, time, entry.second.index, entry.first + 1,
            entry.first == identifierValue ? mask : 0, entry.second.x, entry.second.y,
            0, touching ? 1 : 0, 0, touching, touching, 0);
        if (!child) { CFRelease(parent); return @"Finger allocation failed"; }
        _append(parent, child, 0);
        CFRelease(child);
    }
    _dispatch(_hidClient, parent); CFRelease(parent);
    if (up) next.erase(identifierValue);
    _touches = std::move(next);
    return nil;
}
- (void)releaseTouches {
    std::vector<std::pair<uint32_t, Touch>> copy;
    {
        std::lock_guard<std::mutex> guard(_inputMutex);
        for (auto touch : _touches) copy.push_back(touch);
    }
    for (auto touch : copy) [self touch:@{@"id": @(touch.first), @"x": @(touch.second.x),
        @"y": @(touch.second.y), @"epoch": @(_epoch.load()), @"phase": @"cancel"}];
}
- (NSString *)home {
    if (!_keyboard || !_dispatch || !_hidClient || !_integer || !_sender || !_senderID)
        return @"Home injection unavailable";
    for (BOOL pressed : {YES, NO}) {
        HID event = _keyboard(NULL, mach_absolute_time(), 0x0c, 0x40, pressed, 0);
        if (!event) return @"Home event allocation failed";
        if (_sender && _senderID) _sender(event, _senderID);
        _integer(event, 4, 1);
        _dispatch(_hidClient, event); CFRelease(event);
    }
    return nil;
}
@end
