#import <Foundation/Foundation.h>

// Back-pressure for the door station's SIP listener.
//
// Device evidence (iPad 1, 2026-09-03): the listener logged
//   "[sip-uas] dialog ended mode=monitor RTP tx=0 rx=0" -> "[sip-uas] listening UDP 47190"
// about 1.5 times a second for minutes on end. Every one of those cycles posts
// two state deliveries to the main thread, and each delivery publishes runtime
// status into core and re-themes the visitor screen. Core's serial queue
// saturated, the main thread blocked on it, the runtime heartbeat stopped, and
// core's HTTP handlers timed out until port 47180 refused connections while the
// mesh port stayed up. Accepting an empty dialog every 150 ms is what turned a
// misbehaving peer into a wedged device.
//
// A dialog that carried audio, or that lasted long enough to be real, costs
// nothing. Repeated empty dialogs are spaced out.
@interface DBSipChurnPolicy : NSObject

// Consecutive empty dialogs since the last real one.
@property(nonatomic, readonly) NSUInteger churnCount;

// Seconds to wait before listening again. durationS is how long the dialog
// lasted and rtpPackets is tx + rx.
- (NSTimeInterval)delayAfterDialogWithDuration:(NSTimeInterval)durationS
                                    rtpPackets:(unsigned long)rtpPackets
                                            at:(NSTimeInterval)now;

// YES once, on the cycle where the policy first starts spacing dialogs out, so
// the log records the condition instead of two lines per dialog.
- (BOOL)consumeChurnLogRequest;

- (void)reset;

// Pure schedule, for tests and logs: 0.15, 0.5, 1, 2, then 3 seconds.
+ (NSTimeInterval)delayForChurnCount:(NSUInteger)churnCount;
// A dialog this short with no audio is not a real call.
+ (NSTimeInterval)emptyDialogSeconds;   // 1.0
// Consecutive empty dialogs must fall inside this window to count as churn.
+ (NSTimeInterval)churnWindowSeconds;   // 10.0

@end
