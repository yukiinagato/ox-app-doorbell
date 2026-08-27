// sipctl — pjsua (C API) による実装。
//
// スレッド/ライフサイクル設計:
//  - 公開 API は Runloop 上から呼ばれる (ヘッダの契約)。pjsua は自前 worker スレッドを
//    持ち、コールバックはそこから届く → Runloop::post で marshal する。コールバック内では
//    Runloop::callSync を呼ばない (デッドロック)。post のみ。
//  - pjsua はプロセス内単一インスタンス (g_impl)。start() で pjsua_create/init/start、
//    stop() で 通話切断 → 登録解除 → pjsua_destroy。再 start 可能。
//  - 破棄と post の競合は alive フラグ + 世代番号 (gen) で防ぐ:
//    stop/再start の度に gen++ し、古い世代の post は無視。stopping 中の新規 post は抑止。
#include "sipctl/sipctl.h"

#include <pjsua-lib/pjsua.h>

#include <atomic>
#include <mutex>

#include "util/log.h"

namespace db {

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
         a.null_audio == b.null_audio;
}

// pjsua API を呼ぶ前のスレッド登録 (未登録スレッドからの防御。通常は create したループ)
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

  bool running = false;  // pjsua が生きている (loop 上でのみ触る)
  pjsua_acc_id acc = PJSUA_INVALID_ID;
  std::atomic<int> call_id{PJSUA_INVALID_ID};  // 進行中呼 (pjsua スレッドからも書く)
  SipRegState reg_state = SipRegState::Idle;   // loop 上でのみ触る
  SipCallState call_state = SipCallState::Idle;

  std::shared_ptr<std::atomic<bool>> alive{new std::atomic<bool>(true)};
  std::atomic<int> gen{0};             // stop/再start で ++ — 旧世代の post を無効化
  std::atomic<bool> stopping{false};   // pjsua_destroy 中のコールバック post を抑止

  // 直近通話の RTP 送受パケット数 (通話中は都度取得、破棄時に確定値を保存)
  mutable std::mutex stat_mu;
  int64_t last_tx = 0, last_rx = 0;

  Impl(Runloop& l, Callbacks c) : loop(l), cbs(std::move(c)) {}

  // ---------- pjsua コールバック → Runloop への marshal ----------
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
      if (s == SipCallState::Ended) {  // Ended は過渡状態 — 続けて Idle へ
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

  // ---------- 起動/停止 (loop 上) ----------
  void startOnLoop(const SipSettings& s);
  void stopOnLoop();

  // ---------- pjsua コールバック (pjsua worker スレッド) ----------
  static void s_on_reg_state2(pjsua_acc_id acc_id, pjsua_reg_info* info);
  static void s_on_call_state(pjsua_call_id call_id, pjsip_event* e);
  static void s_on_incoming_call(pjsua_acc_id acc_id, pjsua_call_id call_id, pjsip_rx_data* rdata);
  static void s_on_dtmf_digit2(pjsua_call_id call_id, const pjsua_dtmf_info* info);
  static void s_on_stream_destroyed(pjsua_call_id call_id, pjmedia_stream* strm, unsigned idx);
};

// プロセス内単一 pjsua の持ち主 (start 中の Impl)
static std::atomic<SipCtl::Impl*> g_impl{nullptr};

// ---------------- pjsua コールバック ----------------

void SipCtl::Impl::s_on_reg_state2(pjsua_acc_id, pjsua_reg_info* info) {
  Impl* im = g_impl.load();
  if (!im || !info || !info->cbparam) return;
  const pjsip_regc_cbparam* p = info->cbparam;
  std::string reason = "code=" + std::to_string(p->code);
  if (p->status != PJ_SUCCESS) {
    im->postReg(SipRegState::Failed, "status=" + std::to_string(p->status));
  } else if (p->code / 100 == 2) {
    if (info->renew && p->expiration > 0)
      im->postReg(SipRegState::Registered, reason);
    else
      im->postReg(SipRegState::Idle, reason);  // 登録解除完了
  } else if (p->code >= 300) {
    // 401 は pjsua が資格情報で自動再試行する — ここへ来るのは最終失敗のみ。
    // reg_retry_interval により pjsua が再試行を続ける間、状態は Failed のまま。
    im->postReg(SipRegState::Failed, reason);
  }
  // 1xx は無視
}

void SipCtl::Impl::s_on_call_state(pjsua_call_id call_id, pjsip_event*) {
  Impl* im = g_impl.load();
  if (!im) return;
  pjsua_call_info ci;
  if (pjsua_call_get_info(call_id, &ci) != PJ_SUCCESS) return;
  std::string remote(ci.remote_info.ptr, static_cast<size_t>(ci.remote_info.slen));
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
      if (im->call_id.load() == call_id) im->call_id.store(PJSUA_INVALID_ID);
      im->postCall(SipCallState::Ended, remote);
      break;
    default:
      break;
  }
}

