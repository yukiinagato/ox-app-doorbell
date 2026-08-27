// Mesh の統合テスト。SimClock + Runloop manual モード + InMemNet で決定的にシミュレーションする。
// タイミングは縮小 (heartbeat 30ms / suspect 90 / dead 150 / gossip 50 / sync 50 / claim_ttl 300)。
#include <algorithm>
#include <array>
#include <map>
#include <memory>
#include <random>
#include <string>
#include <utility>
#include <vector>

#include "crdt/lww_map.h"
#include "doctest.h"
#include "events/events.h"
#include "mesh/mesh.h"
#include "mesh/tcp_transport.h"
#include "mesh/udp_beacon.h"
#include "store/store.h"
#include "util/clock.h"
#include "util/common.h"
#include "util/hlc.h"
#include "util/json.h"
#include "util/log.h"
#include "util/runloop.h"

#include <unistd.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>

using namespace db;

namespace {

const std::string kIdA(32, 'a');
const std::string kIdB(32, 'b');
const std::string kIdC(32, 'c');
const std::string kIdJ(32, 'e');  // joiner

std::array<uint8_t, 32> mkPsk(uint8_t fill = 0x5a) {
  std::array<uint8_t, 32> k{};
  k.fill(fill);
  return k;
}

std::string capsJson(int cpu, bool tls = true, bool wan = true, bool mains = true,
                     bool mqtt = true, bool sane = true) {
  auto o = json::obj();
  json::setBool(o.get(), "tls12", tls);
  json::setBool(o.get(), "wan", wan);
  json::setBool(o.get(), "mains_power", mains);
  json::setBool(o.get(), "mqtt_reachable", mqtt);
  json::setBool(o.get(), "wall_clock_sane", sane);
  json::set(o.get(), "cpu_score", int64_t{cpu});
  return json::dump(o.get());
}

// ノード追加オプション (Fleet::add)
struct Opt {
  std::vector<std::string> seeds;
  bool beacon = true;
  uint64_t epoch = 1;
  bool zero_psk = false;
};

// ---- フリート: SimClock/Runloop/InMemNet を共有するノード群 ----
struct Fleet {
  SimClock clock{1'700'000'000'000LL, 0};
  Runloop loop{clock};
  InMemNet net{loop};
  std::array<uint8_t, 32> psk = mkPsk();

  struct Node {
    std::string id, addr;
    Store store;
    std::unique_ptr<HlcClock> hlc;
    std::unique_ptr<LwwMap> config;
    std::unique_ptr<EventLog> events;
    std::unique_ptr<ITransport> tp;
    std::unique_ptr<IDiscovery> disc;
    // 観測
    int remote_events = 0;  // Mesh cbs.on_event の発火回数
    std::vector<EventRecord> received;
    std::vector<std::pair<std::string, bool>> alive_changes;
    std::vector<std::pair<std::string, std::string>> leader_changes;
    std::vector<std::pair<std::string, std::string>> commands;
    // mesh は最後 (先に破棄されるように)
    std::unique_ptr<Mesh> mesh;

    PeerInfo peer(const std::string& pid) const {
      for (const auto& p : mesh->peers()) {
        if (p.id == pid) return p;
      }
      return {};
    }
    bool sawAlive(const std::string& pid, bool alive) const {
      return std::find(alive_changes.begin(), alive_changes.end(),
                       std::make_pair(pid, alive)) != alive_changes.end();
    }
  };
  std::map<std::string, std::unique_ptr<Node>> nodes;

  Fleet() { setLogMinLevel(LogLevel::Warn); }

  Node& add(const std::string& id, const std::string& addr, const std::string& caps,
            Opt opt = {}) {
    auto n = std::make_unique<Node>();
    Node* np = n.get();
    n->id = id;
    n->addr = addr;
    REQUIRE(n->store.open(":memory:"));
    n->hlc = std::make_unique<HlcClock>(clock, id.substr(0, 8));
    n->config = std::make_unique<LwwMap>(id, *n->hlc);
    n->events = std::make_unique<EventLog>(id, *n->hlc, n->store);
    n->events->loadHeads();
    n->tp = net.makeTransport(addr);
    if (opt.beacon) n->disc = net.makeDiscovery(addr);

    MeshSettings st;
    st.node_id = id;
    st.epoch = opt.epoch;
    st.listen_addr = addr;
    st.advertise_addr = addr;
    st.seed_peers = opt.seeds;
    st.psk = opt.zero_psk ? std::array<uint8_t, 32>{} : psk;
    st.caps_json = caps;
    st.heartbeat_ms = 30;
    st.suspect_ms = 90;
    st.dead_ms = 150;
    st.gossip_ms = 50;
    st.sync_ms = 50;
    st.claim_ttl_ms = 300;
    st.reconnect_ms = 50;
    st.max_neighbors = 4;

    Mesh::Callbacks cbs;
    cbs.on_peer_alive_changed = [np](const std::string& pid, bool alive) {
      np->alive_changes.emplace_back(pid, alive);
    };
    cbs.on_leader_changed = [np](const std::string& duty, const std::string& leader) {
      np->leader_changes.emplace_back(duty, leader);
    };
    cbs.on_event = [np](const EventRecord& ev) {
      np->remote_events++;
      np->received.push_back(ev);
    };
    cbs.on_command = [np](const std::string& from, const std::string& cmd) {
      np->commands.emplace_back(from, cmd);
    };
    n->mesh = std::make_unique<Mesh>(loop, clock, *n->hlc, *n->tp, n->disc.get(), n->store,
                                     *n->config, *n->events, st, cbs);
    // ローカル設定書き込みは即 delta push (Node 層の役割の代替)
    n->config->onChange([np](const LwwEntry& e, bool is_local) {
      if (is_local && np->mesh) np->mesh->pushConfigDelta({e});
    });
    n->mesh->start();
    Node& ref = *n;
    nodes[id] = std::move(n);
    return ref;
  }

