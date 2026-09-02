#import "DBRecoveryClient.h"

#import <errno.h>
#import <poll.h>
#import <stdio.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <unistd.h>

static NSString *const DBRecoverySocketPath = @"/var/run/doorbell-keepalive.sock";
static const NSTimeInterval DBRecoveryHeartbeatInterval = 3.0;
static const NSUInteger DBRecoveryNativeKioskFailureThreshold = 3;
static const NSUInteger DBRecoveryNativeKioskLeaseSeconds = 15;
enum {
  DBRecoveryControlTimeoutMs = 250,
  DBRecoveryControlReplyLimit = 512,
};

static NSDictionary *DBRecoverySanitizeHelperStatus(NSDictionary *input) {
  if (![input isKindOfClass:[NSDictionary class]]) return nil;
  NSMutableDictionary *output = [NSMutableDictionary dictionary];
  NSDictionary *types = @{
    @"schema_version" : [NSNumber class], @"mode" : [NSString class],
    @"state" : [NSString class], @"armed" : [NSNumber class],
    @"safe_mode" : [NSNumber class], @"app_pid" : [NSNumber class],
    @"heartbeat_age_ms" : [NSNumber class], @"restart_count_5m" : [NSNumber class],
    @"next_restart_seconds" : [NSNumber class],
    @"maintenance_remaining_seconds" : [NSNumber class],
    @"peer_credentials" : [NSString class], @"last_reason" : [NSString class],
    // Rails added with the cold-boot work: the administrator's persisted mode
    // (which the root kill switch overrides without rewriting), the kill switch
    // and absolute launch-cap flags, and the two process-presence measurements.
    @"configured_mode" : [NSString class], @"disabled_by_file" : [NSNumber class],
    @"launch_inhibited" : [NSNumber class], @"ui_ready" : [NSNumber class],
    @"app_process_present" : [NSNumber class],
  };
  for (NSString *key in types) {
    id value = [input objectForKey:key];
    Class expected = [types objectForKey:key];
    if (![value isKindOfClass:expected]) continue;
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 120) continue;
    [output setObject:value forKey:key];
  }
  for (NSString *key in @[ @"mode", @"configured_mode" ]) {
    NSString *mode = [output objectForKey:key];
    if (mode && ![DBRecoveryClient isValidHelperMode:mode])
      [output removeObjectForKey:key];
  }
  return output;
}

static NSDictionary *DBRecoveryControlCommand(NSString *command) {
  NSData *commandData = [command dataUsingEncoding:NSASCIIStringEncoding];
  if ([commandData length] == 0 || [commandData length] > 32) return nil;
  int descriptor = socket(AF_UNIX, SOCK_DGRAM, 0);
  if (descriptor < 0) return nil;

  static unsigned long counter = 0;
  unsigned long sequence;
  @synchronized([DBRecoveryClient class]) { sequence = ++counter; }
  NSString *clientPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
      [NSString stringWithFormat:@"dbka-%d-%lu.sock", getpid(), sequence]];
  struct sockaddr_un clientAddress;
  memset(&clientAddress, 0, sizeof(clientAddress));
  clientAddress.sun_family = AF_UNIX;
#ifdef __APPLE__
  clientAddress.sun_len = sizeof(clientAddress);
#endif
  const char *clientBytes = [clientPath fileSystemRepresentation];
  if (strlen(clientBytes) >= sizeof(clientAddress.sun_path)) {
    close(descriptor);
    return nil;
  }
  snprintf(clientAddress.sun_path, sizeof(clientAddress.sun_path), "%s", clientBytes);
  unlink(clientBytes);
  if (bind(descriptor, (const struct sockaddr *)&clientAddress,
           sizeof(clientAddress)) != 0) {
    close(descriptor);
    return nil;
  }
  chmod(clientBytes, 0600);

  struct sockaddr_un helperAddress;
  memset(&helperAddress, 0, sizeof(helperAddress));
  helperAddress.sun_family = AF_UNIX;
#ifdef __APPLE__
  helperAddress.sun_len = sizeof(helperAddress);
