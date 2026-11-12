#import "DBSettingsScreen.h"

#import "../Core/DBBootConfig.h"
#import "../Core/DBConfigUtil.h"
#import "../Core/DBIconAsset.h"
#import "../Core/DBCoreBridge.h"
#import "../Core/DBNoticeModel.h"
#import "../Core/DBPurposeModel.h"
#import "../Core/DBTexts.h"
#import "../Core/DBUiTheme.h"
#import "../Media/DBQrCode.h"
#import "../Support/DBSafeModeRecovery.h"
#import "DBChrome.h"
#import "DBEditor.h"
#import "DBNoticeDialog.h"
#import "DBRouter.h"
#import "DBSettingsPages.h"
#import "DBWidgets.h"

// One settings row. `action` names what a tap does; "page" opens one of the
// native editors in DBSettingsPages, named by `argument`.
@interface DBSettingsRow : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *value;
@property(nonatomic, copy) NSString *action;
@property(nonatomic, copy) NSString *argument;
@property(nonatomic, assign) BOOL destructive;
// [[value, label], ...] for "segment", "choose", and "local_choice" rows; `value` holds the
// label.
@property(nonatomic, copy) NSArray *choices;
// The row opens a new group of the grouped table; groupFooter is that group's footer text.
@property(nonatomic, assign) BOOL startsGroup;
@property(nonatomic, copy) NSString *groupFooter;
@end

@implementation DBSettingsRow
@synthesize choices = _choices;
@synthesize title = _title, value = _value, action = _action, argument = _argument,
            destructive = _destructive;
@synthesize startsGroup = _startsGroup, groupFooter = _groupFooter;
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

static DBSettingsRow *DBGroupStart(DBSettingsRow *row) {
  row.startsGroup = YES;
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

// A volume slider previews nothing while it moves and writes once on release: the write is a
// replicated configuration change. The slider outlives its cell, so a table reload during a
// drag cannot replace the control under the finger.
@interface DBVolumeSlider : UISlider
@property(nonatomic, copy) NSString *configKey;
@property(nonatomic, copy) void (^onBegin)(void);
@property(nonatomic, copy) void (^onEnd)(float);
@property(nonatomic, copy) void (^onCancel)(void);
@property(nonatomic, assign) float savedValue;
@property(nonatomic, assign) BOOL editingVolume;
@property(nonatomic, assign) NSInteger pendingVolume;
@end

@implementation DBVolumeSlider
@synthesize configKey = _configKey, onBegin = _onBegin, onEnd = _onEnd, onCancel = _onCancel;
@synthesize savedValue = _savedValue, editingVolume = _editingVolume;
@synthesize pendingVolume = _pendingVolume;

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

// Accessory controls with the gap the cell keeps beside them.
static const CGFloat kDBSwitchAccessoryWidth = 104;
static const CGFloat kDBStepperAccessoryWidth = 114;
static const CGFloat kDBIndicatorAccessoryWidth = 30;
static const CGFloat kDBTwoPaneMinWidth = 700;
static const CGFloat kDBPromptBarHeight = 74;
static const CGFloat kDBQrSide = 96;

@interface DBSettingsScreen () <UITableViewDataSource, UITableViewDelegate,
                                UIActionSheetDelegate>
@end

@implementation DBSettingsScreen {
  DBCoreBridge *_core;
  DBBootConfig *_boot;
  DBTexts *_texts;
  // Only handed to the notice dialog; nothing on this screen is coloured from it.
  DBUiPalette *_palette;
  DBNoticeDialog *_noticeDialog;

  NSDictionary *_cfg;
  NSDictionary *_status;
  NSDictionary *_audio;
  NSDictionary *_localTime;
  NSString *_nodeId;
  NSArray *_sections;  // [{title, id, icon, rows:[DBSettingsRow]}]
  NSArray *_groups;    // the selected category's rows, split into table groups
  dispatch_queue_t _volumeWriteQueue;
  NSMutableDictionary *_volumeWriteGenerations;
  NSMutableDictionary *_pendingVolumeValues;
  NSMutableDictionary *_volumeSliders;  // configuration key -> DBVolumeSlider
  NSInteger _loadGeneration;
  NSTimer *_clockTimer;
  NSUInteger _clockGeneration;
  BOOL _clockReadPending;
  BOOL _screenVisible;

  // Two panes on an iPad, as in the system Settings app: categories left, the chosen
  // category's rows right, each under its own bar. A narrower view drills down on one bar.
  // Only one category is ever built into cells, which keeps the A4 from laying out about
  // 60 rows at once.
  BOOL _modeApplied;
  BOOL _twoPane;
  BOOL _drillDetail;
  DBNavBar *_masterNav;
  UINavigationItem *_masterRoot;
  DBNavBar *_nav;
  UINavigationItem *_navRoot;
  UINavigationItem *_categoryItem;
  UIBarButtonItem *_closeItem;
  UITableView *_categoryTable;
  UITableView *_table;
  UIView *_divider;
  DBHomeTabs *_tabs;
  CGFloat _categoryWidth;
  CGFloat _tableWidth;
  NSString *_selectedId;
  NSInteger _selectedSection;
  NSDictionary *_pairing;

  UIView *_footer;
  UIImageView *_qrImage;
  UILabel *_footerLabel;
  NSString *_qrUrl;

  // The transient message shown on the navigation item's prompt line.
  NSString *_promptText;
  UINavigationItem *_promptItem;
  NSUInteger _promptGeneration;

  DBSettingsRow *_pendingChoiceRow;

  // Native editors for list and form settings (DBSettingsPages), and this screen's prompts.
  DBEditorView *_editor;
  DBSettingsPages *_pages;
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
    _groups = [NSArray array];
    [self buildUi];
  }
  return self;
}

- (NSString *)screenName {
  return @"settings";
}

- (void)buildUi {
  self.backgroundColor = DBChromeScreenBackground();

  _categoryTable = DBChromeGroupedTable(self, self);
  _categoryTable.accessibilityIdentifier = @"settings_categories";
  [self addSubview:_categoryTable];

  _table = DBChromeGroupedTable(self, self);
  [self addSubview:_table];

  _footer = [[UIView alloc] initWithFrame:CGRectZero];
  _footer.backgroundColor = [UIColor clearColor];
  _qrImage = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, kDBQrSide, kDBQrSide)];
  _qrImage.isAccessibilityElement = YES;
  [_footer addSubview:_qrImage];
  _footerLabel = DBChromeSectionFooterLabel();
  [_footer addSubview:_footerLabel];

  _masterNav = [[DBNavBar alloc] init];
  _masterRoot = [_masterNav setRootTitle:@"" backTitle:nil onBack:nil];
  [self addSubview:_masterNav.bar];
  _nav = [[DBNavBar alloc] init];
  [self addSubview:_nav.bar];

  _divider = [[UIView alloc] init];
  _divider.backgroundColor = [UIColor colorWithWhite:0.55f alpha:1];
  [self addSubview:_divider];

  _editor = [[DBEditorView alloc] initWithNavBar:_nav];
  __weak DBSettingsScreen *weakSelf = self;
  _editor.onClose = ^{
    DBSettingsScreen *screen = weakSelf;
    if (!screen) return;
    [screen->_pages close];
    [screen reload];
  };
  _editor.onMessage = ^(NSString *message) { [weakSelf showToast:message]; };
  _editor.onStackChanged = ^{ [weakSelf applyPrompt]; };
  [self addSubview:_editor];

  _tabs = [[DBHomeTabs alloc] initWithRouter:_router tab:DBHomeTabSettings];
  [self addSubview:_tabs.bar];

  [self applyMode:CGRectGetWidth(self.bounds) >= kDBTwoPaneMinWidth];

  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(clockDidEnterBackground:)
      name:UIApplicationDidEnterBackgroundNotification object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(clockDidBecomeActive:)
      name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (void)onScreenWillAppear {
  _screenVisible = YES;
  [_tabs syncSelection];
  [self reload];
  [self startClockUpdates];
}

