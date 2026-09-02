#import <Foundation/Foundation.h>

#import "DBBackoffPolicy.h"
#import "DBPairingModel.h"
#import "DBRefreshCoalescer.h"

// Regression cover for the three kiosk pairing/monitor defects fixed in WP-K:
//   1. DBHomeScreen's inline refresh gate latched permanently, so a door
//      station that joined the Cluster later never appeared in the idle monitor
//      list (item: "monitor list must be live").
//   2. The fMP4 player restarted immediately and endlessly against a door whose
//      HTTP endpoint never answers.
//   3. The shell inferred pairing state instead of reading the authoritative
//      snapshot, and showed raw error codes.

static void Require(BOOL condition, NSString *message) {
  if (!condition) {
    NSLog(@"FAIL: %@", message);
    exit(1);
  }
}

#pragma mark - refresh coalescing

static void TestCoalescerServesASingleRefresh(void) {
  DBRefreshCoalescer *gate = [[DBRefreshCoalescer alloc] init];
  Require([gate beginRefresh], @"the first request owns the refresh slot");
  Require(gate.busy, @"the slot is held while the refresh runs");
  Require(![gate endRefresh], @"an uncontended refresh does not ask for a repeat");
  Require(!gate.busy, @"the slot is released");
}

static void TestCoalescerNeverLatches(void) {
  DBRefreshCoalescer *gate = [[DBRefreshCoalescer alloc] init];
  Require([gate beginRefresh], @"first request runs");
  // Two peers_changed events arrive while the snapshot fetch is in flight.
  Require(![gate beginRefresh], @"a concurrent request is coalesced, not started");
  Require(![gate beginRefresh], @"further concurrent requests are coalesced too");
  Require(gate.pending, @"the coalesced request is remembered");
  Require([gate endRefresh], @"the caller is told to refresh again");
  // The regression: the old gate kept `busy` set here, so this begin failed
  // forever and the screen never read Core again.
  Require([gate beginRefresh], @"the follow-up refresh actually starts");
  Require(![gate endRefresh], @"and completes cleanly");

  // The gate must stay usable for every later event, not just the first pair.
  for (int i = 0; i < 100; i++) {
    Require([gate beginRefresh], @"the gate keeps serving later requests");
    Require(![gate beginRefresh], @"overlap is still coalesced");
    Require([gate endRefresh], @"overlap still schedules a follow-up");
    Require([gate beginRefresh], @"follow-up still starts");
    Require(![gate endRefresh], @"follow-up completes");
  }
}

static void TestCoalescerReset(void) {
  DBRefreshCoalescer *gate = [[DBRefreshCoalescer alloc] init];
  Require([gate beginRefresh], @"request runs");
  Require(![gate beginRefresh], @"request is coalesced");
  [gate reset];
  Require(!gate.busy && !gate.pending, @"reset drops the in-flight and pending state");
  Require([gate beginRefresh], @"the gate is usable after a reset");
}

#pragma mark - retry backoff

static void TestBackoffSchedule(void) {
  Require([DBBackoffPolicy delayForAttempt:0] == 1.0, @"first retry is fast");
  Require([DBBackoffPolicy delayForAttempt:1] == 2.0, @"second retry doubles");
  Require([DBBackoffPolicy delayForAttempt:2] == 5.0, @"third retry backs further off");
  Require([DBBackoffPolicy delayForAttempt:3] == 10.0, @"fourth retry reaches the cap");
  Require([DBBackoffPolicy delayForAttempt:4] == 10.0, @"the cap holds");
  Require([DBBackoffPolicy delayForAttempt:47] == 10.0,
          @"the 48th consecutive failure still waits ten seconds, never zero");
}

static void TestBackoffAdvancesAndResets(void) {
  DBBackoffPolicy *policy = [[DBBackoffPolicy alloc] init];
  Require(policy.attempt == 0, @"a fresh policy starts at the first delay");
  Require([policy nextDelay] == 1.0, @"1s");
  Require([policy nextDelay] == 2.0, @"2s");
  Require([policy nextDelay] == 5.0, @"5s");
  Require([policy nextDelay] == 10.0, @"10s");
  Require([policy nextDelay] == 10.0, @"capped at 10s");
  Require(policy.attempt == 5, @"attempts are counted");

  // A door station that comes back must not stay on the slow schedule.
  [policy reset];
  Require(policy.attempt == 0, @"a playing transport resets the schedule");
  Require([policy nextDelay] == 1.0, @"the next outage retries quickly again");

  // Total wait over a long outage must be bounded below by real spacing: the
  // old flat loop spent no time waiting at all between restarts.
  DBBackoffPolicy *long_run = [[DBBackoffPolicy alloc] init];
  NSTimeInterval total = 0;
  for (int i = 0; i < 48; i++) total += [long_run nextDelay];
  Require(total >= 448.0, @"48 failed attempts span at least seven minutes of waiting");
}

#pragma mark - pairing snapshot

