// Call history (WP-H core): the call_projection schema v7 backfill, outcome derivation, the
// device-local seen watermark, the HTTP surface, call_log_changed delivery, the call_missed rule
// trigger with its seeded default rule, and the event retention policy.

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <map>
#include <mutex>
#include <random>
#include <string>
#include <thread>
#include <vector>

#include <sqlite3.h>

#include "doctest.h"
#include "events/events.h"
#include "node/node.h"
#include "store/store.h"
#include "util/hlc.h"
#include "util/json.h"

using namespace db;

namespace {

std::string logTempDir() {
  char path[] = "/tmp/doorbell_call_log_XXXXXX";
  char* created = mkdtemp(path);
  REQUIRE(created != nullptr);
  return created;
}

void removeLogTempDir(const std::string& dir) {
  for (const char* name : {"doorbell.db", "doorbell.db-wal", "doorbell.db-shm"})
    std::remove((dir + "/" + name).c_str());
  ::rmdir((dir + "/assets").c_str());
  ::rmdir(dir.c_str());
}

bool logExecSql(const std::string& path, const char* sql) {
  sqlite3* db = nullptr;
  if (sqlite3_open(path.c_str(), &db) != SQLITE_OK) {
    if (db) sqlite3_close(db);
    return false;
  }
  const bool ok = sqlite3_exec(db, sql, nullptr, nullptr, nullptr) == SQLITE_OK;
  sqlite3_close(db);
  return ok;
}

// A deterministic lifecycle event. Sequences are contiguous per origin so the store advances its
// applied frontier and materializes the projection.
EventRecord logEvent(uint64_t seq, int64_t ms, const std::string& type, const std::string& door,
                     const std::string& payload, const std::string& device = "aaaaaaaa",
                     const std::string& origin = "aaaaaaaa") {
  EventRecord e;
  e.origin = origin;
  e.seq = seq;
  e.type = type;
  e.door = door;
  e.device = device;
  e.hlc = HlcClock::format(ms, 0, origin.substr(0, 8));
  e.wall_ms = ms;
  e.payload_json = payload;
  return e;
}

std::string pressPayload(const std::string& call_id, const std::string& purpose = "",
                         const std::string& lang = "") {
  std::string out = R"({"schema_version":2,"call_id":")" + call_id + R"(","stage_revision":0)";
  if (!purpose.empty()) out += R"(,"purpose":")" + purpose + "\"";
  if (!lang.empty()) out += R"(,"visitor_lang":")" + lang + "\"";
  return out + "}";
}

std::string scopedPayload(const std::string& call_id, const std::string& extra = "") {
  return R"({"schema_version":2,"call_id":")" + call_id + R"(","stage_revision":0)" + extra + "}";
}

const Store::CallLogRow* findRow(const std::vector<Store::CallLogRow>& rows,
                                 const std::string& call_id) {
  for (const auto& row : rows)
    if (row.call_id == call_id) return &row;
  return nullptr;
}

// One store carrying every terminal shape the projection can produce.
void seedOutcomeFixture(Store& store) {
  // answered: press → answer → end
  REQUIRE(store.eventPut(logEvent(1, 1000, "press", "d_front", pressPayload("c_answered",
                                                                           "p_delivery", "en"))));
  REQUIRE(store.eventPut(logEvent(2, 1500, "call_answered", "d_front",
                                  scopedPayload("c_answered"), "panel-a")));
  REQUIRE(store.eventPut(logEvent(3, 4500, "call_ended", "d_front",
                                  scopedPayload("c_answered", R"(,"reason":"sip_ended")"),
                                  "panel-a")));
  // replied: press → quick reply
  REQUIRE(store.eventPut(logEvent(4, 5000, "press", "d_back", pressPayload("c_replied"))));
  REQUIRE(store.eventPut(logEvent(
      5, 5500, "reply", "d_back",
      R"({"schema_version":2,"reply_id":"qr_away","call_id":"c_replied","stage_revision":0,)"
      R"("call_origin":"aaaaaaaa"})")));
  // missed: press → ring timeout
  REQUIRE(store.eventPut(logEvent(6, 6000, "press", "d_front", pressPayload("c_timeout"))));
  REQUIRE(store.eventPut(logEvent(7, 6500, "call_cancelled", "d_front",
                                  scopedPayload("c_timeout", R"(,"reason":"timeout")"))));
  // missed: press → restart recovery failed
  REQUIRE(store.eventPut(logEvent(8, 7000, "press", "d_back", pressPayload("c_recovery"))));
  REQUIRE(store.eventPut(logEvent(9, 7500, "call_cancelled", "d_back",
                                  scopedPayload("c_recovery",
                                                R"(,"reason":"recovery_failed")"))));
  // cancelled: the visitor walked away
  REQUIRE(store.eventPut(logEvent(10, 8000, "press", "d_side", pressPayload("c_visitor"))));
  REQUIRE(store.eventPut(logEvent(11, 8500, "call_cancelled", "d_side",
                                  scopedPayload("c_visitor", R"(,"reason":"visitor")"))));
  // concurrency loser: a second press on the same door is superseded by the lower call id
  REQUIRE(store.eventPut(logEvent(12, 9000, "press", "d_gate", pressPayload("c_zloser"))));
  REQUIRE(store.eventPut(logEvent(13, 9100, "press", "d_gate", pressPayload("c_awinner"))));
  // live: still ringing, never in the history
  REQUIRE(store.eventPut(logEvent(14, 9500, "press", "d_live", pressPayload("c_live"))));
}

