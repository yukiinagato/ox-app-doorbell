// 管理 API (フル版管理画面が使う追加 5 本) の統合テスト (実 TCP + HTTP)。
//   /api/config/delete (tombstone) / /api/config/import / /api/join-token /
//   /api/panel-token/rotate / /api/test/telegram (モック HttpsFn)
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <mutex>
#include <random>
#include <string>
#include <vector>

#include "doctest.h"
#include "node/node.h"
#include "util/json.h"

using namespace db;

namespace {

int adminFreePort(std::mt19937& rng) {
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

// 生 HTTP 往復 (cookie ヘッダ付き)。応答は生テキスト全文。
std::string adminReq(int port, const std::string& method, const std::string& path,
                     const std::string& body = "", const std::string& cookie = "") {
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
    r += "Content-Type: application/json\r\nContent-Length: " + std::to_string(body.size()) +
         "\r\n";
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

// ログイン → dbsess cookie 値
std::string adminLogin(int port) {
  std::string r = adminReq(port, "POST", "/api/login", "{\"password\":\"testpw\"}");
  REQUIRE(r.find("HTTP/1.1 200") == 0);
  size_t p = r.find("dbsess=");
  REQUIRE(p != std::string::npos);
  size_t e = r.find(';', p);
  return r.substr(p + 7, e - (p + 7));
}

// 応答本文 (ヘッダ終端以降) の JSON
json::Doc bodyJson(const std::string& resp) {
  size_t p = resp.find("\r\n\r\n");
  return json::parse(p == std::string::npos ? "" : resp.substr(p + 4));
}

// telegram leader になれる caps
std::string adminTgCaps() {
  auto o = json::obj();
  json::setBool(o.get(), "tls12", true);
  json::setBool(o.get(), "wan", true);
  json::setBool(o.get(), "mains_power", true);
  json::setBool(o.get(), "wall_clock_sane", true);
  json::set(o.get(), "cpu_score", int64_t{10});
  return json::dump(o.get());
}

// 実時間の縮小 mesh タイミング (単機の leader 就任を数百 ms に)
MeshSettings adminTiming() {
  MeshSettings m;
  m.heartbeat_ms = 100;
  m.suspect_ms = 300;
  m.dead_ms = 500;
  m.gossip_ms = 200;
  m.sync_ms = 200;
  m.claim_ttl_ms = 450;  // leaderTick は claim_ttl/3 = 150ms 周期
  m.reconnect_ms = 200;
  return m;
}

// モック HttpsFn (done 同期呼び — Node 側が Runloop へ marshal する契約)。
// 捕捉はスレッド間で読むため mutex で守る。
struct AdminMockHttps {
  std::mutex mu;
  std::vector<std::pair<std::string, std::string>> reqs;  // (url, body)
  Node::HttpsFn fn() {
    return [this](const std::string&, const std::string& u, const std::string&, const Bytes& b,
                  std::function<void(int, std::string)> done) {
      {
        std::lock_guard<std::mutex> lk(mu);
        reqs.push_back({u, std::string(b.begin(), b.end())});
      }
      if (u.find("/getUpdates") != std::string::npos) {
        done(200, "{\"ok\":true,\"result\":[]}");
        return;
      }
      done(200, "{\"ok\":true,\"result\":{\"message_id\":42}}");
    };
  }
  // url が api を含み body が needle を含む要求の数
  size_t count(const std::string& api, const std::string& needle) {
    std::lock_guard<std::mutex> lk(mu);
    size_t n = 0;
    for (const auto& r : reqs)
      if (r.first.find("/" + api) != std::string::npos &&
          r.second.find(needle) != std::string::npos)
        n++;
    return n;
  }
};

}  // namespace

TEST_CASE("admin API: session gate + config delete/import + join-token + panel-token rotate") {
  std::mt19937 rng(static_cast<uint32_t>(::getpid()) ^ 0xad31u);
  int mesh_port = adminFreePort(rng);
  int http_port = adminFreePort(rng);
  REQUIRE(mesh_port > 0);
  REQUIRE(http_port > 0);

  NodeOptions o;
  o.data_dir = ":memory:";
  o.name = "admin-test";
  o.role = "door_station";
  o.door = "d_front";
  o.listen_addr = "127.0.0.1:" + std::to_string(mesh_port);
  o.psk.fill(0x33);
  o.http_port = http_port;
  Node node(o);
  REQUIRE(node.start());

  // 未ログインは 401 (新規 API も既存 auth gate の対象)
  CHECK(adminReq(http_port, "POST", "/api/config/delete", "{\"key\":\"x\"}").find("401") !=
        std::string::npos);
  CHECK(adminReq(http_port, "POST", "/api/join-token", "{}").find("401") != std::string::npos);

  std::string sess = adminLogin(http_port);

  // ---- delete: 書いた key が tombstone 後に materialize から消える ----
  CHECK(adminReq(http_port, "POST", "/api/config",
                 "{\"key\":\"doors.d_tmp\",\"value\":\"{\\\"label\\\":{\\\"ja\\\":\\\"仮\\\"}}\"}",
                 sess)
            .find("{\"ok\":true}") != std::string::npos);
  CHECK(adminReq(http_port, "GET", "/api/config", "", sess).find("d_tmp") != std::string::npos);
  CHECK(adminReq(http_port, "POST", "/api/config/delete", "{\"key\":\"doors.d_tmp\"}", sess)
            .find("{\"ok\":true}") != std::string::npos);
  CHECK(adminReq(http_port, "GET", "/api/config", "", sess).find("d_tmp") == std::string::npos);
  CHECK(node.configJson().find("d_tmp") == std::string::npos);
  // key 無しは 400
  CHECK(adminReq(http_port, "POST", "/api/config/delete", "{}", sess).find("400") !=
        std::string::npos);

  // ---- import: 複数 entries を順に書く ----
  std::string imp =
      "{\"entries\":[{\"key\":\"buildings.b_x\",\"value\":{\"label\":{\"ja\":\"別館\"}}},"
      "{\"key\":\"integrations.tz_offset_min\",\"value\":480},"
      "{\"key\":\"devices.n_x.local.camera\",\"value\":{\"mjpeg_fps\":12}}]}";
  std::string ir = adminReq(http_port, "POST", "/api/config/import", imp, sess);
  CHECK(ir.find("\"ok\":true") != std::string::npos);
  CHECK(ir.find("\"n\":3") != std::string::npos);
  std::string cfg = adminReq(http_port, "GET", "/api/config", "", sess);
  CHECK(cfg.find("別館") != std::string::npos);
  CHECK(cfg.find("480") != std::string::npos);
  CHECK(cfg.find("\"mjpeg_fps\":12") != std::string::npos);
  // entries 無しは 400
  CHECK(adminReq(http_port, "POST", "/api/config/import", "{}", sess).find("400") !=
        std::string::npos);

  // ---- join-token: 6 桁 PIN + 有効秒 ----
  auto jt = bodyJson(adminReq(http_port, "POST", "/api/join-token", "{}", sess));
  REQUIRE(jt);
  CHECK(json::getBool(jt.get(), "ok"));
  std::string pin = json::getString(jt.get(), "pin");
  CHECK(pin.size() == 6);
  for (char c : pin) CHECK((c >= '0' && c <= '9'));
  int64_t exp = json::getInt(jt.get(), "expires_s");
  CHECK(exp > 0);
  CHECK(exp <= 600);

  // ---- panel-token rotate: 旧 token 即失効・新 token 有効 ----
  auto cj = json::parse(node.configJson());
  REQUIRE(cj);
  cJSON* toks = json::get(json::get(cj.get(), "panel"), "tokens");
  REQUIRE(cJSON_GetArraySize(toks) == 1);
  std::string old_tok = cJSON_GetArrayItem(toks, 0)->valuestring;
  CHECK(adminReq(http_port, "GET", "/api/panel/state?k=" + old_tok).find("HTTP/1.1 200") == 0);
  auto rot = bodyJson(adminReq(http_port, "POST", "/api/panel-token/rotate", "{}", sess));
  REQUIRE(rot);
  CHECK(json::getBool(rot.get(), "ok"));
  std::string new_tok = json::getString(rot.get(), "token");
  CHECK(new_tok.size() == 32);
  CHECK(new_tok != old_tok);
  CHECK(adminReq(http_port, "GET", "/api/panel/state?k=" + old_tok).find("403") !=
        std::string::npos);
  CHECK(adminReq(http_port, "GET", "/api/panel/state?k=" + new_tok).find("HTTP/1.1 200") == 0);

  node.stop();
}

TEST_CASE("admin API: /api/test/telegram (モック HttpsFn)") {
  std::mt19937 rng(static_cast<uint32_t>(::getpid()) ^ 0xad32u);
  int mesh_port = adminFreePort(rng);
  int http_port = adminFreePort(rng);
  REQUIRE(mesh_port > 0);
  REQUIRE(http_port > 0);

  NodeOptions o;
  o.data_dir = ":memory:";
  o.name = "tg-admin";
  o.role = "door_station";
  o.door = "d_front";
  o.listen_addr = "127.0.0.1:" + std::to_string(mesh_port);
  o.psk.fill(0x34);
  o.http_port = http_port;
  o.caps_json = adminTgCaps();
  o.mesh_timing_template = adminTiming();
  o.use_mesh_timing_template = true;
  Node node(o);
  AdminMockHttps https;
  node.setHttpsFn(https.fn());
  REQUIRE(node.start());
  std::string sess = adminLogin(http_port);

  // bot_token 未設定 → no_token
  CHECK(adminReq(http_port, "POST", "/api/test/telegram", "{}", sess).find("no_token") !=
        std::string::npos);

  node.setConfigKey("households.h_ox", "{\"telegram_chat_ids\":[111]}");
  node.setConfigKey("integrations.telegram.bot_token", "\"TESTTOKEN\"");

  // 単機なので telegram leader に就任するはず (縮小タイミングで数百 ms)
  bool leader = false;
  for (int i = 0; i < 100 && !leader; i++) {
    auto st = json::parse(node.statusJson());
    if (st &&
        json::getString(json::get(st.get(), "leaders"), "telegram") == node.nodeId())
      leader = true;
    else
      usleep(50 * 1000);
  }
  REQUIRE(leader);

  // 全 households 宛て (chat 111) — キュー経由で sendMessage が飛ぶ
  CHECK(adminReq(http_port, "POST", "/api/test/telegram", "{}", sess)
            .find("{\"ok\":true}") != std::string::npos);
  bool sent = false;
  for (int i = 0; i < 100 && !sent; i++) {
    if (https.count("sendMessage", "ドアホン テスト通知") >= 1 &&
        https.count("sendMessage", "\"chat_id\":\"111\"") >= 1)
      sent = true;
    else
      usleep(50 * 1000);
  }
  CHECK(sent);

  // chat_id 明示
  CHECK(adminReq(http_port, "POST", "/api/test/telegram", "{\"chat_id\":\"999\"}", sess)
            .find("{\"ok\":true}") != std::string::npos);
  bool sent999 = false;
  for (int i = 0; i < 100 && !sent999; i++) {
    if (https.count("sendMessage", "\"chat_id\":\"999\"") >= 1)
      sent999 = true;
    else
      usleep(50 * 1000);
  }
  CHECK(sent999);

  node.stop();
}

TEST_CASE("admin API: /api/test/telegram は非 leader なら err") {
  std::mt19937 rng(static_cast<uint32_t>(::getpid()) ^ 0xad33u);
  int mesh_port = adminFreePort(rng);
  int http_port = adminFreePort(rng);
  REQUIRE(mesh_port > 0);
  REQUIRE(http_port > 0);

  NodeOptions o;
  o.data_dir = ":memory:";
  o.name = "tg-nolead";
  o.role = "indoor_panel";
  o.listen_addr = "127.0.0.1:" + std::to_string(mesh_port);
  o.psk.fill(0x35);
  o.http_port = http_port;
  o.caps_json = "{}";  // telegram duty 不適格 → leader に決してならない
  o.mesh_timing_template = adminTiming();
  o.use_mesh_timing_template = true;
  Node node(o);
  REQUIRE(node.start());
  std::string sess = adminLogin(http_port);
  node.setConfigKey("integrations.telegram.bot_token", "\"TESTTOKEN\"");
  CHECK(adminReq(http_port, "POST", "/api/test/telegram", "{}", sess).find("not_leader") !=
        std::string::npos);
  node.stop();
}
