#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <map>
#include <mutex>
#include <thread>
#include "sipctl/sipctl.h"
#include "util/common.h"
#include "util/clock.h"
#include "util/runloop.h"
#include "minisip.h"
using namespace db;

namespace {
struct Audio {
  bool tone = false;
  unsigned phase = 0;
  uint64_t loud = 0;
  uint64_t samples = 0;
  static void receive(const int16_t* pcm, int count, void* user) {
    auto& a = *static_cast<Audio*>(user);
    for (int i = 0; i < count; ++i) if (std::abs(int(pcm[i])) > 250) ++a.loud;
    a.samples += count;
  }
  static int transmit(int16_t* pcm, int count, void* user) {
    auto& a = *static_cast<Audio*>(user);
    for (int i = 0; i < count; ++i)
      pcm[i] = a.tone ? int16_t(9000 * std::sin((a.phase++ % 80) * 6.283185307179586 / 80)) : 0;
    return count;
  }
  void reset() { loud = samples = 0; }
};
bool require(bool condition, const char* name) {
  if (!condition) std::fprintf(stderr, "FAIL: %s\n", name);
  return condition;
}
}

int main() {
  RealClock clock;
  Runloop loop(clock);
  loop.start();
  std::array<uint8_t, 32> key{};
  key.fill(0x37);
  const std::string server(32, 'f'), a(32, 'a'), b(32, 'b'), c(32, 'c');
  SipPeerAuth verifier;
  verifier.setKey(server, key);
  std::mutex admission_mutex;
  std::map<std::string, std::string> admission{{"room:front:0:legA", a},
      {"room:front:0:legB", b}, {"room:side:0:legC", c}};
  std::atomic<int> primary{0}, established{0};
  SipCtl::Callbacks callbacks;
  callbacks.on_call_state = [&](SipCallState, const std::string&) { ++primary; };
  callbacks.on_room_state = [&](const std::string&, SipCallState state) {
    if (state == SipCallState::InCall) ++established;
  };
  SipCtl sip(loop, callbacks);
  std::map<std::string, SipCtl::RoomPolicy> policies{
      {"room:front:0:legA", {"front", true, false}},
      {"room:front:0:legB", {"front", true, false}},
      {"room:side:0:legC", {"side", true, false}}};
  SipSettings settings;
  settings.direct_port = 39190;
  settings.null_audio = true;
  settings.ec_tail_ms = 0;
  loop.callSync([&] {
    sip.setInboundPolicy([&](const std::string& source, const std::string& auth, const std::string& mode) {
      std::string peer;
      if (source != "127.0.0.1" || !verifier.verify(auth, mode, clock.wallMs(), &peer)) return SipInboundPath::Rejected;
      std::lock_guard<std::mutex> lock(admission_mutex);
      auto found = admission.find(mode);
      return found != admission.end() && found->second == peer ? SipInboundPath::Peer : SipInboundPath::Rejected;
    }, [](const std::string&) { return std::string(); });
    sip.start(settings);
    sip.setRoomPolicies(policies);
  });
  Audio aa, ab, ac;
  aa.tone = true; ac.tone = true;
  auto call = [&](const std::string& peer, const std::string& mode, Audio& audio) {
    ms_callbacks cb{};
    cb.on_rx_audio = Audio::receive; cb.pull_tx_audio = Audio::transmit; cb.user = &audio;
    const auto auth = sipPeerAuthValue(key, peer, clock.wallMs(), hexEncode(randomBytes(16)), mode);
    return ms_call_authenticated("127.0.0.1", settings.direct_port, mode.c_str(), auth.c_str(), &cb);
  };
  ms_session *sa = call(a, "room:front:0:legA", aa), *sb = call(b, "room:front:0:legB", ab),
             *sc = call(c, "room:side:0:legC", ac);
  auto pump = [&](int ms) {
    auto until = std::chrono::steady_clock::now() + std::chrono::milliseconds(ms);
    while (std::chrono::steady_clock::now() < until) {
      for (auto* session : {sa, sb, sc}) if (session) ms_poll(session, 0);
      std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
  };
  bool ok = require(sa && sb && sc, "authenticated clients created");
  pump(2200);
  ok &= require(established == 3 && primary == 0, "three room legs establish without primary-call callbacks");
  ok &= require(ab.loud > 1000, "joined resident receives the other resident's real RTP audio");
  ok &= require(ac.loud < 100, "another door never receives the front room mix");
  policies["room:front:0:legA"].held = true;
  loop.callSync([&] { sip.setRoomPolicies(policies); });
  pump(600); ab.reset();
  pump(800);
  ok &= require(ab.loud < 100, "holding removes microphone forwarding while another door keeps sending");
  policies["room:front:0:legA"].held = false;
  loop.callSync([&] { sip.setRoomPolicies(policies); });
  pump(500); ab.reset(); pump(800);
  ok &= require(ab.loud > 1000, "resuming restores RTP forwarding on the same dialog");
  policies.erase("room:front:0:legA");
  { std::lock_guard<std::mutex> lock(admission_mutex); admission.erase("room:front:0:legA"); }
  loop.callSync([&] { sip.setRoomPolicies(policies); });
  pump(600); ab.reset(); pump(500);
  ok &= require(ms_get_state(sa) == MS_STATE_ENDED && ab.loud < 100, "revoking the losing leg ends only that leg");
  ms_free(sa); sa = nullptr;
  policies["room:front:0:newA"] = {"front", true, false};
  { std::lock_guard<std::mutex> lock(admission_mutex); admission["room:front:0:newA"] = a; }
  loop.callSync([&] { sip.setRoomPolicies(policies); });
  sa = call(a, "room:front:0:newA", aa);
  pump(1000); ab.reset(); pump(700);
  ok &= require(ab.loud > 1000 && ms_get_state(sb) == MS_STATE_IN_CALL,
      "a new admission joins the surviving conversation after takeover");
  auto* forged = call(a, "room:front:0:legB", aa);
  for (int i = 0; forged && i < 100; ++i) { ms_poll(forged, 0); pump(5); }
  ok &= require(forged && ms_get_state(forged) == MS_STATE_ENDED &&
      ms_get_state(sb) == MS_STATE_IN_CALL, "another member cannot use a participant's admission");
  if (forged) ms_free(forged);
  for (auto* session : {sa, sb, sc}) if (session) ms_free(session);
  loop.callSync([&] { sip.stop(); });
  loop.stop();
  std::printf("conversation RTP join/hold/resume/revoke/isolation/admission: %s\n", ok ? "PASS" : "FAIL");
  return ok ? 0 : 1;
}