#endif
  const char *helperBytes = [DBRecoverySocketPath fileSystemRepresentation];
  snprintf(helperAddress.sun_path, sizeof(helperAddress.sun_path), "%s", helperBytes);
  ssize_t sent = sendto(descriptor, [commandData bytes], [commandData length], 0,
                        (const struct sockaddr *)&helperAddress, sizeof(helperAddress));
  NSDictionary *reply = nil;
  if (sent == (ssize_t)[commandData length]) {
    struct pollfd waitDescriptor = {descriptor, POLLIN, 0};
    if (poll(&waitDescriptor, 1, DBRecoveryControlTimeoutMs) > 0 &&
        (waitDescriptor.revents & POLLIN)) {
      uint8_t bytes[DBRecoveryControlReplyLimit + 1];
      ssize_t length = recv(descriptor, bytes, sizeof(bytes), 0);
      if (length > 0 && length <= (ssize_t)DBRecoveryControlReplyLimit) {
        NSData *data = [NSData dataWithBytes:bytes length:(NSUInteger)length];
        id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if ([value isKindOfClass:[NSDictionary class]]) reply = value;
      }
    }
  }
  close(descriptor);
  unlink(clientBytes);
  return reply;
}

@interface DBRecoveryClient ()
- (void)sendHeartbeat:(NSString *)event;
- (void)reportStatus:(NSString *)event;
- (void)configureTimer;
- (void)applyModeToHelper;
- (void)refreshEffectiveHelperState;
@end

@implementation DBRecoveryClient {
  NSString *_requestedMode;
  NSString *_configuredMode;
  NSString *_configurationSource;
  NSString *_effectiveMode;
  NSString *_effectiveReason;
  NSString *_role;
  NSString *(^_stateProvider)(void);
  NSTimer *_timer;
  int _socket;
  unsigned long _sequence;
  unsigned long _memoryWarnings;
  unsigned long _modeGeneration;
  volatile BOOL _helperReachable;
  volatile BOOL _helperSupervising;
  BOOL _configurationValid;
  BOOL _nativeKioskAvailable;
  BOOL _nativeKioskHealthy;
  NSUInteger _nativeKioskFailureCount;
  BOOL _modeAcknowledged;
  BOOL _started;
  BOOL _loggedUnavailable;
  NSDictionary *_measuredHelperStatus;
  void (^_statusHandler)(NSDictionary *status);
}

@synthesize statusHandler = _statusHandler;

+ (BOOL)isValidHelperMode:(NSString *)mode {
  return [mode isEqualToString:@"off"] || [mode isEqualToString:@"auto"] ||
      [mode isEqualToString:@"on"];
}

+ (NSString *)effectiveModeForConfiguredMode:(NSString *)mode
                        nativeKioskAvailable:(BOOL)nativeKioskAvailable
                          nativeKioskHealthy:(BOOL)nativeKioskHealthy
           consecutiveNativeKioskFailures:(NSUInteger)failureCount {
  if (![self isValidHelperMode:mode]) return @"off";
  if ([mode isEqualToString:@"auto"] && nativeKioskAvailable) {
    if (nativeKioskHealthy || failureCount < DBRecoveryNativeKioskFailureThreshold)
      return @"off";
  }
  return mode;
}

+ (BOOL)shouldEnterSafeModeWithPreviousCleanExit:(NSNumber *)previousCleanExit
                                         launches:(NSArray *)launches
                                              now:(NSTimeInterval)now
                                  updatedLaunches:(NSArray **)updatedLaunches {
  NSMutableArray *recent = [NSMutableArray array];
  for (id value in launches ?: @[]) {
    if (![value isKindOfClass:[NSNumber class]]) continue;
    NSTimeInterval timestamp = [(NSNumber *)value doubleValue];
    if (timestamp <= now && now - timestamp <= 300) [recent addObject:value];
  }
  if (previousCleanExit != nil && ![previousCleanExit boolValue])
    [recent addObject:@(now)];
  if (updatedLaunches) *updatedLaunches = [recent copy];
  return [recent count] >= 3;
}

+ (NSUInteger)restartBackoffSecondsForAttempt:(NSUInteger)attempt {
  static const NSUInteger delays[] = {2, 5, 10, 30, 60};
  NSUInteger index = MIN(attempt, sizeof(delays) / sizeof(delays[0]) - 1);
  return delays[index];
}

