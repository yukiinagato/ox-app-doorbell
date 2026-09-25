#include "node/operation_dispatcher.h"

#include <chrono>
#include <condition_variable>
#include <mutex>
#include <set>

#include "util/ids.h"
#include "util/json.h"
#include "node/operation_config.h"

namespace db {

HttpResp operationFailure(const std::string& error, int status, const std::string& request_id) {
  auto out = json::obj();
  json::set(out.get(), "schema_version", int64_t{2});
  json::setBool(out.get(), "ok", false);
  json::set(out.get(), "error_code", error);
  json::set(out.get(), "err", error);
  json::set(out.get(), "request_id", request_id.empty() ? genTokenHex(16) : request_id);
  json::set(out.get(), "retry_mode", error == "outcome_unknown" ? "same_operation_query" : "none");
  if (error == "outcome_unknown") json::set(out.get(), "unknown_reason", "transport_ambiguous");
  return HttpResp::json(json::dump(out.get()), status);
}

struct OperationDispatcher::Shared {
  struct Pending {
    enum class State { Queued, Running, Expired, Completed };
    HttpReq request;
    std::string request_id;
    HttpResp response;
    State state = State::Queued;
    bool shutdown = false;
    uint64_t task = 0;
    std::condition_variable cv;
    explicit Pending(int64_t timeout_ms)
        : deadline(std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms)) {}
    const std::chrono::steady_clock::time_point deadline;
  };
  std::mutex mu;
  bool open = false;
  Handler handler;
  std::set<std::shared_ptr<Pending>> pending;
  Limits limits;
  explicit Shared(Limits bounds) : limits(std::move(bounds)) {}
};

OperationDispatcher::OperationDispatcher(Runloop& loop)
    : OperationDispatcher(loop, Limits{}) {}
OperationDispatcher::OperationDispatcher(Runloop& loop, Limits limits)
    : loop_(loop), shared_(std::make_shared<Shared>(std::move(limits))) {}
OperationDispatcher::~OperationDispatcher() { stop(); }

#if defined(DB_HTTPD_TEST_HOOKS)
size_t OperationDispatcher::pendingCountForTesting() const {
  std::lock_guard<std::mutex> lock(shared_->mu);
  return shared_->pending.size();
}
#endif

void OperationDispatcher::begin(Handler handler) {
  std::lock_guard<std::mutex> lock(shared_->mu);
  shared_->handler = std::move(handler);
  shared_->open = true;
}

void OperationDispatcher::stop() {
  std::lock_guard<std::mutex> lock(shared_->mu);
  shared_->open = false;
  shared_->handler = {};
  for (const auto& p : shared_->pending) {
    p->shutdown = true;
    if (p->state == Shared::Pending::State::Queued) {
      p->state = Shared::Pending::State::Expired;
      loop_.cancelQueued(p->task);
    }
    p->cv.notify_all();
  }
}

HttpResp OperationDispatcher::request(HttpReq request) {
  const auto shared = shared_;
  const auto failure = [shared](const std::string& error, int status, const std::string& id = "") {
    return shared->limits.failure ? shared->limits.failure(error, status) : operationFailure(error, status, id);
  };
  // Blocking the state executor would prevent the authenticated mesh reply from arriving.
  if (loop_.onLoopThread()) return failure("not_started", 503);
  if (request.body.size() > shared->limits.body_bytes) return failure("capacity_exceeded", 413);
  using State = Shared::Pending::State;
  auto p = std::make_shared<Shared::Pending>(shared->limits.timeout_ms);
  p->request = std::move(request);
  const auto body = shared->limits.inspect_json_body ? json::parse(p->request.body) : json::Doc{};
  p->request_id = json::getString(body.get(), "request_id");
  if (!operationIdValid(p->request_id)) p->request_id = genTokenHex(16);
  std::unique_lock<std::mutex> lock(shared->mu);
  if (!shared->open) return failure("not_started", 503, p->request_id);
  if (shared->pending.size() >= shared->limits.capacity) return failure("capacity_exceeded", 503, p->request_id);
  shared->pending.insert(p);
  p->task = loop_.postDelayed(0, [shared, p, failure] {
    Handler handler;
    {
      std::lock_guard<std::mutex> admission(shared->mu);
      if (!shared->open || p->state != State::Queued ||
          std::chrono::steady_clock::now() >= p->deadline) {
        if (p->state == State::Queued) p->state = State::Expired;
        p->cv.notify_all();
        return;
      }
      p->state = State::Running;
      handler = shared->handler;
    }
    Complete complete = [shared, p](HttpResp response) {
      std::lock_guard<std::mutex> completion(shared->mu);
      if (p->state != State::Running || p->shutdown) return;
      p->response = std::move(response);
      p->state = State::Completed;
      p->cv.notify_all();
    };
    try { handler(p->request, complete); }
    catch (...) { complete(failure("outcome_unknown", 503, p->request_id)); }
  });
  if (!p->task) p->state = State::Expired;
  p->cv.wait_until(lock, p->deadline, [&] {
    return p->state == State::Completed || p->state == State::Expired || p->shutdown;
  });
  HttpResp response;
  if (p->state == State::Completed) response = std::move(p->response);
  else {
    if (p->state == State::Queued) p->state = State::Expired;
    response = failure(p->state == State::Expired ? "not_started" : "outcome_unknown",
                                503, p->request_id);
  }
  if (p->state == State::Expired) loop_.cancelQueued(p->task);
  shared->pending.erase(p);
  return response;
}

}  // namespace db
