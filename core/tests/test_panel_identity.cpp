#if !defined(_WIN32)
#include "operation_test_fixture.h"
#include "media/frame_bus.h"
#include "node/panel_identity.h"

namespace {
struct IdentityFixture {
  SimClock clock{1700000000000LL, 1000};
  Runloop loop{clock};
  NodeOptions options;
  std::unique_ptr<Node> node;
  std::map<std::string, std::string> secrets;
  OperationHttpResult admin;
  IdentityFixture() {
    options.data_dir = ":memory:";
    options.door = "front";
    options.listen_addr = "127.0.0.1:" + std::to_string(testing::freeListenPort());
    options.http_port = testing::freeListenPort();
    options.enable_beacon = false;
    options.psk.fill(0x48);
    secrets = {{"panel.a", "identity-a-test"}, {"panel.b", "identity-b-test"},
               {"panel.rotated", "identity-a-new-test"}, {"sip.shared", "shared-sip-test"},
               {"sip.a", "independent-sip-test"}};
    loop.start();
    NodeDeps deps; deps.clock = &clock; deps.loop = &loop;
    node.reset(new Node(options, std::move(deps)));
    node->setSecureStore([this](const std::string& key) {
      const auto found = secrets.find(key);
      return found == secrets.end() ? std::string() : found->second;
    }, [](const std::string&, const std::string&) { return false; });
    REQUIRE(node->start());
    node->setConfigKey("doors.front", R"({"label":{"en":"Front"},"unlock":{"command":"unlock"}})");
    node->setConfigKey("doors.back", R"({"label":{"en":"Back"}})");
    node->setConfigKey("integrations.webrtc", R"({"ws_url":"wss://pbx.invalid/ws","sip_user":"shared","sip_pass_ref":"secret:sip.shared"})");
    admin = operationHttp(options.http_port, "POST", "/api/login", R"({"password":"testpw"})");
    REQUIRE(admin.status == 200);
  }
  ~IdentityFixture() { node->stop(); loop.stop(); }
  std::string revision() {
    auto snapshot = json::parse(node->configSnapshotJson());
    return json::getString(snapshot.get(), "revision");
  }
  OperationHttpResult manage(const std::string& action, const std::string& data) {
    return operationHttp(options.http_port, "POST", "/api/panels/" + action, data,
        admin.cookie, operationField(admin, "csrf_token"));
  }
  std::string create(const std::string& key, const std::string& grants = "[]",
                     const std::string& doors = "[]") {
    const auto result = manage("create", "{\"expected_revision\":\"" + revision() +
        "\",\"credential_ref\":\"secret:panel." + key + "\",\"grants\":" + grants +
        ",\"door_scope\":" + doors + "}");
    CAPTURE(result.body);
    REQUIRE(result.status == 200);
    const auto id = operationField(result, "panel_id");
    REQUIRE(panelIdentityIdValid(id));
    CHECK(operationField(result, "provisioning_status") == "provisioning_required");
    CHECK(result.body.find("identity-a-test") == std::string::npos);
    return id;
  }
  OperationHttpResult login(const std::string& key) {
    const auto result = operationHttp(options.http_port, "POST", "/api/panel/session",
        "{\"credential\":\"" + secrets.at("panel." + key) + "\"}");
    REQUIRE(result.status == 200);
    REQUIRE(result.cookie.rfind("dbpanel=", 0) == 0);
    return result;
  }
  OperationHttpResult request(const OperationHttpResult& session, const std::string& method,
      const std::string& path, const std::string& body = "") {
    return operationHttp(options.http_port, method, path, body, session.cookie,
        operationField(session, "csrf_token"));
  }
  std::string answer(const OperationHttpResult& session) {
    const auto call = node->pressV2("front", "");
    REQUIRE(!call.empty());
    const auto result = request(session, "POST", "/api/panel/call-lifecycle?door=front&call_id=" +
        call + "&stage_revision=0&state=answered&dialog_id=0123456789abcdef0123456789abcdef");
    CAPTURE(result.body);
    REQUIRE(result.status == 200);
    return call;
  }
};

std::string identityTuple(const std::string& call) {
  return "door=front&call_id=" + call + "&stage_revision=0";
}

int identityUpload(int port, const std::string& path, const OperationHttpResult& session) {
  FrameBus bus;
  RawFrame frame;
  frame.format = 3; frame.w = frame.h = 8; frame.stride = 32; frame.ts_ms = 1;
  frame.data.assign(8 * 8 * 4, 128); bus.push(std::move(frame));
  const auto jpeg = bus.latestJpeg();
  REQUIRE(jpeg.size() > 100);
  const int fd = ::socket(AF_INET, SOCK_STREAM, 0);
  REQUIRE(fd >= 0);
  sockaddr_in address{};
  address.sin_family = AF_INET; address.sin_port = htons(port);
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  REQUIRE(::connect(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0);
  const auto csrf = operationField(session, "csrf_token");
  const std::string header = "POST " + path + " HTTP/1.1\r\nHost: 127.0.0.1:" +
      std::to_string(port) + "\r\nCookie: " + session.cookie + "\r\nX-Doorbell-CSRF: " + csrf +
      "\r\nOrigin: http://127.0.0.1:" + std::to_string(port) +
      "\r\nContent-Type: image/jpeg\r\nConnection: close\r\nContent-Length: " +
      std::to_string(jpeg.size()) + "\r\n\r\n";
  const std::string request = header + std::string(jpeg.begin(), jpeg.end());
  REQUIRE(::send(fd, request.data(), request.size(), 0) == static_cast<ssize_t>(request.size()));
  timeval timeout{5, 0}; setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
  char buffer[4096]; std::string response;
  for (;;) { const auto count = ::recv(fd, buffer, sizeof(buffer), 0); if (count <= 0) break;
    response.append(buffer, static_cast<size_t>(count)); }
  ::close(fd);
  int status = 0; std::sscanf(response.c_str(), "HTTP/1.1 %d", &status);
  return status;
}
}

TEST_CASE("panel identity: current owner without media publish grant is denied") {
  IdentityFixture fixture;
  fixture.create("a", R"(["view","call.answer"])", R"(["front"])");
  const auto session = fixture.login("a");
  const auto call = fixture.answer(session);
  const auto authorization = fixture.request(session, "POST", "/api/panel/media-authorize?" +
      identityTuple(call));
  CHECK(authorization.status == 403);
  // On the historical source this real owner obtained a lease and uploaded a real JPEG.
  if (authorization.status == 200) {
    const auto generation = operationField(authorization, "media_generation");
    REQUIRE(!generation.empty());
    CHECK(identityUpload(fixture.options.http_port, "/call-frame?" + identityTuple(call) +
        "&media_generation=" + generation + "&frame_sequence=1", session) == 403);
  }
}

TEST_CASE("legacy panel Cookie mutations require CSRF and a trusted Origin") {
  IdentityFixture fixture;
  fixture.secrets["panel.legacy"] = "legacy-panel-test";
  fixture.node->setConfigKey("panel.token_refs", R"(["secret:panel.legacy"])");
  const auto session = operationHttp(fixture.options.http_port, "POST", "/api/panel/session",
      R"({"credential":"legacy-panel-test"})");
  REQUIRE(session.status == 200);
  const auto csrf = operationField(session, "csrf_token");
  REQUIRE(!csrf.empty());
  const auto cookie = session.cookie;
  auto request = [&](const std::string& path, const std::string& token,
                     const std::string& origin) {
    return operationHttp(fixture.options.http_port, "POST", path, "", cookie, token,
                         false, origin);
  };

  for (const auto& path : {
           "/api/panel/emergency?active=1",
           "/api/panel/press?door=front",
           "/api/panel/cancel?door=front&call_id=0123456789abcdef0123456789abcdef",
           "/api/panel/hangup?door=front&call_id=0123456789abcdef0123456789abcdef",
           "/api/doors/back/open"}) {
    CAPTURE(path);
    CHECK(request(path, "", "").status == 403);
    CHECK(request(path, "wrong-csrf", "local").status == 403);
    CHECK(request(path, csrf, "https://untrusted.invalid").status == 403);
  }

  CHECK(operationHttp(fixture.options.http_port, "POST",
      "/api/panel/emergency?active=1").status == 403);
  // The legacy panel remains usable with its own cookie, token and same-origin request.
  CHECK(request("/api/panel/emergency?active=1", csrf, "local").status == 200);
  // This route has no configured unlock for the back door: 409 proves authorization passed,
  // while avoiding execution of any unlock command in the test.
  CHECK(request("/api/doors/back/open", csrf, "local").status == 409);

  fixture.node->setSecureStore([&](const std::string& key) {
    return key == "panel.legacy" ? std::string("legacy-panel-rotated") :
        (fixture.secrets.count(key) ? fixture.secrets.at(key) : std::string());
  }, [](const std::string&, const std::string&) { return false; });
  CHECK(request("/api/panel/emergency?active=1", csrf, "local").status == 403);
  fixture.node->setSecureStore([&](const std::string& key) {
    const auto found = fixture.secrets.find(key);
    return found == fixture.secrets.end() ? std::string() : found->second;
  }, [](const std::string&, const std::string&) { return false; });
  const auto replacement = operationHttp(fixture.options.http_port, "POST", "/api/panel/session",
      R"({"credential":"legacy-panel-test"})");
  REQUIRE(replacement.status == 200);
  CHECK(operationHttp(fixture.options.http_port, "POST", "/api/panel/emergency?active=1", "",
      cookie, operationField(replacement, "csrf_token"), false, "local").status == 403);
}

TEST_CASE("panel identity: readonly alias denial scoped state and independent provisioning") {
  IdentityFixture fixture;
  const auto id = fixture.create("a", R"(["view"])", R"(["front"])");
  const auto session = fixture.login("a");
  CHECK(operationField(session, "panel_id") == id);
  CHECK(fixture.request(session, "POST", "/api/doors/front/open").status == 403);
  CHECK(fixture.request(session, "POST", "/api/doors/front/notice", R"({"text":"denied"})").status == 403);
  CHECK(fixture.request(session, "POST", "/api/notice", R"({"text":"denied"})").status == 403);
  CHECK(fixture.request(session, "POST", "/api/panel/press?door=front").status == 403);
  CHECK(fixture.request(session, "POST", "/api/panel/emergency?active=1").status == 403);
  CHECK(fixture.request(session, "POST", "/api/panel/push-subscription", "{}").status == 403);
  CHECK(fixture.request(session, "GET", "/snapshot-proxy?door=back").status == 403);
  CHECK(fixture.request(session, "GET", "/api/call-log?door=back").status == 403);
  auto state = json::parse(fixture.request(session, "GET", "/api/panel/state").body);
  REQUIRE(cJSON_GetArraySize(json::get(state.get(), "doors")) == 1);
  CHECK(json::getString(cJSON_GetArrayItem(json::get(state.get(), "doors"), 0), "id") == "front");
  auto info = fixture.request(session, "GET", "/api/panel/call-info");
  CHECK(info.status == 200);
  CHECK(info.body.find("shared-sip-test") == std::string::npos);
  auto document = json::parse(info.body);
  CHECK(json::getString(json::get(document.get(), "webrtc"), "provisioning_status") == "provisioning_required");
  CHECK(!json::get(json::get(document.get(), "webrtc"), "sip_pass"));
  CHECK(!json::get(json::get(document.get(), "doors"), "back"));
}

TEST_CASE("panel identity: revoking A preserves B owner session and media lease") {
  IdentityFixture fixture;
  const auto a = fixture.create("a", R"(["view","call.answer","media.publish"])", R"(["front"])");
  fixture.create("b", R"(["view","call.answer","media.publish"])", R"(["front"])");
  const auto first = fixture.login("a"), second = fixture.login("b");
  CHECK(fixture.request(first, "GET", "/api/panel/session").status == 200);
  const auto call = fixture.answer(second);
  const auto grant = fixture.request(second, "POST", "/api/panel/media-authorize?" + identityTuple(call));
  REQUIRE(grant.status == 200);
  const auto path = "/call-frame?" + identityTuple(call) + "&media_generation=" +
      operationField(grant, "media_generation") + "&frame_sequence=";
  CHECK(fixture.request(first, "POST", "/api/panel/media-authorize?" + identityTuple(call)).status == 403);
  CHECK(identityUpload(fixture.options.http_port, path + "1", first) == 403);
  CHECK(identityUpload(fixture.options.http_port, path + "1", second) == 200);
  REQUIRE(fixture.manage("revoke", "{\"panel_id\":\"" + a +
      "\",\"expected_revision\":\"" + fixture.revision() + "\"}").status == 200);
  CHECK(fixture.request(first, "GET", "/api/panel/session").status == 403);
  CHECK(fixture.request(second, "GET", "/api/panel/session").status == 200);
  CHECK(identityUpload(fixture.options.http_port, path + "2", second) == 200);
}

TEST_CASE("panel identity: management is strict atomic and shared with native entry") {
  IdentityFixture fixture;
  CHECK(operationHttp(fixture.options.http_port, "POST", "/api/panels/create", "{}",
      fixture.admin.cookie).status == 403);
  CHECK(operationHttp(fixture.options.http_port, "POST", "/api/panels/list", "{}",
      fixture.admin.cookie, operationField(fixture.admin, "csrf_token"), false,
      "https://untrusted.invalid").status == 403);
  for (const auto* body : {"{} trailing", "{\"credential_ref\":\"secret:panel.a\",\"credential_ref\":\"secret:panel.b\"}",
       "{\"grants\":true}", "{\"door_scope\":[\"*\"]}", "{\"grants\":[\"sos.clear\"]}"})
    CHECK(fixture.manage("create", body).status == 400);
  CHECK(fixture.manage("create", std::string(24, '[') + "0" + std::string(24, ']')).status == 400);
  const auto before = fixture.revision();
  const auto id = fixture.create("a");
  CHECK(fixture.manage("revoke", "{\"panel_id\":\"" + id +
      "\",\"expected_revision\":\"" + before + "\"}").status == 409);
  const auto session = fixture.login("a");
  CHECK(fixture.request(session, "POST", "/api/doors/front/open").status == 403);
  CHECK(fixture.request(session, "POST", "/api/panel/press?door=front").status == 403);
  const auto result = json::parse(fixture.node->panelIdentityJson("list", "{}",
      fixture.admin.cookie, operationField(fixture.admin, "csrf_token")));
  CHECK(json::getBool(result.get(), "ok"));
  CHECK(cJSON_GetArraySize(json::get(result.get(), "panels")) == 1);
  CHECK_FALSE(json::getBool(json::parse(fixture.node->panelIdentityJson("list", "{}",
      fixture.admin.cookie, "wrong")).get(), "ok"));
}

TEST_CASE("panel identity: real SIP mapping requires unique account and explicit calling grant") {
  IdentityFixture fixture;
  const auto id = fixture.create("a", R"(["view","call.monitor"])", R"(["front"])");
  const std::string account = "1234567890abcdef1234567890abcdef";
  fixture.node->setConfigKey("sip.accounts." + account,
      R"({"user":"panel-101","pass_ref":"secret:sip.a"})");
  const auto update = fixture.manage("update", "{\"panel_id\":\"" + id +
      "\",\"expected_revision\":\"" + fixture.revision() + "\",\"sip_account_id\":\"" + account + "\"}");
  REQUIRE(update.status == 200);
  CHECK(operationField(update, "provisioning_status") == "configured");
  const auto session = fixture.login("a");
  auto info = json::parse(fixture.request(session, "GET", "/api/panel/call-info").body);
  CHECK(json::getString(json::get(info.get(), "webrtc"), "sip_user") == "panel-101");
  CHECK(json::getString(json::get(info.get(), "webrtc"), "sip_pass") == "independent-sip-test");
  fixture.node->setConfigKey("sip.accounts." + account + ".user", "\"shared\"");
  info = json::parse(fixture.request(session, "GET", "/api/panel/call-info").body);
  CHECK(json::getString(json::get(info.get(), "webrtc"), "provisioning_status") == "provisioning_required");
  CHECK(!json::get(json::get(info.get(), "webrtc"), "sip_pass"));
}

TEST_CASE("panel identity: replicated revocation fences only the observed identity") {
  OperationFleet fleet;
  const std::string a = "11111111111111111111111111111111", b = "22222222222222222222222222222222";
  auto secret = [](const std::string& key) {
    return key == "panel.a" ? "identity-a-test" : key == "panel.b" ? "identity-b-test" : "";
  };
  fleet.a->setSecureStore(secret, {}); fleet.b->setSecureStore(secret, {});
  for (const auto& item : {std::make_pair(a, "a"), std::make_pair(b, "b")}) {
    fleet.a->setConfigKey("panel.identities." + item.first,
        "{\"credential_ref\":\"secret:panel." + std::string(item.second) +
        "\",\"credential_generation\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\","
        "\"door_scope\":[\"front\"],\"grants\":[\"view\",\"sos.trigger\"],\"revoked\":false}");
  }
  REQUIRE(operationWait([&] { return fleet.b->configJson().find(b) != std::string::npos; }));
  const auto first = operationHttp(fleet.b_opts.http_port, "POST", "/api/panel/session",
      R"({"credential":"identity-a-test"})");
  const auto second = operationHttp(fleet.b_opts.http_port, "POST", "/api/panel/session",
      R"({"credential":"identity-b-test"})");
  REQUIRE(first.status == 200); REQUIRE(second.status == 200);
  const auto source = operationHttp(fleet.a_opts.http_port, "POST", "/api/panel/session",
      R"({"credential":"identity-a-test"})");
  auto prepare = operationHttp(fleet.a_opts.http_port, "POST", "/api/operations/prepare",
      fleet.request("sos_start"), source.cookie, operationField(source, "csrf_token"));
  CAPTURE(prepare.body);
  REQUIRE(prepare.status == 200);
  const auto operation = operationField(prepare, "operation_id");
  // The authority observes revocation through real authenticated mesh replication.
  fleet.a->setConfigKey("panel.identities." + a + ".revoked", "true");
  REQUIRE(operationWait([&] {
    return operationHttp(fleet.b_opts.http_port, "GET", "/api/panel/session", "", first.cookie).status == 403;
  }));
  CHECK(operationHttp(fleet.b_opts.http_port, "GET", "/api/panel/session", "", second.cookie).status == 200);
  CHECK(operationHttp(fleet.a_opts.http_port, "POST", "/api/operations/" + operation + "/execute",
      fleet.request("sos_start", operation), source.cookie, operationField(source, "csrf_token")).status == 401);
}
#endif
