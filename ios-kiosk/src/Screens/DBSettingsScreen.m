#import "DBSettingsScreen.h"

#import "../Core/DBBootConfig.h"
#import "../Core/DBConfigUtil.h"
#import "../Core/DBIconAsset.h"
#import "../Core/DBCoreBridge.h"
#import "../Core/DBNoticeModel.h"
#import "../Core/DBPurposeModel.h"
#import "../Core/DBTexts.h"
#import "../Core/DBUiTheme.h"
#import "../Support/DBSafeModeRecovery.h"
#import "DBNoticeDialog.h"
#import "DBNumericKeypad.h"
#import "DBRouter.h"
#import "DBWidgets.h"

// One settings row. `action` names what a tap does; `webOnly` marks the items
// the owner deliberately kept in the web admin (spec §3), which show their
// current value plus the reason instead of pretending to be editable.
@interface DBSettingsRow : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *value;
@property(nonatomic, copy) NSString *action;
@property(nonatomic, copy) NSString *argument;
@property(nonatomic, assign) BOOL webOnly;
@property(nonatomic, assign) BOOL destructive;
// [[value, label], ...] for "segment" and "choose" rows; `value` holds the label.
@property(nonatomic, copy) NSArray *choices;
@end

@implementation DBSettingsRow
@synthesize choices = _choices;
@synthesize title = _title, value = _value, action = _action, argument = _argument,
            webOnly = _webOnly, destructive = _destructive;
@end

static DBSettingsRow *DBRow(NSString *title, NSString *value, NSString *action,
                            NSString *argument) {
  DBSettingsRow *row = [[DBSettingsRow alloc] init];
  row.title = title;
  row.value = value ?: @"";
  row.action = action ?: @"";
  row.argument = argument ?: @"";
  return row;
}

// Core validates the zone against its own bundled table and rejects anything
// else, so this list only has to cover the zones an installation is likely to
// pick; the search field accepts any identifier the operator types.
static NSArray *DBCommonTimeZones(void) {
  return [NSArray arrayWithObjects:
      @"Asia/Tokyo", @"Asia/Seoul", @"Asia/Shanghai", @"Asia/Taipei", @"Asia/Hong_Kong",
      @"Asia/Singapore", @"Asia/Bangkok", @"Asia/Jakarta", @"Asia/Manila",
      @"Asia/Kolkata", @"Asia/Dubai", @"Europe/London", @"Europe/Paris", @"Europe/Berlin",
      @"Europe/Madrid", @"Europe/Rome", @"Europe/Amsterdam", @"Europe/Moscow",
      @"America/New_York", @"America/Chicago", @"America/Denver", @"America/Los_Angeles",
      @"America/Sao_Paulo", @"Australia/Sydney", @"Australia/Perth", @"Pacific/Auckland",
      @"Pacific/Honolulu", @"UTC", nil];
}

@interface DBSettingsCell : UITableViewCell
@property(nonatomic, assign) BOOL firstRow;
@property(nonatomic, assign) BOOL lastRow;
@property(nonatomic, strong) UIView *rowSeparator;
+ (CGFloat)heightForTitle:(NSString *)title value:(NSString *)value width:(CGFloat)width;
@end

@implementation DBSettingsCell
+ (CGFloat)heightForTitle:(NSString *)title value:(NSString *)value width:(CGFloat)width {
  BOOL hasValue = [value length] > 0;
  CGFloat available = MAX(120, width - 64);
  CGFloat titleWidth = hasValue ? available * 0.43 : available;
  CGFloat valueWidth = available * 0.57 - 16;
  CGFloat titleHeight = [title sizeWithFont:[UIFont systemFontOfSize:17]
      constrainedToSize:CGSizeMake(titleWidth, CGFLOAT_MAX)
      lineBreakMode:NSLineBreakByWordWrapping].height;
  CGFloat valueHeight = [value sizeWithFont:[UIFont systemFontOfSize:15]
      constrainedToSize:CGSizeMake(valueWidth, CGFLOAT_MAX)
      lineBreakMode:NSLineBreakByWordWrapping].height;
  return MAX(52, ceil(MAX(titleHeight, valueHeight)) + 24);
}

- (void)layoutSubviews {
  [super layoutSubviews];
  BOOL hasValue = [self.detailTextLabel.text length] > 0;
  // A switch, stepper or segmented control sits at the trailing edge; the
  // labels share what is left.
  CGFloat control = self.accessoryView && CGRectGetWidth(self.accessoryView.bounds) > 20
      ? CGRectGetWidth(self.accessoryView.bounds) + 12 : 0;
  CGFloat available = MAX(120, CGRectGetWidth(self.bounds) - 64 - control);
  CGFloat titleWidth = hasValue ? available * 0.43 : available;
  CGFloat valueWidth = available * 0.57 - 16;
  CGFloat titleHeight = ceil([self.textLabel sizeThatFits:CGSizeMake(titleWidth, CGFLOAT_MAX)].height);
  CGFloat valueHeight = ceil([self.detailTextLabel sizeThatFits:CGSizeMake(valueWidth, CGFLOAT_MAX)].height);
  CGFloat height = CGRectGetHeight(self.bounds);
  self.textLabel.frame = CGRectMake(16, floor((height - titleHeight) / 2), titleWidth, titleHeight);
  self.detailTextLabel.hidden = !hasValue;
  self.detailTextLabel.frame = CGRectMake(32 + titleWidth, floor((height - valueHeight) / 2),
                                         valueWidth, valueHeight);
  self.backgroundView.frame = self.bounds;
  self.selectedBackgroundView.frame = self.bounds;
  UIRectCorner corners = 0;
  if (_firstRow) corners |= UIRectCornerTopLeft | UIRectCornerTopRight;
  if (_lastRow) corners |= UIRectCornerBottomLeft | UIRectCornerBottomRight;
  for (UIView *background in @[self.backgroundView, self.selectedBackgroundView]) {
    CAShapeLayer *mask = [CAShapeLayer layer];
    mask.frame = background.bounds;
    mask.path = [UIBezierPath bezierPathWithRoundedRect:background.bounds byRoundingCorners:corners
        cornerRadii:CGSizeMake(10, 10)].CGPath;
    background.layer.mask = mask;
  }
  if (self.accessoryView) {
    CGSize own = self.accessoryView.bounds.size;
    CGRect frame = control > 0
        ? CGRectMake(CGRectGetWidth(self.bounds) - 16 - own.width, floor((height - own.height) / 2),
                     own.width, own.height)
        : CGRectMake(CGRectGetWidth(self.bounds) - 28, (height - 20) / 2, 12, 20);
    self.accessoryView.frame = [self convertRect:frame toView:self.accessoryView.superview];
  }
  _rowSeparator.hidden = _lastRow;
  _rowSeparator.frame = CGRectMake(16, height - 0.5, CGRectGetWidth(self.bounds) - 16, 0.5);
}
@end

@interface DBVolumeSlider : UISlider
@property(nonatomic, copy) void (^onBegin)(void);
@property(nonatomic, copy) void (^onEnd)(float);
@property(nonatomic, copy) void (^onCancel)(void);
@end

@implementation DBVolumeSlider
- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
  if (_onBegin) _onBegin();
  BOOL result = [super beginTrackingWithTouch:touch withEvent:event];
  if (!result && _onCancel) _onCancel();
  return result;
}
- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
  [super endTrackingWithTouch:touch withEvent:event];
  if (_onEnd) _onEnd(self.value);
}
- (void)cancelTrackingWithEvent:(UIEvent *)event {
  [super cancelTrackingWithEvent:event];
  if (_onCancel) _onCancel();
}
@end

@interface DBVolumeSettingsCell : DBSettingsCell
@property(nonatomic, strong) UISlider *slider;
@property(nonatomic, copy) void (^onCommit)(NSInteger value);
@property(nonatomic, assign) float savedValue;
@property(nonatomic, assign) BOOL editingVolume;
@property(nonatomic, assign) NSInteger pendingVolume;
@end

@implementation DBVolumeSettingsCell
- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
  self = [super initWithStyle:style reuseIdentifier:identifier];
  if (self) {
    DBVolumeSlider *slider = [[DBVolumeSlider alloc] init];
    _slider = slider;
    _slider.minimumValue = 0;
    _slider.maximumValue = 100;
    _slider.continuous = YES;
    [_slider addTarget:self action:@selector(sliderChanged:)
        forControlEvents:UIControlEventValueChanged];
    __weak DBVolumeSettingsCell *weakSelf = self;
    slider.onBegin = ^{ [weakSelf beginVolume]; };
    slider.onEnd = ^(float value) {
      weakSelf.pendingVolume = (NSInteger)(value + 0.5);
      [weakSelf commitVolume];
    };
    slider.onCancel = ^{ [weakSelf cancelVolume]; };
    [self.contentView addSubview:_slider];
  }
  return self;
}

- (void)sliderChanged:(UISlider *)slider {
  _pendingVolume = (NSInteger)(slider.value + 0.5);
  [self updateVolumeLabel];
}

- (void)beginVolume {
  _editingVolume = YES;
  _pendingVolume = (NSInteger)(_slider.value + 0.5);
}

- (void)updateVolumeLabel {
  self.detailTextLabel.text = [NSString stringWithFormat:@"%ld", (long)(_slider.value + 0.5)];
}

- (void)commitVolume {
  NSInteger value = _pendingVolume;
  _editingVolume = NO;
  _slider.value = value;
  NSLog(@"[doorbell] volume slider committed %ld", (long)value);
  if (_onCommit) _onCommit(value);
}

- (void)cancelVolume {
  NSLog(@"[doorbell] volume slider cancelled at %ld", (long)_pendingVolume);
  _editingVolume = NO;
  _slider.value = _savedValue;
  [self updateVolumeLabel];
}

- (void)layoutSubviews {
  [super layoutSubviews];
  CGFloat width = CGRectGetWidth(self.bounds);
  CGFloat height = CGRectGetHeight(self.bounds);
  self.textLabel.frame = CGRectMake(16, (height - 24) / 2, 120, 24);
  _slider.frame = CGRectMake(150, (height - 44) / 2, MAX(80, width - 230), 44);
  self.detailTextLabel.frame = CGRectMake(width - 64, (height - 24) / 2, 48, 24);
}
@end

static const NSInteger kDBRotateKeyAlertTag = 701;

@interface DBSettingsScreen () <UITableViewDataSource, UITableViewDelegate,
                                UITextFieldDelegate, UIAlertViewDelegate,
                                UIActionSheetDelegate>
@end