- (id)initWithPolicy:(NSString *)policy
                 role:(NSString *)role
        stateProvider:(NSString * (^)(void))stateProvider {
  self = [super init];
  if (self) {
    _role = [role copy] ?: @"unknown";
    _stateProvider = [stateProvider copy];
    _socket = -1;
    [self updateConfiguredPolicy:policy ?: @"off"
                           source:@"legacy_boot_fallback"
            nativeKioskAvailable:NO
              nativeKioskHealthy:NO];
  }
  return self;
}

- (void)dealloc {
  [self stop];
}

- (BOOL)helperReachable {
  return _helperReachable;
}

- (BOOL)helperSupervising {
  return _helperSupervising;
}

- (NSString *)configuredMode {
  return [_configuredMode copy] ?: @"off";
}

- (NSString *)effectiveMode {
  return [_effectiveMode copy] ?: @"off";
}

- (void)updateConfiguredPolicy:(NSString *)policy
                         source:(NSString *)source
          nativeKioskAvailable:(BOOL)nativeKioskAvailable
            nativeKioskHealthy:(BOOL)nativeKioskHealthy {
  if (![NSThread isMainThread]) {
    NSString *policyCopy = [policy copy];
    NSString *sourceCopy = [source copy];
    dispatch_async(dispatch_get_main_queue(), ^{
      [self updateConfiguredPolicy:policyCopy source:sourceCopy
             nativeKioskAvailable:nativeKioskAvailable
               nativeKioskHealthy:nativeKioskHealthy];
    });
    return;
  }
  _requestedMode = [policy copy] ?: @"invalid";
  _configurationValid = [[self class] isValidHelperMode:_requestedMode];
  _configuredMode = _configurationValid ? _requestedMode : @"off";
  _configurationSource = [source copy] ?: @"unknown";
  _nativeKioskAvailable = nativeKioskAvailable;
  _nativeKioskHealthy = nativeKioskHealthy;
  if (![_configuredMode isEqualToString:@"auto"] || !nativeKioskAvailable ||
      nativeKioskHealthy) {
    _nativeKioskFailureCount = 0;
  } else if (_nativeKioskFailureCount < DBRecoveryNativeKioskFailureThreshold) {
    _nativeKioskFailureCount++;
  }
  _effectiveMode = [[[self class] effectiveModeForConfiguredMode:_configuredMode
                                           nativeKioskAvailable:nativeKioskAvailable
                                             nativeKioskHealthy:nativeKioskHealthy
                              consecutiveNativeKioskFailures:_nativeKioskFailureCount] copy];
  if (!_configurationValid)
    _effectiveReason = @"invalid_mode_rejected";
  else if ([_configuredMode isEqualToString:@"auto"] &&
           [_effectiveMode isEqualToString:@"off"])
    _effectiveReason = nativeKioskHealthy ? @"native_kiosk_healthy" :
        @"native_kiosk_recheck_pending";
  else if ([_configuredMode isEqualToString:@"auto"] && nativeKioskAvailable)
    _effectiveReason = @"native_kiosk_failed_3_consecutive";
  else if ([_configuredMode isEqualToString:@"auto"])
    _effectiveReason = @"native_kiosk_unavailable";
  else
    _effectiveReason = @"configured_mode";
  _modeAcknowledged = NO;
  _helperSupervising = NO;
  if (_started) {
    [self configureTimer];
    [self applyModeToHelper];
    [self reportStatus:@"configuration_changed"];
  }
}

- (void)start {
  if (_started) return;
  _started = YES;
  [self configureTimer];
  [self applyModeToHelper];
  if (![_configuredMode isEqualToString:@"off"]) [self sendHeartbeat:@"started"];
  [self reportStatus:@"started"];
}

- (void)configureTimer {
  if ([_configuredMode isEqualToString:@"off"]) {
    [_timer invalidate];
    _timer = nil;
    return;
  }
  if (_timer == nil) {
    _timer = [NSTimer scheduledTimerWithTimeInterval:DBRecoveryHeartbeatInterval
                                              target:self
                                            selector:@selector(onTimer:)
                                            userInfo:nil
                                             repeats:YES];
  }
}

- (void)stop {
  if (!_started) return;
  if (![_configuredMode isEqualToString:@"off"]) [self sendHeartbeat:@"stopping"];
  [_timer invalidate];
  _timer = nil;
  if (_socket >= 0) close(_socket);
  _socket = -1;
  _helperReachable = NO;
  _helperSupervising = NO;
  _started = NO;
}

