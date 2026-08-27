#include "node/node.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <set>

#include "bridge/ha_bridge.h"
#include "bridge/telegram.h"
#include "httpd/webui_assets.h"
#include "media/frame_bus.h"
#include "media/motion_detector.h"
#include "mesh/tcp_transport.h"
#include "mesh/udp_beacon.h"
#include "monocypher.h"
#include "sipctl/sipctl.h"
#ifdef _WIN32
#include "media/camera_win.h"
#endif
#include "util/common.h"
#include "util/ids.h"
#include "util/json.h"
#include "util/log.h"

namespace db {

namespace {
constexpr const char* kTag = "node";

std::string hashPassword(const std::string& pw, const std::string& salt_hex) {
  Bytes salt;
  hexDecode(salt_hex, salt);
  Bytes buf = salt;
  buf.insert(buf.end(), pw.begin(), pw.end());
  uint8_t out[32];
  crypto_blake2b(out, sizeof(out), buf.data(), buf.size());
  return hexEncode(out, sizeof(out));
}

bool pskIsZero(const std::array<uint8_t, 32>& psk) {
  for (uint8_t b : psk)
    if (b) return false;
  return true;
}

// "host:port" → host
std::string hostOf(const std::string& addr) {
  auto p = addr.rfind(':');
  return p == std::string::npos ? addr : addr.substr(0, p);
}

// "HH:MM" → 通算分。不正な書式は -1 (rule_engine と同じ規則)。
int parseHhmm(const std::string& s) {
  int h = 0, m = 0;
  char tail = 0;
  if (std::sscanf(s.c_str(), "%d:%d%c", &h, &m, &tail) != 2) return -1;
  if (h < 0 || h > 24 || m < 0 || m > 59) return -1;
  return h * 60 + m;
}

// 負値でも床方向へ丸める除算 (rule_engine と同じ — 現地時刻の分計算用)
int64_t floorDiv(int64_t a, int64_t b) {
  int64_t q = a / b;
  if ((a % b) != 0 && ((a < 0) != (b < 0))) --q;
  return q;
}
}  // namespace

struct Node::Impl {
  NodeOptions opts;

  std::unique_ptr<RealClock> owned_clock;
  IClock* clock = nullptr;
  std::unique_ptr<Runloop> owned_loop;
  Runloop* loop = nullptr;
  bool external_loop = false;

  Store store;
  std::unique_ptr<HlcClock> hlc;
  std::unique_ptr<LwwMap> config;
  std::unique_ptr<EventLog> events;
  RuleEngine rules;
  std::unique_ptr<ITransport> transport;
  std::unique_ptr<IDiscovery> discovery;
  std::unique_ptr<Mesh> mesh;
  std::unique_ptr<Httpd> httpd;
  std::unique_ptr<SipCtl> sipctl;
  std::unique_ptr<HaBridge> bridge;  // HA MQTT ブリッジ (leader 時のみ接続)
  std::unique_ptr<TelegramBridge> tg;  // Telegram ブリッジ (leader 時のみ送信)
  FrameBus frame_bus;  // 帧総線 (任意スレッドから push / 需要駆動 JPEG)
  // 動体検知 (feed は採集スレッド — 設定変更と競合するため motion_mu_ で保護)
  MotionDetector motion;
  std::mutex motion_mu;
  // パネル状態 (loop 上でのみ触る): door → 呼出表示窓の期限 (mono ms)、最新クイック返信
  std::map<std::string, int64_t> door_calling_until;
  std::string last_reply_text;
  int64_t last_reply_ts = 0;
#ifdef _WIN32
  std::unique_ptr<CameraWin> camera;  // door_station のみ起動
#endif

  json::Doc cfg;  // materialize 済み設定 (loop 上でのみ触る)
  std::string node_id;
  uint64_t epoch = 1;
  bool started = false;

  // press の追跡 (クイック返信の宛先解決・回執)
  std::string last_press_door;
  std::map<std::string, std::pair<std::string, uint64_t>> last_press_by_door;

  // SIP 状態 (loop 上でのみ触る)
  SipRegState sip_reg = SipRegState::Idle;
  SipCallState sip_call = SipCallState::Idle;
  std::string dtmf_buf;          // 通話中の DTMF 機能碼バッファ
  uint64_t dtmf_timer = 0;       // 3 秒無入力クリア
  uint64_t sip_reapply_timer = 0;  // 設定変更のデバウンス (連続する sip.* 差分で再起動を繰り返さない)
  uint64_t bridge_reapply_timer = 0;  // 同・HA ブリッジ用 (config 差分は複数キーで届く)

  // Telegram leader の就任遷移検出 (就任時に未通知 press を拾い直す)
  bool tg_was_active = false;

  // 表示制御 (loop 上でのみ触る): 直近に通知した display JSON + 30 秒周期の再評価タイマー
  std::string last_display_json;
  uint64_t display_timer = 0;

  // SOS 緊急モード (loop 上でのみ触る): 現在状態 = emergency / emergency_cancel の hlc 最大側
  bool emergency_active = false;
  std::string emergency_hlc;

  // コールバック (任意スレッドから差し替え可)
  std::mutex cb_mu;
  UiEventCb ui_cb;
  TtsCb tts_cb;
  HttpsFn https_fn;

  // 生存トークン: HttpsFn done (任意スレッド) が Impl 破棄後の loop へ触れないための弱参照
  std::shared_ptr<char> alive = std::make_shared<char>(0);

  // 管理セッション (civetweb スレッドの auth gate とも共有)
  std::mutex sess_mu;
  std::set<std::string> sessions;

  // ---------- helpers ----------
  void uiNotify(const std::string& event_json) {
    UiEventCb cb;
    {
      std::lock_guard<std::mutex> lk(cb_mu);
      cb = ui_cb;
    }
    if (cb) cb(event_json);
  }

  void tts(const std::string& text, const std::string& lang) {
    TtsCb cb;
    {
      std::lock_guard<std::mutex> lk(cb_mu);
      cb = tts_cb;
    }
    if (cb) cb(text, lang);
  }

  int tzOffsetMin() {
    const cJSON* integ = json::get(cfg.get(), "integrations");
    return static_cast<int>(json::getInt(integ, "tz_offset_min", 540));  // 既定 JST
  }

  void rebuildCfg() {
    cfg = json::parse(config->materializeJson());
    if (!cfg) cfg = json::obj();
    rules.setConfig(json::dump(cfg.get()));
  }

  // 設定ツリーからドットパスで取得 (borrowed)
  cJSON* cfgAt(const std::string& dotpath) {
    cJSON* cur = cfg.get();
    size_t pos = 0;
    while (cur && pos <= dotpath.size()) {
      size_t dot = dotpath.find('.', pos);
      std::string part = dotpath.substr(pos, dot == std::string::npos ? std::string::npos : dot - pos);
      cur = json::get(cur, part.c_str());
      if (dot == std::string::npos) return cur;
      pos = dot + 1;
    }
    return cur;
  }

  // devices.<self>.local.camera の実効値 (無ければ既定 8/60/640x480)
  struct CamCfg {
    int fps = 8;
    int quality = 60;
    int w = 640, h = 480;
    std::string hint;
  };
  CamCfg cameraCfg() {
    CamCfg c;
    cJSON* cam = cfgAt("devices." + node_id + ".local.camera");
    if (cam) {
      c.fps = static_cast<int>(json::getInt(cam, "mjpeg_fps", 8));
      c.quality = static_cast<int>(json::getInt(cam, "mjpeg_quality", 60));
      c.hint = json::getString(cam, "device_hint");
      std::string res = json::getString(cam, "resolution", "640x480");
      size_t x = res.find('x');
      if (x != std::string::npos) {
        int w = std::atoi(res.c_str());
        int h = std::atoi(res.c_str() + x + 1);
        if (w > 0 && h > 0) {
          c.w = w;
          c.h = h;
        }
      }
    }
    if (c.fps <= 0) c.fps = 8;
    return c;
  }

  // fps/quality/解像度を FrameBus + httpd へ反映 (起動時と config_changed 時)
  void applyCameraSettings() {
    CamCfg c = cameraCfg();
    frame_bus.setJpegParams(c.quality, c.w);
    if (httpd)
      httpd->setJpegProvider([this] { return frame_bus.latestJpeg(); }, c.fps);
  }

