// HA MQTT ブリッジの実装 (ha_bridge.h 参照)。
#include "bridge/ha_bridge.h"

#include <map>

#include "util/log.h"

namespace db {

namespace {
constexpr const char* kTag = "ha_bridge";

// object_id/unique_id/topic 断片用 — ASCII [0-9A-Za-z_-] 以外は '_' に潰す
// (日本語は name にだけ載せる方針)。
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

// ---------------------------------------------------------------- 構成

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
  // MVP は平文 pass — TODO(Phase2 後半): secure_store (pass_ref) 経由に切り替え (sip と同様)
  mo.password = json::getString(mq, "pass");
  mo.keepalive_s = 30;
  mo.will_topic = base_ + "/bridge/availability";
  mo.will_payload = "offline";
  mo.will_retain = true;

  if (!active || mo.host.empty()) {
    if (client_) DB_LOGI(kTag, "ブリッジ停止 (leader でない / mqtt.host 未設定)");
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
    return;  // discovery/状態は on_connected で発行される
  }
  // 接続設定は同じで内容だけ変わった → 接続中なら retain 済み discovery/状態を上書き再発行
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
  DB_LOGI(kTag, "ブリッジ開始 → " + mo.host + ":" + std::to_string(mo.port));
}

void HaBridge::stopClient(bool graceful) {
  if (!client_) return;
  // graceful なら LWT の代わりに自分で offline (retain) を吐いてから DISCONNECT
  // (DISCONNECT では LWT が発火しないため)。stop() が送信残をフラッシュしてくれる。
  if (graceful && connected_) pub(base_ + "/bridge/availability", "offline", true);
  client_->stop();  // コールバック無効化 + IO スレッド join
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

// ---------------------------------------------------------------- 接続時

void HaBridge::onConnected() {
  connected_ = true;
  pub(base_ + "/bridge/availability", "online", true);
  publishDiscovery();
  publishState();
  // 購読は接続毎に張り直す (クライアントは clean session)
  client_->subscribe(prefix_ + "/status");        // HA 再起動検知 → 再発行
  client_->subscribe(base_ + "/+/reply/set");     // クイック返信下発
  client_->subscribe(base_ + "/cmd/ack");         // 開錠等の命令回執 (現状ログのみ)
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
  json::set(dev, "manufacturer", "Keihan");
  json::set(dev, "model", "DoorStation");
  const std::string bld = json::getString(door, "building");
  if (!bld.empty()) {
    std::string area = labelJa(json::get(cfgAt("buildings." + bld), "label"));
    if (!area.empty()) json::set(dev, "suggested_area", area);
  }
}

void HaBridge::publishDiscovery() {
  // --- 各 door: event (呼び鈴) + binary_sensor (動体検知) ---
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
      json::set(o.get(), "off_delay", static_cast<int64_t>(30));  // OFF は発行しない — 自動復帰
      addAvailability(o.get(), did);
      json::set(o.get(), "unique_id", "doorbell_" + sid + "_motion");
      json::set(o.get(), "object_id", "doorbell_" + sid + "_motion");
      setDoorDevice(o.get(), did);
      pub(prefix_ + "/binary_sensor/doorbell_" + sid + "_motion/config", json::dump(o.get()),
          true);
    }
  }

  // --- 各 device: connectivity (防盗の「端末オフライン」を HA 実体化) ---
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
    addAvailability(o.get(), "");  // bridge のみ (端末断そのものが状態なので door は付けない)
    json::set(o.get(), "unique_id", sid);
    json::set(o.get(), "object_id", sid);
    cJSON* dev = json::addObj(o.get(), "device");
    cJSON* ids = json::addArr(dev, "identifiers");
    json::push(ids, json::Doc(cJSON_CreateString(sid.c_str())));
    json::set(dev, "name", name.empty() ? nid.substr(0, 8) : name);
    json::set(dev, "manufacturer", "Keihan");
    json::set(dev, "model", "DoorStation");
    pub(prefix_ + "/binary_sensor/" + sid + "/config", json::dump(o.get()), true);
  }

  // --- SOS 緊急モード (組込動作 — quiet_hours/ルール非依存。HA 側でライト/サイレン連動) ---
  {
    auto o = json::obj();
    json::set(o.get(), "name", "緊急事態");
    json::set(o.get(), "device_class", "safety");
    json::set(o.get(), "state_topic", base_ + "/emergency");
    addAvailability(o.get(), "");  // bridge のみ
    json::set(o.get(), "unique_id", "doorbell_emergency");
    json::set(o.get(), "object_id", "doorbell_emergency");
    cJSON* dev = json::addObj(o.get(), "device");
    cJSON* ids = json::addArr(dev, "identifiers");
    json::push(ids, json::Doc(cJSON_CreateString("doorbell_bridge")));
    json::set(dev, "name", "Doorbell Mesh");
    json::set(dev, "manufacturer", "Keihan");
    json::set(dev, "model", "MeshBridge");
    pub(prefix_ + "/binary_sensor/doorbell_emergency/config", json::dump(o.get()), true);
  }

  // --- ブリッジ生存 sensor (deploy/ha の看門狗 automation が参照) ---
  {
    auto o = json::obj();
    json::set(o.get(), "name", "Doorbell Bridge");
    json::set(o.get(), "device_class", "connectivity");
    json::set(o.get(), "state_topic", base_ + "/bridge/availability");
    json::set(o.get(), "payload_on", "online");
    json::set(o.get(), "payload_off", "offline");
    // availability は付けない — LWT の offline を「off 状態」として見せる (unavailable ではなく)
    json::set(o.get(), "unique_id", "doorbell_bridge_online");
    json::set(o.get(), "object_id", "doorbell_bridge_online");
    cJSON* dev = json::addObj(o.get(), "device");
    cJSON* ids = json::addArr(dev, "identifiers");
    json::push(ids, json::Doc(cJSON_CreateString("doorbell_bridge")));
    json::set(dev, "name", "Doorbell Mesh");
    json::set(dev, "manufacturer", "Keihan");
    json::set(dev, "model", "MeshBridge");
    pub(prefix_ + "/binary_sensor/doorbell_bridge_online/config", json::dump(o.get()), true);
  }
}

