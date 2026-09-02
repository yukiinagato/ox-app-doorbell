
// Single-thread state executor. Production uses start/stop with RealClock; deterministic tests
// leave it in manual mode, advance SimClock, and call pumpDue.




#pragma once

#include <condition_variable>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <thread>
#include <vector>

#include "util/clock.h"

namespace db {

class Runloop {
 public:
  explicit Runloop(IClock& clock);
  ~Runloop();

  Runloop(const Runloop&) = delete;
  Runloop& operator=(const Runloop&) = delete;

  void start();
  void stop();

  bool post(std::function<void()> fn) { return postDelayed(0, std::move(fn)) != 0; }

  uint64_t postDelayed(int64_t delay_ms, std::function<void()> fn, int64_t period_ms = 0);
  uint64_t postEvery(int64_t period_ms, std::function<void()> fn) {
    return postDelayed(period_ms, std::move(fn), period_ms);
  }
  void cancel(uint64_t id);



  // Executes inline on the loop/manual thread, waits while running, and returns false after stop.
  bool callSync(const std::function<void()>& fn);
  bool onLoopThread() const;

  IClock& clock() { return clock_; }



  size_t pumpDue();

  int64_t nextDueMono();

 private:
  struct Task {
    uint64_t id;
    int64_t period_ms;
    std::function<void()> fn;
  };
  using Key = std::pair<int64_t, uint64_t>;
  struct SyncWaiter {
    std::mutex m;
    std::condition_variable cv;
    bool done = false;
    bool aborted = false;
  };
  enum class State { Manual, Running, Stopping, Stopped };

  void loopMain();
  bool runOne_(std::unique_lock<std::mutex>& lk);

  IClock& clock_;
  std::mutex mu_;
  std::condition_variable cv_;
  std::multimap<Key, Task> queue_;
  std::set<uint64_t> cancelled_;
  uint64_t next_id_ = 1;
  uint64_t next_order_ = 1;
  State state_ = State::Manual;
  std::vector<std::weak_ptr<SyncWaiter>> sync_waiters_;
  std::thread thread_;
  std::thread::id loop_tid_{};
};

}  // namespace db
