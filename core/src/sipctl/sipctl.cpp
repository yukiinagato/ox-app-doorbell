
//








#include "sipctl/sipctl.h"

#include <pjsua-lib/pjsua.h>

#include <algorithm>
#include <atomic>
#include <thread>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <map>
#include <mutex>
#include <set>
#include <string>
#include <vector>

#include "util/log.h"

namespace db {

const char* sipBackendName() { return "pjsip"; }
bool sipBackendAvailable() { return true; }

namespace {
constexpr const char* kTag = "sipctl";

pj_str_t pstr(const std::string& s) {
  pj_str_t r;
  r.ptr = const_cast<char*>(s.c_str());
  r.slen = static_cast<pj_ssize_t>(s.size());
  return r;
}

bool sameSettings(const SipSettings& a, const SipSettings& b) {
  return a.server == b.server && a.port == b.port && a.transport == b.transport &&
         a.user == b.user && a.password == b.password && a.display_name == b.display_name &&
         a.rtp_port_start == b.rtp_port_start && a.ec_tail_ms == b.ec_tail_ms &&
         a.auto_answer == b.auto_answer && a.reg_retry_s == b.reg_retry_s &&
         a.null_audio == b.null_audio && a.direct_port == b.direct_port;
}


constexpr int kMaxMonitorCalls = 2;



std::string doorbellMode(pjsip_rx_data* rdata) {
  if (!rdata || !rdata->msg_info.msg) return "";
  pj_str_t hname = pj_str(const_cast<char*>("X-Doorbell-Mode"));
  auto* h = static_cast<pjsip_generic_string_hdr*>(
      pjsip_msg_find_hdr_by_name(rdata->msg_info.msg, &hname, nullptr));
  if (!h) return "";
  return std::string(h->hvalue.ptr, static_cast<size_t>(h->hvalue.slen));
}


void ensurePjThread() {
  if (!pj_thread_is_registered()) {
    static thread_local pj_thread_desc desc;
    static thread_local pj_thread_t* th = nullptr;
    pj_bzero(desc, sizeof(desc));
    pj_thread_register("db_sip", desc, &th);
  }
}
}  // namespace

struct SipCtl::Impl {
  Runloop& loop;
  Callbacks cbs;
  SipSettings st;

  bool running = false;
  pjsua_acc_id acc = PJSUA_INVALID_ID;
  std::atomic<int> call_id{PJSUA_INVALID_ID};
  std::string call_owner;  // loop-owned token for visitor lifecycle cancellation
  SipRegState reg_state = SipRegState::Idle;
  SipCallState call_state = SipCallState::Idle;




  // Guarded by mon_mu, which already serialises the dialog bookkeeping.
  std::string call_mode;
  void setCallMode(const std::string& mode) {
    std::lock_guard<std::mutex> lk(mon_mu);
    call_mode = mode;
  }
  std::string callMode() {
    std::lock_guard<std::mutex> lk(mon_mu);
    return call_mode;
  }

  std::mutex mon_mu;
  struct MonitorLeg {
    std::string peer;
    bool had_media = false;
  };
  std::map<pjsua_call_id, MonitorLeg> monitors;
  std::atomic<int> mon_count{0};
  // Peers whose monitor dialogs keep ending without ever carrying media. One panel churning
  // listen-in sessions can otherwise occupy a door station indefinitely: each dialog costs an
  // INVITE, media negotiation and a teardown, and on the oldest hardware that is enough to
  // starve everything else on the device.
  std::map<std::string, std::deque<int64_t>> empty_monitor_ends;
  static constexpr size_t kEmptyMonitorLimit = 8;
  static constexpr int64_t kEmptyMonitorWindowMs = 10'000;
  static constexpr int kMonitorRetryAfterS = 10;

  static int64_t nowMs() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
  }

  // True when this peer has recently produced more empty monitor dialogs than a working client
  // ever would.
  bool monitorPeerThrottled(const std::string& peer) {
    std::lock_guard<std::mutex> lk(mon_mu);
    auto it = empty_monitor_ends.find(peer);
    if (it == empty_monitor_ends.end()) return false;
    const int64_t cutoff = nowMs() - kEmptyMonitorWindowMs;
    while (!it->second.empty() && it->second.front() < cutoff) it->second.pop_front();
    if (it->second.empty()) {
      empty_monitor_ends.erase(it);
      return false;
    }
    return it->second.size() >= kEmptyMonitorLimit;
  }