@implementation DBSettingsScreen {
  DBCoreBridge *_core;
  DBBootConfig *_boot;
  DBTexts *_texts;
  DBUiPalette *_palette;
  DBNoticeDialog *_noticeDialog;

  NSDictionary *_cfg;
  NSDictionary *_status;
  NSDictionary *_audio;
  NSDictionary *_localTime;
  NSString *_nodeId;
  NSArray *_sections;  // [{title, rows:[DBSettingsRow]}]
  dispatch_queue_t _volumeWriteQueue;
  NSMutableDictionary *_volumeWriteGenerations;
  NSMutableDictionary *_pendingVolumeValues;
  NSInteger _loadGeneration;
  NSTimer *_clockTimer;
  NSUInteger _clockGeneration;
  BOOL _clockReadPending;
  BOOL _screenVisible;

  UILabel *_title;
  UIButton *_close;
  UITableView *_table;
  // Two panes, as in Settings on a larger iPad: categories left, the chosen
  // category's rows right. Only one category is ever built into cells, which
  // keeps the A4 from laying out ~60 rows at once.
  UITableView *_categoryTable;
  NSString *_selectedId;
  NSInteger _selectedSection;
  NSDictionary *_pairing;
  CGFloat _footerWidth;
  UIView *_footerContainer;
  UIView *_adminFooter;
  DBAdminQrView *_qr;
  UILabel *_toast;
  NSUInteger _toastGeneration;

  // Editors keep numeric fields above the system keyboard.
  CGFloat _numberKeyboardHeight;
  UIView *_keypadOverlay;
  UILabel *_keypadTitle;
  DBNumericKeypad *_keypad;
  NSString *_pendingNumberKey;
  NSInteger _pendingNumberMin;
  NSInteger _pendingNumberMax;

  UIView *_pickerOverlay;
  UITextField *_pickerSearch;
  UITableView *_pickerTable;
  UIButton *_pickerCancel;
  NSArray *_pickerAll;
  NSArray *_pickerFiltered;
  NSString *_pickerKey;
  DBSettingsRow *_pendingChoiceRow;
}

- (id)initWithRouter:(DBRouter *)router {
  self = [super initWithFrame:[UIScreen mainScreen].bounds];
  if (self) {
    _router = router;
    _core = router.core;
    _boot = router.boot;
    _texts = router.texts;
    _nodeId = @"";
    _sections = [NSArray array];
    [self buildUi];
  }
  return self;
}

- (NSString *)screenName {
  return @"settings";
}

- (void)buildUi {
  _title = [[UILabel alloc] init];
  _title.backgroundColor = [UIColor clearColor];
  _title.font = [UIFont boldSystemFontOfSize:20];
  _title.textAlignment = NSTextAlignmentCenter;
  [self addSubview:_title];

  _close = [UIButton buttonWithType:UIButtonTypeCustom];
  _close.titleLabel.font = [UIFont systemFontOfSize:17];
  _close.layer.cornerRadius = 8;
  _close.clipsToBounds = YES;
  [_close addTarget:self action:@selector(onClose) forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_close];

  _categoryTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
  _categoryTable.dataSource = self;
  _categoryTable.delegate = self;
  _categoryTable.rowHeight = 56;
  _categoryTable.separatorStyle = UITableViewCellSeparatorStyleNone;
  _categoryTable.backgroundView = [[UIView alloc] init];
  _categoryTable.backgroundView.backgroundColor = [UIColor clearColor];
  _categoryTable.accessibilityIdentifier = @"settings_categories";
  [self addSubview:_categoryTable];

  _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
  _table.dataSource = self;
  _table.delegate = self;
  _table.separatorStyle = UITableViewCellSeparatorStyleNone;
  _table.backgroundView = [[UIView alloc] init];
  _table.backgroundView.backgroundColor = [UIColor clearColor];
  [self addSubview:_table];

  _qr = [[DBAdminQrView alloc] initWithFrame:CGRectZero];
  _adminFooter = [[UIView alloc] init];
  [_adminFooter addSubview:_qr];
  _footerContainer = [[UIView alloc] init];
  [_footerContainer addSubview:_adminFooter];
  _table.tableFooterView = _footerContainer;

  _toast = [[UILabel alloc] init];
  _toast.backgroundColor = [UIColor clearColor];
  _toast.font = [UIFont systemFontOfSize:12];
  _toast.numberOfLines = 1;
  _toast.adjustsFontSizeToFitWidth = YES;
  _toast.minimumFontSize = 11;
  _toast.textAlignment = NSTextAlignmentCenter;
  [self addSubview:_toast];

  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(numberKeyboardChanged:)
      name:UIKeyboardWillChangeFrameNotification object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(numberKeyboardChanged:)
      name:UIKeyboardWillHideNotification object:nil];
  _keypadOverlay = [[UIView alloc] init];
  _keypadOverlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.86];
  _keypadOverlay.hidden = YES;
  [self addSubview:_keypadOverlay];
  _keypadTitle = [[UILabel alloc] init];
  _keypadTitle.backgroundColor = [UIColor clearColor];
  _keypadTitle.textColor = [UIColor whiteColor];
  _keypadTitle.textAlignment = NSTextAlignmentCenter;
  _keypadTitle.font = [UIFont boldSystemFontOfSize:22];
  [_keypadOverlay addSubview:_keypadTitle];
  _keypad = [[DBNumericKeypad alloc] initWithSubmitTitle:@""];
  _keypad.maxLength = 5;
  __weak DBSettingsScreen *weakSelf = self;
  _keypad.onSubmit = ^(NSString *value) {
    DBSettingsScreen *screen = weakSelf;
    if (screen) [screen commitPendingNumber:value];
  };
  _keypad.onCancel = ^{
    DBSettingsScreen *screen = weakSelf;
    if (screen) screen->_keypadOverlay.hidden = YES;
  };
  [_keypadOverlay addSubview:_keypad];

  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(clockDidEnterBackground:)
      name:UIApplicationDidEnterBackgroundNotification object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(clockDidBecomeActive:)
      name:UIApplicationDidBecomeActiveNotification object:nil];

  _pickerOverlay = [[UIView alloc] init];
  _pickerOverlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.9];
  _pickerOverlay.hidden = YES;
  [self addSubview:_pickerOverlay];
  _pickerSearch = [[UITextField alloc] init];
  _pickerSearch.borderStyle = UITextBorderStyleRoundedRect;
  _pickerSearch.backgroundColor = [UIColor whiteColor];
  _pickerSearch.textColor = [UIColor colorWithWhite:0.12 alpha:1];
  _pickerSearch.font = [UIFont systemFontOfSize:19];
  _pickerSearch.autocorrectionType = UITextAutocorrectionTypeNo;
  _pickerSearch.autocapitalizationType = UITextAutocapitalizationTypeNone;
  _pickerSearch.returnKeyType = UIReturnKeyDone;
  _pickerSearch.delegate = self;
  [_pickerSearch addTarget:self action:@selector(onPickerSearchChanged)
          forControlEvents:UIControlEventEditingChanged];
  [_pickerOverlay addSubview:_pickerSearch];
  _pickerTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
  _pickerTable.dataSource = self;
  _pickerTable.delegate = self;
  _pickerTable.rowHeight = 54;
  [_pickerOverlay addSubview:_pickerTable];
  _pickerCancel = [UIButton buttonWithType:UIButtonTypeCustom];
  _pickerCancel.titleLabel.font = [UIFont boldSystemFontOfSize:18];
  _pickerCancel.layer.cornerRadius = 8;
  _pickerCancel.clipsToBounds = YES;
  [_pickerCancel addTarget:self action:@selector(onPickerCancel)
          forControlEvents:UIControlEventTouchUpInside];
  [_pickerOverlay addSubview:_pickerCancel];
}

- (void)onScreenWillAppear {
  _screenVisible = YES;
  [self reload];
  [self startClockUpdates];
}

- (void)onScreenWillDisappear {
  _screenVisible = NO;
  [self stopClockUpdates];
  [_noticeDialog dismiss];
}

- (void)startClockUpdates {
  if (!_screenVisible || _clockTimer ||
      [UIApplication sharedApplication].applicationState == UIApplicationStateBackground) return;
  _clockGeneration++;
  _clockReadPending = NO;
  _clockTimer = [NSTimer timerWithTimeInterval:1 target:self selector:@selector(refreshClock:)
      userInfo:nil repeats:YES];
  [[NSRunLoop mainRunLoop] addTimer:_clockTimer forMode:NSRunLoopCommonModes];
  [self refreshClock:nil];
}

- (void)stopClockUpdates {
  [_clockTimer invalidate];
  _clockTimer = nil;
  _clockGeneration++;
  _clockReadPending = NO;
}

- (void)refreshClock:(NSTimer *)timer {
  if (!_screenVisible || !_clockTimer || _clockReadPending) return;
  _clockReadPending = YES;
  NSUInteger generation = _clockGeneration;
  DBCoreBridge *core = _core;
  __weak DBSettingsScreen *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSDictionary *localTime = [core localTimeJson:0];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBSettingsScreen *screen = weakSelf;
      if (!screen || !screen->_screenVisible || screen->_clockGeneration != generation) return;
      screen->_clockReadPending = NO;
      screen->_localTime = localTime;
      NSString *iso = [DBConfigUtil str:localTime path:@"iso"];
      if ([iso length] == 0) return;
      NSArray *rows = [screen selectedRows];
      for (NSUInteger index = 0; index < [rows count]; index++) {
        DBSettingsRow *row = [rows objectAtIndex:index];
        if (![row.argument isEqualToString:@"local_clock"]) continue;
        row.value = iso;
        NSIndexPath *path = [NSIndexPath indexPathForRow:index inSection:0];
        UITableViewCell *cell = [screen->_table cellForRowAtIndexPath:path];
        cell.detailTextLabel.text = iso;
        [cell setNeedsLayout];
      }
    });
  });
}

- (void)clockDidEnterBackground:(NSNotification *)notification {
  [self stopClockUpdates];
}

- (void)clockDidBecomeActive:(NSNotification *)notification {
  [self startClockUpdates];
}

- (void)dealloc {
  [_clockTimer invalidate];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)reload {
  for (UITableViewCell *cell in [_table visibleCells]) {
    if ([cell isKindOfClass:[DBVolumeSettingsCell class]] &&
        ((DBVolumeSettingsCell *)cell).editingVolume) return;
  }
  NSInteger generation = ++_loadGeneration;
  DBCoreBridge *core = _core;
  __weak DBSettingsScreen *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSDictionary *cfg = [core config];
    NSDictionary *status = [core status];
    NSString *nodeId = [DBConfigUtil str:status path:@"node.id"] ?: @"";
    NSDictionary *audio = [core audioJsonForDevice:nodeId];
    NSDictionary *localTime = [core localTimeJson:0];
    NSDictionary *pairing = [core pairingInfo];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBSettingsScreen *screen = weakSelf;
      if (!screen || screen->_loadGeneration != generation) return;
      screen->_pairing = pairing;
      screen->_cfg = cfg;
      screen->_status = status;
      screen->_nodeId = nodeId;
      screen->_audio = audio;
      screen->_localTime = localTime;
      [screen->_texts setConfig:cfg];
      [screen->_texts setLang:screen->_boot.uiLang];
      [screen applyPalette];
      [screen rebuildSections];
    });
  });
}

- (NSInteger)minuteOfDay {
  NSInteger hh = [DBConfigUtil intVal:_localTime path:@"hh" def:-1];
  if (hh < 0) return 12 * 60;
  return hh * 60 + [DBConfigUtil intVal:_localTime path:@"mm" def:0];
}

- (void)applyPalette {
  _palette = [DBUiPalette paletteForConfig:_cfg deviceId:_nodeId
                                   display:[DBConfigUtil dig:_status path:@"display"]
                             backgroundHex:nil minuteOfDay:[self minuteOfDay]];
  self.backgroundColor = _palette.surface;
  _title.textColor = _palette.ink;
  _toast.textColor = _palette.mutedInk;
  _close.backgroundColor = [_palette plate];
  _close.layer.borderWidth = 1;
  _close.layer.borderColor = _palette.separator.CGColor;
  [_close setTitleColor:_palette.ink forState:UIControlStateNormal];
  _table.backgroundColor = _palette.surface;
  _categoryTable.backgroundColor = _palette.surface;
  _table.separatorColor = _palette.separator;
  _adminFooter.backgroundColor = [_palette plate];
  _adminFooter.layer.cornerRadius = 12;
  [_qr applyPalette:_palette];
}

