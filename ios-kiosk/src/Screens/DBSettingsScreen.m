#import "DBSettingsScreen.h"

#import "../Core/DBBootConfig.h"
#import "../Core/DBConfigUtil.h"
#import "../Core/DBCoreBridge.h"
#import "../Core/DBNoticeModel.h"
#import "../Core/DBTexts.h"
#import "../Core/DBUiTheme.h"
#import "../Support/DBSafeModeRecovery.h"
#import "DBNoticeDialog.h"
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
@end

@implementation DBSettingsRow
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

@interface DBSettingsScreen () <UITableViewDataSource, UITableViewDelegate>
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
  NSInteger _loadGeneration;

  UILabel *_title;
  UIButton *_close;
  UITableView *_table;
  DBAdminQrView *_qr;
  UILabel *_toast;
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
  _title.font = [UIFont boldSystemFontOfSize:28];
  [self addSubview:_title];

  _close = [UIButton buttonWithType:UIButtonTypeCustom];
  _close.titleLabel.font = [UIFont boldSystemFontOfSize:18];
  _close.layer.cornerRadius = 8;
  _close.clipsToBounds = YES;
  [_close addTarget:self action:@selector(onClose) forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_close];

  _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
  _table.dataSource = self;
  _table.delegate = self;
  _table.rowHeight = 68;  // Large rows: this is a wall panel, not a phone.
  [self addSubview:_table];

  _qr = [[DBAdminQrView alloc] initWithFrame:CGRectZero];
  [self addSubview:_qr];

  _toast = [[UILabel alloc] init];
  _toast.backgroundColor = [UIColor clearColor];
  _toast.font = [UIFont systemFontOfSize:16];
  _toast.textAlignment = NSTextAlignmentCenter;
  [self addSubview:_toast];
}

- (void)onScreenWillAppear {
  [self reload];
}

- (void)onScreenWillDisappear {
  [_noticeDialog dismiss];
}

- (void)reload {
  NSInteger generation = ++_loadGeneration;
  DBCoreBridge *core = _core;
  __weak DBSettingsScreen *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSDictionary *cfg = [core config];
    NSDictionary *status = [core status];
    NSString *nodeId = [DBConfigUtil str:status path:@"node.id"] ?: @"";
    NSDictionary *audio = [core audioJsonForDevice:nodeId];
    NSDictionary *localTime = [core localTimeJson:0];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBSettingsScreen *screen = weakSelf;
      if (!screen || screen->_loadGeneration != generation) return;
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
  _palette = [DBUiPalette paletteForConfig:_cfg deviceId:_nodeId backgroundHex:nil
                               minuteOfDay:[self minuteOfDay]];
  self.backgroundColor = _palette.surface;
  _title.textColor = _palette.ink;
  _toast.textColor = _palette.mutedInk;
  _close.backgroundColor = _palette.elevated;
  [_close setTitleColor:_palette.ink forState:UIControlStateNormal];
  _table.backgroundColor = _palette.surface;
  _table.separatorColor = _palette.separator;
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
  return [NSString stringWithFormat:@"http://%@:%ld/admin/", [DBConfigUtil urlHost:host],
                                    (long)_boot.httpPort];
}

#pragma mark - sections

