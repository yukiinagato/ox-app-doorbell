#import "DBBackoffPolicy.h"

static const NSTimeInterval kDBBackoffScheduleS[] = { 1.0, 2.0, 5.0, 10.0 };
static const NSUInteger kDBBackoffScheduleCount =
    sizeof(kDBBackoffScheduleS) / sizeof(kDBBackoffScheduleS[0]);

@implementation DBBackoffPolicy {
  NSUInteger _attempt;
}

@synthesize attempt = _attempt;

+ (NSTimeInterval)delayForAttempt:(NSUInteger)attempt {
  if (attempt >= kDBBackoffScheduleCount)
    return kDBBackoffScheduleS[kDBBackoffScheduleCount - 1];
  return kDBBackoffScheduleS[attempt];
}

- (NSTimeInterval)nextDelay {
  NSTimeInterval delay = [[self class] delayForAttempt:_attempt];
  // Saturate instead of wrapping; the delay is already capped.
  if (_attempt < NSUIntegerMax) _attempt++;
  return delay;
}

- (void)reset {
  _attempt = 0;
}

@end
