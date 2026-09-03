
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>

#include <sqlite3.h>

#include "doctest.h"
#include "store/store.h"
#include "util/hlc.h"

using namespace db;

namespace {


std::string makeTempDir() {
  char buf[] = "/tmp/doorbell_store_XXXXXX";
  char* d = mkdtemp(buf);
  REQUIRE(d != nullptr);
  return std::string(d);
}


EventRecord mkEv(const std::string& origin, uint64_t seq, int64_t ms, int counter = 0) {
  EventRecord e;
  e.origin = origin;
  e.seq = seq;
  e.type = "press";
  e.door = "d_front";
  e.device = origin;
  e.hlc = HlcClock::format(ms, counter, origin.substr(0, 8));
  e.wall_ms = ms;
  e.payload_json = "{}";
  return e;
}

bool execSql(const std::string& path, const char* sql) {
  sqlite3* db = nullptr;
  if (sqlite3_open(path.c_str(), &db) != SQLITE_OK) {
    if (db) sqlite3_close(db);
    return false;
  }
  const bool ok = sqlite3_exec(db, sql, nullptr, nullptr, nullptr) == SQLITE_OK;
  sqlite3_close(db);
  return ok;
}

}  // namespace

TEST_CASE("store: metadata round trip") {
  std::string path = makeTempDir() + "/db.sqlite";
  Store s;
  REQUIRE(s.open(path));
  CHECK_FALSE(s.metaGet("missing").has_value());
  s.metaSet("node_id", "abc123");
  CHECK(s.metaGet("node_id") == std::string("abc123"));
  s.metaSet("node_id", "def456");
  CHECK(s.metaGet("node_id") == std::string("def456"));

  CHECK(s.metaGet("schema_version").has_value());
}

TEST_CASE("store: metadata batches roll back atomically on write failure") {
  const std::string path = makeTempDir() + "/db.sqlite";
  Store store;
  REQUIRE(store.open(path));
  REQUIRE(execSql(path,
      "CREATE TRIGGER fail_selected_meta BEFORE INSERT ON meta "
      "WHEN NEW.key='meta.fail.second' "
      "BEGIN SELECT RAISE(FAIL,'injected metadata failure'); END"));

  CHECK_FALSE(store.metaSetBatch({{"meta.fail.first", "one"},
                                  {"meta.fail.second", "two"}}));
  CHECK_FALSE(store.metaGet("meta.fail.first").has_value());
  CHECK_FALSE(store.metaGet("meta.fail.second").has_value());
  CHECK_FALSE(store.metaSet("meta.fail.second", "two"));
}

TEST_CASE("store: full config round trip includes tombstones") {
  std::string path = makeTempDir() + "/db.sqlite";
  Store s;
  REQUIRE(s.open(path));

  LwwEntry a;
  a.key = "doors.d_front.label";
  a.value_json = "\"玄関\"";
  a.hlc = HlcClock::format(1000, 0, "aaaaaaaa");
  a.author = "aaaaaaaa";
  a.seq = 1;
  LwwEntry b;
  b.key = "doors.d_back.label";
  b.deleted = true;
  b.hlc = HlcClock::format(2000, 0, "bbbbbbbb");
  b.author = "bbbbbbbb";
  b.seq = 7;
  s.configPut(a);
  s.configPut(b);

  auto all = s.configLoadAll();
  REQUIRE(all.size() == 2);
  CHECK(all[0].key == "doors.d_back.label");
  CHECK(all[0].deleted);
  CHECK(all[0].value_json == "");
  CHECK(all[0].author == "bbbbbbbb");
  CHECK(all[0].seq == 7);
  CHECK(all[1].key == "doors.d_front.label");
  CHECK_FALSE(all[1].deleted);
  CHECK(all[1].value_json == "\"玄関\"");
  CHECK(all[1].hlc == a.hlc);


  a.value_json = "\"表玄関\"";
  a.seq = 2;
  s.configPut(a);
  all = s.configLoadAll();
  REQUIRE(all.size() == 2);
  CHECK(all[1].value_json == "\"表玄関\"");
  CHECK(all[1].seq == 2);


  s.configDelete(b.key);
  CHECK(s.configLoadAll().size() == 1);
}

