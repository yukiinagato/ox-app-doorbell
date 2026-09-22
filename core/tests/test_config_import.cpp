#include "doctest.h"
#if !defined(_WIN32)
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
struct ImportFixture {
  SimClock clock;
  NodeOptions options;
  std::unique_ptr<Node> node;
  std::string session, csrf;
  explicit ImportFixture(const std::string& directory = ":memory:") {
    options.data_dir = directory; options.enable_beacon = false;
    options.listen_addr = "127.0.0.1:" + std::to_string(testing::freeListenPort());
    options.http_port = testing::freeListenPort();
    NodeDeps deps; deps.clock = &clock;
    node.reset(new Node(options, std::move(deps))); REQUIRE(node->start()); login();
  }
  ~ImportFixture() { if (node) node->stop(); }
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
    if (std::string(action) == "commit" || std::string(action) == "query")
      json::set(request.get(), "operation_id", id);
    return body(wire(std::string("/api/config/import/") + action, json::dump(request.get())));
  }
};
}

TEST_CASE("config import: 255 256 and 257 leaf restores use the staged production path") {
  for (int count : {255, 256, 257}) {
    ImportFixture f; const auto before = f.node->configSnapshotJson();
    auto stage = f.stage(f.backup(count));
    REQUIRE(json::getBool(stage.get(), "ok"));
    CHECK(f.node->configSnapshotJson() == before);
    auto report = f.action("preflight", stage.get()); REQUIRE(json::getBool(report.get(), "can_commit"));
    CHECK(json::getInt(report.get(), "expanded_leaf_mutations") == count);
    CHECK(f.node->configSnapshotJson() == before);
    auto result = f.action("commit", stage.get()); REQUIRE(json::getBool(result.get(), "ok"));
    auto current = json::parse(f.node->configJson());
    CHECK(cJSON_GetArraySize(json::get(current.get(), "import_fixture")) == count);
    CHECK(json::dump(f.action("commit", stage.get()).get()) == json::dump(result.get()));
    auto ops = json::arr();
    for (int i = 0; i < 257; ++i) {
      auto* op = json::pushObj(ops.get()); json::set(op, "op", "set");
      json::set(op, "key", "ordinary.leaf_" + std::to_string(i)); json::set(op, "value", int64_t{i});
    }
    CHECK_FALSE(json::getBool(json::parse(f.node->configBatchJson(json::dump(ops.get()))).get(), "ok"));
  }
}

TEST_CASE("config import: invalid final values and missing dependencies never publish a partial import") {
  ImportFixture f; auto document = f.backup(257);
  auto* config = json::get(document.get(), "config");
  SUBCASE("last entry violates a production constraint") {
    auto* emergency = json::get(config, "emergency");
    if (!emergency) emergency = json::addObj(config, "emergency");
    auto trigger = json::obj(); json::set(trigger.get(), "countdown_s", int64_t{99});
    json::setItem(emergency, "trigger", std::move(trigger));
  }
  SUBCASE("missing secure store reference") {
    json::set(config, "import_secret_ref", "secret:import-missing");
  }
  SUBCASE("missing owned asset") { json::set(config, "import_sound", "asset:" + std::string(64, 'a')); }
  const auto before = f.node->configSnapshotJson(); std::atomic<int> published{0};
  f.node->setUiEventCb([&](const std::string& text) {
    if (json::getString(json::parse(text).get(), "t") == "config_changed") ++published;
  });
  auto stage = f.stage(std::move(document)); REQUIRE(json::getBool(stage.get(), "ok"));
  auto report = f.action("preflight", stage.get()); CHECK_FALSE(json::getBool(report.get(), "can_commit"));
  CHECK(json::getString(f.action("commit", stage.get()).get(), "error_code") == "preflight_failed");
  CHECK(f.node->configSnapshotJson() == before); CHECK(published == 0);
  f.node->setUiEventCb({});
}