- (void)onScreenWillDisappear {
  _screenVisible = NO;
  [_editor closeAllPages];
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
  (void)timer;
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
      for (DBSettingsRow *row in [screen selectedRows]) {
        if (![row.argument isEqualToString:@"local_clock"]) continue;
        row.value = iso;
        NSIndexPath *path = [screen indexPathForRow:row];
        if (path == nil) continue;
        UITableViewCell *cell = [screen->_table cellForRowAtIndexPath:path];
        cell.detailTextLabel.text = iso;
        [cell setNeedsLayout];
      }
    });
  });
}

- (void)clockDidEnterBackground:(NSNotification *)notification {
  (void)notification;
  [self stopClockUpdates];
}

- (void)clockDidBecomeActive:(NSNotification *)notification {
  (void)notification;
  [self startClockUpdates];
}

- (void)dealloc {
  [_clockTimer invalidate];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  _categoryTable.dataSource = nil;
  _categoryTable.delegate = nil;
  _table.dataSource = nil;
  _table.delegate = nil;
}

- (BOOL)volumeBeingDragged {
  for (DBVolumeSlider *slider in [_volumeSliders allValues])
    if (slider.editingVolume) return YES;
  return NO;
}

- (void)reload {
  if ([self volumeBeingDragged]) return;
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
      screen->_palette = [DBUiPalette paletteForConfig:cfg deviceId:nodeId
                                               display:[DBConfigUtil dig:status path:@"display"]
                                         backgroundHex:nil minuteOfDay:[screen minuteOfDay]];
      [screen rebuildSections];
    });
  });
}

