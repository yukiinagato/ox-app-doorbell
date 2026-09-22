#include "doctest.h"
#if !defined(_WIN32)
#include "test_env.h"
#include "httpd/httpd.h"
#include "util/clock.h"
#include "util/runloop.h"
#include <atomic>
#include <sys/socket.h>
#include <unistd.h>

using namespace db;
namespace {
std::string boundedWire(int port, const std::string& request) {
  const int fd = ::socket(AF_INET, SOCK_STREAM, 0); REQUIRE(fd >= 0);
#if defined(SO_NOSIGPIPE)
  int enabled = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
#endif
  sockaddr_in address{}; address.sin_family = AF_INET; address.sin_port = htons(port);
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  REQUIRE(::connect(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0);
  timeval timeout{2, 0}; setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
  size_t sent = 0;
  while (sent < request.size()) {
    const auto count = ::send(fd, request.data() + sent, request.size() - sent, 0);
    if (count <= 0) break;
    sent += static_cast<size_t>(count);
  }
  ::shutdown(fd, SHUT_WR);
  std::string response; char buffer[4096];
  for (;;) {
    const auto count = ::recv(fd, buffer, sizeof(buffer), 0);
    if (count <= 0) break;
    response.append(buffer, count);
  }
  ::close(fd); return response;
}
}

TEST_CASE("media HTTP bounds: reject oversized or incomplete request before dispatch") {
  SimClock clock; Runloop loop(clock); loop.start(); Httpd http(loop);
  std::atomic<int> dispatches{0};
  http.route("POST", "/call-frame", [&](const HttpReq&) {
    ++dispatches; return HttpResp::json("{\"ok\":true}");
  });
  const int port = testing::freeListenPort(); REQUIRE(http.start(port, Httpd::Ipv6Mode::Off));
  std::string framing; int expected = 400;
  SUBCASE("declared frame exceeds one MiB without uploading payload") {
    framing = "Content-Type: image/jpeg\r\nContent-Length: 1048577\r\n\r\n"; expected = 413;
  }
  SUBCASE("declared frame is truncated") {
    framing = "Content-Type: image/jpeg\r\nContent-Length: 8\r\n\r\nabc";
  }
  SUBCASE("chunked frame exceeds its separate media ceiling") {
    framing = "Content-Type: image/jpeg\r\nTransfer-Encoding: chunked\r\n\r\n100001\r\n" +
        std::string(1048577, 'x') + "\r\n0\r\n\r\n"; expected = 413;
  }
  const auto response = boundedWire(port, "POST /call-frame HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n" + framing);
  INFO(response.substr(0, 512));
  CHECK(response.find("HTTP/1.1 " + std::to_string(expected)) == 0);
  CHECK(dispatches == 0);
  http.stop(); loop.stop();
}
#endif
