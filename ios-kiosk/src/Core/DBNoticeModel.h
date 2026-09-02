#import <Foundation/Foundation.h>

// Announcements (batch-2 spec §1.4, §4.3, §5.1, §5.2).
// A door-specific notice wins over the cluster-wide notice.global, and an
// expired notice is treated as absent even before core prunes it.

FOUNDATION_EXPORT NSString *const DBNoticeTargetGlobal;   // "*" — the cluster-wide notice
FOUNDATION_EXPORT const NSUInteger DBNoticeMaxTextLength;  // 200
FOUNDATION_EXPORT const NSUInteger DBNoticeMaxPresets;     // 8

@interface DBNoticeModel : NSObject

+ (BOOL)isNoticeActive:(NSDictionary *)notice nowMs:(long long)nowMs;
// The notice a given door renders, or nil. The result carries "scope" =
// "door" or "global" so the UI can say which one it is showing.
+ (NSDictionary *)effectiveNoticeForDoor:(NSString *)door
                                  config:(NSDictionary *)config
                                   nowMs:(long long)nowMs;
+ (NSString *)noticeText:(NSDictionary *)notice;

// Doors with an active notice, in configuration order.
+ (NSArray *)doorsWithActiveNoticeInConfig:(NSDictionary *)config nowMs:(long long)nowMs;

// Admin-editable presets: [{id, text}], bounded and validated.
+ (NSArray *)presetsFromConfig:(NSDictionary *)config;

// Expiry presets. "1h", "today", "until_cleared" -> absolute ms (0 = until cleared).
+ (long long)expiryMsForPreset:(NSString *)presetId
                         nowMs:(long long)nowMs
              endOfDayOffsetMs:(long long)endOfDayOffsetMs;

// Trimmed and clamped to DBNoticeMaxTextLength; empty means "not publishable".
+ (NSString *)clampNoticeText:(NSString *)text;

@end
