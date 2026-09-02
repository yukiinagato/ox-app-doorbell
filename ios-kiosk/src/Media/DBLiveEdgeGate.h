#ifndef DB_LIVE_EDGE_GATE_H
#define DB_LIVE_EDGE_GATE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Live-edge policy for the direct fMP4 / VideoToolbox H.264 path.
//
// Why a fixed "sub-100 ms glass-to-glass" gate is not achievable on the
// original iPad (PowerVR SGX535, iOS 5.1):
//
//   * CVOpenGLESTextureCache reports success for VideoToolbox BGRA surfaces on
//     that GPU but yields an all-white texture, so every displayed frame costs
//     a main-thread CVPixelBufferLockBaseAddress + glTexImage2D/glTexSubImage2D
//     upload of the whole 640x360 BGRA surface, plus a CGImage copy for the
//     UIKit compositor that actually owns final display.
//   * VideoToolbox decode, 802.11 transit and the single HTTP-header clock
//     estimate each add their own tens of milliseconds.
//
// The measured age of a frame at display time is therefore routinely
// 150-400 ms on that device even when the pipeline is perfectly healthy. A
// hard 70 ms gate rejects effectively every frame: the player never reports a
// displayed frame, never reaches Playing, and fails its startup timeout in a
// permanent retry loop while the user sees nothing. The gate below therefore
// starts at the last known-good conservative value and only tightens towards
// the device's own measured baseline once that baseline exists.
//
// The policy is deliberately pure C so it can be unit tested on the host.

// Conservative seed: the value this path shipped with before the sub-100 ms
// experiment. Displaying a slightly older frame is always better than
// displaying none.
#define DB_LIVE_EDGE_DEFAULT_START_MS 650
// Never tighten below this: the SGX535 upload path alone cannot beat it.
#define DB_LIVE_EDGE_DEFAULT_FLOOR_MS 120
// Never loosen above this: beyond it the stream is no longer "live".
#define DB_LIVE_EDGE_DEFAULT_CEILING_MS 650
// Head-room added on top of the measured baseline age.
#define DB_LIVE_EDGE_MARGIN_MS 60
// Consecutive displayed frames required before the measured baseline is
// trusted enough to tighten the gate.
#define DB_LIVE_EDGE_WARMUP_FRAMES 30
// Ages outside this range cannot be real and are ignored by the estimator.
#define DB_LIVE_EDGE_MAX_PLAUSIBLE_AGE_MS 10000

// H.264 must prove itself before it is allowed to cover the MJPEG
// availability layer with its opaque compositor.
#define DB_LIVE_EDGE_SUSTAIN_FRAMES 15
#define DB_LIVE_EDGE_SUSTAIN_SECONDS 1.0
// ... and it is demoted back to MJPEG when the displayed-frame rate collapses.
#define DB_LIVE_EDGE_COLLAPSE_SECONDS 1.5

// Clock-offset sanity bounds for the x-doorbell-server-time-ms header.
#define DB_CLOCK_MIN_EPOCH_MS 946684800000LL       // 2000-01-01
#define DB_CLOCK_MAX_EPOCH_MS 4102444800000LL      // 2100-01-01
#define DB_CLOCK_OFFSET_MAX_ABS_MS 86400000LL      // 24 h
#define DB_CLOCK_RTT_MAX_MS 5000LL

typedef struct {
  int64_t floorMs;
  int64_t ceilingMs;
  int64_t marginMs;
  int64_t currentMs;
  uint32_t warmupFrames;
  uint32_t displayedFrames;
  uint32_t streakFrames;
  double ageEmaMs;
  bool ageEmaValid;
  // Without a trusted server clock an "age" is meaningless, so the gate never
  // drops. Showing late video beats showing none.
  bool clockTrusted;
} DBLiveEdgeGate;

// Non-positive values select the DB_LIVE_EDGE_DEFAULT_* seeds. The start value
// is clamped into [floorMs, ceilingMs].
void DBLiveEdgeGateInit(DBLiveEdgeGate *gate, int64_t startMs, int64_t floorMs,
                        int64_t ceilingMs, bool clockTrusted);

int64_t DBLiveEdgeGateCurrentMs(const DBLiveEdgeGate *gate);

// A frame may be rejected for age only when it is genuinely redundant: the
// clock is trusted, at least one frame has already been displayed, and a newer
// frame is already queued behind it. The only available frame is never
// dropped, so the gate can never keep the player from reaching Playing.
bool DBLiveEdgeGateShouldDrop(const DBLiveEdgeGate *gate, int64_t ageMs,
                              bool newerFrameQueued);

void DBLiveEdgeGateNoteDisplayed(DBLiveEdgeGate *gate, int64_t ageMs,
                                 bool ageValid);

// A drop (stale or superseded before display) means the pipeline is behind;
// back the gate off and require a fresh warm-up before tightening again.
void DBLiveEdgeGateNoteDropped(DBLiveEdgeGate *gate);

bool DBLiveEdgeSustained(uint32_t displayedFrames, double secondsSinceFirstFrame);
bool DBLiveEdgeCollapsed(uint32_t displayedFrames, double secondsSinceLastFrame);

// RTT-compensated estimate of (client epoch ms - server epoch ms). Returns
// false when the header is missing or implausible; *offsetMsOut is then 0 and
// the caller must not drop frames on age.
bool DBClockOffsetEstimateMs(int64_t serverMs, int64_t requestSentMs,
                             int64_t responseAtMs, int64_t *offsetMsOut);

#ifdef __cplusplus
}
#endif

#endif  // DB_LIVE_EDGE_GATE_H
