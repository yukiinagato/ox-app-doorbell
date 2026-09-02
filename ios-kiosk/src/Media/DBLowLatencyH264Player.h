#import <UIKit/UIKit.h>
#import "DBVideoStats.h"

typedef NS_ENUM(NSInteger, DBLowLatencyPlayerState) {
  DBLowLatencyPlayerIdle = 0,
  DBLowLatencyPlayerLoading,
  DBLowLatencyPlayerPlaying,
  DBLowLatencyPlayerFailed,
  // Was playing, then the displayed-frame rate collapsed. The opaque
  // compositor has been hidden again so the MJPEG availability layer below is
  // visible; the caller should retry or fall back.
  DBLowLatencyPlayerStalled
};

@interface DBLowLatencyH264Player : NSObject

// Adaptive live-edge knobs, in ms; see DBLiveEdgeGate.h. Set before -start.
// Zero or negative selects the safe defaults (650 / 120 / 650).
@property(nonatomic) int64_t liveEdgeStartMs;
@property(nonatomic) int64_t liveEdgeFloorMs;
@property(nonatomic) int64_t liveEdgeCeilingMs;

- (id)initWithURL:(NSString *)url
         container:(UIView *)container
           onState:(void (^)(DBLowLatencyPlayerState state))onState;
- (void)start;
- (void)stop;
- (DBLowLatencyPlayerState)state;
- (DBVideoStats)videoStats;  // displayed-frame stats; main thread
- (CFAbsoluteTime)lastFrameAt;
- (NSUInteger)decodedFrames;
- (NSUInteger)displayedFrames;
- (NSUInteger)droppedFrames;
- (NSString *)presentationMode;

@end
