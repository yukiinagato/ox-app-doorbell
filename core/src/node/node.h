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

  // ボタン押下 (門口機 UI / /api/press / panel から)
  void press(const std::string& door_id);
  // クイック返信の配送 (reply_id は config quick_replies のキー、free_text 優先)
  // door_id 空 = 最新 press の door。via: "web" | "telegram" | "mqtt" | "app"
  void sendQuickReply(const std::string& reply_id, const std::string& free_text,
                      const std::string& door_id, const std::string& via);

  // SOS 緊急モード。active=true で発報 / false で解除 (emergency / emergency_cancel
  // イベントを追加 — 全ノードへ複製され、各ノードが {"t":"emergency"} を uiNotify する)。
  // via: "panel" | "web" | "admin"。PIN 検証 (解除時の kiosk PIN 等) は呼び出し側の責務。
  void setEmergency(bool active, const std::string& via);

  // カメラ生フレーム投入 (capi db_core_on_camera_frame / 採集スレッドから; 任意スレッド可)。
  // format: doorbell.h と同じ 0=NV21, 1=NV12, 2=YUY2, 3=BGRA。データはここで 1 回コピー。
  void pushCameraFrame(const uint8_t* data, int format, int width, int height, int stride,
                       int64_t ts_ms);

  std::string statusJson();        // /api/status と同じ内容
  std::string configJson();        // materialize 済み設定全文
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
