#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cstring>
#include <memory>
#include <thread>

#include "doctest.h"
#include "node/node.h"
#include "util/clock.h"
#include "util/json.h"
#include "util/runloop.h"
#include "util/sntp.h"

namespace {
constexpr int64_t kOracleMs = 1'779'000'000'000LL;

// The NTP authority must not follow the device clock being corrected. Only the
// network boundary is simulated; Node, SNTP parsing, run loop, and display API are real.
class OracleNtp {
 public:
  explicit OracleNtp(int64_t now) : now_(now) {}
  ~OracleNtp() {
    running_ = false;
    if (fd_ >= 0) ::shutdown(fd_, SHUT_RDWR);
    if (worker_.joinable()) worker_.join();
    if (fd_ >= 0) ::close(fd_);
  }
  bool start() {
    fd_ = ::socket(AF_INET, SOCK_DGRAM, 0);
    if (fd_ < 0) return false;
    timeval timeout{0, 100000};
    ::setsockopt(fd_, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (::bind(fd_, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) return false;
    socklen_t len = sizeof(addr);
    if (::getsockname(fd_, reinterpret_cast<sockaddr*>(&addr), &len) != 0) return false;
    port_ = ntohs(addr.sin_port);
    running_ = true;
    worker_ = std::thread([this] {
      while (running_) {
        uint8_t request[128]{};
        sockaddr_in peer{};
        socklen_t length = sizeof(peer);
        const auto n = ::recvfrom(fd_, request, sizeof(request), 0,
            reinterpret_cast<sockaddr*>(&peer), &length);
        if (n < 48) continue;
        ++requests_;
        uint8_t reply[48]{};
        reply[0] = 0x24;
        reply[1] = 2;
        std::memcpy(reply + 24, request + 40, 8);
        const uint64_t timestamp = db::sntp::toNtpTimestamp(now_.load());
        for (int i = 0; i != 8; ++i) {
          reply[32 + i] = static_cast<uint8_t>(timestamp >> (56 - 8 * i));
          reply[40 + i] = reply[32 + i];
        }
        ::sendto(fd_, reply, sizeof(reply), 0,
            reinterpret_cast<sockaddr*>(&peer), length);
      }
    });
    return true;
  }
  int port() const { return port_; }
  int requests() const { return requests_; }
  void advance(int64_t ms) { now_ += ms; }
  int64_t now() const { return now_; }
 private:
  std::atomic<int64_t> now_;
  std::atomic<int> requests_{0};
  std::atomic<bool> running_{false};
  int fd_ = -1;
  int port_ = 0;
  std::thread worker_;
};

class ClockScenario {
 public:
  explicit ClockScenario(int64_t deviceSkew)
      : authority(kOracleMs), clock(kOracleMs + deviceSkew, 1000), loop(clock) {
    db::NodeOptions options;
    options.data_dir = ":memory:";
    options.name = "qa-v2-clock";
    options.role = "indoor_panel";
    options.listen_addr = "127.0.0.1:0";
    options.enable_beacon = false;
    options.http_port = 0;
    db::NodeDeps deps;
    deps.clock = &clock;
    deps.loop = &loop;
    node.reset(new db::Node(options, std::move(deps)));
  }
  ~ClockScenario() { node->stop(); }
  void synchronize() {
    REQUIRE(authority.start());
    REQUIRE(node->start());
    node->setConfigKey("time.zone", "\"UTC\"");
    node->setConfigKey("time.ntp.servers",
        "[\"127.0.0.1:" + std::to_string(authority.port()) + "\"]");
    node->setConfigKey("time.ntp.enabled", "true");
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    bool ready = false;
    while (std::chrono::steady_clock::now() < deadline) {
      loop.pumpDue();
      auto status = db::json::parse(node->statusJson());
      auto time = db::json::get(status.get(), "time");
      if (db::json::getBool(time, "ok", false)) { ready = true; break; }
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    REQUIRE_MESSAGE(ready, "Loopback NTP must complete; a fixture failure is not an app regression");
    REQUIRE(authority.requests() >= 1);
    REQUIRE(displayMs() == authority.now());
  }
  int64_t displayMs() {
    auto time = db::json::parse(node->localTimeJson(0));
    REQUIRE(time);
    return db::json::getInt(time.get(), "wall_ms");
  }
  void elapse(int64_t ms) {
    authority.advance(ms);
    clock.advance(ms);
    loop.pumpDue();
  }
  OracleNtp authority;
  db::SimClock clock;
  db::Runloop loop;
  std::unique_ptr<db::Node> node;
};
}

TEST_CASE("qa_v2.clock.stable_ntp_advances_against_independent_authority") {
  ClockScenario s(-300000);
  s.synchronize();
  s.elapse(1234);
  CHECK(s.displayMs() == s.authority.now());
}

TEST_CASE("qa_v2.clock.os_corrects_slow_clock_without_double_offset") {
  ClockScenario s(-300000);
  s.synchronize();
  s.elapse(1500);
  s.clock.setWall(s.authority.now());
  s.loop.pumpDue();
  INFO("The OS has corrected its clock. The app must not add the old +300000ms again.");
  CHECK(s.displayMs() == s.authority.now());
}

TEST_CASE("qa_v2.clock.os_corrects_fast_clock_without_double_offset") {
  ClockScenario s(300000);
  s.synchronize();
  s.elapse(1500);
  s.clock.setWall(s.authority.now());
  s.loop.pumpDue();
  INFO("The OS has corrected its clock. The app must not retain the old -300000ms.");
  CHECK(s.displayMs() == s.authority.now());
}

TEST_CASE("qa_v2.clock.explicit_event_timestamp_is_not_corrected_twice") {
  ClockScenario s(-300000);
  s.synchronize();
  const int64_t recorded = kOracleMs - 60000;
  auto event = db::json::parse(s.node->localTimeJson(recorded));
  REQUIRE(event);
  CHECK(db::json::getInt(event.get(), "wall_ms") == recorded);
}

TEST_CASE("qa_v2.clock.disabling_ntp_restores_raw_system_time") {
  ClockScenario s(-300000);
  s.synchronize();
  s.node->setConfigKey("time.ntp.enabled", "false");
  s.loop.pumpDue();
  CHECK(s.displayMs() == s.clock.systemWallMs());
}
