#import "DBPinOverlay.h"

#import "../Core/DBBootConfig.h"
#import "../Core/DBCoreBridge.h"
#import "../Core/DBTexts.h"
#import "DBRouter.h"
#import <CommonCrypto/CommonDigest.h>

static const NSInteger kMaxLen = 6;
static NSInteger sFails = 0;
static NSTimeInterval sLockedUntil = 0;

@implementation DBPinOverlay {
  DBTexts *_texts;
  DBCoreBridge *_core;
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
    _core = router.core;
    _pin = [[NSMutableString alloc] init];
    _keyButtons = [[NSMutableArray alloc] init];
    self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
    [self buildUi];
  }
  return self;
}

- (UIButton *)keyButton {
  UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
  b.titleLabel.font = [UIFont boldSystemFontOfSize:30];
  [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
  [b setTitleColor:[UIColor whiteColor] forState:UIControlStateHighlighted];
  b.backgroundColor = [UIColor colorWithRed:0.24 green:0.28 blue:0.35 alpha:1];
  [b setBackgroundImage:nil forState:UIControlStateNormal];
  b.layer.borderWidth = 1;
  b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.30].CGColor;
  b.layer.cornerRadius = 12;
  return b;
}

- (void)buildUi {
  _card = [[UIView alloc] init];
  _card.backgroundColor = [UIColor colorWithRed:0.09 green:0.10 blue:0.14 alpha:1];
  _card.layer.cornerRadius = 14;
  [self addSubview:_card];

  _title = [[UILabel alloc] init];
  _title.text = [_texts ts:@"admin.pin_prompt"];
  _title.font = [UIFont boldSystemFontOfSize:26];
  _title.textColor = [UIColor whiteColor];
  _title.textAlignment = NSTextAlignmentCenter;
  [_card addSubview:_title];

  _display = [[UILabel alloc] init];
  _display.font = [UIFont boldSystemFontOfSize:48];
  _display.textColor = [UIColor whiteColor];
  _display.textAlignment = NSTextAlignmentCenter;
  _display.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
  _display.layer.cornerRadius = 8;
  _display.clipsToBounds = YES;
  [_card addSubview:_display];

  _errorLabel = [[UILabel alloc] init];
  _errorLabel.font = [UIFont boldSystemFontOfSize:18];
  _errorLabel.textColor = [UIColor colorWithRed:1.0 green:0.45 blue:0.38 alpha:1];
  _errorLabel.textAlignment = NSTextAlignmentCenter;
  _errorLabel.text = @" ";
  [_card addSubview:_errorLabel];

  NSArray *keys = @[@"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8", @"9", @"back", @"0", @"ok"];
  for (NSString *key in keys) {
    UIButton *b = [self keyButton];
    NSString *label = key;
    if ([key isEqualToString:@"back"]) {
      label = @"DEL";
      [b setTitleColor:[UIColor colorWithRed:1.0 green:0.55 blue:0.45 alpha:1]
              forState:UIControlStateNormal];
    } else if ([key isEqualToString:@"ok"]) {
      label = @"OK";
      b.backgroundColor = [UIColor colorWithRed:0.13 green:0.55 blue:0.28 alpha:1];
      b.layer.borderColor = [UIColor clearColor].CGColor;
    }
    [b setTitle:label forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:28];
    b.accessibilityIdentifier = key;
    [b addTarget:self action:@selector(onKey:) forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:b];
    [_keyButtons addObject:b];
  }

  _cancelButton = [UIButton buttonWithType:UIButtonTypeCustom];
  [_cancelButton setTitle:[_texts ts:@"calling.cancel"] forState:UIControlStateNormal];
  _cancelButton.titleLabel.font = [UIFont systemFontOfSize:19];
  [_cancelButton setTitleColor:[UIColor colorWithWhite:1 alpha:0.75] forState:UIControlStateNormal];
  [_cancelButton addTarget:self action:@selector(onCancel)
          forControlEvents:UIControlEventTouchUpInside];
  [_card addSubview:_cancelButton];



  [self clearLabelBackgrounds:self];


  _display.backgroundColor = [UIColor colorWithWhite:1 alpha:0.07];
}
- (void)layoutSubviews {
  [super layoutSubviews];
  self.frame = self.superview.bounds;
  CGFloat cardW = 380, cardH = 500;
  _card.frame = CGRectMake((self.bounds.size.width - cardW) / 2,
                           (self.bounds.size.height - cardH) / 2, cardW, cardH);
  CGFloat pad = 22, y = 20;
  _title.frame = CGRectMake(pad, y, cardW - 2 * pad, 32);
  y += 40;
  _display.frame = CGRectMake(pad + 8, y, cardW - 2 * pad - 16, 60);
  y += 68;
  _errorLabel.frame = CGRectMake(pad, y, cardW - 2 * pad, 24);
  y += 30;
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



- (void)presentInView:(UIView *)parent then:(void (^)(void))onUnlocked {
  if (self.superview) {
    _onUnlocked = onUnlocked;
    [_pin setString:@""];
    _display.text = @"";
    _errorLabel.text = @" ";
    return;
  }
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
      completion:^(BOOL finished) {
        (void)finished;
        [wself removeFromSuperview];
      }];
}



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

