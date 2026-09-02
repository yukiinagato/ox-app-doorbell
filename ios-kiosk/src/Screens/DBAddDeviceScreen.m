#import "DBAddDeviceScreen.h"

#import "../Core/DBBootConfig.h"
#import "../Core/DBConfigUtil.h"
#import "../Core/DBCoreBridge.h"
#import "../Core/DBPairingModel.h"
#import "../Core/DBTexts.h"
#import "../Media/DBQrCode.h"
#import "DBRouter.h"

// A joined device leaves pending.devices[] immediately. Keep its row on screen
// with the "追加しました ✓" confirmation for a moment so the operator sees the
// result of their own tap.
static const NSTimeInterval kAddedRowLingerS = 6.0;

static UIColor *DBAddBg(void) {
  return [UIColor colorWithRed:0.055 green:0.086 blue:0.129 alpha:1];
}
static UIColor *DBAddPanel(void) {
  return [UIColor colorWithRed:0.09 green:0.12 blue:0.17 alpha:1];
}
static UIColor *DBAddDim(void) { return [UIColor colorWithWhite:0.65 alpha:1]; }
static UIColor *DBAddAccent(void) {
  return [UIColor colorWithRed:0.13 green:0.45 blue:0.85 alpha:1];
}
static UIColor *DBAddOk(void) {
  return [UIColor colorWithRed:0.35 green:0.80 blue:0.45 alpha:1];
}
static UIColor *DBAddError(void) {
  return [UIColor colorWithRed:0.88 green:0.36 blue:0.30 alpha:1];
}

@implementation DBAddDeviceScreen {
  UIScrollView *_scroll;
  UILabel *_title;
  UILabel *_membership;
  UIButton *_closeButton;

  UILabel *_nearbyTitle;
  UIView *_nearbyPanel;
  UILabel *_nearbyEmpty;
  NSMutableArray *_rowViews;     // UIView per rendered row.
  NSString *_rowSignature;

  UIButton *_codeButton;
  UIView *_codeCard;
  UILabel *_codeAddressLabel;
  UILabel *_codeAddress;
  UILabel *_codeCodeLabel;
  UILabel *_codeCode;
  UILabel *_codeCountdown;
  UILabel *_codeInstructions;
  UIButton *_newCodeButton;

  UIButton *_addAllButton;
  UILabel *_addAllWarning;
  UIButton *_addAllStop;

  UIImageView *_qr;
  UILabel *_qrPlaceholder;
  UILabel *_qrCaption;

  UIButton *_unpairButton;
  UILabel *_unpairConfirm;
  UILabel *_errorLabel;

  UILabel *_unpairedNotice;
  UIButton *_openOnboarding;

  DBCoreBridge *_core;
  DBTexts *_texts;
  NSTimer *_poll;
  BOOL _fetchBusy;
  NSString *_state;
  NSArray *_pending;                    // pending.devices[]
  NSMutableDictionary *_deviceStates;   // id -> idle|adding|added|failed
  NSMutableDictionary *_deviceErrors;   // id -> error code
  NSMutableDictionary *_deviceNames;    // id -> display name (kept after joining)
  NSMutableDictionary *_addedAt;        // id -> NSNumber CFAbsoluteTime
  NSDictionary *_token;
  NSInteger _tokenExpiresS;
  NSInteger _tokenAttemptsLeft;
  CFAbsoluteTime _tokenReadAt;
  BOOL _pairingModeActive;
  NSInteger _pairingModeLeftS;
  NSInteger _pairingModeAdded;
  CFAbsoluteTime _pairingModeReadAt;
  NSInteger _memberCount;
  NSInteger _connectedCount;
  BOOL _isFounder;
  BOOL _confirmingUnpair;
  BOOL _confirmingAddAll;
  NSString *_lastQr;
}

- (id)initWithRouter:(DBRouter *)router {
  self = [super initWithFrame:[UIScreen mainScreen].bounds];
  if (self) {
    _router = router;
    _core = router.core;
    _texts = router.texts;
    _rowViews = [[NSMutableArray alloc] init];
    _deviceStates = [[NSMutableDictionary alloc] init];
    _deviceErrors = [[NSMutableDictionary alloc] init];
    _deviceNames = [[NSMutableDictionary alloc] init];
    _addedAt = [[NSMutableDictionary alloc] init];
    _pending = @[];
    _state = DBPairingStateUnknown;
    _lastQr = @"";
    _rowSignature = @"";
    [self buildUi];
  }
  return self;
}

- (void)dealloc {
  [_poll invalidate];
}