int callLogFreePort(std::mt19937& rng) {
  std::uniform_int_distribution<int> dist(40000, 60000);
  for (int i = 0; i < 50; i++) {
    const int port = dist(rng);
    const int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) continue;
    sockaddr_in sa{};
    sa.sin_family = AF_INET;
    sa.sin_port = htons(static_cast<uint16_t>(port));
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    const int ok = ::bind(fd, reinterpret_cast<sockaddr*>(&sa), sizeof(sa));
    ::close(fd);
    if (ok == 0) return port;
  }
  return -1;
}

std::string callLogReq(int port, const std::string& method, const std::string& path,
                       const std::string& body = "", const std::string& cookie = "") {
  const int fd = ::socket(AF_INET, SOCK_STREAM, 0);
  REQUIRE(fd >= 0);
  sockaddr_in sa{};
  sa.sin_family = AF_INET;
  sa.sin_port = htons(static_cast<uint16_t>(port));
  sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  REQUIRE(::connect(fd, reinterpret_cast<sockaddr*>(&sa), sizeof(sa)) == 0);
  std::string r = method + " " + path + " HTTP/1.1\r\nHost: 127.0.0.1\r\n";
  if (!cookie.empty()) r += "Cookie: " + cookie + "\r\n";
  if (!body.empty())
    r += "Content-Type: application/json\r\nContent-Length: " + std::to_string(body.size()) +
         "\r\n";
  r += "Connection: close\r\n\r\n" + body;
  REQUIRE(::send(fd, r.data(), r.size(), 0) == static_cast<ssize_t>(r.size()));
  std::string resp;
  char buf[8192];
  timeval tv{5, 0};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  for (;;) {
    const ssize_t n = ::recv(fd, buf, sizeof(buf), 0);
    if (n <= 0) break;
    resp.append(buf, static_cast<size_t>(n));
  }
  ::close(fd);
  return resp;
}

json::Doc callLogBody(const std::string& resp) {
  const size_t p = resp.find("\r\n\r\n");
  return json::parse(p == std::string::npos ? "" : resp.substr(p + 4));
}

std::string callLogAdminLogin(int port) {
  const std::string r = callLogReq(port, "POST", "/api/login", R"({"password":"historypw"})");
  REQUIRE(r.find("HTTP/1.1 200") == 0);
  const size_t p = r.find("dbsess=");
  REQUIRE(p != std::string::npos);
  return "dbsess=" + r.substr(p + 7, r.find(';', p) - (p + 7));
}

std::string callLogPanelLogin(int port, const std::string& credential) {
  const std::string r = callLogReq(port, "POST", "/api/panel/session",
                                   "{\"credential\":\"" + credential + "\"}");
  REQUIRE(r.find("HTTP/1.1 200") == 0);
  const size_t p = r.find("dbpanel=");
  REQUIRE(p != std::string::npos);
  return "dbpanel=" + r.substr(p + 8, r.find(';', p) - (p + 8));
}

MeshSettings callLogTiming() {
  MeshSettings m;
  m.heartbeat_ms = 100;
  m.suspect_ms = 300;
  m.dead_ms = 500;
  m.gossip_ms = 200;
  m.sync_ms = 200;
  m.claim_ttl_ms = 450;
  m.reconnect_ms = 200;
  return m;
}

struct CallLogNode {
  std::string dir;
  int http_port = 0;
  std::unique_ptr<Node> node;
  std::mutex mu;
  std::vector<std::string> ui_events;
  std::mutex secure_mu;
  std::map<std::string, std::string> secure_values;

