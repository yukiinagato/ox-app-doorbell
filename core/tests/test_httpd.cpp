// Httpd のテスト。極小 HTTP クライアント (POSIX socket) で 127.0.0.1 を叩く。
#include <atomic>
#include <cstring>
#include <map>
#include <random>
#include <string>

#include "doctest.h"
#include "httpd/httpd.h"
#include "util/clock.h"
#include "util/runloop.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

using namespace db;

namespace {

// 40000-60000 からランダムに試行して bind 確認 (pid シードで並行実行と衝突しにくく)
int pickPort() {
  static std::mt19937 rng(static_cast<uint32_t>(::getpid()) * 2654435761u + 12345u);
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

int connectTo(int port) {
  int fd = ::socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return -1;
  sockaddr_in a{};
  a.sin_family = AF_INET;
  a.sin_port = htons(static_cast<uint16_t>(port));
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (::connect(fd, reinterpret_cast<sockaddr*>(&a), sizeof(a)) != 0) {
    ::close(fd);
    return -1;
  }
  timeval tv{5, 0};  // recv 5s タイムアウト (テストのハング防止)
  ::setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  return fd;
}

void sendAll(int fd, const std::string& data) {
  size_t off = 0;
  while (off < data.size()) {
    ssize_t n = ::send(fd, data.data() + off, data.size() - off, 0);
    if (n <= 0) break;
    off += static_cast<size_t>(n);
  }
}

struct CliResp {
  int status = -1;
  std::map<std::string, std::string> headers;  // 小文字キー
  std::string body;
  std::string raw;
};

CliResp parseResp(const std::string& raw) {
  CliResp r;
  r.raw = raw;
  size_t line_end = raw.find("\r\n");
  if (line_end == std::string::npos) return r;
  // "HTTP/1.1 200 OK"
  size_t sp = raw.find(' ');
  if (sp != std::string::npos && sp < line_end) r.status = std::atoi(raw.c_str() + sp + 1);
  size_t hdr_end = raw.find("\r\n\r\n");
  if (hdr_end == std::string::npos) return r;
  size_t pos = line_end + 2;
  while (pos < hdr_end) {
    size_t eol = raw.find("\r\n", pos);
    size_t colon = raw.find(':', pos);
    if (colon != std::string::npos && colon < eol) {
      std::string k = raw.substr(pos, colon - pos);
      for (char& c : k) c = static_cast<char>(::tolower(c));
      size_t vs = colon + 1;
      while (vs < eol && raw[vs] == ' ') vs++;
      r.headers[k] = raw.substr(vs, eol - vs);
    }
    pos = eol + 2;
  }
  r.body = raw.substr(hdr_end + 4);
  return r;
}

// リクエストを送って接続クローズまで読む
CliResp request(int port, const std::string& raw_req) {
  CliResp r;
  int fd = connectTo(port);
  REQUIRE(fd >= 0);
  sendAll(fd, raw_req);
  std::string raw;
  char buf[4096];
  for (;;) {
    ssize_t n = ::recv(fd, buf, sizeof(buf), 0);
    if (n <= 0) break;
    raw.append(buf, static_cast<size_t>(n));
  }
  ::close(fd);
  return parseResp(raw);
}

CliResp get(int port, const std::string& path_query, const std::string& extra_headers = "") {
  return request(port, "GET " + path_query + " HTTP/1.1\r\nHost: 127.0.0.1\r\n" + extra_headers +
                           "Connection: close\r\n\r\n");
}

CliResp postForm(int port, const std::string& path, const std::string& body) {
  return request(port, "POST " + path + " HTTP/1.1\r\nHost: 127.0.0.1\r\n" +
                           "Content-Type: application/x-www-form-urlencoded\r\n" +
                           "Content-Length: " + std::to_string(body.size()) + "\r\n" +
                           "Connection: close\r\n\r\n" + body);
}

}  // namespace

TEST_CASE("httpd: routing + params + cookie + static") {
  RealClock clock;
  Runloop loop(clock);
  loop.start();
  Httpd httpd(loop);

  std::atomic<bool> on_loop{false};
  httpd.route("GET", "/api/ping", [&](const HttpReq&) {
    on_loop = loop.onLoopThread();  // handler は Runloop 上で実行されること
    return HttpResp::json("{\"ok\":true}");
  });
  httpd.route("GET", "/api/config/get", [](const HttpReq&) { return HttpResp::text("exact"); });
  httpd.route("GET", "/api/config/*", [](const HttpReq& r) { return HttpResp::text("cfg:" + r.uri); });
  httpd.route("GET", "/api/*", [](const HttpReq& r) { return HttpResp::text("api:" + r.uri); });
  httpd.route("POST", "/api/echo", [](const HttpReq& r) { return HttpResp::text(r.param("name")); });
  httpd.route("GET", "/api/q", [](const HttpReq& r) { return HttpResp::text(r.param("msg", "?")); });
  httpd.route("GET", "/api/cookie",
              [](const HttpReq& r) { return HttpResp::text(r.cookie("sid")); });
  httpd.setStatic("/admin/index.html", "text/html", toBytes("<html>admin</html>"));

  int port = pickPort();
  REQUIRE(port > 0);
  REQUIRE(httpd.start(port));
  CHECK(httpd.port() == port);

  // 完全一致 + handler が Runloop 上で走ること
  auto r = get(port, "/api/ping");
  CHECK(r.status == 200);
  CHECK(r.body == "{\"ok\":true}");
  CHECK(r.headers["content-type"] == "application/json; charset=utf-8");
  CHECK(r.headers["content-length"] == std::to_string(r.body.size()));
  CHECK(on_loop.load());

  // 完全一致は前缀より優先
  CHECK(get(port, "/api/config/get").body == "exact");
  // 前缀は最長一致
  CHECK(get(port, "/api/config/other").body == "cfg:/api/config/other");
  CHECK(get(port, "/api/zzz").body == "api:/api/zzz");
  // 404
  CHECK(get(port, "/nope").status == 404);

  // POST body param (URL デコード)
  CHECK(postForm(port, "/api/echo", "name=hello%20world&x=1").body == "hello world");
  CHECK(postForm(port, "/api/echo", "x=1").body == "");  // 無ければ def
  // query param (URL デコード: %2F と '+')
  CHECK(get(port, "/api/q?msg=a%2Fb+c").body == "a/b c");
  CHECK(get(port, "/api/q").body == "?");

  // cookie 解析
  CHECK(get(port, "/api/cookie", "Cookie: a=1; sid=abc123; b=2\r\n").body == "abc123");
  CHECK(get(port, "/api/cookie").body == "");

  // static 資産
  auto s = get(port, "/admin/index.html");
  CHECK(s.status == 200);
  CHECK(s.body == "<html>admin</html>");
  CHECK(s.headers["content-type"] == "text/html");

  httpd.stop();
  loop.stop();
}

TEST_CASE("httpd: auth gate 401 + public_prefix") {
  RealClock clock;
  Runloop loop(clock);
  loop.start();
  Httpd httpd(loop);

  httpd.route("GET", "/api/secret", [](const HttpReq&) { return HttpResp::text("s3cr3t"); });
  httpd.setStatic("/pub/app.js", "text/javascript", toBytes("console.log(1)"));
  httpd.setAuth([](const HttpReq& r) { return r.headers.count("x-token") &&
                                              r.headers.at("x-token") == "secret"; },
                {"/pub/"});

  int port = pickPort();
  REQUIRE(port > 0);
  REQUIRE(httpd.start(port));

  CHECK(get(port, "/api/secret").status == 401);
  auto ok = get(port, "/api/secret", "X-Token: secret\r\n");
  CHECK(ok.status == 200);
  CHECK(ok.body == "s3cr3t");
  // public_prefix は素通し
  auto pub = get(port, "/pub/app.js");
  CHECK(pub.status == 200);
  CHECK(pub.body == "console.log(1)");

  httpd.stop();
  loop.stop();
}

TEST_CASE("httpd: snapshot + stream") {
  RealClock clock;
  Runloop loop(clock);
  loop.start();
  Httpd httpd(loop);

  int port = pickPort();
  REQUIRE(port > 0);
  REQUIRE(httpd.start(port));

  // provider 無し → 503
  CHECK(get(port, "/snapshot.jpg").status == 503);
  CHECK(get(port, "/stream.mjpeg").status == 503);

  const std::string jpeg = "\xff\xd8JPEGDATA\xff\xd9";
  httpd.setJpegProvider([&](int64_t*) { return toBytes(jpeg); }, 30);

  auto snap = get(port, "/snapshot.jpg");
  CHECK(snap.status == 200);
  CHECK(snap.headers["content-type"] == "image/jpeg");
  CHECK(snap.body == jpeg);

  // stream: 最初の boundary + 1 フレーム読めたら切断して OK
  int fd = connectTo(port);
  REQUIRE(fd >= 0);
  sendAll(fd, "GET /stream.mjpeg HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
  std::string got;
  char buf[4096];
  while (got.find("--frame") == std::string::npos ||
         got.find("Content-Type: image/jpeg") == std::string::npos ||
         got.find(jpeg) == std::string::npos) {
    ssize_t n = ::recv(fd, buf, sizeof(buf), 0);
    REQUIRE(n > 0);  // タイムアウト/切断はテスト失敗
    got.append(buf, static_cast<size_t>(n));
  }
  CHECK(got.find("multipart/x-mixed-replace; boundary=frame") != std::string::npos);
  ::close(fd);  // 切断 → サーバ側は書込失敗で終了するはず

  // 進行中の stream があっても stop は安全に完了する
  httpd.stop();
  loop.stop();
}

TEST_CASE("httpd: stop 後の再 start") {
  RealClock clock;
  Runloop loop(clock);
  loop.start();
  Httpd httpd(loop);
  httpd.route("GET", "/api/ping", [](const HttpReq&) { return HttpResp::text("pong"); });

  int port1 = pickPort();
  REQUIRE(port1 > 0);
  REQUIRE(httpd.start(port1));
  CHECK(get(port1, "/api/ping").body == "pong");
  httpd.stop();

  int port2 = pickPort();
  REQUIRE(port2 > 0);
  REQUIRE(httpd.start(port2));
  CHECK(httpd.port() == port2);
  CHECK(get(port2, "/api/ping").body == "pong");
  httpd.stop();
  loop.stop();
}
