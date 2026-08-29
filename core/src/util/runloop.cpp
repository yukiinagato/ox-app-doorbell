#include "util/runloop.h"

#include <algorithm>
#include <chrono>

namespace db {

Runloop::Runloop(IClock& clock) : clock_(clock) {}

Runloop::~Runloop() { stop(); }

void Runloop::start() {
  std::lock_guard<std::mutex> lk(mu_);
  if (state_ != State::Manual) return;
  state_ = State::Running;
  // Stopped の再起動はサポートしない: 実行中状態遷移を再現しきれないため。
  thread_ = std::thread([this] { loopMain(); });
}

void Runloop::stop() {
  {
    std::lock_guard<std::mutex> lk(mu_);
    if (state_ != State::Running) return;
    state_ = State::Stopping;
  }
  cv_.notify_all();
  if (thread_.joinable()) thread_.join();
  std::lock_guard<std::mutex> lk(mu_);
  for (auto& w : sync_waiters_) {
    if (auto s = w.lock()) {
      std::lock_guard<std::mutex> ws(s->m);
      if (!s->done) s->aborted = true;
      s->cv.notify_all();
    }
  }
  sync_waiters_.clear();
  state_ = State::Stopped;
}

uint64_t Runloop::postDelayed(int64_t delay_ms, std::function<void()> fn, int64_t period_ms) {
  std::lock_guard<std::mutex> lk(mu_);
  if (state_ != State::Manual && state_ != State::Running) return 0;
  uint64_t id = next_id_++;
  int64_t due = clock_.monoMs() + (delay_ms < 0 ? 0 : delay_ms);
  queue_.emplace(Key{due, next_order_++}, Task{id, period_ms, std::move(fn)});
  cv_.notify_all();
  return id;
}

void Runloop::cancel(uint64_t id) {
  if (id == 0) return;
  std::lock_guard<std::mutex> lk(mu_);
  for (auto it = queue_.begin(); it != queue_.end(); ++it) {
    if (it->second.id == id) {
      queue_.erase(it);
      return;
    }
  }
  // キューに無い = 実行中の繰り返しタスク (再スケジュール前) の可能性 → 印を残す
  cancelled_.insert(id);
}

bool Runloop::runOne_(std::unique_lock<std::mutex>& lk) {
  if (queue_.empty()) return false;
  auto it = queue_.begin();
  if (it->first.first > clock_.monoMs()) return false;
  Task t = std::move(it->second);
  queue_.erase(it);
  lk.unlock();
  t.fn();
  lk.lock();
  if (t.period_ms > 0) {
    if (cancelled_.erase(t.id) == 0 &&
        (state_ == State::Manual || state_ == State::Running)) {
      queue_.emplace(Key{clock_.monoMs() + t.period_ms, next_order_++},
                     Task{t.id, t.period_ms, std::move(t.fn)});
    }
  } else {
    cancelled_.erase(t.id);
  }
  return true;
}

void Runloop::loopMain() {
  {
    std::lock_guard<std::mutex> lk(mu_);
    loop_tid_ = std::this_thread::get_id();
  }
  std::unique_lock<std::mutex> lk(mu_);
  while (state_ == State::Running) {
    if (runOne_(lk)) continue;
    if (queue_.empty()) {
      cv_.wait(lk);
    } else {
      int64_t due = queue_.begin()->first.first;
      int64_t now = clock_.monoMs();
      if (due > now) cv_.wait_for(lk, std::chrono::milliseconds(due - now));
    }
  }
  loop_tid_ = std::thread::id{};
}

bool Runloop::onLoopThread() const {
  std::lock_guard<std::mutex> lk(const_cast<std::mutex&>(mu_));
  return loop_tid_ == std::this_thread::get_id() && loop_tid_ != std::thread::id{};
}

bool Runloop::callSync(const std::function<void()>& fn) {
  std::shared_ptr<SyncWaiter> waiter;
  {
    std::unique_lock<std::mutex> lk(mu_);
    if (state_ == State::Manual) {
      lk.unlock();
      fn();
      return true;
    }
    if (state_ == State::Running && loop_tid_ == std::this_thread::get_id()) {
      lk.unlock();
      fn();
      return true;
    }
    if (state_ != State::Running) return false;
    waiter = std::make_shared<SyncWaiter>();
    sync_waiters_.push_back(waiter);
    uint64_t id = next_id_++;
    queue_.emplace(Key{clock_.monoMs(), next_order_++},
                   Task{id, 0, [this, waiter, fn] {
                     fn();
                     {
                       std::lock_guard<std::mutex> ls(waiter->m);
                       waiter->done = true;
                     }
                     waiter->cv.notify_one();
                     {
                       std::lock_guard<std::mutex> lk(mu_);
                       sync_waiters_.erase(std::remove_if(sync_waiters_.begin(), sync_waiters_.end(),
                                                          [&waiter](const std::weak_ptr<SyncWaiter>& wk) {
                                                            auto cur = wk.lock();
                                                            return !cur || cur == waiter;
                                                          }),
                                          sync_waiters_.end());
                     }
                   }});
    cv_.notify_all();
  }
  std::unique_lock<std::mutex> lk(waiter->m);
  waiter->cv.wait(lk, [&waiter] { return waiter->done || waiter->aborted; });
  return waiter->done && !waiter->aborted;
}

size_t Runloop::pumpDue() {
  std::unique_lock<std::mutex> lk(mu_);
  size_t n = 0;
  while (runOne_(lk)) n++;
  return n;
}

int64_t Runloop::nextDueMono() {
  std::lock_guard<std::mutex> lk(mu_);
  return queue_.empty() ? -1 : queue_.begin()->first.first;
}

}  // namespace db
