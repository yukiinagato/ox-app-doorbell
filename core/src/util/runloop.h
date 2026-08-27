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
#include <mutex>
#include <set>
#include <thread>

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

  void post(std::function<void()> fn) { postDelayed(0, std::move(fn)); }
  // 戻り値はタイマーID (cancel 用)。period_ms>0 なら繰り返し。
  uint64_t postDelayed(int64_t delay_ms, std::function<void()> fn, int64_t period_ms = 0);
  uint64_t postEvery(int64_t period_ms, std::function<void()> fn) {
    return postDelayed(period_ms, std::move(fn), period_ms);
  }
  void cancel(uint64_t id);

  // 他スレッドから同期実行 (ループスレッド上なら inline 実行、
  // manual モード = ループスレッド無しでも inline 実行)。
  void callSync(const std::function<void()>& fn);
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

  void loopMain();
  bool runOne_(std::unique_lock<std::mutex>& lk);  // due タスクを1件実行

  IClock& clock_;
  std::mutex mu_;
  std::condition_variable cv_;
  std::multimap<Key, Task> queue_;
  std::set<uint64_t> cancelled_;  // 実行中に cancel された繰り返しタスク
  uint64_t next_id_ = 1;
  uint64_t next_order_ = 1;
  bool running_ = false;
  bool stop_requested_ = false;
  std::thread thread_;
  std::thread::id loop_tid_{};
};

}  // namespace db
