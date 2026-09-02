#import <Foundation/Foundation.h>

#import "DBLiveEdgeGate.h"

// Regression cover for the iPad 1 kiosk live-video failure: a fixed 70 ms live
// edge dropped every decoded frame, so the player never displayed one, never
// reached Playing, and retried forever behind a blank screen.

static void Require(BOOL condition, NSString *message) {
  if (!condition) {
    NSLog(@"FAIL: %@", message);
    exit(1);
  }
}

static void TestSafeSeed(void) {
  DBLiveEdgeGate gate;
  DBLiveEdgeGateInit(&gate, 0, 0, 0, true);
  Require(DBLiveEdgeGateCurrentMs(&gate) == DB_LIVE_EDGE_DEFAULT_START_MS,
          @"default seed is the last known-good 650ms live edge");
  Require(DB_LIVE_EDGE_DEFAULT_START_MS >= 650,
          @"seed never regresses below the pre-regression value");

  // A profile knob still cannot ask for the unreachable sub-100ms budget.
  DBLiveEdgeGateInit(&gate, 70, 0, 0, true);
  Require(DBLiveEdgeGateCurrentMs(&gate) == DB_LIVE_EDGE_DEFAULT_FLOOR_MS,
          @"configured seed is clamped up to the floor");
  DBLiveEdgeGateInit(&gate, 5000, 0, 0, true);
  Require(DBLiveEdgeGateCurrentMs(&gate) == DB_LIVE_EDGE_DEFAULT_CEILING_MS,
          @"configured seed is clamped down to the ceiling");
  DBLiveEdgeGateInit(&gate, 300, 400, 200, true);
  Require(gate.ceilingMs >= gate.floorMs, @"inverted bounds are repaired");
}

static void TestNeverDropsTheOnlyFrame(void) {
  DBLiveEdgeGate gate;
  DBLiveEdgeGateInit(&gate, 200, 120, 650, true);

  // The very first frame is what turns Loading into Playing.
  Require(!DBLiveEdgeGateShouldDrop(&gate, 5000, true),
          @"first frame is never dropped for age");
  DBLiveEdgeGateNoteDisplayed(&gate, 300, true);

  // Afterwards, an old frame is still kept when nothing newer is queued.
  Require(!DBLiveEdgeGateShouldDrop(&gate, 5000, false),
          @"the only available frame is never dropped for age");
  // ... and only then may a superseded frame be skipped to catch up.
  Require(DBLiveEdgeGateShouldDrop(&gate, 5000, true),
          @"a stale frame with a newer one queued is dropped");
  Require(!DBLiveEdgeGateShouldDrop(&gate, 50, true),
          @"a fresh frame is kept even when a newer one is queued");
}

static void TestUntrustedClockDisablesTheGate(void) {
  DBLiveEdgeGate gate;
  DBLiveEdgeGateInit(&gate, 200, 120, 650, false);
  DBLiveEdgeGateNoteDisplayed(&gate, 300, true);
  Require(!DBLiveEdgeGateShouldDrop(&gate, 999999, true),
          @"without a trusted server clock nothing is dropped on age");
}

