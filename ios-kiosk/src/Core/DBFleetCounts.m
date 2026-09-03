#import "DBFleetCounts.h"

@interface DBFleetCounts ()
@property(nonatomic, readwrite) NSInteger devices;
@property(nonatomic, readwrite) NSInteger devicesOnline;
@property(nonatomic, readwrite) NSInteger doorStations;
@property(nonatomic, readwrite) NSInteger doorStationsOnline;
@property(nonatomic, readwrite) NSInteger panels;
@property(nonatomic, readwrite) NSInteger panelsOnline;
@end

@implementation DBFleetCounts

+ (NSString *)string:(NSDictionary *)root key:(NSString *)key {
  if (![root isKindOfClass:[NSDictionary class]]) return @"";
  id value = [root objectForKey:key];
  return [value isKindOfClass:[NSString class]] ? value : @"";
}

+ (NSDictionary *)dictionary:(NSDictionary *)root key:(NSString *)key {
  if (![root isKindOfClass:[NSDictionary class]]) return nil;
  id value = [root objectForKey:key];
  return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

+ (NSString *)peerID:(NSDictionary *)peer {
  NSString *identifier = [self string:peer key:@"id"];
  return [identifier length] > 0 ? identifier : [self string:peer key:@"node_id"];
}

+ (NSString *)roleOf:(NSDictionary *)peer config:(NSDictionary *)config {
  NSDictionary *devices = [self dictionary:config key:@"devices"];
  NSDictionary *device = [self dictionary:devices key:[self peerID:peer]];
  NSString *configured = [self string:device key:@"role"];
  return [configured length] > 0 ? configured : [self string:peer key:@"role"];
}

+ (DBFleetCounts *)countsFromStatus:(NSDictionary *)status config:(NSDictionary *)config {
  DBFleetCounts *out = [[DBFleetCounts alloc] init];
  id peers = [status objectForKey:@"peers"];
  if (![peers isKindOfClass:[NSArray class]]) return out;
  NSMutableSet *seen = [NSMutableSet set];
  for (id candidate in (NSArray *)peers) {
    if (![candidate isKindOfClass:[NSDictionary class]]) continue;
    NSString *identifier = [self peerID:candidate];
    // A duplicate entry for one node is one device, not two.
    if ([identifier length] > 0) {
      if ([seen containsObject:identifier]) continue;
      [seen addObject:identifier];
    }
    BOOL alive = [[self string:candidate key:@"status"] isEqualToString:@"alive"];
    NSString *role = [self roleOf:candidate config:config];
    out.devices += 1;
    if (alive) out.devicesOnline += 1;
    if ([role isEqualToString:@"door_station"]) {
      out.doorStations += 1;
      if (alive) out.doorStationsOnline += 1;
    } else if ([role isEqualToString:@"indoor_panel"]) {
      out.panels += 1;
      if (alive) out.panelsOnline += 1;
    }
  }
  return out;
}

@end
