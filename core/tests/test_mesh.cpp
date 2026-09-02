

#include <algorithm>
#include <array>
#include <map>
#include <memory>
#include <mutex>
#include <random>
#include <string>
#include <utility>
#include <vector>

#include "monocypher.h"

#include "crdt/lww_map.h"
#include "doctest.h"
#include "events/events.h"
#include "mesh/mesh.h"
#include "mesh/secure_channel.h"
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
const std::string kIdD(32, 'd');
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
  json::setBool(o.get(), "telegram_ready", true);
  json::setBool(o.get(), "web_push_ready", true);
  json::setBool(o.get(), "mqtt_ready", true);
  json::set(o.get(), "cpu_score", int64_t{cpu});
  return json::dump(o.get());
}


struct Opt {
  std::vector<std::string> seeds;
  bool beacon = true;
  uint64_t epoch = 1;
  bool zero_psk = false;
  std::vector<std::string> addrs;
  std::string role = "door_station";
  std::string door;
  std::string model;
  std::string platform;
};


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

    int remote_events = 0;
    std::vector<EventRecord> received;
    std::vector<std::pair<std::string, bool>> alive_changes;
    std::vector<std::pair<std::string, std::string>> leader_changes;
    std::vector<std::pair<std::string, std::string>> commands;
    int pending_changes = 0;  // Mesh cbs.on_pending_changed
    int paired_count = 0;
    struct InviteResult {
      std::string id;
      bool ok = false;
      std::string err;
    };
    std::vector<InviteResult> invite_results;
    std::vector<std::string> joined;          // cbs.on_device_joined ids
    std::vector<std::string> invite_rejects;  // cbs.on_invite_rejected reasons
    std::vector<std::string> token_changes;   // "active:expires_s:attempts_left"
    std::vector<std::string> mode_changes;    // "active:left_s:auto_added_count"
    int unpaired_count = 0;

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
    st.advertise_addrs = opt.addrs;
    st.seed_peers = opt.seeds;
    st.psk = opt.zero_psk ? std::array<uint8_t, 32>{} : psk;
    st.role = opt.role;
    st.door = opt.door;
    if (!opt.model.empty()) st.model = opt.model;
    if (!opt.platform.empty()) st.platform = opt.platform;
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
    cbs.on_pending_changed = [np] { np->pending_changes++; };
    cbs.on_paired = [np] { np->paired_count++; };
    cbs.on_invite_result = [np](const std::string& id, bool ok, const std::string& err) {
      np->invite_results.push_back({id, ok, err});
    };
    cbs.on_device_joined = [np](const std::string& id, const std::string&, const std::string&) {
      np->joined.push_back(id);
    };
    cbs.on_invite_rejected = [np](const std::string& reason) {
      np->invite_rejects.push_back(reason);
    };
    cbs.on_join_token_changed = [np](bool active, int64_t expires_s, int attempts_left) {
      np->token_changes.push_back(std::string(active ? "1" : "0") + ":" +
                                  std::to_string(expires_s) + ":" +
                                  std::to_string(attempts_left));
    };
    cbs.on_pairing_mode_changed = [np](bool active, int64_t left_s, int added) {
      np->mode_changes.push_back(std::string(active ? "1" : "0") + ":" + std::to_string(left_s) +
                                 ":" + std::to_string(added));
    };
    cbs.on_unpaired = [np] { np->unpaired_count++; };
    n->mesh = std::make_unique<Mesh>(loop, clock, *n->hlc, *n->tp, n->disc.get(), n->store,
                                     *n->config, *n->events, st, cbs);

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

struct RawMeshPeer {
  std::unique_ptr<ITransport> transport;
  std::shared_ptr<SecureChannel> channel;
  std::vector<std::string> received;
  bool established = false;
  bool closed = false;
};

std::shared_ptr<RawMeshPeer> connectRawPeer(Fleet& fleet, const std::string& id,
                                            const std::string& address,
                                            const std::string& target) {
  auto peer = std::make_shared<RawMeshPeer>();
  peer->transport = fleet.net.makeTransport(address);
  peer->transport->connect(target, [&fleet, peer, id](ConnPtr conn) {
    if (!conn) {
      peer->closed = true;
      return;
    }
    peer->channel = std::make_shared<SecureChannel>(fleet.loop, std::move(conn), true, fleet.psk,
                                                    id, 500);
    std::weak_ptr<RawMeshPeer> weak_peer = peer;
    SecureChannel::Callbacks callbacks;
    callbacks.on_established = [weak_peer] {
      if (auto locked = weak_peer.lock()) locked->established = true;
    };
    callbacks.on_message = [weak_peer](const std::string& message) {
      if (auto locked = weak_peer.lock()) locked->received.push_back(message);
    };
    callbacks.on_close = [weak_peer] {
      if (auto locked = weak_peer.lock()) locked->closed = true;
    };
    peer->channel->setCallbacks(std::move(callbacks));
    peer->channel->start();
  });
  return peer;
}

cJSON* addWireConfigEntry(cJSON* cfg, const std::string& key, uint64_t seq,
                          const std::string& author = kIdA) {
  cJSON* entry = json::pushObj(cfg);
  json::set(entry, "k", key);
  json::set(entry, "v", "\"wire-value\"");
  json::setBool(entry, "d", false);
  json::set(entry, "h",
            HlcClock::format(static_cast<int64_t>(seq * 1000), 0, author.substr(0, 8)));
  json::set(entry, "a", author);
  json::set(entry, "s", static_cast<int64_t>(seq));
  return entry;
}

json::Doc wireConfigSnapshot(const std::string& prefix) {
  auto message = json::obj();
  json::set(message.get(), "t", "SYNC_RESP");
  json::setBool(message.get(), "fin", true);
  json::set(json::addObj(message.get(), "vv"), kIdA.c_str(), int64_t{0});
  json::addObj(message.get(), "heads");
  cJSON* cfg = json::addArr(message.get(), "cfg");
  addWireConfigEntry(cfg, prefix + ".valid", 1);
  addWireConfigEntry(cfg, prefix + ".candidate", 2);
  json::set(json::addObj(message.get(), "cfg_complete_vv"), kIdA.c_str(), int64_t{2});
  json::addArr(message.get(), "ev");
  return message;
}

json::Doc wireEventRecord(const std::string& origin = kIdA, uint64_t seq = 1) {
  auto event = json::obj();
  json::set(event.get(), "origin", origin);
  json::set(event.get(), "seq", static_cast<int64_t>(seq));
  json::set(event.get(), "type", "motion");
  json::set(event.get(), "door", "d_front");
  json::set(event.get(), "device", kIdA);
  json::set(event.get(), "hlc",
            HlcClock::format(static_cast<int64_t>(seq * 1000), 0, origin.substr(0, 8)));
  json::set(event.get(), "wall", static_cast<int64_t>(seq * 1000));
  json::set(event.get(), "payload", "{}");
  json::set(event.get(), "notify", "{}");
  return event;
}

json::Doc wireLiveEvent() {
  auto message = json::obj();
  json::set(message.get(), "t", "EVENT");
  json::set(message.get(), "ttl", int64_t{2});
  json::setItem(message.get(), "ev", wireEventRecord());
  return message;
}

size_t receivedMessageCount(const RawMeshPeer& peer, const std::string& type) {
  size_t count = 0;
  for (const auto& message : peer.received) {
    auto parsed = json::parse(message);
    if (parsed && json::getString(parsed.get(), "t") == type) count++;
  }
  return count;
}


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



TEST_CASE("mesh: beacon discovery makes three nodes alive and elects capability leaders") {
  Fleet f;
  f.add(kIdA, "A", capsJson(10));
  f.add(kIdB, "B", capsJson(20, true, /*wan=*/false));
  f.add(kIdC, "C", capsJson(5));
  const std::vector<std::string> ids = {kIdA, kIdB, kIdC};

  REQUIRE(f.runUntil([&] { return f.mutualAlive(ids); }, 3000));
  // Each duty elects the eligible node with the highest priority.
  REQUIRE(f.runUntil([&] {
    return f.leaderIs(ids, "telegram", kIdA) && f.leaderIs(ids, "mqtt_bridge", kIdB);
  }, 3000));
  CHECK(f.at(kIdA).mesh->isLeader("telegram"));
  CHECK_FALSE(f.at(kIdB).mesh->isLeader("telegram"));
  CHECK(f.at(kIdB).mesh->isLeader("mqtt_bridge"));


  auto ps = f.at(kIdA).mesh->peers();
  CHECK(ps.size() == 3);
  CHECK_FALSE(f.at(kIdA).peer(kIdA).id.empty());
  int connected = 0;
  for (const auto& p : ps) {
    if (p.connected) connected++;
  }
  CHECK(connected == 2);


  f.at(kIdC).mesh->setCaps(capsJson(99));
  REQUIRE(f.runUntil([&] { return f.leaderIs(ids, "telegram", kIdC); }, 3000));

  CHECK(std::find(f.at(kIdA).leader_changes.begin(), f.at(kIdA).leader_changes.end(),
                  std::make_pair(std::string("telegram"), kIdC)) !=
        f.at(kIdA).leader_changes.end());
}

TEST_CASE("mesh: peer gossip preserves the order of multiple local interface addresses") {
  Fleet f;
  Opt multi;
  multi.addrs = {"A", "A-wifi", "A-ethernet"};
  multi.door = "door-live";
  f.add(kIdA, "A", capsJson(10), multi);
  f.add(kIdB, "B", capsJson(9));
  const std::vector<std::string> ids = {kIdA, kIdB};
  REQUIRE(f.runUntil([&] { return f.mutualAlive(ids); }, 3000));
  REQUIRE(f.runUntil([&] { return f.at(kIdB).peer(kIdA).addrs.size() == 3; }, 3000));
  CHECK(f.at(kIdB).peer(kIdA).addrs == multi.addrs);
  CHECK(f.at(kIdB).peer(kIdA).door == "door-live");
}

