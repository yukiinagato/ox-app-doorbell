#import "DBBootConfig.h"


static NSString *DBSuggestedDoor(void) {
  return [NSString stringWithFormat:@"door-%08x", arc4random()];
}

static NSString *DBDefaultJson(void) {
  return [NSString stringWithFormat:
      @"{ \"name\": \"ipad1-monitor\", \"role\": \"indoor_panel\", \"door\": \"%@\", "
      "\"listen_port\": 47172, \"http_port\": 47180, \"ui_lang\": \"ja\", \"kiosk\": true, "
      "\"door_host\": \"\", \"sip\": { \"direct_port\": 47190 }, \"mic\": false, "
      "\"media_source\": { \"type\": \"auto\" }, \"keepalive_helper\": \"auto\", "
      "\"setup_complete\": false }", DBSuggestedDoor()];
}

static BOOL DBValidDoor(NSString *value) {
  if (![value isKindOfClass:[NSString class]] || [value length] == 0 || [value length] > 64)
    return NO;
  unichar first = [value characterAtIndex:0];
  if (!((first >= 'a' && first <= 'z') || (first >= 'A' && first <= 'Z') ||
        (first >= '0' && first <= '9')))
    return NO;
  NSCharacterSet *invalid = [[NSCharacterSet
      characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"]
      invertedSet];
  return [value rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

static BOOL DBValidPskHex(NSString *value) {
  if ([value length] != 64) return NO;
  NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:
      @"0123456789abcdefABCDEF"] invertedSet];
  return [value rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

@implementation DBBootConfig

- (id)init {
  self = [super init];
  if (self) {
    _rawJson = @"{}";
    _name = @"doorbell";
    _role = @"indoor_panel";
    _door = @"";
    _uiLang = @"ja";
    _kiosk = YES;
    _httpPort = 47180;
    _doorHost = @"";
    _directPort = 47190;
    _sipBackend = @"auto";
    _micEnabled = NO;
    _seedPeers = @[];
    _legacyPskHex = @"";
    _videoSource = @"auto";
    _videoMjpegURL = @"";
    _videoMp4URL = @"";
    _videoSnapshotURL = @"";
    _keepaliveHelperPolicy = @"auto";
    _diagnosticDumps = NO;
    _setupRequired = YES;
    _suggestedDoor = DBSuggestedDoor();
  }
  return self;
}

+ (NSString *)dataDir {
  NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)
      objectAtIndex:0];
  [[NSFileManager defaultManager] createDirectoryAtPath:dir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:NULL];
  return dir;
}

+ (NSString *)pairingJsonFromJson:(NSString *)json
                        secretRef:(NSString *)secretRef
                            seeds:(NSArray *)seeds {
  if (![secretRef hasPrefix:@"secret:"] || [secretRef length] <= 7) return nil;
  NSString *source = [json length] > 0 ? json : DBDefaultJson();
  NSData *data = [source dataUsingEncoding:NSUTF8StringEncoding];
  id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
  if (![obj isKindOfClass:[NSDictionary class]]) return nil;
  NSMutableDictionary *d = [obj mutableCopy];
  [d removeObjectForKey:@"psk_hex"];
  [d setObject:secretRef forKey:@"psk_ref"];
  NSMutableArray *merged = [NSMutableArray array];
  id existing = [d objectForKey:@"seed_peers"];
  if ([existing isKindOfClass:[NSArray class]]) {
    for (id s in (NSArray *)existing)
      if ([s isKindOfClass:[NSString class]] && ![merged containsObject:s]) [merged addObject:s];
  }
  for (id s in (seeds ?: @[]))
    if ([s isKindOfClass:[NSString class]] && ![merged containsObject:s]) [merged addObject:s];
  [merged sortUsingSelector:@selector(compare:)];
  if ([merged count] > 0)
    [d setObject:merged forKey:@"seed_peers"];
  else
    [d removeObjectForKey:@"seed_peers"];
  NSData *out = [NSJSONSerialization dataWithJSONObject:d options:0 error:NULL];
  if (out == nil) return nil;
  return [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding];
}

+ (NSString *)persistPairingSecretRef:(NSString *)secretRef seeds:(NSArray *)seeds {
  NSString *path = [[self dataDir] stringByAppendingPathComponent:@"boot.json"];
  NSString *current = [NSString stringWithContentsOfFile:path
                                                 encoding:NSUTF8StringEncoding
                                                    error:NULL];
  NSString *json = [self pairingJsonFromJson:current secretRef:secretRef seeds:seeds];
  if ([json length] == 0) return nil;
  return [json writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]
      ? json : nil;
}

+ (NSString *)unpairedJsonFromJson:(NSString *)json {
  NSString *source = [json length] > 0 ? json : DBDefaultJson();
  NSData *data = [source dataUsingEncoding:NSUTF8StringEncoding];
  id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
  if (![obj isKindOfClass:[NSDictionary class]]) return nil;
  NSMutableDictionary *d = [obj mutableCopy];
  [d removeObjectForKey:@"psk_hex"];
  [d removeObjectForKey:@"psk_ref"];
  NSData *out = [NSJSONSerialization dataWithJSONObject:d options:0 error:NULL];
  if (out == nil) return nil;
  return [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding];
}

+ (NSString *)clearPairingSecretRef {
  NSString *path = [[self dataDir] stringByAppendingPathComponent:@"boot.json"];
  NSString *current = [NSString stringWithContentsOfFile:path
                                                 encoding:NSUTF8StringEncoding
                                                    error:NULL];
  NSString *json = [self unpairedJsonFromJson:current];
  if ([json length] == 0) return nil;
  return [json writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]
      ? json : nil;
}

+ (BOOL)isLocalWritableKey:(NSString *)key {
  return [key isEqualToString:@"ui_lang"] || [key isEqualToString:@"keepalive_helper"] ||
         [key isEqualToString:@"diagnostic_dumps"];
}

+ (BOOL)isValidLocalValue:(NSString *)value forKey:(NSString *)key {
  if (![value isKindOfClass:[NSString class]]) return NO;
  if ([key isEqualToString:@"ui_lang"])
    return [value isEqualToString:@"ja"] || [value isEqualToString:@"en"] ||
           [value isEqualToString:@"zh"];
  if ([key isEqualToString:@"keepalive_helper"])
    return [value isEqualToString:@"off"] || [value isEqualToString:@"auto"] ||
           [value isEqualToString:@"on"];
  if ([key isEqualToString:@"diagnostic_dumps"])
    return [value isEqualToString:@"true"] || [value isEqualToString:@"false"];
  return NO;
}

+ (NSString *)localJsonFromJson:(NSString *)json key:(NSString *)key value:(NSString *)value {
  if (![self isLocalWritableKey:key] || ![self isValidLocalValue:value forKey:key]) return nil;
  NSString *source = [json length] > 0 ? json : DBDefaultJson();
  NSData *data = [source dataUsingEncoding:NSUTF8StringEncoding];
  id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
  if (![obj isKindOfClass:[NSDictionary class]]) return nil;
  NSMutableDictionary *d = [obj mutableCopy];
  if ([key isEqualToString:@"diagnostic_dumps"])
    [d setObject:[NSNumber numberWithBool:[value isEqualToString:@"true"]] forKey:key];
  else
    [d setObject:value forKey:key];
  NSData *out = [NSJSONSerialization dataWithJSONObject:d options:0 error:NULL];
  if (out == nil) return nil;
  return [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding];
}

+ (NSString *)persistLocalValue:(NSString *)value forKey:(NSString *)key {
  NSString *path = [[self dataDir] stringByAppendingPathComponent:@"boot.json"];
  NSString *current = [NSString stringWithContentsOfFile:path
                                                 encoding:NSUTF8StringEncoding
                                                    error:NULL];
  NSString *json = [self localJsonFromJson:current key:key value:value];
  if ([json length] == 0) return nil;
  return [json writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]
      ? json : nil;
}

+ (NSString *)factoryResetJsonFromJson:(NSString *)json {
  NSString *source = [json length] > 0 ? json : DBDefaultJson();
  NSData *data = [source dataUsingEncoding:NSUTF8StringEncoding];
  id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
  if (![obj isKindOfClass:[NSDictionary class]]) return nil;
  NSMutableDictionary *d = [obj mutableCopy];
  // Cluster identity.
  [d removeObjectForKey:@"psk_hex"];
  [d removeObjectForKey:@"psk_ref"];
  [d removeObjectForKey:@"seed_peers"];
  // Local identity chosen during setup. Keeping it would silently re-announce
  // the old name and role to whatever cluster this device joins next.
  [d removeObjectForKey:@"name"];
  [d removeObjectForKey:@"role"];
  [d removeObjectForKey:@"door"];
  [d setObject:[NSNumber numberWithBool:NO] forKey:@"setup_complete"];
  NSData *out = [NSJSONSerialization dataWithJSONObject:d options:0 error:NULL];
  if (out == nil) return nil;
  return [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding];
}

+ (NSString *)clearPairingAndSetup {
  NSString *path = [[self dataDir] stringByAppendingPathComponent:@"boot.json"];
  NSString *current = [NSString stringWithContentsOfFile:path
                                                 encoding:NSUTF8StringEncoding
                                                    error:NULL];
  NSString *json = [self factoryResetJsonFromJson:current];
  if ([json length] == 0) return nil;
  return [json writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]
      ? json : nil;
}

+ (DBBootConfig *)loadConfiguration {
  DBBootConfig *c = [[DBBootConfig alloc] init];
  NSString *path = [[self dataDir] stringByAppendingPathComponent:@"boot.json"];
  NSString *s = [NSString stringWithContentsOfFile:path
                                          encoding:NSUTF8StringEncoding
                                             error:NULL];
  BOOL hadStoredProfile = [s length] > 0;
  if (hadStoredProfile) {
    c.rawJson = s;
  } else {
    c.rawJson = DBDefaultJson();
    [c.rawJson writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
  }
  NSData *data = [c.rawJson dataUsingEncoding:NSUTF8StringEncoding];
  id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
  if ([obj isKindOfClass:[NSDictionary class]]) {
    NSDictionary *d = obj;
    id v;
    BOOL hasMicSetting = NO;
    if ((v = [d objectForKey:@"name"]) && [v isKindOfClass:[NSString class]]) c.name = v;
    if ((v = [d objectForKey:@"role"]) && [v isKindOfClass:[NSString class]]) c.role = v;
    if ((v = [d objectForKey:@"door"]) && [v isKindOfClass:[NSString class]]) c.door = v;
    if ((v = [d objectForKey:@"setup_complete"]) && [v isKindOfClass:[NSNumber class]])
      c.setupRequired = ![v boolValue];
    else
      // A readable legacy profile is not proof that an operator confirmed its
      // local identity.  Show setup once after upgrade and persist the marker
      // only after the indoor/door choice is explicitly saved.
      c.setupRequired = YES;
    if ((v = [d objectForKey:@"ui_lang"]) && [v isKindOfClass:[NSString class]]) c.uiLang = v;
    if ((v = [d objectForKey:@"kiosk"]) && [v isKindOfClass:[NSNumber class]]) c.kiosk = [v boolValue];
    if ((v = [d objectForKey:@"http_port"]) && [v isKindOfClass:[NSNumber class]] &&
        [v integerValue] > 0)
      c.httpPort = [v integerValue];
    if ((v = [d objectForKey:@"door_host"]) && [v isKindOfClass:[NSString class]]) c.doorHost = v;
    if ((v = [d objectForKey:@"mic"]) && [v isKindOfClass:[NSNumber class]]) {
      c.micEnabled = [v boolValue];
      hasMicSetting = YES;
    }
    if ((v = [d objectForKey:@"seed_peers"]) && [v isKindOfClass:[NSArray class]]) {
      NSMutableArray *seeds = [NSMutableArray array];
      for (id seed in (NSArray *)v)
        if ([seed isKindOfClass:[NSString class]] && [(NSString *)seed length] > 0)
          [seeds addObject:seed];
      c.seedPeers = seeds;
    }
    if ((v = [d objectForKey:@"psk_hex"]) && [v isKindOfClass:[NSString class]] &&
        DBValidPskHex((NSString *)v))
      c.legacyPskHex = v;
    id sip = [d objectForKey:@"sip"];
    if ([sip isKindOfClass:[NSDictionary class]]) {
      id dp = [(NSDictionary *)sip objectForKey:@"direct_port"];
      if ([dp isKindOfClass:[NSNumber class]] && [dp integerValue] > 0)
        c.directPort = [dp integerValue];
      id backend = [(NSDictionary *)sip objectForKey:@"backend"];
      if ([backend isKindOfClass:[NSString class]] &&
          ([(NSString *)backend isEqualToString:@"auto"] ||
           [(NSString *)backend isEqualToString:@"minisip"] ||
           [(NSString *)backend isEqualToString:@"core"]))
        c.sipBackend = backend;
    }

    // `media_source` is a local compatibility profile, not a fleet secret.
    // Accept the nested `media.video` spelling as well so an iOS 9 profile can
    // share the same parser while the common schema settles independently.
    id media = [d objectForKey:@"media_source"];
    if (![media isKindOfClass:[NSDictionary class]]) {
      id rootMedia = [d objectForKey:@"media"];
      media = [rootMedia isKindOfClass:[NSDictionary class]]
          ? [(NSDictionary *)rootMedia objectForKey:@"video"] : nil;
    }
    if ([media isKindOfClass:[NSDictionary class]]) {
      NSDictionary *m = media;
      id type = [m objectForKey:@"type"];
      id mjpeg = [m objectForKey:@"mjpeg_url"];
      id mp4 = [m objectForKey:@"mp4_url"];
      if (![mp4 isKindOfClass:[NSString class]]) mp4 = [m objectForKey:@"h264_url"];
      id snapshot = [m objectForKey:@"snapshot_url"];
      if ([type isKindOfClass:[NSString class]]) c.videoSource = type;
      if ([mjpeg isKindOfClass:[NSString class]]) c.videoMjpegURL = mjpeg;
      if ([mp4 isKindOfClass:[NSString class]]) c.videoMp4URL = mp4;
      if ([snapshot isKindOfClass:[NSString class]]) c.videoSnapshotURL = snapshot;
    }

    id helper = [d objectForKey:@"keepalive_helper"];
    if ([helper isKindOfClass:[NSString class]] &&
        ([(NSString *)helper isEqualToString:@"off"] ||
         [(NSString *)helper isEqualToString:@"auto"] ||
         [(NSString *)helper isEqualToString:@"on"])) {
      c.keepaliveHelperPolicy = helper;
    } else if ([helper isKindOfClass:[NSNumber class]]) {
      c.keepaliveHelperPolicy = [helper boolValue] ? @"on" : @"off";
    }

    id debug = [d objectForKey:@"debug"];
    id dumps = [debug isKindOfClass:[NSDictionary class]]
        ? [(NSDictionary *)debug objectForKey:@"ui_dumps"] : nil;
    if ([dumps isKindOfClass:[NSNumber class]]) c.diagnosticDumps = [dumps boolValue];

    // The original iPad has a built-in microphone. Preserve the historical
    // indoor default, but make a door profile usable when `mic` is omitted.
    if (!hasMicSetting && [c.role isEqualToString:@"door_station"]) c.micEnabled = YES;
  }
  c.suggestedDoor = DBValidDoor(c.door) ? c.door : DBSuggestedDoor();
  if (![self isValidRole:c.role] ||
      ([c.role isEqualToString:@"door_station"] && !DBValidDoor(c.door)))
    c.setupRequired = YES;
  return c;
}

+ (BOOL)isValidRole:(NSString *)role {
  return [role isEqualToString:@"door_station"] || [role isEqualToString:@"indoor_panel"];
}

+ (BOOL)isValidDoor:(NSString *)door { return DBValidDoor(door); }

+ (BOOL)persistSetupName:(NSString *)name role:(NSString *)role door:(NSString *)door {
  if (![self isValidRole:role]) return NO;
  NSString *trimmedDoor = [door stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if ([role isEqualToString:@"door_station"] && !DBValidDoor(trimmedDoor)) return NO;
  NSString *path = [[self dataDir] stringByAppendingPathComponent:@"boot.json"];
  NSString *current = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
  NSData *data = [current dataUsingEncoding:NSUTF8StringEncoding];
  id parsed = data ? [NSJSONSerialization JSONObjectWithData:data
      options:NSJSONReadingMutableContainers error:NULL] : nil;
  NSMutableDictionary *json = [parsed isKindOfClass:[NSDictionary class]]
      ? [parsed mutableCopy] : [NSMutableDictionary dictionary];
  NSString *trimmedName = [name stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if ([trimmedName length] > 64) trimmedName = [trimmedName substringToIndex:64];
  [json setObject:[trimmedName length] ? trimmedName : @"doorbell" forKey:@"name"];
  [json setObject:role forKey:@"role"];
  [json setObject:[role isEqualToString:@"door_station"] ? trimmedDoor : @"" forKey:@"door"];
  [json setObject:@YES forKey:@"setup_complete"];
  NSData *out = [NSJSONSerialization dataWithJSONObject:json options:0 error:NULL];
  if (out == nil) return NO;
  NSString *backup = [path stringByAppendingString:@".bak"];
  if ([[NSFileManager defaultManager] fileExistsAtPath:path])
    [[NSFileManager defaultManager] copyItemAtPath:path toPath:backup error:NULL];
  return [out writeToFile:path options:NSDataWritingAtomic error:NULL];
}

@end