  explicit CallLogNode(uint32_t salt, const std::string& role = "indoor_panel") {
    std::mt19937 rng(static_cast<uint32_t>(::getpid()) ^ salt);
    const int mesh_port = callLogFreePort(rng);
    http_port = callLogFreePort(rng);
    REQUIRE(mesh_port > 0);
    REQUIRE(http_port > 0);
    dir = logTempDir();
    NodeOptions options;
    options.data_dir = dir;
    options.name = "call-history";
    options.role = role;
    if (role == "door_station") options.door = "d_front";
    options.listen_addr = "127.0.0.1:" + std::to_string(mesh_port);
    options.psk.fill(static_cast<uint8_t>(salt));
    options.enable_beacon = false;
    options.http_port = http_port;
    options.mesh_timing_template = callLogTiming();
    options.use_mesh_timing_template = true;
    node.reset(new Node(options));
    node->setUiEventCb([this](const std::string& event_json) {
      std::lock_guard<std::mutex> lk(mu);
      ui_events.push_back(event_json);
    });
    // Both roles declare the alert capability so a suppressed alert can only come from rule
    // targeting, never from a missing shell feature.
    node->setRuntimeCapabilities(R"({"features":{"device_alert_v1":true}})");
    node->setSecureStore(
        [this](const std::string& key) {
          std::lock_guard<std::mutex> lk(secure_mu);
          auto it = secure_values.find(key);
          return it == secure_values.end() ? std::string() : it->second;
        },
        [this](const std::string& key, const std::string& value) {
          std::lock_guard<std::mutex> lk(secure_mu);
          if (value.empty()) secure_values.erase(key);
          else secure_values[key] = value;
          return true;
        });
    REQUIRE(node->start());
  }

  ~CallLogNode() {
    if (node) node->stop();
    node.reset();
    removeLogTempDir(dir);
  }

  std::vector<std::string> drain() {
    std::lock_guard<std::mutex> lk(mu);
    std::vector<std::string> out = ui_events;
    ui_events.clear();
    return out;
  }

