#import "DBPinOverlay.h"

#import "../Core/DBBootConfig.h"
#import "../Core/DBTexts.h"
#import "DBRouter.h"
#import <CommonCrypto/CommonDigest.h>

static const NSInteger kMaxLen = 6;
static NSInteger sFails = 0;
static NSTimeInterval sLockedUntil = 0;

@implementation DBPinOverlay {
  DBTexts *_texts;
  NSMutableString *_pin;
  UILabel *_display;
  UILabel *_errorLabel;
  UIView *_card;
  NSMutableArray *_keyButtons;
  UIButton *_cancelButton;
  UILabel *_title;
  void (^_onUnlocked)(void);
}

- (id)initWithRouter:(DBRouter *)router {
  self = [super initWithFrame:[UIScreen mainScreen].bounds];
  if (self) {
    _texts = router.texts;
    _pin = [[NSMutableString alloc] init];
    _keyButtons = [[NSMutableArray alloc] init];
    self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
    [self buildUi];
  }
  return self;
}

- (UIButton *)keyButton {
  UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];  // iOS5: System=白背景回避
  b.titleLabel.font = [UIFont systemFontOfSize:26];
  [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
  b.backgroundColor = [UIColor colorWithRed:0.18 green:0.22 blue:0.28 alpha:1];
  [b setBackgroundImage:nil forState:UIControlStateNormal];
  b.layer.borderWidth = 1;
  b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
  b.layer.cornerRadius = 10;
  return b;
}

- (void)buildUi {
  _card = [[UIView alloc] init];
  _card.backgroundColor = [UIColor colorWithRed:0.10 green:0.12 blue:0.16 alpha:1];
  _card.layer.cornerRadius = 14;
  [self addSubview:_card];

  _title = [[UILabel alloc] init];
  _title.text = [_texts ts:@"admin.pin_prompt"];
  _title.font = [UIFont boldSystemFontOfSize:24];
  _title.textColor = [UIColor whiteColor];
  _title.textAlignment = NSTextAlignmentCenter;
  [_card addSubview:_title];

  _display = [[UILabel alloc] init];
  _display.font = [UIFont systemFontOfSize:34];
  _display.textColor = [UIColor whiteColor];
  _display.textAlignment = NSTextAlignmentCenter;
  [_card addSubview:_display];

  _errorLabel = [[UILabel alloc] init];
  _errorLabel.font = [UIFont systemFontOfSize:17];
  _errorLabel.textColor = [UIColor colorWithRed:0.88 green:0.36 blue:0.30 alpha:1];
  _errorLabel.textAlignment = NSTextAlignmentCenter;
  _errorLabel.text = @" ";
  [_card addSubview:_errorLabel];

  NSArray *keys = @[@"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8", @"9", @"back", @"0", @"ok"];
  for (NSString *key in keys) {
    UIButton *b = [self keyButton];
    NSString *label = key;
    if ([key isEqualToString:@"back"]) label = @"⌫";
    else if ([key isEqualToString:@"ok"]) label = @"OK";
    [b setTitle:label forState:UIControlStateNormal];
    b.accessibilityIdentifier = key;
    [b addTarget:self action:@selector(onKey:) forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:b];
    [_keyButtons addObject:b];
  }

  _cancelButton = [[UIButton buttonWithType:UIButtonTypeCustom] init];
  [_cancelButton setTitle:[_texts ts:@"calling.cancel"] forState:UIControlStateNormal];
  _cancelButton.titleLabel.font = [UIFont systemFontOfSize:18];
  [_cancelButton setTitleColor:[UIColor colorWithWhite:1 alpha:0.7] forState:UIControlStateNormal];
  [_cancelButton addTarget:self action:@selector(onCancel)
          forControlEvents:UIControlEventTouchUpInside];
  [_card addSubview:_cancelButton];
}
- (void)layoutSubviews {
  [super layoutSubviews];
  self.frame = self.superview.bounds;
  CGFloat cardW = 380, cardH = 500;
  _card.frame = CGRectMake((self.bounds.size.width - cardW) / 2,
                           (self.bounds.size.height - cardH) / 2, cardW, cardH);
  CGFloat pad = 22, y = 22;
  _title.frame = CGRectMake(pad, y, cardW - 2 * pad, 30);
  y += 40;
  _display.frame = CGRectMake(pad, y, cardW - 2 * pad, 44);
  y += 50;
  _errorLabel.frame = CGRectMake(pad, y, cardW - 2 * pad, 22);
  y += 32;
  CGFloat gap = 8;
  CGFloat keyW = (cardW - 2 * pad - 2 * gap) / 3;
  CGFloat keyH = 64;
  for (NSUInteger i = 0; i < [_keyButtons count]; i++) {
    NSUInteger row = i / 3, col = i % 3;
    UIButton *b = [_keyButtons objectAtIndex:i];
    b.frame = CGRectMake(pad + col * (keyW + gap), y + row * (keyH + gap), keyW, keyH);
  }
  y += 4 * (keyH + gap) + 6;
  _cancelButton.frame = CGRectMake(pad, y, cardW - 2 * pad, 34);
}

