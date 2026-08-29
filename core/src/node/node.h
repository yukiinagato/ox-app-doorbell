// Node — 組み立てルート。1 プロセス 1 台の「子機」全体:
//   Store + LwwMap + EventLog + RuleEngine + Mesh + Httpd を配線し、
//   ボタン押下 → イベント → ルール評価 → アクション配送 (chime/クイック返信/…) を回す。
// SIP は sipctl (PJSIP) を配線済み — sip_call アクション / 着信自動応答 / DTMF 機能碼。
// スレッド: 公開 API はどのスレッドからでも可 (内部で Runloop へ marshal)。
#pragma once

#include <array>
#include <functional>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "crdt/lww_map.h"
#include "events/events.h"
#include "httpd/httpd.h"
#include "mesh/mesh.h"
#include "store/store.h"
#include "util/clock.h"
#include "util/hlc.h"
#include "util/runloop.h"

namespace db {

struct NodeOptions {
  std::string data_dir;            // Store 置き場 (":memory:" 可)
  std::string name = "doorbell";   // 端末表示名
  std::string role = "door_station";  // door_station | indoor_panel
  std::string door;                // この端末が担当する door_id ("" 可)
  std::string listen_addr = "0.0.0.0:47172";
  std::string advertise_addr;      // 他ノードへ教える自アドレス
  std::vector<std::string> seed_peers;
  std::array<uint8_t, 32> psk{};   // 全ゼロ = 未配対 (joinCluster 待ち)
  bool enable_beacon = true;       // 実 UDP beacon。テストは必ず false (稼働中 fleet への迷入防止)
  std::string caps_json = "{}";
  std::string sw_version = "0.1.0";
  int http_port = 0;               // 0 = HTTP 無効
  bool seed_default_config = true; // 設定が空なら既定値 (quick_replies 等) を書く
  // SIP boot 上書き (boot.json 由来。config sip.accounts.<self> が未設定の時に使う)
  std::string sip_user;
  std::string sip_pass;
  bool sip_null_audio = false;     // テスト/ヘッドレス: null 音声デバイス
  // mesh タイミング上書き (テスト用; 0 = 既定)
  MeshSettings mesh_timing_template{};
  bool use_mesh_timing_template = false;
};

// テスト注入点。空なら実物 (RealClock + TcpTransport + UdpBeacon)。
struct NodeDeps {
  IClock* clock = nullptr;                       // 借用 (所有しない)
  Runloop* loop = nullptr;                       // 借用。指定時は Node は start/stop しない
                                                 // (複数 Node で共有する決定的シミュレーション用)
  std::unique_ptr<ITransport> transport;         // 所有
  std::unique_ptr<IDiscovery> discovery;         // 所有 (null 可)
};

// https API 実装が無い環境向けに tls12 を握りつぶす。
// has_https=false 時に tls12=false を強制し、json 文字列を返却する。
std::string sanitizeCaps(const std::string& caps_json, bool has_https);

class Node {
 public:
  // ui_event: doorbell.h の db_ui_event_cb 相当 (JSON)。tts: SPI tts_speak 相当 (null 可)。
  using UiEventCb = std::function<void(const std::string& event_json)>;
  using TtsCb = std::function<void(const std::string& text, const std::string& lang)>;
  // HTTPS 送信 (Telegram 等 — コアは TLS を持たない)。非同期: 実装は即座に返り、
  // 完了時に done を任意スレッドから呼んでよい (内部で Runloop へ marshal される)。
  // status < 0 = トランスポート失敗。実装元: capi db_platform.https_request /
  // host ランナーの curl / テストのモック。
  using HttpsFn = std::function<void(
      const std::string& method, const std::string& url, const std::string& headers_json,
      const Bytes& body, std::function<void(int status, std::string resp_body)> done)>;

  Node(NodeOptions opts, NodeDeps deps = {});
  ~Node();

  bool start();
  void stop();

  void setUiEventCb(UiEventCb cb);
  void setTtsCb(TtsCb cb);
  // HTTPS 実装の注入 (Telegram ブリッジが使う)。start 前後どちらでも可・任意スレッド可。
  void setHttpsFn(HttpsFn fn);
  // 端末情報 SPI (gateway/wifi/battery の JSON を返す。任意スレッドから同期呼・ブロック可)。
  // 疎通監視スレッドが定期的に呼ぶ。null 可 (wifi/battery/gateway 無しで動作)。
  using DeviceInfoFn = std::function<std::string()>;
  void setDeviceInfoFn(DeviceInfoFn fn);

  // ボタン押下 (門口機 UI / /api/press / panel から)。purpose: visit_purposes のキー
  // ("" = 用件なしの汎用按鈴)。payload には purpose と訪客言語 (選択済みの場合) が載る。
  void press(const std::string& door_id, const std::string& purpose = "");
  // クイック返信の配送 (reply_id は config quick_replies のキー、free_text 優先)
  // door_id 空 = 最新 press の door。via: "web" | "telegram" | "mqtt" | "app" | "auto"
  // 文言は該当 door の訪客言語で表示/TTS (訳が無ければ ja へ回落)。quick_replies.<id>.audio
  // にキャッシュ済みカスタム音声があれば TTS の代わりにそれを使う (uiNotify に audio_path)。
  void sendQuickReply(const std::string& reply_id, const std::string& free_text,
                      const std::string& door_id, const std::string& via);

