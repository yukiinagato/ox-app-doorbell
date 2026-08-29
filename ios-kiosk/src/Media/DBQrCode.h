#import <UIKit/UIKit.h>

// qrcodegen (C) → UIImage 変換。生 CGBitmapContext を使うので
// どのスレッドからでも安全に呼べる (UIGraphics を使わない)。
@interface DBQrCode : NSObject

+ (UIImage *)imageForString:(NSString *)s targetPx:(CGFloat)px;

@end
