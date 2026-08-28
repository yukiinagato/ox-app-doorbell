// 本機情報 / デバッグ画面。角の ⓘ から開く。
//  - ノード情報 (id/name/role/version)、ポート、peers、能力 (mic/cam)
//  - 本機の全アドレス (IPv4 + 全 IPv6)
//  - 管理後台への QR (IPv4 / IPv6 切替表示)
#import <UIKit/UIKit.h>

@class DBCoreBridge, DBBootConfig;

@interface DBInfoViewController : UIViewController
- (id)initWithCore:(DBCoreBridge *)core boot:(DBBootConfig *)boot;
// QR 生成 (スレッド安全な CGBitmap 描画)。配対引導画面でも再利用する。
+ (UIImage *)qrImageForString:(NSString *)s targetPx:(CGFloat)px;
@end
