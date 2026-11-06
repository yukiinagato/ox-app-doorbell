#import <UIKit/UIKit.h>

@class DBCoreBridge;
@class DBTexts;

// Full-screen "scan the new device's Add QR" overlay for the kiosk (spec §5.1 item 4).
//
// The overlay borrows the app's one camera session (a second session would take the device
// away from a door station). On iOS 7+ it adds AVFoundation's own QR detector to that session
// and invites the doorbell-pair: payload it reads. iOS 5/6 have no such detector, so there
// Core's decoder reads the frames the session already pushes and invites by itself. The camera
// is handed back as it was found: a door station keeps its visitor lens, an indoor panel's
// camera is stopped again.
@interface DBQrScanOverlay : UIView

- (id)initWithCore:(DBCoreBridge *)core texts:(DBTexts *)texts;

// Called once: with the invited device's id and address when a pairing QR was read and Core sent
// the invite, or with nil arguments when the user closed the scanner.
@property(nonatomic, copy) void (^onFinished)(NSString *invitedId, NSString *invitedAddr);

- (void)presentInView:(UIView *)host;
- (void)dismiss;

// Core events forwarded by the add-device screen.
- (void)handleQrScanned:(NSDictionary *)ev;
- (void)handleQrScanState:(NSDictionary *)ev;

// YES when this device has any camera at all (the iPad 1 has none).
+ (BOOL)cameraAvailable;

// "doorbell-pair:<addr>|<id>|<pk>" -> @{addr,id,pk}, or nil for any other text.
+ (NSDictionary *)parsePairPayload:(NSString *)text;

@end
