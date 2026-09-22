#include "operation_test_fixture.h"

namespace {
struct PanelOperationFleet : OperationFleet {
  PanelOperationFleet() {
    a->setSecureStore([](const std::string& key) {
      return key == "panel.operation-test" ? "test-panel-operation-credential" : "";
    }, [](const std::string&, const std::string&) { return true; });
    a->setConfigKey("panel.token_refs", R"(["secret:panel.operation-test"])");
    a->setConfigKey("panel.token_generation", R"("1234567890abcdef1234567890abcdef")");
    REQUIRE(operationWait([&] {
      auto current = json::parse(b->configJson());
      return json::getString(json::get(current.get(), "panel"), "token_generation") ==
          "1234567890abcdef1234567890abcdef";
    }));
  }
  OperationHttpResult panelLogin() {
    auto response = operationHttp(a_opts.http_port, "POST", "/api/panel/session",
        R"({"credential":"test-panel-operation-credential"})");
    REQUIRE(response.status == 200);
    REQUIRE(response.cookie.rfind("dbpanel=", 0) == 0);
    REQUIRE_FALSE(operationField(response, "csrf_token").empty());
    return response;
  }
  OperationHttpResult panelRequest(const OperationHttpResult& session, const std::string& verb,
                                   const std::string& id = "", bool discard = false) {
    const auto csrf = operationField(session, "csrf_token");
    if (verb == "query")
      return operationHttp(a_opts.http_port, "GET", "/api/operations/" + id +
          "?authority_node=" + b->nodeId() + "&action=sos_start", "", session.cookie,
          csrf, false, "");
    return operationHttp(a_opts.http_port, "POST", verb == "prepare" ? "/api/operations/prepare" :
        "/api/operations/" + id + "/execute", request("sos_start", id),
        session.cookie, csrf, discard);
  }
};
}

TEST_CASE("panel operations: remote SOS response loss preserves one session-owned intent") {
  PanelOperationFleet fleet;
  const auto owner = fleet.panelLogin(), other = fleet.panelLogin();
  auto emergencies = std::make_shared<std::atomic<int>>(0);
  fleet.b->setUiEventCb([emergencies](const std::string& text) {
    auto body = json::parse(text);
    if (json::getString(body.get(), "t") == "event" &&
        json::getString(body.get(), "type") == "emergency") ++*emergencies;
  });
  const auto prepared = fleet.panelRequest(owner, "prepare");
  CAPTURE(prepared.body);
  REQUIRE(prepared.status == 200);
  const auto id = operationField(prepared, "operation_id");
  REQUIRE(id.size() == 32);
  CHECK(operationField(prepared, "authority_node") == fleet.b->nodeId());
  auto mixed = owner;
  mixed.cookie += "; dbsess=" + fleet.cookie;
  CHECK(fleet.panelRequest(mixed, "query", id).status == 200);
  for (const auto& verb : {"query", "execute"}) {
    auto denied = fleet.panelRequest(other, verb, id);
    CHECK(denied.status == 403);
    CHECK(denied.body.find("execution_state") == std::string::npos);
  }
  fleet.panelRequest(mixed, "execute", id, true);
  REQUIRE(operationWait([&] { return *emergencies == 1; }));
  for (int attempt = 0; attempt < 3; ++attempt) {
    const auto queried = fleet.panelRequest(owner, "query", id);
    CHECK(queried.status == 200);
    CHECK(operationField(queried, "operation_id") == id);
    CHECK(operationField(queried, "execution_state") == "dispatched");
    CHECK(fleet.panelRequest(owner, "execute", id).status == 202);
  }
  CHECK(*emergencies == 1);
  fleet.b->setUiEventCb({});
}

TEST_CASE("panel operations: only SOS start with current session CSRF origin and grant is allowed") {
  PanelOperationFleet fleet;
  const auto owner = fleet.panelLogin();
  const auto csrf = operationField(owner, "csrf_token");
  for (const auto& action : {"sos_clear", "door_open"}) {
    CHECK(operationHttp(fleet.a_opts.http_port, "POST", "/api/operations/prepare",
        fleet.request(action), owner.cookie, csrf).status == 403);
  }
  const auto body = fleet.request("sos_start");
  CHECK(operationHttp(fleet.a_opts.http_port, "POST", "/api/operations/prepare", body,
      owner.cookie).status == 403);
  CHECK(operationHttp(fleet.a_opts.http_port, "POST", "/api/operations/prepare", body,
      owner.cookie, "wrong-csrf").status == 403);
  CHECK(operationHttp(fleet.a_opts.http_port, "POST", "/api/operations/prepare", body,
      owner.cookie, csrf, false, "").status == 403);
  CHECK(operationHttp(fleet.a_opts.http_port, "POST", "/api/operations/prepare", body,
      owner.cookie, csrf, false, "https://untrusted.invalid").status == 403);
  const auto prepared = fleet.panelRequest(owner, "prepare");
  CAPTURE(prepared.body);
  REQUIRE(prepared.status == 200);
  const auto id = operationField(prepared, "operation_id");
  const auto query = "/api/operations/" + id + "?authority_node=" + fleet.b->nodeId() + "&action=sos_start";
  CHECK(operationHttp(fleet.a_opts.http_port, "GET", query, "", owner.cookie).status == 403);
  CHECK(operationHttp(fleet.a_opts.http_port, "GET", query, "", owner.cookie, csrf,
      false, "https://untrusted.invalid").status == 403);
  CHECK(fleet.panelRequest(owner, "query", id).status == 200);
  auto mixed = owner;
  mixed.cookie += "; dbsess=" + fleet.cookie;
  const auto mixed_prepare = fleet.panelRequest(mixed, "prepare");
  REQUIRE(mixed_prepare.status == 200);
  CHECK(fleet.panelRequest(owner, "query", operationField(mixed_prepare, "operation_id")).status == 200);
  fleet.a->setConfigKey("devices." + fleet.a->nodeId() + ".operations.sos_start", "false");
  CHECK(fleet.panelRequest(owner, "prepare").status == 403);
  CHECK(fleet.panelRequest(owner, "execute", id).status == 403);
  CHECK(fleet.panelRequest(owner, "query", id).status == 403);
}

TEST_CASE("panel operations: credential generation changes invalidate old operation sessions") {
  PanelOperationFleet fleet;
  const auto owner = fleet.panelLogin();
  const auto prepared = fleet.panelRequest(owner, "prepare");
  REQUIRE(prepared.status == 200);
  const auto id = operationField(prepared, "operation_id");
  fleet.a->setConfigKey("panel.token_generation", R"("abcdef1234567890abcdef1234567890")");
  CHECK(fleet.panelRequest(owner, "prepare").status == 401);
  CHECK(fleet.panelRequest(owner, "execute", id).status == 401);
  CHECK(fleet.panelRequest(owner, "query", id).status == 401);
  const auto renewed = fleet.panelLogin();
  CHECK(fleet.panelRequest(renewed, "query", id).status == 403);
}