  // 訪客言語切替 (門口機の言語ボタン / panel / admin)。door_id 空 = 自機担当 door。
  // visitor_lang イベントとして全ノードへ複製され、各ノードが
  // {"t":"visitor_lang","door":…,"lang":…} を uiNotify する。lang "ja" = 即時復帰。
  // ui.visitor_lang_revert_s 秒の無操作で自動的に ja へ戻る (これもイベント)。
  void setVisitorLang(const std::string& door_id, const std::string& lang);

  // 統一資産: data を assets/ へ保存し台帳 (config assets.<hash>) へ登録して hash を返す。
  // 3MB 超・許可外 type (image/jpeg image/png audio/mpeg audio/wav) は "" (登録しない)。
  std::string addAsset(const Bytes& data, const std::string& type, const std::string& label);
  // hash の資産がローカルキャッシュにあればそのファイルパス、無ければ ""。
  std::string assetPath(const std::string& hash);

  // 文言解決 (i18n)。通知文・音声案内など「コアが自前で組む文字列」の単一入口。
  // 解決順: config i18n_overrides.<lang>.<key> → i18n_overrides.ja.<key> → 内蔵既定表
  // (i18n/strings.yaml の ja/en/zh 相当を node.cpp にハードコード) → key 自身。
  // args は {name} プレースホルダの置換対 ({{"door","正面玄関"},{"time","14:03"}} 等)。
  // 殻 (WPF/Android/webui) は自前の resx/strings.xml を持つので通常これを使う必要は無い —
  // i18n_overrides を反映した文言が欲しい時だけ呼ぶ。
  using TextArgs = std::vector<std::pair<std::string, std::string>>;
  std::string text(const std::string& key, const std::string& lang,
                   const TextArgs& args = {}) const;

  // SOS 緊急モード。active=true で発報 / false で解除 (emergency / emergency_cancel
  // イベントを追加 — 全ノードへ複製され、各ノードが {"t":"emergency"} を uiNotify する)。
  // via: "panel" | "web" | "admin"。PIN 検証 (解除時の kiosk PIN 等) は呼び出し側の責務。
  void setEmergency(bool active, const std::string& via);

  // SIP 発呼/切断 (TV 監聴等の平台殻向け)。target: 内線番号 or "sip:" 完全 URI (直接呼)。
  // mode: "" = 通常 / "monitor" = 一方向監聴 (受け側は自マイク音声のみ送る) / "answer"。
  // sipctl 未初期化・PJSIP 無効ビルドでは no-op (ログのみ)。
  void sipCall(const std::string& target, const std::string& mode = "");
  void sipHangup();

  // カメラ生フレーム投入 (capi db_core_on_camera_frame / 採集スレッドから; 任意スレッド可)。
  // format: doorbell.h と同じ 0=NV21, 1=NV12, 2=YUY2, 3=BGRA。データはここで 1 回コピー。
  void pushCameraFrame(const uint8_t* data, int format, int width, int height, int stride,
                       int64_t ts_ms);

  // 符号化済み H.264 (AnnexB) 投入 (capi db_core_on_encoded_frame / Windows は encoder_win
  // から; 任意スレッド可)。fMP4 化して /stream.mp4 購読者へ配る。codec=mjpeg 中は無視。
  void pushEncodedFrame(const uint8_t* annexb, size_t len, bool key, int64_t ts_ms);

  // 殻がエンコーダを回すべきか (capi db_core_video_encoder_wanted; 任意スレッド可)。
  // config camera.codec が h264/auto かつ /stream.mp4 購読者 > 0 の時 true。
  bool videoEncoderWanted();

  std::string statusJson();        // /api/status と同じ内容
  std::string debugJson();         // /api/debug (アドレス/wifi/電池/触発/疎通履歴)
  std::string configJson();        // materialize 済み設定全文

  // --- 配対 (発見/招待; capi db_core_pairing_*) ---
  std::string pairingJson();       // {paired, self:{QR 情報}, pair_qr, pending:{待機一覧+モード}}
  bool foundCluster();             // 未配対時: この端末を親機にする (新規 PSK 生成)
  void joinCluster(const std::string& host, const std::string& pin);  // PIN 参加 (未配対機側)
  void setPairingMode(int seconds);          // 配対モード ON (配対済み機側)
  void inviteDevice(const std::string& id);  // 待機デバイスを承認・招待
  // QR/入力から得た addr+id+pk へ直接招待 (発見前でも可 — QR スキャン)
  void inviteDeviceDirect(const std::string& addr, const std::string& id, const std::string& pk);
  // 設定書き込み (管理 API /api/config と同経路)。value_json はパース不能なら JSON 文字列扱い。
  void setConfigKey(const std::string& key, const std::string& value_json);
  const std::string& nodeId() const { return node_id_; }
  Runloop& loop();                 // テスト駆動用

  struct Impl;

 private:
  std::string node_id_;
  std::unique_ptr<Impl> impl_;
};

}  // namespace db