- (NSString *)screenName {
  return @"add_device";
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

- (UIButton *)flatButtonWithTitle:(NSString *)title background:(UIColor *)bg {
  UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
  [b setTitle:title forState:UIControlStateNormal];
  b.titleLabel.font = [UIFont boldSystemFontOfSize:17];
  [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
  [b setTitleColor:[UIColor colorWithWhite:1 alpha:0.4] forState:UIControlStateDisabled];
  if (bg) {
    b.backgroundColor = bg;
    b.layer.cornerRadius = 10;
  }
  return b;
}

- (void)buildUi {
  self.backgroundColor = DBAddBg();

  _scroll = [[UIScrollView alloc] init];
  _scroll.alwaysBounceVertical = YES;
  [self addSubview:_scroll];

  _title = [self labelWithFont:[UIFont boldSystemFontOfSize:26]
                         color:[UIColor whiteColor] center:YES];
  _title.text = [_texts ts:@"pair.panel_title"];
  [_scroll addSubview:_title];

  _membership = [self labelWithFont:[UIFont systemFontOfSize:15] color:DBAddDim() center:YES];
  [_scroll addSubview:_membership];

  _unpairedNotice = [self labelWithFont:[UIFont systemFontOfSize:16] color:DBAddDim() center:YES];
  _unpairedNotice.text = [_texts ts:@"pair.title_unpaired"];
  _unpairedNotice.hidden = YES;
  [_scroll addSubview:_unpairedNotice];

  _openOnboarding = [self flatButtonWithTitle:[_texts ts:@"pair.open_onboarding"]
                                   background:DBAddAccent()];
  [_openOnboarding addTarget:self action:@selector(onOpenOnboarding)
            forControlEvents:UIControlEventTouchUpInside];
  _openOnboarding.hidden = YES;
  [_scroll addSubview:_openOnboarding];

  _nearbyTitle = [self labelWithFont:[UIFont boldSystemFontOfSize:19]
                               color:[UIColor whiteColor] center:NO];
  _nearbyTitle.text = [_texts ts:@"pair.nearby_title"];
  [_scroll addSubview:_nearbyTitle];

  _nearbyPanel = [[UIView alloc] init];
  _nearbyPanel.backgroundColor = DBAddPanel();
  _nearbyPanel.layer.cornerRadius = 12;
  [_scroll addSubview:_nearbyPanel];

  // Never a blank div: the empty state says the search is still running.
  _nearbyEmpty = [self labelWithFont:[UIFont systemFontOfSize:15] color:DBAddDim() center:YES];
  _nearbyEmpty.text = [NSString stringWithFormat:@"%@\n%@", [_texts ts:@"pair.nearby_none"],
                                                 [_texts ts:@"pair.searching"]];
  [_nearbyPanel addSubview:_nearbyEmpty];

  _codeButton = [self flatButtonWithTitle:[_texts ts:@"pair.add_with_code"]
                               background:DBAddAccent()];
  [_codeButton addTarget:self action:@selector(onStartCode)
        forControlEvents:UIControlEventTouchUpInside];
  [_scroll addSubview:_codeButton];

  _codeCard = [[UIView alloc] init];
  _codeCard.backgroundColor = DBAddPanel();
  _codeCard.layer.cornerRadius = 12;
  _codeCard.hidden = YES;
  [_scroll addSubview:_codeCard];

  _codeAddressLabel = [self labelWithFont:[UIFont systemFontOfSize:14] color:DBAddDim() center:NO];
  _codeAddressLabel.text = [_texts ts:@"pair.address_label"];
  [_codeCard addSubview:_codeAddressLabel];
  _codeAddress = [self labelWithFont:[UIFont boldSystemFontOfSize:24]
                               color:[UIColor whiteColor] center:NO];
  [_codeCard addSubview:_codeAddress];
  _codeCodeLabel = [self labelWithFont:[UIFont systemFontOfSize:14] color:DBAddDim() center:NO];
  _codeCodeLabel.text = [_texts ts:@"pair.code_label"];
  [_codeCard addSubview:_codeCodeLabel];
  _codeCode = [self labelWithFont:[UIFont boldSystemFontOfSize:44]
                            color:[UIColor whiteColor] center:NO];
  [_codeCard addSubview:_codeCode];
  _codeCountdown = [self labelWithFont:[UIFont systemFontOfSize:16] color:DBAddDim() center:NO];
  [_codeCard addSubview:_codeCountdown];
  _codeInstructions = [self labelWithFont:[UIFont systemFontOfSize:14] color:DBAddDim() center:NO];
  _codeInstructions.text = [_texts ts:@"pair.code_instructions"];
  [_codeCard addSubview:_codeInstructions];
  _newCodeButton = [self flatButtonWithTitle:[_texts ts:@"pair.new_code"]
                                  background:DBAddAccent()];
  [_newCodeButton addTarget:self action:@selector(onStartCode)
           forControlEvents:UIControlEventTouchUpInside];
  _newCodeButton.hidden = YES;
  [_codeCard addSubview:_newCodeButton];

  _addAllButton = [self flatButtonWithTitle:[_texts ts:@"pair.add_all"] background:nil];
  [_addAllButton setTitleColor:[UIColor colorWithRed:0.85 green:0.55 blue:0.2 alpha:1]
                      forState:UIControlStateNormal];
  [_addAllButton addTarget:self action:@selector(onAddAll)
          forControlEvents:UIControlEventTouchUpInside];
  [_scroll addSubview:_addAllButton];

  _addAllWarning = [self labelWithFont:[UIFont systemFontOfSize:14] color:DBAddDim() center:YES];
  _addAllWarning.text = [_texts ts:@"pair.add_all_warning"];
  [_scroll addSubview:_addAllWarning];

  _addAllStop = [self flatButtonWithTitle:[_texts ts:@"pair.add_all_stop"]
                               background:[UIColor colorWithRed:0.55 green:0.20 blue:0.16
                                                          alpha:1]];
  [_addAllStop addTarget:self action:@selector(onStopAddAll)
        forControlEvents:UIControlEventTouchUpInside];
  _addAllStop.hidden = YES;
  [_scroll addSubview:_addAllStop];

  _qr = [[UIImageView alloc] init];
  _qr.contentMode = UIViewContentModeScaleAspectFit;
  _qr.backgroundColor = [UIColor whiteColor];
  [_scroll addSubview:_qr];
  _qrPlaceholder = [self labelWithFont:[UIFont systemFontOfSize:14]
                                 color:[UIColor colorWithWhite:0.35 alpha:1] center:YES];
  _qrPlaceholder.text = [_texts ts:@"pair.qr_pending"];
  [_qr addSubview:_qrPlaceholder];
  _qrCaption = [self labelWithFont:[UIFont systemFontOfSize:14] color:DBAddDim() center:YES];
  _qrCaption.text = [_texts ts:@"pair.qr_caption"];
  [_scroll addSubview:_qrCaption];

  _errorLabel = [self labelWithFont:[UIFont boldSystemFontOfSize:15] color:DBAddError() center:YES];
  _errorLabel.text = @"";
  [_scroll addSubview:_errorLabel];

  _unpairButton = [self flatButtonWithTitle:[_texts ts:@"pair.clear_title"] background:nil];
  [_unpairButton setTitleColor:DBAddError() forState:UIControlStateNormal];
  _unpairButton.titleLabel.font = [UIFont systemFontOfSize:16];
  [_unpairButton addTarget:self action:@selector(onUnpair)
          forControlEvents:UIControlEventTouchUpInside];
  [_scroll addSubview:_unpairButton];

  _unpairConfirm = [self labelWithFont:[UIFont systemFontOfSize:14] color:DBAddDim() center:YES];
  _unpairConfirm.text = @"";
  [_scroll addSubview:_unpairConfirm];

  _closeButton = [self flatButtonWithTitle:[_texts ts:@"monitor.close"]
                                background:[UIColor colorWithRed:0.20 green:0.24 blue:0.30
                                                           alpha:1]];
  [_closeButton addTarget:self action:@selector(onClose)
         forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_closeButton];

  [self clearLabelBackgrounds:_scroll];
}

#pragma mark - lifecycle

- (void)onScreenWillAppear {
  _confirmingUnpair = NO;
  _confirmingAddAll = NO;
  _unpairConfirm.text = @"";
  _errorLabel.text = @"";
  [self startPolling];
}

- (void)onScreenWillDisappear {
  [self stopPolling];
}

- (void)startPolling {
  [self reload];
  if (!_poll) {
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

#pragma mark - core snapshot

- (void)onPoll {
  if (_fetchBusy) return;
  _fetchBusy = YES;
  DBCoreBridge *core = _core;
  __weak DBAddDeviceScreen *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSDictionary *info = [core pairingInfo];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBAddDeviceScreen *screen = weakSelf;
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
  if (![state isEqualToString:DBPairingStateUnknown]) _state = state;

  if ([info isKindOfClass:[NSDictionary class]]) {
    _isFounder = [DBConfigUtil boolVal:info path:@"is_founder" def:NO];
    _memberCount = [DBConfigUtil intVal:info path:@"home.member_count" def:0];
    _connectedCount = [DBConfigUtil intVal:info path:@"home.connected_count" def:0];
    _pending = [DBPairingModel pendingDevicesFromPairingInfo:info];
    for (NSDictionary *device in _pending) {
      NSString *identifier = [DBConfigUtil evStr:device key:@"id"];
      if ([identifier length] == 0) continue;
      [_deviceNames setObject:[DBPairingModel displayNameForDevice:device] forKey:identifier];
    }
    _pairingModeActive = [DBConfigUtil boolVal:info path:@"pending.pairing_mode" def:NO];
    _pairingModeLeftS = [DBConfigUtil intVal:info path:@"pending.pairing_mode_left_s" def:0];
    _pairingModeAdded = [DBConfigUtil intVal:info path:@"pending.auto_added_count" def:0];
    _pairingModeReadAt = CFAbsoluteTimeGetCurrent();

    id token = [info objectForKey:@"token"];
    if ([token isKindOfClass:[NSDictionary class]] &&
        [DBConfigUtil evBool:(NSDictionary *)token key:@"active"]) {
      [self adoptToken:(NSDictionary *)token];
    }
    [self applyQrFromInfo:info];
  }
  [self applyContent];
}

- (void)adoptToken:(NSDictionary *)token {
  _token = [token copy];
  _tokenExpiresS = [DBConfigUtil intVal:token path:@"expires_s" def:0];
  _tokenAttemptsLeft = [DBConfigUtil intVal:token path:@"attempts_left" def:0];
  _tokenReadAt = CFAbsoluteTimeGetCurrent();
  NSString *host = [DBConfigUtil evStr:token key:@"host"];
  NSString *pin = [DBConfigUtil evStr:token key:@"pin"];
  if ([host length] > 0) _codeAddress.text = host;
  if ([pin length] > 0) _codeCode.text = pin;
  _codeCard.hidden = NO;
}

- (NSInteger)remainingTokenSeconds {
  if (!_token) return 0;
  NSInteger left = _tokenExpiresS - (NSInteger)(CFAbsoluteTimeGetCurrent() - _tokenReadAt);
  return left > 0 ? left : 0;
}

- (NSInteger)remainingPairingModeSeconds {
  NSInteger left =
      _pairingModeLeftS - (NSInteger)(CFAbsoluteTimeGetCurrent() - _pairingModeReadAt);
  return left > 0 ? left : 0;
}

- (void)applyQrFromInfo:(NSDictionary *)info {
  NSString *qr = [info objectForKey:@"pair_qr"];
  if (![qr isKindOfClass:[NSString class]] || [qr length] == 0) return;
  if ([qr isEqualToString:_lastQr]) return;
  _lastQr = [qr copy];
  NSString *payload = [qr copy];
  __weak DBAddDeviceScreen *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    UIImage *image = [DBQrCode imageForString:payload targetPx:360];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBAddDeviceScreen *screen = weakSelf;
      if (!screen || ![screen->_lastQr isEqualToString:payload]) return;
      screen->_qr.image = image;
      screen->_qrPlaceholder.hidden = (image != nil);
    });
  });
}

