#import <Foundation/Foundation.h>

// ARC wrapper for the versioned doorbell-core C ABI. Platform callbacks may
// arrive on Core threads; UI events are always marshalled to the main thread.
// Buffers returned by platform v2 callbacks are malloc-owned and released via
// the registered release_buffer callback.

typedef void (^DBUiEventHandler)(NSDictionary *ev);

@interface DBCoreBridge : NSObject

@property(nonatomic, readonly) BOOL isRunning;

- (BOOL)startWithDataDir:(NSString *)dataDir bootJson:(NSString *)bootJson;
- (void)stop;

// UI event subscription. Handlers run on the main thread; duplicate keys replace the old handler.
- (void)addHandler:(NSString *)key handler:(DBUiEventHandler)handler;
- (void)removeHandler:(NSString *)key;

// Most recently decoded config snapshot. Safe to call from any thread.
- (NSDictionary *)lastConfig;

// Versioned visitor-call API. pressV2 returns the Core-owned call identity used by every update.
- (NSString *)pressV2:(NSString *)door purpose:(NSString *)purpose;
- (BOOL)selectPurposeV2:(NSString *)door callID:(NSString *)callID purpose:(NSString *)purpose;
- (BOOL)cancelCallV2:(NSString *)door callID:(NSString *)callID reason:(NSString *)reason;
- (void)reportCallRecovery:(NSString *)callID restored:(BOOL)restored;
- (BOOL)reportCallAnsweredV2:(NSString *)door callID:(NSString *)callID
               stageRevision:(NSInteger)stageRevision;
- (BOOL)reportCallEndedV2:(NSString *)door callID:(NSString *)callID
             stageRevision:(NSInteger)stageRevision reason:(NSString *)reason;

// One-release compatibility operations.
- (void)press:(NSString *)door;
- (void)pressPurpose:(NSString *)door purpose:(NSString *)purpose;
- (void)cancelCall:(NSString *)door;
- (void)setVisitorLang:(NSString *)door lang:(NSString *)lang;
- (void)quickReply:(NSString *)replyId door:(NSString *)door;
- (BOOL)quickReplyV2:(NSString *)replyId door:(NSString *)door callID:(NSString *)callID
       stageRevision:(NSInteger)stageRevision;
- (BOOL)emergency:(BOOL)active;

// Core/PJSIP adapter used by the formal iOS 9 compatibility profile. The iOS
// 5 profile keeps these calls unused and injects its MiniSIP implementation.
- (void)coreSipCall:(NSString *)target mode:(NSString *)mode;
- (void)coreSipHangup;
- (BOOL)coreSipSendDtmf:(NSString *)digits;

- (NSDictionary *)status;
- (NSDictionary *)debugInfo;
- (NSDictionary *)deviceInfoNow;
- (NSDictionary *)config;

// Merge one shell-owned runtime section and publish the resulting status to
// Core. Values must be JSON objects and must not contain credentials.
- (void)setRuntimeStatusSection:(NSString *)section value:(NSDictionary *)value;

// Merge bounded root runtime fields such as generation and heartbeat. Values
// must be JSON-safe measurements and must not contain credentials.
- (void)setRuntimeStatusValues:(NSDictionary *)values;

// Publish measured shell capabilities and the semantic UI contract. These are
// runtime advertisements, not persisted configuration.
- (void)setRuntimeCapabilities:(NSDictionary *)capabilities;
- (void)setRuntimeCapability:(NSString *)capability enabled:(BOOL)enabled;
- (void)setUIManifest:(NSDictionary *)manifest;

// Store a shell-owned secret through the same Keychain implementation exposed
// to ABI v2. Pairing keys are owned and stored by Core before it emits psk_ref.
- (BOOL)storeSecret:(NSString *)key value:(NSString *)value;
- (NSString *)loadSecret:(NSString *)key;

// Forward one complete Annex-B access unit from an external camera without decoding it on A4.
- (void)submitEncodedFrame:(NSData *)annexB keyframe:(BOOL)keyframe timestampMs:(int64_t)timestampMs;
- (BOOL)trySubmitEncodedFrame:(NSData *)annexB keyframe:(BOOL)keyframe
                   timestampMs:(int64_t)timestampMs;
- (BOOL)videoEncoderWanted;


- (NSDictionary *)pairingInfo;
- (void)joinCluster:(NSString *)host pin:(NSString *)pin;
- (BOOL)foundCluster;
- (void)setPairingMode:(int)seconds;
- (NSDictionary *)startPairingWithSeconds:(int)seconds;
- (void)removeDevice:(NSString *)nodeId;
- (void)inviteDevice:(NSString *)nodeId;
// Short-lived blocklist for one pending device (the "無視" action).
- (void)denyDevice:(NSString *)nodeId;
// Re-runs the failed secure_put. Core emits pairing_state either way.
- (BOOL)retryPairingPersistence;
// Leaves the Cluster: zeroes the PSK, deletes mesh.psk, emits pairing_state.
- (void)unpair;


- (void)chimeFallback;

@end
