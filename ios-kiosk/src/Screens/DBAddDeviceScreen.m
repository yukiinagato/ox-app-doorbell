#import "DBAddDeviceScreen.h"

#import "../Core/DBBootConfig.h"
#import "../Core/DBConfigUtil.h"
#import "../Core/DBCoreBridge.h"
#import "../Core/DBPairingModel.h"
#import "../Core/DBTexts.h"
#import "../Media/DBQrCode.h"
#import "DBChrome.h"
#import "DBQrScanOverlay.h"
#import "DBRouter.h"

// A joined device leaves pending.devices[] immediately. Keep its row on screen with the
// "added" confirmation for a moment so the operator sees the result of their own tap.
static const NSTimeInterval kAddedRowLingerS = 6.0;

static const CGFloat kColumnMax = 700;
static const CGFloat kQrSide = 240;
static const CGFloat kAddButtonWidth = 84;

typedef enum {
  DBAddSectionOnboarding = 0,
  DBAddSectionNearby,
  DBAddSectionPin,
  DBAddSectionQr,
  DBAddSectionAddAll,
  DBAddSectionSecurity,
  DBAddSectionUnpair,
} DBAddSection;

typedef enum {
  DBAddRowOpenOnboarding = 0,
  DBAddRowDevice,
  DBAddRowNoDevices,
  DBAddRowPinAddress,
  DBAddRowPinCode,
  DBAddRowPinCountdown,
  DBAddRowPinStart,
  DBAddRowQrImage,
  DBAddRowScan,
  DBAddRowAddAllStatus,
  DBAddRowAddAllStart,
  DBAddRowAddAllStop,
  DBAddRowSecurity,
  DBAddRowUnpair,
} DBAddRow;

enum { DBAddAlertCode = 1, DBAddAlertAddAll, DBAddAlertUnpair };

static NSString *const kSectionKind = @"kind";
static NSString *const kSectionRows = @"rows";

@interface DBAddDeviceScreen () <UIAlertViewDelegate, UIActionSheetDelegate,
                                 UITableViewDataSource, UITableViewDelegate>
@end

@implementation DBAddDeviceScreen {
  DBNavBar *_nav;
  UITableView *_table;
  // Membership line, or the "not in a cluster" notice, above the first section.
  UIView *_headerHost;
  UILabel *_headerLabel;
  CGFloat _layoutWidth;

  // Sections on screen: dictionaries of a DBAddSection kind and its DBAddRow kinds.
  NSArray *_model;
  NSString *_modelSignature;
  NSArray *_entries;             // the Nearby rows, in order

  // Cells that hold a view of their own are built once and reused.
  UITableViewCell *_pinCell;
  UILabel *_pinLabel;
  UITableViewCell *_qrCell;
  UIImageView *_qr;
  UILabel *_qrPlaceholder;

  DBQrScanOverlay *_scanner;
  UIAlertView *_alert;
  UIActionSheet *_sheet;
  NSString *_sheetDeviceId;
  NSInteger _sheetAddIndex;
  NSString *_codePromptId;    // device the open code prompt belongs to

  NSString *_mintError;
  BOOL _minting;
  NSString *_securityNotice;  // peer_rejected / cluster_key_changed

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
  NSString *_tokenHost;
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
    _deviceStates = [[NSMutableDictionary alloc] init];
    _deviceErrors = [[NSMutableDictionary alloc] init];
    _deviceNames = [[NSMutableDictionary alloc] init];
    _addedAt = [[NSMutableDictionary alloc] init];
    _pending = @[];
    _entries = @[];
    _model = @[];
    _modelSignature = @"";
    _state = DBPairingStateUnknown;
    _lastQr = @"";
    [self buildUi];
  }
  return self;
}

- (void)dealloc {
  [_poll invalidate];
  _alert.delegate = nil;
  _sheet.delegate = nil;
  _table.dataSource = nil;
  _table.delegate = nil;
}

- (NSString *)screenName {
  return @"add_device";
}

#pragma mark - construction

