#import "DBPinOverlay.h"

#import "../Core/DBBootConfig.h"
#import "../Core/DBCoreBridge.h"
#import "../Core/DBTexts.h"
#import "DBRouter.h"
#import <CommonCrypto/CommonDigest.h>

static const NSInteger kMaxLen = 6;
static NSInteger sFails = 0;
static NSTimeInterval sLockedUntil = 0;

@interface DBPinOverlay () <UITextFieldDelegate>
@end

@implementation DBPinOverlay {
  DBTexts *_texts;
  DBCoreBridge *_core;
  NSMutableString *_pin;
  UITextField *_display;
  CGFloat _keyboardHeight;
  UIButton *_submitButton;
  UILabel *_errorLabel;
  UIView *_card;
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
    self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
    [self buildUi];
  }
  return self;
}

- (void)buildUi {
  _card = [[UIView alloc] init];
  _card.backgroundColor = [UIColor colorWithRed:0.09 green:0.10 blue:0.14 alpha:1];
  _card.layer.cornerRadius = 14;
  [self addSubview:_card];

  _title = [[UILabel alloc] init];
  _title.text = [_texts ts:@"admin.pin_prompt"];
  _title.font = [UIFont boldSystemFontOfSize:18];
  _title.numberOfLines = 0;
  _title.textColor = [UIColor whiteColor];
  _title.textAlignment = NSTextAlignmentCenter;
  [_card addSubview:_title];

  _display = [[UITextField alloc] init];
  _display.secureTextEntry = YES;
  _display.keyboardType = UIKeyboardTypeNumberPad;
  _display.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
  _display.delegate = self;
  [_display addTarget:self action:@selector(pinChanged) forControlEvents:UIControlEventEditingChanged];
  _display.font = [UIFont systemFontOfSize:24];
  _display.textColor = [UIColor colorWithWhite:0.12 alpha:1];
  _display.textAlignment = NSTextAlignmentCenter;
  _display.backgroundColor = [UIColor whiteColor];
  _display.layer.cornerRadius = 8;
  _display.clipsToBounds = YES;
  [_card addSubview:_display];

  _errorLabel = [[UILabel alloc] init];
  _errorLabel.font = [UIFont systemFontOfSize:14];
  _errorLabel.numberOfLines = 0;
  _errorLabel.textColor = [UIColor colorWithRed:1.0 green:0.45 blue:0.38 alpha:1];
  _errorLabel.textAlignment = NSTextAlignmentCenter;
  _errorLabel.text = @" ";
  [_card addSubview:_errorLabel];

  _submitButton = [UIButton buttonWithType:UIButtonTypeCustom];
  [_submitButton setTitle:[_texts ts:@"admin.login"] forState:UIControlStateNormal];
  [_submitButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
  _submitButton.backgroundColor = [UIColor colorWithRed:0.05 green:0.30 blue:0.65 alpha:1];
  _submitButton.titleLabel.font = [UIFont boldSystemFontOfSize:17];
  _submitButton.layer.cornerRadius = 8;
  [_submitButton addTarget:self action:@selector(submit) forControlEvents:UIControlEventTouchUpInside];
  [_card addSubview:_submitButton];
  UIToolbar *toolbar = [[UIToolbar alloc] init];
  toolbar.items = @[
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(onCancel)],
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil],
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(submit)]];
  [toolbar sizeToFit];
  _display.inputAccessoryView = toolbar;
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardChanged:)
      name:UIKeyboardWillChangeFrameNotification object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardChanged:)
      name:UIKeyboardWillHideNotification object:nil];

  _cancelButton = [UIButton buttonWithType:UIButtonTypeCustom];
  [_cancelButton setTitle:[_texts ts:@"calling.cancel"] forState:UIControlStateNormal];
  _cancelButton.titleLabel.font = [UIFont systemFontOfSize:17];
  _cancelButton.backgroundColor = [UIColor colorWithRed:0.18 green:0.20 blue:0.25 alpha:1];
  _cancelButton.layer.cornerRadius = 8;
  _cancelButton.layer.borderWidth = 1;
  _cancelButton.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.14].CGColor;
  [_cancelButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
  [_cancelButton addTarget:self action:@selector(onCancel)
          forControlEvents:UIControlEventTouchUpInside];
  [_card addSubview:_cancelButton];



  [self clearLabelBackgrounds:self];


  _display.backgroundColor = [UIColor whiteColor];
}
- (void)layoutSubviews {
  [super layoutSubviews];
  CGFloat cardW = MIN(380, self.bounds.size.width - 40), cardH = 230;
  CGFloat available = MAX(cardH, self.bounds.size.height - _keyboardHeight);
  _card.frame = CGRectMake((self.bounds.size.width - cardW) / 2,
      MAX(10, (available - cardH) / 2), cardW, cardH);
  _title.frame = CGRectMake(20, 16, cardW - 40, 44);
  _display.frame = CGRectMake(20, 72, cardW - 40, 48);
  _errorLabel.frame = CGRectMake(20, 124, cardW - 40, 28);
  CGFloat buttonWidth = (cardW - 52) / 2;
  _cancelButton.frame = CGRectMake(20, 166, buttonWidth, 44);
  _submitButton.frame = CGRectMake(32 + buttonWidth, 166, buttonWidth, 44);
}

- (void)keyboardChanged:(NSNotification *)note {
  CGRect keyboard = [self convertRect:[[note.userInfo objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue] fromView:nil];
  CGRect overlap = CGRectIntersection(self.bounds, keyboard);
  _keyboardHeight = [note.name isEqualToString:UIKeyboardWillHideNotification] || CGRectIsNull(overlap)
      ? 0 : CGRectGetHeight(overlap);
  [self setNeedsLayout];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (BOOL)textField:(UITextField *)field shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string {
  NSString *next = [field.text ?: @"" stringByReplacingCharactersInRange:range withString:string];
  NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet];
  return [next length] <= kMaxLen && [next rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

- (void)pinChanged {
  [_pin setString:_display.text ?: @""];
  _errorLabel.text = @" ";
}

- (void)presentInView:(UIView *)parent then:(void (^)(void))onUnlocked {
  if (self.superview) {
    _onUnlocked = onUnlocked;
    [_pin setString:@""];
    _display.text = @"";
    _errorLabel.text = @" ";
    [_display becomeFirstResponder];
    return;
  }
  _onUnlocked = onUnlocked;
  _pin = [[NSMutableString alloc] init];
  _display.text = @"";
  _errorLabel.text = @" ";
  self.frame = parent.bounds;
  self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [parent addSubview:self];
  [_display becomeFirstResponder];
  self.alpha = 0.0;
  [UIView animateWithDuration:0.2 animations:^{ self.alpha = 1.0; }];
}

- (void)dismiss {
  [_display resignFirstResponder];
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
  // >0 accepted, 0 wrong, -1 locked out, -2 no cluster password yet.
  int status = [_core verifyAdminPassword:entered];
  if (status > 0) {
    [[self class] retireLocalDigest];
    return YES;
  }
  if (status == 0 || status == -1) {
    // The cluster has a password and Core answered for it, so the device digest
    // stops being consulted and is deleted: one password change must not leave
    // a stale second way in.
    [[self class] retireLocalDigest];
    return NO;
  }
  if (status != -2) return NO;
  // No cluster password yet: the device's own digest is still authoritative,
  // and the first successful entry republishes it as the cluster password.
  if (!localMatches) return NO;
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
