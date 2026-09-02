#import "DBSosSlideModel.h"

const double DBSosArmFraction = 0.90;

@implementation DBSosSlideModel {
  DBSosPhase _phase;
  double _fraction;
  NSInteger _remaining;
  NSInteger _countdownSeconds;
}

@synthesize phase = _phase;
@synthesize fraction = _fraction;
@synthesize remainingSeconds = _remaining;

- (id)init {
  self = [super init];
  if (self) {
    _phase = DBSosPhaseIdle;
    _countdownSeconds = 3;
  }
  return self;
}

- (NSInteger)countdownSeconds {
  return _countdownSeconds;
}

- (void)setCountdownSeconds:(NSInteger)seconds {
  _countdownSeconds = MAX(0, MIN(10, seconds));
}

- (void)configureFromConfig:(NSDictionary *)config {
  id emergency = [config isKindOfClass:[NSDictionary class]]
      ? [config objectForKey:@"emergency"] : nil;
  id trigger = [emergency isKindOfClass:[NSDictionary class]]
      ? [(NSDictionary *)emergency objectForKey:@"trigger"] : nil;
  id seconds = [trigger isKindOfClass:[NSDictionary class]]
      ? [(NSDictionary *)trigger objectForKey:@"countdown_s"] : nil;
  if ([seconds isKindOfClass:[NSNumber class]])
    [self setCountdownSeconds:[(NSNumber *)seconds integerValue]];
  else
    [self setCountdownSeconds:3];
}

- (void)beginTouch {
  if (_phase == DBSosPhaseCountdown || _phase == DBSosPhaseFired) return;
  _phase = DBSosPhaseSliding;
  _fraction = 0;
}

- (void)updateFraction:(double)fraction {
  if (_phase != DBSosPhaseSliding) return;
  if (fraction < 0) fraction = 0;
  if (fraction > 1) fraction = 1;
  _fraction = fraction;
}

- (BOOL)endTouch {
  if (_phase != DBSosPhaseSliding) return NO;
  if (_fraction < DBSosArmFraction) {
    _phase = DBSosPhaseIdle;
    _fraction = 0;
    return NO;
  }
  _fraction = 1.0;
  if (_countdownSeconds <= 0) {
    _phase = DBSosPhaseFired;
    _remaining = 0;
    return YES;
  }
  _phase = DBSosPhaseCountdown;
  _remaining = _countdownSeconds;
  return YES;
}

- (BOOL)tick {
  if (_phase != DBSosPhaseCountdown) return NO;
  if (_remaining > 0) _remaining--;
  if (_remaining > 0) return NO;
  _phase = DBSosPhaseFired;
  return YES;
}

- (BOOL)cancel {
  if (_phase != DBSosPhaseCountdown && _phase != DBSosPhaseSliding) return NO;
  BOOL cancelled = (_phase == DBSosPhaseCountdown);
  [self reset];
  return cancelled;
}

- (void)reset {
  _phase = DBSosPhaseIdle;
  _fraction = 0;
  _remaining = 0;
}

@end