  void remove(const std::string& id) { nodes.erase(id); }
  Node& at(const std::string& id) { return *nodes.at(id); }

  void run(int64_t ms, int64_t step = 5) {
    for (int64_t t = 0; t < ms; t += step) {
      clock.advance(step);
      loop.pumpDue();
    }
  }

  template <class F>
  bool runUntil(F cond, int64_t max_ms, int64_t step = 5) {
    loop.pumpDue();
    if (cond()) return true;
    for (int64_t t = 0; t < max_ms; t += step) {
      clock.advance(step);
      loop.pumpDue();
      if (cond()) return true;
    }
    return false;
  }

  // 全ノードが互いを alive 認識しているか
  bool mutualAlive(const std::vector<std::string>& ids) {
    for (const auto& a : ids) {
      for (const auto& b : ids) {
        if (a == b) continue;
        PeerInfo p = at(a).peer(b);
        if (p.id.empty() || p.status != "alive") return false;
      }
    }
    return true;
  }

  bool leaderIs(const std::vector<std::string>& ids, const std::string& duty,
                const std::string& expect) {
    for (const auto& a : ids) {
      if (at(a).mesh->leaderFor(duty) != expect) return false;
    }
    return true;
  }

  bool configEqual(const std::vector<std::string>& ids) {
    const std::string base = at(ids[0]).config->materializeJson();
    for (const auto& a : ids) {
      if (at(a).config->materializeJson() != base) return false;
    }
    return true;
  }

  bool eventEverywhere(const std::vector<std::string>& ids, const std::string& origin,
                       uint64_t seq) {
    for (const auto& a : ids) {
      if (!at(a).store.eventExists(origin, seq)) return false;
    }
    return true;
  }
};

// 40000-60000 からランダムに bind 可能なポートを探す (test_httpd と同じ流儀)
int pickPort() {
  static std::mt19937 rng(static_cast<uint32_t>(::getpid()) * 2654435761u + 777u);
  std::uniform_int_distribution<int> dist(40000, 60000);
  for (int i = 0; i < 100; i++) {
    int p = dist(rng);
    int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) continue;
    int yes = 1;
    ::setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons(static_cast<uint16_t>(p));
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    int ok = ::bind(fd, reinterpret_cast<sockaddr*>(&a), sizeof(a));
    ::close(fd);
    if (ok == 0) return p;
  }
  return 0;
}

}  // namespace

// ---------------------------------------------------------------- 成員と選主

TEST_CASE("mesh: beacon 発見のみで 3 ノードが全員 alive + leader が caps 通りに一意収束") {
  Fleet f;
  f.add(kIdA, "A", capsJson(10));                        // telegram/mqtt 両方 eligible
  f.add(kIdB, "B", capsJson(20, true, /*wan=*/false));   // wan 無し → telegram 不適格
  f.add(kIdC, "C", capsJson(5));
  const std::vector<std::string> ids = {kIdA, kIdB, kIdC};

  REQUIRE(f.runUntil([&] { return f.mutualAlive(ids); }, 3000));
  // telegram: eligible {A(10), C(5)} → A。mqtt: {A(10), B(20), C(5)} → B。
  REQUIRE(f.runUntil([&] {
    return f.leaderIs(ids, "telegram", kIdA) && f.leaderIs(ids, "mqtt_bridge", kIdB);
  }, 3000));
  CHECK(f.at(kIdA).mesh->isLeader("telegram"));
  CHECK_FALSE(f.at(kIdB).mesh->isLeader("telegram"));
  CHECK(f.at(kIdB).mesh->isLeader("mqtt_bridge"));

  // peers() は自分を含み、直連が付いている
  auto ps = f.at(kIdA).mesh->peers();
  CHECK(ps.size() == 3);
  CHECK_FALSE(f.at(kIdA).peer(kIdA).id.empty());
  int connected = 0;
  for (const auto& p : ps) {
    if (p.connected) connected++;
  }
  CHECK(connected == 2);  // 3 ノード全結線 (max_neighbors=4)

  // caps 変更で再選主: C の cpu_score を引き上げ → telegram leader が C へ遷移
  f.at(kIdC).mesh->setCaps(capsJson(99));
  REQUIRE(f.runUntil([&] { return f.leaderIs(ids, "telegram", kIdC); }, 3000));
  // on_leader_changed が遷移を通知している
  CHECK(std::find(f.at(kIdA).leader_changes.begin(), f.at(kIdA).leader_changes.end(),
                  std::make_pair(std::string("telegram"), kIdC)) !=
        f.at(kIdA).leader_changes.end());
}