- (NSString *)adminUrl {
  NSString *host = nil;
  id addrs = [DBConfigUtil dig:_status path:@"node.local_addrs"];
  if ([addrs isKindOfClass:[NSArray class]]) {
    for (id candidate in (NSArray *)addrs) {
      if (![candidate isKindOfClass:[NSString class]]) continue;
      if ([(NSString *)candidate rangeOfString:@":"].location != NSNotFound) continue;
      host = candidate;
      break;
    }
  }
  if ([host length] == 0) host = @"127.0.0.1";
  // Security protocol v3: the admin is served over HTTPS on 47443 only.
  return [NSString stringWithFormat:@"https://%@:47443/admin/", [DBConfigUtil urlHost:host]];
}

#pragma mark - sections

- (NSDictionary *)section:(NSString *)titleKey rows:(NSArray *)rows {
  return [self section:titleKey rows:rows icon:@"settings" tint:@"#8E8E93"];
}

// `tint` is the icon tile colour, as on iOS Settings; the glyph is always white.
- (NSDictionary *)section:(NSString *)titleKey rows:(NSArray *)rows icon:(NSString *)icon
                     tint:(NSString *)tint {
  return [NSDictionary dictionaryWithObjectsAndKeys:
      [_texts ts:titleKey], @"title", rows, @"rows", titleKey, @"id", icon, @"icon",
      tint, @"tint", nil];
}

- (DBSettingsRow *)toggleRow:(NSString *)title key:(NSString *)key def:(BOOL)def {
  BOOL on = [DBConfigUtil boolVal:_cfg path:key def:def];
  return DBRow(title, @"", @"toggle", [NSString stringWithFormat:@"%@|%d", key, on ? 1 : 0]);
}

- (DBSettingsRow *)stepperRow:(NSString *)title key:(NSString *)key def:(NSInteger)def
                          min:(NSInteger)min max:(NSInteger)max step:(NSInteger)step
                         unit:(NSString *)unit {
  NSInteger value = [DBConfigUtil intVal:_cfg path:key def:def];
  value = MAX(min, MIN(max, value));
  NSString *shown = [unit length] > 0 ? [NSString stringWithFormat:@"%ld %@", (long)value, unit]
                                      : [NSString stringWithFormat:@"%ld", (long)value];
  return DBRow(title, shown, @"stepper",
               [NSString stringWithFormat:@"%@|%ld|%ld|%ld|%ld", key, (long)min, (long)max,
                                          (long)step, (long)value]);
}

// choices: [[value, label], ...]. Up to three fit a segmented control; more
// open an action sheet.
- (DBSettingsRow *)choiceRow:(NSString *)title key:(NSString *)key def:(NSString *)def
                     choices:(NSArray *)choices {
  NSString *current = [DBConfigUtil str:_cfg path:key] ?: def;
  NSString *label = current;
  for (NSArray *choice in choices)
    if ([[choice objectAtIndex:0] isEqualToString:current]) label = [choice objectAtIndex:1];
  DBSettingsRow *row = DBRow(title, label, ([choices count] <= 3 ? @"segment" : @"choose"),
                             [NSString stringWithFormat:@"%@|%@", key, current]);
  row.choices = choices;
  return row;
}

- (NSArray *)soundChoices:(NSArray *)ids none:(BOOL)none {
  NSMutableArray *out = [NSMutableArray array];
  if (none) [out addObject:@[ @"", [_texts ts:@"prefs.sound_none"] ]];
  for (NSString *sound in ids)
    [out addObject:@[ sound, [_texts ts:[@"prefs.sound_" stringByAppendingString:sound]] ]];
  return out;
}

- (DBSettingsRow *)webOnlyRow:(NSString *)title value:(NSString *)value {
  DBSettingsRow *row = DBRow(title, value, @"web", nil);
  row.webOnly = YES;
  return row;
}

- (NSString *)roleLabel {
  return [_texts ts:([_boot.role isEqualToString:@"door_station"] ? @"settings.role_door"
                                                                 : @"settings.role_indoor")];
}

- (NSArray *)deviceRows {
  NSMutableArray *rows = [NSMutableArray array];
  NSString *name = [DBConfigUtil str:_cfg path:[NSString stringWithFormat:
      @"devices.%@.name", _nodeId]] ?: _boot.name;
  [rows addObject:DBRow([_texts ts:@"settings.device_name"], name, @"device_name", nil)];
  [rows addObject:DBRow([_texts ts:@"settings.device_role"], [self roleLabel], @"", nil)];
  if ([_boot.door length] > 0)
    [rows addObject:DBRow([_texts ts:@"settings.device_door"], _boot.door, @"", nil)];
  [rows addObject:DBRow([_texts ts:@"settings.ui_lang"],
                        [DBTexts langDisplayName:_boot.uiLang], @"ui_lang", nil)];
  [rows addObject:DBRow([_texts ts:@"settings.helper_mode"],
                        _boot.keepaliveHelperPolicy ?: @"off", @"helper_mode", nil)];
  NSString *configured = [DBConfigUtil str:_cfg path:@"display.appearance"] ?: @"auto_system";
  NSString *effective = [DBUiTheme appearanceModeForConfig:_cfg deviceId:_nodeId
                                                   display:[DBConfigUtil dig:_status
                                                                       path:@"display"]
                                               minuteOfDay:[self minuteOfDay]];
  [rows addObject:DBRow([_texts ts:@"theme.appearance"],
                        [self appearanceLabel:configured effective:effective],
                        @"cycle",
                        @"display.appearance|auto_schedule,light,dark")];
  if ([_nodeId length] > 0) {
    NSString *local = [NSString stringWithFormat:@"devices.%@.local.video", _nodeId];
    [rows addObject:[self choiceRow:[_texts ts:@"settings.video_playback"]
                                key:[local stringByAppendingString:@".playback"] def:@"low_latency"
                            choices:@[ @[ @"low_latency", [_texts ts:@"prefs.playback_low_latency"] ],
                                       @[ @"hls", @"HLS" ], @[ @"mjpeg", @"MJPEG" ] ]]];
    [rows addObject:[self choiceRow:[_texts ts:@"settings.video_rotation"]
                                key:[local stringByAppendingString:@".rotation"] def:@"auto"
                            choices:@[ @[ @"auto", [_texts ts:@"admin.rotation_auto"] ],
                                       @[ @"0", @"0°" ], @[ @"90", @"90°" ],
                                       @[ @"180", @"180°" ], @[ @"270", @"270°" ] ]]];
  }
  [rows addObject:[self webOnlyRow:[_texts ts:@"settings.theme_bg"]
                             value:([self themeBackgroundHex] ?: @"")]];
  [rows addObject:[self webOnlyRow:[_texts ts:@"settings.web_only_upload"] value:@""]];
  [rows addObject:[self webOnlyRow:[_texts ts:@"settings.web_only_labels"] value:@""]];
  // No キオスクを終了 row here: on this jailbroken iPad the app *is* the kiosk,
  // so there is no mode to leave -- terminating it only makes the watchdog or
  // the root helper relaunch it. A row that cannot do what it says is worse
  // than no row (spec §5.2, no decorative controls).
  return rows;
}

- (NSString *)themeBackgroundHex {
  NSString *device = [DBConfigUtil str:_cfg path:[NSString stringWithFormat:
      @"devices.%@.local.theme.bg_color", _nodeId]];
  return device ?: [DBConfigUtil str:_cfg path:@"display.theme.bg_color"];
}

- (NSArray *)volumeRows {
  NSMutableArray *rows = [NSMutableArray array];
  NSArray *levels = [NSArray arrayWithObjects:
      [NSArray arrayWithObjects:@"call", @"volume.call", nil],
      [NSArray arrayWithObjects:@"sos", @"volume.sos", nil],
      [NSArray arrayWithObjects:@"idle", @"volume.idle", nil], nil];
  BOOL anyDeviceOverride = NO;
  for (NSArray *level in levels) {
    NSString *level_id = [level objectAtIndex:0];
    NSInteger effective = [DBConfigUtil intVal:_audio path:level_id def:-1];
    NSString *deviceKey = [NSString stringWithFormat:
        @"devices.%@.local.audio.volume.%@", _nodeId, level_id];
    BOOL overridden = ([DBConfigUtil dig:_cfg path:deviceKey] != nil);
    if (overridden) effective = [DBConfigUtil intVal:_cfg path:deviceKey def:effective];
    NSNumber *pending = [_pendingVolumeValues objectForKey:deviceKey];
    if (pending) {
      if (effective == [pending integerValue]) [_pendingVolumeValues removeObjectForKey:deviceKey];
      else effective = [pending integerValue];
    }
    if (overridden) anyDeviceOverride = YES;
    NSInteger clusterValue = [DBConfigUtil intVal:_cfg
        path:[NSString stringWithFormat:@"audio.volume.%@", level_id] def:-1];
    NSMutableString *value = [NSMutableString stringWithFormat:@"%ld",
        (long)(effective < 0 ? 0 : effective)];
    if (!overridden && clusterValue >= 0)
      [value appendFormat:@"  (%@)", [_texts t:@"volume.cluster_default",
          [NSString stringWithFormat:@"%ld", (long)clusterValue], nil]];
    // Writing the device key overrides; clearing it inherits again.
    [rows addObject:DBRow([_texts ts:[level objectAtIndex:1]], value, @"volume_slider",
                          [NSString stringWithFormat:@"%@|0|100", deviceKey])];
  }
  if (anyDeviceOverride) {
    [rows addObject:DBRow([_texts ts:@"settings.inherit"], @"", @"inherit",
                          [NSString stringWithFormat:@"devices.%@.local.audio.volume",
                                                     _nodeId])];
  }
  return rows;
}

- (NSString *)appearanceLabel:(NSString *)configured effective:(NSString *)effective {
  if ([configured isEqualToString:@"light"]) return [_texts ts:@"theme.mode_light"];
  if ([configured isEqualToString:@"dark"]) return [_texts ts:@"theme.mode_dark"];
  return [NSString stringWithFormat:@"%@  ·  %@", [_texts ts:@"theme.appearance_auto_schedule"],
      [_texts ts:([effective isEqualToString:@"light"] ? @"theme.mode_light"
                                                       : @"theme.mode_dark")]];
}

- (NSArray *)timeRows {
  NSMutableArray *rows = [NSMutableArray array];
  NSString *zone = [DBConfigUtil str:_status path:@"time.zone"];
  if ([zone length] == 0) zone = [DBConfigUtil str:_cfg path:@"time.zone"];
  [rows addObject:DBRow([_texts ts:@"time.zone"], (zone ?: @""), @"zone", @"time.zone")];
  NSString *source = [DBConfigUtil str:_status path:@"time.source"] ?: @"system";
  [rows addObject:DBRow([_texts ts:@"time.source"],
                        [_texts ts:([source isEqualToString:@"ntp"] ? @"time.source_ntp"
                                                                    : @"time.source_system")],
                        @"", nil)];
  [rows addObject:[self toggleRow:[_texts ts:@"time.ntp_enabled"] key:@"time.ntp.enabled" def:NO]];
  NSInteger interval = [DBConfigUtil intVal:_cfg path:@"time.ntp.interval_s" def:86400];
  [rows addObject:DBRow([_texts ts:@"time.interval_s"],
                        [NSString stringWithFormat:@"%ld", (long)interval], @"number",
                        @"time.ntp.interval_s|3600|604800")];
  // Host names cannot be typed on a drawn numeric keypad, so the server list
  // stays a web-admin field.
  id servers = [DBConfigUtil dig:_cfg path:@"time.ntp.servers"];
  if ([servers isKindOfClass:[NSArray class]])
    [rows addObject:[self webOnlyRow:[_texts ts:@"time.servers"]
                               value:[(NSArray *)servers componentsJoinedByString:@", "]]];
  long long lastSync = [DBConfigUtil longLongVal:_status path:@"time.last_sync_ms" def:0];
  [rows addObject:DBRow([_texts ts:@"time.last_sync"],
                        lastSync > 0 ? [NSString stringWithFormat:@"%lld ms",
                            [DBConfigUtil longLongVal:_status path:@"time.offset_ms" def:0]]
                                     : [_texts ts:@"time.never"], @"", nil)];
  [rows addObject:DBRow([_texts ts:@"time.sync_now"], @"", @"time_sync", nil)];
  NSString *iso = [DBConfigUtil str:_localTime path:@"iso"];
  if ([iso length] > 0)
    [rows addObject:DBRow([_texts ts:@"time.local_now"], iso, @"", @"local_clock")];
  return rows;
}

