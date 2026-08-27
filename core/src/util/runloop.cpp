#include "util/runloop.h"

#include <chrono>

namespace db {

Runloop::Runloop(IClock& clock) : clock_(clock) {}

Runloop::~Runloop() { stop(); }

void Runloop::start() {
  std::lock_guard<std::mutex> lk(mu_);
  if (running_) return;
  running_ = true;
  stop_requested_ = false;
  thread_ = std::thread([this] { loopMain(); });
}

void Runloop::stop() {
  {
    std::lock_guard<std::mutex> lk(mu_);
    if (!running_) return;
    stop_requested_ = true;
  }
  cv_.notify_all();
  if (thread_.joinable()) thread_.join();
  std::lock_guard<std::mutex> lk(mu_);
  running_ = false;
}

uint64_t Runloop::postDelayed(int64_t delay_ms, std::function<void()> fn, int64_t period_ms) {
  std::lock_guard<std::mutex> lk(mu_);
  uint64_t id = next_id_++;
  int64_t due = clock_.monoMs() + (delay_ms < 0 ? 0 : delay_ms);
  queue_.emplace(Key{due, next_order_++}, Task{id, period_ms, std::move(fn)});
  cv_.notify_all();
  return id;
}

void Runloop::cancel(uint64_t id) {
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
    if (cancelled_.erase(t.id) == 0 && !stop_requested_) {
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
  while (!stop_requested_) {
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

void Runloop::callSync(const std::function<void()>& fn) {
  bool have_thread;
  {
    std::lock_guard<std::mutex> lk(mu_);
    have_thread = running_;
  }
  if (!have_thread || onLoopThread()) {
    fn();  // manual モード or ループスレッド上: inline 実行
    return;
  }
  std::mutex m;
  std::condition_variable done_cv;
  bool done = false;
  post([&] {
    fn();
    {
      std::lock_guard<std::mutex> g(m);
      done = true;
    }
    done_cv.notify_one();
  });
  std::unique_lock<std::mutex> g(m);
  done_cv.wait(g, [&] { return done; });
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