TEST_CASE("config import: stages are bounded and bound to session revision digest and expiration") {
  ImportFixture f; auto stage = f.stage(f.backup(257)); REQUIRE(json::getBool(stage.get(), "ok"));
  SUBCASE("one active stage per administrator") {
    CHECK(json::getString(f.stage(f.backup(255)).get(), "error_code") == "stage_capacity_exceeded");
    REQUIRE(json::getBool(f.action("cancel", stage.get()).get(), "ok"));
    CHECK(json::getBool(f.stage(f.backup(255)).get(), "ok"));
  }
  SUBCASE("another authenticated session cannot use the token") {
    f.login();
    CHECK(json::getString(f.action("preflight", stage.get()).get(), "error_code") == "permission_denied");
    CHECK(json::getString(f.action("commit", stage.get()).get(), "error_code") == "permission_denied");
  }
  SUBCASE("mismatched upload digest") {
    json::set(stage.get(), "digest", std::string(64, 'f'));
    CHECK(json::getString(f.action("commit", stage.get()).get(), "error_code") == "stage_mismatch");
  }
  SUBCASE("intervening administrator edit rejects stale revision") {
    REQUIRE(json::getBool(json::parse(f.node->setConfigJson("settings.import_intervening", "true")).get(), "ok"));
    CHECK(json::getString(f.action("commit", stage.get()).get(), "error_code") == "config_conflict");
  }
  SUBCASE("expired stage is reclaimed without refreshing its lifetime") {
    f.clock.advance(600001);
    CHECK(json::getString(f.action("commit", stage.get()).get(), "error_code") == "stage_expired");
    CHECK(json::getBool(f.stage(f.backup(255)).get(), "ok"));
  }
  SUBCASE("current authentication is required even with a stage token") {
    f.csrf = "invalid";
    CHECK(json::getString(f.action("commit", stage.get()).get(), "error_code") == "permission_denied");
  }
  auto current = json::parse(f.node->configJson()); CHECK(json::get(current.get(), "import_fixture") == nullptr);
}

TEST_CASE("config import: oversized unsupported and malformed documents cannot reserve a stage") {
  ImportFixture f;
  SUBCASE("oversized request") {
    CHECK(json::getString(ImportFixture::body(f.wire("/api/config/import/stage",
        std::string(4 * 1024 * 1024 + 1, ' '))).get(), "error_code") == "capacity_exceeded");
  }
  SUBCASE("unknown backup schema") {
    auto document = f.backup(1); json::set(document.get(), "schema_version", int64_t{99});
    CHECK(json::getString(f.stage(std::move(document)).get(), "error_code") == "unsupported_schema");
  }
  SUBCASE("duplicate object members") {
    auto document = f.backup(1); cJSON_AddObjectToObject(json::get(document.get(), "config"), "import_fixture");
    CHECK_FALSE(json::getBool(f.stage(std::move(document)).get(), "ok"));
  }
  SUBCASE("excessive nesting") {
    auto document = f.backup(1); cJSON* next = json::get(document.get(), "config");
    for (int i = 0; i < 17; ++i) next = json::addObj(next, "deep");
    CHECK_FALSE(json::getBool(f.stage(std::move(document)).get(), "ok"));
  }
  SUBCASE("administrator credentials are not restorable JSON") {
    auto document = f.backup(1); auto* config = json::get(document.get(), "config");
    auto admin = json::obj(); json::set(admin.get(), "password_hash", "not-a-backup-secret");
    json::setItem(config, "admin", std::move(admin));
    CHECK(json::getString(f.stage(std::move(document)).get(), "error_code") == "admin_read_only");
  }
  CHECK(json::getBool(f.stage(f.backup(1)).get(), "ok"));
}

TEST_CASE("config import: receipt and configuration roll back together and duplicate results survive restart") {
  const auto directory = testing::uniqueTempPath("doorbell_config_import_receipt", "");
  std::string token, digest, original;
  {
    ImportFixture f(directory); auto stage = f.stage(f.backup(257)); REQUIRE(json::getBool(stage.get(), "ok"));
    const auto before = f.node->configSnapshotJson(); sqlite3* db = nullptr;
    REQUIRE(sqlite3_open((directory + "/doorbell.db").c_str(), &db) == SQLITE_OK);
    REQUIRE(sqlite3_exec(db, "CREATE TRIGGER fail_import_receipt BEFORE INSERT ON meta "
        "WHEN NEW.key = 'config_import_receipts_v1' BEGIN SELECT RAISE(FAIL,'receipt rejected'); END",
        nullptr, nullptr, nullptr) == SQLITE_OK);
    CHECK(json::getString(f.action("commit", stage.get()).get(), "error_code") == "config_persistence_failed");
    CHECK(f.node->configSnapshotJson() == before);
    REQUIRE(sqlite3_exec(db, "DROP TRIGGER fail_import_receipt", nullptr, nullptr, nullptr) == SQLITE_OK);
    sqlite3_close(db);
    auto result = f.action("commit", stage.get()); REQUIRE(json::getBool(result.get(), "ok"));
    original = json::dump(result.get()); token = json::getString(stage.get(), "stage_token");
    digest = json::getString(stage.get(), "digest");
    auto changed = json::Doc(cJSON_Duplicate(stage.get(), 1)); json::set(changed.get(), "digest", std::string(64, 'f'));
    CHECK(json::getString(f.action("commit", changed.get()).get(), "error_code") == "operation_conflict");
  }
  {
    ImportFixture f(directory); auto stage = json::obj();
    json::set(stage.get(), "stage_token", token); json::set(stage.get(), "digest", digest);
    CHECK(json::dump(f.action("commit", stage.get()).get()) == original);
    CHECK(json::getString(f.action("preflight", stage.get()).get(), "error_code") == "stage_expired");
    CHECK(cJSON_GetArraySize(json::get(json::parse(f.node->configJson()).get(), "import_fixture")) == 257);
  }
  std::filesystem::remove_all(directory);
}

