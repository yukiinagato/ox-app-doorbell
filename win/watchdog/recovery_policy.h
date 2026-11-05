#pragma once

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace doorbell {

// Process exit codes DoorbellApp uses to tell the supervisor why it ended. Anything else,
// including an unhandled-exception exit, is a crash.
constexpr std::uint32_t kExitClean = 0;            // an administrator closed the app
constexpr std::uint32_t kExitRestartRequested = 3;  // factory reset, re-pair: start again now
constexpr std::uint32_t kExitSessionEnded = 4;      // logoff or move to another console session
constexpr std::uint32_t kExitAlreadyRunning = 5;    // another instance owns the device

enum class ExitKind { clean, restart_requested, session_ended, already_running, failure };

// Classifies one child exit. A heartbeat timeout is always a failure. An exit the supervisor
// caused or observed because the console session ended is never a failure, whatever code the
// process reported. expected_reason is what the app announced over the supervisor channel just
// before exiting ("clean", "restart", "session"); it covers exits whose code was lost.
inline ExitKind classifyExit(std::uint32_t exit_code, bool heartbeat_timeout,
                             bool session_ended, const std::string& expected_reason) {
  if (heartbeat_timeout) return ExitKind::failure;
  if (session_ended || exit_code == kExitSessionEnded || expected_reason == "session")
    return ExitKind::session_ended;
  if (exit_code == kExitRestartRequested || expected_reason == "restart")
    return ExitKind::restart_requested;
  if (exit_code == kExitAlreadyRunning) return ExitKind::already_running;
  if (exit_code == kExitClean && expected_reason == "clean") return ExitKind::clean;
  // A bare zero without the announcement is treated as clean too: WPF Shutdown(0) is the only
  // way the shell exits with zero, and it is never the result of a crash.
  if (exit_code == kExitClean) return ExitKind::clean;
  return ExitKind::failure;
}

// Pure, platform-neutral recovery policy. Keeping time and persistence outside
// this class makes the policy deterministic and host-testable.
class RecoveryPolicy {
 public:
  static constexpr std::uint64_t kCrashWindowMs = 5ULL * 60ULL * 1000ULL;
  static constexpr std::size_t kSafeModeThreshold = 3;
  // Safe mode lifts itself once the app has gone this long without another failure. A device
  // that keeps crashing in safe mode stays there; one that recovered does not need a visit.
  static constexpr std::uint64_t kSafeModeAutoClearMs = 60ULL * 60ULL * 1000ULL;
  static constexpr std::array<unsigned, 5> kBackoffSeconds{{2, 5, 10, 30, 60}};

  void restore(bool safe_mode, std::size_t consecutive_failures,
               const std::vector<std::uint64_t>& failure_times_ms,
               std::uint64_t last_failure_ms = 0) {
    safe_mode_ = safe_mode;
    consecutive_failures_ = consecutive_failures;
    failure_times_ms_ = failure_times_ms;
    std::sort(failure_times_ms_.begin(), failure_times_ms_.end());
    last_failure_ms_ = last_failure_ms;
    if (last_failure_ms_ == 0 && !failure_times_ms_.empty())
      last_failure_ms_ = failure_times_ms_.back();
  }

  unsigned recordFailure(std::uint64_t now_ms) {
    prune(now_ms);
    failure_times_ms_.push_back(now_ms);
    last_failure_ms_ = now_ms;
    ++consecutive_failures_;
    if (failure_times_ms_.size() >= kSafeModeThreshold) safe_mode_ = true;
    return backoffSeconds(consecutive_failures_ - 1);
  }

  void recordHealthy() {
    consecutive_failures_ = 0;
    failure_times_ms_.clear();
  }

  // Lifts safe mode after kSafeModeAutoClearMs without a failure. Returns true when it did.
  bool maybeAutoClear(std::uint64_t now_ms) {
    if (!safe_mode_) return false;
    if (last_failure_ms_ == 0) last_failure_ms_ = now_ms;
    if (now_ms < last_failure_ms_ || now_ms - last_failure_ms_ < kSafeModeAutoClearMs)
      return false;
    clearSafeMode();
    return true;
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
  std::uint64_t lastFailureMs() const { return last_failure_ms_; }

 private:
  bool safe_mode_ = false;
  std::size_t consecutive_failures_ = 0;
  std::vector<std::uint64_t> failure_times_ms_;
  std::uint64_t last_failure_ms_ = 0;
};

}  // namespace doorbell
