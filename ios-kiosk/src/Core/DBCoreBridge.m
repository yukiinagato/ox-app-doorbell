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

// C コールバックから使う内部メソッドの先行宣言 (定義はファイル後半)。
@interface DBCoreBridge ()
- (void)dispatchEvent:(NSDictionary *)ev;
- (void)speakOnMain:(NSString *)text;
- (NSString *)cachedDeviceInfoJson;
@end

// iOS SDK は net/route.h を含まないため、必要な BSD ルーティング定義を持ち込む
// (この ABI は Darwin で安定)。ルーティングテーブルから既定 GW を正確に得る。
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

// 既定ゲートウェイ IPv4 を sysctl(NET_RT_DUMP) のルーティングテーブルから取得。
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
          ((struct sockaddr_in *)dst)->sin_addr.s_addr == 0) {  // 既定経路 (0.0.0.0)
        char ip[INET_ADDRSTRLEN] = {0};
        if (inet_ntop(AF_INET, &((struct sockaddr_in *)g)->sin_addr, ip, sizeof(ip)))
          gw = [NSString stringWithUTF8String:ip];
      }
    }
    nextp += rtm->rtm_msglen;
  }
  free(buf);
  if (gw) return gw;

  // フォールバック: ルート表が取れない環境では 主 IPv4 の .1 を推定 GW とする
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

// SPI device_info (core の監視スレッドから呼ばれる)。UIKit を触らず、メインスレッドで
// 更新済みのキャッシュ JSON を返すだけ (UIDevice はメインスレッド専用のため)。
static int DBDeviceInfo(void *user, char **out_json) {
  if (out_json == NULL || user == NULL) return -1;
  @autoreleasepool {
    DBCoreBridge *me = (__bridge DBCoreBridge *)user;
    NSString *cached = [me cachedDeviceInfoJson];  // ロック済みコピー
    int rc = -1;
    if ([cached length] > 0) {
      const char *s = [cached UTF8String];
      size_t n = strlen(s);
      char *cbuf = (char *)malloc(n + 1);
      if (cbuf != NULL) {
        memcpy(cbuf, s, n + 1);
        *out_json = cbuf;  // core が db_free
        rc = 0;
      }
    }
    return rc;
  }
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
  // 端末ロック中 (再起動直後) でも core が読めるように
  [add setObject:(__bridge id)kSecAttrAccessibleAfterFirstUnlock
          forKey:(__bridge id)kSecAttrAccessible];
  OSStatus st = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
  if (st == errSecDuplicateItem) {
    NSDictionary *upd = @{(__bridge id)kSecValueData : data};
    return SecItemUpdate((__bridge CFDictionaryRef)base, (__bridge CFDictionaryRef)upd) ==
           errSecSuccess;
  }
  return st == errSecSuccess;
}
// ---- SPI: https_request (同期契約。core の専用スレッドから呼ばれるのでブロック可) ----
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
        char *buf = (char *)malloc(n + 1);  // core が db_free (= free)
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
      *value_out = strdup([v UTF8String]);  // core が db_free
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

// TTS 回落: iOS5 に AVSpeechSynthesizer は無い → 提示音を鳴らす。
static void DBTtsSpeak(void *user, const char *text, const char *lang) {
  if (user == NULL) return;
  @autoreleasepool {
    DBCoreBridge *me = (__bridge DBCoreBridge *)user;
    [me performSelectorOnMainThread:@selector(speakOnMain:)
                         withObject:(text ? [NSString stringWithUTF8String:text] : @"")
                      waitUntilDone:NO];
  }
}

// UI イベント: core 内部スレッド → main へ marshal。
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
  NSMutableDictionary *_handlers;  // key → 複製済みブロック
  NSString *_deviceInfoCache;      // device_info JSON (メインスレッドで更新)
  NSLock *_diLock;                 // _deviceInfoCache 保護
  NSTimer *_diTimer;               // メインで定期更新
}

