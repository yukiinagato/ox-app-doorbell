#import "DBPairingScreen.h"

#import "../Core/DBBootConfig.h"
#import "../Core/DBConfigUtil.h"
#import "../Core/DBCoreBridge.h"
#import "../Core/DBPairUri.h"
#import "../Core/DBPairingModel.h"
#import "../Core/DBTexts.h"
#import "../Media/DBQrCode.h"
#import "DBChrome.h"
#import "DBRouter.h"
#import <QuartzCore/QuartzCore.h>

static const CGFloat kColumnMax = 620;
static const CGFloat kQrSide = 240;
static const CGFloat kQrSideMin = 160;
static const CGFloat kSummaryPad = 20;
static const NSUInteger kPinLength = 6;

typedef enum {
  DBPairSectionUpgrade = 0,
  DBPairSectionPersist,
  DBPairSectionCreated,
  DBPairSectionJoin,
  DBPairSectionNotice,
  DBPairSectionCreate,
  DBPairSectionExit,
} DBPairSection;

typedef enum {
  DBPairRowUpgradeAction = 0,
  DBPairRowRetry,
  DBPairRowCreatedAddress,
  DBPairRowCreatedCountdown,
  DBPairRowHost,
  DBPairRowPin,
  DBPairRowJoin,
  DBPairRowCreate,
  DBPairRowExit,
} DBPairRow;

static NSString *const kSectionKind = @"kind";
static NSString *const kSectionRows = @"rows";

@interface DBPairingScreen () <UIAlertViewDelegate, UITextFieldDelegate, UITableViewDataSource,
                               UITableViewDelegate>
@end

@implementation DBPairingScreen {
  DBNavBar *_nav;
  UITableView *_table;

  // What this device is and how pairing stands. It is the table's header in one column and
  // sits beside the table in two.
  UIView *_summary;
  BOOL _summaryInTable;
  CGFloat _summaryHeight;
  CGFloat _summaryWidth;
  // Security protocol v3: the eight-digit code an administrator types to add this device.
  // After founding a cluster the same label shows the minted Pairing PIN.
  UILabel *_codeCaption;
  UILabel *_codeLabel;
  UILabel *_identity;
  UIActivityIndicatorView *_spinner;
  UILabel *_status;
  UILabel *_hint;
  UIImageView *_qr;
  UILabel *_qrPlaceholder;
  UILabel *_qrCaption;

  // Join with a Pairing PIN. The field cells are built once so a reload keeps their text.
  UITableViewCell *_hostCell;
  UITextField *_hostField;
  UITableViewCell *_pinCell;
  UITextField *_pinField;
  NSString *_pendingInvitationPin;

  // Sections on screen: dictionaries of a DBPairSection kind and its DBPairRow kinds.
  NSArray *_model;
  NSString *_modelSignature;
  UIAlertView *_alert;

  NSString *_confirmCode;
  NSString *_errorText;
  NSString *_errorDetail;
  BOOL _upgradeRejoin;

  NSString *_state;
  NSString *_lastQr;
  NSTimer *_poll;
  BOOL _fetchBusy;
  BOOL _confirmingCreate;
  BOOL _creating;
  BOOL _retrying;
  BOOL _createdFlow;       // The create-Cluster section must stay on screen.
  BOOL _joining;
  BOOL _joinSuccessShown;
  BOOL _sawNotReady;   // Guards the auto-close against a stale first snapshot.
  BOOL _dismissed;
  NSDictionary *_token;    // pairing.token while active.
  NSString *_tokenHost;
  NSString *_tokenPin;
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
    _model = @[];
    _modelSignature = @"";
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
  _alert.delegate = nil;
  _table.dataSource = nil;
  _table.delegate = nil;
}

- (NSString *)screenName {
  return @"pairing";
}

#pragma mark - construction

- (UILabel *)summaryLabel:(UILabel *)label {
  label.textAlignment = NSTextAlignmentCenter;
  [_summary addSubview:label];
  return label;
}

- (UITableViewCell *)fieldCellWithField:(UITextField *)field {
  UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                 reuseIdentifier:nil];
  cell.selectionStyle = UITableViewCellSelectionStyleNone;
  field.frame = CGRectInset(cell.contentView.bounds, 12, 0);
  field.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  field.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
  field.autocorrectionType = UITextAutocorrectionTypeNo;
  field.autocapitalizationType = UITextAutocapitalizationTypeNone;
  field.clearButtonMode = UITextFieldViewModeWhileEditing;
  field.delegate = self;
  [cell.contentView addSubview:field];
  return cell;
}

