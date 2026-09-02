#pragma once

#include <atomic>
#include <chrono>
#include <cstdint>

namespace db {

// wallMs() is the corrected wall clock: the raw platform clock plus the offset the optional
// time service (SNTP) measured. Every consumer -- the HLC, event timestamps, schedules and
// displayed clocks -- reads it, so enabling NTP corrects all of them at once. The offset is zero
// unless time.ntp.enabled is on and a recent sync succeeded, and the platform clock itself is
// never modified.
class IClock {
 public:
  virtual ~IClock() = default;
  virtual int64_t monoMs() = 0;
  // Raw platform wall clock, unaffected by the time service.
  virtual int64_t systemWallMs() = 0;

  int64_t wallMs() {
    return systemWallMs() + wall_offset_ms_.load(std::memory_order_relaxed);
  }
  void setWallOffsetMs(int64_t offset_ms) {
    wall_offset_ms_.store(offset_ms, std::memory_order_relaxed);
  }
  int64_t wallOffsetMs() const { return wall_offset_ms_.load(std::memory_order_relaxed); }

 private:
  std::atomic<int64_t> wall_offset_ms_{0};
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
