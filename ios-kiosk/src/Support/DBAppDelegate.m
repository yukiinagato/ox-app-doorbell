#import "DBAppDelegate.h"
#import "../Core/DBBootConfig.h"
#import "../Core/DBCompatibilityProfile.h"
#import "../Core/DBConfigUtil.h"
#import "../Core/DBCoreBridge.h"
#import "../Core/DBSemanticStyle.h"
#import "../Core/DBTexts.h"
#import "../Media/DBH264Player.h"
#import "../Media/DBLowLatencyH264Player.h"
#import "../Media/DBVtVideoView.h"
#import "../Net/DBMjpegClient.h"
#import "../Core/DBPairUri.h"
#import "../Screens/DBPairingScreen.h"
#import "../Screens/DBRouter.h"
#import "../Screens/DBIncomingScreen.h"
#import "../Screens/DBDoorScreen.h"
#import "DBWatchdog.h"
#import "DBRecoveryClient.h"
#import "DBSafeModeRecovery.h"
#import "../Media/DBCameraFeeder.h"
#import "../Media/DBCameraEncoder.h"
#import "doorbell/doorbell.h"
#import <math.h>

void DBH264Dbg(NSString *fmt, ...);

static NSString *const DBRecoveryCleanExitKey = @"runtime.clean_exit";
static NSString *const DBRecoveryLaunchesKey = @"runtime.unexpected_launches";
static NSString *const DBRecoverySafeModeKey = @"runtime.safe_mode";
static NSString *const DBRecoveryGenerationKey = @"runtime.generation";
static NSString *const DBRecoveryLastExitReasonKey = @"runtime.last_exit_reason";
static NSString *const DBWatchdogBackoffIndexKey = @"runtime.watchdog_backoff_index";
static NSString *const DBRecoveryMaintenanceMarkerPath =
    @"/var/mobile/Documents/.doorbell-maintenance-restart";

static NSString *DBBoundedRuntimeToken(NSString *value) {
  if (![value isKindOfClass:[NSString class]] || [value length] == 0) return @"unknown";
  NSMutableString *bounded = [NSMutableString string];
  NSUInteger limit = MIN((NSUInteger)128, [value length]);
  for (NSUInteger index = 0; index < limit; index++) {
    unichar character = [value characterAtIndex:index];
    BOOL valid = (character >= 'a' && character <= 'z') ||
        (character >= 'A' && character <= 'Z') ||
        (character >= '0' && character <= '9') || character == '_' ||
        character == '-' || character == '.' || character == ':';
    [bounded appendFormat:@"%C", (unichar)(valid ? character : '_')];
  }
  return [bounded length] > 0 ? bounded : @"unknown";
}

static BOOL DBPrepareLocalRecoveryState(void) {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
  NSFileManager *files = [NSFileManager defaultManager];
  BOOL maintenanceRestart = [files fileExistsAtPath:DBRecoveryMaintenanceMarkerPath];
  if (maintenanceRestart) [files removeItemAtPath:DBRecoveryMaintenanceMarkerPath error:NULL];
  NSNumber *previousClean = [defaults objectForKey:DBRecoveryCleanExitKey] == nil
      ? nil : @([defaults boolForKey:DBRecoveryCleanExitKey]);
  if (maintenanceRestart) previousClean = @YES;
  NSArray *recent = nil;
  [DBRecoveryClient
      shouldEnterSafeModeWithPreviousCleanExit:previousClean
                                      launches:[defaults arrayForKey:DBRecoveryLaunchesKey] ?: @[]
                                           now:now updatedLaunches:&recent];
  BOOL safeMode = NO;
  NSInteger previousGeneration = [defaults integerForKey:DBRecoveryGenerationKey];
  NSInteger generation = previousGeneration >= 0 && previousGeneration < NSIntegerMax
      ? previousGeneration + 1 : 1;
  NSString *lastExitReason = [defaults stringForKey:DBRecoveryLastExitReasonKey];
  if (maintenanceRestart)
    lastExitReason = @"maintenance_restart";
  else if (previousClean == nil && [lastExitReason length] == 0)
    lastExitReason = @"first_launch";
  else if (previousClean != nil && ![previousClean boolValue])
    lastExitReason = @"unexpected_termination";
  else if ([lastExitReason length] == 0)
    lastExitReason = @"clean_exit";
  [defaults setObject:recent forKey:DBRecoveryLaunchesKey];
  [defaults setBool:safeMode forKey:DBRecoverySafeModeKey];
  [defaults setInteger:generation forKey:DBRecoveryGenerationKey];
  [defaults setObject:DBBoundedRuntimeToken(lastExitReason)
                forKey:DBRecoveryLastExitReasonKey];
  [defaults setBool:NO forKey:DBRecoveryCleanExitKey];
  [defaults synchronize];
  return safeMode;
}

static void DBMarkCleanExit(void) {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  [defaults setBool:YES forKey:DBRecoveryCleanExitKey];
  [defaults setObject:@"clean_exit" forKey:DBRecoveryLastExitReasonKey];
  [defaults synchronize];
}

static void DBMarkHealthyRuntime(void) {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  [defaults setBool:NO forKey:DBRecoverySafeModeKey];
  [defaults setObject:@[] forKey:DBRecoveryLaunchesKey];
  [defaults setInteger:0 forKey:DBWatchdogBackoffIndexKey];
  [defaults setObject:@"healthy_runtime" forKey:DBRecoveryLastExitReasonKey];
  // The process is still running. Keep clean_exit false so a later crash is
  // counted as one new failure instead of being hidden by the healthy window.
  [defaults setBool:NO forKey:DBRecoveryCleanExitKey];
  [defaults synchronize];
}

static BOOL DBNativeKioskAvailable(void);
static BOOL DBNativeKioskHealthy(void);

static BOOL DBSupportsUIManifest(NSString *role) {
  return [role isEqualToString:@"door_station"] ||
      [role isEqualToString:@"indoor_panel"];
}

static NSDictionary *DBUIElement(BOOL safetyCritical, NSArray *properties) {
  return @{
    @"properties" : properties,
    @"safety_critical" : @(safetyCritical),
  };
}

static NSDictionary *DBUIDefaults(NSString *elementID, NSArray *properties) {
  NSString *foreground = @"#FFFFFF";
  NSString *background = @"#292E33";
  NSString *border = @"#4DA3FF";
  if ([elementID isEqualToString:@"call.primary"]) {
    background = @"#187A3C";
    border = @"#FFFFFF";
  } else if ([elementID isEqualToString:@"cancel.call"] ||
             [elementID isEqualToString:@"call.end"]) {
    background = @"#BF2921";
    border = @"#FFFFFF";
  } else if ([elementID isEqualToString:@"sos.trigger"]) {
    background = @"#C7140F";
    border = @"#FFFFFF";
  } else if ([elementID isEqualToString:@"sos.cancel"]) {
    foreground = @"#8C0D0A";
    background = @"#FFFFFF";
    border = @"#8C0D0A";
  } else if ([elementID isEqualToString:@"ring.title"])
    background = @"#0A0D12";

  NSMutableDictionary *defaults = [NSMutableDictionary dictionary];
  if ([properties containsObject:@"scale"]) [defaults setObject:@1 forKey:@"scale"];
  if ([properties containsObject:@"font_scale"])
    [defaults setObject:@1 forKey:@"font_scale"];
  if ([properties containsObject:@"foreground"])
    [defaults setObject:foreground forKey:@"foreground"];
  if ([properties containsObject:@"background"])
    [defaults setObject:background forKey:@"background"];
  if ([properties containsObject:@"accent"])
    [defaults setObject:@"#4DA3FF" forKey:@"accent"];
  if ([properties containsObject:@"border"])
    [defaults setObject:border forKey:@"border"];
  if ([properties containsObject:@"radius"])
    [defaults setObject:@12 forKey:@"radius"];
  return defaults;
}

