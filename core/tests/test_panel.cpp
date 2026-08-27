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
