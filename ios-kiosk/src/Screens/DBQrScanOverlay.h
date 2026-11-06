#import <UIKit/UIKit.h>

@class DBCoreBridge;
@class DBTexts;

// Full-screen "scan the new device's Add QR" overlay for the kiosk (spec §5.1 item 4).
//
// iOS 5 has no AVFoundation QR detection, so nothing is decoded here: the app's one camera
// session keeps pushing frames to Core and Core's own decoder reads them, exactly as on Android.
// A decoded doorbell-pair: payload is invited by Core itself. The overlay only owns the preview,
// the viewfinder and the messages, and it gives the camera back in the state it found it: a door
// station keeps capturing, an indoor panel's camera is stopped again.
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

// "doorbell-pair:<addr>|<id>|<pk>" -> @{addr,id}, or nil for any other text.
+ (NSDictionary *)parsePairPayload:(NSString *)text;

@end