  void noteEmptyMonitor(const std::string& peer) {
    if (peer.empty()) return;
    std::lock_guard<std::mutex> lk(mon_mu);
    auto& ends = empty_monitor_ends[peer];
    const int64_t now = nowMs();
    const int64_t cutoff = now - kEmptyMonitorWindowMs;
    while (!ends.empty() && ends.front() < cutoff) ends.pop_front();
    ends.push_back(now);
    if (ends.size() > kEmptyMonitorLimit * 4) ends.pop_front();
  }


  std::mutex src_mu;
  std::set<std::string> allowed_sources;

  // Conference port 0 is the sound device; muting its receive level silences the microphone
  // without tearing down the leg, so the far end simply stops hearing us.
  std::atomic<bool> mic_muted{false};

  void applyMicMuteLocked() const {
    pjsua_conf_adjust_rx_level(0, mic_muted.load() ? 0.0f : 1.0f);
  }

  bool addMonitor(pjsua_call_id cid, const std::string& peer) {
    std::lock_guard<std::mutex> lk(mon_mu);
    if (static_cast<int>(monitors.size()) >= kMaxMonitorCalls) return false;
    MonitorLeg leg;
    leg.peer = peer;
    monitors[cid] = leg;
    mon_count.store(static_cast<int>(monitors.size()));
    return true;
  }
  bool isMonitor(pjsua_call_id cid) {
    std::lock_guard<std::mutex> lk(mon_mu);
    return monitors.find(cid) != monitors.end();
  }
  void noteMonitorMedia(pjsua_call_id cid) {
    std::lock_guard<std::mutex> lk(mon_mu);
    auto it = monitors.find(cid);
    if (it != monitors.end()) it->second.had_media = true;
  }
  // Returns the peer when the leg existed, and reports whether it ever carried media.
  bool removeMonitor(pjsua_call_id cid, std::string* peer = nullptr,
                     bool* had_media = nullptr) {
    std::lock_guard<std::mutex> lk(mon_mu);
    auto it = monitors.find(cid);
    if (it == monitors.end()) return false;
    if (peer) *peer = it->second.peer;
    if (had_media) *had_media = it->second.had_media;
    monitors.erase(it);
    mon_count.store(static_cast<int>(monitors.size()));
    return true;
  }
  void clearMonitors() {
    std::lock_guard<std::mutex> lk(mon_mu);
    monitors.clear();
    empty_monitor_ends.clear();
    mon_count.store(0);
  }



  bool sourceAllowed(pjsip_rx_data* rdata) {
    std::lock_guard<std::mutex> lk(src_mu);
    if (allowed_sources.empty()) return true;
    if (!rdata) return false;
    const std::string src = rdata->pkt_info.src_name;
    if (!st.server.empty() && src == st.server) return true;
    return allowed_sources.count(src) > 0;
  }

  std::shared_ptr<std::atomic<bool>> alive{new std::atomic<bool>(true)};
  std::atomic<int> gen{0};
  std::atomic<bool> stopping{false};


  mutable std::mutex stat_mu;
  int64_t last_tx = 0, last_rx = 0;

  Impl(Runloop& l, Callbacks c) : loop(l), cbs(std::move(c)) {}


  void postReg(SipRegState s, const std::string& reason) {
    if (stopping.load()) return;
    auto a = alive;
    int g = gen.load();
    loop.post([this, a, g, s, reason] {
      if (!a->load() || g != gen.load()) return;
      if (reg_state == s) return;
      reg_state = s;
      DB_LOGI(kTag, std::string("reg: ") + regStateName(s) +
                        (reason.empty() ? "" : " (" + reason + ")"));
      if (cbs.on_reg_state) cbs.on_reg_state(s, reason);
    });
  }

  void postCall(SipCallState s, const std::string& remote) {
    if (stopping.load()) return;
    auto a = alive;
    int g = gen.load();
    loop.post([this, a, g, s, remote] {
      if (!a->load() || g != gen.load()) return;
      if (call_state == s) return;
      call_state = s;
      if (cbs.on_call_state) cbs.on_call_state(s, remote);
      if (s == SipCallState::Ended) {
        if (call_id.load() == PJSUA_INVALID_ID) call_owner.clear();
        call_state = SipCallState::Idle;
        if (cbs.on_call_state) cbs.on_call_state(SipCallState::Idle, remote);
      }
    });
  }