// The device 管理パスワード and the web admin password are one cluster-wide
// secret (spec §5.5). Core owns the constant-time comparison and the lockout
// counter it shares with /api/login, so this overlay must never keep a second,
// weaker credential once Core can answer.
//
// Migration of the per-node exit_pin.txt digest: it is accepted exactly once,
// and only while the cluster has no password at all -- proven by Core accepting
// it as the first password. Then the file is deleted. If the cluster already
// has a password, a stale device digest is not a second way in.
+ (NSString *)localDigestPath {
  return [[DBBootConfig dataDir] stringByAppendingPathComponent:@"exit_pin.txt"];
}

+ (NSString *)localDigest {
  NSString *stored = [NSString stringWithContentsOfFile:[self localDigestPath]
                                               encoding:NSUTF8StringEncoding error:NULL];
  NSString *trimmed = [stored stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  return [trimmed length] > 0 ? trimmed : [self sha256Hex:@"000000"];
}

+ (void)retireLocalDigest {
  NSString *path = [self localDigestPath];
  if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return;
  if ([[NSFileManager defaultManager] removeItemAtPath:path error:NULL])
    NSLog(@"[doorbell][admin] retired the local admin digest; the cluster password "
           "is now the only credential");
}

- (BOOL)acceptsEnteredPassword:(NSString *)entered {
  BOOL localMatches =
      [[[self class] sha256Hex:entered] isEqualToString:[[self class] localDigest]];
  if (![DBCoreBridge supportsAdminPassword]) {
    // Core predates the shared password: keep the local digest as the gate.
    return localMatches;
  }
  if ([_core verifyAdminPassword:entered]) {
    [[self class] retireLocalDigest];
    return YES;
  }
  if (!localMatches) return NO;
  // Core rejected it but the device's own digest matches: adopt it as the
  // cluster password. Core accepts an empty "current" only while none is set,
  // so a cluster that already has one refuses here and the stale digest dies.
  if ([_core setAdminPasswordFrom:@"" to:entered] != 0) return NO;
  [[self class] retireLocalDigest];
  NSLog(@"[doorbell][admin] migrated the local admin digest to the cluster password");
  return YES;
}

- (void)submit {
  if ([NSDate timeIntervalSinceReferenceDate] < sLockedUntil) {
    _errorLabel.text = [_texts ts:@"admin.locked"];
    [_pin setString:@""];
    _display.text = @"";
    return;
  }
  if ([self acceptsEnteredPassword:_pin]) {
    sFails = 0;
    void (^cb)(void) = _onUnlocked;
    _onUnlocked = nil;
    [self dismiss];

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
