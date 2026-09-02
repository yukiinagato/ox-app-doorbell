



#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cstdio>
#include <memory>
#include <random>
#include <string>
#include <vector>

#include "doctest.h"
#include "mesh/mesh.h"
#include "node/node.h"
#include "store/store.h"
#include "util/clock.h"
#include "util/common.h"
#include "util/hlc.h"
#include "util/ids.h"
#include "util/json.h"
#include "util/runloop.h"

using namespace db;

namespace {

struct EmFleet {
  SimClock clock{1'700'000'000'000LL, 0};
  Runloop loop{clock};
  InMemNet net{loop};
  std::array<uint8_t, 32> psk{};

  EmFleet() { psk.fill(0x5a); }

  static MeshSettings timing() {
    MeshSettings m;
    m.heartbeat_ms = 30;
    m.suspect_ms = 90;
    m.dead_ms = 150;
    m.gossip_ms = 50;
    m.sync_ms = 50;
    m.claim_ttl_ms = 300;
    m.reconnect_ms = 50;
    return m;
  }

  struct N {
    std::unique_ptr<Node> node;
    std::vector<std::string> ui;

    size_t emCount(bool active) const {
      size_t n = 0;
      for (const auto& e : ui) {
        auto d = json::parse(e);
        if (d && json::getString(d.get(), "t") == "emergency" &&
            json::getBool(d.get(), "active") == active)
          n++;
      }
      return n;
    }
  };
  std::vector<std::unique_ptr<N>> nodes;

  N& add(const std::string& addr, const std::string& name, const std::string& role,
         const std::string& door, bool seed_cfg, const std::string& data_dir = ":memory:") {
    NodeOptions o;
    o.data_dir = data_dir;
    o.name = name;
    o.role = role;
    o.door = door;
    o.listen_addr = addr;
    o.advertise_addr = addr;
    o.psk = psk;
    o.enable_beacon = false;
    o.http_port = 0;
    o.seed_default_config = seed_cfg;
    o.mesh_timing_template = timing();
    o.use_mesh_timing_template = true;
    NodeDeps d;
    d.clock = &clock;
    d.loop = &loop;
    d.transport = net.makeTransport(addr);
    d.discovery = net.makeDiscovery(addr);
    auto n = std::make_unique<N>();
    N* raw = n.get();
    n->node.reset(new Node(o, std::move(d)));
    n->node->setUiEventCb([raw](const std::string& e) { raw->ui.push_back(e); });
    n->node->setRuntimeCapabilities(R"({"features":{"device_alert_v1":true}})");
    nodes.push_back(std::move(n));
    return *nodes.back();
  }

  void run(int64_t ms, int64_t step = 10) {
    for (int64_t t = 0; t < ms; t += step) {
      clock.advance(step);
      loop.pumpDue();
    }
  }
};

bool statusEmergency(Node& node) {
  auto st = json::parse(node.statusJson());
  REQUIRE(st);
  return json::getBool(json::get(st.get(), "emergency"), "active");
}

}  // namespace

TEST_CASE("emergency: activation and clearing update UI state on both nodes") {
  EmFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true);
  auto& b = f.add("B:1", "kitchen", "indoor_panel", "", false);
  REQUIRE(a.node->start());
  REQUIRE(b.node->start());
  f.run(1500);


  CHECK(a.emCount(false) >= 1);
  CHECK(b.emCount(false) >= 1);
  CHECK(a.emCount(true) == 0);
  CHECK(statusEmergency(*a.node) == false);
  const size_t a0 = a.emCount(false), b0 = b.emCount(false);


  b.node->setEmergency(true, "panel");
  f.run(800);
  CHECK(a.emCount(true) == 1);
  CHECK(b.emCount(true) == 1);
  CHECK(statusEmergency(*a.node) == true);
  CHECK(statusEmergency(*b.node) == true);
  size_t delivery_results = 0;
  for (const auto& raw : a.ui) {
    auto event = json::parse(raw);
    if (event && json::getString(event.get(), "t") == "event" &&
        json::getString(event.get(), "type") == "delivery_result")
      ++delivery_results;
  }
  CHECK(delivery_results >= 2);  // one local-shell dispatch record per targeted Core node

  {
    size_t n = 0;
    for (const auto& e : a.ui) {
      auto d = json::parse(e);
      if (d && json::getString(d.get(), "t") == "event" &&
          json::getString(d.get(), "type") == "emergency")
        n++;
    }
    CHECK(n == 1);
  }


  b.node->setEmergency(true, "panel");
  f.run(500);
  CHECK(a.emCount(true) == 1);
  CHECK(b.emCount(true) == 1);


  a.node->setEmergency(false, "admin");
  f.run(800);
  CHECK(a.emCount(false) == a0 + 1);
  CHECK(b.emCount(false) == b0 + 1);
  CHECK(statusEmergency(*a.node) == false);
  CHECK(statusEmergency(*b.node) == false);

  a.node->stop();
  b.node->stop();
}

