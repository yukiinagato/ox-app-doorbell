// MJPEG (multipart/x-mixed-replace) の自前デコーダ (ios/Doorbell/MjpegClient.swift の MRC 移植)。
// NSURLConnection の増量受信 + 境界パース + [UIImage imageWithData:] で組む。
// 子機 httpd の /stream.mjpeg はパート毎に Content-Length を必ず付ける。
// 接続断は 2 秒後に自動再接続 (stop まで)。onFrame は main スレッドで呼ばれる。
#import <UIKit/UIKit.h>

typedef void (^DBMjpegFrameHandler)(UIImage *image);

@interface DBMjpegClient : NSObject

- (id)initWithUrlString:(NSString *)urlString onFrame:(DBMjpegFrameHandler)onFrame;
- (void)start;
- (void)stop;

@end
