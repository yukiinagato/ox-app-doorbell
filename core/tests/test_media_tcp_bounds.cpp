#include "doctest.h"
#if !defined(_WIN32)
#include "mesh/tcp_transport.h"
#include "util/clock.h"
#include "util/runloop.h"
#include <atomic>
#include <chrono>
#include <thread>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>

using namespace db;
namespace {
struct SlowTcpPeer {
  int listener = -1;
  int peer = -1;
  ~SlowTcpPeer() {
    if (peer >= 0) ::close(peer);
    if (listener >= 0) ::close(listener);
  }
};

bool waitTcpClose(const std::atomic<int>& closed, int timeout_ms) {
  const auto deadline = std::chrono::steady_clock::now() +
      std::chrono::milliseconds(timeout_ms);
  while (std::chrono::steady_clock::now() < deadline) {
    if (closed.load() > 0) return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  return closed.load() > 0;
}
}

TEST_CASE("media TCP bounds: a non-reading peer cannot retain an unbounded outbox") {
  SlowTcpPeer sockets;
  sockets.listener = ::socket(AF_INET, SOCK_STREAM, 0);
  REQUIRE(sockets.listener >= 0);
  int receive_bytes = 4096;
  REQUIRE(::setsockopt(sockets.listener, SOL_SOCKET, SO_RCVBUF,
                      &receive_bytes, sizeof(receive_bytes)) == 0);
  sockaddr_in address{};
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  REQUIRE(::bind(sockets.listener, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0);
  REQUIRE(::listen(sockets.listener, 1) == 0);
  socklen_t address_bytes = sizeof(address);
  REQUIRE(::getsockname(sockets.listener, reinterpret_cast<sockaddr*>(&address), &address_bytes) == 0);
  std::atomic<int> connected{0}, closed{0};
  RealClock clock;
  Runloop loop(clock);
  loop.start();
  {
    TcpTransport transport(loop);
    size_t frame_size = 512 * 1024;
    size_t frame_count = 64;
    bool expect_close = true;
    SUBCASE("burst to a peer which never reads") {}
    SUBCASE("a single frame above the wire limit") {
      frame_size = 8 * 1024 * 1024 + 1;
      frame_count = 1;
    }
    SUBCASE("a bounded frame still arrives and keeps the connection usable") {
      frame_size = 2048;
      frame_count = 1;
      expect_close = false;
    }
    transport.connect("127.0.0.1:" + std::to_string(ntohs(address.sin_port)),
        [&, frame_size, frame_count](ConnPtr connection) {
          if (!connection) { connected = -1; return; }
          connection->setCallbacks({}, [&] { ++closed; });
          connected = 1;
          const Bytes frame(frame_size, 0x5a);
          for (size_t index = 0; index < frame_count; ++index) connection->send(frame);
        });
    timeval timeout{3, 0};
    ::setsockopt(sockets.listener, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    sockets.peer = ::accept(sockets.listener, nullptr, nullptr);
    REQUIRE(sockets.peer >= 0);
    ::setsockopt(sockets.peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    if (expect_close) {
      CHECK(waitTcpClose(closed, 2000));
      CHECK(connected.load() == 1);
      CHECK(closed.load() == 1);
    } else {
      Bytes received(frame_size + 4);
      size_t offset = 0;
      while (offset < received.size()) {
        const auto count = ::recv(sockets.peer, received.data() + offset,
                                  received.size() - offset, 0);
        if (count <= 0) break;
        offset += static_cast<size_t>(count);
      }
      CHECK(offset == received.size());
      CHECK(received[0] == 0);
      CHECK(received[1] == 0);
      CHECK(received[2] == 8);
      CHECK(received[3] == 0);
      CHECK(received.back() == 0x5a);
      CHECK_FALSE(waitTcpClose(closed, 250));
      CHECK(connected.load() == 1);
    }
  }
  loop.stop();
}
#endif
