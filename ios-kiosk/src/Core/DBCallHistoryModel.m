#import "DBCallHistoryModel.h"

NSString *const DBCallHistoryFilterAll = @"all";
NSString *const DBCallHistoryFilterMissed = @"missed";

static NSString *DBHistoryString(NSDictionary *row, NSString *key) {
  id value = [row objectForKey:key];
  return [value isKindOfClass:[NSString class]] ? (NSString *)value : @"";
}

static long long DBHistoryTs(NSDictionary *row) {
  id value = [row objectForKey:@"ts"];
  return [value isKindOfClass:[NSNumber class]] ? [(NSNumber *)value longLongValue] : 0;
}

// Days from the civil epoch, without NSCalendar: the kiosk has no usable
// operating-system time-zone database and Core owns the zone anyway.
static void DBCivilFromDays(long long days, long long *year, int *month, int *day) {
  days += 719468;
  long long era = (days >= 0 ? days : days - 146096) / 146097;
  long long doe = days - era * 146097;
  long long yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
  long long y = yoe + era * 400;
  long long doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
  long long mp = (5 * doy + 2) / 153;
  long long d = doy - (153 * mp + 2) / 5 + 1;
  long long m = mp < 10 ? mp + 3 : mp - 9;
  *year = y + (m <= 2 ? 1 : 0);
  *month = (int)m;
  *day = (int)d;
}

static void DBLocalParts(long long ms, NSInteger offsetMinutes, long long *year, int *month,
                          int *day, int *hour, int *minute) {
  long long localSeconds = ms / 1000 + (long long)offsetMinutes * 60;
  long long days = localSeconds / 86400;
  long long rem = localSeconds % 86400;
  if (rem < 0) {
    rem += 86400;
    days -= 1;
  }
  DBCivilFromDays(days, year, month, day);
  *hour = (int)(rem / 3600);
  *minute = (int)((rem % 3600) / 60);
}

@implementation DBCallHistoryModel

+ (NSString *)dayKeyForTs:(long long)ms offsetMinutes:(NSInteger)offsetMinutes {
  long long year = 0;
  int month = 0, day = 0, hour = 0, minute = 0;
  DBLocalParts(ms, offsetMinutes, &year, &month, &day, &hour, &minute);
  return [NSString stringWithFormat:@"%04lld-%02d-%02d", year, month, day];
}

+ (NSString *)clockForTs:(long long)ms offsetMinutes:(NSInteger)offsetMinutes {
  long long year = 0;
  int month = 0, day = 0, hour = 0, minute = 0;
  DBLocalParts(ms, offsetMinutes, &year, &month, &day, &hour, &minute);
  return [NSString stringWithFormat:@"%02d:%02d", hour, minute];
}

+ (NSString *)durationTextForMs:(long long)durationMs {
  if (durationMs <= 0) return @"";
  long long seconds = durationMs / 1000;
  return [NSString stringWithFormat:@"%lld:%02lld", seconds / 60, seconds % 60];
}

+ (NSArray *)rowsFromLog:(NSDictionary *)log {
  id raw = [log isKindOfClass:[NSDictionary class]] ? [log objectForKey:@"rows"] : nil;
  if (![raw isKindOfClass:[NSArray class]]) return [NSArray array];
  NSMutableArray *out = [NSMutableArray array];
  for (id entry in (NSArray *)raw) {
    if (![entry isKindOfClass:[NSDictionary class]]) continue;
    NSDictionary *row = (NSDictionary *)entry;
    if ([DBHistoryString(row, @"id") length] == 0) continue;
    if (DBHistoryTs(row) <= 0) continue;
    [out addObject:row];
  }
  // Core returns newest first; sorting defensively keeps a merged list stable.
  [out sortUsingComparator:^NSComparisonResult(id a, id b) {
    long long ta = DBHistoryTs(a), tb = DBHistoryTs(b);
    if (ta == tb) return [DBHistoryString(b, @"id") compare:DBHistoryString(a, @"id")];
    return ta > tb ? NSOrderedAscending : NSOrderedDescending;
  }];
  return out;
}

