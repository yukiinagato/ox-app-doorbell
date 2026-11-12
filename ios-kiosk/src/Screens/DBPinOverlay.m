#import "DBPinOverlay.h"

#import "../Core/DBBootConfig.h"
#import "../Core/DBCoreBridge.h"
#import "../Core/DBTexts.h"
#import "DBChrome.h"
#import "DBRouter.h"
#import <CommonCrypto/CommonDigest.h>

// Matches Core's admin password bounds (admin_password.h).
static const NSInteger kMinLen = 8;
static const NSInteger kMaxLen = 128;
static NSInteger sFails = 0;
static NSTimeInterval sLockedUntil = 0;

static const CGFloat kPanelWidth = 400;
static const CGFloat kFormHeight = 196;
static const CGFloat kTextInset = 20;

@interface DBPinOverlay () <UITextFieldDelegate, UITableViewDataSource, UITableViewDelegate>
@end

@implementation DBPinOverlay {
  DBTexts *_texts;
  DBCoreBridge *_core;
  NSMutableString *_pin;
  BOOL _needsNewPassword;
  CGFloat _keyboardHeight;
  UIView *_panel;
  DBNavBar *_nav;
  UITableView *_table;
  UITableViewCell *_fieldCell;
  UITextField *_field;
  UIView *_promptHost;
  UILabel *_prompt;
  UIView *_messageHost;
  UILabel *_message;
  CGFloat _formWidth;
  void (^_onUnlocked)(void);
}

- (id)initWithRouter:(DBRouter *)router {
  self = [super initWithFrame:[UIScreen mainScreen].bounds];
  if (self) {
    _texts = router.texts;
    _core = router.core;
    _pin = [[NSMutableString alloc] init];
    self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    [self buildUi];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardChanged:)
        name:UIKeyboardWillChangeFrameNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardChanged:)
        name:UIKeyboardWillHideNotification object:nil];
  }
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  _table.dataSource = nil;
  _table.delegate = nil;
}

- (void)buildUi {
  _panel = [[UIView alloc] init];
  _panel.backgroundColor = DBChromeScreenBackground();
  _panel.clipsToBounds = YES;
  [self addSubview:_panel];

  _nav = [[DBNavBar alloc] init];
  UINavigationItem *item = [_nav setRootTitle:[_texts ts:@"admin.password"] backTitle:nil
                                       onBack:nil];
  item.leftBarButtonItem = DBChromeBarItem([_texts ts:@"admin.cancel"], self, @selector(onCancel));
  item.rightBarButtonItem = DBChromeDoneBarItem([_texts ts:@"admin.login"], self,
                                                @selector(submit));
  [_panel addSubview:_nav.bar];

  _table = DBChromeGroupedTable(self, self);
  _table.alwaysBounceVertical = NO;
  [_panel addSubview:_table];

  _fieldCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:nil];
  _fieldCell.selectionStyle = UITableViewCellSelectionStyleNone;
  _field = [[UITextField alloc] initWithFrame:CGRectInset(_fieldCell.contentView.bounds, 12, 0)];
  _field.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  _field.secureTextEntry = YES;
  // The cluster password is free text of at least eight characters, so the full keyboard is
  // needed; a digits-only pad would make most passwords impossible to type on the device.
  _field.keyboardType = UIKeyboardTypeASCIICapable;
  _field.autocorrectionType = UITextAutocorrectionTypeNo;
  _field.autocapitalizationType = UITextAutocapitalizationTypeNone;
  _field.returnKeyType = UIReturnKeyDone;
  _field.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
  _field.clearButtonMode = UITextFieldViewModeWhileEditing;
  _field.placeholder = [_texts ts:@"admin.password"];
  _field.accessibilityIdentifier = @"admin_password";
  _field.delegate = self;
  [_field addTarget:self action:@selector(pinChanged)
      forControlEvents:UIControlEventEditingChanged];
  [_fieldCell.contentView addSubview:_field];

  // The prompt and the message are owned labels in the table's header and footer, so their
  // text can change without a reload, which would take the keyboard away from the field.
  _promptHost = [[UIView alloc] init];
  _prompt = DBChromeSectionHeaderLabel();
  _prompt.text = [_texts ts:@"admin.pin_prompt"];
  [_promptHost addSubview:_prompt];
  _messageHost = [[UIView alloc] init];
  _message = DBChromeSectionFooterLabel();
  _message.accessibilityIdentifier = @"admin_password_message";
  [_messageHost addSubview:_message];
}

- (CGFloat)heightOfLabel:(UILabel *)label width:(CGFloat)width {
  if ([label.text length] == 0) return 0;
  return ceilf([label sizeThatFits:CGSizeMake(width, 9999)].height);
}

// Sizes the header and footer labels for the form width and hands them back to the table,
// which is how a table learns that their heights changed.
- (void)layoutFormTextForWidth:(CGFloat)width {
  CGFloat textWidth = width - kTextInset * 2;
  CGFloat promptHeight = [self heightOfLabel:_prompt width:textWidth];
  _prompt.frame = CGRectMake(kTextInset, 12, textWidth, promptHeight);
  _promptHost.frame = CGRectMake(0, 0, width, promptHeight + 16);
  _table.tableHeaderView = _promptHost;
  CGFloat messageHeight = [self heightOfLabel:_message width:textWidth];
  _message.frame = CGRectMake(kTextInset, 4, textWidth, messageHeight);
  _messageHost.frame = CGRectMake(0, 0, width, messageHeight + 12);
  _table.tableFooterView = _messageHost;
}

