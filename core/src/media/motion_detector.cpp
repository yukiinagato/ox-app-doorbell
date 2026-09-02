

#include "media/motion_detector.h"

#include <algorithm>
#include <cstring>

namespace db {

double MotionDetector::thresholdPercent(int sensitivity) {
  if (sensitivity < 0) sensitivity = 0;
  if (sensitivity > 100) sensitivity = 100;


  return 50.0 - 0.49 * sensitivity;
}


static inline int bgraLuma(const uint8_t* p) {
  return (29 * p[0] + 150 * p[1] + 77 * p[2]) >> 8;
}

bool MotionDetector::downscaleLuma(const RawFrame& f, int stride,
                                   std::vector<uint8_t>& out) const {
  out.assign(static_cast<size_t>(gw_) * gh_, 0);
  std::vector<uint32_t> sum(static_cast<size_t>(gw_) * gh_, 0);
  std::vector<uint32_t> cnt(static_cast<size_t>(gw_) * gh_, 0);
  for (int r = 0; r < f.h; r++) {
    const uint8_t* row = f.data.data() + static_cast<size_t>(r) * stride;
    int gr = r * gh_ / f.h;
    uint32_t* srow = sum.data() + static_cast<size_t>(gr) * gw_;
    uint32_t* crow = cnt.data() + static_cast<size_t>(gr) * gw_;
    for (int c = 0; c < f.w; c++) {
      int luma;
      switch (f.format) {
        case 0:  // NV21
        case 1:
          luma = row[c];
          break;
        case 2:
          luma = row[c * 2];
          break;
        case 3:
          luma = bgraLuma(row + static_cast<size_t>(c) * 4);
          break;
        default:
          return false;
      }
      int gc = c * gw_ / f.w;
      srow[gc] += static_cast<uint32_t>(luma);
      crow[gc]++;
    }
  }
  for (size_t i = 0; i < out.size(); i++) {
    out[i] = cnt[i] ? static_cast<uint8_t>(sum[i] / cnt[i]) : 0;
  }
  return true;
}

void MotionDetector::setConfig(const MotionConfig& cfg) {
  bool was_enabled = cfg_.enabled;
  cfg_ = cfg;
  if (!cfg_.enabled) {
    streak_ = 0;
    last_pct_ = 0.0;
  } else if (!was_enabled) {

    seen_ = 0;
    prev_.clear();
    streak_ = 0;
  }
}

void MotionDetector::feed(const RawFrame& f) {
  if (!cfg_.enabled) return;
  if (f.w <= 0 || f.h <= 0) return;
  int stride = f.stride;
  if (stride == 0) stride = f.format == 2 ? f.w * 2 : (f.format == 3 ? f.w * 4 : f.w);
  if (rawFrameBytes(f.format, f.w, f.h, stride) == 0 ||
      f.data.size() < rawFrameBytes(f.format, f.w, f.h, stride)) {
    return;
  }


  if (f.w != frame_w_ || f.h != frame_h_) {
    frame_w_ = f.w;
    frame_h_ = f.h;
    gw_ = std::min(kGridW, f.w);
    gh_ = std::min(kGridH, f.h);
    prev_.clear();
    seen_ = 0;
    streak_ = 0;
  }

  std::vector<uint8_t> cur;
  if (!downscaleLuma(f, stride, cur)) return;

  double pct = 0.0;
  bool have_prev = prev_.size() == cur.size() && seen_ > 0;
  if (have_prev) {
    int changed = 0;
    for (size_t i = 0; i < cur.size(); i++) {
      int d = static_cast<int>(cur[i]) - static_cast<int>(prev_[i]);
      if (d < 0) d = -d;
      if (d >= kBlockDiffThreshold) changed++;
    }
    pct = 100.0 * changed / static_cast<double>(cur.size());
  }
  prev_.swap(cur);
  seen_++;
  last_pct_ = pct;


  if (seen_ <= kLearnFrames) {
    streak_ = 0;
    return;
  }

  if (pct >= thresholdPercent(cfg_.sensitivity)) {
    streak_++;
  } else {
    streak_ = 0;
    return;
  }
  if (streak_ < 2) return;


  int64_t interval_ms = static_cast<int64_t>(cfg_.min_interval_s) * 1000;
  if (last_fire_ms_ != INT64_MIN && f.ts_ms - last_fire_ms_ < interval_ms) return;

  last_fire_ms_ = f.ts_ms;
  if (cb_) cb_(f.ts_ms, pct);
}

}  // namespace db
