#import "DBCallEventTracker.h"
#import "DBCallTiming.h"
#import <math.h>

static const NSUInteger kDBCallCacheLimit = 128;

static NSString *DBEventString(NSDictionary *event, NSString *key) {
  id value = [event objectForKey:key];
  return [value isKindOfClass:[NSString class]] ? value : @"";
}

static NSNumber *DBEventNumber(NSDictionary *event, NSString *key) {
  id value = [event objectForKey:key];
  return [value isKindOfClass:[NSNumber class]] ? value : nil;
}

@implementation DBCallEventTracker {
  NSString *_currentCallID;
  NSMutableDictionary *_callDataByID;
  NSMutableArray *_callDataOrder;
  NSMutableDictionary *_acceptedRevisionByID;
  NSMutableArray *_acceptedOrder;
  NSMutableDictionary *_resolvedCallIDs;
  NSMutableArray *_resolvedOrder;
  NSMutableDictionary *_supersededIdleByID;
  NSMutableArray *_supersededIdleOrder;
  NSMutableDictionary *_pendingChimes;
  NSMutableArray *_pendingChimeOrder;
}

@synthesize currentCallID = _currentCallID;

- (id)init {
  self = [super init];
  if (self) {
    _callDataByID = [[NSMutableDictionary alloc] init];
    _callDataOrder = [[NSMutableArray alloc] init];
    _acceptedRevisionByID = [[NSMutableDictionary alloc] init];
    _acceptedOrder = [[NSMutableArray alloc] init];
    _resolvedCallIDs = [[NSMutableDictionary alloc] init];
    _resolvedOrder = [[NSMutableArray alloc] init];
    _supersededIdleByID = [[NSMutableDictionary alloc] init];
    _supersededIdleOrder = [[NSMutableArray alloc] init];
    _pendingChimes = [[NSMutableDictionary alloc] init];
    _pendingChimeOrder = [[NSMutableArray alloc] init];
  }
  return self;
}

- (void)trimMap:(NSMutableDictionary *)map order:(NSMutableArray *)order {
  while ([order count] > kDBCallCacheLimit) {
    NSString *oldest = [order objectAtIndex:0];
    [order removeObjectAtIndex:0];
    [map removeObjectForKey:oldest];
  }
}

- (BOOL)recordCallEvent:(NSDictionary *)event {
  if (![event isKindOfClass:[NSDictionary class]]) return NO;
  NSString *type = DBEventString(event, @"type");
  if (![type isEqualToString:@"press"] && ![type isEqualToString:@"purpose_selected"])
    return NO;
  NSString *callID = DBEventString(event, @"call_id");
  if ([callID length] == 0) return NO;

  NSDictionary *old = [_callDataByID objectForKey:callID];
  NSNumber *oldRevision = DBEventNumber(old, @"stage_revision");
  NSNumber *newRevision = DBEventNumber(event, @"stage_revision");
  if (oldRevision && newRevision &&
      [newRevision longLongValue] <= [oldRevision longLongValue])
    return NO;

  NSDictionary *resolution = [_resolvedCallIDs objectForKey:callID];
  NSString *resolutionType = DBEventString(resolution, @"type");
  if ([resolutionType isEqualToString:@"call_cancelled"] ||
      [resolutionType isEqualToString:@"call_ended"])
    return NO;
  NSNumber *resolvedRevision = DBEventNumber(resolution, @"stage_revision");
  if ([type isEqualToString:@"purpose_selected"] &&
      [resolutionType isEqualToString:@"call_answered"] && newRevision &&
      (!resolvedRevision || [newRevision longLongValue] > [resolvedRevision longLongValue])) {
    [_resolvedCallIDs removeObjectForKey:callID];
    [_resolvedOrder removeObject:callID];
    [_supersededIdleByID setObject:newRevision forKey:callID];
    if (![_supersededIdleOrder containsObject:callID])
      [_supersededIdleOrder addObject:callID];
    [self trimMap:_supersededIdleByID order:_supersededIdleOrder];
  }

  NSMutableDictionary *merged = old ? [old mutableCopy] : [NSMutableDictionary dictionary];
  for (NSString *key in @[
         @"door", @"purpose", @"visitor_lang", @"stage_revision", @"expires_at_ms"
       ]) {
    id value = [event objectForKey:key];
    if (value != nil && value != [NSNull null]) [merged setObject:value forKey:key];
  }
  [_callDataByID setObject:merged forKey:callID];
  if (![_callDataOrder containsObject:callID]) [_callDataOrder addObject:callID];
  [self trimMap:_callDataByID order:_callDataOrder];
  return YES;
}

