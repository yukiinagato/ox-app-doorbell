#include <atomic>
#include <cstdio>
#include <future>
#include <string>
#include <vector>

#include "doctest.h"
#include "sqlite3.h"
#include "store/store.h"
#include "test_env.h"

#if !defined(_WIN32)
#include <fcntl.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

using namespace db;

namespace {
struct Scratch {
  std::string path = db::testing::uniqueTempPath("doorbell_operations", ".sqlite");
  ~Scratch() {
    for (const auto* suffix : {"", "-wal", "-shm", ".sent"}) std::remove((path + suffix).c_str());
  }
};
OperationAuthorization authorization(const std::string& principal = "resident:alice") {
  return {principal, "credential:1", "grant:1", "config:1", true, false};
}
OperationIntent intent() {
  return {{"door_open", "d_front", "{}"}, "lock:front", "{\"command\":\"open\",\"target\":\"front\"}"};
}
std::string prepare(Store& store, int64_t mono = 1000, int64_t wall = 100000) {
  const auto result = store.operationPrepare(intent(), authorization(), mono, wall);
  REQUIRE(result.error_code.empty());
  REQUIRE(result.record.has_value());
  CHECK_FALSE(result.dispatch_acquired);
  CHECK(result.record->state == "prepared");
  return result.record->operation_id;
}
void start(Store& store, const std::string& path = ":memory:") {
  REQUIRE(store.open(path));
  REQUIRE(store.operationStart("authority-a", 100000));
}
bool sql(const std::string& path, const char* command) {
  sqlite3* connection = nullptr;
  if (sqlite3_open(path.c_str(), &connection) != SQLITE_OK) {
    if (connection) sqlite3_close(connection);
    return false;
  }
  const bool ok = sqlite3_exec(connection, command, nullptr, nullptr, nullptr) == SQLITE_OK;
  sqlite3_close(connection);
  return ok;
}
}

TEST_CASE("operations: twenty concurrent retries acquire one durable dispatch") {
  Scratch files;
  Store store;
  start(store, files.path);
  const auto id = prepare(store);
  CHECK(id.size() == 32);
  std::promise<void> release;
  const auto barrier = release.get_future().share();
  std::vector<std::future<OperationResult>> attempts;
  for (int i = 0; i < 20; ++i) {
    attempts.push_back(std::async(std::launch::async, [&] {
      barrier.wait();
      const auto accepted = store.operationAccept(id, authorization(), 1001, 100001, intent().request);
      if (!accepted.error_code.empty()) return accepted;
      return store.operationAcquireDispatch(id, authorization(), 1002, 100002, intent().request);
    }));
  }
  release.set_value();
  int acquired = 0;
  for (auto& attempt : attempts) {
    const auto result = attempt.get();
    REQUIRE(result.record.has_value());
    CHECK(result.error_code.empty());
    CHECK(result.record->state == "dispatching");
    CHECK(result.record->dispatch_acquired);
    if (result.dispatch_acquired) ++acquired;
  }
  CHECK(acquired == 1);
  const auto record = store.operationQuery(id, authorization(), 1003, 100003);
  REQUIRE(record.record.has_value());
  CHECK(record.record->intent.target_json == intent().target_json);
  CHECK(record.record->accepted_wall_ms == 100001);
  CHECK(store.operationMarkDispatched(id, "{\"adapter_accepted\":true}", 100004).error_code.empty());
  CHECK_FALSE(store.operationAcquireDispatch(id, authorization(), 1004, 100004).dispatch_acquired);
}

