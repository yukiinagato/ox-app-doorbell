#import <Foundation/Foundation.h>

// Slide-to-trigger SOS state machine (batch-2 spec §4.4, §0.10).
// Sliding past 90 % arms a cancellable countdown; only reaching zero is a real
// emergency, so the shell calls Core exactly once, at that moment.
typedef enum {
  DBSosPhaseIdle = 0,
  DBSosPhaseSliding,
  DBSosPhaseCountdown,
  DBSosPhaseFired
} DBSosPhase;

FOUNDATION_EXPORT const double DBSosArmFraction;  // 0.90

@interface DBSosSlideModel : NSObject

@property(nonatomic, readonly) DBSosPhase phase;
@property(nonatomic, readonly) double fraction;          // 0..1 travel of the thumb
@property(nonatomic, readonly) NSInteger remainingSeconds;
// emergency.trigger.countdown_s, clamped to 0..10. Zero fires on release.
@property(nonatomic, assign) NSInteger countdownSeconds;

- (void)configureFromConfig:(NSDictionary *)config;

- (void)beginTouch;
- (void)updateFraction:(double)fraction;
// Returns YES when releasing armed the countdown or fired immediately.
- (BOOL)endTouch;
// One second elapsed. Returns YES exactly once, when the countdown reaches zero.
- (BOOL)tick;
// A tap during the countdown cancels it. Returns YES when something was cancelled.
- (BOOL)cancel;
- (void)reset;

@end
