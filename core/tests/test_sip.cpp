

//   DB_SIP_TEST=1 ./doorbell_tests -tc="sip:*"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <random>
#include <string>
#include <vector>

#include "doctest.h"
#include "test_env.h"
#include "node/node.h"
#include "sipctl/sipctl.h"
#include "util/clock.h"
#include "util/json.h"
#include "util/runloop.h"

using namespace db;

namespace {

bool sipTestEnabled() { return std::getenv("DB_SIP_TEST") != nullptr; }

constexpr const char* kServer = "127.0.0.1";

SipSettings devSettings(const std::string& user, const std::string& pass) {
  SipSettings s;
  s.server = kServer;
  s.port = 5060;
  s.user = user;
  s.password = pass;
  s.display_name = "test-door";
  s.null_audio = true;
  s.reg_retry_s = 2;
  return s;
}


struct SipFix {
  RealClock clock;
  Runloop loop{clock};
  std::mutex mu;
  std::condition_variable cv;
  std::vector<SipRegState> regs;
  std::vector<SipCallState> calls;
  std::string digits;
  std::unique_ptr<SipCtl> sip;

  SipFix() {
    loop.start();
    SipCtl::Callbacks cb;
    cb.on_reg_state = [this](SipRegState s, const std::string&) {
      std::lock_guard<std::mutex> lk(mu);
      regs.push_back(s);
      cv.notify_all();
    };
    cb.on_call_state = [this](SipCallState s, const std::string&) {
      std::lock_guard<std::mutex> lk(mu);
      calls.push_back(s);
      cv.notify_all();
    };
    cb.on_dtmf = [this](char d) {
      std::lock_guard<std::mutex> lk(mu);
      digits.push_back(d);
      cv.notify_all();
    };
    sip.reset(new SipCtl(loop, std::move(cb)));
  }

  ~SipFix() {
    sip.reset();
    loop.stop();
  }


  template <typename F>
  void on(F&& f) {
    loop.callSync(std::forward<F>(f));
  }

  bool waitReg(SipRegState want, int ms) {
    std::unique_lock<std::mutex> lk(mu);
    return cv.wait_for(lk, std::chrono::milliseconds(ms), [&] {
      return std::find(regs.begin(), regs.end(), want) != regs.end();
    });
  }
  bool waitCall(SipCallState want, int ms) {
    std::unique_lock<std::mutex> lk(mu);
    return cv.wait_for(lk, std::chrono::milliseconds(ms), [&] {
      return std::find(calls.begin(), calls.end(), want) != calls.end();
    });
  }
};

}  // namespace

TEST_CASE("sip: extension 8001 registers within five seconds") {
  if (!sipTestEnabled()) return;
  SipFix f;
  auto t0 = std::chrono::steady_clock::now();
  f.on([&] { f.sip->start(devSettings("8001", "devpass8001")); });
  REQUIRE(f.waitReg(SipRegState::Registered, 5000));
  auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - t0)
                .count();
  std::printf("[sip] registration took %lld ms\n", static_cast<long long>(ms));
  f.on([&] { CHECK(f.sip->regState() == SipRegState::Registered); });
}

TEST_CASE("sip: call reaches InCall, exchanges RTP with echo, and hangs up") {
  if (!sipTestEnabled()) return;
  SipFix f;
  f.on([&] { f.sip->start(devSettings("8001", "devpass8001")); });
  REQUIRE(f.waitReg(SipRegState::Registered, 5000));

  f.on([&] { f.sip->call("600"); });
  REQUIRE(f.waitCall(SipCallState::InCall, 5000));

  std::this_thread::sleep_for(std::chrono::seconds(3));
  int64_t tx = 0, rx = 0;
  f.on([&] { f.sip->rtpStats(&tx, &rx); });
  std::printf("[sip] RTP tx=%lld rx=%lld over three seconds\n", static_cast<long long>(tx),
              static_cast<long long>(rx));
  CHECK(tx > 50);
  CHECK(rx > 50);

  f.on([&] { f.sip->hangup(); });
  REQUIRE(f.waitCall(SipCallState::Ended, 5000));
  REQUIRE(f.waitCall(SipCallState::Idle, 1000));
}

