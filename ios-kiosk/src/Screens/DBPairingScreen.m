#import "DBPairingScreen.h"

#import "../Core/DBBootConfig.h"
#import "../Core/DBConfigUtil.h"
#import "../Core/DBCoreBridge.h"
#import "../Core/DBPairingModel.h"
#import "../Core/DBTexts.h"
#import "../Media/DBQrCode.h"
#import "DBNumericKeypad.h"
#import "../Core/DBPairUri.h"
#import "DBRouter.h"

static UIColor *DBPairBg(void) {
  return [UIColor colorWithRed:0.055 green:0.086 blue:0.129 alpha:1];
}
static UIColor *DBPairDim(void) { return [UIColor colorWithWhite:0.65 alpha:1]; }
static UIColor *DBPairAccent(void) {
  return [UIColor colorWithRed:0.13 green:0.45 blue:0.85 alpha:1];
}
static UIColor *DBPairError(void) {
  return [UIColor colorWithRed:0.88 green:0.36 blue:0.30 alpha:1];
}
static UIColor *DBPairOk(void) {
  return [UIColor colorWithRed:0.35 green:0.80 blue:0.45 alpha:1];
}

@implementation DBPairingScreen {
  UIScrollView *_scroll;
  UILabel *_title;
  UILabel *_identity;
  UIActivityIndicatorView *_spinner;
  UILabel *_status;
  UILabel *_hint;

  UIImageView *_qr;
  UILabel *_qrPlaceholder;
  UILabel *_qrCaption;

  // Create-Cluster / Pairing-PIN card. Never auto-dismissed.
  UIView *_card;
  UILabel *_cardTitle;
  UILabel *_cardAddressLabel;
  UILabel *_cardAddress;
  UILabel *_cardCodeLabel;
  UILabel *_cardCode;
  UILabel *_cardCountdown;
  UILabel *_cardInstructions;

  // Join with a Pairing PIN.
  UILabel *_joinTitle;
  UILabel *_hostLabel;
  UITextField *_hostField;
  NSString *_pendingInvitationPin;
  UILabel *_codeLabel;
  UILabel *_codeDisplay;
  DBNumericKeypad *_keypad;
  UILabel *_errorLabel;
  UILabel *_errorDetail;

  UIButton *_createButton;
  UILabel *_createConfirm;
  UIButton *_laterButton;

  // Persistence failure.
  UILabel *_persistTitle;
  UILabel *_persistBody;
  UIButton *_retryButton;

  NSString *_state;
  NSString *_lastQr;
  NSTimer *_poll;
  BOOL _fetchBusy;
  BOOL _confirmingCreate;
  BOOL _createdFlow;       // The create-Cluster card must stay on screen.
  BOOL _joining;
  BOOL _joinSuccessShown;
  BOOL _sawNotReady;   // Guards the auto-close against a stale first snapshot.
  BOOL _dismissed;
  NSDictionary *_token;    // pairing.token while active.
  NSInteger _tokenExpiresS;
  NSInteger _tokenAttemptsLeft;
  CFAbsoluteTime _tokenReadAt;
  CGFloat _keyboardInset;
}

- (id)initWithRouter:(DBRouter *)router {
  self = [super initWithFrame:[UIScreen mainScreen].bounds];
  if (self) {
    _router = router;
    _lastQr = @"";
    _state = DBPairingStateUnknown;
    [self buildUi];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onKeyboardWillShow:)
                                                 name:UIKeyboardWillShowNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onKeyboardWillHide:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];
  }
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [_poll invalidate];
}

- (NSString *)screenName {
  return @"pairing";
}

#pragma mark - construction

- (UILabel *)labelWithFont:(UIFont *)font color:(UIColor *)color center:(BOOL)center {
  UILabel *l = [[UILabel alloc] init];
  l.numberOfLines = 0;
  l.font = font;
  l.textColor = color;
  l.backgroundColor = [UIColor clearColor];
  l.textAlignment = center ? NSTextAlignmentCenter : NSTextAlignmentLeft;
  return l;
}