  // The UI callback runs on the runloop, so a lifecycle write and its notification are not
  // observable in the same instant.
  bool waitFor(const std::string& needle, int attempts = 100) {
    for (int i = 0; i < attempts; i++) {
      {
        std::lock_guard<std::mutex> lk(mu);
        for (const auto& event : ui_events)
          if (event.find(needle) != std::string::npos) return true;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    return false;
  }
};

}  // namespace

TEST_CASE("call log: outcome derivation covers every terminal combination") {
  Store store;
  REQUIRE(store.open(":memory:"));
  seedOutcomeFixture(store);

  Store::CallLogQuery query;
  query.limit = 50;
  const auto rows = store.callLog(query);

  REQUIRE(findRow(rows, "c_answered"));
  CHECK(findRow(rows, "c_answered")->outcome == "answered");
  REQUIRE(findRow(rows, "c_replied"));
  CHECK(findRow(rows, "c_replied")->outcome == "replied");
  REQUIRE(findRow(rows, "c_timeout"));
  CHECK(findRow(rows, "c_timeout")->outcome == "missed");
  REQUIRE(findRow(rows, "c_recovery"));
  CHECK(findRow(rows, "c_recovery")->outcome == "missed");
  REQUIRE(findRow(rows, "c_visitor"));
  CHECK(findRow(rows, "c_visitor")->outcome == "cancelled");

  // A concurrent-press loser and a call that is still ringing are not history.
  CHECK(findRow(rows, "c_zloser") == nullptr);
  CHECK(findRow(rows, "c_live") == nullptr);
  const auto loser = store.callProjection("c_zloser");
  REQUIRE(loser);
  CHECK(loser->terminal_reason == "concurrent_press_loser");
  const auto live = store.callProjection("c_live");
  REQUIRE(live);
  CHECK(live->state == "ringing");

  // Newest first.
  REQUIRE(rows.size() == 5);
  CHECK(rows.front().call_id == "c_visitor");
  CHECK(rows.back().call_id == "c_answered");
}

TEST_CASE("call log: a recovery timeout is a missed call, not a visitor cancellation") {
  Store store;
  REQUIRE(store.open(":memory:"));
  REQUIRE(store.eventPut(logEvent(1, 1000, "press", "d_front", pressPayload("c_rt"))));
  REQUIRE(store.eventPut(logEvent(2, 1500, "call_cancelled", "d_front",
                                  scopedPayload("c_rt", R"(,"reason":"recovery_timeout")"))));
  Store::CallLogQuery query;
  const auto rows = store.callLog(query);
  REQUIRE(rows.size() == 1);
  CHECK(rows[0].outcome == "missed");
  CHECK(store.unreadMissedCount() == 1);
}

TEST_CASE("call log: rows carry identity, timestamps, duration and visitor language") {
  Store store;
  REQUIRE(store.open(":memory:"));
  seedOutcomeFixture(store);
  Store::CallLogQuery query;
  const auto rows = store.callLog(query);
  const Store::CallLogRow* answered = findRow(rows, "c_answered");
  REQUIRE(answered);
  // The row identity is the originating press event, not the random call id.
  CHECK(answered->id == "aaaaaaaa:1");
  CHECK(answered->ts == 1000);
  CHECK(answered->door == "d_front");
  CHECK(answered->purpose == "p_delivery");
  CHECK(answered->visitor_lang == "en");
  CHECK(answered->answered_by == "panel-a");
  CHECK(answered->duration_ms == 3000);
  CHECK(answered->snapshot.empty());
  CHECK_FALSE(answered->updated_hlc.empty());

  // Nobody answered a missed call, so it has neither an owner nor a duration.
  const Store::CallLogRow* missed = findRow(rows, "c_timeout");
  REQUIRE(missed);
  CHECK(missed->answered_by.empty());
  CHECK(missed->duration_ms == 0);
  CHECK(missed->ts == 6000);
}

TEST_CASE("call log: since_ms, before_ms, door and outcome page the history") {
  Store store;
  REQUIRE(store.open(":memory:"));
  seedOutcomeFixture(store);

  Store::CallLogQuery all;
  CHECK(store.callLog(all).size() == 5);

  Store::CallLogQuery newest;
  newest.limit = 2;
  const auto page = store.callLog(newest);
  REQUIRE(page.size() == 2);
  CHECK(page[0].call_id == "c_visitor");
  CHECK(page[1].call_id == "c_recovery");

  // Paging older uses the oldest timestamp already shown as an exclusive upper bound.
  Store::CallLogQuery older;
  older.before_ms = page.back().ts;
  older.limit = 2;
  const auto second = store.callLog(older);
  REQUIRE(second.size() == 2);
  CHECK(second[0].call_id == "c_timeout");
  CHECK(second[1].call_id == "c_replied");

  Store::CallLogQuery since;
  since.since_ms = 6000;
  const auto recent = store.callLog(since);
  REQUIRE(recent.size() == 3);
  CHECK(findRow(recent, "c_answered") == nullptr);

  Store::CallLogQuery by_door;
  by_door.door = "d_back";
  const auto back = store.callLog(by_door);
  REQUIRE(back.size() == 2);
  for (const auto& row : back) CHECK(row.door == "d_back");

  Store::CallLogQuery by_outcome;
  by_outcome.outcome = "missed";
  const auto missed = store.callLog(by_outcome);
  REQUIRE(missed.size() == 2);
  for (const auto& row : missed) CHECK(row.outcome == "missed");

  Store::CallLogQuery empty_page;
  empty_page.limit = 0;
  CHECK(store.callLog(empty_page).empty());
}

TEST_CASE("call log: the seen watermark is local, monotonic and drives unread_missed") {
  Store store;
  REQUIRE(store.open(":memory:"));
  seedOutcomeFixture(store);
  CHECK(store.callLogSeenHlc().empty());
  CHECK(store.unreadMissedCount() == 2);
  for (const auto& row : store.callLog({})) CHECK_FALSE(row.seen);

  // Marking one missed call seen leaves the newer one unread.
  const auto rows = store.callLog({});
  const Store::CallLogRow* older_missed = findRow(rows, "c_timeout");
  REQUIRE(older_missed);
  REQUIRE(store.callLogMarkSeen(older_missed->updated_hlc));
  CHECK(store.unreadMissedCount() == 1);
  CHECK(findRow(store.callLog({}), "c_timeout")->seen);
  CHECK_FALSE(findRow(store.callLog({}), "c_recovery")->seen);

  // The watermark never moves backwards, so a stale client cannot resurrect the badge.
  const std::string watermark = store.callLogSeenHlc();
  REQUIRE(store.callLogMarkSeen(HlcClock::format(1, 0, "aaaaaaaa")));
  CHECK(store.callLogSeenHlc() == watermark);
  CHECK(store.unreadMissedCount() == 1);

  // An empty argument marks everything currently known as seen.
  REQUIRE(store.callLogMarkSeen(""));
  CHECK(store.unreadMissedCount() == 0);
  for (const auto& row : store.callLog({})) CHECK(row.seen);

  // A later missed call raises the badge again.
  REQUIRE(store.eventPut(logEvent(15, 12000, "press", "d_front", pressPayload("c_new"))));
  REQUIRE(store.eventPut(logEvent(16, 12500, "call_cancelled", "d_front",
                                  scopedPayload("c_new", R"(,"reason":"timeout")"))));
  CHECK(store.unreadMissedCount() == 1);
}

TEST_CASE("call log: the watermark survives a restart and never replicates") {
  const std::string dir = logTempDir();
  const std::string path = dir + "/db.sqlite";
  {
    Store store;
    REQUIRE(store.open(path));
    seedOutcomeFixture(store);
    REQUIRE(store.callLogMarkSeen(""));
    CHECK(store.unreadMissedCount() == 0);
  }
  {
    Store store;
    REQUIRE(store.open(path));
    CHECK(store.unreadMissedCount() == 0);
    CHECK_FALSE(store.callLogSeenHlc().empty());
    CHECK(store.callLog({}).size() == 5);
  }
  // A second device replays the same events and starts with every missed call unread.
  Store fresh;
  REQUIRE(fresh.open(":memory:"));
  seedOutcomeFixture(fresh);
  CHECK(fresh.unreadMissedCount() == 2);
  removeLogTempDir(dir);
}

TEST_CASE("call log: a schema v6 database is migrated and backfilled by replay") {
  const std::string dir = logTempDir();
  const std::string path = dir + "/db.sqlite";
  {
    Store store;
    REQUIRE(store.open(path));
    seedOutcomeFixture(store);
    CHECK(store.metaGet("schema_version") == std::string("7"));
  }
  // Rebuild the projection with the schema v6 column set, drop one row entirely, and roll the
  // recorded version back. The upgrade must recreate every column and every row from the events.
  REQUIRE(logExecSql(
      path,
      "BEGIN;"
      "ALTER TABLE call_projection RENAME TO call_projection_v6;"
      "CREATE TABLE call_projection("
      "  call_id TEXT PRIMARY KEY, door TEXT NOT NULL, origin TEXT NOT NULL, purpose TEXT,"
      "  state TEXT NOT NULL, stage_revision INT NOT NULL, expires_wall_ms INT NOT NULL,"
      "  updated_hlc TEXT NOT NULL, terminal_reason TEXT,"
      "  dialog_owner TEXT NOT NULL DEFAULT '', answered_hlc TEXT NOT NULL DEFAULT '');"
      "INSERT INTO call_projection SELECT call_id,door,origin,purpose,state,stage_revision,"
      " expires_wall_ms,updated_hlc,terminal_reason,dialog_owner,answered_hlc"
      " FROM call_projection_v6;"
      "DROP TABLE call_projection_v6;"
      "DELETE FROM call_projection WHERE call_id='c_answered';"
      "UPDATE meta SET value='6' WHERE key='schema_version';"
      "COMMIT;"));

  Store upgraded;
  REQUIRE(upgraded.open(path));
  CHECK(upgraded.metaGet("schema_version") == std::string("7"));
  const auto rows = upgraded.callLog({});
  REQUIRE(rows.size() == 5);
  const Store::CallLogRow* answered = findRow(rows, "c_answered");
  REQUIRE(answered);
  CHECK(answered->outcome == "answered");
  CHECK(answered->id == "aaaaaaaa:1");
  CHECK(answered->ts == 1000);
  CHECK(answered->duration_ms == 3000);
  CHECK(answered->visitor_lang == "en");
  // The door fence is rebuilt by the same replay, so a concurrency loser stays a loser.
  const auto loser = upgraded.callProjection("c_zloser");
  REQUIRE(loser);
  CHECK(loser->terminal_reason == "concurrent_press_loser");
  removeLogTempDir(dir);
}

TEST_CASE("store: retention prunes only what replication coverage proves") {
  const std::string dir = logTempDir();
  const std::string path = dir + "/db.sqlite";
  Store store;
  REQUIRE(store.open(path));
  for (uint64_t i = 1; i <= 10; i++) {
    EventRecord e = logEvent(i, static_cast<int64_t>(1000 * i), "motion", "d_front", "{}");
    REQUIRE(store.eventPut(e));
  }
  for (uint64_t i = 1; i <= 10; i++) REQUIRE(store.eventAckDispatched("aaaaaaaa", i));

  // No coverage snapshot: pruning still fails closed.
  CHECK(store.pruneEvents(5, 6000) == 0);
  CHECK(store.eventsSince({}, 100).size() == 10);

  // Coverage that only reaches sequence three bounds the sweep at three.
  REQUIRE(store.eventCoverageSet({{"aaaaaaaa", 3}}));
  CHECK(store.eventCoverage().at("aaaaaaaa") == 3);
  CHECK(store.pruneEvents(5, 6000) == 3);
  CHECK(store.eventsSince({}, 100).size() == 7);

  // Full coverage, but the age cutoff still protects everything at or after it.
  REQUIRE(store.eventCoverageSet({{"aaaaaaaa", 10}}));
  CHECK(store.pruneEvents(0, 5001) == 2);
  auto remaining = store.eventsSince({}, 100);
  REQUIRE(remaining.size() == 5);
  CHECK(remaining.front().wall_ms == 6000);

  // The newest max_events per origin survive whatever the cutoff says.
  CHECK(store.pruneEvents(5, 20000) == 0);
  CHECK(store.eventsSince({}, 100).size() == 5);
  CHECK(store.pruneEvents(2, 20000) == 3);
  remaining = store.eventsSince({}, 100);
  REQUIRE(remaining.size() == 2);
  CHECK(remaining.front().wall_ms == 9000);
  CHECK(remaining.back().wall_ms == 10000);
  // Pruning old records never rewinds the advertised head.
  CHECK(store.eventFrontier("aaaaaaaa") == 10);
  CHECK(store.eventMaxSeq("aaaaaaaa") == 10);
  removeLogTempDir(dir);
}

TEST_CASE("store: retention never deletes an undispatched event") {
  Store store;
  REQUIRE(store.open(":memory:"));
  for (uint64_t i = 1; i <= 4; i++)
    REQUIRE(store.eventPut(logEvent(i, static_cast<int64_t>(1000 * i), "motion", "d_front", "{}")));
  REQUIRE(store.eventCoverageSet({{"aaaaaaaa", 4}}));
  // dispatch_frontier is still zero: the shell has not seen these events yet.
  CHECK(store.pruneEvents(0, 5000) == 0);
  REQUIRE(store.eventAckDispatched("aaaaaaaa", 1));
  REQUIRE(store.eventAckDispatched("aaaaaaaa", 2));
  CHECK(store.pruneEvents(0, 5000) == 2);
  CHECK(store.eventsSince({}, 100).size() == 2);
}

TEST_CASE("rules: call_missed matches only timeout and recovery cancellations") {
  RuleEngine engine;
  engine.setConfig(R"({"trigger_rules":{
    "r_missed":{"enabled":true,"when":{"type":"call_missed"},
                "actions":[{"type":"device_alert","channels":["in_app"]}]},
    "r_any_cancel":{"enabled":true,"when":{"type":"call_cancelled"},
                    "actions":[{"type":"telegram"}]}}})");

  auto evaluate = [&](const std::string& reason) {
    EventRecord ev = logEvent(1, 1000, "call_cancelled", "d_front",
                              scopedPayload("c1", R"(,"reason":")" + reason + "\""));
    return engine.evaluate(ev, 1000, 540);
  };

  const auto timeout_actions = evaluate("timeout");
  REQUIRE(timeout_actions.size() == 2);
  // A missed cancellation keeps matching plain call_cancelled rules; nothing regresses.
  CHECK(timeout_actions[0].type == "telegram");
  CHECK(timeout_actions[1].type == "device_alert");

  for (const char* reason : {"recovery_failed", "recovery_timeout"})
    CHECK(evaluate(reason).size() == 2);

  const auto visitor_actions = evaluate("visitor");
  REQUIRE(visitor_actions.size() == 1);
  CHECK(visitor_actions[0].type == "telegram");

  // A completed call never matches the missed trigger.
  EventRecord ended = logEvent(2, 2000, "call_ended", "d_front",
                               scopedPayload("c1", R"(,"reason":"sip_ended")"));
  CHECK(engine.evaluate(ended, 2000, 540).empty());
}