TEST_CASE("operations: content conflicts and revoked context never retarget a prepared intent") {
  Store store;
  start(store);
  const auto id = prepare(store);
  auto different = intent().request;
  different.door = "d_back";
  CHECK(store.operationAccept(id, authorization(), 1001, 100001, different).error_code == "idempotency_conflict");
  different = {"sos_clear", "", "{}"};
  CHECK(store.operationAccept(id, authorization(), 1001, 100001, different).error_code == "idempotency_conflict");
  CHECK(store.operationAcquireDispatch(id, authorization(), 1001, 100001).error_code == "not_accepted");
  auto changed = authorization();
  changed.config_generation = "config:2";
  auto rejected = store.operationAccept(id, changed, 1001, 100001);
  REQUIRE(rejected.record.has_value());
  CHECK(rejected.record->state == "rejected_not_started");
  CHECK(rejected.error_code == "authorization_or_configuration_changed");
  CHECK_FALSE(store.operationAcquireDispatch(id, authorization(), 1002, 100002).dispatch_acquired);
  CHECK(rejected.record->intent.actuator_id == "lock:front");
  for (int field = 0; field < 2; ++field) {
    const auto next = prepare(store);
    auto revoked = authorization();
    if (field == 0) revoked.credential_version = "credential:2";
    else revoked.grant_version = "grant:2";
    CHECK(store.operationAccept(next, revoked, 1001, 100001).error_code == "authorization_or_configuration_changed");
  }
}

TEST_CASE("operations: identity alone grants no authority and SOS has global scope") {
  Store store;
  start(store);
  auto denied = authorization();
  denied.allowed = false;
  CHECK(store.operationPrepare(intent(), denied, 1000, 100000).error_code == "forbidden");
  const auto id = prepare(store);
  CHECK(store.operationQuery(id, denied, 1001, 100001).error_code == "forbidden");
  auto other = authorization("resident:bob");
  CHECK(store.operationQuery(id, other, 1001, 100001).error_code == "forbidden");
  CHECK(store.operationAccept(id, other, 1001, 100001).error_code == "forbidden");
  other.administrator = true;
  CHECK(store.operationQuery(id, other, 1001, 100001).error_code.empty());
  CHECK(store.operationAccept(id, other, 1001, 100001).error_code == "forbidden");
  OperationIntent sos{{"sos_start", "", "{}"}, "", "{}"};
  CHECK(store.operationPrepare(sos, authorization(), 1000, 100000).error_code.empty());
  sos.request.door = "d_front";
  CHECK(store.operationPrepare(sos, authorization(), 1000, 100000).error_code == "invalid_request");
  auto parameterized = intent();
  parameterized.request.parameters_json = "{\"command\":\"close\"}";
  CHECK(store.operationPrepare(parameterized, authorization(), 1000, 100000).error_code == "invalid_request");
  parameterized = intent();
  parameterized.target_json = std::string(4097, 'x');
  CHECK(store.operationPrepare(parameterized, authorization(), 1000, 100000).error_code == "invalid_request");
  parameterized.target_json = "{} trailing";
  CHECK(store.operationPrepare(parameterized, authorization(), 1000, 100000).error_code == "invalid_request");
}

TEST_CASE("operations: expiry retention and removal cannot resurrect old identities") {
  Store store;
  start(store);
  const auto id = prepare(store);
  auto expired = store.operationAccept(id, authorization(), 31000, 130000);
  REQUIRE(expired.record.has_value());
  CHECK(expired.record->state == "expired_not_started");
  CHECK_FALSE(expired.dispatch_acquired);
  CHECK(store.operationPrune(130000 + kOperationRetentionMs, true) == 0);
  CHECK(store.operationPrune(130001 + kOperationRetentionMs, false) == 0);
  CHECK(store.operationPrune(130001 + kOperationRetentionMs, true) == 1);
  CHECK(store.operationAccept(id, authorization(), 31001, 130001).error_code == "unknown_operation");
  CHECK(store.operationAcquireDispatch(id, authorization(), 31001, 130001).error_code == "unknown_operation");
  CHECK(store.operationList(authorization(), "", 32, 31001, 130001).records.empty());
  CHECK(store.operationAcquireDispatch(std::string(32, 'f'), authorization(), 1000, 100000).error_code == "unknown_operation");
  CHECK(store.operationAccept(std::string(64, 'f'), authorization(), 1000, 100000).error_code == "invalid_request");
  CHECK(store.operationQuery(std::string(32, 'F'), authorization(), 1000, 100000).error_code == "invalid_request");
}

