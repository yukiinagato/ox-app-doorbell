#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <QuartzCore/QuartzCore.h>

@interface DBCameraFeeder : NSObject
@property(nonatomic, copy) void (^onPixelBuffer)(CVPixelBufferRef, CMTime);
@property(nonatomic, copy) void (^onCaptureStopped)(void);
- (id)initWithFrameHandler:(void (^)(NSData *, int, int, int, int))frameHandler
              stateHandler:(void (^)(BOOL, NSString *))stateHandler;
- (void)start;
- (void)stop;
/// YES while a capture session exists (it may still be starting).
@property(nonatomic, readonly) BOOL running;
/// A new preview layer bound to the running session, or nil when the camera is not running.
/// The QR scanner shows it so the user can aim; frames keep flowing to Core unchanged.
- (CALayer *)newPreviewLayer;
@end