TEST_CASE("call log API: the seeded missed-call rule alerts indoor roles only") {
  CallLogNode indoor(0xc10a);
  auto config = json::parse(indoor.node->configJson());
  REQUIRE(config);
  const cJSON* rule = json::get(json::get(config.get(), "trigger_rules"),
                                "r_missed_call_default");
  REQUIRE(rule != nullptr);
  CHECK(json::getBool(rule, "enabled", false));
  CHECK(json::getString(json::get(rule, "when"), "type") == "call_missed");
  const cJSON* action = cJSON_GetArrayItem(json::get(rule, "actions"), 0);
  REQUIRE(action != nullptr);
  CHECK(json::getString(action, "type") == "device_alert");
  const cJSON* roles = json::get(json::get(action, "targets"), "roles");
  REQUIRE(cJSON_IsArray(roles));
  REQUIRE(cJSON_GetArraySize(roles) == 1);
  CHECK(std::string(cJSON_GetArrayItem(roles, 0)->valuestring) == "indoor_panel");

  const std::string call_id = indoor.node->pressV2("d_front", "");
  REQUIRE_FALSE(call_id.empty());
  REQUIRE(indoor.node->cancelCallV2("d_front", call_id, "timeout"));
  REQUIRE(indoor.waitFor("\"kind\":\"call_missed\""));
  REQUIRE(indoor.waitFor("\"t\":\"call_log_changed\""));

  bool alerted = false;
  for (const auto& event : indoor.drain()) {
    auto parsed = json::parse(event);
    if (!parsed || json::getString(parsed.get(), "t") != "device_alert") continue;
    alerted = true;
    CHECK(json::getString(parsed.get(), "kind") == "call_missed");
    CHECK(json::getString(parsed.get(), "door") == "d_front");
    CHECK(json::getString(parsed.get(), "call_id") == call_id);
    CHECK(json::getString(parsed.get(), "reason") == "timeout");
    CHECK(json::getInt(parsed.get(), "unread_missed") == 1);
  }
  CHECK(alerted);
}

