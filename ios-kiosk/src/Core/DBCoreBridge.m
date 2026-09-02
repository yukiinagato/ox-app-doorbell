#import "DBCoreBridge.h"
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <Security/Security.h>
#import <SystemConfiguration/CaptiveNetwork.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <sys/socket.h>
#import <sys/sysctl.h>
#import "doorbell/doorbell.h"


@interface DBCoreBridge ()
- (void)dispatchEvent:(NSDictionary *)ev;
- (void)speakOnMain:(NSString *)text;
- (NSString *)cachedDeviceInfoJson;
@end



#ifndef RTF_GATEWAY
#define RTF_GATEWAY 0x2
#endif
#ifndef RTA_DST
#define RTA_DST 0x1
#define RTA_GATEWAY 0x2
#endif
#ifndef RTAX_DST
#define RTAX_DST 0
#define RTAX_GATEWAY 1
#define RTAX_MAX 8
#endif
struct db_rt_metrics {
  u_int32_t rmx_locks, rmx_mtu, rmx_hopcount;
  int32_t rmx_expire;
  u_int32_t rmx_recvpipe, rmx_sendpipe, rmx_ssthresh, rmx_rtt, rmx_rttvar, rmx_pksent, rmx_state;
  u_int32_t rmx_filler[3];
};
struct db_rt_msghdr {
  u_short rtm_msglen;
  u_char rtm_version, rtm_type;
  u_short rtm_index;
  int rtm_flags, rtm_addrs;
  pid_t rtm_pid;
  int rtm_seq, rtm_errno, rtm_use;
  u_int32_t rtm_inits;
  struct db_rt_metrics rtm_rmx;
};
#define DB_RT_ROUNDUP(a) ((a) > 0 ? (1 + (((a) - 1) | (sizeof(uint32_t) - 1))) : sizeof(uint32_t))


static NSString *DBDefaultGatewayIPv4(void) {
  int mib[6] = {CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP, 0};
  size_t len = 0;
  if (sysctl(mib, 6, NULL, &len, NULL, 0) < 0 || len == 0) return nil;
  char *buf = (char *)malloc(len);
  if (buf == NULL) return nil;
  if (sysctl(mib, 6, buf, &len, NULL, 0) < 0) { free(buf); return nil; }
  NSString *gw = nil;
  char *lim = buf + len;
  for (char *nextp = buf; nextp < lim && gw == nil;) {
    struct db_rt_msghdr *rtm = (struct db_rt_msghdr *)nextp;
    if (rtm->rtm_msglen == 0) break;
    if ((rtm->rtm_flags & RTF_GATEWAY) &&
        (rtm->rtm_addrs & RTA_DST) && (rtm->rtm_addrs & RTA_GATEWAY)) {
      char *cp = (char *)(rtm + 1);
      struct sockaddr *addrs[RTAX_MAX];
      memset(addrs, 0, sizeof(addrs));
      for (int i = 0; i < RTAX_MAX; i++) {
        if (rtm->rtm_addrs & (1 << i)) {
          struct sockaddr *sa = (struct sockaddr *)cp;
          addrs[i] = sa;
          cp += DB_RT_ROUNDUP(sa->sa_len);
        }
      }
      struct sockaddr *dst = addrs[RTAX_DST];
      struct sockaddr *g = addrs[RTAX_GATEWAY];
      if (dst && g && dst->sa_family == AF_INET && g->sa_family == AF_INET &&
          ((struct sockaddr_in *)dst)->sin_addr.s_addr == 0) {
        char ip[INET_ADDRSTRLEN] = {0};
        if (inet_ntop(AF_INET, &((struct sockaddr_in *)g)->sin_addr, ip, sizeof(ip)))
          gw = [NSString stringWithUTF8String:ip];
      }
    }
    nextp += rtm->rtm_msglen;
  }
  free(buf);
  if (gw) return gw;


  struct ifaddrs *head = NULL;
  if (getifaddrs(&head) == 0 && head != NULL) {
    for (struct ifaddrs *p = head; p != NULL; p = p->ifa_next) {
      if (p->ifa_addr == NULL || p->ifa_addr->sa_family != AF_INET) continue;
      if (p->ifa_flags & IFF_LOOPBACK) continue;
      if (!(p->ifa_flags & IFF_UP)) continue;
      if (strncmp(p->ifa_name, "en", 2) != 0) continue;
      uint32_t a = ntohl(((struct sockaddr_in *)p->ifa_addr)->sin_addr.s_addr);
      struct in_addr ga;
      ga.s_addr = htonl((a & 0xFFFFFF00u) | 1u);
      char ip[INET_ADDRSTRLEN] = {0};
      if (inet_ntop(AF_INET, &ga, ip, sizeof(ip))) gw = [NSString stringWithUTF8String:ip];
    }
    freeifaddrs(head);
  }
  return gw;
}



