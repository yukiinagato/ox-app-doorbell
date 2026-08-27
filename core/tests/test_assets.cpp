// 統一資産システム (mesh blob 配布 + 能動キャッシュ) の統合テスト。
//  - InMemNet + SimClock: addAsset → config 複製 → 参照ノードが自動プリフェッチ
//  - 実 TCP + HTTP: POST /api/assets / GET /asset/<hash> の認証と 4xx
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
#include "util/common.h"
#include "util/json.h"
#include "util/runloop.h"

using namespace db;

namespace {

struct AFleet {
  SimClock clock{1'700'000'000'000LL, 0};
  Runloop loop{clock};
  InMemNet net{loop};
  std::array<uint8_t, 32> psk{};

  AFleet() { psk.fill(0x5a); }

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
    size_t uiCount(const std::string& t) const {
      size_t n = 0;
      for (const auto& e : ui) {
        auto d = json::parse(e);
        if (d && json::getString(d.get(), "t") == t) n++;
      }
      return n;
    }
    // 直近の asset_ready の hash ("" = 無し)
    std::string lastAssetReady() const {
      std::string h;
      for (const auto& e : ui) {
        auto d = json::parse(e);
        if (d && json::getString(d.get(), "t") == "asset_ready")
          h = json::getString(d.get(), "hash");
      }
      return h;
    }
  };
  std::vector<std::unique_ptr<N>> nodes;

  N& add(const std::string& addr, const std::string& name, const std::string& role,
         const std::string& door, bool seed_cfg) {
    NodeOptions o;
    o.data_dir = ":memory:";
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

// status_json の assets:{cached,total}
std::pair<int64_t, int64_t> assetCounts(Node& n) {
  auto st = json::parse(n.statusJson());
  REQUIRE(st);
  cJSON* a = json::get(st.get(), "assets");
  REQUIRE(a);
  return {json::getInt(a, "cached", -1), json::getInt(a, "total", -1)};
}

}  // namespace

TEST_CASE("assets: addAsset → config 複製 → 他ノードが自動プリフェッチ") {
  AFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true);
  auto& b = f.add("B:1", "kitchen", "indoor_panel", "", false);
  REQUIRE(a.node->start());
  REQUIRE(b.node->start());
  f.run(1500);

  // A で背景画像を登録 (台帳 assets.<hash> が書かれ B にも複製される)
  Bytes img = toBytes("\xff\xd8***fake-jpeg-bytes***");
  std::string hash = a.node->addAsset(img, "image/jpeg", "桜.jpg");
  REQUIRE(hash.size() == 64);
  CHECK(hash == sha256Hex(img));
  CHECK(a.node->assetPath(hash) != "");  // 登録元は即キャッシュ済み

  // 3MB 超・許可外 type は登録拒否
  CHECK(a.node->addAsset(Bytes(3 * 1024 * 1024 + 1, 0x11), "image/png", "big") == "");
  CHECK(a.node->addAsset(img, "application/zip", "zip") == "");

  // 台帳だけでは前取りしない (参照されて初めて取る)
  f.run(1000);
  CHECK(b.node->assetPath(hash) == "");
  {
    auto [cached, total] = assetCounts(*b.node);
    CHECK(cached == 0);
    CHECK(total == 1);
  }

  // display.theme.bg_image で参照 → B が能動プリフェッチ
  a.node->setConfigKey("display.theme.bg_image", "\"" + hash + "\"");
  f.run(1500);
  std::string bpath = b.node->assetPath(hash);
  REQUIRE(bpath != "");
  Bytes got;
  REQUIRE(readFileBytes(bpath, got));
  CHECK(got == img);
  CHECK(b.uiCount("asset_ready") == 1);
  CHECK(b.lastAssetReady() == hash);
  {
    auto [cached, total] = assetCounts(*b.node);
    CHECK(cached == 1);
    CHECK(total == 1);
  }

  // 冪等: さらに時間を進めても再取得・重複通知しない
  f.run(1000);
  CHECK(b.uiCount("asset_ready") == 1);

  a.node->stop();
  b.node->stop();
}

