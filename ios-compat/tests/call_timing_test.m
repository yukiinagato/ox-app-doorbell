#import <Foundation/Foundation.h>
#import "DBCallTiming.h"
#import "DBCallEventTracker.h"
#import <math.h>

static void require(BOOL condition, NSString *message) {
  if (!condition) {
    fprintf(stderr, "FAIL: %s\n", [message UTF8String]);
    exit(1);
  }
}

static DBCallTimingSnapshot *sample(NSString *generation, NSUInteger core, double request,
                                    long long age, id remaining, id recovery, long long wall) {
  NSMutableDictionary *call = [@{@"call_id": @"c1", @"door": @"front", @"state": @"ringing",
      @"stage_revision": @0, @"snapshot_generation": generation,
      @"snapshot_at_ms": @(wall), @"expires_at_ms": @(wall + 10000),
      @"recovery_required": @YES, @"recovery_eligible": @YES} mutableCopy];
  if (remaining) [call setObject:remaining forKey:@"remaining_ms"];
  if (recovery) [call setObject:recovery forKey:@"recovery_remaining_ms"];
  return [[DBCallTimingSnapshot alloc] initWithDocument:@{@"snapshot_generation": generation,
      @"snapshot_age_ms": @(age), @"active_calls": @[call]} coreGeneration:core requestedAt:request];
}