static int DBDeviceInfo(void *user, char **out_json) {
  if (out_json == NULL || user == NULL) return -1;
  @autoreleasepool {
    DBCoreBridge *me = (__bridge DBCoreBridge *)user;
    NSString *cached = [me cachedDeviceInfoJson];
    int rc = -1;
    if ([cached length] > 0) {
      const char *s = [cached UTF8String];
      size_t n = strlen(s);
      char *cbuf = (char *)malloc(n + 1);
      if (cbuf != NULL) {
        memcpy(cbuf, s, n + 1);
        *out_json = cbuf;
        rc = 0;
      }
    }
    return rc;
  }
}

// Every platform callback in this shell returns malloc-owned buffers. ABI v2
// makes that ownership explicit so future shells can use another allocator.
static void DBReleaseBuffer(void *user, void *buffer) {
  (void)user;
  free(buffer);
}

static NSString *const kKeychainService = @"jp.keihan.doorbell.secure";

// ---- Keychain (SPI secure_get/put) ----
static NSString *DBKeychainGet(NSString *key) {
  NSDictionary *query = @{
    (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
    (__bridge id)kSecAttrService : kKeychainService,
    (__bridge id)kSecAttrAccount : key,
    (__bridge id)kSecReturnData : (__bridge id)kCFBooleanTrue,
    (__bridge id)kSecMatchLimit : (__bridge id)kSecMatchLimitOne,
  };
  CFTypeRef out = NULL;
  OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)query, &out);
  if (st != errSecSuccess || out == NULL) return nil;
  NSData *data = CFBridgingRelease(out);
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static BOOL DBKeychainPut(NSString *key, NSString *value) {
  NSDictionary *base = @{
    (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
    (__bridge id)kSecAttrService : kKeychainService,
    (__bridge id)kSecAttrAccount : key,
  };
  NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
  if (data == nil) data = [NSData data];
  NSMutableDictionary *add = [base mutableCopy];
  [add setObject:data forKey:(__bridge id)kSecValueData];
  // Available while locked after the first unlock following a reboot.
  [add setObject:(__bridge id)kSecAttrAccessibleAfterFirstUnlock
          forKey:(__bridge id)kSecAttrAccessible];
  OSStatus st = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
  if (st == errSecDuplicateItem) {
    NSDictionary *upd = @{
      (__bridge id)kSecValueData : data,
      (__bridge id)kSecAttrAccessible : (__bridge id)kSecAttrAccessibleAfterFirstUnlock,
    };
    return SecItemUpdate((__bridge CFDictionaryRef)base, (__bridge CFDictionaryRef)upd) ==
           errSecSuccess;
  }
  return st == errSecSuccess;
}

static int DBHttpsRequest(void *user, const char *method, const char *url,
                          const char *headers_json, const uint8_t *body, size_t body_len,
                          char **resp_out, int *status_out) {
  (void)user;
  if (method == NULL || url == NULL) return -1;
  @autoreleasepool {
    int rc = -1;
    NSURL *u = [NSURL URLWithString:[NSString stringWithUTF8String:url]];
    if (u == nil) return -1;
    NSMutableURLRequest *req =
        [NSMutableURLRequest requestWithURL:u
                                cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                            timeoutInterval:40];
    req.HTTPMethod = [NSString stringWithUTF8String:method];
    if (headers_json != NULL) {
      NSData *hd =
          [[NSString stringWithUTF8String:headers_json] dataUsingEncoding:NSUTF8StringEncoding];
      id h = hd ? [NSJSONSerialization JSONObjectWithData:hd options:0 error:NULL] : nil;
      if ([h isKindOfClass:[NSDictionary class]]) {
        for (NSString *k in (NSDictionary *)h) {
          [req setValue:[NSString stringWithFormat:@"%@", [(NSDictionary *)h objectForKey:k]]
            forHTTPHeaderField:k];
        }
      }
    }
    if (body != NULL && body_len > 0) req.HTTPBody = [NSData dataWithBytes:body length:body_len];
    NSURLResponse *resp = nil;
    NSError *err = nil;
    NSData *respData = [NSURLConnection sendSynchronousRequest:req
                                             returningResponse:&resp
                                                         error:&err];
    if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
      if (status_out) *status_out = (int)[(NSHTTPURLResponse *)resp statusCode];
      if (resp_out) {
        NSUInteger n = [respData length];
        char *buf = (char *)malloc(n + 1);
        if (buf) {
          if (n > 0) memcpy(buf, [respData bytes], n);
          buf[n] = 0;
          *resp_out = buf;
          rc = 0;
        }
      } else {
        rc = 0;
      }
    }
    return rc;
  }
}

