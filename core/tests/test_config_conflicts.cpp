#include "doctest.h"
#include "node/node.h"
#include "util/json.h"
#include "util/clock.h"
#include "util/runloop.h"
#include "mesh/mesh.h"
#include "node/config_edit_journal.h"
#include "store/store.h"
#include "util/common.h"
#include <sqlite3.h>

using namespace db;

namespace {
struct ConfigConflictFleet {
  SimClock clock{1'700'000'000'000LL, 0};
  Runloop loop{clock};
  InMemNet net{loop};
  std::unique_ptr<Node> a, b, observer;
  explicit ConfigConflictFleet(const std::string& directory = ":memory:", bool observe = false) {
    auto options = [&](const std::string& address, bool seed) {
      NodeOptions value;
      value.data_dir = address == "config-race-a" ? directory : ":memory:";
      value.name = address;
      value.role = "indoor_panel";
      value.listen_addr = value.advertise_addr = address;
      value.enable_beacon = false;
      value.http_port = 0;
      value.seed_default_config = seed;
      value.psk.fill(0x72);
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
    a.reset(new Node(options("config-race-a", true), deps("config-race-a")));
    b.reset(new Node(options("config-race-b", false), deps("config-race-b")));
    REQUIRE(a->start()); REQUIRE(b->start());
    if (observe) {
      observer.reset(new Node(options("config-race-observer", false), deps("config-race-observer")));
      REQUIRE(observer->start());
    }
    run(1500);
  }
  ~ConfigConflictFleet() { if (observer) observer->stop(); a->stop(); b->stop(); }
  void run(int milliseconds) {
    for (int elapsed = 0; elapsed < milliseconds; elapsed += 10) {
      clock.advance(10); loop.pumpDue();
    }
  }
  std::string edit(Node& node, const std::string& value, const cJSON* resolves = nullptr) {
    auto snapshot = json::parse(node.configSnapshotJson());
    auto body = json::obj();
    json::set(body.get(), "schema_version", int64_t{2});
    json::set(body.get(), "expected_revision", json::getString(snapshot.get(), "revision"));
    auto* op = json::pushObj(json::addArr(body.get(), "ops"));
    json::set(op, "op", "set"); json::set(op, "key", resolves ? "settings" : "settings.partition_test");
    if (resolves) json::set(json::addObj(op, "value"), "partition_test", value);
    else json::set(op, "value", value);
    if (resolves) json::setItem(body.get(), "resolves", json::Doc(cJSON_Duplicate(resolves, 1)));
    return node.configCommitJson(json::dump(body.get()));
  }
  void makeConflict(bool reverse) {
    auto base = json::parse(edit(*a, "base"));
    REQUIRE(json::getBool(base.get(), "ok")); run(500);
    net.partition({{"config-race-a"}, {"config-race-b"}, {"config-race-observer"}});
    auto first = json::parse(edit(reverse ? *b : *a, reverse ? "B intent" : "A intent"));
    auto second = json::parse(edit(reverse ? *a : *b, reverse ? "A intent" : "B intent"));
    REQUIRE(json::getBool(first.get(), "ok")); REQUIRE(json::getBool(second.get(), "ok"));
    if (observer) {
      net.partition({{reverse ? "config-race-b" : "config-race-a", "config-race-observer"},
                     {reverse ? "config-race-a" : "config-race-b"}});
      run(1000);
      CHECK(observer->configJson().find(reverse ? "B intent" : "A intent") != std::string::npos);
      CHECK(observer->configJson().find(reverse ? "A intent" : "B intent") == std::string::npos);
    }
    net.heal(); run(2000);
  }
};
}

TEST_CASE("config conflicts: partitioned production replicas retain both editing intents") {
  for (bool reverse : {false, true}) {
    ConfigConflictFleet f(":memory:", true);
    f.makeConflict(reverse);
    auto a = json::parse(f.a->configSnapshotJson());
    auto b = json::parse(f.b->configSnapshotJson());
    const auto* conflicts = json::get(a.get(), "edit_conflicts");
    REQUIRE(cJSON_IsArray(conflicts));
    REQUIRE(cJSON_GetArraySize(conflicts) == 1);
    CHECK(json::dump(conflicts) == json::dump(json::get(b.get(), "edit_conflicts")));
    auto observed = json::parse(f.observer->configSnapshotJson());
    CHECK(json::dump(conflicts) == json::dump(json::get(observed.get(), "edit_conflicts")));
    const auto* conflict = cJSON_GetArrayItem(conflicts, 0);
    CHECK(json::getString(conflict, "entity") == "settings");
    CHECK(json::getString(conflict, "state") == "unresolved");
    CHECK(json::dump(conflict).find("A intent") != std::string::npos);
    CHECK(json::dump(conflict).find("B intent") != std::string::npos);
    const auto stable = json::dump(conflicts);
    f.run(60000);
    auto after = json::parse(f.a->configSnapshotJson());
    CHECK(json::dump(json::get(after.get(), "edit_conflicts")) == stable);
    CHECK(f.a->configJson().find("_config_changes") == std::string::npos);
  }
}

TEST_CASE("config conflicts: explicit resolution references every head and does not remerge") {
  ConfigConflictFleet f; f.makeConflict(false);
  auto snapshot = json::parse(f.a->configSnapshotJson());
  const auto* conflicts = json::get(snapshot.get(), "edit_conflicts");
  REQUIRE(cJSON_IsArray(conflicts)); REQUIRE(cJSON_GetArraySize(conflicts) == 1);
  const auto* conflict = cJSON_GetArrayItem(conflicts, 0);
  auto rejected = json::parse(f.edit(*f.a, "silent overwrite"));
  CHECK(json::getString(rejected.get(), "error_code") == "unresolved_config_conflict");
  auto resolves = json::obj();
  json::setItem(resolves.get(), "settings", json::Doc(cJSON_Duplicate(json::get(conflict, "heads"), 1)));
  auto resolved = json::parse(f.edit(*f.a, "chosen value", resolves.get()));
  CAPTURE(json::dump(resolved.get())); REQUIRE(json::getBool(resolved.get(), "ok"));
  f.run(2000);
  for (Node* node : {f.a.get(), f.b.get()}) {
    auto result = json::parse(node->configSnapshotJson());
    CHECK(cJSON_GetArraySize(json::get(result.get(), "edit_conflicts")) == 0);
    CHECK(node->configJson().find("chosen value") != std::string::npos);
  }
  const auto before = f.a->configSnapshotJson(); f.run(60000);
  auto before_doc = json::parse(before), after = json::parse(f.a->configSnapshotJson());
  CHECK(json::dump(json::get(before_doc.get(), "edit_journal")) ==
        json::dump(json::get(after.get(), "edit_journal")));
}

TEST_CASE("config conflicts: journal and effective values share the SQLite commit and survive pruning") {
  const std::string directory = tempDir() + "/doorbell-config-conflict-" + hexEncode(randomBytes(8));
  std::string before, id;
  {
    ConfigConflictFleet f(directory); f.makeConflict(false);
    id = f.a->nodeId(); before = f.a->configSnapshotJson();
    sqlite3* connection = nullptr;
    REQUIRE(sqlite3_open((directory + "/doorbell.db").c_str(), &connection) == SQLITE_OK);
    REQUIRE(sqlite3_exec(connection,
        "CREATE TRIGGER fail_edit_journal BEFORE INSERT ON config "
        "WHEN NEW.key LIKE '_config_changes.%' BEGIN SELECT RAISE(FAIL,'injected journal failure'); END",
        nullptr, nullptr, nullptr) == SQLITE_OK);
    auto failed = json::parse(f.a->setConfigJson("separate.atomic", "true"));
    CHECK_FALSE(json::getBool(failed.get(), "ok"));
    CHECK(f.a->configJson().find("atomic") == std::string::npos);
    auto previous = json::parse(before), after = json::parse(f.a->configSnapshotJson());
    CHECK(json::dump(json::get(previous.get(), "edit_conflicts")) ==
          json::dump(json::get(after.get(), "edit_conflicts")));
    CHECK(json::getString(previous.get(), "revision") == json::getString(after.get(), "revision"));
    REQUIRE(sqlite3_exec(connection, "DROP TRIGGER fail_edit_journal", nullptr, nullptr, nullptr) == SQLITE_OK);
    sqlite3_close(connection);
  }
  Store store; REQUIRE(store.open(directory + "/doorbell.db"));
  auto loaded = store.configLoadAll(); REQUIRE(configEditRecordsValid(loaded));
  SimClock clock{1'700'000'500'000LL, 0}; HlcClock hlc(clock, id.substr(0, 8));
  LwwMap config(id, hlc); config.load(loaded);
  auto current = json::parse(config.materializeJson());
  const auto retained = json::dump(configEditConflicts(config.all(), current.get()).get());
  auto previous = json::parse(before);
  CHECK(retained == json::dump(json::get(previous.get(), "edit_conflicts")));
  store.pruneEvents(0, clock.wallMs());
  config.gcTombstones(config.versionVector(), "ffffffffffff-ffff-ffffffff");
  CHECK(json::dump(configEditConflicts(config.all(), current.get()).get()) == retained);
}

TEST_CASE("config conflicts: sensitive candidates are redacted and reserved history is immutable") {
  ConfigConflictFleet f;
  const std::string legacy = R"({"password":"test-only-secret","access_token":"test-only-bearer","pass_ref":"secret:test.reference","url":"https://test:private@example.invalid/"})";
  CHECK_FALSE(json::getBool(json::parse(f.a->setConfigJson("settings.credentials", legacy)).get(), "ok"));
  auto candidate = json::obj(); json::setItem(json::addObj(candidate.get(), "settings"), "credentials", json::parse(legacy));
  std::vector<LwwMutation> journal;
  const std::string author(32, 'a');
  CHECK(appendConfigEdits({}, {{"settings.credentials", legacy, false}}, candidate.get(), author, nullptr, &journal).empty());
  REQUIRE(journal.size() == 1);
  CHECK(journal[0].value_json.find("test-only-secret") == std::string::npos);
  CHECK(journal[0].value_json.find("test-only-bearer") == std::string::npos);
  CHECK(journal[0].value_json.find("test:private") == std::string::npos);
  CHECK(journal[0].value_json.find("secret:test.reference") != std::string::npos);
  CHECK(journal[0].value_json.find("requires_reentry\":true") != std::string::npos);
  LwwEntry record{journal[0].key, journal[0].value_json, false, "", author, 1};
  REQUIRE(configEditRecordsValid({record}));
  record.value_json += " "; CHECK_FALSE(configEditRecordsValid({record}));
  auto result = json::parse(f.a->setConfigJson("settings.reference_test", R"({"pass_ref":"secret:test.reference"})"));
  REQUIRE(json::getBool(result.get(), "ok")); f.run(500);
  f.net.partition({{"config-race-a"}, {"config-race-b"}});
  REQUIRE(json::getBool(json::parse(f.edit(*f.a, "A")).get(), "ok"));
  REQUIRE(json::getBool(json::parse(f.edit(*f.b, "B")).get(), "ok"));
  f.net.heal(); f.run(2000);
  auto snapshot = json::parse(f.a->configSnapshotJson());
  const auto text = json::dump(json::get(snapshot.get(), "edit_conflicts"));
  CHECK(text.find("test-only-secret") == std::string::npos);
  CHECK(text.find("test-only-bearer") == std::string::npos);
  CHECK(text.find("test:private") == std::string::npos);
  CHECK(text.find("secret:test.reference") != std::string::npos);

  for (const auto& key : {"_config_changes", "_config_changes.forged"}) {
    CHECK_FALSE(json::getBool(json::parse(f.a->setConfigJson(key, "{}" )).get(), "ok"));
    CHECK_FALSE(json::getBool(json::parse(f.a->deleteConfigKeyJson(key)).get(), "ok"));
  }
}

TEST_CASE("config conflicts: per entity capacity blocks publication instead of dropping intent") {
  ConfigConflictFleet f;
  f.net.partition({{"config-race-a"}, {"config-race-b"}});
  for (int i = 0; i < 64; ++i) {
    auto result = json::parse(f.edit(*f.a, std::to_string(i)));
    CAPTURE(i); REQUIRE(json::getBool(result.get(), "ok"));
  }
  auto before = json::parse(f.a->configSnapshotJson());
  auto result = json::parse(f.edit(*f.a, "must not publish"));
  CHECK(json::getString(result.get(), "error_code") == "config_history_capacity_exceeded");
  auto after = json::parse(f.a->configSnapshotJson());
  CHECK(json::getString(before.get(), "revision") == json::getString(after.get(), "revision"));
  CHECK(f.a->configJson().find("must not publish") == std::string::npos);
  CHECK(json::getInt(json::get(after.get(), "edit_journal"), "records") == 64);
}
