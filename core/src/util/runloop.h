// 単一スレッドのイベントループ。コアの全状態はこのループ上でのみ触る。
//
// 2 つの動作モード:
//  - threaded: start()/stop()。実機用 (RealClock 前提)。
//  - manual:   start() を呼ばない。テスト/シミュレーション用 —
//              SimClock を進めて pumpDue() を呼ぶ (決定的実行)。
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
  // 戻り値はタイマーID (cancel 用)。0 は停止中/無効。period_ms>0 なら繰り返し。
  uint64_t postDelayed(int64_t delay_ms, std::function<void()> fn, int64_t period_ms = 0);
  uint64_t postEvery(int64_t period_ms, std::function<void()> fn) {
    return postDelayed(period_ms, std::move(fn), period_ms);
  }
  void cancel(uint64_t id);

  // 他スレッドから同期実行。manual/ループ内なら inline。実行できたら true を返す。
  // Running で queue へ待機し、停止状態では false。
  bool callSync(const std::function<void()>& fn);
  bool onLoopThread() const;

  IClock& clock() { return clock_; }

  // --- manual モード用 ---
  // clock_.monoMs() 時点までに due のタスクを全部実行。実行件数を返す。
  size_t pumpDue();
  // 次の due (mono ms)。無ければ -1。
  int64_t nextDueMono();

 private:
  struct Task {
    uint64_t id;
    int64_t period_ms;
    std::function<void()> fn;
  };
  using Key = std::pair<int64_t, uint64_t>;  // (due_mono, order) — 決定的順序
  struct SyncWaiter {
    std::mutex m;
    std::condition_variable cv;
    bool done = false;
    bool aborted = false;
  };
  enum class State { Manual, Running, Stopping, Stopped };

  void loopMain();
  bool runOne_(std::unique_lock<std::mutex>& lk);  // due タスクを1件実行

  IClock& clock_;
  std::mutex mu_;
  std::condition_variable cv_;
  std::multimap<Key, Task> queue_;
  std::set<uint64_t> cancelled_;  // 実行中に cancel された繰り返しタスク
  uint64_t next_id_ = 1;
  uint64_t next_order_ = 1;
  State state_ = State::Manual;
  std::vector<std::weak_ptr<SyncWaiter>> sync_waiters_;
  std::thread thread_;
  std::thread::id loop_tid_{};
};

}  // namespace db