- (NSInteger)minuteOfDay {
  NSInteger hh = [DBConfigUtil intVal:_localTime path:@"hh" def:-1];
  if (hh < 0) return 12 * 60;
  return hh * 60 + [DBConfigUtil intVal:_localTime path:@"mm" def:0];
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

- (NSDictionary *)section:(NSString *)titleKey rows:(NSArray *)rows icon:(NSString *)icon {
  return [NSDictionary dictionaryWithObjectsAndKeys:
      [_texts ts:titleKey], @"title", rows, @"rows", titleKey, @"id", icon, @"icon", nil];
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

// choices: [[value, label], ...]. Up to three are offered as a segmented control when it
// fits beside the title; otherwise the row opens an action sheet.
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

// A choice kept in boot.json on this device rather than in the cluster configuration.
- (DBSettingsRow *)localChoiceRow:(NSString *)title key:(NSString *)key value:(NSString *)value
                          choices:(NSArray *)choices {
  DBSettingsRow *row = DBRow(title, value, @"local_choice", key);
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

- (DBSettingsRow *)pageRow:(NSString *)title value:(NSString *)value page:(NSString *)page {
  return DBRow(title, value ?: @"", @"page", page);
}

- (void)applyEditorTexts {
  _editor.cancelTitle = [_texts ts:@"admin.cancel"];
  _editor.okTitle = [_texts ts:@"editor.ok"];
  _editor.confirmTitle = [_texts ts:@"editor.confirm"];
  _editor.setText = [_texts ts:@"editor.secret_set"];
  _editor.unsetText = [_texts ts:@"editor.secret_unset"];
  _editor.customColorTitle = [_texts ts:@"editor.custom_color"];
  _editor.searchPlaceholder = [_texts ts:@"editor.search"];
}

- (void)openPage:(NSString *)name {
  if (_pages == nil) _pages = [[DBSettingsPages alloc] initWithRouter:_router editor:_editor
                                                               nodeId:_nodeId];
  _pages.nodeId = _nodeId;
  [self applyEditorTexts];
  DBEditPage *page = [_pages pageNamed:name];
  if (page == nil) return;
  [self bringSubviewToFront:_editor];
  [_editor pushPage:page];
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
  NSMutableArray *languages = [NSMutableArray array];
  for (NSString *lang in @[ @"ja", @"en", @"zh" ])
    [languages addObject:@[ lang, [DBTexts langDisplayName:lang] ]];
  [rows addObject:[self localChoiceRow:[_texts ts:@"settings.ui_lang"] key:@"ui_lang"
                                 value:[DBTexts langDisplayName:_boot.uiLang]
                               choices:languages]];
  [rows addObject:[self localChoiceRow:[_texts ts:@"settings.helper_mode"]
                                   key:@"keepalive_helper"
                                 value:(_boot.keepaliveHelperPolicy ?: @"off")
                               choices:@[ @[ @"off", @"off" ], @[ @"auto", @"auto" ],
                                          @[ @"on", @"on" ] ]]];
  NSString *configured = [DBConfigUtil str:_cfg path:@"display.appearance"] ?: @"auto_system";
  NSString *effective = [DBUiTheme appearanceModeForConfig:_cfg deviceId:_nodeId
                                                   display:[DBConfigUtil dig:_status
                                                                       path:@"display"]
                                               minuteOfDay:[self minuteOfDay]];
  DBSettingsRow *appearance = DBRow([_texts ts:@"theme.appearance"],
                                    [self appearanceLabel:configured effective:effective],
                                    @"choose",
                                    [@"display.appearance|" stringByAppendingString:configured]);
  appearance.choices = @[ @[ @"auto_schedule", [_texts ts:@"theme.appearance_auto_schedule"] ],
                          @[ @"light", [_texts ts:@"theme.mode_light"] ],
                          @[ @"dark", [_texts ts:@"theme.mode_dark"] ] ];
  [rows addObject:DBGroupStart(appearance)];
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
  [rows addObject:[self pageRow:[_texts ts:@"settings.theme_bg"]
                          value:([self themeBackgroundHex] ?: @"") page:@"theme"]];
  [rows addObject:DBGroupStart([self pageRow:[_texts ts:@"editor.wording"] value:nil
                                        page:@"wording"])];
  [rows addObject:[self pageRow:[_texts ts:@"editor.admin_password"] value:nil
                           page:@"admin_password"]];
  [rows addObject:[self pageRow:[_texts ts:@"editor.config_transfer"] value:nil
                           page:@"config_transfer"]];
  // No "leave the kiosk" row here: on this jailbroken iPad the app *is* the kiosk,
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
  id servers = [DBConfigUtil dig:_cfg path:@"time.ntp.servers"];
  [rows addObject:[self pageRow:[_texts ts:@"time.servers"]
                          value:([servers isKindOfClass:[NSArray class]]
                                     ? [(NSArray *)servers componentsJoinedByString:@", "] : @"")
                           page:@"ntp_servers"]];
  long long lastSync = [DBConfigUtil longLongVal:_status path:@"time.last_sync_ms" def:0];
  [rows addObject:DBGroupStart(DBRow([_texts ts:@"time.last_sync"],
                        lastSync > 0 ? [NSString stringWithFormat:@"%lld ms",
                            [DBConfigUtil longLongVal:_status path:@"time.offset_ms" def:0]]
                                     : [_texts ts:@"time.never"], @"", nil))];
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
      [rows addObject:DBGroupStart(DBRow(label,
                                         notice ? [DBNoticeModel noticeText:notice]
                                                : [_texts ts:@"notice.none"],
                                         @"notice", door))];
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
  [rows addObject:DBGroupStart(DBRow([_texts ts:@"dash.notice_global"], @"", @"notice", @""))];
  [rows addObject:[self pageRow:[_texts ts:@"notice.presets"] value:nil page:@"notice_presets"]];
  [rows addObject:[self pageRow:[_texts ts:@"editor.places"] value:nil page:@"places"]];
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
  [rows addObject:[self pageRow:[_texts ts:@"editor.purposes_edit"] value:nil page:@"purposes"]];
  return rows;
}

- (NSArray *)ruleRows {
  NSMutableArray *rows = [NSMutableArray array];
  // Each rule switches on and off here; the rule editor changes what it does.
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
  [rows addObject:[self pageRow:[_texts ts:@"prefs.rule_edit"] value:nil page:@"rules"]];
  [rows addObject:[self stepperRow:[_texts ts:@"prefs.retention"] key:@"events.retention_days"
                               def:90 min:1 max:3650 step:30
                              unit:[_texts ts:@"prefs.unit_days"]]];
  id quiet = [DBConfigUtil dig:_cfg path:@"quiet_hours"];
  [rows addObject:[self pageRow:[_texts ts:@"settings.quiet_hours"]
                          value:[_texts ts:(quiet ? @"settings.configured"
                                                  : @"settings.not_configured")]
                           page:@"quiet_hours"]];
  BOOL telegram = [[DBConfigUtil str:_cfg path:@"integrations.telegram.bot_token_ref"] length] > 0;
  [rows addObject:[self pageRow:@"Telegram"
                          value:[_texts ts:(telegram ? @"settings.configured"
                                                     : @"settings.not_configured")]
                           page:@"telegram"]];
  [rows addObject:[self pageRow:@"SIP" value:[DBConfigUtil str:_cfg path:@"sip.server"] page:@"sip"]];
  [rows addObject:[self pageRow:[_texts ts:@"editor.mqtt"]
                          value:[DBConfigUtil str:_cfg path:@"integrations.mqtt.host"]
                           page:@"mqtt"]];
  [rows addObject:[self pageRow:[_texts ts:@"editor.secrets"] value:nil page:@"secrets"]];
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
                        @"page", @"devices")];
  // Security protocol v3 state, from the pairing snapshot. The key rows form one group that
  // ends with the destructive rotation.
  NSMutableArray *keyRows = [NSMutableArray array];
  NSDictionary *security = [_pairing isKindOfClass:[NSDictionary class]]
      ? [_pairing objectForKey:@"security"] : nil;
  if ([security isKindOfClass:[NSDictionary class]]) {
    NSString *psk = [DBConfigUtil str:security path:@"psk_id"] ?: @"";
    if ([psk length] > 0)
      [keyRows addObject:DBRow([_texts ts:@"prefs.cluster_key"], psk, @"", nil)];
    NSInteger stale = 0;
    for (NSString *key in @[ @"legacy_peers", @"rekey_required" ]) {
      id list = [security objectForKey:key];
      if ([list isKindOfClass:[NSArray class]]) stale += (NSInteger)[(NSArray *)list count];
    }
    if (stale > 0)
      [keyRows addObject:DBRow([_texts ts:@"prefs.members_need_rejoin"],
                               [_texts t:@"pair.members_need_rejoin",
                                    [NSString stringWithFormat:@"%ld", (long)stale], nil],
                               @"", nil)];
  }
  BOOL paired = [[DBConfigUtil str:_pairing path:@"state"] isEqualToString:@"ready"];
  BOOL canRotate = [DBCoreBridge supportsKeyRotation] && paired;
  if (canRotate) {
    DBSettingsRow *rotate = DBRow([_texts ts:@"prefs.rotate_key"], @"", @"rotate_key", nil);
    rotate.destructive = YES;
    [keyRows addObject:rotate];
  }
  if ([keyRows count] > 0) {
    DBSettingsRow *first = DBGroupStart([keyRows objectAtIndex:0]);
    if (canRotate) first.groupFooter = [_texts ts:@"prefs.rotate_key_footer"];
    [rows addObjectsFromArray:keyRows];
  }
  [rows addObject:DBGroupStart([self pageRow:[_texts ts:@"prefs.panels"] value:nil
                                        page:@"panels"])];
  NSDictionary *sources = [DBConfigUtil dig:_cfg path:@"media_sources"];
  [rows addObject:[self pageRow:[_texts ts:@"prefs.media_sources"]
                          value:([sources isKindOfClass:[NSDictionary class]] && [sources count]
                                     ? [NSString stringWithFormat:@"%lu", (unsigned long)[sources count]]
                                     : nil)
                           page:@"media_sources"]];
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
  [rows addObject:[self pageRow:[_texts ts:@"editor.sounds"] value:nil page:@"sounds"]];
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
  NSDictionary *replies = [DBConfigUtil dig:_cfg path:@"quick_replies"];
  [rows addObject:[self pageRow:[_texts ts:@"prefs.quick_replies"]
                          value:([replies isKindOfClass:[NSDictionary class]]
                                     ? [NSString stringWithFormat:@"%lu", (unsigned long)[replies count]]
                                     : nil)
                           page:@"quick_replies"]];
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
  if ([self volumeBeingDragged]) return;
  NSMutableArray *sections = [NSMutableArray array];
  [sections addObject:[self section:@"settings.section_device" rows:[self deviceRows]
                               icon:@"device-tablet"]];
  NSMutableArray *sound = [NSMutableArray arrayWithArray:[self volumeRows]];
  NSArray *soundRows = [self soundRows];
  if ([sound count] > 0 && [soundRows count] > 0) DBGroupStart([soundRows objectAtIndex:0]);
  [sound addObjectsFromArray:soundRows];
  [sections addObject:[self section:@"prefs.sounds" rows:sound icon:@"volume"]];
  [sections addObject:[self section:@"prefs.display" rows:[self displayRows] icon:@"palette"]];
  [sections addObject:[self section:@"prefs.calls" rows:[self callRows] icon:@"phone"]];
  [sections addObject:[self section:@"settings.section_doors" rows:[self doorRows]
                               icon:@"door"]];
  NSArray *purposes = [self purposeRows];
  if ([purposes count] > 0)
    [sections addObject:[self section:@"settings.section_purposes" rows:purposes
                                 icon:@"message-reply"]];
  [sections addObject:[self section:@"prefs.sos" rows:[self sosRows] icon:@"shield-lock"]];
  [sections addObject:[self section:@"settings.section_time" rows:[self timeRows]
                               icon:@"clock"]];
  [sections addObject:[self section:@"settings.section_rules" rows:[self ruleRows]
                               icon:@"bell"]];
  [sections addObject:[self section:@"settings.section_cluster" rows:[self clusterRows]
                               icon:@"topology-star-3"]];
  [sections addObject:[self section:@"settings.section_history"
                               rows:[NSArray arrayWithObject:
                                        DBRow([_texts ts:@"history.title"], @"",
                                              @"history", nil)]
                               icon:@"list"]];
  [sections addObject:[self section:@"settings.section_info" rows:[self infoRows]
                               icon:@"info-circle"]];
  _sections = sections;
  _selectedSection = 0;
  for (NSUInteger i = 0; i < [sections count]; i++)
    if ([[[sections objectAtIndex:i] objectForKey:@"id"] isEqualToString:_selectedId])
      _selectedSection = (NSInteger)i;
  _selectedId = [[sections objectAtIndex:(NSUInteger)_selectedSection] objectForKey:@"id"];
  [self regroup];

  [_tabs applyTexts:_texts];
  [self applyEditorTexts];
  [self refreshChrome];
  [self updateFooter];
  [_categoryTable reloadData];
  [self syncCategorySelection];
  [_table reloadData];
  [self setNeedsLayout];
}

#pragma mark - panes

- (NSArray *)selectedRows {
  if (_selectedSection < 0 || _selectedSection >= (NSInteger)[_sections count]) return nil;
  return [[_sections objectAtIndex:(NSUInteger)_selectedSection] objectForKey:@"rows"];
}

- (NSString *)detailTitle {
  if (_selectedSection < 0 || _selectedSection >= (NSInteger)[_sections count]) return nil;
  return [[_sections objectAtIndex:(NSUInteger)_selectedSection] objectForKey:@"title"];
}

- (void)regroup {
  NSMutableArray *groups = [NSMutableArray array];
  NSMutableArray *current = nil;
  for (DBSettingsRow *row in [self selectedRows]) {
    if (current == nil || row.startsGroup) {
      current = [NSMutableArray array];
      [groups addObject:current];
    }
    [current addObject:row];
  }
  _groups = groups;
}

- (DBSettingsRow *)rowAt:(NSIndexPath *)indexPath {
  if (indexPath.section < 0 || indexPath.section >= (NSInteger)[_groups count]) return nil;
  NSArray *rows = [_groups objectAtIndex:(NSUInteger)indexPath.section];
  if (indexPath.row < 0 || indexPath.row >= (NSInteger)[rows count]) return nil;
  return [rows objectAtIndex:(NSUInteger)indexPath.row];
}

- (NSIndexPath *)indexPathForRow:(DBSettingsRow *)row {
  for (NSUInteger section = 0; section < [_groups count]; section++) {
    NSUInteger index = [[_groups objectAtIndex:section] indexOfObjectIdenticalTo:row];
    if (index != NSNotFound)
      return [NSIndexPath indexPathForRow:(NSInteger)index inSection:(NSInteger)section];
  }
  return nil;
}

// Controls carry the row's position in the selected category as their tag.
- (DBSettingsRow *)rowForControlTag:(NSInteger)tag {
  NSArray *rows = [self selectedRows];
  if (tag < 0 || tag >= (NSInteger)[rows count]) return nil;
  return [rows objectAtIndex:(NSUInteger)tag];
}

// The door station has no tab bar to leave by, so its root page carries Close.
- (void)refreshChrome {
  NSString *settingsTitle = [_texts ts:@"settings.title"];
  UIBarButtonItem *close = nil;
  if (![DBHomeTabs shownForRole:_router.boot.role]) {
    if (_closeItem == nil) _closeItem = DBChromeBarItem(@"", self, @selector(onClose));
    _closeItem.title = [_texts ts:@"settings.close"];
    close = _closeItem;
  }
  _masterRoot.title = settingsTitle;
  if (_twoPane) {
    _navRoot.title = [self detailTitle] ?: @"";
    if (_navRoot.leftBarButtonItem != nil) _navRoot.leftBarButtonItem = nil;
    if (_masterRoot.leftBarButtonItem != close) _masterRoot.leftBarButtonItem = close;
  } else {
    _navRoot.title = settingsTitle;
    _categoryItem.title = [self detailTitle] ?: @"";
    if (_masterRoot.leftBarButtonItem != nil) _masterRoot.leftBarButtonItem = nil;
    if (_navRoot.leftBarButtonItem != close) _navRoot.leftBarButtonItem = close;
  }
  _masterNav.bar.hidden = !_twoPane;
  _divider.hidden = !_twoPane;
  _categoryTable.hidden = !_twoPane && _drillDetail;
  _table.hidden = !_twoPane && !_drillDetail;
}

- (void)applyMode:(BOOL)twoPane {
  if (_modeApplied && twoPane == _twoPane) return;
  _modeApplied = YES;
  _twoPane = twoPane;
  [_editor closeAllPages];
  _drillDetail = NO;
  _categoryItem = nil;
  _navRoot = [_nav setRootTitle:@"" backTitle:nil onBack:nil];
  [self refreshChrome];
  [self applyPrompt];
  [_categoryTable reloadData];
  [self syncCategorySelection];
  [_table reloadData];
}

// Two panes keep the chosen category highlighted, as the system Settings app does.
- (void)syncCategorySelection {
  if (!_twoPane || _selectedSection < 0 || _selectedSection >= (NSInteger)[_sections count])
    return;
  [_categoryTable selectRowAtIndexPath:[NSIndexPath indexPathForRow:_selectedSection inSection:0]
                              animated:NO scrollPosition:UITableViewScrollPositionNone];
}

- (void)selectCategory:(NSInteger)index {
  if (index < 0 || index >= (NSInteger)[_sections count]) return;
  BOOL changed = index != _selectedSection;
  if (_twoPane && !changed && _editor.pageCount == 0) return;
  [_editor closeAllPages];
  _selectedSection = index;
  _selectedId = [[_sections objectAtIndex:(NSUInteger)index] objectForKey:@"id"];
  [self regroup];
  if (!_twoPane) {
    __weak DBSettingsScreen *weakSelf = self;
    _categoryItem = [_nav pushTitle:[self detailTitle] onPop:^{
      DBSettingsScreen *screen = weakSelf;
      if (!screen) return;
      screen->_drillDetail = NO;
      screen->_categoryItem = nil;
      [screen refreshChrome];
      [screen applyPrompt];
    }];
    _drillDetail = YES;
  }
  [self refreshChrome];
  [self applyPrompt];
  [_table reloadData];
  [_table setContentOffset:CGPointZero animated:NO];
}

#pragma mark - footer

- (NSString *)versionLine {
  NSDictionary *power = [_core powerStateNow];
  NSInteger battery = [DBConfigUtil intVal:power path:@"battery_pct" def:-1];
  BOOL charging = [DBConfigUtil boolVal:power path:@"charging" def:NO];
  NSString *appVersion = [[NSBundle mainBundle]
      objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
  return [DBUiTheme versionLineForName:nil coreVersion:[_core coreVersion]
                           appVersion:appVersion batteryPct:battery charging:charging];
}

// The admin page's QR code, its address, and the version line close every category.
- (void)updateFooter {
  NSString *url = [self adminUrl];
  NSString *caption = [_texts ts:@"web_admin.scan"];
  _qrImage.accessibilityLabel = caption;
  _footerLabel.text = [NSString stringWithFormat:@"%@\n%@\n%@", caption, url,
                                                 [self versionLine] ?: @""];
  if (![url isEqualToString:_qrUrl]) {
    _qrUrl = [url copy];
    __weak DBSettingsScreen *weakSelf = self;
    // QR generation is pure CPU work and stays off the main thread of an A4 device.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
      UIImage *code = [DBQrCode imageForString:url targetPx:kDBQrSide * 2];
      dispatch_async(dispatch_get_main_queue(), ^{
        DBSettingsScreen *screen = weakSelf;
        if (screen && [screen->_qrUrl isEqualToString:url]) screen->_qrImage.image = code;
      });
    });
  }
  [self layoutFooter];
}

