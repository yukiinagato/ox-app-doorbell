#include <cstdio>
#include <condition_variable>
#include <map>
#include <mutex>
#include <string>
#include <vector>

#include <unistd.h>

#include <sqlite3.h>

#include "doctest.h"
#include "events/events.h"
#include "node/node.h"
#include "store/store.h"
#include "util/clock.h"
#include "util/hlc.h"
#include "util/json.h"

using namespace db;

namespace {

struct EventSink {
  std::mutex mu;
  std::condition_variable cv;
  std::vector<std::string> events;

  void push(const std::string& event) {
    std::lock_guard<std::mutex> lock(mu);
    events.push_back(event);
    cv.notify_all();
  }

  size_t countEventType(const std::string& type) {
    std::lock_guard<std::mutex> lock(mu);
    size_t count = 0;
    for (const auto& raw : events) {
      auto event = json::parse(raw);
      if (event && json::getString(event.get(), "t") == "event" &&
          json::getString(event.get(), "type") == type)
        ++count;
    }
    return count;
  }
};

NodeOptions v2NodeOptions() {
  NodeOptions options;
  options.data_dir = ":memory:";
  options.name = "contract-v2";
  options.role = "door_station";
  options.door = "d_front";
  options.listen_addr = "contract-v2:1";
  options.advertise_addr = "contract-v2:1";
  options.enable_beacon = false;
  options.http_port = 0;
  options.psk.fill(0x42);
  return options;
}

std::string contractTempDir() {
  char path[] = "/tmp/doorbell_contract_v2_XXXXXX";
  char* created = mkdtemp(path);
  REQUIRE(created != nullptr);
  return created;
}

EventRecord lifecycleEvent(const std::string& type, uint64_t seq, int64_t wall_ms,
                           const std::string& payload) {
  EventRecord event;
  event.origin = "contractorigin0000000000000000";
  event.seq = seq;
  event.type = type;
  event.door = "d_front";
  event.device = event.origin;
  event.hlc = HlcClock::format(wall_ms, 0, "contract");
  event.wall_ms = wall_ms;
  event.payload_json = payload;
  return event;
}

void putLegacyConfig(Store& store, const std::string& key, const std::string& value,
                     uint64_t seq) {
  LwwEntry entry;
  entry.key = key;
  entry.value_json = value;
  entry.hlc = HlcClock::format(1'000 + static_cast<int64_t>(seq), 0, "legacy");
  entry.author = "legacy-author";
  entry.seq = seq;
  store.configPut(entry);
}

void removeContractDir(const std::string& dir) {
  for (const char* name : {"doorbell.db", "doorbell.db-wal", "doorbell.db-shm"})
    std::remove((dir + "/" + name).c_str());
  ::rmdir((dir + "/assets").c_str());
  ::rmdir(dir.c_str());
}

bool setContractConfigWriteFailure(const std::string& path, bool enabled) {
  sqlite3* db = nullptr;
  if (sqlite3_open(path.c_str(), &db) != SQLITE_OK) {
    if (db) sqlite3_close(db);
    return false;
  }
  const char* sql = enabled
      ? "CREATE TRIGGER fail_config_write BEFORE INSERT ON config "
        "BEGIN SELECT RAISE(FAIL,'injected config write failure'); END"
      : "DROP TRIGGER IF EXISTS fail_config_write";
  const bool ok = sqlite3_exec(db, sql, nullptr, nullptr, nullptr) == SQLITE_OK;
  sqlite3_close(db);
  return ok;
}

bool setContractEventProjectionFailure(const std::string& path, bool enabled) {
  sqlite3* db = nullptr;
  if (sqlite3_open(path.c_str(), &db) != SQLITE_OK) {
    if (db) sqlite3_close(db);
    return false;
  }
  const char* sql = enabled
      ? "CREATE TRIGGER fail_event_projection BEFORE UPDATE OF frontier "
        "ON event_origin_state WHEN NEW.frontier > OLD.frontier "
        "BEGIN SELECT RAISE(FAIL,'injected event projection failure'); END"
      : "DROP TRIGGER IF EXISTS fail_event_projection";
  const bool ok = sqlite3_exec(db, sql, nullptr, nullptr, nullptr) == SQLITE_OK;
  sqlite3_close(db);
  return ok;
}

}  // namespace

TEST_CASE("secret contract: loaded runtime credentials migrate before export or use") {
  const std::string dir = contractTempDir();
  const std::string node_id = "0123456789abcdef0123456789abcdef";
  {
    Store store;
    REQUIRE(store.open(dir + "/doorbell.db"));
    store.metaSet("node_id", node_id);
    putLegacyConfig(store, "sip.accounts." + node_id + ".user", "\"101\"", 1);
    putLegacyConfig(store, "sip.accounts." + node_id + ".pass", "\"sip-legacy\"", 2);
    putLegacyConfig(
        store, "integrations",
        R"({"mqtt":{"host":"broker.invalid","pass":"mqtt-legacy"},"telegram":{"bot_token":"telegram-legacy"},"webrtc":{"sip_user":"201","sip_pass":"webrtc-legacy"}})",
        3);
  }

  std::map<std::string, std::string> secure_values;
  {
    NodeOptions options = v2NodeOptions();
    options.data_dir = dir;
    options.seed_default_config = false;
    Node node(options);
    node.setSecureStore(
        [&](const std::string& key) {
          const auto it = secure_values.find(key);
          return it == secure_values.end() ? std::string() : it->second;
        },
        [&](const std::string& key, const std::string& value) {
          secure_values[key] = value;
          return true;
        });
    REQUIRE(node.start());

    const std::string config = node.configJson();
    for (const char* plaintext : {"sip-legacy", "mqtt-legacy", "telegram-legacy",
                                  "webrtc-legacy"})
      CHECK(config.find(plaintext) == std::string::npos);
    auto parsed = json::parse(config);
    REQUIRE(parsed);
    cJSON* account = json::get(json::get(json::get(parsed.get(), "sip"), "accounts"),
                               node_id.c_str());
    CHECK(json::getString(account, "pass").empty());
    CHECK(json::getString(account, "pass_ref").rfind("secret:", 0) == 0);
    cJSON* integrations = json::get(parsed.get(), "integrations");
    cJSON* mqtt = json::get(integrations, "mqtt");
    cJSON* telegram = json::get(integrations, "telegram");
    cJSON* webrtc = json::get(integrations, "webrtc");
    CHECK(json::getString(mqtt, "pass").empty());
    CHECK(json::getString(mqtt, "pass_ref").rfind("secret:", 0) == 0);
    CHECK(json::getString(telegram, "bot_token").empty());
    CHECK(json::getString(telegram, "bot_token_ref").rfind("secret:", 0) == 0);
    CHECK(json::getString(webrtc, "sip_pass").empty());
    CHECK(json::getString(webrtc, "sip_pass_ref").rfind("secret:", 0) == 0);
    CHECK(secure_values.size() == 4);
    for (const char* plaintext : {"sip-legacy", "mqtt-legacy", "telegram-legacy",
                                  "webrtc-legacy"}) {
      bool found = false;
      for (const auto& value : secure_values) found = found || value.second == plaintext;
      CHECK(found);
    }
    auto status = json::parse(node.statusJson());
    REQUIRE(status);
    CHECK(json::getString(json::get(status.get(), "sip"), "credential_source") ==
          "secure_store");
    CHECK(json::get(json::get(status.get(), "runtime"), "core_secret_migration") == nullptr);
    node.stop();
  }

  {
    Store store;
    REQUIRE(store.open(dir + "/doorbell.db"));
    for (const auto& entry : store.configLoadAll())
      for (const char* plaintext : {"sip-legacy", "mqtt-legacy", "telegram-legacy",
                                    "webrtc-legacy"})
        CHECK(entry.value_json.find(plaintext) == std::string::npos);
  }
  removeContractDir(dir);
}

TEST_CASE("secret contract: failed migration removes plaintext and reports boot fallback") {
  const std::string dir = contractTempDir();
  const std::string node_id = "fedcba9876543210fedcba9876543210";
  {
    Store store;
    REQUIRE(store.open(dir + "/doorbell.db"));
    store.metaSet("node_id", node_id);
    putLegacyConfig(store, "sip.accounts." + node_id + ".user", "\"101\"", 1);
    putLegacyConfig(store, "sip.accounts." + node_id + ".pass", "\"sip-failed\"", 2);
    putLegacyConfig(
        store, "integrations",
        R"({"mqtt":{"host":"broker.invalid","pass":"mqtt-failed"},"telegram":{"bot_token":"telegram-failed"},"webrtc":{"sip_user":"201","sip_pass":"webrtc-failed"}})",
        3);
  }

  int put_attempts = 0;
  {
    NodeOptions options = v2NodeOptions();
    options.data_dir = dir;
    options.seed_default_config = false;
    options.sip_pass = "boot-only-secret";
    Node node(options);
    node.setSecureStore(
        [](const std::string&) { return std::string(); },
        [&](const std::string&, const std::string&) {
          ++put_attempts;
          return false;
        });
    REQUIRE(node.start());
    CHECK(put_attempts == 4);

    const std::string config = node.configJson();
    const std::string status_json = node.statusJson();
    for (const char* plaintext : {"sip-failed", "mqtt-failed", "telegram-failed",
                                  "webrtc-failed", "boot-only-secret"}) {
      CHECK(config.find(plaintext) == std::string::npos);
      CHECK(status_json.find(plaintext) == std::string::npos);
    }
    auto status = json::parse(status_json);
    REQUIRE(status);
    CHECK(json::getString(json::get(status.get(), "sip"), "credential_source") == "boot");
    cJSON* migration = json::get(json::get(status.get(), "runtime"),
                                 "core_secret_migration");
    REQUIRE(migration);
    CHECK_FALSE(json::getBool(migration, "ok", true));
    CHECK(json::getBool(migration, "fail_closed"));
    const std::string migration_json = json::dump(migration);
    for (const char* kind : {"sip", "mqtt", "telegram", "webrtc"})
      CHECK(migration_json.find(std::string("legacy_") + kind +
                                "_credential_secure_store_failed") != std::string::npos);
    node.stop();
  }

  {
    Store store;
    REQUIRE(store.open(dir + "/doorbell.db"));
    for (const auto& entry : store.configLoadAll())
      for (const char* plaintext : {"sip-failed", "mqtt-failed", "telegram-failed",
                                    "webrtc-failed", "boot-only-secret"})
        CHECK(entry.value_json.find(plaintext) == std::string::npos);
  }
  removeContractDir(dir);
}

TEST_CASE("secret contract: durable scrub failure refuses startup and retries safely") {
  const std::string dir = contractTempDir();
  const std::string db_path = dir + "/doorbell.db";
  const std::string node_id = "abcddcba76543210abcddcba76543210";
  {
    Store store;
    REQUIRE(store.open(db_path));
    store.metaSet("node_id", node_id);
    putLegacyConfig(store, "sip.accounts." + node_id + ".user", "\"101\"", 1);
    putLegacyConfig(store, "sip.accounts." + node_id + ".pass", "\"disk-secret\"", 2);
  }
  REQUIRE(setContractConfigWriteFailure(db_path, true));

  std::map<std::string, std::string> secure_values;
  auto install_secure_store = [&](Node& node) {
    node.setSecureStore(
        [&](const std::string& key) {
          const auto it = secure_values.find(key);
          return it == secure_values.end() ? std::string() : it->second;
        },
        [&](const std::string& key, const std::string& value) {
          secure_values[key] = value;
          return true;
        });
  };

  {
    NodeOptions options = v2NodeOptions();
    options.data_dir = dir;
    options.seed_default_config = false;
    Node node(options);
    install_secure_store(node);
    CHECK_FALSE(node.start());
    CHECK(node.configJson() == "{}");
    bool secured = false;
    for (const auto& item : secure_values) secured = secured || item.second == "disk-secret";
    CHECK(secured);
  }

  {
    Store store;
    REQUIRE(store.open(db_path));
    bool plaintext_remains = false;
    for (const auto& entry : store.configLoadAll())
      plaintext_remains = plaintext_remains || entry.value_json.find("disk-secret") !=
          std::string::npos;
    CHECK(plaintext_remains);
  }

  REQUIRE(setContractConfigWriteFailure(db_path, false));
  {
    NodeOptions options = v2NodeOptions();
    options.data_dir = dir;
    options.seed_default_config = false;
    Node node(options);
    install_secure_store(node);
    REQUIRE(node.start());
    CHECK(node.configJson().find("disk-secret") == std::string::npos);
    auto config = json::parse(node.configJson());
    REQUIRE(config);
    cJSON* account = json::get(json::get(json::get(config.get(), "sip"), "accounts"),
                               node_id.c_str());
    CHECK(json::getString(account, "pass").empty());
    CHECK(json::getString(account, "pass_ref").rfind("secret:", 0) == 0);
    node.stop();
  }

  {
    Store store;
    REQUIRE(store.open(db_path));
    for (const auto& entry : store.configLoadAll())
      CHECK(entry.value_json.find("disk-secret") == std::string::npos);
  }
  removeContractDir(dir);
}

TEST_CASE("call flow v2: retry, purpose update, and cancellation are idempotent") {
  Node node(v2NodeOptions());
  EventSink sink;
  node.setUiEventCb([&](const std::string& event) { sink.push(event); });
  REQUIRE(node.start());

  const std::string call_id = node.pressV2("d_front", "");
  REQUIRE(call_id.size() == 32);
  CHECK(sink.countEventType("press") == 1);

  CHECK(node.pressV2("d_front", "") == call_id);
  CHECK(sink.countEventType("press") == 1);

  CHECK(node.selectPurposeV2("d_front", call_id, "p_delivery"));
  CHECK(sink.countEventType("purpose_selected") == 1);
  CHECK(node.selectPurposeV2("d_front", call_id, "p_delivery"));
  CHECK(sink.countEventType("purpose_selected") == 1);
  CHECK_FALSE(node.selectPurposeV2("d_front", "stale", "p_delivery"));

  CHECK(node.cancelCallV2("d_front", call_id, "visitor"));
  CHECK(sink.countEventType("call_cancelled") == 1);
  CHECK(node.cancelCallV2("d_front", call_id, "visitor"));
  CHECK(sink.countEventType("call_cancelled") == 1);
  CHECK(node.statusJson().find(call_id) == std::string::npos);
  node.stop();
}

TEST_CASE("call lifecycle v2 binds only the matching established shell dialog") {
  Node node(v2NodeOptions());
  EventSink sink;
  node.setUiEventCb([&](const std::string& event) { sink.push(event); });
  REQUIRE(node.start());

  const std::string call_id = node.pressV2("d_front", "");
  REQUIRE(!call_id.empty());
  CHECK_FALSE(node.reportCallAnsweredV2("d_front", call_id, 1));
  CHECK_FALSE(node.reportCallAnsweredV2("d_side", call_id, 0));
  CHECK(sink.countEventType("call_answered") == 0);

  CHECK(node.reportCallAnsweredV2("d_front", call_id, 0));
  CHECK(sink.countEventType("call_answered") == 1);
  CHECK_FALSE(node.selectPurposeV2("d_front", call_id, "p_delivery"));
  CHECK(sink.countEventType("purpose_selected") == 0);
  CHECK(node.reportCallAnsweredV2("d_front", call_id, 0));
  CHECK(sink.countEventType("call_answered") == 1);
  CHECK_FALSE(node.cancelCallV2("d_front", call_id, "visitor"));

  CHECK_FALSE(node.reportCallEndedV2("d_front", call_id, 1, "sip_ended"));
  CHECK_FALSE(node.reportCallEndedV2("d_side", call_id, 0, "sip_ended"));
  CHECK(node.reportCallEndedV2("d_front", call_id, 0, "sip_ended"));
  CHECK(sink.countEventType("call_ended") == 1);
  CHECK(node.reportCallEndedV2("d_front", call_id, 0, "sip_ended"));
  CHECK(sink.countEventType("call_ended") == 1);
  CHECK_FALSE(node.reportCallAnsweredV2("d_front", call_id, 0));
  CHECK(node.statusJson().find(call_id) == std::string::npos);
  node.stop();
}

TEST_CASE("call lifecycle retries durable answer and end writes at the normal boundary") {
  const std::string dir = contractTempDir();
  const std::string db_path = dir + "/doorbell.db";
  SimClock clock(1'700'000'000'000LL, 0);
  Runloop loop(clock);
  NodeOptions options = v2NodeOptions();
  options.data_dir = dir;
  NodeDeps deps;
  deps.clock = &clock;
  deps.loop = &loop;
  Node node(options, std::move(deps));
  EventSink sink;
  node.setUiEventCb([&](const std::string& event) { sink.push(event); });
  REQUIRE(node.start());

  const std::string call_id = node.pressV2("d_front", "");
  REQUIRE(!call_id.empty());
  REQUIRE(setContractEventProjectionFailure(db_path, true));
  CHECK_FALSE(node.reportCallAnsweredV2("d_front", call_id, 0));
  CHECK(sink.countEventType("call_answered") == 0);

  for (const int64_t delay : {2'000LL, 5'000LL, 10'000LL, 30'000LL, 60'000LL}) {
    clock.advance(delay - 1);
    loop.pumpDue();
    CHECK(sink.countEventType("call_answered") == 0);
    clock.advance(1);
    loop.pumpDue();
    CHECK(sink.countEventType("call_answered") == 0);
  }
  REQUIRE(setContractEventProjectionFailure(db_path, false));
  clock.advance(59'999);
  loop.pumpDue();
  CHECK(sink.countEventType("call_answered") == 0);
  clock.advance(1);
  loop.pumpDue();
  CHECK(sink.countEventType("call_answered") == 1);
  CHECK(node.statusJson().find("\"state\":\"in_call\"") != std::string::npos);

  REQUIRE(setContractEventProjectionFailure(db_path, true));
  CHECK_FALSE(node.reportCallEndedV2("d_front", call_id, 0, "hangup"));
  CHECK(sink.countEventType("call_ended") == 0);
  REQUIRE(setContractEventProjectionFailure(db_path, false));
  clock.advance(1'999);
  loop.pumpDue();
  CHECK(sink.countEventType("call_ended") == 0);
  clock.advance(1);
  loop.pumpDue();
  CHECK(sink.countEventType("call_ended") == 1);
  CHECK(node.statusJson().find(call_id) == std::string::npos);

  node.stop();
  {
    Store store;
    REQUIRE(store.open(db_path));
    CHECK(store.countEventsOfType("call_answered") == 1);
    CHECK(store.countEventsOfType("call_ended") == 1);
  }
  removeContractDir(dir);
}

TEST_CASE("call lifecycle projection deterministically preserves the earliest dialog owner") {
  Store store;
  REQUIRE(store.open(":memory:"));
  REQUIRE(store.eventPut(lifecycleEvent(
      "press", 1, 1'000,
      R"({"schema_version":2,"call_id":"owned-call","stage_revision":0,"expires_at_ms":61000})")));

  EventRecord later = lifecycleEvent(
      "call_answered", 1, 3'000,
      R"({"schema_version":2,"call_id":"owned-call","stage_revision":0})");
  later.origin = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
  later.device = later.origin;
  later.hlc = HlcClock::format(3'000, 0, "later");
  REQUIRE(store.eventPut(later));

  EventRecord earlier = lifecycleEvent(
      "call_answered", 1, 2'000,
      R"({"schema_version":2,"call_id":"owned-call","stage_revision":0})");
  earlier.origin = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  earlier.device = earlier.origin;
  earlier.hlc = HlcClock::format(2'000, 0, "earlier");
  REQUIRE(store.eventPut(earlier));

  auto projection = store.callProjection("owned-call");
  REQUIRE(projection);
  CHECK(projection->state == "in_call");
  CHECK(projection->dialog_owner == earlier.device);
  CHECK(projection->answered_hlc == earlier.hlc);

  EventRecord losing_end = lifecycleEvent(
      "call_ended", 2, 3'500,
      R"({"schema_version":2,"call_id":"owned-call","stage_revision":0,"reason":"sip_ended"})");
  losing_end.origin = later.origin;
  losing_end.device = later.device;
  losing_end.hlc = HlcClock::format(3'500, 0, "loser-ended");
  REQUIRE(store.eventPut(losing_end));
  projection = store.callProjection("owned-call");
  REQUIRE(projection);
  CHECK(projection->state == "in_call");
  CHECK(projection->dialog_owner == earlier.device);

  EventRecord ended = lifecycleEvent(
      "call_ended", 2, 4'000,
      R"({"schema_version":2,"call_id":"owned-call","stage_revision":0,"reason":"sip_ended"})");
  ended.origin = earlier.origin;
  ended.device = earlier.device;
  ended.hlc = HlcClock::format(4'000, 0, "ended");
  REQUIRE(store.eventPut(ended));
  projection = store.callProjection("owned-call");
  REQUIRE(projection);
  CHECK(projection->state == "ended");
  CHECK(projection->dialog_owner == earlier.device);
}

TEST_CASE("call purpose projection converges on an earlier answer in either arrival order") {
  Store answer_first;
  Store purpose_first;
  REQUIRE(answer_first.open(":memory:"));
  REQUIRE(purpose_first.open(":memory:"));

  EventRecord press = lifecycleEvent(
      "press", 1, 1'000,
      R"({"schema_version":2,"call_id":"answer-first","stage_revision":0,"expires_at_ms":61000})");
  press.origin = "answer-first-door";
  press.device = press.origin;
  press.hlc = HlcClock::format(1'000, 0, press.origin);
  EventRecord answered = lifecycleEvent(
      "call_answered", 1, 2'000,
      R"({"schema_version":2,"call_id":"answer-first","stage_revision":0})");
  answered.origin = "answer-first-owner";
  answered.device = answered.origin;
  answered.hlc = HlcClock::format(2'000, 0, answered.origin);
  EventRecord late_purpose = lifecycleEvent(
      "purpose_selected", 2, 3'000,
      R"({"schema_version":2,"call_id":"answer-first","purpose":"p_delivery","stage_revision":1})");
  late_purpose.origin = press.origin;
  late_purpose.device = late_purpose.origin;
  late_purpose.hlc = HlcClock::format(3'000, 0, late_purpose.origin);

  for (Store* store : {&answer_first, &purpose_first}) REQUIRE(store->eventPut(press));
  REQUIRE(answer_first.eventPut(answered));
  REQUIRE(answer_first.eventPut(late_purpose));
  REQUIRE(purpose_first.eventPut(late_purpose));
  REQUIRE(purpose_first.eventPut(answered));

  for (Store* store : {&answer_first, &purpose_first}) {
    auto projection = store->callProjection("answer-first");
    REQUIRE(projection);
    CHECK(projection->state == "in_call");
    CHECK(projection->stage_revision == 0);
    CHECK(projection->purpose.empty());
    CHECK(projection->updated_hlc == answered.hlc);
    CHECK(projection->dialog_owner == answered.device);
    CHECK(projection->answered_hlc == answered.hlc);
  }
}

TEST_CASE("call purpose projection converges on an earlier purpose in either arrival order") {
  Store purpose_first;
  Store answer_first;
  REQUIRE(purpose_first.open(":memory:"));
  REQUIRE(answer_first.open(":memory:"));

  EventRecord press = lifecycleEvent(
      "press", 1, 1'000,
      R"({"schema_version":2,"call_id":"purpose-first","stage_revision":0,"expires_at_ms":61000})");
  press.origin = "purpose-first-door";
  press.device = press.origin;
  press.hlc = HlcClock::format(1'000, 0, press.origin);
  EventRecord purpose = lifecycleEvent(
      "purpose_selected", 2, 2'000,
      R"({"schema_version":2,"call_id":"purpose-first","purpose":"p_delivery","stage_revision":1})");
  purpose.origin = press.origin;
  purpose.device = purpose.origin;
  purpose.hlc = HlcClock::format(2'000, 0, purpose.origin);
  EventRecord stale_answer = lifecycleEvent(
      "call_answered", 1, 3'000,
      R"({"schema_version":2,"call_id":"purpose-first","stage_revision":0})");
  stale_answer.origin = "purpose-first-stale-owner";
  stale_answer.device = stale_answer.origin;
  stale_answer.hlc = HlcClock::format(3'000, 0, stale_answer.origin);

  for (Store* store : {&purpose_first, &answer_first}) REQUIRE(store->eventPut(press));
  REQUIRE(purpose_first.eventPut(purpose));
  REQUIRE(purpose_first.eventPut(stale_answer));
  REQUIRE(answer_first.eventPut(stale_answer));
  REQUIRE(answer_first.eventPut(purpose));

  for (Store* store : {&purpose_first, &answer_first}) {
    auto projection = store->callProjection("purpose-first");
    REQUIRE(projection);
    CHECK(projection->state == "ringing");
    CHECK(projection->stage_revision == 1);
    CHECK(projection->purpose == "p_delivery");
    CHECK(projection->updated_hlc == purpose.hlc);
    CHECK(projection->dialog_owner.empty());
    CHECK(projection->answered_hlc.empty());
  }

  EventRecord matching_answer = lifecycleEvent(
      "call_answered", 1, 4'000,
      R"({"schema_version":2,"call_id":"purpose-first","stage_revision":1})");
  matching_answer.origin = "purpose-first-matching-owner";
  matching_answer.device = matching_answer.origin;
  matching_answer.hlc = HlcClock::format(4'000, 0, matching_answer.origin);
  for (Store* store : {&purpose_first, &answer_first}) {
    REQUIRE(store->eventPut(matching_answer));
    auto projection = store->callProjection("purpose-first");
    REQUIRE(projection);
    CHECK(projection->state == "in_call");
    CHECK(projection->stage_revision == 1);
    CHECK(projection->purpose == "p_delivery");
    CHECK(projection->dialog_owner == matching_answer.device);
    CHECK(projection->answered_hlc == matching_answer.hlc);
  }
}

TEST_CASE("call purpose projection cannot create or revive terminal calls") {
  Store store;
  REQUIRE(store.open(":memory:"));

  REQUIRE(store.eventPut(lifecycleEvent(
      "purpose_selected", 1, 1'000,
      R"({"schema_version":2,"call_id":"missing-call","purpose":"p_delivery","stage_revision":1})")));
  CHECK_FALSE(store.callProjection("missing-call"));

  REQUIRE(store.eventPut(lifecycleEvent(
      "press", 2, 2'000,
      R"({"schema_version":2,"call_id":"cancelled-call","stage_revision":0,"expires_at_ms":62000})")));
  REQUIRE(store.eventPut(lifecycleEvent(
      "call_cancelled", 3, 3'000,
      R"({"schema_version":2,"call_id":"cancelled-call","stage_revision":0,"reason":"visitor"})")));
  auto cancelled = store.callProjection("cancelled-call");
  REQUIRE(cancelled);
  const std::string cancelled_hlc = cancelled->updated_hlc;
  REQUIRE(store.eventPut(lifecycleEvent(
      "purpose_selected", 4, 4'000,
      R"({"schema_version":2,"call_id":"cancelled-call","purpose":"p_delivery","stage_revision":1})")));
  cancelled = store.callProjection("cancelled-call");
  REQUIRE(cancelled);
  CHECK(cancelled->state == "cancelled");
  CHECK(cancelled->stage_revision == 0);
  CHECK(cancelled->purpose.empty());
  CHECK(cancelled->updated_hlc == cancelled_hlc);

  REQUIRE(store.eventPut(lifecycleEvent(
      "press", 5, 5'000,
      R"({"schema_version":2,"call_id":"ended-call","stage_revision":0,"expires_at_ms":65000})")));
  REQUIRE(store.eventPut(lifecycleEvent(
      "call_answered", 6, 6'000,
      R"({"schema_version":2,"call_id":"ended-call","stage_revision":0})")));
  REQUIRE(store.eventPut(lifecycleEvent(
      "call_ended", 7, 7'000,
      R"({"schema_version":2,"call_id":"ended-call","stage_revision":0,"reason":"hangup"})")));
  auto ended = store.callProjection("ended-call");
  REQUIRE(ended);
  const std::string ended_hlc = ended->updated_hlc;
  REQUIRE(store.eventPut(lifecycleEvent(
      "purpose_selected", 8, 8'000,
      R"({"schema_version":2,"call_id":"ended-call","purpose":"p_delivery","stage_revision":1})")));
  ended = store.callProjection("ended-call");
  REQUIRE(ended);
  CHECK(ended->state == "ended");
  CHECK(ended->stage_revision == 0);
  CHECK(ended->purpose.empty());
  CHECK(ended->updated_hlc == ended_hlc);
}

TEST_CASE("call purpose and answer live state converge by HLC across a partition") {
  SimClock clock{1'700'000'000'000LL, 0};
  Runloop loop{clock};
  InMemNet net{loop};
  std::array<uint8_t, 32> psk{};
  psk.fill(0x67);

  MeshSettings timing;
  timing.heartbeat_ms = 30;
  timing.suspect_ms = 90;
  timing.dead_ms = 150;
  timing.gossip_ms = 50;
  timing.sync_ms = 50;
  timing.claim_ttl_ms = 300;
  timing.reconnect_ms = 50;

  auto options = [&](const std::string& address, const std::string& role, bool seed) {
    NodeOptions value;
    value.data_dir = ":memory:";
    value.name = address;
    value.role = role;
    value.door = role == "door_station" ? "d_front" : "";
    value.listen_addr = address;
    value.advertise_addr = address;
    value.enable_beacon = false;
    value.http_port = 0;
    value.seed_default_config = seed;
    value.psk = psk;
    value.mesh_timing_template = timing;
    value.use_mesh_timing_template = true;
    return value;
  };
  auto deps = [&](const std::string& address) {
    NodeDeps value;
    value.clock = &clock;
    value.loop = &loop;
    value.transport = net.makeTransport(address);
    value.discovery = net.makeDiscovery(address);
    return value;
  };
  auto run = [&](int64_t duration_ms) {
    for (int64_t elapsed = 0; elapsed < duration_ms; elapsed += 10) {
      clock.advance(10);
      loop.pumpDue();
    }
  };

  Node door(options("purpose-race-door", "door_station", true),
            deps("purpose-race-door"));
  Node indoor(options("purpose-race-indoor", "indoor_panel", false),
              deps("purpose-race-indoor"));
  EventSink door_events;
  EventSink indoor_events;
  door.setUiEventCb([&](const std::string& event) { door_events.push(event); });
  indoor.setUiEventCb([&](const std::string& event) { indoor_events.push(event); });
  REQUIRE(door.start());
  REQUIRE(indoor.start());
  run(1'500);

  const std::string call_id = door.pressV2("d_front", "");
  REQUIRE(!call_id.empty());
  run(500);

  net.partition({{"purpose-race-door"}, {"purpose-race-indoor"}});
  REQUIRE(indoor.reportCallAnsweredV2("d_front", call_id, 0));
  run(10);
  REQUIRE(door.selectPurposeV2("d_front", call_id, "p_delivery"));
  CHECK(indoor_events.countEventType("call_answered") == 1);
  CHECK(door_events.countEventType("purpose_selected") == 1);

  net.heal();
  run(2'000);

  for (Node* node : {&door, &indoor}) {
    auto status = json::parse(node->statusJson());
    REQUIRE(status);
    cJSON* calls = json::get(status.get(), "active_calls");
    REQUIRE(cJSON_GetArraySize(calls) == 1);
    cJSON* call = cJSON_GetArrayItem(calls, 0);
    CHECK(json::getString(call, "call_id") == call_id);
    CHECK(json::getString(call, "state") == "in_call");
    CHECK(json::getInt(call, "stage_revision") == 0);
    CHECK(json::getString(call, "purpose").empty());
    CHECK(json::getString(call, "dialog_owner") == indoor.nodeId());
  }
  CHECK(indoor_events.countEventType("purpose_selected") == 0);
  CHECK(door_events.countEventType("call_answered") == 1);

  REQUIRE(indoor.reportCallEndedV2("d_front", call_id, 0, "test_complete"));
  run(1'000);
  CHECK(door.statusJson().find(call_id) == std::string::npos);
  CHECK(indoor.statusJson().find(call_id) == std::string::npos);

  const std::string purpose_wins_id = door.pressV2("d_front", "");
  REQUIRE(!purpose_wins_id.empty());
  REQUIRE(purpose_wins_id != call_id);
  run(500);

  net.partition({{"purpose-race-door"}, {"purpose-race-indoor"}});
  REQUIRE(door.selectPurposeV2("d_front", purpose_wins_id, "p_delivery"));
  run(10);
  REQUIRE(indoor.reportCallAnsweredV2("d_front", purpose_wins_id, 0));

  net.heal();
  run(2'000);

  for (Node* node : {&door, &indoor}) {
    auto status = json::parse(node->statusJson());
    REQUIRE(status);
    cJSON* calls = json::get(status.get(), "active_calls");
    REQUIRE(cJSON_GetArraySize(calls) == 1);
    cJSON* call = cJSON_GetArrayItem(calls, 0);
    CHECK(json::getString(call, "call_id") == purpose_wins_id);
    CHECK(json::getString(call, "state") == "ringing");
    CHECK(json::getInt(call, "stage_revision") == 1);
    CHECK(json::getString(call, "purpose") == "p_delivery");
    CHECK(json::getString(call, "dialog_owner").empty());
  }
  CHECK(indoor_events.countEventType("purpose_selected") == 1);
  CHECK(door_events.countEventType("call_answered") == 1);
  CHECK_FALSE(indoor.reportCallEndedV2("d_front", purpose_wins_id, 0,
                                       "losing_dialog_ended"));

  door.stop();
  indoor.stop();
}

TEST_CASE("same-door concurrent presses converge and cannot replace an established call") {
  EventRecord a = lifecycleEvent(
      "press", 1, 2'000,
      R"({"schema_version":2,"call_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","stage_revision":0,"expires_at_ms":62000})");
  a.origin = "origin-a";
  a.device = a.origin;
  a.hlc = HlcClock::format(2'000, 0, "origin-a");
  EventRecord b = lifecycleEvent(
      "press", 1, 1'000,
      R"({"schema_version":2,"call_id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","stage_revision":0,"expires_at_ms":61000})");
  b.origin = "origin-b";
  b.device = b.origin;
  b.hlc = HlcClock::format(1'000, 0, "origin-b");

  Store first;
  Store second;
  REQUIRE(first.open(":memory:"));
  REQUIRE(second.open(":memory:"));
  REQUIRE(first.eventPut(a));
  REQUIRE(first.eventPut(b));
  REQUIRE(second.eventPut(b));
  REQUIRE(second.eventPut(a));
  for (Store* store : {&first, &second}) {
    auto winner = store->callProjection("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    auto loser = store->callProjection("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    REQUIRE(winner);
    REQUIRE(loser);
    CHECK(winner->state == "ringing");
    CHECK(loser->state == "ended");
    CHECK(loser->terminal_reason == "concurrent_press_loser");
  }

  EventRecord answered = lifecycleEvent(
      "call_answered", 1, 3'000,
      R"({"schema_version":2,"call_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","stage_revision":0})");
  answered.origin = "answer-owner";
  answered.device = answered.origin;
  answered.hlc = HlcClock::format(3'000, 0, "answer-owner");
  REQUIRE(first.eventPut(answered));
  EventRecord replacement = lifecycleEvent(
      "press", 1, 4'000,
      R"({"schema_version":2,"call_id":"00000000000000000000000000000000","stage_revision":0,"expires_at_ms":64000})");
  replacement.origin = "origin-new";
  replacement.device = replacement.origin;
  replacement.hlc = HlcClock::format(4'000, 0, "origin-new");
  REQUIRE(first.eventPut(replacement));
  auto established = first.callProjection("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
  auto rejected = first.callProjection("00000000000000000000000000000000");
  REQUIRE(established);
  REQUIRE(rejected);
  CHECK(established->state == "in_call");
  CHECK(rejected->state == "ended");
  CHECK(rejected->terminal_reason == "concurrent_press_loser");
}

TEST_CASE("same-door answer wins regardless of when the competing press arrives") {
  EventRecord a = lifecycleEvent(
      "press", 1, 1'000,
      R"({"schema_version":2,"call_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","stage_revision":0,"expires_at_ms":61000})");
  a.origin = "answer-race-origin-a";
  a.device = a.origin;
  a.hlc = HlcClock::format(1'000, 0, a.origin);

  EventRecord b = lifecycleEvent(
      "press", 1, 1'100,
      R"({"schema_version":2,"call_id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","stage_revision":0,"expires_at_ms":61100})");
  b.origin = "answer-race-origin-b";
  b.device = b.origin;
  b.hlc = HlcClock::format(1'100, 0, b.origin);

  EventRecord b_answer = lifecycleEvent(
      "call_answered", 1, 2'000,
      R"({"schema_version":2,"call_id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","stage_revision":0,"expires_at_ms":61100})");
  b_answer.origin = "answer-race-owner-b";
  b_answer.device = b_answer.origin;
  b_answer.hlc = HlcClock::format(2'000, 0, b_answer.origin);

  Store presses_first;
  Store answer_first;
  REQUIRE(presses_first.open(":memory:"));
  REQUIRE(answer_first.open(":memory:"));

  REQUIRE(presses_first.eventPut(a));
  REQUIRE(presses_first.eventPut(b));
  REQUIRE(presses_first.eventPut(b_answer));

  REQUIRE(answer_first.eventPut(b));
  REQUIRE(answer_first.eventPut(b_answer));
  REQUIRE(answer_first.eventPut(a));

  for (Store* store : {&presses_first, &answer_first}) {
    auto rejected = store->callProjection("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    auto established = store->callProjection("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    REQUIRE(rejected);
    REQUIRE(established);
    CHECK(rejected->state == "ended");
    CHECK(rejected->terminal_reason == "concurrent_press_loser");
    CHECK(established->state == "in_call");
    CHECK(established->dialog_owner == b_answer.device);
    CHECK(established->answered_hlc == b_answer.hlc);
  }
}

TEST_CASE("an answer that arrives before its press retains the press origin") {
  EventRecord press = lifecycleEvent(
      "press", 1, 1'000,
      R"({"schema_version":2,"call_id":"answer-before-press-call","stage_revision":0,"expires_at_ms":61000})");
  press.origin = "answer-before-press-door";
  press.device = press.origin;
  press.hlc = HlcClock::format(1'000, 0, press.origin);

  EventRecord answer = lifecycleEvent(
      "call_answered", 1, 2'000,
      R"({"schema_version":2,"call_id":"answer-before-press-call","call_origin":"answer-before-press-door","stage_revision":0,"expires_at_ms":61000})");
  answer.origin = "answer-before-press-owner";
  answer.device = answer.origin;
  answer.hlc = HlcClock::format(2'000, 0, answer.origin);

  Store press_first;
  Store answer_first;
  REQUIRE(press_first.open(":memory:"));
  REQUIRE(answer_first.open(":memory:"));
  REQUIRE(press_first.eventPut(press));
  REQUIRE(press_first.eventPut(answer));
  REQUIRE(answer_first.eventPut(answer));
  REQUIRE(answer_first.eventPut(press));

  for (Store* store : {&press_first, &answer_first}) {
    auto projection = store->callProjection("answer-before-press-call");
    REQUIRE(projection);
    CHECK(projection->state == "in_call");
    CHECK(projection->origin == press.origin);
    CHECK(projection->dialog_owner == answer.device);
    CHECK(projection->answered_hlc == answer.hlc);
  }
}

TEST_CASE("a terminal call fence promotes only causally newer same-door presses") {
  auto press = [](const std::string& origin, const std::string& call_id,
                  int64_t wall_ms) {
    EventRecord event = lifecycleEvent(
        "press", 1, wall_ms,
        "{\"schema_version\":2,\"call_id\":\"" + call_id +
            "\",\"stage_revision\":0,\"expires_at_ms\":61000}");
    event.origin = origin;
    event.device = origin;
    event.hlc = HlcClock::format(wall_ms, 0, origin);
    return event;
  };
  const std::string old_id = "00000000000000000000000000000001";
  const std::string newer_id = "fffffffffffffffffffffffffffffff1";
  const std::string stale_id = "fffffffffffffffffffffffffffffff2";
  EventRecord old_press = press("terminal-fence-door", old_id, 1'000);
  EventRecord newer_press = press("terminal-fence-newer", newer_id, 3'000);
  EventRecord stale_press = press("terminal-fence-stale", stale_id, 1'500);
  EventRecord cancel = lifecycleEvent(
      "call_cancelled", 2, 2'000,
      "{\"schema_version\":2,\"call_id\":\"" + old_id +
          "\",\"stage_revision\":0,\"reason\":\"visitor\"}");
  cancel.origin = old_press.origin;
  cancel.device = cancel.origin;
  cancel.hlc = HlcClock::format(2'000, 0, cancel.origin);

  Store newer_before_terminal;
  Store terminal_before_newer;
  REQUIRE(newer_before_terminal.open(":memory:"));
  REQUIRE(terminal_before_newer.open(":memory:"));
  REQUIRE(newer_before_terminal.eventPut(old_press));
  REQUIRE(newer_before_terminal.eventPut(newer_press));
  REQUIRE(newer_before_terminal.eventPut(cancel));
  REQUIRE(terminal_before_newer.eventPut(old_press));
  REQUIRE(terminal_before_newer.eventPut(cancel));
  REQUIRE(terminal_before_newer.eventPut(newer_press));
  for (Store* store : {&newer_before_terminal, &terminal_before_newer}) {
    auto old_projection = store->callProjection(old_id);
    auto new_projection = store->callProjection(newer_id);
    REQUIRE(old_projection);
    REQUIRE(new_projection);
    CHECK(old_projection->state == "cancelled");
    CHECK(new_projection->state == "ringing");
    CHECK(new_projection->terminal_reason.empty());
  }

  Store stale_before_terminal;
  Store terminal_before_stale;
  REQUIRE(stale_before_terminal.open(":memory:"));
  REQUIRE(terminal_before_stale.open(":memory:"));
  REQUIRE(stale_before_terminal.eventPut(old_press));
  REQUIRE(stale_before_terminal.eventPut(stale_press));
  REQUIRE(stale_before_terminal.eventPut(cancel));
  REQUIRE(terminal_before_stale.eventPut(old_press));
  REQUIRE(terminal_before_stale.eventPut(cancel));
  REQUIRE(terminal_before_stale.eventPut(stale_press));
  for (Store* store : {&stale_before_terminal, &terminal_before_stale}) {
    auto old_projection = store->callProjection(old_id);
    auto stale_projection = store->callProjection(stale_id);
    REQUIRE(old_projection);
    REQUIRE(stale_projection);
    CHECK(old_projection->state == "cancelled");
    CHECK(stale_projection->state == "ended");
    CHECK(stale_projection->terminal_reason == "terminal_fence");
  }
}

TEST_CASE("same-door partitioned press and answer converge on the established candidate") {
  SimClock clock{1'700'000'000'000LL, 0};
  Runloop loop{clock};
  InMemNet net{loop};
  std::array<uint8_t, 32> psk{};
  psk.fill(0x68);

  MeshSettings timing;
  timing.heartbeat_ms = 30;
  timing.suspect_ms = 90;
  timing.dead_ms = 150;
  timing.gossip_ms = 50;
  timing.sync_ms = 50;
  timing.claim_ttl_ms = 300;
  timing.reconnect_ms = 50;

  auto options = [&](const std::string& address, bool seed) {
    NodeOptions value;
    value.data_dir = ":memory:";
    value.name = address;
    value.role = "door_station";
    value.door = "d_front";
    value.listen_addr = address;
    value.advertise_addr = address;
    value.enable_beacon = false;
    value.http_port = 0;
    value.seed_default_config = seed;
    value.psk = psk;
    value.mesh_timing_template = timing;
    value.use_mesh_timing_template = true;
    return value;
  };
  auto deps = [&](const std::string& address) {
    NodeDeps value;
    value.clock = &clock;
    value.loop = &loop;
    value.transport = net.makeTransport(address);
    value.discovery = net.makeDiscovery(address);
    return value;
  };
  auto run = [&](int64_t duration_ms) {
    for (int64_t elapsed = 0; elapsed < duration_ms; elapsed += 10) {
      clock.advance(10);
      loop.pumpDue();
    }
  };

  Node a(options("answer-race-a", true), deps("answer-race-a"));
  Node b(options("answer-race-b", false), deps("answer-race-b"));
  REQUIRE(a.start());
  REQUIRE(b.start());
  run(1'500);

  net.partition({{"answer-race-a"}, {"answer-race-b"}});
  const std::string a_call = a.pressV2("d_front", "");
  const std::string b_call = b.pressV2("d_front", "");
  REQUIRE(!a_call.empty());
  REQUIRE(!b_call.empty());
  REQUIRE(a_call != b_call);
  REQUIRE(b.reportCallAnsweredV2("d_front", b_call, 0));

  net.heal();
  run(2'000);

  for (Node* node : {&a, &b}) {
    auto status = json::parse(node->statusJson());
    REQUIRE(status);
    cJSON* calls = json::get(status.get(), "active_calls");
    REQUIRE(cJSON_GetArraySize(calls) == 1);
    cJSON* call = cJSON_GetArrayItem(calls, 0);
    CHECK(json::getString(call, "call_id") == b_call);
    CHECK(json::getString(call, "state") == "in_call");
    CHECK(json::getString(call, "dialog_owner") == b.nodeId());
  }
  CHECK_FALSE(a.reportCallEndedV2("d_front", a_call, 0, "losing_leg"));
  REQUIRE(b.reportCallEndedV2("d_front", b_call, 0, "test_complete"));
  run(1'000);
  CHECK(a.statusJson().find(b_call) == std::string::npos);
  CHECK(b.statusJson().find(b_call) == std::string::npos);

  a.stop();
  b.stop();
}

TEST_CASE("scoped quick reply tombstone converges when it arrives before its press") {
  const std::string call_id = "reply-before-press-call";
  EventRecord press = lifecycleEvent(
      "press", 1, 1'000,
      R"({"schema_version":2,"call_id":"reply-before-press-call","stage_revision":0,"expires_at_ms":61000})");
  press.origin = "reply-race-door";
  press.device = press.origin;
  press.hlc = HlcClock::format(1'000, 0, press.origin);

  EventRecord reply = lifecycleEvent(
      "reply", 1, 2'000,
      R"({"schema_version":2,"reply_id":"qr_away","call_id":"reply-before-press-call","call_origin":"reply-race-door","stage_revision":0})");
  reply.origin = "reply-race-indoor";
  reply.device = reply.origin;
  reply.hlc = HlcClock::format(2'000, 0, reply.origin);

  Store press_first;
  Store reply_first;
  REQUIRE(press_first.open(":memory:"));
  REQUIRE(reply_first.open(":memory:"));
  REQUIRE(press_first.eventPut(press));
  REQUIRE(press_first.eventPut(reply));
  REQUIRE(reply_first.eventPut(reply));
  REQUIRE(reply_first.eventPut(press));

  for (Store* store : {&press_first, &reply_first}) {
    auto projection = store->callProjection(call_id);
    REQUIRE(projection);
    CHECK(projection->state == "ended");
    CHECK(projection->terminal_reason == "reply");
    CHECK(projection->stage_revision == 0);
    CHECK(projection->updated_hlc == reply.hlc);
  }
}

TEST_CASE("rules: purpose revisions rerun button rules and emergency aliases match") {
  RuleEngine rules;
  rules.setConfig(R"({
    "trigger_rules": {
      "purpose": {"when":{"type":"button","purposes":["p_delivery"]},
                    "actions":[{"type":"chime"}]},
      "sos_on": {"when":{"type":"emergency_on"},
                  "actions":[{"type":"device_alert"}]},
      "sos_off": {"when":{"type":"emergency_off"},
                   "actions":[{"type":"device_alert"}]}
    }
  })");

  EventRecord purpose;
  purpose.type = "purpose_selected";
  purpose.payload_json = R"({"call_id":"c1","purpose":"p_delivery","stage_revision":1})";
  auto purpose_actions = rules.evaluate(purpose, 0, 0);
  REQUIRE(purpose_actions.size() == 1);
  CHECK(purpose_actions[0].type == "chime");

  EventRecord on;
  on.type = "emergency";
  auto on_actions = rules.evaluate(on, 0, 0);
  REQUIRE(on_actions.size() == 1);
  CHECK(on_actions[0].type == "device_alert");

  EventRecord off;
  off.type = "emergency_cancel";
  auto off_actions = rules.evaluate(off, 0, 0);
  REQUIRE(off_actions.size() == 1);
  CHECK(off_actions[0].type == "device_alert");
}

TEST_CASE("call flow v2: answered calls recover as in-call and ended calls stay resolved") {
  const std::string dir = contractTempDir();
  {
    Store store;
    REQUIRE(store.open(dir + "/doorbell.db"));
    store.metaSet("node_id", "contractorigin0000000000000000");
    REQUIRE(store.eventPut(lifecycleEvent(
        "press", 1, 1'000,
        R"({"schema_version":2,"call_id":"active-call","stage_revision":1,"expires_at_ms":61000,"purpose":"p_delivery"})")));
    REQUIRE(store.eventPut(lifecycleEvent(
        "call_answered", 2, 2'000,
        R"({"schema_version":2,"call_id":"active-call","stage_revision":1,"expires_at_ms":61000,"purpose":"p_delivery"})")));
  }

  SimClock clock(3'000);
  {
    NodeOptions options = v2NodeOptions();
    options.data_dir = dir;
    NodeDeps deps;
    deps.clock = &clock;
    Node node(options, std::move(deps));
    EventSink sink;
    node.setUiEventCb([&](const std::string& event) { sink.push(event); });
    REQUIRE(node.start());
    const std::string status = node.statusJson();
    CHECK(status.find("active-call") != std::string::npos);
    CHECK(status.find("\"state\":\"in_call\"") != std::string::npos);
    CHECK_FALSE(node.cancelCallV2("d_front", "active-call", "visitor"));
    clock.setWall(70'000);
    CHECK(node.pressV2("d_front", "") == "active-call");
    node.reportCallRecovery("active-call", true);
    node.stop();
  }

  {
    Store store;
    REQUIRE(store.open(dir + "/doorbell.db"));
    REQUIRE(store.eventPut(lifecycleEvent(
        "call_ended", 3, 4'000,
        R"({"schema_version":2,"call_id":"active-call","stage_revision":1,"reason":"hangup"})")));
  }
  clock.setWall(5'000);
  {
    NodeOptions options = v2NodeOptions();
    options.data_dir = dir;
    NodeDeps deps;
    deps.clock = &clock;
    Node node(options, std::move(deps));
    REQUIRE(node.start());
    CHECK(node.statusJson().find("active-call") == std::string::npos);
    node.stop();
  }

  for (const char* name : {"doorbell.db", "doorbell.db-wal", "doorbell.db-shm"})
    std::remove((dir + "/" + name).c_str());
  ::rmdir((dir + "/assets").c_str());
  ::rmdir(dir.c_str());
}

TEST_CASE("call recovery uses the durable projection beyond the recent-event window") {
  const std::string dir = contractTempDir();
  {
    Store store;
    REQUIRE(store.open(dir + "/doorbell.db"));
    store.metaSet("node_id", "contractorigin0000000000000000");
    REQUIRE(store.eventPut(lifecycleEvent(
        "press", 1, 1'000,
        R"({"schema_version":2,"call_id":"durable-call","stage_revision":0,"expires_at_ms":61000})")));
    for (uint64_t seq = 2; seq <= 302; ++seq) {
      EventRecord noise = lifecycleEvent("motion", seq, 1'000 + static_cast<int64_t>(seq), "{}");
      REQUIRE(store.eventPut(noise));
    }
    auto projection = store.callProjection("durable-call");
    REQUIRE(projection);
    CHECK(projection->state == "ringing");
  }

  SimClock clock(3'000, 0);
  Runloop loop(clock);
  {
    NodeOptions options = v2NodeOptions();
    options.data_dir = dir;
    options.caps_json = R"({"features":{"runtime_recovery_v1":true}})";
    NodeDeps deps;
    deps.clock = &clock;
    deps.loop = &loop;
    Node node(options, std::move(deps));
    EventSink sink;
    node.setUiEventCb([&](const std::string& event) { sink.push(event); });
    REQUIRE(node.start());
    CHECK(node.statusJson().find("durable-call") != std::string::npos);
    {
      std::lock_guard<std::mutex> lock(sink.mu);
      bool requested = false;
      for (const auto& raw : sink.events) {
        auto event = json::parse(raw);
        if (event && json::getString(event.get(), "t") == "call_recovery_required" &&
            json::getString(event.get(), "call_id") == "durable-call") {
          requested = true;
          CHECK(json::getString(event.get(), "state") == "ringing");
          CHECK(json::getString(event.get(), "origin") ==
                "contractorigin0000000000000000");
          CHECK(json::getInt(event.get(), "stage_revision") == 0);
          CHECK(json::getInt(event.get(), "expires_at_ms") == 61'000);
        }
      }
      CHECK(requested);
    }
    REQUIRE(setContractEventProjectionFailure(dir + "/doorbell.db", true));
    clock.advance(9'999);
    loop.pumpDue();
    CHECK(sink.countEventType("call_cancelled") == 0);
    clock.advance(1);
    loop.pumpDue();
    CHECK(sink.countEventType("call_cancelled") == 0);
    REQUIRE(setContractEventProjectionFailure(dir + "/doorbell.db", false));
    clock.advance(1'999);
    loop.pumpDue();
    CHECK(sink.countEventType("call_cancelled") == 0);
    clock.advance(1);
    loop.pumpDue();
    CHECK(sink.countEventType("call_cancelled") == 1);
    loop.pumpDue();
    CHECK(sink.countEventType("call_cancelled") == 1);
    node.stop();
  }

  {
    Store store;
    REQUIRE(store.open(dir + "/doorbell.db"));
    auto projection = store.callProjection("durable-call");
    REQUIRE(projection);
    CHECK(projection->state == "cancelled");
    CHECK(projection->terminal_reason == "recovery_timeout");
    CHECK(store.countEventsOfType("call_cancelled") == 1);
  }

  {
    NodeOptions options = v2NodeOptions();
    options.data_dir = dir;
    options.caps_json = R"({"features":{"runtime_recovery_v1":true}})";
    NodeDeps deps;
    deps.clock = &clock;
    deps.loop = &loop;
    Node node(options, std::move(deps));
    REQUIRE(node.start());
    CHECK(node.statusJson().find("durable-call") == std::string::npos);
    clock.advance(10'000);
    loop.pumpDue();
    node.stop();
  }

  {
    Store store;
    REQUIRE(store.open(dir + "/doorbell.db"));
    CHECK(store.countEventsOfType("call_cancelled") == 1);
  }
  for (const char* name : {"doorbell.db", "doorbell.db-wal", "doorbell.db-shm"})
    std::remove((dir + "/" + name).c_str());
  ::rmdir((dir + "/assets").c_str());
  ::rmdir(dir.c_str());
}

TEST_CASE("failed recovery report keeps its authority lease until cancellation is durable") {
  const std::string dir = contractTempDir();
  const std::string db_path = dir + "/doorbell.db";
  {
    Store store;
    REQUIRE(store.open(db_path));
    store.metaSet("node_id", "contractorigin0000000000000000");
    REQUIRE(store.eventPut(lifecycleEvent(
        "press", 1, 1'000,
        R"({"schema_version":2,"call_id":"recovery-failure","stage_revision":0,"expires_at_ms":61000})")));
  }

  SimClock clock(3'000, 0);
  Runloop loop(clock);
  NodeOptions options = v2NodeOptions();
  options.data_dir = dir;
  NodeDeps deps;
  deps.clock = &clock;
  deps.loop = &loop;
  Node node(options, std::move(deps));
  EventSink sink;
  node.setUiEventCb([&](const std::string& event) { sink.push(event); });
  REQUIRE(node.start());
  REQUIRE(setContractEventProjectionFailure(db_path, true));
  node.reportCallRecovery("recovery-failure", false);
  loop.pumpDue();
  CHECK(sink.countEventType("call_cancelled") == 0);

  REQUIRE(setContractEventProjectionFailure(db_path, false));
  clock.advance(1'999);
  loop.pumpDue();
  CHECK(sink.countEventType("call_cancelled") == 0);
  clock.advance(1);
  loop.pumpDue();
  CHECK(sink.countEventType("call_cancelled") == 1);
  node.stop();

  {
    Store store;
    REQUIRE(store.open(db_path));
    auto projection = store.callProjection("recovery-failure");
    REQUIRE(projection);
    CHECK(projection->state == "cancelled");
    CHECK(projection->terminal_reason == "recovery_failed");
    CHECK(store.countEventsOfType("call_cancelled") == 1);
  }
  removeContractDir(dir);
}

TEST_CASE("call projection isolates concurrent calls and rejects visitor cancellation in call") {
  Store store;
  REQUIRE(store.open(":memory:"));

  REQUIRE(store.eventPut(lifecycleEvent(
      "press", 1, 1'000,
      R"({"schema_version":2,"call_id":"established","expires_at_ms":61000})")));
  REQUIRE(store.eventPut(lifecycleEvent(
      "call_answered", 2, 2'000,
      R"({"schema_version":2,"call_id":"established"})")));

  EventRecord other_press = lifecycleEvent(
      "press", 3, 3'000,
      R"({"schema_version":2,"call_id":"other","expires_at_ms":63000})");
  other_press.door = "d_side";
  REQUIRE(store.eventPut(other_press));
  EventRecord other_cancel = lifecycleEvent(
      "call_cancelled", 4, 4'000,
      R"({"schema_version":2,"call_id":"other","reason":"visitor"})");
  other_cancel.door = "d_side";
  REQUIRE(store.eventPut(other_cancel));

  REQUIRE(store.eventPut(lifecycleEvent(
      "call_cancelled", 5, 5'000,
      R"({"schema_version":2,"call_id":"established","reason":"visitor"})")));
  auto established = store.callProjection("established");
  REQUIRE(established);
  CHECK(established->state == "in_call");
  auto other = store.callProjection("other");
  REQUIRE(other);
  CHECK(other->state == "cancelled");

  REQUIRE(store.eventPut(lifecycleEvent(
      "call_cancelled", 6, 6'000,
      R"({"schema_version":2,"call_id":"established","reason":"recovery_failed"})")));
  established = store.callProjection("established");
  REQUIRE(established);
  CHECK(established->state == "cancelled");
  CHECK(established->terminal_reason == "recovery_failed");
}
