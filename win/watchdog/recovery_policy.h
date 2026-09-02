#pragma once

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace doorbell {

// Pure, platform-neutral recovery policy. Keeping time and persistence outside
// this class makes the policy deterministic and host-testable.
class RecoveryPolicy {
 public:
  static constexpr std::uint64_t kCrashWindowMs = 5ULL * 60ULL * 1000ULL;
  static constexpr std::size_t kSafeModeThreshold = 3;
  static constexpr std::array<unsigned, 5> kBackoffSeconds{{2, 5, 10, 30, 60}};

  void restore(bool safe_mode, std::size_t consecutive_failures,
               const std::vector<std::uint64_t>& failure_times_ms) {
    safe_mode_ = safe_mode;
    consecutive_failures_ = consecutive_failures;
    failure_times_ms_ = failure_times_ms;
    std::sort(failure_times_ms_.begin(), failure_times_ms_.end());
  }

  unsigned recordFailure(std::uint64_t now_ms) {
    prune(now_ms);
    failure_times_ms_.push_back(now_ms);
    ++consecutive_failures_;
    if (failure_times_ms_.size() >= kSafeModeThreshold) safe_mode_ = true;
    return backoffSeconds(consecutive_failures_ - 1);
  }

  void recordHealthy() {
    consecutive_failures_ = 0;
    failure_times_ms_.clear();
    // Safe mode is deliberately sticky. An administrator must explicitly clear
    // it after inspecting the device; a healthy interval alone is not evidence
    // that the original crash loop is fixed.
  }

  void clearSafeMode() {
    safe_mode_ = false;
    recordHealthy();
  }

  void prune(std::uint64_t now_ms) {
    const auto first = std::lower_bound(
        failure_times_ms_.begin(), failure_times_ms_.end(),
        now_ms > kCrashWindowMs ? now_ms - kCrashWindowMs : 0);
    failure_times_ms_.erase(failure_times_ms_.begin(), first);
  }

  static unsigned backoffSeconds(std::size_t retry_index) {
    return kBackoffSeconds[(std::min)(retry_index, kBackoffSeconds.size() - 1)];
  }

  bool safeMode() const { return safe_mode_; }
  std::size_t consecutiveFailures() const { return consecutive_failures_; }
  const std::vector<std::uint64_t>& failureTimes() const { return failure_times_ms_; }

 private:
  bool safe_mode_ = false;
  std::size_t consecutive_failures_ = 0;
  std::vector<std::uint64_t> failure_times_ms_;
};

}  // namespace doorbell