TEST_CASE("mesh: eligible 不在の duty は leader 空") {
  Fleet f;
  f.add(kIdA, "A", capsJson(10, /*tls=*/false));  // telegram 不適格
  f.add(kIdB, "B", capsJson(20, /*tls=*/false, /*wan=*/true, /*mains=*/true,
                            /*mqtt=*/false));     // telegram/mqtt 両方不適格
  const std::vector<std::string> ids = {kIdA, kIdB};
  REQUIRE(f.runUntil([&] { return f.mutualAlive(ids); }, 3000));
  f.run(600);
  CHECK(f.at(kIdA).mesh->leaderFor("telegram") == "");
  CHECK(f.at(kIdB).mesh->leaderFor("telegram") == "");
  CHECK(f.leaderIs(ids, "mqtt_bridge", kIdA));  // mqtt は A のみ eligible
}

// ---------------------------------------------------------------- 設定収束

TEST_CASE("mesh: 設定収束 — pushConfigDelta + 周期 SYNC で全ノード一致、同時書込は決定的勝者") {
  Fleet f;
  // seed 経路の検証: beacon 無しで B/C は A を seed に
  f.add(kIdA, "A", capsJson(10), {{}, /*beacon=*/false});
  f.add(kIdB, "B", capsJson(9), {{"A"}, /*beacon=*/false});
  f.add(kIdC, "C", capsJson(8), {{"A"}, /*beacon=*/false});
  const std::vector<std::string> ids = {kIdA, kIdB, kIdC};
  REQUIRE(f.runUntil([&] { return f.mutualAlive(ids); }, 3000));

  f.at(kIdA).config->set("doors.front.label", "\"玄関\"");
  f.at(kIdA).config->set("doors.front.volume", "7");
  REQUIRE(f.runUntil([&] {
    return f.configEqual(ids) &&
           f.at(kIdC).config->get("doors.front.label") ==
               std::optional<std::string>("\"玄関\"");
  }, 3000));

  // 同時書き込み衝突: pump を挟まず A/B が同じ key に書く → 全ノード同一の決定的勝者
  f.at(kIdA).config->set("conflict.key", "\"from-A\"");
  f.at(kIdB).config->set("conflict.key", "\"from-B\"");
  REQUIRE(f.runUntil([&] { return f.configEqual(ids); }, 3000));
  auto winner = f.at(kIdA).config->get("conflict.key");
  REQUIRE(winner.has_value());
  CHECK((*winner == "\"from-A\"" || *winner == "\"from-B\""));
  CHECK(f.at(kIdB).config->get("conflict.key") == winner);
  CHECK(f.at(kIdC).config->get("conflict.key") == winner);

  // tombstone も収束する
  f.at(kIdB).config->remove("doors.front.volume");
  REQUIRE(f.runUntil([&] {
    return f.configEqual(ids) && !f.at(kIdA).config->get("doors.front.volume").has_value();
  }, 3000));
}

// ---------------------------------------------------------------- イベント

TEST_CASE("mesh: broadcastEvent は全ノード exactly-once (重複配送しても件数一致)") {
  Fleet f;
  f.add(kIdA, "A", capsJson(10));
  f.add(kIdB, "B", capsJson(9));
  f.add(kIdC, "C", capsJson(8));
  const std::vector<std::string> ids = {kIdA, kIdB, kIdC};
  REQUIRE(f.runUntil([&] { return f.mutualAlive(ids); }, 3000));

  EventRecord ev = f.at(kIdA).events->append("press", "d_front", kIdA, "{\"n\":1}");
  f.at(kIdA).mesh->broadcastEvent(ev);
  REQUIRE(f.runUntil([&] { return f.eventEverywhere(ids, kIdA, ev.seq); }, 2000));
  CHECK(f.at(kIdB).remote_events == 1);
  CHECK(f.at(kIdC).remote_events == 1);
  CHECK(f.at(kIdA).remote_events == 0);  // 自分発の還流では発火しない
  CHECK(f.at(kIdB).received[0].type == "press");
  CHECK(f.at(kIdB).received[0].payload_json == "{\"n\":1}");

  // 故意の重複配送: 同じイベントをもう一度 broadcast + しばらく回す
  f.at(kIdA).mesh->broadcastEvent(ev);
  f.run(500);
  CHECK(f.at(kIdB).remote_events == 1);  // 冪等 — 二重発火しない
  CHECK(f.at(kIdC).remote_events == 1);
  CHECK(f.at(kIdB).events->heads()[kIdA] == 1);

  // 2 発目は SYNC 経由でも届く (即時 push が無くても anti-entropy が拾う)
  EventRecord ev2 = f.at(kIdC).events->append("motion", "d_back", kIdC, "{}");
  // broadcastEvent を呼ばない
  REQUIRE(f.runUntil([&] { return f.eventEverywhere(ids, kIdC, ev2.seq); }, 3000));
  CHECK(f.at(kIdA).events->heads()[kIdC] == 1);
}

