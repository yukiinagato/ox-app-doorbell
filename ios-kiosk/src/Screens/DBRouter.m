#import "DBRouter.h"

#import "../Core/DBBootConfig.h"
#import "../Core/DBCallEventTracker.h"
#import "../Core/DBConfigUtil.h"
#import "../Core/DBCoreBridge.h"
#import "../Core/DBTexts.h"
#import "../Media/DBSiren.h"
#import "../Media/DBSipListener.h"
#import "DBHomeScreen.h"
#import "DBDoorScreen.h"
#import "DBIncomingScreen.h"
#import "DBInfoScreen.h"
#import "DBAddDeviceScreen.h"
#import "DBPairingModel.h"
#import "DBPairingScreen.h"
#import "DBPinOverlay.h"
#import "DBScreen.h"

static BOOL DBEmergencyUsesChannel(NSDictionary *event, NSString *wanted) {
  id channels = [event objectForKey:@"channels"];
  if (![channels isKindOfClass:[NSArray class]])
    return [wanted isEqualToString:@"in_app"];
  for (id channel in (NSArray *)channels) {
    if ([channel isKindOfClass:[NSString class]] && [(NSString *)channel isEqualToString:wanted])
      return YES;
  }
  return NO;
}

static NSString *const DBPendingIndoorCallDefaultsKey = @"DBPendingIndoorCallV1";

static BOOL DBEmergencyBool(NSDictionary *event, NSString *key, BOOL fallback) {
  id value = [event objectForKey:key];
  return [value isKindOfClass:[NSNumber class]] ? [(NSNumber *)value boolValue] : fallback;
}

static NSDictionary *DBEmergencyChannelResult(NSString *channel, NSString *result,
                                               BOOL visual, BOOL sound, BOOL sticky,
                                               NSTimeInterval ttl, NSString *limitation) {
  NSMutableDictionary *value = [@{
    @"channel" : channel ?: @"unknown",
    @"result" : result ?: @"unsupported",
    @"visual_applied" : @(visual),
    @"sound_applied" : @(sound),
    @"sticky_applied" : @(sticky),
    @"ttl_s" : @(ttl),
  } mutableCopy];
  if ([limitation length] > 0) [value setObject:limitation forKey:@"limitation"];
  return value;
}

#ifndef DB_IOS_COMPAT_CORE_PJSIP
static BOOL DBCoreSipBackendCompiled(void) {
#ifdef DB_IOS_COMPAT_CORE_PJSIP
  return YES;
#else
  return NO;
#endif
}
#endif

@interface DBRouter ()
- (void)resolveCallRecoveryEvent:(NSDictionary *)event;
- (void)processCallRecoveryEvent:(NSDictionary *)event status:(NSDictionary *)status;
- (void)persistTargetedIndoorCall:(NSDictionary *)call;
- (void)clearPersistedIndoorCall:(NSString *)callID;
- (void)restoreTargetedIndoorCallFromStatus:(NSDictionary *)status;
@end

@implementation DBRouter {
  DBCoreBridge *_core;
  DBBootConfig *_boot;
  DBTexts *_texts;
  UIView *_container;
  DBScreen *_current;
  NSUInteger _transitionGeneration;
  DBHomeScreen *_home;
  DBDoorScreen *_door;
  DBIncomingScreen *_incoming;
  DBInfoScreen *_info;
  DBPairingScreen *_pairing;
  DBAddDeviceScreen *_addDevice;
  BOOL _pairingDeferred;
  DBPinOverlay *_pin;
  DBSipSession *_sip;
  DBSipListener *_sipListener;
  DBSiren *_effects;
  DBSiren *_launchAudio;
  NSDictionary *_soundConfig;
  NSString *_effectiveSipBackend;
  NSString *_sipFallbackReason;
  DBCallEventTracker *_callEvents;
  NSString *_selfDeviceID;
  NSString *_reportedRecoveryCallID;
  NSTimer *_emergencyPresentationTimer;
  UILocalNotification *_emergencyNotification;
  NSDictionary *_emergencyReport;
  BOOL _safeMode;
}

@synthesize core = _core;
@synthesize boot = _boot;
@synthesize texts = _texts;
@synthesize containerView = _container;


- (id)initWithBridge:(DBCoreBridge *)core boot:(DBBootConfig *)boot {
  self = [super init];
  if (self) {
    _core = core;
    _boot = boot;
    _texts = [[DBTexts alloc] init];
    _effects = [[DBSiren alloc] init];
    _launchAudio = [[DBSiren alloc] init];
    _callEvents = [[DBCallEventTracker alloc] init];
    [_texts setLang:_boot.uiLang];
    _container = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    _container.backgroundColor = [UIColor blackColor];

#ifdef DB_IOS_COMPAT_CORE_PJSIP
    _effectiveSipBackend = @"core";
    if ([_boot.sipBackend isEqualToString:@"minisip"])
      _sipFallbackReason = @"minisip_forbidden_by_ios9_profile";
#else
    BOOL oldOS = [[[UIDevice currentDevice] systemVersion] floatValue] < 7.0;
    BOOL coreSip = DBCoreSipBackendCompiled();
    if ([_boot.sipBackend isEqualToString:@"minisip"] || oldOS || !coreSip) {
      _effectiveSipBackend = @"minisip";
      if ([_boot.sipBackend isEqualToString:@"core"] && !coreSip)
        _sipFallbackReason = @"core_pjsip_not_compiled";
      else if ([_boot.sipBackend isEqualToString:@"core"] && oldOS)
        _sipFallbackReason = @"core_pjsip_unavailable_ios5";
    } else {
      _effectiveSipBackend = @"core";
    }
#endif
  }
  return self;
}

- (void)dealloc {
  [_emergencyPresentationTimer invalidate];
  if (_emergencyNotification)
    [[UIApplication sharedApplication] cancelLocalNotification:_emergencyNotification];
#ifndef DB_IOS_COMPAT_CORE_PJSIP
  _sip.delegate = nil;
  [_sip hangup];
  _sipListener.delegate = nil;
  [_sipListener stop];
#else
  [_core coreSipHangup];
#endif
}



- (DBHomeScreen *)home {
  if (!_home) _home = [[DBHomeScreen alloc] initWithRouter:self];
  return _home;
}

- (DBDoorScreen *)door {
  if (!_door) {
    _door = [[DBDoorScreen alloc] initWithRouter:self];
    if (_safeMode) [_door enterSafeMode];
  }
  return _door;
}

- (DBIncomingScreen *)incoming {
  if (!_incoming) {
    _incoming = [[DBIncomingScreen alloc] initWithRouter:self];
    if (_safeMode) [_incoming enterSafeMode];
  }
  return _incoming;
}

