







// Lightweight luma-block motion detector. It has no internal lock; configuration and feed calls
// must be externally serialized. Initial learning frames and the configured cooldown suppress
// false/repeated triggers.
#pragma once

#include <cstdint>
#include <functional>
#include <vector>

#include "media/frame_bus.h"

namespace db {


struct MotionConfig {
  bool enabled = true;
  int sensitivity = 40;
  int min_interval_s = 30;
};

class MotionDetector {
 public:

  using MotionCallback = std::function<void(int64_t ts_ms, double changed_pct)>;


  static constexpr int kGridW = 32;
  static constexpr int kGridH = 24;

  static constexpr int kLearnFrames = 3;

  static constexpr int kBlockDiffThreshold = 12;


  static double thresholdPercent(int sensitivity);

  void setConfig(const MotionConfig& cfg);
  const MotionConfig& config() const { return cfg_; }
  void onMotion(MotionCallback cb) { cb_ = std::move(cb); }



  void feed(const RawFrame& f);


  double lastChangedPercent() const { return last_pct_; }

 private:


  bool downscaleLuma(const RawFrame& f, int stride, std::vector<uint8_t>& out) const;

  MotionConfig cfg_;
  MotionCallback cb_;
  std::vector<uint8_t> prev_;
  int gw_ = 0, gh_ = 0;
  int frame_w_ = 0, frame_h_ = 0;
  int seen_ = 0;
  int streak_ = 0;
  int64_t last_fire_ms_ = INT64_MIN;
  double last_pct_ = 0.0;
};

}  // namespace db