#pragma mark - rendering

// Rows are rebuilt only when the visible set or a row state changes, so the
// one-second countdown refresh cannot make the list flicker on an iPad 1.
- (NSArray *)visibleEntries {
  NSMutableArray *entries = [NSMutableArray array];
  NSMutableSet *seen = [NSMutableSet set];
  for (NSDictionary *device in _pending) {
    NSString *identifier = [DBConfigUtil evStr:device key:@"id"];
    if ([identifier length] == 0 || [seen containsObject:identifier]) continue;
    [seen addObject:identifier];
    [entries addObject:device];
  }
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  for (NSString *identifier in [_addedAt allKeys]) {
    if ([seen containsObject:identifier]) continue;
    NSNumber *at = [_addedAt objectForKey:identifier];
    if (now - [at doubleValue] > kAddedRowLingerS) {
      [_addedAt removeObjectForKey:identifier];
      [_deviceStates removeObjectForKey:identifier];
      continue;
    }
    NSString *name = [_deviceNames objectForKey:identifier] ?: identifier;
    [entries addObject:@{ @"id" : identifier, @"name" : name }];
    [seen addObject:identifier];
  }
  return entries;
}

- (NSString *)signatureForEntries:(NSArray *)entries {
  NSMutableString *signature = [NSMutableString string];
  for (NSDictionary *entry in entries) {
    NSString *identifier = [DBConfigUtil evStr:entry key:@"id"];
    NSString *state = [_deviceStates objectForKey:identifier] ?: @"idle";
    NSString *error = [_deviceErrors objectForKey:identifier] ?: @"";
    [signature appendFormat:@"%@|%@|%@;", identifier, state, error];
  }
  return signature;
}