- (void)layoutFooter {
  CGFloat width = CGRectGetWidth(_table.bounds);
  if (width <= 0) return;
  CGFloat inset = DBChromeIsFlat() ? 15 : 20;
  CGFloat labelWidth = MAX(80, width - inset * 2);
  CGFloat labelHeight = ceil([_footerLabel.text ?: @"" sizeWithFont:_footerLabel.font
      constrainedToSize:CGSizeMake(labelWidth, 400)
          lineBreakMode:NSLineBreakByWordWrapping].height);
  // The footer label is centred before iOS 7 and leading on the flat look; the code follows.
  CGFloat qrX = DBChromeIsFlat() ? inset : floor((width - kDBQrSide) / 2);
  _qrImage.frame = CGRectMake(qrX, 8, kDBQrSide, kDBQrSide);
  _footerLabel.frame = CGRectMake(inset, 8 + kDBQrSide + 8, labelWidth, labelHeight);
  CGRect frame = CGRectMake(0, 0, width, CGRectGetMaxY(_footerLabel.frame) + 20);
  if (_table.tableFooterView != _footer || !CGRectEqualToRect(_footer.frame, frame)) {
    _footer.frame = frame;
    _table.tableFooterView = _footer;
  }
}

#pragma mark - messages

// A short message rides the navigation item's prompt line for a few seconds; one that would
// not fit there, or that has several lines, is an alert the operator acknowledges.
- (void)showToast:(NSString *)text {
  if ([text length] == 0) return;
  CGFloat room = CGRectGetWidth(_nav.bar.bounds) - 24;
  BOOL fits = [text rangeOfString:@"\n"].location == NSNotFound &&
      [text sizeWithFont:[UIFont systemFontOfSize:15]].width <= room;
  if (!fits) {
    [[[UIAlertView alloc] initWithTitle:nil message:text delegate:nil
                      cancelButtonTitle:[_texts ts:@"editor.ok"] otherButtonTitles:nil] show];
    return;
  }
  _promptText = [text copy];
  NSUInteger generation = ++_promptGeneration;
  [self applyPrompt];
  __weak DBSettingsScreen *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
    DBSettingsScreen *screen = weakSelf;
    if (!screen || screen->_promptGeneration != generation) return;
    screen->_promptText = nil;
    [screen applyPrompt];
  });
}

