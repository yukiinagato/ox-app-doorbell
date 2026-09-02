#import <Foundation/Foundation.h>

// Reads Documents/boot.json. The unchanged bundle ID preserves the existing
// boot.json, doorbell.db, and Keychain namespace during compatibility upgrades.
@interface DBBootConfig : NSObject

@property(nonatomic, copy) NSString *rawJson;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *role;
@property(nonatomic, copy) NSString *door;
@property(nonatomic, copy) NSString *uiLang;
@property(nonatomic, assign) BOOL kiosk;
@property(nonatomic, assign) long httpPort;
@property(nonatomic, copy) NSString *doorHost;
@property(nonatomic, assign) long directPort;
@property(nonatomic, copy) NSString *sipBackend;  // auto | minisip | core
@property(nonatomic, assign) BOOL micEnabled;
@property(nonatomic, copy) NSArray *seedPeers;

// Read-only migration input. New writes use psk_ref and never place the PSK in
// boot.json; this value remains populated only while an old profile is loaded.
@property(nonatomic, copy) NSString *legacyPskHex;

// Compatibility-shell local media override. This lets a camera-less iPad 1 own
// the visitor UI while a trusted LAN gateway owns the actual camera stream.
// source: "auto" (peer/core metadata), "ip_camera", or "none".
@property(nonatomic, copy) NSString *videoSource;
@property(nonatomic, copy) NSString *videoMjpegURL;
@property(nonatomic, copy) NSString *videoMp4URL;
@property(nonatomic, copy) NSString *videoSnapshotURL;

// Root helper policy is per-device and deliberately tiny: off | auto | on.
// The app only reports the requested policy; the root-owned helper remains the
// authority that decides whether it is available and safe to activate.
@property(nonatomic, copy) NSString *keepaliveHelperPolicy;

// Local support actions, including screenshots and the controlled memory-warning
// qualification trigger, are disabled by default. Enable only for a bounded run.
@property(nonatomic, assign) BOOL diagnosticDumps;

// Remote screenshot hook for verification on a device with no screencap.
// Absent by default, so an ordinary install polls nothing at all.
@property(nonatomic, assign) BOOL debugScreenshots;

// Opens one screen at launch so every page can be photographed on a device
// with no touch injection. Honoured only while debugScreenshots is on, so it
// cannot strand a real panel on the settings page.
// dashboard | incoming | settings | history | pairing | visitor
@property(nonatomic, copy) NSString *debugStartScreen;
@property(nonatomic, assign) BOOL setupRequired;
@property(nonatomic, copy) NSString *suggestedDoor;

+ (NSString *)dataDir;  // Creates Documents when needed.

// Loads the persisted profile or the indoor-panel default. This must not be
// named +load because the Objective-C runtime invokes that selector before
// main(), when no application autorelease pool exists.
+ (DBBootConfig *)loadConfiguration;
+ (BOOL)isValidRole:(NSString *)role;
+ (BOOL)isValidDoor:(NSString *)door;
+ (BOOL)persistSetupName:(NSString *)name role:(NSString *)role door:(NSString *)door;

// Device-local settings the native settings screen may write without any
// cluster credential. The allow-list is deliberate: everything else in
// boot.json is either cluster identity or set once during provisioning.
+ (BOOL)isLocalWritableKey:(NSString *)key;
+ (BOOL)isValidLocalValue:(NSString *)value forKey:(NSString *)key;
// Pure transformation used by the writer below and by the host tests.
+ (NSString *)localJsonFromJson:(NSString *)json key:(NSString *)key value:(NSString *)value;
+ (NSString *)persistLocalValue:(NSString *)value forKey:(NSString *)key;

// Pure transformation used by tests and the atomic file writer below.
+ (NSString *)pairingJsonFromJson:(NSString *)json
                        secretRef:(NSString *)secretRef
                            seeds:(NSArray *)seeds;

// Pairing persistence after the caller has stored mesh.psk in Keychain.
// Removes legacy psk_hex, writes psk_ref, and returns the updated JSON.
+ (NSString *)persistPairingSecretRef:(NSString *)secretRef seeds:(NSArray *)seeds;

// Pure transformation that removes every pairing secret reference from a boot
// profile. Used by "clear pairing" after Core has zeroed its own PSK.
+ (NSString *)unpairedJsonFromJson:(NSString *)json;

// Atomically rewrites boot.json without psk_ref/psk_hex. Returns the new JSON.
+ (NSString *)clearPairingSecretRef;

// Revoke is a factory reset of this device's cluster identity and its local
// setup (spec §5.4): the pairing secret, the mesh seeds, and the operator's
// name/role/door choice all go, and setup_complete returns to false so the
// device comes back up in first-run setup. Pure transformation plus the atomic
// writer that uses it.
+ (NSString *)factoryResetJsonFromJson:(NSString *)json;
+ (NSString *)clearPairingAndSetup;

@end