// UIButtonTypeSystem renders with no visible title on iOS 5; always custom.
- (UIButton *)flatButtonWithTitle:(NSString *)title background:(UIColor *)bg {
  UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
  [b setTitle:title forState:UIControlStateNormal];
  b.titleLabel.font = [UIFont boldSystemFontOfSize:18];
  b.titleLabel.textAlignment = NSTextAlignmentCenter;
  [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
  [b setTitleColor:[UIColor colorWithWhite:1 alpha:0.4] forState:UIControlStateDisabled];
  if (bg) {
    b.backgroundColor = bg;
    b.layer.cornerRadius = 10;
  }
  return b;
}

- (void)buildUi {
  self.backgroundColor = DBPairBg();
  DBTexts *texts = [_router texts];

  _scroll = [[UIScrollView alloc] init];
  _scroll.alwaysBounceVertical = YES;
  [self addSubview:_scroll];

  _title = [self labelWithFont:[UIFont boldSystemFontOfSize:26]
                         color:[UIColor whiteColor] center:YES];
  _title.text = [texts ts:@"pair.title_unpaired"];
  [_scroll addSubview:_title];

  _identity = [self labelWithFont:[UIFont systemFontOfSize:14] color:DBPairDim() center:YES];
  [_scroll addSubview:_identity];

  _spinner = [[UIActivityIndicatorView alloc]
      initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
  _spinner.hidesWhenStopped = YES;
  [_scroll addSubview:_spinner];

  _status = [self labelWithFont:[UIFont boldSystemFontOfSize:18] color:DBPairDim() center:YES];
  _status.text = [texts ts:@"pair.searching"];
  [_scroll addSubview:_status];

  _hint = [self labelWithFont:[UIFont systemFontOfSize:15] color:DBPairDim() center:YES];
  _hint.text = [texts ts:@"pair.searching_hint"];
  [_scroll addSubview:_hint];

  _qr = [[UIImageView alloc] init];
  _qr.contentMode = UIViewContentModeScaleAspectFit;
  _qr.backgroundColor = [UIColor whiteColor];
  [_scroll addSubview:_qr];

  // A blank white square is never acceptable: keep a caption inside the frame
  // until Core publishes pair_qr.
  _qrPlaceholder = [self labelWithFont:[UIFont systemFontOfSize:15]
                                 color:[UIColor colorWithWhite:0.35 alpha:1] center:YES];
  _qrPlaceholder.text = [texts ts:@"pair.qr_pending"];
  [_qr addSubview:_qrPlaceholder];

  _qrCaption = [self labelWithFont:[UIFont systemFontOfSize:14] color:DBPairDim() center:YES];
  _qrCaption.text = [texts ts:@"pair.qr_caption"];
  [_scroll addSubview:_qrCaption];

  _card = [[UIView alloc] init];
  _card.backgroundColor = [UIColor colorWithRed:0.09 green:0.12 blue:0.17 alpha:1];
  _card.layer.cornerRadius = 12;
  _card.hidden = YES;
  [_scroll addSubview:_card];

  _cardTitle = [self labelWithFont:[UIFont boldSystemFontOfSize:19]
                             color:[UIColor whiteColor] center:YES];
  _cardTitle.text = [texts ts:@"pair.created_next"];
  [_card addSubview:_cardTitle];

  _cardAddressLabel = [self labelWithFont:[UIFont systemFontOfSize:14]
                                    color:DBPairDim() center:NO];
  _cardAddressLabel.text = [texts ts:@"pair.address_label"];
  [_card addSubview:_cardAddressLabel];

  _cardAddress = [self labelWithFont:[UIFont boldSystemFontOfSize:24]
                               color:[UIColor whiteColor] center:NO];
  [_card addSubview:_cardAddress];

  _cardCodeLabel = [self labelWithFont:[UIFont systemFontOfSize:14] color:DBPairDim() center:NO];
  _cardCodeLabel.text = [texts ts:@"pair.code_label"];
  [_card addSubview:_cardCodeLabel];

  _cardCode = [self labelWithFont:[UIFont boldSystemFontOfSize:44]
                            color:[UIColor whiteColor] center:NO];
  [_card addSubview:_cardCode];

  _cardCountdown = [self labelWithFont:[UIFont systemFontOfSize:16] color:DBPairDim() center:NO];
  [_card addSubview:_cardCountdown];

  _cardInstructions = [self labelWithFont:[UIFont systemFontOfSize:14]
                                    color:DBPairDim() center:NO];
  _cardInstructions.text = [texts ts:@"pair.code_instructions"];
  [_card addSubview:_cardInstructions];

  _joinTitle = [self labelWithFont:[UIFont boldSystemFontOfSize:18]
                             color:[UIColor whiteColor] center:YES];
  _joinTitle.text = [texts ts:@"pair.join_with_code"];
  [_scroll addSubview:_joinTitle];

  _hostLabel = [self labelWithFont:[UIFont systemFontOfSize:14] color:DBPairDim() center:NO];
  _hostLabel.text = [texts ts:@"pair.address_label"];
  [_scroll addSubview:_hostLabel];

  _hostField = [[UITextField alloc] init];
  _hostField.placeholder = [texts ts:@"pair.address_example"];
  _hostField.borderStyle = UITextBorderStyleRoundedRect;
  _hostField.autocorrectionType = UITextAutocorrectionTypeNo;
  _hostField.autocapitalizationType = UITextAutocapitalizationTypeNone;
  _hostField.keyboardType = UIKeyboardTypeURL;
  _hostField.returnKeyType = UIReturnKeyDone;
  [_hostField addTarget:self action:@selector(onHostFieldDone:)
       forControlEvents:UIControlEventEditingDidEndOnExit];
  [_scroll addSubview:_hostField];

  _codeLabel = [self labelWithFont:[UIFont systemFontOfSize:14] color:DBPairDim() center:NO];
  _codeLabel.text = [texts ts:@"pair.code_label"];
  [_scroll addSubview:_codeLabel];

  _codeDisplay = [self labelWithFont:[UIFont boldSystemFontOfSize:40]
                               color:[UIColor whiteColor] center:YES];
  _codeDisplay.backgroundColor = [UIColor colorWithWhite:1 alpha:0.07];
  _codeDisplay.layer.cornerRadius = 8;
  _codeDisplay.clipsToBounds = YES;
  [_scroll addSubview:_codeDisplay];

  __weak DBPairingScreen *weakSelf = self;
  _keypad = [[DBNumericKeypad alloc] initWithSubmitTitle:[texts ts:@"pair.join_with_code"]];
  _keypad.onChange = ^(NSString *value) {
    DBPairingScreen *screen = weakSelf;
    if (screen) screen->_codeDisplay.text = value;
  };
  _keypad.onSubmit = ^(NSString *value) {
    DBPairingScreen *screen = weakSelf;
    if (screen) [screen submitJoinWithCode:value];
  };
  [_scroll addSubview:_keypad];

  _errorLabel = [self labelWithFont:[UIFont boldSystemFontOfSize:16] color:DBPairError() center:YES];
  _errorLabel.text = @"";
  [_scroll addSubview:_errorLabel];

  _errorDetail = [self labelWithFont:[UIFont systemFontOfSize:12]
                               color:[UIColor colorWithWhite:0.45 alpha:1] center:YES];
  _errorDetail.text = @"";
  [_scroll addSubview:_errorDetail];

  _createButton = [self flatButtonWithTitle:[texts ts:@"pair.create_home"] background:nil];
  [_createButton setTitleColor:[UIColor colorWithRed:0.85 green:0.55 blue:0.2 alpha:1]
                      forState:UIControlStateNormal];
  [_createButton addTarget:self action:@selector(onCreate)
          forControlEvents:UIControlEventTouchUpInside];
  [_scroll addSubview:_createButton];

  _createConfirm = [self labelWithFont:[UIFont systemFontOfSize:14] color:DBPairDim() center:YES];
  _createConfirm.text = @"";
  [_scroll addSubview:_createConfirm];

  _laterButton = [self flatButtonWithTitle:[texts ts:@"pair.later"] background:nil];
  [_laterButton setTitleColor:[UIColor colorWithWhite:1 alpha:0.6] forState:UIControlStateNormal];
  _laterButton.titleLabel.font = [UIFont systemFontOfSize:17];
  [_laterButton addTarget:self action:@selector(onLater)
         forControlEvents:UIControlEventTouchUpInside];
  [_scroll addSubview:_laterButton];

  _persistTitle = [self labelWithFont:[UIFont boldSystemFontOfSize:20]
                                color:DBPairError() center:YES];
  _persistTitle.text = [texts ts:@"pair.persist_error_title"];
  [_scroll addSubview:_persistTitle];

  _persistBody = [self labelWithFont:[UIFont systemFontOfSize:15] color:DBPairDim() center:YES];
  _persistBody.text = [texts ts:@"pair.persist_error_body"];
  [_scroll addSubview:_persistBody];

  _retryButton = [self flatButtonWithTitle:[texts ts:@"pair.retry"] background:DBPairAccent()];
  [_retryButton addTarget:self action:@selector(onRetryPersistence)
         forControlEvents:UIControlEventTouchUpInside];
  [_scroll addSubview:_retryButton];

  // A door station is installed outside and is never the device an operator
  // uses to create the Cluster.
  if ([[_router boot].role isEqualToString:@"door_station"]) _createButton.hidden = YES;

  [self clearLabelBackgrounds:_scroll];
  _codeDisplay.backgroundColor = [UIColor colorWithWhite:1 alpha:0.07];
  [self applyState];
}

#pragma mark - lifecycle

- (void)onScreenWillAppear {
  _dismissed = NO;
  _sawNotReady = NO;
  _joinSuccessShown = NO;
  [self startPolling];
}

- (void)onScreenWillDisappear {
  [self stopPolling];
  [_hostField resignFirstResponder];
}

- (void)startPolling {
  [self reload];
  if (!_poll) {
    // One second so the Pairing-PIN countdown actually ticks.
    _poll = [NSTimer scheduledTimerWithTimeInterval:1.0
                                             target:self
                                           selector:@selector(onPoll)
                                           userInfo:nil
                                            repeats:YES];
  }
}

- (void)stopPolling {
  [_poll invalidate];
  _poll = nil;
}

- (void)reload {
  [self onPoll];
}

- (BOOL)requiresUserDismissal {
  return _createdFlow || [_state isEqualToString:@"persist_error"];
}

#pragma mark - core snapshot

- (void)onPoll {
  if (_fetchBusy) return;
  _fetchBusy = YES;
  DBCoreBridge *core = [_router core];
  __weak DBPairingScreen *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSDictionary *info = [core pairingInfo];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBPairingScreen *screen = weakSelf;
      if (!screen) return;
      screen->_fetchBusy = NO;
      // The very first snapshot can land before the router has attached the
      // view; the poll timer, not the view tree, is what says we are live.
      if (!screen.superview && !screen->_poll) return;
      [screen applyPairingInfo:info];
    });
  });
}