void SipCtl::Impl::s_on_incoming_call(pjsua_acc_id, pjsua_call_id call_id, pjsip_rx_data*) {
  Impl* im = g_impl.load();
  if (!im) return;
  int expected = PJSUA_INVALID_ID;
  if (!im->call_id.compare_exchange_strong(expected, call_id)) {
    pjsua_call_answer(call_id, PJSIP_SC_BUSY_HERE, nullptr, nullptr);  // 通話中 → 486
    return;
  }
  // 逆呼び (モニタ): auto_answer なら 200 応答。st は start/stop 間で不変。
  if (im->st.auto_answer) {
    pjsua_call_answer(call_id, PJSIP_SC_OK, nullptr, nullptr);
  } else {
    pjsua_call_answer(call_id, PJSIP_SC_RINGING, nullptr, nullptr);
  }
}

void SipCtl::Impl::s_on_dtmf_digit2(pjsua_call_id, const pjsua_dtmf_info* info) {
  Impl* im = g_impl.load();
  if (!im || !info) return;
  if (info->method != PJSUA_DTMF_METHOD_RFC2833) return;  // RFC2833 のみ (SIP INFO は無視)
  im->postDtmf(static_cast<char>(info->digit));
}

void SipCtl::Impl::s_on_stream_destroyed(pjsua_call_id, pjmedia_stream* strm, unsigned idx) {
  // 通話終了直前の確定統計 (DISCONNECTED 後は取得できないためここで保存)
  Impl* im = g_impl.load();
  if (!im || idx != 0) return;
  pjmedia_rtcp_stat st;
  if (pjmedia_stream_get_stat(strm, &st) == PJ_SUCCESS) {
    std::lock_guard<std::mutex> lk(im->stat_mu);
    im->last_tx = st.tx.pkt;
    im->last_rx = st.rx.pkt;
  }
}

// ---------------- 起動/停止 ----------------

void SipCtl::Impl::startOnLoop(const SipSettings& s) {
  if (running) stopOnLoop();
  st = s;
  if (st.server.empty()) return;  // SIP 無効運用も正常系

  Impl* expected = nullptr;
  if (!g_impl.compare_exchange_strong(expected, this)) {
    DB_LOGE(kTag, "pjsua は既に他の SipCtl が使用中 (プロセス内単一) — start 拒否");
    return;
  }

  pj_status_t rc = pjsua_create();
  if (rc != PJ_SUCCESS) {
    DB_LOGE(kTag, "pjsua_create 失敗: " + std::to_string(rc));
    g_impl.store(nullptr);
    return;
  }

  pjsua_config cfg;
  pjsua_config_default(&cfg);
  cfg.cb.on_reg_state2 = &Impl::s_on_reg_state2;
  cfg.cb.on_call_state = &Impl::s_on_call_state;
  cfg.cb.on_incoming_call = &Impl::s_on_incoming_call;
  cfg.cb.on_dtmf_digit2 = &Impl::s_on_dtmf_digit2;
  cfg.cb.on_stream_destroyed = &Impl::s_on_stream_destroyed;

  pjsua_logging_config log_cfg;
  pjsua_logging_config_default(&log_cfg);
  log_cfg.console_level = 1;  // エラーのみ (通常ログは DB_LOG 側)
  log_cfg.level = 2;

  pjsua_media_config med;
  pjsua_media_config_default(&med);
  med.clock_rate = 8000;   // PCMU のみ — 全経路 8kHz でリサンプル回避
  med.no_vad = PJ_TRUE;    // 無音でも RTP を流し続ける (rtp_symmetric の返送起動に必要)
  if (!st.null_audio && st.ec_tail_ms > 0) {
    med.ec_options = PJMEDIA_ECHO_WEBRTC;  // 実機: WebRTC AEC
    med.ec_tail_len = static_cast<unsigned>(st.ec_tail_ms);
  } else {
    med.ec_tail_len = 0;  // null 音声はエコー無し
  }

  rc = pjsua_init(&cfg, &log_cfg, &med);
  if (rc != PJ_SUCCESS) {
    DB_LOGE(kTag, "pjsua_init 失敗: " + std::to_string(rc));
    pjsua_destroy();
    g_impl.store(nullptr);
    return;
  }

  // SIP トランスポート (port 0 = 空きポート — 同一ホストの他プロセスと衝突しない)
  pjsua_transport_config tcfg;
  pjsua_transport_config_default(&tcfg);
  tcfg.port = 0;
  pjsip_transport_type_e tt =
      st.transport == "tcp" ? PJSIP_TRANSPORT_TCP : PJSIP_TRANSPORT_UDP;
  rc = pjsua_transport_create(tt, &tcfg, nullptr);
  if (rc != PJ_SUCCESS) {
    DB_LOGE(kTag, "pjsua_transport_create 失敗: " + std::to_string(rc));
    pjsua_destroy();
    g_impl.store(nullptr);
    return;
  }

  pjsua_start();
  if (st.null_audio) pjsua_set_null_snd_dev();  // テストモード: 音声デバイス不要で RTP は流れる

  // codec: PCMU 優先、他は無効
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

  // アカウント (REGISTER 維持 + 自動再試行)
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
  acfg.rtp_cfg.port_range = 99;  // 4000-4099 (FW 開放と一致)

  rc = pjsua_acc_add(&acfg, PJ_TRUE, &acc);
  if (rc != PJ_SUCCESS) {
    DB_LOGE(kTag, "pjsua_acc_add 失敗: " + std::to_string(rc));
    pjsua_destroy();
    g_impl.store(nullptr);
    return;
  }

  running = true;
  reg_state = SipRegState::Registering;
  call_state = SipCallState::Idle;
  DB_LOGI(kTag, "SIP 開始: " + st.user + "@" + host + " (" + st.transport + ")");
  if (cbs.on_reg_state) cbs.on_reg_state(SipRegState::Registering, "");
}