- (void)buildUi {
  self.backgroundColor = DBChromeScreenBackground();
  DBChromeInstallBackdrop(self);

  _table = DBChromeGroupedTable(self, self);
  DBChromeClearTableBackground(_table);
  [self addSubview:_table];

  _nav = [[DBNavBar alloc] init];
  __weak DBAddDeviceScreen *weakSelf = self;
  [_nav setRootTitle:[_texts ts:@"pair.panel_title"]
           backTitle:[_texts ts:@"ui.back"]
              onBack:^{ [weakSelf onClose]; }];
  [self addSubview:_nav.bar];

  _headerHost = [[UIView alloc] init];
  _headerLabel = DBChromeSectionFooterLabel();
  _headerLabel.textAlignment = NSTextAlignmentCenter;
  [_headerHost addSubview:_headerLabel];

  _pinCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                    reuseIdentifier:nil];
  _pinCell.selectionStyle = UITableViewCellSelectionStyleNone;
  _pinLabel = [[UILabel alloc] initWithFrame:CGRectInset(_pinCell.contentView.bounds, 10, 4)];
  _pinLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  _pinLabel.backgroundColor = [UIColor clearColor];
  _pinLabel.font = [UIFont boldSystemFontOfSize:40];
  _pinLabel.textAlignment = NSTextAlignmentCenter;
  _pinLabel.adjustsFontSizeToFitWidth = YES;
  _pinLabel.accessibilityIdentifier = @"add_device_pin";
  [_pinCell.contentView addSubview:_pinLabel];

  _qrCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                   reuseIdentifier:nil];
  _qrCell.selectionStyle = UITableViewCellSelectionStyleNone;
  _qr = [[UIImageView alloc] init];
  _qr.contentMode = UIViewContentModeCenter;
  _qr.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  _qr.frame = _qrCell.contentView.bounds;
  [_qrCell.contentView addSubview:_qr];
  // Never an empty cell: a caption holds the place until Core publishes pair_qr.
  _qrPlaceholder = [[UILabel alloc] initWithFrame:CGRectInset(_qrCell.contentView.bounds, 10, 0)];
  _qrPlaceholder.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  _qrPlaceholder.backgroundColor = [UIColor clearColor];
  _qrPlaceholder.font = [UIFont systemFontOfSize:15];
  _qrPlaceholder.textAlignment = NSTextAlignmentCenter;
  _qrPlaceholder.numberOfLines = 0;
  _qrPlaceholder.text = [_texts ts:@"pair.qr_pending"];
  [_qrCell.contentView addSubview:_qrPlaceholder];

  [self applyContent];
}

#pragma mark - lifecycle

- (void)onScreenWillAppear {
  _confirmingUnpair = NO;
  _confirmingAddAll = NO;
  _mintError = nil;
  [self startPolling];
}

- (void)onScreenWillDisappear {
  [self stopPolling];
  // A confirmation left open must not act after another screen took over.
  _confirmingUnpair = NO;
  _confirmingAddAll = NO;
  _codePromptId = nil;
  _sheetDeviceId = nil;
  UIAlertView *alert = _alert;
  _alert = nil;
  alert.delegate = nil;
  [alert dismissWithClickedButtonIndex:alert.cancelButtonIndex animated:NO];
  UIActionSheet *sheet = _sheet;
  _sheet = nil;
  sheet.delegate = nil;
  [sheet dismissWithClickedButtonIndex:sheet.cancelButtonIndex animated:NO];
  DBQrScanOverlay *scanner = _scanner;
  _scanner = nil;
  scanner.onFinished = nil;
  [scanner dismiss];
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
  if ([host length] > 0) _tokenHost = [host copy];
  if ([pin length] > 0) _pinLabel.text = pin;
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
  // Rasterizing a QR on the A4 main thread visibly stalls the UI.
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    UIImage *image = [DBQrCode imageForString:payload targetPx:kQrSide];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBAddDeviceScreen *screen = weakSelf;
      if (!screen || ![screen->_lastQr isEqualToString:payload]) return;
      screen->_qr.image = image;
      screen->_qrPlaceholder.hidden = (image != nil);
    });
  });
}

#pragma mark - model

// The table is reloaded only when the visible set or a row state changes; the one-second
// countdown refresh rewrites the visible cells in place, so the list cannot flicker on an
// iPad 1 and an open confirmation keeps its anchor row.
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

- (BOOL)entryHasKeyConflict:(NSDictionary *)entry {
  return [DBConfigUtil evBool:entry key:@"pk_conflict"];
}

// idle | adding | added | failed. A device that answers with a different identity key for a
// known id is never invitable from here (spec v3) and reads as failed.
- (NSString *)stateForEntry:(NSDictionary *)entry {
  NSString *state = [_deviceStates objectForKey:[DBConfigUtil evStr:entry key:@"id"]] ?: @"idle";
  if ([state isEqualToString:@"idle"] && [self entryHasKeyConflict:entry]) return @"failed";
  return state;
}

- (NSString *)errorCodeForEntry:(NSDictionary *)entry {
  NSString *state = [_deviceStates objectForKey:[DBConfigUtil evStr:entry key:@"id"]] ?: @"idle";
  if (![state isEqualToString:@"added"] && ![state isEqualToString:@"adding"] &&
      [self entryHasKeyConflict:entry])
    return @"pk_conflict";
  return [_deviceErrors objectForKey:[DBConfigUtil evStr:entry key:@"id"]];
}

static NSDictionary *DBAddSectionMake(DBAddSection kind, NSArray *rows) {
  return @{ kSectionKind : @(kind), kSectionRows : rows };
}

