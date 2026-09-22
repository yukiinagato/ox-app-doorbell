#include <atomic>
#include <chrono>
#include <future>
#include <thread>
#include <vector>

#include "doctest.h"
#include "doorbell/doorbell.h"
#include "node/operation_config.h"
#include "node/operation_dispatcher.h"
#include "node/node.h"
#include "test_env.h"
#include "util/json.h"

using namespace db;
namespace {
bool operationServiceWait(const std::function<bool()>& fn) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
  do {
    if (fn()) return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  } while (std::chrono::steady_clock::now() < deadline);
  return false;
}
std::string operationError(const HttpResp& response) {
  auto body = json::parse(response.body);
  return json::getString(body.get(), "error_code");
}
}

TEST_CASE("operations dispatcher: capacity and stop remove queued owned requests on a borrowed loop") {
  SimClock clock;
  Runloop loop(clock);
  auto dispatcher = std::make_unique<OperationDispatcher>(loop);
  std::atomic<int> invocations{0};
  dispatcher->begin([&](const HttpReq&, const OperationDispatcher::Complete& complete) {
    ++invocations;
    complete(HttpResp::json("{}"));
  });
  std::vector<std::future<HttpResp>> waiting;
  for (size_t i = 0; i < OperationDispatcher::kCapacity; ++i)
    waiting.push_back(std::async(std::launch::async, [&] { return dispatcher->request(HttpReq{}); }));
  REQUIRE(operationServiceWait([&] { return dispatcher->pendingCountForTesting() == 32; }));
  CHECK(operationError(dispatcher->request(HttpReq{})) == "capacity_exceeded");
  dispatcher->stop();
  for (auto& worker : waiting) CHECK(operationError(worker.get()) == "not_started");
  CHECK(dispatcher->pendingCountForTesting() == 0);
  dispatcher.reset();
  loop.pumpDue();
  CHECK(invocations == 0);
}

TEST_CASE("operations dispatcher: queued deadline atomically expires before a late loop starts") {
  SimClock clock;
  Runloop loop(clock);
  OperationDispatcher dispatcher(loop);
  int invocations = 0;
  dispatcher.begin([&](const HttpReq&, const OperationDispatcher::Complete& done) {
    ++invocations; done(HttpResp::json("{}"));
  });
  auto worker = std::async(std::launch::async, [&] { return dispatcher.request(HttpReq{}); });
  REQUIRE(operationServiceWait([&] { return dispatcher.pendingCountForTesting() == 1; }));
  CHECK(operationError(worker.get()) == "not_started");
  loop.pumpDue();
  CHECK(invocations == 0);
  CHECK(dispatcher.pendingCountForTesting() == 0);
}

TEST_CASE("operations dispatcher: a sent asynchronous request times out unknown and late completion owns state") {
  SimClock clock;
  Runloop loop(clock);
  auto dispatcher = std::make_unique<OperationDispatcher>(loop);
  OperationDispatcher::Complete reply;
  int invocations = 0;
  dispatcher->begin([&](const HttpReq&, const OperationDispatcher::Complete& done) {
    ++invocations; reply = done;
  });
  auto worker = std::async(std::launch::async, [&] { return dispatcher->request(HttpReq{}); });
  REQUIRE(operationServiceWait([&] { return dispatcher->pendingCountForTesting() == 1; }));
  loop.pumpDue();
  REQUIRE(invocations == 1);
  CHECK(operationError(worker.get()) == "outcome_unknown");
  dispatcher.reset();
  reply(HttpResp::json("{\"late\":true}"));
  CHECK(invocations == 1);
}

TEST_CASE("operations dispatcher: shutdown wakes a running waiter and rejects loop blocking") {
  RealClock clock;
  Runloop loop(clock);
  loop.start();
  OperationDispatcher dispatcher(loop);
  std::atomic<int> entered{0};
  dispatcher.begin([&](const HttpReq&, const OperationDispatcher::Complete&) { ++entered; });
  auto worker = std::async(std::launch::async, [&] { return dispatcher.request(HttpReq{}); });
  REQUIRE(operationServiceWait([&] { return entered == 1; }));
  loop.callSync([&] {
    CHECK(operationError(dispatcher.request(HttpReq{})) == "not_started");
    dispatcher.stop();
  });
  CHECK(operationError(worker.get()) == "outcome_unknown");
  loop.stop();
}

