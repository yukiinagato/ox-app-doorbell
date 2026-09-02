#import "DBScreen.h"

// "Add a device" panel for a kiosk that is already in a Cluster (spec §5.1).
// Reached from the Home membership line behind the admin password. The iPad 1
// has no camera, so there is no scan action here: only this device's own QR.
@interface DBAddDeviceScreen : DBScreen

- (id)initWithRouter:(DBRouter *)router;
- (void)startPolling;
- (void)stopPolling;
- (void)reload;

// Core events forwarded by the router.
- (void)handleInviteResult:(NSDictionary *)ev;
- (void)handleDeviceJoined:(NSDictionary *)ev;
- (void)handlePendingChanged:(NSDictionary *)ev;
- (void)handlePairingModeChanged:(NSDictionary *)ev;
- (void)handleJoinTokenChanged:(NSDictionary *)ev;
- (void)handlePairingState:(NSDictionary *)ev;

@end