- (DBInfoScreen *)info {
  if (!_info) _info = [[DBInfoScreen alloc] initWithRouter:self];
  return _info;
}

- (DBPairingScreen *)pairing {
  if (!_pairing) _pairing = [[DBPairingScreen alloc] initWithRouter:self];
  return _pairing;
}

- (DBAddDeviceScreen *)addDevice {
  if (!_addDevice) _addDevice = [[DBAddDeviceScreen alloc] initWithRouter:self];
  return _addDevice;
}



- (void)start {
  [self showHomeAnimated:NO];
  [self refreshSoundConfig];
  [self refreshSelfDeviceIdentity];
  if ([_boot.role isEqualToString:@"door_station"]) {
#ifdef DB_IOS_COMPAT_CORE_PJSIP
    [self publishSipRuntimeState:@"core_managed" mode:@""];
#else
    BOOL useMiniSip = [_effectiveSipBackend isEqualToString:@"minisip"];
    if (useMiniSip) {
      [self publishSipRuntimeState:@"starting" mode:@""];
      _sipListener = [[DBSipListener alloc] initWithPort:(int)_boot.directPort
                                              micEnabled:_boot.micEnabled];
      _sipListener.delegate = self;
      [_sipListener start];
    } else {
      [self publishSipRuntimeState:@"core_managed" mode:@""];
    }
#endif
  } else {
    [self publishSipRuntimeState:@"ready" mode:@""];
  }
}

- (void)refreshSelfDeviceIdentity {
  __weak DBRouter *weakSelf = self;
  DBCoreBridge *core = _core;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSDictionary *status = [core status];
    NSString *identifier = [DBConfigUtil str:status path:@"node.id"];
    if (![identifier length]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
      DBRouter *router = weakSelf;
      if (router) {
        router->_selfDeviceID = [identifier copy];
        [router reportOwnedCallRecoveryFromStatus:status];
      }
    });
  });
}

- (void)reportOwnedCallRecoveryFromStatus:(NSDictionary *)status {
  [self processCallRecoveryEvent:nil status:status];
  [self restoreTargetedIndoorCallFromStatus:status];
}

- (void)persistTargetedIndoorCall:(NSDictionary *)call {
  if ([_boot.role isEqualToString:@"door_station"] ||
      ![call isKindOfClass:[NSDictionary class]]) return;
  NSMutableDictionary *saved = [NSMutableDictionary dictionary];
  for (NSString *key in @[
         @"call_id", @"door", @"purpose", @"visitor_lang", @"stage_revision",
         @"expires_at_ms"
       ]) {
    id value = [call objectForKey:key];
    if ([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]])
      [saved setObject:value forKey:key];
  }
  if ([[DBConfigUtil evStr:saved key:@"call_id"] length] == 0 ||
      [[DBConfigUtil evStr:saved key:@"door"] length] == 0 ||
      ![[saved objectForKey:@"stage_revision"] isKindOfClass:[NSNumber class]] ||
      ![[saved objectForKey:@"expires_at_ms"] isKindOfClass:[NSNumber class]]) return;
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  [defaults setObject:saved forKey:DBPendingIndoorCallDefaultsKey];
  BOOL synchronized = [defaults synchronize];
  NSLog(@"[doorbell][recovery] targeted indoor call persisted call=%@ expires=%lld ok=%d",
        [DBConfigUtil evStr:saved key:@"call_id"],
        [DBConfigUtil longLongVal:saved path:@"expires_at_ms" def:0],
        (int)synchronized);
}

- (void)clearPersistedIndoorCall:(NSString *)callID {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSDictionary *saved = [defaults objectForKey:DBPendingIndoorCallDefaultsKey];
  if (![saved isKindOfClass:[NSDictionary class]]) return;
  NSString *savedCallID = [DBConfigUtil evStr:saved key:@"call_id"];
  if ([callID length] > 0 && ![callID isEqualToString:savedCallID]) return;
  [defaults removeObjectForKey:DBPendingIndoorCallDefaultsKey];
  BOOL synchronized = [defaults synchronize];
  NSLog(@"[doorbell][recovery] targeted indoor call cleared call=%@ ok=%d",
        savedCallID, (int)synchronized);
}

- (void)restoreTargetedIndoorCallFromStatus:(NSDictionary *)status {
  if ([_boot.role isEqualToString:@"door_station"] ||
      ![status isKindOfClass:[NSDictionary class]]) return;
  NSDictionary *saved = [[NSUserDefaults standardUserDefaults]
      objectForKey:DBPendingIndoorCallDefaultsKey];
  if (![saved isKindOfClass:[NSDictionary class]]) return;
  NSString *callID = [DBConfigUtil evStr:saved key:@"call_id"];
  long long nowMs = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
  long long savedExpires =
      [DBConfigUtil longLongVal:saved path:@"expires_at_ms" def:0];
  if ([callID length] == 0 || savedExpires <= nowMs) {
    [self clearPersistedIndoorCall:callID];
    return;
  }
  // Runtime identity/capability refreshes also call this method. Once the
  // exact targeted call is already visible, a temporarily incomplete status
  // snapshot must not delete its crash-recovery marker.
  if (_current == _incoming &&
      [_callEvents.currentCallID isEqualToString:callID]) return;
  NSDictionary *selected = nil;
  BOOL matchingCallSeen = NO;
  NSArray *calls = [status objectForKey:@"active_calls"];
  if ([callID length] > 0 && [calls isKindOfClass:[NSArray class]]) {
    for (id rawCall in calls) {
      if (![rawCall isKindOfClass:[NSDictionary class]]) continue;
      NSDictionary *call = (NSDictionary *)rawCall;
      if (![[DBConfigUtil evStr:call key:@"call_id"] isEqualToString:callID]) continue;
      matchingCallSeen = YES;
      NSString *state = [DBConfigUtil evStr:call key:@"state"];
      long long expires = [DBConfigUtil longLongVal:call path:@"expires_at_ms" def:0];
      if (([state isEqualToString:@"ringing"] ||
           [state isEqualToString:@"purpose_pending"]) && expires > nowMs) {
        selected = call;
      }
      break;
    }
  }
  if (!selected) {
    // Missing is not terminal: mesh/status convergence can lag the targeted
    // chime. A matching but non-waiting row is authoritative and may clear.
    if (matchingCallSeen) [self clearPersistedIndoorCall:callID];
    return;
  }

  NSMutableDictionary *chime = [saved mutableCopy];
  for (NSString *key in @[
         @"door", @"purpose", @"visitor_lang", @"stage_revision", @"expires_at_ms"
       ]) {
    id value = [selected objectForKey:key];
    if ([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]])
      [chime setObject:value forKey:key];
  }
  [chime setObject:@2 forKey:@"schema_version"];
  [chime setObject:@"chime" forKey:@"t"];
  [chime setObject:callID forKey:@"call_id"];
  NSDictionary *accepted = [_callEvents acceptChimeEvent:chime nowMs:nowMs];
  if (!accepted) {
    [self clearPersistedIndoorCall:callID];
    return;
  }
  [_home playChime:accepted];
  [self showIncoming:[DBConfigUtil evStr:accepted key:@"door"]
             purpose:[DBConfigUtil evStr:accepted key:@"purpose"]
                lang:[DBConfigUtil evStr:accepted key:@"visitor_lang"]
              callID:callID
       stageRevision:[DBConfigUtil intVal:accepted path:@"stage_revision" def:0]
          expiresAtMs:[DBConfigUtil longLongVal:accepted path:@"expires_at_ms" def:0]];
}