- (void)noteMemoryPressure {
  _memoryWarnings++;
  if (![_configuredMode isEqualToString:@"off"])
    [self sendHeartbeat:@"memory_pressure"];
  else
    [self reportStatus:@"memory_pressure"];
}

- (void)onTimer:(NSTimer *)timer {
  (void)timer;
  [self sendHeartbeat:@"heartbeat"];
  [self refreshEffectiveHelperState];
}

- (void)applyModeToHelper {
  // MODE persists the administrator's configured policy. Native kiosk health only controls a
  // renewable maintenance lease, so a healthy measurement can never turn auto into off at boot.
  NSString *mode = [_configuredMode copy];
  if (![[self class] isValidHelperMode:mode]) mode = @"off";
  NSString *effectiveMode = [_effectiveMode copy];
  unsigned long generation = ++_modeGeneration;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSDictionary *modeReply = DBRecoveryControlCommand(
        [NSString stringWithFormat:@"MODE %@", mode]);
    BOOL acknowledged = [[modeReply objectForKey:@"ok"] boolValue];
    NSDictionary *effectiveReply = nil;
    if (acknowledged && [mode isEqualToString:@"auto"]) {
      NSString *command = [effectiveMode isEqualToString:@"off"]
          ? [NSString stringWithFormat:@"MAINTENANCE_BEGIN %lu",
              (unsigned long)DBRecoveryNativeKioskLeaseSeconds]
          : @"MAINTENANCE_END";
      effectiveReply = DBRecoveryControlCommand(command);
      acknowledged = [[effectiveReply objectForKey:@"ok"] boolValue];
    }
    NSDictionary *status = acknowledged ? DBRecoveryControlCommand(@"STATUS") : nil;
    NSDictionary *measured = DBRecoverySanitizeHelperStatus(status);
    BOOL matches = [[measured objectForKey:@"mode"] isEqualToString:mode];
    dispatch_async(dispatch_get_main_queue(), ^{
      if (generation != self->_modeGeneration) return;
      self->_helperReachable = modeReply != nil;
      self->_modeAcknowledged = acknowledged && matches;
      self->_measuredHelperStatus = measured;
      self->_helperSupervising = self->_modeAcknowledged &&
          ![effectiveMode isEqualToString:@"off"];
      [self reportStatus:acknowledged ? @"mode_acknowledged" : @"mode_unavailable"];
    });
  });
}

- (void)refreshEffectiveHelperState {
  if (!_modeAcknowledged || ![_configuredMode isEqualToString:@"auto"] ||
      ![_effectiveMode isEqualToString:@"off"]) return;
  unsigned long generation = _modeGeneration;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSDictionary *reply = DBRecoveryControlCommand(
        [NSString stringWithFormat:@"MAINTENANCE_BEGIN %lu",
            (unsigned long)DBRecoveryNativeKioskLeaseSeconds]);
    NSDictionary *status = [[reply objectForKey:@"ok"] boolValue]
        ? DBRecoveryControlCommand(@"STATUS") : nil;
    NSDictionary *measured = DBRecoverySanitizeHelperStatus(status);
    dispatch_async(dispatch_get_main_queue(), ^{
      if (generation != self->_modeGeneration) return;
      self->_helperReachable = reply != nil;
      if (measured) self->_measuredHelperStatus = measured;
      self->_helperSupervising = NO;
      [self reportStatus:[[reply objectForKey:@"ok"] boolValue]
          ? @"native_kiosk_lease_renewed" : @"native_kiosk_lease_failed"];
    });
  });
}