- (NSArray *)doorRows {
  NSMutableArray *rows = [NSMutableArray array];
  NSDictionary *doors = [DBConfigUtil dig:_cfg path:@"doors"];
  long long nowMs = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
  if ([doors isKindOfClass:[NSDictionary class]]) {
    for (NSString *door in [DBConfigUtil sortedByOrder:doors]) {
      NSString *label = [DBConfigUtil labelOf:[doors objectForKey:door] lang:_boot.uiLang
                                     fallback:door];
      NSDictionary *notice = [DBNoticeModel effectiveNoticeForDoor:door config:_cfg nowMs:nowMs];
      [rows addObject:DBRow(label,
                            notice ? [DBNoticeModel noticeText:notice]
                                   : [_texts ts:@"notice.none"],
                            @"notice", door)];
      NSDictionary *unlock = [DBConfigUtil dig:_status
          path:[NSString stringWithFormat:@"doors.%@.unlock", door]];
      BOOL configuredUnlock = [DBConfigUtil boolVal:unlock path:@"configured" def:NO];
      BOOL showUnlock = [DBConfigUtil boolVal:unlock path:@"show_button"
                                          def:configuredUnlock];
      [rows addObject:DBRow([_texts ts:@"unlock.title"], @"", @"toggle",
                            [NSString stringWithFormat:@"doors.%@.unlock.show_button|%d",
                                                       door, showUnlock ? 1 : 0])];
    }
  }
  [rows addObject:DBRow([_texts ts:@"dash.notice_global"], @"", @"notice", @"")];
  return rows;
}

- (NSArray *)purposeRows {
  NSMutableArray *rows = [NSMutableArray array];
  NSDictionary *purposes = [DBConfigUtil dig:_cfg path:@"visit_purposes"];
  // The editor lists disabled purposes too: hiding them here would leave no way
  // to switch one back on from the device.
  for (NSString *purpose in [DBPurposeModel allPurposeIdsInConfig:_cfg]) {
    NSDictionary *entry = [purposes objectForKey:purpose];
    BOOL enabled = [DBPurposeModel isPurposeEnabled:entry];
    [rows addObject:DBRow([DBConfigUtil labelOf:entry lang:_boot.uiLang fallback:purpose],
                          [_texts ts:(enabled ? @"purpose.enabled" : @"purpose.disabled")],
                          @"toggle",
                          [NSString stringWithFormat:@"%@|%d",
                              [DBPurposeModel enabledKeyForPurpose:purpose], enabled ? 1 : 0])];
  }
  return rows;
}