TEST_CASE("emergency: state replication is independent from configurable alert recipients") {
  EmFleet f;
  auto& door = f.add("A:1", "front", "door_station", "d_front", true);
  REQUIRE(door.node->start());
  f.run(300);

  door.node->setConfigKey(
      "trigger_rules.r_sos_default_on",
      "{\"enabled\":true,\"when\":{\"type\":\"emergency_on\"},\"actions\":[{"
      "\"type\":\"device_alert\",\"targets\":{\"roles\":[\"indoor_panel\"]},"
      "\"channels\":[\"in_app\"]}]}");
  f.run(50);
  door.node->setEmergency(true, "test");
  f.run(300);
  CHECK(statusEmergency(*door.node) == true);
  CHECK(door.emCount(true) == 0);  // role target excludes the door station

  door.node->setEmergency(false, "test");
  f.run(300);
  door.node->setConfigKey(
      "trigger_rules.r_sos_default_on",
      "{\"enabled\":true,\"when\":{\"type\":\"emergency_on\"},\"actions\":[{"
      "\"type\":\"device_alert\",\"targets\":{\"roles\":[]},\"channels\":[]}]}");
  f.run(50);
  door.node->setEmergency(true, "test");
  f.run(300);
  CHECK(statusEmergency(*door.node) == true);
  CHECK(door.emCount(true) == 0);  // an explicit zero-recipient/silent rule is valid

  door.node->setEmergency(false, "test");
  f.run(300);
  door.node->setConfigKey(
      "trigger_rules.r_sos_default_on",
      "{\"enabled\":true,\"when\":{\"type\":\"emergency_on\"},\"actions\":[{"
      "\"type\":\"device_alert\",\"targets\":{\"web_subscription_groups\":[\"guards\"]},"
      "\"channels\":[\"in_app\"],\"presentation\":{\"background\":\"#102040\","
      "\"foreground\":\"#FFFFFF\",\"accent\":\"#FFD166\"}}]}");
  f.run(50);
  door.node->setEmergency(true, "test");
  f.run(300);
  CHECK(statusEmergency(*door.node) == true);
  CHECK(door.emCount(true) == 0);  // an explicit Web-only target never expands to native shells

  door.node->setEmergency(false, "test");
  f.run(300);
  door.node->setConfigKey(
      "trigger_rules.r_sos_default_on",
      "{\"enabled\":true,\"when\":{\"type\":\"emergency_on\"},\"actions\":[{"
      "\"type\":\"device_alert\",\"channels\":[\"in_app\"],\"presentation\":{"
      "\"background\":\"#102040\",\"foreground\":\"#FFFFFF\","
      "\"accent\":\"#FFD166\"}}]}");
  f.run(50);
  door.node->setEmergency(true, "test");
  f.run(300);
  bool palette_seen = false;
  for (const auto& raw : door.ui) {
    auto event = json::parse(raw);
    if (!event || json::getString(event.get(), "t") != "emergency" ||
        !json::getBool(event.get(), "active"))
      continue;
    palette_seen = json::getString(event.get(), "background") == "#102040" &&
                   json::getString(event.get(), "foreground") == "#FFFFFF" &&
                   json::getString(event.get(), "accent") == "#FFD166";
  }
  CHECK(palette_seen);

  door.node->stop();
}

TEST_CASE("emergency: event replay restores state after restart") {
  const std::string dir = "tmp_test_emergency_" + std::to_string(::getpid());

  {
    EmFleet f;
    auto& a = f.add("A:1", "front", "door_station", "d_front", true, dir);
    REQUIRE(a.node->start());
    f.run(500);
    a.node->setEmergency(true, "panel");
    f.run(500);
    CHECK(a.emCount(true) == 1);
    a.node->stop();
  }


  {
    EmFleet f;
    auto& a = f.add("A:1", "front", "door_station", "d_front", false, dir);
    REQUIRE(a.node->start());
    f.loop.pumpDue();
    CHECK(a.emCount(true) == 1);
    CHECK(a.emCount(false) == 0);
    CHECK(statusEmergency(*a.node) == true);


    a.node->setEmergency(false, "panel");
    f.run(500);
    CHECK(statusEmergency(*a.node) == false);
    a.node->stop();
  }
  {
    EmFleet f;
    auto& a = f.add("A:1", "front", "door_station", "d_front", false, dir);
    REQUIRE(a.node->start());
    f.loop.pumpDue();
    CHECK(a.emCount(true) == 0);
    CHECK(a.emCount(false) >= 1);
    CHECK(statusEmergency(*a.node) == false);
    a.node->stop();
  }


  for (const char* n : {"doorbell.db", "doorbell.db-wal", "doorbell.db-shm"})
    std::remove((dir + "/" + n).c_str());
  ::rmdir(dir.c_str());
}

