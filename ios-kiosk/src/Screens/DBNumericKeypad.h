#import <UIKit/UIKit.h>

// Drawn 3x4 numeric keypad for iOS 5 kiosks that have no usable IME and must
// never let the system keyboard cover an input field. Buttons are
// UIButtonTypeCustom because UIButtonTypeSystem renders invisible on iOS 5.
@interface DBNumericKeypad : UIView

@property(nonatomic, copy) NSString *value;
@property(nonatomic, assign) NSUInteger maxLength;  // Defaults to 6.
@property(nonatomic, copy) void (^onChange)(NSString *value);
@property(nonatomic, copy) void (^onSubmit)(NSString *value);

- (id)initWithSubmitTitle:(NSString *)submitTitle;
- (void)setSubmitTitle:(NSString *)title;
- (void)setKeysEnabled:(BOOL)enabled;
- (void)clear;

// Height this keypad needs for a given width, used by manual frame layout.
+ (CGFloat)heightForWidth:(CGFloat)width;

@end
