#import "DBConfigUtil.h"
#import <math.h>

static CGFloat DBPresentationLinear(CGFloat value) {
  return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4);
}

static CGFloat DBPresentationLuminance(UIColor *color) {
  CGColorRef cg = color.CGColor;
  const CGFloat *components = CGColorGetComponents(cg);
  size_t count = CGColorGetNumberOfComponents(cg);
  CGFloat r = components[0];
  CGFloat g = count >= 3 ? components[1] : r;
  CGFloat b = count >= 3 ? components[2] : r;
  return 0.2126 * DBPresentationLinear(r) + 0.7152 * DBPresentationLinear(g) +
      0.0722 * DBPresentationLinear(b);
}

static CGFloat DBPresentationContrast(UIColor *first, UIColor *second) {
  CGFloat a = DBPresentationLuminance(first), b = DBPresentationLuminance(second);
  return (MAX(a, b) + 0.05) / (MIN(a, b) + 0.05);
}

@implementation DBConfigUtil

+ (id)dig:(NSDictionary *)root path:(NSString *)dotpath {
  id cur = root;
  for (NSString *part in [dotpath componentsSeparatedByString:@"."]) {
    if (![cur isKindOfClass:[NSDictionary class]]) return nil;
    cur = [(NSDictionary *)cur objectForKey:part];
    if (cur == nil) return nil;
  }
  return (cur == [NSNull null]) ? nil : cur;
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
  if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v integerValue];
  if ([v isKindOfClass:[NSString class]]) return [(NSString *)v integerValue];
  return def;
}

+ (long long)longLongVal:(NSDictionary *)root path:(NSString *)dotpath def:(long long)def {
  id v = [self dig:root path:dotpath];
  if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v longLongValue];
  if ([v isKindOfClass:[NSString class]]) return [(NSString *)v longLongValue];
  return def;
}

+ (double)doubleVal:(NSDictionary *)root path:(NSString *)dotpath def:(double)def {
  id v = [self dig:root path:dotpath];
  if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v doubleValue];
  if ([v isKindOfClass:[NSString class]]) return [(NSString *)v doubleValue];
  return def;
}

+ (BOOL)boolVal:(NSDictionary *)root path:(NSString *)dotpath def:(BOOL)def {
  id v = [self dig:root path:dotpath];
  return [v isKindOfClass:[NSNumber class]] ? [(NSNumber *)v boolValue] : def;
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
  return [[map allKeys] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
    NSInteger oa = [self orderOf:a map:map];
    NSInteger ob = [self orderOf:b map:map];
    if (oa != ob) return oa < ob ? NSOrderedAscending : NSOrderedDescending;
    return [a compare:b];
  }];
}

+ (NSString *)labelOf:(NSDictionary *)entry lang:(NSString *)lang fallback:(NSString *)fallback {
  id label = [entry objectForKey:@"label"];
  if (![label isKindOfClass:[NSDictionary class]]) return fallback;
  for (NSString *l in [NSArray arrayWithObjects:lang, @"ja", nil]) {
    id s = [(NSDictionary *)label objectForKey:l];
    if ([s isKindOfClass:[NSString class]] && [(NSString *)s length] > 0) return s;
  }
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
  return [v isKindOfClass:[NSNumber class]] ? [(NSNumber *)v boolValue] : NO;
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

+ (NSDictionary *)findPeer:(NSDictionary *)status nodeId:(NSString *)nodeId {
  if ([nodeId length] == 0) return nil;
  id peers = [status objectForKey:@"peers"];
  if (![peers isKindOfClass:[NSArray class]]) return nil;
  for (id p in (NSArray *)peers) {
    if (![p isKindOfClass:[NSDictionary class]]) continue;
    if ([[self evStr:p key:@"id"] isEqualToString:nodeId] ||
        [[self evStr:p key:@"node_id"] isEqualToString:nodeId]) return p;
  }
  return nil;
}

+ (NSDictionary *)findDoorPeer:(NSDictionary *)status host:(NSString *)host {
  if ([host length] == 0) return nil;
  for (NSDictionary *peer in [self doorPeers:status]) {
    if ([[self peerHosts:peer] containsObject:host]) return peer;
  }
  return nil;
}

+ (NSArray *)doorPeers:(NSDictionary *)status {
  id peers = [status objectForKey:@"peers"];
  if (![peers isKindOfClass:[NSArray class]]) return @[];
  NSMutableArray *out = [NSMutableArray array];
  for (id p in (NSArray *)peers) {
    if (![p isKindOfClass:[NSDictionary class]]) continue;
    if ([self evBool:p key:@"self"]) continue;
    if (![[self evStr:p key:@"role"] isEqualToString:@"door_station"]) continue;
    if ([[self evStr:p key:@"status"] isEqualToString:@"dead"]) continue;
    id addrs = [p objectForKey:@"addrs"];
    BOOL hasAddr = [addrs isKindOfClass:[NSArray class]] && [(NSArray *)addrs count] > 0;
    if ([[self evStr:p key:@"stream"] length] == 0 &&
        [[self evStr:p key:@"stream_mp4"] length] == 0 && !hasAddr) continue;
    [out addObject:p];
  }
  [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
    NSString *an = [self evStr:a key:@"name"];
    NSString *bn = [self evStr:b key:@"name"];
    return [an compare:bn options:NSCaseInsensitiveSearch];
  }];
  return out;
}

