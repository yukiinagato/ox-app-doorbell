#import "DBAdminPinViewController.h"
#import "DBTexts.h"
#import "DBBootConfig.h"
#import <CommonCrypto/CommonDigest.h>
#import <dispatch/dispatch.h>

static const NSInteger kMaxLen = 6;
static NSInteger sFails = 0;
static NSTimeInterval sLockedUntil = 0;

@implementation DBAdminPinViewController {
  DBTexts *_texts;
  NSMutableString *_pin;
  UILabel *_display;
  UILabel *_errorLabel;
  UIView *_card;
  NSMutableArray *_keyButtons;  // 12 テンキー
  UIButton *_cancelButton;
  UILabel *_title;
}

@synthesize onUnlocked = _onUnlocked;

- (id)initWithTexts:(DBTexts *)texts {
  self = [super initWithNibName:nil bundle:nil];
  if (self) {
    _texts = [texts retain];
    _pin = [[NSMutableString alloc] init];
    _keyButtons = [[NSMutableArray alloc] init];
    self.modalPresentationStyle = UIModalPresentationFullScreen;
    self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
  }
  return self;
}

- (void)dealloc {
  [_texts release];
  [_pin release];
  [_keyButtons release];
  [_onUnlocked release];
  [super dealloc];
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];

  _card = [[[UIView alloc] init] autorelease];
  _card.backgroundColor = [UIColor colorWithRed:0.10 green:0.12 blue:0.16 alpha:1];
  _card.layer.cornerRadius = 14;
  [self.view addSubview:_card];

  _title = [[[UILabel alloc] init] autorelease];
  _title.text = [_texts ts:@"admin.pin_prompt"];
  _title.font = [UIFont boldSystemFontOfSize:24];
  _title.textColor = [UIColor whiteColor];
  _title.textAlignment = NSTextAlignmentCenter;
  [_card addSubview:_title];

  _display = [[[UILabel alloc] init] autorelease];
  _display.font = [UIFont systemFontOfSize:34];
  _display.textColor = [UIColor whiteColor];
  _display.textAlignment = NSTextAlignmentCenter;
  [_card addSubview:_display];

  _errorLabel = [[[UILabel alloc] init] autorelease];
  _errorLabel.font = [UIFont systemFontOfSize:17];
  _errorLabel.textColor = [UIColor colorWithRed:0.88 green:0.36 blue:0.30 alpha:1];
  _errorLabel.textAlignment = NSTextAlignmentCenter;
  _errorLabel.text = @" ";
  [_card addSubview:_errorLabel];

  NSArray *keys = [NSArray arrayWithObjects:@"1", @"2", @"3", @"4", @"5", @"6",
                   @"7", @"8", @"9", @"back", @"0", @"ok", nil];
  for (NSString *key in keys) {
    // iOS5: UIButtonTypeSystem は存在せず値1=RoundedRect にフォールバックし
    // 白い既定背景を描く → 白文字が見えない。Custom を使い自前の背景で描く。
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    NSString *label = key;
    if ([key isEqualToString:@"back"]) label = @"⌫";
    else if ([key isEqualToString:@"ok"]) label = @"OK";
    [b setTitle:label forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:26];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.backgroundColor = [UIColor colorWithRed:0.18 green:0.22 blue:0.28 alpha:1];
    [b setBackgroundImage:nil forState:UIControlStateNormal];
    b.layer.borderWidth = 1;
    b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    b.layer.cornerRadius = 10;
    b.accessibilityIdentifier = key;
    [b addTarget:self action:@selector(onKey:) forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:b];
    [_keyButtons addObject:b];
  }

  _cancelButton = [UIButton buttonWithType:UIButtonTypeCustom];  // iOS5: System=白背景RoundedRect回避
  [_cancelButton setTitle:[_texts ts:@"calling.cancel"] forState:UIControlStateNormal];
  _cancelButton.titleLabel.font = [UIFont systemFontOfSize:20];
  [_cancelButton setTitleColor:[UIColor colorWithWhite:1 alpha:0.7] forState:UIControlStateNormal];
  [_cancelButton addTarget:self action:@selector(onCancel) forControlEvents:UIControlEventTouchUpInside];
  [_card addSubview:_cancelButton];

  // iOS5: 背景色未指定の UILabel が不透明白で描画される個体対策。
  [self clearLabelBackgrounds:self.view];
}

- (void)clearLabelBackgrounds:(UIView *)v {
  for (UIView *sub in v.subviews) {
    if ([sub isKindOfClass:[UILabel class]]) sub.backgroundColor = [UIColor clearColor];
    [self clearLabelBackgrounds:sub];
  }
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  CGFloat cardW = 380, cardH = 500;
  _card.frame = CGRectMake((self.view.bounds.size.width - cardW) / 2,
                           (self.view.bounds.size.height - cardH) / 2, cardW, cardH);
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

- (void)onCancel {
  [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)onKey:(UIButton *)sender {
  _errorLabel.text = @" ";
  NSString *identifier = sender.accessibilityIdentifier;
  if ([identifier isEqualToString:@"back"]) {
    if ([_pin length] > 0) [_pin deleteCharactersInRange:NSMakeRange([_pin length] - 1, 1)];
  } else if ([identifier isEqualToString:@"ok"]) {
    [self submit];
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
  NSString *s = [NSString stringWithContentsOfFile:pinFile encoding:NSUTF8StringEncoding error:NULL];
  NSString *trimmed =
      [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if ([trimmed length] > 0) expected = trimmed;

  if ([[[self class] sha256Hex:_pin] isEqualToString:expected]) {
    sFails = 0;
    DBAdminUnlockHandler cb = [[_onUnlocked copy] autorelease];
    [self dismissViewControllerAnimated:YES completion:nil];
    // iOS 5.1 では dismiss の completion (CA commit コンテキスト) 内で即 present すると
    // UIKit の状態機が中途半端なまま EXC_BAD_ACCESS で落ちる (現代 iOS は warning のみ)。
    // よって cb は dismissal 完了後の次 runloop へ deferred してから呼ぶ。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
      if (cb) cb();
    });
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