  void postDtmf(char digit) {
    if (stopping.load()) return;
    auto a = alive;
    int g = gen.load();
    loop.post([this, a, g, digit] {
      if (!a->load() || g != gen.load()) return;
      if (cbs.on_dtmf) cbs.on_dtmf(digit);
    });
  }

  static const char* regStateName(SipRegState s) {
    switch (s) {
      case SipRegState::Idle: return "idle";
      case SipRegState::Registering: return "registering";
      case SipRegState::Registered: return "registered";
      case SipRegState::Failed: return "failed";
    }
    return "?";
  }


  void startOnLoop(const SipSettings& s);
  void stopOnLoop();


  // ---- SIP event pump ----
  // pjsua's own worker polls every 10 ms whether or not anything is happening. This one follows
  // the work; see the note at the top of sipctl.h.
  std::thread pump_thread;
  std::atomic<bool> pump_stop{false};
  std::atomic<bool> registration_pending{false};
  // Iterations of the pump loop, so a test can measure the idle rate rather than infer it.
  std::atomic<uint64_t> pump_iterations{0};

  long earliestTimerMs() {
    pjsip_endpoint* endpt = pjsua_get_pjsip_endpt();
    if (!endpt) return -1;
    pj_timer_heap_t* heap = pjsip_endpt_get_timer_heap(endpt);
    if (!heap) return -1;
    pj_time_val delay;
    if (pj_timer_heap_earliest_time(heap, &delay) != PJ_SUCCESS) return -1;
    if (delay.sec < 0 || delay.msec < 0) return 0;
    if (delay.sec > 3600) return 3600L * 1000L;
    return static_cast<long>(delay.sec) * 1000L + delay.msec;
  }

  void pumpLoop() {
    ensurePjThread();
    while (!pump_stop.load(std::memory_order_relaxed)) {
      const int timeout = sipPumpTimeoutMs(pjsua_call_get_count() > 0,
                                           registration_pending.load(std::memory_order_relaxed),
                                           earliestTimerMs());
      pump_iterations.fetch_add(1, std::memory_order_relaxed);
      pjsua_handle_events(static_cast<unsigned>(timeout));
    }
  }

  void startPump() {
    pump_stop.store(false);
    pump_iterations.store(0);
    pump_thread = std::thread([this] { pumpLoop(); });
  }

  void stopPump() {
    pump_stop.store(true);
    if (pump_thread.joinable()) pump_thread.join();
  }

  static void s_on_reg_state2(pjsua_acc_id acc_id, pjsua_reg_info* info);
  static void s_on_call_state(pjsua_call_id call_id, pjsip_event* e);
  static void s_on_incoming_call(pjsua_acc_id acc_id, pjsua_call_id call_id, pjsip_rx_data* rdata);
  static void s_on_call_media_state(pjsua_call_id call_id);
  static void s_on_dtmf_digit2(pjsua_call_id call_id, const pjsua_dtmf_info* info);
  static void s_on_stream_destroyed(pjsua_call_id call_id, pjmedia_stream* strm, unsigned idx);
};


static std::atomic<SipCtl::Impl*> g_impl{nullptr};



void SipCtl::Impl::s_on_reg_state2(pjsua_acc_id, pjsua_reg_info* info) {
  Impl* im = g_impl.load();
  if (!im || !info || !info->cbparam) return;
  const pjsip_regc_cbparam* p = info->cbparam;
  // A final answer means the exchange is over and the pump can slow down again.
  if (p->status != PJ_SUCCESS || p->code >= 200)
    im->registration_pending.store(false, std::memory_order_relaxed);
  std::string reason = "code=" + std::to_string(p->code);
  if (p->status != PJ_SUCCESS) {
    im->postReg(SipRegState::Failed, "status=" + std::to_string(p->status));
  } else if (p->code / 100 == 2) {
    if (info->renew && p->expiration > 0)
      im->postReg(SipRegState::Registered, reason);
    else
      im->postReg(SipRegState::Idle, reason);
  } else if (p->code >= 300) {


    im->postReg(SipRegState::Failed, reason);
  }

}