static int DBSecureGet(void *user, const char *key, char **value_out) {
  (void)user;
  if (key == NULL || value_out == NULL) return -1;
  @autoreleasepool {
    NSString *v = DBKeychainGet([NSString stringWithUTF8String:key]);
    if (v != nil) {
      *value_out = strdup([v UTF8String]);
      return 0;
    }
    return -1;
  }
}

static int DBSecurePut(void *user, const char *key, const char *value) {
  (void)user;
  if (key == NULL || value == NULL) return -1;
  @autoreleasepool {
    BOOL ok = DBKeychainPut([NSString stringWithUTF8String:key],
                            [NSString stringWithUTF8String:value]);
    return ok ? 0 : -1;
  }
}

static void DBLogLine(void *user, int level, const char *line) {
  (void)user;
  if (line == NULL) return;
  NSLog(@"[core:%d] %s", level, line);
}


static void DBTtsSpeak(void *user, const char *text, const char *lang) {
  (void)lang;
  if (user == NULL) return;
  @autoreleasepool {
    DBCoreBridge *me = (__bridge DBCoreBridge *)user;
    [me performSelectorOnMainThread:@selector(speakOnMain:)
                         withObject:(text ? [NSString stringWithUTF8String:text] : @"")
                      waitUntilDone:NO];
  }
}


static void DBUiEventCb(void *user, const char *event_json) {
  if (user == NULL || event_json == NULL) return;
  @autoreleasepool {
    DBCoreBridge *me = (__bridge DBCoreBridge *)user;
    NSData *data = [NSData dataWithBytes:event_json length:strlen(event_json)];
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if ([obj isKindOfClass:[NSDictionary class]]) {
      [me performSelectorOnMainThread:@selector(dispatchEvent:) withObject:obj waitUntilDone:NO];
    }
  }
}

@implementation DBCoreBridge {
  db_core *_core;
  NSMutableDictionary *_handlers;
  NSString *_deviceInfoCache;
  NSLock *_diLock;
  NSTimer *_diTimer;
  dispatch_queue_t _coreQueue;

  NSLock *_cfgLock;
  NSDictionary *_lastConfig;
  NSMutableDictionary *_runtimeStatus;
  NSMutableDictionary *_runtimeCapabilities;
  NSLock *_encodedFrameLock;
  NSUInteger _pendingEncodedFrames;
  NSUInteger _pendingEncodedBytes;
}

- (id)init {
  self = [super init];
  if (self) {
    _handlers = [[NSMutableDictionary alloc] init];
    _diLock = [[NSLock alloc] init];
    _deviceInfoCache = @"";
    _coreQueue = dispatch_queue_create("doorbell.core", DISPATCH_QUEUE_SERIAL);
    _cfgLock = [[NSLock alloc] init];
    _runtimeStatus = [[NSMutableDictionary alloc] init];
    _runtimeCapabilities = [[NSMutableDictionary alloc] init];
    _encodedFrameLock = [[NSLock alloc] init];
  }
  return self;
}

- (void)dealloc {
  [self stop];
}

