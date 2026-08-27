// パネル API (webui/panel/API.md) と動体検知配線の統合テスト (実 TCP + HTTP)。
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <random>
#include <string>
#include <vector>

#include "doctest.h"
#include "node/node.h"
#include "util/json.h"

using namespace db;

namespace {

int panelFreePort(std::mt19937& rng) {
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

std::string panelReq(int port, const std::string& method, const std::string& path,
                     const std::string& body = "", const std::string& ctype = "") {
  int fd = ::socket(AF_INET, SOCK_STREAM, 0);
  REQUIRE(fd >= 0);
  sockaddr_in sa{};
  sa.sin_family = AF_INET;
  sa.sin_port = htons(static_cast<uint16_t>(port));
  sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  REQUIRE(::connect(fd, reinterpret_cast<sockaddr*>(&sa), sizeof(sa)) == 0);
  std::string r = method + " " + path + " HTTP/1.1\r\nHost: 127.0.0.1\r\n";
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

// BGRA 合成フレーム: phase で右半分の色を変える (動体検知トリガー用)
std::vector<uint8_t> bgra(int w, int h, uint8_t base, uint8_t right) {
  std::vector<uint8_t> d(static_cast<size_t>(w) * h * 4);
  for (int y = 0; y < h; y++)
    for (int x = 0; x < w; x++) {
      uint8_t v = x < w / 2 ? base : right;
      size_t i = (static_cast<size_t>(y) * w + x) * 4;
      d[i] = d[i + 1] = d[i + 2] = v;
      d[i + 3] = 255;
    }
  return d;
}

}  // namespace

TEST_CASE("panel API: token 認証 / state / press / snapshot-proxy / 動体検知") {
  std::mt19937 rng(static_cast<uint32_t>(::getpid()) ^ 0x51a7u);
  int mesh_port = panelFreePort(rng);
  int http_port = panelFreePort(rng);
  REQUIRE(mesh_port > 0);
  REQUIRE(http_port > 0);

  NodeOptions o;
  o.data_dir = ":memory:";
  o.name = "panel-test";
  o.role = "door_station";
  o.door = "d_front";
  o.listen_addr = "127.0.0.1:" + std::to_string(mesh_port);
  o.psk.fill(0x77);
  o.enable_beacon = false;  // 実 beacon 禁止 (稼働 fleet への迷入防止)
  o.http_port = http_port;
  Node node(o);
  REQUIRE(node.start());
  node.setConfigKey("doors.d_front", "{\"label\":{\"ja\":\"正面玄関\"}}");

  // seed された panel token を設定から取得
  auto cfg = json::parse(node.configJson());
  REQUIRE(cfg);
  cJSON* toks = json::get(json::get(cfg.get(), "panel"), "tokens");
  REQUIRE(cJSON_GetArraySize(toks) == 1);
  std::string k = cJSON_GetArrayItem(toks, 0)->valuestring;

  // token 無し/誤り → 403
  CHECK(panelReq(http_port, "GET", "/api/panel/state").find("403") != std::string::npos);
  CHECK(panelReq(http_port, "GET", "/api/panel/state?k=wrong").find("403") != std::string::npos);

  // state: doors に d_front (calling=false)、reply は null
  std::string st = panelReq(http_port, "GET", "/api/panel/state?k=" + k);
  CHECK(st.find("HTTP/1.1 200") == 0);
  CHECK(st.find("\"d_front\"") != std::string::npos);
  CHECK(st.find("正面玄関") != std::string::npos);
  CHECK(st.find("\"calling\":false") != std::string::npos);
  CHECK(st.find("\"reply\":null") != std::string::npos);

  // state: purposes (order 昇順 — 先頭は p_visit) + languages (ui.languages seed)
  {
    size_t body_at = st.find("\r\n\r\n");
    REQUIRE(body_at != std::string::npos);
    auto sj = json::parse(st.substr(body_at + 4));
    REQUIRE(sj);
    cJSON* ps = json::get(sj.get(), "purposes");
    REQUIRE(cJSON_IsArray(ps));
    REQUIRE(cJSON_GetArraySize(ps) == 6);  // 既定 seed 6 種
    cJSON* first = cJSON_GetArrayItem(ps, 0);
    CHECK(json::getString(first, "id") == "p_visit");
    CHECK(json::getString(first, "icon") == "🏠");
    CHECK(json::getString(json::get(first, "label"), "en") == "Visit");
    cJSON* langs = json::get(sj.get(), "languages");
    REQUIRE(cJSON_IsArray(langs));
    CHECK(cJSON_GetArraySize(langs) == 3);  // ja/en/zh
  }

  // i18n: 上書きが無ければ overrides={}。設定すると全文が返る (panel token 必須)
  CHECK(panelReq(http_port, "GET", "/api/panel/i18n").find("403") != std::string::npos);
  {
    std::string r = panelReq(http_port, "GET", "/api/panel/i18n?k=" + k);
    CHECK(r.find("HTTP/1.1 200") == 0);
    CHECK(r.find("\"overrides\":{}") != std::string::npos);
  }
  node.setConfigKey("i18n_overrides.ja",
                    "{\"idle.touch_to_call\":\"タッチして呼び出してください\"}");
  {
    std::string r = panelReq(http_port, "GET", "/api/panel/i18n?k=" + k);
    CHECK(r.find("タッチして呼び出してください") != std::string::npos);
    CHECK(r.find("\"languages\"") != std::string::npos);
  }

  // press (form) → calling=true + events に press
  CHECK(panelReq(http_port, "POST", "/api/panel/press", "door=d_front&k=" + k,
                 "application/x-www-form-urlencoded")
            .find("{\"ok\":true}") != std::string::npos);
  st = panelReq(http_port, "GET", "/api/panel/state?k=" + k);
  CHECK(st.find("\"calling\":true") != std::string::npos);
  CHECK(st.find("\"press\"") != std::string::npos);
  // 不明 door は 400
  CHECK(panelReq(http_port, "POST", "/api/panel/press", "door=nope&k=" + k,
                 "application/x-www-form-urlencoded")
            .find("400") != std::string::npos);
  // 用件付き按鈴 → state の events (press 行) に purpose が載る。不明 purpose は 400
  CHECK(panelReq(http_port, "POST", "/api/panel/press",
                 "door=d_front&purpose=p_delivery&k=" + k,
                 "application/x-www-form-urlencoded")
            .find("{\"ok\":true}") != std::string::npos);
  st = panelReq(http_port, "GET", "/api/panel/state?k=" + k);
  CHECK(st.find("\"purpose\":\"p_delivery\"") != std::string::npos);
  CHECK(panelReq(http_port, "POST", "/api/panel/press", "door=d_front&purpose=p_nope&k=" + k,
                 "application/x-www-form-urlencoded")
            .find("400") != std::string::npos);

  // クイック返信 → state.reply 反映 + calling 解除
  node.sendQuickReply("qr_away", "", "d_front", "web");
  st = panelReq(http_port, "GET", "/api/panel/state?k=" + k);
  CHECK(st.find("ただいま留守にしています") != std::string::npos);
  CHECK(st.find("\"calling\":false") != std::string::npos);

  // snapshot-proxy: フレーム無し 503 → push 後 200 image/jpeg
  CHECK(panelReq(http_port, "GET", "/snapshot-proxy?door=d_front&k=" + k)
            .find("503") != std::string::npos);
  auto f0 = bgra(64, 48, 100, 100);
  node.pushCameraFrame(f0.data(), 3 /*BGRA*/, 64, 48, 64 * 4, 1000);
  std::string snap = panelReq(http_port, "GET", "/snapshot-proxy?door=d_front&k=" + k);
  CHECK(snap.find("HTTP/1.1 200") == 0);
  CHECK(snap.find("image/jpeg") != std::string::npos);
  CHECK(snap.find("\xFF\xD8\xFF") != std::string::npos);  // JPEG SOI

  // 動体検知: 静止 (学習) → 右半分を反転 ×2 → motion イベント
  for (int i = 0; i < 6; i++) node.pushCameraFrame(f0.data(), 3, 64, 48, 64 * 4, 2000 + i);
  // 連続 2 フレーム変化し続ける必要がある (前フレームとの差分で判定)
  auto f1 = bgra(64, 48, 100, 250);
  auto f2 = bgra(64, 48, 100, 60);
  node.pushCameraFrame(f1.data(), 3, 64, 48, 64 * 4, 3000);
  node.pushCameraFrame(f2.data(), 3, 64, 48, 64 * 4, 3100);
  // 発火は loop へ post される — 少し待って state の events に motion が出る
  for (int i = 0; i < 50; i++) {
    st = panelReq(http_port, "GET", "/api/panel/state?k=" + k);
    if (st.find("\"motion\"") != std::string::npos) break;
    usleep(100 * 1000);
  }
  CHECK(st.find("\"motion\"") != std::string::npos);

  node.stop();
}

TEST_CASE("panel API: call-frame / peer-frame.jpg / call-info (網頁通話契約)") {
  std::mt19937 rng(static_cast<uint32_t>(::getpid()) ^ 0xca11u);
  int mesh_port = panelFreePort(rng);
  int http_port = panelFreePort(rng);
  REQUIRE(mesh_port > 0);
  REQUIRE(http_port > 0);

  NodeOptions o;
  o.data_dir = ":memory:";
  o.name = "callframe-test";
  o.role = "door_station";
  o.door = "d_front";
  o.listen_addr = "127.0.0.1:" + std::to_string(mesh_port);
  o.psk.fill(0x78);
  o.enable_beacon = false;
  o.http_port = http_port;
  Node node(o);
  REQUIRE(node.start());
  node.setConfigKey("doors.d_front", "{\"label\":{\"ja\":\"正面玄関\"}}");
  node.setConfigKey("sip.accounts." + node.nodeId(), "{\"user\":\"8001\"}");
  node.setConfigKey("integrations.webrtc",
                    "{\"ws_url\":\"ws://10.0.1.5:8088/ws\",\"sip_user\":\"260\","
                    "\"sip_pass\":\"pw\"}");

  auto cfg = json::parse(node.configJson());
  REQUIRE(cfg);
  cJSON* toks = json::get(json::get(cfg.get(), "panel"), "tokens");
  REQUIRE(cJSON_GetArraySize(toks) == 1);
  std::string k = cJSON_GetArrayItem(toks, 0)->valuestring;

  // JPEG もどき (SOI + 適当な本文)
  std::string jpg = "\xFF\xD8\xFF\xE0 fake-jpeg-body";

  // token 無し → 403 (CORS は付く)
  std::string r = panelReq(http_port, "POST", "/call-frame?door=d_front", jpg, "image/jpeg");
  CHECK(r.find("403") != std::string::npos);
  CHECK(r.find("Access-Control-Allow-Origin: *") != std::string::npos);
  // 通話中でない → 409 not in call
  r = panelReq(http_port, "POST", "/call-frame?door=d_front&k=" + k, jpg, "image/jpeg");
  CHECK(r.find("409") != std::string::npos);
  CHECK(r.find("not in call") != std::string::npos);
  // 他 door 宛 → 404 not this station
  r = panelReq(http_port, "POST", "/call-frame?door=d_other&k=" + k, jpg, "image/jpeg");
  CHECK(r.find("404") != std::string::npos);
  // CORS preflight
  r = panelReq(http_port, "OPTIONS", "/call-frame");
  CHECK(r.find("204") != std::string::npos);
  CHECK(r.find("Access-Control-Allow-Methods: POST, OPTIONS") != std::string::npos);

  // peer-frame.jpg: フレーム無し → 404 (通話外もこれ)
  r = panelReq(http_port, "GET", "/peer-frame.jpg");
  CHECK(r.find("404") != std::string::npos);

  // call-info: webrtc 設定 + d_front の内線 (自機 station="") が返る
  r = panelReq(http_port, "GET", "/api/panel/call-info?k=" + k);
  CHECK(r.find("HTTP/1.1 200") == 0);
  CHECK(r.find("ws://10.0.1.5:8088/ws") != std::string::npos);
  CHECK(r.find("\"sip_user\":\"260\"") != std::string::npos);
  CHECK(r.find("\"extension\":\"8001\"") != std::string::npos);
  CHECK(r.find("\"online\":true") != std::string::npos);
  // token 無しは 403
  CHECK(panelReq(http_port, "GET", "/api/panel/call-info").find("403") != std::string::npos);

  node.stop();
}
