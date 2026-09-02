#include "recovery_policy.h"

#include <cassert>
#include <iostream>

int main() {
  using doorbell::RecoveryPolicy;

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
  assert(restored.recordFailure(300) == 60);

  std::cout << "watchdog recovery policy: ok\n";
  return 0;
}
