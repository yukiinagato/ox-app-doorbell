#import "DBSettingsLogic.h"

static NSDictionary *DBLDict(id value) {
  return [value isKindOfClass:[NSDictionary class]] ? value : @{};
}

static NSArray *DBLArray(id value) {
  return [value isKindOfClass:[NSArray class]] ? value : @[];
}

static NSString *DBLString(id value) {
  return [value isKindOfClass:[NSString class]] ? value : @"";
}

static BOOL DBLMatches(NSString *text, NSString *pattern) {
  if (![text isKindOfClass:[NSString class]]) return NO;
  NSRegularExpression *expression =
      [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:NULL];
  NSRange whole = NSMakeRange(0, [text length]);
  NSRange found = [expression rangeOfFirstMatchInString:text options:0 range:whole];
  return found.location == 0 && found.length == whole.length;
}

static BOOL DBLIsBool(id value) {
  return [value isKindOfClass:[NSNumber class]] &&
      CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static BOOL DBLIsNumber(id value) {
  return [value isKindOfClass:[NSNumber class]] && !DBLIsBool(value);
}

static NSArray *DBLSortedByOrder(NSDictionary *map) {
  return [[map allKeys] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
    id left = [DBLDict([map objectForKey:a]) objectForKey:@"order"];
    id right = [DBLDict([map objectForKey:b]) objectForKey:@"order"];
    NSInteger x = DBLIsNumber(left) ? [left integerValue] : NSIntegerMax;
    NSInteger y = DBLIsNumber(right) ? [right integerValue] : NSIntegerMax;
    if (x != y) return x < y ? NSOrderedAscending : NSOrderedDescending;
    return [(NSString *)a compare:(NSString *)b];
  }];
}

static NSArray *DBLUiProperties(void) {
  return @[ @"scale", @"font_scale", @"foreground", @"background", @"accent", @"border",
            @"radius" ];
}

static NSArray *DBLDefaultStrategies(void) {
  return @[
    @{ @"id" : @"h264_low_latency", @"enabled" : @YES, @"startup_timeout_ms" : @5000,
       @"stall_timeout_ms" : @3000 },
    @{ @"id" : @"h264_hls", @"enabled" : @NO, @"startup_timeout_ms" : @5000,
       @"stall_timeout_ms" : @5000 },
    @{ @"id" : @"mjpeg", @"enabled" : @YES, @"startup_timeout_ms" : @5000,
       @"stall_timeout_ms" : @3000 },
  ];
}

@implementation DBSettingsLogic

#pragma mark - device identity

+ (BOOL)validDoorId:(NSString *)door {
  return DBLMatches(door, @"[A-Za-z0-9][A-Za-z0-9_-]{0,63}");
}