- (void)recordCancellationEvent:(NSDictionary *)event {
  if (![event isKindOfClass:[NSDictionary class]]) return;
  NSString *callID = DBEventString(event, @"call_id");
  if ([callID length] == 0) return;
  NSNumber *revision = DBEventNumber(event, @"stage_revision") ?: @0;
  [_resolvedCallIDs setObject:@{ @"type" : @"call_cancelled",
                                 @"stage_revision" : revision } forKey:callID];
  if (![_resolvedOrder containsObject:callID]) [_resolvedOrder addObject:callID];
  [self trimMap:_resolvedCallIDs order:_resolvedOrder];
  [_callDataByID removeObjectForKey:callID];
  [_callDataOrder removeObject:callID];
  [_supersededIdleByID removeObjectForKey:callID];
  [_supersededIdleOrder removeObject:callID];
}

- (BOOL)recordLifecycleEvent:(NSDictionary *)event type:(NSString *)expectedType
                clearCurrent:(BOOL)clearCurrent {
  if (![event isKindOfClass:[NSDictionary class]]) return NO;
  NSString *type = DBEventString(event, @"type");
  NSNumber *schema = DBEventNumber(event, @"schema_version");
  NSString *callID = DBEventString(event, @"call_id");
  if (![type isEqualToString:expectedType] || !schema || [schema integerValue] < 2 ||
      [callID length] == 0) return NO;
  NSNumber *revision = DBEventNumber(event, @"stage_revision") ?: @0;
  NSNumber *cachedRevision = DBEventNumber([_callDataByID objectForKey:callID],
                                           @"stage_revision");
  if (cachedRevision && [revision longLongValue] < [cachedRevision longLongValue]) return NO;
  NSDictionary *existing = [_resolvedCallIDs objectForKey:callID];
  NSNumber *existingRevision = DBEventNumber(existing, @"stage_revision");
  if ([DBEventString(existing, @"type") isEqualToString:expectedType] && existingRevision &&
      [revision longLongValue] <= [existingRevision longLongValue])
    return NO;
  BOOL matches = [_currentCallID length] > 0 && [callID isEqualToString:_currentCallID];
  [_resolvedCallIDs setObject:@{ @"type" : expectedType,
                                 @"stage_revision" : revision } forKey:callID];
  if (![_resolvedOrder containsObject:callID]) [_resolvedOrder addObject:callID];
  [self trimMap:_resolvedCallIDs order:_resolvedOrder];
  if (![expectedType isEqualToString:@"call_answered"]) {
    [_callDataByID removeObjectForKey:callID];
    [_callDataOrder removeObject:callID];
  }
  [_supersededIdleByID removeObjectForKey:callID];
  [_supersededIdleOrder removeObject:callID];
  if (matches && clearCurrent) _currentCallID = nil;
  return matches;
}

- (BOOL)recordAnsweredEvent:(NSDictionary *)event {
  return [self recordLifecycleEvent:event type:@"call_answered" clearCurrent:NO];
}

- (BOOL)recordEndedEvent:(NSDictionary *)event {
  return [self recordLifecycleEvent:event type:@"call_ended" clearCurrent:YES];
}

- (BOOL)consumeSupersededIdleForCurrentCall {
  if ([_currentCallID length] == 0 ||
      ![_supersededIdleByID objectForKey:_currentCallID]) return NO;
  [_supersededIdleByID removeObjectForKey:_currentCallID];
  [_supersededIdleOrder removeObject:_currentCallID];
  return YES;
}

- (NSDictionary *)acceptChimeEvent:(NSDictionary *)event nowMs:(long long)nowMs {
  return [self acceptChimeEvent:event nowMs:nowMs coreDeadlineValidated:NO];
}