+ (NSInteger)unreadMissedFromLog:(NSDictionary *)log {
  id value = [log isKindOfClass:[NSDictionary class]]
      ? [log objectForKey:@"unread_missed"] : nil;
  if (![value isKindOfClass:[NSNumber class]]) return 0;
  NSInteger count = [(NSNumber *)value integerValue];
  return count > 0 ? count : 0;
}

+ (NSString *)newestHlcInRows:(NSArray *)rows {
  for (NSDictionary *row in rows) {
    NSString *hlc = DBHistoryString(row, @"hlc");
    if ([hlc length] > 0) return hlc;
  }
  return @"";
}

+ (BOOL)rowIsMissed:(NSDictionary *)row {
  return [DBHistoryString(row, @"outcome") isEqualToString:@"missed"];
}

+ (NSArray *)filterRows:(NSArray *)rows filter:(NSString *)filter {
  if ([filter length] == 0 || [filter isEqualToString:DBCallHistoryFilterAll])
    return rows ?: [NSArray array];
  NSMutableArray *out = [NSMutableArray array];
  BOOL missedOnly = [filter isEqualToString:DBCallHistoryFilterMissed];
  for (NSDictionary *row in rows) {
    if (missedOnly ? [self rowIsMissed:row]
                   : [DBHistoryString(row, @"door") isEqualToString:filter])
      [out addObject:row];
  }
  return out;
}

+ (NSArray *)pageRows:(NSArray *)rows beforeMs:(long long)beforeMs limit:(NSInteger)limit {
  if (limit <= 0) limit = 50;
  NSMutableArray *out = [NSMutableArray array];
  for (NSDictionary *row in rows) {
    if (beforeMs > 0 && DBHistoryTs(row) >= beforeMs) continue;
    [out addObject:row];
    if ((NSInteger)[out count] >= limit) break;
  }
  return out;
}

+ (long long)nextBeforeMsForPage:(NSArray *)page {
  long long oldest = 0;
  for (NSDictionary *row in page) {
    long long ts = DBHistoryTs(row);
    if (ts <= 0) continue;
    if (oldest == 0 || ts < oldest) oldest = ts;
  }
  return oldest;
}

+ (BOOL)pageMayHaveMore:(NSArray *)page limit:(NSInteger)limit {
  if (limit <= 0) limit = 50;
  return (NSInteger)[page count] >= limit;
}

+ (NSArray *)mergeRows:(NSArray *)existing withPage:(NSArray *)page {
  NSMutableArray *merged = [NSMutableArray arrayWithArray:existing ?: [NSArray array]];
  NSMutableSet *known = [NSMutableSet set];
  for (NSDictionary *row in merged) [known addObject:DBHistoryString(row, @"id")];
  for (NSDictionary *row in page) {
    NSString *identifier = DBHistoryString(row, @"id");
    if ([identifier length] == 0 || [known containsObject:identifier]) continue;
    [known addObject:identifier];
    [merged addObject:row];
  }
  [merged sortUsingComparator:^NSComparisonResult(id a, id b) {
    long long ta = DBHistoryTs(a), tb = DBHistoryTs(b);
    if (ta == tb) return [DBHistoryString(b, @"id") compare:DBHistoryString(a, @"id")];
    return ta > tb ? NSOrderedAscending : NSOrderedDescending;
  }];
  return merged;
}

+ (NSArray *)groupRowsByDay:(NSArray *)rows dayKey:(NSString * (^)(long long ms))dayKey {
  NSMutableArray *sections = [NSMutableArray array];
  NSString *currentDay = nil;
  NSMutableArray *currentRows = nil;
  for (NSDictionary *row in rows) {
    NSString *day = dayKey ? dayKey(DBHistoryTs(row)) : @"";
    if (day == nil) day = @"";
    if (currentDay == nil || ![currentDay isEqualToString:day]) {
      currentDay = day;
      currentRows = [NSMutableArray array];
      [sections addObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:
          day, @"day", currentRows, @"rows", nil]];
    }
    [currentRows addObject:row];
  }
  return sections;
}

@end