TEST_CASE("call log API: a door station never raises a missed-call alert") {
  CallLogNode door(0xd006, "door_station");
  const std::string call_id = door.node->pressV2("d_front", "");
  REQUIRE_FALSE(call_id.empty());
  REQUIRE(door.node->cancelCallV2("d_front", call_id, "timeout"));
  REQUIRE(door.waitFor("\"t\":\"call_log_changed\""));
  for (const auto& event : door.drain()) {
    auto parsed = json::parse(event);
    if (!parsed) continue;
    CHECK(json::getString(parsed.get(), "kind") != "call_missed");
  }
  // The history itself is still recorded on the door station; only the alert is suppressed.
  auto log = json::parse(door.node->callLogJson(0, 10));
  REQUIRE(log);
  CHECK(json::getInt(log.get(), "unread_missed") == 1);
}

TEST_CASE("call log API: panel credential and admin session read the same history") {
  CallLogNode panel(0x9a71);
  const int port = panel.http_port;

  CHECK(callLogReq(port, "GET", "/api/call-log").find("HTTP/1.1 403") == 0);
  CHECK(callLogReq(port, "POST", "/api/call-log/seen", "{}").find("HTTP/1.1 403") == 0);

  const std::string admin = callLogAdminLogin(port);
  auto rotation = callLogBody(
      callLogReq(port, "POST", "/api/panel-token/rotate", "{}", admin));
  REQUIRE(rotation);
  const std::string credential = json::getString(rotation.get(), "token");
  REQUIRE(credential.size() == 32);
  const std::string panel_cookie = callLogPanelLogin(port, credential);

  const std::string answered = panel.node->pressV2("d_front", "p_delivery");
  REQUIRE_FALSE(answered.empty());
  REQUIRE(panel.node->reportCallAnsweredV2("d_front", answered, 0));
  REQUIRE(panel.node->reportCallEndedV2("d_front", answered, 0, "sip_ended"));
  const std::string missed = panel.node->pressV2("d_front", "");
  REQUIRE_FALSE(missed.empty());
  REQUIRE(panel.node->cancelCallV2("d_front", missed, "timeout"));

  auto by_panel = callLogBody(callLogReq(port, "GET", "/api/call-log", "", panel_cookie));
  REQUIRE(by_panel);
  cJSON* rows = json::get(by_panel.get(), "rows");
  REQUIRE(cJSON_IsArray(rows));
  REQUIRE(cJSON_GetArraySize(rows) == 2);
  CHECK(json::getString(cJSON_GetArrayItem(rows, 0), "outcome") == "missed");
  CHECK(json::getString(cJSON_GetArrayItem(rows, 1), "outcome") == "answered");
  CHECK(json::getString(cJSON_GetArrayItem(rows, 1), "purpose") == "p_delivery");
  CHECK(json::getInt(by_panel.get(), "unread_missed") == 1);
  CHECK(json::getInt(by_panel.get(), "server_ts") > 0);

  const std::string by_admin = callLogReq(port, "GET", "/api/call-log", "", admin);
  CHECK(by_admin.find("HTTP/1.1 200") == 0);
  CHECK(by_admin.find("\"unread_missed\":1") != std::string::npos);

  // Filters reach the same query the C ABI uses.
  auto only_missed = callLogBody(
      callLogReq(port, "GET", "/api/call-log?outcome=missed&limit=10", "", panel_cookie));
  REQUIRE(only_missed);
  CHECK(cJSON_GetArraySize(json::get(only_missed.get(), "rows")) == 1);
  auto other_door = callLogBody(
      callLogReq(port, "GET", "/api/call-log?door=d_back", "", panel_cookie));
  REQUIRE(other_door);
  CHECK(cJSON_GetArraySize(json::get(other_door.get(), "rows")) == 0);
}