- (BOOL)isRunning {
  return _core != NULL;
}
- (BOOL)startWithDataDir:(NSString *)dataDir bootJson:(NSString *)bootJson {
  if (_core != NULL) return YES;
  // startWithDataDir is invoked on the main thread, so prime the UIKit-backed
  // device-info cache before Core can issue its first worker-thread callback.
  [self refreshDeviceInfo];
  db_platform_v2 plat;
  memset(&plat, 0, sizeof(plat));
  plat.struct_size = sizeof(plat);
  plat.version = DB_PLATFORM_V2_VERSION;
  plat.log_line = DBLogLine;
  plat.tts_speak = DBTtsSpeak;
  plat.https_request = DBHttpsRequest;
  plat.secure_get = DBSecureGet;
  plat.secure_put = DBSecurePut;
  plat.device_info = DBDeviceInfo;
  plat.release_buffer = DBReleaseBuffer;
  plat.user = (__bridge void *)self;

  _core = db_core_create_v2(&plat, [dataDir UTF8String], [bootJson UTF8String]);
  if (_core == NULL) return NO;
  db_core_set_ui_callback(_core, DBUiEventCb, (__bridge void *)self);
  if (db_core_start(_core) != 0) {
    db_core_destroy(_core);
    _core = NULL;
    return NO;
  }
  // Refresh the callback cache periodically on the main run loop.
  _diTimer = [NSTimer scheduledTimerWithTimeInterval:10.0
                                              target:self
                                            selector:@selector(refreshDeviceInfo)
                                            userInfo:nil
                                             repeats:YES];
  return YES;
}

- (void)stop {
  if (_diTimer) {
    [_diTimer invalidate];
    _diTimer = nil;
  }
  if (_core == NULL) return;
  dispatch_sync(_coreQueue, ^{
    db_core *core = self->_core;
    self->_core = NULL;
    if (!core) return;
    db_core_set_ui_callback(core, NULL, NULL);
    db_core_stop(core);
    db_core_destroy(core);
  });
}

- (void)addHandler:(NSString *)key handler:(DBUiEventHandler)handler {
  if (key == nil || handler == nil) return;
  [_handlers setObject:handler forKey:key];
}

- (void)removeHandler:(NSString *)key {
  [_handlers removeObjectForKey:key];
}

- (void)dispatchEvent:(NSDictionary *)ev {

  NSArray *all = [_handlers allValues];
  for (DBUiEventHandler h in all) h(ev);
}

- (void)speakOnMain:(NSString *)text {
  (void)text;
  [self chimeFallback];
}

- (void)chimeFallback {
  AudioServicesPlaySystemSound((SystemSoundID)1013);
}

- (NSString *)pressV2:(NSString *)door purpose:(NSString *)purpose {
  if ([door length] == 0) return nil;
  NSString *d = [door copy];
  NSString *p = [purpose copy] ?: @"";
  __block NSString *callID = nil;
  dispatch_sync(_coreQueue, ^{
    if (!self->_core) return;
    char *raw = db_core_press_v2(self->_core, [d UTF8String], [p UTF8String]);
    if (raw != NULL) {
      callID = [NSString stringWithUTF8String:raw];
      db_free(raw);
    }
  });
  return callID;
}

- (BOOL)selectPurposeV2:(NSString *)door callID:(NSString *)callID purpose:(NSString *)purpose {
  if ([door length] == 0 || [callID length] == 0 || [purpose length] == 0) return NO;
  NSString *d = [door copy];
  NSString *cid = [callID copy];
  NSString *p = [purpose copy];
  __block BOOL accepted = NO;
  dispatch_sync(_coreQueue, ^{
    if (self->_core)
      accepted = db_core_select_purpose_v2(self->_core, [d UTF8String], [cid UTF8String],
                                            [p UTF8String]) == 0;
  });
  return accepted;
}

- (BOOL)cancelCallV2:(NSString *)door callID:(NSString *)callID reason:(NSString *)reason {
  if ([door length] == 0 || [callID length] == 0) return NO;
  NSString *d = [door copy];
  NSString *cid = [callID copy];
  NSString *why = [reason length] ? [reason copy] : @"visitor";
  __block BOOL accepted = NO;
  dispatch_sync(_coreQueue, ^{
    if (self->_core)
      accepted = db_core_cancel_call_v2(self->_core, [d UTF8String], [cid UTF8String],
                                         [why UTF8String]) == 0;
  });
  return accepted;
}