void SipCtl::Impl::s_on_call_state(pjsua_call_id call_id, pjsip_event*) {
  Impl* im = g_impl.load();
  if (!im) return;
  pjsua_call_info ci;
  if (pjsua_call_get_info(call_id, &ci) != PJ_SUCCESS) return;
  std::string remote(ci.remote_info.ptr, static_cast<size_t>(ci.remote_info.slen));

  if (im->call_id.load() != call_id) {
    if (ci.state == PJSIP_INV_STATE_DISCONNECTED) {
      std::string peer;
      bool had_media = false;
      if (im->removeMonitor(call_id, &peer, &had_media)) {
        // A dialog that never carried media did nothing but cost the device work.
        if (!had_media) im->noteEmptyMonitor(peer);
        DB_LOGI(kTag, "monitor call #" + std::to_string(call_id) + " ended (" + remote +
                          (had_media ? "" : ", no media") + ", remaining " +
                          std::to_string(im->mon_count.load()) + ")");
      }
    }
    return;
  }
  switch (ci.state) {
    case PJSIP_INV_STATE_CALLING:
    case PJSIP_INV_STATE_INCOMING:
    case PJSIP_INV_STATE_EARLY:
    case PJSIP_INV_STATE_CONNECTING:
      im->postCall(SipCallState::Calling, remote);
      break;
    case PJSIP_INV_STATE_CONFIRMED:
      im->postCall(SipCallState::InCall, remote);
      break;
    case PJSIP_INV_STATE_DISCONNECTED:
      im->call_id.store(PJSUA_INVALID_ID);
      im->setCallMode("");
      im->postCall(SipCallState::Ended, remote);
      break;
    default:
      break;
  }
}

void SipCtl::Impl::s_on_incoming_call(pjsua_acc_id, pjsua_call_id call_id,
                                      pjsip_rx_data* rdata) {
  Impl* im = g_impl.load();
  if (!im) return;

  if (!im->sourceAllowed(rdata)) {
    DB_LOGW(kTag, std::string("incoming call rejected with 403 (unlisted source ") +
                      (rdata ? rdata->pkt_info.src_name : "?") + ")");
    pjsua_call_answer(call_id, PJSIP_SC_FORBIDDEN, nullptr, nullptr);
    return;
  }




  const std::string mode = doorbellMode(rdata);
  const bool busy = im->call_id.load() != PJSUA_INVALID_ID;
  bool want_monitor = (mode == "monitor") || (mode.empty() && busy);





  if (mode == "answer" && busy) {
    pjsua_call_id cur = im->call_id.load();
    pjsua_call_info mi;
    const bool confirmed = cur != PJSUA_INVALID_ID &&
                           pjsua_call_get_info(cur, &mi) == PJ_SUCCESS &&
                           mi.state == PJSIP_INV_STATE_CONFIRMED;
    if (confirmed) {
      DB_LOGI(kTag, "incoming answer call cannot take over established primary call #" + std::to_string(cur) +
                        " is already answered; falling back to monitor mode");
      want_monitor = true;
    } else if (cur != PJSUA_INVALID_ID &&
               im->call_id.compare_exchange_strong(cur, call_id)) {



      DB_LOGI(kTag, "answer takeover: canceling unestablished primary call #" + std::to_string(cur) +
                        " and accepting incoming call #" + std::to_string(call_id) + " bidirectionally");
      pjsua_call_hangup(cur, 0, nullptr, nullptr);
      im->setCallMode("answer");
      pjsua_call_answer(call_id, PJSIP_SC_OK, nullptr, nullptr);
      return;
    }

  }

  if (want_monitor) {
    const std::string peer = rdata ? std::string(rdata->pkt_info.src_name) : std::string();
    // A client whose listen-in sessions keep ending without media is churning, not listening.
    // Refusing it with a Retry-After keeps one misbehaving panel from occupying a door station.
    if (im->monitorPeerThrottled(peer)) {
      DB_LOGW(kTag, "refusing monitor call from " + peer +
                        ": too many dialogs ended without media");
      pjsua_msg_data msg_data;
      pjsua_msg_data_init(&msg_data);
      pjsip_generic_string_hdr retry;
      pj_str_t name = pj_str(const_cast<char*>("Retry-After"));
      char seconds[8];
      std::snprintf(seconds, sizeof(seconds), "%d", Impl::kMonitorRetryAfterS);
      pj_str_t value = pj_str(seconds);
      pjsip_generic_string_hdr_init2(&retry, &name, &value);
      pj_list_push_back(&msg_data.hdr_list, &retry);
      pjsua_call_answer(call_id, PJSIP_SC_BUSY_HERE, nullptr, &msg_data);  // 486 + Retry-After
      return;
    }
    if (!im->st.auto_answer || !im->addMonitor(call_id, peer)) {
      pjsua_call_answer(call_id, PJSIP_SC_BUSY_HERE, nullptr, nullptr);  // 486
      return;
    }
    pjsua_call_info ci;
    std::string remote;
    if (pjsua_call_get_info(call_id, &ci) == PJ_SUCCESS)
      remote.assign(ci.remote_info.ptr, static_cast<size_t>(ci.remote_info.slen));
    DB_LOGI(kTag, "accepted monitor call #" + std::to_string(call_id) + " (" + remote + ", total " +
                      std::to_string(im->mon_count.load()) + ", mode=" +
                      (mode.empty() ? "fallback" : mode) + ")");
    pjsua_call_answer(call_id, PJSIP_SC_OK, nullptr, nullptr);
    return;
  }


  int expected = PJSUA_INVALID_ID;
  if (!im->call_id.compare_exchange_strong(expected, call_id)) {
    pjsua_call_answer(call_id, PJSIP_SC_BUSY_HERE, nullptr, nullptr);
    return;
  }


  im->setCallMode(mode);
  if (mode == "answer" || im->st.auto_answer) {
    pjsua_call_answer(call_id, PJSIP_SC_OK, nullptr, nullptr);
  } else {
    pjsua_call_answer(call_id, PJSIP_SC_RINGING, nullptr, nullptr);
  }
}