TEST_CASE("call log API: mark-seen clears the badge and republishes the count") {
  CallLogNode panel(0x5ee4);
  const int port = panel.http_port;
  const std::string admin = callLogAdminLogin(port);

  const std::string missed = panel.node->pressV2("d_front", "");
  REQUIRE_FALSE(missed.empty());
  REQUIRE(panel.node->cancelCallV2("d_front", missed, "timeout"));
  REQUIRE(panel.waitFor("\"t\":\"call_log_changed\""));
  panel.drain();

  auto before = json::parse(panel.node->callLogJson(0, 10));
  REQUIRE(before);
  CHECK(json::getInt(before.get(), "unread_missed") == 1);

  auto seen = callLogBody(callLogReq(port, "POST", "/api/call-log/seen", "{}", admin));
  REQUIRE(seen);
  CHECK(json::getBool(seen.get(), "ok", false));
  CHECK(json::getInt(seen.get(), "unread_missed") == 0);
  CHECK_FALSE(json::getString(seen.get(), "seen_hlc").empty());
  REQUIRE(panel.waitFor("\"unread_missed\":0"));

  auto after = json::parse(panel.node->callLogJson(0, 10));
  REQUIRE(after);
  CHECK(json::getInt(after.get(), "unread_missed") == 0);
  cJSON* rows = json::get(after.get(), "rows");
  REQUIRE(cJSON_GetArraySize(rows) == 1);
  CHECK(json::getBool(cJSON_GetArrayItem(rows, 0), "seen", false));

  // The C ABI wrapper shares the watermark and is idempotent.
  CHECK(panel.node->markCallLogSeen(""));
  CHECK(json::getInt(json::parse(panel.node->callLogJson(0, 10)).get(), "unread_missed") == 0);
}

