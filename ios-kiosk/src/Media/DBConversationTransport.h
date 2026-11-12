#import <Foundation/Foundation.h>
@class DBCoreBridge;
@interface DBConversationTransport : NSObject
- (id)initWithCore:(DBCoreBridge *)core;
- (void)handleEvent:(NSDictionary *)event;
- (void)stop;
@end
