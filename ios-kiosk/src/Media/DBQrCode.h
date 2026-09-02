#import <UIKit/UIKit.h>



@interface DBQrCode : NSObject

+ (UIImage *)imageForString:(NSString *)s targetPx:(CGFloat)px;

@end
