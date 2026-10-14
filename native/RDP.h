#import <Foundation/Foundation.h>
#import "Engine.h"

@interface RIRDPServer : NSObject
- (instancetype)initWithConfig:(NSDictionary *)config engine:(RIEngine *)engine directory:(NSString *)directory;
- (NSString *)start;
- (void)stop;
- (NSDictionary *)status;
@end