static void TestAdaptiveTightening(void) {
  DBLiveEdgeGate gate;
  DBLiveEdgeGateInit(&gate, 650, 120, 650, true);
  // A healthy iPad 1 baseline: ~180 ms measured age, steady.
  for (int i = 0; i < DB_LIVE_EDGE_WARMUP_FRAMES - 1; i++) {
    DBLiveEdgeGateNoteDisplayed(&gate, 180, true);
    Require(DBLiveEdgeGateCurrentMs(&gate) == 650,
            @"gate stays at the safe seed during warm-up");
  }
  DBLiveEdgeGateNoteDisplayed(&gate, 180, true);
  Require(DBLiveEdgeGateCurrentMs(&gate) == 180 + DB_LIVE_EDGE_MARGIN_MS,
          @"gate tightens to the measured baseline plus margin");
  Require(DBLiveEdgeGateCurrentMs(&gate) >= DB_LIVE_EDGE_DEFAULT_FLOOR_MS,
          @"gate never tightens below the floor");

  // A device that is genuinely fast still cannot go below the floor.
  DBLiveEdgeGate fast;
  DBLiveEdgeGateInit(&fast, 650, 120, 650, true);
  for (int i = 0; i < DB_LIVE_EDGE_WARMUP_FRAMES; i++)
    DBLiveEdgeGateNoteDisplayed(&fast, 10, true);
  Require(DBLiveEdgeGateCurrentMs(&fast) == DB_LIVE_EDGE_DEFAULT_FLOOR_MS,
          @"floor holds against an implausibly low measured baseline");

  // A drop means the pipeline is behind: back off and re-warm.
  int64_t tightened = DBLiveEdgeGateCurrentMs(&gate);
  DBLiveEdgeGateNoteDropped(&gate);
  Require(DBLiveEdgeGateCurrentMs(&gate) > tightened, @"a drop relaxes the gate");
  Require(gate.streakFrames == 0, @"a drop restarts the warm-up streak");
  DBLiveEdgeGateNoteDisplayed(&gate, 180, true);
  Require(DBLiveEdgeGateCurrentMs(&gate) > tightened,
          @"one frame after a drop does not re-tighten the gate");

  // Ages are never allowed to push the gate past the ceiling.
  DBLiveEdgeGate slow;
  DBLiveEdgeGateInit(&slow, 650, 120, 650, true);
  for (int i = 0; i < DB_LIVE_EDGE_WARMUP_FRAMES * 4; i++)
    DBLiveEdgeGateNoteDisplayed(&slow, 4000, true);
  Require(DBLiveEdgeGateCurrentMs(&slow) == DB_LIVE_EDGE_DEFAULT_CEILING_MS,
          @"ceiling holds against a very high measured baseline");

  // Frames without a usable capture timestamp still count as displayed but do
  // not poison the estimator.
  DBLiveEdgeGate untimed;
  DBLiveEdgeGateInit(&untimed, 650, 120, 650, true);
  for (int i = 0; i < DB_LIVE_EDGE_WARMUP_FRAMES * 2; i++)
    DBLiveEdgeGateNoteDisplayed(&untimed, 0, false);
  Require(untimed.displayedFrames == (uint32_t)(DB_LIVE_EDGE_WARMUP_FRAMES * 2),
          @"untimed frames count as displayed");
  Require(DBLiveEdgeGateCurrentMs(&untimed) == 650,
          @"untimed frames never tighten the gate");
}

static void TestSustainAndCollapse(void) {
  Require(!DBLiveEdgeSustained(1, 0.0),
          @"one frame does not let H.264 cover the MJPEG layer");
  Require(!DBLiveEdgeSustained(5, 0.2), @"a short burst is not sustained");
  Require(DBLiveEdgeSustained(DB_LIVE_EDGE_SUSTAIN_FRAMES, 0.4),
          @"enough frames counts as sustained");
  Require(DBLiveEdgeSustained(3, DB_LIVE_EDGE_SUSTAIN_SECONDS + 0.1),
          @"a slow but steady rate counts as sustained");

  Require(!DBLiveEdgeCollapsed(0, 10.0), @"nothing displayed yet is not a collapse");
  Require(!DBLiveEdgeCollapsed(30, 0.3), @"a normal frame interval is not a collapse");
  Require(DBLiveEdgeCollapsed(30, DB_LIVE_EDGE_COLLAPSE_SECONDS + 0.1),
          @"a long gap after playing is a collapse");
}

static void TestClockOffset(void) {
  int64_t serverMs = 1750000000000LL;
  int64_t offset = -1;

  // Request at T, response 100 ms later; the header was written ~50 ms ago.
  Require(DBClockOffsetEstimateMs(serverMs, serverMs, serverMs + 100, &offset),
          @"a plausible header is trusted");
  Require(offset == 50, @"half the round trip is compensated");

  // A client clock that is 2 s ahead, measured across a 100 ms round trip.
  Require(DBClockOffsetEstimateMs(serverMs, serverMs + 2000,
                                  serverMs + 2100, &offset),
          @"a real client/server skew is trusted");
  Require(offset == 2050, @"skew is reported as client-minus-server");

  Require(!DBClockOffsetEstimateMs(0, serverMs, serverMs + 10, &offset),
          @"a missing/zero server time is rejected");
  Require(offset == 0, @"a rejected estimate reports a zero offset");
  Require(!DBClockOffsetEstimateMs(42, serverMs, serverMs + 10, &offset),
          @"a non-epoch server time is rejected");
  Require(!DBClockOffsetEstimateMs(serverMs, serverMs,
                                   serverMs + DB_CLOCK_RTT_MAX_MS + 1, &offset),
          @"an unusably slow handshake is rejected");
  Require(!DBClockOffsetEstimateMs(serverMs, serverMs + DB_CLOCK_OFFSET_MAX_ABS_MS * 2,
                                   serverMs + DB_CLOCK_OFFSET_MAX_ABS_MS * 2 + 10,
                                   &offset),
          @"an out-of-bounds offset is rejected");
}

int main(void) {
  @autoreleasepool {
    TestSafeSeed();
    TestNeverDropsTheOnlyFrame();
    TestUntrustedClockDisablesTheGate();
    TestAdaptiveTightening();
    TestSustainAndCollapse();
    TestClockOffset();
    NSLog(@"live_edge_gate_test ok");
  }
  return 0;
}
