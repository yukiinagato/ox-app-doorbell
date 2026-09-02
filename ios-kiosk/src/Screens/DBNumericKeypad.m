#import "DBNumericKeypad.h"

static const CGFloat kKeyGap = 8;
static const CGFloat kKeyHeight = 56;

@implementation DBNumericKeypad {
  NSMutableString *_digits;
  NSMutableArray *_buttons;
  UIButton *_submit;
}

@synthesize maxLength = _maxLength;
@synthesize onChange = _onChange;
@synthesize onSubmit = _onSubmit;

+ (CGFloat)heightForWidth:(CGFloat)width {
  (void)width;
  return 4 * kKeyHeight + 3 * kKeyGap;
}

- (UIButton *)keyButton {
  UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
  b.titleLabel.font = [UIFont boldSystemFontOfSize:26];
  [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
  [b setTitleColor:[UIColor whiteColor] forState:UIControlStateHighlighted];
  [b setTitleColor:[UIColor colorWithWhite:1 alpha:0.35] forState:UIControlStateDisabled];
  b.backgroundColor = [UIColor colorWithRed:0.24 green:0.28 blue:0.35 alpha:1];
  [b setBackgroundImage:nil forState:UIControlStateNormal];
  b.layer.borderWidth = 1;
  b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.30].CGColor;
  b.layer.cornerRadius = 10;
  return b;
}

- (id)initWithSubmitTitle:(NSString *)submitTitle {
  self = [super initWithFrame:CGRectZero];
  if (self) {
    _digits = [[NSMutableString alloc] init];
    _buttons = [[NSMutableArray alloc] init];
    _maxLength = 6;
    NSArray *keys = @[@"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8", @"9",
                      @"back", @"0", @"ok"];
    for (NSString *key in keys) {
      UIButton *b = [self keyButton];
      NSString *label = key;
      if ([key isEqualToString:@"back"]) {
        label = @"DEL";
        [b setTitleColor:[UIColor colorWithRed:1.0 green:0.55 blue:0.45 alpha:1]
                forState:UIControlStateNormal];
      } else if ([key isEqualToString:@"ok"]) {
        label = [submitTitle length] > 0 ? submitTitle : @"OK";
        b.titleLabel.font = [UIFont boldSystemFontOfSize:19];
        b.backgroundColor = [UIColor colorWithRed:0.13 green:0.55 blue:0.28 alpha:1];
        b.layer.borderColor = [UIColor clearColor].CGColor;
        _submit = b;
      }
      [b setTitle:label forState:UIControlStateNormal];
      b.accessibilityIdentifier = key;
      [b addTarget:self action:@selector(onKey:) forControlEvents:UIControlEventTouchUpInside];
      [self addSubview:b];
      [_buttons addObject:b];
    }
  }
  return self;
}

- (void)setSubmitTitle:(NSString *)title {
  if ([title length] > 0) [_submit setTitle:title forState:UIControlStateNormal];
}

- (void)setKeysEnabled:(BOOL)enabled {
  for (UIButton *b in _buttons) {
    b.enabled = enabled;
    b.alpha = enabled ? 1.0 : 0.45;
  }
}

- (NSString *)value {
  return [_digits copy];
}

- (void)setValue:(NSString *)value {
  [_digits setString:@""];
  for (NSUInteger i = 0; i < [value length] && [_digits length] < _maxLength; i++) {
    unichar c = [value characterAtIndex:i];
    if (c >= '0' && c <= '9') [_digits appendFormat:@"%C", c];
  }
  if (_onChange) _onChange([_digits copy]);
}

- (void)clear {
  [self setValue:@""];
}

- (void)onKey:(UIButton *)sender {
  NSString *identifier = sender.accessibilityIdentifier;
  if ([identifier isEqualToString:@"ok"]) {
    if (_onSubmit) _onSubmit([_digits copy]);
    return;
  }
  if ([identifier isEqualToString:@"back"]) {
    if ([_digits length] > 0)
      [_digits deleteCharactersInRange:NSMakeRange([_digits length] - 1, 1)];
  } else if ([_digits length] < _maxLength) {
    [_digits appendString:identifier];
  }
  if (_onChange) _onChange([_digits copy]);
}

- (void)layoutSubviews {
  [super layoutSubviews];
  CGFloat width = self.bounds.size.width;
  CGFloat keyW = (width - 2 * kKeyGap) / 3;
  for (NSUInteger i = 0; i < [_buttons count]; i++) {
    NSUInteger row = i / 3, col = i % 3;
    UIButton *b = [_buttons objectAtIndex:i];
    b.frame = CGRectMake(col * (keyW + kKeyGap), row * (kKeyHeight + kKeyGap),
                         keyW, kKeyHeight);
  }
}

@end
