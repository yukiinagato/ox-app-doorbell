// Node (組み立てルート) の統合テスト。
//  - InMemNet + SimClock 共有 Runloop で複数 Node を決定的にシミュレーション
//  - 実 TCP + 実 HTTP で API を煙試験
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <memory>
#include <random>
#include <string>
#include <vector>

#include "doctest.h"
#include "mesh/mesh.h"
#include "node/node.h"
#include "util/clock.h"
#include "util/json.h"
#include "util/runloop.h"

using namespace db;

namespace {

struct NFleet {
  SimClock clock{1'700'000'000'000LL, 0};
  Runloop loop{clock};
  InMemNet net{loop};
  std::array<uint8_t, 32> psk{};

  NFleet() { psk.fill(0x5a); }

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
    std::vector<std::string> tts;
    size_t uiCount(const std::string& t, const std::string& type = "") const {
      size_t n = 0;
      for (const auto& e : ui) {
        auto d = json::parse(e);
        if (!d) continue;
        if (json::getString(d.get(), "t") != t) continue;
        if (!type.empty() && json::getString(d.get(), "type") != type) continue;
        n++;
      }
      return n;
    }
  };
  std::vector<std::unique_ptr<N>> nodes;

  N& add(const std::string& addr, const std::string& name, const std::string& role,
         const std::string& door, bool seed_cfg, bool zero_psk = false) {
    NodeOptions o;
    o.data_dir = ":memory:";
    o.name = name;
    o.role = role;
    o.door = door;
    o.listen_addr = addr;
    o.advertise_addr = addr;
    o.psk = zero_psk ? std::array<uint8_t, 32>{} : psk;
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
    n->node->setTtsCb([raw](const std::string& t, const std::string&) { raw->tts.push_back(t); });
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

}  // namespace

TEST_CASE("node: 2台が合流し既定設定が複製される") {
  NFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true);
  auto& b = f.add("B:1", "kitchen", "indoor_panel", "", false);
  REQUIRE(a.node->start());
  REQUIRE(b.node->start());
  f.run(1500);

  // 互いを alive 認識
  auto st = json::parse(b.node->statusJson());
  REQUIRE(st);
  cJSON* peers = json::get(st.get(), "peers");
  REQUIRE(cJSON_GetArraySize(peers) == 2);
  cJSON* it = nullptr;
  cJSON_ArrayForEach(it, peers) { CHECK(json::getString(it, "status") == "alive"); }

  // A が seed した既定設定 (quick_replies) が B にも届いている
  auto cfg = json::parse(b.node->configJson());
  REQUIRE(cfg);
  cJSON* qr = json::get(json::get(cfg.get(), "quick_replies"), "qr_away");
  REQUIRE(qr);
  CHECK(json::getString(json::get(qr, "label"), "ja") == "ただいま留守にしています");

  // devices エントリが双方の分ある
  cJSON* devs = json::get(cfg.get(), "devices");
  CHECK(cJSON_GetArraySize(devs) == 2);

  a.node->stop();
  b.node->stop();
}

TEST_CASE("node: start 後に status / config のスナップショット JSON が取得できる") {
  NFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true);
  REQUIRE(a.node->start());
  std::string status = a.node->statusJson();
  std::string config = a.node->configJson();
  CHECK(status != "{}");
  CHECK(config != "{}");
  CHECK(json::parse(status));
  CHECK(json::parse(config));
  a.node->stop();
}

TEST_CASE("node: setConfigKey の反映がスナップショット経由で遅延反映される") {
  NFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true);
  REQUIRE(a.node->start());
  a.node->setConfigKey("ui.snapshot_test", "\"updated\"");
  f.clock.advance(35);
  f.run(40);
  auto cfg = json::parse(a.node->configJson());
  REQUIRE(cfg);
  CHECK(json::getString(json::get(cfg.get(), "ui"), "snapshot_test") == "updated");
  a.node->stop();
}

TEST_CASE("sanitizeCaps: tls12 だけ環境で抑制") {
  auto caps1 = sanitizeCaps(R"({"tls12":true,"wan":true})", false);
  auto j1 = json::parse(caps1);
  REQUIRE(j1);
  CHECK(json::getBool(j1.get(), "tls12") == false);
  CHECK(json::getBool(j1.get(), "wan") == true);

  auto caps2 = sanitizeCaps(R"({"tls12":true,"wan":true})", true);
  auto j2 = json::parse(caps2);
  REQUIRE(j2);
  CHECK(json::getBool(j2.get(), "tls12") == true);

  CHECK(sanitizeCaps("not-json", false) == "not-json");
  CHECK(sanitizeCaps("not-json", true) == "not-json");
}

