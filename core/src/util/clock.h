// 時計の注入点。実機は RealClock、テスト/シミュレーションは SimClock。
// wallMs は旧端末では大きく狂い得る前提 (CMOS 電池切れ等) — 順序付けには HLC を使うこと。
#pragma once

#include <atomic>
#include <chrono>
#include <cstdint>

namespace db {

class IClock {
 public:
  virtual ~IClock() = default;
  virtual int64_t wallMs() = 0;  // epoch ms (信頼しない)
  virtual int64_t monoMs() = 0;  // 単調増加 ms (タイマー・心跳用)
};

class RealClock : public IClock {
 public:
  int64_t wallMs() override {
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

// テスト用: 手動で進める。wall と mono は独立に操作可能 (時計跳び注入)。
class SimClock : public IClock {
 public:
  explicit SimClock(int64_t wall_start_ms = 1'700'000'000'000LL, int64_t mono_start_ms = 0)
      : wall_(wall_start_ms), mono_(mono_start_ms) {}
  int64_t wallMs() override { return wall_.load(); }
  int64_t monoMs() override { return mono_.load(); }
  void advance(int64_t ms) {
    mono_ += ms;
    wall_ += ms;
  }
  void setWall(int64_t ms) { wall_ = ms; }  // 時計跳びの注入
  void setMono(int64_t ms) { mono_ = ms; }

 private:
  std::atomic<int64_t> wall_;
  std::atomic<int64_t> mono_;
};

}  // namespace db