- (void)resolveCallRecoveryEvent:(NSDictionary *)event {
  NSDictionary *recoveryEvent = [event copy];
  __weak DBRouter *weakSelf = self;
  DBCoreBridge *core = _core;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSDictionary *status = [core status];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBRouter *router = weakSelf;
      if (router) [router processCallRecoveryEvent:recoveryEvent status:status];
    });
  });
}

- (void)processCallRecoveryEvent:(NSDictionary *)event status:(NSDictionary *)status {
  NSString *requestedCallID = [DBConfigUtil evStr:event key:@"call_id"];
  NSString *statusDeviceID = [DBConfigUtil str:status path:@"node.id"];
  if ([statusDeviceID length] > 0) _selfDeviceID = [statusDeviceID copy];
  if (![_selfDeviceID length]) {
    if ([requestedCallID length]) [_core reportCallRecovery:requestedCallID restored:NO];
    return;
  }

  NSArray *calls = [status objectForKey:@"active_calls"];
  NSDictionary *selected = nil;
  if ([calls isKindOfClass:[NSArray class]]) {
    for (id rawCall in calls) {
      if (![rawCall isKindOfClass:[NSDictionary class]]) continue;
      NSDictionary *call = (NSDictionary *)rawCall;
      NSString *callID = [DBConfigUtil evStr:call key:@"call_id"];
      if (![callID length] ||
          ([requestedCallID length] && ![requestedCallID isEqualToString:callID])) continue;
      NSString *state = [DBConfigUtil evStr:call key:@"state"];
      BOOL ownsDialog = [state isEqualToString:@"in_call"] &&
          [[DBConfigUtil evStr:call key:@"dialog_owner"] isEqualToString:_selfDeviceID];
      BOOL ownsWaiting = [state isEqualToString:@"ringing"] &&
          [[DBConfigUtil evStr:call key:@"origin"] isEqualToString:_selfDeviceID] &&
          [_boot.role isEqualToString:@"door_station"] &&
          ([[DBConfigUtil evStr:call key:@"door"] length] == 0 ||
           [[DBConfigUtil evStr:call key:@"door"] isEqualToString:_boot.door]);
      if ([requestedCallID length] || ownsDialog || ownsWaiting) {
        selected = call;
        break;
      }
    }
  }

  if (!selected) {
    NSString *eventOwner = [DBConfigUtil evStr:event key:@"dialog_owner"];
    if ([requestedCallID length] &&
        ([eventOwner length] == 0 || [eventOwner isEqualToString:_selfDeviceID]) &&
        ![_reportedRecoveryCallID isEqualToString:requestedCallID]) {
      _reportedRecoveryCallID = [requestedCallID copy];
      [_core reportCallRecovery:requestedCallID restored:NO];
    }
    return;
  }

  NSString *callID = [DBConfigUtil evStr:selected key:@"call_id"];
  if ([_reportedRecoveryCallID isEqualToString:callID]) return;
  NSString *persistedState = [DBConfigUtil evStr:selected key:@"state"];
  NSString *eventState = [DBConfigUtil evStr:event key:@"state"];
  NSString *eventOwner = [DBConfigUtil evStr:event key:@"dialog_owner"];
  NSString *owner = [eventOwner length] > 0
      ? eventOwner : [DBConfigUtil evStr:selected key:@"dialog_owner"];
  if ([persistedState isEqualToString:@"in_call"] ||
      [eventState isEqualToString:@"in_call"]) {
    if (![owner isEqualToString:_selfDeviceID]) return;
    _reportedRecoveryCallID = [callID copy];
    // Neither MiniSIP nor Core PJSIP keeps a native dialog across process restart.
    [_core reportCallRecovery:callID restored:NO];
    return;
  }

  BOOL ownsWaiting = [_boot.role isEqualToString:@"door_station"] &&
      [[DBConfigUtil evStr:selected key:@"origin"] isEqualToString:_selfDeviceID] &&
      ([persistedState isEqualToString:@"ringing"] ||
       [eventState isEqualToString:@"ringing"] ||
       [eventState isEqualToString:@"purpose_pending"]);
  if (!ownsWaiting) return;
  BOOL restored = [self.door restoreWaitingCall:selected recoveryState:eventState];
  _reportedRecoveryCallID = [callID copy];
  [_core reportCallRecovery:callID restored:restored];
}

- (NSString *)effectiveSipBackend {
  return _effectiveSipBackend ?: @"minisip";
}

- (void)publishSipRuntimeState:(NSString *)state mode:(NSString *)mode {
  BOOL miniSip = [[self effectiveSipBackend] isEqualToString:@"minisip"];
  BOOL doorUAS = [_boot.role isEqualToString:@"door_station"] && miniSip;
  NSMutableDictionary *runtime = [@{
    @"schema_version" : @1,
    @"configured_backend" : _boot.sipBackend ?: @"auto",
    @"effective_backend" : [self effectiveSipBackend],
    @"implementation" : miniSip ? @"mini_sip_direct_pcmu" : @"core_pjsip",
    @"state" : state ?: @"unknown",
    @"direct_port" : @(_boot.directPort),
    @"uac_compiled" : @YES,
    @"uas_enabled" : @(doorUAS),
    @"pcmu" : @(miniSip),
    @"sip_tls" : @NO,
    @"srtp" : @NO,
  } mutableCopy];
  if ([mode length] > 0 && ![mode isEqualToString:@"bind_failed"])
    [runtime setObject:mode forKey:@"dialog_mode"];
  if ([_sipFallbackReason length] > 0)
    [runtime setObject:_sipFallbackReason forKey:@"fallback_reason"];
  [_core setRuntimeStatusSection:@"sip" value:runtime];
}