void SipCtl::Impl::stopOnLoop() {
  if (!running) return;
  gen.fetch_add(1);       // 旧世代の post を無効化
  stopping.store(true);   // destroy 中のコールバック post を抑止
  ensurePjThread();
  DB_LOGI(kTag, "SIP 停止 (通話切断 → 登録解除 → pjsua_destroy)");
  pjsua_call_hangup_all();
  if (acc != PJSUA_INVALID_ID) pjsua_acc_set_registration(acc, PJ_FALSE);  // 失敗は無視
  pjsua_destroy();  // 未了の切断/解除も内部で完了させる
  g_impl.store(nullptr);
  stopping.store(false);
  acc = PJSUA_INVALID_ID;
  call_id.store(PJSUA_INVALID_ID);
  running = false;
  reg_state = SipRegState::Idle;
  call_state = SipCallState::Idle;
}

// ---------------- 公開 API (Runloop 上から呼ばれる) ----------------

SipCtl::SipCtl(Runloop& loop, Callbacks cbs) : impl_(new Impl(loop, std::move(cbs))) {}

SipCtl::~SipCtl() {
  // loop 稼働中なら loop 上で停止 (先に queue 済みの post を流し切ってから破棄)
  impl_->loop.callSync([this] { impl_->stopOnLoop(); });
  impl_->alive->store(false);
}

void SipCtl::start(const SipSettings& settings) { impl_->startOnLoop(settings); }

void SipCtl::stop() { impl_->stopOnLoop(); }

void SipCtl::updateSettings(const SipSettings& settings) {
  if (sameSettings(impl_->st, settings)) return;
  DB_LOGI(kTag, "SIP 設定変更 → 再起動/再登録");
  impl_->startOnLoop(settings);  // 内部で stop → start
}

void SipCtl::call(const std::string& extension) {
  Impl* im = impl_.get();
  if (!im->running || im->acc == PJSUA_INVALID_ID) {
    DB_LOGW(kTag, "call(" + extension + "): SIP 未開始 — 無視");
    return;
  }
  if (im->call_id.load() != PJSUA_INVALID_ID) {
    DB_LOGW(kTag, "call(" + extension + "): 通話進行中 — 無視");
    return;
  }
  ensurePjThread();
  std::string host = im->st.server +
                     (im->st.port != 5060 ? ":" + std::to_string(im->st.port) : "");
  std::string tp = im->st.transport == "tcp" ? ";transport=tcp" : "";
  std::string uri = "sip:" + extension + "@" + host + tp;
  pj_str_t dst = pstr(uri);
  pjsua_call_id cid = PJSUA_INVALID_ID;
  pj_status_t rc = pjsua_call_make_call(im->acc, &dst, nullptr, nullptr, nullptr, &cid);
  if (rc != PJ_SUCCESS) {
    DB_LOGE(kTag, "発呼失敗 " + uri + ": " + std::to_string(rc));
    return;
  }
  im->call_id.store(cid);
  DB_LOGI(kTag, "発呼 " + uri);
}

void SipCtl::hangup() {
  Impl* im = impl_.get();
  if (!im->running) return;
  ensurePjThread();
  pjsua_call_hangup_all();
}

void SipCtl::answer() {
  Impl* im = impl_.get();
  int cid = im->call_id.load();
  if (!im->running || cid == PJSUA_INVALID_ID) return;
  ensurePjThread();
  pjsua_call_answer(cid, PJSIP_SC_OK, nullptr, nullptr);
}

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