static DBCallTimingReading *observe(DBCallTiming *timing, DBCallTimingSnapshot *snapshot, double now) {
  return [timing observeSnapshot:snapshot callID:@"c1" door:@"front" now:now];
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    NSDictionary *chime = @{@"schema_version": @2, @"call_id": @"c1", @"door": @"front",
        @"stage_revision": @0, @"expires_at_ms": @1010000};
    if (argc > 1 && strcmp(argv[1], "--red-old-recovery") == 0) {
      DBCallEventTracker *oldTracker = [[DBCallEventTracker alloc] init];
      require([oldTracker acceptChimeEvent:chime nowMs:1300000] != nil,
          @"a Core-valid call must survive a device wall clock five minutes fast");
      return 0;
    }
    for (NSNumber *offset in @[@(-300000), @0, @300000]) {
      DBCallTiming *timing = [[DBCallTiming alloc] init];
      DBCallTimingReading *r = observe(timing, sample(@"s1", 1, 100, 2000, @10000, @8000,
          1000000 + [offset longLongValue]), 101);
      require(fabs([r.remainingSeconds doubleValue] - 7) < 0.000001 && r.mayRestore,
          @"wall offsets cannot change the Core-projected remaining duration");
      require(fabs([r.recoveryRemainingSeconds doubleValue] - 5) < 0.000001,
          @"age and read latency also consume the recovery window");
      DBCallEventTracker *tracker = [[DBCallEventTracker alloc] init];
      require([tracker acceptChimeEvent:chime timingReading:r] != nil,
          @"targeted restoration uses current Core duration despite a stale persisted wall deadline");
      require([tracker acceptChimeEvent:chime timingReading:r] == nil,
          @"repeated recovery cannot chime twice");
      DBCallEventTracker *live = [[DBCallEventTracker alloc] init];
      require([live queueChimeEvent:chime coreGeneration:1 now:100], @"targeted live chime is queued");
      NSArray *ready = [live takeReadyChimesFromSnapshot:sample(@"live", 1, 100, 2000,
          @10000, @0, 1000000 + [offset longLongValue]) coreGeneration:1 now:101];
      require([ready count] == 1 && live.pendingChimeCount == 0,
          @"ordinary targeted chime also ignores device wall offset");
      require(![live queueChimeEvent:chime coreGeneration:1 now:102],
          @"accepted live revision remains deduplicated");
    }
    DBCallEventTracker *late = [[DBCallEventTracker alloc] init];
    require([late queueChimeEvent:chime coreGeneration:1 now:100], @"late snapshot fixture queues real event");
    DBCallTimingSnapshot *empty = [[DBCallTimingSnapshot alloc] initWithDocument:
        @{@"snapshot_generation": @"before", @"snapshot_age_ms": @0, @"active_calls": @[]}
        coreGeneration:1 requestedAt:100];
    require([[late takeReadyChimesFromSnapshot:empty coreGeneration:1 now:100] count] == 0 &&
        late.pendingChimeCount == 1, @"an event before the cache waits without activating or cancelling");
    require([[late takeReadyChimesFromSnapshot:sample(@"before", 1, 101, 0, @10000, @0, 1000000)
        coreGeneration:1 now:101] count] == 0, @"unchanged sample generation is not retried as fresh");
    require([[late takeReadyChimesFromSnapshot:sample(@"after", 1, 102, 0, @10000, @0, 1000000)
        coreGeneration:1 now:102] count] == 1, @"a matching newly published Core snapshot releases the targeted event");
    DBCallEventTracker *revisionWait = [[DBCallEventTracker alloc] init];
    NSMutableDictionary *newPurpose = [chime mutableCopy];
    [newPurpose setObject:@1 forKey:@"stage_revision"];
    [revisionWait queueChimeEvent:newPurpose coreGeneration:1 now:100];
    require([[revisionWait takeReadyChimesFromSnapshot:sample(@"old-purpose", 1, 100, 0, @10000, @0, 1000000)
        coreGeneration:1 now:100] count] == 0, @"a cached older purpose cannot admit the newer targeted revision");
    DBCallTimingSnapshot *purposeBase = sample(@"new-purpose", 1, 101, 0, @10000, @0, 1000000);
    NSMutableDictionary *purposeDoc = [purposeBase.document mutableCopy];
    NSMutableDictionary *purposeCall = [[[purposeDoc objectForKey:@"active_calls"] objectAtIndex:0] mutableCopy];
    [purposeCall setObject:@1 forKey:@"stage_revision"];
    [purposeDoc setObject:@[purposeCall] forKey:@"active_calls"];
    DBCallTimingSnapshot *purposeSnapshot = [[DBCallTimingSnapshot alloc] initWithDocument:purposeDoc
        coreGeneration:1 requestedAt:101];
    require([[revisionWait takeReadyChimesFromSnapshot:purposeSnapshot coreGeneration:1 now:101] count] == 1,
        @"the exact new call revision admits the waiting targeted notification");
    DBCallEventTracker *foregroundChime = [[DBCallEventTracker alloc] init];
    [foregroundChime queueChimeEvent:chime coreGeneration:1 now:100];
    DBCallTimingSnapshot *beforeSleep = sample(@"sleep", 1, 100, 0, @10000, @0, 1000000);
    [foregroundChime requireFreshChimeSnapshot:beforeSleep];
    require([[foregroundChime takeReadyChimesFromSnapshot:beforeSleep coreGeneration:1 now:100] count] == 0,
        @"a pending chime cannot use an unchanged pre-sleep sample");
    require([[foregroundChime takeReadyChimesFromSnapshot:sample(@"awake", 1, 101, 0, @10000, @0, 1000000)
        coreGeneration:1 now:101] count] == 1, @"new foreground sample releases the still-valid pending chime");
    DBCallEventTracker *bounded = [[DBCallEventTracker alloc] init];
    [bounded queueChimeEvent:chime coreGeneration:1 now:100];
    require(![bounded queueChimeEvent:chime coreGeneration:1 now:109],
        @"duplicate delivery cannot renew the unresolved notification deadline");
    require([[bounded takeReadyChimesFromSnapshot:nil coreGeneration:1 now:110] count] == 0 &&
        bounded.pendingChimeCount == 0 && bounded.currentCallID == nil,
        @"bounded waiting ends without accepting or changing the call");
    DBCallEventTracker *restart = [[DBCallEventTracker alloc] init];
    [restart queueChimeEvent:chime coreGeneration:1 now:100];
    require([[restart takeReadyChimesFromSnapshot:sample(@"old", 1, 100, 0, @10000, @0, 1000000)
        coreGeneration:2 now:101] count] == 0 && restart.pendingChimeCount == 0,
        @"a pre-restart queued notification cannot enter the replacement Core lifetime");
    [restart queueChimeEvent:chime coreGeneration:2 now:102];
    require([[restart takeReadyChimesFromSnapshot:sample(@"old", 1, 102, 0, @10000, @0, 1000000)
        coreGeneration:2 now:102] count] == 0 && restart.pendingChimeCount == 1,
        @"an old callback cannot consume the new lifetime's pending notification");
    require([[restart takeReadyChimesFromSnapshot:sample(@"new", 2, 103, 0, @10000, @0, 1000000)
        coreGeneration:2 now:103] count] == 1, @"new lifetime callback remains admissible");
    DBCallEventTracker *cancelled = [[DBCallEventTracker alloc] init];
    [cancelled queueChimeEvent:chime coreGeneration:1 now:100];
    [cancelled recordCancellationEvent:@{@"call_id": @"c1", @"stage_revision": @0}];
    require([[cancelled takeReadyChimesFromSnapshot:sample(@"late", 1, 101, 0, @10000, @0, 1000000)
        coreGeneration:1 now:101] count] == 0 && cancelled.currentCallID == nil,
        @"a late old-call result cannot resurrect a cancelled call");
    DBCallEventTracker *capacity = [[DBCallEventTracker alloc] init];
    for (NSUInteger i = 0; i < 129; ++i) {
      NSMutableDictionary *event = [chime mutableCopy];
      [event setObject:[NSString stringWithFormat:@"pending-%lu", (unsigned long)i] forKey:@"call_id"];
      require([capacity queueChimeEvent:event coreGeneration:1 now:100], @"new pending identity is accepted");
    }
    require(capacity.pendingChimeCount == 128, @"unresolved targeted notifications have fixed capacity");
    [capacity takeReadyChimesFromSnapshot:nil coreGeneration:1 now:110];
    require(capacity.pendingChimeCount == 0, @"capacity clears at the bounded admission deadline");
    DBCallTiming *timing = [[DBCallTiming alloc] init];
    observe(timing, sample(@"s1", 1, 100, 0, @10000, @10000, 1000000), 100);
    DBCallTimingReading *r = observe(timing, sample(@"s1", 1, 106, 0, @10000, @10000, 700000), 106);
    require([r.remainingSeconds doubleValue] == 4, @"same cache cannot reset deadline");
    r = observe(timing, sample(@"s1", 1, 107, 0, nil, @10000, 1000000), 107);
    require(r.remainingSeconds == nil && !r.mayRestore, @"missing duration remains unknown");
    r = observe(timing, sample(@"s1", 1, 111, 0, @10000, @10000, 1000000), 111);
    require([r.remainingSeconds doubleValue] == 0 && !r.mayRestore, @"invalid read cannot erase old anchor");
    DBCallEventTracker *expiredTracker = [[DBCallEventTracker alloc] init];
    require([expiredTracker acceptChimeEvent:chime timingReading:r] == nil,
        @"expired Core projection cannot re-ring");
    for (id invalid in @[@(-1), @YES, @(NAN), @(INFINITY), @1.5, @9007199254740992.0]) {
      r = observe(timing, sample(@"s2", 1, 120, 0, invalid, @10000, 1000000), 120);
      require(r.remainingSeconds == nil && !r.mayRestore, @"malformed duration must not become a timer");
    }
    r = observe(timing, sample(@"s3", 1, 130, -1, @10000, @10000, 1000000), 130);
    require(r.disposition == DBCallTimingUnavailable, @"unknown age blocks recovery");
    r = observe(timing, sample(@"s3", 1, 130, 0, @10000, @10001, 1000000), 130);
    require(!r.mayRestore, @"recovery window cannot exceed ten seconds");

    DBCallTimingSnapshot *old = sample(@"s4", 1, 140, 0, @10000, @10000, 1000000);
    observe(timing, old, 140);
    [timing requireFreshSnapshot:old];
    [timing reset];
    require(observe(timing, old, 140).disposition == DBCallTimingUnavailable,
        @"foreground same generation and age cannot prove freshness after sleep");
    require(observe(timing, sample(@"s5", 1, 140, 0, @0, @0, 1000000), 140).disposition == DBCallTimingActive,
        @"a new Core sample releases the foreground barrier");
    DBCallTiming *unknown = [[DBCallTiming alloc] init];
    [unknown requireFreshSnapshot:nil];
    require(![unknown acceptsSnapshot:old] && ![unknown acceptsSnapshot:old],
        @"without previous reads the first sample is only a baseline");
    require([unknown acceptsSnapshot:sample(@"s4", 2, 140, 0, @10000, @10000, 1000000)],
        @"new Core lifetime releases the barrier");
    NSDictionary *callback = [timing callbackForCall:@"c1" coreGeneration:1];
    require([timing acceptsCallback:callback callID:@"c1" coreGeneration:1], @"current callback is accepted");
    require(![timing acceptsCallback:callback callID:@"c1" coreGeneration:2], @"old Core callback is rejected");
    require(![timing acceptsCallback:callback callID:@"replacement" coreGeneration:1], @"old call callback is rejected");
    [timing invalidateCallbacks];
    require(![timing acceptsCallback:callback callID:@"c1" coreGeneration:1], @"old timer revision is rejected");
    DBCallTiming *owned = [[DBCallTiming alloc] init];
    NSMutableDictionary *local = [[[sample(@"owned", 1, 200, 0, @10000, @10000, 1000000)
        .document objectForKey:@"active_calls"] objectAtIndex:0] mutableCopy];
    [local setObject:@"self" forKey:@"origin"];
    NSMutableDictionary *foreign = [local mutableCopy];
    [foreign setObject:@"foreign" forKey:@"call_id"];
    [foreign setObject:@"other" forKey:@"origin"];
    NSDictionary *document = @{@"snapshot_generation": @"owned", @"snapshot_age_ms": @0,
        @"active_calls": @[foreign, local]};
    DBCallTimingSnapshot *ownedSnapshot = [[DBCallTimingSnapshot alloc]
        initWithDocument:document coreGeneration:1 requestedAt:200];
    [owned observeRecoverySnapshot:ownedSnapshot callID:@"c1" role:@"door_station"
        nodeID:@"self" door:@"front" now:200];
    ownedSnapshot = [[DBCallTimingSnapshot alloc] initWithDocument:document
        coreGeneration:1 requestedAt:205];
    require([owned observeRecoverySnapshot:ownedSnapshot callID:@"foreign" role:@"door_station"
        nodeID:@"self" door:@"front" now:205].disposition == DBCallTimingUnavailable,
        @"foreign candidates cannot replace an owned recovery anchor");
    r = [owned observeRecoverySnapshot:ownedSnapshot callID:@"c1" role:@"door_station"
        nodeID:@"self" door:@"front" now:205];
    require([r.remainingSeconds doubleValue] == 5 && [r.recoveryRemainingSeconds doubleValue] == 5,
        @"owned cached call and recovery deadlines remain unchanged after foreign candidates");
    require(DBCallMonotonicTime() > 0, @"historical monotonic adapter returns measured time");
    puts("compatibility call timing: live chime, bounded admission, wall offsets, cache age, recovery, foreground and stale callbacks passed");
  }
  return 0;
}
