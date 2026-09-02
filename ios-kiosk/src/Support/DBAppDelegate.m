#import "DBAppDelegate.h"
#import "../Core/DBBootConfig.h"
#import "../Core/DBCompatibilityProfile.h"
#import "../Core/DBConfigUtil.h"
#import "../Core/DBCoreBridge.h"
#import "../Core/DBSemanticStyle.h"
#import "../Core/DBTexts.h"
#import "../Media/DBH264Player.h"
#import "../Media/DBLowLatencyH264Player.h"
#import "../Net/DBMjpegClient.h"
#import "../Screens/DBRouter.h"
#import "../Screens/DBIncomingScreen.h"
#import "DBWatchdog.h"
#import "DBRecoveryClient.h"
#import "DBSafeModeRecovery.h"
#import "doorbell/doorbell.h"

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
  BOOL crashLoop = [DBRecoveryClient
      shouldEnterSafeModeWithPreviousCleanExit:previousClean
                                      launches:[defaults arrayForKey:DBRecoveryLaunchesKey] ?: @[]
                                           now:now updatedLaunches:&recent];
  BOOL safeMode = [defaults boolForKey:DBRecoverySafeModeKey] || crashLoop;
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

@interface DBBootstrapSetupController : UIViewController
@property(nonatomic, copy) void (^onSave)(NSString *role, NSString *door);
- (id)initWithBoot:(DBBootConfig *)boot;
@end

@implementation DBBootstrapSetupController {
  DBBootConfig *_boot;
  DBTexts *_texts;
  UISegmentedControl *_role;
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
  }
  return self;
}

- (UILabel *)label:(NSString *)text size:(CGFloat)size {
  UILabel *label = [[UILabel alloc] init];
  label.text = text;
  label.textColor = [UIColor whiteColor];
  label.font = [UIFont systemFontOfSize:size];
  label.numberOfLines = 0;
  return label;
}