TEST_CASE("sip: a wrong password fails within ten seconds") {
  if (!sipTestEnabled()) return;
  SipFix f;
  f.on([&] { f.sip->start(devSettings("8002", "wrong")); });
  REQUIRE(f.waitReg(SipRegState::Failed, 10000));
  CHECK(!f.waitReg(SipRegState::Registered, 500));
}






namespace {

SipSettings directSettings(int direct_port) {
  SipSettings s;
  s.null_audio = true;
  s.direct_port = direct_port;
  return s;
}

bool waitMonitorCount(SipFix& f, int want, int ms) {
  for (int i = 0; i < ms / 50; i++) {
    int n = 0;
    f.on([&] { n = f.sip->monitorCount(); });
    if (n == want) return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
  }
  return false;
}
}  // namespace

TEST_CASE("sip: direct monitor INVITE is accepted as one-way audio with RTP") {
  if (!sipTestEnabled()) return;
  const int port = 47380 + (::getpid() % 17);
  SipFix f;
  f.on([&] { f.sip->start(directSettings(port)); });
  f.on([&] { CHECK(f.sip->regState() == SipRegState::Idle); });


  f.on([&] { f.sip->call("sip:127.0.0.1:" + std::to_string(port), "monitor"); });
  REQUIRE(f.waitCall(SipCallState::InCall, 5000));
  REQUIRE(waitMonitorCount(f, 1, 3000));

  std::this_thread::sleep_for(std::chrono::seconds(2));
  int64_t tx = 0, rx = 0;
  f.on([&] { f.sip->rtpStats(&tx, &rx); });
  std::printf("[sip] direct-call RTP tx=%lld rx=%lld over two seconds\n", static_cast<long long>(tx),
              static_cast<long long>(rx));
  CHECK(tx > 30);
  CHECK(rx > 30);

  f.on([&] { f.sip->hangup(); });
  REQUIRE(f.waitCall(SipCallState::Ended, 5000));
  CHECK(waitMonitorCount(f, 0, 3000));
}

TEST_CASE("sip: owned cancellation rejects an unrelated Core call id") {
  if (!sipTestEnabled()) return;
  const int port = 47380 + (::getpid() % 17);
  SipFix f;
  f.on([&] { f.sip->start(directSettings(port)); });
  bool started = false;
  f.on([&] {
    started = f.sip->callOwned("visitor-call-a",
                               "sip:127.0.0.1:" + std::to_string(port), "monitor");
  });
  REQUIRE(started);
  REQUIRE(f.waitCall(SipCallState::InCall, 5000));
  REQUIRE(waitMonitorCount(f, 1, 3000));

  bool unrelated_hung_up = true;
  f.on([&] { unrelated_hung_up = f.sip->hangupOwned("visitor-call-b"); });
  CHECK_FALSE(unrelated_hung_up);
  f.on([&] { CHECK(f.sip->callState() == SipCallState::InCall); });

  bool owner_hung_up = false;
  f.on([&] { owner_hung_up = f.sip->hangupOwned("visitor-call-a"); });
  CHECK(owner_hung_up);
  REQUIRE(f.waitCall(SipCallState::Ended, 5000));
  CHECK(waitMonitorCount(f, 0, 3000));
}

TEST_CASE("sip: direct INVITE without a mode falls back to monitor during a primary call") {
  if (!sipTestEnabled()) return;
  const int port = 47380 + (::getpid() % 17);
  SipFix f;
  f.on([&] { f.sip->start(directSettings(port)); });

  f.on([&] { f.sip->call("sip:127.0.0.1:" + std::to_string(port)); });
  REQUIRE(f.waitCall(SipCallState::InCall, 5000));
  REQUIRE(waitMonitorCount(f, 1, 3000));
  f.on([&] { f.sip->hangup(); });
  REQUIRE(f.waitCall(SipCallState::Ended, 5000));
  CHECK(waitMonitorCount(f, 0, 3000));
}

TEST_CASE("sip: direct answer INVITE cancels an unestablished primary call and takes over") {
  if (!sipTestEnabled()) return;
  const int port = 47380 + (::getpid() % 17);
  SipFix f;
  f.on([&] { f.sip->start(directSettings(port)); });




  f.on([&] { f.sip->call("sip:127.0.0.1:" + std::to_string(port), "answer"); });
  REQUIRE(f.waitCall(SipCallState::InCall, 5000));
  REQUIRE(f.waitCall(SipCallState::Ended, 5000));
  CHECK(waitMonitorCount(f, 0, 500));
}