void SipCtl::Impl::s_on_call_media_state(pjsua_call_id call_id) {
  Impl* im = g_impl.load();
  if (!im) return;
  pjsua_call_info ci;
  if (pjsua_call_get_info(call_id, &ci) != PJ_SUCCESS) return;
  if (ci.media_status != PJSUA_CALL_MEDIA_ACTIVE) return;
  const pjsua_conf_port_id slot = ci.conf_slot;
  if (slot == PJSUA_INVALID_ID) return;
  if (im->call_id.load() == call_id) {
    pjsua_conf_connect(slot, 0);
    pjsua_conf_connect(0, slot);
    // Reapply, because a mute set before the call was answered must survive into it.
    im->applyMicMuteLocked();
    DB_LOGI(kTag, "primary call #" + std::to_string(call_id) + ": bidirectional audio connected (conf slot " +
                      std::to_string(slot) + " <-> 0)");
  } else if (im->isMonitor(call_id)) {
    im->noteMonitorMedia(call_id);
    pjsua_conf_connect(0, slot);
    DB_LOGI(kTag, "monitor call #" + std::to_string(call_id) +
                      ": one-way microphone audio connected (conf 0 -> slot " + std::to_string(slot) + ")");
  }
}

void SipCtl::Impl::s_on_dtmf_digit2(pjsua_call_id, const pjsua_dtmf_info* info) {
  Impl* im = g_impl.load();
  if (!im || !info) return;
  if (info->method != PJSUA_DTMF_METHOD_RFC2833) return;
  im->postDtmf(static_cast<char>(info->digit));
}

void SipCtl::Impl::s_on_stream_destroyed(pjsua_call_id call_id, pjmedia_stream* strm,
                                         unsigned idx) {


  Impl* im = g_impl.load();
  if (!im || idx != 0 || im->call_id.load() != call_id) return;
  pjmedia_rtcp_stat st;
  if (pjmedia_stream_get_stat(strm, &st) == PJ_SUCCESS) {
    std::lock_guard<std::mutex> lk(im->stat_mu);
    im->last_tx = st.tx.pkt;
    im->last_rx = st.rx.pkt;
  }
}