static void TestStateIsReadNotInferred(void) {
  Require([[DBPairingModel stateFromPairingInfo:nil] isEqualToString:DBPairingStateUnknown],
          @"no snapshot is unknown");
  Require([[DBPairingModel stateFromPairingInfo:@{}] isEqualToString:DBPairingStateUnknown],
          @"an empty snapshot is unknown, never unpaired");
  Require([[DBPairingModel stateFromPairingInfo:@{ @"state" : @"joining" }]
              isEqualToString:@"joining"],
          @"the authoritative state wins");
  Require([[DBPairingModel stateFromPairingInfo:@{ @"state" : @"persist_error" }]
              isEqualToString:@"persist_error"],
          @"persist_error is rendered as its own state");
  Require([[DBPairingModel stateFromPairingInfo:@{ @"state" : @"nonsense" }]
              isEqualToString:DBPairingStateUnknown],
          @"an unrecognised state is not guessed at");

  // Mixed-version fleet: an older core publishes only the booleans.
  Require([[DBPairingModel stateFromPairingInfo:@{ @"paired" : @NO }]
              isEqualToString:@"unpaired"],
          @"legacy unpaired");
  Require([[DBPairingModel stateFromPairingInfo:@{ @"paired" : @YES }]
              isEqualToString:@"ready"],
          @"legacy paired");
  Require([[DBPairingModel stateFromPairingInfo:
               @{ @"paired" : @YES, @"persistence_ready" : @NO }]
              isEqualToString:@"persist_error"],
          @"legacy paired-but-unpersisted is a persistence error");
}

static void TestErrorCodesNeverLeakRaw(void) {
  Require([[DBPairingModel errorTextKeyForCode:@"bad_pin"]
              isEqualToString:@"pair.err.bad_pin"],
          @"known codes map into pair.err.*");
  Require([[DBPairingModel errorTextKeyForCode:@"host_unpaired"]
              isEqualToString:@"pair.err.host_unpaired"],
          @"host_unpaired maps");
  Require([[DBPairingModel errorTextKeyForCode:@"no_ack"]
              isEqualToString:@"pair.err.no_ack"],
          @"no_ack maps");
  Require([[DBPairingModel errorTextKeyForCode:@"something_new"]
              isEqualToString:@"pair.err.unknown"],
          @"an unlisted code falls back to a human message");
  Require([[DBPairingModel errorTextKeyForCode:@""] isEqualToString:@"pair.err.unknown"],
          @"an empty code falls back too");
  Require([[DBPairingModel errorTextKeyForCode:(NSString *)[NSNull null]]
              isEqualToString:@"pair.err.unknown"],
          @"a wrongly typed code cannot build a key");
}

static void TestPendingDevices(void) {
  NSDictionary *info = @{
    @"pending" : @{
      @"devices" : @[
        @{ @"id" : @"abc123def", @"name" : @"玄関", @"role" : @"door_station" },
        @{ @"id" : @"nonamedevice", @"model" : @"Moto G" },
        @{ @"id" : @"bare0987654" },
        @{ @"name" : @"no id at all" },
        @"not a dictionary",
      ],
    },
  };
  NSArray *devices = [DBPairingModel pendingDevicesFromPairingInfo:info];
  Require([devices count] == 3, @"entries without a usable id are dropped");
  Require([[DBPairingModel displayNameForDevice:[devices objectAtIndex:0]]
              isEqualToString:@"玄関"],
          @"a human name is used as-is");
  Require([[DBPairingModel displayNameForDevice:[devices objectAtIndex:1]]
              isEqualToString:@"Moto G noname"],
          @"model plus a short id when there is no name");
  Require([[DBPairingModel displayNameForDevice:[devices objectAtIndex:2]]
              isEqualToString:@"bare09"],
          @"a short id is the last resort");
  Require([[DBPairingModel pendingDevicesFromPairingInfo:@{}] count] == 0,
          @"a snapshot without pending data yields an empty list");
  Require([[DBPairingModel pendingDevicesFromPairingInfo:
               @{ @"pending" : @"broken" }] count] == 0,
          @"malformed pending data yields an empty list");
}

static void TestCountdownFormatting(void) {
  Require([[DBPairingModel countdownMinutesFromSeconds:600] isEqualToString:@"10"],
          @"ten minutes");
  Require([[DBPairingModel countdownSecondsFromSeconds:600] isEqualToString:@"00"],
          @"seconds are zero padded");
  Require([[DBPairingModel countdownMinutesFromSeconds:65] isEqualToString:@"1"], @"1 min");
  Require([[DBPairingModel countdownSecondsFromSeconds:65] isEqualToString:@"05"], @"05 s");
  Require([[DBPairingModel countdownMinutesFromSeconds:-30] isEqualToString:@"0"],
          @"an expired countdown never goes negative");
  Require([[DBPairingModel countdownSecondsFromSeconds:-30] isEqualToString:@"00"],
          @"an expired countdown never goes negative");
}

int main(void) {
  @autoreleasepool {
    TestCoalescerServesASingleRefresh();
    TestCoalescerNeverLatches();
    TestCoalescerReset();
    TestBackoffSchedule();
    TestBackoffAdvancesAndResets();
    TestStateIsReadNotInferred();
    TestErrorCodesNeverLeakRaw();
    TestPendingDevices();
    TestCountdownFormatting();
    NSLog(@"pairing_ux_test ok");
  }
  return 0;
}