TEST_CASE("sip: setAllowedSources rejects a direct INVITE from an unlisted source") {
  if (!sipTestEnabled()) return;
  const int port = 47380 + (::getpid() % 17);
  SipFix f;
  f.on([&] { f.sip->start(directSettings(port)); });
  f.on([&] { f.sip->setAllowedSources({"10.255.255.1"}); });
  f.on([&] { f.sip->call("sip:127.0.0.1:" + std::to_string(port), "monitor"); });
  REQUIRE(f.waitCall(SipCallState::Ended, 5000));
  CHECK(waitMonitorCount(f, 0, 500));
  bool in_call = false;
  {
    std::lock_guard<std::mutex> lk(f.mu);
    in_call = std::find(f.calls.begin(), f.calls.end(), SipCallState::InCall) != f.calls.end();
  }
  CHECK(!in_call);

  f.on([&] { f.sip->setAllowedSources({}); });
}



namespace {
int freePortSip(std::mt19937& /*rng*/) {
  // Ports come from one process-wide allocator; see core/tests/test_ports.h.
  return db::testing::freeListenPort();
}

struct UiRec {
  std::mutex mu;
  std::condition_variable cv;
  std::vector<std::string> evs;
  void push(const std::string& e) {
    {
      std::lock_guard<std::mutex> lk(mu);
      evs.push_back(e);
    }
    cv.notify_all();
  }

  bool waitEv(const std::string& t, const std::string& key, const std::string& val, int ms) {
    std::unique_lock<std::mutex> lk(mu);
    return cv.wait_for(lk, std::chrono::milliseconds(ms), [&] {
      for (const auto& e : evs) {
        auto d = json::parse(e);
        if (!d || json::getString(d.get(), "t") != t) continue;
        if (key.empty() || json::getString(d.get(), key.c_str()) == val) return true;
      }
      return false;
    });
  }
};
}  // namespace

TEST_CASE("sip: Node press rule transitions a SIP call from calling to in_call") {
  if (!sipTestEnabled()) return;
  std::mt19937 rng(static_cast<uint32_t>(::getpid()) ^ 0x51Au);
  int mesh_port = freePortSip(rng);
  REQUIRE(mesh_port > 0);

  NodeOptions o;
  o.data_dir = ":memory:";
  o.name = "sip-door";
  o.role = "door_station";
  o.door = "d_front";
  o.listen_addr = "127.0.0.1:" + std::to_string(mesh_port);
  o.psk.fill(0x5a);
  o.enable_beacon = false;
  o.http_port = 0;
  o.sip_user = "8001";
  o.sip_pass = "devpass8001";
  o.sip_null_audio = true;
  Node node(o);
  UiRec ui;
  node.setUiEventCb([&](const std::string& e) { ui.push(e); });
  REQUIRE(node.start());


  node.setConfigKey("sip.server", "\"127.0.0.1\"");
  node.setConfigKey("sip.port", "5060");
  node.setConfigKey("trigger_rules.r1",
                    "{\"enabled\":true,"
                    "\"when\":{\"type\":\"button\",\"doors\":[\"d_front\"]},"
                    "\"actions\":[{\"type\":\"sip_call\",\"target_extension\":\"600\"}]}");

  REQUIRE(ui.waitEv("sip", "state", "registered", 10000));

  node.press("");
  CHECK(ui.waitEv("state", "state", "calling", 5000));
  CHECK(ui.waitEv("state", "state", "in_call", 8000));


  auto st = json::parse(node.statusJson());
  REQUIRE(st);
  cJSON* sip = json::get(st.get(), "sip");
  REQUIRE(sip);
  CHECK(json::getBool(sip, "registered", false));

  node.stop();
}

TEST_CASE("sip: a listen-in dialog can never answer a call") {
  // Real-device finding: a ringing call was recorded as answered by an indoor panel nobody had
  // touched. An outbound monitor dialog occupies the same primary slot as a real call, so the
  // "call established while ringing" branch fired for a listen-in session and reported it as an
  // answer. Only a dialog someone is actually talking on may answer.
  CHECK_FALSE(SipCtl::dialogCanAnswer("monitor"));
  CHECK(SipCtl::dialogCanAnswer(""));        // an ordinary two-way call
  CHECK(SipCtl::dialogCanAnswer("answer"));  // an explicit takeover by a person
}
