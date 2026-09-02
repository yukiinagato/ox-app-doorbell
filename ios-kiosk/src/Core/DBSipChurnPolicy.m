#import "DBSipChurnPolicy.h"

@implementation DBSipChurnPolicy {
  NSUInteger _churnCount;
  NSTimeInterval _lastEmptyAt;
  BOOL _logPending;
}

@synthesize churnCount = _churnCount;

+ (NSTimeInterval)emptyDialogSeconds { return 1.0; }
+ (NSTimeInterval)churnWindowSeconds { return 10.0; }

+ (NSTimeInterval)delayForChurnCount:(NSUInteger)churnCount {
  switch (churnCount) {
    case 0: return 0.15;
    case 1: return 0.15;
    case 2: return 0.5;
    case 3: return 1.0;
    case 4: return 2.0;
    default: return 3.0;
  }
}

- (NSTimeInterval)delayAfterDialogWithDuration:(NSTimeInterval)durationS
                                    rtpPackets:(unsigned long)rtpPackets
                                            at:(NSTimeInterval)now {
  BOOL empty = (rtpPackets == 0) && (durationS < [[self class] emptyDialogSeconds]);
  if (!empty) {
    // A real dialog clears the record: a door that is actually being monitored
    // must never be slowed down.
    [self reset];
    return [[self class] delayForChurnCount:0];
  }
  if (_lastEmptyAt > 0 && (now - _lastEmptyAt) > [[self class] churnWindowSeconds])
    _churnCount = 0;
  _lastEmptyAt = now;
  _churnCount++;
  if (_churnCount == 3) _logPending = YES;  // Once, when spacing begins.
  return [[self class] delayForChurnCount:_churnCount];
}

- (BOOL)consumeChurnLogRequest {
  BOOL pending = _logPending;
  _logPending = NO;
  return pending;
}

- (void)reset {
  _churnCount = 0;
  _lastEmptyAt = 0;
  _logPending = NO;
}

@end
