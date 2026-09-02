#import <UIKit/UIKit.h>

#import "../Media/DBVideoStats.h"
#import "DBHTTPMediaSupport.h"

typedef void (^DBMjpegFrameHandler)(UIImage *image);
typedef void (^DBMjpegStateHandler)(NSString *state, NSString *reason);

// Bounded MJPEG receiver for iOS 5. Networking and thumbnail decoding run off
// the main thread; only the latest pending frame is retained for display.
@interface DBMjpegClient : NSObject

@property(nonatomic, assign) BOOL lowResourceMode;

- (id)initWithURLString:(NSString *)urlString onFrame:(DBMjpegFrameHandler)onFrame;
- (id)initWithURLString:(NSString *)urlString
     credentialProvider:(DBHTTPMediaCredentialProvider)credentialProvider
            stateHandler:(DBMjpegStateHandler)stateHandler
                 onFrame:(DBMjpegFrameHandler)onFrame;
- (void)start;
- (void)stop;
- (DBVideoStats)videoStats;
- (CFAbsoluteTime)lastFrameAt;

@end
