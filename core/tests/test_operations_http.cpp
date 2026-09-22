#include "operation_test_fixture.h"

TEST_CASE("operations HTTP: prepare uses the configured remote authority") {
  OperationFleet fleet;
  const auto prepared = fleet.prepare("sos_start");
  CAPTURE(prepared.body);
  REQUIRE(prepared.status == 200);
  CHECK(operationField(prepared, "execution_state") == "prepared");
  CHECK(operationField(prepared, "authority_node") == fleet.b->nodeId());
  CHECK(operationField(prepared, "operation_id").size() == 32);
}

TEST_CASE("operations HTTP: remote door retries dispatch one MQTT packet and query the same handle") {
  OperationBroker broker;
  OperationFleet fleet;
  fleet.a->setConfigKey("integrations.mqtt.host", "\"127.0.0.1\"");
  fleet.a->setConfigKey("integrations.mqtt.port", std::to_string(broker.port));
  fleet.a->setConfigKey("integrations.mqtt.base_topic", "\"operation-test\"");
  REQUIRE(operationWait([&] {
    auto status = json::parse(fleet.b->statusJson());
    return json::getString(json::get(status.get(), "bridge"), "mqtt") == "connected";
  }));
  const auto prepared = fleet.prepare("door_open");
  CAPTURE(prepared.body);
  REQUIRE(prepared.status == 200);
  const auto id = operationField(prepared, "operation_id");
  auto executed = fleet.execute("door_open", id);
  CAPTURE(executed.body);
  REQUIRE(executed.status == 202);
  CHECK(operationField(executed, "execution_state") == "dispatched");
  REQUIRE(operationWait([&] { return broker.count(id) == 1; }));
  for (int attempt = 0; attempt < 4; ++attempt) {
    CHECK(fleet.execute("door_open", id).status == 202);
    auto query = fleet.query("door_open", id);
    CHECK(query.status == 200);
    CHECK(operationField(query, "operation_id") == id);
    CHECK(operationField(query, "execution_state") == "dispatched");
  }
  CHECK(broker.count(id) == 1);
  const auto unavailable = fleet.prepare("door_open");
  REQUIRE(unavailable.status == 200);
  fleet.b->stop();
  CHECK(operationWait([&] {
    return fleet.execute("door_open", operationField(unavailable, "operation_id")).status == 503;
  }));
  CHECK(broker.count(id) == 1);
}

TEST_CASE("operations HTTP: lost SOS response is recoverable without a second intent") {
  OperationFleet fleet;
  auto emergencies = std::make_shared<std::atomic<int>>(0);
  fleet.b->setUiEventCb([emergencies](const std::string& text) {
    auto body = json::parse(text);
    if (json::getString(body.get(), "t") == "event" && json::getString(body.get(), "type") == "emergency")
      ++*emergencies;
  });
  const auto prepared = fleet.prepare("sos_start");
  REQUIRE(prepared.status == 200);
  const auto id = operationField(prepared, "operation_id");
  fleet.execute("sos_start", id, true);
  REQUIRE(operationWait([&] { return *emergencies == 1; }));
  CHECK(fleet.query("sos_start", id).status == 200);
  for (int attempt = 0; attempt < 3; ++attempt) CHECK(fleet.execute("sos_start", id).status == 202);
  CHECK(*emergencies == 1);
  auto wrong = operationHttp(fleet.a_opts.http_port, "POST", "/api/operations/" + id + "/execute",
      fleet.request("sos_clear", id), fleet.cookie, fleet.csrf);
  CHECK(wrong.status == 409);
  CHECK(*emergencies == 1);
  fleet.b->setUiEventCb({});
}

TEST_CASE("operations native: another authenticated node cannot query or execute the creator handle") {
  OperationFleet fleet;
  auto prepared = json::parse(fleet.a->operationRequestJson("prepare", fleet.request("sos_start")));
  REQUIRE(json::getString(prepared.get(), "execution_state") == "prepared");
  const auto id = json::getString(prepared.get(), "operation_id");
  for (const std::string verb : {"query", "execute"}) {
    const auto body = fleet.b->operationRequestJson(verb, fleet.request("sos_start", id));
    auto denied = json::parse(body);
    CHECK(json::getString(denied.get(), "error_code") == "permission_denied");
    CHECK(body.find("execution_state") == std::string::npos);
    CHECK(body.find("config_generation") == std::string::npos);
  }
  auto executed = json::parse(fleet.a->operationRequestJson("execute", fleet.request("sos_start", id)));
  CHECK(json::getString(executed.get(), "execution_state") == "dispatched");
  auto queried = json::parse(fleet.a->operationRequestJson("query", fleet.request("sos_start", id)));
  CHECK(json::getString(queried.get(), "execution_state") == "dispatched");
}