- (void)applyPairingInfo:(NSDictionary *)info {
  NSString *state = [DBPairingModel stateFromPairingInfo:info];
  // "{}" before the first snapshot means "unknown", never "unpaired".
  if (![state isEqualToString:DBPairingStateUnknown]) _state = state;

  if ([info isKindOfClass:[NSDictionary class]]) {
    NSDictionary *selfInfo = [info objectForKey:@"self"];
    if ([selfInfo isKindOfClass:[NSDictionary class]]) {
      NSString *name = [DBConfigUtil evStr:selfInfo key:@"name"];
      NSString *model = [DBConfigUtil evStr:selfInfo key:@"model"];
      NSString *addr = [DBConfigUtil evStr:selfInfo key:@"addr"];
      NSMutableArray *parts = [NSMutableArray array];
      if ([name length] > 0) [parts addObject:name];
      if ([model length] > 0) [parts addObject:model];
      NSString *head = [parts componentsJoinedByString:@" · "];
      if ([head length] > 0 && [addr length] > 0)
        _identity.text = [NSString stringWithFormat:@"%@\n%@", head, addr];
      else if ([addr length] > 0)
        _identity.text = addr;
      else
        _identity.text = head;
    }
    id token = [info objectForKey:@"token"];
    if ([token isKindOfClass:[NSDictionary class]] &&
        [DBConfigUtil evBool:(NSDictionary *)token key:@"active"]) {
      [self adoptToken:(NSDictionary *)token];
    } else if (_token && ![self remainingTokenSeconds]) {
      _token = nil;
    }
    [self applyQrFromInfo:info];
  }

  if (![_state isEqualToString:@"ready"] &&
      ![_state isEqualToString:DBPairingStateUnknown]) _sawNotReady = YES;
  // Only a real transition into `ready` closes this screen. A stale first
  // snapshot must never flash "joined" and dismiss the onboarding UI.
  if ([_state isEqualToString:@"ready"] && _sawNotReady && !_createdFlow &&
      !_joinSuccessShown) {
    _joinSuccessShown = YES;
    [self showJoinedAndClose];
  }
  [self applyState];
}

