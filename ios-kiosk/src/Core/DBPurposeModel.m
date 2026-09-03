#import "DBPurposeModel.h"

static NSDictionary *DBPurposeMap(NSDictionary *config) {
  if (![config isKindOfClass:[NSDictionary class]]) return nil;
  id purposes = [config objectForKey:@"visit_purposes"];
  return [purposes isKindOfClass:[NSDictionary class]] ? (NSDictionary *)purposes : nil;
}

// Same ordering rule as DBConfigUtil's sortedByOrder: `order` when it is a
// number, 999 otherwise, ties broken by identifier so the list is stable.
static NSInteger DBPurposeOrder(NSDictionary *map, NSString *identifier) {
  id entry = [map objectForKey:identifier];
  if ([entry isKindOfClass:[NSDictionary class]]) {
    id order = [(NSDictionary *)entry objectForKey:@"order"];
    if ([order isKindOfClass:[NSNumber class]]) return [(NSNumber *)order integerValue];
  }
  return 999;
}

static NSArray *DBSortedPurposeIds(NSDictionary *map) {
  return [[map allKeys] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
    if (![a isKindOfClass:[NSString class]] || ![b isKindOfClass:[NSString class]])
      return NSOrderedSame;
    NSInteger orderA = DBPurposeOrder(map, a);
    NSInteger orderB = DBPurposeOrder(map, b);
    if (orderA != orderB) return orderA < orderB ? NSOrderedAscending : NSOrderedDescending;
    return [(NSString *)a compare:(NSString *)b];
  }];
}

@implementation DBPurposeModel

+ (BOOL)isPurposeEnabled:(NSDictionary *)entry {
  if (![entry isKindOfClass:[NSDictionary class]]) return YES;
  id enabled = [entry objectForKey:@"enabled"];
  if (![enabled isKindOfClass:[NSNumber class]]) return YES;
  return [(NSNumber *)enabled boolValue];
}

+ (NSArray *)allPurposeIdsInConfig:(NSDictionary *)config {
  NSDictionary *map = DBPurposeMap(config);
  if (map == nil) return [NSArray array];
  NSMutableArray *out = [NSMutableArray array];
  for (id identifier in DBSortedPurposeIds(map)) {
    if (![identifier isKindOfClass:[NSString class]]) continue;
    if (![[map objectForKey:identifier] isKindOfClass:[NSDictionary class]]) continue;
    [out addObject:identifier];
  }
  return out;
}

+ (NSArray *)enabledPurposeIdsInConfig:(NSDictionary *)config {
  NSDictionary *map = DBPurposeMap(config);
  NSMutableArray *out = [NSMutableArray array];
  for (NSString *identifier in [self allPurposeIdsInConfig:config]) {
    if ([self isPurposeEnabled:[map objectForKey:identifier]]) [out addObject:identifier];
  }
  return out;
}

+ (NSString *)iconNameForPurpose:(NSString *)purposeId {
  if (![purposeId isKindOfClass:[NSString class]] || [purposeId length] == 0) return nil;
  NSDictionary *icons = [NSDictionary dictionaryWithObjectsAndKeys:
      @"home", @"p_visit",
      @"package", @"p_delivery",
      @"mail", @"p_mail", nil];
  return [icons objectForKey:purposeId];
}

+ (NSString *)displayIconForConfiguredIcon:(NSString *)icon {
  if (![icon isKindOfClass:[NSString class]] || [icon length] == 0) return @"";
  NSMutableString *safe = [NSMutableString string];
  NSUInteger length = [icon length];
  for (NSUInteger i = 0; i < length; i++) {
    unichar c = [icon characterAtIndex:i];
    // A surrogate pair is a codepoint above the BMP: every modern emoji.
    if (c >= 0xD800 && c <= 0xDFFF) continue;
    if (c == 0xFE0E || c == 0xFE0F) continue;  // Variation selectors.
    if (c == 0x200D) continue;                 // Zero-width joiner.
    if (c >= 0x1F00 && c <= 0x1FFF) continue;  // Not emoji, but not in the font.
    if (c < 0x20) continue;
    [safe appendFormat:@"%C", c];
  }
  NSString *trimmed = [safe stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  return trimmed ?: @"";
}

+ (NSString *)enabledKeyForPurpose:(NSString *)purposeId {
  if ([purposeId length] == 0) return @"";
  return [NSString stringWithFormat:@"visit_purposes.%@.enabled", purposeId];
}

@end
