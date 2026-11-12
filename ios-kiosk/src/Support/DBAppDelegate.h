#import <UIKit/UIKit.h>

@class DBCameraFeeder;

@interface DBAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;


- (void)diagDump;

// Return to first-run setup after a revocation factory reset (spec §5.4).
// Core, the watchdog, and the recovery client are stopped first so the
// bootstrap branch starts from the same state as a fresh install.
- (void)restartIntoBootstrapSetup;

// Applies a role or door chosen in this device's own settings: boot.json is written first,
// then the same maintenance restart a replicated identity edit takes. Returns NO when the
// identity is invalid or could not be persisted; nothing has changed in that case.
- (BOOL)applyLocalIdentityName:(NSString *)name role:(NSString *)role door:(NSString *)door;

// The one camera session this app owns. The QR scanner borrows it instead of opening a second
// session, which would take the device away from a door station's capture.
- (DBCameraFeeder *)sharedCamera;
@end
