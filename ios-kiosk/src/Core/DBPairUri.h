#import <Foundation/Foundation.h>

// The doorbell://pair invitation: what the shell accepts, what it refuses, why.
//
// Core is adding db_core_parse_pair_uri_json so every shell reads one format.
// These are the spec's error names, so this class becomes a thin wrapper around
// that call without any behaviour changing.
FOUNDATION_EXPORT NSString *const DBPairUriErrorBadScheme;    // "bad_scheme"
FOUNDATION_EXPORT NSString *const DBPairUriErrorMissingPin;   // "missing_pin"
FOUNDATION_EXPORT NSString *const DBPairUriErrorMissingHost;  // "missing_host"
FOUNDATION_EXPORT NSString *const DBPairUriErrorExpired;      // "expired"

@interface DBPairUri : NSObject

@property(nonatomic, readonly, copy) NSString *host;     // "10.0.1.5:47172"
@property(nonatomic, readonly, copy) NSString *pin;      // exactly six ASCII digits
@property(nonatomic, readonly, copy) NSString *cluster;  // percent-decoded, may be empty
@property(nonatomic, readonly) long long expiresAtS;     // 0 = never expires
// nil when the invitation is usable, otherwise one of the names above.
@property(nonatomic, readonly, copy) NSString *error;

- (BOOL)isValid;

// nowS is compared against the expiry: the deadline is the second the token
// stops working, not the last second it works.
+ (DBPairUri *)parse:(NSString *)text nowS:(long long)nowS;

// The same result read from core's document, once that export exists. Core is
// the authority when it answers; an absent or unparsable document is nil so the
// caller falls back to the local parse.
+ (DBPairUri *)fromCoreDocument:(NSDictionary *)document;

// The invitation core publishes next to the PIN, or an empty string on a core
// that predates the field, in which case the card keeps showing host and PIN.
+ (NSString *)invitationUriInPairingInfo:(NSDictionary *)pairingInfo;

@end
