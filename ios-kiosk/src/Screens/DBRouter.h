#import <UIKit/UIKit.h>
#import "../Media/DBSipSession.h"
#import "../Media/DBSipListener.h"

@class DBCoreBridge, DBBootConfig, DBTexts, DBScreen, DBHomeScreen, DBDoorScreen,
       DBIncomingScreen, DBSettingsScreen, DBHistoryScreen, DBPairingScreen;


// Main-thread screen state machine and sole owner of the active SIP session. Screens are retained
// for the application lifetime and transitions use addSubview/removeFromSuperview instead of the
// fragile iOS 5 modal controller path.

@interface DBRouter : NSObject <DBMiniSipDelegate, DBMiniSipListenerDelegate>

@property(nonatomic, readonly) UIView *containerView;
@property(nonatomic, readonly) DBCoreBridge *core;
@property(nonatomic, readonly) DBBootConfig *boot;
@property(nonatomic, readonly) DBTexts *texts;
@property(nonatomic, readonly) DBHomeScreen *home;
@property(nonatomic, readonly) DBDoorScreen *door;
@property(nonatomic, readonly) DBIncomingScreen *incoming;
@property(nonatomic, readonly) DBPairingScreen *pairing;

- (id)initWithBridge:(DBCoreBridge *)core boot:(DBBootConfig *)boot;
- (void)start;
- (NSString *)currentScreenName;
- (NSString *)effectiveSipBackend;


- (void)showHomeAnimated:(BOOL)animated;
- (void)showIncoming:(NSString *)door purpose:(NSString *)purpose lang:(NSString *)lang
               callID:(NSString *)callID stageRevision:(NSInteger)stageRevision
          expiresAtMs:(long long)expiresAtMs;
- (void)showMonitorPeer:(NSDictionary *)peer;
- (void)closeIncomingAnimated:(BOOL)animated;
- (void)showInfo;
- (void)closeInfoAnimated:(BOOL)animated;

// Native settings (spec §3) and the full-screen call history (spec §5.1).
// Callers gate both behind the admin password on a door station; the indoor
// 管理 entry does the same.
// Debug aid: open one screen by name, bypassing the admin password. The caller
// must have checked that boot.json turned the screenshot hook on.
- (void)showDebugStartScreen:(NSString *)name;

- (void)showSettings;
- (void)closeSettingsAnimated:(BOOL)animated;
- (void)showHistory;
- (void)closeHistoryAnimated:(BOOL)animated;
- (void)showPairing;
- (void)closePairingAnimated:(BOOL)animated;

// "Add a device" panel (spec §5.1). Callers gate it behind the admin password.
- (void)showAddDevice;
- (void)closeAddDeviceAnimated:(BOOL)animated;

// The user chose 「あとで設定」. Onboarding stops re-appearing on its own; the
// Home screen shows the persistent pair.not_set_up_banner instead.
- (void)pairingDeferredByUser;

// Revoke is a factory reset of this device's cluster identity and setup
// (spec §5.4): the Keychain PSK, the boot.json pairing fields, and the
// name/role/door/setup_complete choice all go, then the device returns to
// first-run setup.
- (void)factoryResetForRevocation:(NSString *)reason;


- (void)requestPinThen:(void (^)(void))action;
- (void)dismissPinOverlay;


- (void)sipStart:(NSString *)host port:(int)port mode:(NSString *)mode;
- (void)sipHangup;
- (void)sipSendDtmf:(NSString *)digits;
- (void)sipListenerHangup;

// Drop optional decoder/image state before iOS escalates memory pressure to an
// OOM kill. Active call signalling and safety-critical alarms stay alive.
- (void)releaseMediaForMemoryPressure;
- (void)suspendMediaForBackground;
- (void)resumeMediaAfterBackground;

// Safe mode keeps signalling, SOS, controls, and audio while shedding optional media and effects.
- (void)setSafeMode:(BOOL)enabled reason:(NSString *)reason;


- (void)playLaunchSound;
- (void)playButtonSound;
- (void)playUpdateSound;


// CoreBridge guarantees that events enter here on the main thread.
- (void)onCoreEvent:(NSDictionary *)ev;

@end