TEST_CASE("mesh: sendCommand / broadcastCommand → on_command") {
  Fleet f;
  f.add(kIdA, "A", capsJson(10));
  f.add(kIdB, "B", capsJson(9));
  f.add(kIdC, "C", capsJson(8));
  const std::vector<std::string> ids = {kIdA, kIdB, kIdC};
  REQUIRE(f.runUntil([&] { return f.mutualAlive(ids); }, 3000));

  f.at(kIdA).mesh->sendCommand(kIdB, "{\"cmd\":\"chime\",\"sound\":\"ding1\"}");
  REQUIRE(f.runUntil([&] { return !f.at(kIdB).commands.empty(); }, 1000));
  CHECK(f.at(kIdB).commands[0].first == kIdA);
  CHECK(f.at(kIdB).commands[0].second == "{\"cmd\":\"chime\",\"sound\":\"ding1\"}");
  CHECK(f.at(kIdC).commands.empty());

  f.at(kIdC).mesh->broadcastCommand("{\"cmd\":\"reload\"}");
  REQUIRE(f.runUntil([&] {
    return f.at(kIdA).commands.size() == 1 && f.at(kIdB).commands.size() == 2;
  }, 1000));
  CHECK(f.at(kIdA).commands[0].first == kIdC);
}

TEST_CASE("mesh: fetchSnapshot — 他ノードの JPEG 取得 / provider 無しは空 / 5s タイムアウト") {
  Fleet f;
  f.add(kIdA, "A", capsJson(10));
  f.add(kIdB, "B", capsJson(9));
  const std::vector<std::string> ids = {kIdA, kIdB};
  REQUIRE(f.runUntil([&] { return f.mutualAlive(ids); }, 3000));

  // B に快照供給者を登録 (FrameBus の代わりに固定バイト列)
  const Bytes jpeg = {0xff, 0xd8, 0xff, 0xe0, 0x01, 0x02, 0x03, 0xff, 0xd9};
  f.at(kIdB).mesh->setSnapshotProvider([&jpeg] { return jpeg; });

  // A → B: SNAP_REQ/SNAP_RESP (base64 往復) で同一バイト列が返る
  int called = 0;
  Bytes got;
  f.at(kIdA).mesh->fetchSnapshot(kIdB, [&](Bytes b) {
    called++;
    got = std::move(b);
  });
  REQUIRE(f.runUntil([&] { return called == 1; }, 2000));
  CHECK(got == jpeg);

  // 自分宛は provider 直呼び (B 自身)
  called = 0;
  f.at(kIdB).mesh->fetchSnapshot(kIdB, [&](Bytes b) {
    called++;
    got = std::move(b);
  });
  REQUIRE(f.runUntil([&] { return called == 1; }, 500));
  CHECK(got == jpeg);

  // provider 未登録の A へ要求 → 空 (失敗) が即応答で返る
  called = 0;
  f.at(kIdB).mesh->fetchSnapshot(kIdA, [&](Bytes b) {
    called++;
    got = std::move(b);
  });
  REQUIRE(f.runUntil([&] { return called == 1; }, 2000));
  CHECK(got.empty());

  // B が黙って死んだ場合は 5s タイムアウトで空が返る (先に接続だけ残った瞬間を狙うのは
  // 難しいので、チャネル断→即失敗 or タイムアウトのどちらでも「空で必ず解決」を確認)
  called = 0;
  f.net.killNode("B");
  f.at(kIdA).mesh->fetchSnapshot(kIdB, [&](Bytes b) {
    called++;
    got = std::move(b);
  });
  REQUIRE(f.runUntil([&] { return called == 1; }, 6000));
  CHECK(got.empty());
}