TEST_CASE("mesh: peer runtime exposes only bounded semantic UI application reports") {
  std::string projected;
  CHECK_FALSE(projectMeshRuntimeJson(std::string(64 * 1024 + 1, 'x'), &projected));
  CHECK_FALSE(projectMeshRuntimeJson(
      R"({"ui_style":{"schema_version":1.5,"elements":{}}})", &projected));

  Fleet f;
  f.add(kIdA, "A", capsJson(10));
  f.add(kIdB, "B", capsJson(9));
  const std::vector<std::string> ids = {kIdA, kIdB};
  REQUIRE(f.runUntil([&] { return f.mutualAlive(ids); }, 3000));

  f.at(kIdB).mesh->setRuntime(
      R"({"ui_style":{"schema_version":1,"applied":["ring.title"]}})");
  f.at(kIdA).mesh->setRuntime(
      R"({"schema_version":1,"generation":7,"heartbeat_ms":1700000000123,"safe_mode":true,"last_exit_reason":"native_crash","fingerprint":"private-device-id","process_recovery":{"safe_mode":true,"restart_attempt":2,"next_backoff_ms":5000,"last_exit_reason":"native_crash","helper_error":"/private/secret/path"},"recovery_helper":{"configured":"auto","effective":"helper","measured":{"helper_installed":true,"helper_running":true,"native_kiosk_consecutive_failures":3,"helper_error":"Bearer private"}},"components":{"core":"running","sip_audio":"available","bad/id":"secret"},"media_playback":{"schema_version":1,"state":"playing","transport":"fmp4_direct","codec":"h264","compositor":"uikit_bgra_sibling","decoded_frames":326,"displayed_frames":325,"dropped_frames":1,"latency_ms":26,"jitter_ms":4,"fps_x10":149,"active":true,"safe_mode":false,"stream_url":"https://secret.invalid/camera"},"device_alert":{"schema_version":1,"active":true,"event_hlc":"12-0-a","result":"presented","secret":"private","channel_results":[{"channel":"in_app","requested":true,"applied":true,"permission":"not_required","result":"presented"},{"channel":"bad/channel","result":"Bearer private"}]},"ui_style":{"schema_version":1,"node_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","applied":["ring.title","bad/id"],"rejected":[{"semantic_id":"cancel.call","reason":"contrast"}],"last_known_good":{"used":["cancel.call"],"persisted":["ring.title"]},"last_error":"cancel.call:contrast","updated_at_ms":1700000000123,"elements":{"ring.title":{"source":"override","applied":true,"rejected":false,"lkg_persisted":true,"error":""},"cancel.call":{"result":"last_known_good","validation_valid":false,"last_known_good_persisted":true,"validation_error":"contrast","persistence_error":""},"bad/id":{"applied":true}}}})");
  REQUIRE(f.runUntil([&] {
    return f.at(kIdB).peer(kIdA).runtime_json.find("cancel.call") != std::string::npos;
  }, 1000));

  auto runtime = json::parse(f.at(kIdB).peer(kIdA).runtime_json);
  REQUIRE(runtime);
  CHECK(json::getBool(runtime.get(), "safe_mode"));
  CHECK(json::getInt(runtime.get(), "generation") == 7);
  CHECK(json::getString(runtime.get(), "last_exit_reason") == "native_crash");
  CHECK(json::get(runtime.get(), "fingerprint") == nullptr);
  const cJSON* recovery = json::get(runtime.get(), "process_recovery");
  REQUIRE(cJSON_IsObject(recovery));
  CHECK(json::getInt(recovery, "restart_attempt") == 2);
  CHECK(json::get(recovery, "helper_error") == nullptr);
  const cJSON* helper = json::get(runtime.get(), "recovery_helper");
  REQUIRE(cJSON_IsObject(helper));
  CHECK(json::getString(helper, "configured") == "auto");
  CHECK(json::getBool(json::get(helper, "measured"), "helper_installed"));
  CHECK(json::get(json::get(helper, "measured"), "helper_error") == nullptr);
  const cJSON* components = json::get(runtime.get(), "components");
  REQUIRE(cJSON_IsObject(components));
  CHECK(json::getString(components, "core") == "running");
  CHECK(json::get(components, "bad/id") == nullptr);
  const cJSON* playback = json::get(runtime.get(), "media_playback");
  REQUIRE(cJSON_IsObject(playback));
  CHECK(json::getString(playback, "state") == "playing");
  CHECK(json::getString(playback, "transport") == "fmp4_direct");
  CHECK(json::getString(playback, "compositor") == "uikit_bgra_sibling");
  CHECK(json::getInt(playback, "decoded_frames") == 326);
  CHECK(json::getInt(playback, "displayed_frames") == 325);
  CHECK(json::getInt(playback, "latency_ms") == 26);
  CHECK(json::get(playback, "stream_url") == nullptr);
  const cJSON* device_alert = json::get(runtime.get(), "device_alert");
  REQUIRE(cJSON_IsObject(device_alert));
  CHECK(json::getString(device_alert, "event_hlc") == "12-0-a");
  CHECK(json::get(device_alert, "secret") == nullptr);
  CHECK(cJSON_GetArraySize(json::get(device_alert, "channel_results")) == 2);
  CHECK(json::getString(cJSON_GetArrayItem(json::get(device_alert, "channel_results"), 1),
                        "result").empty());
  const cJSON* ui_style = json::get(runtime.get(), "ui_style");
  REQUIRE(cJSON_IsObject(ui_style));
  CHECK(json::getInt(ui_style, "schema_version") == 1);
  CHECK(json::getString(ui_style, "last_error") == "cancel.call:contrast");
  CHECK(cJSON_GetArraySize(json::get(ui_style, "applied")) == 1);
  CHECK(json::get(json::get(ui_style, "elements"), "bad/id") == nullptr);
  CHECK(json::getBool(json::get(json::get(ui_style, "elements"), "ring.title"),
                      "applied"));
  CHECK_FALSE(json::getBool(
      json::get(json::get(ui_style, "elements"), "cancel.call"), "validation_valid", true));

  const std::string accepted = f.at(kIdB).peer(kIdA).runtime_json;
  f.at(kIdA).mesh->setRuntime(
      R"({"ui_style":{"schema_version":2,"elements":{"ring.title":{"applied":false}}}})");
  f.run(100);
  CHECK(f.at(kIdB).peer(kIdA).runtime_json == accepted);

  const std::string own_runtime = f.at(kIdB).peer(kIdB).runtime_json;
  CHECK(own_runtime.find("ring.title") != std::string::npos);
  CHECK(own_runtime.find("cancel.call") == std::string::npos);
}

TEST_CASE("mesh: a duty without an eligible node has no leader") {
  Fleet f;
  f.add(kIdA, "A", capsJson(10, /*tls=*/false));
  f.add(kIdB, "B", capsJson(20, /*tls=*/false, /*wan=*/true, /*mains=*/true,
                            /*mqtt=*/false));
  const std::vector<std::string> ids = {kIdA, kIdB};
  REQUIRE(f.runUntil([&] { return f.mutualAlive(ids); }, 3000));
  f.run(600);
  CHECK(f.at(kIdA).mesh->leaderFor("telegram") == "");
  CHECK(f.at(kIdB).mesh->leaderFor("telegram") == "");
  CHECK(f.leaderIs(ids, "mqtt_bridge", kIdA));
}

TEST_CASE("mesh: backend leaders require local credential readiness") {
  Fleet fleet;
  auto high = json::parse(capsJson(99));
  REQUIRE(high);
  json::setBool(high.get(), "telegram_ready", false);
  json::setBool(high.get(), "web_push_ready", false);
  json::setBool(high.get(), "mqtt_ready", false);
  fleet.add(kIdA, "high-without-secrets", json::dump(high.get()));
  fleet.add(kIdB, "lower-ready", capsJson(10));
  const std::vector<std::string> ids = {kIdA, kIdB};
  REQUIRE(fleet.runUntil([&] { return fleet.mutualAlive(ids); }, 3000));
  REQUIRE(fleet.runUntil([&] {
    return fleet.leaderIs(ids, "telegram", kIdB) &&
           fleet.leaderIs(ids, "web_push", kIdB) &&
           fleet.leaderIs(ids, "mqtt_bridge", kIdB);
  }, 3000));

  fleet.at(kIdA).mesh->setCaps(capsJson(99));
  REQUIRE(fleet.runUntil([&] {
    return fleet.leaderIs(ids, "telegram", kIdA) &&
           fleet.leaderIs(ids, "web_push", kIdA) &&
           fleet.leaderIs(ids, "mqtt_bridge", kIdA);
  }, 3000));
}

TEST_CASE("mesh leadership requires an explicit sane wall clock measurement") {
  auto caps = json::obj();
  json::setBool(caps.get(), "tls12", true);
  json::setBool(caps.get(), "wan", true);
  json::setBool(caps.get(), "mains_power", true);
  json::setBool(caps.get(), "telegram_ready", true);
  json::setBool(caps.get(), "web_push_ready", true);
  Fleet fleet;
  fleet.add(kIdA, "A", json::dump(caps.get()));
  fleet.run(600);
  CHECK(fleet.at(kIdA).mesh->leaderFor("telegram").empty());
  CHECK(fleet.at(kIdA).mesh->leaderFor("web_push").empty());
}



TEST_CASE("mesh: delta push and periodic sync converge config with deterministic conflicts") {
  Fleet f;

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


  f.at(kIdA).config->set("conflict.key", "\"from-A\"");
  f.at(kIdB).config->set("conflict.key", "\"from-B\"");
  REQUIRE(f.runUntil([&] { return f.configEqual(ids); }, 3000));
  auto winner = f.at(kIdA).config->get("conflict.key");
  REQUIRE(winner.has_value());
  CHECK((*winner == "\"from-A\"" || *winner == "\"from-B\""));
  CHECK(f.at(kIdB).config->get("conflict.key") == winner);
  CHECK(f.at(kIdC).config->get("conflict.key") == winner);


  f.at(kIdB).config->remove("doors.front.volume");
  REQUIRE(f.runUntil([&] {
    return f.configEqual(ids) && !f.at(kIdA).config->get("doors.front.volume").has_value();
  }, 3000));
}

TEST_CASE("mesh: full config sync acknowledges compacted same-key history") {
  Fleet f;
  f.add(kIdA, "A", capsJson(10), {{}, /*beacon=*/false});
  f.at(kIdA).config->set("cluster.name", R"("Old")");
  f.at(kIdA).config->set("cluster.name", R"("Current")");
  REQUIRE(f.at(kIdA).config->all().size() == 1);
  REQUIRE(f.at(kIdA).config->versionVector().at(kIdA) == 2);

  f.add(kIdB, "B", capsJson(9), {{"A"}, /*beacon=*/false});
  REQUIRE(f.runUntil([&] {
    const auto vv = f.at(kIdB).config->versionVector();
    const auto it = vv.find(kIdA);
    return f.at(kIdB).config->get("cluster.name") ==
               std::optional<std::string>(R"("Current")") &&
           it != vv.end() && it->second == 2;
  }, 3000));
  CHECK(f.at(kIdA).config->deltaSince(f.at(kIdB).config->versionVector()).empty());
}

TEST_CASE("mesh: malformed config wire snapshots are rejected atomically") {
  Fleet fleet;
  Fleet::Node& receiver =
      fleet.add(kIdB, "B", capsJson(9), {{}, /*beacon=*/false});
  auto peer = connectRawPeer(fleet, kIdC, "raw-C", "B");
  REQUIRE(fleet.runUntil([&] { return peer->established; }, 1000));
  REQUIRE(peer->channel != nullptr);

  int case_number = 0;
  auto rejected = [&](const std::string& name,
                      const std::function<void(cJSON*)>& make_invalid) {
    CAPTURE(name);
    const std::string prefix = "wire.reject" + std::to_string(case_number++);
    auto message = wireConfigSnapshot(prefix);
    make_invalid(message.get());
    peer->channel->sendMessage(json::dump(message.get()));
    fleet.run(20);
    CHECK_FALSE(receiver.config->get(prefix + ".valid").has_value());
    CHECK_FALSE(receiver.config->get(prefix + ".candidate").has_value());
    const VersionVector vector = receiver.config->versionVector();
    const auto author = vector.find(kIdA);
    CHECK((author == vector.end() || author->second == 0));
  };

  rejected("negative complete frontier", [](cJSON* message) {
    json::set(json::get(message, "cfg_complete_vv"), kIdA.c_str(), int64_t{-1});
  });
  rejected("fractional complete frontier", [](cJSON* message) {
    json::set(json::get(message, "cfg_complete_vv"), kIdA.c_str(), 1.5);
  });
  rejected("complete frontier above INT64_MAX", [](cJSON* message) {
    json::set(json::get(message, "cfg_complete_vv"), kIdA.c_str(),
              9223372036854775808.0);
  });
  rejected("invalid complete frontier author", [](cJSON* message) {
    json::set(json::get(message, "cfg_complete_vv"), "not-a-node-id", int64_t{1});
  });
  rejected("negative request version", [](cJSON* message) {
    json::set(json::get(message, "vv"), kIdA.c_str(), int64_t{-1});
  });
  rejected("fractional event head", [](cJSON* message) {
    json::set(json::get(message, "heads"), kIdA.c_str(), 1.25);
  });
  rejected("zero config sequence", [](cJSON* message) {
    json::set(cJSON_GetArrayItem(json::get(message, "cfg"), 1), "s", int64_t{0});
  });
  rejected("negative config sequence", [](cJSON* message) {
    json::set(cJSON_GetArrayItem(json::get(message, "cfg"), 1), "s", int64_t{-1});
  });
  rejected("fractional config sequence", [](cJSON* message) {
    json::set(cJSON_GetArrayItem(json::get(message, "cfg"), 1), "s", 1.5);
  });
  rejected("config sequence above INT64_MAX", [](cJSON* message) {
    json::set(cJSON_GetArrayItem(json::get(message, "cfg"), 1), "s",
              9223372036854775808.0);
  });
  rejected("invalid config author", [](cJSON* message) {
    json::set(cJSON_GetArrayItem(json::get(message, "cfg"), 1), "a", "not-a-node-id");
  });
  rejected("invalid config key", [](cJSON* message) {
    json::set(cJSON_GetArrayItem(json::get(message, "cfg"), 1), "k", ".invalid");
  });
  rejected("oversized config key", [](cJSON* message) {
    json::set(cJSON_GetArrayItem(json::get(message, "cfg"), 1), "k",
              std::string(513, 'x'));
  });
  rejected("malformed config HLC", [](cJSON* message) {
    json::set(cJSON_GetArrayItem(json::get(message, "cfg"), 1), "h", "not-an-hlc");
  });
  rejected("config HLC belongs to another author", [](cJSON* message) {
    json::set(cJSON_GetArrayItem(json::get(message, "cfg"), 1), "h",
              HlcClock::format(2000, 0, kIdB.substr(0, 8)));
  });

  auto valid = wireConfigSnapshot("wire.accepted");
  peer->channel->sendMessage(json::dump(valid.get()));
  REQUIRE(fleet.runUntil(
      [&] {
        return receiver.config->get("wire.accepted.valid") ==
                   std::optional<std::string>("\"wire-value\"") &&
               receiver.config->get("wire.accepted.candidate") ==
                   std::optional<std::string>("\"wire-value\"");
      },
      500));
  CHECK(receiver.config->versionVector().at(kIdA) == 2);

  auto hasSyncResponse = [&] {
    for (const auto& message : peer->received) {
      auto parsed = json::parse(message);
      if (parsed && json::getString(parsed.get(), "t") == "SYNC_RESP") return true;
    }
    return false;
  };
  peer->received.clear();
  auto invalid_request = json::obj();
  json::set(invalid_request.get(), "t", "SYNC_REQ");
  json::set(json::addObj(invalid_request.get(), "vv"), kIdA.c_str(), -0.5);
  json::addObj(invalid_request.get(), "heads");
  peer->channel->sendMessage(json::dump(invalid_request.get()));
  fleet.run(20);
  CHECK_FALSE(hasSyncResponse());

  peer->received.clear();
  auto valid_request = json::obj();
  json::set(valid_request.get(), "t", "SYNC_REQ");
  json::set(json::addObj(valid_request.get(), "vv"), kIdA.c_str(), int64_t{0});
  json::addObj(valid_request.get(), "heads");
  peer->channel->sendMessage(json::dump(valid_request.get()));
  REQUIRE(fleet.runUntil(hasSyncResponse, 100));
}

TEST_CASE("mesh: malformed live events are neither persisted nor forwarded") {
  Fleet fleet;
  Fleet::Node& receiver =
      fleet.add(kIdB, "B", capsJson(9), {{}, /*beacon=*/false});
  auto sender = connectRawPeer(fleet, kIdC, "raw-C", "B");
  auto observer = connectRawPeer(fleet, kIdD, "raw-D", "B");
  REQUIRE(fleet.runUntil([&] { return sender->established && observer->established; }, 1000));
  REQUIRE(sender->channel);
  REQUIRE(observer->channel);

  auto rejected = [&](const std::string& name,
                      const std::function<void(cJSON*)>& make_invalid) {
    CAPTURE(name);
    auto message = wireLiveEvent();
    make_invalid(message.get());
    observer->received.clear();
    sender->channel->sendMessage(json::dump(message.get()));
    fleet.run(20);
    CHECK(receiver.store.recentEvents(10).empty());
    CHECK(receiver.remote_events == 0);
    CHECK(receivedMessageCount(*observer, "EVENT") == 0);
  };

  rejected("invalid origin", [](cJSON* message) {
    json::set(json::get(message, "ev"), "origin", "not-a-node-id");
  });
  rejected("zero sequence", [](cJSON* message) {
    json::set(json::get(message, "ev"), "seq", int64_t{0});
  });
  rejected("negative sequence", [](cJSON* message) {
    json::set(json::get(message, "ev"), "seq", int64_t{-1});
  });
  rejected("fractional sequence", [](cJSON* message) {
    json::set(json::get(message, "ev"), "seq", 1.5);
  });
  rejected("sequence at the ambiguous signed boundary", [](cJSON* message) {
    json::set(json::get(message, "ev"), "seq", 9223372036854775808.0);
  });
  rejected("malformed HLC", [](cJSON* message) {
    json::set(json::get(message, "ev"), "hlc", "not-an-hlc");
  });
  rejected("HLC belongs to another origin", [](cJSON* message) {
    json::set(json::get(message, "ev"), "hlc",
              HlcClock::format(1000, 0, kIdB.substr(0, 8)));
  });
  rejected("fractional wall clock", [](cJSON* message) {
    json::set(json::get(message, "ev"), "wall", 1000.5);
  });
  rejected("wall clock at the ambiguous lower boundary", [](cJSON* message) {
    json::set(json::get(message, "ev"), "wall", -9223372036854775808.0);
  });
  rejected("empty event type", [](cJSON* message) {
    json::set(json::get(message, "ev"), "type", "");
  });
  rejected("non-token event type", [](cJSON* message) {
    json::set(json::get(message, "ev"), "type", "motion/type");
  });
  rejected("oversized door", [](cJSON* message) {
    json::set(json::get(message, "ev"), "door", std::string(257, 'd'));
  });
  rejected("control character in device", [](cJSON* message) {
    json::set(json::get(message, "ev"), "device", "device\nname");
  });
  rejected("malformed payload JSON", [](cJSON* message) {
    json::set(json::get(message, "ev"), "payload", "{");
  });
  rejected("non-object payload JSON", [](cJSON* message) {
    json::set(json::get(message, "ev"), "payload", "[]");
  });
  rejected("oversized payload JSON", [](cJSON* message) {
    json::set(json::get(message, "ev"), "payload", std::string(64 * 1024 + 1, 'x'));
  });
  rejected("whitespace-only notification JSON", [](cJSON* message) {
    json::set(json::get(message, "ev"), "notify", " ");
  });
  rejected("non-object notification JSON", [](cJSON* message) {
    json::set(json::get(message, "ev"), "notify", "true");
  });
  rejected("fractional flood TTL", [](cJSON* message) {
    json::set(message, "ttl", 1.5);
  });
  rejected("oversized flood TTL", [](cJSON* message) {
    json::set(message, "ttl", int64_t{3});
  });

  observer->received.clear();
  auto valid = wireLiveEvent();
  json::set(json::get(valid.get(), "ev"), "payload", "");
  json::set(json::get(valid.get(), "ev"), "notify", "");
  sender->channel->sendMessage(json::dump(valid.get()));
  REQUIRE(fleet.runUntil([&] { return receiver.store.eventExists(kIdA, 1); }, 500));
  CHECK(receiver.remote_events == 1);
  const auto stored = receiver.store.eventGet(kIdA, 1);
  REQUIRE(stored.has_value());
  CHECK(stored->payload_json == "{}");
  CHECK(stored->notify_json == "{}");
  REQUIRE(fleet.runUntil([&] { return receivedMessageCount(*observer, "EVENT") == 1; }, 500));
}

TEST_CASE("mesh: sync event arrays decode completely before any state is applied") {
  Fleet fleet;
  Fleet::Node& receiver =
      fleet.add(kIdB, "B", capsJson(9), {{}, /*beacon=*/false});
  auto peer = connectRawPeer(fleet, kIdC, "raw-C", "B");
  REQUIRE(fleet.runUntil([&] { return peer->established; }, 1000));
  REQUIRE(peer->channel != nullptr);

  auto malformed = wireConfigSnapshot("wire.event.reject");
  cJSON* malformed_events = json::get(malformed.get(), "ev");
  json::push(malformed_events, wireEventRecord(kIdA, 1));
  auto bad_event = wireEventRecord(kIdC, 1);
  json::set(bad_event.get(), "payload", "[]");
  json::push(malformed_events, std::move(bad_event));
  peer->channel->sendMessage(json::dump(malformed.get()));
  fleet.run(20);
  CHECK_FALSE(receiver.config->get("wire.event.reject.valid").has_value());
  CHECK_FALSE(receiver.config->get("wire.event.reject.candidate").has_value());
  CHECK_FALSE(receiver.store.eventExists(kIdA, 1));
  CHECK_FALSE(receiver.store.eventExists(kIdC, 1));
  CHECK(receiver.remote_events == 0);

  auto wrong_shape = wireConfigSnapshot("wire.event.shape");
  cJSON_DeleteItemFromObjectCaseSensitive(wrong_shape.get(), "ev");
  json::set(wrong_shape.get(), "ev", "not-an-array");
  peer->channel->sendMessage(json::dump(wrong_shape.get()));
  fleet.run(20);
  CHECK_FALSE(receiver.config->get("wire.event.shape.valid").has_value());

  auto malformed_fin = wireConfigSnapshot("wire.event.fin");
  json::set(malformed_fin.get(), "fin", "true");
  peer->channel->sendMessage(json::dump(malformed_fin.get()));
  fleet.run(20);
  CHECK_FALSE(receiver.config->get("wire.event.fin.valid").has_value());

  auto valid = wireConfigSnapshot("wire.event.accept");
  auto legacy_empty_event = wireEventRecord(kIdC, 1);
  json::set(legacy_empty_event.get(), "payload", "");
  json::set(legacy_empty_event.get(), "notify", "");
  json::push(json::get(valid.get(), "ev"), std::move(legacy_empty_event));
  peer->channel->sendMessage(json::dump(valid.get()));
  REQUIRE(fleet.runUntil(
      [&] {
        return receiver.config->get("wire.event.accept.valid") ==
                   std::optional<std::string>("\"wire-value\"") &&
               receiver.store.eventExists(kIdC, 1);
      },
      500));
  CHECK(receiver.remote_events == 1);
  CHECK(receiver.received.front().origin == kIdC);
  CHECK(receiver.received.front().payload_json == "{}");
  CHECK(receiver.received.front().notify_json == "{}");
}

TEST_CASE("mesh: heartbeat and claim counters reject unsafe wire numbers") {
  Fleet fleet;
  Fleet::Node& receiver =
      fleet.add(kIdB, "B", capsJson(9), {{}, /*beacon=*/false});
  auto peer = connectRawPeer(fleet, kIdC, "raw-C", "B");
  REQUIRE(fleet.runUntil([&] { return peer->established; }, 1000));
  REQUIRE(peer->channel != nullptr);
  REQUIRE(receiver.peer(kIdC).id == kIdC);

  auto ping = [](double epoch, double heartbeat) {
    auto message = json::obj();
    json::set(message.get(), "t", "PING");
    json::set(message.get(), "id", kIdC);
    json::set(message.get(), "epoch", epoch);
    json::set(message.get(), "hb", heartbeat);
    json::set(message.get(), "hlc", HlcClock::format(1000, 0, kIdC.substr(0, 8)));
    return message;
  };

  auto negative_epoch = ping(-1.0, 1.0);
  peer->channel->sendMessage(json::dump(negative_epoch.get()));
  fleet.run(10);
  CHECK(receiver.peer(kIdC).epoch == 0);
  CHECK(receiver.peer(kIdC).hb_seq == 0);

  auto fractional_heartbeat = ping(1.0, 1.5);
  peer->channel->sendMessage(json::dump(fractional_heartbeat.get()));
  fleet.run(10);
  CHECK(receiver.peer(kIdC).epoch == 0);

  auto peers = json::obj();
  json::set(peers.get(), "t", "PEERS");
  cJSON* records = json::addArr(peers.get(), "peers");
  cJSON* first = json::pushObj(records);
  json::set(first, "id", kIdA);
  json::set(first, "epoch", int64_t{1});
  json::set(first, "hb", int64_t{1});
  json::set(first, "hlc", HlcClock::format(1000, 0, kIdA.substr(0, 8)));
  cJSON* second = json::pushObj(records);
  json::set(second, "id", kIdD);
  json::set(second, "epoch", int64_t{-1});
  json::set(second, "hb", int64_t{1});
  json::set(second, "hlc", HlcClock::format(1000, 0, kIdD.substr(0, 8)));
  peer->channel->sendMessage(json::dump(peers.get()));
  fleet.run(10);
  CHECK(receiver.peer(kIdA).id.empty());
  CHECK(receiver.peer(kIdD).id.empty());

  auto valid_ping = ping(1.0, 1.0);
  peer->channel->sendMessage(json::dump(valid_ping.get()));
  REQUIRE(fleet.runUntil([&] { return receiver.peer(kIdC).hb_seq == 1; }, 100));
  REQUIRE(fleet.runUntil([&] { return receiver.mesh->leaderFor("telegram") == kIdB; }, 200));

  auto claim = json::obj();
  json::set(claim.get(), "t", "CLAIM");
  json::set(claim.get(), "duty", "telegram");
  json::set(claim.get(), "leader", kIdC);
  json::set(claim.get(), "rank", int64_t{1000});
  json::set(claim.get(), "term", int64_t{-1});
  peer->channel->sendMessage(json::dump(claim.get()));
  fleet.run(5);
  CHECK(receiver.mesh->leaderFor("telegram") == kIdB);

  json::set(claim.get(), "term", int64_t{1});
  json::set(claim.get(), "rank", 9223372036854775808.0);
  peer->channel->sendMessage(json::dump(claim.get()));
  fleet.run(5);
  CHECK(receiver.mesh->leaderFor("telegram") == kIdB);
}



TEST_CASE("mesh: broadcastEvent is exactly once despite duplicate delivery") {
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
  CHECK(f.at(kIdA).remote_events == 0);
  CHECK(f.at(kIdB).received[0].type == "press");
  CHECK(f.at(kIdB).received[0].payload_json == "{\"n\":1}");


  f.at(kIdA).mesh->broadcastEvent(ev);
  f.run(500);
  CHECK(f.at(kIdB).remote_events == 1);
  CHECK(f.at(kIdC).remote_events == 1);
  CHECK(f.at(kIdB).events->heads()[kIdA] == 1);


  EventRecord ev2 = f.at(kIdC).events->append("motion", "d_back", kIdC, "{}");

  REQUIRE(f.runUntil([&] { return f.eventEverywhere(ids, kIdC, ev2.seq); }, 3000));
  CHECK(f.at(kIdA).events->heads()[kIdC] == 1);
}

TEST_CASE("mesh: anti-entropy fills a missing event below an out-of-order sequence") {
  Fleet f;
  auto& source = f.add(kIdA, "A", capsJson(10), {{}, /*beacon=*/false});
  const EventRecord seq1 = source.events->append("motion", "d_back", kIdA, "{}");
  f.clock.advance(1);
  const EventRecord seq2 = source.events->append("motion", "d_back", kIdA, "{}");
  REQUIRE(seq1.seq == 1);
  REQUIRE(seq2.seq == 2);

  auto& receiver = f.add(kIdB, "B", capsJson(9), {{"A"}, /*beacon=*/false});
  REQUIRE(receiver.events->applyRemote(seq2));
  CHECK(receiver.events->heads()[kIdA] == 0);

  REQUIRE(f.runUntil([&] {
    return receiver.store.eventExists(kIdA, 1) && receiver.events->heads()[kIdA] == 2;
  }, 3000));
  REQUIRE(receiver.received.size() == 2);
  CHECK(receiver.received[0].seq == 1);
  CHECK(receiver.received[1].seq == 2);
  CHECK(receiver.store.eventExists(kIdA, 2));
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

TEST_CASE("mesh: fetchSnapshot handles remote JPEG, missing providers, and timeout") {
  Fleet f;
  f.add(kIdA, "A", capsJson(10));
  f.add(kIdB, "B", capsJson(9));
  const std::vector<std::string> ids = {kIdA, kIdB};
  REQUIRE(f.runUntil([&] { return f.mutualAlive(ids); }, 3000));


  const Bytes jpeg = {0xff, 0xd8, 0xff, 0xe0, 0x01, 0x02, 0x03, 0xff, 0xd9};
  f.at(kIdB).mesh->setSnapshotProvider([&jpeg] { return jpeg; });


  int called = 0;
  Bytes got;
  f.at(kIdA).mesh->fetchSnapshot(kIdB, [&](Bytes b) {
    called++;
    got = std::move(b);
  });
  REQUIRE(f.runUntil([&] { return called == 1; }, 2000));
  CHECK(got == jpeg);


  called = 0;
  f.at(kIdB).mesh->fetchSnapshot(kIdB, [&](Bytes b) {
    called++;
    got = std::move(b);
  });
  REQUIRE(f.runUntil([&] { return called == 1; }, 500));
  CHECK(got == jpeg);


  called = 0;
  f.at(kIdB).mesh->fetchSnapshot(kIdA, [&](Bytes b) {
    called++;
    got = std::move(b);
  });
  REQUIRE(f.runUntil([&] { return called == 1; }, 2000));
  CHECK(got.empty());



  called = 0;
  f.net.killNode("B");
  f.at(kIdA).mesh->fetchSnapshot(kIdB, [&](Bytes b) {
    called++;
    got = std::move(b);
  });
  REQUIRE(f.runUntil([&] { return called == 1; }, 6000));
  CHECK(got.empty());
}

TEST_CASE("mesh: fetchBlob supports chunked remote, direct local, and missing blobs") {
  Fleet f;
  f.add(kIdA, "A", capsJson(10));
  f.add(kIdB, "B", capsJson(9));
  f.add(kIdC, "C", capsJson(8));
  const std::vector<std::string> ids = {kIdA, kIdB, kIdC};
  REQUIRE(f.runUntil([&] { return f.mutualAlive(ids); }, 3000));


  Bytes blob(700 * 1024);
  for (size_t i = 0; i < blob.size(); i++) blob[i] = static_cast<uint8_t>((i * 31 + 7) & 0xff);
  const std::string hash = sha256Hex(blob);
  f.at(kIdC).mesh->setBlobProvider(
      [&](const std::string& h) { return h == hash ? blob : Bytes(); });

  f.at(kIdB).mesh->setBlobProvider([](const std::string&) { return Bytes(); });

  int called = 0;
  Bytes got;
  f.at(kIdA).mesh->fetchBlob(hash, [&](Bytes b) {
    called++;
    got = std::move(b);
  });
  REQUIRE(f.runUntil([&] { return called == 1; }, 5000));
  CHECK(got.size() == blob.size());
  CHECK(got == blob);
  CHECK(sha256Hex(got) == hash);


  called = 0;
  f.at(kIdC).mesh->fetchBlob(hash, [&](Bytes b) {
    called++;
    got = std::move(b);
  });
  REQUIRE(f.runUntil([&] { return called == 1; }, 500));
  CHECK(got == blob);


  called = 0;
  f.at(kIdA).mesh->fetchBlob(std::string(64, '0'), [&](Bytes b) {
    called++;
    got = std::move(b);
  });
  REQUIRE(f.runUntil([&] { return called == 1; }, 5000));
  CHECK(got.empty());
}



TEST_CASE("mesh: partitions elect local leaders and heal without event loss or duplication") {
  Fleet f;
  f.add(kIdA, "A", capsJson(10));
  f.add(kIdB, "B", capsJson(20));
  f.add(kIdC, "C", capsJson(5));
  const std::vector<std::string> ids = {kIdA, kIdB, kIdC};
  REQUIRE(f.runUntil([&] { return f.mutualAlive(ids); }, 3000));
  REQUIRE(f.runUntil([&] { return f.leaderIs(ids, "telegram", kIdB); }, 3000));

  f.net.partition({{"A"}, {"B", "C"}});

  REQUIRE(f.runUntil([&] {
    return f.at(kIdA).peer(kIdB).status == "dead" && f.at(kIdA).peer(kIdC).status == "dead" &&
           f.at(kIdB).peer(kIdA).status == "dead" && f.at(kIdC).peer(kIdA).status == "dead";
  }, 2000));
  REQUIRE(f.runUntil([&] {
    return f.at(kIdA).mesh->leaderFor("telegram") == kIdA &&
           f.at(kIdB).mesh->leaderFor("telegram") == kIdB &&
           f.at(kIdC).mesh->leaderFor("telegram") == kIdB;
  }, 2000));


  f.at(kIdA).config->set("during.partition.a", "\"1\"");
  f.at(kIdB).config->set("during.partition.b", "\"2\"");
  f.at(kIdA).config->set("both.sides", "\"A\"");
  f.at(kIdB).config->set("both.sides", "\"B\"");
  EventRecord ea = f.at(kIdA).events->append("press", "d_front", kIdA, "{}");
  f.at(kIdA).mesh->broadcastEvent(ea);
  EventRecord eb = f.at(kIdB).events->append("motion", "d_back", kIdB, "{}");
  f.at(kIdB).mesh->broadcastEvent(eb);
  f.run(300);
  CHECK(f.at(kIdC).store.eventExists(kIdB, eb.seq));
  CHECK_FALSE(f.at(kIdC).store.eventExists(kIdA, ea.seq));

  f.net.heal();
  REQUIRE(f.runUntil([&] { return f.mutualAlive(ids); }, 3000));
  REQUIRE(f.runUntil([&] {
    return f.configEqual(ids) && f.eventEverywhere(ids, kIdA, ea.seq) &&
           f.eventEverywhere(ids, kIdB, eb.seq);
  }, 5000));

  CHECK(f.at(kIdA).sawAlive(kIdB, true));
  CHECK(f.at(kIdB).sawAlive(kIdA, true));

  REQUIRE(f.runUntil([&] { return f.leaderIs(ids, "telegram", kIdB); }, 3000));

  for (const auto& id : ids) {
    CHECK(f.at(id).events->heads()[kIdA] == 1);
    CHECK(f.at(id).events->heads()[kIdB] == 1);
  }

  auto w = f.at(kIdA).config->get("both.sides");
  REQUIRE(w.has_value());
  CHECK(f.at(kIdB).config->get("both.sides") == w);
  CHECK(f.at(kIdC).config->get("both.sides") == w);
}



TEST_CASE("mesh: killNode reports dead and a higher epoch reports alive") {
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
  CHECK_FALSE(f.at(kIdA).sawAlive(kIdC, false));


  f.remove(kIdB);
  f.add(kIdB, "B", capsJson(9), {{}, true, /*epoch=*/2});
  REQUIRE(f.runUntil([&] {
    return f.at(kIdA).sawAlive(kIdB, true) && f.at(kIdC).sawAlive(kIdB, true) &&
           f.mutualAlive(ids);
  }, 3000));
  CHECK(f.at(kIdA).peer(kIdB).epoch == 2);
}

TEST_CASE("mesh: leader death promotes the next candidate after lease expiry") {
  Fleet f;
  f.add(kIdA, "A", capsJson(10));
  f.add(kIdB, "B", capsJson(20));
  f.add(kIdC, "C", capsJson(5));
  const std::vector<std::string> ids = {kIdA, kIdB, kIdC};
  REQUIRE(f.runUntil([&] { return f.mutualAlive(ids); }, 3000));
  REQUIRE(f.runUntil([&] {
    return f.leaderIs(ids, "telegram", kIdB) && f.leaderIs(ids, "mqtt_bridge", kIdB);
  }, 3000));

  f.at(kIdC).leader_changes.clear();
  f.net.killNode("B");

  REQUIRE(f.runUntil([&] {
    return f.at(kIdA).mesh->leaderFor("telegram") == kIdA &&
           f.at(kIdC).mesh->leaderFor("telegram") == kIdA &&
           f.at(kIdC).mesh->leaderFor("mqtt_bridge") == kIdA;
  }, 3000));
  CHECK(f.at(kIdA).mesh->isLeader("telegram"));

  CHECK(std::find(f.at(kIdC).leader_changes.begin(), f.at(kIdC).leader_changes.end(),
                  std::make_pair(std::string("telegram"), kIdA)) !=
        f.at(kIdC).leader_changes.end());
}



TEST_CASE("mesh: joinCluster retrieves PSK and config snapshot before joining") {
  Fleet f;
  Fleet::Node& host = f.add(kIdA, "A", capsJson(10), {{}, /*beacon=*/false});
  host.config->set("cluster.name", "\"京阪ハウス\"");
  host.config->set("doors.front.label", "\"正面玄関\"");
  f.run(100);

  auto token = host.mesh->createJoinToken();
  CHECK(token.pin.size() == 6);
  CHECK(token.expires_mono > f.clock.monoMs());


  Fleet::Node& joiner = f.add(kIdJ, "J", capsJson(3), {{}, /*beacon=*/false, 1,
                                                       /*zero_psk=*/true});
  std::vector<std::pair<bool, std::string>> results;
  joiner.mesh->joinCluster("A", token.pin, [&](bool ok, const std::string& err) {
    results.emplace_back(ok, err);
  });
  REQUIRE(f.runUntil([&] { return !results.empty(); }, 2000));
  CHECK(results[0].first);
  CHECK(results[0].second == "");

  CHECK(joiner.config->get("cluster.name") == std::optional<std::string>("\"京阪ハウス\""));
  CHECK(joiner.config->get("doors.front.label") == std::optional<std::string>("\"正面玄関\""));

  REQUIRE(f.runUntil([&] { return f.mutualAlive({kIdA, kIdJ}); }, 3000));
  CHECK(f.at(kIdA).peer(kIdJ).connected);

  host.config->set("cluster.psk_id", "\"k1\"");
  REQUIRE(f.runUntil([&] {
    return joiner.config->get("cluster.psk_id") == std::optional<std::string>("\"k1\"");
  }, 2000));
}

TEST_CASE("mesh: joinCluster invalidates a token after bad PIN attempts or expiry") {
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

  auto r = attempt(token.pin);
  CHECK_FALSE(r.first);
  CHECK(r.second == "no_token");


  auto token2 = host.mesh->createJoinToken();
  f.clock.advance(10 * 60 * 1000 + 1000);
  f.loop.pumpDue();
  auto r2 = attempt(token2.pin);
  CHECK_FALSE(r2.first);
  CHECK(r2.second == "expired");


  auto r3 = attempt("123456");
  CHECK_FALSE(r3.first);
  CHECK(r3.second == "no_token");
}



TEST_CASE("mesh: membership, config, and events converge with loss and delay") {
  Fleet f;
  f.net.setDrop(0.20, 20250827);
  f.net.setDelayMs(3);
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

  for (const auto& id : ids) {
    CHECK(f.at(id).events->heads()[kIdA] == 1);
    CHECK(f.at(id).events->heads()[kIdB] == 1);
  }
  CHECK(f.at(kIdB).remote_events == 1);
  CHECK(f.at(kIdC).remote_events == 2);

  REQUIRE(f.runUntil([&] { return f.leaderIs(ids, "telegram", kIdB); }, 10000));
}



TEST_CASE("mesh: real TcpTransport performs loopback handshake, ping, and config sync") {
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




std::vector<std::string> pendingIds(const std::string& js) {
  std::vector<std::string> out;
  json::Doc d = json::parse(js);
  if (!d) return out;
  const cJSON* arr = json::get(d.get(), "devices");
  const cJSON* it = nullptr;
  cJSON_ArrayForEach(it, arr) { out.push_back(json::getString(it, "id")); }
  return out;
}

TEST_CASE("mesh: pairing discovery and invite provide PSK and config to an unpaired node") {
  Fleet f;

  Fleet::Node& host = f.add(kIdA, "A", capsJson(10), {{}, /*beacon=*/true});
  host.config->set("cluster.name", "\"京阪ハウス\"");
  host.config->set("doors.front.label", "\"正面玄関\"");

  Fleet::Node& joiner = f.add(kIdJ, "J", capsJson(3), {{}, /*beacon=*/true, 1, /*zero_psk=*/true});
  CHECK_FALSE(joiner.mesh->isPaired());
  CHECK(host.mesh->isPaired());


  REQUIRE(f.runUntil([&] {
    auto ids = pendingIds(host.mesh->pendingJson());
    return std::find(ids.begin(), ids.end(), kIdJ) != ids.end();
  }, 3000));
  CHECK(host.pending_changes >= 1);


  host.mesh->inviteDevice(kIdJ);
  REQUIRE(f.runUntil([&] { return joiner.mesh->isPaired(); }, 3000));
  CHECK(joiner.paired_count >= 1);

  CHECK(joiner.config->get("cluster.name") == std::optional<std::string>("\"京阪ハウス\""));
  CHECK(joiner.config->get("doors.front.label") == std::optional<std::string>("\"正面玄関\""));

  REQUIRE(f.runUntil([&] { return f.mutualAlive({kIdA, kIdJ}); }, 4000));

  host.config->set("cluster.tz", "\"Asia/Tokyo\"");
  REQUIRE(f.runUntil([&] {
    return joiner.config->get("cluster.tz") == std::optional<std::string>("\"Asia/Tokyo\"");
  }, 3000));
}

TEST_CASE("mesh: inviteDeviceDirect accepts address and public key without discovery") {
  Fleet f;

  Fleet::Node& host = f.add(kIdA, "A", capsJson(10), {{}, /*beacon=*/false});
  host.config->set("cluster.name", "\"京阪ハウス\"");
  Fleet::Node& joiner = f.add(kIdJ, "J", capsJson(3), {{}, /*beacon=*/false, 1, /*zero_psk=*/true});
  f.run(100);
  CHECK(pendingIds(host.mesh->pendingJson()).empty());


  json::Doc self = json::parse(joiner.mesh->pairingSelfJson());
  REQUIRE(self);
  const std::string addr = json::getString(self.get(), "addr");
  const std::string pk = json::getString(self.get(), "pk");
  CHECK(pk.size() == 64);

  host.mesh->inviteDeviceDirect(addr, pk);
  REQUIRE(f.runUntil([&] { return joiner.mesh->isPaired(); }, 3000));
  CHECK(joiner.config->get("cluster.name") == std::optional<std::string>("\"京阪ハウス\""));
  REQUIRE(f.runUntil([&] { return f.mutualAlive({kIdA, kIdJ}); }, 4000));
}

TEST_CASE("mesh: pairing mode automatically invites newly discovered unpaired nodes") {
  Fleet f;
  Fleet::Node& host = f.add(kIdA, "A", capsJson(10), {{}, /*beacon=*/true});
  host.config->set("cluster.name", "\"京阪ハウス\"");

  host.mesh->setPairingMode(10 * 60 * 1000);


  Fleet::Node& joiner = f.add(kIdJ, "J", capsJson(3), {{}, /*beacon=*/true, 1, /*zero_psk=*/true});
  REQUIRE(f.runUntil([&] { return joiner.mesh->isPaired(); }, 4000));
  CHECK(joiner.config->get("cluster.name") == std::optional<std::string>("\"京阪ハウス\""));
  REQUIRE(f.runUntil([&] { return f.mutualAlive({kIdA, kIdJ}); }, 4000));
}

TEST_CASE("mesh: foundCluster requires a paired founder and creates a real PSK") {
  Fleet f;

  Fleet::Node& founder =
      f.add(kIdA, "A", capsJson(10), {{}, /*beacon=*/false, 1, /*zero_psk=*/true});
  CHECK_FALSE(founder.mesh->isPaired());

  CHECK(founder.mesh->createJoinToken().pin.empty());


  CHECK(founder.mesh->foundCluster());
  CHECK(founder.mesh->isPaired());
  CHECK(founder.paired_count >= 1);
  CHECK_FALSE(founder.mesh->foundCluster());
  founder.config->set("cluster.name", "\"京阪ハウス\"");


  auto token = founder.mesh->createJoinToken();
  CHECK(token.pin.size() == 6);
  Fleet::Node& joiner =
      f.add(kIdJ, "J", capsJson(3), {{}, /*beacon=*/false, 1, /*zero_psk=*/true});
  std::vector<std::pair<bool, std::string>> res;
  joiner.mesh->joinCluster("A", token.pin, [&](bool ok, const std::string& e) {
    res.emplace_back(ok, e);
  });
  REQUIRE(f.runUntil([&] { return !res.empty(); }, 2000));
  CHECK(res[0].first);
  CHECK(joiner.mesh->isPaired());
  CHECK(joiner.config->get("cluster.name") == std::optional<std::string>("\"京阪ハウス\""));
}

TEST_CASE("mesh: an unpaired host rejects join attempts") {
  Fleet f;
  Fleet::Node& host =
      f.add(kIdA, "A", capsJson(10), {{}, /*beacon=*/false, 1, /*zero_psk=*/true});
  Fleet::Node& joiner =
      f.add(kIdJ, "J", capsJson(3), {{}, /*beacon=*/false, 1, /*zero_psk=*/true});

  std::vector<std::pair<bool, std::string>> res;
  joiner.mesh->joinCluster("A", "123456", [&](bool ok, const std::string& e) {
    res.emplace_back(ok, e);
  });
  REQUIRE(f.runUntil([&] { return !res.empty(); }, 2000));
  CHECK_FALSE(res[0].first);
  CHECK(res[0].second == "host_unpaired");
  CHECK_FALSE(joiner.mesh->isPaired());
}

TEST_CASE("mesh: an unpaired node cannot issue invitations") {
  Fleet f;

  Fleet::Node& a = f.add(kIdA, "A", capsJson(10), {{}, /*beacon=*/true, 1, /*zero_psk=*/true});
  Fleet::Node& b = f.add(kIdJ, "J", capsJson(3), {{}, /*beacon=*/true, 1, /*zero_psk=*/true});
  f.run(1000);

  CHECK(pendingIds(a.mesh->pendingJson()).empty());
  CHECK(pendingIds(b.mesh->pendingJson()).empty());
  a.mesh->inviteDevice(kIdJ);
  f.run(1000);
  CHECK_FALSE(b.mesh->isPaired());
}



namespace {

const cJSON* pendingDevice(const std::string& js, const std::string& id) {
  static json::Doc held;
  held = json::parse(js);
  if (!held) return nullptr;
  const cJSON* it = nullptr;
  cJSON_ArrayForEach(it, json::get(held.get(), "devices")) {
    if (json::getString(it, "id") == id) return it;
  }
  return nullptr;
}

}  // namespace

TEST_CASE("mesh: an acknowledged invitation reports invite_result, then device_joined") {
  Fleet f;
  Fleet::Node& host = f.add(kIdA, "A", capsJson(10), {{}, /*beacon=*/true});
  Fleet::Node& joiner = f.add(kIdJ, "J", capsJson(3),
                              {{}, /*beacon=*/true, 1, /*zero_psk=*/true, {}, "indoor_panel", "",
                               "iPad mini 3", "ios"});

  REQUIRE(f.runUntil([&] { return pendingDevice(host.mesh->pendingJson(), kIdJ) != nullptr; },
                     3000));
  // C8: the device card is filled from the beacon, not guessed by the shell.
  const cJSON* card = pendingDevice(host.mesh->pendingJson(), kIdJ);
  REQUIRE(card);
  CHECK(json::getString(card, "model") == "iPad mini 3");
  CHECK(json::getString(card, "platform") == "ios");
  CHECK(json::getString(card, "role") == "indoor_panel");
  CHECK(json::getString(card, "invite_state") == "none");

  host.mesh->inviteDevice(kIdJ);
  REQUIRE(f.runUntil([&] { return !host.invite_results.empty(); }, 4000));
  CHECK(host.invite_results[0].ok);
  CHECK(host.invite_results[0].id == kIdJ);
  CHECK(host.invite_results[0].err == "");
  CHECK(joiner.mesh->isPaired());

  // The positive confirmation is the secure channel, not the acknowledgement.
  REQUIRE(f.runUntil([&] { return !host.joined.empty(); }, 5000));
  CHECK(host.joined[0] == kIdJ);
  CHECK(pendingIds(host.mesh->pendingJson()).empty());
}

TEST_CASE("mesh: a manual invitation to a silent device retries and then reports no_ack") {
  Fleet f;
  Fleet::Node& host = f.add(kIdA, "A", capsJson(10), {{}, /*beacon=*/true});
  f.add(kIdJ, "J", capsJson(3), {{}, /*beacon=*/true, 1, /*zero_psk=*/true});
  REQUIRE(f.runUntil([&] { return pendingDevice(host.mesh->pendingJson(), kIdJ) != nullptr; },
                     3000));

  f.net.killNode("J");
  host.mesh->inviteDevice(kIdJ);
  REQUIRE(f.runUntil([&] { return !host.invite_results.empty(); }, 20000));
  CHECK_FALSE(host.invite_results[0].ok);
  CHECK(host.invite_results[0].err == "no_ack");
  CHECK(host.invite_results[0].id == kIdJ);

  const cJSON* card = pendingDevice(host.mesh->pendingJson(), kIdJ);
  REQUIRE(card);
  CHECK(json::getString(card, "invite_state") == "failed");
  CHECK(json::getInt(card, "attempts", 0) == 3);
  CHECK(json::getString(card, "last_error") == "no_ack");
}

TEST_CASE("mesh: denyDevice drops a pending device and keeps ignoring its announcements") {
  Fleet f;
  Fleet::Node& host = f.add(kIdA, "A", capsJson(10), {{}, /*beacon=*/true});
  f.add(kIdJ, "J", capsJson(3), {{}, /*beacon=*/true, 1, /*zero_psk=*/true});
  REQUIRE(f.runUntil([&] { return pendingDevice(host.mesh->pendingJson(), kIdJ) != nullptr; },
                     3000));

  host.mesh->denyDevice(kIdJ);
  CHECK(pendingIds(host.mesh->pendingJson()).empty());
  f.run(2000);
  CHECK(pendingIds(host.mesh->pendingJson()).empty());
}

TEST_CASE("mesh: an invitation to an already paired device is rejected, not ignored") {
  Fleet f;
  Fleet::Node& host = f.add(kIdA, "A", capsJson(10), {{}, /*beacon=*/false});
  Fleet::Node& other = f.add(kIdB, "B", capsJson(5), {{}, /*beacon=*/false});
  f.run(100);

  json::Doc self = json::parse(other.mesh->pairingSelfJson());
  REQUIRE(self);
  host.mesh->inviteDeviceDirect(json::getString(self.get(), "addr"),
                                json::getString(self.get(), "pk"));
  REQUIRE(f.runUntil([&] { return !host.invite_results.empty(); }, 4000));
  CHECK_FALSE(host.invite_results[0].ok);
  CHECK(host.invite_results[0].err == "already_paired");
  REQUIRE_FALSE(other.invite_rejects.empty());
  CHECK(other.invite_rejects[0] == "already_paired");
}

TEST_CASE("mesh: unpair clears the key, drops peers, and allows joining another cluster") {
  Fleet f;
  Fleet::Node& host = f.add(kIdA, "A", capsJson(10), {{}, /*beacon=*/true});
  Fleet::Node& joiner = f.add(kIdJ, "J", capsJson(3), {{}, /*beacon=*/true, 1,
                                                       /*zero_psk=*/true});
  REQUIRE(f.runUntil([&] { return pendingDevice(host.mesh->pendingJson(), kIdJ) != nullptr; },
                     3000));
  host.mesh->inviteDevice(kIdJ);
  REQUIRE(f.runUntil([&] { return f.mutualAlive({kIdA, kIdJ}); }, 5000));

  joiner.mesh->unpair();
  CHECK_FALSE(joiner.mesh->isPaired());
  CHECK(joiner.unpaired_count == 1);
  CHECK(joiner.mesh->peers().size() == 1);  // only itself
  CHECK(joiner.mesh->createJoinToken().pin.empty());

  // Announcing resumes, so the same node can be added again without a restart.
  REQUIRE(f.runUntil([&] { return pendingDevice(host.mesh->pendingJson(), kIdJ) != nullptr; },
                     4000));
  host.mesh->inviteDevice(kIdJ);
  REQUIRE(f.runUntil([&] { return joiner.mesh->isPaired(); }, 4000));
  REQUIRE(f.runUntil([&] { return f.mutualAlive({kIdA, kIdJ}); }, 6000));
}

TEST_CASE("mesh: JOIN_OK is refused once an invitation has already paired the node") {
  Fleet f;
  Fleet::Node& host = f.add(kIdA, "A", capsJson(10), {{}, /*beacon=*/false});
  Fleet::Node& joiner = f.add(kIdJ, "J", capsJson(3), {{}, /*beacon=*/false, 1,
                                                       /*zero_psk=*/true});
  auto token = host.mesh->createJoinToken();

  std::vector<std::pair<bool, std::string>> res;
  joiner.mesh->joinCluster("A", token.pin, [&](bool ok, const std::string& err) {
    res.emplace_back(ok, err);
  });
  // The node pairs by another route while the code join is still in flight.
  CHECK(joiner.mesh->foundCluster());
  REQUIRE(f.runUntil([&] { return !res.empty(); }, 3000));
  CHECK_FALSE(res[0].first);
  CHECK(res[0].second == "already_paired");
  CHECK(joiner.paired_count == 1);  // no duplicate paired notification
}

TEST_CASE("mesh: joinCluster on a paired node answers already_paired") {
  Fleet f;
  Fleet::Node& host = f.add(kIdA, "A", capsJson(10), {{}, /*beacon=*/false});
  std::vector<std::pair<bool, std::string>> res;
  host.mesh->joinCluster("A", "123456", [&](bool ok, const std::string& err) {
    res.emplace_back(ok, err);
  });
  REQUIRE(f.runUntil([&] { return !res.empty(); }, 2000));
  CHECK_FALSE(res[0].first);
  CHECK(res[0].second == "already_paired");
}

TEST_CASE("mesh: an invitation carrying an all-zero cluster key is rejected") {
  Fleet f;
  Fleet::Node& joiner = f.add(kIdJ, "J", capsJson(3), {{}, /*beacon=*/false, 1,
                                                       /*zero_psk=*/true});
  f.run(50);
  json::Doc self = json::parse(joiner.mesh->pairingSelfJson());
  REQUIRE(self);
  Bytes pk;
  REQUIRE(hexDecode(json::getString(self.get(), "pk"), pk));
  REQUIRE(pk.size() == 32);

  // Seal a well-formed invitation whose PSK is all zeros, exactly what a broken or hostile
  // inviter would send.
  Bytes esk = randomBytes(32);
  std::array<uint8_t, 32> epk{}, shared{}, key{};
  crypto_x25519_public_key(epk.data(), esk.data());
  crypto_x25519(shared.data(), esk.data(), pk.data());
  crypto_blake2b(key.data(), 32, shared.data(), shared.size());
  const std::string plain =
      "{\"psk\":\"" + std::string(64, '0') + "\",\"psk_id\":\"k1\",\"seeds\":[],\"cfg\":[]}";
  Bytes nonce = randomBytes(24);
  Bytes sealed(16 + plain.size());
  crypto_aead_lock(sealed.data() + 16, sealed.data(), key.data(), nonce.data(), nullptr, 0,
                   reinterpret_cast<const uint8_t*>(plain.data()), plain.size());
  auto o = json::obj();
  json::set(o.get(), "t", "INVITE");
  json::set(o.get(), "epk", hexEncode(epk.data(), epk.size()));
  json::set(o.get(), "n", hexEncode(nonce));
  json::set(o.get(), "c", hexEncode(sealed));
  const std::string body = json::dump(o.get());
  Bytes frame;
  frame.push_back(kFrameJoin);
  frame.insert(frame.end(), body.begin(), body.end());

  auto sender = f.net.makeTransport("X");
  sender->connect("J", [&](ConnPtr conn) {
    REQUIRE(conn);
    conn->setCallbacks([](const Bytes&) {}, [] {});
    conn->send(frame);
  });
  REQUIRE(f.runUntil([&] { return !joiner.invite_rejects.empty(); }, 3000));
  CHECK(joiner.invite_rejects[0] == "host_zero_psk");
  CHECK_FALSE(joiner.mesh->isPaired());
}

TEST_CASE("mesh: the join token reports its countdown, attempts, and expiry") {
  Fleet f;
  Fleet::Node& host = f.add(kIdA, "A", capsJson(10), {{}, /*beacon=*/false});
  Fleet::Node& joiner = f.add(kIdJ, "J", capsJson(3), {{}, /*beacon=*/false, 1,
                                                       /*zero_psk=*/true});

  json::Doc idle = json::parse(host.mesh->tokenJson());
  REQUIRE(idle);
  CHECK_FALSE(json::getBool(idle.get(), "active"));
  CHECK(json::get(idle.get(), "pin") == nullptr);

  auto token = host.mesh->createJoinToken();
  REQUIRE(host.token_changes.size() == 1);
  json::Doc live = json::parse(host.mesh->tokenJson());
  REQUIRE(live);
  CHECK(json::getBool(live.get(), "active"));
  CHECK(json::getString(live.get(), "pin") == token.pin);
  CHECK(json::getString(live.get(), "host") == "A");
  CHECK(json::getInt(live.get(), "attempts_left", 0) == 3);
  const int64_t first = json::getInt(live.get(), "expires_s", 0);
  CHECK(first > 590);

  f.run(5000);
  json::Doc later = json::parse(host.mesh->tokenJson());
  CHECK(json::getInt(later.get(), "expires_s", 0) < first);

  std::vector<std::pair<bool, std::string>> res;
  const std::string wrong = token.pin == "000000" ? "000001" : "000000";
  joiner.mesh->joinCluster("A", wrong, [&](bool ok, const std::string& e) {
    res.emplace_back(ok, e);
  });
  REQUIRE(f.runUntil([&] { return !res.empty(); }, 2000));
  CHECK(res[0].second == "bad_pin");
  json::Doc burned = json::parse(host.mesh->tokenJson());
  CHECK(json::getInt(burned.get(), "attempts_left", 0) == 2);

  f.run(10 * 60 * 1000 + 2000);
  json::Doc expired = json::parse(host.mesh->tokenJson());
  CHECK_FALSE(json::getBool(expired.get(), "active"));
  CHECK(json::get(expired.get(), "pin") == nullptr);
  // Mint, one bad attempt, and expiry all reach the shell.
  CHECK(host.token_changes.size() >= 3);
  CHECK(host.token_changes.back().rfind("0:", 0) == 0);
}

TEST_CASE("mesh: pairing mode reports start, stop, and how many devices it added") {
  Fleet f;
  Fleet::Node& host = f.add(kIdA, "A", capsJson(10), {{}, /*beacon=*/true});
  host.mesh->setPairingMode(10 * 60 * 1000);
  REQUIRE(host.mode_changes.size() == 1);
  CHECK(host.mode_changes[0].rfind("1:", 0) == 0);

  Fleet::Node& joiner = f.add(kIdJ, "J", capsJson(3), {{}, /*beacon=*/true, 1,
                                                       /*zero_psk=*/true});
  REQUIRE(f.runUntil([&] { return joiner.mesh->isPaired(); }, 4000));
  REQUIRE(f.runUntil([&] { return !host.joined.empty(); }, 5000));

  json::Doc pending = json::parse(host.mesh->pendingJson());
  REQUIRE(pending);
  CHECK(json::getBool(pending.get(), "pairing_mode"));
  CHECK(json::getInt(pending.get(), "auto_added_count", 0) == 1);

  host.mesh->setPairingMode(0);
  json::Doc off = json::parse(host.mesh->pendingJson());
  CHECK_FALSE(json::getBool(off.get(), "pairing_mode"));
  REQUIRE(host.mode_changes.size() >= 2);
  CHECK(host.mode_changes.back().rfind("0:", 0) == 0);
}

TEST_CASE("mesh: discovery is rekeyed when a node creates or joins a cluster at runtime") {
  Fleet f;
  // Both nodes start unpaired, so neither can be discovered by the other yet.
  Fleet::Node& founder = f.add(kIdA, "A", capsJson(10), {{}, /*beacon=*/true, 1,
                                                         /*zero_psk=*/true});
  Fleet::Node& other = f.add(kIdJ, "J", capsJson(3), {{}, /*beacon=*/true, 1,
                                                      /*zero_psk=*/true});
  f.run(500);
  CHECK(founder.peer(kIdJ).id.empty());

  REQUIRE(founder.mesh->foundCluster());
  REQUIRE(f.runUntil([&] { return pendingDevice(founder.mesh->pendingJson(), kIdJ) != nullptr; },
                     3000));
  founder.mesh->inviteDevice(kIdJ);
  REQUIRE(f.runUntil([&] { return other.mesh->isPaired(); }, 4000));

  // Without the beacon rekey the two would never find each other until a restart.
  REQUIRE(f.runUntil([&] { return f.mutualAlive({kIdA, kIdJ}); }, 6000));
}

TEST_CASE("udp_beacon: a keyed HELLO is discovered and a zero-key HELLO is ignored") {
  RealClock clock;
  Runloop loop(clock);
  loop.start();
  const uint16_t port = 47191;
  const auto psk = mkPsk(0x37);
  UdpBeacon beacon(loop, psk, "239.255.71.72", port, 1000);
  std::vector<std::string> found;
  std::mutex mu;
  beacon.start([&](const DiscoveredPeer& p) {
    std::lock_guard<std::mutex> lk(mu);
    found.push_back(p.node_id);
  });
  loop.callSync([&] { beacon.announce(kIdA, "127.0.0.1:47172"); });

  auto mac = [](const std::array<uint8_t, 32>& key, const std::string& id,
                const std::string& addr) {
    static const uint8_t kTag[6] = {'b', 'e', 'a', 'c', 'o', 'n'};
    crypto_blake2b_ctx ctx;
    crypto_blake2b_keyed_init(&ctx, 32, key.data(), key.size());
    crypto_blake2b_update(&ctx, kTag, sizeof(kTag));
    crypto_blake2b_update(&ctx, reinterpret_cast<const uint8_t*>(id.data()), id.size());
    crypto_blake2b_update(&ctx, reinterpret_cast<const uint8_t*>(addr.data()), addr.size());
    uint8_t out[32];
    crypto_blake2b_final(&ctx, out);
    return hexEncode(out, 16);
  };
  auto hello = [&](const std::string& id, const std::string& addr, const std::string& m) {
    auto o = json::obj();
    json::set(o.get(), "v", int64_t{1});
    json::set(o.get(), "id", id);
    json::set(o.get(), "addr", addr);
    json::set(o.get(), "mac", m);
    return json::dump(o.get());
  };

  int fd = ::socket(AF_INET, SOCK_DGRAM, 0);
  REQUIRE(fd >= 0);
  sockaddr_in dst{};
  dst.sin_family = AF_INET;
  dst.sin_port = htons(port);
  ::inet_pton(AF_INET, "127.0.0.1", &dst.sin_addr);

  const std::array<uint8_t, 32> zero{};
  const std::string spoof = hello(kIdC, "10.0.0.9:47172", mac(zero, kIdC, "10.0.0.9:47172"));
  const std::string real = hello(kIdB, "10.0.0.8:47172", mac(psk, kIdB, "10.0.0.8:47172"));
  ::sendto(fd, spoof.data(), spoof.size(), 0, reinterpret_cast<sockaddr*>(&dst), sizeof(dst));
  ::sendto(fd, real.data(), real.size(), 0, reinterpret_cast<sockaddr*>(&dst), sizeof(dst));
  ::usleep(400 * 1000);
  ::close(fd);
  beacon.stop();
  loop.stop();

  std::lock_guard<std::mutex> lk(mu);
  CHECK(std::find(found.begin(), found.end(), kIdC) == found.end());
  WARN_MESSAGE(std::find(found.begin(), found.end(), kIdB) != found.end(),
               "loopback UDP delivery unavailable in this environment");
}

TEST_CASE("udp_beacon: multicast smoke test sends without errors") {
  RealClock clock;
  Runloop loop(clock);
  loop.start();
  UdpBeacon beacon(loop, mkPsk(0x11), "239.255.71.71", 47171, 50);
  int found = 0;
  beacon.start([&](const DiscoveredPeer&) { found++; });
  loop.callSync([&] { beacon.announce(kIdA, "127.0.0.1:47172"); });
  ::usleep(250 * 1000);


  WARN_MESSAGE(beacon.sentCount() >= 1, "no beacons sent; multicast may be unavailable");
  WARN_MESSAGE(beacon.sendErrorCount() == 0, "multicast send failed; environment may not support it");
  beacon.stop();
  loop.stop();
}