TEST_CASE("emergency: startup does not present an older recovered activation over a newer clear") {
  const std::string dir =
      tempDir() + "/doorbell_stale_emergency_" + genTokenHex(8);
  REQUIRE(makeDir(dir));
  const std::string db_path = dir + "/doorbell.db";

  EventRecord cleared;
  cleared.origin = "cccccccc2222";
  cleared.seq = 1;
  cleared.type = "emergency_cancel";
  cleared.device = cleared.origin;
  cleared.hlc = HlcClock::format(20'000, 0, "cccccccc");
  cleared.wall_ms = 20'000;
  cleared.payload_json = R"({"schema_version":2,"source":"cccccccc2222"})";

  EventRecord gap;
  gap.origin = "bbbbbbbb1111";
  gap.seq = 1;
  gap.type = "motion";
  gap.door = "d_front";
  gap.device = gap.origin;
  gap.hlc = HlcClock::format(5'000, 0, "bbbbbbbb");
  gap.wall_ms = 5'000;
  gap.payload_json = "{}";

  EventRecord stale_active = gap;
  stale_active.seq = 2;
  stale_active.type = "emergency";
  stale_active.hlc = HlcClock::format(10'000, 0, "bbbbbbbb");
  stale_active.wall_ms = 10'000;
  stale_active.payload_json =
      R"({"schema_version":2,"source":"bbbbbbbb1111"})";

  {
    Store store;
    REQUIRE(store.open(db_path));
    LwwEntry stale_rule;
    stale_rule.key = "trigger_rules.stale_emergency_chime";
    stale_rule.value_json =
        R"({"enabled":true,"when":{"type":"emergency_on"},"actions":[{"type":"chime","devices":"all","sound":"stale-marker"}]})";
    stale_rule.hlc = HlcClock::format(1'000, 0, "dddddddd");
    stale_rule.author = "dddddddd3333";
    stale_rule.seq = 1;
    REQUIRE(store.configPut(stale_rule));
    REQUIRE(store.eventPut(cleared));
    REQUIRE(store.eventAckDispatched(cleared.origin, cleared.seq));
    REQUIRE(store.eventIngest(stale_active));
    REQUIRE(store.eventIngest(gap));
    CHECK(store.eventFrontier(stale_active.origin) == 0);
    CHECK(store.eventDispatchFrontier(stale_active.origin) == 0);
  }

  {
    EmFleet fleet;
    auto& door = fleet.add("A:1", "front", "door_station", "d_front", true, dir);
    REQUIRE(door.node->start());
    fleet.loop.pumpDue();
    CHECK(statusEmergency(*door.node) == false);
    CHECK(door.emCount(true) == 0);
    bool stale_chime = false;
    for (const auto& raw : door.ui) {
      auto event = json::parse(raw);
      if (event && json::getString(event.get(), "t") == "chime" &&
          json::getString(event.get(), "sound") == "stale-marker")
        stale_chime = true;
    }
    CHECK_FALSE(stale_chime);
    door.node->stop();
  }

  {
    Store store;
    REQUIRE(store.open(db_path));
    CHECK(store.eventFrontier(stale_active.origin) == 2);
    CHECK(store.eventDispatchFrontier(stale_active.origin) == 2);
    const std::string stale_id = stale_active.origin + ":" +
        std::to_string(stale_active.seq);
    bool stale_delivery = false;
    for (const auto& event : store.recentEvents(1000)) {
      if (event.type != "delivery_result") continue;
      auto payload = json::parse(event.payload_json);
      if (payload && json::getString(payload.get(), "source_event_id") == stale_id)
        stale_delivery = true;
    }
    CHECK_FALSE(stale_delivery);
  }

  for (const char* name : {"doorbell.db", "doorbell.db-wal", "doorbell.db-shm"})
    std::remove((dir + "/" + name).c_str());
  ::rmdir((dir + "/assets").c_str());
  ::rmdir(dir.c_str());
}



namespace {

int emFreePort(std::mt19937& rng) {
  std::uniform_int_distribution<int> dist(40000, 60000);
  for (int i = 0; i < 50; i++) {
    int port = dist(rng);
    int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) continue;
    sockaddr_in sa{};
    sa.sin_family = AF_INET;
    sa.sin_port = htons(static_cast<uint16_t>(port));
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int ok = ::bind(fd, reinterpret_cast<sockaddr*>(&sa), sizeof(sa));
    ::close(fd);
    if (ok == 0) return port;
  }
  return -1;
}

std::string emHttp(int port, const std::string& method, const std::string& path,
                   const std::string& body = "", const std::string& ctype = "",
                   const std::string& cookie = "") {
  int fd = ::socket(AF_INET, SOCK_STREAM, 0);
  REQUIRE(fd >= 0);
  sockaddr_in sa{};
  sa.sin_family = AF_INET;
  sa.sin_port = htons(static_cast<uint16_t>(port));
  sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  REQUIRE(::connect(fd, reinterpret_cast<sockaddr*>(&sa), sizeof(sa)) == 0);
  std::string r = method + " " + path + " HTTP/1.1\r\nHost: 127.0.0.1\r\n";
  if (!cookie.empty()) {
    if (cookie.rfind("Bearer ", 0) == 0) r += "Authorization: " + cookie + "\r\n";
    else r += "Cookie: " + cookie + "\r\n";
  }
  if (!body.empty())
    r += "Content-Type: " + (ctype.empty() ? "application/json" : ctype) +
         "\r\nContent-Length: " + std::to_string(body.size()) + "\r\n";
  r += "Connection: close\r\n\r\n" + body;
  REQUIRE(::send(fd, r.data(), r.size(), 0) == static_cast<ssize_t>(r.size()));
  std::string resp;
  char buf[8192];
  timeval tv{5, 0};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  for (;;) {
    ssize_t n = ::recv(fd, buf, sizeof(buf), 0);
    if (n <= 0) break;
    resp.append(buf, static_cast<size_t>(n));
  }
  ::close(fd);
  return resp;
}

}  // namespace

TEST_CASE("emergency API: panels may activate, while only admins may clear") {
  std::mt19937 rng(static_cast<uint32_t>(::getpid()) ^ 0xe5e5u);
  int mesh_port = emFreePort(rng);
  int http_port = emFreePort(rng);
  REQUIRE(mesh_port > 0);
  REQUIRE(http_port > 0);

  NodeOptions o;
  o.data_dir = ":memory:";
  o.name = "em-test";
  o.role = "indoor_panel";
  o.listen_addr = "127.0.0.1:" + std::to_string(mesh_port);
  {
    Bytes r = randomBytes(o.psk.size());
    std::copy(r.begin(), r.end(), o.psk.begin());
  }
  o.http_port = http_port;
  Node node(o);
  node.setSecureStore(
      [](const std::string& key) { return key == "panel.test" ? "emergency-panel-token" : ""; },
      [](const std::string&, const std::string&) { return true; });
  REQUIRE(node.start());
  node.setConfigKey("panel.token_refs", "[\"secret:panel.test\"]");
  const std::string panel_auth = "Bearer emergency-panel-token";


  CHECK(emHttp(http_port, "POST", "/api/panel/emergency").find("403") != std::string::npos);
  CHECK(emHttp(http_port, "POST", "/api/panel/emergency", "",
               "application/x-www-form-urlencoded", panel_auth)
            .find("{\"ok\":true}") != std::string::npos);
  {
    auto st = json::parse(node.statusJson());
    REQUIRE(st);
    CHECK(json::getBool(json::get(st.get(), "emergency"), "active") == true);
  }


  std::string resp = emHttp(http_port, "POST", "/api/panel/emergency", "active=0",
                            "application/x-www-form-urlencoded", panel_auth);
  CHECK(resp.rfind("HTTP/1.1 403", 0) == 0);
  CHECK(resp.find("cancel not allowed") != std::string::npos);
  {
    auto st = json::parse(node.statusJson());
    REQUIRE(st);
    CHECK(json::getBool(json::get(st.get(), "emergency"), "active") == true);
  }


  CHECK(emHttp(http_port, "POST", "/api/emergency", "{\"active\":false}")
            .rfind("HTTP/1.1 401", 0) == 0);


  std::string login = emHttp(http_port, "POST", "/api/login", "{\"password\":\"test123\"}");
  REQUIRE(login.rfind("HTTP/1.1 200", 0) == 0);
  auto cpos = login.find("dbsess=");
  REQUIRE(cpos != std::string::npos);
  std::string cookie = login.substr(cpos, login.find(';', cpos) - cpos);
  CHECK(emHttp(http_port, "POST", "/api/emergency", "{\"active\":false}", "", cookie)
            .find("{\"ok\":true}") != std::string::npos);
  {
    auto st = json::parse(node.statusJson());
    REQUIRE(st);
    CHECK(json::getBool(json::get(st.get(), "emergency"), "active") == false);
  }

  CHECK(emHttp(http_port, "POST", "/api/emergency", "{}", "", cookie)
            .find("400") != std::string::npos);

  node.stop();
}