TEST_CASE("mesh: fetchBlob — 保持ノードから複数チャンク取得 / 自機は provider 直 / 不在は空") {
  Fleet f;
  f.add(kIdA, "A", capsJson(10));
  f.add(kIdB, "B", capsJson(9));
  f.add(kIdC, "C", capsJson(8));
  const std::vector<std::string> ids = {kIdA, kIdB, kIdC};
  REQUIRE(f.runUntil([&] { return f.mutualAlive(ids); }, 3000));

  // 700KB = 1 チャンク (256KB) を超える資産。C だけが保持している。
  Bytes blob(700 * 1024);
  for (size_t i = 0; i < blob.size(); i++) blob[i] = static_cast<uint8_t>((i * 31 + 7) & 0xff);
  const std::string hash = sha256Hex(blob);
  f.at(kIdC).mesh->setBlobProvider(
      [&](const std::string& h) { return h == hash ? blob : Bytes(); });
  // B は何も持たない — A は found:false を受けて次の候補 (C) へ進む
  f.at(kIdB).mesh->setBlobProvider([](const std::string&) { return Bytes(); });

  int called = 0;
  Bytes got;
  f.at(kIdA).mesh->fetchBlob(hash, [&](Bytes b) {
    called++;
    got = std::move(b);
  });
  REQUIRE(f.runUntil([&] { return called == 1; }, 5000));
  CHECK(got.size() == blob.size());
  CHECK(got == blob);              // チャンク再組立てがバイト等価
  CHECK(sha256Hex(got) == hash);   // 内容ハッシュが一致 (呼び出し側の検証と同じ)

  // 自分が持っている hash は mesh 往復せず provider 直呼びで返る
  called = 0;
  f.at(kIdC).mesh->fetchBlob(hash, [&](Bytes b) {
    called++;
    got = std::move(b);
  });
  REQUIRE(f.runUntil([&] { return called == 1; }, 500));
  CHECK(got == blob);

  // 誰も持っていない hash は (候補を試し切って) 空で必ず解決する
  called = 0;
  f.at(kIdA).mesh->fetchBlob(std::string(64, '0'), [&](Bytes b) {
    called++;
    got = std::move(b);
  });
  REQUIRE(f.runUntil([&] { return called == 1; }, 5000));
  CHECK(got.empty());
}

// ---------------------------------------------------------------- 分断と治癒

TEST_CASE("mesh: partition → 分区毎に独立 leader、heal → 収束・イベント不重不漏") {
  Fleet f;
  f.add(kIdA, "A", capsJson(10));
  f.add(kIdB, "B", capsJson(20));
  f.add(kIdC, "C", capsJson(5));
  const std::vector<std::string> ids = {kIdA, kIdB, kIdC};
  REQUIRE(f.runUntil([&] { return f.mutualAlive(ids); }, 3000));
  REQUIRE(f.runUntil([&] { return f.leaderIs(ids, "telegram", kIdB); }, 3000));

  f.net.partition({{"A"}, {"B", "C"}});
  // 各分区で dead 判定と独立選主
  REQUIRE(f.runUntil([&] {
    return f.at(kIdA).peer(kIdB).status == "dead" && f.at(kIdA).peer(kIdC).status == "dead" &&
           f.at(kIdB).peer(kIdA).status == "dead" && f.at(kIdC).peer(kIdA).status == "dead";
  }, 2000));
  REQUIRE(f.runUntil([&] {
    return f.at(kIdA).mesh->leaderFor("telegram") == kIdA &&   // A 分区: A が自己選出
           f.at(kIdB).mesh->leaderFor("telegram") == kIdB &&   // B/C 分区: B
           f.at(kIdC).mesh->leaderFor("telegram") == kIdB;
  }, 2000));

  // 分断中の書き込みとイベント
  f.at(kIdA).config->set("during.partition.a", "\"1\"");
  f.at(kIdB).config->set("during.partition.b", "\"2\"");
  f.at(kIdA).config->set("both.sides", "\"A\"");
  f.at(kIdB).config->set("both.sides", "\"B\"");
  EventRecord ea = f.at(kIdA).events->append("press", "d_front", kIdA, "{}");
  f.at(kIdA).mesh->broadcastEvent(ea);  // 誰にも届かない
  EventRecord eb = f.at(kIdB).events->append("motion", "d_back", kIdB, "{}");
  f.at(kIdB).mesh->broadcastEvent(eb);  // C にだけ届く
  f.run(300);
  CHECK(f.at(kIdC).store.eventExists(kIdB, eb.seq));
  CHECK_FALSE(f.at(kIdC).store.eventExists(kIdA, ea.seq));

  f.net.heal();
  REQUIRE(f.runUntil([&] { return f.mutualAlive(ids); }, 3000));
  REQUIRE(f.runUntil([&] {
    return f.configEqual(ids) && f.eventEverywhere(ids, kIdA, ea.seq) &&
           f.eventEverywhere(ids, kIdB, eb.seq);
  }, 5000));
  // 復活通知が出ている (dead → alive)
  CHECK(f.at(kIdA).sawAlive(kIdB, true));
  CHECK(f.at(kIdB).sawAlive(kIdA, true));
  // leader は全体最適 (B) に戻る
  REQUIRE(f.runUntil([&] { return f.leaderIs(ids, "telegram", kIdB); }, 3000));
  // イベントは不重: 各ノードの heads が正確に 1 件ずつ
  for (const auto& id : ids) {
    CHECK(f.at(id).events->heads()[kIdA] == 1);
    CHECK(f.at(id).events->heads()[kIdB] == 1);
  }
  // 分断中の同時書込も単一勝者に収束
  auto w = f.at(kIdA).config->get("both.sides");
  REQUIRE(w.has_value());
  CHECK(f.at(kIdB).config->get("both.sides") == w);
  CHECK(f.at(kIdC).config->get("both.sides") == w);
}

