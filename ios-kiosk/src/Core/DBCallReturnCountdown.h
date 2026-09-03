#import <Foundation/Foundation.h>

// The indoor incoming page returns to the dashboard on its own (batch 3).
//
// The title carries a "(60)" suffix counting down from status.call.return_s.
// Reaching zero returns to the dashboard. Three rules matter more than the
// timer itself:
//   - A visitor cancelling the call does NOT close the page. The resident may
//     still be looking at the live view, so only the countdown, or the
//     resident, ends it.
//   - Tapping the number cancels the countdown for good: the suffix goes and
//     the page stays until the resident leaves.
//   - Answering pauses it. The suffix is hidden while talking and the full
//     value starts again when the call ends.
@interface DBCallReturnCountdown : NSObject

// Seconds still to run; meaningless unless isVisible.
@property(nonatomic, readonly) NSInteger remaining;
// The configured full value this countdown restarts from.
@property(nonatomic, readonly) NSInteger fullSeconds;
// YES while the suffix should be drawn.
@property(nonatomic, readonly) BOOL isVisible;
// YES once the resident has cancelled it; sticky until the next start.
@property(nonatomic, readonly) BOOL isCancelledByUser;
// YES while an answered call holds it.
@property(nonatomic, readonly) BOOL isPaused;

// status.call.return_s, or the documented default when core does not report it.
+ (NSInteger)secondsFromStatus:(NSDictionary *)status;
+ (NSInteger)defaultSeconds;  // 60

// Begins, or begins again, at the full value. Clears cancel and pause.
- (void)startWithSeconds:(NSInteger)seconds;
// One second elapsed. YES exactly once, when it reaches zero.
- (BOOL)tick;
// The resident tapped the number. YES when something was actually cancelled.
- (BOOL)cancelByUser;
// The call was answered.
- (void)pauseForAnsweredCall;
// The answered call ended: the full value starts again unless the resident
// already cancelled it.
- (void)resumeAfterCall;
- (void)reset;

@end