- (void)applyContent {
  BOOL ready = [_state isEqualToString:@"ready"];
  _unpairedNotice.hidden = ready;
  _openOnboarding.hidden = ready;
  _nearbyTitle.hidden = !ready;
  _nearbyPanel.hidden = !ready;
  _codeButton.hidden = !ready;
  _codeCard.hidden = !ready || (_token == nil);
  _addAllButton.hidden = !ready;
  _addAllWarning.hidden = !ready;
  _addAllStop.hidden = !ready || !_pairingModeActive;
  _qr.hidden = !ready;
  _qrCaption.hidden = !ready;
  _unpairButton.hidden = !ready;

  NSMutableArray *parts = [NSMutableArray array];
  [parts addObject:[_texts t:@"pair.membership",
                        [NSString stringWithFormat:@"%ld", (long)_memberCount], nil]];
  [parts addObject:[_texts t:@"pair.membership_connected",
                        [NSString stringWithFormat:@"%ld", (long)_connectedCount], nil]];
  if (_isFounder) [parts addObject:[_texts ts:@"pair.created_badge"]];
  _membership.text = [parts componentsJoinedByString:@"  ·  "];

  if (ready) {
    NSArray *entries = [self visibleEntries];
    NSString *signature = [self signatureForEntries:entries];
    if (![signature isEqualToString:_rowSignature]) {
      _rowSignature = [signature copy];
      [self rebuildRows:entries];
    }
    _nearbyEmpty.hidden = ([entries count] > 0);
    [self applyCodeCard];
    [self applyAddAll];
  }
  [self setNeedsLayout];
}