// ---------------------------------------------------------------- ノード死と復活

TEST_CASE("mesh: killNode → dead 通知、epoch+1 で復活 → alive 通知") {
  Fleet f;
  f.add(kIdA, "A", capsJson(10));
  f.add(kIdB, "B", capsJson(9));
  f.add(kIdC, "C", capsJson(8));
  const std::vector<std::string> ids = {kIdA, kIdB, kIdC};
  REQUIRE(f.runUntil([&] { return f.mutualAlive(ids); }, 3000));

  f.net.killNode("B");
  REQUIRE(f.runUntil([&] {
    return f.at(kIdA).sawAlive(kIdB, false) && f.at(kIdC).sawAlive(kIdB, false);
  }, 2000));
  CHECK(f.at(kIdA).peer(kIdB).status == "dead");
  CHECK_FALSE(f.at(kIdA).sawAlive(kIdC, false));  // C は死んでいない

  // 復活 (epoch+1 の別プロセス相当)
  f.remove(kIdB);
  f.add(kIdB, "B", capsJson(9), {{}, true, /*epoch=*/2});
  REQUIRE(f.runUntil([&] {
    return f.at(kIdA).sawAlive(kIdB, true) && f.at(kIdC).sawAlive(kIdB, true) &&
           f.mutualAlive(ids);
  }, 3000));
  CHECK(f.at(kIdA).peer(kIdB).epoch == 2);
}

TEST_CASE("mesh: leader 死 → lease 切れ後に次順位へ遷移") {
  Fleet f;
  f.add(kIdA, "A", capsJson(10));
  f.add(kIdB, "B", capsJson(20));  // 初代 leader
  f.add(kIdC, "C", capsJson(5));
  const std::vector<std::string> ids = {kIdA, kIdB, kIdC};
  REQUIRE(f.runUntil([&] { return f.mutualAlive(ids); }, 3000));
  REQUIRE(f.runUntil([&] {
    return f.leaderIs(ids, "telegram", kIdB) && f.leaderIs(ids, "mqtt_bridge", kIdB);
  }, 3000));

  f.at(kIdC).leader_changes.clear();
  f.net.killNode("B");
  // 次順位 A (10 > 5) へ
  REQUIRE(f.runUntil([&] {
    return f.at(kIdA).mesh->leaderFor("telegram") == kIdA &&
           f.at(kIdC).mesh->leaderFor("telegram") == kIdA &&
           f.at(kIdC).mesh->leaderFor("mqtt_bridge") == kIdA;
  }, 3000));
  CHECK(f.at(kIdA).mesh->isLeader("telegram"));
  // C に遷移通知が出ている
  CHECK(std::find(f.at(kIdC).leader_changes.begin(), f.at(kIdC).leader_changes.end(),
                  std::make_pair(std::string("telegram"), kIdA)) !=
        f.at(kIdC).leader_changes.end());
}

// ---------------------------------------------------------------- 配対 (JOIN)

TEST_CASE("mesh: joinCluster — PSK/設定スナップショット取得と mesh 合流") {
  Fleet f;
  Fleet::Node& host = f.add(kIdA, "A", capsJson(10), {{}, /*beacon=*/false});
  host.config->set("cluster.name", "\"京阪ハウス\"");
  host.config->set("doors.front.label", "\"正面玄関\"");
  f.run(100);

  auto token = host.mesh->createJoinToken();
  CHECK(token.pin.size() == 6);
  CHECK(token.expires_mono > f.clock.monoMs());

  // joiner は PSK 未設定 (全ゼロ) で参加
  Fleet::Node& joiner = f.add(kIdJ, "J", capsJson(3), {{}, /*beacon=*/false, 1,
                                                       /*zero_psk=*/true});
  std::vector<std::pair<bool, std::string>> results;
  joiner.mesh->joinCluster("A", token.pin, [&](bool ok, const std::string& err) {
    results.emplace_back(ok, err);
  });
  REQUIRE(f.runUntil([&] { return !results.empty(); }, 2000));
  CHECK(results[0].first);
  CHECK(results[0].second == "");
  // 設定スナップショットが適用済み
  CHECK(joiner.config->get("cluster.name") == std::optional<std::string>("\"京阪ハウス\""));
  CHECK(joiner.config->get("doors.front.label") == std::optional<std::string>("\"正面玄関\""));
  // 正規接続へ移行 (取得した PSK で暗号チャネルが張れる)
  REQUIRE(f.runUntil([&] { return f.mutualAlive({kIdA, kIdJ}); }, 3000));
  CHECK(f.at(kIdA).peer(kIdJ).connected);
  // join 後の設定変更も同期される
  host.config->set("cluster.psk_id", "\"k1\"");
  REQUIRE(f.runUntil([&] {
    return joiner.config->get("cluster.psk_id") == std::optional<std::string>("\"k1\"");
  }, 2000));
}