TEST_CASE("node: 配対 — 未配対機を発見 → 招待 → PSK 取得 (paired uiNotify + 設定複製)") {
  NFleet f;
  auto& host = f.add("A:1", "front", "door_station", "d_front", /*seed_cfg=*/true);
  auto& joiner = f.add("J:1", "newpad", "indoor_panel", "", /*seed_cfg=*/false,
                       /*zero_psk=*/true);
  REQUIRE(host.node->start());
  REQUIRE(joiner.node->start());

  // pairingJson は入れ子オブジェクトとして整形される (文字列化しない)
  auto pj0 = json::parse(joiner.node->pairingJson());
  REQUIRE(pj0);
  CHECK(json::getBool(pj0.get(), "paired") == false);
  cJSON* self = json::get(pj0.get(), "self");
  REQUIRE(self);  // 入れ子オブジェクト (setItem)
  CHECK(json::getString(self, "pk").size() == 64);
  CHECK(json::getString(pj0.get(), "pair_qr").rfind("doorbell-pair:", 0) == 0);

  // host が未配対機を発見して pending に載せる
  REQUIRE([&] {
    for (int i = 0; i < 200; i++) {
      f.run(50);
      auto pj = json::parse(host.node->pairingJson());
      cJSON* pend = pj ? json::get(pj.get(), "pending") : nullptr;
      cJSON* devs = pend ? json::get(pend, "devices") : nullptr;
      cJSON* it = nullptr;
      cJSON_ArrayForEach(it, devs) {
        if (json::getString(it, "id") == joiner.node->nodeId()) return true;
      }
    }
    return false;
  }());

  // 管理者が承認 → 招待 push → joiner が PSK 取得
  host.node->inviteDevice(joiner.node->nodeId());
  REQUIRE([&] {
    for (int i = 0; i < 200; i++) {
      f.run(50);
      if (joiner.uiCount("paired") >= 1) return true;
    }
    return false;
  }());
  // paired イベントに psk_hex/seeds が載る (殻が boot.json 永続化に使う)
  std::string psk_hex;
  for (const auto& e : joiner.ui) {
    auto d = json::parse(e);
    if (d && json::getString(d.get(), "t") == "paired") psk_hex = json::getString(d.get(), "psk_hex");
  }
  CHECK(psk_hex.size() == 64);
  CHECK(psk_hex != std::string(64, '0'));  // 全ゼロでない = 実 PSK
  // pairingJson が paired=true になり、既定設定 (host が seed した quick_replies) が届く
  auto pj1 = json::parse(joiner.node->pairingJson());
  CHECK(json::getBool(pj1.get(), "paired") == true);
  REQUIRE([&] {
    for (int i = 0; i < 200; i++) {
      f.run(50);
      auto cfg = json::parse(joiner.node->configJson());
      cJSON* qr = cfg ? json::get(json::get(cfg.get(), "quick_replies"), "qr_away") : nullptr;
      if (qr) return true;
    }
    return false;
  }());

  host.node->stop();
  joiner.node->stop();
}

TEST_CASE("node: press → ルール評価 → chime/sip/イベント複製が exactly-once") {
  NFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true);
  auto& b = f.add("B:1", "kitchen", "indoor_panel", "", false);
  REQUIRE(a.node->start());
  REQUIRE(b.node->start());
  f.run(1000);

  // ルール: 正面玄関の按鈴 → B で chime + A から sip_call
  std::string rule = std::string("{\"enabled\":true,") +
      "\"when\":{\"type\":\"button\",\"doors\":[\"d_front\"]}," +
      "\"actions\":[{\"type\":\"chime\",\"devices\":[\"" + b.node->nodeId() + "\"],\"sound\":\"ding1\"}," +
      "{\"type\":\"sip_call\",\"target_extension\":\"600\"}]}";
  a.node->setConfigKey("trigger_rules.r1", rule);
  f.run(500);

  a.node->press("");  // 自分の担当 door (d_front)
  f.run(800);

  // B: press イベント 1 回 + chime 1 回。A: calling 状態 1 回。
  CHECK(b.uiCount("event", "press") == 1);
  CHECK(b.uiCount("chime") == 1);
  CHECK(a.uiCount("event", "press") == 1);
  CHECK(a.uiCount("state") == 1);

  // さらに時間を進めても重複しない (SYNC の再配送は冪等)
  f.run(1000);
  CHECK(b.uiCount("event", "press") == 1);
  CHECK(b.uiCount("chime") == 1);

  a.node->stop();
  b.node->stop();
}

TEST_CASE("node: クイック返信が門口機の表示 + TTS に届く") {
  NFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true);
  auto& b = f.add("B:1", "kitchen", "indoor_panel", "", false);
  REQUIRE(a.node->start());
  REQUIRE(b.node->start());
  f.run(1500);  // 設定 (quick_replies, devices) の複製を待つ

  a.node->press("");
  f.run(300);

  // 室内パネル B から「留守にしています」を返す (web 経由想定)
  b.node->sendQuickReply("qr_away", "", "d_front", "web");
  f.run(500);

  CHECK(a.uiCount("reply") == 1);
  REQUIRE(a.tts.size() == 1);
  CHECK(a.tts[0] == "ただいま留守にしています");

  // reply イベントも複製される (両者の UI に event/reply が 1 回ずつ)
  CHECK(a.uiCount("event", "reply") == 1);
  CHECK(b.uiCount("event", "reply") == 1);

  // 自由文も送れる
  b.node->sendQuickReply("", "10分で戻ります", "d_front", "web");
  f.run(500);
  REQUIRE(a.tts.size() == 2);
  CHECK(a.tts[1] == "10分で戻ります");

  a.node->stop();
  b.node->stop();
}

