#import <Foundation/Foundation.h>
#import "DBCallEventTracker.h"

static void Check(BOOL condition, NSString *message) {
  if (condition) return;
  NSLog(@"FAIL: %@", message);
  exit(1);
}

int main(void) {
  @autoreleasepool {
    DBCallEventTracker *tracker = [[DBCallEventTracker alloc] init];
    NSDictionary *press = @{
      @"t" : @"event", @"type" : @"press", @"call_id" : @"call-a",
      @"door" : @"front", @"purpose" : @"delivery", @"stage_revision" : @0,
      @"expires_at_ms" : @2000,
    };
    [tracker recordCallEvent:press];
    Check([tracker.currentCallID length] == 0,
          @"raw press must not activate an incoming call");

    NSDictionary *chime = @{
      @"schema_version" : @2, @"t" : @"chime", @"call_id" : @"call-a",
      @"door" : @"front", @"stage_revision" : @0, @"expires_at_ms" : @2000,
    };
    NSDictionary *accepted = [tracker acceptChimeEvent:chime nowMs:1000];
    Check(accepted != nil, @"targeted schema-v2 chime should activate UI");
    Check([[accepted objectForKey:@"purpose"] isEqualToString:@"delivery"],
          @"chime should inherit cached call data");
    Check([[tracker currentCallID] isEqualToString:@"call-a"],
          @"accepted chime should set current call identity");
    Check([tracker acceptChimeEvent:chime nowMs:1000] == nil,
          @"same call revision must be idempotent");

    NSMutableDictionary *newRevision = [chime mutableCopy];
    [newRevision setObject:@1 forKey:@"stage_revision"];
    Check([tracker acceptChimeEvent:newRevision nowMs:1000] != nil,
          @"newer stage revision should be accepted");
    Check([tracker acceptChimeEvent:@{
      @"schema_version" : @2, @"t" : @"chime", @"call_id" : @"expired",
      @"door" : @"front", @"stage_revision" : @0, @"expires_at_ms" : @1000,
    } nowMs:1000] == nil, @"expired chime must not open UI");
    Check([tracker acceptChimeEvent:@{
      @"schema_version" : @1, @"t" : @"chime", @"call_id" : @"old",
      @"door" : @"front", @"stage_revision" : @0, @"expires_at_ms" : @2000,
    } nowMs:1000] == nil, @"legacy chime lacks the scoped UI contract");

    NSDictionary *cancelBeforeChime = @{
      @"t" : @"event", @"type" : @"call_cancelled", @"call_id" : @"call-c",
    };
    [tracker recordCancellationEvent:cancelBeforeChime];
    Check([tracker acceptChimeEvent:@{
      @"schema_version" : @2, @"t" : @"chime", @"call_id" : @"call-c",
      @"door" : @"front", @"stage_revision" : @0, @"expires_at_ms" : @2000,
    } nowMs:1000] == nil, @"late chime must not resurrect a cancelled call");

    Check(![tracker eventMatchesCurrentCall:@{@"call_id" : @"call-b"}],
          @"another call must not cancel the current UI");
    Check([tracker eventMatchesCurrentCall:@{@"call_id" : @"call-a"}],
          @"matching call_id should address the current UI");

    NSDictionary *answered = @{
      @"schema_version" : @2, @"t" : @"event", @"type" : @"call_answered",
      @"call_id" : @"call-a", @"stage_revision" : @1,
    };
    Check([tracker recordAnsweredEvent:answered],
          @"answered event should match the active call without clearing its identity");
    Check([[tracker currentCallID] isEqualToString:@"call-a"],
          @"answering panel retains call identity until ended");
    NSMutableDictionary *lateChime = [newRevision mutableCopy];
    [lateChime setObject:@2 forKey:@"stage_revision"];
    Check([tracker acceptChimeEvent:lateChime nowMs:1000] != nil,
          @"a higher-revision chime must supersede the stale answered revision");
    Check([tracker consumeSupersededIdleForCurrentCall],
          @"the losing answer leg's idle must be consumed exactly once");
    Check(![tracker consumeSupersededIdleForCurrentCall],
          @"only the losing leg's first idle may be suppressed");
    Check(![tracker recordEndedEvent:@{
      @"schema_version" : @2, @"type" : @"call_ended", @"call_id" : @"call-b",
      @"stage_revision" : @2,
    }], @"another call cannot clear the current UI");
    Check([tracker recordEndedEvent:@{
      @"schema_version" : @2, @"type" : @"call_ended", @"call_id" : @"call-a",
      @"stage_revision" : @2,
    }], @"matching call_ended clears the current UI");
    Check([tracker.currentCallID length] == 0,
          @"ended call releases current call identity");
    [tracker clearCurrentCall];
    Check([tracker.currentCallID length] == 0, @"clear should release current call identity");

    DBCallEventTracker *race = [[DBCallEventTracker alloc] init];
    NSDictionary *racePress = @{
      @"schema_version" : @2, @"t" : @"event", @"type" : @"press",
      @"call_id" : @"call-race", @"door" : @"front", @"stage_revision" : @0,
      @"expires_at_ms" : @2000,
    };
    [race recordCallEvent:racePress];
    Check([race acceptChimeEvent:@{
      @"schema_version" : @2, @"t" : @"chime", @"call_id" : @"call-race",
      @"door" : @"front", @"stage_revision" : @0, @"expires_at_ms" : @2000,
    } nowMs:1000] != nil, @"revision zero should ring before it is answered");
    Check([race recordAnsweredEvent:@{
      @"schema_version" : @2, @"type" : @"call_answered", @"call_id" : @"call-race",
      @"stage_revision" : @0,
    }], @"revision zero answer should bind the current call");
    NSDictionary *winningPurpose = @{
      @"schema_version" : @2, @"t" : @"event", @"type" : @"purpose_selected",
      @"call_id" : @"call-race", @"door" : @"front", @"purpose" : @"delivery",
      @"stage_revision" : @1, @"expires_at_ms" : @2000,
    };
    Check([race recordCallEvent:winningPurpose],
          @"purpose revision one should supersede the answered revision zero");
    Check(![race recordCallEvent:winningPurpose],
          @"same-revision purpose updates must remain idempotent");
    Check([race consumeSupersededIdleForCurrentCall],
          @"losing revision-zero idle must leave revision one ringing");
    Check([[race currentCallID] isEqualToString:@"call-race"],
          @"losing idle must not clear the newer ringing call");
    NSDictionary *raceRevisionOne = @{
      @"schema_version" : @2, @"t" : @"chime", @"call_id" : @"call-race",
      @"door" : @"front", @"purpose" : @"delivery", @"stage_revision" : @1,
      @"expires_at_ms" : @2000,
    };
    Check([race acceptChimeEvent:raceRevisionOne nowMs:1000] != nil,
          @"same-call chime for the winning revision must ring");
    Check([race acceptChimeEvent:raceRevisionOne nowMs:1000] == nil,
          @"the winning revision chime remains idempotent");
  }
  puts("call event tracker test passed");
  return 0;
}
