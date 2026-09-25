#if !defined(_WIN32)
#include "operation_test_fixture.h"
#include <memory>
#include <string>

namespace {
struct RevocationFixture {
  SimClock clock{1700000000000LL, 1000};
  Runloop loop{clock};
  NodeOptions options;
  std::mutex secret_mutex;
  std::map<std::string, std::string> secrets{
      {"panel.a", "revocation-a"}, {"panel.b", "revocation-b"},
      {"panel.legacy", "revocation-legacy"}};
  bool fail_put = false;
  std::unique_ptr<Node> node;
  OperationHttpResult admin, a, b, legacy;

  RevocationFixture() {
    options.data_dir = ":memory:";
    options.role = "door_station";
    options.door = "front";
    options.listen_addr = "127.0.0.1:" + std::to_string(testing::freeListenPort());
    options.http_port = testing::freeListenPort();
    options.enable_beacon = false;
    options.psk.fill(0x4a);
    loop.start();
    NodeDeps deps; deps.clock = &clock; deps.loop = &loop;
    node.reset(new Node(options, std::move(deps)));
    node->setSecureStore([this](const std::string& key) {
      std::lock_guard<std::mutex> lock(secret_mutex);
      const auto it = secrets.find(key);
      return it == secrets.end() ? std::string() : it->second;
    }, [this](const std::string& key, const std::string& value) {
      std::lock_guard<std::mutex> lock(secret_mutex);
      if (fail_put) return false;
      if (value.empty()) secrets.erase(key);
      else secrets[key] = value;
      return true;
    });
    REQUIRE(node->start());
    config("doors.front", R"({"label":{"en":"Front"}})");
    config("panel.token_refs", R"(["secret:panel.legacy"])");
    config("panel.identities." + std::string(32, 'a'),
        R"({"credential_ref":"secret:panel.a","credential_generation":"cccccccccccccccccccccccccccccccc","revoked":false,"door_scope":["front"],"grants":["view","call.answer","media.publish"]})");
    config("panel.identities." + std::string(32, 'b'),
        R"({"credential_ref":"secret:panel.b","credential_generation":"dddddddddddddddddddddddddddddddd","revoked":false,"door_scope":["front"],"grants":["view"]})");
    admin = operationHttp(options.http_port, "POST", "/api/login", R"({"password":"testpw"})");
    REQUIRE(admin.status == 200);
    a = login("revocation-a");
    b = login("revocation-b");
    legacy = login("revocation-legacy");
  }
  ~RevocationFixture() { node->stop(); loop.stop(); }
  void config(const std::string& key, const std::string& value) {
    const auto text = node->setConfigJson(key, value);
    INFO(key << ": " << text);
    const auto result = json::parse(text);
    REQUIRE(json::getBool(result.get(), "ok"));
  }
  OperationHttpResult login(const std::string& credential) {
    const auto result = operationHttp(options.http_port, "POST", "/api/panel/session",
        "{\"credential\":\"" + credential + "\"}");
    INFO(result.body);
    REQUIRE(result.status == 200);
    REQUIRE(result.cookie.rfind("dbpanel=", 0) == 0);
    return result;
  }
  OperationHttpResult write(const std::string& path, const std::string& body) {
    return operationHttp(options.http_port, "POST", path, body, admin.cookie,
        operationField(admin, "csrf_token"));
  }
  int sessionStatus(const OperationHttpResult& session) {
    return operationHttp(options.http_port, "GET", "/api/panel/session", "", session.cookie).status;
  }
  void expectSessions(int a_status, int b_status, int legacy_status) {
    CHECK(sessionStatus(a) == a_status);
    CHECK(sessionStatus(b) == b_status);
    CHECK(sessionStatus(legacy) == legacy_status);
    CHECK(operationHttp(options.http_port, "GET", "/api/config", "", admin.cookie).status == 200);
  }
};
}  // namespace