+ (BOOL)validDeviceName:(NSString *)name {
  if (![name isKindOfClass:[NSString class]]) return NO;
  NSString *trimmed = [name stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  return [trimmed length] >= 1 && [trimmed length] <= 64;
}

+ (NSString *)suggestedDoorIdForDevice:(NSString *)deviceId {
  NSMutableString *suffix = [NSMutableString string];
  NSCharacterSet *alnum = [NSCharacterSet characterSetWithCharactersInString:
      @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"];
  NSString *source = DBLString(deviceId);
  for (NSUInteger i = 0; i < [source length] && [suffix length] < 8; i++) {
    unichar c = [source characterAtIndex:i];
    if ([alnum characterIsMember:c]) [suffix appendFormat:@"%C", c];
  }
  return [@"door-" stringByAppendingString:[suffix length] > 0 ? suffix : @"1"];
}

+ (NSDictionary *)peerWithId:(NSString *)deviceId status:(NSDictionary *)status {
  for (id peer in DBLArray([DBLDict(status) objectForKey:@"peers"])) {
    if ([DBLString([DBLDict(peer) objectForKey:@"id"]) isEqualToString:deviceId]) return peer;
  }
  return nil;
}

+ (BOOL)deviceIsLive:(NSString *)deviceId status:(NSDictionary *)status {
  NSDictionary *peer = [self peerWithId:deviceId status:status];
  if (peer) return [DBLString([peer objectForKey:@"status"]) isEqualToString:@"alive"];
  // The local node answers for itself even when the peer list does not carry it.
  NSString *me = DBLString([DBLDict([DBLDict(status) objectForKey:@"node"]) objectForKey:@"id"]);
  return [me length] > 0 && [me isEqualToString:deviceId];
}

+ (NSArray *)unservedDoorsInConfig:(NSDictionary *)config status:(NSDictionary *)status
                         forDevice:(NSString *)deviceId {
  NSDictionary *doors = DBLDict([DBLDict(config) objectForKey:@"doors"]);
  NSDictionary *devices = DBLDict([DBLDict(config) objectForKey:@"devices"]);
  NSMutableSet *served = [NSMutableSet set];
  for (NSString *other in devices) {
    if ([other isEqualToString:deviceId]) continue;
    NSDictionary *entry = DBLDict([devices objectForKey:other]);
    if (![DBLString([entry objectForKey:@"role"]) isEqualToString:@"door_station"]) continue;
    NSString *door = DBLString([entry objectForKey:@"door"]);
    if ([door length] > 0 && [self deviceIsLive:other status:status]) [served addObject:door];
  }
  NSMutableArray *out = [NSMutableArray array];
  for (NSString *door in DBLSortedByOrder(doors)) {
    if (![self validDoorId:door] || [served containsObject:door]) continue;
    [out addObject:door];
  }
  NSString *current = DBLString([DBLDict([devices objectForKey:deviceId]) objectForKey:@"door"]);
  if ([self validDoorId:current] && ![out containsObject:current])
    [out insertObject:current atIndex:0];
  return out;
}

+ (NSString *)deviceBoundToDoor:(NSString *)door config:(NSDictionary *)config
                      excluding:(NSString *)deviceId {
  if ([door length] == 0) return nil;
  NSDictionary *devices = DBLDict([DBLDict(config) objectForKey:@"devices"]);
  for (NSString *other in [[devices allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
    if ([other isEqualToString:deviceId]) continue;
    NSDictionary *entry = DBLDict([devices objectForKey:other]);
    if ([DBLString([entry objectForKey:@"role"]) isEqualToString:@"door_station"] &&
        [DBLString([entry objectForKey:@"door"]) isEqualToString:door])
      return other;
  }
  return nil;
}

+ (NSArray *)roleChangeOpsForDevice:(NSString *)deviceId role:(NSString *)role
                               door:(NSString *)door {
  if (!DBLMatches(deviceId, @"[A-Za-z0-9_-]{1,64}")) return nil;
  BOOL doorStation = [role isEqualToString:@"door_station"];
  if (!doorStation && ![role isEqualToString:@"indoor_panel"]) return nil;
  if (doorStation && ![self validDoorId:door]) return nil;
  NSString *base = [@"devices." stringByAppendingString:deviceId];
  return @[
    @{ @"op" : @"set", @"key" : [base stringByAppendingString:@".role"], @"value" : role },
    @{ @"op" : @"set", @"key" : [base stringByAppendingString:@".door"],
       @"value" : doorStation ? door : @"" },
  ];
}

+ (BOOL)roleEditableForDevice:(NSDictionary *)entry peer:(NSDictionary *)peer {
  NSString *platform = DBLString([DBLDict(entry) objectForKey:@"platform"]);
  if ([platform length] == 0)
    platform = DBLString([DBLDict([DBLDict(peer) objectForKey:@"caps"]) objectForKey:@"platform"]);
  return ![[platform lowercaseString] isEqualToString:@"tvos"];
}

+ (NSDictionary *)peerHealth:(NSDictionary *)peer {
  NSMutableDictionary *out = [NSMutableDictionary dictionary];
  NSString *status = DBLString([DBLDict(peer) objectForKey:@"status"]);
  [out setObject:([status isEqualToString:@"alive"] ? @"online"
                     : ([status isEqualToString:@"suspect"] ? @"suspect" : @"offline"))
          forKey:@"state"];
  NSString *version = DBLString([DBLDict(peer) objectForKey:@"sw"]);
  if ([version length] == 0) version = DBLString([DBLDict(peer) objectForKey:@"version"]);
  if ([version length] > 0) [out setObject:version forKey:@"version"];
  NSDictionary *power = DBLDict([DBLDict(peer) objectForKey:@"power"]);
  id pct = [power objectForKey:@"battery_pct"];
  if (DBLIsNumber(pct) && [pct doubleValue] >= 0)
    [out setObject:[NSNumber numberWithInteger:MIN((NSInteger)100, (NSInteger)lround([pct doubleValue]))]
            forKey:@"battery"];
  [out setObject:[NSNumber numberWithBool:(DBLIsBool([power objectForKey:@"charging"]) &&
                                           [[power objectForKey:@"charging"] boolValue])]
          forKey:@"charging"];
  return out;
}

+ (NSString *)fingerprintText:(NSString *)hex {
  NSString *lower = [DBLString(hex) lowercaseString];
  if (!DBLMatches(lower, @"[0-9a-f]{64}")) return nil;
  NSString *upper = [lower uppercaseString];
  NSMutableArray *pairs = [NSMutableArray array];
  for (NSUInteger i = 0; i < 64; i += 2) [pairs addObject:[upper substringWithRange:NSMakeRange(i, 2)]];
  return [pairs componentsJoinedByString:@":"];
}

+ (NSString *)membershipState:(NSDictionary *)peer {
  NSDictionary *source = DBLDict(peer);
  NSString *state = DBLString([source objectForKey:@"membership"]);
  if ([state length] == 0) state = DBLString([source objectForKey:@"mesh_state"]);
  if ([state length] == 0) state = DBLString([source objectForKey:@"pairing_state"]);
  NSArray *known = @[ @"member", @"rekey_required", @"protocol_upgrade_required",
                      @"upgrade_rejoin_required" ];
  return [known containsObject:state] ? state : @"unknown";
}

#pragma mark - assets

+ (NSString *)assetHashOfSound:(id)value {
  NSString *text = DBLString(value);
  return [text hasPrefix:@"asset:"] ? [text substringFromIndex:6] : @"";
}

+ (NSDictionary *)assetReferencesInConfig:(NSDictionary *)config {
  NSDictionary *cfg = DBLDict(config);
  NSMutableDictionary *out = [NSMutableDictionary dictionary];
  void (^add)(id, NSString *) = ^(id hash, NSString *where) {
    if (![hash isKindOfClass:[NSString class]] || [(NSString *)hash length] == 0) return;
    NSMutableArray *list = [out objectForKey:hash];
    if (list == nil) {
      list = [NSMutableArray array];
      [out setObject:list forKey:hash];
    }
    [list addObject:where];
  };
  add([DBLDict([DBLDict([cfg objectForKey:@"display"]) objectForKey:@"theme"])
          objectForKey:@"bg_image"], @"display.theme");
  NSDictionary *devices = DBLDict([cfg objectForKey:@"devices"]);
  for (NSString *device in [[devices allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
    NSDictionary *theme = DBLDict([DBLDict([DBLDict([devices objectForKey:device])
        objectForKey:@"local"]) objectForKey:@"theme"]);
    add([theme objectForKey:@"bg_image"],
        [@"devices." stringByAppendingString:
            [device substringToIndex:MIN((NSUInteger)8, [device length])]]);
  }
  NSDictionary *replies = DBLDict([cfg objectForKey:@"quick_replies"]);
  for (NSString *reply in [[replies allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
    NSDictionary *audio = DBLDict([DBLDict([replies objectForKey:reply]) objectForKey:@"audio"]);
    for (NSString *lang in [[audio allKeys] sortedArrayUsingSelector:@selector(compare:)])
      add([audio objectForKey:lang],
          [NSString stringWithFormat:@"quick_replies.%@ (%@)", reply, lang]);
  }
  NSDictionary *ui = DBLDict([cfg objectForKey:@"ui"]);
  for (NSString *key in @[ @"ringtone", @"launch_sound", @"call_sound", @"button_sound",
                           @"update_sound" ])
    add([self assetHashOfSound:[ui objectForKey:key]], [@"ui." stringByAppendingString:key]);
  NSDictionary *rules = DBLDict([cfg objectForKey:@"trigger_rules"]);
  for (NSString *rule in [[rules allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
    for (id action in DBLArray([DBLDict([rules objectForKey:rule]) objectForKey:@"actions"])) {
      NSString *where = [@"trigger_rules." stringByAppendingString:rule];
      add([self assetHashOfSound:[DBLDict(action) objectForKey:@"sound"]], where);
      add([self assetHashOfSound:[DBLDict([DBLDict(action) objectForKey:@"presentation"])
              objectForKey:@"sound"]], where);
    }
  }
  add([self assetHashOfSound:[DBLDict([cfg objectForKey:@"emergency"]) objectForKey:@"alarm_sound"]],
      @"emergency.alarm_sound");
  return out;
}

#pragma mark - per-element UI overrides

+ (NSString *)uiManifestError:(NSDictionary *)manifest {
  if (![manifest isKindOfClass:[NSDictionary class]] || [manifest count] == 0) return @"unreported";
  id version = [manifest objectForKey:@"schema_version"];
  if (!DBLIsNumber(version) || [version integerValue] != 1) return @"schema_version";
  if (![@[ @"logical", @"dp", @"pt", @"effective_px" ]
          containsObject:DBLString([manifest objectForKey:@"units"])])
    return @"units";
  NSDictionary *viewport = [manifest objectForKey:@"viewport"];
  if (![viewport isKindOfClass:[NSDictionary class]]) return @"viewport";
  id touch = [viewport objectForKey:@"minimum_touch"];
  id low = [viewport objectForKey:@"scale_min"];
  id high = [viewport objectForKey:@"scale_max"];
  if (!DBLIsNumber(touch) || !DBLIsNumber(low) || !DBLIsNumber(high) ||
      !([touch doubleValue] >= 1) || !([low doubleValue] > 0) ||
      !([high doubleValue] >= [low doubleValue]))
    return @"viewport";
  NSDictionary *elements = [manifest objectForKey:@"elements"];
  if (![elements isKindOfClass:[NSDictionary class]]) return @"elements";
  for (NSString *element in elements) {
    if (!DBLMatches(element, @"[A-Za-z0-9_.-]+")) return @"element_id";
    NSDictionary *description = [elements objectForKey:element];
    if (![description isKindOfClass:[NSDictionary class]] ||
        ![[description objectForKey:@"properties"] isKindOfClass:[NSArray class]])
      return @"properties";
    for (id property in [description objectForKey:@"properties"])
      if (![DBLUiProperties() containsObject:property]) return @"properties";
    if (!DBLIsBool([description objectForKey:@"safety_critical"])) return @"safety_critical";
  }
  return nil;
}

+ (NSArray *)uiPropertiesInManifest:(NSDictionary *)manifest element:(NSString *)element {
  NSDictionary *description =
      DBLDict([DBLDict([DBLDict(manifest) objectForKey:@"elements"]) objectForKey:element]);
  NSArray *allowed = DBLArray([description objectForKey:@"properties"]);
  NSMutableArray *out = [NSMutableArray array];
  for (NSString *property in DBLUiProperties())
    if ([allowed containsObject:property]) [out addObject:property];
  return out;
}

+ (BOOL)uiPropertyIsColor:(NSString *)property {
  return [@[ @"foreground", @"background", @"accent", @"border" ] containsObject:property];
}

+ (NSDictionary *)uiRangeInManifest:(NSDictionary *)manifest element:(NSString *)element
                           property:(NSString *)property {
  NSDictionary *viewport = DBLDict([DBLDict(manifest) objectForKey:@"viewport"]);
  NSDictionary *description =
      DBLDict([DBLDict([DBLDict(manifest) objectForKey:@"elements"]) objectForKey:element]);
  if ([property isEqualToString:@"scale"] || [property isEqualToString:@"font_scale"]) {
    double low = [[viewport objectForKey:@"scale_min"] doubleValue];
    double high = [[viewport objectForKey:@"scale_max"] doubleValue];
    // A safety-critical control may grow but never shrink below its designed size.
    if ([[description objectForKey:@"safety_critical"] boolValue]) low = MAX(low, 1.0);
    return @{ @"min" : [NSNumber numberWithDouble:low], @"max" : [NSNumber numberWithDouble:high] };
  }
  if ([property isEqualToString:@"radius"])
    return @{ @"min" : @0, @"max" : [viewport objectForKey:@"minimum_touch"] ?: @0 };
  return nil;
}

+ (NSString *)uiValueErrorInManifest:(NSDictionary *)manifest element:(NSString *)element
                            property:(NSString *)property value:(id)value {
  NSDictionary *elements = DBLDict([DBLDict(manifest) objectForKey:@"elements"]);
  if (![[elements objectForKey:element] isKindOfClass:[NSDictionary class]]) return @"absent";
  if (![[self uiPropertiesInManifest:manifest element:element] containsObject:property])
    return @"not_allowed";
  if ([self uiPropertyIsColor:property])
    return DBLMatches(value, @"#[0-9A-Fa-f]{6}") ? nil : @"color";
  NSDictionary *range = [self uiRangeInManifest:manifest element:element property:property];
  if (!DBLIsNumber(value) || range == nil) return @"range";
  double number = [value doubleValue];
  if (!isfinite(number) || number < [[range objectForKey:@"min"] doubleValue] ||
      number > [[range objectForKey:@"max"] doubleValue])
    return @"range";
  return nil;
}

+ (NSDictionary *)uiElementValue:(NSDictionary *)elements element:(NSString *)element {
  if (![elements isKindOfClass:[NSDictionary class]] || [element length] == 0) return nil;
  id whole = [elements objectForKey:element];
  if ([whole isKindOfClass:[NSDictionary class]]) return whole;
  id cursor = elements;
  for (NSString *segment in [element componentsSeparatedByString:@"."]) {
    if (![cursor isKindOfClass:[NSDictionary class]]) return nil;
    cursor = [(NSDictionary *)cursor objectForKey:segment];
  }
  return [cursor isKindOfClass:[NSDictionary class]] ? cursor : nil;
}

#pragma mark - playback profiles

+ (NSArray *)normalizedPlaybackStrategies:(NSDictionary *)profile {
  NSMutableDictionary *defaults = [NSMutableDictionary dictionary];
  for (NSDictionary *strategy in DBLDefaultStrategies())
    [defaults setObject:strategy forKey:[strategy objectForKey:@"id"]];
  NSMutableArray *out = [NSMutableArray array];
  NSMutableSet *seen = [NSMutableSet set];
  for (id candidate in DBLArray([DBLDict(profile) objectForKey:@"strategies"])) {
    NSDictionary *strategy = DBLDict(candidate);
    NSString *identifier = DBLString([strategy objectForKey:@"id"]);
    NSDictionary *fallback = [defaults objectForKey:identifier];
    if (fallback == nil || [seen containsObject:identifier]) continue;
    [seen addObject:identifier];
    id enabled = [strategy objectForKey:@"enabled"];
    id startup = [strategy objectForKey:@"startup_timeout_ms"];
    id stall = [strategy objectForKey:@"stall_timeout_ms"];
    [out addObject:@{
      @"id" : identifier,
      @"enabled" : [NSNumber numberWithBool:!(DBLIsBool(enabled) && ![enabled boolValue])],
      @"startup_timeout_ms" : DBLIsNumber(startup) ? startup
                                                   : [fallback objectForKey:@"startup_timeout_ms"],
      @"stall_timeout_ms" : DBLIsNumber(stall) ? stall
                                               : [fallback objectForKey:@"stall_timeout_ms"],
    }];
  }
  BOOL empty = [out count] == 0;
  for (NSDictionary *fallback in DBLDefaultStrategies()) {
    if ([seen containsObject:[fallback objectForKey:@"id"]]) continue;
    // A profile that was never written shows the built-in defaults; a stored one that omits
    // a strategy has it disabled.
    NSMutableDictionary *added = [fallback mutableCopy];
    if (!empty) [added setObject:@NO forKey:@"enabled"];
    [out addObject:added];
  }
  return out;
}

+ (NSString *)playbackErrorForStrategies:(NSArray *)strategies {
  BOOL anyEnabled = NO;
  for (id candidate in DBLArray(strategies)) {
    NSDictionary *strategy = DBLDict(candidate);
    NSInteger startup = [[strategy objectForKey:@"startup_timeout_ms"] integerValue];
    NSInteger stall = [[strategy objectForKey:@"stall_timeout_ms"] integerValue];
    if (startup < 100 || startup > 60000 || stall < 1000 || stall > 60000)
      return @"timeout_range";
    if ([[strategy objectForKey:@"enabled"] boolValue]) anyEnabled = YES;
  }
  return anyEnabled ? nil : @"one_required";
}

+ (NSDictionary *)playbackProfile:(NSDictionary *)existing withStrategies:(NSArray *)edited {
  NSMutableDictionary *value = [DBLDict(existing) mutableCopy];
  NSArray *previous = DBLArray([value objectForKey:@"strategies"]);
  NSMutableArray *merged = [NSMutableArray array];
  NSMutableSet *known = [NSMutableSet set];
  for (id candidate in DBLArray(edited)) {
    NSDictionary *strategy = DBLDict(candidate);
    NSString *identifier = DBLString([strategy objectForKey:@"id"]);
    if ([identifier length] == 0 || [known containsObject:identifier]) continue;
    [known addObject:identifier];
    NSMutableDictionary *next = [NSMutableDictionary dictionary];
    for (id before in previous)
      if ([DBLString([DBLDict(before) objectForKey:@"id"]) isEqualToString:identifier]) {
        [next addEntriesFromDictionary:before];
        break;
      }
    for (NSString *key in @[ @"id", @"enabled", @"startup_timeout_ms", @"stall_timeout_ms" ])
      if ([strategy objectForKey:key]) [next setObject:[strategy objectForKey:key] forKey:key];
    [merged addObject:next];
  }
  NSMutableArray *ordered = [NSMutableArray array];
  NSUInteger nextKnown = 0;
  for (id before in previous) {
    if ([known containsObject:DBLString([DBLDict(before) objectForKey:@"id"])]) {
      if (nextKnown < [merged count]) [ordered addObject:[merged objectAtIndex:nextKnown++]];
    } else {
      [ordered addObject:before];
    }
  }
  while (nextKnown < [merged count]) [ordered addObject:[merged objectAtIndex:nextKnown++]];
  [value setObject:ordered forKey:@"strategies"];
  return value;
}

#pragma mark - raw configuration

+ (NSString *)compactJson:(id)value {
  if (value == nil) return @"null";
  NSData *data = [NSJSONSerialization dataWithJSONObject:@[ value ] options:0 error:NULL];
  if (data == nil) return @"";
  NSString *array = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  return [array length] >= 2 ? [array substringWithRange:NSMakeRange(1, [array length] - 2)] : @"";
}

+ (void)flatten:(id)value prefix:(NSString *)prefix into:(NSMutableArray *)out {
  if ([value isKindOfClass:[NSDictionary class]] && [(NSDictionary *)value count] > 0) {
    for (NSString *key in [[(NSDictionary *)value allKeys]
             sortedArrayUsingSelector:@selector(compare:)]) {
      NSString *path = [prefix length] > 0 ? [NSString stringWithFormat:@"%@.%@", prefix, key] : key;
      [self flatten:[(NSDictionary *)value objectForKey:key] prefix:path into:out];
    }
    return;
  }
  if ([prefix length] > 0) [out addObject:@[ prefix, [self compactJson:value] ]];
}

+ (NSArray *)flattenConfig:(NSDictionary *)config {
  NSMutableArray *out = [NSMutableArray array];
  [self flatten:DBLDict(config) prefix:@"" into:out];
  return out;
}

+ (BOOL)parseJsonValue:(NSString *)text into:(id *)value {
  NSString *trimmed = [DBLString(text) stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if ([trimmed length] == 0) return NO;
  NSData *data = [[NSString stringWithFormat:@"[%@]", trimmed] dataUsingEncoding:NSUTF8StringEncoding];
  id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
  if (![parsed isKindOfClass:[NSArray class]] || [(NSArray *)parsed count] != 1) return NO;
  if (value) *value = [(NSArray *)parsed objectAtIndex:0];
  return YES;
}

+ (BOOL)validConfigKey:(NSString *)key {
  if (![key isKindOfClass:[NSString class]] || [key length] == 0 || [key length] > 512) return NO;
  if ([key rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location !=
      NSNotFound)
    return NO;
  for (NSString *segment in [key componentsSeparatedByString:@"."])
    if ([segment length] == 0) return NO;
  return YES;
}

#pragma mark - speech

+ (BOOL)parseSpeakingRate:(NSString *)text into:(double *)rate {
  NSString *trimmed = [DBLString(text) stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (!DBLMatches(trimmed, @"[0-9]+(\\.[0-9]+)?")) return NO;
  double value = [trimmed doubleValue];
  if (!(value >= 0.25 && value <= 4.0)) return NO;
  if (rate) *rate = value;
  return YES;
}

@end
