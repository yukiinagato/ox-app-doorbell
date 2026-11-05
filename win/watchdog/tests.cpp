#include "recovery_policy.h"

#include <cassert>
#include <iostream>

int main() {
  using doorbell::ExitKind;
  using doorbell::RecoveryPolicy;
  using doorbell::classifyExit;

  assert(RecoveryPolicy::backoffSeconds(0) == 2);
  assert(RecoveryPolicy::backoffSeconds(1) == 5);
  assert(RecoveryPolicy::backoffSeconds(2) == 10);
  assert(RecoveryPolicy::backoffSeconds(3) == 30);
  assert(RecoveryPolicy::backoffSeconds(4) == 60);
  assert(RecoveryPolicy::backoffSeconds(99) == 60);

  RecoveryPolicy policy;
  assert(policy.recordFailure(1'000) == 2);
  assert(policy.recordFailure(60'000) == 5);
  assert(!policy.safeMode());
  assert(policy.recordFailure(299'000) == 10);
  assert(policy.safeMode());

  policy.recordHealthy();
  assert(policy.safeMode());
  assert(policy.consecutiveFailures() == 0);
  assert(policy.failureTimes().empty());
  policy.clearSafeMode();
  assert(!policy.safeMode());

  RecoveryPolicy outside_window;
  outside_window.recordFailure(1'000);
  outside_window.recordFailure(2'000);
  outside_window.recordFailure(RecoveryPolicy::kCrashWindowMs + 2'001);
  assert(!outside_window.safeMode());
  assert(outside_window.failureTimes().size() == 1);

  RecoveryPolicy restored;
  restored.restore(true, 7, {100, 200});
  assert(restored.safeMode());
  assert(restored.lastFailureMs() == 200);
  assert(restored.recordFailure(300) == 60);

  // Safe mode lifts itself an hour after the last failure, and not before.
  RecoveryPolicy looping;
  looping.recordFailure(10'000);
  looping.recordFailure(20'000);
  looping.recordFailure(30'000);
  assert(looping.safeMode());
  assert(!looping.maybeAutoClear(30'000 + RecoveryPolicy::kSafeModeAutoClearMs - 1));
  assert(looping.safeMode());
  assert(looping.maybeAutoClear(30'000 + RecoveryPolicy::kSafeModeAutoClearMs));
  assert(!looping.safeMode());
  assert(looping.consecutiveFailures() == 0);
  assert(!looping.maybeAutoClear(99'999'999));

  // Deliberate exits never count as crashes.
  assert(classifyExit(0, false, false, "") == ExitKind::clean);
  assert(classifyExit(0, false, false, "clean") == ExitKind::clean);
  assert(classifyExit(3, false, false, "") == ExitKind::restart_requested);
  assert(classifyExit(1, false, false, "restart") == ExitKind::restart_requested);
  assert(classifyExit(4, false, false, "") == ExitKind::session_ended);
  assert(classifyExit(0xC0000005u, false, true, "") == ExitKind::session_ended);
  assert(classifyExit(1, false, false, "session") == ExitKind::session_ended);
  assert(classifyExit(5, false, false, "") == ExitKind::already_running);
  assert(classifyExit(0xE0434352u, false, false, "") == ExitKind::failure);
  assert(classifyExit(1, false, false, "") == ExitKind::failure);
  // A hang the supervisor had to kill is a failure even if a reason was announced.
  assert(classifyExit(3, true, false, "restart") == ExitKind::failure);

  // Three factory resets in a row must not reach safe mode: only failures are recorded.
  RecoveryPolicy resets;
  for (int i = 0; i < 3; ++i)
    if (classifyExit(3, false, false, "restart") == ExitKind::failure)
      resets.recordFailure(1'000 + i);
  assert(!resets.safeMode());

  std::cout << "watchdog recovery policy: ok\n";
  return 0;
}