- (void)layoutSubviews {
  [super layoutSubviews];
  CGSize size = self.bounds.size;
  CGFloat barHeight = DBChromeNavBarHeight();
  CGFloat width = MIN(kPanelWidth, size.width);
  // The panel sits in the area the keyboard leaves free and shrinks to it when that area is
  // shorter than the form; the table then scrolls.
  CGFloat available = MAX(barHeight + 44, size.height - _keyboardHeight);
  CGFloat height = MIN(barHeight + kFormHeight, available);
  _panel.frame = CGRectMake(floorf((size.width - width) / 2),
                            MAX(0, floorf((available - height) / 2)), width, height);
  [_nav layoutInBounds:_panel.bounds];
  _table.frame = CGRectMake(0, barHeight, width, height - barHeight);
  if (_formWidth != width) {
    _formWidth = width;
    [self layoutFormTextForWidth:width];
  }
}

- (void)keyboardChanged:(NSNotification *)note {
  if (!self.window) {
    _keyboardHeight = 0;
    return;
  }
  CGRect keyboard = [self convertRect:[[note.userInfo objectForKey:UIKeyboardFrameEndUserInfoKey]
                                          CGRectValue]
                             fromView:nil];
  CGRect overlap = CGRectIntersection(self.bounds, keyboard);
  _keyboardHeight =
      [note.name isEqualToString:UIKeyboardWillHideNotification] || CGRectIsNull(overlap)
          ? 0 : CGRectGetHeight(overlap);
  [self setNeedsLayout];
}

- (void)showPrompt:(NSString *)prompt message:(NSString *)message {
  if (prompt) _prompt.text = prompt;
  _message.text = message ?: @"";
  if (_formWidth > 0) [self layoutFormTextForWidth:_formWidth];
}

- (void)clearEntry {
  [_pin setString:@""];
  _field.text = @"";
}

#pragma mark - table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  (void)tableView;
  return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  (void)tableView;
  (void)section;
  return 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  (void)tableView;
  (void)indexPath;
  return _fieldCell;
}

#pragma mark - entry

- (BOOL)textField:(UITextField *)field shouldChangeCharactersInRange:(NSRange)range
    replacementString:(NSString *)string {
  NSString *next = [field.text ?: @"" stringByReplacingCharactersInRange:range withString:string];
  return (NSInteger)[next length] <= kMaxLen;
}

- (BOOL)textFieldShouldReturn:(UITextField *)field {
  (void)field;
  [self submit];
  return NO;
}

- (void)pinChanged {
  [_pin setString:_field.text ?: @""];
  if ([_message.text length] > 0) [self showPrompt:nil message:nil];
}

- (void)presentInView:(UIView *)parent then:(void (^)(void))onUnlocked {
  _onUnlocked = onUnlocked;
  [self clearEntry];
  [self showPrompt:[_texts ts:@"admin.pin_prompt"] message:nil];
  if (!self.superview) {
    self.frame = parent.bounds;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [parent addSubview:self];
    [self layoutIfNeeded];
  }
  [_field becomeFirstResponder];
}

// Removed at once, without a fade: the router reports this overlay for as long as it has a
// superview, and a full-screen alpha animation is outside the A4 budget.
- (void)dismiss {
  [_field resignFirstResponder];
  [self removeFromSuperview];
}

- (void)onCancel {
  _onUnlocked = nil;
  [self dismiss];
}

// The device admin password and the web admin password are one cluster-wide
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
  // No digest file means no device credential at all; there is no built-in default.
  return [trimmed length] > 0 ? trimmed : nil;
}

+ (void)retireLocalDigest {
  NSString *path = [self localDigestPath];
  if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return;
  if ([[NSFileManager defaultManager] removeItemAtPath:path error:NULL])
    NSLog(@"[doorbell][admin] retired the local admin digest; the cluster password "
           "is now the only credential");
}

- (BOOL)acceptsEnteredPassword:(NSString *)entered {
  NSString *digest = [[self class] localDigest];
  BOOL localMatches =
      digest != nil && [[[self class] sha256Hex:entered] isEqualToString:digest];
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
  // No cluster password yet. A legacy device digest, if present, must match before this entry
  // may become the cluster password; without one this is the same trust-on-first-use as the
  // first web login. Either way the new password has to meet Core's minimum length, so an old
  // six-digit PIN cannot be carried over and the user is asked for a longer one instead.
  if (digest != nil && !localMatches) return NO;
  if ((NSInteger)[entered length] < kMinLen) {
    _needsNewPassword = YES;
    return NO;
  }
  if ([_core setAdminPasswordFrom:@"" to:entered] != 0) return NO;
  [[self class] retireLocalDigest];
  NSLog(@"[doorbell][admin] set the first cluster password from this device");
  return YES;
}

- (void)submit {
  if ([NSDate timeIntervalSinceReferenceDate] < sLockedUntil) {
    [self showPrompt:nil message:[_texts ts:@"admin.locked"]];
    [self clearEntry];
    return;
  }
  _needsNewPassword = NO;
  if ([self acceptsEnteredPassword:_pin]) {
    sFails = 0;
    void (^cb)(void) = _onUnlocked;
    _onUnlocked = nil;
    [self dismiss];
    if (cb) cb();
    return;
  }
  if (_needsNewPassword) {
    // Not a wrong password: the cluster has none yet and this entry is too short to become it.
    [self showPrompt:[_texts ts:@"admin.password_set_prompt"]
             message:[_texts ts:@"admin.password_too_short"]];
    [self clearEntry];
    return;
  }
  sFails++;
  if (sFails >= 5) {
    sFails = 0;
    sLockedUntil = [NSDate timeIntervalSinceReferenceDate] + 10 * 60;
    [self showPrompt:nil message:[_texts ts:@"admin.locked"]];
  } else {
    [self showPrompt:nil message:[_texts ts:@"admin.pin_wrong"]];
  }
  [self clearEntry];
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
