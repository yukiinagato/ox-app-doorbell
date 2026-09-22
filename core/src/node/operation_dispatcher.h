#pragma once

#include <functional>
#include <memory>
#include <string>

#include "httpd/httpd.h"
#include "util/runloop.h"

namespace db {

// A bounded HTTP/native waiter. Only begin/stop and the handler run on the state loop;
// request runs on a worker. Posted work owns no caller stack or connection, and an expired
// lifetime cannot call a destroyed Node even when its borrowed Runloop keeps running.
class OperationDispatcher {
 public:
  using Complete = std::function<void(HttpResp)>;
  using Handler = std::function<void(const HttpReq&, const Complete&)>;
  static constexpr size_t kCapacity = 32;
  static constexpr int64_t kTimeoutMs = 4000;
  struct Limits {
    size_t capacity = kCapacity;
    size_t body_bytes = 8192;
    int64_t timeout_ms = kTimeoutMs;
    std::function<HttpResp(const std::string&, int)> failure;
  };

  explicit OperationDispatcher(Runloop& loop);
  OperationDispatcher(Runloop& loop, Limits limits);
  ~OperationDispatcher();
  void begin(Handler handler);
  void stop();
  HttpResp request(HttpReq request);
#if defined(DB_HTTPD_TEST_HOOKS)
  size_t pendingCountForTesting() const;
#endif

 private:
  struct Shared;
  Runloop& loop_;
  std::shared_ptr<Shared> shared_;
};

HttpResp operationFailure(const std::string& error, int status,
                          const std::string& request_id = "");

}  // namespace db
