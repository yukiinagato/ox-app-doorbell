#import <GLKit/GLKit.h>

// Low-latency H.264 renderer shared by compatibility profiles. iOS 5 loads the
// device-only decoder dynamically; iOS 9 links the public VideoToolbox API.
@interface DBVtVideoView : GLKView

@property(nonatomic, copy) void (^onDisplayedFrame)(int64_t captureMs);
// Drop decoded frames that are already too old before they enter the GL queue.
@property(nonatomic) int64_t serverToClientOffsetMs;
@property(nonatomic) int64_t maxQueueAgeMs;
@property(nonatomic, readonly) NSUInteger decodedFrames;
@property(nonatomic, readonly) NSUInteger droppedFrames;

- (void)setCompatibilityOutputView:(UIImageView *)view;
- (BOOL)startWithSps:(NSData *)sps pps:(NSData *)pps;
- (void)pushSample:(NSData *)avcc
         captureMs:(int64_t)captureMs
             dtsMs:(int64_t)dtsMs
             durMs:(int64_t)durMs;
- (void)shutdownDecoder;

@end
