#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, DBLowLatencyPlayerState) {
  DBLowLatencyPlayerIdle = 0,
  DBLowLatencyPlayerLoading,
  DBLowLatencyPlayerPlaying,
  DBLowLatencyPlayerFailed
};

@interface DBLowLatencyH264Player : NSObject

- (id)initWithURL:(NSString *)url
         container:(UIView *)container
           onState:(void (^)(DBLowLatencyPlayerState state))onState;
- (void)start;
- (void)stop;
- (DBLowLatencyPlayerState)state;

@end
