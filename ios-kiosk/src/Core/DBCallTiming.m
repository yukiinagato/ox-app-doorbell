#import "DBCallTiming.h"
#import <CoreFoundation/CoreFoundation.h>
#import <mach/mach_time.h>
#import <math.h>

NSTimeInterval DBCallMonotonicTime(void) {
  static mach_timebase_info_data_t timebase;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ mach_timebase_info(&timebase); });
  return (double)mach_absolute_time() * timebase.numer / timebase.denom / 1e9;
}

static NSString *DBTimingString(id value) {
  return [value isKindOfClass:[NSString class]] ? value : @"";
}

static NSNumber *DBTimingMilliseconds(id value) {
  if (![value isKindOfClass:[NSNumber class]] ||
      CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return nil;
  double number = [value doubleValue];
  return isfinite(number) && number >= 0 && number <= 9007199254740991.0 &&
      floor(number) == number ? value : nil;
}

@implementation DBCallTimingSnapshot
- (id)initWithDocument:(NSDictionary *)document coreGeneration:(NSUInteger)generation
           requestedAt:(NSTimeInterval)requestedAt {
  self = [super init];
  if (self) {
    _document = [document copy];
    _coreGeneration = generation;
    _requestedAt = requestedAt;
  }
  return self;
}
@end

@interface DBCallTimingReading ()
@property(nonatomic, readwrite) DBCallTimingDisposition disposition;
@property(nonatomic, readwrite, copy) NSDictionary *call;
@property(nonatomic, readwrite, strong) NSNumber *remainingSeconds;
@property(nonatomic, readwrite, strong) NSNumber *recoveryRemainingSeconds;
@end

@implementation DBCallTimingReading
- (BOOL)mayRestore {
  return [[_call objectForKey:@"recovery_required"] isEqual:@YES] &&
      [[_call objectForKey:@"recovery_eligible"] isEqual:@YES] &&
      [_remainingSeconds doubleValue] > 0 && [_recoveryRemainingSeconds doubleValue] > 0;
}
@end

@implementation DBCallTiming {
  NSArray *_identity;
  NSNumber *_deadline;
  NSNumber *_recoveryDeadline;
  NSArray *_lastSample;
  NSArray *_refreshBaseline;
  NSUInteger _callbackRevision;
}

- (NSArray *)sampleIdentity:(DBCallTimingSnapshot *)snapshot {
  NSString *generation = DBTimingString([snapshot.document objectForKey:@"snapshot_generation"]);
  return [generation length] ? @[@(snapshot.coreGeneration), generation] : nil;
}

- (void)reset {
  _identity = nil;
  _deadline = nil;
  _recoveryDeadline = nil;
}

- (void)requireFreshSnapshot:(DBCallTimingSnapshot *)snapshot {
  if (!_waitingForFreshSnapshot) _refreshBaseline = [self sampleIdentity:snapshot] ?: _lastSample;
  _waitingForFreshSnapshot = YES;
  [self reset];
  [self invalidateCallbacks];
}

- (BOOL)acceptsSnapshot:(DBCallTimingSnapshot *)snapshot {
  NSArray *sample = [self sampleIdentity:snapshot];
  if (!sample || !isfinite(snapshot.requestedAt) ||
      !DBTimingMilliseconds([snapshot.document objectForKey:@"snapshot_age_ms"]) ||
      ![[snapshot.document objectForKey:@"active_calls"] isKindOfClass:[NSArray class]]) return NO;
  _lastSample = sample;
  if (_waitingForFreshSnapshot) {
    if (!_refreshBaseline) { _refreshBaseline = sample; return NO; }
    if ([_refreshBaseline isEqual:sample]) return NO;
    _waitingForFreshSnapshot = NO;
    _refreshBaseline = nil;
  }
  return YES;
}

- (DBCallTimingReading *)observeRecoverySnapshot:(DBCallTimingSnapshot *)snapshot
                                         callID:(NSString *)callID role:(NSString *)role
                                         nodeID:(NSString *)nodeID door:(NSString *)door
                                            now:(NSTimeInterval)now {
  if ([nodeID length] && [[snapshot.document objectForKey:@"active_calls"] isKindOfClass:[NSArray class]]) {
    for (id call in [snapshot.document objectForKey:@"active_calls"]) {
      if (![call isKindOfClass:[NSDictionary class]] ||
          ![DBTimingString([call objectForKey:@"call_id"]) isEqualToString:callID]) continue;
      NSString *state = DBTimingString([call objectForKey:@"state"]);
      BOOL ownsDialog = [state isEqualToString:@"in_call"] &&
          [DBTimingString([call objectForKey:@"dialog_owner"]) isEqualToString:nodeID];
      BOOL ownsWaiting = [state isEqualToString:@"ringing"] && [role isEqualToString:@"door_station"] &&
          [DBTimingString([call objectForKey:@"origin"]) isEqualToString:nodeID] &&
          [DBTimingString([call objectForKey:@"door"]) isEqualToString:door];
      if (ownsDialog || ownsWaiting)
        return [self observeSnapshot:snapshot callID:callID
            door:DBTimingString([call objectForKey:@"door"]) now:now];
      break;
    }
  }
  return [[DBCallTimingReading alloc] init];
}

- (DBCallTimingReading *)observeSnapshot:(DBCallTimingSnapshot *)snapshot
                                 callID:(NSString *)callID door:(NSString *)door
                                    now:(NSTimeInterval)now {
  DBCallTimingReading *reading = [[DBCallTimingReading alloc] init];
  if (![self acceptsSnapshot:snapshot] || ![callID length] || !isfinite(now) ||
      now < snapshot.requestedAt) return reading;
  NSDictionary *call = nil;
  for (id candidate in [snapshot.document objectForKey:@"active_calls"]) {
    if (![candidate isKindOfClass:[NSDictionary class]]) return reading;
    if ([DBTimingString([candidate objectForKey:@"call_id"]) isEqualToString:callID] &&
        [DBTimingString([candidate objectForKey:@"door"]) isEqualToString:door]) call = candidate;
  }
  if (!call) { [self reset]; reading.disposition = DBCallTimingAbsent; return reading; }
  NSString *sample = DBTimingString([snapshot.document objectForKey:@"snapshot_generation"]);
  NSString *state = DBTimingString([call objectForKey:@"state"]);
  NSNumber *revision = DBTimingMilliseconds([call objectForKey:@"stage_revision"]);
  if (![DBTimingString([call objectForKey:@"snapshot_generation"]) isEqual:sample] ||
      !revision || (![state isEqualToString:@"ringing"] && ![state isEqualToString:@"in_call"]))
    return reading;
  NSArray *identity = @[@(snapshot.coreGeneration), sample, callID, door ?: @"", revision,
      DBTimingString([call objectForKey:@"dialog_owner"]), state];
  double age = [[snapshot.document objectForKey:@"snapshot_age_ms"] doubleValue];
  NSNumber *remaining = DBTimingMilliseconds([call objectForKey:@"remaining_ms"]);
  NSNumber *recovery = DBTimingMilliseconds([call objectForKey:@"recovery_remaining_ms"]);
  if ([recovery doubleValue] > 10000) recovery = nil;
  NSNumber *deadline = remaining ? @(snapshot.requestedAt + MAX(0, [remaining doubleValue] - age) / 1000) : nil;
  NSNumber *recoveryDeadline = recovery ? @(snapshot.requestedAt + MAX(0, [recovery doubleValue] - age) / 1000) : nil;
  if ([_identity isEqual:identity]) {
    if (deadline) _deadline = _deadline ? @(MIN([_deadline doubleValue], [deadline doubleValue])) : deadline;
    if (recoveryDeadline) _recoveryDeadline = _recoveryDeadline ?
        @(MIN([_recoveryDeadline doubleValue], [recoveryDeadline doubleValue])) : recoveryDeadline;
  } else {
    _identity = identity;
    _deadline = deadline;
    _recoveryDeadline = recoveryDeadline;
  }
  reading.disposition = DBCallTimingActive;
  reading.call = call;
  reading.remainingSeconds = deadline ? @(MAX(0, [_deadline doubleValue] - now)) : nil;
  reading.recoveryRemainingSeconds = recoveryDeadline ? @(MAX(0, [_recoveryDeadline doubleValue] - now)) : nil;
  return reading;
}

- (void)invalidateCallbacks { ++_callbackRevision; }

- (NSDictionary *)callbackForCall:(NSString *)callID coreGeneration:(NSUInteger)generation {
  return @{@"revision": @(_callbackRevision), @"core": @(generation), @"call": callID ?: @""};
}

- (BOOL)acceptsCallback:(NSDictionary *)callback callID:(NSString *)callID
         coreGeneration:(NSUInteger)generation {
  return [callback isEqual:[self callbackForCall:callID coreGeneration:generation]];
}
@end