TEST_CASE("operations: recovery invalidates prepared and accepted without acquiring dispatch") {
  Scratch files;
  std::string prepared, accepted, old_boot;
  {
    Store store;
    start(store, files.path);
    prepared = prepare(store);
    accepted = prepare(store);
    auto result = store.operationAccept(accepted, authorization(), 1001, 100001);
    REQUIRE(result.record.has_value());
    CHECK(result.record->state == "accepted");
    old_boot = result.record->boot_generation;
  }
  Store restarted;
  start(restarted, files.path);
  auto a = restarted.operationQuery(prepared, authorization(), 10, 100010);
  auto b = restarted.operationQuery(accepted, authorization(), 10, 100010);
  REQUIRE(a.record.has_value());
  REQUIRE(b.record.has_value());
  CHECK(a.record->state == "expired_not_started");
  CHECK(b.record->state == "failed_before_dispatch");
  CHECK_FALSE(restarted.operationAcquireDispatch(accepted, authorization(), 10, 100010).dispatch_acquired);
  const auto fresh = restarted.operationPrepare(intent(), authorization(), 10, 100010);
  REQUIRE(fresh.record.has_value());
  CHECK(fresh.record->boot_generation != old_boot);
  CHECK(fresh.record->expires_mono_ms == 30010);
}

TEST_CASE("operations: a newer authority boot fences an older open connection") {
  Scratch files;
  Store older;
  start(older, files.path);
  const auto id = prepare(older);
  Store newer;
  start(newer, files.path);
  CHECK(older.operationAccept(id, authorization(), 1001, 100001).error_code == "storage_unavailable");
  CHECK_FALSE(older.operationAcquireDispatch(id, authorization(), 1001, 100001).dispatch_acquired);
  const auto recovered = newer.operationQuery(id, authorization(), 1, 100001);
  REQUIRE(recovered.record.has_value());
  CHECK(recovered.record->state == "expired_not_started");
}

TEST_CASE("operations: late authenticated actuator acknowledgement resolves unknown without resend") {
  Scratch files;
  std::string id;
  {
    Store store;
    start(store, files.path);
    id = prepare(store);
    REQUIRE(store.operationAccept(id, authorization(), 1001, 100001).error_code.empty());
    REQUIRE(store.operationAcquireDispatch(id, authorization(), 1002, 100002).dispatch_acquired);
    REQUIRE(store.operationMarkDispatched(id, "{}", 100003).error_code.empty());
  }
  Store store;
  start(store, files.path);
  auto unknown = store.operationQuery(id, authorization(), 1, 100004);
  REQUIRE(unknown.record.has_value());
  CHECK(unknown.record->state == "unknown_after_dispatch");
  CHECK(store.operationPrune(100000 + 4 * kOperationRetentionMs, true) == 0);
  CHECK_FALSE(store.operationAcquireDispatch(id, authorization(), 1, 100004).dispatch_acquired);
  CHECK(store.operationAcknowledge(id, "authority-a", "lock:front", false, "{}", 100005).error_code == "forbidden");
  CHECK(store.operationAcknowledge(id, "authority-b", "lock:front", true, "{}", 100005).error_code == "ack_mismatch");
  CHECK(store.operationAcknowledge(id, "authority-a", "lock:back", true, "{}", 100005).error_code == "ack_mismatch");
  auto acknowledged = store.operationAcknowledge(id, "authority-a", "lock:front", true,
                                                 "{\"confirmed\":true}", 100005);
  REQUIRE(acknowledged.record.has_value());
  CHECK(acknowledged.record->state == "actuator_ack");
  CHECK_FALSE(acknowledged.dispatch_acquired);
  CHECK_FALSE(store.operationAcquireDispatch(id, authorization(), 1, 100006).dispatch_acquired);
  CHECK(store.operationPrune(100006 + kOperationRetentionMs, true) == 1);
}

