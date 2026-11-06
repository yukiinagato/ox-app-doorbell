#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
@interface UIColor : NSObject
@property(nonatomic, readonly) CGColorRef CGColor;
+ (UIColor *)colorWithRed:(CGFloat)red green:(CGFloat)green blue:(CGFloat)blue alpha:(CGFloat)alpha;
+ (UIColor *)clearColor;
@end
@interface UIFont : NSObject
+ (UIFont *)boldSystemFontOfSize:(CGFloat)size;
@end
@interface UILabel : NSObject
@property(nonatomic, strong) UIColor *textColor;
@property(nonatomic, strong) UIColor *backgroundColor;
@property(nonatomic, strong) UIFont *font;
@end
@interface UIButton : NSObject
@property(nonatomic, strong) UIColor *backgroundColor;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) CALayer *layer;
- (void)setTitleColor:(UIColor *)color forState:(NSUInteger)state;
@end
enum { UIControlStateNormal = 0 };
