#import <UIKit/UIKit.h>



@interface DBQrCode : NSObject

+ (UIImage *)imageForString:(NSString *)s targetPx:(CGFloat)px;
// Whole-module pixels at the screen scale, so the bitmap is never resampled on screen. The
// image is at most `points` wide; the quiet zone is included.
+ (UIImage *)imageForString:(NSString *)s pointSize:(CGFloat)points;

@end