- (void)rebuildRows:(NSArray *)entries {
  for (UIView *row in _rowViews) [row removeFromSuperview];
  [_rowViews removeAllObjects];

  NSInteger index = 0;
  for (NSDictionary *entry in entries) {
    NSString *identifier = [DBConfigUtil evStr:entry key:@"id"];
    NSString *state = [_deviceStates objectForKey:identifier] ?: @"idle";
    UIView *row = [[UIView alloc] init];
    row.backgroundColor = [UIColor clearColor];

    UILabel *name = [self labelWithFont:[UIFont boldSystemFontOfSize:19]
                                  color:[UIColor whiteColor] center:NO];
    name.numberOfLines = 1;
    name.text = [DBPairingModel displayNameForDevice:entry];
    name.tag = 1;
    [row addSubview:name];

    NSMutableArray *metaParts = [NSMutableArray array];
    NSString *role = [DBConfigUtil evStr:entry key:@"role"];
    if ([role isEqualToString:@"door_station"])
      [metaParts addObject:[_texts ts:@"pair.role_door_station"]];
    else if ([role isEqualToString:@"indoor_panel"])
      [metaParts addObject:[_texts ts:@"pair.role_indoor_panel"]];
    NSString *model = [DBConfigUtil evStr:entry key:@"model"];
    NSString *platform = [DBConfigUtil evStr:entry key:@"platform"];
    if ([model length] > 0) [metaParts addObject:model];
    if ([platform length] > 0) [metaParts addObject:platform];
    NSInteger age = [DBConfigUtil intVal:entry path:@"age_s" def:-1];
    if (age >= 0)
      [metaParts addObject:[_texts t:@"pair.nearby_waiting_since",
                                [NSString stringWithFormat:@"%ld", (long)age], nil]];
    UILabel *meta = [self labelWithFont:[UIFont systemFontOfSize:13]
                                  color:DBAddDim() center:NO];
    meta.numberOfLines = 1;
    meta.text = [metaParts componentsJoinedByString:@" · "];
    meta.tag = 2;
    [row addSubview:meta];

    if ([state isEqualToString:@"added"]) {
      UILabel *added = [self labelWithFont:[UIFont boldSystemFontOfSize:17]
                                     color:DBAddOk() center:NO];
      added.text = [NSString stringWithFormat:@"%@ ✓", [_texts ts:@"pair.added"]];
      added.tag = 3;
      [row addSubview:added];
    } else if ([state isEqualToString:@"adding"]) {
      UILabel *adding = [self labelWithFont:[UIFont boldSystemFontOfSize:17]
                                      color:DBAddDim() center:NO];
      adding.text = [_texts ts:@"pair.adding"];
      adding.tag = 3;
      [row addSubview:adding];
      UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
          initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
      spinner.tag = 6;
      [spinner startAnimating];
      [row addSubview:spinner];
    } else {
      UIButton *add = [self flatButtonWithTitle:[_texts ts:@"pair.add"]
                                     background:DBAddAccent()];
      add.tag = 4;
      add.accessibilityIdentifier = identifier;
      [add addTarget:self action:@selector(onAddDevice:)
            forControlEvents:UIControlEventTouchUpInside];
      [row addSubview:add];

      UIButton *deny = [self flatButtonWithTitle:[_texts ts:@"pair.deny"] background:nil];
      [deny setTitleColor:DBAddDim() forState:UIControlStateNormal];
      deny.titleLabel.font = [UIFont systemFontOfSize:15];
      deny.tag = 5;
      deny.accessibilityIdentifier = identifier;
      [deny addTarget:self action:@selector(onDenyDevice:)
             forControlEvents:UIControlEventTouchUpInside];
      [row addSubview:deny];
    }

    if ([state isEqualToString:@"failed"]) {
      NSString *code = [_deviceErrors objectForKey:identifier];
      UILabel *failure = [self labelWithFont:[UIFont systemFontOfSize:13]
                                       color:DBAddError() center:NO];
      failure.numberOfLines = 2;
      failure.text = [NSString stringWithFormat:@"%@ — %@", [_texts ts:@"pair.add_failed"],
                          [_texts ts:[DBPairingModel errorTextKeyForCode:code]]];
      failure.tag = 7;
      [row addSubview:failure];
    }

    row.tag = index++;
    [_nearbyPanel addSubview:row];
    [_rowViews addObject:row];
  }
  [self clearLabelBackgrounds:_nearbyPanel];
}

