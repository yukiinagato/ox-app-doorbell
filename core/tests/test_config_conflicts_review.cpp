#include "doctest.h"
#include "test_env.h"
#include "node/node.h"
#include "node/config_edit_journal.h"
#include "util/common.h"
#include "util/json.h"
#include <sqlite3.h>
#include <filesystem>
#include <sys/socket.h>
#include <unistd.h>

using namespace db;

namespace {
struct ReviewFleet {
  SimClock clock{1'700'000'000'000LL, 0};
  Runloop loop{clock};
  InMemNet net{loop};
  std::unique_ptr<Node> a, b;
  explicit ReviewFleet(const std::string& directory = ":memory:") {
    auto options = [&](const std::string& address, bool seed) {
      NodeOptions value;
      value.data_dir = seed ? directory : ":memory:";
      value.name = address; value.role = "indoor_panel";
      value.listen_addr = value.advertise_addr = address;
      value.enable_beacon = false; value.http_port = 0;
      value.seed_default_config = seed; value.psk.fill(0x39);
      auto& t = value.mesh_timing_template;
      t.heartbeat_ms = 30; t.suspect_ms = 90; t.dead_ms = 150;
      t.gossip_ms = t.sync_ms = t.reconnect_ms = 50; t.claim_ttl_ms = 300;
      value.use_mesh_timing_template = true;
      return value;
    };
    auto deps = [&](const std::string& address) {
      NodeDeps value; value.clock = &clock; value.loop = &loop;
      value.transport = net.makeTransport(address); value.discovery = net.makeDiscovery(address);
      return value;
    };
    a.reset(new Node(options("review-a", true), deps("review-a")));
    b.reset(new Node(options("review-b", false), deps("review-b")));
    REQUIRE(a->start()); REQUIRE(b->start()); run(1500);
  }
  ~ReviewFleet() { a->stop(); b->stop(); }
  void run(int milliseconds) {
    for (int elapsed = 0; elapsed < milliseconds; elapsed += 10) { clock.advance(10); loop.pumpDue(); }
  }
  void partition() { net.partition({{"review-a"}, {"review-b"}}); }
  void heal() { net.heal(); run(2000); }
};
std::string conflictText(Node& node) {
  auto snapshot = json::parse(node.configSnapshotJson());
  return json::dump(json::get(snapshot.get(), "edit_conflicts"));
}
int64_t journalCount(Node& node) {
  auto snapshot = json::parse(node.configSnapshotJson());
  return json::getInt(json::get(snapshot.get(), "edit_journal"), "records");
}
LwwEntry journalRecord(const std::function<void(cJSON*)>& alter) {
  const std::string author(32, 'a');
  SimClock clock{1'700'000'000'000LL, 0}; HlcClock hlc(clock, author.substr(0, 8));
  LwwMap map(author, hlc); map.set("settings.review", "1");
  auto candidate = json::parse(R"({"settings":{"review":2}})");
  std::vector<LwwMutation> journal;
  REQUIRE(appendConfigEdits(map.all(), {{"settings.review", "2", false}},
      candidate.get(), author, nullptr, &journal).empty());
  REQUIRE(journal.size() == 1);
  auto record = json::parse(journal[0].value_json);
  alter(record.get());
  const auto encoded = json::dump(record.get());
  return {"_config_changes." + json::getString(record.get(), "change_id") + "." +
          sha256Hex(toBytes(encoded)), encoded, false, hlc.tick(), author, 2};
}
std::string request(int port, const std::string& method, const std::string& path,
                    const std::string& body = "", const std::string& cookie = "",
                    const std::string& extra = "") {
  const int fd = ::socket(AF_INET, SOCK_STREAM, 0); REQUIRE(fd >= 0);
  sockaddr_in address{}; address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK); address.sin_port = htons(port);
  REQUIRE(::connect(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0);
  std::string wire = method + " " + path + " HTTP/1.1\r\nHost: 127.0.0.1:" + std::to_string(port) + "\r\n" + extra;
  if (!cookie.empty()) wire += "Cookie: dbsess=" + cookie + "\r\n";
  if (!body.empty()) wire += "Content-Type: application/json\r\nContent-Length: " + std::to_string(body.size()) + "\r\n";
  wire += "Connection: close\r\n\r\n" + body;
  REQUIRE(::send(fd, wire.data(), wire.size(), 0) == static_cast<ssize_t>(wire.size()));
  timeval timeout{5, 0}; setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
  std::string response; char bytes[4096];
  for (;;) { const auto count = ::recv(fd, bytes, sizeof(bytes), 0); if (count <= 0) break; response.append(bytes, count); }
  ::close(fd); return response;
}
json::Doc bodyOf(const std::string& response) {
  const auto offset = response.find("\r\n\r\n");
  return json::parse(offset == std::string::npos ? "" : response.substr(offset + 4));
}
}

