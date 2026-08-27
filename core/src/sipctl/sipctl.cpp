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

#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <mutex>
#include <set>
#include <vector>

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
         a.null_audio == b.null_audio && a.direct_port == b.direct_port;
}

// 受理する着信モニタ呼の上限 (PJSUA_MAX_CALLS=4 の内訳: 主呼 1 + モニタ 2 + 予備 1)
constexpr int kMaxMonitorCalls = 2;

// 着信 INVITE の X-Doorbell-Mode ヘッダ値 ("monitor" | "answer" | "")。
// pjsua スレッドから呼ばれる (rdata はコールバック中のみ有効)。
std::string doorbellMode(pjsip_rx_data* rdata) {
  if (!rdata || !rdata->msg_info.msg) return "";
  pj_str_t hname = pj_str(const_cast<char*>("X-Doorbell-Mode"));
  auto* h = static_cast<pjsip_generic_string_hdr*>(
      pjsip_msg_find_hdr_by_name(rdata->msg_info.msg, &hname, nullptr));
  if (!h) return "";
  return std::string(h->hvalue.ptr, static_cast<size_t>(h->hvalue.slen));
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
  std::atomic<int> call_id{PJSUA_INVALID_ID};  // 進行中の主呼 (pjsua スレッドからも書く)
  SipRegState reg_state = SipRegState::Idle;   // loop 上でのみ触る
  SipCallState call_state = SipCallState::Idle;

  // 受理中のモニタ呼 (pjsua スレッドで増減、loop からも参照 — mon_mu 保護)。
  // モニタ呼 = マイク (conf slot 0) → 相手 の一方向のみ接続する「聞くだけ」の呼。
  // 主呼の状態機 (call_state / on_call_state) には一切影響させない。
  std::mutex mon_mu;
  std::vector<pjsua_call_id> monitors;
  std::atomic<int> mon_count{0};

  // 直接 INVITE の許可送信元 IP (空 = 全許可)。loop から set、pjsua スレッドから参照。
  std::mutex src_mu;
  std::set<std::string> allowed_sources;

  bool addMonitor(pjsua_call_id cid) {
    std::lock_guard<std::mutex> lk(mon_mu);
    if (static_cast<int>(monitors.size()) >= kMaxMonitorCalls) return false;
    monitors.push_back(cid);
    mon_count.store(static_cast<int>(monitors.size()));
    return true;
  }
  bool isMonitor(pjsua_call_id cid) {
    std::lock_guard<std::mutex> lk(mon_mu);
    return std::find(monitors.begin(), monitors.end(), cid) != monitors.end();
  }
  bool removeMonitor(pjsua_call_id cid) {
    std::lock_guard<std::mutex> lk(mon_mu);
    auto it = std::find(monitors.begin(), monitors.end(), cid);
    if (it == monitors.end()) return false;
    monitors.erase(it);
    mon_count.store(static_cast<int>(monitors.size()));
    return true;
  }
  void clearMonitors() {
    std::lock_guard<std::mutex> lk(mon_mu);
    monitors.clear();
    mon_count.store(0);
  }

  // 直接 INVITE の送信元検査 (pjsua スレッド)。allowed_sources 非空なら
  // server 自身 (Asterisk 経由) とリスト内 IP 以外を拒否する。
  bool sourceAllowed(pjsip_rx_data* rdata) {
    std::lock_guard<std::mutex> lk(src_mu);
    if (allowed_sources.empty()) return true;  // 未設定 = 全許可 (従来挙動)
    if (!rdata) return false;
    const std::string src = rdata->pkt_info.src_name;
    if (!st.server.empty() && src == st.server) return true;  // Asterisk 経由
    return allowed_sources.count(src) > 0;
  }

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
  static void s_on_call_media_state(pjsua_call_id call_id);
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
  // モニタ呼・拒否済み呼は主呼の状態機 (postCall) を乱さない — 増減はログのみ
  if (im->call_id.load() != call_id) {
    if (ci.state == PJSIP_INV_STATE_DISCONNECTED && im->removeMonitor(call_id)) {
      DB_LOGI(kTag, "モニタ呼 #" + std::to_string(call_id) + " 終了 (" + remote +
                        ", 残 " + std::to_string(im->mon_count.load()) + " 本)");
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
  // 直接 INVITE の送信元検査 (allowlist 設定時のみ)
  if (!im->sourceAllowed(rdata)) {
    DB_LOGW(kTag, std::string("着信拒否 403 (許可外の送信元 ") +
                      (rdata ? rdata->pkt_info.src_name : "?") + ")");
    pjsua_call_answer(call_id, PJSIP_SC_FORBIDDEN, nullptr, nullptr);
    return;
  }
  // 一方向モニタか双方向かの判別:
  //   X-Doorbell-Mode: monitor → モニタ / answer → 双方向 / ヘッダ無し →
  //   主呼進行中ならモニタ・アイドルなら従来の双方向自動応答 (逆呼び)。
  // (Alert-Info 等の標準ヘッダによる判別は将来拡張 — 現状は自前ヘッダ + フォールバック)
  const std::string mode = doorbellMode(rdata);
  const bool busy = im->call_id.load() != PJSUA_INVALID_ID;
  const bool want_monitor = (mode == "monitor") || (mode.empty() && busy);

  if (want_monitor) {
    // モニタ呼: auto_answer 有効時のみ、上限 kMaxMonitorCalls 本まで追加受理
    if (!im->st.auto_answer || !im->addMonitor(call_id)) {
      pjsua_call_answer(call_id, PJSIP_SC_BUSY_HERE, nullptr, nullptr);  // 486
      return;
    }
    pjsua_call_info ci;
    std::string remote;
    if (pjsua_call_get_info(call_id, &ci) == PJ_SUCCESS)
      remote.assign(ci.remote_info.ptr, static_cast<size_t>(ci.remote_info.slen));
    DB_LOGI(kTag, "モニタ呼受理 #" + std::to_string(call_id) + " (" + remote + ", 計 " +
                      std::to_string(im->mon_count.load()) + " 本, mode=" +
                      (mode.empty() ? "fallback" : mode) + ")");
    pjsua_call_answer(call_id, PJSIP_SC_OK, nullptr, nullptr);
    return;
  }

  // 双方向 (主呼として受理)。主呼進行中に mode=answer が来た場合は 486 (将来: 会議化)。
  int expected = PJSUA_INVALID_ID;
  if (!im->call_id.compare_exchange_strong(expected, call_id)) {
    pjsua_call_answer(call_id, PJSIP_SC_BUSY_HERE, nullptr, nullptr);  // 通話中 → 486
    return;
  }
  // 逆呼び (双方向): auto_answer なら 200 応答。st は start/stop 間で不変。
  if (im->st.auto_answer) {
    pjsua_call_answer(call_id, PJSIP_SC_OK, nullptr, nullptr);
  } else {
    pjsua_call_answer(call_id, PJSIP_SC_RINGING, nullptr, nullptr);
  }
}

// 音声メディア確立 → conference bridge へ配線 (pjsua は自動接続しない)。
//   主呼: マイク (slot 0) ⇔ 呼 の双方向。
//   モニタ呼: マイク (slot 0) → 呼 の一方向のみ (相手の音声はこちらへ流さない — TV は聞くだけ)。
void SipCtl::Impl::s_on_call_media_state(pjsua_call_id call_id) {
  Impl* im = g_impl.load();
  if (!im) return;
  pjsua_call_info ci;
  if (pjsua_call_get_info(call_id, &ci) != PJ_SUCCESS) return;
  if (ci.media_status != PJSUA_CALL_MEDIA_ACTIVE) return;
  const pjsua_conf_port_id slot = ci.conf_slot;
  if (slot == PJSUA_INVALID_ID) return;
  if (im->call_id.load() == call_id) {
    pjsua_conf_connect(slot, 0);  // 相手 → スピーカ
    pjsua_conf_connect(0, slot);  // マイク → 相手
    DB_LOGI(kTag, "主呼 #" + std::to_string(call_id) + ": 音声双方向接続 (conf slot " +
                      std::to_string(slot) + " <-> 0)");
  } else if (im->isMonitor(call_id)) {
    pjsua_conf_connect(0, slot);  // マイク → モニタ (一方向)
    DB_LOGI(kTag, "モニタ呼 #" + std::to_string(call_id) +
                      ": マイク→モニタ 一方向接続 (conf 0 -> slot " + std::to_string(slot) + ")");
  }
}

void SipCtl::Impl::s_on_dtmf_digit2(pjsua_call_id, const pjsua_dtmf_info* info) {
  Impl* im = g_impl.load();
  if (!im || !info) return;
  if (info->method != PJSUA_DTMF_METHOD_RFC2833) return;  // RFC2833 のみ (SIP INFO は無視)
  im->postDtmf(static_cast<char>(info->digit));
}

void SipCtl::Impl::s_on_stream_destroyed(pjsua_call_id call_id, pjmedia_stream* strm,
                                         unsigned idx) {
  // 通話終了直前の確定統計 (DISCONNECTED 後は取得できないためここで保存)。
  // rtpStats は主呼基準 — モニタ呼の統計では上書きしない。
  Impl* im = g_impl.load();
  if (!im || idx != 0 || im->call_id.load() != call_id) return;
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
  // 登録モード = server と user が揃っている時のみ (user 無しで REGISTER は組めない —
  // 例: fleet 設定に sip.server だけあり自機の sip.accounts が無い TV/新設端末)。
  // それ以外でも direct_port が有効なら transport だけ立てる (直接呼の待受 — 自愈方針)。
  // どちらも無効なら何もしない (SIP 無効運用も正常系)。
  const bool registered_mode = !st.server.empty() && !st.user.empty();
  if (!registered_mode && st.direct_port <= 0) return;

  Impl* expected = nullptr;
  if (!g_impl.compare_exchange_strong(expected, this)) {
    // プロセス内複数 Node (テスト) では 2 台目以降がここへ来る — SIP 無しで続行
    DB_LOGW(kTag, "pjsua は既に他の SipCtl が使用中 (プロセス内単一) — この Node は SIP 無効");
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
  cfg.cb.on_call_media_state = &Impl::s_on_call_media_state;
  cfg.cb.on_dtmf_digit2 = &Impl::s_on_dtmf_digit2;
  cfg.cb.on_stream_destroyed = &Impl::s_on_stream_destroyed;

  pjsua_logging_config log_cfg;
  pjsua_logging_config_default(&log_cfg);
  // 既定はエラーのみ (通常ログは DB_LOG 側)。DB_SIP_LOG=1 で pjsua 詳細ログ (診断用)
  const bool verbose = std::getenv("DB_SIP_LOG") != nullptr;
  log_cfg.console_level = verbose ? 4 : 1;
  log_cfg.level = verbose ? 4 : 2;

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

  // SIP トランスポート: direct_port で固定 listen (直接呼の宛先)。使用中 (同一ホストの
  // 他プロセス等) なら空きポートへフォールバック — 登録運用は継続、直接着信のみ不可。
  pjsua_transport_config tcfg;
  pjsua_transport_config_default(&tcfg);
  tcfg.port = st.direct_port > 0 ? static_cast<unsigned>(st.direct_port) : 0;
  pjsip_transport_type_e tt =
      st.transport == "tcp" ? PJSIP_TRANSPORT_TCP : PJSIP_TRANSPORT_UDP;
  pjsua_transport_id tid = -1;
  rc = pjsua_transport_create(tt, &tcfg, &tid);
  if (rc != PJ_SUCCESS && tcfg.port != 0) {
    DB_LOGW(kTag, "SIP 固定ポート " + std::to_string(st.direct_port) +
                      " が使用中 — 空きポートへフォールバック (直接着信は不可)");
    tcfg.port = 0;
    rc = pjsua_transport_create(tt, &tcfg, &tid);
  }
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

  if (!registered_mode) {
    // 直接呼専用モード: 登録なし。着信の受け皿 + 発信元としてローカルアカウントを作る
    // (アカウント 0 件だと pjsua は着信を処理できない)。
    rc = pjsua_acc_add_local(tid, PJ_TRUE, &acc);
    if (rc != PJ_SUCCESS) {
      DB_LOGE(kTag, "pjsua_acc_add_local 失敗: " + std::to_string(rc));
      pjsua_destroy();
      g_impl.store(nullptr);
      return;
    }
    // RTP 固定レンジはアカウント設定 — ローカルアカウントにも適用する
    // (acc_get_config は pool へ複製する API — 一時 pool を使う)
    if (pj_pool_t* pool = pjsua_pool_create("db_lacc", 512, 512)) {
      pjsua_acc_config lcfg;
      pjsua_acc_config_default(&lcfg);
      if (pjsua_acc_get_config(acc, pool, &lcfg) == PJ_SUCCESS) {
        lcfg.rtp_cfg.port = static_cast<unsigned>(st.rtp_port_start);
        lcfg.rtp_cfg.port_range = 99;  // 4000-4099 (FW 開放と一致)
        pjsua_acc_modify(acc, &lcfg);
      }
      pj_pool_release(pool);
    }
    running = true;
    reg_state = SipRegState::Idle;
    call_state = SipCallState::Idle;
    DB_LOGI(kTag, "SIP 開始 (直接呼のみ, 登録なし, " + st.transport + " port " +
                      std::to_string(tcfg.port == 0 ? 0 : st.direct_port) + ")");
    return;
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
  // Contact の NAT 書換を無効化: 同一 LAN 前提 (docs/network-ports.md)。Asterisk 側は
  // rewrite_contact=yes が面倒を見る。有効のままだと NAT 検出時に Contact が書き換わり、
  // このアカウントで応答した「直接呼」(Asterisk 非経由) の in-dialog 要求 (BYE 等) が
  // 書換後の別アドレスへ飛んで届かなくなる (dev の Docker ブリッジで実測)。
  acfg.allow_contact_rewrite = PJ_FALSE;
  acfg.allow_via_rewrite = PJ_FALSE;

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
  clearMonitors();
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

void SipCtl::call(const std::string& target, const std::string& mode) {
  Impl* im = impl_.get();
  if (!im->running || im->acc == PJSUA_INVALID_ID) {
    DB_LOGW(kTag, "call(" + target + "): SIP 未開始 — 無視");
    return;
  }
  if (im->call_id.load() != PJSUA_INVALID_ID) {
    DB_LOGW(kTag, "call(" + target + "): 通話進行中 — 無視");
    return;
  }
  ensurePjThread();
  // "sip:" で始まる完全 URI はそのまま直呼 (Asterisk 非経由)。それ以外は従来の内線
  // (server 経由 — server 未設定なら不可)。
  std::string uri;
  if (target.compare(0, 4, "sip:") == 0) {
    uri = target;
  } else if (!im->st.server.empty()) {
    std::string host = im->st.server +
                       (im->st.port != 5060 ? ":" + std::to_string(im->st.port) : "");
    std::string tp = im->st.transport == "tcp" ? ";transport=tcp" : "";
    uri = "sip:" + target + "@" + host + tp;
  } else {
    DB_LOGW(kTag, "call(" + target + "): server 未設定で内線発呼は不可 — 無視");
    return;
  }
  // mode 指定時は X-Doorbell-Mode ヘッダで意図を明示 (受け側の一方向/双方向判別)。
  // pjsua_msg_data はスタックで良い — make_call 内で複製される。
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
    DB_LOGE(kTag, "発呼失敗 " + uri + ": " + std::to_string(rc));
    return;
  }
  im->call_id.store(cid);
  DB_LOGI(kTag, "発呼 " + uri + (mode.empty() ? "" : " (mode=" + mode + ")"));
}

void SipCtl::setAllowedSources(const std::vector<std::string>& ips) {
  Impl* im = impl_.get();
  std::lock_guard<std::mutex> lk(im->src_mu);
  im->allowed_sources.clear();
  im->allowed_sources.insert(ips.begin(), ips.end());
}

int SipCtl::monitorCount() const { return impl_->mon_count.load(); }

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