TEST_CASE("config import: expanded admission ceilings and scrubbed differences are enforced") {
  ImportFixture f; auto document = f.backup(0); auto* config = json::get(document.get(), "config");
  cJSON_DeleteItemFromObjectCaseSensitive(config, "import_fixture");
  SUBCASE("4096 changed leaves across bounded journal entities can be restored") {
    for (int entity = 0; entity < 16; ++entity) {
      auto* group = json::addObj(config, ("import_group_" + std::to_string(entity)).c_str());
      for (int leaf = 0; leaf < 256; ++leaf) json::set(group, ("v" + std::to_string(leaf)).c_str(), int64_t{leaf});
    }
    auto stage = f.stage(std::move(document)); REQUIRE(json::getBool(stage.get(), "ok"));
    auto report = f.action("preflight", stage.get()); INFO(json::dump(report.get()));
    REQUIRE(json::getBool(report.get(), "can_commit")); CHECK(json::getInt(report.get(), "expanded_leaf_mutations") == 4096);
    CHECK(json::getBool(f.action("commit", stage.get()).get(), "ok"));
  }
  SUBCASE("4097 changes are rejected before live mutation") {
    for (int entity = 0; entity < 16; ++entity) {
      auto* group = json::addObj(config, ("import_group_" + std::to_string(entity)).c_str());
      for (int leaf = 0; leaf < 256; ++leaf) json::set(group, ("v" + std::to_string(leaf)).c_str(), int64_t{leaf});
    }
    json::set(config, "import_extra", int64_t{1});
    const auto before = f.node->configSnapshotJson(); auto stage = f.stage(std::move(document));
    REQUIRE(json::getBool(stage.get(), "ok")); auto report = f.action("preflight", stage.get());
    CHECK_FALSE(json::getBool(report.get(), "can_commit"));
    CHECK(json::dump(json::get(report.get(), "problems")).find("capacity_exceeded") != std::string::npos);
    CHECK_FALSE(json::getBool(f.action("commit", stage.get()).get(), "ok"));
    CHECK(f.node->configSnapshotJson() == before);
  }
  SUBCASE("unsafe values do not appear in preflight differences") {
    json::set(config, "import_credential_url", "https://example.invalid/?token=FAKE-IMPORT-PRIVATE");
    auto stage = f.stage(std::move(document)); REQUIRE(json::getBool(stage.get(), "ok"));
    const auto report = json::dump(f.action("preflight", stage.get()).get());
    CHECK(report.find("FAKE-IMPORT-PRIVATE") == std::string::npos);
    CHECK(report.find("requires_reentry") != std::string::npos);
  }
}

TEST_CASE("config import: device semantic overrides remain validated when restoring a complete snapshot") {
  ImportFixture f;
  const auto key = "devices." + f.node->nodeId() + ".local.ui.elements.call.primary";
  REQUIRE(json::getBool(json::parse(f.node->setConfigJson(key, R"({"font_scale":1.25})")).get(), "ok"));
  auto document = f.backup(257);
  auto* device = json::get(json::get(json::get(document.get(), "config"), "devices"), f.node->nodeId().c_str());
  auto* style = json::get(json::get(json::get(json::get(json::get(device, "local"), "ui"), "elements"), "call"), "primary");
  REQUIRE(cJSON_IsObject(style));
  bool valid = true;
  SUBCASE("valid style is restored through semantic leaf records") { json::set(style, "font_scale", 1.5); }
  SUBCASE("invalid style cannot bypass constraints inside a device container") {
    valid = false; json::set(style, "font_scale", 0.1);
  }
  auto stage = f.stage(std::move(document)); REQUIRE(json::getBool(stage.get(), "ok"));
  auto report = f.action("preflight", stage.get()); INFO(json::dump(report.get()));
  CHECK(json::getBool(report.get(), "can_commit") == valid);
  auto result = f.action("commit", stage.get()); CHECK(json::getBool(result.get(), "ok") == valid);
}

