// sipctl の実 Asterisk 統合テスト (deploy/dev/asterisk のコンテナが必要)。
// 既定ではスキップ — DB_SIP_TEST=1 で有効化:
//   DB_SIP_TEST=1 ./doorbell_tests -tc="sip:*"
// 音声は null デバイス (SipSettings.null_audio) — 実音声デバイス不要。
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
  s.null_audio = true;  // テストモード: null 音声デバイス
  s.reg_retry_s = 2;
  return s;
}

// RealClock + threaded Runloop 上の SipCtl。状態変化を mutex + cv で記録。
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
    sip.reset();  // 内部で loop 上の stop → pjsua_destroy
    loop.stop();
  }

  // 公開 API は Runloop 上から (ヘッダの契約)
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

TEST_CASE("sip: 8001 登録 → 5 秒以内に Registered") {
  if (!sipTestEnabled()) return;  // DB_SIP_TEST=1 の時のみ (CI 非依存)
  SipFix f;
  auto t0 = std::chrono::steady_clock::now();
  f.on([&] { f.sip->start(devSettings("8001", "devpass8001")); });
  REQUIRE(f.waitReg(SipRegState::Registered, 5000));
  auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - t0)
                .count();
  std::printf("[sip] 登録所要 %lld ms\n", static_cast<long long>(ms));
  f.on([&] { CHECK(f.sip->regState() == SipRegState::Registered); });
}

TEST_CASE("sip: call(600) → InCall → RTP 双方向 (Echo) → hangup") {
  if (!sipTestEnabled()) return;
  SipFix f;
  f.on([&] { f.sip->start(devSettings("8001", "devpass8001")); });
  REQUIRE(f.waitReg(SipRegState::Registered, 5000));

  f.on([&] { f.sip->call("600"); });
  REQUIRE(f.waitCall(SipCallState::InCall, 5000));

  std::this_thread::sleep_for(std::chrono::seconds(3));
  int64_t tx = 0, rx = 0;
  f.on([&] { f.sip->rtpStats(&tx, &rx); });
  std::printf("[sip] RTP tx=%lld rx=%lld (3 秒)\n", static_cast<long long>(tx),
              static_cast<long long>(rx));
  CHECK(tx > 50);
  CHECK(rx > 50);

  f.on([&] { f.sip->hangup(); });
  REQUIRE(f.waitCall(SipCallState::Ended, 5000));
  REQUIRE(f.waitCall(SipCallState::Idle, 1000));
}

TEST_CASE("sip: 誤パスワード → 10 秒以内に Failed") {
  if (!sipTestEnabled()) return;
  SipFix f;
  f.on([&] { f.sip->start(devSettings("8002", "wrong")); });
  REQUIRE(f.waitReg(SipRegState::Failed, 10000));
  CHECK(!f.waitReg(SipRegState::Registered, 500));  // 登録されてしまわない
}

// ---------- Node 統合 (実 TCP Node + trigger_rule sip_call) ----------

namespace {
int freePortSip(std::mt19937& rng) {
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
  // {"t":t} かつ (key 指定時) [key]==val のイベントを待つ
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

TEST_CASE("sip: Node 統合 — press → trigger_rule sip_call → calling → in_call") {
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
  o.http_port = 0;
  o.sip_user = "8001";  // boot 上書き (config sip.accounts 未設定)
  o.sip_pass = "devpass8001";
  o.sip_null_audio = true;
  Node node(o);
  UiRec ui;
  node.setUiEventCb([&](const std::string& e) { ui.push(e); });
  REQUIRE(node.start());

  // SIP 設定 + ルールを config へ (server 設定 → デバウンス後に登録が走る)
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

  // status_json にも反映されている
  auto st = json::parse(node.statusJson());
  REQUIRE(st);
  cJSON* sip = json::get(st.get(), "sip");
  REQUIRE(sip);
  CHECK(json::getBool(sip, "registered", false));

  node.stop();  // 停止順: sipctl → httpd → mesh (通話は切断される)
}