- (void)reportCallRecovery:(NSString *)callID restored:(BOOL)restored {
  if ([callID length] == 0) return;
  NSString *cid = [callID copy];
  dispatch_async(_coreQueue, ^{
    if (self->_core)
      db_core_report_call_recovery(self->_core, [cid UTF8String], restored ? 1 : 0);
  });
}

- (BOOL)reportCallAnsweredV2:(NSString *)door callID:(NSString *)callID
               stageRevision:(NSInteger)stageRevision {
  if ([door length] == 0 || [callID length] == 0 || stageRevision < 0) return NO;
  NSString *d = [door copy];
  NSString *cid = [callID copy];
  __block BOOL accepted = NO;
  dispatch_sync(_coreQueue, ^{
    if (self->_core)
      accepted = db_core_report_call_answered_v2(self->_core, [d UTF8String],
          [cid UTF8String], (int)stageRevision) == 0;
  });
  return accepted;
}

- (BOOL)reportCallEndedV2:(NSString *)door callID:(NSString *)callID
             stageRevision:(NSInteger)stageRevision reason:(NSString *)reason {
  if ([door length] == 0 || [callID length] == 0 || stageRevision < 0) return NO;
  NSString *d = [door copy];
  NSString *cid = [callID copy];
  NSString *why = [reason length] > 0 ? [reason copy] : @"sip_ended";
  __block BOOL accepted = NO;
  dispatch_sync(_coreQueue, ^{
    if (self->_core)
      accepted = db_core_report_call_ended_v2(self->_core, [d UTF8String],
          [cid UTF8String], (int)stageRevision, [why UTF8String]) == 0;
  });
  return accepted;
}

- (void)press:(NSString *)door {
  if (door == nil) return;
  NSString *d = [door copy];
  dispatch_async(_coreQueue, ^{
    if (self->_core) db_core_press(self->_core, [d UTF8String]);
  });
}

- (void)pressPurpose:(NSString *)door purpose:(NSString *)purpose {
  if (door == nil || purpose == nil) return;
  NSString *d = [door copy];
  NSString *pp = [purpose copy];
  dispatch_async(_coreQueue, ^{
    if (self->_core) db_core_press_purpose(self->_core, [d UTF8String], [pp UTF8String]);
  });
}

- (void)cancelCall:(NSString *)door {
  if (door == nil) return;
  NSString *d = [door copy];
  dispatch_async(_coreQueue, ^{
    if (self->_core) db_core_cancel_call(self->_core, [d UTF8String]);
  });
}

- (void)setVisitorLang:(NSString *)door lang:(NSString *)lang {
  if (door == nil || lang == nil) return;
  NSString *d = [door copy];
  NSString *l = [lang copy];
  dispatch_async(_coreQueue, ^{
    if (self->_core) db_core_set_visitor_lang(self->_core, [d UTF8String], [l UTF8String]);
  });
}

- (void)quickReply:(NSString *)replyId door:(NSString *)door {
  if (replyId == nil || [replyId length] == 0) return;
  NSString *rid = [replyId copy];
  NSString *d = [door copy];
  dispatch_async(_coreQueue, ^{
    if (self->_core) db_core_quick_reply(self->_core, [rid UTF8String], [d UTF8String]);
  });
}

- (BOOL)quickReplyV2:(NSString *)replyId door:(NSString *)door callID:(NSString *)callID
       stageRevision:(NSInteger)stageRevision {
  if ([replyId length] == 0 || [callID length] == 0 || stageRevision < 0) return NO;
  NSString *rid = [replyId copy];
  NSString *d = [door copy] ?: @"";
  NSString *cid = [callID copy];
  __block BOOL accepted = NO;
  dispatch_sync(_coreQueue, ^{
    if (self->_core)
      accepted = db_core_quick_reply_v2(self->_core, [rid UTF8String], [d UTF8String],
                                        [cid UTF8String], (int)stageRevision) == 0;
  });
  return accepted;
}

- (BOOL)emergency:(BOOL)active {
  __block BOOL committed = NO;
  dispatch_sync(_coreQueue, ^{
    if (self->_core)
      committed = db_core_emergency_v2(self->_core, active ? 1 : 0) != 0;
  });
  if (!committed) NSLog(@"[doorbell] SOS state was not durably committed");
  return committed;
}