- (void)adoptToken:(NSDictionary *)token {
  _token = [token copy];
  _tokenExpiresS = [DBConfigUtil intVal:token path:@"expires_s" def:0];
  _tokenAttemptsLeft = [DBConfigUtil intVal:token path:@"attempts_left" def:0];
  _tokenReadAt = CFAbsoluteTimeGetCurrent();
  NSString *host = [DBConfigUtil evStr:token key:@"host"];
  NSString *pin = [DBConfigUtil evStr:token key:@"pin"];
  if ([host length] > 0) _cardAddress.text = host;
  if ([pin length] > 0) _cardCode.text = pin;
}

- (NSInteger)remainingTokenSeconds {
  if (!_token) return 0;
  NSInteger elapsed = (NSInteger)(CFAbsoluteTimeGetCurrent() - _tokenReadAt);
  NSInteger left = _tokenExpiresS - elapsed;
  return left > 0 ? left : 0;
}

- (void)applyQrFromInfo:(NSDictionary *)info {
  // Core publishes the invitation the other shells encode; the older
  // pair_qr payload is the fallback for a core that has none. The shell never
  // assembles the string itself.
  NSString *qr = [DBPairUri invitationUriInPairingInfo:info];
  if ([qr length] == 0) qr = [info objectForKey:@"pair_qr"];
  if (![qr isKindOfClass:[NSString class]] || [qr length] == 0) return;
  if ([qr isEqualToString:_lastQr]) return;
  _lastQr = [qr copy];
  NSString *payload = [qr copy];
  __weak DBPairingScreen *weakSelf = self;
  // Rasterizing a QR on the A4 main thread visibly stalls the UI.
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    UIImage *image = [DBQrCode imageForString:payload targetPx:480];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBPairingScreen *screen = weakSelf;
      if (!screen || ![screen->_lastQr isEqualToString:payload]) return;
      screen->_qr.image = image;
      screen->_qrPlaceholder.hidden = (image != nil);
    });
  });
}