- (void)refreshSoundConfig {
  __weak DBRouter *wself = self;
  DBCoreBridge *core = _core;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSDictionary *cfg = [core config];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBRouter *s = wself;
      if (s && [cfg isKindOfClass:[NSDictionary class]]) s->_soundConfig = cfg;
    });
  });
}

- (NSString *)soundValue:(NSString *)key fallback:(NSString *)fallback {
  id value = [DBConfigUtil dig:_soundConfig path:[@"ui." stringByAppendingString:key]];
  return [value isKindOfClass:[NSString class]] ? value : fallback;
}

- (void)playLaunchSound {


  __weak DBRouter *wself = self;
  DBCoreBridge *core = _core;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSDictionary *cfg = [core config];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBRouter *s = wself;
      if (!s) return;
      if ([cfg isKindOfClass:[NSDictionary class]]) s->_soundConfig = cfg;
      [s->_launchAudio playConfiguredSound:[s soundValue:@"launch_sound"
                                                    fallback:@"title_display"]
                                         loop:NO];
    });
  });
}

- (void)playButtonSound {
  [_effects playConfiguredSound:[self soundValue:@"button_sound" fallback:@"button_click"] loop:NO];
}

- (void)playUpdateSound {
  [_effects playConfiguredSound:[self soundValue:@"update_sound" fallback:@"indoor_update"] loop:NO];
}

- (void)transitionTo:(DBScreen *)next animated:(BOOL)animated {
  if (_safeMode) animated = NO;
  if (_current == next) {
    // A superseded animation completion must never be able to leave the
    // logical current screen detached from the container.
    next.alpha = 1.0;
    if (next.superview != _container) [_container addSubview:next];
    [_container bringSubviewToFront:next];
    [next setNeedsLayout];
    return;
  }
  NSUInteger generation = ++_transitionGeneration;
  next.frame = _container.bounds;
  next.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  DBScreen *old = _current;
  _current = next;
  [old onScreenWillDisappear];
  [next onScreenWillAppear];
  if (animated) {
    next.alpha = 0.0;
    [_container addSubview:next];
    [_container bringSubviewToFront:next];
    __weak DBRouter *weakSelf = self;
    [UIView animateWithDuration:0.25
        animations:^{ next.alpha = 1.0; }
        completion:^(BOOL finished) {
          (void)finished;
          DBRouter *router = weakSelf;
          if (!router) return;
          // Transitions can reverse within the animation window (for example
          // a late lifecycle event immediately after a chime).  A stale
          // completion may remove only a screen that is still non-current.
          if (old != router->_current) [old removeFromSuperview];
          if (generation == router->_transitionGeneration &&
              router->_current == next) {
            next.alpha = 1.0;
            if (next.superview != router->_container)
              [router->_container addSubview:next];
            [router->_container bringSubviewToFront:next];
          }
        }];
  } else {
    next.alpha = 1.0;
    [_container addSubview:next];
    [_container bringSubviewToFront:next];
    if (old != _current) [old removeFromSuperview];
  }
}

- (void)showHomeAnimated:(BOOL)animated {
  DBScreen *primary = [_boot.role isEqualToString:@"door_station"] ? self.door : self.home;
  [self transitionTo:primary animated:animated];
  [self checkPairingDeferred];
}



- (void)checkPairingDeferred {
  if (_pairingDeferred) return;
  __weak DBRouter *wself = self;
  DBCoreBridge *core = _core;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    DBRouter *s = wself;
    if (!s || s->_pairingDeferred) return;
    DBScreen *primary = [s->_boot.role isEqualToString:@"door_station"] ? s->_door : s->_home;
    if (s->_current != primary || !primary) return;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      NSDictionary *p = [core pairingInfo];
      dispatch_async(dispatch_get_main_queue(), ^{
        DBRouter *s2 = wself;
        if (!s2 || s2->_pairingDeferred) return;
        DBScreen *primary2 = [s2->_boot.role isEqualToString:@"door_station"] ? s2->_door : s2->_home;
        if (s2->_current != primary2) return;
        // "{}" before the first snapshot is unknown, never unpaired: showing
        // onboarding on top of a paired kiosk would be a false alarm.
        NSString *state = [DBPairingModel stateFromPairingInfo:p];
        if ([state isEqualToString:DBPairingStateUnknown] ||
            [state isEqualToString:@"ready"]) return;
        [s2 showPairing];
      });
    });
  });
}

- (BOOL)currentIsPrimaryScreen {
  DBScreen *primary = [_boot.role isEqualToString:@"door_station"] ? _door : _home;
  return primary != nil && _current == primary;
}

- (void)pairingDeferredByUser {
  _pairingDeferred = YES;
  if (_home) [_home refreshFromCore];
}

- (void)showIncoming:(NSString *)door purpose:(NSString *)purpose lang:(NSString *)lang
               callID:(NSString *)callID stageRevision:(NSInteger)stageRevision
          expiresAtMs:(long long)expiresAtMs {
  [[self incoming] prepareWithDoor:door purpose:purpose lang:lang callID:callID
                     stageRevision:stageRevision expiresAtMs:expiresAtMs];
  [self transitionTo:_incoming animated:YES];
}

- (void)showMonitorPeer:(NSDictionary *)peer {
  [_callEvents clearCurrentCall];
  [[self home] stopChime];
  [[self incoming] prepareMonitorWithPeer:peer];
  [self transitionTo:_incoming animated:YES];
}

- (void)closeIncomingAnimated:(BOOL)animated {
  if (_current != _incoming) return;
  [self clearPersistedIndoorCall:_callEvents.currentCallID];
  [_callEvents clearCurrentCall];
  [[self home] stopChime];
  [self showHomeAnimated:animated];
}

- (void)showInfo {
  [[self info] reload];
  [self transitionTo:_info animated:YES];
}

- (void)closeInfoAnimated:(BOOL)animated {
  if (_current == _info) [self showHomeAnimated:animated];
}

- (void)showPairing {
  // Opening onboarding on purpose (banner tap, revoke, clear pairing) cancels a
  // previous 「あとで設定」.
  _pairingDeferred = NO;
  [[self pairing] startPolling];
  [self transitionTo:_pairing animated:YES];
}

- (void)closePairingAnimated:(BOOL)animated {
  if (_current != _pairing) return;
  [_pairing stopPolling];
  [self showHomeAnimated:animated];
}

- (void)showAddDevice {
  [[self addDevice] startPolling];
  [self transitionTo:_addDevice animated:YES];
}

- (void)closeAddDeviceAnimated:(BOOL)animated {
  if (_current != _addDevice) return;
  [_addDevice stopPolling];
  [self showHomeAnimated:animated];
}

- (NSString *)currentScreenName {
  if (_pin && _pin.superview) return [NSString stringWithFormat:@"pin+%@", [_current screenName]];
  return [_current screenName];
}


