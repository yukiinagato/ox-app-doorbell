#import <GLKit/GLKit.h>

// Jailbroken iOS 5 low-latency H.264 renderer. VideoToolbox is loaded with
// dlsym because the decoding API exists on the device but was not public until
// later iOS releases.
@interface DBVtVideoView : GLKView

@property(nonatomic, copy) void (^onDisplayedFrame)(int64_t captureMs);
// Drop decoded frames that are already too old before they enter the GL queue.
@property(nonatomic) int64_t serverToClientOffsetMs;
@property(nonatomic) int64_t maxQueueAgeMs;
@property(nonatomic, readonly) NSUInteger decodedFrames;
@property(nonatomic, readonly) NSUInteger droppedFrames;

- (BOOL)startWithSps:(NSData *)sps pps:(NSData *)pps;
- (void)pushSample:(NSData *)avcc
         captureMs:(int64_t)captureMs
             dtsMs:(int64_t)dtsMs
             durMs:(int64_t)durMs;
- (void)shutdownDecoder;

@end
