
#include <algorithm>
#include <memory>
#include <optional>
#include <random>
#include <set>
#include <vector>

#include "crdt/lww_map.h"
#include "doctest.h"
#include "util/clock.h"
#include "util/json.h"

using namespace db;

namespace {


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

TEST_CASE("CRDT convergence: three replicas agree after shuffled duplicate operations") {
  const std::vector<std::string> keys = {"a",  "a.b",       "doors.front.label",
                                         "nm", "doors.vol", "doors.front.ring"};
  for (uint32_t seed = 1; seed <= 24; seed++) {
    CAPTURE(seed);
    std::mt19937 rng(seed);
    std::vector<std::unique_ptr<Replica>> reps;
    reps.push_back(std::make_unique<Replica>(kIdA, 1'000'000));
    reps.push_back(std::make_unique<Replica>(kIdB, 1'000'500));
    reps.push_back(std::make_unique<Replica>(kIdC, 999'700));

    for (int op = 0; op < 60; op++) {
      Replica& r = *reps[rng() % reps.size()];
      const std::string& k = keys[rng() % keys.size()];
      if (rng() % 4 == 0) {
        r.map.remove(k);
      } else {
        r.map.set(k, "\"v" + std::to_string(rng() % 100) + "\"");
      }
      if (rng() % 2 == 0) r.clock.advance(rng() % 3);
    }

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

TEST_CASE("CRDT merge is commutative, idempotent, and associative") {
  Replica a(kIdA, 1000);
  Replica b(kIdB, 2000);
  const LwwEntry e1 = a.map.set("k", "\"1\"");
  a.clock.advance(1);
  const LwwEntry e2 = a.map.set("k", "\"2\"");
  const LwwEntry e3 = b.map.set("k", "\"3\"");


  Replica x("dddd000000000000", 0);
  Replica y("eeee000000000000", 0);
  CHECK(x.map.applyRemote(e1));
  CHECK(x.map.applyRemote(e2));
  CHECK(x.map.applyRemote(e3));
  CHECK(y.map.applyRemote(e3));
  CHECK_FALSE(y.map.applyRemote(e1));
  CHECK_FALSE(y.map.applyRemote(e2));
  CHECK(sameState(x.map, y.map));
  CHECK(x.map.get("k") == std::optional<std::string>("\"3\""));

  CHECK(y.map.versionVector().at(kIdA) == 2);


  auto vv_before = x.map.versionVector();
  CHECK_FALSE(x.map.applyRemote(e3));
  CHECK_FALSE(x.map.applyRemote(e1));
  CHECK(x.map.versionVector() == vv_before);
  CHECK(sameState(x.map, y.map));


  Replica z("ffff000000000000", 0);
  z.map.applyRemote(e2);
  z.map.applyRemote(e1);
  z.map.applyRemote(e3);
  CHECK(sameState(z.map, x.map));
}

TEST_CASE("concurrent writes use the author as a deterministic HLC tie-breaker") {
  Replica a(kIdA, 5000);
  Replica b(kIdB, 5000);
  const LwwEntry ea = a.map.set("door.label", "\"A\"");
  const LwwEntry eb = b.map.set("door.label", "\"B\"");

  int64_t ms_a = 0, ms_b = 0;
  int c_a = 0, c_b = 0;
  REQUIRE(HlcClock::parse(ea.hlc, &ms_a, &c_a, nullptr));
  REQUIRE(HlcClock::parse(eb.hlc, &ms_b, &c_b, nullptr));
  CHECK(ms_a == ms_b);
  CHECK(c_a == c_b);

  CHECK(a.map.applyRemote(eb));
  CHECK_FALSE(b.map.applyRemote(ea));
  CHECK(a.map.get("door.label") == std::optional<std::string>("\"B\""));
  CHECK(b.map.get("door.label") == std::optional<std::string>("\"B\""));
  CHECK(sameState(a.map, b.map));

  Replica c(kIdC, 0);
  Replica d("dddd000000000000", 0);
  c.map.applyRemote(ea);
  c.map.applyRemote(eb);
  d.map.applyRemote(eb);
  d.map.applyRemote(ea);
  CHECK(sameState(c.map, d.map));
  CHECK(c.map.get("door.label") == std::optional<std::string>("\"B\""));
}

TEST_CASE("remote batches expose all winners in one callback") {
  Replica source(kIdA, 5'000);
  std::vector<LwwEntry> batch = source.map.mutate({
      {"devices.panel.local.ui.elements.ring.title", R"({"scale":1.25})", false},
      {"devices.panel.local.ui.elements.ring.action", R"({"scale":1.25})", false}});
  REQUIRE(batch.size() == 2);

  SimClock clock(5'000);
  HlcClock hlc(clock, kIdB);
  LwwMap target(kIdB, hlc);
  int callbacks = 0;
  size_t callback_size = 0;
  bool complete_snapshot = false;
  target.onBatchChange([&](const std::vector<LwwEntry>& changed, bool is_local) {
    ++callbacks;
    callback_size = changed.size();
    complete_snapshot = !is_local &&
        target.get("devices.panel.local.ui.elements.ring.title").has_value() &&
        target.get("devices.panel.local.ui.elements.ring.action").has_value();
  });
  const auto changed = target.applyRemoteBatch(batch);
  CHECK(changed.size() == 2);
  CHECK(callbacks == 1);
  CHECK(callback_size == 2);
  CHECK(complete_snapshot);

  CHECK(target.applyRemoteBatch(batch).empty());
  CHECK(callbacks == 1);
}

TEST_CASE("persistence rejection rolls back local state and sequence allocation") {
  SimClock clock(5'000);
  HlcClock hlc(clock, kIdA);
  LwwMap map(kIdA, hlc);
  int observer_calls = 0;
  bool accept = false;
  map.onCommit([&](const std::vector<LwwEntry>&, bool, bool) { return accept; });
  map.onChange([&](const LwwEntry&, bool) { ++observer_calls; });

  const LwwEntry rejected = map.set("cluster.name", R"("not durable")");
  CHECK_FALSE(map.lastMutationCommitted());
  CHECK_FALSE(map.get("cluster.name").has_value());
  CHECK(map.versionVector().empty());
  CHECK(observer_calls == 0);

  accept = true;
  const LwwEntry committed = map.set("cluster.name", R"("durable")");
  CHECK(map.lastMutationCommitted());
  CHECK(committed.seq == rejected.seq);
  CHECK(committed.seq == 1);
  CHECK(map.versionVector().at(kIdA) == 1);
  CHECK(map.get("cluster.name") == std::optional<std::string>(R"("durable")"));
  CHECK(observer_calls == 1);

  accept = false;
  map.remove("cluster.name");
  CHECK_FALSE(map.lastMutationCommitted());
  CHECK(map.get("cluster.name") == std::optional<std::string>(R"("durable")"));
  CHECK(map.versionVector().at(kIdA) == 1);
  CHECK(observer_calls == 1);
}

TEST_CASE("persistence rejection rolls back complete local and remote batches") {
  Replica source(kIdA, 6'000);
  const auto remote = source.map.mutate({
      {"doors.front.label", R"("Front")", false},
      {"doors.front.volume", "7", false}});
  REQUIRE(remote.size() == 2);

  SimClock clock(6'000);
  HlcClock hlc(clock, kIdB);
  LwwMap target(kIdB, hlc);
  bool accept = false;
  int observer_calls = 0;
  target.onCommit([&](const std::vector<LwwEntry>&, bool, bool) { return accept; });
  target.onBatchChange([&](const std::vector<LwwEntry>&, bool) { ++observer_calls; });

  CHECK(target.applyRemoteBatch(remote).empty());
  CHECK_FALSE(target.lastMutationCommitted());
  CHECK(target.all().empty());
  CHECK(target.versionVector().empty());
  CHECK(observer_calls == 0);

  accept = true;
  CHECK(target.applyRemoteBatch(remote).size() == 2);
  CHECK(target.versionVector().at(kIdA) == 2);
  CHECK(observer_calls == 1);

  accept = false;
  const auto before = target.all();
  CHECK(target.mutate({{"local.a", "1", false}, {"local.b", "2", false}}).empty());
  CHECK_FALSE(target.lastMutationCommitted());
  CHECK(target.all().size() == before.size());
  const auto rolled_back_vv = target.versionVector();
  CHECK(rolled_back_vv.find(kIdB) == rolled_back_vv.end());
  CHECK(observer_calls == 1);
}

TEST_CASE("persistence rejection preserves remote out-of-order frontier bookkeeping") {
  Replica source(kIdA, 7'000);
  const LwwEntry first = source.map.set("a", "1");
  source.clock.advance(1);
  const LwwEntry second = source.map.set("b", "2");

  SimClock clock(7'000);
  HlcClock hlc(clock, kIdB);
  LwwMap target(kIdB, hlc);
  bool accept = true;
  target.onCommit([&](const std::vector<LwwEntry>&, bool, bool) { return accept; });
  REQUIRE(target.applyRemote(second));
  CHECK(target.versionVector().at(kIdA) == 0);

  accept = false;
  CHECK_FALSE(target.applyRemote(first));
  CHECK_FALSE(target.lastMutationCommitted());
  CHECK(target.versionVector().at(kIdA) == 0);
  CHECK_FALSE(target.get("a").has_value());
  CHECK(target.get("b") == std::optional<std::string>("2"));

  accept = true;
  CHECK(target.applyRemote(first));
  CHECK(target.versionVector().at(kIdA) == 2);
}

TEST_CASE("deltaSince is consistent with the version vector") {
  Replica a(kIdA, 1000);
  Replica b(kIdB, 1000);
  a.map.set("x", "1");
  a.clock.advance(1);
  a.map.set("w", "2");
  a.clock.advance(1);
  a.map.set("y", "3");
  b.map.set("z", "9");

  auto delta = a.map.deltaSince(b.map.versionVector());
  REQUIRE(delta.size() == 3);

  CHECK(delta[0].seq == 1);
  CHECK(delta[1].seq == 2);
  CHECK(delta[2].seq == 3);

  for (auto it = delta.rbegin(); it != delta.rend(); ++it) b.map.applyRemote(*it);
  CHECK(b.map.versionVector().at(kIdA) == 3);

  CHECK(a.map.deltaSince(b.map.versionVector()).empty());

  for (const auto& e : b.map.deltaSince(a.map.versionVector())) a.map.applyRemote(e);
  CHECK(b.map.deltaSince(a.map.versionVector()).empty());
  CHECK(sameState(a.map, b.map));
}

TEST_CASE("version vectors do not cover delayed mutations across sequence gaps") {
  Replica source(kIdA, 1'000);
  const LwwEntry first = source.map.set("doors.front.label", R"("Front")");
  source.clock.advance(1);
  const LwwEntry second = source.map.set("doors.front.volume", "7");

  Replica target(kIdB, 1'000);
  CHECK(target.map.applyRemote(second));
  CHECK(target.map.versionVector().at(kIdA) == 0);

  const auto repair = source.map.deltaSince(target.map.versionVector());
  REQUIRE(repair.size() == 2);
  CHECK(repair[0].seq == first.seq);
  CHECK(repair[1].seq == second.seq);

  CHECK(target.map.applyRemote(first));
  CHECK(target.map.versionVector().at(kIdA) == 2);
  CHECK(source.map.deltaSince(target.map.versionVector()).empty());
  CHECK(sameState(source.map, target.map));
}

TEST_CASE("complete snapshots acknowledge compacted same-key sequences across restart") {
  Replica source(kIdA, 1'500);
  source.map.set("doors.front.label", R"("Old")");
  source.clock.advance(1);
  const LwwEntry winner = source.map.set("doors.front.label", R"("Current")");
  const auto compacted = source.map.deltaSince({});
  REQUIRE(compacted.size() == 1);
  CHECK(compacted.front().seq == 2);

  SimClock target_clock(1'500);
  HlcClock target_hlc(target_clock, kIdB);
  LwwMap target(kIdB, target_hlc);
  std::map<std::string, LwwEntry> persisted;
  int commits = 0;
  int observer_calls = 0;
  target.onCommit([&](const std::vector<LwwEntry>& entries, bool is_local, bool batch) {
    CHECK_FALSE(is_local);
    CHECK(batch);
    REQUIRE(entries.size() == 2);
    ++commits;
    for (const auto& entry : entries) persisted[entry.key] = entry;
    return true;
  });
  target.onBatchChange([&](const std::vector<LwwEntry>& entries, bool is_local) {
    CHECK_FALSE(is_local);
    REQUIRE(entries.size() == 1);
    CHECK(entries.front().key == "doors.front.label");
    ++observer_calls;
  });

  const auto changed = target.applyRemoteSnapshot(compacted, source.map.versionVector());
  REQUIRE(changed.size() == 1);
  CHECK(sameEntry(changed.front(), winner));
  CHECK(target.versionVector().at(kIdA) == 2);
  CHECK(source.map.deltaSince(target.versionVector()).empty());
  CHECK(target.all().size() == 1);
  CHECK(target.materializeJson().find("__doorbell_internal") == std::string::npos);
  CHECK(persisted.size() == 2);
  CHECK(observer_calls == 1);
  const auto marker = std::find_if(persisted.begin(), persisted.end(), [](const auto& item) {
    return item.first.find("__doorbell_internal.crdt_coverage.") == 0;
  });
  REQUIRE(marker != persisted.end());
  CHECK(marker->second.deleted);
  CHECK(marker->second.seq == 0);
  const auto visible_delta = target.deltaSince({});
  REQUIRE(visible_delta.size() == 1);
  CHECK(visible_delta.front().key == "doors.front.label");

  CHECK(target.applyRemoteSnapshot(source.map.deltaSince(target.versionVector()),
                                   source.map.versionVector()).empty());
  CHECK(commits == 1);
  CHECK(observer_calls == 1);

  std::vector<LwwEntry> durable_rows;
  for (const auto& [key, entry] : persisted) durable_rows.push_back(entry);
  SimClock restarted_clock(10);
  HlcClock restarted_hlc(restarted_clock, kIdB);
  LwwMap restarted(kIdB, restarted_hlc);
  restarted.load(durable_rows);
  CHECK(restarted.get("doors.front.label") == std::optional<std::string>(R"("Current")"));
  CHECK(restarted.versionVector().at(kIdA) == 2);
  CHECK(restarted.all().size() == 1);
  CHECK(source.map.deltaSince(restarted.versionVector()).empty());
}

TEST_CASE("a complete snapshot repairs different-key state before acknowledging its frontier") {
  Replica source(kIdA, 1'600);
  const LwwEntry first = source.map.set("first.key", "1");
  source.clock.advance(1);
  const LwwEntry second = source.map.set("second.key", "2");

  Replica target(kIdB, 1'600);
  REQUIRE(target.map.applyRemote(second));
  CHECK(target.map.versionVector().at(kIdA) == 0);
  CHECK_FALSE(target.map.get("first.key").has_value());

  const auto complete_delta = source.map.deltaSince(target.map.versionVector());
  REQUIRE(complete_delta.size() == 2);
  CHECK(complete_delta.front().seq == first.seq);
  REQUIRE(target.map.applyRemoteSnapshot(complete_delta, source.map.versionVector()).size() == 1);
  CHECK(target.map.get("first.key") == std::optional<std::string>("1"));
  CHECK(target.map.get("second.key") == std::optional<std::string>("2"));
  CHECK(target.map.versionVector().at(kIdA) == 2);
  CHECK(source.map.deltaSince(target.map.versionVector()).empty());
}

TEST_CASE("a losing remote repair durably closes a same-key sequence gap") {
  Replica source(kIdA, 1'625);
  const LwwEntry first = source.map.set("same.key", "1");
  source.clock.advance(1);
  const LwwEntry second = source.map.set("same.key", "2");

  SimClock target_clock(1'625);
  HlcClock target_hlc(target_clock, kIdB);
  LwwMap target(kIdB, target_hlc);
  std::map<std::string, LwwEntry> persisted;
  target.onCommit([&](const std::vector<LwwEntry>& entries, bool, bool) {
    for (const auto& entry : entries) persisted[entry.key] = entry;
    return true;
  });

  REQUIRE(target.applyRemote(second));
  CHECK(target.versionVector().at(kIdA) == 0);
  CHECK_FALSE(target.applyRemote(first));
  CHECK(target.lastMutationCommitted());
  CHECK(target.versionVector().at(kIdA) == 2);
  CHECK(persisted.size() == 2);

  std::vector<LwwEntry> durable_rows;
  for (const auto& [key, entry] : persisted) durable_rows.push_back(entry);
  SimClock restarted_clock(10);
  HlcClock restarted_hlc(restarted_clock, kIdB);
  LwwMap restarted(kIdB, restarted_hlc);
  restarted.load(durable_rows);
  CHECK(restarted.get("same.key") == std::optional<std::string>("2"));
  CHECK(restarted.versionVector().at(kIdA) == 2);
  CHECK(source.map.deltaSince(restarted.versionVector()).empty());
}

TEST_CASE("snapshot coverage rolls back atomically when persistence rejects it") {
  Replica source(kIdA, 1'750);
  source.map.set("same.key", "1");
  source.clock.advance(1);
  source.map.set("same.key", "2");

  SimClock target_clock(1'750);
  HlcClock target_hlc(target_clock, kIdB);
  LwwMap target(kIdB, target_hlc);
  bool accept = false;
  target.onCommit([&](const std::vector<LwwEntry>&, bool, bool) { return accept; });

  CHECK(target.applyRemoteSnapshot(source.map.all(), source.map.versionVector()).empty());
  CHECK_FALSE(target.lastMutationCommitted());
  CHECK(target.all().empty());
  CHECK(target.versionVector().empty());

  accept = true;
  REQUIRE(target.applyRemoteSnapshot(source.map.all(), source.map.versionVector()).size() == 1);
  CHECK(target.lastMutationCommitted());
  CHECK(target.versionVector().at(kIdA) == 2);
}

TEST_CASE("restart preserves remote gaps and a batch repair closes independent frontiers") {
  Replica source_a(kIdA, 2'000);
  const LwwEntry a1 = source_a.map.set("devices.panel-a.ui.scale", "1.0");
  source_a.clock.advance(1);
  const LwwEntry a2 = source_a.map.set("devices.panel-a.ui.color", R"("#ffffff")");

  Replica source_c(kIdC, 2'000);
  const LwwEntry c1 = source_c.map.set("devices.panel-c.ui.scale", "1.25");
  source_c.clock.advance(1);
  const LwwEntry c2 = source_c.map.set("devices.panel-c.ui.color", R"("#000000")");

  Replica before_restart(kIdB, 2'000);
  REQUIRE(before_restart.map.applyRemoteBatch({a2, c2}).size() == 2);
  CHECK(before_restart.map.versionVector().at(kIdA) == 0);
  CHECK(before_restart.map.versionVector().at(kIdC) == 0);

  SimClock restarted_clock(100);
  HlcClock restarted_hlc(restarted_clock, kIdB);
  LwwMap restarted(kIdB, restarted_hlc);
  restarted.load(before_restart.map.all());
  CHECK(restarted.versionVector().at(kIdA) == 0);
  CHECK(restarted.versionVector().at(kIdC) == 0);

  int callbacks = 0;
  size_t callback_size = 0;
  restarted.onBatchChange([&](const std::vector<LwwEntry>& changed, bool is_local) {
    CHECK_FALSE(is_local);
    ++callbacks;
    callback_size = changed.size();
  });
  const auto changed = restarted.applyRemoteBatch({c2, a2, c1, a1});
  CHECK(changed.size() == 2);
  CHECK(callbacks == 1);
  CHECK(callback_size == 2);
  CHECK(restarted.versionVector().at(kIdA) == 2);
  CHECK(restarted.versionVector().at(kIdC) == 2);
  CHECK(source_a.map.deltaSince(restarted.versionVector()).empty());
  CHECK(source_c.map.deltaSince(restarted.versionVector()).empty());
}

TEST_CASE("materializeJson handles nesting, prefix conflicts, and localized values") {
  Replica a(kIdA, 1000);
  a.map.set("doors.front.label", "\"玄関\"");
  a.map.set("doors.front.volume", "7");
  a.map.set("doors.back.label", "\"裏口\"");
  a.map.set("name", "\"我が家\"");
  a.map.set("memo", "パース不能な生テキスト");
  a.map.set("net", "\"wifi\"");
  a.map.set("net.ssid", "\"ap-1\"");
  a.map.set("gone", "1");
  a.map.remove("gone");

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
  CHECK(cJSON_IsObject(net));
  CHECK(json::getString(net, "ssid") == "ap-1");
  CHECK(json::get(doc.get(), "gone") == nullptr);


  auto sub = json::parse(a.map.materializeJson("doors."));
  REQUIRE(sub);
  CHECK(json::getString(json::get(sub.get(), "front"), "label") == "玄関");
  CHECK(json::get(sub.get(), "name") == nullptr);


  auto pairs = a.map.byPrefix("doors.front.");
  REQUIRE(pairs.size() == 2);
  CHECK(pairs[0].first == "doors.front.label");
  CHECK(pairs[1].first == "doors.front.volume");
  CHECK(a.map.byPrefix("gone").empty());
}

TEST_CASE("gcTombstones respects coverage and age requirements") {
  Replica a(kIdA, 1000);
  a.map.set("k1", "1");  // seq1
  a.clock.advance(1);
  const LwwEntry t1 = a.map.remove("k1");  // seq2 tombstone
  a.clock.advance(1);
  const LwwEntry t2 = a.map.remove("k2");
  a.clock.advance(1);
  const std::string cutoff = a.hlc.tick();
  CHECK_FALSE(a.map.get("k1").has_value());


  VersionVector vv_partial{{kIdA, 2}};
  CHECK(a.map.gcTombstones(vv_partial, cutoff) == 1);
  REQUIRE(a.map.all().size() == 1);
  CHECK(a.map.all()[0].key == "k2");

  VersionVector vv_full{{kIdA, 3}};
  CHECK(a.map.gcTombstones(vv_full, t2.hlc) == 0);

  CHECK(a.map.gcTombstones(vv_full, cutoff) == 1);
  CHECK(a.map.all().empty());

  Replica b(kIdB, 1000);
  b.map.remove("k");
  b.clock.advance(10);
  CHECK(b.map.gcTombstones(VersionVector{}, b.hlc.tick()) == 0);
  CHECK(b.map.all().size() == 1);
}

TEST_CASE("load avoids callbacks, continues local sequence, and prevents HLC regression") {
  Replica a(kIdA, 5000);
  a.map.set("k1", "1");
  a.clock.advance(1);
  a.map.set("k2", "2");
  a.clock.advance(1);
  a.map.remove("k1");  // seq3

  Replica b(kIdB, 6000);
  const LwwEntry eb = b.map.set("k3", "3");
  a.map.applyRemote(eb);
  const auto snapshot = a.map.all();


  SimClock clock2(100);
  HlcClock hlc2(clock2, kIdA);
  LwwMap m2(kIdA, hlc2);
  int cb_count = 0;
  m2.onChange([&](const LwwEntry&, bool) { cb_count++; });
  m2.load(snapshot);
  CHECK(cb_count == 0);
  CHECK(sameState(m2, a.map));


  const LwwEntry e4 = m2.set("k4", "4");
  CHECK(e4.seq == 4);
  CHECK(m2.versionVector().at(kIdA) == 4);
  CHECK(cb_count == 1);

  std::string max_hlc;
  for (const auto& e : snapshot) max_hlc = std::max(max_hlc, e.hlc);
  CHECK(e4.hlc > max_hlc);
}