- (NSDictionary *)normalizedChimeEvent:(NSDictionary *)event {
  if (![event isKindOfClass:[NSDictionary class]]) return nil;
  NSString *callID = DBEventString(event, @"call_id");
  if (![callID length]) return nil;
  NSMutableDictionary *normalized = [NSMutableDictionary dictionary];
  NSDictionary *cached = [_callDataByID objectForKey:callID];
  for (NSString *key in @[@"door", @"purpose", @"visitor_lang", @"stage_revision", @"expires_at_ms"]) {
    id value = [cached objectForKey:key];
    if (value && value != [NSNull null]) [normalized setObject:value forKey:key];
  }
  [normalized addEntriesFromDictionary:event];
  return normalized;
}

- (NSUInteger)pendingChimeCount { return [_pendingChimes count]; }

- (BOOL)queueChimeEvent:(NSDictionary *)event coreGeneration:(NSUInteger)generation
                   now:(NSTimeInterval)now {
  NSDictionary *normalized = [self normalizedChimeEvent:event];
  NSString *callID = DBEventString(normalized, @"call_id");
  NSNumber *revision = DBEventNumber(normalized, @"stage_revision");
  if (!isfinite(now) || !generation || [DBEventNumber(normalized, @"schema_version") integerValue] < 2 ||
      ![DBEventString(normalized, @"door") length] || !revision || [revision longLongValue] < 0)
    return NO;
  NSNumber *accepted = [_acceptedRevisionByID objectForKey:callID];
  if (accepted && [revision longLongValue] <= [accepted longLongValue]) return NO;
  NSDictionary *pending = [_pendingChimes objectForKey:callID];
  if (pending && [[pending objectForKey:@"core"] unsignedIntegerValue] == generation &&
      [revision longLongValue] <= [DBEventNumber([pending objectForKey:@"event"], @"stage_revision") longLongValue])
    return NO;
  [_pendingChimeOrder removeObject:callID];
  [_pendingChimes setObject:[@{@"event": normalized, @"core": @(generation),
      @"deadline": @(now + 10), @"timing": [[DBCallTiming alloc] init]} mutableCopy] forKey:callID];
  [_pendingChimeOrder addObject:callID];
  [self trimMap:_pendingChimes order:_pendingChimeOrder];
  return YES;
}

- (void)requireFreshChimeSnapshot:(DBCallTimingSnapshot *)snapshot {
  for (NSDictionary *pending in [_pendingChimes allValues])
    [[pending objectForKey:@"timing"] requireFreshSnapshot:snapshot];
}

- (NSArray *)takeReadyChimesFromSnapshot:(DBCallTimingSnapshot *)snapshot
                         coreGeneration:(NSUInteger)generation now:(NSTimeInterval)now {
  NSMutableArray *ready = [NSMutableArray array];
  for (NSString *callID in [_pendingChimeOrder copy]) {
    NSMutableDictionary *pending = [_pendingChimes objectForKey:callID];
    NSDictionary *event = [pending objectForKey:@"event"];
    NSString *resolved = DBEventString([_resolvedCallIDs objectForKey:callID], @"type");
    BOOL remove = !isfinite(now) || now >= [[pending objectForKey:@"deadline"] doubleValue] ||
        generation != [[pending objectForKey:@"core"] unsignedIntegerValue] ||
        [resolved isEqualToString:@"call_cancelled"] || [resolved isEqualToString:@"call_ended"];
    NSString *sample = DBEventString(snapshot.document, @"snapshot_generation");
    if (!remove && snapshot.coreGeneration == generation && [sample length] &&
        ![[pending objectForKey:@"sample"] isEqual:sample]) {
      [pending setObject:sample forKey:@"sample"];
      DBCallTiming *timing = [pending objectForKey:@"timing"];
      DBCallTimingReading *reading = [timing observeSnapshot:snapshot callID:callID
          door:DBEventString(event, @"door") now:now];
      if (reading.disposition == DBCallTimingActive) {
        NSNumber *currentRevision = DBEventNumber(reading.call, @"stage_revision");
        NSNumber *eventRevision = DBEventNumber(event, @"stage_revision");
        if ([currentRevision longLongValue] > [eventRevision longLongValue] ||
            ![DBEventString(reading.call, @"state") isEqualToString:@"ringing"]) remove = YES;
        else if ([currentRevision isEqual:eventRevision] && [reading.remainingSeconds doubleValue] > 0) {
          NSString *previous = _currentCallID;
          NSDictionary *accepted = [self acceptChimeEvent:event timingReading:reading];
          if (accepted) [ready addObject:@{@"event": accepted, @"previous_call_id": previous ?: @""}];
          remove = YES;
        }
      }
    }
    if (remove) {
      [_pendingChimes removeObjectForKey:callID];
      [_pendingChimeOrder removeObject:callID];
    }
  }
  return ready;
}

