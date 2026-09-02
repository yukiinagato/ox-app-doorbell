
#include <unistd.h>

#include <cstdlib>
#include <sqlite3.h>
#include <stdexcept>
#include <string>
#include <tuple>
#include <vector>

#include "doctest.h"
#include "events/events.h"
#include "store/store.h"
#include "util/clock.h"
#include "util/hlc.h"
#include "util/json.h"

using namespace db;

namespace {

std::string makeTempDir() {
  char buf[] = "/tmp/doorbell_evlog_XXXXXX";
  char* d = mkdtemp(buf);
  REQUIRE(d != nullptr);
  return std::string(d);
}


EventRecord mkRemote(const std::string& origin, uint64_t seq, int64_t ms) {
  EventRecord e;
  e.origin = origin;
  e.seq = seq;
  e.type = "motion";
  e.door = "d_back";
  e.device = origin;
  e.hlc = HlcClock::format(ms, 0, origin.substr(0, 8));
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

TEST_CASE("event_log: append advances sequence and HLC and invokes the local callback") {
  SimClock clock(1000);
  HlcClock hlc(clock, "aaaaaaaa");
  Store store;
  REQUIRE(store.open(":memory:"));
  EventLog log("aaaaaaaa0000", hlc, store);
  log.loadHeads();

  std::vector<std::tuple<std::string, uint64_t, bool>> got;
  log.onEvent([&](const EventRecord& e, bool is_local) {
    got.emplace_back(e.origin, e.seq, is_local);
  });

  EventRecord e1 = log.append("press", "d_front", "aaaaaaaa0000", "{\"n\":1}");
  clock.advance(10);
  EventRecord e2 = log.append("press", "d_front", "aaaaaaaa0000", "{\"n\":2}");
  EventRecord e3 = log.append("missed", "d_front", "aaaaaaaa0000", "{}");

  CHECK(e1.seq == 1);
  CHECK(e2.seq == 2);
  CHECK(e3.seq == 3);
  CHECK(e1.hlc < e2.hlc);
  CHECK(e2.hlc < e3.hlc);
  CHECK(e1.origin == "aaaaaaaa0000");
  CHECK(e1.wall_ms == 1000);
  CHECK(log.heads()["aaaaaaaa0000"] == 3);
  CHECK(store.eventExists("aaaaaaaa0000", 3));

  REQUIRE(got.size() == 3);
  CHECK(std::get<1>(got[0]) == 1);
  CHECK(std::get<2>(got[0]) == true);  // local
  CHECK(std::get<2>(got[2]) == true);
}

TEST_CASE("event_log: nested local append waits for the source dispatch acknowledgement") {
  SimClock clock(1000);
  HlcClock hlc(clock, "aaaaaaaa");
  Store store;
  REQUIRE(store.open(":memory:"));
  EventLog log("aaaaaaaa0000", hlc, store);
  log.loadHeads();

  std::vector<std::string> types;
  log.onEvent([&](const EventRecord& event, bool is_local) {
    CHECK(is_local);
    types.push_back(event.type);
    if (event.type == "press") {
      auto payload = json::obj();
      json::set(payload.get(), "source_event_id",
                event.origin + ":" + std::to_string(event.seq));
      CHECK(log.append("delivery_result", event.door, event.device,
                       json::dump(payload.get())).seq == 2);
    }
  });

  CHECK(log.append("press", "d_front", "aaaaaaaa0000", "{}").seq == 1);
  REQUIRE(types.size() == 2);
  CHECK(types[0] == "press");
  CHECK(types[1] == "delivery_result");
  CHECK(store.eventDispatchFrontier("aaaaaaaa0000") == 2);
}

TEST_CASE("event_log: applied events replay after restart until dispatch is acknowledged") {
  const std::string path = makeTempDir() + "/db.sqlite";
  {
    SimClock clock(1000);
    HlcClock hlc(clock, "aaaaaaaa");
    Store store;
    REQUIRE(store.open(path));
    EventLog log("aaaaaaaa0000", hlc, store);
    log.loadHeads();
    CHECK(log.append("motion", "d_front", "aaaaaaaa0000", "{}").seq == 1);
    CHECK(store.eventFrontier("aaaaaaaa0000") == 1);
    CHECK(store.eventDispatchFrontier("aaaaaaaa0000") == 0);
  }

  {
    SimClock clock(1000);
    HlcClock hlc(clock, "aaaaaaaa");
    Store store;
    REQUIRE(store.open(path));
    EventLog log("aaaaaaaa0000", hlc, store);
    log.loadHeads();
    int delivered = 0;
    log.onEvent([&](const EventRecord& event, bool is_local) {
      delivered++;
      CHECK(event.seq == 1);
      CHECK(is_local);
    });
    log.replayRecovered();
    CHECK(delivered == 1);
    CHECK(store.eventDispatchFrontier("aaaaaaaa0000") == 1);
    log.replayRecovered();
    CHECK(delivered == 1);
  }

  SimClock clock(1000);
  HlcClock hlc(clock, "aaaaaaaa");
  Store store;
  REQUIRE(store.open(path));
  EventLog log("aaaaaaaa0000", hlc, store);
  log.loadHeads();
  int delivered = 0;
  log.onEvent([&](const EventRecord&, bool) { delivered++; });
  log.replayRecovered();
  CHECK(delivered == 0);
}

TEST_CASE("event_log: callback failure remains pending across restart") {
  const std::string path = makeTempDir() + "/db.sqlite";
  {
    SimClock clock(1000);
    HlcClock hlc(clock, "aaaaaaaa");
    Store store;
    REQUIRE(store.open(path));
    EventLog log("aaaaaaaa0000", hlc, store);
    log.loadHeads();
    CHECK(log.append("motion", "d_front", "aaaaaaaa0000", "{}").seq == 1);
  }
  {
    SimClock clock(1000);
    HlcClock hlc(clock, "aaaaaaaa");
    Store store;
    REQUIRE(store.open(path));
    EventLog log("aaaaaaaa0000", hlc, store);
    log.loadHeads();
    log.onEvent([](const EventRecord&, bool) { throw std::runtime_error("injected"); });
    CHECK_THROWS_AS(log.replayRecovered(), std::runtime_error);
    CHECK(store.eventDispatchFrontier("aaaaaaaa0000") == 0);
  }

  SimClock clock(1000);
  HlcClock hlc(clock, "aaaaaaaa");
  Store store;
  REQUIRE(store.open(path));
  EventLog log("aaaaaaaa0000", hlc, store);
  log.loadHeads();
  int delivered = 0;
  log.onEvent([&](const EventRecord&, bool) { delivered++; });
  log.replayRecovered();
  CHECK(delivered == 1);
  CHECK(store.eventDispatchFrontier("aaaaaaaa0000") == 1);
}

TEST_CASE("event_log: failed local persistence does not consume a sequence or emit") {
  const std::string path = makeTempDir() + "/db.sqlite";
  SimClock clock(1000);
  HlcClock hlc(clock, "aaaaaaaa");
  Store store;
  REQUIRE(store.open(path));
  EventLog log("aaaaaaaa0000", hlc, store);
  log.loadHeads();

  int emitted = 0;
  log.onEvent([&](const EventRecord&, bool) { emitted++; });
  REQUIRE(execSql(
      path,
      "CREATE TRIGGER fail_event_write BEFORE INSERT ON events "
      "BEGIN SELECT RAISE(FAIL,'injected event write failure'); END"));

  const EventRecord failed =
      log.append("press", "d_front", "aaaaaaaa0000", R"({"attempt":1})");
  CHECK(failed.seq == 0);
  CHECK(failed.origin.empty());
  CHECK(store.eventMaxSeq("aaaaaaaa0000") == 0);
  CHECK(store.eventFrontier("aaaaaaaa0000") == 0);
  CHECK_FALSE(store.eventExists("aaaaaaaa0000", 1));
  CHECK(emitted == 0);

  REQUIRE(execSql(path, "DROP TRIGGER fail_event_write"));
  REQUIRE(execSql(
      path,
      "CREATE TRIGGER fail_event_state BEFORE INSERT ON event_origin_state "
      "BEGIN SELECT RAISE(FAIL,'injected event state failure'); END"));
  const EventRecord failed_state =
      log.append("press", "d_front", "aaaaaaaa0000", R"({"attempt":2})");
  CHECK(failed_state.seq == 0);
  CHECK(store.eventMaxSeq("aaaaaaaa0000") == 0);
  CHECK(store.eventFrontier("aaaaaaaa0000") == 0);
  CHECK_FALSE(store.eventExists("aaaaaaaa0000", 1));
  CHECK(emitted == 0);

  REQUIRE(execSql(path, "DROP TRIGGER fail_event_state"));
  REQUIRE(execSql(
      path,
      "CREATE TRIGGER fail_event_projection BEFORE UPDATE OF frontier ON event_origin_state "
      "WHEN NEW.frontier > OLD.frontier "
      "BEGIN SELECT RAISE(FAIL,'injected projection write failure'); END"));
  const EventRecord failed_projection =
      log.append("press", "d_front", "aaaaaaaa0000", R"({"attempt":3})");
  CHECK(failed_projection.seq == 0);
  CHECK(store.eventMaxSeq("aaaaaaaa0000") == 0);
  CHECK(store.eventFrontier("aaaaaaaa0000") == 0);
  CHECK_FALSE(store.eventExists("aaaaaaaa0000", 1));
  CHECK_FALSE(store.callProjection("aaaaaaaa0000:1").has_value());
  CHECK(emitted == 0);

  REQUIRE(execSql(path, "DROP TRIGGER fail_event_projection"));
  const EventRecord first =
      log.append("press", "d_front", "aaaaaaaa0000", R"({"attempt":4})");
  const EventRecord second =
      log.append("motion", "d_front", "aaaaaaaa0000", R"({"attempt":5})");
  CHECK(first.seq == 1);
  CHECK(second.seq == 2);
  CHECK(store.eventMaxSeq("aaaaaaaa0000") == 2);
  CHECK(store.eventFrontier("aaaaaaaa0000") == 2);
  CHECK(emitted == 2);
}

TEST_CASE("event_log: startup repairs and replays a durable event whose frontier was not applied") {
  const std::string path = makeTempDir() + "/db.sqlite";
  const EventRecord remote = mkRemote("bbbbbbbb1111", 1, 5000);
  {
    SimClock clock(1000);
    HlcClock hlc(clock, "aaaaaaaa");
    Store store;
    REQUIRE(store.open(path));
    EventLog log("aaaaaaaa0000", hlc, store);
    log.loadHeads();
    int emitted = 0;
    log.onEvent([&](const EventRecord&, bool) { emitted++; });
    REQUIRE(execSql(
        path,
        "CREATE TRIGGER fail_remote_projection BEFORE UPDATE OF frontier ON event_origin_state "
        "WHEN NEW.frontier > OLD.frontier "
        "BEGIN SELECT RAISE(FAIL,'injected remote projection failure'); END"));
    CHECK(log.applyRemote(remote));
    CHECK(store.eventExists(remote.origin, remote.seq));
    CHECK(store.eventFrontier(remote.origin) == 0);
    CHECK(emitted == 0);
    REQUIRE(execSql(path, "DROP TRIGGER fail_remote_projection"));
  }

  SimClock recovered_clock(1000);
  HlcClock recovered_hlc(recovered_clock, "aaaaaaaa");
  Store recovered_store;
  REQUIRE(recovered_store.open(path));
  EventLog recovered("aaaaaaaa0000", recovered_hlc, recovered_store);
  recovered.loadHeads();
  CHECK(recovered.heads()[remote.origin] == 1);
  int emitted = 0;
  bool was_local = true;
  recovered.onEvent([&](const EventRecord& event, bool is_local) {
    emitted++;
    was_local = is_local;
    CHECK(event.origin == remote.origin);
    CHECK(event.seq == remote.seq);
  });
  recovered.replayRecovered();
  CHECK(emitted == 1);
  CHECK_FALSE(was_local);
  recovered.replayRecovered();
  CHECK(emitted == 1);
}

TEST_CASE("event_log: applyRemote is idempotent for duplicates and reflected local events") {
  SimClock clock(1000);
  HlcClock hlc(clock, "aaaaaaaa");
  Store store;
  REQUIRE(store.open(":memory:"));
  EventLog log("aaaaaaaa0000", hlc, store);
  log.loadHeads();

  int cb_count = 0;
  bool last_local = true;
  log.onEvent([&](const EventRecord&, bool is_local) {
    cb_count++;
    last_local = is_local;
  });

  EventRecord r = mkRemote("bbbbbbbb1111", 1, 999'999);
  CHECK(log.applyRemote(r));
  CHECK_FALSE(log.applyRemote(r));
  CHECK(cb_count == 1);
  CHECK(last_local == false);
  CHECK(log.heads()["bbbbbbbb1111"] == 1);


  EventRecord mine = log.append("press", "d_front", "aaaaaaaa0000", "{}");
  CHECK(mine.hlc > r.hlc);


  CHECK_FALSE(log.applyRemote(mine));
  CHECK(log.heads()["aaaaaaaa0000"] == 1);
  CHECK(cb_count == 2);
}

TEST_CASE("event_log: head advances only through a contiguous out-of-order prefix") {
  SimClock clock(1000);
  HlcClock hlc(clock, "aaaaaaaa");
  Store store;
  REQUIRE(store.open(":memory:"));
  EventLog log("aaaaaaaa0000", hlc, store);
  log.loadHeads();

  CHECK(log.applyRemote(mkRemote("bbbbbbbb1111", 3, 3000)));
  CHECK(log.heads()["bbbbbbbb1111"] == 0);
  CHECK(log.applyRemote(mkRemote("bbbbbbbb1111", 2, 2000)));
  CHECK(log.heads()["bbbbbbbb1111"] == 0);
  CHECK(log.applyRemote(mkRemote("bbbbbbbb1111", 1, 1000)));
  CHECK(log.heads()["bbbbbbbb1111"] == 3);
  CHECK(store.eventMaxSeq("bbbbbbbb1111") == 3);
  CHECK(store.eventFrontier("bbbbbbbb1111") == 3);
  CHECK(store.eventExists("bbbbbbbb1111", 1));
  CHECK(store.eventExists("bbbbbbbb1111", 2));
  CHECK(store.eventExists("bbbbbbbb1111", 3));


  auto delta = log.deltaSince({{"bbbbbbbb1111", 2}}, 10);
  REQUIRE(delta.size() == 1);
  CHECK(delta[0].seq == 3);
}

TEST_CASE("event_log: anti-entropy repairs a gap after restart without reusing local IDs") {
  SimClock clock(1000);
  HlcClock source_hlc(clock, "bbbbbbbb");
  Store source_store;
  REQUIRE(source_store.open(":memory:"));
  EventLog source("bbbbbbbb1111", source_hlc, source_store);
  source.loadHeads();
  const EventRecord seq1 = source.append("motion", "d_back", "bbbbbbbb1111", "{}");
  clock.advance(1);
  const EventRecord seq2 = source.append("motion", "d_back", "bbbbbbbb1111", "{}");
  REQUIRE(seq1.seq == 1);
  REQUIRE(seq2.seq == 2);

  const std::string path = makeTempDir() + "/db.sqlite";
  HlcClock recovered_hlc(clock, "bbbbbbbb");
  {
    Store receiver_store;
    REQUIRE(receiver_store.open(path));
    EventLog receiver("bbbbbbbb1111", recovered_hlc, receiver_store);
    receiver.loadHeads();
    CHECK(receiver.applyRemote(seq2));
    CHECK(receiver.heads()["bbbbbbbb1111"] == 0);
    CHECK(receiver_store.eventMaxSeq("bbbbbbbb1111") == 2);
  }

  Store receiver_store;
  REQUIRE(receiver_store.open(path));
  EventLog receiver("bbbbbbbb1111", recovered_hlc, receiver_store);
  receiver.loadHeads();
  CHECK(receiver.heads()["bbbbbbbb1111"] == 0);
  CHECK(receiver.append("motion", "d_back", "bbbbbbbb1111", "{}").seq == 3);
  CHECK(receiver.heads()["bbbbbbbb1111"] == 0);

  const auto repair = source.deltaSince(receiver.heads(), 1);
  REQUIRE(repair.size() == 1);
  CHECK(repair[0].seq == 1);
  CHECK(receiver.applyRemote(repair[0]));
  CHECK(receiver.heads()["bbbbbbbb1111"] == 3);
  CHECK(receiver_store.eventExists("bbbbbbbb1111", 1));
  CHECK(receiver_store.eventExists("bbbbbbbb1111", 2));
  CHECK(receiver_store.eventExists("bbbbbbbb1111", 3));
}

TEST_CASE("event_log: buffered lifecycle events project and notify in origin sequence order") {
  SimClock clock(1000);
  HlcClock hlc(clock, "aaaaaaaa");
  Store store;
  REQUIRE(store.open(":memory:"));
  EventLog log("aaaaaaaa0000", hlc, store);
  log.loadHeads();

  EventRecord terminal = mkRemote("bbbbbbbb1111", 1, 1000);
  terminal.type = "reply";
  terminal.payload_json = R"({"schema_version":2,"reply_id":"not_home"})";
  EventRecord next_press = mkRemote("bbbbbbbb1111", 2, 2000);
  next_press.type = "press";
  next_press.payload_json =
      R"({"schema_version":2,"call_id":"next-call","stage_revision":0,"expires_at_ms":62000})";

  RuleEngine rules;
  rules.setConfig(R"({
    "trigger_rules": {
      "reply": {"when":{"type":"reply"},"actions":[{"type":"ha_event"}]},
      "ring": {"when":{"type":"button"},"actions":[{"type":"chime"}]}
    }
  })");
  std::vector<uint64_t> notified;
  std::vector<uint64_t> rule_evaluations;
  log.onEvent([&](const EventRecord& event, bool is_local) {
    notified.push_back(event.seq);
    if (!rules.evaluate(event, event.wall_ms, 0).empty())
      rule_evaluations.push_back(event.seq);
    CHECK_FALSE(is_local);
    if (event.seq == 1) CHECK_FALSE(store.callProjection("next-call").has_value());
    if (event.seq == 2) {
      auto projection = store.callProjection("next-call");
      REQUIRE(projection);
      CHECK(projection->state == "ringing");
    }
  });

  CHECK(log.applyRemote(next_press));
  CHECK(log.heads()["bbbbbbbb1111"] == 0);
  CHECK(notified.empty());
  CHECK_FALSE(store.callProjection("next-call").has_value());

  CHECK(log.applyRemote(terminal));
  CHECK(log.heads()["bbbbbbbb1111"] == 2);
  REQUIRE(notified.size() == 2);
  CHECK(notified[0] == 1);
  CHECK(notified[1] == 2);
  REQUIRE(rule_evaluations.size() == 2);
  CHECK(rule_evaluations[0] == 1);
  CHECK(rule_evaluations[1] == 2);
  auto projection = store.callProjection("next-call");
  REQUIRE(projection);
  CHECK(projection->state == "ringing");
}

TEST_CASE("event_log: mergeNotify uses HLC LWW and preserves the field union") {
  SimClock clock(1000);
  HlcClock hlc(clock, "aaaaaaaa");
  Store store;
  REQUIRE(store.open(":memory:"));
  EventLog log("aaaaaaaa0000", hlc, store);
  log.loadHeads();

  EventRecord ev = log.append("press", "d_front", "aaaaaaaa0000", "{}");
  const std::string h0 = HlcClock::format(5000, 0, "cccccccc");
  const std::string h1 = HlcClock::format(6000, 0, "cccccccc");
  const std::string h2 = HlcClock::format(7000, 0, "dddddddd");


  CHECK_FALSE(log.mergeNotify(ev.origin, 999, "{\"hlc\":\"" + h1 + "\"}"));

  CHECK_FALSE(log.mergeNotify(ev.origin, ev.seq, "[1,2]"));


  CHECK(log.mergeNotify(ev.origin, ev.seq,
                        "{\"hlc\":\"" + h1 + "\",\"claimed_by\":\"phoneA\"}"));

  CHECK_FALSE(log.mergeNotify(ev.origin, ev.seq,
                              "{\"hlc\":\"" + h1 + "\",\"claimed_by\":\"phoneA\"}"));


  CHECK(log.mergeNotify(
      ev.origin, ev.seq,
      "{\"hlc\":\"" + h0 + "\",\"claimed_by\":\"phoneB\",\"telegram_msg_ids\":[5]}"));
  {
    auto got = store.eventGet(ev.origin, ev.seq);
    REQUIRE(got.has_value());
    auto doc = json::parse(got->notify_json);
    REQUIRE(doc);
    CHECK(json::getString(doc.get(), "hlc") == h1);
    CHECK(json::getString(doc.get(), "claimed_by") == "phoneA");
    cJSON* ids = json::get(doc.get(), "telegram_msg_ids");
    REQUIRE(ids != nullptr);
    CHECK(cJSON_GetArraySize(ids) == 1);
  }


  CHECK(log.mergeNotify(ev.origin, ev.seq,
                        "{\"hlc\":\"" + h2 + "\",\"claimed_by\":\"phoneC\"}"));
  {
    auto got = store.eventGet(ev.origin, ev.seq);
    REQUIRE(got.has_value());
    auto doc = json::parse(got->notify_json);
    REQUIRE(doc);
    CHECK(json::getString(doc.get(), "hlc") == h2);
    CHECK(json::getString(doc.get(), "claimed_by") == "phoneC");
    CHECK(json::get(doc.get(), "telegram_msg_ids") != nullptr);
  }
}

TEST_CASE("event_log: loadHeads continues sequence after reopen") {
  std::string path = makeTempDir() + "/db.sqlite";
  SimClock clock(1000);
  HlcClock hlc(clock, "aaaaaaaa");
  {
    Store store;
    REQUIRE(store.open(path));
    EventLog log("aaaaaaaa0000", hlc, store);
    log.loadHeads();
    CHECK(log.append("press", "d_front", "aaaaaaaa0000", "{}").seq == 1);
    CHECK(log.append("press", "d_front", "aaaaaaaa0000", "{}").seq == 2);
    CHECK(log.applyRemote(mkRemote("bbbbbbbb1111", 5, 2000)));
  }
  Store store2;
  REQUIRE(store2.open(path));
  EventLog log2("aaaaaaaa0000", hlc, store2);
  log2.loadHeads();
  auto heads = log2.heads();
  CHECK(heads["aaaaaaaa0000"] == 2);
  CHECK(heads["bbbbbbbb1111"] == 0);
  CHECK(store2.eventMaxSeq("bbbbbbbb1111") == 5);
  CHECK(log2.append("press", "d_front", "aaaaaaaa0000", "{}").seq == 3);
}

TEST_CASE("event_log: loadHeads restores the applied event HLC before a wall-clock rollback") {
  const std::string path = makeTempDir() + "/db.sqlite";
  std::string previous_hlc;
  {
    SimClock clock(4'000'000'000'000LL);
    HlcClock hlc(clock, "aaaaaaaa");
    Store store;
    REQUIRE(store.open(path));
    EventLog log("aaaaaaaa0000", hlc, store);
    log.loadHeads();
    const EventRecord previous = log.append("press", "d_front", "aaaaaaaa0000", "{}");
    REQUIRE(previous.seq == 1);
    previous_hlc = previous.hlc;
  }

  SimClock rolled_back_clock(1000);
  HlcClock recovered_hlc(rolled_back_clock, "aaaaaaaa");
  Store recovered_store;
  REQUIRE(recovered_store.open(path));
  EventLog recovered("aaaaaaaa0000", recovered_hlc, recovered_store);
  recovered.loadHeads();
  const EventRecord next = recovered.append("motion", "d_front", "aaaaaaaa0000", "{}");
  CHECK(next.seq == 2);
  CHECK(next.hlc > previous_hlc);
}
