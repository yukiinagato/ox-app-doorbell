#if !defined(_WIN32)
#include "doctest.h"
#include "test_env.h"
#include "node/node.h"
#include "util/json.h"
#include <filesystem>
#include <sqlite3.h>
#include <cstdio>
#include <sys/socket.h>
#include <unistd.h>

using namespace db;
namespace {
struct ReviewImportFixture {
  SimClock clock;
  NodeOptions options;
  std::unique_ptr<Node> node;
  std::string session, csrf;
  explicit ReviewImportFixture(const std::string& directory = ":memory:") {
    options.data_dir = directory; options.enable_beacon = false;
    options.listen_addr = "127.0.0.1:" + std::to_string(testing::freeListenPort());
    options.http_port = testing::freeListenPort();
    NodeDeps deps; deps.clock = &clock;
    node.reset(new Node(options, std::move(deps))); REQUIRE(node->start()); login();
  }
  ~ReviewImportFixture() { if (node) node->stop(); }
  std::string wire(const std::string& path, const std::string& body, bool authenticated = true) {
    const int fd = ::socket(AF_INET, SOCK_STREAM, 0); REQUIRE(fd >= 0);
    sockaddr_in address{}; address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK); address.sin_port = htons(options.http_port);
    REQUIRE(::connect(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0);
    const std::string origin = "http://127.0.0.1:" + std::to_string(options.http_port);
    std::string request = "POST " + path + " HTTP/1.1\r\nHost: 127.0.0.1:" +
        std::to_string(options.http_port) + "\r\nOrigin: " + origin + "\r\n";
    if (authenticated) request += "Cookie: dbsess=" + session + "\r\nX-Doorbell-CSRF: " + csrf + "\r\n";
    request += "Content-Type: application/json\r\nContent-Length: " + std::to_string(body.size()) +
               "\r\nConnection: close\r\n\r\n" + body;
    size_t sent = 0;
    while (sent < request.size()) {
      const auto count = ::send(fd, request.data() + sent, request.size() - sent, 0);
      REQUIRE(count > 0); sent += static_cast<size_t>(count);
    }
    timeval timeout{5, 0}; setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    std::string response; char bytes[8192];
    for (;;) { const auto n = ::recv(fd, bytes, sizeof(bytes), 0); if (n <= 0) break; response.append(bytes, n); }
    ::close(fd); return response;
  }
  static json::Doc body(const std::string& response) {
    const auto split = response.find("\r\n\r\n");
    return json::parse(split == std::string::npos ? "" : response.substr(split + 4));
  }
  void login() {
    const auto response = wire("/api/login", R"({"password":"testpw"})", false);
    REQUIRE(response.find("HTTP/1.1 200") == 0);
    const auto begin = response.find("dbsess="); REQUIRE(begin != std::string::npos);
    session = response.substr(begin + 7, response.find(';', begin) - begin - 7);
    csrf = json::getString(body(response).get(), "csrf_token");
    REQUIRE_FALSE(csrf.empty());
  }
  json::Doc backup(int added) {
    auto snapshot = json::parse(node->configSnapshotJson());
    auto document = json::obj(); json::set(document.get(), "schema_version", int64_t{2});
    json::Doc config(cJSON_Duplicate(json::get(snapshot.get(), "config"), 1));
    cJSON_DeleteItemFromObjectCaseSensitive(config.get(), "import_fixture");
    auto* extra = json::addObj(config.get(), "import_fixture");
    for (int i = 0; i < added; ++i) json::set(extra, ("leaf_" + std::to_string(i)).c_str(), int64_t{i});
    json::setItem(document.get(), "config", std::move(config)); return document;
  }
  json::Doc stage(json::Doc document) {
    auto snapshot = json::parse(node->configSnapshotJson()); auto request = json::obj();
    json::set(request.get(), "schema_version", int64_t{2});
    json::set(request.get(), "expected_revision", json::getString(snapshot.get(), "revision"));
    json::setItem(request.get(), "document", std::move(document));
    return body(wire("/api/config/import/stage", json::dump(request.get())));
  }
  json::Doc action(const char* action, const cJSON* stage, const std::string& id = std::string(32, 'a')) {
    auto request = json::obj(); json::set(request.get(), "schema_version", int64_t{2});
    json::set(request.get(), "stage_token", json::getString(stage, "stage_token"));
    json::set(request.get(), "digest", json::getString(stage, "digest"));
    if (std::string(action) == "commit") json::set(request.get(), "operation_id", id);
    return body(wire(std::string("/api/config/import/") + action, json::dump(request.get())));
  }
};
}

TEST_CASE("config import review: existing local parent and semantic child round trip together") {
  ReviewImportFixture f;
  const auto prefix = "devices." + f.node->nodeId();
  REQUIRE(json::getBool(json::parse(f.node->setConfigJson(prefix + ".local",
      R"({"review_marker":1})")).get(), "ok"));
  REQUIRE(json::getBool(json::parse(f.node->setConfigJson(prefix + ".local.ui.elements.call.primary",
      R"({"font_scale":1.25})")).get(), "ok"));
  auto document = f.backup(0);
  auto* device = json::get(json::get(json::get(document.get(), "config"), "devices"), f.node->nodeId().c_str());
  REQUIRE(cJSON_IsObject(device));
  json::set(device, "name", "Restored review device");
  auto expected = json::Doc(cJSON_Duplicate(json::get(document.get(), "config"), 1));
  auto stage = f.stage(std::move(document)); REQUIRE(json::getBool(stage.get(), "ok"));
  auto report = f.action("preflight", stage.get()); INFO(json::dump(report.get()));
  CHECK(json::getBool(report.get(), "can_commit"));
  auto result = f.action("commit", stage.get()); INFO(json::dump(result.get()));
  CHECK(json::getBool(result.get(), "ok"));
  auto current = json::parse(f.node->configSnapshotJson());
  CHECK(cJSON_Compare(json::get(current.get(), "config"), expected.get(), 1));
}

TEST_CASE("config import review: restored door announcement publishes its production event") {
  ReviewImportFixture f;
  REQUIRE(json::getBool(json::parse(f.node->setConfigJson("doors.d_review",
      R"({"label":{"en":"Review door"}})")).get(), "ok"));
  auto document = f.backup(0);
  auto* door = json::get(json::get(json::get(document.get(), "config"), "doors"), "d_review");
  REQUIRE(cJSON_IsObject(door));
  auto notice = json::obj(); json::set(notice.get(), "text", "Restored announcement");
  json::set(notice.get(), "created_ms", f.clock.wallMs()); json::set(notice.get(), "expires_ms", int64_t{0});
  json::set(notice.get(), "from_device", f.node->nodeId()); json::setItem(door, "notice", std::move(notice));
  auto stage = f.stage(std::move(document)); REQUIRE(json::getBool(stage.get(), "ok"));
  auto report = f.action("preflight", stage.get()); INFO(json::dump(report.get()));
  REQUIRE(json::getBool(report.get(), "can_commit"));
  std::atomic<int> changes{0};
  f.node->setUiEventCb([&](const std::string& text) {
    auto event = json::parse(text);
    if (json::getString(event.get(), "t") == "notice_changed" &&
        json::getString(event.get(), "door") == "d_review" && json::getBool(event.get(), "active")) ++changes;
  });
  auto result = f.action("commit", stage.get()); REQUIRE(json::getBool(result.get(), "ok"));
  CHECK(changes.load() == 1);
  f.node->setUiEventCb({});
}

#endif