- (void)buildUi {
  DBTexts *texts = [_router texts];
  self.backgroundColor = DBChromeScreenBackground();
  DBChromeInstallBackdrop(self);

  _table = DBChromeGroupedTable(self, self);
  DBChromeClearTableBackground(_table);
  [self addSubview:_table];

  // First-run pairing has nowhere to go back to: the exit is the "set up later" row.
  _nav = [[DBNavBar alloc] init];
  [_nav setRootTitle:[texts ts:@"pair.title_unpaired"] backTitle:nil onBack:nil];
  [self addSubview:_nav.bar];

  _summary = [[UIView alloc] init];
  _codeCaption = [self summaryLabel:DBChromeSectionFooterLabel()];
  // Monospaced digits, sized to be read across a room; drawn once, no animation (A4 budget).
  _codeLabel = [self summaryLabel:[[UILabel alloc] init]];
  _codeLabel.backgroundColor = [UIColor clearColor];
  _codeLabel.font = [UIFont fontWithName:@"Courier-Bold" size:56] ?: [UIFont boldSystemFontOfSize:56];
  _codeLabel.adjustsFontSizeToFitWidth = YES;
  _codeLabel.accessibilityIdentifier = @"pair_confirm_code";
  _identity = [self summaryLabel:DBChromeSectionFooterLabel()];
  _status = [self summaryLabel:DBChromeSectionHeaderLabel()];
  _status.text = [texts ts:@"pair.searching"];
  _spinner = [[UIActivityIndicatorView alloc]
      initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
  _spinner.hidesWhenStopped = YES;
  [_summary addSubview:_spinner];
  _hint = [self summaryLabel:DBChromeSectionFooterLabel()];
  _hint.text = [texts ts:@"pair.searching_hint"];

  _qr = [[UIImageView alloc] init];
  _qr.contentMode = UIViewContentModeScaleAspectFit;
  // The bitmap is one pixel per point; enlarging it must keep the module edges hard.
  _qr.layer.magnificationFilter = kCAFilterNearest;
  [_summary addSubview:_qr];
  // Never an empty square: a caption holds the place until Core publishes pair_qr.
  _qrPlaceholder = [self summaryLabel:DBChromeSectionFooterLabel()];
  _qrPlaceholder.text = [texts ts:@"pair.qr_pending"];
  _qrCaption = [self summaryLabel:DBChromeSectionFooterLabel()];
  _qrCaption.text = [texts ts:@"pair.qr_caption"];

  _hostField = [[UITextField alloc] init];
  _hostField.placeholder = [NSString stringWithFormat:@"%@  %@", [texts ts:@"pair.address_label"],
                                                      [texts ts:@"pair.address_example"]];
  _hostField.keyboardType = UIKeyboardTypeURL;
  _hostField.returnKeyType = UIReturnKeyNext;
  _hostField.accessibilityIdentifier = @"pair_join_host";
  _hostCell = [self fieldCellWithField:_hostField];

  _pinField = [[UITextField alloc] init];
  _pinField.placeholder = [texts ts:@"pair.code_label"];
  _pinField.keyboardType = UIKeyboardTypeNumberPad;
  _pinField.returnKeyType = UIReturnKeyJoin;
  _pinField.accessibilityIdentifier = @"pair_join_pin";
  _pinCell = [self fieldCellWithField:_pinField];

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
  [self dismissAlert];
  [self endEditing:YES];
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
      // Localized role, the device's own name and the app version. Core's
      // default name is "<role> · <id>" and its model may still read "unknown"
      // on an older boot document, so neither is shown raw.
      DBTexts *texts = [_router texts];
      DBBootConfig *boot = [_router boot];
      NSString *nodeId = [DBConfigUtil evStr:selfInfo key:@"node_id"];
      if ([nodeId length] == 0) nodeId = [DBConfigUtil evStr:selfInfo key:@"id"];
      NSString *name = [nodeId length] > 0
          ? [DBConfigUtil str:[[_router core] lastConfig]
                         path:[NSString stringWithFormat:@"devices.%@.name", nodeId]] : nil;
      if ([name length] == 0) name = boot.name;
      NSString *coreName = [DBConfigUtil evStr:selfInfo key:@"name"];
      if ([name length] == 0 && [coreName rangeOfString:@" · "].location == NSNotFound)
        name = coreName;
      NSString *role = [texts ts:[boot.role isEqualToString:@"door_station"]
                                     ? @"pair.role_door_station" : @"pair.role_indoor_panel"];
      NSString *version =
          [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
      NSString *addr = [DBConfigUtil evStr:selfInfo key:@"addr"];
      NSMutableArray *parts = [NSMutableArray arrayWithObject:role];
      if ([name length] > 0) [parts addObject:name];
      if ([version length] > 0) [parts addObject:[NSString stringWithFormat:@"v%@", version]];
      NSString *head = [parts componentsJoinedByString:@" · "];
      _identity.text = [addr length] > 0 ? [NSString stringWithFormat:@"%@\n%@", head, addr] : head;
      NSString *code = [DBConfigUtil evStr:selfInfo key:@"confirm_code"];
      _confirmCode = [code length] == 8
          ? [NSString stringWithFormat:@"%@ %@", [code substringToIndex:4], [code substringFromIndex:4]]
          : [code copy];
    }
    _upgradeRejoin = [DBConfigUtil evBool:info key:@"upgrade_rejoin_required"];
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
  if ([host length] > 0) _tokenHost = [host copy];
  if ([pin length] > 0) _tokenPin = [pin copy];
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
    UIImage *image = [DBQrCode imageForString:payload targetPx:kQrSide];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBPairingScreen *screen = weakSelf;
      if (!screen || ![screen->_lastQr isEqualToString:payload]) return;
      screen->_qr.image = image;
      screen->_qrPlaceholder.hidden = (image != nil) || screen->_qr.hidden;
    });
  });
}

