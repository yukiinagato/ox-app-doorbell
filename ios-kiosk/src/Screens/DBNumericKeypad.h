#import <UIKit/UIKit.h>

// Numeric input with the system number pad and a completion toolbar.
@interface DBNumericKeypad : UIView

@property(nonatomic, copy) NSString *value;
@property(nonatomic, assign) NSUInteger maxLength;  // Defaults to 6.
@property(nonatomic, copy) void (^onChange)(NSString *value);
@property(nonatomic, copy) void (^onSubmit)(NSString *value);
@property(nonatomic, copy) void (^onCancel)(void);

- (id)initWithSubmitTitle:(NSString *)submitTitle;
- (void)setSubmitTitle:(NSString *)title;
- (void)setKeysEnabled:(BOOL)enabled;
- (void)clear;
- (void)beginEditing;

// Height this keypad needs for a given width, used by manual frame layout.
+ (CGFloat)heightForWidth:(CGFloat)width;

@end
