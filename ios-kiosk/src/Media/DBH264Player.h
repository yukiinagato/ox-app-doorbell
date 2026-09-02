#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import "DBVideoStats.h"

// iOS 5 H.264 compatibility player. It converts the bounded fMP4 input into a loopback HLS feed
// consumed by MPMoviePlayerController; decoding remains in the system hardware path.

typedef NS_ENUM(NSInteger, DBH264PlayerState) {
  DBH264PlayerIdle = 0,
  DBH264PlayerLoading,
  DBH264PlayerPlaying,
  DBH264PlayerFailed
};

@interface DBH264Player : NSObject


+ (BOOL)hardwareSupported;



- (id)initWithURL:(NSString *)url container:(UIView *)container
          onState:(void (^)(DBH264PlayerState st))onState;
- (void)start;
- (void)stop;
- (DBH264PlayerState)state;
- (DBVideoStats)videoStats;  // HLS playback-position based estimate; main thread
- (CFAbsoluteTime)lastFrameAt;

@end