TEST_CASE("operations: transaction failure never returns a dispatch grant") {
  Scratch files;
  Store store;
  start(store, files.path);
  const auto id = prepare(store);
  REQUIRE(store.operationAccept(id, authorization(), 1001, 100001).error_code.empty());
  REQUIRE(sql(files.path, "CREATE TRIGGER fail_dispatch BEFORE UPDATE ON operation_ledger "
      "WHEN NEW.state='dispatching' BEGIN SELECT RAISE(FAIL,'injected dispatch failure'); END"));
  const auto failed = store.operationAcquireDispatch(id, authorization(), 1002, 100002);
  CHECK(failed.error_code == "storage_error");
  CHECK_FALSE(failed.dispatch_acquired);
  auto unchanged = store.operationQuery(id, authorization(), 1003, 100003);
  REQUIRE(unchanged.record.has_value());
  CHECK(unchanged.record->state == "accepted");
  CHECK_FALSE(unchanged.record->dispatch_acquired);
  REQUIRE(sql(files.path, "DROP TRIGGER fail_dispatch"));
  CHECK(store.operationAcquireDispatch(id, authorization(), 1004, 100004).dispatch_acquired);
}

#if !defined(_WIN32)
TEST_CASE("operations: abrupt process death before and after adapter send never causes replay") {
  for (const bool send : {false, true}) {
    Scratch files;
    int handles[2];
    REQUIRE(::pipe(handles) == 0);
    const auto child = ::fork();
    REQUIRE(child >= 0);
    if (child == 0) {
      ::close(handles[0]);
      Store store;
      if (!store.open(files.path) || !store.operationStart("authority-a", 100000)) ::_exit(10);
      const auto prepared = store.operationPrepare(intent(), authorization(), 1000, 100000);
      if (!prepared.record) ::_exit(11);
      const auto id = prepared.record->operation_id;
      if (!store.operationAccept(id, authorization(), 1001, 100001).record) ::_exit(12);
      if (!store.operationAcquireDispatch(id, authorization(), 1002, 100002).dispatch_acquired) ::_exit(13);
      if (::write(handles[1], id.data(), id.size()) != static_cast<ssize_t>(id.size())) ::_exit(14);
      if (send) {
        const int marker = ::open((files.path + ".sent").c_str(), O_CREAT | O_WRONLY | O_APPEND, 0600);
        if (marker < 0 || ::write(marker, "1", 1) != 1) ::_exit(15);
        ::close(marker);
      }
      // Skip destructors and SQLite close/checkpoint; the next process must recover the WAL.
      ::_exit(0);
    }
    ::close(handles[1]);
    char buffer[32];
    const auto count = ::read(handles[0], buffer, sizeof(buffer));
    ::close(handles[0]);
    int status = 0;
    REQUIRE(::waitpid(child, &status, 0) == child);
    REQUIRE(WIFEXITED(status));
    REQUIRE(WEXITSTATUS(status) == 0);
    REQUIRE(count == 32);
    const std::string id(buffer, sizeof(buffer));
    Store recovered;
    start(recovered, files.path);
    const auto result = recovered.operationQuery(id, authorization(), 10, 100010);
    REQUIRE(result.record.has_value());
    CHECK(result.record->state == "unknown_after_dispatch");
    CHECK_FALSE(recovered.operationAcquireDispatch(id, authorization(), 10, 100010).dispatch_acquired);
    FILE* marker = std::fopen((files.path + ".sent").c_str(), "rb");
    if (send) {
      REQUIRE(marker != nullptr);
      CHECK(std::fgetc(marker) == '1');
      CHECK(std::fgetc(marker) == EOF);
      std::fclose(marker);
    } else {
      CHECK(marker == nullptr);
      if (marker) std::fclose(marker);
    }
  }
}
#endif

TEST_CASE("operations: prepared capacity and pagination remain bounded") {
  Store store;
  start(store);
  for (size_t i = 0; i < kOperationPreparedLimit; ++i)
    REQUIRE(store.operationPrepare(intent(), authorization(), 1000, 100000).record.has_value());
  CHECK(store.operationPrepare(intent(), authorization(), 1000, 100000).error_code == "operation_capacity");
  const auto first = store.operationList(authorization(), "", 100000, 1000, 100000);
  REQUIRE(first.error_code.empty());
  REQUIRE(first.records.size() == 32);
  const auto second = store.operationList(authorization(), first.records.back().operation_id, 32, 1000, 100000);
  REQUIRE(second.records.size() == 32);
  CHECK(first.records.back().operation_id < second.records.front().operation_id);
  CHECK(store.operationPrepare(intent(), authorization(), 31000, 130000).record.has_value());
  const auto expired = store.operationQuery(first.records.front().operation_id, authorization(), 31000, 130000);
  REQUIRE(expired.record.has_value());
  CHECK(expired.record->state == "expired_not_started");
}