TEST_CASE("events API: since_ms, type and door cursor the stream with replication identity") {
  CallLogNode panel(0xe7e5);
  const int port = panel.http_port;
  const std::string admin = callLogAdminLogin(port);

  const std::string first = panel.node->pressV2("d_front", "");
  REQUIRE_FALSE(first.empty());
  REQUIRE(panel.node->cancelCallV2("d_front", first, "visitor"));

  auto all = callLogBody(callLogReq(port, "GET", "/api/events?limit=50", "", admin));
  REQUIRE(all);
  cJSON* events = json::get(all.get(), "events");
  REQUIRE(cJSON_IsArray(events));
  REQUIRE(cJSON_GetArraySize(events) > 0);
  const cJSON* newest = cJSON_GetArrayItem(events, 0);
  CHECK_FALSE(json::getString(newest, "origin").empty());
  CHECK(json::getInt(newest, "seq") > 0);
  CHECK_FALSE(json::getString(newest, "hlc").empty());
  const int64_t cursor = json::getInt(all.get(), "server_ts");
  CHECK(cursor > 0);

  auto presses = callLogBody(
      callLogReq(port, "GET", "/api/events?type=press&limit=50", "", admin));
  REQUIRE(presses);
  cJSON* press_rows = json::get(presses.get(), "events");
  REQUIRE(cJSON_GetArraySize(press_rows) == 1);
  CHECK(json::getString(cJSON_GetArrayItem(press_rows, 0), "type") == "press");

  auto other_door = callLogBody(
      callLogReq(port, "GET", "/api/events?door=d_back&limit=50", "", admin));
  REQUIRE(other_door);
  CHECK(cJSON_GetArraySize(json::get(other_door.get(), "events")) == 0);

  // Nothing is newer than the cursor yet; a new press then shows up alone.
  auto empty = callLogBody(callLogReq(
      port, "GET", "/api/events?type=press&since_ms=" + std::to_string(cursor + 1), "", admin));
  REQUIRE(empty);
  CHECK(cJSON_GetArraySize(json::get(empty.get(), "events")) == 0);

  // Advance the wall clock past the cursor so the next press is unambiguously newer.
  std::this_thread::sleep_for(std::chrono::milliseconds(5));
  const std::string second = panel.node->pressV2("d_front", "");
  REQUIRE_FALSE(second.empty());
  auto tail = callLogBody(callLogReq(
      port, "GET", "/api/events?type=press&since_ms=" + std::to_string(cursor + 1), "", admin));
  REQUIRE(tail);
  REQUIRE(cJSON_GetArraySize(json::get(tail.get(), "events")) == 1);
}

TEST_CASE("config: events.retention_days rejects values outside the supported range") {
  CallLogNode panel(0x4e70);
  const int port = panel.http_port;
  const std::string admin = callLogAdminLogin(port);

  // /api/config carries the value as JSON text inside a JSON string.
  auto write = [&](const std::string& value) {
    return callLogReq(port, "POST", "/api/config",
                      "{\"key\":\"events.retention_days\",\"value\":\"" + value + "\"}",
                      admin);
  };
  CHECK(write("30").find("\"ok\":true") != std::string::npos);
  CHECK(write("0").find("\"ok\":true") == std::string::npos);
  CHECK(write("4000").find("\"ok\":true") == std::string::npos);
  CHECK(write("7.5").find("\"ok\":true") == std::string::npos);
  CHECK(write("ninety").find("\"ok\":true") == std::string::npos);

  auto config = json::parse(panel.node->configJson());
  REQUIRE(config);
  CHECK(json::getInt(json::get(config.get(), "events"), "retention_days") == 30);

  const std::string unknown_field = callLogReq(
      port, "POST", "/api/config",
      R"({"key":"events","value":"{\"retention_days\":30,\"bogus\":1}"})", admin);
  CHECK(unknown_field.find("\"ok\":true") == std::string::npos);
}