- (void)coreSipCall:(NSString *)target mode:(NSString *)mode {
  if ([target length] == 0) return;
  NSString *destination = [target copy];
  NSString *callMode = [mode copy] ?: @"";
  dispatch_async(_coreQueue, ^{
    if (self->_core)
      db_core_sip_call(self->_core, [destination UTF8String], [callMode UTF8String]);
  });
}

- (void)coreSipHangup {
  dispatch_async(_coreQueue, ^{
    if (self->_core) db_core_sip_hangup(self->_core);
  });
}

- (BOOL)coreSipSendDtmf:(NSString *)digits {
  if ([digits length] == 0) return NO;
  NSString *value = [digits copy];
  __block BOOL accepted = NO;
  dispatch_sync(_coreQueue, ^{
    if (self->_core)
      accepted = db_core_sip_send_dtmf(self->_core, [value UTF8String]) != 0;
  });
  return accepted;
}

- (NSDictionary *)takeJson:(char *)p {
  if (p == NULL) return nil;
  size_t n = strlen(p);
  // Reject obviously corrupt or unbounded buffers before JSON parsing.
  if (n < 2 || p[0] != '{' || n > 8 * 1024 * 1024) {
    NSLog(@"[doorbell][core] rejected malformed JSON buffer (length=%zu)", n);
    db_free(p);
    return nil;
  }
  NSData *data = [NSData dataWithBytes:p length:n];
  db_free(p);
  id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
  return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}


- (NSDictionary *)status {
  __block NSDictionary *out = nil;
  dispatch_sync(_coreQueue, ^{
    if (self->_core) out = [self takeJson:db_core_status_json(self->_core)];
  });
  return out;
}

- (NSDictionary *)debugInfo {
  __block NSDictionary *out = nil;
  dispatch_sync(_coreQueue, ^{
    if (self->_core) out = [self takeJson:db_core_debug_json(self->_core)];
  });
  return out;
}

- (NSDictionary *)config {
  __block NSDictionary *out = nil;
  dispatch_sync(_coreQueue, ^{
    if (self->_core) out = [self takeJson:db_core_config_json(self->_core)];
  });
  if (out) {
    [_cfgLock lock];
    _lastConfig = out;
    [_cfgLock unlock];
  }
  return out;
}

- (void)setRuntimeStatusSection:(NSString *)section value:(NSDictionary *)value {
  if ([section length] == 0 || ![value isKindOfClass:[NSDictionary class]]) return;
  [self setRuntimeStatusValues:@{ section : value }];
}

- (void)setRuntimeStatusValues:(NSDictionary *)values {
  if (![values isKindOfClass:[NSDictionary class]] || [values count] == 0) return;
  NSDictionary *valuesCopy = [values copy];
  dispatch_async(_coreQueue, ^{
    if (!self->_core) return;
    [self->_runtimeStatus addEntriesFromDictionary:valuesCopy];
    NSData *data = [NSJSONSerialization dataWithJSONObject:self->_runtimeStatus
                                                   options:0 error:NULL];
    NSString *json = data ? [[NSString alloc] initWithData:data
                                                   encoding:NSUTF8StringEncoding] : nil;
    if ([json length] > 0)
      db_core_set_runtime_status_json(self->_core, [json UTF8String]);
  });
}

- (void)setRuntimeCapabilities:(NSDictionary *)capabilities {
  if (![capabilities isKindOfClass:[NSDictionary class]]) return;
  NSDictionary *copy = [capabilities copy];
  dispatch_async(_coreQueue, ^{
    if (!self->_core) return;
    self->_runtimeCapabilities = [copy mutableCopy];
    NSData *data = [NSJSONSerialization dataWithJSONObject:self->_runtimeCapabilities
                                                   options:0 error:NULL];
    NSString *json = data ? [[NSString alloc] initWithData:data
                                                   encoding:NSUTF8StringEncoding] : nil;
    if ([json length] > 0)
      db_core_set_capabilities_json(self->_core, [json UTF8String]);
  });
}

