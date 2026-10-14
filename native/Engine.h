#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

// The sample is borrowed for this callback; retain it before handing it to an asynchronous queue.
typedef void (^RIEncodedHandler)(CMSampleBufferRef sample, BOOL key,
                                uint64_t timestamp, uint32_t epoch, uint32_t sequence);

@interface RIEngine : NSObject
- (instancetype)initWithConfig:(NSDictionary *)config;
- (void)setEncodedHandler:(RIEncodedHandler)handler;
- (void)setStreaming:(BOOL)streaming;
- (void)setCapturePressure:(unsigned)queued blocked:(BOOL)blocked;
- (void)requestKeyframe;
- (NSDictionary *)status;
- (NSString *)touch:(NSDictionary *)message;
- (void)releaseTouches;
- (NSString *)home;
@end