- (NSArray *)ruleRows {
  NSMutableArray *rows = [NSMutableArray array];
  // Each rule switches on and off here; what a rule does stays in the web admin.
  for (NSString *root in @[ @"trigger_rules", @"rules" ]) {
    NSDictionary *rules = [DBConfigUtil dig:_cfg path:root];
    if (![rules isKindOfClass:[NSDictionary class]]) continue;
    for (NSString *ruleId in [[rules allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
      NSDictionary *rule = [rules objectForKey:ruleId];
      if (![rule isKindOfClass:[NSDictionary class]]) continue;
      NSString *name = [DBConfigUtil str:rule path:@"name"];
      if ([name length] == 0) {
        NSString *key = [NSString stringWithFormat:@"prefs.rule_%@", ruleId];
        NSString *known = [_texts ts:key];
        name = [known isEqualToString:key] ? ruleId : known;
      }
      [rows addObject:[self toggleRow:name
                                  key:[NSString stringWithFormat:@"%@.%@.enabled", root, ruleId]
                                  def:YES]];
    }
  }
  [rows addObject:[self webOnlyRow:[_texts ts:@"prefs.rule_edit"] value:@""]];
  [rows addObject:[self stepperRow:[_texts ts:@"prefs.retention"] key:@"events.retention_days"
                               def:90 min:1 max:3650 step:30
                              unit:[_texts ts:@"prefs.unit_days"]]];
  id quiet = [DBConfigUtil dig:_cfg path:@"quiet_hours"];
  [rows addObject:[self webOnlyRow:[_texts ts:@"settings.quiet_hours"]
                             value:[_texts ts:(quiet ? @"settings.configured"
                                                     : @"settings.not_configured")]]];
  BOOL telegram = [[DBConfigUtil str:_cfg path:@"integrations.telegram.token_ref"] length] > 0;
  [rows addObject:[self webOnlyRow:@"Telegram"
                             value:[_texts ts:(telegram ? @"settings.configured"
                                                        : @"settings.not_configured")]]];
  [rows addObject:[self webOnlyRow:[_texts ts:@"settings.web_only_secrets"] value:@""]];
  return rows;
}

- (NSArray *)clusterRows {
  NSMutableArray *rows = [NSMutableArray array];
  [rows addObject:DBRow([_texts ts:@"admin.menu_add_device"], @"", @"add_device", nil)];
  id peers = [DBConfigUtil dig:_status path:@"peers"];
  NSInteger count = [peers isKindOfClass:[NSArray class]] ? (NSInteger)[(NSArray *)peers count]
                                                          : 0;
  [rows addObject:DBRow([_texts ts:@"admin.devices"],
                        [_texts t:@"settings.rules_count",
                             [NSString stringWithFormat:@"%ld", (long)(count + 1)], nil],
                        @"", nil)];
  // Security protocol v3 state, from the pairing snapshot.
  NSDictionary *security = [_pairing isKindOfClass:[NSDictionary class]]
      ? [_pairing objectForKey:@"security"] : nil;
  if ([security isKindOfClass:[NSDictionary class]]) {
    NSString *psk = [DBConfigUtil str:security path:@"psk_id"] ?: @"";
    if ([psk length] > 0)
      [rows addObject:DBRow([_texts ts:@"prefs.cluster_key"], psk, @"", nil)];
    NSInteger stale = 0;
    for (NSString *key in @[ @"legacy_peers", @"rekey_required" ]) {
      id list = [security objectForKey:key];
      if ([list isKindOfClass:[NSArray class]]) stale += (NSInteger)[(NSArray *)list count];
    }
    if (stale > 0)
      [rows addObject:DBRow([_texts ts:@"prefs.members_need_rejoin"],
                            [_texts t:@"pair.members_need_rejoin",
                                 [NSString stringWithFormat:@"%ld", (long)stale], nil],
                            @"", nil)];
  }
  BOOL paired = [[DBConfigUtil str:_pairing path:@"state"] isEqualToString:@"ready"];
  if ([DBCoreBridge supportsKeyRotation] && paired) {
    DBSettingsRow *rotate = DBRow([_texts ts:@"prefs.rotate_key"], @"", @"rotate_key", nil);
    rotate.destructive = YES;
    [rows addObject:rotate];
  }
  [rows addObject:[self webOnlyRow:[_texts ts:@"prefs.panels"] value:@""]];
  [rows addObject:[self webOnlyRow:[_texts ts:@"prefs.media_sources"] value:@""]];
  return rows;
}

- (NSArray *)soundRows {
  NSMutableArray *rows = [NSMutableArray array];
  [rows addObject:[self choiceRow:[_texts ts:@"prefs.ringtone"] key:@"ui.ringtone"
                              def:@"school_chime"
                          choices:[self soundChoices:@[ @"school_chime", @"ding1", @"ding2",
                                                        @"classic" ] none:NO]]];
  [rows addObject:[self toggleRow:[_texts ts:@"prefs.call_sound_loop"] key:@"ui.call_sound_loop"
                              def:NO]];
  [rows addObject:[self choiceRow:[_texts ts:@"prefs.button_sound"] key:@"ui.button_sound"
                              def:@"button_click"
                          choices:[self soundChoices:@[ @"button_click" ] none:YES]]];
  [rows addObject:[self webOnlyRow:[_texts ts:@"prefs.sound_upload"] value:@""]];
  return rows;
}

- (NSArray *)displayRows {
  NSMutableArray *rows = [NSMutableArray array];
  [rows addObject:[self stepperRow:[_texts ts:@"prefs.brightness"] key:@"display.brightness"
                               def:70 min:0 max:100 step:5 unit:@"%"]];
  [rows addObject:[self toggleRow:[_texts ts:@"prefs.night_mode"] key:@"display.night.enabled"
                              def:NO]];
  if ([DBConfigUtil boolVal:_cfg path:@"display.night.enabled" def:NO])
    [rows addObject:[self stepperRow:[_texts ts:@"prefs.night_brightness"]
                                 key:@"display.night.brightness" def:15 min:1 max:100 step:5
                                unit:@"%"]];
  NSString *saver = @"display.screensaver";
  NSInteger legacyAfter = [DBConfigUtil intVal:_cfg path:@"display.screensaver_after_s" def:120];
  [rows addObject:[self toggleRow:[_texts ts:@"prefs.screensaver"]
                              key:[saver stringByAppendingString:@".enabled"] def:legacyAfter > 0]];
  [rows addObject:[self stepperRow:[_texts ts:@"prefs.screensaver_after"]
                               key:[saver stringByAppendingString:@".after_s"]
                               def:legacyAfter min:10 max:3600 step:10
                              unit:[_texts ts:@"prefs.unit_seconds"]]];
  [rows addObject:[self choiceRow:[_texts ts:@"prefs.screensaver_mode"]
                              key:[saver stringByAppendingString:@".mode"] def:@"dim"
                          choices:@[ @[ @"dim", [_texts ts:@"prefs.saver_dim"] ],
                                     @[ @"minimal", [_texts ts:@"prefs.saver_minimal"] ],
                                     @[ @"clock", [_texts ts:@"prefs.saver_clock"] ] ]]];
  [rows addObject:[self stepperRow:[_texts ts:@"prefs.screensaver_brightness"]
                               key:[saver stringByAppendingString:@".brightness"] def:10 min:1
                               max:100 step:5 unit:@"%"]];
  return rows;
}

- (NSArray *)callRows {
  NSMutableArray *rows = [NSMutableArray array];
  [rows addObject:[self choiceRow:[_texts ts:@"prefs.call_flow"] key:@"ui.call_flow"
                              def:@"purpose_first"
                          choices:@[ @[ @"purpose_first", [_texts ts:@"prefs.flow_purpose_first"] ],
                                     @[ @"ring_then_purpose",
                                        [_texts ts:@"prefs.flow_ring_then_purpose"] ] ]]];
  NSString *seconds = [_texts ts:@"prefs.unit_seconds"];
  [rows addObject:[self stepperRow:[_texts ts:@"prefs.call_ttl"] key:@"ui.call_ttl_s" def:60
                               min:10 max:300 step:10 unit:seconds]];
  [rows addObject:[self stepperRow:[_texts ts:@"prefs.reply_ttl"] key:@"reply.display_ttl_s"
                               def:8 min:3 max:60 step:1 unit:seconds]];
  [rows addObject:[self stepperRow:[_texts ts:@"prefs.visitor_lang_revert"]
                               key:@"ui.visitor_lang_revert_s" def:60 min:5 max:600 step:5
                              unit:seconds]];
  [rows addObject:[self webOnlyRow:[_texts ts:@"prefs.quick_replies"] value:@""]];
  return rows;
}

- (NSArray *)sosRows {
  NSMutableArray *rows = [NSMutableArray array];
  [rows addObject:[self stepperRow:[_texts ts:@"prefs.sos_countdown"]
                               key:@"emergency.trigger.countdown_s" def:3 min:0 max:10 step:1
                              unit:[_texts ts:@"prefs.unit_seconds"]]];
  [rows addObject:[self toggleRow:[_texts ts:@"prefs.sos_cancel_pin"]
                              key:@"emergency.cancel_requires_pin" def:YES]];
  [rows addObject:[self toggleRow:[_texts ts:@"prefs.sos_web_alerts"]
                              key:@"emergency.web_active_page_alerts" def:YES]];
  id roles = [DBConfigUtil dig:_cfg path:@"emergency.button_on_roles"];
  NSArray *list = [roles isKindOfClass:[NSArray class]] ? roles : @[ @"indoor_panel" ];
  for (NSArray *role in @[ @[ @"indoor_panel", @"admin.role_indoor" ],
                           @[ @"door_station", @"admin.role_door" ] ]) {
    BOOL on = [list containsObject:[role objectAtIndex:0]];
    [rows addObject:DBRow([NSString stringWithFormat:@"%@ · %@", [_texts ts:@"prefs.sos_roles"],
                                                     [_texts ts:[role objectAtIndex:1]]],
                          @"", @"role_toggle",
                          [NSString stringWithFormat:@"%@|%d", [role objectAtIndex:0], on ? 1 : 0])];
  }
  [rows addObject:[self choiceRow:[_texts ts:@"prefs.sos_sound"] key:@"emergency.alarm_sound"
                              def:@"siren1"
                          choices:[self soundChoices:@[ @"siren1" ] none:NO]]];
  return rows;
}

- (NSString *)versionLine {
  NSDictionary *power = [_core powerStateNow];
  NSInteger battery = [DBConfigUtil intVal:power path:@"battery_pct" def:-1];
  BOOL charging = [DBConfigUtil boolVal:power path:@"charging" def:NO];
  NSString *appVersion = [[NSBundle mainBundle]
      objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
  return [DBUiTheme versionLineForName:nil coreVersion:[_core coreVersion]
                           appVersion:appVersion batteryPct:battery charging:charging];
}

- (NSArray *)infoRows {
  NSMutableArray *rows = [NSMutableArray array];
  [rows addObject:DBRow([_texts ts:@"info.safe_mode"], [self safeModeValue], @"", nil)];
  [rows addObject:DBRow([_texts ts:@"admin.menu_info"], @"", @"info", nil)];
  return rows;
}

// The kiosk's local safe mode is now visible instead of silently latched
// (follow-up from the iPad 1 keepalive qualification record).
- (NSString *)safeModeValue {
  // The shell publishes both a media-detail object and these flat fields under
  // status.runtime; the flat ones are what the operator needs here.
  NSString *state = [DBConfigUtil str:_status path:@"runtime.safe_mode_state"];
  if ([state length] == 0)
    state = [DBConfigUtil str:_status path:@"runtime.process_recovery.recovery_state"];
  if ([state length] == 0 || [state isEqualToString:@"off"])
    return [_texts ts:@"info.safe_mode_off"];
  if ([state isEqualToString:@"heartbeat_stalled"])
    return [_texts ts:@"info.safe_mode_heartbeat"];
  if ([state isEqualToString:@"crash_charged"]) return [_texts ts:@"info.safe_mode_crash"];
  if ([state isEqualToString:@"helper_latched"]) return [_texts ts:@"info.safe_mode_helper"];
  double remaining = [DBConfigUtil doubleVal:_status path:@"runtime.safe_mode_remaining_s"
                                         def:[DBSafeModeRecovery healthyWindowSeconds]];
  long minutes = (long)ceil(remaining / 60.0);
  if (minutes < 1) minutes = 1;
  return [_texts t:@"info.safe_mode_wait", [NSString stringWithFormat:@"%ld", minutes], nil];
}

- (void)rebuildSections {
  for (UITableViewCell *cell in [_table visibleCells]) {
    if ([cell isKindOfClass:[DBVolumeSettingsCell class]] &&
        ((DBVolumeSettingsCell *)cell).editingVolume) return;
  }
  NSMutableArray *sections = [NSMutableArray array];
  [sections addObject:[self section:@"settings.section_device" rows:[self deviceRows]
                               icon:@"device-tablet" tint:@"#8E8E93"]];
  NSMutableArray *sound = [NSMutableArray arrayWithArray:[self volumeRows]];
  [sound addObjectsFromArray:[self soundRows]];
  [sections addObject:[self section:@"prefs.sounds" rows:sound icon:@"volume" tint:@"#FF2D55"]];
  [sections addObject:[self section:@"prefs.display" rows:[self displayRows]
                               icon:@"palette" tint:@"#007AFF"]];
  [sections addObject:[self section:@"prefs.calls" rows:[self callRows]
                               icon:@"phone" tint:@"#34C759"]];
  [sections addObject:[self section:@"settings.section_doors" rows:[self doorRows]
                               icon:@"door" tint:@"#FF9500"]];
  NSArray *purposes = [self purposeRows];
  if ([purposes count] > 0)
    [sections addObject:[self section:@"settings.section_purposes" rows:purposes
                                 icon:@"message-reply" tint:@"#5AC8FA"]];
  [sections addObject:[self section:@"prefs.sos" rows:[self sosRows]
                               icon:@"shield-lock" tint:@"#FF3B30"]];
  [sections addObject:[self section:@"settings.section_time" rows:[self timeRows]
                               icon:@"clock" tint:@"#5856D6"]];
  [sections addObject:[self section:@"settings.section_rules" rows:[self ruleRows]
                               icon:@"bell" tint:@"#FF3B30"]];
  [sections addObject:[self section:@"settings.section_cluster" rows:[self clusterRows]
                               icon:@"topology-star-3" tint:@"#30B0C7"]];
  [sections addObject:[self section:@"settings.section_history"
                               rows:[NSArray arrayWithObject:
                                        DBRow([_texts ts:@"history.title"], @"",
                                              @"history", nil)]
                               icon:@"list" tint:@"#8E8E93"]];
  [sections addObject:[self section:@"settings.section_info" rows:[self infoRows]
                               icon:@"info-circle" tint:@"#8E8E93"]];
  _sections = sections;
  _selectedSection = 0;
  for (NSUInteger i = 0; i < [sections count]; i++)
    if ([[[sections objectAtIndex:i] objectForKey:@"id"] isEqualToString:_selectedId])
      _selectedSection = (NSInteger)i;
  _selectedId = [[sections objectAtIndex:(NSUInteger)_selectedSection] objectForKey:@"id"];
  [_categoryTable reloadData];

  _title.text = [_texts ts:@"settings.title"];
  [_close setTitle:[_texts ts:@"settings.close"] forState:UIControlStateNormal];
  [_qr setUrl:[self adminUrl] caption:[_texts ts:@"web_admin.scan"]];
  [_qr setVersionLine:[self versionLine]];
  [_table reloadData];
  [self setNeedsLayout];
}

#pragma mark - actions

- (NSArray *)selectedRows {
  if (_selectedSection < 0 || _selectedSection >= (NSInteger)[_sections count]) return nil;
  return [[_sections objectAtIndex:(NSUInteger)_selectedSection] objectForKey:@"rows"];
}

- (DBSettingsRow *)rowAt:(NSIndexPath *)indexPath {
  NSArray *rows = [self selectedRows];
  if (indexPath.row < 0 || indexPath.row >= (NSInteger)[rows count]) return nil;
  return [rows objectAtIndex:(NSUInteger)indexPath.row];
}

- (void)showToast:(NSString *)text {
  _toast.text = text;
  _toast.alpha = 1;
  NSUInteger generation = ++_toastGeneration;
  __weak DBSettingsScreen *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
    DBSettingsScreen *screen = weakSelf;
    if (!screen || screen->_toastGeneration != generation) return;
    [UIView animateWithDuration:0.2 animations:^{ screen->_toast.alpha = 0; }];
  });
  [self setNeedsLayout];
}

- (void)cycleLocalKey:(NSString *)key values:(NSArray *)values current:(NSString *)current {
  NSUInteger index = [values indexOfObject:(current ?: @"")];
  NSString *next = [values objectAtIndex:(index == NSNotFound ? 0
                                                             : (index + 1) % [values count])];
  NSString *json = [DBBootConfig persistLocalValue:next forKey:key];
  if ([json length] == 0) {
    [self showToast:[_texts ts:@"settings.save_failed"]];
    return;
  }
  _boot.rawJson = json;
  if ([key isEqualToString:@"ui_lang"]) {
    _boot.uiLang = next;
    [_texts setLang:next];
  } else if ([key isEqualToString:@"keepalive_helper"]) {
    _boot.keepaliveHelperPolicy = next;
  }
  [self showToast:[_texts ts:@"settings.saved"]];
  [self rebuildSections];
}

- (void)openNoticeDialogForDoor:(NSString *)door {
  if (!_noticeDialog) _noticeDialog = [[DBNoticeDialog alloc] initWithRouter:_router];
  NSMutableArray *doorIds = [NSMutableArray array];
  NSMutableDictionary *labels = [NSMutableDictionary dictionary];
  NSDictionary *doors = [DBConfigUtil dig:_cfg path:@"doors"];
  if ([doors isKindOfClass:[NSDictionary class]]) {
    for (NSString *identifier in [DBConfigUtil sortedByOrder:doors]) {
      [doorIds addObject:identifier];
      [labels setObject:[DBConfigUtil labelOf:[doors objectForKey:identifier]
                                         lang:_boot.uiLang fallback:identifier]
                 forKey:identifier];
    }
  }
  __weak DBSettingsScreen *weakSelf = self;
  [_noticeDialog presentInView:self config:_cfg doorIds:doorIds doorLabels:labels
               preselectedDoor:door palette:_palette onFinished:^(BOOL changed) {
    DBSettingsScreen *screen = weakSelf;
    if (screen && changed) [screen reload];
  }];
}

// Every cluster write goes through Core's C ABI, which applies the same
// validation and advisory colour warnings as the web admin (spec §5.5). A Core
// that predates the export answers -100 and the row says so rather than
// pretending the value was saved.
- (BOOL)reportWriteStatus:(int)status {
  if (status != 0) {
    [self showToast:[_texts ts:(status == -100 ? @"settings.web_only"
                                               : @"settings.save_failed")]];
    return NO;
  }
  // A readability warning means the value was saved and may be hard to read;
  // custom colours are never rejected (spec §5.2).
  NSString *message = [_texts ts:@"settings.saved"];
  for (id entry in [_core lastWriteWarnings]) {
    if (![entry isKindOfClass:[NSDictionary class]]) continue;
    id ratio = [(NSDictionary *)entry objectForKey:@"contrast"];
    NSString *key = [DBConfigUtil evStr:entry key:@"message_key"];
    if ([key length] == 0) key = @"theme.low_contrast";
    message = [_texts t:key,
        [NSString stringWithFormat:@"%.1f", [ratio respondsToSelector:@selector(doubleValue)]
                                                ? [ratio doubleValue] : 0.0], nil];
    break;
  }
  [self showToast:message];
  // Core publishes read snapshots after the mutation event; do not restore an older slider value.
  __weak DBSettingsScreen *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{ [weakSelf reload]; });
  return YES;
}