TEST_CASE("config conflict review: replicated records reject unknown fields and excessive parent metadata") {
  auto valid = journalRecord([](cJSON*) {}); REQUIRE(configEditRecordsValid({valid}));
  SUBCASE("unknown record payload cannot leak into candidate history") {
    auto entry = journalRecord([](cJSON* doc) { json::set(doc, "unreviewed_payload", "test-only-plaintext"); });
    CHECK_FALSE(configEditRecordsValid({entry}));
  }
  SUBCASE("unknown operation payload cannot bypass scrubbing") {
    auto entry = journalRecord([](cJSON* doc) {
      json::set(cJSON_GetArrayItem(json::get(doc, "ops"), 0), "debug_token", "test-only-plaintext");
    });
    CHECK_FALSE(configEditRecordsValid({entry}));
  }
  SUBCASE("each field has at most two typed base versions") {
    auto entry = journalRecord([](cJSON* doc) {
      auto parents = json::arr();
      for (int i = 0; i < 3; ++i) json::push(parents.get(), json::obj());
      json::setItem(cJSON_GetArrayItem(json::get(doc, "ops"), 0), "base_versions", std::move(parents));
    });
    CHECK_FALSE(configEditRecordsValid({entry}));
  }
  SUBCASE("base versions cannot be an arbitrary string") {
    auto entry = journalRecord([](cJSON* doc) {
      json::set(cJSON_GetArrayItem(json::get(doc, "ops"), 0), "base_versions", "test-only-plaintext");
    });
    CHECK_FALSE(configEditRecordsValid({entry}));
  }
  SUBCASE("changed fields remain bounded") {
    auto entry = journalRecord([](cJSON* doc) {
      auto* ops = json::get(doc, "ops");
      const auto* first = cJSON_GetArrayItem(ops, 0);
      for (int i = 1; i < 257; ++i) json::push(ops, json::Doc(cJSON_Duplicate(first, 1)));
    });
    CHECK_FALSE(configEditRecordsValid({entry}));
  }
}

TEST_CASE("config conflict review: legacy public native setters retain partitioned intent") {
  ReviewFleet f;
  f.a->setConfigKey("settings.review", R"("base")"); f.run(500); f.partition();
  f.a->setConfigKey("settings.review", R"("A native intent")");
  f.b->setConfigKey("settings.review", R"("B native intent")");
  f.heal(); const auto text = conflictText(*f.a);
  CHECK(text.find("A native intent") != std::string::npos);
  CHECK(text.find("B native intent") != std::string::npos);
  CHECK(text == conflictText(*f.b));
}

TEST_CASE("config conflict review: native notices retain both branches and block a blind clear") {
  ReviewFleet f;
  REQUIRE(f.a->setDoorNotice("*", "base", 0)); f.run(500); f.partition();
  REQUIRE(f.a->setDoorNotice("*", "A notice intent", 0));
  REQUIRE(f.b->setDoorNotice("*", "B notice intent", 0)); f.heal();
  const auto before = conflictText(*f.a);
  CHECK(before.find("A notice intent") != std::string::npos);
  CHECK(before.find("B notice intent") != std::string::npos);
  CHECK_FALSE(f.a->clearDoorNotice("*")); CHECK(conflictText(*f.a) == before);
}