TEST_CASE("store: config writes report SQLite failures without partial batches") {
  const std::string path = makeTempDir() + "/db.sqlite";
  Store store;
  REQUIRE(store.open(path));

  sqlite3* injection = nullptr;
  REQUIRE(sqlite3_open(path.c_str(), &injection) == SQLITE_OK);
  REQUIRE(sqlite3_exec(
              injection,
              "CREATE TRIGGER fail_config_write BEFORE INSERT ON config "
              "BEGIN SELECT RAISE(FAIL,'injected config write failure'); END",
              nullptr, nullptr, nullptr) == SQLITE_OK);
  sqlite3_close(injection);

  LwwEntry one;
  one.key = "durability.one";
  one.value_json = "1";
  one.hlc = HlcClock::format(1'000, 0, "aaaaaaaa");
  one.author = "aaaaaaaa";
  one.seq = 1;
  CHECK_FALSE(store.configPut(one));
  CHECK(store.configLoadAll().empty());

  LwwEntry two = one;
  two.key = "durability.two";
  two.seq = 2;
  CHECK_FALSE(store.configPutBatch({one, two}));
  CHECK(store.configLoadAll().empty());
}

TEST_CASE("store: data persists after reopen") {
  std::string path = makeTempDir() + "/db.sqlite";
  {
    Store s;
    REQUIRE(s.open(path));
    s.metaSet("k", "v");
    CHECK(s.eventPut(mkEv("aaaaaaaa", 1, 1000)));
  }
  Store s2;
  REQUIRE(s2.open(path));
  CHECK(s2.metaGet("k") == std::string("v"));
  CHECK(s2.eventExists("aaaaaaaa", 1));
  auto heads = s2.eventHeads();
  CHECK(heads["aaaaaaaa"] == 1);
}

TEST_CASE("store: corrupt files are renamed and recreated") {
  std::string dir = makeTempDir();
  std::string path = dir + "/db.sqlite";
  {
    std::ofstream f(path);
    f << "これは SQLite ではないゴミデータ................";
  }
  Store s;
  REQUIRE(s.open(path));
  s.metaSet("k", "v");
  CHECK(s.metaGet("k") == std::string("v"));

  std::string cmd = "ls " + dir + " | grep -c 'db.sqlite.corrupt-'";
  FILE* p = popen(cmd.c_str(), "r");
  REQUIRE(p != nullptr);
  char out[16] = {0};
  REQUIRE(fgets(out, sizeof(out), p) != nullptr);
  pclose(p);
  CHECK(std::atoi(out) == 1);
}

TEST_CASE("store: a busy healthy database fails closed without replacement") {
  const std::string dir = makeTempDir();
  const std::string path = dir + "/db.sqlite";
  {
    Store original;
    REQUIRE(original.open(path));
    original.metaSet("sentinel", "preserve-me");
  }

  sqlite3* locker = nullptr;
  REQUIRE(sqlite3_open(path.c_str(), &locker) == SQLITE_OK);
  REQUIRE(sqlite3_exec(locker, "PRAGMA journal_mode=DELETE", nullptr, nullptr, nullptr) ==
          SQLITE_OK);
  REQUIRE(sqlite3_exec(locker, "BEGIN EXCLUSIVE", nullptr, nullptr, nullptr) == SQLITE_OK);

  Store contender;
  CHECK_FALSE(contender.open(path));
  std::string cmd = "ls " + dir + " | grep -c 'db.sqlite.corrupt-'";
  FILE* pipe = popen(cmd.c_str(), "r");
  REQUIRE(pipe != nullptr);
  char count[16] = {0};
  REQUIRE(fgets(count, sizeof(count), pipe) != nullptr);
  pclose(pipe);
  CHECK(std::atoi(count) == 0);

  REQUIRE(sqlite3_exec(locker, "ROLLBACK", nullptr, nullptr, nullptr) == SQLITE_OK);
  sqlite3_close(locker);

  Store reopened;
  REQUIRE(reopened.open(path));
  CHECK(reopened.metaGet("sentinel") == std::optional<std::string>("preserve-me"));
}

TEST_CASE("store: duplicate eventPut returns false") {
  Store s;
  REQUIRE(s.open(makeTempDir() + "/db.sqlite"));
  EventRecord e = mkEv("aaaaaaaa", 1, 1000);
  CHECK(s.eventPut(e));
  CHECK_FALSE(s.eventPut(e));
  e.type = "motion";
  CHECK_FALSE(s.eventPut(e));
  auto got = s.eventGet("aaaaaaaa", 1);
  REQUIRE(got.has_value());
  CHECK(got->type == "press");
  CHECK_FALSE(s.eventGet("aaaaaaaa", 2).has_value());
  CHECK(s.eventExists("aaaaaaaa", 1));
  CHECK_FALSE(s.eventExists("bbbbbbbb", 1));
}

TEST_CASE("store: eventHeads and eventsSince respect HLC order and limit") {
  Store s;
  REQUIRE(s.open(makeTempDir() + "/db.sqlite"));

  CHECK(s.eventPut(mkEv("aaaaaaaa", 1, 1000)));
  CHECK(s.eventPut(mkEv("bbbbbbbb", 1, 1500)));
  CHECK(s.eventPut(mkEv("aaaaaaaa", 2, 2000)));
  CHECK(s.eventPut(mkEv("bbbbbbbb", 2, 2500)));
  CHECK(s.eventPut(mkEv("aaaaaaaa", 3, 3000)));

  auto heads = s.eventHeads();
  REQUIRE(heads.size() == 2);
  CHECK(heads["aaaaaaaa"] == 3);
  CHECK(heads["bbbbbbbb"] == 2);


  auto all = s.eventsSince({}, 100);
  REQUIRE(all.size() == 5);
  for (size_t i = 1; i < all.size(); i++) CHECK(all[i - 1].hlc < all[i].hlc);
  CHECK(all[0].wall_ms == 1000);
  CHECK(all[4].wall_ms == 3000);


  auto delta = s.eventsSince({{"aaaaaaaa", 2}, {"bbbbbbbb", 1}}, 100);
  REQUIRE(delta.size() == 2);
  CHECK(delta[0].origin == "bbbbbbbb");
  CHECK(delta[0].seq == 2);
  CHECK(delta[1].origin == "aaaaaaaa");
  CHECK(delta[1].seq == 3);


  auto lim = s.eventsSince({}, 2);
  REQUIRE(lim.size() == 2);
  CHECK(lim[0].wall_ms == 1000);
  CHECK(lim[1].wall_ms == 1500);
}

TEST_CASE("store: event heads and retained prefix survive a refused prune") {
  const std::string path = makeTempDir() + "/db.sqlite";
  {
    Store s;
    REQUIRE(s.open(path));
    CHECK(s.eventPut(mkEv("aaaaaaaa", 2, 2000)));
    CHECK(s.eventHeads()["aaaaaaaa"] == 0);
    CHECK(s.eventFrontier("aaaaaaaa") == 0);
    CHECK(s.eventMaxSeq("aaaaaaaa") == 2);
  }
  {
    Store s;
    REQUIRE(s.open(path));
    CHECK(s.eventHeads()["aaaaaaaa"] == 0);
    CHECK(s.eventMaxSeq("aaaaaaaa") == 2);
    CHECK(s.eventPut(mkEv("aaaaaaaa", 1, 1000)));
    CHECK(s.eventFrontier("aaaaaaaa") == 2);
    CHECK(s.pruneEvents(0, 0) == 0);
    CHECK(s.eventFrontier("aaaaaaaa") == 2);
    CHECK(s.eventMaxSeq("aaaaaaaa") == 2);
    CHECK(s.eventsSince({}, 10).size() == 2);
  }
}

TEST_CASE("store: recentEvents returns newest first") {
  Store s;
  REQUIRE(s.open(makeTempDir() + "/db.sqlite"));
  CHECK(s.eventPut(mkEv("aaaaaaaa", 1, 1000)));
  CHECK(s.eventPut(mkEv("aaaaaaaa", 2, 3000)));
  CHECK(s.eventPut(mkEv("bbbbbbbb", 1, 2000)));
  auto recent = s.recentEvents(2);
  REQUIRE(recent.size() == 2);
  CHECK(recent[0].wall_ms == 3000);
  CHECK(recent[1].wall_ms == 2000);
}

TEST_CASE("store: runtime event queries exclude gaps until their origin frontier advances") {
  const std::string path = makeTempDir() + "/db.sqlite";
  EventRecord emergency = mkEv("aaaaaaaa", 1, 1000);
  emergency.type = "emergency";
  EventRecord emergency_cancel = mkEv("aaaaaaaa", 3, 3000);
  emergency_cancel.type = "emergency_cancel";
  EventRecord gap_press = mkEv("bbbbbbbb", 2, 2500);

  {
    Store store;
    REQUIRE(store.open(path));
    CHECK(store.eventPut(emergency));
    CHECK(store.eventPut(emergency_cancel));
    CHECK(store.eventPut(gap_press));
    CHECK(store.eventFrontier("aaaaaaaa") == 1);
    CHECK(store.eventFrontier("bbbbbbbb") == 0);

    REQUIRE(store.eventGet("aaaaaaaa", 3));
    REQUIRE(store.eventGet("bbbbbbbb", 2));
    auto delta = store.eventsSince({{"aaaaaaaa", 1}, {"bbbbbbbb", 0}}, 10);
    REQUIRE(delta.size() == 2);

    auto latest = store.latestEventOfTypes("emergency", "emergency_cancel");
    REQUIRE(latest);
    CHECK(latest->type == "emergency");
    auto recent = store.recentEvents(10);
    REQUIRE(recent.size() == 1);
    CHECK(recent[0].type == "emergency");
    CHECK(store.countEventsOfType("press") == 0);
    CHECK(store.metaGet("stat_press_total") == std::string("0"));
  }

  Store reopened;
  REQUIRE(reopened.open(path));
  auto latest = reopened.latestEventOfTypes("emergency", "emergency_cancel");
  REQUIRE(latest);
  CHECK(latest->type == "emergency");
  auto recent = reopened.recentEvents(10);
  REQUIRE(recent.size() == 1);
  CHECK(recent[0].type == "emergency");

  EventRecord emergency_bridge = mkEv("aaaaaaaa", 2, 2000);
  emergency_bridge.type = "motion";
  CHECK(reopened.eventPut(emergency_bridge));
  CHECK(reopened.eventFrontier("aaaaaaaa") == 3);
  latest = reopened.latestEventOfTypes("emergency", "emergency_cancel");
  REQUIRE(latest);
  CHECK(latest->type == "emergency_cancel");

  EventRecord press_bridge = mkEv("bbbbbbbb", 1, 1500);
  press_bridge.type = "online";
  CHECK(reopened.eventPut(press_bridge));
  CHECK(reopened.eventFrontier("bbbbbbbb") == 2);
  CHECK(reopened.countEventsOfType("press") == 1);
  CHECK(reopened.metaGet("stat_press_total") == std::string("1"));
  recent = reopened.recentEvents(10);
  REQUIRE(recent.size() == 5);
  CHECK(recent[0].type == "emergency_cancel");
  CHECK(recent[1].type == "press");
}

TEST_CASE("store: schema migration rebuilds call projection from contiguous events only") {
  const std::string path = makeTempDir() + "/db.sqlite";
  EventRecord press = mkEv("aaaaaaaa", 1, 1000);
  press.payload_json =
      R"({"schema_version":2,"call_id":"migration-gap","stage_revision":0})";
  EventRecord cancel = mkEv("aaaaaaaa", 3, 3000);
  cancel.type = "call_cancelled";
  cancel.payload_json =
      R"({"schema_version":2,"call_id":"migration-gap","stage_revision":0,"reason":"visitor"})";

  {
    Store store;
    REQUIRE(store.open(path));
    CHECK(store.eventPut(press));
    CHECK(store.eventPut(cancel));
    auto projection = store.callProjection("migration-gap");
    REQUIRE(projection);
    CHECK(projection->state == "ringing");
  }

  REQUIRE(execSql(path, "UPDATE meta SET value='3' WHERE key='schema_version';"
                        "UPDATE call_projection SET state='cancelled',"
                        " terminal_reason='legacy_gap' WHERE call_id='migration-gap';"));

  Store migrated;
  REQUIRE(migrated.open(path));
  CHECK(migrated.eventFrontier("aaaaaaaa") == 1);
  REQUIRE(migrated.eventGet("aaaaaaaa", 3));
  auto projection = migrated.callProjection("migration-gap");
  REQUIRE(projection);
  CHECK(projection->state == "ringing");
  auto recent = migrated.recentEvents(10);
  REQUIRE(recent.size() == 1);
  CHECK(recent[0].seq == 1);

  EventRecord bridge = mkEv("aaaaaaaa", 2, 2000);
  bridge.type = "motion";
  CHECK(migrated.eventPut(bridge));
  projection = migrated.callProjection("migration-gap");
  REQUIRE(projection);
  CHECK(projection->state == "cancelled");
}

TEST_CASE("store: quick reply never terminalizes an established call") {
  Store store;
  REQUIRE(store.open(":memory:"));

  EventRecord press = mkEv("aaaaaaaa", 1, 1000);
  press.payload_json =
      R"({"schema_version":2,"call_id":"established","stage_revision":0})";
  REQUIRE(store.eventPut(press));

  EventRecord answered = mkEv("aaaaaaaa", 2, 2000);
  answered.type = "call_answered";
  answered.payload_json =
      R"({"schema_version":2,"call_id":"established","stage_revision":0,"dialog_owner":"aaaaaaaa"})";
  REQUIRE(store.eventPut(answered));
  auto projection = store.callProjection("established");
  REQUIRE(projection);
  CHECK(projection->state == "in_call");

  EventRecord reply = mkEv("aaaaaaaa", 3, 3000);
  reply.type = "reply";
  reply.payload_json =
      R"({"schema_version":2,"reply_id":"not_home","call_id":"established","stage_revision":0})";
  REQUIRE(store.eventPut(reply));
  projection = store.callProjection("established");
  REQUIRE(projection);
  CHECK(projection->state == "in_call");
  CHECK(projection->terminal_reason.empty());
}

TEST_CASE("store: scoped replies converge and never terminate a later call") {
  EventRecord press_a = mkEv("aaaaaaaa", 1, 1000);
  press_a.payload_json = R"({"schema_version":2,"call_id":"call-a","stage_revision":0})";
  EventRecord reply_a = mkEv("bbbbbbbb", 1, 2000);
  reply_a.type = "reply";
  reply_a.payload_json =
      R"({"schema_version":2,"reply_id":"not_home","call_id":"call-a","stage_revision":0,"call_origin":"aaaaaaaa"})";

  Store ordered;
  Store reordered;
  REQUIRE(ordered.open(":memory:"));
  REQUIRE(reordered.open(":memory:"));
  REQUIRE(ordered.eventPut(press_a));
  REQUIRE(ordered.eventPut(reply_a));
  REQUIRE(reordered.eventPut(reply_a));
  REQUIRE(reordered.eventPut(press_a));
  const auto ordered_a = ordered.callProjection("call-a");
  const auto reordered_a = reordered.callProjection("call-a");
  REQUIRE(ordered_a);
  REQUIRE(reordered_a);
  CHECK(ordered_a->state == "ended");
  CHECK(reordered_a->state == "ended");
  CHECK(ordered_a->terminal_reason == "reply");
  CHECK(reordered_a->terminal_reason == "reply");

  EventRecord cancel_a = mkEv("aaaaaaaa", 2, 3000);
  cancel_a.type = "call_cancelled";
  cancel_a.payload_json =
      R"({"schema_version":2,"call_id":"call-a","stage_revision":0,"reason":"visitor"})";
  REQUIRE(ordered.eventPut(cancel_a));
  const auto ordered_after_cancel = ordered.callProjection("call-a");
  REQUIRE(ordered_after_cancel);
  CHECK(ordered_after_cancel->state == "ended");
  CHECK(ordered_after_cancel->terminal_reason == "reply");

  Store cancel_first;
  REQUIRE(cancel_first.open(":memory:"));
  REQUIRE(cancel_first.eventPut(press_a));
  REQUIRE(cancel_first.eventPut(cancel_a));
  REQUIRE(cancel_first.eventPut(reply_a));
  const auto cancel_first_projection = cancel_first.callProjection("call-a");
  REQUIRE(cancel_first_projection);
  CHECK(cancel_first_projection->state == "ended");
  CHECK(cancel_first_projection->terminal_reason == "reply");

  EventRecord press_b = mkEv("cccccccc", 1, 4000);
  press_b.payload_json = R"({"schema_version":2,"call_id":"call-b","stage_revision":0})";
  REQUIRE(ordered.eventPut(press_b));
  EventRecord delayed_reply_a = reply_a;
  delayed_reply_a.seq = 2;
  delayed_reply_a.hlc = HlcClock::format(5000, 0, "bbbbbbbb");
  delayed_reply_a.wall_ms = 5000;
  REQUIRE(ordered.eventPut(delayed_reply_a));
  const auto ordered_b = ordered.callProjection("call-b");
  REQUIRE(ordered_b);
  CHECK(ordered_b->state == "ringing");
  CHECK(ordered_b->terminal_reason.empty());
}

TEST_CASE("store: schema v4 upgrade treats its applied frontier as already dispatched") {
  const std::string path = makeTempDir() + "/db.sqlite";
  {
    Store store;
    REQUIRE(store.open(path));
    REQUIRE(store.eventPut(mkEv("aaaaaaaa", 1, 1000)));
    CHECK(store.eventFrontier("aaaaaaaa") == 1);
    CHECK(store.eventDispatchFrontier("aaaaaaaa") == 0);
  }

  REQUIRE(execSql(
      path,
      "BEGIN;"
      "ALTER TABLE event_origin_state RENAME TO event_origin_state_v5;"
      "CREATE TABLE event_origin_state("
      " origin TEXT PRIMARY KEY,frontier INT NOT NULL,max_seq INT NOT NULL);"
      "INSERT INTO event_origin_state(origin,frontier,max_seq)"
      " SELECT origin,frontier,max_seq FROM event_origin_state_v5;"
      "DROP TABLE event_origin_state_v5;"
      "UPDATE meta SET value='4' WHERE key='schema_version';"
      "COMMIT;"));

  Store upgraded;
  REQUIRE(upgraded.open(path));
  CHECK(upgraded.eventFrontier("aaaaaaaa") == 1);
  CHECK(upgraded.eventDispatchFrontier("aaaaaaaa") == 1);
  CHECK(upgraded.pendingEventDispatches(10).empty());
}

TEST_CASE("store: pruneEvents fails closed until a replicated coverage snapshot exists") {
  Store s;
  REQUIRE(s.open(makeTempDir() + "/db.sqlite"));
  for (uint64_t i = 1; i <= 10; i++) {
    CHECK(s.eventPut(mkEv("aaaaaaaa", i, static_cast<int64_t>(1000 * i))));
  }


  CHECK(s.pruneEvents(100, 3000) == 0);
  auto all = s.eventsSince({}, 100);
  REQUIRE(all.size() == 10);
  CHECK(all[0].wall_ms == 1000);


  CHECK(s.pruneEvents(5, 0) == 0);
  all = s.eventsSince({}, 100);
  REQUIRE(all.size() == 10);
  CHECK(all[0].wall_ms == 1000);
  CHECK(all[9].wall_ms == 10000);


  CHECK(s.pruneEvents(100, 0) == 0);

  Store joining_peer;
  REQUIRE(joining_peer.open(makeTempDir() + "/db.sqlite"));
  for (const auto& event : all) CHECK(joining_peer.eventPut(event));
  CHECK(joining_peer.eventFrontier("aaaaaaaa") == 10);
  CHECK(joining_peer.eventsSince({}, 100).size() == 10);
}
