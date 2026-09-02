#import <Foundation/Foundation.h>

// Local safe-mode auto-clear policy.
//
// Follow-up from docs/evidence/ios5-ipad1-keepalive-helper-qualification-2026-09-02.md:
// three unclean exits in five minutes latch the kiosk's local safe mode, which
// disables every H.264 strategy. The old recovery was a bare five-minute
// dispatch_after that neither required an alive main run loop nor survived a
// restart, so a panel could stay MJPEG-only indefinitely. The window is now ten
// minutes of measured health: the runtime heartbeat must keep advancing, no new
// crash may be charged, and the root helper must not be in safe mode itself.
@interface DBSafeModeRecovery : NSObject

+ (NSTimeInterval)healthyWindowSeconds;   // 600
+ (NSTimeInterval)heartbeatStaleSeconds;  // 35 (three 10 s heartbeats plus slack)

// Pure decision, shared by the app delegate and the host tests.
+ (BOOL)shouldClearSafeModeEnteredAt:(NSTimeInterval)enteredAt
                     lastHeartbeatAt:(NSTimeInterval)lastHeartbeatAt
                   crashesSinceEntry:(NSUInteger)crashesSinceEntry
                helperSafeModeActive:(BOOL)helperSafeModeActive
                                 now:(NSTimeInterval)now;

// Seconds still to serve, clamped to zero. Used by the 本機情報 state line.
+ (NSTimeInterval)remainingSecondsEnteredAt:(NSTimeInterval)enteredAt
                                        now:(NSTimeInterval)now;

// Machine-readable state for status publication and 本機情報:
// "off", "healthy_wait", "heartbeat_stalled", "crash_charged", "helper_latched".
+ (NSString *)stateForActive:(BOOL)active
                    enteredAt:(NSTimeInterval)enteredAt
              lastHeartbeatAt:(NSTimeInterval)lastHeartbeatAt
            crashesSinceEntry:(NSUInteger)crashesSinceEntry
         helperSafeModeActive:(BOOL)helperSafeModeActive
                          now:(NSTimeInterval)now;

@end