#pragma mark - state rendering

- (BOOL)isPersistError {
  return [_state isEqualToString:@"persist_error"];
}

- (BOOL)showsCreated {
  return _createdFlow && ![self isPersistError];
}

// A persistence error is cleared only by a successful retry. Every other path
// is hidden so nothing else can silently dismiss it.
- (BOOL)showsJoinPath {
  return ![self isPersistError] && ![self showsCreated] &&
         ![_state isEqualToString:@"ready"] && ![_state isEqualToString:@"revoked"];
}

static NSDictionary *DBPairSectionMake(DBPairSection kind, NSArray *rows) {
  return @{ kSectionKind : @(kind), kSectionRows : rows };
}

- (NSArray *)buildModel {
  if ([self isPersistError])
    return @[ DBPairSectionMake(DBPairSectionPersist, @[ @(DBPairRowRetry) ]) ];

  NSMutableArray *model = [NSMutableArray array];
  BOOL joining = [_state isEqualToString:@"joining"] || _joining;
  if ([self showsCreated]) {
    [model addObject:DBPairSectionMake(DBPairSectionCreated,
        @[ @(DBPairRowCreatedAddress), @(DBPairRowCreatedCountdown) ])];
  }
  if ([self showsJoinPath]) {
    // Paired under protocol v2: one clear warning state, then the ordinary join path.
    if (_upgradeRejoin && !joining)
      [model addObject:DBPairSectionMake(DBPairSectionUpgrade, @[ @(DBPairRowUpgradeAction) ])];
    [model addObject:DBPairSectionMake(DBPairSectionJoin,
        @[ @(DBPairRowHost), @(DBPairRowPin), @(DBPairRowJoin) ])];
    // A door station is installed outside and is never the device an operator
    // uses to create the Cluster.
    if (![[_router boot].role isEqualToString:@"door_station"])
      [model addObject:DBPairSectionMake(DBPairSectionCreate, @[ @(DBPairRowCreate) ])];
  } else if ([_errorText length] > 0) {
    [model addObject:DBPairSectionMake(DBPairSectionNotice, @[])];
  }
  [model addObject:DBPairSectionMake(DBPairSectionExit, @[ @(DBPairRowExit) ])];
  return model;
}

- (NSString *)exitTitle {
  DBTexts *texts = [_router texts];
  BOOL finished = _createdFlow || [_state isEqualToString:@"ready"] ||
                  [_state isEqualToString:@"revoked"];
  return [texts ts:finished ? @"ui.close" : @"pair.later"];
}

- (NSString *)errorFooter {
  if ([_errorText length] == 0) return nil;
  return [_errorDetail length] > 0
      ? [NSString stringWithFormat:@"%@\n%@", _errorText, _errorDetail] : _errorText;
}

