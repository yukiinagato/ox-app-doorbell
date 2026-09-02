#import "DBCallReturnCountdown.h"

static const NSInteger kDefaultReturnSeconds = 60;

@implementation DBCallReturnCountdown {
  NSInteger _remaining;
  NSInteger _fullSeconds;
  BOOL _running;
  BOOL _paused;
  BOOL _cancelled;
  BOOL _fired;
}

@synthesize remaining = _remaining;
@synthesize fullSeconds = _fullSeconds;
@synthesize isCancelledByUser = _cancelled;
@synthesize isPaused = _paused;

- (id)init {
  self = [super init];
  if (self) _fullSeconds = kDefaultReturnSeconds;
  return self;
}

+ (NSInteger)defaultSeconds { return kDefaultReturnSeconds; }

+ (NSInteger)secondsFromStatus:(NSDictionary *)status {
  id call = [status isKindOfClass:[NSDictionary class]]
      ? [status objectForKey:@"call"] : nil;
  id value = [call isKindOfClass:[NSDictionary class]]
      ? [(NSDictionary *)call objectForKey:@"return_s"] : nil;
  if (![value isKindOfClass:[NSNumber class]]) return kDefaultReturnSeconds;
  NSInteger seconds = [(NSNumber *)value integerValue];
  // A core that reports nothing usable keeps the documented default rather
  // than a page that never returns or returns instantly.
  if (seconds <= 0 || seconds > 3600) return kDefaultReturnSeconds;
  return seconds;
}

- (BOOL)isVisible {
  return _running && !_paused && !_cancelled;
}

- (void)startWithSeconds:(NSInteger)seconds {
  _fullSeconds = (seconds > 0 && seconds <= 3600) ? seconds : kDefaultReturnSeconds;
  _remaining = _fullSeconds;
  _running = YES;
  _paused = NO;
  _cancelled = NO;
  _fired = NO;
}

- (BOOL)tick {
  if (!_running || _paused || _cancelled || _fired) return NO;
  if (_remaining > 0) _remaining--;
  if (_remaining > 0) return NO;
  _fired = YES;
  _running = NO;
  return YES;
}

- (BOOL)cancelByUser {
  if (!_running || _cancelled) return NO;
  _cancelled = YES;
  _running = NO;
  return YES;
}

- (void)pauseForAnsweredCall {
  if (_cancelled) return;
  _paused = YES;
}

- (void)resumeAfterCall {
  if (_cancelled) return;
  // The resident has just finished talking; they get the whole window again,
  // not whatever was left when the call started.
  _remaining = _fullSeconds;
  _running = YES;
  _paused = NO;
  _fired = NO;
}

- (void)reset {
  _remaining = 0;
  _running = NO;
  _paused = NO;
  _cancelled = NO;
  _fired = NO;
}

@end