- (NSArray *)buildModelWithEntries:(NSArray *)entries {
  if (![_state isEqualToString:@"ready"])
    return @[ DBAddSectionMake(DBAddSectionOnboarding, @[ @(DBAddRowOpenOnboarding) ]) ];

  NSMutableArray *model = [NSMutableArray array];
  NSMutableArray *nearby = [NSMutableArray array];
  for (NSUInteger i = 0; i < [entries count]; i++) [nearby addObject:@(DBAddRowDevice)];
  if ([nearby count] == 0) [nearby addObject:@(DBAddRowNoDevices)];
  [model addObject:DBAddSectionMake(DBAddSectionNearby, nearby)];

  NSMutableArray *pin = [NSMutableArray array];
  if (_token != nil) {
    [pin addObject:@(DBAddRowPinAddress)];
    [pin addObject:@(DBAddRowPinCode)];
    [pin addObject:@(DBAddRowPinCountdown)];
  }
  [pin addObject:@(DBAddRowPinStart)];
  [model addObject:DBAddSectionMake(DBAddSectionPin, pin)];

  NSMutableArray *qr = [NSMutableArray arrayWithObject:@(DBAddRowQrImage)];
  if ([DBQrScanOverlay cameraAvailable]) [qr addObject:@(DBAddRowScan)];
  [model addObject:DBAddSectionMake(DBAddSectionQr, qr)];

  [model addObject:DBAddSectionMake(DBAddSectionAddAll,
      _pairingModeActive ? @[ @(DBAddRowAddAllStatus), @(DBAddRowAddAllStop) ]
                         : @[ @(DBAddRowAddAllStart) ])];

  if ([_securityNotice length] > 0)
    [model addObject:DBAddSectionMake(DBAddSectionSecurity, @[ @(DBAddRowSecurity) ])];

  [model addObject:DBAddSectionMake(DBAddSectionUnpair, @[ @(DBAddRowUnpair) ])];
  return model;
}

- (NSString *)headerText {
  if (![_state isEqualToString:@"ready"]) return [_texts ts:@"pair.title_unpaired"];
  NSMutableArray *parts = [NSMutableArray array];
  [parts addObject:[_texts t:@"pair.membership",
                        [NSString stringWithFormat:@"%ld", (long)_memberCount], nil]];
  [parts addObject:[_texts t:@"pair.membership_connected",
                        [NSString stringWithFormat:@"%ld", (long)_connectedCount], nil]];
  if (_isFounder) [parts addObject:[_texts ts:@"pair.created_badge"]];
  return [parts componentsJoinedByString:@"  ·  "];
}

- (void)applyContent {
  NSArray *entries = [_state isEqualToString:@"ready"] ? [self visibleEntries] : @[];
  NSArray *model = [self buildModelWithEntries:entries];
  NSMutableString *signature = [NSMutableString string];
  for (NSDictionary *section in model)
    [signature appendFormat:@"%@:%lu,", [section objectForKey:kSectionKind],
                            (unsigned long)[[section objectForKey:kSectionRows] count]];
  [signature appendFormat:@"/%@/", [self signatureForEntries:entries]];
  for (NSDictionary *entry in entries)
    [signature appendString:[self entryHasKeyConflict:entry] ? @"c" : @"-"];
  [signature appendFormat:@"/%d/%@/%@", (int)_minting, _mintError ?: @"", _securityNotice ?: @""];

  _entries = entries;
  _model = model;
  NSString *header = [self headerText];
  if (![header isEqualToString:_headerLabel.text]) {
    _headerLabel.text = header;
    [self layoutHeader];
  }
  if (![signature isEqualToString:_modelSignature]) {
    _modelSignature = [signature copy];
    [_table reloadData];
    return;
  }
  for (NSIndexPath *indexPath in [_table indexPathsForVisibleRows]) {
    DBAddRow kind = [self rowKindAt:indexPath];
    if (kind != DBAddRowDevice && kind != DBAddRowPinAddress && kind != DBAddRowPinCountdown &&
        kind != DBAddRowPinStart && kind != DBAddRowAddAllStatus)
      continue;
    UITableViewCell *cell = [_table cellForRowAtIndexPath:indexPath];
    if (cell) [self configureCell:cell kind:kind atIndexPath:indexPath];
  }
}

#pragma mark - rows

- (DBAddSection)sectionKindAt:(NSInteger)section {
  return (DBAddSection)[[[_model objectAtIndex:(NSUInteger)section] objectForKey:kSectionKind]
      intValue];
}

- (DBAddRow)rowKindAt:(NSIndexPath *)indexPath {
  NSArray *rows = [[_model objectAtIndex:(NSUInteger)indexPath.section]
      objectForKey:kSectionRows];
  return (DBAddRow)[[rows objectAtIndex:(NSUInteger)indexPath.row] intValue];
}

- (NSDictionary *)entryAt:(NSIndexPath *)indexPath {
  return (NSUInteger)indexPath.row < [_entries count]
      ? [_entries objectAtIndex:(NSUInteger)indexPath.row] : nil;
}

// The width a cell's labels can use; the grouped inset differs by OS and idiom.
- (CGFloat)cellTextWidth {
  CGFloat width = _table.bounds.size.width;
  if (DBChromeIsFlat()) return width - 30;
  return width - (DBChromeIsPad() && width > 400 ? 110 : 40);
}

