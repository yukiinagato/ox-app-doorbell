#include "node/node.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <atomic>
#include <chrono>
#include <mutex>
#include <thread>
#include <set>
#include <tuple>

#include "bridge/ha_bridge.h"
#include "bridge/telegram.h"
#include "httpd/webui_assets.h"
#include "media/frame_bus.h"
#include "media/motion_detector.h"
#include "media/video_track.h"
#include "mesh/socket_compat.h"
#include "mesh/tcp_transport.h"
#include "mesh/udp_beacon.h"
#include "monocypher.h"
#include "sipctl/sipctl.h"
#ifdef _WIN32
#include "media/camera_win.h"
#include "media/encoder_win.h"
#endif
#include "util/common.h"
#include "util/ids.h"
#include "util/json.h"
#include "util/log.h"

namespace db {

std::string sanitizeCaps(const std::string& caps_json, bool has_https) {
  auto doc = json::parse(caps_json);
  if (!doc || !cJSON_IsObject(doc.get())) return caps_json;
  if (!has_https) json::setBool(doc.get(), "tls12", false);
  return json::dump(doc.get());
}

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

// "host:port" → host
std::string hostOf(const std::string& addr) {
  auto p = addr.rfind(':');
  return p == std::string::npos ? addr : addr.substr(0, p);
}

// SIP の remote 表示 (例 "\"Door\" <sip:201@10.0.1.5>" / "sip:192.168.1.7:47190") から
// user と host を取り出す。user 無し (直接呼) は user 空。IPv4 LAN 前提 (IPv6 括弧は非対応)。
bool parseSipRemote(const std::string& remote, std::string* user, std::string* host) {
  std::string uri = remote;
  size_t lt = uri.find('<');
  if (lt != std::string::npos) {
    size_t gt = uri.find('>', lt);
    uri = uri.substr(lt + 1, gt == std::string::npos ? std::string::npos : gt - lt - 1);
  }
  size_t s = uri.find("sip:");
  if (s == std::string::npos) return false;
  uri = uri.substr(s + 4);
  size_t sc = uri.find(';');  // ;transport= 等のパラメータ除去
  if (sc != std::string::npos) uri = uri.substr(0, sc);
  size_t at = uri.find('@');
  if (at != std::string::npos) {
    *user = uri.substr(0, at);
    uri = uri.substr(at + 1);
  } else {
    user->clear();
  }
  *host = hostOf(uri);
  return !host->empty();
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

// ---- 統一資産 (docs/config-schema.md assets) ----
constexpr size_t kAssetMaxBytes = 3 * 1024 * 1024;        // wav/mp3/画像 ≤3MB
constexpr int64_t kAssetGcGraceMs = 10 * 60 * 1000;       // 無参照資産の削除猶予 (10 分)
constexpr const char* kAssetTypes[] = {"image/jpeg", "image/png", "audio/mpeg", "audio/wav"};

bool assetTypeAllowed(const std::string& type) {
  for (const char* t : kAssetTypes)
    if (type == t) return true;
  return false;
}

// 64 桁小文字 hex (sha256) か — /asset/<hash> のパス走査対策も兼ねる
bool isSha256HexStr(const std::string& s) {
  if (s.size() != 64) return false;
  for (char c : s) {
    if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
  }
  return true;
}

// "asset:<sha256>" 形式 (chime sound / emergency.alarm_sound) から hash を取り出す ("" = 非該当)
std::string assetRefHash(const std::string& v) {
  if (v.rfind("asset:", 0) != 0) return "";
  std::string h = v.substr(6);
  return isSha256HexStr(h) ? h : "";
}

// ---------- 内蔵既定文言 (Node::text の最終回落) ----------
// i18n/strings.yaml (文言の単一ソース) のうち「コアが自前で組む通知文」だけを写した表。
// 殻の UI 文言 (idle.* / admin.* 等) は各殻の resx/strings.xml が持つのでここには置かない。
// 追加する時は i18n/strings.yaml 側にも必ず同じキーを足すこと。
struct BuiltinText {
  const char* key;
  const char* ja;
  const char* en;
  const char* zh;
};
constexpr BuiltinText kBuiltinTexts[] = {
    {"event.press", "{door} に来客です ({time})", "Visitor at {door} ({time})",
     "{door} 有访客 ({time})"},
    {"event.motion", "{door} で動きを検知 ({time})", "Motion at {door} ({time})",
     "{door} 检测到移动 ({time})"},
    {"event.offline", "⚠ {device} オフライン (最終応答 {time})",
     "⚠ {device} offline (last seen {time})", "⚠ {device} 离线 (最后在线 {time})"},
    {"event.online", "{device} オンライン復帰", "{device} back online", "{device} 恢复在线"},
    {"emergency.title", "緊急事態", "EMERGENCY", "紧急情况"},
    {"emergency.notified", "家族に通知しました", "Family has been notified", "已通知家人"},
    {"emergency.notify_on", "🚨 緊急事態です — {device} から発報 ({time})",
     "🚨 Emergency — triggered by {device} ({time})", "🚨 紧急情况 — 由 {device} 触发 ({time})"},
    {"emergency.notify_off", "✅ 緊急解除", "✅ Emergency cleared", "✅ 警报已解除"},
    {"reply.answered", "応答済み ({text})", "Replied ({text})", "已回复 ({text})"},
    {"notify.test", "ドアホン テスト通知", "Doorbell test notification", "门铃测试通知"},
};

// 内蔵既定表の引き (見つからなければ nullptr)。lang は ja/en/zh 以外なら ja 扱い。
const char* builtinText(const std::string& key, const std::string& lang) {
  for (const auto& t : kBuiltinTexts) {
    if (key != t.key) continue;
    if (lang == "en") return t.en;
    if (lang == "zh") return t.zh;
    return t.ja;
  }
  return nullptr;
}

// "{name}" プレースホルダの全置換
void substArgs(std::string& s, const std::vector<std::pair<std::string, std::string>>& args) {
  for (const auto& kv : args) {
    const std::string ph = "{" + kv.first + "}";
    size_t pos = 0;
    while ((pos = s.find(ph, pos)) != std::string::npos) {
      s.replace(pos, ph.size(), kv.second);
      pos += kv.second.size();
    }
  }
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
  // H.264 流暢档 (Phase 6a): 符号化フレームの共有点 (/stream.mp4 の源)。
  // エンコードは殻/平台層 — コアは箱詰め (fMP4) と配信だけ。
  VideoTrack video_track;
  // 動体検知 (feed は採集スレッド — 設定変更と競合するため motion_mu_ で保護)
  MotionDetector motion;
  std::mutex motion_mu;
  // パネル状態 (loop 上でのみ触る): door → 呼出表示窓の期限 (mono ms)、最新クイック返信
  std::map<std::string, int64_t> door_calling_until;
  std::string last_reply_text;
  int64_t last_reply_ts = 0;
#ifdef _WIN32
  std::unique_ptr<CameraWin> camera;  // door_station のみ起動
  // Windows の H.264 硬編は core 内 (camera_win と同居 — 殻に採集ループが無いため)。
  // wanted (購読者あり) の間だけ回す — encoder_timer が 5 秒毎に判定する。
  std::unique_ptr<EncoderWin> encoder;
  uint64_t encoder_timer = 0;
#endif

  json::Doc cfg;  // materialize 済み設定 (loop 上でのみ触る)
  std::string node_id;
  uint64_t epoch = 1;
  bool started = false;
  std::mutex snap_mu;
  std::string status_snap;
  std::string config_snap;
  std::string pairing_snap;
  bool snap_scheduled = false;  // snap_mu 保護
  uint64_t snapshot_timer = 0;

  // press の追跡 (クイック返信の宛先解決・回執)
  std::string last_press_door;
  std::map<std::string, std::pair<std::string, uint64_t>> last_press_by_door;

  // SIP 状態 (loop 上でのみ触る)
  SipRegState sip_reg = SipRegState::Idle;
  SipCallState sip_call = SipCallState::Idle;
  // 通話中の相手 (対称 MJPEG 双方向映像用 — onSipCall InCall で解決)
  std::string sip_peer_node;    // 相手の node_id ("" = 特定不能: PSTN/Groundwire 等)
  std::string sip_peer_stream;  // 相手のライブ映像 URL (http://<host>:47180/stream.mjpeg)
  // 網頁通話の相手映像スロット (POST /call-frame が置き、殻が /peer-frame.jpg で輪詢する。
  // FrameBus とは別 — 自機カメラの絵と混ぜない。loop 上でのみ触る)
  Bytes peer_frame;
  int64_t peer_frame_mono = 0;  // 受信時刻 (monoMs)。3 秒で腐る
  std::string dtmf_buf;          // 通話中の DTMF 機能碼バッファ
  uint64_t dtmf_timer = 0;       // 3 秒無入力クリア
  uint64_t sip_reapply_timer = 0;  // 設定変更のデバウンス (連続する sip.* 差分で再起動を繰り返さない)
  uint64_t bridge_reapply_timer = 0;  // 同・HA ブリッジ用 (config 差分は複数キーで届く)

  // Telegram leader の就任遷移検出 (就任時に未通知 press を拾い直す)
  bool tg_was_active = false;

  // 表示制御 (loop 上でのみ触る): 直近に通知した display JSON + 30 秒周期の再評価タイマー
  std::string last_display_json;
  uint64_t display_timer = 0;

  // 統一資産キャッシュ (loop 上でのみ触る)。実体は assets_dir/<sha256>。
  std::string assets_dir;                       // data_dir/assets (":memory:" はテンポラリ)
  std::set<std::string> asset_fetching;         // mesh から取得中の hash (重複取得防止)
  std::map<std::string, int64_t> asset_unref_since;  // GC 猶予: hash → 無参照を初観測した mono
  uint64_t asset_prefetch_timer = 0;            // config 変更のデバウンス

  // 訪客言語 (loop 上でのみ触る): door → 選択中言語 (主言語 ja は保持しない = 空)。
  // 復帰タイマーは visitor_lang イベントを起こしたノードだけが張る (復帰イベントの重複防止)。
  std::map<std::string, std::string> visitor_lang_by_door;
  std::map<std::string, uint64_t> visitor_lang_revert_timer;  // door → timer id

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

  // ---------- 疎通監視 (debug 画面用) ----------
  // 全て runloop 上でのみ触る (背景スレッド無し = iOS の suspend/resume と衝突しない)。
  Node::DeviceInfoFn device_info_fn;      // 端末情報 SPI (gateway/wifi/battery)。cache 読取で速い
  std::string device_info_json;            // 直近 device_info (gateway/wifi/battery)
  std::string net_leader_addr;             // leader ノードの host (mesh から。空=自機/不明)
  std::vector<std::pair<std::string, std::string>> net_custom;  // (label, "host:port") config 由来
  uint64_t net_refresh_timer = 0;          // leader/custom スナップショット更新 (loop)
  uint64_t net_probe_timer = 0;            // 疎通プローブ (1 tick 1 target)
  size_t net_tick = 0;                     // round-robin index

  // ---------- helpers ----------
  void uiNotify(const std::string& event_json) {
    // イベント配送より先に快照を更新する — 受信側がイベントを見て status/config を
    // 読み直したとき、必ずイベント時点以降の状態が見える (遅延更新だと古い快照を
    // 読んだきり再通知が来ず、UI が停滞する)。loop 外から呼ばれた場合 (sipctl 等) は
    // loop 上の状態に触れないよう post に退避。started 前後は init/stop が面倒を見る。
    if (started && loop->onLoopThread()) {
      refreshSnapshots();
    } else {
      scheduleSnapshotRefresh();
    }
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

  void scheduleSnapshotRefresh() {
    std::lock_guard<std::mutex> lk(snap_mu);
    if (snap_scheduled) return;
    snap_scheduled = true;
    if (!loop->post([this] { refreshSnapshots(); })) snap_scheduled = false;  // 停止後は放棄
  }

  // video_track へ push し、inactive→active 遷移 (SPS/PPS 受領 = init segment 完成) を
  // 快照へ反映する。status.video.active は uiNotify を伴わず変わる数少ない状態のため、
  // ここで拾わないと 2 秒周期タイマーまで快照が古いまま。エンコーダスレッドから
  // 呼ばれるので schedule (post) 経由で loop に退避する。
  void pushVideoTrack(const uint8_t* p, size_t n, bool key, int64_t ts) {
    bool was = video_track.active();
    video_track.push(p, n, key, ts);
    if (!was && video_track.active()) scheduleSnapshotRefresh();
  }

  void refreshSnapshots() {
    if (!started) {  // stop の解体中に残った予約を実行しない (init は started=true 後に呼ぶ)
      std::lock_guard<std::mutex> lk(snap_mu);
      snap_scheduled = false;
      return;
    }
    std::string status = statusJsonOnLoop();
    std::string config_json = config->materializeJson();
    std::string pairing = pairingJsonOnLoop();
    std::lock_guard<std::mutex> lk(snap_mu);
    status_snap = std::move(status);
    config_snap = std::move(config_json);
    pairing_snap = std::move(pairing);
    snap_scheduled = false;
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

  // devices.<self>.local.camera の実効値 (無ければ既定 8/60/640x480 + auto/720p25/1500k)
  struct CamCfg {
    int fps = 8;
    int quality = 60;
    int w = 640, h = 480;
    std::string hint;
    // H.264 流暢档 (docs/config-schema.md camera.codec 節)
    std::string codec = "auto";  // auto | mjpeg | h264
    int h264_w = 1280, h264_h = 720;
    int h264_fps = 25;
    int h264_kbps = 1500;
    bool h264Enabled() const { return codec != "mjpeg"; }  // auto = 硬編があれば
  };
  static void parseRes(const std::string& res, int* w, int* h) {
    size_t x = res.find('x');
    if (x == std::string::npos) return;
    int pw = std::atoi(res.c_str());
    int ph = std::atoi(res.c_str() + x + 1);
    if (pw > 0 && ph > 0) {
      *w = pw;
      *h = ph;
    }
  }
  CamCfg cameraCfg() {
    CamCfg c;
    cJSON* cam = cfgAt("devices." + node_id + ".local.camera");
    if (cam) {
      c.fps = static_cast<int>(json::getInt(cam, "mjpeg_fps", 8));
      c.quality = static_cast<int>(json::getInt(cam, "mjpeg_quality", 60));
      c.hint = json::getString(cam, "device_hint");
      parseRes(json::getString(cam, "resolution", "640x480"), &c.w, &c.h);
      c.codec = json::getString(cam, "codec", "auto");
      if (c.codec != "mjpeg" && c.codec != "h264") c.codec = "auto";
      parseRes(json::getString(cam, "h264_resolution", "1280x720"), &c.h264_w, &c.h264_h);
      c.h264_fps = static_cast<int>(json::getInt(cam, "h264_fps", 25));
      c.h264_kbps = static_cast<int>(json::getInt(cam, "h264_bitrate_kbps", 1500));
    }
    if (c.fps <= 0) c.fps = 8;
    if (c.h264_fps <= 0) c.h264_fps = 25;
    if (c.h264_kbps <= 0) c.h264_kbps = 1500;
    return c;
  }

  // fps/quality/解像度を FrameBus + httpd + video_track へ反映 (起動時と config_changed 時)
  void applyCameraSettings() {
    CamCfg c = cameraCfg();
    frame_bus.setJpegParams(c.quality, c.w);
    if (httpd)
      httpd->setJpegProvider([this](int64_t* ts) { return frame_bus.latestJpeg(ts); }, c.fps);
    // codec=mjpeg → track 停止 (購読者は切断・殻の wanted も 0 になる)。
    // auto/h264 → 有効化 (auto で硬編が無い端末は殻が push しないだけ —
    // /stream.mp4 は init 待ちタイムアウトの 503 になりクライアントは MJPEG へ回落)。
    video_track.setEnabled(c.h264Enabled());
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

  // ---------- 統一資産 (mesh blob 配布 + 能動キャッシュ) ----------
  // 実体は assets_dir/<sha256>。台帳は config assets.<hash> = {size,type,origin,label}。
  // 設定変更 (+起動/peers 変化) で参照中 hash を能動プリフェッチ — 再生/表示は常にローカル。

  std::string assetFilePath(const std::string& hash) { return assets_dir + "/" + hash; }

  bool assetCached(const std::string& hash) {
    return isSha256HexStr(hash) && fileExists(assetFilePath(hash));
  }

  // 設定が参照している資産 hash を収集する (プリフェッチ/GC の基準):
  //   display.theme.bg_image / devices.*.local.theme.bg_image /
  //   quick_replies.*.audio.* / trigger_rules の chime sound "asset:*" /
  //   emergency.alarm_sound "asset:*"
  std::set<std::string> referencedAssets() {
    std::set<std::string> out;
    auto addHash = [&out](const std::string& h) {
      if (isSha256HexStr(h)) out.insert(h);
    };
    addHash(json::getString(cfgAt("display.theme"), "bg_image"));
    cJSON* devices = json::get(cfg.get(), "devices");
    cJSON* dev = nullptr;
    cJSON_ArrayForEach(dev, devices) {
      addHash(json::getString(json::get(json::get(dev, "local"), "theme"), "bg_image"));
    }
    cJSON* qrs = json::get(cfg.get(), "quick_replies");
    cJSON* qr = nullptr;
    cJSON_ArrayForEach(qr, qrs) {
      cJSON* audio = json::get(qr, "audio");
      cJSON* a = nullptr;
      cJSON_ArrayForEach(a, audio) {
        if (cJSON_IsString(a)) addHash(a->valuestring);
      }
    }
    addHash(assetRefHash(json::getString(json::get(cfg.get(), "ui"), "ringtone")));
    cJSON* rules_obj = json::get(cfg.get(), "trigger_rules");
    cJSON* rule = nullptr;
    cJSON_ArrayForEach(rule, rules_obj) {
      cJSON* action = nullptr;
      cJSON_ArrayForEach(action, json::get(rule, "actions")) {
        addHash(assetRefHash(json::getString(action, "sound")));
      }
    }
    addHash(assetRefHash(json::getString(json::get(cfg.get(), "emergency"), "alarm_sound")));
    return out;
  }

  // config 差分は複数キーで届く — 200ms デバウンスしてから前取り評価
  void schedulePrefetch() {
    if (!started) return;
    if (asset_prefetch_timer) loop->cancel(asset_prefetch_timer);
    asset_prefetch_timer = loop->postDelayed(200, [this] {
      asset_prefetch_timer = 0;
      prefetchAssets();
    });
  }

  // 参照中で未キャッシュの資産を mesh から取得 + 参照が消えた資産の猶予付き GC
  void prefetchAssets() {
    if (!mesh) return;
    std::set<std::string> refs = referencedAssets();
    // GC: 保持対象 = 参照中 ∪ 台帳掲載 (台帳から消された資産だけが回収対象)
    std::set<std::string> keep = refs;
    cJSON* ledger = json::get(cfg.get(), "assets");
    cJSON* it = nullptr;
    cJSON_ArrayForEach(it, ledger) {
      if (it->string && isSha256HexStr(it->string)) keep.insert(it->string);
    }
    const int64_t now_mono = clock->monoMs();
    for (const std::string& name : listDir(assets_dir)) {
      if (!isSha256HexStr(name)) continue;  // .tmp 等は触らない
      if (keep.count(name)) {
        asset_unref_since.erase(name);
        continue;
      }
      auto u = asset_unref_since.find(name);
      if (u == asset_unref_since.end()) {
        asset_unref_since[name] = now_mono;  // 猶予開始
      } else if (now_mono - u->second >= kAssetGcGraceMs) {
        DB_LOGI(kTag, "asset GC: " + name.substr(0, 12) + "…");
        removeFile(assetFilePath(name));
        asset_unref_since.erase(u);
      }
    }
    // 前取り
    for (const std::string& hash : refs) {
      if (assetCached(hash) || asset_fetching.count(hash)) continue;
      asset_fetching.insert(hash);
      std::weak_ptr<char> w = alive;
      mesh->fetchBlob(hash, [this, w, hash](Bytes data) {
        if (w.expired()) return;
        asset_fetching.erase(hash);
        if (data.empty()) return;  // 保持ノード不在 — 次の config/peers 変化で再試行
        if (sha256Hex(data) != hash) {
          DB_LOGW(kTag, "asset 検証失敗 (hash 不一致): " + hash.substr(0, 12) + "…");
          return;
        }
        if (!writeFileBytes(assetFilePath(hash), data)) {
          DB_LOGW(kTag, "asset 保存失敗: " + assetFilePath(hash));
          return;
        }
        DB_LOGI(kTag, "asset キャッシュ完了: " + hash.substr(0, 12) + "… (" +
                          std::to_string(data.size()) + "B)");
        auto o = json::obj();
        json::set(o.get(), "t", "asset_ready");
        json::set(o.get(), "hash", hash);
        uiNotify(json::dump(o.get()));
        // テーマ背景がこの資産だった場合に bg_image_path が null → パスへ解決される
        evalDisplay();
      });
    }
  }

  // 資産の登録 (POST /api/assets / Node::addAsset)。検証 → 保存 → 台帳へ。失敗は ""。
  std::string addAssetOnLoop(const Bytes& data, const std::string& type,
                             const std::string& label) {
    if (data.empty() || data.size() > kAssetMaxBytes || !assetTypeAllowed(type)) return "";
    const std::string hash = sha256Hex(data);
    if (!fileExists(assetFilePath(hash)) && !writeFileBytes(assetFilePath(hash), data)) {
      DB_LOGE(kTag, "asset 保存失敗: " + assetFilePath(hash));
      return "";
    }
    auto o = json::obj();
    json::set(o.get(), "size", static_cast<int64_t>(data.size()));
    json::set(o.get(), "type", type);
    json::set(o.get(), "origin", node_id);
    if (!label.empty()) json::set(o.get(), "label", label);
    config->set("assets." + hash, json::dump(o.get()));
    return hash;
  }

  // chime の uiNotify。sound "asset:<hash>" のカスタム音はキャッシュ済みなら
  // ローカルファイルパス (audio_path) を添える — 無ければ殻が既定音へ回落する。
  void notifyChime(const std::string& sound, const std::string& door) {
    auto o = json::obj();
    json::set(o.get(), "t", "chime");
    json::set(o.get(), "sound", sound);
    if (!door.empty()) json::set(o.get(), "door", door);
    const std::string hash = assetRefHash(sound);
    if (!hash.empty() && assetCached(hash)) json::set(o.get(), "audio_path", assetFilePath(hash));
    uiNotify(json::dump(o.get()));
  }

  // ---------- 訪客言語 ----------
  // 状態はイベント (visitor_lang) 由来 — 全ノードが onEvent で追随する。
  // 主言語 (ja) は「未選択」と同義でマップに持たない。

  std::string visitorLangFor(const std::string& door) {
    auto it = visitor_lang_by_door.find(door);
    return it == visitor_lang_by_door.end() ? "ja" : it->second;
  }

  int visitorRevertS() {
    return static_cast<int>(json::getInt(json::get(cfg.get(), "ui"), "visitor_lang_revert_s", 60));
  }

  void doSetVisitorLang(const std::string& door_arg, const std::string& lang) {
    std::string door = door_arg;
    if (door.empty()) door = opts.door.empty() ? last_press_door : opts.door;
    if (door.empty() || lang.empty()) {
      DB_LOGW(kTag, "setVisitorLang: door/lang 不足");
      return;
    }
    if (visitorLangFor(door) == lang) return;  // 変化なし (連打/復帰の重複防止)
    auto p = json::obj();
    json::set(p.get(), "lang", lang);
    events->append("visitor_lang", door, node_id, json::dump(p.get()));
  }

  void cancelVisitorRevert(const std::string& door) {
    auto t = visitor_lang_revert_timer.find(door);
    if (t == visitor_lang_revert_timer.end()) return;
    loop->cancel(t->second);
    visitor_lang_revert_timer.erase(t);
  }

  // 復帰タイマーを張り直す (発信ノードのみが呼ぶ)
  void armVisitorRevert(const std::string& door) {
    cancelVisitorRevert(door);
    const int s = visitorRevertS();
    if (s <= 0) return;  // 0 以下 = 自動復帰しない
    visitor_lang_revert_timer[door] =
        loop->postDelayed(static_cast<int64_t>(s) * 1000, [this, door] {
          visitor_lang_revert_timer.erase(door);
          if (visitor_lang_by_door.count(door)) doSetVisitorLang(door, "ja");
        });
  }

  // visitor_lang イベント受理毎 (ローカル発・複製受信の両方)
  void applyVisitorLangEvent(const EventRecord& ev, bool is_local) {
    auto p = json::parse(ev.payload_json.empty() ? "{}" : ev.payload_json);
    const std::string lang = p ? json::getString(p.get(), "lang") : "";
    if (ev.door.empty() || lang.empty()) return;
    if (lang == "ja") {
      visitor_lang_by_door.erase(ev.door);
      cancelVisitorRevert(ev.door);
    } else {
      visitor_lang_by_door[ev.door] = lang;
      cancelVisitorRevert(ev.door);  // 他ノード発の切替で自分の古いタイマーは無効
      if (is_local && ev.origin == node_id) armVisitorRevert(ev.door);
    }
    auto o = json::obj();
    json::set(o.get(), "t", "visitor_lang");
    json::set(o.get(), "door", ev.door);
    json::set(o.get(), "lang", lang);
    uiNotify(json::dump(o.get()));
  }

  // ---------- 表示制御 (display) ----------
  // 実効値 = config display.* を基底に devices.<self>.local.display.* で上書き
  // (スカラーはキー単位、night はオブジェクト単位で上書き)。night の窓判定は
  // rule_engine と同じ規則 (補正済み壁時計 + tz_offset_min、from <= t < to、日跨ぎ対応)。
  // theme (待機画面の背景) は display.theme を基底に devices.<self>.local.theme が
  // キー単位で上書き — 室内機/管理画面は config を書くだけで「推送」になる (CRDT 即時同期)。
  struct DisplayState {
    int brightness = 70;
    bool night = false;
    bool red_tint = false;
    int screensaver_after_s = 120;
    int pixel_shift_s = 300;
    std::string bg_color = "#101418";  // theme 背景色
    std::string bg_image;              // theme 背景画像 (assets の sha256; "" = 無し)
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
    {  // テーマ (devices.<self>.local.theme がキー単位で display.theme を上書き)
      cJSON* tbase = json::get(base, "theme");
      cJSON* tovr = cfgAt("devices." + node_id + ".local.theme");
      auto str = [&](const char* key) {
        if (tovr && json::get(tovr, key)) return json::getString(tovr, key);
        return json::getString(tbase, key);
      };
      const std::string c = str("bg_color");
      if (!c.empty()) d.bg_color = c;
      d.bg_image = str("bg_image");
      if (!isSha256HexStr(d.bg_image)) d.bg_image.clear();  // null/不正は「画像なし」
    }
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

  // display オブジェクトの中身 (uiNotify と status_json で共用)。
  // theme.bg_image_path は「キャッシュ済みならローカル絶対パス / まだなら null」—
  // 殻はパスを描画するだけでよい (未キャッシュ分は asset_ready 後に display が再発行される)。
  json::Doc displayDoc(const DisplayState& d) {
    auto o = json::obj();
    json::set(o.get(), "brightness", static_cast<int64_t>(d.brightness));
    json::setBool(o.get(), "night", d.night);
    json::setBool(o.get(), "red_tint", d.red_tint);
    json::set(o.get(), "screensaver_after_s", static_cast<int64_t>(d.screensaver_after_s));
    json::set(o.get(), "pixel_shift_s", static_cast<int64_t>(d.pixel_shift_s));
    cJSON* theme = json::addObj(o.get(), "theme");
    json::set(theme, "bg_color", d.bg_color);
    if (!d.bg_image.empty()) {
      json::set(theme, "bg_image", d.bg_image);
      if (assetCached(d.bg_image)) {
        json::set(theme, "bg_image_path", assetFilePath(d.bg_image));
      } else {
        json::setItem(theme, "bg_image_path", json::Doc(cJSON_CreateNull()));
      }
    } else {
      json::setItem(theme, "bg_image", json::Doc(cJSON_CreateNull()));
      json::setItem(theme, "bg_image_path", json::Doc(cJSON_CreateNull()));
    }
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
    // 警報音: emergency.alarm_sound ("siren1" 等の内蔵名 or "asset:<sha256>") + 音量。
    // カスタム音がキャッシュ済みなら audio_path (chime と同じ流儀 — 無ければ殻は内蔵音)。
    cJSON* em = json::get(cfg.get(), "emergency");
    const std::string sound = json::getString(em, "alarm_sound", "siren1");
    json::set(o.get(), "alarm_sound", sound);
    json::set(o.get(), "alarm_volume", json::getInt(em, "alarm_volume", 100));
    const std::string hash = assetRefHash(sound);
    if (!hash.empty() && assetCached(hash))
      json::set(o.get(), "audio_path", assetFilePath(hash));
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
    // 応答モード (config-schema sip.accounts.<id>.answer_mode):
    //   "auto" = 即応答 (門口機既定) / "ring" = 着信 UI で手動応答 (室内機向け)。
    // 未設定は従来どおり auto (SipSettings 既定)。
    std::string am = json::getString(acct, "answer_mode");
    if (am == "ring") s.auto_answer = false;
    else if (am == "auto") s.auto_answer = true;
    // 直接呼の待受ポート (既定 47190 — docs/network-ports.md)
    s.direct_port = static_cast<int>(json::getInt(sip, "direct_port", s.direct_port));
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

  // 直接 INVITE の許可送信元 = mesh 成員 (dead 以外) の実アドレス host 群 + 自 host。
  // peers 変化毎に更新する (計画書 §12: mesh 成員 IP 白名単 + 403)。
  // suspect も含める: 一時的な heartbeat 遅延で通話中の対講が拒否されないように。
  void updateSipAllowedSources() {
    if (!sipctl || !mesh) return;
    std::vector<std::string> ips;
    ips.push_back("127.0.0.1");  // 自機ループバック (単機テスト/自己監視)
    for (const auto& p : mesh->peers()) {
      if (p.status == "dead") continue;
      for (const auto& a : p.addrs) ips.push_back(hostOf(a));
    }
    sipctl->setAllowedSources(ips);
  }

  // 通話相手の node_id と MJPEG URL を解決する (対称双方向映像):
  //   - Asterisk 経由 (host == sip.server): remote user (内線) → sip.accounts.* の user 逆引き
  //   - 直接呼: remote host → mesh peers[].addrs の host 照合
  // 特定できない相手 (PSTN/Groundwire/網頁内線) は両方空のまま → 映像なし
  // (門口機は /peer-frame.jpg の輪詢に降級 — 網頁通話の「映像も送る」経路)。
  void resolveCallPeer(const std::string& remote, std::string* node, std::string* stream) {
    node->clear();
    stream->clear();
    std::string user, host;
    if (!parseSipRemote(remote, &user, &host) || !mesh) return;
    const std::string server = json::getString(json::get(cfg.get(), "sip"), "server");
    if (!user.empty() && !server.empty() && host == server) {
      // 内線 → node_id (config-schema: 門口機と室内機の両方が sip.accounts に載る)
      cJSON* accounts = cfgAt("sip.accounts");
      cJSON* it = nullptr;
      cJSON_ArrayForEach(it, accounts) {
        if (it->string && json::getString(it, "user") == user) {
          *node = it->string;
          break;
        }
      }
    } else {
      // 直接呼: 送信元 host を peers の実アドレスと照合
      for (const auto& p : mesh->peers()) {
        if (p.id == node_id) continue;
        for (const auto& a : p.addrs) {
          if (hostOf(a) == host) {
            *node = p.id;
            break;
          }
        }
        if (!node->empty()) break;
      }
    }
    if (node->empty() || *node == node_id) {
      node->clear();
      return;
    }
    for (const auto& p : mesh->peers()) {
      if (p.id == *node && p.status != "dead" && !p.addrs.empty()) {
        *stream = "http://" + hostOf(p.addrs[0]) + ":47180/stream.mjpeg";
        return;
      }
    }
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
      // 通話相手情報と網頁通話の相手映像スロットは通話と共に消える
      sip_peer_node.clear();
      sip_peer_stream.clear();
      peer_frame.clear();
      peer_frame_mono = 0;
    }
    if (st == SipCallState::InCall) {
      // 相手を特定して映像 URL を添える (答接管で門口機側が in_call になる時も同経路)。
      // 殻はこの URL を描画するだけ — 解決できない相手 (PSTN 等) は peer_stream 無し。
      // TODO(Phase 6b): 站間通話画面の H.264 硬解。相手が h264 提供中なら
      // peer_stream_mp4 (= <origin>/stream.mp4) も添えて、殻が MediaCodec/
      // VideoToolbox/MF で硬解描画する。今回 (6a) は従来どおり MJPEG のみ。
      resolveCallPeer(remote, &sip_peer_node, &sip_peer_stream);
    }
    if (!s) return;
    auto o = json::obj();
    json::set(o.get(), "t", "state");
    json::set(o.get(), "state", s);
    if (!remote.empty()) json::set(o.get(), "remote", remote);
    if (st == SipCallState::InCall && !sip_peer_node.empty()) {
      json::set(o.get(), "peer_node", sip_peer_node);
      if (!sip_peer_stream.empty()) json::set(o.get(), "peer_stream", sip_peer_stream);
    }
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

  // ---------- 文言解決 (Node::text の実体 — loop 上でのみ) ----------
  // i18n_overrides.<lang>.<key> → i18n_overrides.ja.<key> → 内蔵既定表 → key 自身。
  // i18n_overrides のキーはドットを含む平キー ("event.press") — cfgAt で降りずに直接引く。
  std::string textOnLoop(const std::string& key, const std::string& lang_arg,
                         const std::vector<std::pair<std::string, std::string>>& args) {
    const std::string lang = lang_arg.empty() ? "ja" : lang_arg;
    std::string out;
    cJSON* ov = json::get(cfg.get(), "i18n_overrides");
    if (ov) {
      out = json::getString(json::get(ov, lang.c_str()), key.c_str());
      if (out.empty() && lang != "ja") out = json::getString(json::get(ov, "ja"), key.c_str());
    }
    if (out.empty()) {
      const char* b = builtinText(key, lang);
      if (b) out = b;
    }
    if (out.empty()) out = key;  // 未知キーはキー自身 (欠落を画面上で見つけやすくする)
    substArgs(out, args);
    return out;
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

    // 統一資産のキャッシュ置き場 (":memory:" Store はテンポラリへ)
    assets_dir = (opts.data_dir == ":memory:")
                     ? tempDir() + "/doorbell-assets-" + node_id
                     : opts.data_dir + "/assets";
    makeDir(assets_dir);

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
      // 統一資産: 参照が増えた/減った可能性 — デバウンスして前取り+GC を評価
      schedulePrefetch();
      uiNotify("{\"t\":\"config_changed\"}");
    });
    events->onEvent([this](const EventRecord& ev, bool is_local) { onEvent(ev, is_local); });

    // トランスポート
    if (!transport) transport.reset(new TcpTransport(*loop));
    // beacon は未配対機でも生成する — PAIR-ANNOUNCE (平文・PSK 非依存) で自身を広告し、
    // 集群ノードの承認/配対モードで招待を受け取るため (配対 §1.6 拡張)。
    if (!discovery && opts.enable_beacon) discovery.reset(new UdpBeacon(*loop, opts.psk));

    // Mesh
    MeshSettings ms = opts.use_mesh_timing_template ? opts.mesh_timing_template : MeshSettings{};
    ms.node_id = node_id;
    ms.epoch = epoch;
    ms.listen_addr = opts.listen_addr;
    // advertise_addr 未指定なら実 LAN IPv4 を自動検出 (0.0.0.0 を配らない)。
    ms.advertise_addr = opts.advertise_addr;
    if (ms.advertise_addr.empty()) {
      std::string ip = db::net::primaryIPv4();
      auto colon = opts.listen_addr.rfind(':');
      std::string port = colon != std::string::npos ? opts.listen_addr.substr(colon + 1) : "47172";
      ms.advertise_addr = ip.empty() ? opts.listen_addr : (ip + ":" + port);
    }
    {  // 診断: アドレス検出の内訳をログ
      auto v4 = db::net::localAddresses(false);
      auto all = db::net::localAddresses(true);
      DB_LOGI(kTag, "addr-detect: getifaddrs v4=" + std::to_string(v4.size()) +
                        " all=" + std::to_string(all.size()) +
                        " route=" + db::net::primaryIPv4ViaRoute() +
                        " advertise=" + ms.advertise_addr);
    }
    ms.seed_peers = opts.seed_peers;
    ms.psk = opts.psk;
    ms.role = opts.role;
    ms.sw_version = opts.sw_version;
    ms.caps_json = opts.caps_json;
    Mesh::Callbacks cbs;
    cbs.on_peers_changed = [this] {
      updateSipAllowedSources();  // 直接 INVITE の許可 IP を mesh 成員に追随させる
      schedulePrefetch();         // 新しい peer が保持ノードかもしれない — 未取得資産を再試行
      uiNotify("{\"t\":\"peers_changed\"}");
    };
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
      updateSipAllowedSources();
      onPeerAlive(id, alive);
    };
    cbs.on_command = [this](const std::string& from, const std::string& cmd) {
      onCommand(from, cmd);
    };
    cbs.on_pending_changed = [this] { uiNotify("{\"t\":\"pending_changed\"}"); };
    // INVITE 受理 / PIN 参加で PSK を取得した → 殻に新 boot 設定を渡して永続化 + 再起動させる。
    cbs.on_paired = [this] { onBecamePaired(); };
    mesh.reset(new Mesh(*loop, *clock, *hlc, *transport, discovery.get(), store, *config,
                        *events, ms, cbs));
    // 他ノードからの快照要求 (SNAP_REQ — Telegram 写真用) には最新 JPEG で応える
    mesh->setSnapshotProvider([this] { return frame_bus.latestJpeg(); });
    // 資産 blob 要求 (BLOB_REQ) にはローカルキャッシュから応える
    mesh->setBlobProvider([this](const std::string& hash) {
      Bytes b;
      if (isSha256HexStr(hash)) readFileBytes(assetFilePath(hash), b);
      return b;
    });

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
      hooks.visitor_langs = [this] {
        return std::vector<std::pair<std::string, std::string>>(visitor_lang_by_door.begin(),
                                                                visitor_lang_by_door.end());
      };
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
      th.text = [this](const std::string& key, const std::string& lang,
                       const std::vector<std::pair<std::string, std::string>>& args) {
        return textOnLoop(key, lang, args);  // ブリッジは loop 上でしか呼ばない
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
      updateSipAllowedSources();  // 初期 peers (自分含む) を許可リストへ
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
      // H.264 硬編 (encoder_win — MF encoder MFT)。出力 AnnexB は video_track へ。
      // 未稼働中の feed は即 return するので採集経路への負担はない。
      encoder.reset(new EncoderWin([this](const uint8_t* p, size_t n, bool key, int64_t ts) {
        pushVideoTrack(p, n, key, ts);
      }));
      camera.reset(new CameraWin([this](RawFrame&& f) {
        {
          std::lock_guard<std::mutex> lk(motion_mu);
          motion.feed(f);
        }
        if (encoder) encoder->feed(f);  // 稼働中のみ消費 (NV12 変換もエンコーダ側)
        frame_bus.push(std::move(f));
      }));
      // codec=h264/auto の間は h264_resolution を採集目標にする (MJPEG 側は
      // frame_bus の max_width 縮小で従来解像度のまま — 二重採集はしない)。
      int tw = c.h264Enabled() ? c.h264_w : c.w;
      int th = c.h264Enabled() ? c.h264_h : c.h;
      camera->start(c.hint, tw, th);
      // wanted (購読者あり) の間だけエンコーダを回す (5 秒毎判定 — 省電力)
      encoder_timer = loop->postEvery(5'000, [this] {
        if (!encoder) return;
        bool want = video_track.enabled() && video_track.subscriberCount() > 0;
        if (want && !encoder->running()) {
          CamCfg cc = cameraCfg();
          EncoderWin::Params p;
          p.fps = cc.h264_fps;
          p.bitrate_kbps = cc.h264_kbps;
          encoder->start(p);
        } else if (!want && encoder->running()) {
          encoder->stop();
        }
      });
    }
#endif
    // 表示制御: 30 秒周期の再評価 + 起動直後の 1 回発行 (壳が初期状態を受け取れる)
    display_timer = loop->postEvery(30'000, [this] { evalDisplay(); });
    // SOS: 状態を Store から復元し、初期状態も 1 回発行する (再起動後のイベント再生に相当)
    restoreEmergency();

    started = true;
    snapshot_timer = loop->postEvery(2'000, [this] { refreshSnapshots(); });
    refreshSnapshots();
    evalDisplay(/*force=*/true);
    emergencyNotifyUi();
    prefetchAssets();  // 起動時: 参照中で未キャッシュの資産を前取り
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
      // 訪客言語 (門口機の言語切替に出す言語 + 無操作復帰秒)
      config->set("ui.languages", "[\"ja\",\"en\",\"zh\"]");
      config->set("ui.visitor_lang_revert_s", "60");
      // 訪客の用件ボタン (既定 seed — docs/config-schema.md visit_purposes)
      auto vp = [&](const char* id, const char* ja, const char* en, const char* zh,
                    const char* icon, int order) {
        auto o = json::obj();
        cJSON* label = json::addObj(o.get(), "label");
        json::set(label, "ja", ja);
        json::set(label, "en", en);
        json::set(label, "zh", zh);
        json::set(o.get(), "icon", icon);
        json::set(o.get(), "order", static_cast<int64_t>(order));
        config->set(std::string("visit_purposes.") + id, json::dump(o.get()));
      };
      vp("p_visit", "訪問", "Visit", "访客", "🏠", 1);
      vp("p_delivery", "宅配便", "Delivery", "快递", "📦", 2);
      vp("p_mail", "郵便", "Mail", "邮件", "✉️", 3);
      vp("p_sales", "営業・集金", "Sales", "推销/收费", "💼", 4);
      vp("p_work", "検針・工事", "Utility", "检修/施工", "🔧", 5);
      vp("p_other", "その他", "Other", "其他", "❓", 6);
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
      // 按鈴 = 訪客の操作 — 自分が復帰タイマーを持つ door なら無操作カウントを仕切り直す
      if (visitor_lang_revert_timer.count(ev.door)) armVisitorRevert(ev.door);
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
    } else if (ev.type == "visitor_lang") {
      // 全ノードで door→言語 を追随 + uiNotify (復帰タイマーは発信ノードだけが張る)
      applyVisitorLangEvent(ev, is_local);
    } else if (ev.type == "call_cancelled") {
      if (!ev.door.empty()) door_calling_until.erase(ev.door);
    }
    {
      auto o = json::obj();
      json::set(o.get(), "t", "event");
      json::set(o.get(), "type", ev.type);
      json::set(o.get(), "door", ev.door);
      json::set(o.get(), "device", ev.device);
      if (ev.type == "press" || ev.type == "purpose_selected") {
        auto p = json::parse(ev.payload_json.empty() ? "{}" : ev.payload_json);
        if (p) {
          const std::string purpose = json::getString(p.get(), "purpose");
          const std::string vlang = json::getString(p.get(), "visitor_lang");
          if (!purpose.empty()) json::set(o.get(), "purpose", purpose);
          if (!vlang.empty()) json::set(o.get(), "visitor_lang", vlang);
        }
      }
      uiNotify(json::dump(o.get()));
    }
    auto actions = rules.evaluate(ev, hlc->correctedWallMs(), tzOffsetMin());
    bool chime_notified = false;
    bool chime_action_seen = false;
    for (const auto& a : actions) {
      auto p = json::parse(a.params_json.empty() ? "{}" : a.params_json);
      if (a.type == "chime") {
        chime_action_seen = true;
        // devices 配列に自分が含まれる (または "all") 時だけ自分が鳴る
        bool mine = false;
        cJSON* devs = json::get(p.get(), "devices");
        if (!devs) {
          mine = (opts.role == "indoor_panel");  // 省略時: 室内パネル全部
        } else if (cJSON_IsString(devs)) {
          mine = std::string(devs->valuestring) == "all";
        } else if (cJSON_IsArray(devs)) {
          if (cJSON_GetArraySize(devs) == 0) mine = (opts.role == "indoor_panel");
          cJSON* it = nullptr;
          cJSON_ArrayForEach(it, devs) {
            if (cJSON_IsString(it) && node_id == it->valuestring) mine = true;
          }
        }
        if (mine) {
          notifyChime(json::getString(p.get(), "sound", "ding1"), ev.door);
          chime_notified = true;
        }
      } else if (a.type == "auto_reply") {
        // 用件別の自動応対 (例: 宅配 → 置き配案内)。該当 door の門口機だけが実行する
        // (1 door 1 門口機 = exactly-once。表示+音声+reply イベントは quickReply と同経路)。
        if (opts.role == "door_station" && !ev.door.empty() && ev.door == opts.door) {
          const std::string rid = json::getString(p.get(), "reply_id");
          if (!rid.empty()) {
            DB_LOGI(kTag, "auto_reply -> " + rid);
            quickReply(rid, "", ev.door, "auto");
          }
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
    // 呼出ルールをまだ設定していない家庭でも、室内パネルは必ず鳴る。
    // 明示 chime がこの端末で実行された場合は二重再生しない。全体既定は ui.ringtone。
    if (ev.type == "press" && opts.role == "indoor_panel" && !chime_action_seen &&
        !chime_notified) {
      notifyChime(json::getString(json::get(cfg.get(), "ui"), "ringtone", "ding1"), ev.door);
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
      notifyChime(json::getString(c.get(), "sound", "ding1"), json::getString(c.get(), "door"));
    } else if (cmd == "show_reply") {
      std::string text = json::getString(c.get(), "text");
      const std::string lang = json::getString(c.get(), "lang", "ja");
      // カスタム音声 (quick_replies.<id>.audio.<lang> の sha256)。キャッシュ済みなら
      // ローカルパスを uiNotify に添えて殻に再生させる — TTS はしない。
      // 未キャッシュなら TTS へ回落 (音声の優先度: キャッシュ済 audio → TTS → 殻の提示音)。
      const std::string audio = json::getString(c.get(), "audio");
      const bool audio_ok = !audio.empty() && assetCached(audio);
      auto o = json::obj();
      json::set(o.get(), "t", "reply");
      json::set(o.get(), "text", text);
      json::set(o.get(), "ttl_s", json::getInt(c.get(), "ttl_s", 30));
      json::set(o.get(), "lang", lang);
      if (audio_ok) {
        json::set(o.get(), "audio", audio);
        json::set(o.get(), "audio_path", assetFilePath(audio));
      }
      uiNotify(json::dump(o.get()));
      if (!audio_ok && json::getBool(c.get(), "speak", true)) tts(text, lang);
    } else {
      DB_LOGW(kTag, "unknown command from " + from.substr(0, 8) + ": " + cmd);
    }
  }

  // ---------- クイック返信 ----------
  void quickReply(const std::string& reply_id, const std::string& free_text,
                  const std::string& door_arg, const std::string& via) {
    std::string door = door_arg.empty() ? last_press_door : door_arg;
    // 文言/音声は該当 door の訪客言語に追従 (訳が無ければ ja へ回落 — labelIn)
    const std::string lang = visitorLangFor(door);
    std::string text = free_text;
    bool speak = true;
    std::string audio;  // quick_replies.<id>.audio.<lang> の sha256 (無ければ ja へ回落)
    if (text.empty() && !reply_id.empty()) {
      cJSON* q = cfgAt("quick_replies." + reply_id);
      if (q) {
        text = labelIn(json::get(q, "label"), lang);
        speak = json::getBool(q, "speak", true);
        if (cJSON* au = json::get(q, "audio")) {
          audio = json::getString(au, lang.c_str());
          if (audio.empty()) audio = json::getString(au, "ja");
          if (!isSha256HexStr(audio)) audio.clear();
        }
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
    json::set(c.get(), "lang", lang);
    if (!audio.empty()) json::set(c.get(), "audio", audio);
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

  // door の担当門口機 (door_station) の node_id ("" = 不在)
  std::string doorStation(const std::string& door_id) {
    cJSON* devices = json::get(cfg.get(), "devices");
    cJSON* dev = nullptr;
    cJSON_ArrayForEach(dev, devices) {
      if (dev->string && json::getString(dev, "role") == "door_station" &&
          json::getString(dev, "door") == door_id) {
        return dev->string;
      }
    }
    return "";
  }

  // node の httpd origin ("http://<host>:47180")。自機 = "" (相対 URL でよい)、不明 = 見つからず ""。
  // 呼び出し側は自機かどうかを nid == node_id で区別すること。
  std::string nodeOrigin(const std::string& nid) {
    if (nid == node_id || !mesh) return "";
    for (const auto& p : mesh->peers()) {
      if (p.id == nid && !p.addrs.empty())
        return "http://" + hostOf(p.addrs[0]) + ":47180";
    }
    return "";
  }

  // ---------- 疎通監視 (debug 画面) ----------
  // loop 上: leader/custom ターゲットのスナップショットを更新 (mesh/config は loop 専有)
  // leader/custom ターゲット + device_info を更新 (runloop 上。mutex 不要)。
  void netRefreshSnapshot() {
    std::string leader_host;
    if (mesh) {
      std::string lid = mesh->leaderFor("telegram");
      if (lid.empty()) lid = mesh->leaderFor("mqtt_bridge");
      if (!lid.empty() && lid != node_id) {
        for (const auto& p : mesh->peers())
          if (p.id == lid && !p.addrs.empty()) { leader_host = hostOf(p.addrs[0]); break; }
      }
    }
    std::vector<std::pair<std::string, std::string>> custom;
    cJSON* arr = cfgAt("debug.ping_targets");
    if (arr && cJSON_IsArray(arr)) {
      cJSON* it = nullptr;
      cJSON_ArrayForEach(it, arr) {
        std::string host, label;
        int port = 80;
        if (cJSON_IsString(it)) { host = it->valuestring; label = host; }
        else if (cJSON_IsObject(it)) {
          host = json::getString(it, "host");
          label = json::getString(it, "label", host);
          cJSON* pj = json::get(it, "port");
          if (pj && cJSON_IsNumber(pj)) port = pj->valueint;
        }
        if (!host.empty()) custom.push_back({label, host + ":" + std::to_string(port)});
      }
    }
    net_leader_addr = leader_host;
    net_custom = std::move(custom);
    // device_info も更新 (SPI は cache 読取で速い — ブロックしない)
    if (device_info_fn) {
      std::string di = device_info_fn();
      if (!di.empty()) device_info_json = di;
    }
  }

  // 現在のターゲット一覧 (gateway + leader + custom)。runloop 上。
  std::vector<std::pair<std::string, std::pair<std::string, int>>> netTargets() {
    std::vector<std::pair<std::string, std::pair<std::string, int>>> targets;
    std::string gw;
    if (!device_info_json.empty()) {
      json::Doc d = json::parse(device_info_json);
      if (d) gw = json::getString(d.get(), "gateway");
    }
    if (!gw.empty()) targets.push_back({"gateway", {gw, 80}});
    if (!net_leader_addr.empty()) targets.push_back({"leader", {net_leader_addr, 47172}});
    for (auto& c : net_custom) {
      std::string hp = c.second;
      auto cpos = hp.rfind(':');
      std::string h = cpos == std::string::npos ? hp : hp.substr(0, cpos);
      int pt = cpos == std::string::npos ? 80 : std::atoi(hp.substr(cpos + 1).c_str());
      targets.push_back({c.first, {h, pt}});
    }
    return targets;
  }

  // 1 tick で 1 ターゲットだけ短時間プローブ (runloop を最大 800ms しかブロックしない)。
  // 背景スレッドを使わない = iOS の suspend/resume watchdog と衝突しない。
  void netProbeTick() {
    auto targets = netTargets();
    if (targets.empty()) return;
    auto& t = targets[net_tick % targets.size()];
    net_tick++;
    int rtt = -1;
    bool ok = net::tcpProbe(t.second.first, t.second.second, 800, &rtt);
    Store::NetProbe pr;
    pr.ts_ms = clock->wallMs();
    pr.target = t.first;
    pr.host = t.second.first + ":" + std::to_string(t.second.second);
    pr.ok = ok;
    pr.rtt_ms = rtt;
    store.netProbePut(pr);
    if ((net_tick % 20) == 0) store.netProbePrune(clock->wallMs() - 7LL * 24 * 3600 * 1000);
  }

  void startNetMonitor() {
    netRefreshSnapshot();
    net_refresh_timer = loop->postEvery(20'000, [this] { netRefreshSnapshot(); });
    net_probe_timer = loop->postEvery(6'000, [this] { netProbeTick(); });
  }

  void stopNetMonitor() {
    if (net_refresh_timer) { loop->cancel(net_refresh_timer); net_refresh_timer = 0; }
    if (net_probe_timer) { loop->cancel(net_probe_timer); net_probe_timer = 0; }
  }

  // ---------- 配対 (発見/招待) ----------

  // 配対 UI 用: 自身の告知情報 (QR) + 近隣の未配対デバイス一覧 + 配対モード状態。
  std::string pairingJsonOnLoop() {
    auto o = json::obj();
    if (!mesh) return json::dump(o.get());
    json::setBool(o.get(), "paired", mesh->isPaired());
    json::set(o.get(), "role", opts.role);
    // 自身の告知 (未配対時に QR へ載せる id/addr/pk) — QR 文字列も組んで渡す
    json::Doc self = json::parse(mesh->pairingSelfJson());
    if (self) {
      // QR ペイロード: doorbell-pair:<addr>|<id>|<pk> (管理端末が読み取り invite する)
      const std::string qr = "doorbell-pair:" + json::getString(self.get(), "addr") + "|" +
                             json::getString(self.get(), "id") + "|" +
                             json::getString(self.get(), "pk");
      json::set(o.get(), "pair_qr", qr);
      json::setItem(o.get(), "self", std::move(self));  // 入れ子オブジェクトとして添付
    }
    // 近隣の未配対デバイス + 配対モード
    json::Doc pend = json::parse(mesh->pendingJson());
    if (pend) json::setItem(o.get(), "pending", std::move(pend));
    return json::dump(o.get());
  }

  // INVITE 受理 / PIN 参加で PSK を取得 → 殻へ新 boot 設定を通知 (殻が boot.json 永続化 + 再起動)。
  void onBecamePaired() {
    if (!mesh) return;
    const auto& s = mesh->settings();
    auto o = json::obj();
    json::set(o.get(), "t", "paired");
    json::set(o.get(), "psk_hex", hexEncode(s.psk.data(), s.psk.size()));
    json::set(o.get(), "psk_id", s.psk_id);
    cJSON* seeds = json::addArr(o.get(), "seeds");
    for (const auto& a : s.seed_peers)
      json::push(seeds, json::Doc(cJSON_CreateString(a.c_str())));
    DB_LOGI(kTag, "paired: PSK 取得 (seeds=" + std::to_string(s.seed_peers.size()) +
                      ") — 殻へ boot 永続化 + 再起動を要求");
    uiNotify(json::dump(o.get()));
  }

  std::string debugJsonOnLoop() {
    auto o = json::obj();
    json::set(o.get(), "node", node_id);
    json::set(o.get(), "version", opts.sw_version);
    json::set(o.get(), "role", opts.role);
    cJSON* addrs = json::addArr(o.get(), "addresses");
    for (const auto& a : db::net::localAddresses(true))
      json::push(addrs, json::Doc(cJSON_CreateString(a.c_str())));
    {
      json::Doc d = device_info_json.empty() ? json::Doc(nullptr) : json::parse(device_info_json);
      if (d) json::setItem(o.get(), "device", std::move(d));
    }
    {  // 触発統計: 累計 press 回数 (全履歴 COUNT) + 最新 press
      cJSON* trig = json::addObj(o.get(), "triggers");
      int64_t total = 0;  // O(1): meta の累計カウンタを読むだけ
      auto pc = store.metaGet("stat_press_total");
      if (pc) { try { total = std::stoll(*pc); } catch (...) { total = 0; } }
      json::set(trig, "total_press", total);
      auto last = store.latestEventOfTypes("press", "press");
      if (last) {
        cJSON* l = json::addObj(trig, "last");
        json::set(l, "door", last->door);
        json::set(l, "device", last->device);
        json::set(l, "wall_ms", last->wall_ms);
        json::set(l, "payload", last->payload_json);
      }
    }
    {  // 疎通履歴 24h
      int64_t since = clock->wallMs() - 24LL * 3600 * 1000;
      cJSON* probes = json::addArr(o.get(), "net_probes");
      for (const auto& p : store.netProbesSince(since, 5000)) {
        cJSON* e = json::pushObj(probes);
        json::set(e, "ts", p.ts_ms);
        json::set(e, "target", p.target);
        json::set(e, "host", p.host);
        json::setBool(e, "ok", p.ok);
        json::set(e, "rtt", static_cast<int64_t>(p.rtt_ms));
      }
    }
    return json::dump(o.get());
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
    // 本機の全ローカルアドレス (IPv4 + グローバル IPv6) — 表示/デバッグ用。
    {
      cJSON* la = json::addArr(self, "local_addrs");
      for (const auto& a : db::net::localAddresses(true))
        json::push(la, json::Doc(cJSON_CreateString(a.c_str())));
    }
    cJSON* sip = json::addObj(o.get(), "sip");
    json::setBool(sip, "registered", sip_reg == SipRegState::Registered);
    json::set(sip, "state", sipRegName(sip_reg));
    json::set(sip, "call", sipCallName(sip_call));
    if (!sip_peer_node.empty()) json::set(sip, "peer_node", sip_peer_node);
    if (!sip_peer_stream.empty()) json::set(sip, "peer_stream", sip_peer_stream);
    if (sipctl) {  // 直近通話の RTP 送受 (診断/実測テスト用 — tools/dev_intercom_test.sh)
      int64_t tx = 0, rx = 0;
      sipctl->rtpStats(&tx, &rx);
      json::set(sip, "rtp_tx", tx);
      json::set(sip, "rtp_rx", rx);
    }
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
    // 自機の H.264 流暢档の状態 (管理画面/診断用)。active = SPS/PPS 受領済み =
    // 実際に配信できる状態 (auto で硬編が無い端末は codec=auto でも active=false のまま)。
    {
      CamCfg cc = cameraCfg();
      cJSON* v = json::addObj(o.get(), "video");
      json::set(v, "codec", cc.codec);
      json::setBool(v, "active", video_track.active());
      json::set(v, "subscribers", static_cast<int64_t>(video_track.subscriberCount()));
      std::string cs = video_track.codecString();
      if (!cs.empty()) json::set(v, "codec_str", cs);
    }
    // 統一資産のキャッシュ被覆率 (台帳掲載のうちローカルにある数 — 管理画面用)
    {
      int64_t total = 0, cached = 0;
      cJSON* ledger = json::get(cfg.get(), "assets");
      cJSON* a = nullptr;
      cJSON_ArrayForEach(a, ledger) {
        if (!a->string) continue;
        total++;
        if (assetCached(a->string)) cached++;
      }
      cJSON* as = json::addObj(o.get(), "assets");
      json::set(as, "cached", cached);
      json::set(as, "total", total);
    }
    // 訪客言語の現在状態 (door → 選択中言語; 主言語 ja の door は載らない)
    {
      cJSON* vl = json::addObj(o.get(), "visitor_lang");
      for (const auto& kv : visitor_lang_by_door) json::set(vl, kv.first.c_str(), kv.second);
    }
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
            // H.264 流暢档 (Phase 6a): codec が h264/auto の門口機は /stream.mp4 も持つ。
            // auto で硬編が無い端末は接続時に 503 → クライアントは MJPEG へ自動回落する
            // (远端の実際の可否は config からは分からないため URL は楽観的に載せる)。
            cJSON* cam = json::get(json::get(dev, "local"), "camera");
            std::string codec = json::getString(cam, "codec", "auto");
            if (codec != "mjpeg") {
              json::set(e, "stream_mp4",
                        "http://" + hostOf(p.addrs[0]) + ":47180/stream.mp4");
            }
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
    // /api/panel/* と /snapshot-proxy /call-frame はハンドラ内で panel token (?k=) を検証する。
    // /peer-frame.jpg は /snapshot.jpg と同格の LAN 公開 (殻の輪詢用 — webui/panel/API.md)
    // /asset/ はハンドラ内で管理セッション or panel token を検証する (gate は素通し)。
    httpd->setAuth([this](const HttpReq& r) { return r.uri == "/" || checkSession(r); },
                   {"/api/login", "/locale/", "/panel/", "/admin/", "/stream.mjpeg",
                    "/stream.mp4", "/snapshot.jpg", "/api/panel/", "/snapshot-proxy",
                    "/call-frame", "/peer-frame.jpg", "/asset/"});

    // /stream.mp4 (fMP4 ライブ — 認証は /stream.mjpeg と同扱いの LAN 公開 + 任意 ?k=)。
    // 接続毎に video_track の購読を張る。Reader の破棄 (= 切断) が購読解除。
    httpd->setMp4Provider([this]() -> Httpd::Mp4Pull {
      if (!video_track.enabled()) return nullptr;  // codec=mjpeg → 503
      auto reader = video_track.subscribe();
      return [reader](bool* ended) { return reader->pull(500, ended); };
    });

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

    httpd->route("GET", "/api/debug",
                 [this](const HttpReq&) { return HttpResp::json(debugJsonOnLoop()); });

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
      if (t.pin.empty())  // 未配対 → 発行不可 (全ゼロ PSK を配らない)
        return HttpResp::json("{\"ok\":false,\"err\":\"host_unpaired\"}", 409);
      auto o = json::obj();
      json::setBool(o.get(), "ok", true);
      json::set(o.get(), "pin", t.pin);
      json::set(o.get(), "expires_s", (t.expires_mono - clock->monoMs()) / 1000);
      return HttpResp::json(json::dump(o.get()));
    });

    // このノードを新規クラスタの親機にする (未配対時のみ — 新規 PSK 生成)
    httpd->route("POST", "/api/pairing/found", [this](const HttpReq&) {
      if (!mesh) return HttpResp::json("{\"ok\":false,\"err\":\"no_mesh\"}", 503);
      bool ok = mesh->foundCluster();
      auto o = json::obj();
      json::setBool(o.get(), "ok", ok);
      if (!ok) json::set(o.get(), "err", "already_paired");
      return HttpResp::json(json::dump(o.get()));
    });

    // --- 配対 (発見/招待; 管理セッション必須) ---
    // 自身の告知 QR + 近隣の未配対デバイス一覧 + 配対モード状態
    httpd->route("GET", "/api/pairing",
                 [this](const HttpReq&) { return HttpResp::json(pairingJsonOnLoop()); });
    // 配対モードを ON (既定 600 秒 = 10 分)。期間中に現れた未配対機を自動招待。
    httpd->route("POST", "/api/pairing/mode", [this](const HttpReq& req) {
      if (!mesh) return HttpResp::json("{\"ok\":false,\"err\":\"no_mesh\"}", 503);
      auto b = json::parse(req.body);
      int64_t sec = b ? json::getInt(b.get(), "seconds", 600) : 600;
      if (sec < 0) sec = 0;
      if (sec > 3600) sec = 3600;
      mesh->setPairingMode(sec * 1000);
      auto o = json::obj();
      json::setBool(o.get(), "ok", true);
      json::set(o.get(), "seconds", sec);
      return HttpResp::json(json::dump(o.get()));
    });
    // 一覧の 1 台を承認 → {psk,seeds,cfg} を封緘 push
    httpd->route("POST", "/api/pairing/invite", [this](const HttpReq& req) {
      if (!mesh) return HttpResp::json("{\"ok\":false,\"err\":\"no_mesh\"}", 503);
      auto b = json::parse(req.body);
      std::string id = b ? json::getString(b.get(), "id") : "";
      if (id.empty()) return HttpResp::json("{\"ok\":false,\"err\":\"no_id\"}", 400);
      mesh->inviteDevice(id);
      return HttpResp::json("{\"ok\":true}");
    });
    // QR スキャンからの直接招待。body: {qr:"doorbell-pair:<addr>|<id>|<pk>"} または {addr,id,pk}
    httpd->route("POST", "/api/pairing/invite-direct", [this](const HttpReq& req) {
      if (!mesh) return HttpResp::json("{\"ok\":false,\"err\":\"no_mesh\"}", 503);
      auto b = json::parse(req.body);
      std::string addr = b ? json::getString(b.get(), "addr") : "";
      std::string id = b ? json::getString(b.get(), "id") : "";
      std::string pk = b ? json::getString(b.get(), "pk") : "";
      std::string qr = b ? json::getString(b.get(), "qr") : "";
      if (!qr.empty()) {  // "doorbell-pair:<addr>|<id>|<pk>" を分解
        const std::string kPrefix = "doorbell-pair:";
        if (qr.rfind(kPrefix, 0) == 0) qr = qr.substr(kPrefix.size());
        auto p1 = qr.find('|'), p2 = qr.rfind('|');
        if (p1 != std::string::npos && p2 != std::string::npos && p2 > p1) {
          addr = qr.substr(0, p1);
          id = qr.substr(p1 + 1, p2 - p1 - 1);
          pk = qr.substr(p2 + 1);
        }
      }
      if (addr.empty() || pk.size() != 64)
        return HttpResp::json("{\"ok\":false,\"err\":\"bad_qr\"}", 400);
      mesh->inviteDeviceDirect(addr, pk);
      return HttpResp::json("{\"ok\":true}");
    });
    // 未配対機側: PIN + seed で能動的に参加 (管理 UI から。QR/承認と併存)
    httpd->route("POST", "/api/pairing/join", [this](const HttpReq& req) {
      if (!mesh) return HttpResp::json("{\"ok\":false,\"err\":\"no_mesh\"}", 503);
      if (mesh->isPaired()) return HttpResp::json("{\"ok\":false,\"err\":\"already_paired\"}", 409);
      auto b = json::parse(req.body);
      std::string host = b ? json::getString(b.get(), "host") : "";
      std::string pin = b ? json::getString(b.get(), "pin") : "";
      if (host.empty() || pin.empty())
        return HttpResp::json("{\"ok\":false,\"err\":\"need host+pin\"}", 400);
      // 結果は非同期 (uiNotify t:paired / t:join_result)。ここでは受理のみ返す。
      mesh->joinCluster(host, pin, [this](bool ok, const std::string& err) {
        auto o = json::obj();
        json::set(o.get(), "t", "join_result");
        json::setBool(o.get(), "ok", ok);
        json::set(o.get(), "err", err);
        uiNotify(json::dump(o.get()));
      });
      return HttpResp::json("{\"ok\":true,\"pending\":true}");
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
      std::string purpose = b ? json::getString(b.get(), "purpose") : "";
      if (!purpose.empty() && !cfgAt("visit_purposes." + purpose))
        return HttpResp::json("{\"ok\":false,\"err\":\"unknown purpose\"}", 400);
      doPress(door, purpose);
      return HttpResp::json("{\"ok\":true}");
    });

    // 統一資産の登録 (管理セッション)。body = 実体 (raw)、?type=&label=。
    // 3MB 超・許可外 type は 4xx。応答: {"ok":true,"hash":"<sha256>"}。
    httpd->route("POST", "/api/assets", [this](const HttpReq& req) {
      const std::string type = req.param("type");
      if (!assetTypeAllowed(type))
        return HttpResp::json("{\"ok\":false,\"err\":\"bad type\"}", 415);
      if (req.body.empty()) return HttpResp::json("{\"ok\":false,\"err\":\"empty body\"}", 400);
      if (req.body.size() > kAssetMaxBytes)
        return HttpResp::json("{\"ok\":false,\"err\":\"too large\"}", 413);
      Bytes data(req.body.begin(), req.body.end());
      const std::string hash = addAssetOnLoop(data, type, req.param("label"));
      if (hash.empty()) return HttpResp::json("{\"ok\":false,\"err\":\"store failed\"}", 500);
      auto o = json::obj();
      json::setBool(o.get(), "ok", true);
      json::set(o.get(), "hash", hash);
      return HttpResp::json(json::dump(o.get()));
    });

    // 資産の取得 (管理セッション or panel token ?k=)。ローカルキャッシュから返す/404。
    // 内容アドレス (sha256) なので不変 — 長期キャッシュ可。
    httpd->route("GET", "/asset/*", [this](const HttpReq& req) {
      if (!checkSession(req) && !panelTokenOk(req))
        return HttpResp::json("{\"ok\":false,\"err\":\"bad token\"}", 403);
      const std::string hash = req.uri.substr(7);  // "/asset/" 以降
      if (!isSha256HexStr(hash))
        return HttpResp::json("{\"ok\":false,\"err\":\"bad hash\"}", 400);
      Bytes data;
      if (!readFileBytes(assetFilePath(hash), data))
        return HttpResp::json("{\"ok\":false,\"err\":\"not cached\"}", 404);
      HttpResp r;
      r.content_type = json::getString(cfgAt("assets." + hash), "type",
                                       "application/octet-stream");
      r.body.assign(data.begin(), data.end());
      r.headers["Cache-Control"] = "max-age=31536000, immutable";
      return r;
    });

    // 資産の削除 (管理セッション)。台帳 assets.<hash> を tombstone + ローカルキャッシュを
    // 即削除する。他ノードは台帳消滅 (CRDT 複製) を見て猶予付き GC で自然に回収する。
    // まだ設定から参照中の hash も削除できる (参照側は次回プリフェッチで保持ノード不在に
    // なるだけ — 掃除は管理者の責務)。
    httpd->route("DELETE", "/api/assets/*", [this](const HttpReq& req) {
      const std::string hash = req.uri.substr(std::string("/api/assets/").size());
      if (!isSha256HexStr(hash))
        return HttpResp::json("{\"ok\":false,\"err\":\"bad hash\"}", 400);
      config->remove("assets." + hash);
      removeFile(assetFilePath(hash));
      asset_unref_since.erase(hash);
      return HttpResp::json("{\"ok\":true}");
    });

    // 訪客言語切替 (管理セッション)。{"door":…,"lang":…} — door 省略 = 自機担当 door。
    httpd->route("POST", "/api/visitor-lang", [this](const HttpReq& req) {
      auto b = json::parse(req.body);
      std::string lang = b ? json::getString(b.get(), "lang") : "";
      if (lang.empty()) return HttpResp::json("{\"ok\":false,\"err\":\"no lang\"}", 400);
      doSetVisitorLang(b ? json::getString(b.get(), "door") : "", lang);
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
        // 訪客言語バッジ (選択中のみ — 主言語 ja は載らない)
        auto vl = visitor_lang_by_door.find(it->string);
        if (vl != visitor_lang_by_door.end()) json::set(e, "visitor_lang", vl->second);
        // H.264 流暢档 (Phase 6a): 担当門口機の codec が h264/auto なら /stream.mp4 の
        // URL を載せる (monitor.html の MSE 用)。auto で硬編が無い端末は接続 503 →
        // クライアントは従来のスナップショット輪詢へ自動回落する。
        std::string station = doorStation(it->string);
        if (!station.empty()) {
          cJSON* cam = json::get(json::get(cfgAt("devices." + station), "local"), "camera");
          if (json::getString(cam, "codec", "auto") != "mjpeg") {
            if (station == node_id) {
              json::set(e, "stream_mp4", "/stream.mp4");  // 自機担当 — 相対 URL
            } else {
              std::string origin = nodeOrigin(station);
              if (!origin.empty()) json::set(e, "stream_mp4", origin + "/stream.mp4");
            }
          }
        }
      }
      cJSON* evs = json::addArr(o.get(), "events");
      for (const auto& ev : store.recentEvents(10)) {
        cJSON* e = json::pushObj(evs);
        json::set(e, "type", ev.type);
        json::set(e, "door", ev.door);
        json::set(e, "device", ev.device);
        json::set(e, "wall_ms", ev.wall_ms);
        if (ev.type == "press" && !ev.payload_json.empty()) {  // 用件バッジ + 言語バッジ
          auto p = json::parse(ev.payload_json);
          const std::string purpose = p ? json::getString(p.get(), "purpose") : "";
          const std::string vlang = p ? json::getString(p.get(), "visitor_lang") : "";
          if (!purpose.empty()) json::set(e, "purpose", purpose);
          if (!vlang.empty()) json::set(e, "visitor_lang", vlang);
        }
      }
      if (last_reply_ts > 0) {
        cJSON* r = json::addObj(o.get(), "reply");
        json::set(r, "text", last_reply_text);
        json::set(r, "ts", last_reply_ts);
      } else {
        json::setItem(o.get(), "reply", json::Doc(cJSON_CreateNull()));
      }
      // 訪客の用件ボタン (order 昇順 — 門口ページの描画用。ラベルは全言語同梱で
      // 言語切替時の再取得を不要にする)
      {
        struct P {
          int64_t order;
          std::string id;
          const cJSON* obj;
        };
        std::vector<P> ps;
        cJSON* vps = json::get(cfg.get(), "visit_purposes");
        cJSON* vp = nullptr;
        cJSON_ArrayForEach(vp, vps) {
          if (vp->string) ps.push_back({json::getInt(vp, "order", 1000), vp->string, vp});
        }
        std::sort(ps.begin(), ps.end(), [](const P& a, const P& b) {
          return std::tie(a.order, a.id) < std::tie(b.order, b.id);
        });
        cJSON* arr = json::addArr(o.get(), "purposes");
        for (const P& p : ps) {
          cJSON* e = json::pushObj(arr);
          json::set(e, "id", p.id);
          json::set(e, "icon", json::getString(p.obj, "icon"));
          json::set(e, "order", p.order);
          if (cJSON* label = json::get(p.obj, "label"))
            json::setItem(e, "label", json::Doc(cJSON_Duplicate(label, 1)));
        }
      }
      // 訪客言語切替に出す言語 (config ui.languages — 無ければ ja のみ)
      {
        cJSON* arr = json::addArr(o.get(), "languages");
        cJSON* langs = cfgAt("ui.languages");
        if (cJSON_IsArray(langs)) {
          cJSON* l = nullptr;
          cJSON_ArrayForEach(l, langs) {
            if (cJSON_IsString(l)) json::push(arr, json::Doc(cJSON_CreateString(l->valuestring)));
          }
        }
        if (cJSON_GetArraySize(arr) == 0)
          json::push(arr, json::Doc(cJSON_CreateString("ja")));
      }
      json::set(o.get(), "server_ts", hlc->correctedWallMs());
      return HttpResp::json(json::dump(o.get()));
    });

    // パネルページの文言解決 (i18n_overrides の全文 + 言語一覧)。読込時 1 回取得する —
    // ルックアップ順は overrides.<lang>.<key> → ページ内蔵文言 → キー (Node::text と同順)。
    httpd->route("GET", "/api/panel/i18n", [this](const HttpReq& req) {
      if (!panelTokenOk(req)) return HttpResp::json("{\"ok\":false,\"err\":\"bad token\"}", 403);
      auto o = json::obj();
      json::setBool(o.get(), "ok", true);
      cJSON* arr = json::addArr(o.get(), "languages");
      cJSON* langs = cfgAt("ui.languages");
      if (cJSON_IsArray(langs)) {
        cJSON* l = nullptr;
        cJSON_ArrayForEach(l, langs) {
          if (cJSON_IsString(l)) json::push(arr, json::Doc(cJSON_CreateString(l->valuestring)));
        }
      }
      if (cJSON_GetArraySize(arr) == 0) json::push(arr, json::Doc(cJSON_CreateString("ja")));
      cJSON* ov = json::get(cfg.get(), "i18n_overrides");
      if (ov) {
        json::setItem(o.get(), "overrides", json::Doc(cJSON_Duplicate(ov, 1)));
      } else {
        json::addObj(o.get(), "overrides");
      }
      return HttpResp::json(json::dump(o.get()));
    });

    httpd->route("POST", "/api/panel/press", [this](const HttpReq& req) {
      if (!panelTokenOk(req)) return HttpResp::json("{\"ok\":false,\"err\":\"bad token\"}", 403);
      std::string door = req.param("door");
      if (door.empty() || !cfgAt("doors." + door))
        return HttpResp::json("{\"ok\":false,\"err\":\"unknown door\"}", 400);
      std::string purpose = req.param("purpose");
      if (!purpose.empty() && !cfgAt("visit_purposes." + purpose))
        return HttpResp::json("{\"ok\":false,\"err\":\"unknown purpose\"}", 400);
      doPress(door, purpose);
      return HttpResp::json("{\"ok\":true}");
    });

    // 訪客言語切替 (panel token)。?door=&lang= — door 省略 = 自機担当 door。
    httpd->route("POST", "/api/panel/visitor-lang", [this](const HttpReq& req) {
      if (!panelTokenOk(req)) return HttpResp::json("{\"ok\":false,\"err\":\"bad token\"}", 403);
      const std::string lang = req.param("lang");
      if (lang.empty()) return HttpResp::json("{\"ok\":false,\"err\":\"no lang\"}", 400);
      const std::string door = req.param("door");
      if (!door.empty() && !cfgAt("doors." + door))
        return HttpResp::json("{\"ok\":false,\"err\":\"unknown door\"}", 400);
      doSetVisitorLang(door, lang);
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

    // ---------- 網頁通話 (webui/panel/call.html — 契約は webui/panel/API.md) ----------

    // 網頁通話の設定/宛先解決。webrtc = config integrations.webrtc (未設定なら通話ボタン無効)。
    // doors[].extension = その door の担当門口機の内線 (sip.accounts.<node_id>.user)。
    httpd->route("GET", "/api/panel/call-info", [this](const HttpReq& req) {
      if (!panelTokenOk(req)) return HttpResp::json("{\"ok\":false,\"err\":\"bad token\"}", 403);
      auto o = json::obj();
      json::setBool(o.get(), "ok", true);
      cJSON* w = json::addObj(o.get(), "webrtc");
      cJSON* wc = cfgAt("integrations.webrtc");
      json::set(w, "ws_url", json::getString(wc, "ws_url"));
      json::set(w, "sip_user", json::getString(wc, "sip_user"));
      json::set(w, "sip_pass", json::getString(wc, "sip_pass"));
      json::set(w, "server", json::getString(json::get(cfg.get(), "sip"), "server"));
      cJSON* doors = json::addObj(o.get(), "doors");
      cJSON* dcfg = json::get(cfg.get(), "doors");
      cJSON* it = nullptr;
      cJSON_ArrayForEach(it, dcfg) {
        if (!it->string) continue;
        cJSON* e = json::addObj(doors, it->string);
        // 担当門口機 (door_station) の node_id → 内線 + 実アドレス
        std::string station;
        cJSON* devices = json::get(cfg.get(), "devices");
        cJSON* dev = nullptr;
        cJSON_ArrayForEach(dev, devices) {
          if (dev->string && json::getString(dev, "role") == "door_station" &&
              json::getString(dev, "door") == it->string) {
            station = dev->string;
            break;
          }
        }
        if (station.empty()) continue;
        json::set(e, "extension", json::getString(cfgAt("sip.accounts." + station), "user"));
        if (station == node_id) {
          json::set(e, "station", "");  // 自機 — 相対 URL でよい
          json::setBool(e, "online", true);
        } else if (mesh) {
          for (const auto& p : mesh->peers()) {
            if (p.id == station && !p.addrs.empty()) {
              json::set(e, "station", "http://" + hostOf(p.addrs[0]) + ":47180");
              json::setBool(e, "online", p.status != "dead");
            }
          }
        }
      }
      return HttpResp::json(json::dump(o.get()));
    });

    // ブラウザ → 門口機の「相手映像」フレーム投入 (通話中のみ受理)。
    // body = JPEG 1 枚 (getUserMedia→canvas)。門口機殻は /peer-frame.jpg を輪詢して描画する。
    // 他ホストのパネルページからの直接 POST を許すため CORS を返す (preflight は下の OPTIONS)。
    httpd->route("POST", "/call-frame", [this](const HttpReq& req) {
      auto cors = [](HttpResp r) {
        r.headers["Access-Control-Allow-Origin"] = "*";
        return r;
      };
      if (!panelTokenOk(req))
        return cors(HttpResp::json("{\"ok\":false,\"err\":\"bad token\"}", 403));
      const std::string door = req.param("door");
      if (opts.role != "door_station" || (!door.empty() && door != opts.door))
        return cors(HttpResp::json("{\"ok\":false,\"err\":\"not this station\"}", 404));
      if (sip_call != SipCallState::InCall)
        return cors(HttpResp::json("{\"ok\":false,\"err\":\"not in call\"}", 409));
      // JPEG 以外は拒否 (SOI マーカ検査 — Content-Type は信用しない)
      if (req.body.size() < 4 || static_cast<uint8_t>(req.body[0]) != 0xFF ||
          static_cast<uint8_t>(req.body[1]) != 0xD8)
        return cors(HttpResp::json("{\"ok\":false,\"err\":\"not jpeg\"}", 400));
      peer_frame.assign(req.body.begin(), req.body.end());
      peer_frame_mono = clock->monoMs();
      return cors(HttpResp::json("{\"ok\":true}"));
    });
    httpd->route("OPTIONS", "/call-frame", [](const HttpReq&) {
      HttpResp r;  // CORS preflight (fetch が Content-Type: image/jpeg で送るため必要)
      r.status = 204;
      r.body = "";
      r.headers["Access-Control-Allow-Origin"] = "*";
      r.headers["Access-Control-Allow-Methods"] = "POST, OPTIONS";
      r.headers["Access-Control-Allow-Headers"] = "Content-Type";
      r.headers["Access-Control-Max-Age"] = "600";
      return r;
    });

    // 網頁通話相手の最新フレーム (通話中の門口機殻が輪詢)。3 秒より古いフレームは 404
    // (相手が映像送信を止めた/通話が終わった — 殻は「映像なし」表示へ戻る)。
    httpd->route("GET", "/peer-frame.jpg", [this](const HttpReq&) {
      if (peer_frame.empty() || clock->monoMs() - peer_frame_mono > 3000)
        return HttpResp::json("{\"ok\":false,\"err\":\"no frame\"}", 404);
      HttpResp r;
      r.content_type = "image/jpeg";
      r.body.assign(peer_frame.begin(), peer_frame.end());
      r.headers["Cache-Control"] = "no-store";
      return r;
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

  // purpose: visit_purposes のキー ("" = 用件なしの汎用按鈴)。payload には purpose と
  // 選択中の訪客言語を同梱する (docs/config-schema.md — Telegram/HA/panel の展示面が使う)。
  void doPress(const std::string& door_arg, const std::string& purpose) {
    std::string door = door_arg.empty() ? opts.door : door_arg;
    auto p = json::obj();
    if (!purpose.empty()) json::set(p.get(), "purpose", purpose);
    const std::string vlang = visitorLangFor(door);
    if (vlang != "ja") json::set(p.get(), "visitor_lang", vlang);
    events->append("press", door, node_id, json::dump(p.get()));
  }

  void doSelectPurpose(const std::string& door_arg, const std::string& purpose) {
    if (purpose.empty() || !cfgAt("visit_purposes." + purpose)) return;
    const std::string door = door_arg.empty() ? opts.door : door_arg;
    auto p = json::obj();
    json::set(p.get(), "purpose", purpose);
    events->append("purpose_selected", door, node_id, json::dump(p.get()));
  }

  void doCancelCall(const std::string& door_arg) {
    const std::string door = door_arg.empty() ? opts.door : door_arg;
    events->append("call_cancelled", door, node_id, "{}");
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
  if (impl_->encoder) impl_->encoder->stop();
#endif
  // /stream.mp4 の購読者を全員起こして切断させる (httpd->stop の mg_stop が
  // 進行中接続の完了を待つため、先に終わらせておく)
  impl_->video_track.stop();
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
    if (impl_->snapshot_timer) {
      impl_->loop->cancel(impl_->snapshot_timer);
      impl_->snapshot_timer = 0;
    }
    if (impl_->asset_prefetch_timer) {
      impl_->loop->cancel(impl_->asset_prefetch_timer);
      impl_->asset_prefetch_timer = 0;
    }
#ifdef _WIN32
    if (impl_->encoder_timer) {
      impl_->loop->cancel(impl_->encoder_timer);
      impl_->encoder_timer = 0;
    }
#endif
    for (auto& kv : impl_->visitor_lang_revert_timer) impl_->loop->cancel(kv.second);
    impl_->visitor_lang_revert_timer.clear();
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

void Node::setDeviceInfoFn(DeviceInfoFn fn) {
  // 監視スレッド開始前に呼ばれる想定 (capi の create 時)。
  impl_->device_info_fn = std::move(fn);
}

void Node::press(const std::string& door_id, const std::string& purpose) {
  std::string d = door_id;
  std::string p = purpose;
  impl_->loop->post([this, d, p] { impl_->doPress(d, p); });
}

void Node::selectPurpose(const std::string& door_id, const std::string& purpose) {
  std::string d = door_id;
  std::string p = purpose;
  impl_->loop->post([this, d, p] { impl_->doSelectPurpose(d, p); });
}

void Node::cancelCall(const std::string& door_id) {
  std::string d = door_id;
  impl_->loop->post([this, d] { impl_->doCancelCall(d); });
}

void Node::setVisitorLang(const std::string& door_id, const std::string& lang) {
  std::string d = door_id;
  std::string l = lang;
  impl_->loop->post([this, d, l] { impl_->doSetVisitorLang(d, l); });
}

std::string Node::addAsset(const Bytes& data, const std::string& type,
                           const std::string& label) {
  std::string hash;
  impl_->loop->callSync([&] { hash = impl_->addAssetOnLoop(data, type, label); });
  return hash;
}

std::string Node::text(const std::string& key, const std::string& lang,
                       const TextArgs& args) const {
  std::string out;
  impl_->loop->callSync([&] { out = impl_->textOnLoop(key, lang, args); });
  return out;
}

std::string Node::assetPath(const std::string& hash) {
  std::string path;
  impl_->loop->callSync([&] {
    if (impl_->assetCached(hash)) path = impl_->assetFilePath(hash);
  });
  return path;
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

void Node::pushEncodedFrame(const uint8_t* annexb, size_t len, bool key, int64_t ts_ms) {
  // VideoTrack は自前ロック — 高頻度呼び出しなので loop へは marshal しない
  impl_->pushVideoTrack(annexb, len, key, ts_ms);
}

bool Node::videoEncoderWanted() {
  return impl_->video_track.enabled() && impl_->video_track.subscriberCount() > 0;
}

void Node::sendQuickReply(const std::string& reply_id, const std::string& free_text,
                          const std::string& door_id, const std::string& via) {
  std::string rid = reply_id;
  std::string txt = free_text;
  std::string d = door_id;
  std::string v = via;
  impl_->loop->post([this, rid, txt, d, v] { impl_->quickReply(rid, txt, d, v); });
}

void Node::setEmergency(bool active, const std::string& via) {
  bool a = active;
  std::string v = via;
  impl_->loop->post([this, a, v] { impl_->doEmergency(a, v); });
}

std::string Node::statusJson() {
  std::lock_guard<std::mutex> lk(impl_->snap_mu);
  if (impl_->status_snap.empty()) return "{}";
  return impl_->status_snap;
}

std::string Node::debugJson() {
  std::string out;
  impl_->loop->callSync([&] { out = impl_->debugJsonOnLoop(); });
  return out;
}

std::string Node::configJson() {
  std::lock_guard<std::mutex> lk(impl_->snap_mu);
  if (impl_->config_snap.empty()) return "{}";
  return impl_->config_snap;
}

void Node::setConfigKey(const std::string& key, const std::string& value_json) {
  impl_->loop->callSync([&] { impl_->setKey(key, value_json); });
}

std::string Node::pairingJson() {
  std::lock_guard<std::mutex> lk(impl_->snap_mu);
  if (impl_->pairing_snap.empty()) return "{}";
  return impl_->pairing_snap;
}

bool Node::foundCluster() {
  bool ok = false;
  impl_->loop->callSync([&] {
    if (impl_->mesh) ok = impl_->mesh->foundCluster();
  });
  return ok;
}

void Node::joinCluster(const std::string& host, const std::string& pin) {
  std::string h = host;
  std::string p = pin;
  impl_->loop->post([this, h, p] {
    if (impl_->mesh && !impl_->mesh->isPaired()) {
      impl_->mesh->joinCluster(h, p, [this](bool ok, const std::string& err) {
        auto o = json::obj();
        json::set(o.get(), "t", "join_result");
        json::setBool(o.get(), "ok", ok);
        json::set(o.get(), "err", err);
        impl_->uiNotify(json::dump(o.get()));
      });
    }
  });
}

void Node::setPairingMode(int seconds) {
  int s = seconds;
  impl_->loop->post([this, s] {
    if (impl_->mesh) impl_->mesh->setPairingMode(static_cast<int64_t>(s) * 1000);
  });
}

void Node::inviteDevice(const std::string& id) {
  std::string did = id;
  impl_->loop->post([this, did] {
    if (impl_->mesh) impl_->mesh->inviteDevice(did);
  });
}

void Node::inviteDeviceDirect(const std::string& addr, const std::string& id,
                              const std::string& pk) {
  (void)id;  // id は将来のログ/照合用 (招待自体は addr+pk で成立)
  std::string a = addr;
  std::string p = pk;
  impl_->loop->post([this, a, p] {
    if (impl_->mesh) impl_->mesh->inviteDeviceDirect(a, p);
  });
}

Runloop& Node::loop() { return *impl_->loop; }

// ---------- SIP 直接呼 (TV 監聴等 — 末尾追記: 並行作業との衝突回避) ----------

void Node::sipCall(const std::string& target, const std::string& mode) {
  impl_->loop->callSync([&] {
    if (impl_->sipctl) impl_->sipctl->call(target, mode);
  });
}

void Node::sipHangup() {
  impl_->loop->callSync([&] {
    if (impl_->sipctl) impl_->sipctl->hangup();
  });
}

}  // namespace db