- (void)requestPinThen:(void (^)(void))action {
  if (!_pin) _pin = [[DBPinOverlay alloc] initWithRouter:self];
  [_pin presentInView:_container then:action];
}

- (void)dismissPinOverlay {
  [_pin dismiss];
}



- (void)sipStart:(NSString *)host port:(int)port mode:(NSString *)mode {
  [self sipHangup];
  if ([host length] == 0) return;
#ifdef DB_IOS_COMPAT_CORE_PJSIP
  NSString *target = [NSString stringWithFormat:@"sip:%@:%d", host, port];
  [_core coreSipCall:target mode:mode ?: @""];
#else
  _sip = [[DBSipSession alloc] initWithHost:host port:port mode:mode micEnabled:_boot.micEnabled];
  _sip.delegate = self;
  [_sip start];
#endif
}

- (void)sipHangup {
#ifdef DB_IOS_COMPAT_CORE_PJSIP
  [_core coreSipHangup];
#else
  if (!_sip) return;
  _sip.delegate = nil;
  [_sip hangup];
  _sip = nil;
#endif
}

- (void)sipSendDtmf:(NSString *)digits {
#ifdef DB_IOS_COMPAT_CORE_PJSIP
  [_core coreSipSendDtmf:digits];
#else
  [_sip sendDtmf:digits];
#endif
}

- (void)sipListenerHangup {
#ifdef DB_IOS_COMPAT_CORE_PJSIP
  [_core coreSipHangup];
#else
  [_sipListener hangupCurrentCall];
#endif
}

- (void)releaseMediaForMemoryPressure {
  [_incoming releaseMediaForMemoryPressure];
  [_door releaseMediaForMemoryPressure];
}

- (void)suspendMediaForBackground {
  [_incoming suspendMediaForBackground];
  [_door suspendMediaForBackground];
}

- (void)resumeMediaAfterBackground {
  [_incoming resumeMediaAfterBackground];
  [_door resumeMediaAfterBackground];
}

- (void)setSafeMode:(BOOL)enabled reason:(NSString *)reason {
  if (!enabled) {
    if (!_safeMode) return;
    _safeMode = NO;
    [_incoming exitSafeMode];
    [_door exitSafeMode];
    if (_home) [_home exitSafeMode];
    [_core setRuntimeStatusSection:@"safe_mode" value:@{
      @"schema_version" : @1,
      @"active" : @NO,
      @"reason" : reason ?: @"healthy_runtime",
      @"sip_audio" : @"available",
      @"ringer" : @"available",
      @"sos" : @"available",
      @"controls" : @"available",
      @"custom_visuals" : @"available",
    }];
    return;
  }
  if (_safeMode) return;
  _safeMode = YES;
  [_incoming enterSafeMode];
  [_door enterSafeMode];
  if (_home) [_home enterSafeMode];
  NSDictionary *media = [_boot.role isEqualToString:@"door_station"]
      ? [[self door] safeModeMediaStatus] : [[self incoming] safeModeMediaStatus];
  [_core setRuntimeStatusSection:@"safe_mode" value:@{
    @"schema_version" : @1,
    @"active" : @YES,
    @"reason" : reason ?: @"unknown",
    @"media" : media ?: @{},
    @"sip_audio" : @"available",
    @"ringer" : @"available",
    @"sos" : @"available",
    @"controls" : @"available",
    @"custom_visuals" : @"disabled",
  }];
}

- (void)hideEmergencyPresentation {
  NSDictionary *clear = @{ @"active" : @NO };
  if ([_boot.role isEqualToString:@"door_station"])
    [_door handleEmergencyEvent:clear];
  else
    [_home hideEmergencyEvent:clear];
}

- (void)clearEmergencySystemNotification {
  if (!_emergencyNotification) return;
  [[UIApplication sharedApplication] cancelLocalNotification:_emergencyNotification];
  _emergencyNotification = nil;
}

- (void)publishEmergencyReportForEvent:(NSDictionary *)event channels:(NSArray *)channels {
  _emergencyReport = @{
    @"schema_version" : @1,
    @"event_hlc" : [DBConfigUtil evStr:event key:@"event_hlc"] ?: @"",
    @"active" : @([DBConfigUtil evBool:event key:@"active"]),
    @"result" : [channels count] > 0 ? @"applied" : @"not_requested",
    @"channels" : channels ?: @[],
    @"updated_at_ms" : @((long long)([[NSDate date] timeIntervalSince1970] * 1000.0)),
  };
  [_core setRuntimeStatusSection:@"device_alert" value:_emergencyReport];
}

- (void)onEmergencyPresentationTimeout:(NSTimer *)timer {
  (void)timer;
  [_emergencyPresentationTimer invalidate];
  _emergencyPresentationTimer = nil;
  [self hideEmergencyPresentation];
  [self clearEmergencySystemNotification];
  NSArray *oldChannels = [_emergencyReport objectForKey:@"channels"];
  NSMutableArray *expired = [NSMutableArray array];
  for (NSDictionary *channel in oldChannels) {
    NSMutableDictionary *next = [channel mutableCopy];
    if ([[channel objectForKey:@"channel"] isEqualToString:@"system_notification"]) {
      [next setObject:@"unsupported" forKey:@"result"];
      NSString *old = [channel objectForKey:@"limitation"];
      if (![old isKindOfClass:[NSString class]] ||
          [old rangeOfString:@"delivered_notification_removal_unavailable"].location == NSNotFound) {
        NSString *combined = [old length] > 0
            ? [old stringByAppendingString:@";delivered_notification_removal_unavailable"]
            : @"delivered_notification_removal_unavailable";
        [next setObject:combined forKey:@"limitation"];
      }
    } else {
      [next setObject:@"ttl_expired" forKey:@"result"];
    }
    [expired addObject:next];
  }
  NSMutableDictionary *report = [_emergencyReport mutableCopy];
  [report setObject:expired forKey:@"channels"];
  [report setObject:@((long long)([[NSDate date] timeIntervalSince1970] * 1000.0))
              forKey:@"updated_at_ms"];
  _emergencyReport = report;
  [_core setRuntimeStatusSection:@"device_alert" value:_emergencyReport];
}