- (NSString *)detailForEntry:(NSDictionary *)entry {
  NSString *state = [self stateForEntry:entry];
  NSMutableArray *parts = [NSMutableArray array];
  if ([state isEqualToString:@"added"]) [parts addObject:[_texts ts:@"pair.added"]];
  if ([state isEqualToString:@"adding"]) [parts addObject:[_texts ts:@"pair.adding"]];
  NSString *role = [DBConfigUtil evStr:entry key:@"role"];
  if ([role isEqualToString:@"door_station"])
    [parts addObject:[_texts ts:@"pair.role_door_station"]];
  else if ([role isEqualToString:@"indoor_panel"])
    [parts addObject:[_texts ts:@"pair.role_indoor_panel"]];
  NSString *model = [DBConfigUtil evStr:entry key:@"model"];
  NSString *platform = [DBConfigUtil evStr:entry key:@"platform"];
  if ([model length] > 0) [parts addObject:model];
  if ([platform length] > 0) [parts addObject:platform];
  NSInteger age = [DBConfigUtil intVal:entry path:@"age_s" def:-1];
  if (age >= 0)
    [parts addObject:[_texts t:@"pair.nearby_waiting_since",
                          [NSString stringWithFormat:@"%ld", (long)age], nil]];
  NSString *detail = [parts componentsJoinedByString:@" · "];
  if ([state isEqualToString:@"failed"]) {
    NSString *failure = [NSString stringWithFormat:@"%@ — %@", [_texts ts:@"pair.add_failed"],
        [_texts ts:[DBPairingModel errorTextKeyForCode:[self errorCodeForEntry:entry]]]];
    detail = [detail length] > 0 ? [NSString stringWithFormat:@"%@\n%@", detail, failure]
                                 : failure;
  }
  return detail;
}

- (BOOL)entryOffersAdd:(NSDictionary *)entry {
  NSString *state = [self stateForEntry:entry];
  return ![state isEqualToString:@"added"] && ![state isEqualToString:@"adding"] &&
         ![self entryHasKeyConflict:entry];
}

- (NSString *)countdownText {
  NSInteger left = [self remainingTokenSeconds];
  if (left <= 0 || _tokenAttemptsLeft <= 0) return [_texts ts:@"pair.code_expired"];
  return [_texts t:@"pair.code_expires_in", [DBPairingModel countdownMinutesFromSeconds:left],
                   [DBPairingModel countdownSecondsFromSeconds:left], nil];
}

- (NSString *)attemptsText {
  if ([self remainingTokenSeconds] <= 0 || _tokenAttemptsLeft <= 0) return @"";
  return [_texts t:@"pair.code_attempts_left",
                   [NSString stringWithFormat:@"%ld", (long)_tokenAttemptsLeft], nil];
}

- (NSString *)addAllStatusText {
  NSInteger left = [self remainingPairingModeSeconds];
  return [_texts t:@"pair.add_all_on", [DBPairingModel countdownMinutesFromSeconds:left],
                   [DBPairingModel countdownSecondsFromSeconds:left],
                   [NSString stringWithFormat:@"%ld", (long)_pairingModeAdded], nil];
}

- (UIActivityIndicatorView *)spinner {
  UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
      initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
  [spinner startAnimating];
  return spinner;
}

- (void)configureActionCell:(UITableViewCell *)cell title:(NSString *)title busy:(BOOL)busy {
  cell.textLabel.text = title;
  cell.textLabel.textAlignment = NSTextAlignmentCenter;
  cell.textLabel.adjustsFontSizeToFitWidth = YES;
  cell.textLabel.enabled = !busy;
  cell.selectionStyle = busy ? UITableViewCellSelectionStyleNone
                             : UITableViewCellSelectionStyleBlue;
  if (busy && ![cell.accessoryView isKindOfClass:[UIActivityIndicatorView class]])
    cell.accessoryView = [self spinner];
  if (!busy) cell.accessoryView = nil;
}