- (void)applyState {
  DBTexts *texts = [_router texts];
  BOOL persistError = [self isPersistError];
  BOOL joining = [_state isEqualToString:@"joining"] || _joining;
  BOOL ready = [_state isEqualToString:@"ready"];
  BOOL revoked = [_state isEqualToString:@"revoked"];
  BOOL showCard = [self showsCreated];
  BOOL upgrade = NO;

  _hostField.enabled = !joining;
  _pinField.enabled = !joining;
  if (joining) [self endEditing:YES];

  if (persistError) {
    _status.text = @"";
    [_spinner stopAnimating];
  } else if (revoked) {
    _status.text = [texts ts:@"pair.revoked"];
    [_spinner stopAnimating];
  } else if (showCard) {
    _status.text = [NSString stringWithFormat:@"%@ ✓", [texts ts:@"pair.created"]];
    [_spinner stopAnimating];
  } else if (ready) {
    _status.text = [NSString stringWithFormat:@"%@ ✓", [texts ts:@"pair.joined"]];
    [_spinner stopAnimating];
  } else if (joining) {
    _status.text = [texts ts:@"pair.joining"];
    [_spinner startAnimating];
  } else if (_upgradeRejoin) {
    upgrade = YES;
    _status.text = [texts ts:@"pair.upgrade_rejoin"];
    [_spinner stopAnimating];
  } else {
    _status.text = [texts ts:@"pair.searching"];
    [_spinner startAnimating];
  }
  _nav.topItem.title = [texts ts:upgrade ? @"pair.upgrade_title" : @"pair.title_unpaired"];

  // The large code is this device's confirmation code while it waits to be added, and the
  // minted Pairing PIN once it has founded a cluster.
  BOOL unpaired = [_state isEqualToString:@"unpaired"];
  NSString *code = nil;
  if (showCard) {
    code = _tokenPin;
    _codeCaption.text = [texts ts:@"pair.code_label"];
  } else if (unpaired && !persistError) {
    code = _confirmCode;
    _codeCaption.text = [texts ts:@"pair.confirm_code_caption"];
  }
  _codeLabel.text = code;
  _codeLabel.hidden = [code length] == 0;
  _codeCaption.hidden = _codeLabel.hidden;

  _qr.hidden = persistError || showCard;
  _qrCaption.hidden = _qr.hidden;
  _qrPlaceholder.hidden = _qr.hidden || _qr.image != nil;
  // Core does not report clock skew, so a skew warning would only be a guess.
  _hint.hidden = persistError || showCard || joining || ready;

  NSArray *model = [self buildModel];
  NSMutableString *signature = [NSMutableString string];
  for (NSDictionary *section in model)
    [signature appendFormat:@"%@:%lu,", [section objectForKey:kSectionKind],
                            (unsigned long)[[section objectForKey:kSectionRows] count]];
  [signature appendFormat:@"/%d%d%d/%@/%@", (int)joining, (int)_creating, (int)_retrying,
                          [self exitTitle], [self errorFooter] ?: @""];
  _model = model;
  if (![signature isEqualToString:_modelSignature]) {
    _modelSignature = [signature copy];
    [self reloadTable];
  } else {
    for (NSIndexPath *indexPath in [_table indexPathsForVisibleRows]) {
      DBPairRow kind = [self rowKindAt:indexPath];
      if (kind != DBPairRowCreatedAddress && kind != DBPairRowCreatedCountdown) continue;
      UITableViewCell *cell = [_table cellForRowAtIndexPath:indexPath];
      if (cell) [self configureCell:cell kind:kind];
    }
  }
  [self setNeedsLayout];
}

// A reload detaches every cell, which takes the keyboard away from a field being edited;
// the field gets it back once its cell is on screen again.
- (void)reloadTable {
  UITextField *editing = [_hostField isFirstResponder] ? _hostField
      : ([_pinField isFirstResponder] ? _pinField : nil);
  [_table reloadData];
  if (editing && editing.enabled && [self showsJoinPath]) {
    [_table layoutIfNeeded];
    [editing becomeFirstResponder];
  }
}

- (NSString *)countdownText {
  DBTexts *texts = [_router texts];
  NSInteger left = [self remainingTokenSeconds];
  if (!_token || left <= 0) return [texts ts:@"pair.code_expired"];
  return [texts t:@"pair.code_expires_in", [DBPairingModel countdownMinutesFromSeconds:left],
                  [DBPairingModel countdownSecondsFromSeconds:left], nil];
}