- (NSDictionary *)section:(NSString *)titleKey rows:(NSArray *)rows {
  return [NSDictionary dictionaryWithObjectsAndKeys:
      [_texts ts:titleKey], @"title", rows, @"rows", nil];
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
  [rows addObject:DBRow([_texts ts:@"settings.device_name"], _boot.name, @"", nil)];
  [rows addObject:DBRow([_texts ts:@"settings.device_role"], [self roleLabel], @"", nil)];
  if ([_boot.door length] > 0)
    [rows addObject:DBRow([_texts ts:@"settings.device_door"], _boot.door, @"", nil)];
  [rows addObject:DBRow([_texts ts:@"settings.ui_lang"],
                        [DBTexts langDisplayName:_boot.uiLang], @"ui_lang", nil)];
  [rows addObject:DBRow([_texts ts:@"settings.helper_mode"],
                        _boot.keepaliveHelperPolicy ?: @"off", @"helper_mode", nil)];
  NSString *appearance = [DBUiTheme appearanceModeForConfig:_cfg deviceId:_nodeId
                                                minuteOfDay:[self minuteOfDay]];
  [rows addObject:[self webOnlyRow:[_texts ts:@"settings.appearance"]
                             value:[_texts ts:([appearance isEqualToString:@"light"]
                                                   ? @"settings.appearance_light"
                                                   : @"settings.appearance_dark")]]];
  NSString *playback = [DBConfigUtil str:_cfg path:[NSString stringWithFormat:
      @"devices.%@.local.video.playback", _nodeId]] ?: @"low_latency";
  [rows addObject:[self webOnlyRow:[_texts ts:@"settings.video_playback"] value:playback]];
  NSString *rotation = [DBConfigUtil str:_cfg path:[NSString stringWithFormat:
      @"devices.%@.local.video.rotation", _nodeId]] ?: @"auto";
  [rows addObject:[self webOnlyRow:[_texts ts:@"settings.video_rotation"] value:rotation]];
  [rows addObject:[self webOnlyRow:[_texts ts:@"settings.theme_bg"]
                             value:([self themeBackgroundHex] ?: @"")]];
  [rows addObject:[self webOnlyRow:[_texts ts:@"settings.web_only_upload"] value:@""]];
  if (_boot.kiosk)
    [rows addObject:DBRow([_texts ts:@"settings.exit_kiosk"], @"", @"exit_kiosk", nil)];
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
  for (NSArray *level in levels) {
    NSString *key = [level objectAtIndex:0];
    NSInteger value = [DBConfigUtil intVal:_audio path:key def:-1];
    [rows addObject:[self webOnlyRow:[_texts ts:[level objectAtIndex:1]]
                               value:(value < 0 ? @"" : [NSString stringWithFormat:@"%ld",
                                                          (long)value])]];
  }
  return rows;
}

- (NSArray *)timeRows {
  NSMutableArray *rows = [NSMutableArray array];
  NSString *zone = [DBConfigUtil str:_status path:@"time.zone"];
  if ([zone length] == 0) zone = [DBConfigUtil str:_cfg path:@"time.zone"];
  [rows addObject:[self webOnlyRow:[_texts ts:@"time.zone"] value:(zone ?: @"")]];
  NSString *source = [DBConfigUtil str:_status path:@"time.source"] ?: @"system";
  [rows addObject:DBRow([_texts ts:@"time.source"],
                        [_texts ts:([source isEqualToString:@"ntp"] ? @"time.source_ntp"
                                                                    : @"time.source_system")],
                        @"", nil)];
  BOOL ntpOn = [DBConfigUtil boolVal:_status path:@"time.enabled" def:NO];
  [rows addObject:[self webOnlyRow:[_texts ts:@"time.ntp_enabled"]
                             value:[_texts ts:(ntpOn ? @"settings.on" : @"settings.off")]]];
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
    [rows addObject:DBRow([_texts ts:@"time.local_now"], iso, @"", nil)];
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
      BOOL showUnlock = [DBConfigUtil boolVal:_cfg
          path:[NSString stringWithFormat:@"doors.%@.unlock.show_button", door] def:NO];
      [rows addObject:[self webOnlyRow:[_texts ts:@"settings.unlock_button"]
                                 value:[_texts ts:(showUnlock ? @"settings.on"
                                                              : @"settings.off")]]];
    }
  }
  [rows addObject:DBRow([_texts ts:@"dash.notice_global"], @"", @"notice", @"")];
  return rows;
}

