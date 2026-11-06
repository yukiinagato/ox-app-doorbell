#import "DBScreen.h"

// "Add a device" panel for a kiosk that is already in a Cluster (spec §5.1).
// Reached from the Home membership line behind the admin password. A device with a
// camera (iPad mini) can scan the new device's Add QR; the iPad 1 has none, so it
// shows only this device's own QR and explains why the scan action is missing.
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
// Security protocol v3 events: a peer refused for a reason, and a rotated key.
- (void)handlePeerRejected:(NSDictionary *)ev;
- (void)handleClusterKeyChanged:(NSDictionary *)ev;
// Core's QR decoder: qr_scanned {text, invited} and qr_scan_state {active}.
- (void)handleQrScanned:(NSDictionary *)ev;
- (void)handleQrScanState:(NSDictionary *)ev;
// debug_start_screen "qr_scan": the same path as tapping Scan QR.
- (void)openScannerForDebug;

@end