- (NSString *)attemptsText {
  if (!_token || [self remainingTokenSeconds] <= 0) return @"";
  return [[_router texts] t:@"pair.code_attempts_left",
                            [NSString stringWithFormat:@"%ld", (long)_tokenAttemptsLeft], nil];
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

#pragma mark - table

- (DBPairSection)sectionKindAt:(NSInteger)section {
  return (DBPairSection)[[[_model objectAtIndex:(NSUInteger)section] objectForKey:kSectionKind]
      intValue];
}

- (DBPairRow)rowKindAt:(NSIndexPath *)indexPath {
  NSArray *rows = [[_model objectAtIndex:(NSUInteger)indexPath.section]
      objectForKey:kSectionRows];
  return (DBPairRow)[[rows objectAtIndex:(NSUInteger)indexPath.row] intValue];
}

- (NSInteger)indexOfSection:(DBPairSection)kind {
  for (NSUInteger i = 0; i < [_model count]; i++)
    if ([self sectionKindAt:(NSInteger)i] == kind) return (NSInteger)i;
  return NSNotFound;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  (void)tableView;
  return (NSInteger)[_model count];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  (void)tableView;
  return (NSInteger)[[[_model objectAtIndex:(NSUInteger)section] objectForKey:kSectionRows]
      count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
  (void)tableView;
  DBTexts *texts = [_router texts];
  switch ([self sectionKindAt:section]) {
    case DBPairSectionUpgrade: return [texts ts:@"pair.upgrade_title"];
    case DBPairSectionPersist: return [texts ts:@"pair.persist_error_title"];
    case DBPairSectionCreated: return [texts ts:@"pair.created_next"];
    case DBPairSectionJoin: return [texts ts:@"pair.join_with_code"];
    default: return nil;
  }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
  (void)tableView;
  DBTexts *texts = [_router texts];
  switch ([self sectionKindAt:section]) {
    case DBPairSectionUpgrade: return [texts ts:@"pair.upgrade_body"];
    case DBPairSectionPersist: return [texts ts:@"pair.persist_error_body"];
    case DBPairSectionCreated: return [texts ts:@"pair.code_instructions"];
    case DBPairSectionJoin:
    case DBPairSectionNotice: return [self errorFooter];
    default: return nil;
  }
}

- (UIActivityIndicatorView *)rowSpinner {
  UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
      initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
  [spinner startAnimating];
  return spinner;
}

- (void)configureActionCell:(UITableViewCell *)cell title:(NSString *)title busy:(BOOL)busy
                    enabled:(BOOL)enabled {
  cell.textLabel.text = title;
  cell.textLabel.textAlignment = NSTextAlignmentCenter;
  cell.textLabel.adjustsFontSizeToFitWidth = YES;
  cell.textLabel.enabled = enabled && !busy;
  cell.selectionStyle = (enabled && !busy) ? UITableViewCellSelectionStyleBlue
                                           : UITableViewCellSelectionStyleNone;
  cell.accessoryView = busy ? [self rowSpinner] : nil;
}

- (void)configureCell:(UITableViewCell *)cell kind:(DBPairRow)kind {
  DBTexts *texts = [_router texts];
  BOOL joining = [_state isEqualToString:@"joining"] || _joining;
  switch (kind) {
    case DBPairRowUpgradeAction:
      [self configureActionCell:cell title:[texts ts:@"pair.upgrade_rejoin_action"] busy:NO
                        enabled:YES];
      break;
    case DBPairRowRetry:
      [self configureActionCell:cell title:[texts ts:@"pair.retry"] busy:_retrying enabled:YES];
      break;
    case DBPairRowCreatedAddress:
      cell.textLabel.text = [texts ts:@"pair.address_label"];
      cell.detailTextLabel.text = _tokenHost ?: @"";
      cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
      break;
    case DBPairRowCreatedCountdown:
      cell.textLabel.text = [self countdownText];
      cell.textLabel.adjustsFontSizeToFitWidth = YES;
      cell.detailTextLabel.text = [self attemptsText];
      break;
    case DBPairRowJoin:
      [self configureActionCell:cell title:[texts ts:@"pair.join_submit"]
                           busy:joining && !_creating enabled:YES];
      cell.accessibilityIdentifier = @"pair_join_submit";
      break;
    case DBPairRowCreate:
      [self configureActionCell:cell title:[texts ts:@"pair.create_home"] busy:_creating
                        enabled:!joining];
      break;
    case DBPairRowExit:
      [self configureActionCell:cell title:[self exitTitle] busy:NO enabled:YES];
      break;
    case DBPairRowHost:
    case DBPairRowPin:
      break;
  }
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  DBPairRow kind = [self rowKindAt:indexPath];
  if (kind == DBPairRowHost) return _hostCell;
  if (kind == DBPairRowPin) return _pinCell;
  BOOL value = kind == DBPairRowCreatedAddress || kind == DBPairRowCreatedCountdown;
  NSString *identifier = value ? @"value" : @"action";
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
  if (!cell) {
    cell = [[UITableViewCell alloc]
          initWithStyle:value ? UITableViewCellStyleValue1 : UITableViewCellStyleDefault
        reuseIdentifier:identifier];
    if (value) cell.selectionStyle = UITableViewCellSelectionStyleNone;
  }
  cell.accessibilityIdentifier = nil;
  [self configureCell:cell kind:kind];
  return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:NO];
  BOOL joining = [_state isEqualToString:@"joining"] || _joining;
  switch ([self rowKindAt:indexPath]) {
    case DBPairRowUpgradeAction: [self focusField:_hostField]; break;
    case DBPairRowRetry: if (!_retrying) [self onRetryPersistence]; break;
    case DBPairRowJoin: if (!joining) [self submitJoinWithCode:_pinField.text ?: @""]; break;
    case DBPairRowCreate: if (!joining && !_creating) [self onCreate]; break;
    case DBPairRowExit: [self onLater]; break;
    default: break;
  }
}

#pragma mark - fields

// A field can take the keyboard only while its cell is in the table, so the join section is
// brought on screen and laid out first.
- (void)focusField:(UITextField *)field {
  NSInteger join = [self indexOfSection:DBPairSectionJoin];
  if (join == NSNotFound || !field.enabled) return;
  [_table scrollRectToVisible:[_table rectForSection:join] animated:NO];
  [_table layoutIfNeeded];
  [field becomeFirstResponder];
}

static NSString *DBPairDigits(NSString *text, NSUInteger limit) {
  NSMutableString *digits = [NSMutableString string];
  for (NSUInteger i = 0; i < [text length] && [digits length] < limit; i++) {
    unichar c = [text characterAtIndex:i];
    if (c >= '0' && c <= '9') [digits appendFormat:@"%C", c];
  }
  return digits;
}

- (BOOL)textField:(UITextField *)field shouldChangeCharactersInRange:(NSRange)range
    replacementString:(NSString *)string {
  if (field != _pinField) return YES;
  NSString *next = [field.text ?: @"" stringByReplacingCharactersInRange:range withString:string];
  return [next length] <= kPinLength &&
         [DBPairDigits(next, kPinLength) length] == [next length];
}

- (BOOL)textFieldShouldReturn:(UITextField *)field {
  if (field == _hostField) {
    [_pinField becomeFirstResponder];
  } else {
    [self submitJoinWithCode:_pinField.text ?: @""];
  }
  return NO;
}

#pragma mark - events

- (void)handleJoinResult:(NSDictionary *)ev {
  _joining = NO;
  if ([DBConfigUtil evBool:ev key:@"ok"]) {
    // Success is confirmed by pairing_state; keep the joining feedback until
    // then instead of announcing a result Core has not committed yet.
    _errorText = nil;
    _errorDetail = nil;
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
  _errorText = nil;
  _errorDetail = nil;
  [self applyState];
}

- (void)showErrorCode:(NSString *)code {
  DBTexts *texts = [_router texts];
  _errorText = [texts ts:[DBPairingModel errorTextKeyForCode:code]];
  _errorDetail = [code length] > 0 ? [texts t:@"pair.err_detail", code, nil] : nil;
  [self applyState];
}

#pragma mark - actions

- (void)dismissAlert {
  UIAlertView *alert = _alert;
  _alert = nil;
  _confirmingCreate = NO;
  alert.delegate = nil;
  [alert dismissWithClickedButtonIndex:alert.cancelButtonIndex animated:NO];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
  if (alertView != _alert) return;
  _alert = nil;
  if (buttonIndex != alertView.cancelButtonIndex) [self onCreate];
  else _confirmingCreate = NO;
}

// An invitation opened from a QR or a doorbell://pair link. The device is not
// taken out of a cluster without being asked: joining is a full local reset.
- (void)presentInvitation:(DBPairUri *)invitation {
  DBTexts *texts = [_router texts];
  [self dismissAlert];
  if (invitation == nil || ![invitation isValid]) {
    NSString *reason = invitation.error;
    _errorText = [texts ts:@"pair.invitation_title"];
    _errorDetail = [texts ts:([reason isEqualToString:DBPairUriErrorExpired]
                                  ? @"pair.invitation_expired"
                                  : @"pair.invitation_invalid")];
    [self applyState];
    return;
  }
  _hostField.text = invitation.host;
  _pendingInvitationPin = [invitation.pin copy];
  // The PIN is filled in but not sent: the visitor of this screen still has to
  // press join, which is the confirmation, and can see what they are joining.
  _pinField.text = DBPairDigits(invitation.pin, kPinLength);
  _errorText = [invitation.cluster length] > 0
      ? [texts t:@"pair.invitation_confirm", invitation.cluster, nil]
      : [texts ts:@"pair.invitation_confirm_unnamed"];
  // Already in a cluster: say what joining costs before it happens.
  _errorDetail = [_state isEqualToString:@"ready"]
      ? [texts ts:@"pair.invitation_replace"] : nil;
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
    _errorText = [texts ts:@"pair.enter_address_and_code"];
    _errorDetail = [texts ts:@"pair.address_example"];
    [self applyState];
    [self focusField:_hostField];
    return;
  }
  if ([code length] != kPinLength) {
    _errorText = [texts ts:@"pair.enter_address_and_code"];
    _errorDetail = [texts ts:@"pair.code_label"];
    [self applyState];
    [self focusField:_pinField];
    return;
  }
  [self endEditing:YES];
  _errorText = nil;
  _errorDetail = nil;
  _joining = YES;
  [self applyState];
  [[_router core] joinCluster:host pin:code];
}

- (void)onCreate {
  DBTexts *texts = [_router texts];
  if (!_confirmingCreate) {
    if (_alert != nil) return;
    _confirmingCreate = YES;
    _errorText = nil;
    _errorDetail = nil;
    [self endEditing:YES];
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:[texts ts:@"pair.create_home"]
                                                    message:[texts ts:@"pair.create_home_confirm"]
                                                   delegate:self
                                          cancelButtonTitle:[texts ts:@"admin.cancel"]
                                          otherButtonTitles:[texts ts:@"editor.confirm"], nil];
    _alert = alert;
    [alert show];
    [self applyState];
    return;
  }
  _confirmingCreate = NO;
  _creating = YES;
  _joining = YES;
  [self applyState];

  DBCoreBridge *core = [_router core];
  __weak DBPairingScreen *weakSelf = self;
  // foundCluster and the PIN mint both block on the Core queue; never on main.
  // Founding shows the Pairing PIN and this device's own QR and nothing else: it
  // must not open the bulk-add window, which would silently adopt every
  // device that asks (spec §5.4).
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    BOOL created = [core foundCluster];
    NSDictionary *token = created ? [core mintJoinTokenWithSeconds:600] : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
      DBPairingScreen *screen = weakSelf;
      if (!screen) return;
      screen->_joining = NO;
      screen->_creating = NO;
      if (!created) {
        // Core refuses only when this node is already in a Cluster; anything
        // else is a local failure with no specific code.
        [screen showErrorCode:[screen->_state isEqualToString:@"ready"]
                                  ? @"already_paired" : @""];
        return;
      }
      // A `paired` event must not close the screen at zero frames and take the
      // generated Pairing PIN with it: the created section owns the screen
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
  [self endEditing:YES];
  [_router pairingDeferredByUser];
  [_router closePairingAnimated:YES];
}

