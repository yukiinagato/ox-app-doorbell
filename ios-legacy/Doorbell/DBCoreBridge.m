#import "DBCoreBridge.h"
#import <AudioToolbox/AudioToolbox.h>
#import <Security/Security.h>
#import "doorbell/doorbell.h"

static NSString *const kKeychainService = @"jp.keihan.doorbell.secure";

@interface DBCoreBridge ()
- (void)dispatchEvent:(NSDictionary *)ev;
- (void)speakOnMain:(NSDictionary *)info;
@end

// ---- Keychain (SPI secure_get/put) ----
static NSString *DBKeychainGet(NSString *key) {
  NSDictionary *query = [NSDictionary dictionaryWithObjectsAndKeys:
      (id)kSecClassGenericPassword, (id)kSecClass,
      kKeychainService, (id)kSecAttrService,
      key, (id)kSecAttrAccount,
      (id)kCFBooleanTrue, (id)kSecReturnData,
      (id)kSecMatchLimitOne, (id)kSecMatchLimit,
      nil];
  CFTypeRef out = NULL;
  OSStatus st = SecItemCopyMatching((CFDictionaryRef)query, &out);
  if (st != errSecSuccess || out == NULL) return nil;
  NSData *data = [(NSData *)out autorelease];
  return [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
}

static BOOL DBKeychainPut(NSString *key, NSString *value) {
  NSDictionary *base = [NSDictionary dictionaryWithObjectsAndKeys:
      (id)kSecClassGenericPassword, (id)kSecClass,
      kKeychainService, (id)kSecAttrService,
      key, (id)kSecAttrAccount,
      nil];
  NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
  if (data == nil) data = [NSData data];
  NSMutableDictionary *add = [[base mutableCopy] autorelease];
  [add setObject:data forKey:(id)kSecValueData];
  // 端末ロック中 (再起動直後) でも core が読めるように
  [add setObject:(id)kSecAttrAccessibleAfterFirstUnlock forKey:(id)kSecAttrAccessible];
  OSStatus st = SecItemAdd((CFDictionaryRef)add, NULL);
  if (st == errSecDuplicateItem) {
    NSDictionary *upd = [NSDictionary dictionaryWithObject:data forKey:(id)kSecValueData];
    return SecItemUpdate((CFDictionaryRef)base, (CFDictionaryRef)upd) == errSecSuccess;
  }
  return st == errSecSuccess;
}

// ---- SPI: https_request (同期契約。core の専用スレッドから呼ばれるのでブロック可) ----
static int DBHttpsRequest(void *user, const char *method, const char *url,
                          const char *headers_json, const uint8_t *body, size_t body_len,
                          char **resp_out, int *status_out) {
  (void)user;
  if (method == NULL || url == NULL) return -1;
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  int rc = -1;
  NSURL *u = [NSURL URLWithString:[NSString stringWithUTF8String:url]];
  if (u == nil) {
    [pool release];
    return -1;
  }
  NSMutableURLRequest *req =
      [NSMutableURLRequest requestWithURL:u
                              cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                          timeoutInterval:40];
  [req setHTTPMethod:[NSString stringWithUTF8String:method]];
  if (headers_json != NULL) {
    NSData *hd = [[NSString stringWithUTF8String:headers_json] dataUsingEncoding:NSUTF8StringEncoding];
    id h = hd ? [NSJSONSerialization JSONObjectWithData:hd options:0 error:NULL] : nil;
    if ([h isKindOfClass:[NSDictionary class]]) {
      for (NSString *k in (NSDictionary *)h) {
        id v = [(NSDictionary *)h objectForKey:k];
        [req setValue:[NSString stringWithFormat:@"%@", v] forHTTPHeaderField:k];
      }
    }
  }
  if (body != NULL && body_len > 0) {
    [req setHTTPBody:[NSData dataWithBytes:body length:body_len]];
  }
  NSURLResponse *resp = nil;
  NSError *err = nil;
  NSData *respData = [NSURLConnection sendSynchronousRequest:req returningResponse:&resp error:&err];
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
  [pool release];
  return rc;
}

static int DBSecureGet(void *user, const char *key, char **value_out) {
  (void)user;
  if (key == NULL || value_out == NULL) return -1;
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  NSString *v = DBKeychainGet([NSString stringWithUTF8String:key]);
  int rc = -1;
  if (v != nil) {
    *value_out = strdup([v UTF8String]);  // core が db_free
    rc = 0;
  }
  [pool release];
  return rc;
}

static int DBSecurePut(void *user, const char *key, const char *value) {
  (void)user;
  if (key == NULL || value == NULL) return -1;
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  BOOL ok = DBKeychainPut([NSString stringWithUTF8String:key],
                          [NSString stringWithUTF8String:value]);
  [pool release];
  return ok ? 0 : -1;
}

static void DBLogLine(void *user, int level, const char *line) {
  (void)user;
  if (line == NULL) return;
  NSLog(@"[core:%d] %s", level, line);
}

// TTS 回落: iOS5 に AVSpeechSynthesizer は無い → 提示音 (システム音) を鳴らす。
static void DBTtsSpeak(void *user, const char *text, const char *lang) {
  if (user == NULL) return;
  DBCoreBridge *me = (DBCoreBridge *)user;
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  NSMutableDictionary *info = [NSMutableDictionary dictionary];
  if (text) [info setObject:[NSString stringWithUTF8String:text] forKey:@"text"];
  if (lang) [info setObject:[NSString stringWithUTF8String:lang] forKey:@"lang"];
  [me performSelectorOnMainThread:@selector(speakOnMain:) withObject:info waitUntilDone:NO];
  [pool release];
}

// UI イベント: core 内部スレッド → main へ marshal。
static void DBUiEventCb(void *user, const char *event_json) {
  if (user == NULL || event_json == NULL) return;
  DBCoreBridge *me = (DBCoreBridge *)user;
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  NSData *data = [NSData dataWithBytes:event_json length:strlen(event_json)];
  id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
  if ([obj isKindOfClass:[NSDictionary class]]) {
    [me performSelectorOnMainThread:@selector(dispatchEvent:) withObject:obj waitUntilDone:NO];
  }
  [pool release];
}

@implementation DBCoreBridge {
  db_core *_core;
  NSMutableDictionary *_handlers;  // key → 複製済みブロック
}

- (id)init {
  self = [super init];
  if (self) {
    _handlers = [[NSMutableDictionary alloc] init];
  }
  return self;
}

- (void)dealloc {
  [self stop];
  [_handlers release];
  [super dealloc];
}

- (BOOL)isRunning {
  return _core != NULL;
}

- (BOOL)startWithDataDir:(NSString *)dataDir bootJson:(NSString *)bootJson {
  if (_core != NULL) return YES;
  db_platform plat;
  memset(&plat, 0, sizeof(plat));
  plat.user = self;
  plat.log_line = DBLogLine;
  plat.tts_speak = DBTtsSpeak;
  plat.https_request = DBHttpsRequest;
  plat.secure_get = DBSecureGet;
  plat.secure_put = DBSecurePut;

  _core = db_core_create(&plat, [dataDir UTF8String], [bootJson UTF8String]);
  if (_core == NULL) return NO;
  db_core_set_ui_callback(_core, DBUiEventCb, self);
  if (db_core_start(_core) != 0) {
    db_core_destroy(_core);
    _core = NULL;
    return NO;
  }
  return YES;
}

- (void)stop {
  if (_core == NULL) return;
  db_core_set_ui_callback(_core, NULL, NULL);
  db_core_stop(_core);
  db_core_destroy(_core);
  _core = NULL;
}

- (void)addHandler:(NSString *)key handler:(DBUiEventHandler)handler {
  DBUiEventHandler copy = [handler copy];
  [_handlers setObject:copy forKey:key];
  [copy release];
}

- (void)removeHandler:(NSString *)key {
  [_handlers removeObjectForKey:key];
}

- (void)dispatchEvent:(NSDictionary *)ev {
  // ハンドラ内での add/remove (来鈴画面の出入り) と衝突しないようコピーして回す
  NSArray *all = [_handlers allValues];
  for (DBUiEventHandler h in all) {
    h(ev);
  }
}

- (void)speakOnMain:(NSDictionary *)info {
  (void)info;
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

- (NSDictionary *)config {
  if (_core == NULL) return nil;
  return [self takeJson:db_core_config_json(_core)];
}

@end
