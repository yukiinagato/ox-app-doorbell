// EventLog のテスト。SimClock + HlcClock で決定的に。
#include <unistd.h>

#include <cstdlib>
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

// リモートノード発のイベントを合成
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

}  // namespace

TEST_CASE("event_log: append は seq 単調 + hlc 昇順 + local コールバック") {
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
  CHECK(e2.hlc < e3.hlc);  // 同一 ms はカウンタで単調
  CHECK(e1.origin == "aaaaaaaa0000");
  CHECK(e1.wall_ms == 1000);
  CHECK(log.heads()["aaaaaaaa0000"] == 3);
  CHECK(store.eventExists("aaaaaaaa0000", 3));

  REQUIRE(got.size() == 3);
  CHECK(std::get<1>(got[0]) == 1);
  CHECK(std::get<2>(got[0]) == true);  // local
  CHECK(std::get<2>(got[2]) == true);
}

TEST_CASE("event_log: applyRemote は冪等 (二重配送・自分発の還流)") {
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
  CHECK_FALSE(log.applyRemote(r));  // 二重配送は無視
  CHECK(cb_count == 1);
  CHECK(last_local == false);
  CHECK(log.heads()["bbbbbbbb1111"] == 1);

  // リモート hlc を observe している → 次のローカル刻印はそれより大きい
  EventRecord mine = log.append("press", "d_front", "aaaaaaaa0000", "{}");
  CHECK(mine.hlc > r.hlc);

  // 自分発イベントが mesh から還流しても冪等に無視
  CHECK_FALSE(log.applyRemote(mine));
  CHECK(log.heads()["aaaaaaaa0000"] == 1);
  CHECK(cb_count == 2);  // append の分のみ増加
}

TEST_CASE("event_log: 順序逆転配送でも heads は前進のみ") {
  SimClock clock(1000);
  HlcClock hlc(clock, "aaaaaaaa");
  Store store;
  REQUIRE(store.open(":memory:"));
  EventLog log("aaaaaaaa0000", hlc, store);
  log.loadHeads();

  CHECK(log.applyRemote(mkRemote("bbbbbbbb1111", 3, 3000)));  // seq 3 が先着
  CHECK(log.heads()["bbbbbbbb1111"] == 3);
  CHECK(log.applyRemote(mkRemote("bbbbbbbb1111", 2, 2000)));  // 遅れて seq 2
  CHECK(log.heads()["bbbbbbbb1111"] == 3);  // 後退しない
  CHECK(store.eventExists("bbbbbbbb1111", 2));
  CHECK(store.eventExists("bbbbbbbb1111", 3));

  // deltaSince は Store 委譲: 相手が seq2 まで知っていれば seq3 のみ
  auto delta = log.deltaSince({{"bbbbbbbb1111", 2}}, 10);
  REQUIRE(delta.size() == 1);
  CHECK(delta[0].seq == 3);
}

TEST_CASE("event_log: mergeNotify は hlc LWW + フィールド和集合") {
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

  // 存在しないイベント → false
  CHECK_FALSE(log.mergeNotify(ev.origin, 999, "{\"hlc\":\"" + h1 + "\"}"));
  // オブジェクトでない notify → false
  CHECK_FALSE(log.mergeNotify(ev.origin, ev.seq, "[1,2]"));

  // 空 → 初回マージ
  CHECK(log.mergeNotify(ev.origin, ev.seq,
                        "{\"hlc\":\"" + h1 + "\",\"claimed_by\":\"phoneA\"}"));
  // 同一内容の再マージは変化なし
  CHECK_FALSE(log.mergeNotify(ev.origin, ev.seq,
                              "{\"hlc\":\"" + h1 + "\",\"claimed_by\":\"phoneA\"}"));

  // 古い hlc 側は衝突フィールドで負けるが、無い フィールドは和集合に入る
  CHECK(log.mergeNotify(
      ev.origin, ev.seq,
      "{\"hlc\":\"" + h0 + "\",\"claimed_by\":\"phoneB\",\"telegram_msg_ids\":[5]}"));
  {
    auto got = store.eventGet(ev.origin, ev.seq);
    REQUIRE(got.has_value());
    auto doc = json::parse(got->notify_json);
    REQUIRE(doc);
    CHECK(json::getString(doc.get(), "hlc") == h1);              // 新しい方が勝つ
    CHECK(json::getString(doc.get(), "claimed_by") == "phoneA");  // 衝突は勝者側
    cJSON* ids = json::get(doc.get(), "telegram_msg_ids");        // 和集合で残る
    REQUIRE(ids != nullptr);
    CHECK(cJSON_GetArraySize(ids) == 1);
  }

  // より新しい hlc は衝突フィールドを上書き、既存の固有フィールドは保持
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

TEST_CASE("event_log: reopen 後の loadHeads で seq 継続") {
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
  CHECK(heads["bbbbbbbb1111"] == 5);
  CHECK(log2.append("press", "d_front", "aaaaaaaa0000", "{}").seq == 3);  // 続きから採番
}