- (void)onRetryPersistence {
  _retrying = YES;
  [self applyState];
  DBCoreBridge *core = [_router core];
  __weak DBPairingScreen *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    BOOL ok = [core retryPairingPersistence];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBPairingScreen *screen = weakSelf;
      if (!screen) return;
      screen->_retrying = NO;
      if (ok) screen->_state = @"ready";
      [screen applyState];
      [screen reload];
    });
  });
}

#pragma mark - keyboard

- (void)onKeyboardWillShow:(NSNotification *)note {
  // Another screen's keyboard (an alert's text field) is not this table's concern.
  if (!self.window) return;
  NSValue *frame = [[note userInfo] objectForKey:UIKeyboardFrameEndUserInfoKey];
  CGRect local = [self convertRect:[frame CGRectValue] fromView:nil];
  _keyboardInset = MAX(0, CGRectGetMaxY(_table.frame) - CGRectGetMinY(local));
  [self applyKeyboardInsetAndScrollToField];
}

- (void)onKeyboardWillHide:(NSNotification *)note {
  (void)note;
  _keyboardInset = 0;
  [self applyKeyboardInsetAndScrollToField];
}

// The whole join section (both fields and the Join row) is brought above the keyboard.
- (void)applyKeyboardInsetAndScrollToField {
  UIEdgeInsets insets = UIEdgeInsetsMake(0, 0, _keyboardInset, 0);
  _table.contentInset = insets;
  _table.scrollIndicatorInsets = insets;
  NSInteger join = [self indexOfSection:DBPairSectionJoin];
  if (_keyboardInset > 0 && join != NSNotFound &&
      ([_hostField isFirstResponder] || [_pinField isFirstResponder])) {
    [_table scrollRectToVisible:[_table rectForSection:join] animated:YES];
  }
}

