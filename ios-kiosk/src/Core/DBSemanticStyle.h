#import <UIKit/UIKit.h>

FOUNDATION_EXPORT NSString *const DBSemanticStyleReportDidChangeNotification;

// Resolves one constrained semantic style override and keeps a validated local
// last-known-good copy. Callers provide opaque effective baseline colors so a
// single-field update cannot bypass contrast validation.
@interface DBSemanticStyle : NSObject

+ (NSDictionary *)styleForConfig:(NSDictionary *)config
                         deviceID:(NSString *)deviceID
                       semanticID:(NSString *)semanticID
                   safetyCritical:(BOOL)safetyCritical
               baselineForeground:(UIColor *)foreground
               baselineBackground:(UIColor *)background
                   baselineAccent:(UIColor *)accent
                   baselineBorder:(UIColor *)border;

+ (CGFloat)numberInStyle:(NSDictionary *)style key:(NSString *)key
                fallback:(CGFloat)fallback minimum:(CGFloat)minimum maximum:(CGFloat)maximum;
+ (UIColor *)colorInStyle:(NSDictionary *)style key:(NSString *)key fallback:(UIColor *)fallback;
+ (void)applyButton:(UIButton *)button style:(NSDictionary *)style
          foreground:(UIColor *)foreground background:(UIColor *)background
              border:(UIColor *)border radius:(CGFloat)radius fontSize:(CGFloat)fontSize;
+ (void)applyLabel:(UILabel *)label style:(NSDictionary *)style
          foreground:(UIColor *)foreground background:(UIColor *)background
            fontSize:(CGFloat)fontSize;
+ (NSDictionary *)runtimeReport;

@end