TEST_CASE("operations HTTP: changed configuration rejects an unstarted immutable intent") {
  OperationFleet fleet;
  const auto prepared = fleet.prepare("sos_start");
  REQUIRE(prepared.status == 200);
  const auto id = operationField(prepared, "operation_id");
  fleet.b->setConfigKey("doors.front.unlock.command", "\"replacement\"");
  REQUIRE(operationWait([&] { return fleet.b->configJson().find("replacement") != std::string::npos; }));
  const auto response = fleet.execute("sos_start", id);
  CHECK(response.status == 409);
  CHECK(operationField(response, "error_code") == "config_conflict");
  CHECK(operationField(fleet.query("sos_start", id), "execution_state") == "rejected_not_started");
  REQUIRE(fleet.a->setAdminPassword("testpw", "new-operation-password") == 0);
  CHECK(fleet.prepare("sos_start").status == 401);
}

TEST_CASE("operations HTTP: current grants and CSRF guard prepare execute and query") {
  OperationFleet fleet;
  auto no_csrf = operationHttp(fleet.a_opts.http_port, "POST", "/api/operations/prepare",
      fleet.request("sos_start"), fleet.cookie);
  CHECK(no_csrf.status == 403);
  auto prepared = fleet.prepare("sos_start");
  REQUIRE(prepared.status == 200);
  const auto id = operationField(prepared, "operation_id");
  const auto b_login = operationHttp(fleet.b_opts.http_port, "POST", "/api/login", "{\"password\":\"testpw\"}");
  REQUIRE(b_login.status == 200);
  const auto b_csrf = operationField(b_login, "csrf_token");
  const auto other = operationHttp(fleet.b_opts.http_port, "POST", "/api/operations/" + id + "/execute",
      fleet.request("sos_start", id), b_login.cookie, b_csrf);
  CHECK(other.status == 403);
  CHECK(other.body.find("execution_state") == std::string::npos);
  fleet.a->setConfigKey("devices." + fleet.a->nodeId() + ".operations.sos_start", "false");
  REQUIRE(operationWait([&] { return fleet.prepare("sos_start").status == 403; }));
  CHECK(fleet.query("sos_start", id).status == 403);
  CHECK(fleet.execute("sos_start", id).status == 403);
  CHECK(fleet.query("sos_start", id).body.find("execution_state") == std::string::npos);
}

TEST_CASE("operations bridge: frozen endpoint refuses the stale adapter before configuration applies") {
  OperationBroker broker;
  RealClock clock;
  Runloop loop(clock);
  loop.start();
  HaBridge bridge(loop, {});
  struct Cleanup {
    Runloop& loop;
    HaBridge& bridge;
    ~Cleanup() { loop.callSync([&] { bridge.stop(); }); loop.stop(); }
  } cleanup{loop, bridge};
  const std::string node(32, 'b');
  const std::string id(32, 'f');
  auto config = [&](const std::string& base) {
    return "{\"integrations\":{\"mqtt\":{\"host\":\"127.0.0.1\",\"port\":" +
        std::to_string(broker.port) + ",\"base_topic\":\"" + base + "\"}}}";
  };
  loop.callSync([&] { bridge.configure(config("previous-operation-test"), node, true); });
  REQUIRE(operationWait([&] {
    bool connected = false;
    loop.callSync([&] { connected = bridge.mqttStatus() == "connected"; });
    return connected;
  }));
  const auto frozen = HaBridge::operationBinding("127.0.0.1", broker.port, "operation-test");
  // The configuration is committed while the active adapter still has its old topic binding.
  loop.callSync([&] {
    CHECK_FALSE(bridge.operationReady(frozen));
    CHECK_FALSE(bridge.dispatchOperation("front", "unlock", id, node, frozen));
  });
  CHECK(broker.count(id) == 0);
  loop.callSync([&] { bridge.configure(config("operation-test"), node, true); });
  REQUIRE(operationWait([&] {
    bool ready = false;
    loop.callSync([&] { ready = bridge.operationReady(frozen); });
    return ready;
  }));
  loop.callSync([&] { CHECK(bridge.dispatchOperation("front", "unlock", id, node, frozen)); });
  REQUIRE(operationWait([&] { return broker.count(id) == 1; }));
}