#pragma mark - layout

- (CGFloat)heightOfLabel:(UILabel *)label width:(CGFloat)width {
  if (label.hidden || [label.text length] == 0) return 0;
  return ceilf([label sizeThatFits:CGSizeMake(width, 9999)].height);
}

// Stacks the visible summary pieces in a column of the given width and returns its height.
// A positive maxHeight shrinks the QR so the column fits beside the table.
- (CGFloat)layoutSummaryForWidth:(CGFloat)width maxHeight:(CGFloat)maxHeight {
  CGFloat inner = width - kSummaryPad * 2;
  CGFloat x = kSummaryPad;
  CGFloat y = 12;

  if (!_codeLabel.hidden) {
    CGFloat captionHeight = [self heightOfLabel:_codeCaption width:inner];
    _codeCaption.frame = CGRectMake(x, y, inner, captionHeight);
    y += captionHeight + 4;
    _codeLabel.frame = CGRectMake(x, y, inner, 64);
    y += 64 + 8;
  }

  CGFloat identityHeight = [self heightOfLabel:_identity width:inner];
  _identity.frame = CGRectMake(x, y, inner, identityHeight);
  y += identityHeight > 0 ? identityHeight + 10 : 0;

  // The spinner sits right beside the status text, the pair centred together.
  CGFloat spinnerSpace = [_spinner isAnimating] ? 28 : 0;
  if ([_status.text length] > 0) {
    CGSize fit = [_status sizeThatFits:CGSizeMake(inner - spinnerSpace, 9999)];
    CGFloat statusWidth = MIN(inner - spinnerSpace, ceilf(fit.width));
    CGFloat statusHeight = MAX(24, ceilf(fit.height));
    CGFloat groupX = x + floorf((inner - statusWidth - spinnerSpace) / 2);
    _status.frame = CGRectMake(groupX + spinnerSpace, y, statusWidth, statusHeight);
    _spinner.center = CGPointMake(groupX + 10, y + statusHeight / 2);
    y += statusHeight + 6;
  } else {
    _status.frame = CGRectZero;
  }

  CGFloat hintHeight = [self heightOfLabel:_hint width:inner];
  _hint.frame = CGRectMake(x, y, inner, hintHeight);
  y += hintHeight > 0 ? hintHeight + 10 : 0;

  if (!_qr.hidden) {
    CGFloat captionHeight = [self heightOfLabel:_qrCaption width:inner];
    CGFloat side = MIN(kQrSide, inner);
    if (maxHeight > 0) side = MAX(kQrSideMin, MIN(side, maxHeight - y - captionHeight - 20));
    _qr.frame = CGRectMake(x + floorf((inner - side) / 2), y, side, side);
    _qrPlaceholder.frame = CGRectInset(_qr.frame, 8, 8);
    y += side + 8;
    _qrCaption.frame = CGRectMake(x, y, inner, captionHeight);
    y += captionHeight;
  }
  return y + 12;
}