- (void)sendHeartbeat:(NSString *)event {
  if ([_configuredMode isEqualToString:@"off"]) return;
  if (_socket < 0) _socket = socket(AF_UNIX, SOCK_DGRAM, 0);
  if (_socket < 0) {
    BOOL changed = _helperReachable;
    _helperReachable = NO;
    _helperSupervising = NO;
    if (changed || ![event isEqualToString:@"heartbeat"]) [self reportStatus:event];
    return;
  }

  NSBundle *bundle = [NSBundle mainBundle];
  NSString *bundleID = [bundle bundleIdentifier] ?: @"jp.ox.doorbell";
  NSString *version = [[bundle infoDictionary] objectForKey:@"CFBundleVersion"] ?: @"unknown";
  NSString *state = _stateProvider ? _stateProvider() : @"unknown";
  if (![state isKindOfClass:[NSString class]] || [state length] == 0) state = @"unknown";
  NSDictionary *message = @{
    @"protocol" : @1,
    @"event" : event ?: @"heartbeat",
    @"pid" : [NSNumber numberWithInt:getpid()],
    @"bundle_id" : bundleID,
    @"app_version" : version,
    @"role" : _role,
    @"policy" : _configuredMode,
    @"state" : state,
    @"sequence" : [NSNumber numberWithUnsignedLong:++_sequence],
    @"memory_warnings" : [NSNumber numberWithUnsignedLong:_memoryWarnings],
    @"unix_time" : [NSNumber numberWithDouble:[[NSDate date] timeIntervalSince1970]],
  };
  NSData *payload = [NSJSONSerialization dataWithJSONObject:message options:0 error:NULL];
  if ([payload length] == 0 || [payload length] > 2048) return;

  struct sockaddr_un address;
  memset(&address, 0, sizeof(address));
  address.sun_family = AF_UNIX;
#ifdef __APPLE__
  address.sun_len = sizeof(address);
#endif
  const char *path = [DBRecoverySocketPath fileSystemRepresentation];
  if (strlen(path) >= sizeof(address.sun_path)) {
    _helperReachable = NO;
    _helperSupervising = NO;
    return;
  }
  snprintf(address.sun_path, sizeof(address.sun_path), "%s", path);
  ssize_t sent = sendto(_socket, [payload bytes], [payload length], 0,
                        (const struct sockaddr *)&address, sizeof(address));
  BOOL reachable = sent == (ssize_t)[payload length];
  BOOL changed = reachable != _helperReachable;
  _helperReachable = reachable;
  _helperSupervising = reachable && _modeAcknowledged &&
      ![_effectiveMode isEqualToString:@"off"];
  if (!reachable && !_loggedUnavailable) {
    NSLog(@"[doorbell][recovery] optional helper unavailable at %@ (%d)",
          DBRecoverySocketPath, errno);
    _loggedUnavailable = YES;
  } else if (reachable) {
    _loggedUnavailable = NO;
  }
  if (changed || ![event isEqualToString:@"heartbeat"]) [self reportStatus:event];
}

- (void)reportStatus:(NSString *)event {
  if (!_statusHandler) return;
  NSString *state = @"local_watchdog";
  if ([_effectiveMode isEqualToString:@"off"])
    state = _nativeKioskHealthy ? @"native_kiosk" : @"native_kiosk_recheck";
  else if (_helperSupervising)
    state = @"supervised";
  else if ([_effectiveMode isEqualToString:@"on"])
    state = @"required_helper_unavailable";
  NSDictionary *status = @{
    @"schema_version" : @2,
    @"configured" : @{
      @"requested_mode" : _requestedMode ?: @"invalid",
      @"mode" : _configuredMode ?: @"off",
      @"source" : _configurationSource ?: @"unknown",
      @"valid" : @(_configurationValid),
    },
    @"effective" : @{
      @"mode" : _effectiveMode ?: @"off",
      @"reason" : _effectiveReason ?: @"unknown",
    },
    @"measured" : @{
      @"native_kiosk_available" : @(_nativeKioskAvailable),
      @"native_kiosk_healthy" : @(_nativeKioskHealthy),
      @"native_kiosk_failure_count" : @(_nativeKioskFailureCount),
      @"native_kiosk_failure_threshold" : @(DBRecoveryNativeKioskFailureThreshold),
      @"helper_reachable" : @(_helperReachable),
      @"helper_supervising" : @(_helperSupervising),
      @"mode_acknowledged" : @(_modeAcknowledged),
      @"helper_status" : _measuredHelperStatus ?: @{},
    },
    @"state" : state,
    @"last_event" : event ?: @"unknown",
    @"memory_warnings" : @(_memoryWarnings),
  };
  void (^handler)(NSDictionary *) = _statusHandler;
  if ([NSThread isMainThread])
    handler(status);
  else
    dispatch_async(dispatch_get_main_queue(), ^{ handler(status); });
}

@end