TEST_CASE("T16 secret writes revoke only sessions bound to the written reference") {
  RevocationFixture f;
  const auto config_before = f.node->configJson();
  SUBCASE("same-value write revokes independent identity only") {
    const auto result = f.write("/api/secrets",
        R"({"secret_ref":"secret:panel.a","value":"revocation-a"})");
    INFO(result.body); REQUIRE(result.status == 200);
    f.expectSessions(403, 200, 200);
    CHECK(f.sessionStatus(f.login("revocation-a")) == 200);
  }
  SUBCASE("changed value revokes independent identity only") {
    const auto result = f.write("/api/secrets",
        R"({"secret_ref":"secret:panel.a","value":"revocation-a-new"})");
    INFO(result.body); REQUIRE(result.status == 200);
    f.expectSessions(403, 200, 200);
    CHECK(f.sessionStatus(f.login("revocation-a-new")) == 200);
  }
  SUBCASE("same-value legacy write does not revoke independent identities") {
    REQUIRE(f.write("/api/secrets",
        R"({"secret_ref":"secret:panel.legacy","value":"revocation-legacy"})").status == 200);
    f.expectSessions(200, 200, 403);
    CHECK(f.sessionStatus(f.login("revocation-legacy")) == 200);
  }
  SUBCASE("same-value provisioning has the same revocation semantics") {
    REQUIRE(f.write("/api/panel-token/provision",
        R"({"secret_ref":"secret:panel.legacy","token":"revocation-legacy"})").status == 200);
    f.expectSessions(200, 200, 403);
    CHECK(f.sessionStatus(f.login("revocation-legacy")) == 200);
  }
  SUBCASE("failed writes do not revoke any session") {
    { std::lock_guard<std::mutex> lock(f.secret_mutex); f.fail_put = true; }
    CHECK(f.write("/api/secrets",
        R"({"secret_ref":"secret:panel.a","value":"revocation-a"})").status == 500);
    f.expectSessions(200, 200, 200);
    CHECK(f.write("/api/panel-token/provision",
        R"({"secret_ref":"secret:panel.legacy","token":"revocation-legacy"})").status == 500);
    f.expectSessions(200, 200, 200);
  }
  SUBCASE("unrelated reference does not revoke any session") {
    REQUIRE(f.write("/api/secrets",
        R"({"secret_ref":"secret:unrelated.test","value":"unrelated-value"})").status == 200);
    f.expectSessions(200, 200, 200);
  }
  SUBCASE("invalid reference is rejected before revocation") {
    CHECK(f.write("/api/secrets", R"({"secret_ref":"invalid","value":"value"})").status == 400);
    f.expectSessions(200, 200, 200);
  }
  CHECK(f.node->configJson() == config_before);
}

TEST_CASE("T16 call lifecycle distinguishes missing authentication from missing permission") {
  RevocationFixture f;
  const auto call = f.node->pressV2("front", "");
  REQUIRE(!call.empty());
  const auto path = "/api/panel/call-lifecycle?door=front&call_id=" + call +
      "&stage_revision=0&state=answered&dialog_id=0123456789abcdef0123456789abcdef";
  const auto unauthenticated = operationHttp(f.options.http_port, "POST", path);
  CHECK(unauthenticated.status == 403);
  CHECK(operationField(unauthenticated, "error_code") == "auth_required");
  const auto denied = operationHttp(f.options.http_port, "POST", path, "", f.b.cookie,
      operationField(f.b, "csrf_token"));
  CHECK(denied.status == 403);
  CHECK(operationField(denied, "error_code") == "permission_denied");
  const auto no_csrf = operationHttp(f.options.http_port, "POST", path, "", f.a.cookie);
  CHECK(no_csrf.status == 403);
  CHECK(operationField(no_csrf, "error_code") == "permission_denied");
  const auto allowed = operationHttp(f.options.http_port, "POST", path, "", f.a.cookie,
      operationField(f.a, "csrf_token"));
  INFO(allowed.body); REQUIRE(allowed.status == 200);
}
#endif
