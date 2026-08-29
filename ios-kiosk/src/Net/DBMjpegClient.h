#import <UIKit/UIKit.h>

// MJPEG (multipart/x-mixed-replace) 受信クライアント — ios-kiosk 版。
//
// 設計 (旧版 ios-legacy の最大の问题を構造で潰す):
//  - 旧版: NSURLConnection を main runloop で駆動し、parseLoop の while(YES) 内で
//    UIImage を生成 (JPEG デコード) → main スレッドが周期的に長阻塞 → UI 無反応。
//  - 新版: BSD socket を専用スレッドで同期的に読み (main runloop に一切乗らない)、
//    デコードは専用の直列 queue (ImageIO サムネイル = DCT スケーリングで低負荷)、
//    「常に最新フレーム優先」で古いフレームは破棄、帧レート上限 (~8fps)、
//    main スレッドでは受け取った UIImage を UIImageView に設定するだけ。
typedef void (^DBMjpegFrameHandler)(UIImage *image);  // main スレッドで呼ばれる

@interface DBMjpegClient : NSObject

- (id)initWithURLString:(NSString *)urlString onFrame:(DBMjpegFrameHandler)onFrame;
- (void)start;  // 冪等
- (void)stop;   // 冪等。socket を shutdown してスレッドを即起床させる

@end
