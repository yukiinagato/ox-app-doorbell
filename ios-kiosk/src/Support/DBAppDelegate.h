#import <UIKit/UIKit.h>

@interface DBAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;


- (void)diagDump;

// Return to first-run setup after a revocation factory reset (spec §5.4).
// Core, the watchdog, and the recovery client are stopped first so the
// bootstrap branch starts from the same state as a fresh install.
- (void)restartIntoBootstrapSetup;
@end