static NSDictionary *DBUIManifest(NSString *role) {
  NSDictionary *elements = @{};
  if ([role isEqualToString:@"door_station"]) {
    // Only advertise semantic elements that this shell actually reads from
    // devices.<self>.local.ui.elements.*.
    elements = @{
      @"call.primary" : DBUIElement(NO, @[
        @"scale", @"font_scale", @"foreground", @"background", @"border", @"radius"
      ]),
      @"cancel.call" : DBUIElement(YES, @[
        @"scale", @"font_scale", @"foreground", @"background", @"border", @"radius"
      ]),
      @"call.end" : DBUIElement(YES, @[
        @"scale", @"font_scale", @"foreground", @"background", @"border", @"radius"
      ]),
      @"purpose.button" : DBUIElement(NO, @[
        @"font_scale", @"foreground", @"background", @"border", @"radius"
      ]),
      @"sos.cancel" : DBUIElement(YES, @[
        @"scale", @"font_scale", @"foreground", @"background", @"border", @"radius"
      ]),
    };
  } else if ([role isEqualToString:@"indoor_panel"]) {
    elements = @{
      @"sos.trigger" : DBUIElement(YES, @[
        @"scale", @"font_scale", @"foreground", @"background", @"border", @"radius"
      ]),
      @"sos.cancel" : DBUIElement(YES, @[
        @"scale", @"font_scale", @"foreground", @"background", @"border", @"radius"
      ]),
      @"ring.title" : DBUIElement(NO, @[
        @"font_scale", @"foreground", @"background"
      ]),
      @"ring.action" : DBUIElement(NO, @[
        @"font_scale", @"foreground", @"background", @"border", @"radius"
      ]),
      @"call.end" : DBUIElement(YES, @[
        @"font_scale", @"foreground", @"background", @"border", @"radius"
      ]),
      @"reply.button" : DBUIElement(NO, @[
        @"font_scale", @"foreground", @"background", @"border", @"radius"
      ]),
      @"monitor.close" : DBUIElement(YES, @[
        @"font_scale", @"foreground", @"background", @"border", @"radius"
      ]),
    };
  }
  NSMutableDictionary *manifestElements = [NSMutableDictionary dictionary];
  for (NSString *elementID in elements) {
    NSMutableDictionary *descriptor =
        [[elements objectForKey:elementID] mutableCopy];
    NSArray *properties = [descriptor objectForKey:@"properties"];
    [descriptor setObject:DBUIDefaults(elementID, properties) forKey:@"defaults"];
    [manifestElements setObject:descriptor forKey:elementID];
  }
  return @{
    @"schema_version" : @1,
    @"units" : @"pt",
    @"viewport" : @{ @"minimum_touch" : @44, @"scale_min" : @0.75,
                       @"scale_max" : @2.0 },
    @"elements" : manifestElements,
  };
}

static NSDictionary *DBShellCapabilities(DBBootConfig *boot, BOOL secureStoreAvailable,
                                         BOOL safeMode) {
  UIDevice *device = [UIDevice currentDevice];
  device.batteryMonitoringEnabled = YES;
  BOOL mains = device.batteryState == UIDeviceBatteryStateCharging ||
      device.batteryState == UIDeviceBatteryStateFull;
  BOOL wallClockSane = [[NSDate date] timeIntervalSince1970] > 1700000000.0;
  BOOL uiManifest = DBSupportsUIManifest(boot.role);
  NSDictionary *features = @{
    @"platform_v2" : @YES,
    @"call_flow_v2" : @YES,
    @"call_cancel_v2" : @YES,
    @"call_lifecycle_v2" : @YES,
    @"device_alert_v1" : @YES,
    @"ui_manifest_v1" : @(uiManifest),
    @"runtime_recovery_v1" : @YES,
    @"helper_policy_v1" : @YES,
    @"frosted_glass_radius_v1" : @YES,
  };
  NSMutableDictionary *capabilities = [@{
    // A local route is not proof of Internet or broker reachability. Operational
    // overrides remain available until a configured endpoint probe succeeds.
    @"tls12" : @NO,
    @"wan" : @NO,
    @"mains_power" : @(mains),
    @"mqtt_reachable" : @NO,
    @"wall_clock_sane" : @(wallClockSane),
    @"cpu_score" : @0,
    @"native_kiosk" : @(DBNativeKioskHealthy()),
    @"root_helper" : @NO,
    @"features" : features,
    @"device_alert_channels" : @[ @"in_app", @"system_notification" ],

    // Shell-supported features. The rtsp_h264_forwarding key is intentionally
    // absent until DESCRIBE, SETUP, and a complete IDR have succeeded at runtime.
    @"platform_v2" : @YES,
    @"https_transport" : @YES,
    @"secure_store" : @(secureStoreAvailable),
    @"ui_manifest_v1" : @(uiManifest),
    @"runtime_recovery" : @YES,
    @"microphone" : @YES,
    @"microphone_enabled" : @(boot.micEnabled),
    @"speaker" : @YES,
    // Both camera keys remain false until the capture callback delivers a frame.
    @"camera" : @NO,
    @"camera_capture" : @NO,
    @"mjpeg_http_preview" : @YES,
    @"mjpeg_https_preview" : @YES,
    @"snapshot_https_preview" : @YES,
    @"low_resource_jpeg_safe_mode" : @(safeMode),
  } mutableCopy];
#ifdef DB_IOS_COMPAT_CORE_PJSIP
  [capabilities setObject:@YES forKey:@"sip_core_pjsip_uac"];
  [capabilities setObject:@YES forKey:@"sip_core_pjsip_uas"];
#else
  [capabilities setObject:@YES forKey:@"sip_minisip_uac"];
  [capabilities setObject:@YES forKey:@"sip_minisip_uas"];
#endif
  return capabilities;
}

static BOOL DBNativeKioskAvailable(void) {
  return [[[UIDevice currentDevice] systemVersion] floatValue] >= 6.0;
}

static BOOL DBNativeKioskHealthy(void) {
  return DBNativeKioskAvailable() && UIAccessibilityIsGuidedAccessEnabled();
}




@interface DBRootController : UIViewController
@end
@implementation DBRootController
- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation {
  return YES;
}
@end

@interface DBBootstrapSetupController : UIViewController <UITextFieldDelegate>
@property(nonatomic, copy) BOOL (^onSave)(NSString *name, NSString *role, NSString *door);
- (id)initWithBoot:(DBBootConfig *)boot;
@end

@implementation DBBootstrapSetupController {
  DBBootConfig *_boot;
  DBTexts *_texts;
  UIScrollView *_scroll;
  UIView *_form;
  UILabel *_title;
  UILabel *_message;
  UILabel *_roleLabel;
  UIButton *_saveButton;
  UIButton *_doorRole;
  UIButton *_indoorRole;
  NSInteger _selectedRole;
  BOOL _automaticName;
  BOOL _automaticDoor;
  NSString *_nameIdentifier;
  UILabel *_nameLabel;
  UITextField *_name;
  UITextField *_door;
  UILabel *_doorLabel;
  UILabel *_doorHint;
}

- (id)initWithBoot:(DBBootConfig *)boot {
  self = [super initWithNibName:nil bundle:nil];
  if (self) {
    _boot = boot;
    _texts = [[DBTexts alloc] init];
    [_texts setLang:boot.uiLang];
    NSString *suffix = [[boot.name componentsSeparatedByString:@"-"] lastObject];
    NSCharacterSet *nonHex = [[NSCharacterSet characterSetWithCharactersInString:
        @"0123456789abcdef"] invertedSet];
    BOOL generated = [suffix length] == 8 &&
        [suffix rangeOfCharacterFromSet:nonHex].location == NSNotFound &&
        ([boot.name rangeOfString:@"-door-"].location != NSNotFound ||
         [boot.name rangeOfString:@"-indoor-"].location != NSNotFound);
    NSString *doorSuffix = [[boot.suggestedDoor componentsSeparatedByString:@"-"] lastObject];
    BOOL generatedDoor = [doorSuffix length] == 8 &&
        [doorSuffix rangeOfCharacterFromSet:nonHex].location == NSNotFound &&
        ([boot.suggestedDoor hasPrefix:@"door-"] ||
         [boot.suggestedDoor isEqualToString:[DBBootConfig suggestedDeviceNameForRole:
             @"door_station" identifier:doorSuffix]]);
    _nameIdentifier = generated ? suffix : generatedDoor ? doorSuffix :
        [NSString stringWithFormat:@"%08x", arc4random()];
    _automaticDoor = boot.setupRequired && generatedDoor;
    _automaticName = boot.setupRequired && (generated ||
        [boot.name isEqualToString:@"ipad1-monitor"] || [boot.name isEqualToString:@"doorbell"] ||
        [boot.name length] == 0);
  }
  return self;
}

- (UILabel *)label:(NSString *)text size:(CGFloat)size {
  UILabel *label = [[UILabel alloc] init];
  label.text = text;
  label.textColor = [UIColor colorWithWhite:0.12 alpha:1];
  label.backgroundColor = [UIColor clearColor];
  label.font = [UIFont systemFontOfSize:size];
  label.numberOfLines = 0;
  return label;
}