- (NSArray *)purposeRows {
  NSMutableArray *rows = [NSMutableArray array];
  NSDictionary *purposes = [DBConfigUtil dig:_cfg path:@"visit_purposes"];
  if ([purposes isKindOfClass:[NSDictionary class]]) {
    for (NSString *purpose in [DBConfigUtil sortedByOrder:purposes]) {
      NSDictionary *entry = [purposes objectForKey:purpose];
      BOOL enabled = [DBConfigUtil boolVal:entry path:@"enabled" def:YES];
      [rows addObject:[self webOnlyRow:[DBConfigUtil labelOf:entry lang:_boot.uiLang
                                                    fallback:purpose]
                                 value:[_texts ts:(enabled ? @"settings.on"
                                                           : @"settings.off")]]];
    }
  }
  return rows;
}

- (NSArray *)ruleRows {
  NSMutableArray *rows = [NSMutableArray array];
  NSDictionary *rules = [DBConfigUtil dig:_cfg path:@"rules"];
  NSInteger count = [rules isKindOfClass:[NSDictionary class]] ? (NSInteger)[rules count] : 0;
  [rows addObject:[self webOnlyRow:[_texts ts:@"admin.rules"]
                             value:[_texts t:@"settings.rules_count",
                                        [NSString stringWithFormat:@"%ld", (long)count], nil]]];
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
  return rows;
}

- (NSArray *)infoRows {
  NSMutableArray *rows = [NSMutableArray array];
  NSDictionary *power = [_core powerStateNow];
  NSInteger battery = [DBConfigUtil intVal:power path:@"battery_pct" def:-1];
  BOOL charging = [DBConfigUtil boolVal:power path:@"charging" def:NO];
  NSString *appVersion = [[NSBundle mainBundle]
      objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
  [rows addObject:DBRow([_texts ts:@"info.version"],
                        [DBUiTheme versionLineForName:nil coreVersion:[_core coreVersion]
                                           appVersion:appVersion batteryPct:battery
                                             charging:charging], @"", nil)];
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
  NSMutableArray *sections = [NSMutableArray array];
  [sections addObject:[self section:@"settings.section_device" rows:[self deviceRows]]];
  [sections addObject:[self section:@"settings.section_volume" rows:[self volumeRows]]];
  [sections addObject:[self section:@"settings.section_time" rows:[self timeRows]]];
  [sections addObject:[self section:@"settings.section_doors" rows:[self doorRows]]];
  NSArray *purposes = [self purposeRows];
  if ([purposes count] > 0)
    [sections addObject:[self section:@"settings.section_purposes" rows:purposes]];
  [sections addObject:[self section:@"settings.section_rules" rows:[self ruleRows]]];
  [sections addObject:[self section:@"settings.section_cluster" rows:[self clusterRows]]];
  [sections addObject:[self section:@"settings.section_history"
                               rows:[NSArray arrayWithObject:
                                        DBRow([_texts ts:@"history.title"], @"",
                                              @"history", nil)]]];
  [sections addObject:[self section:@"settings.section_info" rows:[self infoRows]]];
  _sections = sections;

  _title.text = [_texts ts:@"settings.title"];
  [_close setTitle:[_texts ts:@"settings.close"] forState:UIControlStateNormal];
  [_qr setUrl:[self adminUrl] caption:[_texts ts:@"web_admin.scan"]];
  [_table reloadData];
  [self setNeedsLayout];
}

#pragma mark - actions

- (DBSettingsRow *)rowAt:(NSIndexPath *)indexPath {
  if (indexPath.section < 0 || indexPath.section >= (NSInteger)[_sections count]) return nil;
  NSArray *rows = [[_sections objectAtIndex:(NSUInteger)indexPath.section] objectForKey:@"rows"];
  if (indexPath.row < 0 || indexPath.row >= (NSInteger)[rows count]) return nil;
  return [rows objectAtIndex:(NSUInteger)indexPath.row];
}

- (void)showToast:(NSString *)text {
  _toast.text = text;
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

- (void)performAction:(DBSettingsRow *)row {
  NSString *action = row.action;
  if ([action length] == 0) return;
  if ([action isEqualToString:@"web"]) {
    [self showToast:[_texts ts:@"settings.web_only"]];
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
      BOOL started = [core timeSyncNow];
      dispatch_async(dispatch_get_main_queue(), ^{
        DBSettingsScreen *screen = weakSelf;
        if (!screen) return;
        [screen showToast:[screen->_texts ts:(started ? @"time.sync_started"
                                                      : @"time.sync_failed")]];
        if (started) [screen reload];
      });
    });
  } else if ([action isEqualToString:@"notice"]) {
    [self openNoticeDialogForDoor:row.argument];
  } else if ([action isEqualToString:@"add_device"]) {
    [_router showAddDevice];
  } else if ([action isEqualToString:@"history"]) {
    [_router showHistory];
  } else if ([action isEqualToString:@"info"]) {
    [_router showInfo];
  } else if ([action isEqualToString:@"exit_kiosk"]) {
    [self showToast:[_texts ts:@"settings.web_only"]];
  }
}

