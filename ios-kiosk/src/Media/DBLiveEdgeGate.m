#include "DBLiveEdgeGate.h"

// Pure C on purpose: this file is compiled into the armv7 kiosk app and, byte
// for byte, into the ios-compat host test binary.

void DBLiveEdgeGateInit(DBLiveEdgeGate *gate, int64_t startMs, int64_t floorMs,
                        int64_t ceilingMs, bool clockTrusted) {
  if (!gate) return;
  if (floorMs <= 0) floorMs = DB_LIVE_EDGE_DEFAULT_FLOOR_MS;
  if (ceilingMs <= 0) ceilingMs = DB_LIVE_EDGE_DEFAULT_CEILING_MS;
  if (ceilingMs < floorMs) ceilingMs = floorMs;
  if (startMs <= 0) startMs = DB_LIVE_EDGE_DEFAULT_START_MS;
  if (startMs < floorMs) startMs = floorMs;
  if (startMs > ceilingMs) startMs = ceilingMs;
  gate->floorMs = floorMs;
  gate->ceilingMs = ceilingMs;
  gate->marginMs = DB_LIVE_EDGE_MARGIN_MS;
  gate->currentMs = startMs;
  gate->warmupFrames = DB_LIVE_EDGE_WARMUP_FRAMES;
  gate->displayedFrames = 0;
  gate->streakFrames = 0;
  gate->ageEmaMs = 0.0;
  gate->ageEmaValid = false;
  gate->clockTrusted = clockTrusted;
}

int64_t DBLiveEdgeGateCurrentMs(const DBLiveEdgeGate *gate) {
  return gate ? gate->currentMs : 0;
}

bool DBLiveEdgeGateShouldDrop(const DBLiveEdgeGate *gate, int64_t ageMs,
                              bool newerFrameQueued) {
  if (!gate) return false;
  if (!gate->clockTrusted) return false;
  if (gate->currentMs <= 0) return false;
  // The first displayed frame is what turns Loading into Playing. It is never
  // rejected, whatever its age.
  if (gate->displayedFrames == 0) return false;
  // Only a catch-up drop is allowed: something newer is already waiting.
  if (!newerFrameQueued) return false;
  return ageMs > gate->currentMs;
}

void DBLiveEdgeGateNoteDisplayed(DBLiveEdgeGate *gate, int64_t ageMs,
                                 bool ageValid) {
  if (!gate) return;
  if (gate->displayedFrames < 0xFFFFFFFFu) gate->displayedFrames++;
  if (!ageValid || ageMs < 0 || ageMs > DB_LIVE_EDGE_MAX_PLAUSIBLE_AGE_MS) return;
  if (gate->streakFrames < 0xFFFFFFFFu) gate->streakFrames++;
  if (!gate->ageEmaValid) {
    gate->ageEmaMs = (double)ageMs;
    gate->ageEmaValid = true;
  } else {
    gate->ageEmaMs += ((double)ageMs - gate->ageEmaMs) / 8.0;
  }
  if (gate->streakFrames < gate->warmupFrames) return;
  int64_t target = (int64_t)(gate->ageEmaMs + 0.5) + gate->marginMs;
  if (target < gate->floorMs) target = gate->floorMs;
  if (target > gate->ceilingMs) target = gate->ceilingMs;
  gate->currentMs = target;
}

void DBLiveEdgeGateNoteDropped(DBLiveEdgeGate *gate) {
  if (!gate) return;
  gate->streakFrames = 0;
  int64_t relaxed = gate->currentMs + gate->marginMs;
  if (relaxed > gate->ceilingMs) relaxed = gate->ceilingMs;
  if (relaxed > gate->currentMs) gate->currentMs = relaxed;
}

bool DBLiveEdgeSustained(uint32_t displayedFrames, double secondsSinceFirstFrame) {
  if (displayedFrames >= (uint32_t)DB_LIVE_EDGE_SUSTAIN_FRAMES) return true;
  // A low but steady frame rate still counts once it has held for a while.
  return displayedFrames >= 2u && secondsSinceFirstFrame >= DB_LIVE_EDGE_SUSTAIN_SECONDS;
}

bool DBLiveEdgeCollapsed(uint32_t displayedFrames, double secondsSinceLastFrame) {
  if (displayedFrames == 0) return false;
  return secondsSinceLastFrame > DB_LIVE_EDGE_COLLAPSE_SECONDS;
}

bool DBClockOffsetEstimateMs(int64_t serverMs, int64_t requestSentMs,
                             int64_t responseAtMs, int64_t *offsetMsOut) {
  if (offsetMsOut) *offsetMsOut = 0;
  if (serverMs < DB_CLOCK_MIN_EPOCH_MS || serverMs > DB_CLOCK_MAX_EPOCH_MS)
    return false;
  int64_t rtt = responseAtMs - requestSentMs;
  if (rtt < 0) rtt = 0;
  // A very slow handshake makes the one-way estimate too coarse to gate a
  // live edge with; fall back to "never drop on age".
  if (rtt > DB_CLOCK_RTT_MAX_MS) return false;
  // The header was written roughly rtt/2 before it was read here.
  int64_t offset = responseAtMs - (serverMs + rtt / 2);
  int64_t magnitude = offset < 0 ? -offset : offset;
  if (magnitude > DB_CLOCK_OFFSET_MAX_ABS_MS) return false;
  if (offsetMsOut) *offsetMsOut = offset;
  return true;
}