TEST_CASE("config conflict review: legacy HTTP import commits an edit record atomically") {
  NodeOptions options; options.data_dir = ":memory:"; options.enable_beacon = false;
  options.listen_addr = "127.0.0.1:" + std::to_string(testing::freeListenPort());
  options.http_port = testing::freeListenPort(); Node node(options); REQUIRE(node.start());
  const auto login = request(options.http_port, "POST", "/api/login", R"({"password":"testpw"})");
  REQUIRE(login.find("HTTP/1.1 200") == 0);
  const auto cookie_begin = login.find("dbsess="); REQUIRE(cookie_begin != std::string::npos);
  const auto cookie = login.substr(cookie_begin + 7, login.find(';', cookie_begin) - cookie_begin - 7);
  auto session = bodyOf(request(options.http_port, "GET", "/api/session", "", cookie));
  const auto before = journalCount(node);
  const auto response = request(options.http_port, "POST", "/api/config/import",
      R"({"entries":[{"key":"settings.review_import","value":"imported intent"}]})", cookie,
      "Origin: http://127.0.0.1:" + std::to_string(options.http_port) + "\r\nX-Doorbell-CSRF: " +
      json::getString(session.get(), "csrf_token") + "\r\n");
  REQUIRE(response.find("HTTP/1.1 200") == 0);
  CHECK(journalCount(node) == before + 1);
  CHECK(node.configJson().find("imported intent") != std::string::npos); node.stop();
}

TEST_CASE("config conflict review: collection root mutations are explicitly rejected") {
  ReviewFleet f; const std::string device(32, 'f');
  REQUIRE(json::getBool(json::parse(f.a->setConfigJson("devices." + device + ".name", R"("base device marker")")).get(), "ok"));
  f.run(20);
  const auto before = journalCount(*f.a);
  SUBCASE("set was already restricted before T28") {
    auto value = json::obj(); json::set(json::addObj(value.get(), device.c_str()), "name", "collection overwrite");
    auto result = json::parse(f.a->setConfigJson("devices", json::dump(value.get())));
    CHECK_FALSE(json::getBool(result.get(), "ok"));
  }
  SUBCASE("legacy delete must not create a different collection entity") {
    auto result = json::parse(f.a->deleteConfigKeyJson("devices"));
    CHECK_FALSE(json::getBool(result.get(), "ok"));
  }
  SUBCASE("CAS delete follows the same collection restriction") {
    auto snapshot = json::parse(f.a->configSnapshotJson()); auto body = json::obj();
    json::set(body.get(), "schema_version", int64_t{2});
    json::set(body.get(), "expected_revision", json::getString(snapshot.get(), "revision"));
    auto* op = json::pushObj(json::addArr(body.get(), "ops"));
    json::set(op, "op", "delete"); json::set(op, "key", "devices");
    CHECK_FALSE(json::getBool(json::parse(f.a->configCommitJson(json::dump(body.get()))).get(), "ok"));
  }
  CHECK(journalCount(*f.a) == before);
  CHECK(f.a->configJson().find("base device marker") != std::string::npos);
}

TEST_CASE("config conflict review: remote journal persistence failure retries without a frontier gap") {
  const auto directory = testing::uniqueTempPath("doorbell_review_remote_journal", "");
  {
    ReviewFleet f(directory);
    REQUIRE(json::getBool(json::parse(f.a->setConfigJson("settings.review", R"("base")")).get(), "ok"));
    f.run(500); const auto before = f.a->configSnapshotJson();
    sqlite3* db = nullptr; REQUIRE(sqlite3_open((directory + "/doorbell.db").c_str(), &db) == SQLITE_OK);
    REQUIRE(sqlite3_exec(db, "CREATE TRIGGER fail_remote_journal BEFORE INSERT ON config "
        "WHEN NEW.key LIKE '_config_changes.%' BEGIN SELECT RAISE(FAIL,'review remote journal failure'); END",
        nullptr, nullptr, nullptr) == SQLITE_OK);
    REQUIRE(json::getBool(json::parse(f.b->setConfigJson("settings.review", R"("retry this remote intent")")).get(), "ok"));
    f.run(800);
    auto failed = json::parse(f.a->configSnapshotJson()), original = json::parse(before);
    CHECK(json::getString(failed.get(), "revision") == json::getString(original.get(), "revision"));
    CHECK(f.a->configJson().find("retry this remote intent") == std::string::npos);
    REQUIRE(sqlite3_exec(db, "DROP TRIGGER fail_remote_journal", nullptr, nullptr, nullptr) == SQLITE_OK);
    sqlite3_close(db); f.run(2000);
    CHECK(f.a->configJson().find("retry this remote intent") != std::string::npos);
    CHECK(journalCount(*f.a) == journalCount(*f.b));
  }
  std::filesystem::remove_all(directory);
}

