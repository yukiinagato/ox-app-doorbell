// SOS 緊急モードの統合テスト。
//  - InMemNet + SimClock 共有 Runloop: 発報/解除の全ノード複製と uiNotify
//  - 永続 Store: 再起動後 (イベント再生) の状態復元
//  - 実 TCP + HTTP: /api/emergency (admin) と /api/panel/emergency (panel token, トリガのみ)
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
#include "util/clock.h"
#include "util/common.h"
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
    // {"t":"emergency","active":<active>} の件数
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
    o.enable_beacon = false;  // 実 beacon 禁止 (稼働 fleet への迷入防止)
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

TEST_CASE("emergency: 発報 → 両ノード ui active=true → 解除 → false") {
  EmFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true);
  auto& b = f.add("B:1", "kitchen", "indoor_panel", "", false);
  REQUIRE(a.node->start());
  REQUIRE(b.node->start());
  f.run(1500);

  // 起動直後の初期状態は inactive (壳が初期状態を受け取れる)
  CHECK(a.emCount(false) >= 1);
  CHECK(b.emCount(false) >= 1);
  CHECK(a.emCount(true) == 0);
  CHECK(statusEmergency(*a.node) == false);
  const size_t a0 = a.emCount(false), b0 = b.emCount(false);

  // B (室内機) が発報 → 全ノードで active=true がちょうど 1 回
  b.node->setEmergency(true, "panel");
  f.run(800);
  CHECK(a.emCount(true) == 1);
  CHECK(b.emCount(true) == 1);
  CHECK(statusEmergency(*a.node) == true);
  CHECK(statusEmergency(*b.node) == true);
  // イベントとしても両ノードに届く
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

  // 再発報 (同状態) は遷移ではない → uiNotify は増えない
  b.node->setEmergency(true, "panel");
  f.run(500);
  CHECK(a.emCount(true) == 1);
  CHECK(b.emCount(true) == 1);

  // A 側から解除 → 全ノード false
  a.node->setEmergency(false, "admin");
  f.run(800);
  CHECK(a.emCount(false) == a0 + 1);
  CHECK(b.emCount(false) == b0 + 1);
  CHECK(statusEmergency(*a.node) == false);
  CHECK(statusEmergency(*b.node) == false);

  a.node->stop();
  b.node->stop();
}

TEST_CASE("emergency: 再起動後 (イベント再生) に状態が復元される") {
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

  // 再起動 (同じ data_dir) → 起動直後の uiNotify で active=true が届く
  {
    EmFleet f;
    auto& a = f.add("A:1", "front", "door_station", "d_front", false, dir);
    REQUIRE(a.node->start());
    f.loop.pumpDue();
    CHECK(a.emCount(true) == 1);
    CHECK(a.emCount(false) == 0);
    CHECK(statusEmergency(*a.node) == true);

    // 解除 → 再々起動では inactive で復元
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

  // 後始末 (best-effort)
  for (const char* n : {"doorbell.db", "doorbell.db-wal", "doorbell.db-shm"})
    std::remove((dir + "/" + n).c_str());
  ::rmdir(dir.c_str());
}

// ---------- 実 TCP + HTTP: admin / panel API ----------

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
  if (!cookie.empty()) r += "Cookie: " + cookie + "\r\n";
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

TEST_CASE("emergency API: panel トリガ 200 / panel 解除 403 / admin は両方可") {
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
  REQUIRE(node.start());

  // panel token を設定から取得
  auto cfg = json::parse(node.configJson());
  REQUIRE(cfg);
  cJSON* toks = json::get(json::get(cfg.get(), "panel"), "tokens");
  REQUIRE(cJSON_GetArraySize(toks) == 1);
  std::string k = cJSON_GetArrayItem(toks, 0)->valuestring;

  // token 無し → 403 / 発報 → 200
  CHECK(emHttp(http_port, "POST", "/api/panel/emergency").find("403") != std::string::npos);
  CHECK(emHttp(http_port, "POST", "/api/panel/emergency", "k=" + k,
               "application/x-www-form-urlencoded")
            .find("{\"ok\":true}") != std::string::npos);
  {
    auto st = json::parse(node.statusJson());
    REQUIRE(st);
    CHECK(json::getBool(json::get(st.get(), "emergency"), "active") == true);
  }

  // panel からの解除は 403 (トリガのみ) — 状態は active のまま
  std::string resp = emHttp(http_port, "POST", "/api/panel/emergency", "k=" + k + "&active=0",
                            "application/x-www-form-urlencoded");
  CHECK(resp.rfind("HTTP/1.1 403", 0) == 0);
  CHECK(resp.find("cancel not allowed") != std::string::npos);
  {
    auto st = json::parse(node.statusJson());
    REQUIRE(st);
    CHECK(json::getBool(json::get(st.get(), "emergency"), "active") == true);
  }

  // /api/emergency は admin セッションが必要 (未ログイン 401)
  CHECK(emHttp(http_port, "POST", "/api/emergency", "{\"active\":false}")
            .rfind("HTTP/1.1 401", 0) == 0);

  // ログイン → admin 解除 → inactive
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
  // active 欠落は 400
  CHECK(emHttp(http_port, "POST", "/api/emergency", "{}", "", cookie)
            .find("400") != std::string::npos);

  node.stop();
}
