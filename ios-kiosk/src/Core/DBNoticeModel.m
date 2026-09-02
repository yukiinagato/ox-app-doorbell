#import "DBNoticeModel.h"

NSString *const DBNoticeTargetGlobal = @"*";
const NSUInteger DBNoticeMaxTextLength = 200;
const NSUInteger DBNoticeMaxPresets = 8;

static NSDictionary *DBNoticeDict(id value) {
  return [value isKindOfClass:[NSDictionary class]] ? (NSDictionary *)value : nil;
}

@implementation DBNoticeModel

+ (NSString *)noticeText:(NSDictionary *)notice {
  id text = [notice objectForKey:@"text"];
  return [text isKindOfClass:[NSString class]] ? (NSString *)text : @"";
}

+ (BOOL)isNoticeActive:(NSDictionary *)notice nowMs:(long long)nowMs {
  if (![notice isKindOfClass:[NSDictionary class]]) return NO;
  if ([[self noticeText:notice] length] == 0) return NO;
  id expires = [notice objectForKey:@"expires_ms"];
  if (![expires isKindOfClass:[NSNumber class]]) return YES;
  long long deadline = [(NSNumber *)expires longLongValue];
  if (deadline <= 0) return YES;  // until cleared
  return nowMs < deadline;
}

+ (NSDictionary *)effectiveNoticeForDoor:(NSString *)door
                                  config:(NSDictionary *)config
                                   nowMs:(long long)nowMs {
  if (![config isKindOfClass:[NSDictionary class]]) return nil;
  if ([door length] > 0) {
    NSDictionary *doors = DBNoticeDict([config objectForKey:@"doors"]);
    NSDictionary *entry = DBNoticeDict([doors objectForKey:door]);
    NSDictionary *notice = DBNoticeDict([entry objectForKey:@"notice"]);
    if ([self isNoticeActive:notice nowMs:nowMs]) {
      NSMutableDictionary *out = [notice mutableCopy];
      [out setObject:@"door" forKey:@"scope"];
      [out setObject:door forKey:@"door"];
      return out;
    }
  }
  NSDictionary *global = DBNoticeDict([config objectForKey:@"notice"]);
  global = DBNoticeDict([global objectForKey:@"global"]);
  if ([self isNoticeActive:global nowMs:nowMs]) {
    NSMutableDictionary *out = [global mutableCopy];
    [out setObject:@"global" forKey:@"scope"];
    [out setObject:(door ?: @"") forKey:@"door"];
    return out;
  }
  return nil;
}

+ (NSArray *)doorsWithActiveNoticeInConfig:(NSDictionary *)config nowMs:(long long)nowMs {
  NSDictionary *doors = DBNoticeDict([config objectForKey:@"doors"]);
  if (doors == nil) return [NSArray array];
  NSMutableArray *out = [NSMutableArray array];
  for (NSString *door in [[doors allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
    NSDictionary *notice = DBNoticeDict([DBNoticeDict([doors objectForKey:door])
        objectForKey:@"notice"]);
    if ([self isNoticeActive:notice nowMs:nowMs]) [out addObject:door];
  }
  return out;
}

+ (NSArray *)presetsFromConfig:(NSDictionary *)config {
  NSDictionary *notice = DBNoticeDict([config objectForKey:@"notice"]);
  id raw = [notice objectForKey:@"presets"];
  if (![raw isKindOfClass:[NSArray class]]) return [NSArray array];
  NSMutableArray *out = [NSMutableArray array];
  NSMutableSet *seen = [NSMutableSet set];
  for (id entry in (NSArray *)raw) {
    if ([out count] >= DBNoticeMaxPresets) break;
    NSDictionary *preset = DBNoticeDict(entry);
    if (preset == nil) continue;
    id identifier = [preset objectForKey:@"id"];
    NSString *text = [self clampNoticeText:[preset objectForKey:@"text"]];
    if (![identifier isKindOfClass:[NSString class]] ||
        [(NSString *)identifier length] == 0 || [text length] == 0)
      continue;
    if ([seen containsObject:identifier]) continue;
    [seen addObject:identifier];
    [out addObject:[NSDictionary dictionaryWithObjectsAndKeys:
        identifier, @"id", text, @"text", nil]];
  }
  return out;
}

+ (long long)expiryMsForPreset:(NSString *)presetId
                         nowMs:(long long)nowMs
              endOfDayOffsetMs:(long long)endOfDayOffsetMs {
  if ([presetId isEqualToString:@"1h"]) return nowMs + 3600LL * 1000LL;
  if ([presetId isEqualToString:@"today"])
    return endOfDayOffsetMs > 0 ? nowMs + endOfDayOffsetMs : nowMs + 3600LL * 1000LL;
  return 0;  // until cleared
}

+ (NSString *)clampNoticeText:(NSString *)text {
  if (![text isKindOfClass:[NSString class]]) return @"";
  NSString *trimmed = [text stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if ([trimmed length] <= DBNoticeMaxTextLength) return trimmed;
  return [trimmed substringToIndex:DBNoticeMaxTextLength];
}

@end