- (NSString *)postEmergencySystemNotification:(NSDictionary *)event {
  UIApplication *application = [UIApplication sharedApplication];
  [self clearEmergencySystemNotification];
  BOOL visual = DBEmergencyBool(event, @"visual", YES);
  NSInteger volume = [DBConfigUtil intVal:event path:@"alarm_volume" def:100];
  BOOL sound = volume > 0 &&
      ([[DBConfigUtil evStr:event key:@"alarm_sound"] length] > 0 ||
       [[DBConfigUtil evStr:event key:@"audio_path"] length] > 0);
  if (!visual && !sound) return @"suppressed_by_presentation";
  UILocalNotification *notification = [[UILocalNotification alloc] init];
  if (visual) {
    notification.alertAction = [_texts ts:@"emergency.title"];
    notification.alertBody = [_texts ts:[DBConfigUtil evBool:event key:@"active"]
        ? @"emergency.notified" : @"emergency.cancel"];
  }
  if (sound)
    notification.soundName = UILocalNotificationDefaultSoundName;
  notification.userInfo = @{
    @"kind" : [DBConfigUtil evBool:event key:@"active"]
        ? @"emergency" : @"emergency_cancel"
  };
  _emergencyNotification = notification;
  [application presentLocalNotificationNow:notification];
  return @"presented";
}

- (void)miniSipListenerStateChanged:(DBMiniSipState)state mode:(NSString *)mode {
  NSString *runtimeState = @"unknown";
  if (state == DBMiniSipListening) runtimeState = @"listening";
  else if (state == DBMiniSipRinging) runtimeState = @"ringing";
  else if (state == DBMiniSipInCall) runtimeState = @"in_call";
  else if (state == DBMiniSipCalling) runtimeState = @"calling";
  else if ([mode isEqualToString:@"bind_failed"]) runtimeState = @"bind_failed_retrying";
  else if (state == DBMiniSipEnded) runtimeState = @"restarting_listener";
  [self publishSipRuntimeState:runtimeState mode:mode];
  if ([_boot.role isEqualToString:@"door_station"])
    [self.door miniSipListenerStateChanged:state mode:mode];
}


- (void)miniSipStateChanged:(DBMiniSipState)state {
  if (state == DBMiniSipEnded && [_callEvents consumeSupersededIdleForCurrentCall]) {
    if (_current == _incoming) [_incoming handleSupersededSipIdle];
    return;
  }
  if (_current == _incoming) [_incoming sipStateChanged:state];
}