- (void)commitPendingNumber:(NSString *)value {
  _keypadOverlay.hidden = YES;
  if ([_pendingNumberKey length] == 0) return;
  NSInteger number = [value integerValue];
  if ([value length] == 0 || number < _pendingNumberMin || number > _pendingNumberMax) {
    [self showToast:[_texts ts:@"settings.save_failed"]];
    return;
  }
  [self reportWriteStatus:[_core setConfigKey:_pendingNumberKey numberValue:number]];
  _pendingNumberKey = nil;
}

- (void)promptNumberForRow:(DBSettingsRow *)row {
  NSArray *parts = [row.argument componentsSeparatedByString:@"|"];
  if ([parts count] != 3) return;
  _pendingNumberKey = [[parts objectAtIndex:0] copy];
  _pendingNumberMin = [[parts objectAtIndex:1] integerValue];
  _pendingNumberMax = [[parts objectAtIndex:2] integerValue];
  _keypadTitle.text = [NSString stringWithFormat:@"%@  (%ld–%ld)", row.title,
                       (long)_pendingNumberMin, (long)_pendingNumberMax];
  [_keypad setSubmitTitle:[_texts ts:@"admin.save"]];
  [_keypad clear];
  _keypadOverlay.hidden = NO;
  [_keypad beginEditing];
  [self bringSubviewToFront:_keypadOverlay];
  [self setNeedsLayout];
}

- (void)toggleForRow:(DBSettingsRow *)row {
  NSArray *parts = [row.argument componentsSeparatedByString:@"|"];
  if ([parts count] != 2) return;
  BOOL current = [[parts objectAtIndex:1] integerValue] != 0;
  [self reportWriteStatus:[_core setConfigKey:[parts objectAtIndex:0] boolValue:!current]];
}

- (void)cycleForRow:(DBSettingsRow *)row {
  NSArray *parts = [row.argument componentsSeparatedByString:@"|"];
  if ([parts count] != 2) return;
  NSString *key = [parts objectAtIndex:0];
  NSArray *values = [[parts objectAtIndex:1] componentsSeparatedByString:@","];
  if ([values count] == 0) return;
  NSString *current = [DBConfigUtil str:_cfg path:key] ?: @"";
  NSUInteger index = [values indexOfObject:current];
  NSString *next = [values objectAtIndex:(index == NSNotFound ? 0
                                                              : (index + 1) % [values count])];
  [self reportWriteStatus:[_core setConfigKey:key stringValue:next]];
}

- (void)inheritForRow:(DBSettingsRow *)row {
  // Clearing the device key restores inheritance from the cluster default.
  [self reportWriteStatus:[_core deleteConfigKey:row.argument]];
}

- (void)presentZonePickerForKey:(NSString *)key {
  _pickerKey = [key copy];
  // Core publishes the zones it can actually resolve; the built-in list is the
  // fallback for a core that does not report them.
  id zones = [DBConfigUtil dig:_status path:@"time.zones"];
  _pickerAll = ([zones isKindOfClass:[NSArray class]] && [(NSArray *)zones count] > 0)
      ? (NSArray *)zones : DBCommonTimeZones();
  _pickerFiltered = _pickerAll;
  _pickerSearch.text = @"";
  _pickerSearch.placeholder = [_texts ts:@"settings.zone_search"];
  [_pickerCancel setTitle:[_texts ts:@"admin.cancel"] forState:UIControlStateNormal];
  _pickerCancel.backgroundColor = _palette.elevated;
  [_pickerCancel setTitleColor:_palette.ink forState:UIControlStateNormal];
  _pickerTable.backgroundColor = _palette.surface;
  _pickerTable.separatorColor = _palette.separator;
  [_pickerTable reloadData];
  _pickerOverlay.hidden = NO;
  [self bringSubviewToFront:_pickerOverlay];
  [self setNeedsLayout];
}

- (void)onPickerSearchChanged {
  NSString *query = [_pickerSearch.text stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if ([query length] == 0) {
    _pickerFiltered = _pickerAll;
  } else {
    NSMutableArray *matches = [NSMutableArray array];
    for (NSString *zone in _pickerAll) {
      if ([zone rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound)
        [matches addObject:zone];
    }
    // Anything the operator types is offered too: Core owns the real table and
    // rejects an identifier it does not know.
    if ([matches count] == 0 && [query rangeOfString:@"/"].location != NSNotFound)
      [matches addObject:query];
    _pickerFiltered = matches;
  }
  [_pickerTable reloadData];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
  [textField resignFirstResponder];
  return YES;
}

- (void)onPickerCancel {
  [_pickerSearch resignFirstResponder];
  _pickerOverlay.hidden = YES;
  _pickerKey = nil;
}

- (void)promptDeviceName {
  UIAlertView *alert = [[UIAlertView alloc] initWithTitle:[_texts ts:@"settings.device_name"]
      message:nil delegate:self
      cancelButtonTitle:[_texts ts:@"admin.cancel"]
      otherButtonTitles:[_texts ts:@"admin.save"], nil];
  alert.alertViewStyle = UIAlertViewStylePlainTextInput;
  UITextField *field = [alert textFieldAtIndex:0];
  field.text = _boot.name;
  field.autocorrectionType = UITextAutocorrectionTypeNo;
  field.autocapitalizationType = UITextAutocapitalizationTypeNone;
  field.clearButtonMode = UITextFieldViewModeWhileEditing;
  [alert show];
}

- (BOOL)alertViewShouldEnableFirstOtherButton:(UIAlertView *)alertView {
  if (alertView.alertViewStyle != UIAlertViewStylePlainTextInput) return YES;
  NSString *name = [[alertView textFieldAtIndex:0].text stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  return [name length] > 0 && [name length] <= 64;
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
  if (buttonIndex == alertView.cancelButtonIndex) return;
  if (alertView.tag == kDBRotateKeyAlertTag) {
    [self rotateClusterKey];
    return;
  }
  NSString *name = [[alertView textFieldAtIndex:0].text stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if ([name length] == 0 || [name length] > 64 || [_nodeId length] == 0) {
    [self showToast:[_texts ts:@"settings.save_failed"]];
    return;
  }
  if ([name isEqualToString:_boot.name]) return;
  // The replicated identity handler persists boot.json without leaving the settings screen.
  [self reportWriteStatus:[_core setConfigKey:[NSString stringWithFormat:
      @"devices.%@.name", _nodeId] stringValue:name]];
}

- (void)performAction:(DBSettingsRow *)row {
  NSString *action = row.action;
  if ([action length] == 0) return;
  if ([action isEqualToString:@"device_name"]) {
    [self promptDeviceName];
  } else if ([action isEqualToString:@"web"]) {
    [self showToast:[_texts ts:@"settings.web_only"]];
  } else if ([action isEqualToString:@"number"]) {
    [self promptNumberForRow:row];
  } else if ([action isEqualToString:@"toggle"]) {
    [self toggleForRow:row];
  } else if ([action isEqualToString:@"cycle"]) {
    [self cycleForRow:row];
  } else if ([action isEqualToString:@"inherit"]) {
    [self inheritForRow:row];
  } else if ([action isEqualToString:@"zone"]) {
    [self presentZonePickerForKey:row.argument];
  } else if ([action isEqualToString:@"ui_lang"]) {
    [self cycleLocalKey:@"ui_lang"
                 values:[NSArray arrayWithObjects:@"ja", @"en", @"zh", nil]
                current:_boot.uiLang];
  } else if ([action isEqualToString:@"helper_mode"]) {
    [self cycleLocalKey:@"keepalive_helper"
                 values:[NSArray arrayWithObjects:@"off", @"auto", @"on", nil]
                current:_boot.keepaliveHelperPolicy];
  } else if ([action isEqualToString:@"time_sync"]) {
    DBCoreBridge *core = _core;
    __weak DBSettingsScreen *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      NSDictionary *before = [[core status] objectForKey:@"time"];
      long long previousSync = [[before objectForKey:@"last_sync_ms"] longLongValue];
      BOOL started = [core timeSyncNow];
      dispatch_async(dispatch_get_main_queue(), ^{
        DBSettingsScreen *screen = weakSelf;
        if (!screen) return;
        [screen showToast:[screen->_texts ts:(started ? @"time.sync_started"
                                                      : @"time.sync_failed")]];
        if (started) [screen reload];
      });
      if (!started) return;
      for (int attempt = 0; attempt < 60; attempt++) {
        [NSThread sleepForTimeInterval:0.1];
        NSDictionary *time = [[core status] objectForKey:@"time"];
        if ([[time objectForKey:@"syncing"] boolValue]) continue;
        BOOL succeeded = [[time objectForKey:@"last_sync_ms"] longLongValue] > previousSync;
        dispatch_async(dispatch_get_main_queue(), ^{
          DBSettingsScreen *screen = weakSelf;
          if (!screen) return;
          [screen showToast:[screen->_texts ts:(succeeded ? @"time.sync_succeeded"
                                                        : @"time.sync_result_failed")]];
          [screen reload];
        });
        break;
      }
    });
  } else if ([action isEqualToString:@"notice"]) {
    [self openNoticeDialogForDoor:row.argument];
  } else if ([action isEqualToString:@"stepper"]) {
    // A tap on a wide-range stepper row opens the keypad for a typed value.
    NSArray *parts = [row.argument componentsSeparatedByString:@"|"];
    if ([parts count] == 5) {
      DBSettingsRow *number = DBRow(row.title, row.value, @"number",
          [NSString stringWithFormat:@"%@|%@|%@", [parts objectAtIndex:0],
                                     [parts objectAtIndex:1], [parts objectAtIndex:2]]);
      [self promptNumberForRow:number];
    }
  } else if ([action isEqualToString:@"segment"]) {
    // The segmented control handles taps itself.
  } else if ([action isEqualToString:@"choose"]) {
    [self presentChoicesForRow:row];
  } else if ([action isEqualToString:@"role_toggle"]) {
    [self toggleRoleForRow:row];
  } else if ([action isEqualToString:@"rotate_key"]) {
    UIAlertView *confirm = [[UIAlertView alloc] initWithTitle:[_texts ts:@"prefs.rotate_key"]
        message:[_texts ts:@"prefs.rotate_key_confirm"] delegate:self
        cancelButtonTitle:[_texts ts:@"admin.cancel"]
        otherButtonTitles:[_texts ts:@"prefs.rotate_key"], nil];
    confirm.tag = kDBRotateKeyAlertTag;
    [confirm show];
  } else if ([action isEqualToString:@"add_device"]) {
    [_router showAddDevice];
  } else if ([action isEqualToString:@"history"]) {
    [_router showHistory];
  } else if ([action isEqualToString:@"info"]) {
    [_router showInfo];
  }
}

- (void)onClose {
  [_router closeSettingsAnimated:YES];
}

#pragma mark - native controls

- (void)onSwitch:(UISwitch *)sender {
  NSArray *rows = [self selectedRows];
  if (sender.tag < 0 || sender.tag >= (NSInteger)[rows count]) return;
  DBSettingsRow *row = [rows objectAtIndex:(NSUInteger)sender.tag];
  NSArray *parts = [row.argument componentsSeparatedByString:@"|"];
  if ([parts count] != 2) return;
  if ([row.action isEqualToString:@"role_toggle"]) {
    [self setRole:[parts objectAtIndex:0] enabled:sender.on];
    return;
  }
  if (![self reportWriteStatus:[_core setConfigKey:[parts objectAtIndex:0] boolValue:sender.on]])
    [sender setOn:!sender.on animated:YES];
}

- (void)onStepper:(UIStepper *)sender {
  NSArray *rows = [self selectedRows];
  if (sender.tag < 0 || sender.tag >= (NSInteger)[rows count]) return;
  DBSettingsRow *row = [rows objectAtIndex:(NSUInteger)sender.tag];
  NSArray *parts = [row.argument componentsSeparatedByString:@"|"];
  if ([parts count] != 5) return;
  // Writes on release only: each change is a replicated config write.
  [self reportWriteStatus:[_core setConfigKey:[parts objectAtIndex:0]
                                  numberValue:(NSInteger)sender.value]];
}

- (void)onStepperChanged:(UIStepper *)sender {
  UIView *view = sender.superview;
  while (view && ![view isKindOfClass:[UITableViewCell class]]) view = view.superview;
  NSArray *rows = [self selectedRows];
  if (!view || sender.tag < 0 || sender.tag >= (NSInteger)[rows count]) return;
  DBSettingsRow *row = [rows objectAtIndex:(NSUInteger)sender.tag];
  NSRange space = [row.value rangeOfString:@" "];
  NSString *unit = space.location == NSNotFound ? @"" : [row.value substringFromIndex:space.location];
  if ([row.value hasSuffix:@"%"]) unit = @"%";
  ((UITableViewCell *)view).detailTextLabel.text =
      [NSString stringWithFormat:@"%ld%@", (long)sender.value, unit];
  // UIStepper reports no release on iOS 5; writing after a short pause keeps
  // a run of taps to one replicated config write.
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(onStepper:)
                                             object:sender];
  [self performSelector:@selector(onStepper:) withObject:sender afterDelay:0.7];
}

- (void)onSegment:(UISegmentedControl *)sender {
  NSArray *rows = [self selectedRows];
  if (sender.tag < 0 || sender.tag >= (NSInteger)[rows count]) return;
  DBSettingsRow *row = [rows objectAtIndex:(NSUInteger)sender.tag];
  NSInteger index = sender.selectedSegmentIndex;
  if (index < 0 || index >= (NSInteger)[row.choices count]) return;
  NSString *key = [[row.argument componentsSeparatedByString:@"|"] objectAtIndex:0];
  [self reportWriteStatus:[_core setConfigKey:key
      stringValue:[[row.choices objectAtIndex:(NSUInteger)index] objectAtIndex:0]]];
}

- (void)presentChoicesForRow:(DBSettingsRow *)row {
  UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:row.title delegate:self
      cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:nil];
  for (NSArray *choice in row.choices) [sheet addButtonWithTitle:[choice objectAtIndex:1]];
  sheet.cancelButtonIndex = [sheet addButtonWithTitle:[_texts ts:@"admin.cancel"]];
  _pendingChoiceRow = row;
  NSUInteger index = [[self selectedRows] indexOfObject:row];
  CGRect rect = index == NSNotFound ? CGRectMake(CGRectGetMidX(_table.bounds), 0, 1, 1)
      : [_table rectForRowAtIndexPath:[NSIndexPath indexPathForRow:(NSInteger)index inSection:0]];
  [sheet showFromRect:rect inView:_table animated:YES];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)buttonIndex {
  DBSettingsRow *row = _pendingChoiceRow;
  _pendingChoiceRow = nil;
  if (row == nil || buttonIndex == sheet.cancelButtonIndex || buttonIndex < 0 ||
      buttonIndex >= (NSInteger)[row.choices count]) return;
  NSString *key = [[row.argument componentsSeparatedByString:@"|"] objectAtIndex:0];
  [self reportWriteStatus:[_core setConfigKey:key
      stringValue:[[row.choices objectAtIndex:(NSUInteger)buttonIndex] objectAtIndex:0]]];
}