- (NSDictionary *)acceptChimeEvent:(NSDictionary *)event timingReading:(DBCallTimingReading *)reading {
  if (reading.disposition != DBCallTimingActive || [reading.remainingSeconds doubleValue] <= 0 ||
      ![DBEventString(reading.call, @"state") isEqualToString:@"ringing"] ||
      ![DBEventString(event, @"call_id") isEqualToString:DBEventString(reading.call, @"call_id")] ||
      ![DBEventString(event, @"door") isEqualToString:DBEventString(reading.call, @"door")] ||
      ![DBEventNumber(event, @"stage_revision") isEqual:DBEventNumber(reading.call, @"stage_revision")])
    return nil;
  return [self acceptChimeEvent:event nowMs:0 coreDeadlineValidated:YES];
}

- (NSDictionary *)acceptChimeEvent:(NSDictionary *)event nowMs:(long long)nowMs
           coreDeadlineValidated:(BOOL)validated {
  if (![event isKindOfClass:[NSDictionary class]]) return nil;
  NSNumber *schema = DBEventNumber(event, @"schema_version");
  NSString *callID = DBEventString(event, @"call_id");
  if (!schema || [schema integerValue] < 2 || [callID length] == 0)
    return nil;

  NSDictionary *normalized = [self normalizedChimeEvent:event];

  NSString *door = DBEventString(normalized, @"door");
  NSNumber *revision = DBEventNumber(normalized, @"stage_revision");
  NSNumber *expires = DBEventNumber(normalized, @"expires_at_ms");
  if ([door length] == 0 || !revision || [revision longLongValue] < 0 || !expires ||
      (!validated && [expires longLongValue] <= nowMs))
    return nil;

  NSDictionary *resolution = [_resolvedCallIDs objectForKey:callID];
  NSString *resolutionType = DBEventString(resolution, @"type");
  if ([resolutionType isEqualToString:@"call_cancelled"] ||
      [resolutionType isEqualToString:@"call_ended"])
    return nil;
  if ([resolutionType isEqualToString:@"call_answered"]) {
    NSNumber *answeredRevision = DBEventNumber(resolution, @"stage_revision");
    if (!answeredRevision || [revision longLongValue] <= [answeredRevision longLongValue])
      return nil;
    [_resolvedCallIDs removeObjectForKey:callID];
    [_resolvedOrder removeObject:callID];
    [_supersededIdleByID setObject:revision forKey:callID];
    if (![_supersededIdleOrder containsObject:callID])
      [_supersededIdleOrder addObject:callID];
    [self trimMap:_supersededIdleByID order:_supersededIdleOrder];
  }

  NSNumber *accepted = [_acceptedRevisionByID objectForKey:callID];
  if (accepted && [revision longLongValue] <= [accepted longLongValue]) return nil;
  [_acceptedRevisionByID setObject:revision forKey:callID];
  if (![_acceptedOrder containsObject:callID]) [_acceptedOrder addObject:callID];
  [self trimMap:_acceptedRevisionByID order:_acceptedOrder];
  _currentCallID = [callID copy];
  return [normalized copy];
}

- (BOOL)eventMatchesCurrentCall:(NSDictionary *)event {
  if ([_currentCallID length] == 0 || ![event isKindOfClass:[NSDictionary class]]) return NO;
  NSString *callID = DBEventString(event, @"call_id");
  return [callID length] > 0 && [callID isEqualToString:_currentCallID];
}

- (void)clearCurrentCall {
  if ([_currentCallID length] > 0) {
    [_supersededIdleByID removeObjectForKey:_currentCallID];
    [_supersededIdleOrder removeObject:_currentCallID];
  }
  _currentCallID = nil;
}

@end