#pragma mark - state rendering

- (void)applyState {
  DBTexts *texts = [_router texts];
  BOOL persistError = [_state isEqualToString:@"persist_error"];
  BOOL joining = [_state isEqualToString:@"joining"] || _joining;
  BOOL ready = [_state isEqualToString:@"ready"];
  BOOL revoked = [_state isEqualToString:@"revoked"];
  BOOL showCard = _createdFlow && !persistError;

  _persistTitle.hidden = !persistError;
  _persistBody.hidden = !persistError;
  _retryButton.hidden = !persistError;

  // A persistence error is cleared only by a successful retry. Every other path
  // is hidden so nothing else can silently dismiss it.
  BOOL showJoinPath = !persistError && !showCard && !ready && !revoked;
  _joinTitle.hidden = !showJoinPath;
  _hostLabel.hidden = !showJoinPath;
  _hostField.hidden = !showJoinPath;
  _codeLabel.hidden = !showJoinPath;
  _codeDisplay.hidden = !showJoinPath;
  _keypad.hidden = !showJoinPath;
  _createButton.hidden = !showJoinPath ||
      [[_router boot].role isEqualToString:@"door_station"];
  _createConfirm.hidden = _createButton.hidden || [_createConfirm.text length] == 0;

  _card.hidden = !showCard;
  _qr.hidden = persistError || showCard;
  _qrCaption.hidden = _qr.hidden;
  _hint.hidden = persistError || showCard || joining || ready;
  _laterButton.hidden = persistError;

  _hostField.enabled = !joining;
  [_keypad setKeysEnabled:!joining];

  if (persistError) {
    _status.text = @"";
    [_spinner stopAnimating];
  } else if (revoked) {
    _status.text = [texts ts:@"pair.revoked"];
    _status.textColor = DBPairError();
    [_spinner stopAnimating];
  } else if (showCard) {
    _status.text = [NSString stringWithFormat:@"%@ ✓", [texts ts:@"pair.created"]];
    _status.textColor = DBPairOk();
    [_spinner stopAnimating];
    [self applyCardCountdown];
  } else if (ready) {
    _status.text = [NSString stringWithFormat:@"%@ ✓", [texts ts:@"pair.joined"]];
    _status.textColor = DBPairOk();
    [_spinner stopAnimating];
  } else if (joining) {
    _status.text = [texts ts:@"pair.joining"];
    _status.textColor = DBPairDim();
    [_spinner startAnimating];
  } else {
    _status.text = [texts ts:@"pair.searching"];
    _status.textColor = DBPairDim();
    [_spinner startAnimating];
  }
  [self setNeedsLayout];
}

- (void)applyCardCountdown {
  DBTexts *texts = [_router texts];
  NSInteger left = [self remainingTokenSeconds];
  if (!_token || left <= 0) {
    _cardCountdown.text = [texts ts:@"pair.code_expired"];
    _cardCountdown.textColor = DBPairError();
    return;
  }
  NSString *countdown = [texts t:@"pair.code_expires_in",
                             [DBPairingModel countdownMinutesFromSeconds:left],
                             [DBPairingModel countdownSecondsFromSeconds:left], nil];
  NSString *attempts = [texts t:@"pair.code_attempts_left",
                            [NSString stringWithFormat:@"%ld", (long)_tokenAttemptsLeft], nil];
  _cardCountdown.text = [NSString stringWithFormat:@"%@  ·  %@", countdown, attempts];
  _cardCountdown.textColor = DBPairDim();
}

- (void)showJoinedAndClose {
  _joining = NO;
  [self applyState];
  __weak DBPairingScreen *weakSelf = self;
  // The success state must be readable before the main UI returns.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    DBPairingScreen *screen = weakSelf;
    if (!screen || screen->_dismissed || screen->_createdFlow) return;
    if (![screen->_state isEqualToString:@"ready"]) return;
    screen->_dismissed = YES;
    [screen.router closePairingAnimated:YES];
  });
}

#pragma mark - events