- (void)toggleRoleForRow:(DBSettingsRow *)row {
  NSArray *parts = [row.argument componentsSeparatedByString:@"|"];
  if ([parts count] != 2) return;
  [self setRole:[parts objectAtIndex:0] enabled:[[parts objectAtIndex:1] integerValue] == 0];
}

- (void)setRole:(NSString *)role enabled:(BOOL)enabled {
  id current = [DBConfigUtil dig:_cfg path:@"emergency.button_on_roles"];
  NSMutableArray *roles = [NSMutableArray arrayWithArray:
      [current isKindOfClass:[NSArray class]] ? current : @[ @"indoor_panel" ]];
  [roles removeObject:role];
  if (enabled) [roles addObject:role];
  NSData *data = [NSJSONSerialization dataWithJSONObject:roles options:0 error:NULL];
  NSString *json = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
  if ([json length] == 0) return;
  [self reportWriteStatus:[_core setConfigKey:@"emergency.button_on_roles" valueJson:json]];
}

- (void)rotateClusterKey {
  __weak DBSettingsScreen *weakSelf = self;
  [_core rotateClusterKey:^(int result) {
    DBSettingsScreen *screen = weakSelf;
    if (!screen) return;
    [screen showToast:[screen->_texts ts:(result == 0 ? @"pair.cluster_key_changed"
                                                      : @"prefs.rotate_key_failed")]];
    [screen reload];
  }];
}

#pragma mark - table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  if (tableView == _pickerTable) return (NSInteger)[_pickerFiltered count];
  if (tableView == _categoryTable) return (NSInteger)[_sections count];
  return (NSInteger)[[self selectedRows] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
  if (tableView != _table) return nil;
  if (_selectedSection < 0 || _selectedSection >= (NSInteger)[_sections count]) return nil;
  return [[_sections objectAtIndex:(NSUInteger)_selectedSection] objectForKey:@"title"];
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
  return tableView == _table ? 56 : 0;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
  if (tableView != _table) return nil;
  // The detail pane's large title names the chosen category.
  UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tableView.bounds.size.width, 56)];
  header.backgroundColor = _palette.surface;
  UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(8, 14, tableView.bounds.size.width - 16, 30)];
  label.backgroundColor = [UIColor clearColor];
  label.font = [UIFont boldSystemFontOfSize:24];
  label.textColor = _palette.ink;
  label.text = [self tableView:tableView titleForHeaderInSection:section];
  [header addSubview:label];
  return header;
}