- (void)layoutSubviews {
  [super layoutSubviews];
  CGRect bounds = self.bounds;
  CGFloat top = [_nav layoutInBounds:bounds];
  CGFloat height = bounds.size.height - top;
  // Landscape on a tablet has room for two columns: what this device is and its status on
  // the left, the form on the right. Everywhere else one centred column scrolls as a whole.
  BOOL twoColumns = bounds.size.width > bounds.size.height && bounds.size.width >= 900;

  if (twoColumns) {
    CGFloat column = MIN(kColumnMax, floorf(bounds.size.width / 2));
    CGFloat left = floorf((bounds.size.width - column * 2) / 2);
    if (_summaryInTable) {
      _table.tableHeaderView = nil;
      _summaryInTable = NO;
    }
    if (_summary.superview != self) [self insertSubview:_summary belowSubview:_nav.bar];
    CGFloat summaryHeight = [self layoutSummaryForWidth:column maxHeight:height];
    _summary.frame = CGRectMake(left, top, column, MIN(summaryHeight, height));
    _table.frame = CGRectMake(left + column, top, column, height);
    _summaryHeight = 0;
    _summaryWidth = 0;
  } else {
    CGFloat column = MIN(kColumnMax, bounds.size.width);
    _table.frame = CGRectMake(floorf((bounds.size.width - column) / 2), top, column, height);
    CGFloat summaryHeight = [self layoutSummaryForWidth:column maxHeight:0];
    // Handing the header back is how a table learns that its height changed.
    if (!_summaryInTable || summaryHeight != _summaryHeight || column != _summaryWidth) {
      _summary.frame = CGRectMake(0, 0, column, summaryHeight);
      _table.tableHeaderView = _summary;
      _summaryInTable = YES;
      _summaryHeight = summaryHeight;
      _summaryWidth = column;
    }
  }
}

@end
