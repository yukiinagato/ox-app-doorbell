// HA (Home Assistant) MQTT ブリッジ — mqtt_bridge duty の leader ノードだけが
// Mosquitto へ接続し、MQTT Discovery で門铃実体を自動登録、イベントを topic へ流し、
// 返信 (reply/set) や命令回執を受ける。topic 設計は計画書の表が唯一事実源
// (docs/config-schema.md「MQTT (Phase 2)」参照)。
//   - 有効条件: config integrations.mqtt.host 非空 かつ mesh.isLeader("mqtt_bridge")
//     — 判定は Node 側 (configure の active 引数)。リーダー交代/設定変更で再評価される。
//   - 接続時: LWT=<base>/bridge/availability=offline(retain) → online(retain) 発行 →
//     全 discovery (retain) → 現在状態 (door/node availability) → 購読。
//   - スナップショット/カメラは MQTT に載せない (実画は go2rtc、静止画は HA generic camera
//     が子機の /snapshot.jpg を直接取る — deploy/ha/ 参照)。
// スレッド: 全 API は Runloop 上でのみ (MqttClient のコールバックも Runloop へ届く)。
#pragma once

#include <functional>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "bridge/mqtt_client.h"
#include "events/events.h"
#include "util/json.h"
#include "util/runloop.h"

namespace db {

class HaBridge {
 public:
  struct Hooks {
    // <base>/<door_id>/reply/set 受信 → クイック返信配送 (Node::quickReply via="mqtt")。
    // payload が quick_replies のキーなら reply_id、でなければ free_text で渡す。
    std::function<void(const std::string& reply_id, const std::string& free_text,
                       const std::string& door_id)>
        on_reply;
    // 各ノードの生死スナップショット (node_id, online) — Node が mesh->peers() から作る
    std::function<std::vector<std::pair<std::string, bool>>()> node_alive;
  };

  HaBridge(Runloop& loop, Hooks hooks);
  ~HaBridge();

  // 有効条件の再評価 (起動時 / config 変更 / leader 交代時に Node から呼ぶ)。
  // cfg_json = materialize 済み設定全文。active = host 非空 かつ 自分が leader。
  // 接続設定が変われば再接続、discovery 内容だけ変われば接続のまま再発行する。
  void configure(const std::string& cfg_json, const std::string& node_id, bool active);

  // Node::onEvent から (リーダー時のみ)。press/motion/offline/online/dtmf_action を発行。
  void onEvent(const EventRecord& ev);

  // graceful 停止: availability=offline (retain) を吐いてから DISCONNECT (Node::stop から)。
  void stop();

  // status_json 用: "connected" | "disconnected" | "inactive"
  std::string mqttStatus() const;

 private:
  void startClient(const MqttClient::Options& mo);
  void stopClient(bool graceful);
  void onConnected();
  void onMessage(const std::string& topic, const std::string& payload);
  void publishDiscovery();
  void publishState();
  void pub(const std::string& topic, const std::string& payload, bool retain);

  // discovery 部品
  void addAvailability(cJSON* o, const std::string& door_id);  // door_id 空 = bridge のみ
  void setDoorDevice(cJSON* o, const std::string& door_id);
  std::string labelJa(const cJSON* label_obj) const;
  cJSON* cfgAt(const std::string& dotpath) const;

  Runloop& loop_;
  Hooks hooks_;
  json::Doc cfg_;          // configure で渡された設定ツリー
  std::string cfg_json_;   // 同・原文 (変更検出用)
  std::string node_id_;
  std::string base_;       // integrations.mqtt.base_topic (既定 doorbell)
  std::string prefix_;     // integrations.mqtt.discovery_prefix (既定 homeassistant)
  MqttClient::Options mopts_;  // 現行クライアントの接続設定 (変更検出用)
  std::unique_ptr<MqttClient> client_;
  bool active_ = false;
  bool connected_ = false;
};

}  // namespace db