- (void)onCoreEvent:(NSDictionary *)ev {
  NSString *t = [DBConfigUtil evStr:ev key:@"t"];

  if ([t isEqualToString:@"call_recovery_required"]) {
    [self resolveCallRecoveryEvent:ev];
    return;
  }

  if ([t isEqualToString:@"event"]) {
    NSString *type = [DBConfigUtil evStr:ev key:@"type"];
    if ([_boot.role isEqualToString:@"door_station"] &&
        ([type isEqualToString:@"press"] || [type isEqualToString:@"purpose_selected"])) {
      [_door handleCallEvent:ev];
      return;
    }
    if ([_boot.role isEqualToString:@"door_station"] &&
        [type isEqualToString:@"call_answered"]) {
      [_door handleCallAnswered:ev];
      return;
    }
    if ([_boot.role isEqualToString:@"door_station"] &&
        [type isEqualToString:@"call_ended"]) {
      [_door handleCallEnded:ev];
      return;
    }
    // A replicated press only refreshes call data/history. Core emits a
    // separate, locally targeted schema-v2 chime when this panel should ring.
    if ([type isEqualToString:@"press"] && ![_boot.role isEqualToString:@"door_station"]) {
      [_callEvents recordCallEvent:ev];
      if (_current == _incoming && ![_incoming isActiveMonitor] &&
          [_callEvents eventMatchesCurrentCall:ev]) {
        [_incoming refreshPurpose:[DBConfigUtil evStr:ev key:@"purpose"]
                             lang:[DBConfigUtil evStr:ev key:@"visitor_lang"]
                    stageRevision:[DBConfigUtil intVal:ev path:@"stage_revision" def:0]];
      }
      [_home appendEvent:ev];
      return;
    }
    if ([type isEqualToString:@"call_cancelled"] &&
        [_boot.role isEqualToString:@"door_station"]) {
      [_door handleCallCancelled:ev];
      return;
    }
    if ([type isEqualToString:@"call_cancelled"] &&
        ![_boot.role isEqualToString:@"door_station"]) {
      BOOL currentCall = [_callEvents eventMatchesCurrentCall:ev];
      [self clearPersistedIndoorCall:[DBConfigUtil evStr:ev key:@"call_id"]];
      [_callEvents recordCancellationEvent:ev];
      if (currentCall) {
        [self playUpdateSound];
        [[self home] stopChime];
        if (_current == _incoming) [_incoming handleCallCancelled:ev];
      }
      [_home appendEvent:ev];
      return;
    }
    if ([type isEqualToString:@"call_answered"] &&
        ![_boot.role isEqualToString:@"door_station"]) {
      BOOL currentCall = [_callEvents recordAnsweredEvent:ev];
      [self clearPersistedIndoorCall:[DBConfigUtil evStr:ev key:@"call_id"]];
      if (currentCall) {
        [[self home] stopChime];
        NSString *answeringDevice = [DBConfigUtil evStr:ev key:@"dialog_owner"];
        if ([answeringDevice length] == 0)
          answeringDevice = [DBConfigUtil evStr:ev key:@"device"];
        BOOL identityMatches = [answeringDevice length] == 0 || [_selfDeviceID length] == 0 ||
            [answeringDevice isEqualToString:_selfDeviceID];
        BOOL localAnswerer = _current == _incoming && [_incoming isAnsweringCall] &&
            identityMatches;
        if (!localAnswerer) {
          if (_current == _incoming) [_incoming yieldAnsweredDialog];
          [self sipHangup];
          if (_current == _incoming) [self closeIncomingAnimated:YES];
        }
      }
      [_home appendEvent:ev];
      return;
    }
    if ([type isEqualToString:@"call_ended"] &&
        ![_boot.role isEqualToString:@"door_station"]) {
      BOOL currentCall = [_callEvents recordEndedEvent:ev];
      [self clearPersistedIndoorCall:[DBConfigUtil evStr:ev key:@"call_id"]];
      if (currentCall) {
        [[self home] stopChime];
        [self sipHangup];
        if (_current == _incoming) [self closeIncomingAnimated:YES];
      }
      [_home appendEvent:ev];
      return;
    }
    if ([type isEqualToString:@"purpose_selected"] &&
        ![_boot.role isEqualToString:@"door_station"]) {
      BOOL accepted = [_callEvents recordCallEvent:ev];
      if (accepted && [_callEvents eventMatchesCurrentCall:ev]) {
        [self playUpdateSound];
        if (_current == _incoming && ![_incoming isActiveMonitor])
          [_incoming handlePurposeSelected:ev];
      }
      [_home appendEvent:ev];
      return;
    }
    if ([_boot.role isEqualToString:@"door_station"]) {
      // Door flow consumes its own press through the core state callback. Other
      // replicated events need no indoor-only history UI here.
    } else {
      [_home appendEvent:ev];
    }
  } else if ([t isEqualToString:@"chime"]) {
    if ([_boot.role isEqualToString:@"door_station"]) return;
    NSString *callID = [DBConfigUtil evStr:ev key:@"call_id"];
    if ([callID length] == 0) {
      // Administrative chimes without an active call remain sound-only.
      [_home playChime:ev];
      return;
    }
    NSString *previousCallID = _callEvents.currentCallID;
    long long nowMs = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
    NSDictionary *chime = [_callEvents acceptChimeEvent:ev nowMs:nowMs];
    if (!chime) return;  // expired, malformed, duplicate, or stale revision
    [self persistTargetedIndoorCall:chime];
    [_home playChime:chime];
    BOOL sameCall = [previousCallID length] > 0 && [previousCallID isEqualToString:callID];
    if (sameCall && _current == _incoming && ![_incoming isActiveMonitor]) {
      [_incoming refreshPurpose:[DBConfigUtil evStr:chime key:@"purpose"]
                           lang:[DBConfigUtil evStr:chime key:@"visitor_lang"]
                  stageRevision:[DBConfigUtil intVal:chime path:@"stage_revision" def:0]];
      return;
    }
    [self showIncoming:[DBConfigUtil evStr:chime key:@"door"]
               purpose:[DBConfigUtil evStr:chime key:@"purpose"]
                  lang:[DBConfigUtil evStr:chime key:@"visitor_lang"]
                callID:callID
         stageRevision:[DBConfigUtil intVal:chime path:@"stage_revision" def:0]
            expiresAtMs:[DBConfigUtil longLongVal:chime path:@"expires_at_ms" def:0]];
  } else if ([t isEqualToString:@"reply"]) {
    if ([_boot.role isEqualToString:@"door_station"]) {
      [_door handleReplyEvent:ev];
    } else if (_current == _incoming) {
      [_incoming handleReplyEvent:ev];
    } else {
      [_home showReplyBanner:ev];
    }
  } else if ([t isEqualToString:@"visitor_lang"]) {
    if ([_boot.role isEqualToString:@"door_station"])
      [_door handleVisitorLangEvent:ev];
    else if (_current == _incoming)
      [_incoming handleVisitorLangEvent:ev];
  } else if ([t isEqualToString:@"state"]) {
    if ([_boot.role isEqualToString:@"door_station"]) {
      [_door handleStateEvent:ev];
#ifdef DB_IOS_COMPAT_CORE_PJSIP
    } else if (_current == _incoming) {
      NSString *state = [DBConfigUtil evStr:ev key:@"state"];
      if ([state isEqualToString:@"in_call"])
        [_incoming sipStateChanged:DBMiniSipInCall];
      else if ([state isEqualToString:@"idle"]) {
        if ([_callEvents consumeSupersededIdleForCurrentCall])
          [_incoming handleSupersededSipIdle];
        else
          [_incoming sipStateChanged:DBMiniSipEnded];
      }
#endif
    }
  } else if ([t isEqualToString:@"display"]) {
    if ([_boot.role isEqualToString:@"door_station"])
      [_door refreshFromCore];
    else
      [_home applyDisplayEvent:ev];
  } else if ([t isEqualToString:@"emergency"]) {
    BOOL active = [DBConfigUtil evBool:ev key:@"active"];
    BOOL inApp = DBEmergencyUsesChannel(ev, @"in_app");
    BOOL systemNotification = DBEmergencyUsesChannel(ev, @"system_notification");
    BOOL visual = DBEmergencyBool(ev, @"visual", YES);
    BOOL sticky = DBEmergencyBool(ev, @"sticky", active);
    NSTimeInterval ttl = [DBConfigUtil doubleVal:ev path:@"ttl_s" def:(active ? 0 : 10)];
    ttl = MAX(0, ttl);
    NSInteger volume = [DBConfigUtil intVal:ev path:@"alarm_volume" def:100];
    BOOL sound = volume > 0 &&
        ([[DBConfigUtil evStr:ev key:@"alarm_sound"] length] > 0 ||
         [[DBConfigUtil evStr:ev key:@"audio_path"] length] > 0);
    BOOL systemSound = sound && (!inApp || !active);
    NSMutableArray *results = [NSMutableArray array];
    [_emergencyPresentationTimer invalidate];
    _emergencyPresentationTimer = nil;

    if (!active) {
      [self hideEmergencyPresentation];
      [self clearEmergencySystemNotification];
    }
    if (inApp) {
      NSString *colorLimitation =
          [[DBConfigUtil emergencyPalette:ev] objectForKey:@"limitation"];
      [results addObject:DBEmergencyChannelResult(
          @"in_app", active ? @"presented" : @"cleared", visual && active,
          sound && active, sticky && active, ttl, colorLimitation)];
    }
    if (systemNotification) {
      NSMutableDictionary *systemEvent = [ev mutableCopy];
      if (!systemSound) [systemEvent setObject:@0 forKey:@"alarm_volume"];
      NSString *systemResult = [self postEmergencySystemNotification:systemEvent];
      NSMutableArray *limitations = [NSMutableArray array];
      if (sticky) [limitations addObject:@"sticky_system_notification_unsupported"];
      if (!sticky && ttl > 0)
        [limitations addObject:@"delivered_notification_removal_unavailable"];
      if (systemSound && volume < 100)
        [limitations addObject:@"system_notification_volume_is_binary"];
      if (sound && !systemSound)
        [limitations addObject:@"sound_owned_by_in_app_channel"];
      [results addObject:DBEmergencyChannelResult(
          @"system_notification", systemResult, visual, systemSound, NO, ttl,
          [limitations componentsJoinedByString:@";"])];
    }
    id rawChannels = [ev objectForKey:@"channels"];
    if ([rawChannels isKindOfClass:[NSArray class]]) {
      for (id rawChannel in (NSArray *)rawChannels) {
        if (![rawChannel isKindOfClass:[NSString class]]) continue;
        NSString *channel = (NSString *)rawChannel;
        if ([channel isEqualToString:@"in_app"] ||
            [channel isEqualToString:@"system_notification"]) continue;
        [results addObject:DBEmergencyChannelResult(
            channel, @"unsupported", NO, NO, NO, 0, @"unsupported_channel")];
      }
    }
    [self publishEmergencyReportForEvent:ev channels:results];

    if (!active) {
      if (!sticky && ttl > 0 && systemNotification) {
        _emergencyPresentationTimer =
            [NSTimer scheduledTimerWithTimeInterval:ttl target:self
                                           selector:@selector(onEmergencyPresentationTimeout:)
                                           userInfo:nil repeats:NO];
      }
      return;
    }
    if (!inApp && !systemNotification) return;

    if (inApp && visual && ![_boot.role isEqualToString:@"door_station"])
      [self closeIncomingAnimated:NO];
    if (inApp) {
      if ([_boot.role isEqualToString:@"door_station"])
        [_door handleEmergencyEvent:ev];
      else
        [_home showEmergencyEvent:ev];
    }

    if (!sticky && ttl > 0) {
      _emergencyPresentationTimer =
          [NSTimer scheduledTimerWithTimeInterval:ttl target:self
                                         selector:@selector(onEmergencyPresentationTimeout:)
                                         userInfo:nil repeats:NO];
    }
  } else if ([t isEqualToString:@"paired"]) {
    [self onPaired:ev];
  } else if ([t isEqualToString:@"pairing_persistence_error"]) {
    [_core setRuntimeStatusSection:@"secure_store" value:@{
      @"schema_version" : @1,
      @"available" : @NO,
      @"implementation" : @"ios_keychain_generic_password",
      @"accessibility" : @"after_first_unlock",
      @"pairing_persistence" : @"core_secure_put_failed",
    }];
    [[self pairing] handlePersistenceError];
    _pairingDeferred = NO;
    if (_current != _pairing) [self showPairing];
    NSLog(@"[doorbell] pairing persistence failed before a secret reference was issued");
  } else if ([t isEqualToString:@"join_result"]) {
    if (_current == _pairing) [_pairing handleJoinResult:ev];
  } else if ([t isEqualToString:@"invite_rejected"]) {
    if (_current == _pairing) [_pairing handleInviteRejected:ev];
  } else if ([t isEqualToString:@"pairing_state"]) {
    NSString *state = [DBConfigUtil evStr:ev key:@"state"];
    if (_current == _pairing) [_pairing handlePairingState:ev];
    if (_current == _addDevice) [_addDevice handlePairingState:ev];
    if ([state isEqualToString:@"ready"]) _pairingDeferred = NO;
    // Membership changes the Home banner and can add or remove door stations.
    if (_home) [_home refreshFromCore];
    // Only ever replace the idle primary screen. A live call, the monitor, or
    // the admin panel must not be torn down by a membership event.
    if (![state isEqualToString:@"ready"] && ![state isEqualToString:@"revoked"] &&
        !_pairingDeferred && [self currentIsPrimaryScreen])
      [self showPairing];
  } else if ([t isEqualToString:@"pairing_revoked"]) {
    _pairingDeferred = NO;
    [[self pairing] handleRevoked:ev];
    if (_home) [_home refreshFromCore];
    if (_current != _pairing && [self currentIsPrimaryScreen]) [self showPairing];
  } else if ([t isEqualToString:@"pending_changed"]) {
    if (_current == _addDevice) [_addDevice handlePendingChanged:ev];
  } else if ([t isEqualToString:@"invite_result"]) {
    if (_current == _addDevice) [_addDevice handleInviteResult:ev];
  } else if ([t isEqualToString:@"device_joined"]) {
    if (_current == _addDevice) [_addDevice handleDeviceJoined:ev];
    // A door station that just joined must reach the monitor list without
    // waiting for the next peers_changed.
    if (_home) [_home refreshFromCore];
    if (_current == _door) [_door refreshFromCore];
    if (_current == _incoming) [_incoming refreshFromCore];
  } else if ([t isEqualToString:@"pairing_mode_changed"]) {
    if (_current == _addDevice) [_addDevice handlePairingModeChanged:ev];
  } else if ([t isEqualToString:@"join_token_changed"]) {
    if (_current == _addDevice) [_addDevice handleJoinTokenChanged:ev];
  } else if ([t isEqualToString:@"peers_changed"] || [t isEqualToString:@"config_changed"] ||
             [t isEqualToString:@"asset_ready"]) {
    if ([t isEqualToString:@"peers_changed"] || [t isEqualToString:@"config_changed"])
      [self refreshSelfDeviceIdentity];
    if ([t isEqualToString:@"config_changed"] || [t isEqualToString:@"asset_ready"])
      [self refreshSoundConfig];
    // Refresh Home even while it is covered: its door list is what the idle
    // 「門口を見る」 picker renders the moment the user returns to it.
    if (_home) [_home refreshFromCore];
    if (_current == _door) [_door refreshFromCore];
    if (_current == _incoming) [_incoming refreshFromCore];
    if (_current == _pairing) [_pairing reload];
    if (_current == _addDevice) [_addDevice reload];
  }
}