- (void)applyCodeCard {
  if (_token == nil) {
    _codeCard.hidden = YES;
    return;
  }
  _codeCard.hidden = NO;
  NSInteger left = [self remainingTokenSeconds];
  if (left <= 0 || _tokenAttemptsLeft <= 0) {
    _codeCountdown.text = [_texts ts:@"pair.code_expired"];
    _codeCountdown.textColor = DBAddError();
    _newCodeButton.hidden = NO;
    return;
  }
  NSString *countdown = [_texts t:@"pair.code_expires_in",
                             [DBPairingModel countdownMinutesFromSeconds:left],
                             [DBPairingModel countdownSecondsFromSeconds:left], nil];
  NSString *attempts = [_texts t:@"pair.code_attempts_left",
                            [NSString stringWithFormat:@"%ld", (long)_tokenAttemptsLeft], nil];
  _codeCountdown.text = [NSString stringWithFormat:@"%@  ·  %@", countdown, attempts];
  _codeCountdown.textColor = DBAddDim();
  _newCodeButton.hidden = YES;
}

- (void)applyAddAll {
  if (_pairingModeActive) {
    NSInteger left = [self remainingPairingModeSeconds];
    [_addAllButton setTitle:[_texts t:@"pair.add_all_on",
                                 [DBPairingModel countdownMinutesFromSeconds:left],
                                 [DBPairingModel countdownSecondsFromSeconds:left],
                                 [NSString stringWithFormat:@"%ld", (long)_pairingModeAdded],
                                 nil]
                   forState:UIControlStateNormal];
    _addAllStop.hidden = NO;
    _addAllWarning.hidden = NO;
    return;
  }
  _addAllStop.hidden = YES;
  [_addAllButton setTitle:(_confirmingAddAll ? [_texts ts:@"pair.confirm_tap_again"]
                                             : [_texts ts:@"pair.add_all"])
                 forState:UIControlStateNormal];
}

#pragma mark - events

- (void)handleInviteResult:(NSDictionary *)ev {
  NSString *identifier = [DBConfigUtil evStr:ev key:@"id"];
  if ([identifier length] == 0) return;
  if ([DBConfigUtil evBool:ev key:@"ok"]) {
    // Acknowledged, not joined: keep "追加中…" until device_joined confirms it.
    [_deviceStates setObject:@"adding" forKey:identifier];
    [_deviceErrors removeObjectForKey:identifier];
  } else {
    [_deviceStates setObject:@"failed" forKey:identifier];
    [_deviceErrors setObject:[DBConfigUtil evStr:ev key:@"err"] forKey:identifier];
  }
  [self applyContent];
}

- (void)handleDeviceJoined:(NSDictionary *)ev {
  NSString *identifier = [DBConfigUtil evStr:ev key:@"id"];
  if ([identifier length] == 0) return;
  NSString *name = [DBConfigUtil evStr:ev key:@"name"];
  if ([name length] > 0) [_deviceNames setObject:name forKey:identifier];
  [_deviceStates setObject:@"added" forKey:identifier];
  [_deviceErrors removeObjectForKey:identifier];
  [_addedAt setObject:[NSNumber numberWithDouble:CFAbsoluteTimeGetCurrent()]
               forKey:identifier];
  [self applyContent];
  [self reload];
}

- (void)handlePendingChanged:(NSDictionary *)ev {
  (void)ev;
  [self reload];
}

- (void)handlePairingModeChanged:(NSDictionary *)ev {
  _pairingModeActive = [DBConfigUtil evBool:ev key:@"active"];
  _pairingModeLeftS = [DBConfigUtil intVal:ev path:@"left_s" def:0];
  _pairingModeAdded = [DBConfigUtil intVal:ev path:@"auto_added_count" def:_pairingModeAdded];
  _pairingModeReadAt = CFAbsoluteTimeGetCurrent();
  if (!_pairingModeActive) _confirmingAddAll = NO;
  [self applyContent];
}

- (void)handleJoinTokenChanged:(NSDictionary *)ev {
  if (![DBConfigUtil evBool:ev key:@"active"]) {
    _tokenExpiresS = 0;
    _tokenAttemptsLeft = 0;
    [self applyContent];
    return;
  }
  _tokenExpiresS = [DBConfigUtil intVal:ev path:@"expires_s" def:_tokenExpiresS];
  _tokenAttemptsLeft = [DBConfigUtil intVal:ev path:@"attempts_left" def:_tokenAttemptsLeft];
  _tokenReadAt = CFAbsoluteTimeGetCurrent();
  [self applyContent];
}

- (void)handlePairingState:(NSDictionary *)ev {
  NSString *state = [DBConfigUtil evStr:ev key:@"state"];
  NSString *resolved = [DBPairingModel stateFromPairingInfo:@{ @"state" : state ?: @"" }];
  if (![resolved isEqualToString:DBPairingStateUnknown]) _state = resolved;
  [self applyContent];
  [self reload];
}