// The prompt follows the page on top of the detail bar. A bar with a prompt is taller, so
// the master bar takes a blank one to stay level with it.
- (void)applyPrompt {
  UINavigationItem *top = _nav.topItem;
  if (_promptItem != top && _promptItem.prompt != nil) _promptItem.prompt = nil;
  _promptItem = top;
  if (top.prompt != _promptText && ![top.prompt isEqualToString:_promptText])
    top.prompt = _promptText;
  NSString *masterPrompt = (_twoPane && _promptText != nil) ? @" " : nil;
  if (_masterRoot.prompt != masterPrompt && ![_masterRoot.prompt isEqualToString:masterPrompt])
    _masterRoot.prompt = masterPrompt;
  [self setNeedsLayout];
}

#pragma mark - actions

- (void)setLocalKey:(NSString *)key value:(NSString *)next {
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
    [self showToast:[_texts ts:(status == -100 ? @"editor.core_too_old"
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

- (void)promptNumberForKey:(NSString *)key title:(NSString *)title current:(NSString *)current
                       min:(NSInteger)min max:(NSInteger)max {
  if ([key length] == 0) return;
  __weak DBSettingsScreen *weakSelf = self;
  [_editor promptTitle:[NSString stringWithFormat:@"%@ (%ld–%ld)", title, (long)min, (long)max]
                 value:[NSString stringWithFormat:@"%ld", (long)[current integerValue]]
           placeholder:nil keyboard:UIKeyboardTypeNumberPad secure:NO
                  then:^(NSString *text) {
    DBSettingsScreen *screen = weakSelf;
    if (!screen) return;
    NSString *value = [text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSInteger number = [value integerValue];
    if ([value length] == 0 || number < min || number > max) {
      [screen showToast:[screen->_texts ts:@"settings.save_failed"]];
      return;
    }
    [screen reportWriteStatus:[screen->_core setConfigKey:key numberValue:number]];
  }];
}

- (void)promptNumberForRow:(DBSettingsRow *)row {
  NSArray *parts = [row.argument componentsSeparatedByString:@"|"];
  // "key|min|max" for a number row, "key|min|max|step|value" for a stepper row.
  if ([parts count] != 3 && [parts count] != 5) return;
  [self promptNumberForKey:[parts objectAtIndex:0] title:row.title current:row.value
                       min:[[parts objectAtIndex:1] integerValue]
                       max:[[parts objectAtIndex:2] integerValue]];
}

- (void)toggleForRow:(DBSettingsRow *)row {
  NSArray *parts = [row.argument componentsSeparatedByString:@"|"];
  if ([parts count] != 2) return;
  BOOL current = [[parts objectAtIndex:1] integerValue] != 0;
  [self reportWriteStatus:[_core setConfigKey:[parts objectAtIndex:0] boolValue:!current]];
}

- (void)inheritForRow:(DBSettingsRow *)row {
  // Clearing the device key restores inheritance from the cluster default.
  [self reportWriteStatus:[_core deleteConfigKey:row.argument]];
}

// The zone list is a searchable page. Core publishes the zones it can actually resolve; the
// built-in list is the fallback for a core that does not report them.
- (void)openZonePickerForKey:(NSString *)key {
  id zones = [DBConfigUtil dig:_status path:@"time.zones"];
  NSArray *all = ([zones isKindOfClass:[NSArray class]] && [(NSArray *)zones count] > 0)
      ? (NSArray *)zones : DBCommonTimeZones();
  NSString *current = [DBConfigUtil str:_status path:@"time.zone"];
  if ([current length] == 0) current = [DBConfigUtil str:_cfg path:@"time.zone"];
  __weak DBSettingsScreen *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  DBEditPage *page = [DBEditPage title:[_texts ts:@"time.zone"] build:^NSArray *{
    NSString *query = [editor.filterText stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray *shown = [NSMutableArray array];
    for (id zone in all) {
      if (![zone isKindOfClass:[NSString class]]) continue;
      if ([query length] == 0 ||
          [zone rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound)
        [shown addObject:zone];
    }
    // Anything the operator types is offered too: Core owns the real table and
    // rejects an identifier it does not know.
    if ([shown count] == 0 && [query rangeOfString:@"/"].location != NSNotFound)
      [shown addObject:query];
    NSMutableArray *fields = [NSMutableArray array];
    for (NSString *zone in shown) {
      DBEditField *field = [DBEditField kind:DBEditKindAction title:zone value:zone];
      field.checked = [zone isEqualToString:current];
      field.action = ^{
        DBSettingsScreen *screen = weakSelf;
        if (!screen) return;
        [editor popPage];
        [screen reportWriteStatus:[screen->_core setConfigKey:key stringValue:zone]];
      };
      [fields addObject:field];
    }
    return @[ [DBEditSection title:nil fields:fields] ];
  }];
  page.searchable = YES;
  page.filtersItself = YES;
  page.searchPlaceholder = [_texts ts:@"settings.zone_search"];
  [self applyEditorTexts];
  [self bringSubviewToFront:_editor];
  [_editor pushPage:page];
}

- (void)promptDeviceName {
  __weak DBSettingsScreen *weakSelf = self;
  [_editor promptTitle:[_texts ts:@"settings.device_name"] value:_boot.name placeholder:nil
              keyboard:UIKeyboardTypeDefault secure:NO then:^(NSString *text) {
    DBSettingsScreen *screen = weakSelf;
    if (!screen) return;
    NSString *name = [text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([name length] == 0 || [name length] > 64 || [screen->_nodeId length] == 0) {
      [screen showToast:[screen->_texts ts:@"settings.save_failed"]];
      return;
    }
    if ([name isEqualToString:screen->_boot.name]) return;
    // The replicated identity handler persists boot.json without leaving the settings screen.
    [screen reportWriteStatus:[screen->_core setConfigKey:[NSString stringWithFormat:
        @"devices.%@.name", screen->_nodeId] stringValue:name]];
  }];
}

- (void)syncTimeNow {
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
}

- (void)performAction:(DBSettingsRow *)row {
  NSString *action = row.action;
  if ([action length] == 0) return;
  if ([action isEqualToString:@"device_name"]) {
    [self promptDeviceName];
  } else if ([action isEqualToString:@"page"]) {
    [self openPage:row.argument];
  } else if ([action isEqualToString:@"number"] || [action isEqualToString:@"stepper"]) {
    // A tap on a stepper row asks for a typed value, which a wide range needs.
    [self promptNumberForRow:row];
  } else if ([action isEqualToString:@"toggle"]) {
    [self toggleForRow:row];
  } else if ([action isEqualToString:@"inherit"]) {
    [self inheritForRow:row];
  } else if ([action isEqualToString:@"zone"]) {
    [self openZonePickerForKey:row.argument];
  } else if ([action isEqualToString:@"time_sync"]) {
    [self syncTimeNow];
  } else if ([action isEqualToString:@"notice"]) {
    [self openNoticeDialogForDoor:row.argument];
  } else if ([action isEqualToString:@"segment"]) {
    // The segmented control handles taps itself; without one the row offers the sheet.
    if ([self segmentWidthForRow:row] <= 0) [self presentChoicesForRow:row];
  } else if ([action isEqualToString:@"choose"] || [action isEqualToString:@"local_choice"]) {
    [self presentChoicesForRow:row];
  } else if ([action isEqualToString:@"role_toggle"]) {
    [self toggleRoleForRow:row];
  } else if ([action isEqualToString:@"rotate_key"]) {
    __weak DBSettingsScreen *weakSelf = self;
    [_editor confirmTitle:[_texts ts:@"prefs.rotate_key"]
                  message:[_texts ts:@"prefs.rotate_key_confirm"]
                     then:^{ [weakSelf rotateClusterKey]; }];
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
  DBSettingsRow *row = [self rowForControlTag:sender.tag];
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
  DBSettingsRow *row = [self rowForControlTag:sender.tag];
  NSArray *parts = [row.argument componentsSeparatedByString:@"|"];
  if ([parts count] != 5) return;
  // Writes on release only: each change is a replicated config write.
  [self reportWriteStatus:[_core setConfigKey:[parts objectAtIndex:0]
                                  numberValue:(NSInteger)sender.value]];
}

- (UITableViewCell *)cellContaining:(UIView *)view {
  while (view && ![view isKindOfClass:[UITableViewCell class]]) view = view.superview;
  return (UITableViewCell *)view;
}

- (void)onStepperChanged:(UIStepper *)sender {
  UITableViewCell *cell = [self cellContaining:sender];
  DBSettingsRow *row = [self rowForControlTag:sender.tag];
  if (!cell || !row) return;
  NSRange space = [row.value rangeOfString:@" "];
  NSString *unit = space.location == NSNotFound ? @"" : [row.value substringFromIndex:space.location];
  cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld%@", (long)sender.value, unit];
  [cell setNeedsLayout];
  // UIStepper reports no release on iOS 5; writing after a short pause keeps
  // a run of taps to one replicated config write.
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(onStepper:)
                                             object:sender];
  [self performSelector:@selector(onStepper:) withObject:sender afterDelay:0.7];
}

- (void)onSegment:(UISegmentedControl *)sender {
  DBSettingsRow *row = [self rowForControlTag:sender.tag];
  NSInteger index = sender.selectedSegmentIndex;
  if (row == nil || index < 0 || index >= (NSInteger)[row.choices count]) return;
  NSString *key = [[row.argument componentsSeparatedByString:@"|"] objectAtIndex:0];
  [self reportWriteStatus:[_core setConfigKey:key
      stringValue:[[row.choices objectAtIndex:(NSUInteger)index] objectAtIndex:0]]];
}

- (void)presentChoicesForRow:(DBSettingsRow *)row {
  if ([row.choices count] == 0) return;
  UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:row.title delegate:self
      cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:nil];
  for (NSArray *choice in row.choices) [sheet addButtonWithTitle:[choice objectAtIndex:1]];
  sheet.cancelButtonIndex = [sheet addButtonWithTitle:[_texts ts:@"admin.cancel"]];
  _pendingChoiceRow = row;
  NSIndexPath *path = [self indexPathForRow:row];
  if (DBChromeIsPad() && path != nil) {
    [sheet showFromRect:[_table rectForRowAtIndexPath:path] inView:_table animated:YES];
  } else {
    [sheet showInView:self];
  }
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)buttonIndex {
  DBSettingsRow *row = _pendingChoiceRow;
  _pendingChoiceRow = nil;
  if (row == nil || buttonIndex == sheet.cancelButtonIndex || buttonIndex < 0 ||
      buttonIndex >= (NSInteger)[row.choices count]) return;
  NSString *value = [[row.choices objectAtIndex:(NSUInteger)buttonIndex] objectAtIndex:0];
  if ([row.action isEqualToString:@"local_choice"]) {
    [self setLocalKey:row.argument value:value];
    return;
  }
  NSString *key = [[row.argument componentsSeparatedByString:@"|"] objectAtIndex:0];
  [self reportWriteStatus:[_core setConfigKey:key stringValue:value]];
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

#pragma mark - volume

- (void)updateVolumeLabel:(DBVolumeSlider *)slider {
  UITableViewCell *cell = [self cellContaining:slider];
  cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld", (long)(slider.value + 0.5)];
  [cell setNeedsLayout];
}

- (void)onVolumeChanged:(DBVolumeSlider *)slider {
  slider.pendingVolume = (NSInteger)(slider.value + 0.5);
  [self updateVolumeLabel:slider];
}

- (void)commitVolume:(DBVolumeSlider *)slider {
  NSInteger value = slider.pendingVolume;
  NSString *key = slider.configKey;
  slider.editingVolume = NO;
  slider.value = value;
  NSLog(@"[doorbell] volume slider committed %ld", (long)value);
  if (!_volumeWriteQueue) {
    _volumeWriteQueue = dispatch_queue_create("doorbell.volume-writes", DISPATCH_QUEUE_SERIAL);
    _volumeWriteGenerations = [NSMutableDictionary dictionary];
    _pendingVolumeValues = [NSMutableDictionary dictionary];
  }
  NSUInteger generation = [[_volumeWriteGenerations objectForKey:key] unsignedIntegerValue] + 1;
  [_volumeWriteGenerations setObject:@(generation) forKey:key];
  [_pendingVolumeValues setObject:@(value) forKey:key];
  DBCoreBridge *core = _core;
  __weak DBSettingsScreen *weakSelf = self;
  dispatch_async(_volumeWriteQueue, ^{
    int result = [core setConfigKey:key numberValue:value];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBSettingsScreen *current = weakSelf;
      if (!current || [[current->_volumeWriteGenerations objectForKey:key]
                          unsignedIntegerValue] != generation) return;
      if (result != 0) [current->_pendingVolumeValues removeObjectForKey:key];
      [current reportWriteStatus:result];
    });
  });
}

- (void)cancelVolume:(DBVolumeSlider *)slider {
  NSLog(@"[doorbell] volume slider cancelled at %ld", (long)slider.pendingVolume);
  slider.editingVolume = NO;
  slider.value = slider.savedValue;
  [self updateVolumeLabel:slider];
}

- (DBVolumeSlider *)volumeSliderForRow:(DBSettingsRow *)row width:(CGFloat)width {
  NSString *key = [[row.argument componentsSeparatedByString:@"|"] objectAtIndex:0];
  if (_volumeSliders == nil) _volumeSliders = [NSMutableDictionary dictionary];
  DBVolumeSlider *slider = [_volumeSliders objectForKey:key];
  if (slider == nil) {
    slider = [[DBVolumeSlider alloc] initWithFrame:CGRectMake(0, 0, width, 34)];
    slider.configKey = key;
    slider.minimumValue = 0;
    slider.maximumValue = 100;
    slider.continuous = YES;
    slider.accessibilityIdentifier = key;
    [slider addTarget:self action:@selector(onVolumeChanged:)
     forControlEvents:UIControlEventValueChanged];
    __weak DBSettingsScreen *weakSelf = self;
    __weak DBVolumeSlider *weakSlider = slider;
    slider.onBegin = ^{
      weakSlider.editingVolume = YES;
      weakSlider.pendingVolume = (NSInteger)(weakSlider.value + 0.5);
    };
    slider.onEnd = ^(float value) {
      DBVolumeSlider *current = weakSlider;
      if (!current) return;
      current.pendingVolume = (NSInteger)(value + 0.5);
      [weakSelf commitVolume:current];
    };
    slider.onCancel = ^{
      DBVolumeSlider *current = weakSlider;
      if (current) [weakSelf cancelVolume:current];
    };
    [_volumeSliders setObject:slider forKey:key];
  }
  slider.accessibilityLabel = row.title;
  if (!slider.editingVolume && ![slider isTracking]) {
    slider.bounds = CGRectMake(0, 0, width, 34);
    slider.savedValue = [row.value floatValue];
    slider.value = slider.savedValue;
    slider.pendingVolume = (NSInteger)slider.savedValue;
  }
  return slider;
}

#pragma mark - table

- (BOOL)isVolumeRow:(DBSettingsRow *)row {
  return [row.action isEqualToString:@"volume_slider"];
}

- (CGFloat)volumeSliderWidth {
  return MAX(120, MIN(280, floor(DBEditCellTextWidth(_table, 0, 0) * 0.5f)));
}

// The width of the row's segmented control, or zero when the row has none: more than three
// choices, or a control that would not leave room for the title.
- (CGFloat)segmentWidthForRow:(DBSettingsRow *)row {
  if (![row.action isEqualToString:@"segment"] || [row.choices count] == 0) return 0;
  CGFloat widest = 0;
  for (NSArray *choice in row.choices)
    widest = MAX(widest, [[choice objectAtIndex:1]
        sizeWithFont:[UIFont boldSystemFontOfSize:13]].width);
  CGFloat width = ceil(MAX(56, widest + 24)) * [row.choices count];
  CGFloat title = [row.title sizeWithFont:[UIFont boldSystemFontOfSize:17]].width;
  return title + width + 24 <= DBEditCellTextWidth(_table, 0, 0) ? width : 0;
}

- (BOOL)opensElsewhere:(DBSettingsRow *)row {
  for (NSString *action in @[ @"page", @"zone", @"add_device", @"history", @"info" ])
    if ([row.action isEqualToString:action]) return YES;
  return NO;
}

- (CGFloat)accessoryWidthForRow:(DBSettingsRow *)row {
  NSString *action = row.action;
  if ([action isEqualToString:@"toggle"] || [action isEqualToString:@"role_toggle"])
    return kDBSwitchAccessoryWidth;
  if ([action isEqualToString:@"stepper"]) return kDBStepperAccessoryWidth;
  if ([self isVolumeRow:row]) return [self volumeSliderWidth] + 20;
  CGFloat segment = [self segmentWidthForRow:row];
  if (segment > 0) return segment + 20;
  return [self opensElsewhere:row] ? kDBIndicatorAccessoryWidth : 0;
}

- (NSString *)detailForRow:(DBSettingsRow *)row {
  if ([self isVolumeRow:row])
    return [NSString stringWithFormat:@"%ld", (long)([row.value floatValue] + 0.5f)];
  if ([self segmentWidthForRow:row] > 0) return @"";
  return row.value;
}

- (DBEditCellLayout)layoutForRow:(DBSettingsRow *)row {
  return DBEditCellLayoutMake(row.title, [self detailForRow:row],
                              DBEditCellTextWidth(_table, [self accessoryWidthForRow:row], 0));
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return tableView == _categoryTable ? 1 : (NSInteger)[_groups count];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  if (tableView == _categoryTable) return (NSInteger)[_sections count];
  return section < (NSInteger)[_groups count]
      ? (NSInteger)[[_groups objectAtIndex:(NSUInteger)section] count] : 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
  if (tableView == _categoryTable || section >= (NSInteger)[_groups count]) return nil;
  NSString *footer = [(DBSettingsRow *)[[_groups objectAtIndex:(NSUInteger)section]
      objectAtIndex:0] groupFooter];
  return [footer length] > 0 ? footer : nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
  if (tableView == _categoryTable) return 44;
  return [self layoutForRow:[self rowAt:indexPath]].height;
}

- (UITableViewCell *)categoryCellForRow:(NSInteger)index {
  static NSString *identifier = @"category";
  UITableViewCell *cell = [_categoryTable dequeueReusableCellWithIdentifier:identifier];
  if (cell == nil) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                  reuseIdentifier:identifier];
    // Long category names shrink instead of being cut off.
    cell.textLabel.adjustsFontSizeToFitWidth = YES;
    cell.textLabel.minimumFontSize = 12;
    cell.textLabel.lineBreakMode = NSLineBreakByTruncatingTail;
  }
  NSDictionary *section = [_sections objectAtIndex:(NSUInteger)index];
  cell.textLabel.text = [section objectForKey:@"title"];
  cell.imageView.image = [DBIconAsset imageNamed:[section objectForKey:@"icon"]];
  cell.accessoryType = _twoPane ? UITableViewCellAccessoryNone
                                : UITableViewCellAccessoryDisclosureIndicator;
  return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  if (tableView == _categoryTable) return [self categoryCellForRow:indexPath.row];
  DBSettingsRow *row = [self rowAt:indexPath];
  UITableViewCell *cell = DBEditDequeueCell(tableView, [self layoutForRow:row].style,
                                            row.destructive);
  cell.textLabel.text = row.title;
  cell.detailTextLabel.text = [self detailForRow:row];
  NSUInteger index = [[self selectedRows] indexOfObjectIdenticalTo:row];
  UIView *control = index == NSNotFound ? nil : [self controlForRow:row index:(NSInteger)index];
  if (control != nil) {
    // A volume slider outlives its cell. Its former cell lets go of it first, or that cell
    // would pull the slider out of this one when it is reused.
    UITableViewCell *former = [self cellContaining:control];
    if (former != nil && former != cell) former.accessoryView = nil;
    cell.accessoryView = control;
  } else if ([self opensElsewhere:row]) {
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
  }
  BOOL tappable = [row.action length] > 0 &&
      (control == nil || [row.action isEqualToString:@"stepper"]);
  if (!tappable) cell.selectionStyle = UITableViewCellSelectionStyleNone;
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
  if ([self isVolumeRow:row] && [parts count] >= 1)
    return [self volumeSliderForRow:row width:[self volumeSliderWidth]];
  CGFloat segmentWidth = [self segmentWidthForRow:row];
  if (segmentWidth > 0) {
    NSMutableArray *labels = [NSMutableArray array];
    NSInteger selected = UISegmentedControlNoSegment;
    NSString *current = [parts count] == 2 ? [parts objectAtIndex:1] : @"";
    for (NSUInteger i = 0; i < [row.choices count]; i++) {
      NSArray *choice = [row.choices objectAtIndex:i];
      [labels addObject:[choice objectAtIndex:1]];
      if ([[choice objectAtIndex:0] isEqualToString:current]) selected = (NSInteger)i;
    }
    UISegmentedControl *segment = [[UISegmentedControl alloc] initWithItems:labels];
    // The compact stock style; it is the only one on iOS 7 and later.
    segment.segmentedControlStyle = UISegmentedControlStyleBar;
    segment.frame = CGRectMake(0, 0, segmentWidth, 30);
    segment.selectedSegmentIndex = selected;
    segment.tag = index;
    segment.accessibilityLabel = row.title;
    [segment addTarget:self action:@selector(onSegment:) forControlEvents:UIControlEventValueChanged];
    return segment;
  }
  return nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  if (tableView == _categoryTable) {
    if (!_twoPane) [tableView deselectRowAtIndexPath:indexPath animated:NO];
    [self selectCategory:indexPath.row];
    return;
  }
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  [self performAction:[self rowAt:indexPath]];
}

#pragma mark - layout

// One pass places everything. 1024x768: 320 pt of categories, a 1 pt rule, 703 pt of detail.
// 768x1024: 280 + 1 + 487. Below 700 pt (the phone family) the category list and the detail
// share the full width under one bar.
- (void)layoutSubviews {
  [super layoutSubviews];
  CGRect bounds = self.bounds;
  CGFloat width = CGRectGetWidth(bounds);
  CGFloat height = MAX(0, CGRectGetHeight(bounds) - [_tabs layoutInBounds:bounds]);
  [self applyMode:width >= kDBTwoPaneMinWidth];

  CGFloat bar = _promptText != nil ? kDBPromptBarHeight : DBChromeNavBarHeight();
  CGFloat body = MAX(0, height - bar);
  CGRect detail;
  if (_twoPane) {
    CGFloat master = width >= 900 ? 320 : 280;
    _masterNav.bar.frame = CGRectMake(0, 0, master, bar);
    _categoryTable.frame = CGRectMake(0, bar, master, body);
    _divider.frame = CGRectMake(master, 0, 1, height);
    CGFloat detailX = master + 1;
    _nav.bar.frame = CGRectMake(detailX, 0, width - detailX, bar);
    detail = CGRectMake(detailX, bar, width - detailX, body);
  } else {
    _nav.bar.frame = CGRectMake(0, 0, width, bar);
    detail = CGRectMake(0, bar, width, body);
    _categoryTable.frame = detail;
  }
  _table.frame = detail;
  _editor.frame = detail;
  _noticeDialog.frame = bounds;

  // Row heights, segmented controls, and the footer follow the pane widths.
  if (CGRectGetWidth(_categoryTable.frame) != _categoryWidth) {
    _categoryWidth = CGRectGetWidth(_categoryTable.frame);
    [_categoryTable reloadData];
    [self syncCategorySelection];
  }
  if (CGRectGetWidth(detail) != _tableWidth) {
    _tableWidth = CGRectGetWidth(detail);
    [self layoutFooter];
    if (![self volumeBeingDragged]) [_table reloadData];
  }
}

@end