- (void)loadView {
  self.view = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
  self.view.backgroundColor = [UIColor colorWithWhite:0.96 alpha:1];
  _scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
  _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  _scroll.alwaysBounceVertical = YES;
  [self.view addSubview:_scroll];
  _form = [[UIView alloc] init];
  [_scroll addSubview:_form];
  _title = [self label:[_texts ts:@"setup.title"] size:32];
  _title.font = [UIFont boldSystemFontOfSize:32];
  [_form addSubview:_title];
  _message = [self label:[_texts ts:@"setup.message"] size:20];
  _message.textColor = [UIColor colorWithWhite:0.30 alpha:1];
  [_form addSubview:_message];
  _nameLabel = [self label:[_texts ts:@"setup.name"] size:22];
  _nameLabel.font = [UIFont boldSystemFontOfSize:22];
  [_form addSubview:_nameLabel];
  _name = [self textField:_boot.name];
  _name.accessibilityIdentifier = @"setup_name";
  [_name addTarget:self action:@selector(nameEdited) forControlEvents:UIControlEventEditingChanged];
  [_form addSubview:_name];
  _roleLabel = [self label:[_texts ts:@"setup.role"] size:22];
  _roleLabel.font = [UIFont boldSystemFontOfSize:22];
  [_form addSubview:_roleLabel];
  _selectedRole = [_boot.role isEqualToString:@"indoor_panel"] ? 1 : 0;
  _doorRole = [self roleButton:[_texts ts:@"admin.role_door"] index:0];
  _indoorRole = [self roleButton:[_texts ts:@"admin.role_indoor"] index:1];
  _doorLabel = [self label:[_texts ts:@"setup.door"] size:22];
  _doorLabel.font = [UIFont boldSystemFontOfSize:22];
  [_form addSubview:_doorLabel];
  _door = [self textField:_boot.suggestedDoor];
  _door.accessibilityIdentifier = @"setup_door";
  [_door addTarget:self action:@selector(doorEdited) forControlEvents:UIControlEventEditingChanged];
  [_form addSubview:_door];
  _doorHint = [self label:[_texts ts:@"setup.door_hint"] size:18];
  _doorHint.textColor = [UIColor colorWithWhite:0.30 alpha:1];
  [_form addSubview:_doorHint];
  _saveButton = [UIButton buttonWithType:UIButtonTypeCustom];
  [_saveButton setTitle:[_texts ts:@"setup.finish"] forState:UIControlStateNormal];
  [_saveButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
  _saveButton.titleLabel.font = [UIFont boldSystemFontOfSize:22];
  _saveButton.titleLabel.numberOfLines = 0;
  _saveButton.titleLabel.textAlignment = NSTextAlignmentCenter;
  _saveButton.backgroundColor = [UIColor colorWithRed:0.05 green:0.30 blue:0.65 alpha:1];
  _saveButton.layer.cornerRadius = 8;
  [_saveButton addTarget:self action:@selector(save) forControlEvents:UIControlEventTouchUpInside];
  _saveButton.accessibilityIdentifier = @"setup_save";
  [_form addSubview:_saveButton];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardChanged:)
      name:UIKeyboardWillChangeFrameNotification object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardChanged:)
      name:UIKeyboardWillHideNotification object:nil];
  [self roleChanged];
}

- (CGFloat)layoutLabel:(UILabel *)label y:(CGFloat)y width:(CGFloat)width {
  CGFloat height = ceil([label sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)].height);
  label.frame = CGRectMake(0, y, width, height);
  return y + height;
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  CGFloat width = MIN(640.0, CGRectGetWidth(self.view.bounds) - 48.0);
  CGFloat y = 0;
  y = [self layoutLabel:_title y:y width:width] + 18;
  y = [self layoutLabel:_message y:y width:width] + 28;
  y = [self layoutLabel:_nameLabel y:y width:width] + 12;
  _name.frame = CGRectMake(0, y, width, 60); y += 88;
  y = [self layoutLabel:_roleLabel y:y width:width] + 12;
  CGFloat roleWidth = (width - 12) / 2;
  CGFloat roleHeight = MAX(60.0, MAX([_doorRole.titleLabel sizeThatFits:
      CGSizeMake(roleWidth - 24, CGFLOAT_MAX)].height, [_indoorRole.titleLabel sizeThatFits:
      CGSizeMake(roleWidth - 24, CGFLOAT_MAX)].height) + 24);
  _doorRole.frame = CGRectMake(0, y, roleWidth, roleHeight);
  _indoorRole.frame = CGRectMake(roleWidth + 12, y, roleWidth, roleHeight);
  y += roleHeight + 28;
  if (!_door.hidden) {
    y = [self layoutLabel:_doorLabel y:y width:width] + 12;
    _door.frame = CGRectMake(0, y, width, 60); y += 72;
    y = [self layoutLabel:_doorHint y:y width:width] + 32;
  }
  CGFloat buttonHeight = MAX(60.0, [_saveButton.titleLabel sizeThatFits:
      CGSizeMake(width - 32, CGFLOAT_MAX)].height + 24);
  _saveButton.frame = CGRectMake(0, y, width, buttonHeight); y += buttonHeight;
  CGFloat top = MAX(32.0, (CGRectGetHeight(self.view.bounds) - y) / 2.0);
  _form.frame = CGRectMake((CGRectGetWidth(self.view.bounds) - width) / 2.0, top, width, y);
  _scroll.contentSize = CGSizeMake(CGRectGetWidth(self.view.bounds), top + y + 32);
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
  return YES;
}

- (void)keyboardChanged:(NSNotification *)notification {
  CGRect keyboard = [self.view convertRect:
      [[notification.userInfo objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue]
      fromView:nil];
  CGRect overlap = CGRectIntersection(self.view.bounds, keyboard);
  CGFloat bottom = [notification.name isEqualToString:UIKeyboardWillHideNotification] ||
      CGRectIsNull(overlap) ? 0 : CGRectGetHeight(overlap);
  _scroll.contentInset = UIEdgeInsetsMake(0, 0, bottom, 0);
  _scroll.scrollIndicatorInsets = _scroll.contentInset;
  UITextField *active = [_name isFirstResponder] ? _name : _door;
  if ([active isFirstResponder]) {
    CGRect field = [_form convertRect:CGRectInset(active.frame, 0, -16) toView:_scroll];
    [_scroll scrollRectToVisible:field animated:YES];
  }
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
  if (textField == _name && !_door.hidden) [_door becomeFirstResponder];
  else [self.view endEditing:YES];
  return YES;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (UITextField *)textField:(NSString *)text {
  UITextField *field = [[UITextField alloc] init];
  field.text = text;
  field.textColor = [UIColor colorWithWhite:0.12 alpha:1];
  field.backgroundColor = [UIColor whiteColor];
  field.font = [UIFont systemFontOfSize:24];
  field.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
  field.layer.cornerRadius = 8;
  field.layer.borderWidth = 1;
  field.layer.borderColor = [UIColor colorWithWhite:0.45 alpha:1].CGColor;
  field.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 16, 1)];
  field.leftViewMode = UITextFieldViewModeAlways;
  field.autocapitalizationType = UITextAutocapitalizationTypeNone;
  field.autocorrectionType = UITextAutocorrectionTypeNo;
  field.returnKeyType = UIReturnKeyDone;
  field.delegate = self;
  UIToolbar *toolbar = [[UIToolbar alloc] init];
  toolbar.items = @[
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
          target:nil action:nil],
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
          target:self action:@selector(dismissKeyboard)]];
  [toolbar sizeToFit];
  field.inputAccessoryView = toolbar;
  return field;
}

- (void)dismissKeyboard {
  [self.view endEditing:YES];
}

- (UIButton *)roleButton:(NSString *)title index:(NSInteger)index {
  UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
  button.tag = index;
  [button setTitle:title forState:UIControlStateNormal];
  button.titleLabel.font = [UIFont boldSystemFontOfSize:22];
  button.titleLabel.numberOfLines = 0;
  button.titleLabel.textAlignment = NSTextAlignmentCenter;
  button.layer.cornerRadius = 8;
  [button addTarget:self action:@selector(selectRole:) forControlEvents:UIControlEventTouchUpInside];
  [_form addSubview:button];
  return button;
}

- (void)doorEdited {
  _automaticDoor = NO;
}

- (void)nameEdited {
  _automaticName = NO;
}

- (void)selectRole:(UIButton *)button {
  _selectedRole = button.tag;
  [self roleChanged];
}

- (void)roleChanged {
  UIColor *blue = [UIColor colorWithRed:0.05 green:0.30 blue:0.65 alpha:1];
  for (UIButton *button in @[_doorRole, _indoorRole]) {
    BOOL selected = button.tag == _selectedRole;
    button.selected = selected;
    button.backgroundColor = selected ? blue : [UIColor whiteColor];
    [button setTitleColor:selected ? [UIColor whiteColor] : blue forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateSelected];
    button.layer.borderColor = blue.CGColor;
    button.layer.borderWidth = selected ? 3 : 1;
    button.accessibilityTraits = UIAccessibilityTraitButton |
        (selected ? UIAccessibilityTraitSelected : 0);
  }
  BOOL isDoor = _selectedRole == 0;
  if (_automaticDoor) _door.text = [DBBootConfig suggestedDeviceNameForRole:
      @"door_station" identifier:_nameIdentifier];
  if (_automaticName) _name.text = [DBBootConfig suggestedDeviceNameForRole:
      isDoor ? @"door_station" : @"indoor_panel" identifier:_nameIdentifier];
  _name.returnKeyType = isDoor ? UIReturnKeyNext : UIReturnKeyDone;
  if ([_name isFirstResponder]) [_name reloadInputViews];
  if (!isDoor) [_door resignFirstResponder];
  _door.hidden = !isDoor;
  _doorLabel.hidden = !isDoor;
  _doorHint.hidden = !isDoor;
  [self.view setNeedsLayout];
}