#pragma mark - actions

- (void)onAddDevice:(UIButton *)sender {
  NSString *identifier = sender.accessibilityIdentifier;
  if ([identifier length] == 0) return;
  [_deviceStates setObject:@"adding" forKey:identifier];
  [_deviceErrors removeObjectForKey:identifier];
  [self applyContent];
  [_core inviteDevice:identifier];
}

- (void)onDenyDevice:(UIButton *)sender {
  NSString *identifier = sender.accessibilityIdentifier;
  if ([identifier length] == 0) return;
  [_deviceStates removeObjectForKey:identifier];
  [_deviceErrors removeObjectForKey:identifier];
  [_addedAt removeObjectForKey:identifier];
  [_core denyDevice:identifier];
  [self reload];
}

- (void)onStartCode {
  _errorLabel.text = @"";
  _codeButton.enabled = NO;
  DBCoreBridge *core = _core;
  __weak DBAddDeviceScreen *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSDictionary *token = [core startPairingWithSeconds:600];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBAddDeviceScreen *screen = weakSelf;
      if (!screen) return;
      screen->_codeButton.enabled = YES;
      if ([token isKindOfClass:[NSDictionary class]] &&
          [DBConfigUtil evBool:token key:@"ok"]) {
        [screen adoptToken:token];
        if (screen->_tokenExpiresS <= 0) screen->_tokenExpiresS = 600;
        if (screen->_tokenAttemptsLeft <= 0) screen->_tokenAttemptsLeft = 3;
      } else {
        NSString *code = [DBConfigUtil evStr:token key:@"err"];
        screen->_errorLabel.text =
            [screen->_texts ts:[DBPairingModel errorTextKeyForCode:code]];
      }
      [screen applyContent];
    });
  });
}

- (void)onAddAll {
  if (_pairingModeActive) return;
  if (!_confirmingAddAll) {
    _confirmingAddAll = YES;
    [self applyAddAll];
    return;
  }
  _confirmingAddAll = NO;
  _pairingModeActive = YES;
  _pairingModeLeftS = 600;
  _pairingModeAdded = 0;
  _pairingModeReadAt = CFAbsoluteTimeGetCurrent();
  [_core setPairingMode:600];
  [self applyContent];
}

- (void)onStopAddAll {
  _pairingModeActive = NO;
  _confirmingAddAll = NO;
  [_core setPairingMode:0];
  [self applyContent];
  [self reload];
}

- (void)onUnpair {
  if (!_confirmingUnpair) {
    _confirmingUnpair = YES;
    _unpairConfirm.text = [_texts ts:@"pair.clear_confirm"];
    [_unpairButton setTitle:[_texts ts:@"pair.confirm_tap_again"]
                   forState:UIControlStateNormal];
    [self setNeedsLayout];
    return;
  }
  _confirmingUnpair = NO;
  _unpairConfirm.text = @"";
  [_unpairButton setTitle:[_texts ts:@"pair.clear_title"] forState:UIControlStateNormal];
  [_core unpair];
  NSString *json = [DBBootConfig clearPairingSecretRef];
  if ([json length] > 0) [_router boot].rawJson = json;
  [_router boot].legacyPskHex = @"";
  _state = @"unpaired";
  [self applyContent];
  [_router closeAddDeviceAnimated:NO];
  [_router showPairing];
}

- (void)onOpenOnboarding {
  [_router closeAddDeviceAnimated:NO];
  [_router showPairing];
}

- (void)onClose {
  [_router closeAddDeviceAnimated:YES];
}

#pragma mark - layout

