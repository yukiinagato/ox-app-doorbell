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
      @"f7:house_fill", @"p_visit",
      @"f7:cube_box_fill", @"p_delivery",
      @"f7:envelope_fill", @"p_mail",
      @"f7:bag_fill", @"p_sales",
      @"f7:hammer_fill", @"p_work",
      @"f7:ellipsis_circle_fill", @"p_other", nil];
  // Every purpose has an icon; one the owner invented gets the generic person.
  return [icons objectForKey:purposeId] ?: @"f7:person_fill";
}

// The first rule that matches wins. Emoji are compared by their base codepoint (variation
// selectors and skin tones removed), names by their lowercase text.
static NSString *DBPurposeIconForGlyph(NSString *icon) {
  NSString *key = [[icon stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
  NSArray *rules = @[
    @[ @"f7:house_fill", @"house", @"home", @"visit", @"visitor", @"\U0001F3E0", @"\U0001F3E1",
       @"\U0001F3D8" ],
    @[ @"f7:cube_box_fill", @"box", @"package", @"parcel", @"delivery", @"\U0001F4E6",
       @"\U0001F69A", @"\U0001F6F5" ],
    @[ @"f7:envelope_fill", @"envelope", @"mail", @"post", @"\u2709", @"\U0001F4E7",
       @"\U0001F4EE", @"\U0001F4EC", @"\U0001F48C", @"\U0001F4E8" ],
    @[ @"f7:bag_fill", @"bag", @"briefcase", @"sales", @"\U0001F6CD", @"\U0001F45C",
       @"\U0001F4BC", @"\U0001F6D2", @"\U0001F4B4" ],
    @[ @"f7:hammer_fill", @"hammer", @"wrench", @"tool", @"tools", @"work", @"utility",
       @"\U0001F528", @"\U0001F527", @"\U0001F6E0", @"\u2692", @"\u26CF" ],
    @[ @"f7:ellipsis_circle_fill", @"ellipsis", @"other", @"more", @"\u2026", @"\u22EF",
       @"\u2753", @"\u2754", @"\U0001F4AC" ],
    @[ @"f7:bell_fill", @"bell", @"ring", @"\U0001F514", @"\U0001F6CE" ],
    @[ @"f7:person_fill", @"person", @"user", @"\U0001F464", @"\U0001F64B" ],
  ];
  NSMutableString *base = [NSMutableString string];
  NSUInteger length = [key length];
  for (NSUInteger i = 0; i < length; i++) {
    unichar c = [key characterAtIndex:i];
    if (c == 0xFE0E || c == 0xFE0F || c == 0x200D) continue;
    [base appendFormat:@"%C", c];
  }
  for (NSArray *rule in rules)
    for (NSUInteger i = 1; i < [rule count]; i++)
      if ([base hasPrefix:[rule objectAtIndex:i]] && ([base length] == [[rule objectAtIndex:i] length] ||
          [[rule objectAtIndex:i] characterAtIndex:0] > 0x2000))
        return [rule objectAtIndex:0];
  return nil;
}

+ (NSString *)iconNameForOptionPurpose:(NSString *)purposeId icon:(NSString *)icon {
  if ([purposeId isKindOfClass:[NSString class]] && [purposeId length] > 0)
    return [self iconNameForPurpose:purposeId];
  if (![icon isKindOfClass:[NSString class]]) return nil;
  if ([[icon stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
          length] == 0) return nil;
  return DBPurposeIconForGlyph(icon) ?: @"f7:person_fill";
}

+ (NSArray *)optionIconChoices {
  return @[
    @[ @"\U0001F3E0", @"flow_editor.icon_house", @"f7:house_fill" ],
    @[ @"\U0001F4E6", @"flow_editor.icon_box", @"f7:cube_box_fill" ],
    @[ @"\u2709\uFE0F", @"flow_editor.icon_envelope", @"f7:envelope_fill" ],
    @[ @"\U0001F6CD\uFE0F", @"flow_editor.icon_bag", @"f7:bag_fill" ],
    @[ @"\U0001F528", @"flow_editor.icon_tool", @"f7:hammer_fill" ],
    @[ @"\u2026", @"flow_editor.icon_ellipsis", @"f7:ellipsis_circle_fill" ],
    @[ @"\U0001F514", @"flow_editor.icon_bell", @"f7:bell_fill" ],
    @[ @"\U0001F464", @"flow_editor.icon_person", @"f7:person_fill" ],
  ];
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