- (void)handleJoinResult:(NSDictionary *)ev {
  _joining = NO;
  if ([DBConfigUtil evBool:ev key:@"ok"]) {
    // Success is confirmed by pairing_state; keep the joining feedback until
    // then instead of announcing a result Core has not committed yet.
    _errorLabel.text = @"";
    _errorDetail.text = @"";
    _joining = YES;
    [self applyState];
    [self reload];
    return;
  }
  [self showErrorCode:[DBConfigUtil evStr:ev key:@"err"]];
}

- (void)handleInviteRejected:(NSDictionary *)ev {
  [self showErrorCode:[DBConfigUtil evStr:ev key:@"reason"]];
}

- (void)handlePairingState:(NSDictionary *)ev {
  NSString *state = [DBConfigUtil evStr:ev key:@"state"];
  if ([state length] > 0) {
    NSString *resolved = [DBPairingModel stateFromPairingInfo:@{ @"state" : state }];
    if (![resolved isEqualToString:DBPairingStateUnknown]) _state = resolved;
  }
  if (![_state isEqualToString:@"ready"] &&
      ![_state isEqualToString:DBPairingStateUnknown]) _sawNotReady = YES;
  if ([_state isEqualToString:@"ready"] && _sawNotReady && !_createdFlow &&
      !_joinSuccessShown) {
    _joinSuccessShown = YES;
    [self showJoinedAndClose];
  }
  [self applyState];
  [self reload];
}

- (void)handleRevoked:(NSDictionary *)ev {
  (void)ev;
  _state = @"revoked";
  _createdFlow = NO;
  _joinSuccessShown = NO;
  _sawNotReady = YES;
  [self applyState];
}

- (void)handlePersistenceError {
  _state = @"persist_error";
  _createdFlow = NO;
  _joining = NO;
  _errorLabel.text = @"";
  _errorDetail.text = @"";
  [self applyState];
}

- (void)showErrorCode:(NSString *)code {
  DBTexts *texts = [_router texts];
  _errorLabel.text = [texts ts:[DBPairingModel errorTextKeyForCode:code]];
  _errorDetail.text = [code length] > 0
      ? [texts t:@"pair.err_detail", code, nil] : @"";
  [self applyState];
}

#pragma mark - actions

- (void)onHostFieldDone:(id)sender {
  (void)sender;
  [_hostField resignFirstResponder];
}

// An invitation opened from a QR or a doorbell://pair link. The device is not
// taken out of a cluster without being asked: joining is a full local reset.
- (void)presentInvitation:(DBPairUri *)invitation {
  DBTexts *texts = [_router texts];
  _confirmingCreate = NO;
  if (invitation == nil || ![invitation isValid]) {
    NSString *reason = invitation.error;
    _errorLabel.text = [texts ts:@"pair.invitation_title"];
    _errorDetail.text = [texts ts:([reason isEqualToString:DBPairUriErrorExpired]
                                       ? @"pair.invitation_expired"
                                       : @"pair.invitation_invalid")];
    [self applyState];
    return;
  }
  _hostField.text = invitation.host;
  _pendingInvitationPin = [invitation.pin copy];
  // The PIN is filled in but not sent: the visitor of this screen still has to
  // press join, which is the confirmation, and can see what they are joining.
  _keypad.value = invitation.pin;
  _errorLabel.text = [invitation.cluster length] > 0
      ? [texts t:@"pair.invitation_confirm", invitation.cluster, nil]
      : [texts ts:@"pair.invitation_confirm_unnamed"];
  // Already in a cluster: say what joining costs before it happens.
  _errorDetail.text = [_state isEqualToString:@"ready"]
      ? [texts ts:@"pair.invitation_replace"] : @"";
  [self applyState];
}

// The PIN from an invitation, submitted when the user confirms.
- (NSString *)pendingInvitationPin {
  return _pendingInvitationPin;
}