TEST_CASE("node: 節点死で offline イベントが一度だけ記録される") {
  NFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true);
  auto& b = f.add("B:1", "annex", "door_station", "d_annex", false);
  auto& c = f.add("C:1", "kitchen", "indoor_panel", "", false);
  REQUIRE(a.node->start());
  REQUIRE(b.node->start());
  REQUIRE(c.node->start());
  f.run(1500);

  f.net.killNode("B:1");
  f.run(1000);  // dead 判定 + イベント複製

  // 生存者 (A,C) のどちらでも offline イベントはちょうど 1 件
  CHECK(a.uiCount("event", "offline") == 1);
  CHECK(c.uiCount("event", "offline") == 1);

  a.node->stop();
  b.node->stop();
  c.node->stop();
}

// ---------- 実 TCP + HTTP 煙試験 ----------

namespace {
int freePort(std::mt19937& rng) {
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

// 極小 HTTP クライアント (1 リクエスト 1 接続)
std::string httpReq(int port, const std::string& raw) {
  int fd = ::socket(AF_INET, SOCK_STREAM, 0);
  REQUIRE(fd >= 0);
  sockaddr_in sa{};
  sa.sin_family = AF_INET;
  sa.sin_port = htons(static_cast<uint16_t>(port));
  sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  REQUIRE(::connect(fd, reinterpret_cast<sockaddr*>(&sa), sizeof(sa)) == 0);
  REQUIRE(::send(fd, raw.data(), raw.size(), 0) == static_cast<ssize_t>(raw.size()));
  std::string resp;
  char buf[4096];
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

std::string simpleReq(int port, const std::string& method, const std::string& path,
                      const std::string& body = "", const std::string& cookie = "") {
  std::string r = method + " " + path + " HTTP/1.1\r\nHost: 127.0.0.1\r\n";
  if (!cookie.empty()) r += "Cookie: " + cookie + "\r\n";
  if (!body.empty()) {
    r += "Content-Type: application/json\r\nContent-Length: " + std::to_string(body.size()) + "\r\n";
  }
  r += "Connection: close\r\n\r\n" + body;
  return httpReq(port, r);
}
}  // namespace

TEST_CASE("node: 実 TCP + HTTP API 煙試験 (login/status/press/events)") {
  std::mt19937 rng(static_cast<uint32_t>(::getpid()) ^ 0x9e37u);
  int mesh_port = freePort(rng);
  int http_port = freePort(rng);
  REQUIRE(mesh_port > 0);
  REQUIRE(http_port > 0);

  NodeOptions o;
  o.data_dir = ":memory:";
  o.name = "real";
  o.role = "door_station";
  o.door = "d_front";
  o.listen_addr = "127.0.0.1:" + std::to_string(mesh_port);
  o.psk.fill(0x5a);
  o.enable_beacon = false;  // 実 beacon 禁止 (稼働 fleet への迷入防止)
  o.http_port = http_port;
  Node node(o);  // 実物 deps (RealClock + TcpTransport + UdpBeacon)
  REQUIRE(node.start());

  // 未ログインの API は 401、/admin/ は公開
  CHECK(simpleReq(http_port, "GET", "/api/status").rfind("HTTP/1.1 401", 0) == 0);
  CHECK(simpleReq(http_port, "GET", "/admin/").find("200") != std::string::npos);

  // 初回ログイン = パスワード設定
  std::string login = simpleReq(http_port, "POST", "/api/login", "{\"password\":\"test123\"}");
  REQUIRE(login.rfind("HTTP/1.1 200", 0) == 0);
  auto cpos = login.find("dbsess=");
  REQUIRE(cpos != std::string::npos);
  std::string cookie = login.substr(cpos, login.find(';', cpos) - cpos);

  // 誤パスワードは 401
  CHECK(simpleReq(http_port, "POST", "/api/login", "{\"password\":\"wrong\"}")
            .rfind("HTTP/1.1 401", 0) == 0);

  // status / press / events
  std::string st = simpleReq(http_port, "GET", "/api/status", "", cookie);
  CHECK(st.find("\"peers\"") != std::string::npos);
  CHECK(simpleReq(http_port, "POST", "/api/press", "{\"door\":\"d_front\"}", cookie)
            .rfind("HTTP/1.1 200", 0) == 0);
  std::string ev = simpleReq(http_port, "GET", "/api/events?limit=10", "", cookie);
  CHECK(ev.find("\"press\"") != std::string::npos);

  // locale 資産 (公開)
  CHECK(simpleReq(http_port, "GET", "/locale/ja.json").find("呼び出し中") != std::string::npos);

  node.stop();
}