- (void)setRuntimeCapability:(NSString *)capability enabled:(BOOL)enabled {
  if ([capability length] == 0 || [capability length] > 128) return;
  NSString *name = [capability copy];
  dispatch_async(_coreQueue, ^{
    if (!self->_core) return;
    if (enabled)
      [self->_runtimeCapabilities setObject:@YES forKey:name];
    else
      [self->_runtimeCapabilities removeObjectForKey:name];
    NSData *data = [NSJSONSerialization dataWithJSONObject:self->_runtimeCapabilities
                                                   options:0 error:NULL];
    NSString *json = data ? [[NSString alloc] initWithData:data
                                                   encoding:NSUTF8StringEncoding] : nil;
    if ([json length] > 0)
      db_core_set_capabilities_json(self->_core, [json UTF8String]);
  });
}

- (void)setUIManifest:(NSDictionary *)manifest {
  if (![manifest isKindOfClass:[NSDictionary class]]) return;
  NSDictionary *copy = [manifest copy];
  dispatch_async(_coreQueue, ^{
    if (!self->_core) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:copy options:0 error:NULL];
    NSString *json = data ? [[NSString alloc] initWithData:data
                                                   encoding:NSUTF8StringEncoding] : nil;
    if ([json length] > 0)
      db_core_set_ui_manifest_json(self->_core, [json UTF8String]);
  });
}

- (BOOL)storeSecret:(NSString *)key value:(NSString *)value {
  if ([key length] == 0 || [value length] == 0) return NO;
  return DBKeychainPut(key, value);
}

- (NSString *)loadSecret:(NSString *)key {
  if ([key length] == 0) return nil;
  return DBKeychainGet(key);
}

- (void)submitEncodedFrame:(NSData *)annexB keyframe:(BOOL)keyframe
               timestampMs:(int64_t)timestampMs {
  [self trySubmitEncodedFrame:annexB keyframe:keyframe timestampMs:timestampMs];
}

- (BOOL)trySubmitEncodedFrame:(NSData *)annexB keyframe:(BOOL)keyframe
                   timestampMs:(int64_t)timestampMs {
  NSUInteger length = [annexB length];
  if (length == 0 || length > 4 * 1024 * 1024) return NO;
  [_encodedFrameLock lock];
  BOOL hasCapacity = _pendingEncodedFrames < 3 &&
      _pendingEncodedBytes + length <= 6 * 1024 * 1024;
  if (hasCapacity) {
    _pendingEncodedFrames++;
    _pendingEncodedBytes += length;
  }
  [_encodedFrameLock unlock];
  if (!hasCapacity) return NO;
  NSData *copy = [annexB copy];
  dispatch_async(_coreQueue, ^{
    if (self->_core)
      db_core_on_encoded_frame(self->_core, [copy bytes], [copy length], keyframe ? 1 : 0,
                               timestampMs);
    [self->_encodedFrameLock lock];
    if (self->_pendingEncodedFrames > 0) self->_pendingEncodedFrames--;
    if (self->_pendingEncodedBytes >= [copy length])
      self->_pendingEncodedBytes -= [copy length];
    else
      self->_pendingEncodedBytes = 0;
    [self->_encodedFrameLock unlock];
  });
  return YES;
}

- (BOOL)videoEncoderWanted {
  __block BOOL wanted = NO;
  dispatch_sync(_coreQueue, ^{
    if (self->_core) wanted = db_core_video_encoder_wanted(self->_core) != 0;
  });
  return wanted;
}


- (NSDictionary *)lastConfig {
  [_cfgLock lock];
  NSDictionary *c = _lastConfig;
  [_cfgLock unlock];
  return c;
}


- (NSDictionary *)pairingInfo {
  __block NSDictionary *out = nil;
  dispatch_sync(_coreQueue, ^{
    if (self->_core) out = [self takeJson:db_core_pairing_json(self->_core)];
  });
  return out;
}

- (void)joinCluster:(NSString *)host pin:(NSString *)pin {
  if (host == nil || pin == nil) return;
  NSString *h = [host copy];
  NSString *pp = [pin copy];
  dispatch_async(_coreQueue, ^{
    if (self->_core) db_core_join_cluster(self->_core, [h UTF8String], [pp UTF8String]);
  });
}

