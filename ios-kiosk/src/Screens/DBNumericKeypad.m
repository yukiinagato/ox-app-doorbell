#import "DBNumericKeypad.h"

@interface DBNumericKeypad () <UITextFieldDelegate>
@end

@implementation DBNumericKeypad {
  UITextField *_field;
  UIButton *_submit;
}

+ (CGFloat)heightForWidth:(CGFloat)width {
  (void)width;
  return 108;
}

- (id)initWithSubmitTitle:(NSString *)submitTitle {
  self = [super initWithFrame:CGRectZero];
  if (self) {
    _maxLength = 6;
    _field = [[UITextField alloc] init];
    _field.keyboardType = UIKeyboardTypeNumberPad;
    _field.font = [UIFont systemFontOfSize:24];
    _field.textColor = [UIColor blackColor];
    _field.backgroundColor = [UIColor whiteColor];
    _field.borderStyle = UITextBorderStyleRoundedRect;
    _field.textAlignment = NSTextAlignmentCenter;
    _field.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    _field.delegate = self;
    _field.accessibilityIdentifier = @"numeric_input";
    [_field addTarget:self action:@selector(valueChanged) forControlEvents:UIControlEventEditingChanged];
    [self addSubview:_field];
    _submit = [UIButton buttonWithType:UIButtonTypeCustom];
    _submit.backgroundColor = [UIColor colorWithRed:0.05 green:0.30 blue:0.65 alpha:1];
    _submit.layer.cornerRadius = 8;
    _submit.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [_submit setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [_submit addTarget:self action:@selector(submitValue) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_submit];
    [self setSubmitTitle:submitTitle];
    UIToolbar *toolbar = [[UIToolbar alloc] init];
    toolbar.items = @[
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
          target:self action:@selector(cancelEditing)],
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
          target:nil action:nil],
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
          target:self action:@selector(submitValue)]];
    [toolbar sizeToFit];
    _field.inputAccessoryView = toolbar;
  }
  return self;
}

- (void)setSubmitTitle:(NSString *)title {
  [_submit setTitle:title forState:UIControlStateNormal];
}

- (void)setKeysEnabled:(BOOL)enabled {
  _field.enabled = enabled;
  _submit.enabled = enabled;
  if (!enabled) [_field resignFirstResponder];
}

- (NSString *)value { return _field.text ?: @""; }

- (void)setValue:(NSString *)value {
  NSMutableString *digits = [NSMutableString string];
  for (NSUInteger i = 0; i < [value length] && [digits length] < _maxLength; i++) {
    unichar c = [value characterAtIndex:i];
    if (c >= '0' && c <= '9') [digits appendFormat:@"%C", c];
  }
  _field.text = digits;
  [self valueChanged];
}

- (void)clear { self.value = @""; }
- (void)beginEditing { [_field becomeFirstResponder]; }

- (void)valueChanged {
  if (_onChange) _onChange(self.value);
}

- (void)submitValue {
  [_field resignFirstResponder];
  if (_onSubmit) _onSubmit(self.value);
}

- (void)cancelEditing {
  [_field resignFirstResponder];
  if (_onCancel) _onCancel();
}

- (BOOL)textField:(UITextField *)field shouldChangeCharactersInRange:(NSRange)range
 replacementString:(NSString *)string {
  NSString *next = [field.text ?: @"" stringByReplacingCharactersInRange:range withString:string];
  NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet];
  return [next length] <= _maxLength && [next rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

- (void)layoutSubviews {
  [super layoutSubviews];
  CGFloat width = self.bounds.size.width;
  _field.frame = CGRectMake(0, 0, width, 52);
  _submit.frame = CGRectMake(0, 64, width, 44);
}
@end