void SipCtl::Impl::startOnLoop(const SipSettings& s) {
  if (running) stopOnLoop();
  st = s;




  const bool registered_mode = !st.server.empty() && !st.user.empty();
  if (!registered_mode && st.direct_port <= 0) return;

  Impl* expected = nullptr;
  if (!g_impl.compare_exchange_strong(expected, this)) {

    DB_LOGW(kTag, "pjsua is already owned by another SipCtl instance; SIP is disabled for this node");
    return;
  }

  pj_status_t rc = pjsua_create();
  if (rc != PJ_SUCCESS) {
    DB_LOGE(kTag, "pjsua_create failed: " + std::to_string(rc));
    g_impl.store(nullptr);
    return;
  }

  pjsua_config cfg;
  pjsua_config_default(&cfg);
  // No pjsua worker: its loop polls every 10 ms for ever, idle or not. We pump the events
  // ourselves at a rate that follows the work. See the note at the top of sipctl.h.
  cfg.thread_cnt = 0;
  cfg.cb.on_reg_state2 = &Impl::s_on_reg_state2;
  cfg.cb.on_call_state = &Impl::s_on_call_state;
  cfg.cb.on_incoming_call = &Impl::s_on_incoming_call;
  cfg.cb.on_call_media_state = &Impl::s_on_call_media_state;
  cfg.cb.on_dtmf_digit2 = &Impl::s_on_dtmf_digit2;
  cfg.cb.on_stream_destroyed = &Impl::s_on_stream_destroyed;

  pjsua_logging_config log_cfg;
  pjsua_logging_config_default(&log_cfg);

  const bool verbose = std::getenv("DB_SIP_LOG") != nullptr;
  log_cfg.console_level = verbose ? 4 : 1;
  log_cfg.level = verbose ? 4 : 2;

  pjsua_media_config med;
  pjsua_media_config_default(&med);
  med.clock_rate = 8000;
  med.no_vad = PJ_TRUE;
  if (!st.null_audio && st.ec_tail_ms > 0) {
    med.ec_options = PJMEDIA_ECHO_WEBRTC;
    med.ec_tail_len = static_cast<unsigned>(st.ec_tail_ms);
  } else {
    med.ec_tail_len = 0;
  }

  rc = pjsua_init(&cfg, &log_cfg, &med);
  if (rc != PJ_SUCCESS) {
    DB_LOGE(kTag, "pjsua_init failed: " + std::to_string(rc));
    pjsua_destroy();
    g_impl.store(nullptr);
    return;
  }



  pjsua_transport_config tcfg;
  pjsua_transport_config_default(&tcfg);
  tcfg.port = st.direct_port > 0 ? static_cast<unsigned>(st.direct_port) : 0;
  pjsip_transport_type_e tt =
      st.transport == "tcp" ? PJSIP_TRANSPORT_TCP : PJSIP_TRANSPORT_UDP;
  pjsua_transport_id tid = -1;
  rc = pjsua_transport_create(tt, &tcfg, &tid);
  if (rc != PJ_SUCCESS && tcfg.port != 0) {
    DB_LOGW(kTag, "fixed SIP port " + std::to_string(st.direct_port) +
                      " is in use; falling back to an ephemeral port without direct incoming calls");
    tcfg.port = 0;
    rc = pjsua_transport_create(tt, &tcfg, &tid);
  }
  if (rc != PJ_SUCCESS) {
    DB_LOGE(kTag, "pjsua_transport_create failed: " + std::to_string(rc));
    pjsua_destroy();
    g_impl.store(nullptr);
    return;
  }

  pjsua_start();
  startPump();
  if (st.null_audio) pjsua_set_null_snd_dev();


  {
    pjsua_codec_info ci[32];
    unsigned n = 32;
    if (pjsua_enum_codecs(ci, &n) == PJ_SUCCESS) {
      for (unsigned i = 0; i < n; i++)
        pjsua_codec_set_priority(&ci[i].codec_id, PJMEDIA_CODEC_PRIO_DISABLED);
    }
    std::string pcmu = "PCMU/8000";
    pj_str_t id = pstr(pcmu);
    pjsua_codec_set_priority(&id, PJMEDIA_CODEC_PRIO_HIGHEST);
  }

  if (!registered_mode) {


    rc = pjsua_acc_add_local(tid, PJ_TRUE, &acc);
    if (rc != PJ_SUCCESS) {
      DB_LOGE(kTag, "pjsua_acc_add_local failed: " + std::to_string(rc));
      pjsua_destroy();
      g_impl.store(nullptr);
      return;
    }


    if (pj_pool_t* pool = pjsua_pool_create("db_lacc", 512, 512)) {
      pjsua_acc_config lcfg;
      pjsua_acc_config_default(&lcfg);
      if (pjsua_acc_get_config(acc, pool, &lcfg) == PJ_SUCCESS) {
        lcfg.rtp_cfg.port = static_cast<unsigned>(st.rtp_port_start);
        lcfg.rtp_cfg.port_range = 99;
        pjsua_acc_modify(acc, &lcfg);
      }
      pj_pool_release(pool);
    }
    running = true;
    reg_state = SipRegState::Idle;
    call_state = SipCallState::Idle;
    DB_LOGI(kTag, "SIP started for direct calls without registration (" + st.transport + " port " +
                      std::to_string(tcfg.port == 0 ? 0 : st.direct_port) + ")");
    return;
  }


  std::string host = st.server + (st.port != 5060 ? ":" + std::to_string(st.port) : "");
  std::string tp = st.transport == "tcp" ? ";transport=tcp" : "";
  std::string id_uri = "sip:" + st.user + "@" + host + tp;
  if (!st.display_name.empty()) id_uri = "\"" + st.display_name + "\" <" + id_uri + ">";
  std::string reg_uri = "sip:" + host + tp;
  std::string realm = "*", scheme = "digest";

  pjsua_acc_config acfg;
  pjsua_acc_config_default(&acfg);
  acfg.id = pstr(id_uri);
  acfg.reg_uri = pstr(reg_uri);
  acfg.cred_count = 1;
  acfg.cred_info[0].realm = pstr(realm);
  acfg.cred_info[0].scheme = pstr(scheme);
  acfg.cred_info[0].username = pstr(st.user);
  acfg.cred_info[0].data_type = PJSIP_CRED_DATA_PLAIN_PASSWD;
  acfg.cred_info[0].data = pstr(st.password);
  acfg.reg_retry_interval = static_cast<unsigned>(st.reg_retry_s > 0 ? st.reg_retry_s : 30);
  acfg.rtp_cfg.port = static_cast<unsigned>(st.rtp_port_start);
  acfg.rtp_cfg.port_range = 99;




  acfg.allow_contact_rewrite = PJ_FALSE;
  acfg.allow_via_rewrite = PJ_FALSE;

  rc = pjsua_acc_add(&acfg, PJ_TRUE, &acc);
  if (rc != PJ_SUCCESS) {
    DB_LOGE(kTag, "pjsua_acc_add failed: " + std::to_string(rc));
    pjsua_destroy();
    g_impl.store(nullptr);
    return;
  }

  running = true;
  registration_pending.store(true, std::memory_order_relaxed);
  reg_state = SipRegState::Registering;
  call_state = SipCallState::Idle;
  DB_LOGI(kTag, "SIP started: " + st.user + "@" + host + " (" + st.transport + ")");
  if (cbs.on_reg_state) cbs.on_reg_state(SipRegState::Registering, "");
}