- (void)configureCell:(UITableViewCell *)cell kind:(DBAddRow)kind
          atIndexPath:(NSIndexPath *)indexPath {
  switch (kind) {
    case DBAddRowDevice: {
      NSDictionary *entry = [self entryAt:indexPath];
      NSString *state = [self stateForEntry:entry];
      cell.textLabel.text = [DBPairingModel displayNameForDevice:entry];
      cell.detailTextLabel.text = [self detailForEntry:entry];
      cell.accessoryType = [state isEqualToString:@"added"] ? UITableViewCellAccessoryCheckmark
                                                            : UITableViewCellAccessoryNone;
      BOOL offersAdd = [self entryOffersAdd:entry];
      cell.selectionStyle = ([state isEqualToString:@"idle"] || [state isEqualToString:@"failed"])
          ? UITableViewCellSelectionStyleBlue : UITableViewCellSelectionStyleNone;
      if ([state isEqualToString:@"adding"]) {
        if (![cell.accessoryView isKindOfClass:[UIActivityIndicatorView class]])
          cell.accessoryView = [self spinner];
      } else if (offersAdd) {
        UIButton *add = [cell.accessoryView isKindOfClass:[UIButton class]]
            ? (UIButton *)cell.accessoryView : nil;
        if (!add) {
          add = DBChromeButton([_texts ts:@"pair.add"], 15);
          add.frame = CGRectMake(0, 0, kAddButtonWidth, 34);
          [add addTarget:self action:@selector(onAddDevice:)
              forControlEvents:UIControlEventTouchUpInside];
          cell.accessoryView = add;
        }
        add.tag = indexPath.row;
      } else {
        cell.accessoryView = nil;
      }
      break;
    }
    case DBAddRowNoDevices:
      cell.textLabel.text = [_texts ts:@"pair.nearby_none"];
      break;
    case DBAddRowPinAddress:
      cell.textLabel.text = [_texts ts:@"pair.address_label"];
      cell.detailTextLabel.text = _tokenHost ?: @"";
      cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
      break;
    case DBAddRowPinCountdown:
      cell.textLabel.text = [self countdownText];
      cell.textLabel.adjustsFontSizeToFitWidth = YES;
      cell.detailTextLabel.text = [self attemptsText];
      break;
    case DBAddRowPinStart:
      [self configureActionCell:cell
                          title:[_texts ts:_token ? @"pair.new_code" : @"pair.add_with_code"]
                           busy:_minting];
      break;
    case DBAddRowScan:
      [self configureActionCell:cell title:[_texts ts:@"pair.scan_qr"] busy:NO];
      cell.accessibilityIdentifier = @"add_device_scan";
      break;
    case DBAddRowAddAllStatus:
      cell.textLabel.text = [self addAllStatusText];
      cell.textLabel.adjustsFontSizeToFitWidth = YES;
      break;
    case DBAddRowAddAllStart:
      [self configureActionCell:cell title:[_texts ts:@"pair.add_all"] busy:NO];
      break;
    case DBAddRowAddAllStop:
      [self configureActionCell:cell title:[_texts ts:@"pair.add_all_stop"] busy:NO];
      break;
    case DBAddRowSecurity:
      cell.textLabel.text = _securityNotice;
      break;
    case DBAddRowUnpair:
      [self configureActionCell:cell title:[_texts ts:@"pair.clear_title"] busy:NO];
      break;
    case DBAddRowOpenOnboarding:
      [self configureActionCell:cell title:[_texts ts:@"pair.open_onboarding"] busy:NO];
      break;
    case DBAddRowPinCode:
    case DBAddRowQrImage:
      break;
  }
}

#pragma mark - table

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
  switch ([self sectionKindAt:section]) {
    case DBAddSectionNearby: return [_texts ts:@"pair.nearby_title"];
    case DBAddSectionPin: return [_texts ts:@"pair.code_label"];
    default: return nil;
  }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
  (void)tableView;
  switch ([self sectionKindAt:section]) {
    case DBAddSectionNearby:
      return [_entries count] == 0 ? [_texts ts:@"pair.searching"] : nil;
    case DBAddSectionPin: {
      NSMutableArray *lines = [NSMutableArray array];
      if (_token != nil) [lines addObject:[_texts ts:@"pair.code_instructions"]];
      if ([_mintError length] > 0) [lines addObject:_mintError];
      return [lines count] > 0 ? [lines componentsJoinedByString:@"\n"] : nil;
    }
    case DBAddSectionQr:
      // The iPad 1 has no camera: say why the scan action is missing.
      return [DBQrScanOverlay cameraAvailable]
          ? [_texts ts:@"pair.qr_caption"]
          : [NSString stringWithFormat:@"%@\n%@", [_texts ts:@"pair.qr_caption"],
                                       [_texts ts:@"pair.scan_no_camera"]];
    case DBAddSectionAddAll: return [_texts ts:@"pair.add_all_warning"];
    case DBAddSectionUnpair: return [_texts ts:@"pair.clear_resets_device"];
    default: return nil;
  }
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
  (void)tableView;
  switch ([self rowKindAt:indexPath]) {
    case DBAddRowDevice: {
      NSDictionary *entry = [self entryAt:indexPath];
      CGFloat width = [self cellTextWidth] - kAddButtonWidth - 10;
      CGSize size = [[self detailForEntry:entry] sizeWithFont:[UIFont systemFontOfSize:14]
                                            constrainedToSize:CGSizeMake(width, 9999)
                                                lineBreakMode:NSLineBreakByWordWrapping];
      return MAX(60, 10 + 22 + ceilf(size.height) + 10);
    }
    case DBAddRowSecurity: {
      CGSize size = [_securityNotice sizeWithFont:[UIFont systemFontOfSize:16]
                                constrainedToSize:CGSizeMake([self cellTextWidth], 9999)
                                    lineBreakMode:NSLineBreakByWordWrapping];
      return MAX(44, ceilf(size.height) + 24);
    }
    case DBAddRowPinCode: return 72;
    case DBAddRowQrImage: return kQrSide + 16;
    default: return 44;
  }
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  DBAddRow kind = [self rowKindAt:indexPath];
  if (kind == DBAddRowPinCode) return _pinCell;
  if (kind == DBAddRowQrImage) return _qrCell;

  NSString *identifier = @"action";
  UITableViewCellStyle style = UITableViewCellStyleDefault;
  if (kind == DBAddRowDevice) {
    identifier = @"device";
    style = UITableViewCellStyleSubtitle;
  } else if (kind == DBAddRowPinAddress || kind == DBAddRowPinCountdown) {
    identifier = @"value";
    style = UITableViewCellStyleValue1;
  } else if (kind == DBAddRowNoDevices || kind == DBAddRowAddAllStatus ||
             kind == DBAddRowSecurity) {
    identifier = @"text";
  } else if (kind == DBAddRowUnpair) {
    identifier = @"destructive";
  }
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:style reuseIdentifier:identifier];
    if (kind == DBAddRowDevice) {
      cell.detailTextLabel.numberOfLines = 0;
      cell.detailTextLabel.font = [UIFont systemFontOfSize:14];
    } else if ([identifier isEqualToString:@"text"]) {
      cell.textLabel.numberOfLines = 0;
      cell.textLabel.font = [UIFont systemFontOfSize:16];
      cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if ([identifier isEqualToString:@"value"]) {
      cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if ([identifier isEqualToString:@"destructive"]) {
      // The one coloured row: leaving the cluster erases this device's setup.
      cell.textLabel.textColor = [UIColor colorWithRed:0.80f green:0.11f blue:0.09f alpha:1];
    }
  }
  cell.accessibilityIdentifier = nil;
  [self configureCell:cell kind:kind atIndexPath:indexPath];
  return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:NO];
  switch ([self rowKindAt:indexPath]) {
    case DBAddRowDevice: [self onDeviceRow:indexPath]; break;
    case DBAddRowPinStart: if (!_minting) [self onStartCode]; break;
    case DBAddRowScan: [self onScanQr]; break;
    case DBAddRowAddAllStart: [self onAddAll]; break;
    case DBAddRowAddAllStop: [self onStopAddAll]; break;
    case DBAddRowUnpair: [self onUnpair]; break;
    case DBAddRowOpenOnboarding: [self onOpenOnboarding]; break;
    default: break;
  }
}