TEST_CASE("operations: unresolved records fill active capacity and are never silently evicted") {
  Store store;
  start(store);
  std::string first;
  for (size_t i = 0; i < kOperationActiveLimit; ++i) {
    const auto prepared = store.operationPrepare(intent(), authorization(), 1000, 100000);
    REQUIRE(prepared.record.has_value());
    const auto& id = prepared.record->operation_id;
    if (i == 0) first = id;
    REQUIRE(store.operationAccept(id, authorization(), 1001, 100001).error_code.empty());
    REQUIRE(store.operationAcquireDispatch(id, authorization(), 1002, 100002).dispatch_acquired);
    REQUIRE(store.operationMarkUnknown(id, "{}", 100003).error_code.empty());
  }
  CHECK(store.operationPrepare(intent(), authorization(), 1004, 100004).error_code == "operation_capacity");
  CHECK(store.operationPrune(100004 + 10 * kOperationRetentionMs, true) == 0);
  const auto retained = store.operationQuery(first, authorization(), 1004, 100004);
  REQUIRE(retained.record.has_value());
  CHECK(retained.record->state == "unknown_after_dispatch");
  CHECK_FALSE(store.operationAcquireDispatch(first, authorization(), 1004, 100004).dispatch_acquired);
  CHECK(store.operationPrepare(intent(), authorization(), 1004, 100004).error_code == "operation_capacity");
}

TEST_CASE("operations: all-state reservation ceiling preserves young terminal results") {
  Store store;
  start(store);
  std::string first;
  for (size_t i = 0; i < kOperationRowLimit; ++i) {
    const auto prepared = store.operationPrepare(intent(), authorization(), 1000, 100000);
    REQUIRE(prepared.record.has_value());
    const auto& id = prepared.record->operation_id;
    if (i == 0) first = id;
    REQUIRE(store.operationReject(id, "cancelled_before_dispatch", 100001).error_code.empty());
  }
  CHECK(kOperationRowLimit * kOperationReservationBytes == 48 * 1024 * 1024);
  CHECK(store.operationPrepare(intent(), authorization(), 1002, 100002).error_code == "operation_capacity");
  CHECK(store.operationPrune(100001 + kOperationRetentionMs, true) == 0);
  REQUIRE(store.operationQuery(first, authorization(), 1002, 100002).record.has_value());
  CHECK(store.operationPrune(100002 + kOperationRetentionMs, true) == kOperationRowLimit);
  CHECK(store.operationAcquireDispatch(first, authorization(), 1002, 100002).error_code == "unknown_operation");
  CHECK(store.operationPrepare(intent(), authorization(), 1002, 100002).record.has_value());
}

TEST_CASE("operations: bounded metadata and results retain existing reservations") {
  Store store;
  start(store);
  auto huge = intent();
  huge.target_json = "{\"data\":\"" + std::string(3800, 'x') + "\"}";
  CHECK(store.operationPrepare(huge, authorization(), 1000, 100000).error_code == "invalid_request");
  const auto id = prepare(store);
  REQUIRE(store.operationAccept(id, authorization(), 1001, 100001).error_code.empty());
  REQUIRE(store.operationAcquireDispatch(id, authorization(), 1002, 100002).dispatch_acquired);
  const auto maximum = "{\"x\":\"" + std::string(4088, 'x') + "\"}";
  REQUIRE(maximum.size() == 4096);
  CHECK(store.operationMarkDispatched(id, maximum + " ", 100003).error_code == "invalid_request");
  CHECK(store.operationMarkDispatched(id, maximum, 100003).error_code.empty());
  const auto retained = store.operationQuery(id, authorization(), 1004, 100004);
  REQUIRE(retained.record.has_value());
  CHECK(retained.record->result_json == maximum);
  CHECK_FALSE(store.operationAcquireDispatch(id, authorization(), 1004, 100004).dispatch_acquired);
}
