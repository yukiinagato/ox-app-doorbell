#import <Foundation/Foundation.h>
#import "DBSipSession.h"

@protocol DBMiniSipListenerDelegate <NSObject>
- (void)miniSipListenerStateChanged:(DBMiniSipState)state mode:(NSString *)mode;
@end

// Persistent direct-call UAS adapter for camera-less iPad door stations. The
// underlying C listener handles one dialog and is recreated after every call.
@interface DBSipListener : NSObject

@property(nonatomic, weak) id<DBMiniSipListenerDelegate> delegate;

- (id)initWithPort:(int)port micEnabled:(BOOL)micEnabled;
- (void)start;
- (void)hangupCurrentCall;
- (void)stop;

@end