void SipCtl::Impl::stopOnLoop() {
  if (!running) return;
  gen.fetch_add(1);
  stopping.store(true);
  ensurePjThread();
  DB_LOGI(kTag, "stopping SIP: hang up, unregister, then destroy pjsua");
  pjsua_call_hangup_all();
  if (acc != PJSUA_INVALID_ID) pjsua_acc_set_registration(acc, PJ_FALSE);
  // The pump must be off the endpoint before it is torn down: handle_events on a destroyed
  // endpoint is a use-after-free, not a no-op.
  stopPump();
  pjsua_destroy();
  g_impl.store(nullptr);
  stopping.store(false);
  acc = PJSUA_INVALID_ID;
  call_id.store(PJSUA_INVALID_ID);
  call_owner.clear();
  clearMonitors();
  running = false;
  reg_state = SipRegState::Idle;
  call_state = SipCallState::Idle;
}



SipCtl::SipCtl(Runloop& loop, Callbacks cbs) : impl_(new Impl(loop, std::move(cbs))) {}

SipCtl::~SipCtl() {

  impl_->loop.callSync([this] { impl_->stopOnLoop(); });
  impl_->alive->store(false);
}

void SipCtl::start(const SipSettings& settings) { impl_->startOnLoop(settings); }

void SipCtl::stop() { impl_->stopOnLoop(); }

void SipCtl::updateSettings(const SipSettings& settings) {
  if (sameSettings(impl_->st, settings)) return;
  DB_LOGI(kTag, "SIP settings changed; restarting and registering again");
  impl_->startOnLoop(settings);
}

void SipCtl::call(const std::string& target, const std::string& mode) {
  (void)callOwned("", target, mode);
}

