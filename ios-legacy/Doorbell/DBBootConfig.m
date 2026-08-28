#import "DBBootConfig.h"

// iPad1 (A1219) は監視端 (indoor_panel)。既定 boot.json。
static NSString *const kDefaultJson =
    @"{ \"name\": \"ipad1-monitor\", \"role\": \"indoor_panel\", \"door\": \"\", "
    @"\"listen_port\": 47172, \"http_port\": 47180, \"ui_lang\": \"ja\", \"kiosk\": true, "
    @"\"door_host\": \"\", \"sip\": { \"direct_port\": 47190 }, \"mic\": false }";

@implementation DBBootConfig

- (id)init {
  self = [super init];
  if (self) {
    _rawJson = [@"{}" copy];
    _name = [@"doorbell" copy];
    _role = [@"indoor_panel" copy];
    _door = [@"" copy];
    _uiLang = [@"ja" copy];
    _kiosk = YES;
    _httpPort = 47180;
    _doorHost = [@"" copy];
    _directPort = 47190;
    _micEnabled = NO;
  }
  return self;
}

- (void)dealloc {
  [_rawJson release];
  [_name release];
  [_role release];
  [_door release];
  [_uiLang release];
  [_doorHost release];
  [super dealloc];
}

+ (NSString *)dataDir {
  NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
  NSString *dir = [dirs objectAtIndex:0];
  [[NSFileManager defaultManager] createDirectoryAtPath:dir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:NULL];
  return dir;
}

+ (DBBootConfig *)load {
  DBBootConfig *c = [[[DBBootConfig alloc] init] autorelease];
  NSString *path = [[self dataDir] stringByAppendingPathComponent:@"boot.json"];
  NSString *s = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
  if ([s length] > 0) {
    c.rawJson = s;
  } else {
    c.rawJson = kDefaultJson;
    [kDefaultJson writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
  }
  NSData *data = [c.rawJson dataUsingEncoding:NSUTF8StringEncoding];
  id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
  if ([obj isKindOfClass:[NSDictionary class]]) {
    NSDictionary *d = obj;
    id v;
    if ((v = [d objectForKey:@"name"]) && [v isKindOfClass:[NSString class]]) c.name = v;
    if ((v = [d objectForKey:@"role"]) && [v isKindOfClass:[NSString class]]) c.role = v;
    if ((v = [d objectForKey:@"door"]) && [v isKindOfClass:[NSString class]]) c.door = v;
    if ((v = [d objectForKey:@"ui_lang"]) && [v isKindOfClass:[NSString class]]) c.uiLang = v;
    if ((v = [d objectForKey:@"kiosk"]) && [v isKindOfClass:[NSNumber class]]) c.kiosk = [v boolValue];
    if ((v = [d objectForKey:@"http_port"]) && [v isKindOfClass:[NSNumber class]] &&
        [v integerValue] > 0)
      c.httpPort = [v integerValue];
    if ((v = [d objectForKey:@"door_host"]) && [v isKindOfClass:[NSString class]]) c.doorHost = v;
    if ((v = [d objectForKey:@"mic"]) && [v isKindOfClass:[NSNumber class]]) c.micEnabled = [v boolValue];
    id sip = [d objectForKey:@"sip"];
    if ([sip isKindOfClass:[NSDictionary class]]) {
      id dp = [(NSDictionary *)sip objectForKey:@"direct_port"];
      if ([dp isKindOfClass:[NSNumber class]] && [dp integerValue] > 0)
        c.directPort = [dp integerValue];
    }
  }
  return c;
}

@end