// Core has already stored the session key before issuing this reference. The
// shell must persist only the reference and seeds, without handling key bytes.
- (void)onPaired:(NSDictionary *)ev {
  NSString *pskRef = [DBConfigUtil evStr:ev key:@"psk_ref"];
  id sids = [ev objectForKey:@"seeds"];
  NSArray *seeds = [sids isKindOfClass:[NSArray class]] ? sids : nil;
  BOOL validReference = [pskRef isEqualToString:@"secret:mesh.psk"];
  NSString *js = validReference
      ? [DBBootConfig persistPairingSecretRef:pskRef seeds:seeds] : nil;
  if ([js length] > 0) {
    _boot.rawJson = js;
    _boot.legacyPskHex = @"";
    [_core setRuntimeStatusSection:@"secure_store" value:@{
      @"schema_version" : @1,
      @"available" : @YES,
      @"implementation" : @"ios_keychain_generic_password",
      @"accessibility" : @"after_first_unlock",
      @"pairing_persistence" : @"psk_ref",
    }];
    NSLog(@"[doorbell] paired: secure PSK reference and seeds persisted");
    _pairingDeferred = NO;
    if (_home) [_home refreshFromCore];
    // The create-Cluster flow leaves a Pairing PIN on screen that the operator
    // has to read and type on the next device. Closing here is what made it
    // visible for zero frames on the iPad.
    if (_current == _pairing && [_pairing requiresUserDismissal]) {
      [_pairing reload];
      return;
    }
    [self closePairingAnimated:YES];
  } else {
    [_core setRuntimeStatusSection:@"secure_store" value:@{
      @"schema_version" : @1,
      @"available" : @(validReference),
      @"implementation" : @"ios_keychain_generic_password",
      @"accessibility" : @"after_first_unlock",
      @"pairing_persistence" : validReference ? @"boot_write_failed" : @"invalid_psk_ref",
    }];
    [[self pairing] handlePersistenceError];
    _pairingDeferred = NO;
    if (_current != _pairing) [self showPairing];
    NSLog(@"[doorbell] paired: secure PSK reference persistence failed");
  }
}

@end