TEST_CASE("mesh: joinCluster — 誤 PIN 3 回で token 失効、期限切れ拒否") {
  Fleet f;
  Fleet::Node& host = f.add(kIdA, "A", capsJson(10), {{}, /*beacon=*/false});
  Fleet::Node& joiner = f.add(kIdJ, "J", capsJson(3), {{}, /*beacon=*/false, 1,
                                                       /*zero_psk=*/true});
  auto token = host.mesh->createJoinToken();
  std::string wrong = token.pin == "000000" ? "000001" : "000000";

  auto attempt = [&](const std::string& pin) {
    std::vector<std::pair<bool, std::string>> res;
    joiner.mesh->joinCluster("A", pin, [&](bool ok, const std::string& err) {
      res.emplace_back(ok, err);
    });
    REQUIRE(f.runUntil([&] { return !res.empty(); }, 2000));
    return res[0];
  };

  for (int i = 0; i < 3; i++) {
    auto r = attempt(wrong);
    CHECK_FALSE(r.first);
    CHECK(r.second == "bad_pin");
  }
  // 3 回失敗で失効 → 正しい PIN でも拒否
  auto r = attempt(token.pin);
  CHECK_FALSE(r.first);
  CHECK(r.second == "no_token");

  // 期限切れ: 新トークン発行後に 10 分超経過
  auto token2 = host.mesh->createJoinToken();
  f.clock.advance(10 * 60 * 1000 + 1000);
  f.loop.pumpDue();
  auto r2 = attempt(token2.pin);
  CHECK_FALSE(r2.first);
  CHECK(r2.second == "expired");

  // token 無し
  auto r3 = attempt("123456");
  CHECK_FALSE(r3.first);
  CHECK(r3.second == "no_token");
}

// ---------------------------------------------------------------- 損失環境

TEST_CASE("mesh: drop 20% + 遅延でも成員・設定・イベントが収束する (時間を長めに)") {
  Fleet f;
  f.net.setDrop(0.20, 20250827);
  f.net.setDelayMs(3);  // 配送遅延も併せて注入
  f.add(kIdA, "A", capsJson(10));
  f.add(kIdB, "B", capsJson(20));
  f.add(kIdC, "C", capsJson(5));
  const std::vector<std::string> ids = {kIdA, kIdB, kIdC};
  REQUIRE(f.runUntil([&] { return f.mutualAlive(ids); }, 15000));

  f.at(kIdA).config->set("lossy.a", "\"1\"");
  f.at(kIdB).config->set("lossy.b", "\"2\"");
  f.at(kIdA).config->set("lossy.conflict", "\"A\"");
  f.at(kIdC).config->set("lossy.conflict", "\"C\"");
  EventRecord ev = f.at(kIdA).events->append("press", "d_front", kIdA, "{}");
  f.at(kIdA).mesh->broadcastEvent(ev);
  EventRecord ev2 = f.at(kIdB).events->append("motion", "d_back", kIdB, "{}");
  f.at(kIdB).mesh->broadcastEvent(ev2);

  REQUIRE(f.runUntil([&] {
    return f.configEqual(ids) && f.eventEverywhere(ids, kIdA, ev.seq) &&
           f.eventEverywhere(ids, kIdB, ev2.seq);
  }, 20000));
  // exactly-once (適用は高々 1 回)
  for (const auto& id : ids) {
    CHECK(f.at(id).events->heads()[kIdA] == 1);
    CHECK(f.at(id).events->heads()[kIdB] == 1);
  }
  CHECK(f.at(kIdB).remote_events == 1);  // A 発の 1 件のみ
  CHECK(f.at(kIdC).remote_events == 2);
  // leader も収束
  REQUIRE(f.runUntil([&] { return f.leaderIs(ids, "telegram", kIdB); }, 10000));
}

// ---------------------------------------------------------------- 実 TCP スモーク