- (void)save {
  [self.view endEditing:YES];
  NSString *role = _selectedRole == 0 ? @"door_station" : @"indoor_panel";
  NSString *door = [[_door text] stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if ([role isEqualToString:@"door_station"] && ![DBBootConfig isValidDoor:door]) {
    [[[UIAlertView alloc] initWithTitle:[_texts ts:@"setup.title"]
                                message:[_texts ts:@"setup.invalid_door"]
                               delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
    return;
  }
  if (_onSave && !_onSave(_name.text ?: @"", role, door)) {
    [[[UIAlertView alloc] initWithTitle:[_texts ts:@"setup.title"]
                                message:[_texts ts:@"setup.invalid_door"]
                               delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
  }
}
@end

@interface DBEffectWindow : UIWindow
@property(nonatomic, copy) void (^onButtonTap)(void);
@end
@implementation DBEffectWindow
- (void)sendEvent:(UIEvent *)event {
  [super sendEvent:event];
  if (event.type != UIEventTypeTouches || !_onButtonTap) return;
  for (UITouch *touch in [event allTouches]) {
    if (touch.phase != UITouchPhaseEnded) continue;
    UIView *view = touch.view;
    while (view && ![view isKindOfClass:[UIButton class]]) view = view.superview;
    if ([view isKindOfClass:[UIButton class]] && [(UIButton *)view isEnabled]) {
      _onButtonTap();
      break;
    }
  }
}
@end

@interface DBAppDelegate ()
- (void)showBootstrapSetup:(UIApplication *)application;
- (void)startBootstrapRecoveryClient;
- (void)refreshRecoveryConfiguration;
- (void)refreshNativeKioskMeasurement;
- (void)nativeKioskProbeTimerFired:(NSTimer *)timer;
- (void)nativeKioskStatusChanged:(NSNotification *)notification;
- (void)publishUIStyleRuntimeStatus:(NSNotification *)notification;
- (void)publishRuntimeHealth:(NSTimer *)timer;
- (void)armLocalSafeModeRecovery;
- (void)handleMemoryPressureFromSource:(NSString *)source;
- (BOOL)applyReplicatedIdentity;
- (void)restartForIdentityChange;
@end

@implementation DBAppDelegate {
  DBCameraFeeder *_camera;
  DBCoreBridge *_core;
  DBBootConfig *_boot;
  DBRouter *_router;
  DBWatchdog *_watchdog;
  DBRecoveryClient *_recovery;
  DBH264Player *_h264Test;
  DBLowLatencyH264Player *_vtTest;
  DBMjpegClient *_mjpegTest;
  UIImageView *_mjpegTestView;
  BOOL _recoveryStarted;
  NSUInteger _recoveryConfigGeneration;
  NSString *_recoveryRequestedMode;
  NSString *_recoveryConfigSource;
  NSTimer *_nativeKioskProbeTimer;
  NSTimer *_runtimeHeartbeatTimer;
  NSTimer *_screenshotTimer;
  BOOL _localSafeMode;
  BOOL _helperSafeModeActive;
  NSUInteger _safeModeRecoveryGeneration;
  NSTimer *_safeModeRecoveryTimer;
  NSTimeInterval _safeModeEnteredAt;
  NSTimeInterval _lastHeartbeatAt;
  BOOL _secureStoreAvailable;
  NSUInteger _memoryPressureCount;
  NSString *_lastMemoryPressureSource;
  long long _lastMemoryPressureAtMs;
  BOOL _identityRestartPending;
}
@synthesize window = _window;

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  _boot = [DBBootConfig loadConfiguration];
  if (_boot.setupRequired) {
    // The unprovisioned branch used to return before any recovery client existed,
    // so a provisioned root helper saw no heartbeat, concluded the launch had
    // failed, and relaunched the app on every startup timeout for as long as
    // bootstrap setup stayed open. Announce liveness from this branch too.
    [self startBootstrapRecoveryClient];
    [self showBootstrapSetup:application];
    return YES;
  }
  // Setup completion re-enters this method; retire the bootstrap-only client first.
  if (_recovery) {
    [_recovery stop];
    _recovery = nil;
    _recoveryStarted = NO;
  }
  _localSafeMode = DBPrepareLocalRecoveryState();
  _core = [[DBCoreBridge alloc] init];
  BOOL secureStoreAvailable = YES;
  NSString *legacyPskMigration = @"not_needed";
  if ([_boot.legacyPskHex length] == 64) {
    BOOL keyStored = [_core storeSecret:@"mesh.psk" value:_boot.legacyPskHex];
    NSString *migrated = keyStored
        ? [DBBootConfig persistPairingSecretRef:@"secret:mesh.psk" seeds:nil] : nil;
    if ([migrated length] > 0) {
      _boot.rawJson = migrated;
      _boot.legacyPskHex = @"";
      legacyPskMigration = @"migrated_to_psk_ref";
    } else {
      secureStoreAvailable = keyStored;
      legacyPskMigration = keyStored ? @"boot_write_failed_fallback_retained"
                                     : @"keychain_write_failed_fallback_retained";
    }
    NSLog(@"[doorbell] legacy PSK migration: %@", legacyPskMigration);
  }
  _secureStoreAvailable = secureStoreAvailable;
  _router = [[DBRouter alloc] initWithBridge:_core boot:_boot];
  DBRouter *router = _router;  // The router lives for the application lifetime.
  // Subscribe before Core starts so initial discovery and peer events are not lost.
  // DBCoreBridge delivers callbacks on the main queue after launch can complete.
  [_core addHandler:@"app" handler:^(NSDictionary *ev) { [router onCoreEvent:ev]; }];
  __weak DBAppDelegate *identityDelegate = self;
  [_core addHandler:@"identity-sync" handler:^(NSDictionary *ev) {
    if ([[DBConfigUtil evStr:ev key:@"t"] isEqualToString:@"config_changed"])
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
          dispatch_get_main_queue(), ^{ [identityDelegate applyReplicatedIdentity]; });
  }];

  // Keep the shell available in offline mode if Core cannot start.
  BOOL coreStarted = [_core startWithDataDir:[DBBootConfig dataDir] bootJson:_boot.rawJson];
  if (coreStarted) {
    [_core setRuntimeCapabilities:DBShellCapabilities(_boot, secureStoreAvailable,
                                                       _localSafeMode)];
    if (DBSupportsUIManifest(_boot.role)) [_core setUIManifest:DBUIManifest(_boot.role)];
    [_core setRuntimeStatusSection:@"secure_store" value:@{
      @"schema_version" : @1,
      @"available" : @(secureStoreAvailable),
      @"implementation" : @"ios_keychain_generic_password",
      @"accessibility" : @"after_first_unlock",
      @"legacy_psk_migration" : legacyPskMigration,
    }];
    [_core setRuntimeStatusSection:@"ios_compat" value:@{
      @"schema_version" : @1,
      @"platform" : @"ios_compat",
      @"role" : _boot.role ?: @"",
      @"device" : [[UIDevice currentDevice] model] ?: @"",
      @"os_version" : [[UIDevice currentDevice] systemVersion] ?: @"",
      @"core_abi" : @{
        @"version" : @(DB_PLATFORM_V2_VERSION),
        @"struct_size" : @(sizeof(db_platform_v2)),
        @"https_request" : @YES,
        @"secure_get" : @YES,
        @"secure_put" : @YES,
        @"device_info" : @YES,
        @"release_buffer" : @YES,
      },
      @"keepalive_helper_boot_fallback" : _boot.keepaliveHelperPolicy ?: @"off",
      @"safe_mode" : @(_localSafeMode),
    }];
    [[NSNotificationCenter defaultCenter]
        addObserver:self selector:@selector(publishUIStyleRuntimeStatus:)
               name:DBSemanticStyleReportDidChangeNotification object:nil];
    [self publishUIStyleRuntimeStatus:nil];
  }

  DBEffectWindow *win = [[DBEffectWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
  __weak DBRouter *effectRouter = _router;
  win.onButtonTap = ^{ [effectRouter playButtonSound]; };
  DBRootController *root = [[DBRootController alloc] initWithNibName:nil bundle:nil];
  UIView *container = _router.containerView;
  container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  root.view = container;
  win.rootViewController = root;
  [win makeKeyAndVisible];
  self.window = win;

  if ([_boot.role isEqualToString:@"indoor_panel"] && !_localSafeMode)
    [DBVtVideoView prewarm];

  application.idleTimerDisabled = YES;  // keep-awake (kiosk)

  [_router start];
  if (_localSafeMode) {
    _safeModeEnteredAt = [[NSDate date] timeIntervalSince1970];
    [_router setSafeMode:YES reason:@"crash_loop_3_in_5m"];
    [self armLocalSafeModeRecovery];
  }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{ [_router playLaunchSound]; });

  DBRouter *recoveryRouter = _router;
  _recovery = [[DBRecoveryClient alloc] initWithPolicy:_boot.keepaliveHelperPolicy
                                                  role:_boot.role
                                         stateProvider:^NSString * {
    return [recoveryRouter currentScreenName];
  }];
  DBCoreBridge *recoveryCore = _core;
  __weak DBAppDelegate *recoveryDelegate = self;
  _recovery.statusHandler = ^(NSDictionary *status) {
    [recoveryCore setRuntimeStatusSection:@"recovery" value:status];
    DBAppDelegate *delegate = recoveryDelegate;
    if (delegate) delegate->_helperSafeModeActive = NO;
    [delegate publishRuntimeHealth:nil];
  };
  _recoveryRequestedMode = [_boot.keepaliveHelperPolicy copy] ?: @"off";
  _recoveryConfigSource = @"legacy_boot_fallback";
  [_core addHandler:@"recovery-config" handler:^(NSDictionary *event) {
    NSString *type = [DBConfigUtil evStr:event key:@"t"];
    if ([type isEqualToString:@"config_changed"] ||
        [type isEqualToString:@"paired"] ||
        [type isEqualToString:@"peers_changed"])
      [recoveryDelegate refreshRecoveryConfiguration];
  }];
  [self refreshRecoveryConfiguration];
  if (DBNativeKioskAvailable()) {
    [[NSNotificationCenter defaultCenter]
        addObserver:self selector:@selector(nativeKioskStatusChanged:)
               name:UIAccessibilityGuidedAccessStatusDidChangeNotification object:nil];
    _nativeKioskProbeTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
        target:self selector:@selector(nativeKioskProbeTimerFired:)
        userInfo:nil repeats:YES];
  }

  // UI watchdog starts after the main run loop is ready. A reachable root
  // helper owns relaunch; otherwise the watchdog keeps its uiopen fallback.
  DBRouter *r = _router;
  DBRecoveryClient *recovery = _recovery;
  _watchdog = [[DBWatchdog alloc] initWithNameProvider:^NSString * {
    return [r currentScreenName];
  } externalSupervisorProvider:^BOOL {
    return recovery.helperSupervising;
  }];
  [_watchdog start];
  __weak DBAppDelegate *cameraDelegate = self;
  DBCoreBridge *cameraCore = _core;
  _camera = [[DBCameraFeeder alloc] initWithFrameHandler:^(NSData *data, int format, int width, int height, int stride) {
    [cameraCore pushCameraFrame:data format:format width:width height:height stride:stride];
  } stateHandler:^(BOOL active, NSString *reason) {
    DBAppDelegate *delegate = cameraDelegate;
    if (!delegate) return;
    cameraCore.cameraActive = active;
    [cameraCore setRuntimeCapability:@"camera" enabled:active];
    [cameraCore setRuntimeCapability:@"camera_capture" enabled:active];
    [cameraCore setRuntimeStatusSection:@"camera" value:@{@"active": @(active), @"state": reason}];
    [[delegate->_router door] refreshFromCore];
  }];
  DBCameraEncoder *cameraEncoder = [[DBCameraEncoder alloc] initWithCore:cameraCore];
  cameraEncoder.onStateChanged = ^(BOOL active) {
    (void)active;
    DBAppDelegate *delegate = cameraDelegate;
    if (delegate) [[delegate->_router door] refreshFromCore];
  };
  _camera.onPixelBuffer = ^(CVPixelBufferRef pixels, CMTime timestamp) { [cameraEncoder feed:pixels timestamp:timestamp]; };
  _camera.onCaptureStopped = ^{ [cameraEncoder stop]; };
  [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateCameraOrientation:)
      name:UIDeviceOrientationDidChangeNotification object:nil];
  [self updateCameraOrientation:nil];
  _runtimeHeartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:10.0
      target:self selector:@selector(publishRuntimeHealth:) userInfo:nil repeats:YES];
  [self startScreenshotHookIfEnabled];
  if (_boot.debugScreenshots && [_boot.debugStartScreen length] > 0) {
    // After the first layout, so the screen it opens is fully drawn.
    DBRouter *startRouter = _router;
    NSString *startScreen = [_boot.debugStartScreen copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
      [startRouter showDebugStartScreen:startScreen];
    });
  }
  [self publishRuntimeHealth:nil];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:0 forKey:DBWatchdogBackoffIndexKey];
    [defaults synchronize];
  });

  if (_boot.diagnosticDumps) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self diagDump]; });
  }
  return YES;
}