- (void)layoutSubviews {
  [super layoutSubviews];
  CGSize size = self.bounds.size;
  CGFloat pad = 24;
  CGFloat width = size.width - pad * 2;
  CGFloat closeHeight = 52;
  _scroll.frame = CGRectMake(0, 12, size.width, size.height - 12 - closeHeight - 16);
  _closeButton.frame = CGRectMake(pad, size.height - closeHeight - 10, width, closeHeight);

  CGFloat y = 8;
  _title.frame = CGRectMake(pad, y, width, 34);
  y += 40;
  CGFloat membershipHeight = [_membership sizeThatFits:CGSizeMake(width, 9999)].height;
  _membership.frame = CGRectMake(pad, y, width, membershipHeight);
  y += membershipHeight + 16;

  if (!_unpairedNotice.hidden) {
    CGFloat noticeHeight = [_unpairedNotice sizeThatFits:CGSizeMake(width, 9999)].height;
    _unpairedNotice.frame = CGRectMake(pad, y, width, noticeHeight);
    y += noticeHeight + 12;
    _openOnboarding.frame = CGRectMake(pad, y, width, 48);
    y += 60;
  }

  if (!_nearbyPanel.hidden) {
    _nearbyTitle.frame = CGRectMake(pad, y, width, 24);
    y += 30;
    CGFloat rowY = 10;
    CGFloat inner = width - 24;
    for (UIView *row in _rowViews) {
      UILabel *name = (UILabel *)[row viewWithTag:1];
      UILabel *meta = (UILabel *)[row viewWithTag:2];
      UILabel *status = (UILabel *)[row viewWithTag:3];
      UIButton *add = (UIButton *)[row viewWithTag:4];
      UIButton *deny = (UIButton *)[row viewWithTag:5];
      UIActivityIndicatorView *spinner = (UIActivityIndicatorView *)[row viewWithTag:6];
      UILabel *failure = (UILabel *)[row viewWithTag:7];
      CGFloat actionWidth = 200;
      CGFloat rowHeight = 62;
      name.frame = CGRectMake(0, 6, inner - actionWidth - 10, 24);
      meta.frame = CGRectMake(0, 32, inner - actionWidth - 10, 18);
      if (add) {
        add.frame = CGRectMake(inner - actionWidth, 8, 110, 44);
        deny.frame = CGRectMake(inner - 82, 8, 82, 44);
      }
      if (status) {
        status.frame = CGRectMake(inner - actionWidth + (spinner ? 26 : 0), 18,
                                  actionWidth - (spinner ? 26 : 0), 24);
        if (spinner) spinner.center = CGPointMake(inner - actionWidth + 10, 30);
      }
      if (failure) {
        failure.frame = CGRectMake(0, rowHeight - 4, inner, 32);
        rowHeight += 34;
      }
      row.frame = CGRectMake(12, rowY, inner, rowHeight);
      rowY += rowHeight + 8;
    }
    CGFloat panelHeight = [_rowViews count] > 0 ? rowY + 4 : 84;
    if ([_rowViews count] == 0)
      _nearbyEmpty.frame = CGRectMake(12, 16, inner, 52);
    _nearbyPanel.frame = CGRectMake(pad, y, width, panelHeight);
    y += panelHeight + 16;

    _codeButton.frame = CGRectMake(pad, y, width, 48);
    y += 58;

    if (!_codeCard.hidden) {
      CGFloat cardInner = width - 32;
      CGFloat cy = 16;
      _codeAddressLabel.frame = CGRectMake(16, cy, cardInner, 18);
      cy += 20;
      _codeAddress.frame = CGRectMake(16, cy, cardInner, 30);
      cy += 38;
      _codeCodeLabel.frame = CGRectMake(16, cy, cardInner, 18);
      cy += 20;
      _codeCode.frame = CGRectMake(16, cy, cardInner, 50);
      cy += 56;
      _codeCountdown.frame = CGRectMake(16, cy, cardInner, 22);
      cy += 28;
      CGFloat instructionsHeight =
          [_codeInstructions sizeThatFits:CGSizeMake(cardInner, 9999)].height;
      _codeInstructions.frame = CGRectMake(16, cy, cardInner, instructionsHeight);
      cy += instructionsHeight + 12;
      if (!_newCodeButton.hidden) {
        _newCodeButton.frame = CGRectMake(16, cy, cardInner, 44);
        cy += 54;
      }
      _codeCard.frame = CGRectMake(pad, y, width, cy + 4);
      y += cy + 20;
    }

    _addAllButton.frame = CGRectMake(pad, y, width, 44);
    y += 50;
    CGFloat warningHeight = [_addAllWarning sizeThatFits:CGSizeMake(width, 9999)].height;
    _addAllWarning.frame = CGRectMake(pad, y, width, warningHeight);
    y += warningHeight + 10;
    if (!_addAllStop.hidden) {
      _addAllStop.frame = CGRectMake(pad, y, width, 44);
      y += 54;
    }

    CGFloat side = MIN(width * 0.5, 240);
    _qr.frame = CGRectMake((size.width - side) / 2, y, side, side);
    _qrPlaceholder.frame = CGRectMake(8, side / 2 - 20, side - 16, 40);
    y += side + 8;
    CGFloat captionHeight = [_qrCaption sizeThatFits:CGSizeMake(width, 9999)].height;
    _qrCaption.frame = CGRectMake(pad, y, width, captionHeight);
    y += captionHeight + 16;
  }

  CGFloat errorHeight = [_errorLabel.text length] > 0
      ? [_errorLabel sizeThatFits:CGSizeMake(width, 9999)].height : 0;
  _errorLabel.frame = CGRectMake(pad, y, width, errorHeight);
  y += errorHeight > 0 ? errorHeight + 10 : 0;

  if (!_unpairButton.hidden) {
    _unpairButton.frame = CGRectMake(pad, y, width, 40);
    y += 46;
    if ([_unpairConfirm.text length] > 0) {
      CGFloat confirmHeight = [_unpairConfirm sizeThatFits:CGSizeMake(width, 9999)].height;
      _unpairConfirm.frame = CGRectMake(pad, y, width, confirmHeight);
      y += confirmHeight + 10;
    }
  }

  _scroll.contentSize = CGSizeMake(size.width, y + 20);
}

@end
