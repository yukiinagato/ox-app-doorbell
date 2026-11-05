// Home Assistant MQTT bridge. Only the elected mqtt_bridge leader connects and publishes
// retained discovery/state. All methods and MQTT callbacks run on Runloop.
//
// Commands that arrive over MQTT are authorized by the broker: any client that may publish
// under <base_topic>/ can use them. Commands that change cluster state beyond a quick reply
// (SOS trigger/clear, announcements) are therefore disabled unless an administrator enables
// integrations.ha.allow_sos_control or integrations.ha.allow_notice_control.
#pragma once

#include <cstdint>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "bridge/mqtt_client.h"
#include "events/events.h"
#include "util/common.h"
#include "util/json.h"
#include "util/runloop.h"

namespace db {

class HaBridge {
 public:
  // Snapshots larger than this are not published. The broker-side packet cap is 256 KiB.
  static constexpr size_t kMaxSnapshotBytes = 200 * 1024;

  struct Hooks {
    std::function<void(const std::string&)> on_operation_ack;
    std::function<void()> on_operation_disconnect;

    std::function<bool(const std::string& reply_id, const std::string& free_text,
                       const std::string& door_id, const std::string& call_id,
                       int stage_revision)>
        on_reply;

    std::function<std::vector<std::pair<std::string, bool>>()> node_alive;

    std::function<bool()> emergency_active;

    std::function<std::vector<std::pair<std::string, std::string>>()> visitor_langs;

    // Localized text for a core.ha.* key in the bridge language. Missing hook or key: the key.
    std::function<std::string(const std::string& key)> text;
    // Bridge language for entity names and door/quick-reply labels (ja, en or zh).
    std::function<std::string()> language;
    // idle | ringing | in_call for a door.
    std::function<std::string(const std::string& door)> call_state;
    // The live call of a door as {"call_id":..,"stage_revision":n}, or empty when idle.
    std::function<std::string(const std::string& door)> active_call;
    // The newest finished call of a door as a call-log row object, or empty.
    std::function<std::string(const std::string& door)> last_call;
    // Unseen missed calls of a door, consistent with the device-local seen watermark.
    std::function<int64_t(const std::string& door)> unseen_missed;
    // Fetches the current JPEG of the door's camera; the callback receives empty bytes when
    // unavailable. The callback runs on Runloop.
    std::function<void(const std::string& door, std::function<void(Bytes)> done)> fetch_snapshot;
    // {"active":bool,"source":id,"source_name":..,"door":..,"via":..,
    //  "triggered_at":ms,"cleared_at":ms}
    std::function<std::string()> emergency_info;
    // Starts or clears SOS on behalf of MQTT. Only called when allow_sos_control is on.
    std::function<bool(bool active)> set_emergency;
    // Publishes (non-empty) or clears (empty) the cluster announcement. Only called when
    // allow_notice_control is on.
    std::function<bool(const std::string& text)> set_notice;
  };

  HaBridge(Runloop& loop, Hooks hooks);
  ~HaBridge();

  void configure(const std::string& cfg_json, const std::string& node_id, bool active);

  void onEvent(const EventRecord& ev);
  // Call history or the seen watermark changed: republish per-door call state and history.
  void onCallLogChanged();
  // Called exactly once after the authority's durable dispatch acquisition, never from replay.
  bool dispatchOperation(const std::string& door, const std::string& command,
                         const std::string& operation_id, const std::string& authority,
                         const std::string& binding, const std::string& actuator = "",
                         const std::string& command_digest = "");
  static std::string operationBinding(const std::string& host, uint16_t port,
                                      const std::string& base_topic);
  bool operationReady(const std::string& binding) const;

  void stop();

  std::string mqttStatus() const;

  // Valid JPEG no larger than kMaxSnapshotBytes.
  static bool snapshotPublishable(const Bytes& jpeg);

 private:
  void startClient(const MqttClient::Options& mo);
  void stopClient(bool graceful);
  void onConnected();
  void onMessage(const std::string& topic, const std::string& payload, bool retained);
  void publishDiscovery();
  void publishState();
  void publishEmergency();
  void publishCallState(const std::string& door_id = "");
  void publishNotice();
  void publishSnapshot(const std::string& door_id);
  void handleQuickReplySelect(const std::string& door, const std::string& label);

  void publishDoorAttrs(const std::string& door_id = "");
  std::string visitorLangOf(const std::string& door_id) const;
  void pub(const std::string& topic, const std::string& payload, bool retain);
  void pubConfig(const std::string& component, const std::string& object_id, cJSON* body);
  void removeConfig(const std::string& component, const std::string& object_id);

  void addAvailability(cJSON* o, const std::string& door_id);
  void setDoorDevice(cJSON* o, const std::string& door_id);
  void setMeshDevice(cJSON* o);
  std::string label(const cJSON* label_obj) const;
  std::string text(const std::string& key) const;
  std::string lang() const;
  bool allowSosControl() const;
  bool allowNoticeControl() const;
  std::vector<std::pair<std::string, std::string>> quickReplyOptions() const;
  cJSON* cfgAt(const std::string& dotpath) const;

  Runloop& loop_;
  Hooks hooks_;
  json::Doc cfg_;
  std::string cfg_json_;
  std::string node_id_;
  std::string base_;
  std::string prefix_;
  MqttClient::Options mopts_;
  std::unique_ptr<MqttClient> client_;
  bool active_ = false;
  bool connected_ = false;
  // Reply text per call_id for the last-call attributes (bounded, newest last).
  std::deque<std::pair<std::string, std::string>> reply_texts_;
  std::map<std::string, int64_t> snapshot_at_;  // door -> wall ms of the last published image
  uint64_t snapshot_generation_ = 0;
};

}  // namespace db