// Name edits refresh the shared boot model; role or door edits require a clean process boundary.
- (BOOL)applyReplicatedIdentity {
  if (_identityRestartPending) return YES;
  NSDictionary *node = [[_core status] objectForKey:@"node"];
  NSString *nodeID = [node isKindOfClass:[NSDictionary class]]
      ? [(NSDictionary *)node objectForKey:@"id"] : nil;
  NSDictionary *devices = [[_core config] objectForKey:@"devices"];
  NSDictionary *device = [devices isKindOfClass:[NSDictionary class]]
      ? [(NSDictionary *)devices objectForKey:nodeID ?: @""] : nil;
  if (![device isKindOfClass:[NSDictionary class]]) return NO;
  NSString *role = [device objectForKey:@"role"];
  if (![role isKindOfClass:[NSString class]] || ![DBBootConfig isValidRole:role]) return NO;
  NSString *door = [role isEqualToString:@"door_station"] ? [device objectForKey:@"door"] : @"";
  if (![door isKindOfClass:[NSString class]]) door = @"";
  if ([role isEqualToString:@"door_station"] && ![DBBootConfig isValidDoor:door]) return NO;
  NSString *name = [device objectForKey:@"name"];
  if (![name isKindOfClass:[NSString class]]) name = _boot.name;
  name = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if ([name length] > 64) name = [name substringToIndex:64];
  if ([name length] == 0) name = @"doorbell";
  if ([name isEqualToString:_boot.name] && [role isEqualToString:_boot.role] &&
      [door isEqualToString:_boot.door])
    return NO;
  if (![DBBootConfig persistSetupName:name role:role door:door]) {
    NSLog(@"[doorbell] replicated identity could not be persisted");
    return NO;
  }
  if ([role isEqualToString:_boot.role] && [door isEqualToString:_boot.door]) {
    _boot.name = name;
    _boot.rawJson = [DBBootConfig loadConfiguration].rawJson;
    return NO;
  }
  _identityRestartPending = YES;
  dispatch_async(dispatch_get_main_queue(), ^{ [self restartForIdentityChange]; });
  return YES;
}

- (void)restartForIdentityChange {
  if (!_identityRestartPending) return;
  [@"identity_change\n" writeToFile:DBRecoveryMaintenanceMarkerPath atomically:YES
                            encoding:NSUTF8StringEncoding error:NULL];
  BOOL supervised = _recovery.helperSupervising;
  DBMarkCleanExit();
  [_core stop];
  [DBWatchdog restartForMaintenanceWithExternalSupervisor:supervised];
}

// The kiosk's local safe mode disables every H.264 strategy, so a latch that
// never clears leaves an indoor panel on MJPEG for good (follow-up recorded in
// docs/evidence/ios5-ipad1-keepalive-helper-qualification-2026-09-02.md).
// The old recovery was a bare five-minute dispatch_after that neither required
// a live run loop nor survived a restart. It is now a ten-minute window of
// measured health, re-evaluated every thirty seconds: the runtime heartbeat
// must keep advancing, no new unclean launch may be charged, and the root
// helper must not be holding its own latch.
- (void)armLocalSafeModeRecovery {
  if (!_localSafeMode || _helperSafeModeActive) return;
  _safeModeRecoveryGeneration++;
  if (_safeModeEnteredAt <= 0) _safeModeEnteredAt = [[NSDate date] timeIntervalSince1970];
  if (_safeModeRecoveryTimer) return;
  _safeModeRecoveryTimer =
      [NSTimer scheduledTimerWithTimeInterval:30.0 target:self
                                     selector:@selector(evaluateLocalSafeModeRecovery:)
                                     userInfo:nil repeats:YES];
}

// Unclean launches recorded after the latch was taken. Within one healthy
// process this is zero; a launch charged during the window restarts it.
- (NSUInteger)crashesChargedSinceSafeModeEntry {
  if (_safeModeEnteredAt <= 0) return 0;
  NSArray *launches =
      [[NSUserDefaults standardUserDefaults] arrayForKey:DBRecoveryLaunchesKey] ?: @[];
  NSUInteger charged = 0;
  for (id entry in launches) {
    if (![entry isKindOfClass:[NSNumber class]]) continue;
    if ([(NSNumber *)entry doubleValue] > _safeModeEnteredAt) charged++;
  }
  return charged;
}