- (void)setPairingMode:(int)seconds {
  dispatch_async(_coreQueue, ^{
    if (self->_core) db_core_pairing_mode(self->_core, seconds);
  });
}

- (NSDictionary *)startPairingWithSeconds:(int)seconds {
  __block NSDictionary *out = nil;
  dispatch_sync(_coreQueue, ^{
    if (self->_core) out = [self takeJson:db_core_start_pairing_json(self->_core, seconds)];
  });
  return out;
}

- (void)removeDevice:(NSString *)nodeId {
  if ([nodeId length] == 0) return;
  NSString *target = [nodeId copy];
  dispatch_async(_coreQueue, ^{
    if (self->_core) db_core_remove_device(self->_core, [target UTF8String]);
  });
}

- (BOOL)foundCluster {
  __block BOOL ok = NO;
  dispatch_sync(_coreQueue, ^{
    ok = (self->_core && db_core_found_cluster(self->_core) != 0) ? YES : NO;
  });
  return ok;
}

- (void)inviteDevice:(NSString *)nodeId {
  if (nodeId == nil) return;
  NSString *idStr = [nodeId copy];
  dispatch_async(_coreQueue, ^{
    if (self->_core) db_core_invite_device(self->_core, [idStr UTF8String]);
  });
}

- (void)denyDevice:(NSString *)nodeId {
  if ([nodeId length] == 0) return;
  NSString *idStr = [nodeId copy];
  dispatch_async(_coreQueue, ^{
    if (self->_core) db_core_deny_device(self->_core, [idStr UTF8String]);
  });
}

- (BOOL)retryPairingPersistence {
  __block BOOL ok = NO;
  dispatch_sync(_coreQueue, ^{
    ok = (self->_core && db_core_retry_pairing_persistence(self->_core) != 0) ? YES : NO;
  });
  return ok;
}

- (void)unpair {
  dispatch_async(_coreQueue, ^{
    if (self->_core) db_core_unpair(self->_core);
  });
}


- (NSString *)cachedDeviceInfoJson {
  [_diLock lock];
  NSString *s = _deviceInfoCache;
  [_diLock unlock];
  return s;
}



- (NSDictionary *)deviceInfoNow {
  NSMutableDictionary *root = [NSMutableDictionary dictionary];
  NSString *gw = DBDefaultGatewayIPv4();
  if (gw) [root setObject:gw forKey:@"gateway"];
  NSArray *ifs = CFBridgingRelease(CNCopySupportedInterfaces());
  if (ifs) {
    for (NSString *ifn in ifs) {
      NSDictionary *info = CFBridgingRelease(CNCopyCurrentNetworkInfo((__bridge CFStringRef)ifn));
      if (info) {
        NSMutableDictionary *w = [NSMutableDictionary dictionary];
        id ssid = [info objectForKey:(id)kCNNetworkInfoKeySSID];
        id bssid = [info objectForKey:(id)kCNNetworkInfoKeyBSSID];
        if (ssid) [w setObject:ssid forKey:@"ssid"];
        if (bssid) [w setObject:bssid forKey:@"bssid"];
        if ([w count]) [root setObject:w forKey:@"wifi"];
      }
    }
  }
  UIDevice *dev = [UIDevice currentDevice];
  dev.batteryMonitoringEnabled = YES;
  float lvl = dev.batteryLevel;
  NSString *state = @"unknown";
  switch (dev.batteryState) {
    case UIDeviceBatteryStateCharging: state = @"charging"; break;
    case UIDeviceBatteryStateFull: state = @"full"; break;
    case UIDeviceBatteryStateUnplugged: state = @"unplugged"; break;
    default: break;
  }
  NSMutableDictionary *bat = [NSMutableDictionary dictionary];
  if (lvl >= 0) [bat setObject:[NSNumber numberWithFloat:lvl] forKey:@"level"];
  [bat setObject:state forKey:@"state"];
  [root setObject:bat forKey:@"battery"];
  return root;
}


- (void)refreshDeviceInfo {
  NSDictionary *root = [self deviceInfoNow];
  NSData *json = [NSJSONSerialization dataWithJSONObject:root options:0 error:NULL];
  NSString *s =
      json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : @"";
  [_diLock lock];
  _deviceInfoCache = s;
  [_diLock unlock];
}

@end
