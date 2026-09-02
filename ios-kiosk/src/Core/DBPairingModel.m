#import "DBPairingModel.h"

NSString *const DBPairingStateUnknown = @"unknown";

// Every error code the core contract can deliver. An unlisted code falls back
// to pair.err.unknown so a raw machine code is never the primary message.
static NSArray *DBPairingKnownErrorCodes(void) {
  static NSArray *codes = nil;
  if (codes == nil) {
    codes = @[
      @"bad_pin", @"expired", @"no_token", @"host_unpaired", @"connect_failed",
      @"timeout", @"closed", @"join_in_progress", @"already_paired",
      @"decrypt_failed", @"bad_payload", @"bad_challenge",
      @"local_persist_failed", @"persist_failed", @"host_zero_psk", @"no_ack",
    ];
  }
  return codes;
}

@implementation DBPairingModel

+ (NSString *)stateFromPairingInfo:(NSDictionary *)info {
  if (![info isKindOfClass:[NSDictionary class]] || [info count] == 0)
    return DBPairingStateUnknown;
  id raw = [info objectForKey:@"state"];
  if ([raw isKindOfClass:[NSString class]] && [(NSString *)raw length] > 0) {
    NSString *state = (NSString *)raw;
    if ([state isEqualToString:@"unpaired"] || [state isEqualToString:@"joining"] ||
        [state isEqualToString:@"persist_error"] || [state isEqualToString:@"ready"] ||
        [state isEqualToString:@"revoked"])
      return state;
    return DBPairingStateUnknown;
  }
  // Older cores publish only the booleans.
  id paired = [info objectForKey:@"paired"];
  if (![paired isKindOfClass:[NSNumber class]]) return DBPairingStateUnknown;
  if (![(NSNumber *)paired boolValue]) return @"unpaired";
  id persisted = [info objectForKey:@"persistence_ready"];
  if ([persisted isKindOfClass:[NSNumber class]] && ![(NSNumber *)persisted boolValue])
    return @"persist_error";
  return @"ready";
}

+ (NSString *)errorTextKeyForCode:(NSString *)code {
  if (![code isKindOfClass:[NSString class]] || [code length] == 0 ||
      ![DBPairingKnownErrorCodes() containsObject:code])
    return @"pair.err.unknown";
  return [@"pair.err." stringByAppendingString:code];
}

+ (NSArray *)pendingDevicesFromPairingInfo:(NSDictionary *)info {
  if (![info isKindOfClass:[NSDictionary class]]) return @[];
  id pending = [info objectForKey:@"pending"];
  if (![pending isKindOfClass:[NSDictionary class]]) return @[];
  id devices = [(NSDictionary *)pending objectForKey:@"devices"];
  if (![devices isKindOfClass:[NSArray class]]) return @[];
  NSMutableArray *out = [NSMutableArray array];
  for (id device in (NSArray *)devices) {
    if (![device isKindOfClass:[NSDictionary class]]) continue;
    id identifier = [(NSDictionary *)device objectForKey:@"id"];
    if (![identifier isKindOfClass:[NSString class]] ||
        [(NSString *)identifier length] == 0) continue;
    [out addObject:device];
  }
  return out;
}

+ (NSString *)stringValue:(NSDictionary *)device key:(NSString *)key {
  id value = [device objectForKey:key];
  return ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0)
      ? (NSString *)value : nil;
}

+ (NSString *)displayNameForDevice:(NSDictionary *)device {
  if (![device isKindOfClass:[NSDictionary class]]) return @"";
  NSString *name = [self stringValue:device key:@"name"];
  if (name) return name;
  NSString *identifier = [self stringValue:device key:@"id"] ?: @"";
  NSString *shortId = [identifier length] > 6 ? [identifier substringToIndex:6] : identifier;
  NSString *model = [self stringValue:device key:@"model"];
  if (model && [shortId length] > 0)
    return [NSString stringWithFormat:@"%@ %@", model, shortId];
  if (model) return model;
  return shortId;
}

+ (NSString *)countdownMinutesFromSeconds:(NSInteger)seconds {
  if (seconds < 0) seconds = 0;
  return [NSString stringWithFormat:@"%ld", (long)(seconds / 60)];
}

+ (NSString *)countdownSecondsFromSeconds:(NSInteger)seconds {
  if (seconds < 0) seconds = 0;
  return [NSString stringWithFormat:@"%02ld", (long)(seconds % 60)];
}

@end