// ---------------------------------------------------------------- 現在状態

void HaBridge::publishState() {
  std::map<std::string, bool> alive;
  if (hooks_.node_alive) {
    for (const auto& p : hooks_.node_alive()) alive[p.first] = p.second;
  }
  alive[node_id_] = true;  // 自分 (leader) は生きている

  cJSON* devs = json::get(cfg_.get(), "devices");
  cJSON* it = nullptr;
  cJSON_ArrayForEach(it, devs) {
    if (!it->string) continue;
    const std::string nid = it->string;
    const auto a = alive.find(nid);
    const bool on = a != alive.end() && a->second;
    pub(base_ + "/node/" + nid + "/availability", on ? "online" : "offline", true);
  }
  // door の可用性 = 担当 door_station の生死
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
}

// SOS 現在状態 (Node が hlc 最大側で計算) を retain で発行 — 接続/再発行/遷移時に呼ぶ
void HaBridge::publishEmergency() {
  const bool on = hooks_.emergency_active && hooks_.emergency_active();
  pub(base_ + "/emergency", on ? "ON" : "OFF", true);
}

// ---------------------------------------------------------------- イベント → 発行

void HaBridge::onEvent(const EventRecord& ev) {
  if (!client_ || !connected_) return;  // 未接続中のイベントは流さない (retain 状態は再接続時に再発行)
  if (ev.type == "press") {
    if (ev.door.empty()) return;
    pub(base_ + "/" + ev.door + "/event", "{\"event_type\":\"press\"}", false);
  } else if (ev.type == "motion") {
    if (ev.door.empty()) return;
    pub(base_ + "/" + ev.door + "/motion", "ON", false);  // OFF は off_delay で自動復帰
  } else if (ev.type == "offline" || ev.type == "online") {
    const std::string& nid = ev.device;
    if (nid.empty()) return;
    const bool on = ev.type == "online";
    pub(base_ + "/node/" + nid + "/availability", on ? "online" : "offline", true);
    // その node が door 担当なら door の可用性も更新
    const std::string door = json::getString(cfgAt("devices." + nid), "door");
    if (!door.empty()) pub(base_ + "/" + door + "/availability", on ? "online" : "offline", true);
  } else if (ev.type == "emergency" || ev.type == "emergency_cancel") {
    // 状態は Node が hlc 最大側で計算済み (このイベント処理より先に更新される) — 現在値を発行
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

// ---------------------------------------------------------------- 受信

void HaBridge::onMessage(const std::string& topic, const std::string& payload) {
  if (topic == prefix_ + "/status") {
    // HA 再起動 → discovery と状態を全再発行 (retain はあるが念のため揃える)
    if (payload == "online" && connected_) {
      DB_LOGI(kTag, "HA online — discovery/状態を再発行");
      pub(base_ + "/bridge/availability", "online", true);
      publishDiscovery();
      publishState();
    }
    return;
  }
  if (topic == base_ + "/cmd/ack") {
    DB_LOGI(kTag, "cmd ack: " + payload);  // Phase 3: 面板/通話へのフィードバック配線予定
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
    // payload が quick_replies のキーならそれ、でなければ自由文
    cJSON* qr = json::get(cfgAt("quick_replies"), payload.c_str());
    if (qr) {
      hooks_.on_reply(payload, "", door);
    } else {
      hooks_.on_reply("", payload, door);
    }
  }
}

}  // namespace db