- (void)loadView {
  UIView *root = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
  root.backgroundColor = [UIColor colorWithRed:0.055 green:0.086 blue:0.129 alpha:1];
  self.view = root;
  CGFloat width = CGRectGetWidth(root.bounds) - 40.0;
  CGFloat y = 38.0;
  UILabel *title = [self label:[_texts ts:@"setup.title"] size:26];
  title.font = [UIFont boldSystemFontOfSize:26];
  title.textAlignment = NSTextAlignmentCenter;
  title.frame = CGRectMake(20, y, width, 40); [root addSubview:title]; y += 56;
  UILabel *message = [self label:[_texts ts:@"setup.message"] size:15];
  message.textColor = [UIColor colorWithWhite:0.72 alpha:1];
  message.textAlignment = NSTextAlignmentCenter;
  message.frame = CGRectMake(20, y, width, 62); [root addSubview:message]; y += 80;
  UILabel *roleLabel = [self label:[_texts ts:@"setup.role"] size:16];
  roleLabel.frame = CGRectMake(20, y, width, 24); [root addSubview:roleLabel]; y += 30;
  _role = [[UISegmentedControl alloc] initWithItems:@[
      [_texts ts:@"admin.role_door"], [_texts ts:@"admin.role_indoor"] ]];
  _role.selectedSegmentIndex = [_boot.role isEqualToString:@"indoor_panel"] ? 1 : 0;
  _role.frame = CGRectMake(20, y, width, 36);
  [_role addTarget:self action:@selector(roleChanged) forControlEvents:UIControlEventValueChanged];
  [root addSubview:_role]; y += 52;
  _doorLabel = [self label:[_texts ts:@"setup.door"] size:16];
  _doorLabel.frame = CGRectMake(20, y, width, 24); [root addSubview:_doorLabel]; y += 28;
  _door = [[UITextField alloc] initWithFrame:CGRectMake(20, y, width, 36)];
  _door.text = _boot.suggestedDoor;
  _door.placeholder = [_texts ts:@"setup.door_hint"];
  _door.borderStyle = UITextBorderStyleRoundedRect;
  _door.autocapitalizationType = UITextAutocapitalizationTypeNone;
  _door.autocorrectionType = UITextAutocorrectionTypeNo;
  [root addSubview:_door]; y += 44;
  _doorHint = [self label:[_texts ts:@"setup.door_hint"] size:13];
  _doorHint.textColor = [UIColor colorWithWhite:0.55 alpha:1];
  _doorHint.frame = CGRectMake(20, y, width, 22); [root addSubview:_doorHint]; y += 42;
  UIButton *save = [UIButton buttonWithType:UIButtonTypeCustom];
  [save setTitle:[_texts ts:@"setup.finish"] forState:UIControlStateNormal];
  [save setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
  save.titleLabel.font = [UIFont boldSystemFontOfSize:18];
  save.backgroundColor = [UIColor colorWithRed:0.13 green:0.45 blue:0.85 alpha:1];
  save.layer.cornerRadius = 10;
  save.frame = CGRectMake(20, y, width, 48);
  [save addTarget:self action:@selector(save) forControlEvents:UIControlEventTouchUpInside];
  [root addSubview:save];
  [self roleChanged];
}

- (void)roleChanged {
  BOOL isDoor = _role.selectedSegmentIndex == 0;
  _door.hidden = !isDoor;
  _doorLabel.hidden = !isDoor;
  _doorHint.hidden = !isDoor;
}

- (void)save {
  NSString *role = _role.selectedSegmentIndex == 0 ? @"door_station" : @"indoor_panel";
  NSString *door = [[_door text] stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if ([role isEqualToString:@"door_station"] && ![DBBootConfig isValidDoor:door]) {
    [[[UIAlertView alloc] initWithTitle:[_texts ts:@"setup.title"]
                                message:[_texts ts:@"setup.invalid_door"]
                               delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
    return;
  }
  if (_onSave) _onSave(role, door);
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
@end

@implementation DBAppDelegate {
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
    id measured = [status objectForKey:@"measured"];
    id helper = [measured isKindOfClass:[NSDictionary class]]
        ? [(NSDictionary *)measured objectForKey:@"helper_status"] : nil;
    BOOL helperSafe = [helper isKindOfClass:[NSDictionary class]] &&
        [[(NSDictionary *)helper objectForKey:@"safe_mode"] boolValue];
    BOOL helperWasSafe = delegate ? delegate->_helperSafeModeActive : NO;
    if (delegate) delegate->_helperSafeModeActive = helperSafe;
    if (helperSafe) {
      if (delegate) delegate->_safeModeRecoveryGeneration++;
      [[NSUserDefaults standardUserDefaults] setBool:YES forKey:DBRecoverySafeModeKey];
      if (delegate) {
        delegate->_localSafeMode = YES;
        delegate->_safeModeEnteredAt = [[NSDate date] timeIntervalSince1970];
      }
      [recoveryRouter setSafeMode:YES reason:@"root_helper_crash_loop"];
    } else if (delegate && helperWasSafe && delegate->_localSafeMode) {
      [delegate armLocalSafeModeRecovery];
    }
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
  _runtimeHeartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:10.0
      target:self selector:@selector(publishRuntimeHealth:) userInfo:nil repeats:YES];
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
  setup.onSave = ^(NSString *role, NSString *door) {
    DBAppDelegate *delegate = weakSelf;
    if (!delegate) return;
    if (![DBBootConfig persistSetupName:delegate->_boot.name role:role door:door]) return;
    // No Core or watchdog has started on this branch, so entering the normal
    // launch path is equivalent to a fresh, configured process start.
    [delegate application:application didFinishLaunchingWithOptions:nil];
  };
  UIWindow *window = [[DBEffectWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
  window.rootViewController = setup;
  [window makeKeyAndVisible];
  self.window = window;
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

- (void)applicationDidBecomeActive:(UIApplication *)application {
  (void)application;
  [self refreshNativeKioskMeasurement];
  [_router resumeMediaAfterBackground];
  [self publishRuntimeHealth:nil];
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
  (void)application;
  [_router suspendMediaForBackground];
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
  _localSafeMode = YES;
  _safeModeEnteredAt = [[NSDate date] timeIntervalSince1970];
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  [defaults setBool:YES forKey:DBRecoverySafeModeKey];
  [defaults setObject:@"memory_pressure" forKey:DBRecoveryLastExitReasonKey];
  [defaults synchronize];
  [_router setSafeMode:YES reason:@"memory_pressure"];
  [self armLocalSafeModeRecovery];
  [_core setRuntimeCapabilities:DBShellCapabilities(_boot, _secureStoreAvailable, YES)];
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
  if ([host length] == 0) host = [[url path] stringByTrimmingCharactersInSet:
                                     [NSCharacterSet characterSetWithCharactersInString:@"/"]];
  NSLog(@"[doorbell] openURL: %@ → host='%@'", url, host);
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
