#import <GLKit/GLKit.h>

// Low-latency H.264 renderer shared by compatibility profiles. iOS 5 loads the
// device-only decoder dynamically; iOS 9 links the public VideoToolbox API.
@interface DBVtVideoView : GLKView

+ (void)prewarm;
+ (DBVtVideoView *)takeWarmView;
+ (void)recycleWarmView:(DBVtVideoView *)view;
+ (void)purgeWarmView;

@property(nonatomic, copy) void (^onDisplayedFrame)(int64_t captureMs);
@property(nonatomic) int64_t serverToClientOffsetMs;
@property(nonatomic, readonly) NSUInteger decodedFrames;
@property(nonatomic, readonly) NSUInteger droppedFrames;

// Adaptive live edge. It seeds high and tightens only after the device's own
// baseline latency has been measured; see DBLiveEdgeGate.h for why a fixed
// sub-100 ms budget is unreachable on the original iPad. Pass clockTrusted=NO
// when the server clock is unknown: the gate then never drops on age.
- (void)configureLiveEdgeStartMs:(int64_t)startMs
                         floorMs:(int64_t)floorMs
                       ceilingMs:(int64_t)ceilingMs
                    clockTrusted:(BOOL)clockTrusted;
- (int64_t)liveEdgeMs;

- (void)setCompatibilityOutputView:(UIImageView *)view;
- (BOOL)startWithSps:(NSData *)sps pps:(NSData *)pps;
- (void)pushSample:(NSData *)avcc
         captureMs:(int64_t)captureMs
             dtsMs:(int64_t)dtsMs
             durMs:(int64_t)durMs;
- (void)shutdownDecoder;

@end
