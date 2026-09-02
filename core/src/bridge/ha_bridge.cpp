
#include "bridge/ha_bridge.h"

#include <map>

#include "util/log.h"

namespace db {

namespace {
constexpr const char* kTag = "ha_bridge";



std::string sanitizeId(const std::string& s) {
  std::string out;
  out.reserve(s.size());
  for (char c : s) {
    const bool ok = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                    c == '_' || c == '-';
    out.push_back(ok ? c : '_');
  }
  return out;
}
}  // namespace

HaBridge::HaBridge(Runloop& loop, Hooks hooks) : loop_(loop), hooks_(std::move(hooks)) {}

HaBridge::~HaBridge() { stopClient(false); }

cJSON* HaBridge::cfgAt(const std::string& dotpath) const {
  cJSON* cur = cfg_.get();
  size_t pos = 0;
  while (cur && pos <= dotpath.size()) {
    size_t dot = dotpath.find('.', pos);
    std::string part =
        dotpath.substr(pos, dot == std::string::npos ? std::string::npos : dot - pos);
    cur = json::get(cur, part.c_str());
    if (dot == std::string::npos) return cur;
    pos = dot + 1;
  }
  return cur;
}

std::string HaBridge::labelJa(const cJSON* label_obj) const {
  if (!label_obj) return "";
  std::string v = json::getString(label_obj, "ja");
  if (v.empty()) v = json::getString(label_obj, "en");
  if (v.empty() && label_obj->child && cJSON_IsString(label_obj->child))
    v = label_obj->child->valuestring;
  return v;
}



void HaBridge::configure(const std::string& cfg_json, const std::string& node_id, bool active) {
  const bool cfg_changed = cfg_json != cfg_json_;
  if (cfg_changed) {
    cfg_ = json::parse(cfg_json);
    if (!cfg_) cfg_ = json::obj();
    cfg_json_ = cfg_json;
  }
  node_id_ = node_id;

  cJSON* mq = cfgAt("integrations.mqtt");
  base_ = json::getString(mq, "base_topic", "doorbell");
  prefix_ = json::getString(mq, "discovery_prefix", "homeassistant");

  MqttClient::Options mo;
  mo.host = json::getString(mq, "host");
  mo.port = static_cast<uint16_t>(json::getInt(mq, "port", 1883));
  mo.client_id = "doorbell-" + node_id_.substr(0, 8);
  mo.username = json::getString(mq, "user");

  mo.password = json::getString(mq, "pass");
  mo.keepalive_s = 30;
  mo.will_topic = base_ + "/bridge/availability";
  mo.will_payload = "offline";
  mo.will_retain = true;

  if (!active || mo.host.empty()) {
    if (client_) DB_LOGI(kTag, "bridge stopped because this node is not leader or mqtt.host is unset");
    stopClient(true);
    active_ = false;
    return;
  }
  active_ = true;

  const bool opts_changed =
      mo.host != mopts_.host || mo.port != mopts_.port || mo.username != mopts_.username ||
      mo.password != mopts_.password || mo.will_topic != mopts_.will_topic;
  if (!client_ || opts_changed) {
    stopClient(true);
    startClient(mo);
    return;
  }

  if (cfg_changed && connected_) {
    publishDiscovery();
    publishState();
  }
}

void HaBridge::startClient(const MqttClient::Options& mo) {
  mopts_ = mo;
  MqttClient::Callbacks cbs;
  cbs.on_connected = [this] { onConnected(); };
  cbs.on_disconnected = [this] { connected_ = false; };
  cbs.on_message = [this](const std::string& t, const std::string& p, bool) { onMessage(t, p); };
  client_.reset(new MqttClient(loop_, mo, std::move(cbs)));
  client_->start();
  DB_LOGI(kTag, "bridge started at " + mo.host + ":" + std::to_string(mo.port));
}

void HaBridge::stopClient(bool graceful) {
  if (!client_) return;


  if (graceful && connected_) pub(base_ + "/bridge/availability", "offline", true);
  client_->stop();
  client_.reset();
  connected_ = false;
}

void HaBridge::stop() {
  stopClient(true);
  active_ = false;
}

std::string HaBridge::mqttStatus() const {
  if (!active_ || !client_) return "inactive";
  return connected_ ? "connected" : "disconnected";
}



void HaBridge::onConnected() {
  connected_ = true;
  pub(base_ + "/bridge/availability", "online", true);
  publishDiscovery();
  publishState();

  client_->subscribe(prefix_ + "/status");
  client_->subscribe(base_ + "/+/reply/set");
  client_->subscribe(base_ + "/cmd/ack");
}

void HaBridge::pub(const std::string& topic, const std::string& payload, bool retain) {
  if (client_) client_->publish(topic, payload, retain);
}

// ---------------------------------------------------------------- Discovery

void HaBridge::addAvailability(cJSON* o, const std::string& door_id) {
  cJSON* arr = json::addArr(o, "availability");
  cJSON* b = json::pushObj(arr);
  json::set(b, "topic", base_ + "/bridge/availability");
  if (!door_id.empty()) {
    cJSON* d = json::pushObj(arr);
    json::set(d, "topic", base_ + "/" + door_id + "/availability");
  }
  json::set(o, "availability_mode", "all");
}

void HaBridge::setDoorDevice(cJSON* o, const std::string& door_id) {
  cJSON* door = cfgAt("doors." + door_id);
  cJSON* dev = json::addObj(o, "device");
  cJSON* ids = json::addArr(dev, "identifiers");
  json::push(ids, json::Doc(cJSON_CreateString(("doorbell_" + sanitizeId(door_id)).c_str())));
  std::string name = labelJa(json::get(door, "label"));
  json::set(dev, "name", name.empty() ? door_id : name);
  json::set(dev, "manufacturer", "ox");
  json::set(dev, "model", "DoorStation");
  const std::string bld = json::getString(door, "building");
  if (!bld.empty()) {
    std::string area = labelJa(json::get(cfgAt("buildings." + bld), "label"));
    if (!area.empty()) json::set(dev, "suggested_area", area);
  }
}

void HaBridge::publishDiscovery() {

  cJSON* doors = json::get(cfg_.get(), "doors");
  cJSON* it = nullptr;
  cJSON_ArrayForEach(it, doors) {
    if (!it->string) continue;
    const std::string did = it->string;
    const std::string sid = sanitizeId(did);
    {
      auto o = json::obj();
      json::set(o.get(), "name", "呼び鈴");
      cJSON* types = json::addArr(o.get(), "event_types");
      json::push(types, json::Doc(cJSON_CreateString("press")));
      json::set(o.get(), "device_class", "doorbell");
      json::set(o.get(), "state_topic", base_ + "/" + did + "/event");
      addAvailability(o.get(), did);
      json::set(o.get(), "unique_id", "doorbell_" + sid + "_event");
      json::set(o.get(), "object_id", "doorbell_" + sid);
      setDoorDevice(o.get(), did);
      pub(prefix_ + "/event/doorbell_" + sid + "/config", json::dump(o.get()), true);
    }
    {
      auto o = json::obj();
      json::set(o.get(), "name", "動体検知");
      json::set(o.get(), "device_class", "motion");
      json::set(o.get(), "state_topic", base_ + "/" + did + "/motion");
      json::set(o.get(), "payload_on", "ON");
      json::set(o.get(), "off_delay", static_cast<int64_t>(30));
      addAvailability(o.get(), did);
      json::set(o.get(), "unique_id", "doorbell_" + sid + "_motion");
      json::set(o.get(), "object_id", "doorbell_" + sid + "_motion");
      setDoorDevice(o.get(), did);
      pub(prefix_ + "/binary_sensor/doorbell_" + sid + "_motion/config", json::dump(o.get()),
          true);
    }
    {

      auto o = json::obj();
      json::set(o.get(), "name", "訪客言語");
      json::set(o.get(), "state_topic", base_ + "/" + did + "/attrs");
      json::set(o.get(), "value_template", "{{ value_json.visitor_lang }}");
      json::set(o.get(), "json_attributes_topic", base_ + "/" + did + "/attrs");
      addAvailability(o.get(), did);
      json::set(o.get(), "unique_id", "doorbell_" + sid + "_visitor_lang");
      json::set(o.get(), "object_id", "doorbell_" + sid + "_visitor_lang");
      setDoorDevice(o.get(), did);
      pub(prefix_ + "/sensor/doorbell_" + sid + "_visitor_lang/config", json::dump(o.get()),
          true);
    }
  }


  cJSON* devs = json::get(cfg_.get(), "devices");
  cJSON_ArrayForEach(it, devs) {
    if (!it->string) continue;
    const std::string nid = it->string;
    const std::string sid = "doorbell_node_" + sanitizeId(nid.substr(0, 8));
    auto o = json::obj();
    std::string name = json::getString(it, "name");
    json::set(o.get(), "name", name.empty() ? nid.substr(0, 8) : name);
    json::set(o.get(), "device_class", "connectivity");
    json::set(o.get(), "state_topic", base_ + "/node/" + nid + "/availability");
    json::set(o.get(), "payload_on", "online");
    json::set(o.get(), "payload_off", "offline");
    addAvailability(o.get(), "");
    json::set(o.get(), "unique_id", sid);
    json::set(o.get(), "object_id", sid);
    cJSON* dev = json::addObj(o.get(), "device");
    cJSON* ids = json::addArr(dev, "identifiers");
    json::push(ids, json::Doc(cJSON_CreateString(sid.c_str())));
    json::set(dev, "name", name.empty() ? nid.substr(0, 8) : name);
    json::set(dev, "manufacturer", "ox");
    json::set(dev, "model", "DoorStation");
    pub(prefix_ + "/binary_sensor/" + sid + "/config", json::dump(o.get()), true);
  }


  {
    auto o = json::obj();
    json::set(o.get(), "name", "緊急事態");
    json::set(o.get(), "device_class", "safety");
    json::set(o.get(), "state_topic", base_ + "/emergency");
    addAvailability(o.get(), "");
    json::set(o.get(), "unique_id", "doorbell_emergency");
    json::set(o.get(), "object_id", "doorbell_emergency");
    cJSON* dev = json::addObj(o.get(), "device");
    cJSON* ids = json::addArr(dev, "identifiers");
    json::push(ids, json::Doc(cJSON_CreateString("doorbell_bridge")));
    json::set(dev, "name", "Doorbell Mesh");
    json::set(dev, "manufacturer", "ox");
    json::set(dev, "model", "MeshBridge");
    pub(prefix_ + "/binary_sensor/doorbell_emergency/config", json::dump(o.get()), true);
  }


  {
    auto o = json::obj();
    json::set(o.get(), "name", "Doorbell Bridge");
    json::set(o.get(), "device_class", "connectivity");
    json::set(o.get(), "state_topic", base_ + "/bridge/availability");
    json::set(o.get(), "payload_on", "online");
    json::set(o.get(), "payload_off", "offline");

    json::set(o.get(), "unique_id", "doorbell_bridge_online");
    json::set(o.get(), "object_id", "doorbell_bridge_online");
    cJSON* dev = json::addObj(o.get(), "device");
    cJSON* ids = json::addArr(dev, "identifiers");
    json::push(ids, json::Doc(cJSON_CreateString("doorbell_bridge")));
    json::set(dev, "name", "Doorbell Mesh");
    json::set(dev, "manufacturer", "ox");
    json::set(dev, "model", "MeshBridge");
    pub(prefix_ + "/binary_sensor/doorbell_bridge_online/config", json::dump(o.get()), true);
  }
}



void HaBridge::publishState() {
  std::map<std::string, bool> alive;
  if (hooks_.node_alive) {
    for (const auto& p : hooks_.node_alive()) alive[p.first] = p.second;
  }
  alive[node_id_] = true;

  cJSON* devs = json::get(cfg_.get(), "devices");
  cJSON* it = nullptr;
  cJSON_ArrayForEach(it, devs) {
    if (!it->string) continue;
    const std::string nid = it->string;
    const auto a = alive.find(nid);
    const bool on = a != alive.end() && a->second;
    pub(base_ + "/node/" + nid + "/availability", on ? "online" : "offline", true);
  }

  cJSON* doors = json::get(cfg_.get(), "doors");
  cJSON_ArrayForEach(it, doors) {
    if (!it->string) continue;
    const std::string did = it->string;
    bool on = false;
    cJSON* d = nullptr;
    cJSON_ArrayForEach(d, devs) {
      if (!d->string || json::getString(d, "door") != did) continue;
      const auto a = alive.find(d->string);
      if (a != alive.end() && a->second) on = true;
    }
    pub(base_ + "/" + did + "/availability", on ? "online" : "offline", true);
  }
  publishEmergency();
  publishDoorAttrs();
}


void HaBridge::publishEmergency() {
  const bool on = hooks_.emergency_active && hooks_.emergency_active();
  pub(base_ + "/emergency", on ? "ON" : "OFF", true);
}

std::string HaBridge::visitorLangOf(const std::string& door_id) const {
  if (!hooks_.visitor_langs) return "ja";
  for (const auto& kv : hooks_.visitor_langs())
    if (kv.first == door_id) return kv.second;
  return "ja";
}



void HaBridge::publishDoorAttrs(const std::string& door_id) {
  auto one = [this](const std::string& did) {
    auto o = json::obj();
    json::set(o.get(), "visitor_lang", visitorLangOf(did));
    pub(base_ + "/" + did + "/attrs", json::dump(o.get()), true);
  };
  if (!door_id.empty()) {
    one(door_id);
    return;
  }
  cJSON* doors = json::get(cfg_.get(), "doors");
  cJSON* it = nullptr;
  cJSON_ArrayForEach(it, doors) {
    if (it->string) one(it->string);
  }
}



void HaBridge::onEvent(const EventRecord& ev) {
  if (!client_ || !connected_) return;
  if (ev.type == "press") {
    if (ev.door.empty()) return;


    auto o = json::obj();
    json::set(o.get(), "event_type", "press");
    auto p = json::parse(ev.payload_json.empty() ? "{}" : ev.payload_json);
    if (p) {
      const std::string purpose = json::getString(p.get(), "purpose");
      const std::string vlang = json::getString(p.get(), "visitor_lang");
      if (!purpose.empty()) json::set(o.get(), "purpose", purpose);
      if (!vlang.empty()) json::set(o.get(), "visitor_lang", vlang);
    }
    pub(base_ + "/" + ev.door + "/event", json::dump(o.get()), false);
  } else if (ev.type == "visitor_lang") {
    if (ev.door.empty()) return;
    publishDoorAttrs(ev.door);
  } else if (ev.type == "motion") {
    if (ev.door.empty()) return;
    pub(base_ + "/" + ev.door + "/motion", "ON", false);
  } else if (ev.type == "offline" || ev.type == "online") {
    const std::string& nid = ev.device;
    if (nid.empty()) return;
    const bool on = ev.type == "online";
    pub(base_ + "/node/" + nid + "/availability", on ? "online" : "offline", true);

    const std::string door = json::getString(cfgAt("devices." + nid), "door");
    if (!door.empty()) pub(base_ + "/" + door + "/availability", on ? "online" : "offline", true);
  } else if (ev.type == "emergency" || ev.type == "emergency_cancel") {

    publishEmergency();
  } else if (ev.type == "dtmf_action") {
    auto p = json::parse(ev.payload_json);
    if (!p || json::getString(p.get(), "type") != "ha_command") return;
    const std::string cmd = sanitizeId(json::getString(p.get(), "command"));
    if (cmd.empty()) return;
    std::string door = json::getString(p.get(), "door");
    if (door.empty() || door == "self") door = ev.door;
    auto o = json::obj();
    json::set(o.get(), "door", door);
    pub(base_ + "/cmd/" + cmd, json::dump(o.get()), false);
  }
}



void HaBridge::onMessage(const std::string& topic, const std::string& payload) {
  if (topic == prefix_ + "/status") {

    if (payload == "online" && connected_) {
      DB_LOGI(kTag, "HA is online; republishing discovery and state");
      pub(base_ + "/bridge/availability", "online", true);
      publishDiscovery();
      publishState();
    }
    return;
  }
  if (topic == base_ + "/cmd/ack") {
    DB_LOGI(kTag, "cmd ack: " + payload);
    return;
  }
  // <base>/<door_id>/reply/set
  const std::string head = base_ + "/";
  const std::string tail = "/reply/set";
  if (topic.size() > head.size() + tail.size() && topic.compare(0, head.size(), head) == 0 &&
      topic.compare(topic.size() - tail.size(), tail.size(), tail) == 0) {
    const std::string door = topic.substr(head.size(), topic.size() - head.size() - tail.size());
    if (door.empty() || door.find('/') != std::string::npos) return;
    if (!hooks_.on_reply) return;

    auto scoped = json::parse(payload);
    bool accepted = false;
    if (scoped && cJSON_IsObject(scoped.get())) {
      const std::string reply_id = json::getString(scoped.get(), "reply_id");
      const std::string text = json::getString(scoped.get(), "text");
      const std::string call_id = json::getString(scoped.get(), "call_id");
      const int revision = static_cast<int>(json::getInt(scoped.get(), "stage_revision", -1));
      if (!call_id.empty() && revision >= 0)
        accepted = hooks_.on_reply(reply_id, text, door, call_id, revision);
    } else {
      cJSON* qr = json::get(cfgAt("quick_replies"), payload.c_str());
      accepted = qr ? hooks_.on_reply(payload, "", door, "", -1)
                    : hooks_.on_reply("", payload, door, "", -1);
    }
    if (!accepted)
      DB_LOGW(kTag, "quick reply rejected because the MQTT command was stale or unscoped");
  }
}

}  // namespace db