#pragma mark - events

- (void)handleInviteResult:(NSDictionary *)ev {
  NSString *identifier = [DBConfigUtil evStr:ev key:@"id"];
  if ([identifier length] == 0) return;
  if ([DBConfigUtil evBool:ev key:@"ok"]) {
    // Acknowledged, not joined: keep the "adding" row until device_joined confirms it.
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

- (void)handlePeerRejected:(NSDictionary *)ev {
  NSString *reason = [DBConfigUtil evStr:ev key:@"reason"] ?: @"";
  NSString *identifier = [DBConfigUtil evStr:ev key:@"id"];
  NSString *why = [_texts ts:[DBPairingModel errorTextKeyForCode:reason]];
  _securityNotice = [_texts t:@"pair.peer_rejected", why, nil];
  if ([identifier length] > 0 && [_deviceStates objectForKey:identifier] != nil) {
    [_deviceStates setObject:@"failed" forKey:identifier];
    [_deviceErrors setObject:reason forKey:identifier];
  }
  [self applyContent];
}

- (void)handleClusterKeyChanged:(NSDictionary *)ev {
  (void)ev;
  _securityNotice = [_texts ts:@"pair.cluster_key_changed"];
  [self applyContent];
  [self reload];
}

#pragma mark - actions

// A waiting device offers Add and Ignore; one that is being added or was added offers nothing.
- (void)onDeviceRow:(NSIndexPath *)indexPath {
  NSDictionary *entry = [self entryAt:indexPath];
  NSString *identifier = [DBConfigUtil evStr:entry key:@"id"];
  NSString *state = [self stateForEntry:entry];
  if ([identifier length] == 0 || _sheet != nil) return;
  if (![state isEqualToString:@"idle"] && ![state isEqualToString:@"failed"]) return;
  BOOL conflict = [self entryHasKeyConflict:entry];
  UIActionSheet *sheet = [[UIActionSheet alloc]
               initWithTitle:conflict ? [_texts ts:@"pair.pk_conflict_warning"]
                                      : [DBPairingModel displayNameForDevice:entry]
                    delegate:self
           cancelButtonTitle:nil
      destructiveButtonTitle:nil
           otherButtonTitles:nil];
  _sheetAddIndex = conflict ? -1 : [sheet addButtonWithTitle:[_texts ts:@"pair.add"]];
  sheet.destructiveButtonIndex = [sheet addButtonWithTitle:[_texts ts:@"pair.deny"]];
  sheet.cancelButtonIndex = [sheet addButtonWithTitle:[_texts ts:@"admin.cancel"]];
  _sheetDeviceId = [identifier copy];
  _sheet = sheet;
  [sheet showFromRect:[_table rectForRowAtIndexPath:indexPath] inView:_table animated:YES];
}

- (void)actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex {
  NSString *identifier = _sheetDeviceId;
  _sheetDeviceId = nil;
  _sheet = nil;
  if ([identifier length] == 0 || buttonIndex < 0) return;
  if (buttonIndex == _sheetAddIndex) {
    [self promptToAddIdentifier:identifier];
  } else if (buttonIndex == actionSheet.destructiveButtonIndex) {
    [self denyIdentifier:identifier];
  }
}

- (void)onAddDevice:(UIButton *)sender {
  NSDictionary *entry = (NSUInteger)sender.tag < [_entries count]
      ? [_entries objectAtIndex:(NSUInteger)sender.tag] : nil;
  if (!entry || ![self entryOffersAdd:entry]) return;
  [self promptToAddIdentifier:[DBConfigUtil evStr:entry key:@"id"]];
}

- (void)showAlert:(UIAlertView *)alert tag:(NSInteger)tag {
  alert.tag = tag;
  _alert = alert;
  [alert show];
}

- (void)promptToAddIdentifier:(NSString *)identifier {
  if ([identifier length] == 0 || _alert != nil) return;
  if (![DBCoreBridge supportsCodeInvite]) {
    [self inviteIdentifier:identifier code:nil];
    return;
  }
  // The eight-digit code is shown on the new device's own pairing screen.
  _codePromptId = [identifier copy];
  UIAlertView *prompt = [[UIAlertView alloc] initWithTitle:[_texts ts:@"pair.confirm_code_title"]
                                                   message:[_texts ts:@"pair.confirm_code_prompt"]
                                                  delegate:self
                                         cancelButtonTitle:[_texts ts:@"admin.cancel"]
                                         otherButtonTitles:[_texts ts:@"pair.add"], nil];
  prompt.alertViewStyle = UIAlertViewStylePlainTextInput;
  UITextField *field = [prompt textFieldAtIndex:0];
  field.keyboardType = UIKeyboardTypeNumberPad;
  field.placeholder = @"0000 0000";
  [self showAlert:prompt tag:DBAddAlertCode];
}

- (void)confirmWithTitle:(NSString *)title message:(NSString *)message
                  action:(NSString *)action tag:(NSInteger)tag {
  UIAlertView *alert = [[UIAlertView alloc] initWithTitle:title
                                                  message:message
                                                 delegate:self
                                        cancelButtonTitle:[_texts ts:@"admin.cancel"]
                                        otherButtonTitles:action, nil];
  [self showAlert:alert tag:tag];
}

- (void)inviteIdentifier:(NSString *)identifier code:(NSString *)code {
  [_deviceStates setObject:@"adding" forKey:identifier];
  [_deviceErrors removeObjectForKey:identifier];
  [self applyContent];
  if (code != nil) [_core inviteDevice:identifier code:code];
  else [_core inviteDevice:identifier];
}

- (BOOL)alertViewShouldEnableFirstOtherButton:(UIAlertView *)alertView {
  if (alertView.tag != DBAddAlertCode) return YES;
  return [[self digitsOf:[[alertView textFieldAtIndex:0] text]] length] == 8;
}

- (NSString *)digitsOf:(NSString *)text {
  NSMutableString *out = [NSMutableString string];
  for (NSUInteger i = 0; i < [text length]; i++) {
    unichar c = [text characterAtIndex:i];
    if (c >= '0' && c <= '9') [out appendFormat:@"%C", c];
  }
  return out;
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
  if (alertView != _alert) return;
  _alert = nil;
  BOOL confirmed = buttonIndex != alertView.cancelButtonIndex;
  if (alertView.tag == DBAddAlertAddAll) {
    if (confirmed) [self onAddAll];
    else _confirmingAddAll = NO;
    return;
  }
  if (alertView.tag == DBAddAlertUnpair) {
    if (confirmed) [self onUnpair];
    else _confirmingUnpair = NO;
    return;
  }
  NSString *identifier = _codePromptId;
  _codePromptId = nil;
  if (!confirmed || [identifier length] == 0) return;
  NSString *code = [self digitsOf:[[alertView textFieldAtIndex:0] text]];
  if ([code length] != 8) {
    [_deviceStates setObject:@"failed" forKey:identifier];
    [_deviceErrors setObject:@"confirm_code_required" forKey:identifier];
    [self applyContent];
    return;
  }
  [self inviteIdentifier:identifier code:code];
}

- (void)denyIdentifier:(NSString *)identifier {
  [_deviceStates removeObjectForKey:identifier];
  [_deviceErrors removeObjectForKey:identifier];
  [_addedAt removeObjectForKey:identifier];
  [_core denyDevice:identifier];
  [self reload];
}

- (void)onScanQr {
  if (_scanner) return;
  DBQrScanOverlay *scanner = [[DBQrScanOverlay alloc] initWithCore:_core texts:_texts];
  __weak DBAddDeviceScreen *weakSelf = self;
  scanner.onFinished = ^(NSString *invitedId, NSString *invitedAddr) {
    DBAddDeviceScreen *screen = weakSelf;
    if (!screen) return;
    screen->_scanner = nil;
    if ([invitedId length] == 0) return;
    // Core already sent the invite. Show the device as "adding" until device_joined arrives,
    // the same row a code-confirmed invite gets; its address names it until then.
    [screen->_deviceStates setObject:@"adding" forKey:invitedId];
    [screen->_deviceErrors removeObjectForKey:invitedId];
    if ([invitedAddr length] > 0 && ![screen->_deviceNames objectForKey:invitedId])
      [screen->_deviceNames setObject:invitedAddr forKey:invitedId];
    [screen->_addedAt setObject:[NSNumber numberWithDouble:CFAbsoluteTimeGetCurrent()]
                         forKey:invitedId];
    [screen applyContent];
  };
  _scanner = scanner;
  [scanner presentInView:self];
}

- (void)openScannerForDebug {
  [self onScanQr];
}

- (void)handleQrScanned:(NSDictionary *)ev {
  [_scanner handleQrScanned:ev];
}

- (void)handleQrScanState:(NSDictionary *)ev {
  [_scanner handleQrScanState:ev];
}

- (void)onStartCode {
  _mintError = nil;
  _minting = YES;
  [self applyContent];
  DBCoreBridge *core = _core;
  __weak DBAddDeviceScreen *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    // Minting the Pairing PIN must never open the bulk-add window (spec §5.4): that window
    // is opened only by its own row, with its warning. An older Core without the mint export
    // leaves the section empty and says why instead of silently opening the window.
    NSDictionary *token = [core mintJoinTokenWithSeconds:600];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBAddDeviceScreen *screen = weakSelf;
      if (!screen) return;
      screen->_minting = NO;
      if ([token isKindOfClass:[NSDictionary class]] &&
          [DBConfigUtil evBool:token key:@"ok"]) {
        [screen adoptToken:token];
        if (screen->_tokenExpiresS <= 0) screen->_tokenExpiresS = 600;
        if (screen->_tokenAttemptsLeft <= 0) screen->_tokenAttemptsLeft = 3;
      } else if (![DBCoreBridge supportsJoinTokenMinting]) {
        screen->_mintError = [screen->_texts ts:@"pair.mint_unsupported"];
      } else {
        NSString *code = [DBConfigUtil evStr:token key:@"err"];
        screen->_mintError = [screen->_texts ts:[DBPairingModel errorTextKeyForCode:code]];
      }
      [screen applyContent];
    });
  });
}

