#import <UIKit/UIKit.h>

#import "DBHTTPMediaSupport.h"

typedef void (^DBSnapshotFrameHandler)(UIImage *image);
typedef void (^DBSnapshotStateHandler)(NSString *state, NSString *reason);

// Low-rate, bounded JPEG polling fallback. HTTP transport and thumbnail decode
// stay off the main run loop and support the platform TLS stack.
@interface DBSnapshotPoller : NSObject

@property(nonatomic, assign) BOOL lowResourceMode;

- (id)initWithURLString:(NSString *)urlString onFrame:(DBSnapshotFrameHandler)onFrame;
- (id)initWithURLString:(NSString *)urlString
     credentialProvider:(DBHTTPMediaCredentialProvider)credentialProvider
            stateHandler:(DBSnapshotStateHandler)stateHandler
                 onFrame:(DBSnapshotFrameHandler)onFrame;
- (void)start;
- (void)stop;

@end
