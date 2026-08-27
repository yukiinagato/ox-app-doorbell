// LwwMap の CRDT 性質テスト。収束性はランダム操作 + シャッフル/重複配送の property test で疑う。
#include <algorithm>
#include <memory>
#include <optional>
#include <random>
#include <vector>

#include "crdt/lww_map.h"
#include "doctest.h"
#include "util/clock.h"
#include "util/json.h"

using namespace db;

namespace {

// テスト用レプリカ一式 (時計・HLC・マップ)。published にローカル書き込みの全履歴を溜める。
struct Replica {
  SimClock clock;
  HlcClock hlc;
  LwwMap map;
  std::vector<LwwEntry> published;
  Replica(const std::string& id, int64_t wall_start)
      : clock(wall_start), hlc(clock, id), map(id, hlc) {
    map.onChange([this](const LwwEntry& e, bool is_local) {
      if (is_local) published.push_back(e);
    });
  }
};

bool sameEntry(const LwwEntry& a, const LwwEntry& b) {
  return a.key == b.key && a.value_json == b.value_json && a.deleted == b.deleted &&
         a.hlc == b.hlc && a.author == b.author && a.seq == b.seq;
}

// 全 entry (tombstone 含む) と version vector の完全一致
bool sameState(const LwwMap& a, const LwwMap& b) {
  auto ea = a.all();
  auto eb = b.all();
  if (ea.size() != eb.size()) return false;
  for (size_t i = 0; i < ea.size(); i++) {
    if (!sameEntry(ea[i], eb[i])) return false;
  }
  return a.versionVector() == b.versionVector();
}

const std::string kIdA = "aaaa000000000000";
const std::string kIdB = "bbbb000000000000";
const std::string kIdC = "cccc000000000000";

}  // namespace