- (UITableViewCell *)categoryCellForRow:(NSInteger)index {
  static NSString *identifier = @"category";
  UITableViewCell *cell = [_categoryTable dequeueReusableCellWithIdentifier:identifier];
  if (cell == nil) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                  reuseIdentifier:identifier];
    cell.backgroundView = [[UIView alloc] init];
    cell.selectedBackgroundView = [[UIView alloc] init];
    cell.backgroundView.layer.cornerRadius = 10;
    cell.selectedBackgroundView.layer.cornerRadius = 10;
    cell.textLabel.font = [UIFont systemFontOfSize:17];
    cell.textLabel.backgroundColor = [UIColor clearColor];
    cell.textLabel.adjustsFontSizeToFitWidth = YES;
    cell.textLabel.minimumFontSize = 13;
    cell.indentationWidth = 46;  // room for the icon tile
    cell.indentationLevel = 1;
    UIView *tile = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
    tile.layer.cornerRadius = 7;
    tile.tag = 11;
    UIImageView *glyph = [[UIImageView alloc] initWithFrame:CGRectMake(5, 5, 20, 20)];
    glyph.tag = 12;
    [tile addSubview:glyph];
    [cell.contentView addSubview:tile];
  }
  NSDictionary *section = [_sections objectAtIndex:(NSUInteger)index];
  BOOL selected = index == _selectedSection;
  cell.textLabel.text = [section objectForKey:@"title"];
  cell.textLabel.textColor = _palette.ink;
  cell.backgroundColor = [UIColor clearColor];
  cell.backgroundView.backgroundColor = selected ? [_palette plate] : [UIColor clearColor];
  cell.selectedBackgroundView.backgroundColor = _palette.elevated;
  cell.accessibilityTraits = selected ? UIAccessibilityTraitSelected : UIAccessibilityTraitNone;
  UIView *tile = [cell.contentView viewWithTag:11];
  tile.backgroundColor = [DBConfigUtil parseHexColor:[section objectForKey:@"tint"]];
  ((UIImageView *)[tile viewWithTag:12]).image =
      [DBIconAsset tintedImageNamed:[section objectForKey:@"icon"] color:[UIColor whiteColor]
                               size:CGSizeMake(20, 20)];
  return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell
    forRowAtIndexPath:(NSIndexPath *)indexPath {
  if (tableView != _categoryTable) return;
  // UITableViewCell lays out textLabel after cellForRow, so the tile and the
  // label are placed here, inset like a grouped list.
  CGFloat height = tableView.rowHeight;
  cell.backgroundView.frame = CGRectInset(cell.bounds, 0, 3);
  cell.selectedBackgroundView.frame = cell.backgroundView.frame;
  [cell.contentView viewWithTag:11].frame = CGRectMake(12, (height - 30) / 2, 30, 30);
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
  if (tableView == _pickerTable) return 58;
  if (tableView == _categoryTable) return 56;
  DBSettingsRow *row = [self rowAt:indexPath];
  NSString *value = row.webOnly ? [NSString stringWithFormat:@"%@ · %@", row.value,
                                     [_texts ts:@"prefs.open_in_admin"]] : row.value;
  if ([row.action isEqualToString:@"volume_slider"]) return 64;
  // Rows with a control lose its width (≈ 110 pt switch/stepper, more for a segment).
  CGFloat controlWidth = [row.action isEqualToString:@"segment"]
      ? MIN(360, 120 * [row.choices count]) + 12
      : ([row.action isEqualToString:@"toggle"] || [row.action isEqualToString:@"stepper"] ||
         [row.action isEqualToString:@"role_toggle"]) ? 110 : 0;
  if ([row.action isEqualToString:@"segment"]) value = @"";
  return MAX(56, [DBSettingsCell heightForTitle:row.title value:value
                                          width:tableView.bounds.size.width - controlWidth]);
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  if (tableView == _pickerTable) {
    static NSString *zoneIdentifier = @"zone";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:zoneIdentifier];
    if (cell == nil)
      cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                    reuseIdentifier:zoneIdentifier];
    if (indexPath.row < (NSInteger)[_pickerFiltered count])
      cell.textLabel.text = [_pickerFiltered objectAtIndex:(NSUInteger)indexPath.row];
    cell.textLabel.font = [UIFont systemFontOfSize:19];
    cell.textLabel.textColor = _palette.ink;
    cell.textLabel.backgroundColor = [UIColor clearColor];
    cell.backgroundColor = _palette.elevated;
    return cell;
  }
  if (tableView == _categoryTable) return [self categoryCellForRow:indexPath.row];
  DBSettingsRow *row = [self rowAt:indexPath];
  BOOL volumeSlider = [row.action isEqualToString:@"volume_slider"];
  NSString *identifier = volumeSlider ? @"volume_setting" : @"setting";
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
  if (cell == nil) {
    Class cellClass = volumeSlider ? [DBVolumeSettingsCell class] : [DBSettingsCell class];
    cell = [[cellClass alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    cell.backgroundView = [[UIView alloc] init];

    cell.selectedBackgroundView = [[UIView alloc] init];
    DBSettingsCell *settingsCell = (DBSettingsCell *)cell;
    settingsCell.rowSeparator = [[UIView alloc] init];
    [cell.contentView addSubview:settingsCell.rowSeparator];
  }
  cell.textLabel.text = row.title;
  cell.textLabel.font = [UIFont systemFontOfSize:17];
  cell.textLabel.numberOfLines = 0;
  cell.detailTextLabel.font = [UIFont systemFontOfSize:15];
  cell.detailTextLabel.textAlignment = NSTextAlignmentRight;
  cell.detailTextLabel.numberOfLines = 0;
  cell.detailTextLabel.text = [row.action isEqualToString:@"segment"] ? @"" : row.value;
  cell.textLabel.textColor = _palette.ink;
  cell.detailTextLabel.textColor = _palette.mutedInk;
  cell.backgroundColor = [UIColor clearColor];
  cell.backgroundView.backgroundColor = [_palette plate];
  DBSettingsCell *settingsCell = (DBSettingsCell *)cell;
  settingsCell.firstRow = indexPath.row == 0;
  settingsCell.lastRow = indexPath.row + 1 == [self tableView:tableView numberOfRowsInSection:indexPath.section];
  settingsCell.rowSeparator.backgroundColor = _palette.separator;
  cell.selectedBackgroundView.backgroundColor = _palette.elevated;
  cell.textLabel.backgroundColor = [UIColor clearColor];
  cell.detailTextLabel.backgroundColor = [UIColor clearColor];
  cell.accessoryType = UITableViewCellAccessoryNone;
  UIView *control = [self controlForRow:row index:indexPath.row];
  if (control != nil) {
    cell.accessoryView = control;
  } else if ([row.action length] > 0 && !row.webOnly && !volumeSlider) {
    UIImageView *arrow = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 12, 20)];
    arrow.userInteractionEnabled = NO;
    arrow.contentMode = UIViewContentModeCenter;
    arrow.image = [DBIconAsset tintedImageNamed:@"chevron-right" color:_palette.mutedInk
                                         size:CGSizeMake(20, 20)];
    cell.accessoryView = arrow;
  } else {
    cell.accessoryView = nil;
  }
  BOOL tappable = [row.action length] > 0 && !volumeSlider &&
      ![row.action isEqualToString:@"segment"];
  cell.selectionStyle = tappable ? UITableViewCellSelectionStyleGray
                                 : UITableViewCellSelectionStyleNone;
  if (row.destructive) cell.textLabel.textColor = [UIColor colorWithRed:1 green:0.23f blue:0.19f alpha:1];
  if (row.webOnly) cell.detailTextLabel.text = [row.value length] > 0
      ? [NSString stringWithFormat:@"%@ · %@", row.value, [_texts ts:@"prefs.open_in_admin"]]
      : [_texts ts:@"prefs.open_in_admin"];
  if (volumeSlider) {
    DBVolumeSettingsCell *volumeCell = (DBVolumeSettingsCell *)cell;
    NSArray *parts = [row.argument componentsSeparatedByString:@"|"];
    NSString *key = [parts objectAtIndex:0];
    volumeCell.slider.accessibilityLabel = row.title;
    volumeCell.slider.accessibilityIdentifier = key;
    if (!volumeCell.editingVolume && ![volumeCell.slider isTracking]) {
      volumeCell.savedValue = [row.value floatValue];
      volumeCell.slider.value = volumeCell.savedValue;
      volumeCell.pendingVolume = (NSInteger)volumeCell.savedValue;
    }
    [volumeCell updateVolumeLabel];
    __weak DBSettingsScreen *weakSelf = self;
    volumeCell.onCommit = ^(NSInteger value) {
      DBSettingsScreen *screen = weakSelf;
      if (!screen) return;
      if (!screen->_volumeWriteQueue) {
        screen->_volumeWriteQueue = dispatch_queue_create("doorbell.volume-writes", DISPATCH_QUEUE_SERIAL);
        screen->_volumeWriteGenerations = [NSMutableDictionary dictionary];
        screen->_pendingVolumeValues = [NSMutableDictionary dictionary];
      }
      NSUInteger generation = [[screen->_volumeWriteGenerations objectForKey:key] unsignedIntegerValue] + 1;
      [screen->_volumeWriteGenerations setObject:@(generation) forKey:key];
      [screen->_pendingVolumeValues setObject:@(value) forKey:key];
      DBCoreBridge *core = screen->_core;
      dispatch_async(screen->_volumeWriteQueue, ^{
        int result = [core setConfigKey:key numberValue:value];
        dispatch_async(dispatch_get_main_queue(), ^{
          DBSettingsScreen *current = weakSelf;
          if (!current || [[current->_volumeWriteGenerations objectForKey:key] unsignedIntegerValue] != generation) return;
          if (result != 0) [current->_pendingVolumeValues removeObjectForKey:key];
          [current reportWriteStatus:result];
        });
      });
    };
  }
  return cell;
}

// Native controls are built per bind; a table shows one category, so this is a
// handful of controls at a time.
- (UIView *)controlForRow:(DBSettingsRow *)row index:(NSInteger)index {
  NSArray *parts = [row.argument componentsSeparatedByString:@"|"];
  if (([row.action isEqualToString:@"toggle"] || [row.action isEqualToString:@"role_toggle"]) &&
      [parts count] == 2) {
    UISwitch *toggle = [[UISwitch alloc] init];
    toggle.on = [[parts objectAtIndex:1] integerValue] != 0;
    toggle.tag = index;
    toggle.accessibilityLabel = row.title;
    [toggle addTarget:self action:@selector(onSwitch:) forControlEvents:UIControlEventValueChanged];
    return toggle;
  }
  if ([row.action isEqualToString:@"stepper"] && [parts count] == 5) {
    UIStepper *stepper = [[UIStepper alloc] init];
    stepper.minimumValue = [[parts objectAtIndex:1] doubleValue];
    stepper.maximumValue = [[parts objectAtIndex:2] doubleValue];
    stepper.stepValue = MAX(1, [[parts objectAtIndex:3] doubleValue]);
    stepper.value = [[parts objectAtIndex:4] doubleValue];
    stepper.continuous = YES;
    stepper.tag = index;
    stepper.accessibilityLabel = row.title;
    [stepper addTarget:self action:@selector(onStepperChanged:)
        forControlEvents:UIControlEventValueChanged];
    return stepper;
  }
  if ([row.action isEqualToString:@"segment"] && [row.choices count] > 0) {
    NSMutableArray *labels = [NSMutableArray array];
    NSInteger selected = UISegmentedControlNoSegment;
    NSString *current = [parts count] == 2 ? [parts objectAtIndex:1] : @"";
    for (NSUInteger i = 0; i < [row.choices count]; i++) {
      NSArray *choice = [row.choices objectAtIndex:i];
      [labels addObject:[choice objectAtIndex:1]];
      if ([[choice objectAtIndex:0] isEqualToString:current]) selected = (NSInteger)i;
    }
    UISegmentedControl *segment = [[UISegmentedControl alloc] initWithItems:labels];
    segment.segmentedControlStyle = UISegmentedControlStyleBar;
    segment.frame = CGRectMake(0, 0, MIN(360, 120 * [labels count]), 36);
    segment.selectedSegmentIndex = selected;
    segment.tag = index;
    [segment addTarget:self action:@selector(onSegment:) forControlEvents:UIControlEventValueChanged];
    return segment;
  }
  return nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  if (tableView == _categoryTable) {
    if (indexPath.row >= (NSInteger)[_sections count] || indexPath.row == _selectedSection) return;
    _selectedSection = indexPath.row;
    _selectedId = [[_sections objectAtIndex:(NSUInteger)_selectedSection] objectForKey:@"id"];
    [_categoryTable reloadData];
    [_table reloadData];
    [_table setContentOffset:CGPointZero animated:NO];
    return;
  }
  if (tableView == _pickerTable) {
    if (indexPath.row >= (NSInteger)[_pickerFiltered count]) return;
    NSString *zone = [_pickerFiltered objectAtIndex:(NSUInteger)indexPath.row];
    NSString *key = _pickerKey;
    [self onPickerCancel];
    if ([key length] > 0) [self reportWriteStatus:[_core setConfigKey:key stringValue:zone]];
    return;
  }
  [self performAction:[self rowAt:indexPath]];
}

#pragma mark - layout

- (void)numberKeyboardChanged:(NSNotification *)note {
  CGRect keyboard = [self convertRect:[[note.userInfo objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue] fromView:nil];
  CGRect overlap = CGRectIntersection(self.bounds, keyboard);
  _numberKeyboardHeight = [note.name isEqualToString:UIKeyboardWillHideNotification] || CGRectIsNull(overlap)
      ? 0 : CGRectGetHeight(overlap);
  [self setNeedsLayout];
}

- (void)layoutSubviews {
  [super layoutSubviews];
  CGSize size = self.bounds.size;
  CGFloat width = size.width;
  CGFloat pad = 20;
  _title.frame = CGRectMake(100, 16, width - 200, 28);
  _close.frame = CGRectMake(size.width - pad - 80, 6, 80, 44);
  // iPad 1 is 768 or 1024 points wide: the category pane takes a fixed share
  // and the detail gets the rest.
  CGFloat paneWidth = width >= 900 ? 280 : 236;
  _categoryTable.frame = CGRectMake(12, 56, paneWidth, MAX(0, size.height - 56));
  CGFloat detailX = 12 + paneWidth + 16;
  CGFloat contentWidth = width - detailX - 16;
  _table.frame = CGRectMake(detailX, 56, contentWidth, MAX(0, size.height - 56));
  _adminFooter.frame = CGRectMake(0, 20, contentWidth, 116);
  _qr.frame = CGRectMake(20, 22, contentWidth - 40, 72);
  if (_footerWidth != contentWidth) {
    _footerWidth = contentWidth;
    _footerContainer.frame = CGRectMake(0, 0, contentWidth, 136);
    _table.tableFooterView = _footerContainer;
  }
  _toast.frame = CGRectMake(100, 0, width - 200, 16);
  _noticeDialog.frame = self.bounds;

  _keypadOverlay.frame = self.bounds;
  CGFloat keypadWidth = MIN(320, size.width - 80);
  CGFloat keypadHeight = [DBNumericKeypad heightForWidth:keypadWidth];
  CGFloat keypadY = MAX(60, (size.height - _numberKeyboardHeight - keypadHeight) / 2);
  _keypadTitle.frame = CGRectMake(0, keypadY - 46, size.width, 34);
  _keypad.frame = CGRectMake((size.width - keypadWidth) / 2, keypadY, keypadWidth,
                             keypadHeight);

  _pickerOverlay.frame = self.bounds;
  CGFloat pickerWidth = MIN(520, size.width - 60);
  CGFloat pickerX = (size.width - pickerWidth) / 2;
  _pickerSearch.frame = CGRectMake(pickerX, 40, pickerWidth, 46);
  _pickerCancel.frame = CGRectMake(pickerX, size.height - 66, pickerWidth, 46);
  _pickerTable.frame = CGRectMake(pickerX, 96, pickerWidth,
                                  MAX(80, size.height - 96 - 80));
}

@end
