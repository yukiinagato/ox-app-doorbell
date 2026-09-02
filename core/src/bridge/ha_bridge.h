










// Home Assistant MQTT bridge. Only the elected mqtt_bridge leader connects and publishes
// retained discovery/state. All methods and MQTT callbacks run on Runloop.
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


    std::function<bool(const std::string& reply_id, const std::string& free_text,
                       const std::string& door_id, const std::string& call_id,
                       int stage_revision)>
        on_reply;

    std::function<std::vector<std::pair<std::string, bool>>()> node_alive;

    std::function<bool()> emergency_active;


    std::function<std::vector<std::pair<std::string, std::string>>()> visitor_langs;
  };

  HaBridge(Runloop& loop, Hooks hooks);
  ~HaBridge();




  void configure(const std::string& cfg_json, const std::string& node_id, bool active);



  void onEvent(const EventRecord& ev);


  void stop();


  std::string mqttStatus() const;

 private:
  void startClient(const MqttClient::Options& mo);
  void stopClient(bool graceful);
  void onConnected();
  void onMessage(const std::string& topic, const std::string& payload);
  void publishDiscovery();
  void publishState();
  void publishEmergency();

  void publishDoorAttrs(const std::string& door_id = "");
  std::string visitorLangOf(const std::string& door_id) const;
  void pub(const std::string& topic, const std::string& payload, bool retain);


  void addAvailability(cJSON* o, const std::string& door_id);
  void setDoorDevice(cJSON* o, const std::string& door_id);
  std::string labelJa(const cJSON* label_obj) const;
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
};

}  // namespace db
