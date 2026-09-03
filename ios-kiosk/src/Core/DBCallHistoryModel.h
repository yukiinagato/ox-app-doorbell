#import <Foundation/Foundation.h>

// Call-history paging, filtering, and day grouping for the dashboard list and
// the full-screen history page (batch-2 spec §5.1 "History").
// Pure model over db_core_call_log_json documents so the host suite can test it.

FOUNDATION_EXPORT NSString *const DBCallHistoryFilterAll;
FOUNDATION_EXPORT NSString *const DBCallHistoryFilterMissed;

@interface DBCallHistoryModel : NSObject

// Validated, newest-first rows. Malformed entries are dropped, never rendered.
+ (NSArray *)rowsFromLog:(NSDictionary *)log;
+ (NSInteger)unreadMissedFromLog:(NSDictionary *)log;
+ (NSString *)newestHlcInRows:(NSArray *)rows;

// filter is DBCallHistoryFilterAll, DBCallHistoryFilterMissed, or a door id.
+ (NSArray *)filterRows:(NSArray *)rows filter:(NSString *)filter;

// One page strictly older than beforeMs. beforeMs of zero means "newest page".
+ (NSArray *)pageRows:(NSArray *)rows beforeMs:(long long)beforeMs limit:(NSInteger)limit;
// The paging cursor for the next 「さらに読み込む」 request.
+ (long long)nextBeforeMsForPage:(NSArray *)page;
// YES when a further page can exist: the page filled up completely.
+ (BOOL)pageMayHaveMore:(NSArray *)page limit:(NSInteger)limit;

// Rows already displayed plus a freshly loaded page, de-duplicated by row id and
// kept newest-first so a concurrent refresh cannot duplicate or reorder a call.
+ (NSArray *)mergeRows:(NSArray *)existing withPage:(NSArray *)page;

// Sections of {"day": <key>, "rows": [...]} in list order; dayKey maps a
// wall-clock timestamp to the caller's locale-correct day string.
+ (NSArray *)groupRowsByDay:(NSArray *)rows dayKey:(NSString * (^)(long long ms))dayKey;

+ (BOOL)rowIsMissed:(NSDictionary *)row;

// Wall-clock rendering in the cluster time zone. Core owns the zone, so the
// shell asks it once for the current offset and formats every row with that
// offset instead of consulting the operating system's calendar.
+ (NSString *)dayKeyForTs:(long long)ms offsetMinutes:(NSInteger)offsetMinutes;  // YYYY-MM-DD
+ (NSString *)clockForTs:(long long)ms offsetMinutes:(NSInteger)offsetMinutes;   // HH:MM
+ (NSString *)durationTextForMs:(long long)durationMs;                           // M:SS

// The civil parts of one instant in a fixed offset, in the shape core's
// local-time document uses: hh, mm, ss, date, weekday_num, wall_ms. The shell
// derives per-second clock ticks from a cached base with this instead of
// asking core every second, which on an iPad 1 meant a blocking hop onto
// core's serial queue once a second per screen.
+ (NSDictionary *)localPartsForTs:(long long)ms offsetMinutes:(NSInteger)offsetMinutes;

@end