- (void)onClose {
  [_router closeSettingsAnimated:YES];
}

#pragma mark - table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  (void)tableView;
  return (NSInteger)[_sections count];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  (void)tableView;
  if (section < 0 || section >= (NSInteger)[_sections count]) return 0;
  return (NSInteger)[[[_sections objectAtIndex:(NSUInteger)section]
      objectForKey:@"rows"] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
  (void)tableView;
  if (section < 0 || section >= (NSInteger)[_sections count]) return nil;
  return [[_sections objectAtIndex:(NSUInteger)section] objectForKey:@"title"];
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  static NSString *identifier = @"setting";
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
  if (cell == nil) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                  reuseIdentifier:identifier];
  }
  DBSettingsRow *row = [self rowAt:indexPath];
  cell.textLabel.text = row.title;
  cell.textLabel.font = [UIFont systemFontOfSize:20];
  cell.textLabel.numberOfLines = 2;
  cell.detailTextLabel.font = [UIFont systemFontOfSize:17];
  cell.detailTextLabel.text = row.webOnly && [row.value length] == 0
      ? [_texts ts:@"settings.web_only"] : row.value;
  cell.textLabel.textColor = _palette.ink;
  cell.detailTextLabel.textColor = row.webOnly ? _palette.mutedInk : _palette.ink;
  cell.backgroundColor = _palette.elevated;
  cell.textLabel.backgroundColor = [UIColor clearColor];
  cell.detailTextLabel.backgroundColor = [UIColor clearColor];
  cell.accessoryType = ([row.action length] > 0 && !row.webOnly)
      ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
  cell.selectionStyle = [row.action length] > 0 ? UITableViewCellSelectionStyleGray
                                                : UITableViewCellSelectionStyleNone;
  return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  [self performAction:[self rowAt:indexPath]];
}

#pragma mark - layout

- (void)layoutSubviews {
  [super layoutSubviews];
  CGSize size = self.bounds.size;
  CGFloat pad = 20;
  _title.frame = CGRectMake(pad, 16, size.width - 2 * pad - 120, 36);
  _close.frame = CGRectMake(size.width - pad - 110, 16, 110, 40);
  CGFloat footer = 96;
  _table.frame = CGRectMake(0, 64, size.width, MAX(0, size.height - 64 - footer));
  _qr.frame = CGRectMake(pad, size.height - footer + 6, MIN(360, size.width - 2 * pad), 80);
  _toast.frame = CGRectMake(CGRectGetMaxX(_qr.frame) + 12, size.height - footer + 30,
                            MAX(0, size.width - CGRectGetMaxX(_qr.frame) - 12 - pad), 30);
  _noticeDialog.frame = self.bounds;
}

@end
