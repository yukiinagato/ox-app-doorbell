#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>

// doorbell-core の fMP4 ライブをローカル HLS に変換し、iOS 5 標準の
// MPMoviePlayerController でハードウェア再生する。失敗時は呼び出し側が MJPEG に戻す。
typedef NS_ENUM(NSInteger, DBH264PlayerState) {
  DBH264PlayerIdle = 0,
  DBH264PlayerLoading,
  DBH264PlayerPlaying,
  DBH264PlayerFailed
};

@interface DBH264Player : NSObject

// HLS/MPMoviePlayerController は対象の iOS 5.1 で利用できる。
+ (BOOL)hardwareSupported;

// url: /stream.mp4 の URL。container: 貼り付ける view (moviePlayer の view を full frame)。
// onState: main スレッドで Playing/Failed を通知。再生後の失敗も通知される。
- (id)initWithURL:(NSString *)url container:(UIView *)container
          onState:(void (^)(DBH264PlayerState st))onState;
- (void)start;   // 冪等
- (void)stop;    // 冪等。movie player 解放 + 通知停止
- (DBH264PlayerState)state;

@end