- (NSString *)localSafeModeRecoveryState {
  return [DBSafeModeRecovery stateForActive:_localSafeMode
                                  enteredAt:_safeModeEnteredAt
                            lastHeartbeatAt:_lastHeartbeatAt
                          crashesSinceEntry:[self crashesChargedSinceSafeModeEntry]
                       helperSafeModeActive:_helperSafeModeActive
                                        now:[[NSDate date] timeIntervalSince1970]];
}

- (void)evaluateLocalSafeModeRecovery:(NSTimer *)timer {
  (void)timer;
  if (!_localSafeMode) {
    [_safeModeRecoveryTimer invalidate];
    _safeModeRecoveryTimer = nil;
    return;
  }
  NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
  if (![DBSafeModeRecovery shouldClearSafeModeEnteredAt:_safeModeEnteredAt
                                       lastHeartbeatAt:_lastHeartbeatAt
                                     crashesSinceEntry:[self crashesChargedSinceSafeModeEntry]
                                  helperSafeModeActive:_helperSafeModeActive
                                                   now:now])
    return;
  [_safeModeRecoveryTimer invalidate];
  _safeModeRecoveryTimer = nil;
  // The screenshot hook is a boot.json debug opt-in, not part of recovery. It
  // used to be torn down here, so remote verification stopped working at the
  // exact moment the panel became healthy.
  DBMarkHealthyRuntime();
  _localSafeMode = NO;
  _safeModeEnteredAt = 0;
  [_router setSafeMode:NO reason:@"healthy_runtime_10m"];
  [_core setRuntimeCapabilities:DBShellCapabilities(_boot, _secureStoreAvailable, NO)];
  [self publishRuntimeHealth:nil];
  NSLog(@"[doorbell][recovery] exited local safe mode after 10m healthy runtime");
}

- (void)startBootstrapRecoveryClient {
  if (_recovery) return;
  _recovery = [[DBRecoveryClient alloc] initWithPolicy:_boot.keepaliveHelperPolicy
                                                  role:_boot.role
                                         stateProvider:^NSString * {
    return @"bootstrap_setup";
  }];
  _recoveryRequestedMode = [_boot.keepaliveHelperPolicy copy] ?: @"off";
  _recoveryConfigSource = @"bootstrap_setup_boot_fallback";
  _recoveryStarted = YES;
  // No Core exists on this branch, so there is no runtime status sink to publish
  // into; the client only announces `started` plus its periodic heartbeat.
  [_recovery start];
}

- (void)showBootstrapSetup:(UIApplication *)application {
  DBBootstrapSetupController *setup = [[DBBootstrapSetupController alloc] initWithBoot:_boot];
  __weak DBAppDelegate *weakSelf = self;
  setup.onSave = ^BOOL(NSString *name, NSString *role, NSString *door) {
    DBAppDelegate *delegate = weakSelf;
    if (!delegate) return NO;
    if (![DBBootConfig persistSetupName:name role:role door:door]) return NO;
    // No Core or watchdog has started on this branch, so entering the normal
    // launch path is equivalent to a fresh, configured process start.
    [delegate application:application didFinishLaunchingWithOptions:nil];
    return YES;
  };
  UIWindow *window = [[DBEffectWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
  window.rootViewController = setup;
  [window makeKeyAndVisible];
  self.window = window;
}

// iOS 5 has no screencap, so remote verification needs the app to draw itself.
// The poll exists only when boot.json opts in, so an ordinary install pays
// nothing: no timer, no stat, no file.
// The rotation the root view controller applies for an interface orientation.
// The screenshot has to undo exactly this to come out upright.
static CGFloat DBRotationForInterfaceOrientation(UIInterfaceOrientation orientation) {
  switch (orientation) {
    case UIInterfaceOrientationPortraitUpsideDown: return (CGFloat)M_PI;
    case UIInterfaceOrientationLandscapeLeft: return (CGFloat)(-M_PI_2);
    case UIInterfaceOrientationLandscapeRight: return (CGFloat)M_PI_2;
    default: return 0;
  }
}

static NSString *const DBScreenshotRequestPath =
    @"/var/mobile/Documents/screenshot.request";
static NSString *const DBScreenshotOutputPath = @"/var/mobile/Documents/screenshot.png";

- (void)startScreenshotHookIfEnabled {
  if (!_boot.debugScreenshots || _screenshotTimer != nil) return;
  NSLog(@"[doorbell][debug] screenshot hook armed at %@", DBScreenshotRequestPath);
  _screenshotTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self
                                                    selector:@selector(pollScreenshotRequest:)
                                                    userInfo:nil repeats:YES];
}

- (void)pollScreenshotRequest:(NSTimer *)timer {
  (void)timer;
  NSFileManager *files = [NSFileManager defaultManager];
  if (![files fileExistsAtPath:DBScreenshotRequestPath]) return;
  // Remove the request first: a render that throws must not leave a request
  // that fires again every second.
  [files removeItemAtPath:DBScreenshotRequestPath error:NULL];
  UIWindow *window = self.window ?: [[UIApplication sharedApplication] keyWindow];
  if (window == nil) return;
  CGSize size = window.bounds.size;
  if (size.width <= 0 || size.height <= 0) return;
  // On iOS 5 the window keeps the device's native portrait geometry and the
  // root view controller carries the rotation, so rendering the window layer
  // straight into a portrait context produces a landscape screen lying on its
  // side. Draw into an upright canvas and undo the interface rotation instead.
  UIInterfaceOrientation orientation =
      [[UIApplication sharedApplication] statusBarOrientation];
  CGFloat radians = DBRotationForInterfaceOrientation(orientation);
  BOOL sideways = UIInterfaceOrientationIsLandscape(orientation);
  CGSize canvas = sideways ? CGSizeMake(size.height, size.width) : size;
  UIGraphicsBeginImageContextWithOptions(canvas, YES, 0.0);
  CGContextRef ctx = UIGraphicsGetCurrentContext();
  if (ctx != NULL) {
    // Both rectangles share a centre; rotating about it is all the correction
    // a quarter turn needs, and it keeps the portrait path pixel-identical.
    CGContextTranslateCTM(ctx, canvas.width / 2, canvas.height / 2);
    CGContextRotateCTM(ctx, -radians);
    CGContextTranslateCTM(ctx, -size.width / 2, -size.height / 2);
    [window.layer renderInContext:ctx];
  }
  UIImage *shot = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  if (shot == nil) return;
  NSData *png = UIImagePNGRepresentation(shot);
  if (png == nil) return;
  [png writeToFile:DBScreenshotOutputPath atomically:YES];
  NSLog(@"[doorbell][debug] screenshot written (%lux%lu, orientation %ld, %lu bytes)",
        (unsigned long)canvas.width, (unsigned long)canvas.height, (long)orientation,
        (unsigned long)[png length]);
}

- (void)restartIntoBootstrapSetup {
  [_nativeKioskProbeTimer invalidate];
  _nativeKioskProbeTimer = nil;
  [_runtimeHeartbeatTimer invalidate];
  _runtimeHeartbeatTimer = nil;
  [_safeModeRecoveryTimer invalidate];
  _safeModeRecoveryTimer = nil;
  // The watchdog has no stop entry point by design (it must survive normal UI
  // churn); dropping the reference is what the bootstrap branch already does.
  _watchdog = nil;
  [_recovery stop];
  _recovery = nil;
  _recoveryStarted = NO;
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [_core stop];
  _core = nil;
  _router = nil;
  _boot = [DBBootConfig loadConfiguration];
  [self startBootstrapRecoveryClient];
  [self showBootstrapSetup:[UIApplication sharedApplication]];
}

- (void)publishUIStyleRuntimeStatus:(NSNotification *)notification {
  (void)notification;
  [_core setRuntimeStatusSection:@"ui_style" value:[DBSemanticStyle runtimeReport]];
}

- (void)publishRuntimeHealth:(NSTimer *)timer {
  (void)timer;
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSTimeInterval wallSeconds = [[NSDate date] timeIntervalSince1970];
  long long heartbeatMs = wallSeconds > 0 ? (long long)(wallSeconds * 1000.0) : 0;
  // The safe-mode auto-clear only counts a window the run loop actually served.
  _lastHeartbeatAt = wallSeconds;
  NSInteger generation = [defaults integerForKey:DBRecoveryGenerationKey];
  NSString *lastExit = DBBoundedRuntimeToken(
      [defaults stringForKey:DBRecoveryLastExitReasonKey]);
  NSString *helperMode = DBBoundedRuntimeToken(
      _recovery ? _recovery.effectiveMode : @"off");
  NSArray *launches = [defaults arrayForKey:DBRecoveryLaunchesKey] ?: @[];
  NSDictionary *components = @{
    @"core" : _core.isRunning ? @"running" : @"stopped",
    @"sip" : _core.isRunning ? @"available" : @"stopped",
    @"media" : _localSafeMode ? @"degraded" : @"available",
    @"ui" : self.window ? @"running" : @"starting",
  };
  // 本機情報 renders these two fields, so the operator can see why safe mode is
  // still on and how long is left before it clears itself.
  NSString *recoveryState = [self localSafeModeRecoveryState];
  double recoveryRemaining = _localSafeMode
      ? [DBSafeModeRecovery remainingSecondsEnteredAt:_safeModeEnteredAt now:wallSeconds] : 0;
  NSDictionary *processRecovery = @{
    @"schema_version" : @1,
    @"generation" : @(MAX((NSInteger)0, generation)),
    @"safe_mode" : @(_localSafeMode),
    @"crash_count_5m" : @([launches count]),
    @"last_exit_reason" : lastExit,
    @"recovery_state" : recoveryState,
    @"recovery_remaining_s" : @(recoveryRemaining),
  };
  NSDictionary *memoryPressure = @{
    @"schema_version" : @1,
    @"count" : @(_memoryPressureCount),
    @"last_source" : _lastMemoryPressureSource ?: @"none",
    @"last_at_ms" : [NSNumber numberWithLongLong:_lastMemoryPressureAtMs],
    @"media_released" : @(_memoryPressureCount > 0),
  };
  [_core setRuntimeStatusValues:@{
    @"schema_version" : @1,
    @"generation" : @(MAX((NSInteger)0, generation)),
    @"heartbeat_ms" : [NSNumber numberWithLongLong:heartbeatMs],
    @"last_exit_reason" : lastExit,
    @"safe_mode" : @(_localSafeMode),
    @"safe_mode_state" : recoveryState,
    @"safe_mode_remaining_s" : @(recoveryRemaining),
    @"crash_count_5m" : @([launches count]),
    @"codec_health" : _localSafeMode ? @"safe_mode_low_resolution_mjpeg"
                                        : @"unknown_until_stream",
    @"helper_mode" : helperMode,
    @"helper_available" : @(_recovery && _recovery.helperReachable),
    @"process_recovery" : processRecovery,
    @"memory_pressure" : memoryPressure,
    @"components" : components,
  }];
}

- (void)refreshRecoveryConfiguration {
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{ [self refreshRecoveryConfiguration]; });
    return;
  }
  NSUInteger generation = ++_recoveryConfigGeneration;
  DBCoreBridge *core = _core;
  NSString *fallback = [_boot.keepaliveHelperPolicy copy] ?: @"off";
  __weak DBAppDelegate *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSDictionary *status = [core status];
    NSDictionary *config = [core config];
    NSString *selfID = [DBConfigUtil str:status path:@"node.id"];
    id configured = nil;
    if ([selfID length] > 0 && [config isKindOfClass:[NSDictionary class]]) {
      id devices = [config objectForKey:@"devices"];
      id device = [devices isKindOfClass:[NSDictionary class]]
          ? [(NSDictionary *)devices objectForKey:selfID] : nil;
      id local = [device isKindOfClass:[NSDictionary class]]
          ? [(NSDictionary *)device objectForKey:@"local"] : nil;
      id recovery = [local isKindOfClass:[NSDictionary class]]
          ? [(NSDictionary *)local objectForKey:@"recovery"] : nil;
      if ([recovery isKindOfClass:[NSDictionary class]])
        configured = [(NSDictionary *)recovery objectForKey:@"helper_mode"];
    }
    BOOL hasCanonicalValue = configured != nil;
    BOOL validCanonicalValue = [configured isKindOfClass:[NSString class]] &&
        [DBRecoveryClient isValidHelperMode:(NSString *)configured];
    NSString *requested = hasCanonicalValue
        ? (validCanonicalValue ? configured : @"invalid") : fallback;
    NSString *source = hasCanonicalValue ? @"fleet_config" : @"legacy_boot_fallback";
    dispatch_async(dispatch_get_main_queue(), ^{
      DBAppDelegate *delegate = weakSelf;
      if (!delegate || generation != delegate->_recoveryConfigGeneration) return;
      delegate->_recoveryRequestedMode = [requested copy];
      delegate->_recoveryConfigSource = [source copy];
      [delegate->_recovery updateConfiguredPolicy:requested source:source
                            nativeKioskAvailable:DBNativeKioskAvailable()
                              nativeKioskHealthy:DBNativeKioskHealthy()];
      if (!delegate->_recoveryStarted) {
        delegate->_recoveryStarted = YES;
        [delegate->_recovery start];
      }
    });
  });
}

