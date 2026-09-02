#import <Foundation/Foundation.h>

// Shell-side reading of the authoritative pairing snapshot (db_core_pairing_json).
// Shells render `state`; they never infer it. Everything here is Foundation-only
// and pure so it can be unit tested on the host.

// Returned when the snapshot has not arrived yet ("{}" or a malformed value).
// The UI must treat it as "unknown, do not decide" rather than as unpaired.
extern NSString *const DBPairingStateUnknown;

@interface DBPairingModel : NSObject

// One of unpaired | joining | persist_error | ready | revoked | unknown.
// Falls back to the legacy paired/persistence_ready booleans when an older Core
// omits "state", so a mixed-version fleet still shows the right screen.
+ (NSString *)stateFromPairingInfo:(NSDictionary *)info;

// Full text key for one join/invite error code, always inside the pair.err.*
// namespace and never derived from unvalidated text.
+ (NSString *)errorTextKeyForCode:(NSString *)code;

// Pending devices from pending.devices[], newest request last. Always an array.
+ (NSArray *)pendingDevicesFromPairingInfo:(NSDictionary *)info;

// Human row title for one pending device: name, else model, else id prefix.
+ (NSString *)displayNameForDevice:(NSDictionary *)device;

// Countdown helpers for pair.code_expires_in / pair.add_all_on ("{m}:{s}").
+ (NSString *)countdownMinutesFromSeconds:(NSInteger)seconds;
+ (NSString *)countdownSecondsFromSeconds:(NSInteger)seconds;

@end