TEST_CASE("assets: 1MB 級 (複数チャンク) の blob 転送") {
  AFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true);
  auto& b = f.add("B:1", "kitchen", "indoor_panel", "", false);
  REQUIRE(a.node->start());
  REQUIRE(b.node->start());
  f.run(1500);

  Bytes wav(1024 * 1024 + 123);  // 256KB チャンク × 5
  for (size_t i = 0; i < wav.size(); i++) wav[i] = static_cast<uint8_t>(i * 31 + (i >> 8));
  std::string hash = a.node->addAsset(wav, "audio/wav", "siren.wav");
  REQUIRE(hash.size() == 64);

  // emergency.alarm_sound の "asset:*" 参照でも前取りされる
  a.node->setConfigKey("emergency.alarm_sound", "\"asset:" + hash + "\"");
  f.run(2000);

  std::string bpath = b.node->assetPath(hash);
  REQUIRE(bpath != "");
  Bytes got;
  REQUIRE(readFileBytes(bpath, got));
  CHECK(got.size() == wav.size());
  CHECK(got == wav);
  CHECK(b.lastAssetReady() == hash);

  a.node->stop();
  b.node->stop();
}

// ---------- 実 TCP + HTTP ----------

namespace {

int assetFreePort(std::mt19937& rng) {
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

// 生 HTTP 往復 (バイナリ body 可・send は全量書き込み)
std::string assetReq(int port, const std::string& method, const std::string& path,
                     const std::string& body = "", const std::string& cookie = "",
                     const std::string& ctype = "application/octet-stream") {
  int fd = ::socket(AF_INET, SOCK_STREAM, 0);
  REQUIRE(fd >= 0);
  sockaddr_in sa{};
  sa.sin_family = AF_INET;
  sa.sin_port = htons(static_cast<uint16_t>(port));
  sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  REQUIRE(::connect(fd, reinterpret_cast<sockaddr*>(&sa), sizeof(sa)) == 0);
  std::string r = method + " " + path + " HTTP/1.1\r\nHost: 127.0.0.1\r\n";
  if (!cookie.empty()) r += "Cookie: dbsess=" + cookie + "\r\n";
  if (!body.empty())
    r += "Content-Type: " + ctype + "\r\nContent-Length: " + std::to_string(body.size()) + "\r\n";
  r += "Connection: close\r\n\r\n" + body;
  size_t off = 0;
  while (off < r.size()) {  // 大 body (3MB) でも全量送る
    ssize_t n = ::send(fd, r.data() + off, r.size() - off, 0);
    REQUIRE(n > 0);
    off += static_cast<size_t>(n);
  }
  std::string resp;
  char buf[8192];
  timeval tv{10, 0};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  for (;;) {
    ssize_t n = ::recv(fd, buf, sizeof(buf), 0);
    if (n <= 0) break;
    resp.append(buf, static_cast<size_t>(n));
  }
  ::close(fd);
  return resp;
}

std::string assetBody(const std::string& resp) {
  size_t p = resp.find("\r\n\r\n");
  return p == std::string::npos ? "" : resp.substr(p + 4);
}

}  // namespace

TEST_CASE("assets: HTTP API (POST /api/assets / GET /asset/<hash>)") {
  std::mt19937 rng(static_cast<uint32_t>(::getpid()) ^ 0xa55e7u);
  int mesh_port = assetFreePort(rng);
  int http_port = assetFreePort(rng);
  REQUIRE(mesh_port > 0);
  REQUIRE(http_port > 0);

  NodeOptions o;
  o.data_dir = ":memory:";
  o.name = "asset-http";
  o.role = "door_station";
  o.door = "d_front";
  o.listen_addr = "127.0.0.1:" + std::to_string(mesh_port);
  o.psk.fill(0x5a);
  o.enable_beacon = false;  // 実 beacon 禁止 (稼働 fleet への迷入防止)
  o.http_port = http_port;
  Node node(o);
  REQUIRE(node.start());

  // ログイン (初回 = パスワード設定)
  std::string login = assetReq(http_port, "POST", "/api/login", "{\"password\":\"pw\"}", "",
                               "application/json");
  REQUIRE(login.rfind("HTTP/1.1 200", 0) == 0);
  size_t cpos = login.find("dbsess=");
  REQUIRE(cpos != std::string::npos);
  std::string cookie = login.substr(cpos + 7, login.find(';', cpos) - (cpos + 7));

  // 未ログインの登録は 401 (管理 API ゲート)
  CHECK(assetReq(http_port, "POST", "/api/assets?type=image/png", "x").rfind("HTTP/1.1 401", 0) ==
        0);

  // 登録 (バイナリ body — \r\n や NUL を含む)
  std::string body = "PNG\r\n\x1a\n";
  body.push_back('\0');
  body += "payload";
  std::string up = assetReq(http_port, "POST", "/api/assets?type=image/png&label=t.png", body,
                            cookie);
  REQUIRE(up.rfind("HTTP/1.1 200", 0) == 0);
  auto uj = json::parse(assetBody(up));
  REQUIRE(uj);
  std::string hash = json::getString(uj.get(), "hash");
  CHECK(hash == sha256Hex(toBytes(body)));

  // 台帳 (config assets.<hash>) に size/type/origin/label が載る
  auto cfg = json::parse(node.configJson());
  REQUIRE(cfg);
  cJSON* entry = json::get(json::get(cfg.get(), "assets"), hash.c_str());
  REQUIRE(entry);
  CHECK(json::getInt(entry, "size") == static_cast<int64_t>(body.size()));
  CHECK(json::getString(entry, "type") == "image/png");
  CHECK(json::getString(entry, "origin") == node.nodeId());
  CHECK(json::getString(entry, "label") == "t.png");

  // 許可外 type / 空 body / 3MB 超は 4xx
  CHECK(assetReq(http_port, "POST", "/api/assets?type=application/zip", "x", cookie)
            .rfind("HTTP/1.1 415", 0) == 0);
  CHECK(assetReq(http_port, "POST", "/api/assets?type=image/png", "", cookie)
            .rfind("HTTP/1.1 400", 0) == 0);
  CHECK(assetReq(http_port, "POST", "/api/assets?type=audio/wav",
                 std::string(3 * 1024 * 1024 + 1, 'z'), cookie)
            .rfind("HTTP/1.1 413", 0) == 0);

  // 取得: 認証なし 403 / 管理セッション 200 / panel token 200 / 未知 hash 404
  CHECK(assetReq(http_port, "GET", "/asset/" + hash).rfind("HTTP/1.1 403", 0) == 0);
  std::string got = assetReq(http_port, "GET", "/asset/" + hash, "", cookie);
  REQUIRE(got.rfind("HTTP/1.1 200", 0) == 0);
  CHECK(got.find("Content-Type: image/png") != std::string::npos);
  CHECK(assetBody(got) == body);

  cJSON* toks = json::get(json::get(cfg.get(), "panel"), "tokens");
  REQUIRE(cJSON_GetArraySize(toks) == 1);
  std::string k = cJSON_GetArrayItem(toks, 0)->valuestring;
  CHECK(assetReq(http_port, "GET", "/asset/" + hash + "?k=" + k).rfind("HTTP/1.1 200", 0) == 0);
  CHECK(assetReq(http_port, "GET", "/asset/" + std::string(64, '0'), "", cookie)
            .rfind("HTTP/1.1 404", 0) == 0);
  // hash 形式検証 (64 hex 以外は 400 — パス走査対策を兼ねる)
  CHECK(assetReq(http_port, "GET", "/asset/" + std::string(64, 'z'), "", cookie)
            .rfind("HTTP/1.1 400", 0) == 0);

  // パス走査: 素の ../ も URL エンコード版もファイル実体を返さない。
  // 実装は 64 桁小文字 hex 以外を弾くので通過し得ないが、退行検知のため明示的に固定する。
  // 期待は「200 で中身を返さない」こと — civetweb が正規化した結果 "/" に落ちる形
  // (/asset/../.. → /) は既存の /admin/ リダイレクト (302) になるが、これも漏洩ではない。
  for (const std::string& p :
       {std::string("/asset/../.."), std::string("/asset/../../etc/passwd"),
        std::string("/asset/..%2f..%2fetc%2fpasswd"), std::string("/asset/%2e%2e%2f%2e%2e"),
        std::string("/asset/" + std::string(63, 'a') + "/../../etc/passwd")}) {
    const std::string r = assetReq(http_port, "GET", p, "", cookie);
    INFO("path=" << p << " resp=" << r.substr(0, 40));
    CHECK(r.rfind("HTTP/1.1 200", 0) != 0);      // 実体は決して返さない
    CHECK(r.find("root:") == std::string::npos);  // /etc/passwd の内容が漏れていない
  }

  node.stop();
}