- (void)submitJoinWithCode:(NSString *)code {
  if (_joining) return;
  DBTexts *texts = [_router texts];
  NSString *host = [_hostField.text
      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if ([host length] == 0) {
    _errorLabel.text = [texts ts:@"pair.enter_address_and_code"];
    _errorDetail.text = [texts ts:@"pair.address_example"];
    [_hostField becomeFirstResponder];
    [self applyState];
    return;
  }
  if ([code length] != 6) {
    _errorLabel.text = [texts ts:@"pair.enter_address_and_code"];
    _errorDetail.text = [texts ts:@"pair.code_label"];
    [self applyState];
    return;
  }
  [_hostField resignFirstResponder];
  _errorLabel.text = @"";
  _errorDetail.text = @"";
  _joining = YES;
  [self applyState];
  [[_router core] joinCluster:host pin:code];
}

- (void)onCreate {
  DBTexts *texts = [_router texts];
  if (!_confirmingCreate) {
    _confirmingCreate = YES;
    _errorLabel.text = @"";
    _errorDetail.text = @"";
    _createConfirm.text = [texts ts:@"pair.create_home_confirm"];
    [_createButton setTitle:[texts ts:@"pair.confirm_tap_again"]
                   forState:UIControlStateNormal];
    [self applyState];
    return;
  }
  _confirmingCreate = NO;
  _createConfirm.text = @"";
  [_createButton setTitle:[texts ts:@"pair.create_home"] forState:UIControlStateNormal];
  _createButton.enabled = NO;
  _joining = YES;
  [self applyState];

  DBCoreBridge *core = [_router core];
  __weak DBPairingScreen *weakSelf = self;
  // foundCluster and the PIN mint both block on the Core queue; never on main.
  // Founding shows the PIN card and this device's own QR and nothing else: it
  // must not open the 「まとめて追加」 window, which would silently adopt every
  // device that asks (spec §5.4).
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    BOOL created = [core foundCluster];
    NSDictionary *token = created ? [core mintJoinTokenWithSeconds:600] : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
      DBPairingScreen *screen = weakSelf;
      if (!screen) return;
      screen->_joining = NO;
      screen->_createButton.enabled = YES;
      if (!created) {
        // Core refuses only when this node is already in a Cluster; anything
        // else is a local failure with no specific code.
        [screen showErrorCode:[screen->_state isEqualToString:@"ready"]
                                  ? @"already_paired" : @""];
        return;
      }
      // The generated Pairing PIN used to be dismissed at zero frames because
      // the `paired` event closed the screen. The card now owns the screen
      // until the user chooses to leave.
      screen->_createdFlow = YES;
      screen->_state = @"ready";
      if ([token isKindOfClass:[NSDictionary class]] &&
          [DBConfigUtil evBool:token key:@"ok"]) {
        [screen adoptToken:token];
        screen->_tokenAttemptsLeft =
            [DBConfigUtil intVal:token path:@"attempts_left" def:3];
        if (screen->_tokenExpiresS <= 0) screen->_tokenExpiresS = 600;
      }
      [screen applyState];
    });
  });
}

- (void)onLater {
  if (_dismissed) return;
  _dismissed = YES;
  _createdFlow = NO;
  [_hostField resignFirstResponder];
  [_router pairingDeferredByUser];
  [_router closePairingAnimated:YES];
}

- (void)onRetryPersistence {
  _retryButton.enabled = NO;
  DBCoreBridge *core = [_router core];
  __weak DBPairingScreen *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    BOOL ok = [core retryPairingPersistence];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBPairingScreen *screen = weakSelf;
      if (!screen) return;
      screen->_retryButton.enabled = YES;
      if (ok) screen->_state = @"ready";
      [screen applyState];
      [screen reload];
    });
  });
}

#pragma mark - keyboard

- (void)onKeyboardWillShow:(NSNotification *)note {
  NSValue *frame = [[note userInfo] objectForKey:UIKeyboardFrameEndUserInfoKey];
  CGRect keyboard = [frame CGRectValue];
  CGRect local = [self convertRect:keyboard fromView:nil];
  CGFloat overlap = CGRectGetMaxY(self.bounds) - CGRectGetMinY(local);
  _keyboardInset = MAX(0, overlap);
  [self applyKeyboardInsetAndScrollToField];
}

- (void)onKeyboardWillHide:(NSNotification *)note {
  (void)note;
  _keyboardInset = 0;
  [self applyKeyboardInsetAndScrollToField];
}

- (void)applyKeyboardInsetAndScrollToField {
  UIEdgeInsets insets = UIEdgeInsetsMake(0, 0, _keyboardInset, 0);
  _scroll.contentInset = insets;
  _scroll.scrollIndicatorInsets = insets;
  if (_keyboardInset > 0 && !_hostField.hidden)
    [_scroll scrollRectToVisible:CGRectInset(_hostField.frame, 0, -20) animated:YES];
}

#pragma mark - layout