TEST_CASE("config import: receipt recovery is validated and admission problems appear in preflight") {
  const auto directory = testing::uniqueTempPath("doorbell_config_import_receipts", "");
  {
    ImportFixture f(directory);
    auto first = f.stage(f.backup(1)); REQUIRE(json::getBool(f.action("commit", first.get()).get(), "ok"));
    auto stage = f.stage(f.backup(2)); REQUIRE(json::getBool(stage.get(), "ok"));
    const auto before = f.node->configSnapshotJson(); sqlite3* db = nullptr;
    REQUIRE(sqlite3_open((directory + "/doorbell.db").c_str(), &db) == SQLITE_OK);
    std::string replacement;
    SUBCASE("invalid receipt content fails closed") { replacement = R"({"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa":{}})"; }
    SUBCASE("unparseable receipt metadata cannot prevent cancellation") { replacement = "invalid-json"; }
    SUBCASE("full durable receipt capacity is reported before commit") {
      sqlite3_stmt* statement = nullptr;
      REQUIRE(sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key='config_import_receipts_v1'", -1,
                               &statement, nullptr) == SQLITE_OK);
      REQUIRE(sqlite3_step(statement) == SQLITE_ROW);
      auto original = json::parse(reinterpret_cast<const char*>(sqlite3_column_text(statement, 0)));
      sqlite3_finalize(statement); auto ledger = json::obj();
      for (int i = 0; i < 128; ++i) {
        char id[33]; std::snprintf(id, sizeof(id), "%032x", i + 1);
        json::Doc receipt(cJSON_Duplicate(original->child, 1));
        json::set(json::get(receipt.get(), "result"), "operation_id", id);
        json::setItem(ledger.get(), id, std::move(receipt));
      }
      replacement = json::dump(ledger.get());
    }
    sqlite3_stmt* statement = nullptr;
    REQUIRE(sqlite3_prepare_v2(db, "UPDATE meta SET value=?1 WHERE key='config_import_receipts_v1'", -1,
                             &statement, nullptr) == SQLITE_OK);
    REQUIRE(sqlite3_bind_text(statement, 1, replacement.c_str(), -1, SQLITE_TRANSIENT) == SQLITE_OK);
    REQUIRE(sqlite3_step(statement) == SQLITE_DONE); sqlite3_finalize(statement); sqlite3_close(db);
    auto report = f.action("preflight", stage.get());
    CHECK(json::getBool(report.get(), "ok")); CHECK_FALSE(json::getBool(report.get(), "can_commit"));
    CHECK(cJSON_GetArraySize(json::get(report.get(), "problems")) > 0);
    CHECK_FALSE(json::getBool(f.action("commit", stage.get(), std::string(32, 'b')).get(), "ok"));
    CHECK(f.node->configSnapshotJson() == before);
    CHECK(json::getBool(f.action("cancel", stage.get()).get(), "ok"));
  }
  std::filesystem::remove_all(directory);
}

TEST_CASE("config import: recovery query reads the bound durable result without executing a stage") {
  const auto directory = testing::uniqueTempPath("doorbell_config_import_query", "");
  json::Doc stage; std::string committed;
  {
    ImportFixture f(directory); const auto before = f.node->configSnapshotJson();
    stage = f.stage(f.backup(257)); REQUIRE(json::getBool(stage.get(), "ok"));
    CHECK(json::getString(f.action("query", stage.get()).get(), "error_code") == "operation_not_found");
    CHECK(f.node->configSnapshotJson() == before);
    CHECK(json::getBool(f.action("preflight", stage.get()).get(), "can_commit"));
    auto result = f.action("commit", stage.get()); REQUIRE(json::getBool(result.get(), "ok"));
    committed = json::dump(result.get()); const auto after = f.node->configSnapshotJson();
    auto query = f.action("query", stage.get());
    CHECK(json::getString(query.get(), "state") == "committed");
    CHECK(json::dump(json::get(query.get(), "result")) == committed);
    CHECK(f.node->configSnapshotJson() == after);
    json::Doc wrong(cJSON_Duplicate(stage.get(), 1)); json::set(wrong.get(), "digest", std::string(64, '0'));
    CHECK(json::getString(f.action("query", wrong.get()).get(), "error_code") == "operation_conflict");
    f.csrf = "wrong";
    CHECK(json::getString(f.action("query", stage.get()).get(), "error_code") == "permission_denied");
  }
  {
    ImportFixture f(directory); const auto before = f.node->configSnapshotJson();
    auto query = f.action("query", stage.get());
    CHECK(json::getString(query.get(), "state") == "committed");
    CHECK(json::dump(json::get(query.get(), "result")) == committed);
    CHECK(f.node->configSnapshotJson() == before);
  }
  std::filesystem::remove_all(directory);
}
#endif