TEST_CASE("config conflict review: explicit resolution deletion must cover the whole entity") {
  ReviewFleet f;
  REQUIRE(json::getBool(json::parse(f.a->setConfigJson("settings.review", R"("base")")).get(), "ok"));
  f.run(500); f.partition();
  REQUIRE(json::getBool(json::parse(f.a->setConfigJson("settings.review", R"("A intent")")).get(), "ok"));
  REQUIRE(json::getBool(json::parse(f.b->setConfigJson("settings.review", R"("B intent")")).get(), "ok"));
  f.heal(); auto snapshot = json::parse(f.a->configSnapshotJson());
  const auto* conflicts = json::get(snapshot.get(), "edit_conflicts");
  REQUIRE(cJSON_GetArraySize(conflicts) == 1);
  const auto before = json::dump(conflicts);
  auto body = json::obj(); json::set(body.get(), "schema_version", int64_t{2});
  json::set(body.get(), "expected_revision", json::getString(snapshot.get(), "revision"));
  json::setItem(json::addObj(body.get(), "resolves"), "settings",
      json::Doc(cJSON_Duplicate(json::get(cJSON_GetArrayItem(conflicts, 0), "heads"), 1)));
  auto* op = json::pushObj(json::addArr(body.get(), "ops")); json::set(op, "op", "delete");
  SUBCASE("partial delete cannot retire all entity heads") {
    json::set(op, "key", "settings.review");
    auto result = json::parse(f.a->configCommitJson(json::dump(body.get())));
    CHECK_FALSE(json::getBool(result.get(), "ok")); CHECK(conflictText(*f.a) == before);
  }
  SUBCASE("explicit whole entity deletion remains available") {
    json::set(op, "key", "settings");
    auto result = json::parse(f.a->configCommitJson(json::dump(body.get())));
    REQUIRE(json::getBool(result.get(), "ok")); f.run(2000);
    CHECK(conflictText(*f.a) == "[]"); CHECK(conflictText(*f.b) == "[]");
  }
}

TEST_CASE("config conflict review: only bounded secret references survive candidate scrubbing") {
  const std::string author(32, 'a');
  const auto recordFor = [&](const std::string& value) {
    auto candidate = json::obj(); json::set(json::addObj(candidate.get(), "settings"), "reference", value);
    const auto encoded = json::dump(json::get(json::get(candidate.get(), "settings"), "reference"));
    std::vector<LwwMutation> journal;
    REQUIRE(appendConfigEdits({}, {{"settings.reference", encoded, false}}, candidate.get(),
        author, nullptr, &journal).empty());
    REQUIRE(journal.size() == 1);
    return json::parse(journal[0].value_json);
  };
  for (const auto& value : {std::string("secret:a"), std::string("secret:device.camera_1-pass"),
                           std::string("secret:") + std::string(128, 'a')}) {
    INFO(value);
    auto record = recordFor(value);
    CHECK_FALSE(json::getBool(record.get(), "requires_reentry"));
    CHECK(json::getString(json::get(record.get(), "candidate"), "reference") == value);
    CHECK(json::getString(cJSON_GetArrayItem(json::get(record.get(), "ops"), 0), "value") == value);
  }
  for (const auto& value : {std::string("secret:"), std::string("secret:") + std::string(129, 'a'),
                           std::string("secret:plaintext secret"), std::string("secret:invalid/@path"),
                           std::string("https://example.invalid/#test-only-fragment-token"),
                           std::string("https://example.invalid/%74est-only-encoded-token"),
                           std::string("https://example.invalid/?test-only-query-token"),
                           std::string("https://test:private@example.invalid/")}) {
    INFO(value);
    auto record = recordFor(value);
    CHECK(json::getBool(record.get(), "requires_reentry"));
    const auto* candidate = json::get(json::get(record.get(), "candidate"), "reference");
    const auto* operation = json::get(cJSON_GetArrayItem(json::get(record.get(), "ops"), 0), "value");
    CHECK(json::getBool(candidate, "requires_reentry"));
    CHECK(json::getBool(operation, "requires_reentry"));
    CHECK(json::dump(record.get()).find(value) == std::string::npos);
  }
}