  // 動体検知設定 (devices.<self>.local.motion) を反映 (起動時と config_changed 時)
  void applyMotionSettings() {
    cJSON* m = cfgAt("devices." + node_id + ".local.motion");
    MotionConfig mc;
    mc.enabled = json::getBool(m, "enabled", true);
    mc.sensitivity = static_cast<int>(json::getInt(m, "sensitivity", 40));
    mc.min_interval_s = static_cast<int>(json::getInt(m, "min_interval_s", 30));
    std::lock_guard<std::mutex> lk(motion_mu);
    motion.setConfig(mc);
  }

  // ---------- 表示制御 (display) ----------
  // 実効値 = config display.* を基底に devices.<self>.local.display.* で上書き
  // (スカラーはキー単位、night はオブジェクト単位で上書き)。night の窓判定は
  // rule_engine と同じ規則 (補正済み壁時計 + tz_offset_min、from <= t < to、日跨ぎ対応)。
  struct DisplayState {
    int brightness = 70;
    bool night = false;
    bool red_tint = false;
    int screensaver_after_s = 120;
    int pixel_shift_s = 300;
  };

  DisplayState displayState() {
    cJSON* base = json::get(cfg.get(), "display");
    cJSON* ovr = cfgAt("devices." + node_id + ".local.display");
    auto num = [&](const char* key, int64_t def) {
      if (ovr && json::get(ovr, key)) return json::getInt(ovr, key, def);
      return json::getInt(base, key, def);
    };
    DisplayState d;
    d.brightness = static_cast<int>(num("brightness", 70));
    d.screensaver_after_s = static_cast<int>(num("screensaver_after_s", 120));
    d.pixel_shift_s = static_cast<int>(num("pixel_shift_s", 300));
    cJSON* night = ovr ? json::get(ovr, "night") : nullptr;
    if (!night) night = json::get(base, "night");
    if (night && json::getBool(night, "enabled", true)) {
      const int from = parseHhmm(json::getString(night, "from", "22:00"));
      const int to = parseHhmm(json::getString(night, "to", "06:00"));
      if (from >= 0 && to >= 0 && from != to) {
        const int64_t local =
            hlc->correctedWallMs() + static_cast<int64_t>(tzOffsetMin()) * 60'000LL;
        const int64_t day = floorDiv(local, 86'400'000LL);
        const int minute = static_cast<int>((local - day * 86'400'000LL) / 60'000LL);
        d.night = (from < to) ? (from <= minute && minute < to)
                              : (minute >= from || minute < to);  // 日跨ぎ窓
      }
      if (d.night) {
        d.brightness = static_cast<int>(json::getInt(night, "brightness", 15));
        d.red_tint = json::getBool(night, "red_tint", true);
      }
    }
    return d;
  }

  // display オブジェクトの中身 (uiNotify と status_json で共用)
  json::Doc displayDoc(const DisplayState& d) {
    auto o = json::obj();
    json::set(o.get(), "brightness", static_cast<int64_t>(d.brightness));
    json::setBool(o.get(), "night", d.night);
    json::setBool(o.get(), "red_tint", d.red_tint);
    json::set(o.get(), "screensaver_after_s", static_cast<int64_t>(d.screensaver_after_s));
    json::set(o.get(), "pixel_shift_s", static_cast<int64_t>(d.pixel_shift_s));
    return o;
  }

  // 30 秒周期 + config_changed + 起動直後に評価し、変化時だけ uiNotify する
  void evalDisplay(bool force = false) {
    auto o = displayDoc(displayState());
    json::set(o.get(), "t", "display");
    std::string j = json::dump(o.get());
    if (!force && j == last_display_json) return;
    last_display_json = j;
    uiNotify(j);
  }

  // ---------- SOS 緊急モード ----------
  // 現在状態 = emergency / emergency_cancel の hlc 最大側 (HLC 文字列は辞書順比較可)。
  // quiet_hours・trigger_rules に依存しない組込動作 — Telegram/MQTT へは常に流れる。
  void emergencyNotifyUi() {
    auto o = json::obj();
    json::set(o.get(), "t", "emergency");
    json::setBool(o.get(), "active", emergency_active);
    uiNotify(json::dump(o.get()));
  }

  // 起動時: Store から状態を復元する (Telegram へは送らない — 遷移ではない)。
  // 復元した hlc は observe する — 再起動で壁時計が巻き戻っていても、以後の
  // ローカル発報/解除が必ず復元済み状態より新しい HLC を刻めるようにする。
  void restoreEmergency() {
    auto ev = store.latestEventOfTypes("emergency", "emergency_cancel");
    if (!ev) return;
    hlc->observe(ev->hlc);
    emergency_hlc = ev->hlc;
    emergency_active = (ev->type == "emergency");
  }

  // emergency / emergency_cancel イベント受理毎 (ローカル発・複製受信の両方)。
  // 変化時: 全ノードで uiNotify、leader なら Telegram 🚨/✅ (bridge 側の active 判定に任せる)。
  void applyEmergencyEvent(const EventRecord& ev) {
    if (ev.hlc <= emergency_hlc) return;  // 古い/巻き戻しイベントは無視
    emergency_hlc = ev.hlc;
    const bool now = (ev.type == "emergency");
    if (now == emergency_active) return;
    emergency_active = now;
    emergencyNotifyUi();
    if (tg) {
      auto p = json::parse(ev.payload_json.empty() ? "{}" : ev.payload_json);
      std::string source = p ? json::getString(p.get(), "source") : "";
      if (source.empty()) source = ev.device;
      tg->sendEmergency(now, source, ev.wall_ms);
    }
  }

  void doEmergency(bool active, const std::string& via) {
    auto p = json::obj();
    json::set(p.get(), "source", node_id);
    json::set(p.get(), "via", via);
    events->append(active ? "emergency" : "emergency_cancel", "", node_id, json::dump(p.get()));
  }

  // ---------- SIP ----------
  // 設定源: config の sip.server/port/transport + sip.accounts.<node_id>.{user,pass}。
  // アカウント未設定時は boot 上書き (NodeOptions.sip_user/sip_pass) を使う。
  // MVP は平文 pass — TODO(Phase2): secure_store (pass_ref) 経由に切り替え。
  SipSettings sipSettings() {
    SipSettings s;
    cJSON* sip = json::get(cfg.get(), "sip");
    s.server = json::getString(sip, "server");
    s.port = static_cast<int>(json::getInt(sip, "port", 5060));
    s.transport = json::getString(sip, "transport", "udp");
    cJSON* acct = cfgAt("sip.accounts." + node_id);
    s.user = json::getString(acct, "user");
    s.password = json::getString(acct, "pass");
    if (s.user.empty()) s.user = opts.sip_user;
    if (s.password.empty()) s.password = opts.sip_pass;
    s.display_name = opts.name;
    s.null_audio = opts.sip_null_audio;
    // AEC 遅延は装機標定 (devices.<self>.local.aec.tail_ms) があれば上書き
    cJSON* aec = cfgAt("devices." + node_id + ".local.aec");
    int tail = aec ? static_cast<int>(json::getInt(aec, "tail_ms", 0)) : 0;
    if (tail > 0) s.ec_tail_ms = tail;
    return s;
  }

  // sip.* の差分は複数キーで届く — 300ms デバウンスしてから updateSettings (再登録)
  void scheduleSipReapply() {
    if (!sipctl) return;
    if (sip_reapply_timer) loop->cancel(sip_reapply_timer);
    sip_reapply_timer = loop->postDelayed(300, [this] {
      sip_reapply_timer = 0;
      if (sipctl) sipctl->updateSettings(sipSettings());
    });
  }

  // ---------- HA MQTT ブリッジ ----------
  // 有効条件 = config integrations.mqtt.host 非空 かつ 自分が mqtt_bridge leader。
  // リーダー交代 (on_leader_changed) と設定変更 (デバウンス) で再評価する。
  void reevalBridge() {
    if (!bridge) return;
    const std::string host = json::getString(cfgAt("integrations.mqtt"), "host");
    const bool active = !host.empty() && mesh && mesh->isLeader("mqtt_bridge");
    bridge->configure(json::dump(cfg.get()), node_id, active);
  }

  void scheduleBridgeReapply() {
    if (!bridge && !tg) return;
    if (bridge_reapply_timer) loop->cancel(bridge_reapply_timer);
    bridge_reapply_timer = loop->postDelayed(300, [this] {
      bridge_reapply_timer = 0;
      reevalBridge();
      reevalTelegram();
    });
  }

  // ---------- Telegram ブリッジ ----------
  // 有効条件 = config integrations.telegram.bot_token 非空 かつ 自分が telegram leader。
  // MVP は平文 bot_token — TODO(Phase2 後半): bot_token_ref (secure store) 対応。
  void reevalTelegram() {
    if (!tg) return;
    const std::string token =
        json::getString(cfgAt("integrations.telegram"), "bot_token");
    const bool active = !token.empty() && mesh && mesh->isLeader("telegram");
    tg->configure(json::dump(cfg.get()), node_id, active);
    // 就任遷移で未通知 press を拾い直す (設計 §1.5「宁重勿漏」: 前 leader が claim だけ
    // 残して死んだ press をここで回収する。notified_at 済みは bridge 側で弾かれる)
    if (active && !tg_was_active) rescanPendingTelegram();
    tg_was_active = active;
  }

  void rescanPendingTelegram() {
    const int64_t cutoff = hlc->correctedWallMs() - 15 * 60 * 1000;  // 直近 15 分のみ
    for (const auto& ev : store.recentEvents(50)) {
      if (ev.type != "press" || ev.wall_ms < cutoff) continue;
      auto n = json::parse(ev.notify_json.empty() ? "{}" : ev.notify_json);
      if (n && !json::getString(n.get(), "notified_at").empty()) continue;  // 通知済み
      if (n && json::get(n.get(), "replied")) continue;                     // 応対済み
      for (const auto& a : rules.evaluate(ev, hlc->correctedWallMs(), tzOffsetMin())) {
        if (a.type == "telegram") tg->onAction(ev, a.params_json);
      }
    }
  }

  // ---------- HTTPS (Telegram ブリッジ用) ----------
  // HttpsFn (done は任意スレッド) を Runloop 上の done に変換する。未注入なら即失敗。
  void httpsCall(const std::string& method, const std::string& url, const std::string& headers,
                 const Bytes& body, std::function<void(int, std::string)> done) {
    HttpsFn fn;
    {
      std::lock_guard<std::mutex> lk(cb_mu);
      fn = https_fn;
    }
    if (!fn) {
      loop->post([done] { done(-1, ""); });
      return;
    }
    std::weak_ptr<char> w = alive;
    Runloop* lp = loop;
    fn(method, url, headers, body, [w, lp, done](int status, std::string resp) {
      // 任意スレッド → Runloop へ。Node 破棄後の応答は捨てる
      // (capi は destroy 前に在飛の SPI 呼び出しの完了を待つ — doorbell_capi.cpp)。
      if (w.expired()) return;
      lp->post([w, done, status, resp] {
        if (!w.expired()) done(status, resp);
      });
    });
  }

  void onSipReg(SipRegState st, const std::string& reason) {
    sip_reg = st;
    auto o = json::obj();
    json::set(o.get(), "t", "sip");
    json::setBool(o.get(), "registered", st == SipRegState::Registered);
    json::set(o.get(), "state", sipRegName(st));
    if (!reason.empty()) json::set(o.get(), "reason", reason);
    uiNotify(json::dump(o.get()));
  }

  void onSipCall(SipCallState st, const std::string& remote) {
    sip_call = st;
    // UI 状態機: calling / in_call / idle (Ended は過渡 — 通知しない)
    const char* s = nullptr;
    switch (st) {
      case SipCallState::Calling: s = "calling"; break;
      case SipCallState::InCall: s = "in_call"; break;
      case SipCallState::Idle: s = "idle"; break;
      case SipCallState::Ended: break;
    }
    if (st == SipCallState::Idle) {
      dtmf_buf.clear();
      if (dtmf_timer) {
        loop->cancel(dtmf_timer);
        dtmf_timer = 0;
      }
    }
    if (!s) return;
    auto o = json::obj();
    json::set(o.get(), "t", "state");
    json::set(o.get(), "state", s);
    if (!remote.empty()) json::set(o.get(), "remote", remote);
    uiNotify(json::dump(o.get()));
  }

  // DTMF 機能碼: 受信 digit をバッファし sip.dtmf_actions のキー (例 "*1") と照合。
  // 3 秒無入力でクリア。
  void onSipDtmf(char digit) {
    if (dtmf_timer) loop->cancel(dtmf_timer);
    dtmf_timer = loop->postDelayed(3000, [this] {
      dtmf_timer = 0;
      dtmf_buf.clear();
    });
    dtmf_buf.push_back(digit);
    cJSON* acts = cfgAt("sip.dtmf_actions");
    if (!acts) return;
    cJSON* hit = json::get(acts, dtmf_buf.c_str());
    if (hit) {
      execDtmfAction(dtmf_buf, hit);
      dtmf_buf.clear();
      return;
    }
    // どのキーの接頭辞でもない → 打ち直し扱い (今回の digit から再開)
    bool prefix = false;
    cJSON* it = nullptr;
    cJSON_ArrayForEach(it, acts) {
      if (it->string && std::strncmp(it->string, dtmf_buf.c_str(), dtmf_buf.size()) == 0)
        prefix = true;
    }
    if (!prefix) {
      dtmf_buf.assign(1, digit);
      cJSON_ArrayForEach(it, acts) {
        if (it->string && std::strncmp(it->string, dtmf_buf.c_str(), 1) == 0) return;
      }
      dtmf_buf.clear();
    }
  }

  void execDtmfAction(const std::string& code, cJSON* action) {
    std::string type = json::getString(action, "type");
    DB_LOGI(kTag, "dtmf 機能碼 " + code + " -> " + type);
    if (type == "hangup") {
      if (sipctl) sipctl->hangup();
    } else if (type == "ha_command") {
      // Phase 2 で MQTT bridge へ配線 — 今はイベント記録のみ
      auto p = json::parse(json::dump(action));
      json::set(p.get(), "code", code);
      DB_LOGI(kTag, "ha_command (Phase 2 で MQTT へ): " + json::dump(p.get()));
      std::string door = opts.door.empty() ? last_press_door : opts.door;
      events->append("dtmf_action", door, node_id, json::dump(p.get()));
    } else {
      DB_LOGW(kTag, "未知の dtmf アクション: " + type);
    }
  }

  static const char* sipRegName(SipRegState s) {
    switch (s) {
      case SipRegState::Idle: return "idle";
      case SipRegState::Registering: return "registering";
      case SipRegState::Registered: return "registered";
      case SipRegState::Failed: return "failed";
    }
    return "?";
  }
  static const char* sipCallName(SipCallState s) {
    switch (s) {
      case SipCallState::Idle: return "idle";
      case SipCallState::Calling: return "calling";
      case SipCallState::InCall: return "in_call";
      case SipCallState::Ended: return "ended";
    }
    return "?";
  }

  std::string labelIn(const cJSON* label_obj, const std::string& lang) {
    if (!label_obj) return "";
    std::string v = json::getString(label_obj, lang.c_str());
    if (v.empty()) v = json::getString(label_obj, "ja");
    if (v.empty() && cJSON_IsString(label_obj->child)) v = label_obj->child->valuestring;
    return v;
  }

  // ---------- 起動 ----------
  bool init() {
    // Store
    std::string db_path = opts.data_dir;
    if (db_path != ":memory:") {
      makeDir(opts.data_dir);  // 既存でもよい
      db_path = opts.data_dir + "/doorbell.db";
    }
    if (!store.open(db_path)) {
      DB_LOGE(kTag, "store open failed: " + db_path);
      return false;
    }
    // 身元
    auto id = store.metaGet("node_id");
    if (!id) {
      node_id = genNodeId();
      store.metaSet("node_id", node_id);
    } else {
      node_id = *id;
    }
    auto ep = store.metaGet("epoch");
    epoch = ep ? std::stoull(*ep) + 1 : 1;
    store.metaSet("epoch", std::to_string(epoch));

    hlc.reset(new HlcClock(*clock, node_id.substr(0, 8)));
    config.reset(new LwwMap(node_id, *hlc));
    config->load(store.configLoadAll());
    events.reset(new EventLog(node_id, *hlc, store));
    events->loadHeads();

    config->onChange([this](const LwwEntry& e, bool is_local) {
      store.configPut(e);
      rebuildCfg();
      if (is_local && mesh) mesh->pushConfigDelta({e});
      // 自機のカメラ設定 (fps/quality/解像度) の変更は即反映
      if (e.key.compare(0, 8, "devices.") == 0 && e.key.find(node_id) != std::string::npos) {
        if (httpd) applyCameraSettings();
        applyMotionSettings();
      }
      // SIP 設定 (sip.* / 自機の aec) の変更 → デバウンス後に再登録
      if (e.key.compare(0, 4, "sip.") == 0 ||
          (e.key.compare(0, 8, "devices.") == 0 && e.key.find(node_id) != std::string::npos))
        scheduleSipReapply();
      // HA ブリッジは設定全文 (mqtt 接続先/doors/devices/…) に依存 — デバウンスして再評価
      scheduleBridgeReapply();
      // 表示制御 (display.* / devices.<self>.local.display.*) — 変化時だけ uiNotify される
      if (started) evalDisplay();
      uiNotify("{\"t\":\"config_changed\"}");
    });
    events->onEvent([this](const EventRecord& ev, bool is_local) { onEvent(ev, is_local); });

    // トランスポート
    if (!transport) transport.reset(new TcpTransport(*loop));
    if (!discovery && !pskIsZero(opts.psk))
      discovery.reset(new UdpBeacon(*loop, opts.psk));

    // Mesh
    MeshSettings ms = opts.use_mesh_timing_template ? opts.mesh_timing_template : MeshSettings{};
    ms.node_id = node_id;
    ms.epoch = epoch;
    ms.listen_addr = opts.listen_addr;
    ms.advertise_addr = opts.advertise_addr.empty() ? opts.listen_addr : opts.advertise_addr;
    ms.seed_peers = opts.seed_peers;
    ms.psk = opts.psk;
    ms.role = opts.role;
    ms.sw_version = opts.sw_version;
    ms.caps_json = opts.caps_json;
    Mesh::Callbacks cbs;
    cbs.on_peers_changed = [this] { uiNotify("{\"t\":\"peers_changed\"}"); };
    cbs.on_leader_changed = [this](const std::string& duty, const std::string& leader) {
      // leader 交代は即座に反映 (自分が就任 → 開始 / 退任 → 停止)
      if (duty == "mqtt_bridge") reevalBridge();
      if (duty == "telegram") reevalTelegram();
      auto o = json::obj();
      json::set(o.get(), "t", "leader");
      json::set(o.get(), "duty", duty);
      json::set(o.get(), "id", leader);
      uiNotify(json::dump(o.get()));
    };
    cbs.on_peer_alive_changed = [this](const std::string& id, bool alive) {
      onPeerAlive(id, alive);
    };
    cbs.on_command = [this](const std::string& from, const std::string& cmd) {
      onCommand(from, cmd);
    };
    mesh.reset(new Mesh(*loop, *clock, *hlc, *transport, discovery.get(), store, *config,
                        *events, ms, cbs));
    // 他ノードからの快照要求 (SNAP_REQ — Telegram 写真用) には最新 JPEG で応える
    mesh->setSnapshotProvider([this] { return frame_bus.latestJpeg(); });

    rebuildCfg();

    // HA MQTT ブリッジ (接続するのは leader 就任後 — reevalBridge が判断)
    {
      HaBridge::Hooks hooks;
      hooks.on_reply = [this](const std::string& rid, const std::string& text,
                              const std::string& door) { quickReply(rid, text, door, "mqtt"); };
      hooks.node_alive = [this] {
        std::vector<std::pair<std::string, bool>> v;
        if (mesh)
          for (const auto& p : mesh->peers()) v.push_back({p.id, p.status != "dead"});
        return v;
      };
      hooks.emergency_active = [this] { return emergency_active; };
      bridge.reset(new HaBridge(*loop, std::move(hooks)));
    }

    // Telegram ブリッジ (送信するのは telegram leader だけ — reevalTelegram が判断)
    {
      TelegramBridge::Hooks th;
      th.https = [this](const std::string& m, const std::string& u, const std::string& h,
                        Bytes body, std::function<void(int, std::string)> done) {
        httpsCall(m, u, h, body, std::move(done));
      };
      th.on_reply = [this](const std::string& rid, const std::string& text,
                           const std::string& door) { quickReply(rid, text, door, "telegram"); };
      th.get_event = [this](const std::string& o, uint64_t s) { return store.eventGet(o, s); };
      th.merge_notify = [this](const std::string& o, uint64_t s, const std::string& nj) {
        if (!events->mergeNotify(o, s, nj)) return;
        // 回執は SYNC 差分に乗らない (既知イベントは deltaSince が送らない) —
        // EVENT 再広播で全ノードへ複製する (受信側は mergeNotify で取り込む)
        auto ev = store.eventGet(o, s);
        if (ev && mesh) mesh->broadcastEvent(*ev);
      };
      th.hlc_tick = [this] { return hlc->tick(); };
      th.fetch_snapshot = [this](const std::string& nid, std::function<void(Bytes)> cb) {
        if (mesh) {
          mesh->fetchSnapshot(nid, std::move(cb));
        } else {
          loop->post([cb] { cb(Bytes()); });
        }
      };
      tg.reset(new TelegramBridge(*loop, store, std::move(th)));
    }

    seedConfig();
    mesh->start();
    reevalBridge();  // 単機構成で既に leader の場合に備えて一度評価
    reevalTelegram();

    // SIP (sipctl)。server 未設定なら start は no-op — 設定が届いたら再適用される。
    {
      SipCtl::Callbacks scb;
      scb.on_reg_state = [this](SipRegState st, const std::string& reason) {
        onSipReg(st, reason);
      };
      scb.on_call_state = [this](SipCallState st, const std::string& remote) {
        onSipCall(st, remote);
      };
      scb.on_dtmf = [this](char d) { onSipDtmf(d); };
      sipctl.reset(new SipCtl(*loop, std::move(scb)));
      sipctl->start(sipSettings());
    }

    if (opts.http_port > 0) {
      httpd.reset(new Httpd(*loop));
      registerHttp();
      if (!httpd->start(opts.http_port)) {
        DB_LOGE(kTag, "httpd start failed on port " + std::to_string(opts.http_port));
        return false;
      }
      applyCameraSettings();  // /snapshot.jpg・/stream.mjpeg の JPEG 提供者を配線
    }
    // 動体検知: 発火 (採集スレッド) → loop へ → motion イベント (door 担当の門口機のみ)
    motion.onMotion([this](int64_t /*ts_ms*/, double changed_pct) {
      loop->post([this, changed_pct] {
        if (!started || opts.role != "door_station" || opts.door.empty()) return;
        auto p = json::obj();
        json::set(p.get(), "changed_pct", changed_pct);
        events->append("motion", opts.door, node_id, json::dump(p.get()));
      });
    });
    applyMotionSettings();
#ifdef _WIN32
    // Windows の門口機はカメラ採集 (Media Foundation) を起動。失敗はログのみ。
    if (opts.role == "door_station") {
      CamCfg c = cameraCfg();
      camera.reset(new CameraWin([this](RawFrame&& f) {
        {
          std::lock_guard<std::mutex> lk(motion_mu);
          motion.feed(f);
        }
        frame_bus.push(std::move(f));
      }));
      camera->start(c.hint, c.w, c.h);
    }
#endif
    // 表示制御: 30 秒周期の再評価 + 起動直後の 1 回発行 (壳が初期状態を受け取れる)
    display_timer = loop->postEvery(30'000, [this] { evalDisplay(); });
    // SOS: 状態を Store から復元し、初期状態も 1 回発行する (再起動後のイベント再生に相当)
    restoreEmergency();

    started = true;
    evalDisplay(/*force=*/true);
    emergencyNotifyUi();
    DB_LOGI(kTag, "node " + node_id.substr(0, 8) + " (" + opts.name + ") started");
    return true;
  }

  // 既定設定 (初回のみ) + 自機の devices エントリ登録
  void seedConfig() {
    if (opts.seed_default_config && !config->get("schema_version")) {
      config->set("schema_version", "1");
      config->set("reply.display_ttl_s", "30");
      config->set("integrations.tz_offset_min", "540");
      auto qr = [&](const char* id, const char* ja, const char* en, const char* zh, int order) {
        auto o = json::obj();
        cJSON* label = json::addObj(o.get(), "label");
        json::set(label, "ja", ja);
        json::set(label, "en", en);
        json::set(label, "zh", zh);
        json::setBool(o.get(), "speak", true);
        json::set(o.get(), "order", static_cast<int64_t>(order));
        config->set(std::string("quick_replies.") + id, json::dump(o.get()));
      };
      qr("qr_away", "ただいま留守にしています", "We are away right now", "现在不在家", 1);
      qr("qr_no", "結構です", "Not interested", "不需要，谢谢", 2);
      qr("qr_wrong", "お間違いのようです", "Wrong address", "您可能找错地方了", 3);
      qr("qr_wait", "少々お待ちください", "One moment please", "请稍等", 4);
      // パネルアクセストークン (webui/panel/API.md — 管理画面から差替可)
      config->set("panel.tokens", "[\"" + genTokenHex(16) + "\"]");
    }
    // 自機のエントリ (差分がある時だけ書く — 起動毎の無駄な gossip を避ける)
    auto dev = json::obj();
    json::set(dev.get(), "name", opts.name);
    json::set(dev.get(), "role", opts.role);
    if (!opts.door.empty()) json::set(dev.get(), "door", opts.door);
    std::string key = "devices." + node_id;
    std::string want = json::dump(dev.get());
    auto cur = config->get(key);
    if (!cur || *cur != want) config->set(key, want);
  }

  // ---------- イベント配送 ----------
  void onEvent(const EventRecord& ev, bool is_local) {
    if (is_local && mesh) mesh->broadcastEvent(ev);
    if (ev.type == "press") {
      last_press_door = ev.door;
      last_press_by_door[ev.door] = {ev.origin, ev.seq};
      // パネル表示用の呼出窓 (30 秒 or 返信で解除)
      if (!ev.door.empty()) door_calling_until[ev.door] = clock->monoMs() + 30'000;
    } else if (ev.type == "reply") {
      auto p = json::parse(ev.payload_json);
      if (p) {
        last_reply_text = json::getString(p.get(), "text");
        last_reply_ts = hlc->correctedWallMs();
      }
      if (!ev.door.empty()) door_calling_until.erase(ev.door);
    } else if (ev.type == "emergency" || ev.type == "emergency_cancel") {
      // 全ノードで状態再計算 (複製で自然に届く)。変化時 uiNotify + Telegram は中で行う。
      applyEmergencyEvent(ev);
    }
    {
      auto o = json::obj();
      json::set(o.get(), "t", "event");
      json::set(o.get(), "type", ev.type);
      json::set(o.get(), "door", ev.door);
      json::set(o.get(), "device", ev.device);
      uiNotify(json::dump(o.get()));
    }
    auto actions = rules.evaluate(ev, hlc->correctedWallMs(), tzOffsetMin());
    for (const auto& a : actions) {
      auto p = json::parse(a.params_json.empty() ? "{}" : a.params_json);
      if (a.type == "chime") {
        // devices 配列に自分が含まれる (または "all") 時だけ自分が鳴る
        bool mine = false;
        cJSON* devs = json::get(p.get(), "devices");
        if (!devs) {
          mine = (opts.role == "indoor_panel");  // 省略時: 室内パネル全部
        } else if (cJSON_IsString(devs)) {
          mine = std::string(devs->valuestring) == "all";
        } else if (cJSON_IsArray(devs)) {
          cJSON* it = nullptr;
          cJSON_ArrayForEach(it, devs) {
            if (cJSON_IsString(it) && node_id == it->valuestring) mine = true;
          }
        }
        if (mine) {
          auto o = json::obj();
          json::set(o.get(), "t", "chime");
          json::set(o.get(), "sound", json::getString(p.get(), "sound", "ding1"));
          json::set(o.get(), "door", ev.door);
          uiNotify(json::dump(o.get()));
        }
      } else if (a.type == "sip_call") {
        // 発呼するのは押された門口機本人だけ
        if (is_local && ev.origin == node_id && ev.type == "press") {
          std::string ext = json::getString(p.get(), "target_extension", "600");
          if (sipctl && sipctl->regState() == SipRegState::Registered) {
            DB_LOGI(kTag, "sip_call -> " + ext);
            sipctl->call(ext);  // calling/in_call の uiNotify は on_call_state 経由
          } else {
            // SIP 未登録 → 降級 (chime/telegram/ha_event はルール経由で従来どおり発火)
            DB_LOGW(kTag, "sip_call -> " + ext + " スキップ (SIP 未登録) — 降級");
            auto o = json::obj();
            json::set(o.get(), "t", "state");
            json::set(o.get(), "state", "degraded");
            json::set(o.get(), "target", ext);
            uiNotify(json::dump(o.get()));
          }
        }
      } else if (a.type == "telegram") {
        // leader だけが外部へ送る (claim による重複防止は bridge 側 — telegram.cpp §1.5)
        if (tg && mesh && mesh->isLeader("telegram")) tg->onAction(ev, a.params_json);
      } else if (a.type == "ha_event") {
        // MQTT への発行はルールと独立に下の bridge->onEvent で行う (leader gate も同様)
      }
    }
    // HA MQTT ブリッジへ (リーダー時のみ — press/motion/offline/online/dtmf_action を発行)
    if (bridge && mesh && mesh->isLeader("mqtt_bridge")) bridge->onEvent(ev);
    // Telegram ブリッジへ (press の追跡は非 leader でも必要。reply の「✅」通知と
    // 送信可否は bridge 内の active 判定に任せる)
    if (tg) tg->onEvent(ev);
  }

  // 生死変化 → offline/online イベント。重複防止: alive 集合の中で node_id 最大の者だけが記録
  void onPeerAlive(const std::string& id, bool alive) {
    auto peers = mesh->peers();
    std::string max_alive;
    for (const auto& p : peers)
      if (p.status == "alive" && p.id > max_alive) max_alive = p.id;
    if (max_alive != node_id) return;
    events->append(alive ? "online" : "offline", "", id, "{}");
  }

  void onCommand(const std::string& from, const std::string& cmd_json) {
    auto c = json::parse(cmd_json);
    if (!c) return;
    std::string cmd = json::getString(c.get(), "cmd");
    if (cmd == "chime") {
      auto o = json::obj();
      json::set(o.get(), "t", "chime");
      json::set(o.get(), "sound", json::getString(c.get(), "sound", "ding1"));
      uiNotify(json::dump(o.get()));
    } else if (cmd == "show_reply") {
      std::string text = json::getString(c.get(), "text");
      auto o = json::obj();
      json::set(o.get(), "t", "reply");
      json::set(o.get(), "text", text);
      json::set(o.get(), "ttl_s", json::getInt(c.get(), "ttl_s", 30));
      uiNotify(json::dump(o.get()));
      if (json::getBool(c.get(), "speak", true))
        tts(text, json::getString(c.get(), "lang", "ja"));
    } else {
      DB_LOGW(kTag, "unknown command from " + from.substr(0, 8) + ": " + cmd);
    }
  }

  // ---------- クイック返信 ----------
  void quickReply(const std::string& reply_id, const std::string& free_text,
                  const std::string& door_arg, const std::string& via) {
    std::string door = door_arg.empty() ? last_press_door : door_arg;
    std::string text = free_text;
    bool speak = true;
    if (text.empty() && !reply_id.empty()) {
      cJSON* q = cfgAt("quick_replies." + reply_id);
      if (q) {
        text = labelIn(json::get(q, "label"), "ja");
        speak = json::getBool(q, "speak", true);
      }
    }
    if (text.empty()) {
      DB_LOGW(kTag, "quickReply: 本文なし (reply_id=" + reply_id + ")");
      return;
    }
    int64_t ttl = 30;
    if (cJSON* r = cfgAt("reply.display_ttl_s")) ttl = static_cast<int64_t>(cJSON_IsNumber(r) ? r->valuedouble : 30);

    // 宛先: 該当 door の door_station (door 不明なら全 door_station)
    auto c = json::obj();
    json::set(c.get(), "cmd", "show_reply");
    json::set(c.get(), "text", text);
    json::setBool(c.get(), "speak", speak);
    json::set(c.get(), "ttl_s", ttl);
    json::set(c.get(), "lang", "ja");
    std::string cmd = json::dump(c.get());

    cJSON* devices = json::get(cfg.get(), "devices");
    int sent = 0;
    cJSON* it = nullptr;
    cJSON_ArrayForEach(it, devices) {
      if (json::getString(it, "role") != "door_station") continue;
      if (!door.empty() && json::getString(it, "door") != door) continue;
      std::string target = it->string ? it->string : "";
      if (target.empty()) continue;
      if (target == node_id) {
        onCommand(node_id, cmd);
      } else {
        mesh->sendCommand(target, cmd);
      }
      sent++;
    }
    if (sent == 0 && opts.role == "door_station") onCommand(node_id, cmd);  // 単機構成

    // reply イベント + 元 press への回執
    auto pl = json::obj();
    json::set(pl.get(), "reply_id", reply_id);
    json::set(pl.get(), "text", text);
    json::set(pl.get(), "via", via);
    events->append("reply", door, node_id, json::dump(pl.get()));
    auto lp = last_press_by_door.find(door);
    if (lp != last_press_by_door.end()) {
      auto n = json::obj();
      json::set(n.get(), "hlc", hlc->tick());
      cJSON* rep = json::addObj(n.get(), "replied");
      json::set(rep, "reply_id", reply_id);
      json::set(rep, "by", via);
      events->mergeNotify(lp->second.first, lp->second.second, json::dump(n.get()));
    }
  }

  // ---------- status ----------
  std::string statusJsonOnLoop() {
    auto o = json::obj();
    cJSON* self = json::addObj(o.get(), "node");
    json::set(self, "id", node_id);
    json::set(self, "name", opts.name);
    json::set(self, "role", opts.role);
    json::set(self, "door", opts.door);
    json::set(self, "version", opts.sw_version);
    cJSON* sip = json::addObj(o.get(), "sip");
    json::setBool(sip, "registered", sip_reg == SipRegState::Registered);
    json::set(sip, "state", sipRegName(sip_reg));
    json::set(sip, "call", sipCallName(sip_call));
    cJSON* leaders = json::addObj(o.get(), "leaders");
    if (mesh) {
      json::set(leaders, "telegram", mesh->leaderFor("telegram"));
      json::set(leaders, "mqtt_bridge", mesh->leaderFor("mqtt_bridge"));
    }
    cJSON* br = json::addObj(o.get(), "bridge");
    json::set(br, "mqtt", bridge ? bridge->mqttStatus() : "inactive");
    // telegram には常接続の概念が無い (毎回 HTTPS) — active | inactive の 2 値
    json::set(br, "telegram", tg ? tg->status() : "inactive");
    // 表示制御の実効値 (管理画面用) + SOS 現在状態
    json::setItem(o.get(), "display", displayDoc(displayState()));
    cJSON* em = json::addObj(o.get(), "emergency");
    json::setBool(em, "active", emergency_active);
    cJSON* arr = json::addArr(o.get(), "peers");
    if (mesh) {
      for (const auto& p : mesh->peers()) {
        cJSON* e = json::pushObj(arr);
        json::set(e, "id", p.id);
        json::set(e, "status", p.status);
        json::set(e, "role", p.role);
        json::set(e, "sw", p.sw_version);
        json::setBool(e, "self", p.id == node_id);
        cJSON* addrs = json::addArr(e, "addrs");
        for (const auto& a : p.addrs) json::push(addrs, json::Doc(cJSON_CreateString(a.c_str())));
        // 表示名・door・ライブ映像 URL は設定から補完
        cJSON* dev = cfgAt("devices." + p.id);
        if (dev) {
          json::set(e, "name", json::getString(dev, "name", p.id.substr(0, 8)));
          std::string door = json::getString(dev, "door");
          if (!door.empty()) {
            json::set(e, "door", door);
            cJSON* d = cfgAt("doors." + door);
            if (d) json::set(e, "door_label", labelIn(json::get(d, "label"), "ja"));
          }
          if (json::getString(dev, "role") == "door_station" && !p.addrs.empty()) {
            json::set(e, "stream", "http://" + hostOf(p.addrs[0]) + ":47180/stream.mjpeg");
          }
        }
      }
    }
    return json::dump(o.get());
  }

  // ---------- HTTP ----------
  bool checkSession(const HttpReq& req) {
    std::string tok = req.cookie("dbsess");
    if (tok.empty()) return false;
    std::lock_guard<std::mutex> lk(sess_mu);
    return sessions.count(tok) > 0;
  }

  void registerHttp() {
    size_t n = 0;
    const WebAsset* assets = webuiAssets(&n);
    for (size_t i = 0; i < n; i++)
      httpd->setStatic(assets[i].path, assets[i].content_type,
                       Bytes(assets[i].data, assets[i].data + assets[i].len));

    // "/" (リダイレクトのみ) は gate 側で例外扱い — prefix リストに "/" を入れると全公開になる
    // /api/panel/* と /snapshot-proxy はハンドラ内で panel token (?k=) を検証する
    httpd->setAuth([this](const HttpReq& r) { return r.uri == "/" || checkSession(r); },
                   {"/api/login", "/locale/", "/panel/", "/admin/", "/stream.mjpeg",
                    "/snapshot.jpg", "/api/panel/", "/snapshot-proxy"});

    httpd->route("GET", "/", [](const HttpReq&) {
      HttpResp r;
      r.status = 302;
      r.headers["Location"] = "/admin/";
      r.body = "";
      return r;
    });

    httpd->route("POST", "/api/login", [this](const HttpReq& req) {
      auto b = json::parse(req.body);
      std::string pw = b ? json::getString(b.get(), "password") : "";
      if (pw.empty()) return HttpResp::json("{\"ok\":false}", 401);
      auto salt = store.metaGet("admin_pw_salt");
      auto hash = store.metaGet("admin_pw_hash");
      if (!salt || !hash) {  // 初回ログインでパスワード設定
        std::string s = genTokenHex(16);
        store.metaSet("admin_pw_salt", s);
        store.metaSet("admin_pw_hash", hashPassword(pw, s));
        DB_LOGI(kTag, "管理パスワードを初期設定した");
      } else if (hashPassword(pw, *salt) != *hash) {
        return HttpResp::json("{\"ok\":false}", 401);
      }
      std::string tok = genTokenHex(16);
      {
        std::lock_guard<std::mutex> lk(sess_mu);
        sessions.insert(tok);
        if (sessions.size() > 64) sessions.erase(sessions.begin());
      }
      HttpResp r = HttpResp::json("{\"ok\":true}");
      r.headers["Set-Cookie"] = "dbsess=" + tok + "; Path=/; HttpOnly; SameSite=Strict";
      return r;
    });

    httpd->route("GET", "/api/status",
                 [this](const HttpReq&) { return HttpResp::json(statusJsonOnLoop()); });

    httpd->route("GET", "/api/events", [this](const HttpReq& req) {
      size_t limit = 50;
      try {
        std::string l = req.param("limit");
        if (!l.empty()) limit = std::stoul(l);
      } catch (...) {
      }
      auto o = json::obj();
      cJSON* arr = json::addArr(o.get(), "events");
      for (const auto& ev : store.recentEvents(limit)) {
        cJSON* e = json::pushObj(arr);
        json::set(e, "type", ev.type);
        json::set(e, "door", ev.door);
        json::set(e, "device", ev.device);
        json::set(e, "wall_ms", ev.wall_ms);
        json::set(e, "payload", ev.payload_json);
      }
      return HttpResp::json(json::dump(o.get()));
    });

    httpd->route("GET", "/api/config", [this](const HttpReq&) {
      return HttpResp::json(config->materializeJson());
    });

    httpd->route("POST", "/api/config", [this](const HttpReq& req) {
      auto b = json::parse(req.body);
      if (!b) return HttpResp::json("{\"ok\":false,\"err\":\"bad json\"}", 400);
      std::string key = json::getString(b.get(), "key");
      std::string value = json::getString(b.get(), "value");
      if (key.empty()) return HttpResp::json("{\"ok\":false,\"err\":\"no key\"}", 400);
      setKey(key, value);
      return HttpResp::json("{\"ok\":true}");
    });

    // 設定キー削除 (LwwMap tombstone — materialize からも消える)
    httpd->route("POST", "/api/config/delete", [this](const HttpReq& req) {
      auto b = json::parse(req.body);
      std::string key = b ? json::getString(b.get(), "key") : "";
      if (key.empty()) return HttpResp::json("{\"ok\":false,\"err\":\"no key\"}", 400);
      config->remove(key);
      return HttpResp::json("{\"ok\":true}");
    });

    // 設定インポート: {entries:[{key,value},...]} を順に setKey。value は任意の JSON 値
    // (エクスポートは既存 GET /api/config — フラット化は管理画面側の責務)。
    httpd->route("POST", "/api/config/import", [this](const HttpReq& req) {
      auto b = json::parse(req.body);
      cJSON* entries = b ? json::get(b.get(), "entries") : nullptr;
      if (!entries || !cJSON_IsArray(entries))
        return HttpResp::json("{\"ok\":false,\"err\":\"no entries\"}", 400);
      int64_t n = 0;
      cJSON* it = nullptr;
      cJSON_ArrayForEach(it, entries) {
        std::string key = json::getString(it, "key");
        cJSON* v = json::get(it, "value");
        if (key.empty() || !v) continue;
        setKey(key, json::dump(v));
        n++;
      }
      auto o = json::obj();
      json::setBool(o.get(), "ok", true);
      json::set(o.get(), "n", n);
      return HttpResp::json(json::dump(o.get()));
    });

    // デバイス追加用の配対トークン発行 (PIN 6 桁・10 分有効 — mesh §1.6)
    httpd->route("POST", "/api/join-token", [this](const HttpReq&) {
      if (!mesh) return HttpResp::json("{\"ok\":false,\"err\":\"no mesh\"}", 503);
      auto t = mesh->createJoinToken();
      auto o = json::obj();
      json::setBool(o.get(), "ok", true);
      json::set(o.get(), "pin", t.pin);
      json::set(o.get(), "expires_s", (t.expires_mono - clock->monoMs()) / 1000);
      return HttpResp::json(json::dump(o.get()));
    });

    // Telegram テスト送信。chat_id 省略 = 全 households へ。
    // 送れない理由 (leader でない / bot_token 未設定 / 宛先なし) は err コードで返す。
    httpd->route("POST", "/api/test/telegram", [this](const HttpReq& req) {
      auto b = json::parse(req.body);
      std::string chat = b ? json::getString(b.get(), "chat_id") : "";
      if (json::getString(cfgAt("integrations.telegram"), "bot_token").empty())
        return HttpResp::json("{\"ok\":false,\"err\":\"no_token\"}");
      if (!tg || !mesh || !mesh->isLeader("telegram"))
        return HttpResp::json("{\"ok\":false,\"err\":\"not_leader\"}");
      if (chat.empty()) {
        // 宛先の存在確認 (展開は bridge 側と同じ households.*.telegram_chat_ids)
        bool any = false;
        cJSON* hs = json::get(cfg.get(), "households");
        cJSON* h = nullptr;
        cJSON_ArrayForEach(h, hs) {
          cJSON* ids = json::get(h, "telegram_chat_ids");
          if (ids && cJSON_GetArraySize(ids) > 0) any = true;
        }
        if (!any) return HttpResp::json("{\"ok\":false,\"err\":\"no_chat\"}");
      }
      tg->sendTestMessage(chat);
      return HttpResp::json("{\"ok\":true}");
    });

    // パネル token のローテート (旧 token は即失効 — panel.tokens を新 1 件に差し替え)
    httpd->route("POST", "/api/panel-token/rotate", [this](const HttpReq&) {
      std::string tok = genTokenHex(16);
      config->set("panel.tokens", "[\"" + tok + "\"]");
      auto o = json::obj();
      json::setBool(o.get(), "ok", true);
      json::set(o.get(), "token", tok);
      return HttpResp::json(json::dump(o.get()));
    });

    httpd->route("POST", "/api/press", [this](const HttpReq& req) {
      auto b = json::parse(req.body);
      std::string door = b ? json::getString(b.get(), "door") : "";
      doPress(door);
      return HttpResp::json("{\"ok\":true}");
    });

    httpd->route("POST", "/api/reply", [this](const HttpReq& req) {
      auto b = json::parse(req.body);
      if (!b) return HttpResp::json("{\"ok\":false}", 400);
      quickReply(json::getString(b.get(), "reply_id"), json::getString(b.get(), "text"),
                 json::getString(b.get(), "door"), "web");
      return HttpResp::json("{\"ok\":true}");
    });

    // SOS 緊急モード (管理セッション)。{"active":true|false} — 発報も解除も可。
    httpd->route("POST", "/api/emergency", [this](const HttpReq& req) {
      auto b = json::parse(req.body);
      if (!b || !json::get(b.get(), "active"))
        return HttpResp::json("{\"ok\":false,\"err\":\"no active\"}", 400);
      doEmergency(json::getBool(b.get(), "active"), "admin");
      return HttpResp::json("{\"ok\":true}");
    });

    httpd->route("GET", "/api/logs", [](const HttpReq&) {
      auto o = json::obj();
      cJSON* arr = json::addArr(o.get(), "logs");
      for (const auto& l : recentLogs(200))
        json::push(arr, json::Doc(cJSON_CreateString(l.c_str())));
      return HttpResp::json(json::dump(o.get()));
    });

    // ---------- パネル API (webui/panel/API.md が契約; 認証は panel token ?k=) ----------
    httpd->route("GET", "/api/panel/state", [this](const HttpReq& req) {
      if (!panelTokenOk(req)) return HttpResp::json("{\"ok\":false,\"err\":\"bad token\"}", 403);
      auto o = json::obj();
      cJSON* doors = json::addArr(o.get(), "doors");
      int64_t now_mono = clock->monoMs();
      cJSON* dcfg = json::get(cfg.get(), "doors");
      cJSON* it = nullptr;
      cJSON_ArrayForEach(it, dcfg) {
        if (!it->string) continue;
        cJSON* e = json::pushObj(doors);
        json::set(e, "id", it->string);
        std::string label = labelIn(json::get(it, "label"), "ja");
        json::set(e, "label", label.empty() ? std::string(it->string) : label);
        auto c = door_calling_until.find(it->string);
        json::setBool(e, "calling", c != door_calling_until.end() && c->second > now_mono);
      }
      cJSON* evs = json::addArr(o.get(), "events");
      for (const auto& ev : store.recentEvents(10)) {
        cJSON* e = json::pushObj(evs);
        json::set(e, "type", ev.type);
        json::set(e, "door", ev.door);
        json::set(e, "device", ev.device);
        json::set(e, "wall_ms", ev.wall_ms);
      }
      if (last_reply_ts > 0) {
        cJSON* r = json::addObj(o.get(), "reply");
        json::set(r, "text", last_reply_text);
        json::set(r, "ts", last_reply_ts);
      } else {
        json::setItem(o.get(), "reply", json::Doc(cJSON_CreateNull()));
      }
      json::set(o.get(), "server_ts", hlc->correctedWallMs());
      return HttpResp::json(json::dump(o.get()));
    });

    httpd->route("POST", "/api/panel/press", [this](const HttpReq& req) {
      if (!panelTokenOk(req)) return HttpResp::json("{\"ok\":false,\"err\":\"bad token\"}", 403);
      std::string door = req.param("door");
      if (door.empty() || !cfgAt("doors." + door))
        return HttpResp::json("{\"ok\":false,\"err\":\"unknown door\"}", 400);
      doPress(door);
      return HttpResp::json("{\"ok\":true}");
    });

    // SOS 発報 (panel token)。トリガのみ — 解除は不可 (403; 解除は kiosk PIN 経由の
    // db_core_emergency か管理セッションの /api/emergency のみ)。
    httpd->route("POST", "/api/panel/emergency", [this](const HttpReq& req) {
      if (!panelTokenOk(req)) return HttpResp::json("{\"ok\":false,\"err\":\"bad token\"}", 403);
      const std::string act = req.param("active");
      if (act == "0" || act == "false")
        return HttpResp::json("{\"ok\":false,\"err\":\"cancel not allowed\"}", 403);
      doEmergency(true, "web");
      return HttpResp::json("{\"ok\":true}");
    });

    httpd->route("GET", "/snapshot-proxy", [this](const HttpReq& req) {
      if (!panelTokenOk(req)) return HttpResp::json("{\"ok\":false,\"err\":\"bad token\"}", 403);
      std::string door = req.param("door");
      // その door を担当する door_station を設定から探す
      std::string target;
      cJSON* devices = json::get(cfg.get(), "devices");
      cJSON* it = nullptr;
      cJSON_ArrayForEach(it, devices) {
        if (!it->string) continue;
        if (json::getString(it, "role") == "door_station" && json::getString(it, "door") == door) {
          target = it->string;
          break;
        }
      }
      if (target.empty()) return HttpResp::json("{\"ok\":false,\"err\":\"no station\"}", 404);
      if (target == node_id) {
        Bytes jpg = frame_bus.latestJpeg();
        if (jpg.empty()) return HttpResp::json("{\"ok\":false,\"err\":\"no frame\"}", 503);
        HttpResp r;
        r.content_type = "image/jpeg";
        r.body.assign(jpg.begin(), jpg.end());
        r.headers["Cache-Control"] = "no-store";
        return r;
      }
      // 他ノード担当: 子機の認証免除 /snapshot.jpg へ 302 (契約で許容された方式)
      if (mesh) {
        for (const auto& p : mesh->peers()) {
          if (p.id == target && !p.addrs.empty()) {
            HttpResp r;
            r.status = 302;
            r.headers["Location"] = "http://" + hostOf(p.addrs[0]) + ":47180/snapshot.jpg";
            r.headers["Cache-Control"] = "no-store";
            return r;
          }
        }
      }
      return HttpResp::json("{\"ok\":false,\"err\":\"station offline\"}", 503);
    });
  }

  // panel token (?k= / form k=) を config panel.tokens と照合
  bool panelTokenOk(const HttpReq& req) {
    std::string k = req.param("k");
    if (k.empty()) return false;
    cJSON* toks = cfgAt("panel.tokens");
    cJSON* it = nullptr;
    cJSON_ArrayForEach(it, toks) {
      if (cJSON_IsString(it) && k == it->valuestring) return true;
    }
    return false;
  }

  void setKey(const std::string& key, const std::string& value) {
    auto v = json::parse(value);
    if (v) {
      config->set(key, value);
    } else {  // 生文字列は JSON 文字列として包む
      auto s = json::Doc(cJSON_CreateString(value.c_str()));
      config->set(key, json::dump(s.get()));
    }
  }

  void doPress(const std::string& door_arg) {
    std::string door = door_arg.empty() ? opts.door : door_arg;
    events->append("press", door, node_id, "{}");
  }
};

// ---------------- 公開 API ----------------

Node::Node(NodeOptions opts, NodeDeps deps) : impl_(new Impl) {
  impl_->opts = std::move(opts);
  if (deps.clock) {
    impl_->clock = deps.clock;
  } else {
    impl_->owned_clock.reset(new RealClock);
    impl_->clock = impl_->owned_clock.get();
  }
  if (deps.loop) {
    impl_->loop = deps.loop;
    impl_->external_loop = true;
  } else {
    impl_->owned_loop.reset(new Runloop(*impl_->clock));
    impl_->loop = impl_->owned_loop.get();
  }
  impl_->transport = std::move(deps.transport);
  impl_->discovery = std::move(deps.discovery);
}

Node::~Node() { stop(); }

bool Node::start() {
  if (impl_->started) return true;
  if (!impl_->external_loop) impl_->loop->start();
  bool ok = false;
  impl_->loop->callSync([&] { ok = impl_->init(); });
  if (ok) node_id_ = impl_->node_id;
  return ok;
}

void Node::stop() {
  if (!impl_ || !impl_->started) return;
  impl_->started = false;
#ifdef _WIN32
  // カメラ採集スレッドを先に止める (frame_bus への push を止めてから httpd を畳む)
  if (impl_->camera) impl_->camera->stop();
#endif
  // 停止順: sipctl → httpd → mesh
  impl_->loop->callSync([&] {
    if (impl_->sip_reapply_timer) {
      impl_->loop->cancel(impl_->sip_reapply_timer);
      impl_->sip_reapply_timer = 0;
    }
    if (impl_->dtmf_timer) {
      impl_->loop->cancel(impl_->dtmf_timer);
      impl_->dtmf_timer = 0;
    }
    if (impl_->bridge_reapply_timer) {
      impl_->loop->cancel(impl_->bridge_reapply_timer);
      impl_->bridge_reapply_timer = 0;
    }
    if (impl_->display_timer) {
      impl_->loop->cancel(impl_->display_timer);
      impl_->display_timer = 0;
    }
    if (impl_->tg) impl_->tg->stop();          // 輪詢/キュー駆動を止める (キューは永続)
    if (impl_->bridge) impl_->bridge->stop();  // availability=offline (retain) → DISCONNECT
    if (impl_->sipctl) impl_->sipctl->stop();  // 通話切断 → 登録解除 → pjsua_destroy
  });
  // httpd は runloop の外から止める (worker が callSync 待ちのまま mg_stop すると死锁)
  if (impl_->httpd) impl_->httpd->stop();
  impl_->loop->callSync([&] {
    if (impl_->mesh) impl_->mesh->stop();
    if (impl_->discovery) impl_->discovery->stop();
  });
  if (!impl_->external_loop) impl_->loop->stop();
}

void Node::setUiEventCb(UiEventCb cb) {
  std::lock_guard<std::mutex> lk(impl_->cb_mu);
  impl_->ui_cb = std::move(cb);
}

void Node::setTtsCb(TtsCb cb) {
  std::lock_guard<std::mutex> lk(impl_->cb_mu);
  impl_->tts_cb = std::move(cb);
}

void Node::setHttpsFn(HttpsFn fn) {
  std::lock_guard<std::mutex> lk(impl_->cb_mu);
  impl_->https_fn = std::move(fn);
}

void Node::press(const std::string& door_id) {
  impl_->loop->callSync([&] { impl_->doPress(door_id); });
}

void Node::pushCameraFrame(const uint8_t* data, int format, int width, int height, int stride,
                           int64_t ts_ms) {
  if (!data || width <= 0 || height <= 0) return;
  size_t n = rawFrameBytes(format, width, height, stride);
  if (n == 0) return;  // 未知 format
  RawFrame f;
  f.format = format;
  f.w = width;
  f.h = height;
  f.stride = stride;
  f.ts_ms = ts_ms;
  f.data.assign(data, data + n);  // コピーはこの 1 回だけ
  {
    std::lock_guard<std::mutex> lk(impl_->motion_mu);
    impl_->motion.feed(f);  // 動体検知 (発火は onMotion → loop へ post)
  }
  impl_->frame_bus.push(std::move(f));
}

void Node::sendQuickReply(const std::string& reply_id, const std::string& free_text,
                          const std::string& door_id, const std::string& via) {
  impl_->loop->callSync([&] { impl_->quickReply(reply_id, free_text, door_id, via); });
}

void Node::setEmergency(bool active, const std::string& via) {
  impl_->loop->callSync([&] { impl_->doEmergency(active, via); });
}

std::string Node::statusJson() {
  std::string out;
  impl_->loop->callSync([&] { out = impl_->statusJsonOnLoop(); });
  return out;
}

std::string Node::configJson() {
  std::string out;
  impl_->loop->callSync([&] { out = impl_->config->materializeJson(); });
  return out;
}

void Node::setConfigKey(const std::string& key, const std::string& value_json) {
  impl_->loop->callSync([&] { impl_->setKey(key, value_json); });
}

Runloop& Node::loop() { return *impl_->loop; }

}  // namespace db
