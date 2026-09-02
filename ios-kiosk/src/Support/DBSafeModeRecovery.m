#import "DBSafeModeRecovery.h"

static const NSTimeInterval kHealthyWindow = 600.0;
static const NSTimeInterval kHeartbeatStale = 35.0;

@implementation DBSafeModeRecovery

+ (NSTimeInterval)healthyWindowSeconds { return kHealthyWindow; }
+ (NSTimeInterval)heartbeatStaleSeconds { return kHeartbeatStale; }

+ (BOOL)shouldClearSafeModeEnteredAt:(NSTimeInterval)enteredAt
                     lastHeartbeatAt:(NSTimeInterval)lastHeartbeatAt
                   crashesSinceEntry:(NSUInteger)crashesSinceEntry
                helperSafeModeActive:(BOOL)helperSafeModeActive
                                 now:(NSTimeInterval)now {
  // The root helper owns its own latch; the app never clears it from underneath.
  if (helperSafeModeActive) return NO;
  if (crashesSinceEntry > 0) return NO;
  if (enteredAt <= 0) return NO;
  if (now - enteredAt < kHealthyWindow) return NO;
  // A stalled heartbeat means the window was served by a wedged run loop.
  if (lastHeartbeatAt <= 0) return NO;
  if (now - lastHeartbeatAt > kHeartbeatStale) return NO;
  return YES;
}

+ (NSTimeInterval)remainingSecondsEnteredAt:(NSTimeInterval)enteredAt
                                        now:(NSTimeInterval)now {
  if (enteredAt <= 0) return kHealthyWindow;
  NSTimeInterval remaining = kHealthyWindow - (now - enteredAt);
  return remaining > 0 ? remaining : 0;
}

+ (NSString *)stateForActive:(BOOL)active
                    enteredAt:(NSTimeInterval)enteredAt
              lastHeartbeatAt:(NSTimeInterval)lastHeartbeatAt
            crashesSinceEntry:(NSUInteger)crashesSinceEntry
         helperSafeModeActive:(BOOL)helperSafeModeActive
                          now:(NSTimeInterval)now {
  if (!active) return @"off";
  if (helperSafeModeActive) return @"helper_latched";
  if (crashesSinceEntry > 0) return @"crash_charged";
  if (lastHeartbeatAt <= 0 || now - lastHeartbeatAt > kHeartbeatStale)
    return @"heartbeat_stalled";
  return @"healthy_wait";
}

@end