- (void)onAddAll {
  if (_pairingModeActive) return;
  if (!_confirmingAddAll) {
    if (_alert != nil) return;
    _confirmingAddAll = YES;
    [self confirmWithTitle:[_texts ts:@"pair.add_all"]
                   message:[_texts ts:@"pair.add_all_warning"]
                    action:[_texts ts:@"editor.confirm"]
                       tag:DBAddAlertAddAll];
    return;
  }
  _confirmingAddAll = NO;
  _pairingModeActive = YES;
  _pairingModeLeftS = 600;
  _pairingModeAdded = 0;
  _pairingModeReadAt = CFAbsoluteTimeGetCurrent();
  // Bulk add is the only caller that opens the pairing window.
  (void)[_core startPairingWithSeconds:600];
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
    if (_alert != nil) return;
    _confirmingUnpair = YES;
    [self confirmWithTitle:[_texts ts:@"pair.clear_title"]
                   message:[_texts ts:@"pair.clear_confirm"]
                    action:[_texts ts:@"editor.remove_device"]
                       tag:DBAddAlertUnpair];
    return;
  }
  _confirmingUnpair = NO;
  // Leaving the cluster, confirmed on the device itself, is a factory reset of its cluster
  // identity and its setup, exactly like a remote revocation (spec §5.4). The router owns
  // the wipe and the return to first-run setup.
  _state = @"unpaired";
  [self applyContent];
  [_router closeAddDeviceAnimated:NO];
  [_router factoryResetForRevocation:@"admin_unpair"];
}