- (void)refreshNativeKioskMeasurement {
  if (!_recovery) return;
  [_recovery updateConfiguredPolicy:_recoveryRequestedMode ?: @"off"
                               source:_recoveryConfigSource ?: @"legacy_boot_fallback"
                nativeKioskAvailable:DBNativeKioskAvailable()
                  nativeKioskHealthy:DBNativeKioskHealthy()];
}

- (void)nativeKioskStatusChanged:(NSNotification *)notification {
  (void)notification;
  [self refreshNativeKioskMeasurement];
}

- (void)nativeKioskProbeTimerFired:(NSTimer *)timer {
  (void)timer;
  [self refreshNativeKioskMeasurement];
}

- (void)applicationWillTerminate:(UIApplication *)application {
  (void)application;
  DBMarkCleanExit();
  [_runtimeHeartbeatTimer invalidate];
  _runtimeHeartbeatTimer = nil;
  [_nativeKioskProbeTimer invalidate];
  _nativeKioskProbeTimer = nil;
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [_recovery stop];
  [self publishRuntimeHealth:nil];
  [_core stop];
}

- (void)updateCameraOrientation:(NSNotification *)notification {
  int degrees = -1;
  switch ([UIDevice currentDevice].orientation) {
    case UIDeviceOrientationPortrait: degrees = 0; break;
    case UIDeviceOrientationLandscapeLeft: degrees = 90; break;
    case UIDeviceOrientationPortraitUpsideDown: degrees = 180; break;
    case UIDeviceOrientationLandscapeRight: degrees = 270; break;
    default: break;
  }
  if (degrees < 0 && !notification) {
    switch ([UIApplication sharedApplication].statusBarOrientation) {
      case UIInterfaceOrientationPortrait: degrees = 0; break;
      case UIInterfaceOrientationLandscapeLeft: degrees = 270; break;
      case UIInterfaceOrientationPortraitUpsideDown: degrees = 180; break;
      case UIInterfaceOrientationLandscapeRight: degrees = 90; break;
      default: break;
    }
  }
  if (degrees >= 0) [_core setVideoSensorRotation:degrees];
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
  (void)application;
  [_core invalidateCachedLocalTime];
  [self refreshNativeKioskMeasurement];
  [_router resumeMediaAfterBackground];
  [self updateCameraOrientation:nil];
  if (_core.isRunning && [_boot.role isEqualToString:@"door_station"] &&
      [_boot.videoSource isEqualToString:@"auto"]) [_camera start];
  [self publishRuntimeHealth:nil];
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
  (void)application;
  [_router suspendMediaForBackground];
  [_camera stop];
}

- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application {
  (void)application;
  [self handleMemoryPressureFromSource:@"uikit"];
}

- (void)handleMemoryPressureFromSource:(NSString *)source {
  NSTimeInterval wallSeconds = [[NSDate date] timeIntervalSince1970];
  NSString *boundedSource = ([source isEqualToString:@"uikit"] ||
                             [source isEqualToString:@"diagnostic_url"])
      ? source : @"unknown";
  _memoryPressureCount++;
  _lastMemoryPressureSource = [boundedSource copy];
  _lastMemoryPressureAtMs = wallSeconds > 0 ? (long long)(wallSeconds * 1000.0) : 0;
  [_router releaseMediaForMemoryPressure];
  [DBVtVideoView purgeWarmView];
  [_h264Test stop];
  _h264Test = nil;
  [_vtTest stop];
  _vtTest = nil;
  [_mjpegTest stop];
  _mjpegTest = nil;
  _mjpegTestView.image = nil;
  [_mjpegTestView removeFromSuperview];
  _mjpegTestView = nil;
  [[NSURLCache sharedURLCache] removeAllCachedResponses];
  [_recovery noteMemoryPressure];
  _localSafeMode = NO;
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  [defaults setBool:NO forKey:DBRecoverySafeModeKey];
  [defaults setObject:@"memory_pressure" forKey:DBRecoveryLastExitReasonKey];
  [defaults synchronize];
  [_core setRuntimeCapabilities:DBShellCapabilities(_boot, _secureStoreAvailable, NO)];
  [self publishRuntimeHealth:nil];
  NSLog(@"[doorbell][recovery] released optional media after memory warning source=%@ count=%lu",
        _lastMemoryPressureSource, (unsigned long)_memoryPressureCount);
}