TEST_CASE("mesh: TcpTransport 実物スモーク — 127.0.0.1 で握手 + PING + 設定同期") {
  setLogMinLevel(LogLevel::Warn);
  RealClock clock;
  Runloop loop(clock);
  loop.start();

  const int pa = pickPort();
  REQUIRE(pa > 0);
  int pb = pickPort();
  if (pb == pa || pb == 0) pb = pa + 1;
  const std::string addr_a = "127.0.0.1:" + std::to_string(pa);
  const std::string addr_b = "127.0.0.1:" + std::to_string(pb);

  struct TcpNode {
    Store store;
    std::unique_ptr<HlcClock> hlc;
    std::unique_ptr<LwwMap> config;
    std::unique_ptr<EventLog> events;
    std::unique_ptr<TcpTransport> tp;
    std::unique_ptr<Mesh> mesh;
  };
  auto mk = [&](const std::string& id, const std::string& listen,
                std::vector<std::string> seeds) {
    auto n = std::make_unique<TcpNode>();
    REQUIRE(n->store.open(":memory:"));
    n->hlc = std::make_unique<HlcClock>(clock, id.substr(0, 8));
    n->config = std::make_unique<LwwMap>(id, *n->hlc);
    n->events = std::make_unique<EventLog>(id, *n->hlc, n->store);
    n->events->loadHeads();
    n->tp = std::make_unique<TcpTransport>(loop);
    MeshSettings st;
    st.node_id = id;
    st.listen_addr = listen;
    st.advertise_addr = listen;
    st.seed_peers = std::move(seeds);
    st.psk = mkPsk(0x77);
    st.caps_json = capsJson(1);
    st.heartbeat_ms = 100;
    st.suspect_ms = 400;
    st.dead_ms = 800;
    st.gossip_ms = 150;
    st.sync_ms = 150;
    st.claim_ttl_ms = 900;
    st.reconnect_ms = 200;
    n->mesh = std::make_unique<Mesh>(loop, clock, *n->hlc, *n->tp, nullptr, n->store, *n->config,
                                     *n->events, st, Mesh::Callbacks{});
    TcpNode* np = n.get();
    n->config->onChange([np](const LwwEntry& e, bool is_local) {
      if (is_local && np->mesh) np->mesh->pushConfigDelta({e});
    });
    return n;
  };
  auto na = mk(kIdA, addr_a, {});
  auto nb = mk(kIdB, addr_b, {addr_a});
  loop.callSync([&] {
    na->mesh->start();
    nb->mesh->start();
  });

  auto waitFor = [&](const std::function<bool()>& pred, int timeout_ms) {
    for (int t = 0; t < timeout_ms; t += 20) {
      bool ok = false;
      loop.callSync([&] { ok = pred(); });
      if (ok) return true;
      ::usleep(20 * 1000);
    }
    return false;
  };

  // 握手 + PING: 互いを alive 認識し hb が進む
  REQUIRE(waitFor([&] {
    auto ap = na->mesh->peers();
    auto bp = nb->mesh->peers();
    bool a_sees_b = false, b_sees_a = false;
    for (const auto& p : ap) {
      if (p.id == kIdB && p.status == "alive" && p.connected && p.hb_seq > 0) a_sees_b = true;
    }
    for (const auto& p : bp) {
      if (p.id == kIdA && p.status == "alive" && p.connected && p.hb_seq > 0) b_sees_a = true;
    }
    return a_sees_b && b_sees_a;
  }, 8000));

  // 設定同期 (両方向)
  loop.callSync([&] { na->config->set("tcp.smoke", "\"ok\""); });
  REQUIRE(waitFor([&] {
    return nb->config->get("tcp.smoke") == std::optional<std::string>("\"ok\"");
  }, 5000));
  loop.callSync([&] { nb->config->set("tcp.back", "\"too\""); });
  REQUIRE(waitFor([&] {
    return na->config->get("tcp.back") == std::optional<std::string>("\"too\"");
  }, 5000));

  loop.callSync([&] {
    na->mesh->stop();
    nb->mesh->stop();
  });
  loop.stop();
}

// ---------------------------------------------------------------- beacon 煙試験

TEST_CASE("udp_beacon: 送信がエラーにならない (multicast 煙試験)") {
  RealClock clock;
  Runloop loop(clock);
  loop.start();
  UdpBeacon beacon(loop, mkPsk(0x11), "239.255.71.71", 47171, 50);
  int found = 0;
  beacon.start([&](const DiscoveredPeer&) { found++; });
  loop.callSync([&] { beacon.announce(kIdA, "127.0.0.1:47172"); });
  ::usleep(250 * 1000);
  // CI ランナーには multicast 経路が無いことがある — 煙試験は「クラッシュしない」ことだけを
  // 保証し、送達性は WARN に留める (協議ロジックは InMem テストで網羅済み)
  WARN_MESSAGE(beacon.sentCount() >= 1, "beacon 送信 0 件 (multicast 不可の環境?)");
  WARN_MESSAGE(beacon.sendErrorCount() == 0, "multicast 送信エラー (CI 環境依存の可能性)");
  beacon.stop();
  loop.stop();
}