TEST_CASE("operations config: grants are explicit bounded typed and reject unknown security fields") {
  const std::string node(32, 'a');
  auto check = [&](const std::string& key, const std::string& text) {
    auto body = json::parse(text);
    std::string error;
    return operationConfigValid(key, body.get(), &error);
  };
  CHECK(check("devices." + node + ".operations", "{}"));
  CHECK(check("devices." + node + ".operations", "{\"doors\":[\"front\"],\"sos_start\":true,\"sos_clear\":false}"));
  CHECK_FALSE(check("devices." + node + ".operations", "{\"admin\":true}"));
  CHECK_FALSE(check("devices." + node, "{\"operations\":{\"sos_clear\":1}}"));
  CHECK_FALSE(check("devices." + node + ".operations.doors", "[\"front\",\"front\"]"));
  CHECK_FALSE(check("devices." + node + ".operations.doors", "[\"../front\"]"));
  CHECK_FALSE(check("doors.front.operations", "{\"authority_node\":\"https://caller.invalid\"}"));
  CHECK_FALSE(check("cluster.operations", "{\"sos_authority_node\":false}"));
  auto many = json::arr();
  for (int i = 0; i < 65; ++i) cJSON_AddItemToArray(many.get(), cJSON_CreateString(("door" + std::to_string(i)).c_str()));
  CHECK_FALSE(check("devices." + node + ".operations.doors", json::dump(many.get())));
}

TEST_CASE("operations ABI: versioned native calls retain ownership and derive their node principal") {
  CHECK(db_core_operation_prepare_json_v2(nullptr, "{}") == nullptr);
  CHECK(db_core_operation_execute_json_v2(nullptr, "{}") == nullptr);
  CHECK(db_core_operation_query_json_v2(nullptr, "{}") == nullptr);
  db_platform_v2 platform{};
  platform.struct_size = sizeof(platform);
  platform.version = DB_PLATFORM_V2_VERSION;
  const std::string boot = "{\"role\":\"indoor_panel\",\"listen_port\":" +
      std::to_string(testing::freeListenPort()) + ",\"http_port\":0}";
  db_core* core = db_core_create_v2(&platform, ":memory:", boot.c_str());
  REQUIRE(core);
  struct Guard { db_core* core; ~Guard() { db_core_destroy(core); } } guard{core};
  REQUIRE(db_core_start(core) == 0);
  char* text = db_core_status_json(core);
  REQUIRE(text);
  auto status = json::parse(text);
  db_free(text);
  const std::string id = json::getString(json::get(status.get(), "self"), "id");
  REQUIRE(operationIdValid(id));
  const std::string key = "devices." + id + ".operations";
  REQUIRE(db_core_set_config_json(core, key.c_str(), "{\"sos_start\":true}") == 0);
  REQUIRE(db_core_set_config_json(core, "cluster.operations.sos_authority_node", ("\"" + id + "\"").c_str()) == 0);
  const char* prepare = "{\"schema_version\":2,\"action\":\"sos_start\"}";
  text = db_core_operation_prepare_json_v2(core, prepare);
  REQUIRE(text);
  auto prepared = json::parse(text);
  db_free(text);
  CAPTURE(json::dump(prepared.get()));
  REQUIRE(json::getString(prepared.get(), "execution_state") == "prepared");
  auto body = json::obj();
  json::set(body.get(), "schema_version", int64_t{2});
  json::set(body.get(), "action", "sos_start");
  json::set(body.get(), "authority_node", id);
  json::set(body.get(), "operation_id", json::getString(prepared.get(), "operation_id"));
  const auto request = json::dump(body.get());
  for (int i = 0; i < 3; ++i) {
    text = db_core_operation_execute_json_v2(core, request.c_str());
    REQUIRE(text);
    auto executed = json::parse(text);
    db_free(text);
    CHECK(json::getString(executed.get(), "execution_state") == "dispatched");
  }
  text = db_core_operation_query_json_v2(core, request.c_str());
  REQUIRE(text);
  auto queried = json::parse(text);
  db_free(text);
  CHECK(json::getString(queried.get(), "operation_id") == json::getString(prepared.get(), "operation_id"));
  text = db_core_operation_prepare_json_v2(core, "{\"schema_version\":2,\"action\":\"sos_start\",\"principal\":\"other\"}");
  REQUIRE(text);
  CHECK(std::string(text).find("invalid_request") != std::string::npos);
  db_free(text);
}

TEST_CASE("operations Node: stop retires an actual native request before a borrowed loop outlives Node") {
  RealClock clock;
  Runloop loop(clock);
  NodeOptions options;
  options.data_dir = ":memory:";
  options.enable_beacon = false;
  options.listen_addr = "127.0.0.1:" + std::to_string(testing::freeListenPort());
  NodeDeps dependencies;
  dependencies.clock = &clock;
  dependencies.loop = &loop;
  auto node = std::make_unique<Node>(options, std::move(dependencies));
  REQUIRE(node->start());
  auto pending = std::async(std::launch::async, [&] {
    return node->operationRequestJson("prepare", "{\"schema_version\":2,\"action\":\"sos_start\"}");
  });
  REQUIRE(operationServiceWait([&] { return node->operationPendingForTesting() == 1; }));
  node->stop();
  auto result = json::parse(pending.get());
  CHECK(json::getString(result.get(), "error_code") == "not_started");
  node.reset();
  // Node's production request closure was queued, then cancelled before Impl destruction.
  loop.pumpDue();
}