- (void)layoutSubviews {
  [super layoutSubviews];
  CGSize size = self.bounds.size;
  CGFloat pad = 24;
  CGFloat width = size.width - pad * 2;
  _scroll.frame = CGRectMake(0, 12, size.width, size.height - 12);

  CGFloat y = 8;
  _title.frame = CGRectMake(pad, y, width, 34);
  y += 40;
  CGFloat identityHeight = [_identity sizeThatFits:CGSizeMake(width, 9999)].height;
  _identity.frame = CGRectMake(pad, y, width, identityHeight);
  y += identityHeight + 12;

  CGFloat statusHeight = MAX(24, [_status sizeThatFits:CGSizeMake(width - 40, 9999)].height);
  _status.frame = CGRectMake(pad + 34, y, width - 68, statusHeight);
  _spinner.center = CGPointMake(pad + 16, y + statusHeight / 2);
  y += statusHeight + 6;

  if (!_hint.hidden) {
    CGFloat hintHeight = [_hint sizeThatFits:CGSizeMake(width, 9999)].height;
    _hint.frame = CGRectMake(pad, y, width, hintHeight);
    y += hintHeight + 12;
  }

  if (!_persistTitle.hidden) {
    CGFloat titleHeight = [_persistTitle sizeThatFits:CGSizeMake(width, 9999)].height;
    _persistTitle.frame = CGRectMake(pad, y, width, titleHeight);
    y += titleHeight + 8;
    CGFloat bodyHeight = [_persistBody sizeThatFits:CGSizeMake(width, 9999)].height;
    _persistBody.frame = CGRectMake(pad, y, width, bodyHeight);
    y += bodyHeight + 14;
    _retryButton.frame = CGRectMake(pad, y, width, 48);
    y += 58;
  }

  if (!_qr.hidden) {
    CGFloat side = MIN(width * 0.62, 300);
    if (side < 240) side = MIN(width, 240);
    _qr.frame = CGRectMake((size.width - side) / 2, y, side, side);
    _qrPlaceholder.frame = CGRectMake(8, side / 2 - 20, side - 16, 40);
    y += side + 8;
    CGFloat captionHeight = [_qrCaption sizeThatFits:CGSizeMake(width, 9999)].height;
    _qrCaption.frame = CGRectMake(pad, y, width, captionHeight);
    y += captionHeight + 14;
  }

  if (!_card.hidden) {
    CGFloat inner = width - 32;
    CGFloat cy = 16;
    CGFloat titleHeight = [_cardTitle sizeThatFits:CGSizeMake(inner, 9999)].height;
    _cardTitle.frame = CGRectMake(16, cy, inner, titleHeight);
    cy += titleHeight + 14;
    _cardAddressLabel.frame = CGRectMake(16, cy, inner, 18);
    cy += 20;
    _cardAddress.frame = CGRectMake(16, cy, inner, 30);
    cy += 38;
    _cardCodeLabel.frame = CGRectMake(16, cy, inner, 18);
    cy += 20;
    _cardCode.frame = CGRectMake(16, cy, inner, 50);
    cy += 56;
    _cardCountdown.frame = CGRectMake(16, cy, inner, 22);
    cy += 28;
    CGFloat instructionsHeight =
        [_cardInstructions sizeThatFits:CGSizeMake(inner, 9999)].height;
    _cardInstructions.frame = CGRectMake(16, cy, inner, instructionsHeight);
    cy += instructionsHeight + 16;
    _card.frame = CGRectMake(pad, y, width, cy);
    y += cy + 16;
  }

  if (!_joinTitle.hidden) {
    _joinTitle.frame = CGRectMake(pad, y, width, 24);
    y += 30;
    _hostLabel.frame = CGRectMake(pad, y, width, 18);
    y += 20;
    _hostField.frame = CGRectMake(pad, y, width, 40);
    y += 48;
    _codeLabel.frame = CGRectMake(pad, y, width, 18);
    y += 20;
    _codeDisplay.frame = CGRectMake(pad, y, width, 54);
    y += 62;
    CGFloat keypadWidth = MIN(width, 330);
    CGFloat keypadHeight = [DBNumericKeypad heightForWidth:keypadWidth];
    _keypad.frame = CGRectMake((size.width - keypadWidth) / 2, y, keypadWidth, keypadHeight);
    y += keypadHeight + 12;
  }

  CGFloat errorHeight = [_errorLabel.text length] > 0
      ? [_errorLabel sizeThatFits:CGSizeMake(width, 9999)].height : 0;
  _errorLabel.frame = CGRectMake(pad, y, width, errorHeight);
  y += errorHeight > 0 ? errorHeight + 4 : 0;
  CGFloat detailHeight = [_errorDetail.text length] > 0 ? 16 : 0;
  _errorDetail.frame = CGRectMake(pad, y, width, detailHeight);
  y += detailHeight > 0 ? detailHeight + 10 : 0;

  if (!_createButton.hidden) {
    _createButton.frame = CGRectMake(pad, y, width, 44);
    y += 50;
    if (!_createConfirm.hidden) {
      CGFloat confirmHeight = [_createConfirm sizeThatFits:CGSizeMake(width, 9999)].height;
      _createConfirm.frame = CGRectMake(pad, y, width, confirmHeight);
      y += confirmHeight + 10;
    }
  }

  if (!_laterButton.hidden) {
    _laterButton.frame = CGRectMake(pad, y, width, 40);
    y += 52;
  }

  _scroll.contentSize = CGSizeMake(size.width, y + 20);
}

@end