bool SipCtl::callOwned(const std::string& owner, const std::string& target,
                       const std::string& mode) {
  Impl* im = impl_.get();
  if (!im->running || im->acc == PJSUA_INVALID_ID) {
    DB_LOGW(kTag, "call(" + target + "): SIP is not started; ignoring call");
    return false;
  }
  if (im->call_id.load() != PJSUA_INVALID_ID) {
    DB_LOGW(kTag, "call(" + target + "): another call is active; ignoring call");
    return false;
  }
  ensurePjThread();


  std::string uri;
  if (target.compare(0, 4, "sip:") == 0) {
    uri = target;
  } else if (!im->st.server.empty()) {
    std::string host = im->st.server +
                       (im->st.port != 5060 ? ":" + std::to_string(im->st.port) : "");
    std::string tp = im->st.transport == "tcp" ? ";transport=tcp" : "";
    uri = "sip:" + target + "@" + host + tp;
  } else {
    DB_LOGW(kTag, "call(" + target + "): extension call requires a configured server");
    return false;
  }


  pjsua_msg_data md;
  pjsua_msg_data_init(&md);
  pjsip_generic_string_hdr mode_hdr;
  pj_str_t hname = pj_str(const_cast<char*>("X-Doorbell-Mode"));
  pj_str_t hval = pstr(mode);
  if (!mode.empty()) {
    pjsip_generic_string_hdr_init2(&mode_hdr, &hname, &hval);
    pj_list_push_back(&md.hdr_list, &mode_hdr);
  }
  pj_str_t dst = pstr(uri);
  pjsua_call_id cid = PJSUA_INVALID_ID;
  pj_status_t rc = pjsua_call_make_call(im->acc, &dst, nullptr, nullptr,
                                        mode.empty() ? nullptr : &md, &cid);
  if (rc != PJ_SUCCESS) {
    DB_LOGE(kTag, "outbound call failed " + uri + ": " + std::to_string(rc));
    return false;
  }
  im->call_id.store(cid);
  im->call_owner = owner;
  im->setCallMode(mode);
  DB_LOGI(kTag, "calling " + uri + (mode.empty() ? "" : " (mode=" + mode + ")"));
  return true;
}

void SipCtl::setAllowedSources(const std::vector<std::string>& ips) {
  Impl* im = impl_.get();
  std::lock_guard<std::mutex> lk(im->src_mu);
  im->allowed_sources.clear();
  im->allowed_sources.insert(ips.begin(), ips.end());
}

int SipCtl::monitorCount() const { return impl_->mon_count.load(); }

std::string SipCtl::callMode() const { return impl_->callMode(); }

void SipCtl::hangup() {
  Impl* im = impl_.get();
  if (!im->running) return;
  ensurePjThread();
  pjsua_call_hangup_all();
}

bool SipCtl::hangupOwned(const std::string& owner) {
  Impl* im = impl_.get();
  const int cid = im->call_id.load();
  if (!im->running || owner.empty() || im->call_owner != owner || cid == PJSUA_INVALID_ID)
    return false;
  ensurePjThread();
  return pjsua_call_hangup(cid, 0, nullptr, nullptr) == PJ_SUCCESS;
}

void SipCtl::answer() {
  Impl* im = impl_.get();
  int cid = im->call_id.load();
  if (!im->running || cid == PJSUA_INVALID_ID) return;
  ensurePjThread();
  pjsua_call_answer(cid, PJSIP_SC_OK, nullptr, nullptr);
}

bool SipCtl::sendDtmf(const std::string& digits) {
  Impl* im = impl_.get();
  int cid = im->call_id.load();
  if (!im->running || cid == PJSUA_INVALID_ID || digits.empty()) return false;
  ensurePjThread();
  pj_str_t value = pstr(digits);
  const pj_status_t rc = pjsua_call_dial_dtmf(cid, &value);
  if (rc != PJ_SUCCESS) {
    DB_LOGW(kTag, "send DTMF failed: " + std::to_string(rc));
    return false;
  }
  return true;
}

void SipCtl::setMicMuted(bool muted) {
  impl_->mic_muted.store(muted);
  if (impl_->running) impl_->applyMicMuteLocked();
}

bool SipCtl::micMuted() const { return impl_->mic_muted.load(); }

SipRegState SipCtl::regState() const { return impl_->reg_state; }

SipCallState SipCtl::callState() const { return impl_->call_state; }

void SipCtl::rtpStats(int64_t* tx_pkts, int64_t* rx_pkts) const {
  Impl* im = impl_.get();
  int cid = im->call_id.load();
  if (im->running && cid != PJSUA_INVALID_ID) {
    ensurePjThread();
    pjsua_stream_stat ss;
    if (pjsua_call_get_stream_stat(cid, 0, &ss) == PJ_SUCCESS) {
      std::lock_guard<std::mutex> lk(im->stat_mu);
      im->last_tx = ss.rtcp.tx.pkt;
      im->last_rx = ss.rtcp.rx.pkt;
    }
  }
  std::lock_guard<std::mutex> lk(im->stat_mu);
  if (tx_pkts) *tx_pkts = im->last_tx;
  if (rx_pkts) *rx_pkts = im->last_rx;
}

}  // namespace db