#pragma mark - 出入

- (void)presentInView:(UIView *)parent then:(void (^)(void))onUnlocked {
  _onUnlocked = onUnlocked;
  _pin = [[NSMutableString alloc] init];
  _display.text = @"";
  _errorLabel.text = @" ";
  self.frame = parent.bounds;
  self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [parent addSubview:self];
  self.alpha = 0.0;
  [UIView animateWithDuration:0.2 animations:^{ self.alpha = 1.0; }];
}

- (void)dismiss {
  __weak DBPinOverlay *wself = self;
  [UIView animateWithDuration:0.2
      animations:^{ wself.alpha = 0.0; }
      completion:^(BOOL finished) { [wself removeFromSuperview]; }];
}

#pragma mark - 操作

- (void)onCancel {
  _onUnlocked = nil;
  [self dismiss];
}

- (void)onKey:(UIButton *)sender {
  _errorLabel.text = @" ";
  NSString *identifier = sender.accessibilityIdentifier;
  if ([identifier isEqualToString:@"back"]) {
    if ([_pin length] > 0) [_pin deleteCharactersInRange:NSMakeRange([_pin length] - 1, 1)];
  } else if ([identifier isEqualToString:@"ok"]) {
    [self submit];
    return;
  } else if ([_pin length] < (NSUInteger)kMaxLen) {
    [_pin appendString:identifier];
  }
  NSMutableString *dots = [NSMutableString string];
  for (NSUInteger i = 0; i < [_pin length]; i++) [dots appendString:@"●"];
  _display.text = dots;
}

- (void)submit {
  if ([NSDate timeIntervalSinceReferenceDate] < sLockedUntil) {
    _errorLabel.text = [_texts ts:@"admin.locked"];
    [_pin setString:@""];
    _display.text = @"";
    return;
  }
  NSString *expected = [[self class] sha256Hex:@"000000"];
  NSString *pinFile = [[DBBootConfig dataDir] stringByAppendingPathComponent:@"exit_pin.txt"];
  NSString *s = [NSString stringWithContentsOfFile:pinFile
                                          encoding:NSUTF8StringEncoding
                                             error:NULL];
  NSString *trimmed =
      [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if ([trimmed length] > 0) expected = trimmed;

  if ([[[self class] sha256Hex:_pin] isEqualToString:expected]) {
    sFails = 0;
    void (^cb)(void) = _onUnlocked;
    _onUnlocked = nil;
    [self dismiss];
    // モーダル機構がないため CA commit 再入問題は存在しない — 直ちに実行してよい。
    if (cb) cb();
    return;
  }
  sFails++;
  if (sFails >= 5) {
    sFails = 0;
    sLockedUntil = [NSDate timeIntervalSinceReferenceDate] + 10 * 60;
    _errorLabel.text = [_texts ts:@"admin.locked"];
  } else {
    _errorLabel.text = [_texts ts:@"admin.pin_wrong"];
  }
  [_pin setString:@""];
  _display.text = @"";
}

+ (NSString *)sha256Hex:(NSString *)s {
  NSData *data = [s dataUsingEncoding:NSUTF8StringEncoding];
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256([data bytes], (CC_LONG)[data length], digest);
  NSMutableString *out = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
  for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [out appendFormat:@"%02x", digest[i]];
  return out;
}

@end

