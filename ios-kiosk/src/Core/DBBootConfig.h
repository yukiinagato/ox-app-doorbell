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

// Pure transformation used by tests and the atomic file writer below.
+ (NSString *)pairingJsonFromJson:(NSString *)json
                        secretRef:(NSString *)secretRef
                            seeds:(NSArray *)seeds;

// Pairing persistence after the caller has stored mesh.psk in Keychain.
// Removes legacy psk_hex, writes psk_ref, and returns the updated JSON.
+ (NSString *)persistPairingSecretRef:(NSString *)secretRef seeds:(NSArray *)seeds;

@end
