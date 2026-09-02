#import <Foundation/Foundation.h>

// Visit purposes (`visit_purposes.<id>`), including the cross-platform
// `enabled` flag introduced by the iOS package: a bool that defaults to true,
// so an installation that predates the key keeps every purpose.
//
// A disabled purpose disappears from every chooser a visitor or resident can
// pick from. It is deliberately NOT hidden where an already chosen purpose is
// being reported back (the incoming screen's purpose slot, the call history):
// that is a record of what the visitor actually pressed, and dropping it would
// lose information about a call that already happened.
@interface DBPurposeModel : NSObject

// Only an explicit false disables; anything else, including an absent key or a
// non-boolean value, leaves the purpose enabled.
+ (BOOL)isPurposeEnabled:(NSDictionary *)entry;

// Configuration order (`order`, then identifier), matching the rest of the
// shell. `allPurposeIdsInConfig` keeps disabled entries so the settings editor
// can switch them back on; `enabledPurposeIdsInConfig` is what a chooser shows.
+ (NSArray *)allPurposeIdsInConfig:(NSDictionary *)config;
+ (NSArray *)enabledPurposeIdsInConfig:(NSDictionary *)config;

// The configuration key the settings toggle writes.
+ (NSString *)enabledKeyForPurpose:(NSString *)purposeId;

@end
