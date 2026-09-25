#pragma once

#include <atomic>
#include <chrono>
#include <cstdint>
#include <mutex>

namespace db {

// When SNTP has a nonzero correction, wallMs projects a calibrated wall-time anchor from the
// monotonic clock. This keeps OS clock steps from being added to or subtracting from that sample.
// Without a correction it follows the raw platform wall clock. The platform clock is never set.
class IClock {
 public:
  virtual ~IClock() = default;
  virtual int64_t monoMs() = 0;
  // Raw platform wall clock, unaffected by the time service.
  virtual int64_t systemWallMs() = 0;

  int64_t wallMs() {
    if (wall_offset_ms_.load(std::memory_order_relaxed) == 0) return systemWallMs();
    std::lock_guard<std::mutex> lock(anchor_mutex_);
    if (wall_offset_ms_.load(std::memory_order_relaxed) == 0) return systemWallMs();
    if (!anchored_) {
      anchor_wall_ms_.store(systemWallMs() + wall_offset_ms_.load(std::memory_order_relaxed),
                            std::memory_order_relaxed);
      anchor_mono_ms_.store(monoMs(), std::memory_order_relaxed);
      anchored_ = true;
    }
    return anchor_wall_ms_.load(std::memory_order_relaxed) +
           (monoMs() - anchor_mono_ms_.load(std::memory_order_relaxed));
  }
  void setWallOffsetMs(int64_t offset_ms) {
    std::lock_guard<std::mutex> lock(anchor_mutex_);
    wall_offset_ms_.store(offset_ms, std::memory_order_relaxed);
    if (offset_ms == 0) {
      anchored_ = false;
      return;
    }
    anchor_wall_ms_.store(systemWallMs() + offset_ms, std::memory_order_relaxed);
    anchor_mono_ms_.store(monoMs(), std::memory_order_relaxed);
    anchored_ = true;
  }
  int64_t wallOffsetMs() const { return wall_offset_ms_.load(std::memory_order_relaxed); }

 private:
  std::atomic<int64_t> wall_offset_ms_{0};
  std::atomic<int64_t> anchor_wall_ms_{0};
  std::atomic<int64_t> anchor_mono_ms_{0};
  std::mutex anchor_mutex_;
  bool anchored_ = false;
};

class RealClock : public IClock {
 public:
  int64_t systemWallMs() override {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::system_clock::now().time_since_epoch())
        .count();
  }
  int64_t monoMs() override {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
  }
};


class SimClock : public IClock {
 public:
  explicit SimClock(int64_t wall_start_ms = 1'700'000'000'000LL, int64_t mono_start_ms = 0)
      : wall_(wall_start_ms), mono_(mono_start_ms) {}
  int64_t systemWallMs() override { return wall_.load(); }
  int64_t monoMs() override { return mono_.load(); }
  void advance(int64_t ms) {
    mono_ += ms;
    wall_ += ms;
  }
  void setWall(int64_t ms) { wall_ = ms; }
  void setMono(int64_t ms) { mono_ = ms; }

 private:
  std::atomic<int64_t> wall_;
  std::atomic<int64_t> mono_;
};

}  // namespace db
