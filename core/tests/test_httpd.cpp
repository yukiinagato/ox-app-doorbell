
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
  timeval tv{5, 0};
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
  std::map<std::string, std::string> headers;
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
    on_loop = loop.onLoopThread();
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


  auto r = get(port, "/api/ping");
  CHECK(r.status == 200);
  CHECK(r.body == "{\"ok\":true}");
  CHECK(r.headers["content-type"] == "application/json; charset=utf-8");
  CHECK(r.headers["content-length"] == std::to_string(r.body.size()));
  CHECK(on_loop.load());


  CHECK(get(port, "/api/config/get").body == "exact");

  CHECK(get(port, "/api/config/other").body == "cfg:/api/config/other");
  CHECK(get(port, "/api/zzz").body == "api:/api/zzz");
  // 404
  CHECK(get(port, "/nope").status == 404);


  CHECK(postForm(port, "/api/echo", "name=hello%20world&x=1").body == "hello world");
  CHECK(postForm(port, "/api/echo", "x=1").body == "");

  CHECK(get(port, "/api/q?msg=a%2Fb+c").body == "a/b c");
  CHECK(get(port, "/api/q").body == "?");


  CHECK(get(port, "/api/cookie", "Cookie: a=1; sid=abc123; b=2\r\n").body == "abc123");
  CHECK(get(port, "/api/cookie").body == "");


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


  CHECK(get(port, "/snapshot.jpg").status == 503);
  CHECK(get(port, "/stream.mjpeg").status == 503);

  const std::string jpeg = "\xff\xd8JPEGDATA\xff\xd9";
  httpd.setJpegProvider([&](int64_t*) { return toBytes(jpeg); }, 30);
  httpd.setVideoRotationProvider([] { return 270; });

  auto snap = get(port, "/snapshot.jpg");
  CHECK(snap.status == 200);
  CHECK(snap.headers["content-type"] == "image/jpeg");
  CHECK(snap.body == jpeg);


  int fd = connectTo(port);
  REQUIRE(fd >= 0);
  sendAll(fd, "GET /stream.mjpeg HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
  std::string got;
  char buf[4096];
  while (got.find("--frame") == std::string::npos ||
         got.find("Content-Type: image/jpeg") == std::string::npos ||
         got.find(jpeg) == std::string::npos) {
    ssize_t n = ::recv(fd, buf, sizeof(buf), 0);
    REQUIRE(n > 0);
    got.append(buf, static_cast<size_t>(n));
  }
  CHECK(got.find("multipart/x-mixed-replace; boundary=frame") != std::string::npos);
  CHECK(got.find("Access-Control-Allow-Origin: *") != std::string::npos);
  CHECK(got.find("X-Doorbell-Video-Rotation: 270") != std::string::npos);
  ::close(fd);


  httpd.stop();
  loop.stop();
}

TEST_CASE("httpd: restarts after stop") {
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

TEST_CASE("httpd: same-origin mp4 proxy authenticates before streaming") {
  RealClock clock;
  Runloop loop(clock);
  loop.start();
  Httpd httpd(loop);
  httpd.setAuth([](const HttpReq&) { return false; }, {"/stream-proxy.mp4"});
  httpd.setMp4ProxyProvider([](const HttpReq& req, int* status) -> Httpd::Mp4Pull {
    if (req.param("k") != "panel-token") {
      *status = 403;
      return nullptr;
    }
    if (req.param("door") != "front") {
      *status = 404;
      return nullptr;
    }
    *status = 200;
    auto part = std::make_shared<int>(0);
    return [part](bool* ended) {
      if ((*part)++ == 0) return toBytes("init-segment");
      *ended = true;
      return toBytes("media-fragment");
    };
  });

  const int port = pickPort();
  REQUIRE(port > 0);
  REQUIRE(httpd.start(port));
  CHECK(get(port, "/stream-proxy.mp4?door=front&k=bad").status == 403);
  CHECK(get(port, "/stream-proxy.mp4?door=missing&k=panel-token").status == 404);
  auto ok = get(port, "/stream-proxy.mp4?door=front&k=panel-token");
  CHECK(ok.status == 200);
  CHECK(ok.headers["content-type"] == "video/mp4");
  CHECK(ok.headers["cache-control"] == "no-store");
  CHECK(ok.body == "init-segmentmedia-fragment");

  httpd.stop();
  loop.stop();
}