- (void)onOpenOnboarding {
  [_router closeAddDeviceAnimated:NO];
  [_router showPairing];
}

- (void)onClose {
  [_router closeAddDeviceAnimated:YES];
}

#pragma mark - layout

// Sizes the header for the table width and hands it back to the table, which is how a table
// learns that its header height changed.
- (void)layoutHeader {
  CGFloat width = _table.bounds.size.width;
  if (width <= 0) return;
  CGFloat textHeight = ceilf([_headerLabel sizeThatFits:CGSizeMake(width - 40, 9999)].height);
  _headerLabel.frame = CGRectMake(20, 14, width - 40, textHeight);
  _headerHost.frame = CGRectMake(0, 0, width, textHeight + 18);
  _table.tableHeaderView = _headerHost;
}

- (void)layoutSubviews {
  [super layoutSubviews];
  CGRect bounds = self.bounds;
  CGFloat top = [_nav layoutInBounds:bounds];
  CGFloat width = MIN(kColumnMax, bounds.size.width);
  _table.frame = CGRectMake(floorf((bounds.size.width - width) / 2), top, width,
                            bounds.size.height - top);
  if (_layoutWidth != width) {
    _layoutWidth = width;
    [self layoutHeader];
    // Row heights depend on the table width.
    [_table reloadData];
  }
}

@end
