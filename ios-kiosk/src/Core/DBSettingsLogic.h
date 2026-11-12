#import <Foundation/Foundation.h>

// Foundation-only rules behind the native settings pages: identity edits for other devices,
// asset references, UI-element ranges, playback profiles, and the raw configuration view.
// Every key and range mirrors webui/admin/app.js and docs/en/config-schema.md.
@interface DBSettingsLogic : NSObject

// ---- device identity ----
// "[A-Za-z0-9][A-Za-z0-9_-]{0,63}", the door id every shell's boot validator accepts.
+ (BOOL)validDoorId:(NSString *)door;
// One to 64 characters after trimming.
+ (BOOL)validDeviceName:(NSString *)name;
// "door-" plus the first eight alphanumerics of the device id.
+ (NSString *)suggestedDoorIdForDevice:(NSString *)deviceId;
// Configured doors that no live door station other than deviceId serves, in display order.
// The door deviceId is assigned to today is always offered.
+ (NSArray *)unservedDoorsInConfig:(NSDictionary *)config status:(NSDictionary *)status
                         forDevice:(NSString *)deviceId;
// The id of another door station configured for door, or nil.
+ (NSString *)deviceBoundToDoor:(NSString *)door config:(NSDictionary *)config
                      excluding:(NSString *)deviceId;
// One atomic batch for devices.<id>.role and devices.<id>.door. An indoor panel gets an
// empty door. nil when the role or the door is invalid.
+ (NSArray *)roleChangeOpsForDevice:(NSString *)deviceId role:(NSString *)role
                               door:(NSString *)door;
// NO for a target whose role is fixed (tvOS).
+ (BOOL)roleEditableForDevice:(NSDictionary *)entry peer:(NSDictionary *)peer;
// {state: "online"|"suspect"|"offline", version: NSString or absent,
//  battery: NSNumber 0..100 or absent, charging: NSNumber BOOL}. peer may be nil.
+ (NSDictionary *)peerHealth:(NSDictionary *)peer;
// "AA:BB:..." for a 64-digit hex SHA-256, otherwise nil.
+ (NSString *)fingerprintText:(NSString *)hex;
// member, rekey_required, protocol_upgrade_required, upgrade_rejoin_required, or unknown.
+ (NSString *)membershipState:(NSDictionary *)peer;

// ---- assets ----
// hash -> array of the configuration places that reference it.
+ (NSDictionary *)assetReferencesInConfig:(NSDictionary *)config;

// ---- per-element UI overrides ----
// nil when the manifest a device published is usable, otherwise a short reason.
+ (NSString *)uiManifestError:(NSDictionary *)manifest;
// The properties the manifest allows for an element, in the canonical order.
+ (NSArray *)uiPropertiesInManifest:(NSDictionary *)manifest element:(NSString *)element;
+ (BOOL)uiPropertyIsColor:(NSString *)property;
// {min, max} for scale, font_scale, and radius; nil for a colour.
+ (NSDictionary *)uiRangeInManifest:(NSDictionary *)manifest element:(NSString *)element
                           property:(NSString *)property;
// nil when value is acceptable; otherwise "absent", "not_allowed", "range", or "color".
+ (NSString *)uiValueErrorInManifest:(NSDictionary *)manifest element:(NSString *)element
                            property:(NSString *)property value:(id)value;
// The element's stored override, whether it is keyed whole or nested by its dots.
+ (NSDictionary *)uiElementValue:(NSDictionary *)elements element:(NSString *)element;

// ---- playback profiles ----
// The three known strategies in stored order with defaults filled in.
+ (NSArray *)normalizedPlaybackStrategies:(NSDictionary *)profile;
// nil, "timeout_range", or "one_required".
+ (NSString *)playbackErrorForStrategies:(NSArray *)strategies;
// existing with the edited strategies merged in; unknown fields and strategies are kept.
+ (NSDictionary *)playbackProfile:(NSDictionary *)existing withStrategies:(NSArray *)edited;

// ---- raw configuration ----
// @[ @[ dotted key, compact JSON value ], ... ] for every leaf, sorted by key.
+ (NSArray *)flattenConfig:(NSDictionary *)config;
// Parses one JSON value (object, array, string, number, true, false, null). NO on bad JSON.
+ (BOOL)parseJsonValue:(NSString *)text into:(id *)value;
// A dotted key of non-empty segments with no whitespace.
+ (BOOL)validConfigKey:(NSString *)key;
+ (NSString *)compactJson:(id)value;

// ---- speech ----
// 0.25 to 4, the range Core accepts for speech.speaking_rate.
+ (BOOL)parseSpeakingRate:(NSString *)text into:(double *)rate;

@end