- (id)init {
  self = [super init];
  if (self) {
    _handlers = [[NSMutableDictionary alloc] init];
    _diLock = [[NSLock alloc] init];
    _deviceInfoCache = @"";
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
  db_platform plat;
  memset(&plat, 0, sizeof(plat));
  plat.log_line = DBLogLine;
  plat.tts_speak = DBTtsSpeak;
  plat.https_request = DBHttpsRequest;
  plat.secure_get = DBSecureGet;
  plat.secure_put = DBSecurePut;
  plat.device_info = DBDeviceInfo;
  plat.user = (__bridge void *)self;

  _core = db_core_create(&plat, [dataDir UTF8String], [bootJson UTF8String]);
  if (_core == NULL) return NO;
  db_core_set_ui_callback(_core, DBUiEventCb, (__bridge void *)self);
  if (db_core_start(_core) != 0) {
    db_core_destroy(_core);
    _core = NULL;
    return NO;
  }
  // device_info キャッシュを main で定期更新 (core 監視スレッドが読む)
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
  db_core_set_ui_callback(_core, NULL, NULL);
  db_core_stop(_core);
  db_core_destroy(_core);
  _core = NULL;
}

- (void)addHandler:(NSString *)key handler:(DBUiEventHandler)handler {
  if (key == nil || handler == nil) return;
  [_handlers setObject:handler forKey:key];
}

- (void)removeHandler:(NSString *)key {
  [_handlers removeObjectForKey:key];
}

- (void)dispatchEvent:(NSDictionary *)ev {
  // ハンドラ内での add/remove (画面の出入り) と衝突しないようコピーして回す
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

- (void)press:(NSString *)door {
  if (_core) db_core_press(_core, [door UTF8String]);
}

- (void)pressPurpose:(NSString *)door purpose:(NSString *)purpose {
  if (_core) db_core_press_purpose(_core, [door UTF8String], [purpose UTF8String]);
}

- (void)setVisitorLang:(NSString *)door lang:(NSString *)lang {
  if (_core) db_core_set_visitor_lang(_core, [door UTF8String], [lang UTF8String]);
}

- (void)quickReply:(NSString *)replyId door:(NSString *)door {
  if (_core && [replyId length] > 0)
    db_core_quick_reply(_core, [replyId UTF8String], [door UTF8String]);
}

- (void)emergency:(BOOL)active {
  if (_core) db_core_emergency(_core, active ? 1 : 0);
}

- (NSDictionary *)takeJson:(char *)p {
  if (p == NULL) return nil;
  NSData *data = [NSData dataWithBytes:p length:strlen(p)];
  db_free(p);
  id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
  return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

- (NSDictionary *)status {
  if (_core == NULL) return nil;
  return [self takeJson:db_core_status_json(_core)];
}

- (NSDictionary *)debugInfo {
  if (_core == NULL) return nil;
  return [self takeJson:db_core_debug_json(_core)];
}

- (NSDictionary *)config {
  if (_core == NULL) return nil;
  return [self takeJson:db_core_config_json(_core)];
}

// --- 配対 (発見/招待) ---
- (NSDictionary *)pairingInfo {
  if (_core == NULL) return nil;
  return [self takeJson:db_core_pairing_json(_core)];
}

- (void)joinCluster:(NSString *)host pin:(NSString *)pin {
  if (_core && [host length] > 0 && [pin length] > 0)
    db_core_join_cluster(_core, [host UTF8String], [pin UTF8String]);
}

- (void)setPairingMode:(int)seconds {
  if (_core) db_core_pairing_mode(_core, seconds);
}

- (BOOL)foundCluster {
  return (_core && db_core_found_cluster(_core) != 0) ? YES : NO;
}

- (void)inviteDevice:(NSString *)nodeId {
  if (_core && [nodeId length] > 0) db_core_invite_device(_core, [nodeId UTF8String]);
}

// core の監視スレッドが読む (ロック済みコピー)。
- (NSString *)cachedDeviceInfoJson {
  [_diLock lock];
  NSString *s = _deviceInfoCache;
  [_diLock unlock];
  return s;
}

// gateway / wifi(SSID,BSSID) / battery を今この場で取得して dict で返す。
// メインスレッド専用 (UIDevice/CaptiveNetwork は main 限定)。
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

// メインスレッド専用。core 監視用に device_info をキャッシュ (NSTimer から)。
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