TEST_CASE("収束性 property: ランダム操作 + シャッフル順・重複配送で 3 台が完全一致") {
  const std::vector<std::string> keys = {"a",  "a.b",       "doors.front.label",
                                         "nm", "doors.vol", "doors.front.ring"};
  for (uint32_t seed = 1; seed <= 24; seed++) {
    CAPTURE(seed);
    std::mt19937 rng(seed);
    std::vector<std::unique_ptr<Replica>> reps;
    reps.push_back(std::make_unique<Replica>(kIdA, 1'000'000));
    reps.push_back(std::make_unique<Replica>(kIdB, 1'000'500));  // 時計はずれている
    reps.push_back(std::make_unique<Replica>(kIdC, 999'700));
    // 各レプリカが互いを知らずに書く = 真の並行編集
    for (int op = 0; op < 60; op++) {
      Replica& r = *reps[rng() % reps.size()];
      const std::string& k = keys[rng() % keys.size()];
      if (rng() % 4 == 0) {
        r.map.remove(k);
      } else {
        r.map.set(k, "\"v" + std::to_string(rng() % 100) + "\"");
      }
      if (rng() % 2 == 0) r.clock.advance(rng() % 3);  // 進めない時もある → 同一 ms 衝突を作る
    }
    // 全 entry を集め、各レプリカへ「異なるシャッフル順 + 約3割の重複」で配送
    std::vector<LwwEntry> pool;
    for (auto& r : reps) pool.insert(pool.end(), r->published.begin(), r->published.end());
    for (auto& r : reps) {
      std::vector<LwwEntry> feed = pool;
      for (const auto& e : pool) {
        if (rng() % 10 < 3) feed.push_back(e);
      }
      std::shuffle(feed.begin(), feed.end(), rng);
      for (const auto& e : feed) r->map.applyRemote(e);
    }
    CHECK(sameState(reps[0]->map, reps[1]->map));
    CHECK(sameState(reps[1]->map, reps[2]->map));
    for (const auto& k : keys) {
      CHECK(reps[0]->map.get(k) == reps[1]->map.get(k));
      CHECK(reps[1]->map.get(k) == reps[2]->map.get(k));
    }
  }
}

TEST_CASE("交換律・冪等・結合律") {
  Replica a(kIdA, 1000);
  Replica b(kIdB, 2000);
  const LwwEntry e1 = a.map.set("k", "\"1\"");
  a.clock.advance(1);
  const LwwEntry e2 = a.map.set("k", "\"2\"");  // e1 を上書き
  const LwwEntry e3 = b.map.set("k", "\"3\"");  // 物理時刻最大 → 全体の勝者

  // 交換律: 適用順が違っても同一状態
  Replica x("dddd000000000000", 0);
  Replica y("eeee000000000000", 0);
  CHECK(x.map.applyRemote(e1));
  CHECK(x.map.applyRemote(e2));
  CHECK(x.map.applyRemote(e3));
  CHECK(y.map.applyRemote(e3));
  CHECK_FALSE(y.map.applyRemote(e1));  // 既に新しい勝者 → 状態不変
  CHECK_FALSE(y.map.applyRemote(e2));
  CHECK(sameState(x.map, y.map));
  CHECK(x.map.get("k") == std::optional<std::string>("\"3\""));
  // 状態が変わらなくても vv は前進している
  CHECK(y.map.versionVector().at(kIdA) == 2);

  // 冪等: 二重適用で不変 (false を返し状態も vv も変わらない)
  auto vv_before = x.map.versionVector();
  CHECK_FALSE(x.map.applyRemote(e3));
  CHECK_FALSE(x.map.applyRemote(e1));
  CHECK(x.map.versionVector() == vv_before);
  CHECK(sameState(x.map, y.map));

  // 結合律: バッチの区切り方が違っても同一 — (e1,e2)+e3 と e2+(e1,e3)
  Replica z("ffff000000000000", 0);
  z.map.applyRemote(e2);
  z.map.applyRemote(e1);
  z.map.applyRemote(e3);
  CHECK(sameState(z.map, x.map));
}

TEST_CASE("同時書き込み: 同一 hlc 物理部でも author で決定的勝者") {
  Replica a(kIdA, 5000);
  Replica b(kIdB, 5000);  // 同じ壁時計
  const LwwEntry ea = a.map.set("door.label", "\"A\"");
  const LwwEntry eb = b.map.set("door.label", "\"B\"");
  // 物理 ms・カウンタが完全一致していることを確認 (node8 と author だけが違う)
  int64_t ms_a = 0, ms_b = 0;
  int c_a = 0, c_b = 0;
  REQUIRE(HlcClock::parse(ea.hlc, &ms_a, &c_a, nullptr));
  REQUIRE(HlcClock::parse(eb.hlc, &ms_b, &c_b, nullptr));
  CHECK(ms_a == ms_b);
  CHECK(c_a == c_b);
  // 相互適用: (hlc, author) が大きい b が両側で勝つ
  CHECK(a.map.applyRemote(eb));
  CHECK_FALSE(b.map.applyRemote(ea));
  CHECK(a.map.get("door.label") == std::optional<std::string>("\"B\""));
  CHECK(b.map.get("door.label") == std::optional<std::string>("\"B\""));
  CHECK(sameState(a.map, b.map));
  // 第三者がどちらの順で受けても同じ勝者
  Replica c(kIdC, 0);
  Replica d("dddd000000000000", 0);
  c.map.applyRemote(ea);
  c.map.applyRemote(eb);
  d.map.applyRemote(eb);
  d.map.applyRemote(ea);
  CHECK(sameState(c.map, d.map));
  CHECK(c.map.get("door.label") == std::optional<std::string>("\"B\""));
}

TEST_CASE("deltaSince と versionVector の整合") {
  Replica a(kIdA, 1000);
  Replica b(kIdB, 1000);
  a.map.set("x", "1");
  a.clock.advance(1);
  a.map.set("x", "2");  // seq2 が seq1 を上書き → delta に seq1 は現れない
  a.clock.advance(1);
  a.map.set("y", "3");
  b.map.set("z", "9");

  auto delta = a.map.deltaSince(b.map.versionVector());
  REQUIRE(delta.size() == 2);
  // (author, seq) 昇順の決定的順序
  CHECK(delta[0].seq == 2);
  CHECK(delta[1].seq == 3);
  // 逆順適用 (順序逆転: seq3 の後に seq2 が届く) でも vv は max で追いつく
  for (auto it = delta.rbegin(); it != delta.rend(); ++it) b.map.applyRemote(*it);
  CHECK(b.map.versionVector().at(kIdA) == 3);
  // 追いついたら delta は空
  CHECK(a.map.deltaSince(b.map.versionVector()).empty());
  // 逆方向も同期すれば相互に空 = 完全一致
  for (const auto& e : b.map.deltaSince(a.map.versionVector())) a.map.applyRemote(e);
  CHECK(b.map.deltaSince(a.map.versionVector()).empty());
  CHECK(sameState(a.map, b.map));
}

TEST_CASE("materializeJson: 入れ子構築・リーフとプレフィックスの衝突・日本語値") {
  Replica a(kIdA, 1000);
  a.map.set("doors.front.label", "\"玄関\"");
  a.map.set("doors.front.volume", "7");
  a.map.set("doors.back.label", "\"裏口\"");
  a.map.set("name", "\"我が家\"");
  a.map.set("memo", "パース不能な生テキスト");  // JSON として不正 → 文字列で埋める
  a.map.set("net", "\"wifi\"");                 // リーフ…
  a.map.set("net.ssid", "\"ap-1\"");            // …とプレフィックスの衝突 → 深いパス優先
  a.map.set("gone", "1");
  a.map.remove("gone");  // tombstone は出力しない

  auto doc = json::parse(a.map.materializeJson());
  REQUIRE(doc);
  cJSON* doors = json::get(doc.get(), "doors");
  REQUIRE(doors);
  CHECK(json::getString(json::get(doors, "front"), "label") == "玄関");
  CHECK(json::getInt(json::get(doors, "front"), "volume") == 7);
  CHECK(json::getString(json::get(doors, "back"), "label") == "裏口");
  CHECK(json::getString(doc.get(), "name") == "我が家");
  CHECK(json::getString(doc.get(), "memo") == "パース不能な生テキスト");
  cJSON* net = json::get(doc.get(), "net");
  REQUIRE(net);
  CHECK(cJSON_IsObject(net));  // 深いパス優先で "wifi" はオブジェクトに置換されている
  CHECK(json::getString(net, "ssid") == "ap-1");
  CHECK(json::get(doc.get(), "gone") == nullptr);

  // prefix 指定は部分木 (prefix を取り除いたパス) を返す
  auto sub = json::parse(a.map.materializeJson("doors."));
  REQUIRE(sub);
  CHECK(json::getString(json::get(sub.get(), "front"), "label") == "玄関");
  CHECK(json::get(sub.get(), "name") == nullptr);

  // byPrefix も確認 (tombstone 除外・key 昇順)
  auto pairs = a.map.byPrefix("doors.front.");
  REQUIRE(pairs.size() == 2);
  CHECK(pairs[0].first == "doors.front.label");
  CHECK(pairs[1].first == "doors.front.volume");
  CHECK(a.map.byPrefix("gone").empty());
}

TEST_CASE("gcTombstones: 被覆判定と時刻条件") {
  Replica a(kIdA, 1000);
  a.map.set("k1", "1");  // seq1
  a.clock.advance(1);
  const LwwEntry t1 = a.map.remove("k1");  // seq2 tombstone
  a.clock.advance(1);
  const LwwEntry t2 = a.map.remove("k2");  // seq3 tombstone (より新しい)
  a.clock.advance(1);
  const std::string cutoff = a.hlc.tick();  // t1/t2 より新しい刻印
  CHECK_FALSE(a.map.get("k1").has_value());

  // 被覆が seq2 まで → t1 だけが対象 (t2 は seq3 未被覆で残る)
  VersionVector vv_partial{{kIdA, 2}};
  CHECK(a.map.gcTombstones(vv_partial, cutoff) == 1);
  REQUIRE(a.map.all().size() == 1);
  CHECK(a.map.all()[0].key == "k2");
  // 被覆はあるが hlc < older_than が成り立たない (同値) → 残る
  VersionVector vv_full{{kIdA, 3}};
  CHECK(a.map.gcTombstones(vv_full, t2.hlc) == 0);
  // 両条件成立で消える
  CHECK(a.map.gcTombstones(vv_full, cutoff) == 1);
  CHECK(a.map.all().empty());
  // author 不在の vv は被覆ゼロ扱い
  Replica b(kIdB, 1000);
  b.map.remove("k");
  b.clock.advance(10);
  CHECK(b.map.gcTombstones(VersionVector{}, b.hlc.tick()) == 0);
  CHECK(b.map.all().size() == 1);
}

TEST_CASE("load: on_change 無し・self seq 継続・HLC 逆行防止") {
  Replica a(kIdA, 5000);
  a.map.set("k1", "1");
  a.clock.advance(1);
  a.map.set("k2", "2");
  a.clock.advance(1);
  a.map.remove("k1");  // seq3
  // 別 author の entry も混ぜる
  Replica b(kIdB, 6000);
  const LwwEntry eb = b.map.set("k3", "3");
  a.map.applyRemote(eb);
  const auto snapshot = a.map.all();

  // 「再起動」: 壁時計が大幅に過去へ巻き戻った状態で復元
  SimClock clock2(100);
  HlcClock hlc2(clock2, kIdA);
  LwwMap m2(kIdA, hlc2);
  int cb_count = 0;
  m2.onChange([&](const LwwEntry&, bool) { cb_count++; });
  m2.load(snapshot);
  CHECK(cb_count == 0);  // load は on_change を呼ばない
  CHECK(sameState(m2, a.map));

  // 採番が巻き戻らない: 次のローカル書き込みは seq4
  const LwwEntry e4 = m2.set("k4", "4");
  CHECK(e4.seq == 4);
  CHECK(m2.versionVector().at(kIdA) == 4);
  CHECK(cb_count == 1);
  // 巻き戻った壁時計でも新規刻印は復元済みのどの刻印よりも新しい
  std::string max_hlc;
  for (const auto& e : snapshot) max_hlc = std::max(max_hlc, e.hlc);
  CHECK(e4.hlc > max_hlc);
}
