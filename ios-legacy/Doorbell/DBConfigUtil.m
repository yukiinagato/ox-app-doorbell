#import "DBConfigUtil.h"

@implementation DBConfigUtil

+ (id)dig:(NSDictionary *)root path:(NSString *)dotpath {
  id cur = root;
  NSArray *parts = [dotpath componentsSeparatedByString:@"."];
  for (NSString *part in parts) {
    if (![cur isKindOfClass:[NSDictionary class]]) return nil;
    cur = [(NSDictionary *)cur objectForKey:part];
    if (cur == nil) return nil;
  }
  if (cur == [NSNull null]) return nil;
  return cur;
}

+ (NSString *)str:(NSDictionary *)root path:(NSString *)dotpath {
  id v = [self dig:root path:dotpath];
  if (v == nil) return nil;
  if ([v isKindOfClass:[NSString class]]) {
    return [(NSString *)v length] == 0 ? nil : (NSString *)v;
  }
  return [NSString stringWithFormat:@"%@", v];
}

+ (NSInteger)intVal:(NSDictionary *)root path:(NSString *)dotpath def:(NSInteger)def {
  id v = [self dig:root path:dotpath];
  if (v == nil) return def;
  if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v integerValue];
  if ([v isKindOfClass:[NSString class]]) return [(NSString *)v integerValue];
  return def;
}

+ (double)doubleVal:(NSDictionary *)root path:(NSString *)dotpath def:(double)def {
  id v = [self dig:root path:dotpath];
  if (v == nil) return def;
  if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v doubleValue];
  if ([v isKindOfClass:[NSString class]]) return [(NSString *)v doubleValue];
  return def;
}

+ (BOOL)boolVal:(NSDictionary *)root path:(NSString *)dotpath def:(BOOL)def {
  id v = [self dig:root path:dotpath];
  if (v == nil) return def;
  if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v boolValue];
  return def;
}

+ (NSInteger)orderOf:(NSString *)identifier map:(NSDictionary *)map {
  id e = [map objectForKey:identifier];
  if ([e isKindOfClass:[NSDictionary class]]) {
    id o = [(NSDictionary *)e objectForKey:@"order"];
    if ([o isKindOfClass:[NSNumber class]]) return [(NSNumber *)o integerValue];
  }
  return 999;
}

+ (NSArray *)sortedByOrder:(NSDictionary *)map {
  NSArray *keys = [map allKeys];
  return [keys sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
    NSInteger oa = [self orderOf:a map:map];
    NSInteger ob = [self orderOf:b map:map];
    if (oa != ob) return oa < ob ? NSOrderedAscending : NSOrderedDescending;
    return [(NSString *)a compare:(NSString *)b];
  }];
}

+ (NSString *)labelOf:(NSDictionary *)entry lang:(NSString *)lang fallback:(NSString *)fallback {
  id label = [entry objectForKey:@"label"];
  if (![label isKindOfClass:[NSDictionary class]]) return fallback;
  id s = [(NSDictionary *)label objectForKey:lang];
  if ([s isKindOfClass:[NSString class]] && [(NSString *)s length] > 0) return s;
  s = [(NSDictionary *)label objectForKey:@"ja"];
  if ([s isKindOfClass:[NSString class]] && [(NSString *)s length] > 0) return s;
  return fallback;
}

+ (NSString *)evStr:(NSDictionary *)ev key:(NSString *)key {
  id v = [ev objectForKey:key];
  if ([v isKindOfClass:[NSString class]]) return v;
  if (v != nil && v != [NSNull null]) return [NSString stringWithFormat:@"%@", v];
  return @"";
}

+ (BOOL)evBool:(NSDictionary *)ev key:(NSString *)key {
  id v = [ev objectForKey:key];
  if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v boolValue];
  return NO;
}

+ (NSDictionary *)findDoorPeer:(NSDictionary *)status door:(NSString *)door {
  id peers = [status objectForKey:@"peers"];
  if (![peers isKindOfClass:[NSArray class]]) return nil;
  for (id p in (NSArray *)peers) {
    if (![p isKindOfClass:[NSDictionary class]]) continue;
    if ([self evBool:p key:@"self"]) continue;
    if (![[self evStr:p key:@"role"] isEqualToString:@"door_station"]) continue;
    if ([door length] > 0 && ![[self evStr:p key:@"door"] isEqualToString:door]) continue;
    if ([[self evStr:p key:@"status"] isEqualToString:@"dead"]) continue;
    return p;
  }
  return nil;
}

+ (NSString *)peerHost:(NSDictionary *)peer {
  id addrs = [peer objectForKey:@"addrs"];
  if (![addrs isKindOfClass:[NSArray class]]) return nil;
  for (id a in (NSArray *)addrs) {
    if (![a isKindOfClass:[NSString class]] || [(NSString *)a length] == 0) continue;
    NSString *s = a;
    NSRange r = [s rangeOfString:@":" options:NSBackwardsSearch];
    if (r.location != NSNotFound) {
      NSString *host = [s substringToIndex:r.location];
      return [host length] == 0 ? nil : host;
    }
    return s;
  }
  return nil;
}

+ (UIColor *)parseHexColor:(NSString *)s {
  NSString *hex = s;
  if ([hex hasPrefix:@"#"]) hex = [hex substringFromIndex:1];
  if ([hex length] != 6) return nil;
  unsigned int v = 0;
  NSScanner *sc = [NSScanner scannerWithString:hex];
  if (![sc scanHexInt:&v]) return nil;
  return [UIColor colorWithRed:((v >> 16) & 0xFF) / 255.0
                         green:((v >> 8) & 0xFF) / 255.0
                          blue:(v & 0xFF) / 255.0
                         alpha:1.0];
}

@end