- (BOOL)application:(UIApplication *)application
            openURL:(NSURL *)url
  sourceApplication:(NSString *)source
         annotation:(id)annotation {
  (void)application; (void)source; (void)annotation;
  NSString *host = [url host] ?: @"";
  if ([host length] == 0) {
    // A bare "doorbell://" has no path either, and messaging nil here used to
    // put a literal (null) in the log.
    host = [[url path] stringByTrimmingCharactersInSet:
               [NSCharacterSet characterSetWithCharactersInString:@"/"]] ?: @"";
  }
  // ASCII only: ASL mangles a multi-byte arrow into one dash per character.
  NSLog(@"[doorbell] openURL: %@ -> host='%@'", url, host);
  if ([host isEqualToString:@"pair"]) {
    // A scanned invitation, or one opened from another app. Core validates it
    // when it can, because it checks the expiry against corrected cluster
    // time; the shell parser is the fallback before core has started.
    NSString *text = [url absoluteString];
    DBPairUri *invitation = [DBPairUri fromCoreDocument:[_core parsePairUri:text]];
    if (invitation == nil) {
      invitation = [DBPairUri parse:text
                               nowS:(long long)[[NSDate date] timeIntervalSince1970]];
    }
    [_router showPairing];
    [[_router pairing] presentInvitation:invitation];
    return YES;
  }
  if ([host isEqualToString:@"pin"]) {
    [_router requestPinThen:nil];
    return YES;
  }
  if ([host isEqualToString:@"info"]) {

    [_router showInfo];
    return YES;
  }
  NSSet *diagnosticHosts = [NSSet setWithObjects:@"shot", @"home", @"stress",
      @"h264stop", @"memorypressure", nil];
  BOOL diagnosticAction = [diagnosticHosts containsObject:host] ||
      [host hasPrefix:@"h264test"] || [host hasPrefix:@"vttest"] ||
      [host hasPrefix:@"mjpegtest"];
  if (diagnosticAction && !_boot.diagnosticDumps) {
    NSLog(@"[doorbell] rejected disabled diagnostic URL action: %@", host);
    return NO;
  }
  if ([host isEqualToString:@"shot"]) {
    [self diagDump];
    return YES;
  }
  if ([host isEqualToString:@"home"]) {
    [self h264TestStop];
    return YES;
  }
  if ([host isEqualToString:@"memorypressure"]) {
    if (application.applicationState == UIApplicationStateBackground) {
      NSLog(@"[doorbell] rejected background diagnostic memory-pressure action");
      return NO;
    }
    [self handleMemoryPressureFromSource:@"diagnostic_url"];
    return YES;
  }
  if ([host isEqualToString:@"stress"]) {


    DBCoreBridge *c = _core;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      for (int i = 0; i < 60; i++) {
        (void)[c status];
        (void)[c debugInfo];
        (void)[c config];
        if (i % 10 == 0) NSLog(@"[doorbell] stress %d/60", i);
        [NSThread sleepForTimeInterval:0.05];
      }
      NSLog(@"[doorbell] stress done (60 rounds, no crash)");
    });
    return YES;
  }
  if ([host hasPrefix:@"h264test"]) {


    NSString *ip = nil;
    if ([host length] > 8) ip = [host substringFromIndex:8];
    if ([ip length] == 0) ip = @"127.0.0.1";
    NSString *url = [NSString stringWithFormat:@"http://%@:47180/stream.mp4", ip];
    NSLog(@"[doorbell] h264test: %@", url);
    [_h264Test stop];
    _h264Test = nil;
    UIView *container = _router.containerView;
    __weak DBAppDelegate *wself = self;
    _h264Test = [[DBH264Player alloc] initWithURL:url container:container
                                          onState:^(DBH264PlayerState st) {
      NSLog(@"[doorbell] h264test state=%ld", (long)st);
      if (st == DBH264PlayerFailed) {
        DBAppDelegate *s = wself;
        if (s) [s h264TestStop];
      }
    }];
    [_h264Test start];
    return YES;
  }
  if ([host hasPrefix:@"vttest"]) {
    NSString *ip = [host length] > 6 ? [host substringFromIndex:6] : nil;
    if (![ip length]) ip = @"127.0.0.1";
    NSString *stream = [NSString stringWithFormat:@"http://%@:47180/stream.mp4", ip];
    [self h264TestStop];
    UIView *container = _router.containerView;
    __weak DBAppDelegate *wself = self;
    _vtTest = [[DBLowLatencyH264Player alloc] initWithURL:stream container:container
                                                  onState:^(DBLowLatencyPlayerState state) {
      DBH264Dbg(@"[vt] test state=%ld", (long)state);
      if (state == DBLowLatencyPlayerFailed) {
        DBAppDelegate *delegate = wself;
        if (delegate) [delegate h264TestStop];
      }
    }];
    [_vtTest start];
    return YES;
  }
  if ([host hasPrefix:@"mjpegtest"]) {
    NSString *ip = [host length] > 9 ? [host substringFromIndex:9] : nil;
    if (![ip length]) ip = @"127.0.0.1";
    [self h264TestStop];
    UIView *container = _router.containerView;
    _mjpegTestView = [[UIImageView alloc] initWithFrame:container.bounds];
    _mjpegTestView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _mjpegTestView.contentMode = UIViewContentModeScaleAspectFit;
    _mjpegTestView.backgroundColor = [UIColor blackColor];
    [container addSubview:_mjpegTestView];
    __weak DBAppDelegate *wself = self;
    NSString *url = [NSString stringWithFormat:@"http://%@:47180/stream.mjpeg", ip];
    _mjpegTest = [[DBMjpegClient alloc] initWithURLString:url onFrame:^(UIImage *image) {
      DBAppDelegate *delegate = wself;
      if (delegate) delegate->_mjpegTestView.image = image;
    }];
    [_mjpegTest start];
    return YES;
  }
  if ([host isEqualToString:@"h264stop"]) {
    [self h264TestStop];
    return YES;
  }
  return YES;
}

- (void)h264TestStop {
  [_h264Test stop];
  _h264Test = nil;
  [_vtTest stop];
  _vtTest = nil;
  [_mjpegTest stop];
  _mjpegTest = nil;
  [_mjpegTestView removeFromSuperview];
  _mjpegTestView = nil;
  [_router showHomeAnimated:NO];
}





- (void)diagDump {
  NSMutableString *out = [NSMutableString string];
  UIApplication *app = [UIApplication sharedApplication];
  UIWindow *win = self.window ?: app.keyWindow;
  [out appendFormat:@"time=%@\n", [[NSDate date] description]];
  [out appendFormat:@"appState=%ld active=%d\n", (long)app.applicationState,
                      (int)(app.applicationState == UIApplicationStateActive)];
  [out appendFormat:@"screenBounds=%@ brightness=%.2f\n",
                      NSStringFromCGRect([UIScreen mainScreen].bounds),
                      [UIScreen mainScreen].brightness];
  [out appendFormat:@"window=%@ frame=%@ hidden=%d alpha=%.2f\n", win,
                      win ? NSStringFromCGRect(win.frame) : @"nil",
                      (int)(win.isHidden), win.alpha];
  if (win) {
    [out appendFormat:@"rootVC=%@\n", win.rootViewController];
    UIView *rv = nil;
    UIViewController *rvc = win.rootViewController;
    if (rvc) {

      if ([rvc respondsToSelector:@selector(isViewLoaded)] && [rvc isViewLoaded]) rv = rvc.view;
    }
    [out appendFormat:@"loadedView=%@\n", rv ?: @"(not loaded)"];
    if (rv) {
      [out appendFormat:@"rootView frame=%@ hidden=%d alpha=%.2f superview=%@ subviews=%lu\n",
                          NSStringFromCGRect(rv.frame), (int)rv.isHidden, rv.alpha,
                          rv.superview, (unsigned long)[rv.subviews count]];
    }
    SEL rec = NSSelectorFromString(@"recursiveDescription");
    if ([win respondsToSelector:rec]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
      [out appendFormat:@"--- view tree ---\n%@\n", [win performSelector:rec]];
#pragma clang diagnostic pop
    }
  }
  [out writeToFile:@"/var/mobile/Documents/ui-dump.txt"
          atomically:YES
            encoding:NSUTF8StringEncoding
               error:NULL];
  if (win) {
    CGSize sz = win.bounds.size;
    if (sz.width < 1 || sz.height < 1) sz = [UIScreen mainScreen].bounds.size;
    UIGraphicsBeginImageContextWithOptions(sz, NO, 1.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (ctx) {
      [win.layer renderInContext:ctx];
      UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
      UIGraphicsEndImageContext();
      if (img) {
        [UIImagePNGRepresentation(img) writeToFile:@"/var/mobile/Documents/ui-dump.png"
                                        atomically:YES];
      }
    } else {
      UIGraphicsEndImageContext();
    }
  }
  NSLog(@"[doorbell] diag dump done (Documents/ui-dump.png, ui-dump.txt)");
}

@end