+ (NSArray *)peerHosts:(NSDictionary *)peer {
  id addrs = [peer objectForKey:@"addrs"];
  if (![addrs isKindOfClass:[NSArray class]]) return @[];
  NSMutableArray *hosts = [NSMutableArray array];
  for (id a in (NSArray *)addrs) {
    if (![a isKindOfClass:[NSString class]] || [(NSString *)a length] == 0) continue;
    NSString *raw = (NSString *)a;
    NSString *host = raw;
    if ([raw hasPrefix:@"["]) {
      NSRange end = [raw rangeOfString:@"]"];
      if (end.location != NSNotFound && end.location > 1)
        host = [raw substringWithRange:NSMakeRange(1, end.location - 1)];
    } else {
      NSArray *parts = [raw componentsSeparatedByString:@":"];
      // Strip the port only from IPv4/hostname pairs; preserve bare IPv6 literals.
      if ([parts count] == 2) host = [parts objectAtIndex:0];
    }
    if ([host length] > 0 && ![hosts containsObject:host]) [hosts addObject:host];
  }
  return hosts;
}

+ (NSString *)peerHost:(NSDictionary *)peer {
  NSArray *hosts = [self peerHosts:peer];
  return [hosts count] ? [hosts objectAtIndex:0] : nil;
}

+ (NSString *)urlHost:(NSString *)host {
  if ([host length] == 0) return nil;
  if ([host hasPrefix:@"["]) return host;
  return [host rangeOfString:@":"].location == NSNotFound
      ? host : [NSString stringWithFormat:@"[%@]", host];
}

+ (UIColor *)parseHexColor:(NSString *)s {
  NSString *hex = s;
  if ([hex hasPrefix:@"#"]) hex = [hex substringFromIndex:1];
  if ([hex length] != 6) return nil;
  unsigned int v = 0;
  NSScanner *sc = [NSScanner scannerWithString:hex];
  if (![sc scanHexInt:&v] || ![sc isAtEnd]) return nil;
  return [UIColor colorWithRed:((v >> 16) & 0xFF) / 255.0
                         green:((v >> 8) & 0xFF) / 255.0
                          blue:(v & 0xFF) / 255.0
                         alpha:1.0];
}

+ (NSDictionary *)emergencyPalette:(NSDictionary *)event {
  UIColor *defaultBackground = [UIColor colorWithRed:0.55 green:0.05 blue:0.04 alpha:1];
  UIColor *defaultForeground = [UIColor whiteColor];
  UIColor *defaultAccent = [UIColor whiteColor];
  NSArray *keys = @[ @"background", @"foreground", @"accent" ];
  NSArray *fallbacks = @[ defaultBackground, defaultForeground, defaultAccent ];
  NSMutableArray *colors = [NSMutableArray array];
  BOOL invalid = NO;
  for (NSUInteger i = 0; i < [keys count]; i++) {
    id raw = [event objectForKey:[keys objectAtIndex:i]];
    if (raw == nil || raw == [NSNull null] ||
        ([raw isKindOfClass:[NSString class]] && [(NSString *)raw length] == 0)) {
      [colors addObject:[fallbacks objectAtIndex:i]];
      continue;
    }
    if (![raw isKindOfClass:[NSString class]] || [(NSString *)raw length] != 7 ||
        ![(NSString *)raw hasPrefix:@"#"]) {
      invalid = YES;
      break;
    }
    UIColor *color = [self parseHexColor:raw];
    if (!color) {
      invalid = YES;
      break;
    }
    [colors addObject:color];
  }
  if (!invalid && [colors count] == 3) {
    invalid = DBPresentationContrast([colors objectAtIndex:1], [colors objectAtIndex:0]) < 4.5 ||
        DBPresentationContrast([colors objectAtIndex:2], [colors objectAtIndex:0]) < 3.0;
  }
  UIColor *background = invalid ? defaultBackground : [colors objectAtIndex:0];
  UIColor *foreground = invalid ? defaultForeground : [colors objectAtIndex:1];
  UIColor *accent = invalid ? defaultAccent : [colors objectAtIndex:2];
  UIColor *accentForeground = DBPresentationContrast([UIColor blackColor], accent) >= 4.5
      ? [UIColor blackColor] : [UIColor whiteColor];
  return @{
    @"background" : background,
    @"foreground" : foreground,
    @"accent" : accent,
    @"accent_foreground" : accentForeground,
    @"limitation" : invalid ? @"invalid_emergency_presentation_colors" : @"",
  };
}

@end
