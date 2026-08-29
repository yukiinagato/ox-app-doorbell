#import <UIKit/UIKit.h>

// Snapshot read by the incoming-screen UI on the main thread. Jitter is the
// smoothed absolute frame-to-frame variation of end-to-end latency.
typedef struct {
  BOOL valid;
  NSInteger latencyMs;
  NSInteger jitterMs;
  CGFloat framesPerSecond;
} DBVideoStats;

static inline DBVideoStats DBVideoStatsMake(BOOL valid, NSInteger latencyMs,
                                            NSInteger jitterMs, CGFloat fps) {
  DBVideoStats s;
  s.valid = valid;
  s.latencyMs = latencyMs;
  s.jitterMs = jitterMs;
  s.framesPerSecond = fps;
  return s;
}
