#include "bridge/ha_bridge.h"

#include <algorithm>
#include <ctime>
#include <map>

#include "util/log.h"

namespace db {

namespace {
constexpr const char* kTag = "ha_bridge";
constexpr size_t kReplyTextMemory = 32;

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

std::string isoUtc(int64_t wall_ms) {
  if (wall_ms <= 0) return "";
  const std::time_t secs = static_cast<std::time_t>(wall_ms / 1000);
  std::tm tm{};
#if defined(_WIN32)
  gmtime_s(&tm, &secs);
#else
  gmtime_r(&secs, &tm);
#endif
  char buf[32];
  std::strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%SZ", &tm);
  return buf;
}

bool missedCancellation(const EventRecord& ev) {
  auto p = json::parse(ev.payload_json.empty() ? "{}" : ev.payload_json);
  const std::string reason = p ? json::getString(p.get(), "reason") : "";
  return reason == "timeout" || reason.rfind("recovery_", 0) == 0;
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

std::string HaBridge::lang() const {
  std::string l = hooks_.language ? hooks_.language() : "";
  return l.empty() ? "ja" : l;
}

std::string HaBridge::text(const std::string& key) const {
  if (!hooks_.text) return key;
  std::string t = hooks_.text(key);
  return t.empty() ? key : t;
}

std::string HaBridge::label(const cJSON* label_obj) const {
  if (!label_obj) return "";
  if (cJSON_IsString(label_obj)) return label_obj->valuestring;
  std::string v = json::getString(label_obj, lang().c_str());
  if (v.empty()) v = json::getString(label_obj, "ja");
  if (v.empty()) v = json::getString(label_obj, "en");
  if (v.empty() && label_obj->child && cJSON_IsString(label_obj->child))
    v = label_obj->child->valuestring;
  return v;
}

bool HaBridge::allowSosControl() const {
  return json::getBool(cfgAt("integrations.ha"), "allow_sos_control", false);
}

bool HaBridge::allowNoticeControl() const {
  return json::getBool(cfgAt("integrations.ha"), "allow_notice_control", false);
}

std::vector<std::pair<std::string, std::string>> HaBridge::quickReplyOptions() const {
  struct Entry {
    int64_t order;
    std::string id, text;
  };
  std::vector<Entry> entries;
  cJSON* qrs = cfgAt("quick_replies");
  cJSON* it = nullptr;
  cJSON_ArrayForEach(it, qrs) {
    if (!it->string || !cJSON_IsObject(it)) continue;
    if (json::get(it, "enabled") && !json::getBool(it, "enabled", true)) continue;
    std::string t = label(json::get(it, "label"));
    if (t.empty()) continue;
    entries.push_back({json::getInt(it, "order", 1000), it->string, t});
  }
  std::stable_sort(entries.begin(), entries.end(),
                   [](const Entry& a, const Entry& b) { return a.order < b.order; });
  std::vector<std::pair<std::string, std::string>> out;
  for (auto& e : entries) {
    // HA select options must be unique; a duplicated label keeps its first reply.
    bool dup = false;
    for (const auto& o : out) dup = dup || o.second == e.text;
    if (!dup) out.push_back({e.id, e.text});
  }
  return out;
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
  mo.tls = json::getBool(mq, "tls", false);
  mo.tls_sha256 = json::getString(mq, "tls_sha256");

  if (!active || mo.host.empty()) {
    if (client_) DB_LOGI(kTag, "bridge stopped because this node is not leader or mqtt.host is unset");
    stopClient(true);
    active_ = false;
    return;
  }
  active_ = true;

  const bool opts_changed =
      mo.host != mopts_.host || mo.port != mopts_.port || mo.username != mopts_.username ||
      mo.password != mopts_.password || mo.will_topic != mopts_.will_topic ||
      mo.tls != mopts_.tls || mo.tls_sha256 != mopts_.tls_sha256;
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
  cbs.on_disconnected = [this] {
    connected_ = false;
    if (hooks_.on_operation_disconnect) hooks_.on_operation_disconnect();
  };
  cbs.on_message = [this](const std::string& t, const std::string& p, bool retained) { onMessage(t, p, retained); };
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
  if (hooks_.on_operation_disconnect) hooks_.on_operation_disconnect();
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
  client_->subscribe(base_ + "/+/reply/select");
  client_->subscribe(base_ + "/cmd/ack");
  client_->subscribe(base_ + "/emergency/set");
  client_->subscribe(base_ + "/notice/set");
}

void HaBridge::pub(const std::string& topic, const std::string& payload, bool retain) {
  if (client_) client_->publish(topic, payload, retain);
}

void HaBridge::pubConfig(const std::string& component, const std::string& object_id,
                         cJSON* body) {
  pub(prefix_ + "/" + component + "/" + object_id + "/config", json::dump(body), true);
}

void HaBridge::removeConfig(const std::string& component, const std::string& object_id) {
  // An empty retained config removes the entity from Home Assistant.
  pub(prefix_ + "/" + component + "/" + object_id + "/config", "", true);
}

bool HaBridge::dispatchOperation(const std::string& door, const std::string& command,
                                 const std::string& operation_id, const std::string& authority,
                                 const std::string& binding, const std::string& actuator,
                                 const std::string& command_digest) {
  if (!operationReady(binding) || authority != node_id_ || command.empty() ||
      sanitizeId(command) != command || door.empty() || operation_id.size() != 32) return false;
  auto payload = json::obj();
  json::set(payload.get(), "door", door);
  json::set(payload.get(), "operation_id", operation_id);
  json::set(payload.get(), "authority_node", authority);
  if (!actuator.empty()) {
    json::set(payload.get(), "ack_protocol", "ed25519-v1");
    json::set(payload.get(), "actuator_id", actuator);
    json::set(payload.get(), "command_digest", command_digest);
  }
  return client_->tryPublish(base_ + "/cmd/" + command, json::dump(payload.get()));
}

std::string HaBridge::operationBinding(const std::string& host, uint16_t port,
                                       const std::string& base_topic) {
  auto binding = json::obj();
  json::set(binding.get(), "host", host);
  json::set(binding.get(), "port", static_cast<int64_t>(port));
  json::set(binding.get(), "base_topic", base_topic);
  return sha256Hex(toBytes(json::dump(binding.get())));
}

bool HaBridge::operationReady(const std::string& binding) const {
  return active_ && connected_ && client_ &&
      binding == operationBinding(mopts_.host, mopts_.port, base_);
}

bool HaBridge::snapshotPublishable(const Bytes& jpeg) {
  return jpeg.size() >= 4 && jpeg.size() <= kMaxSnapshotBytes && jpeg[0] == 0xff &&
      jpeg[1] == 0xd8 && jpeg[jpeg.size() - 2] == 0xff && jpeg.back() == 0xd9;
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
  std::string name = label(json::get(door, "label"));
  json::set(dev, "name", name.empty() ? door_id : name);
  json::set(dev, "manufacturer", "ox");
  json::set(dev, "model", "DoorStation");
  const std::string bld = json::getString(door, "building");
  if (!bld.empty()) {
    std::string area = label(json::get(cfgAt("buildings." + bld), "label"));
    if (!area.empty()) json::set(dev, "suggested_area", area);
  }
}

void HaBridge::setMeshDevice(cJSON* o) {
  cJSON* dev = json::addObj(o, "device");
  cJSON* ids = json::addArr(dev, "identifiers");
  json::push(ids, json::Doc(cJSON_CreateString("doorbell_bridge")));
  json::set(dev, "name", text("core.ha.device.mesh"));
  json::set(dev, "manufacturer", "ox");
  json::set(dev, "model", "MeshBridge");
}

void HaBridge::publishDiscovery() {
  cJSON* doors = json::get(cfg_.get(), "doors");
  cJSON* it = nullptr;
  const auto replies = quickReplyOptions();
  cJSON_ArrayForEach(it, doors) {
    if (!it->string) continue;
    const std::string did = it->string;
    const std::string sid = sanitizeId(did);
    const std::string door_base = base_ + "/" + did;
    auto common = [&](cJSON* o, const std::string& key, const std::string& suffix) {
      json::set(o, "name", text("core.ha.entity." + key));
      addAvailability(o, did);
      json::set(o, "unique_id", "doorbell_" + sid + suffix);
      json::set(o, "object_id", "doorbell_" + sid + suffix);
      setDoorDevice(o, did);
    };
    {
      auto o = json::obj();
      common(o.get(), "doorbell", "_event");
      // Keeps the press-only object_id so existing entity ids and HomeKit links survive.
      json::set(o.get(), "object_id", "doorbell_" + sid);
      cJSON* types = json::addArr(o.get(), "event_types");
      for (const char* t : {"press", "answered", "missed", "replied", "cancelled",
                            "visitor_message"})
        json::push(types, json::Doc(cJSON_CreateString(t)));
      json::set(o.get(), "device_class", "doorbell");
      json::set(o.get(), "state_topic", door_base + "/event");
      pubConfig("event", "doorbell_" + sid, o.get());
    }
    {
      auto o = json::obj();
      common(o.get(), "motion", "_motion");
      json::set(o.get(), "device_class", "motion");
      json::set(o.get(), "state_topic", door_base + "/motion");
      json::set(o.get(), "payload_on", "ON");
      json::set(o.get(), "off_delay", static_cast<int64_t>(30));
      pubConfig("binary_sensor", "doorbell_" + sid + "_motion", o.get());
    }
    {
      auto o = json::obj();
      common(o.get(), "visitor_lang", "_visitor_lang");
      json::set(o.get(), "state_topic", door_base + "/attrs");
      json::set(o.get(), "value_template", "{{ value_json.visitor_lang }}");
      json::set(o.get(), "json_attributes_topic", door_base + "/attrs");
      pubConfig("sensor", "doorbell_" + sid + "_visitor_lang", o.get());
    }
    {
      auto o = json::obj();
      common(o.get(), "call_state", "_call_state");
      json::set(o.get(), "device_class", "enum");
      cJSON* opts = json::addArr(o.get(), "options");
      for (const char* s : {"idle", "ringing", "in_call"})
        json::push(opts, json::Doc(cJSON_CreateString(s)));
      json::set(o.get(), "state_topic", door_base + "/call_state");
      json::set(o.get(), "icon", "mdi:phone-ring");
      pubConfig("sensor", "doorbell_" + sid + "_call_state", o.get());
    }
    {
      auto o = json::obj();
      common(o.get(), "last_call", "_last_call");
      json::set(o.get(), "device_class", "enum");
      cJSON* opts = json::addArr(o.get(), "options");
      for (const char* s : {"none", "answered", "missed", "replied", "cancelled"})
        json::push(opts, json::Doc(cJSON_CreateString(s)));
      json::set(o.get(), "state_topic", door_base + "/last_call");
      json::set(o.get(), "json_attributes_topic", door_base + "/last_call/attrs");
      json::set(o.get(), "icon", "mdi:history");
      pubConfig("sensor", "doorbell_" + sid + "_last_call", o.get());
    }
    {
      auto o = json::obj();
      common(o.get(), "missed_calls", "_missed_calls");
      json::set(o.get(), "state_topic", door_base + "/missed");
      json::set(o.get(), "state_class", "measurement");
      json::set(o.get(), "icon", "mdi:phone-missed");
      pubConfig("sensor", "doorbell_" + sid + "_missed_calls", o.get());
    }
    {
      auto o = json::obj();
      common(o.get(), "snapshot", "_snapshot");
      json::set(o.get(), "image_topic", door_base + "/snapshot");
      json::set(o.get(), "content_type", "image/jpeg");
      pubConfig("image", "doorbell_" + sid + "_snapshot", o.get());
    }
    if (!replies.empty()) {
      auto o = json::obj();
      common(o.get(), "quick_reply", "_quick_reply");
      json::set(o.get(), "command_topic", door_base + "/reply/select");
      cJSON* opts = json::addArr(o.get(), "options");
      for (const auto& r : replies) json::push(opts, json::Doc(cJSON_CreateString(r.second.c_str())));
      json::setBool(o.get(), "optimistic", true);
      json::set(o.get(), "icon", "mdi:message-reply-text");
      pubConfig("select", "doorbell_" + sid + "_quick_reply", o.get());
    } else {
      removeConfig("select", "doorbell_" + sid + "_quick_reply");
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
    pubConfig("binary_sensor", sid, o.get());
  }

  {
    auto o = json::obj();
    json::set(o.get(), "name", text("core.ha.entity.emergency"));
    json::set(o.get(), "device_class", "safety");
    json::set(o.get(), "state_topic", base_ + "/emergency");
    json::set(o.get(), "json_attributes_topic", base_ + "/emergency/attrs");
    addAvailability(o.get(), "");
    json::set(o.get(), "unique_id", "doorbell_emergency");
    json::set(o.get(), "object_id", "doorbell_emergency");
    setMeshDevice(o.get());
    pubConfig("binary_sensor", "doorbell_emergency", o.get());
  }

  const bool sos = allowSosControl();
  for (const char* action : {"clear", "trigger"}) {
    const std::string object_id = std::string("doorbell_sos_") + action;
    if (!sos) {
      removeConfig("button", object_id);
      continue;
    }
    auto o = json::obj();
    json::set(o.get(), "name", text(std::string("core.ha.entity.sos_") + action));
    json::set(o.get(), "command_topic", base_ + "/emergency/set");
    json::set(o.get(), "payload_press", std::string(action) == "clear" ? "OFF" : "ON");
    json::set(o.get(), "icon", std::string(action) == "clear" ? "mdi:alarm-light-off"
                                                              : "mdi:alarm-light");
    addAvailability(o.get(), "");
    json::set(o.get(), "unique_id", object_id);
    json::set(o.get(), "object_id", object_id);
    setMeshDevice(o.get());
    pubConfig("button", object_id, o.get());
  }

  if (allowNoticeControl()) {
    auto o = json::obj();
    json::set(o.get(), "name", text("core.ha.entity.notice"));
    json::set(o.get(), "command_topic", base_ + "/notice/set");
    json::set(o.get(), "state_topic", base_ + "/notice");
    json::set(o.get(), "max", static_cast<int64_t>(255));
    json::set(o.get(), "icon", "mdi:bullhorn");
    addAvailability(o.get(), "");
    json::set(o.get(), "unique_id", "doorbell_notice");
    json::set(o.get(), "object_id", "doorbell_notice");
    setMeshDevice(o.get());
    pubConfig("text", "doorbell_notice", o.get());
  } else {
    removeConfig("text", "doorbell_notice");
  }

  {
    auto o = json::obj();
    json::set(o.get(), "name", text("core.ha.entity.bridge"));
    json::set(o.get(), "device_class", "connectivity");
    json::set(o.get(), "state_topic", base_ + "/bridge/availability");
    json::set(o.get(), "payload_on", "online");
    json::set(o.get(), "payload_off", "offline");

    json::set(o.get(), "unique_id", "doorbell_bridge_online");
    json::set(o.get(), "object_id", "doorbell_bridge_online");
    setMeshDevice(o.get());
    pubConfig("binary_sensor", "doorbell_bridge_online", o.get());
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
  publishCallState();
  publishNotice();
}

void HaBridge::publishEmergency() {
  const bool on = hooks_.emergency_active && hooks_.emergency_active();
  pub(base_ + "/emergency", on ? "ON" : "OFF", true);
  auto attrs = hooks_.emergency_info ? json::parse(hooks_.emergency_info()) : json::Doc();
  if (!attrs || !cJSON_IsObject(attrs.get())) attrs = json::obj();
  json::setBool(attrs.get(), "active", on);
  for (const char* k : {"triggered_at", "cleared_at"}) {
    const int64_t ms = json::getInt(attrs.get(), k, 0);
    if (ms > 0) json::set(attrs.get(), (std::string(k) + "_iso").c_str(), isoUtc(ms));
  }
  pub(base_ + "/emergency/attrs", json::dump(attrs.get()), true);
}

void HaBridge::publishNotice() {
  const std::string current = json::getString(json::get(cfgAt("notice"), "global"), "text");
  pub(base_ + "/notice", allowNoticeControl() ? current : "", true);
}

void HaBridge::publishCallState(const std::string& door_id) {
  auto one = [this](const std::string& did) {
    const std::string door_base = base_ + "/" + did;
    std::string state = hooks_.call_state ? hooks_.call_state(did) : "idle";
    if (state != "ringing" && state != "in_call") state = "idle";
    pub(door_base + "/call_state", state, true);

    const int64_t missed = hooks_.unseen_missed ? hooks_.unseen_missed(did) : 0;
    pub(door_base + "/missed", std::to_string(missed), true);

    auto row = hooks_.last_call ? json::parse(hooks_.last_call(did)) : json::Doc();
    auto attrs = json::obj();
    std::string outcome = "none";
    if (row && cJSON_IsObject(row.get())) {
      outcome = json::getString(row.get(), "outcome", "none");
      const std::string call_id = json::getString(row.get(), "call_id");
      const int64_t ts = json::getInt(row.get(), "ts", 0);
      json::set(attrs.get(), "outcome", outcome);
      json::set(attrs.get(), "call_id", call_id);
      json::set(attrs.get(), "ts", ts);
      json::set(attrs.get(), "time", isoUtc(ts));
      json::set(attrs.get(), "purpose", json::getString(row.get(), "purpose"));
      json::set(attrs.get(), "visitor_lang", json::getString(row.get(), "visitor_lang"));
      json::set(attrs.get(), "answered_by", json::getString(row.get(), "answered_by"));
      json::set(attrs.get(), "duration_s", json::getInt(row.get(), "duration_ms", 0) / 1000);
      json::setBool(attrs.get(), "seen", json::getBool(row.get(), "seen", true));
      std::string reply;
      for (const auto& r : reply_texts_)
        if (r.first == call_id) reply = r.second;
      json::set(attrs.get(), "reply_text", reply);
    }
    const auto snap = snapshot_at_.find(did);
    if (snap != snapshot_at_.end())
      json::set(attrs.get(), "image_last_updated", isoUtc(snap->second));
    pub(door_base + "/last_call", outcome, true);
    pub(door_base + "/last_call/attrs", json::dump(attrs.get()), true);
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

void HaBridge::onCallLogChanged() {
  if (!client_ || !connected_) return;
  publishCallState();
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
    const auto snap = snapshot_at_.find(did);
    if (snap != snapshot_at_.end())
      json::set(o.get(), "image_last_updated", isoUtc(snap->second));
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

void HaBridge::publishSnapshot(const std::string& door_id) {
  if (!hooks_.fetch_snapshot || door_id.empty()) return;
  const uint64_t generation = ++snapshot_generation_;
  hooks_.fetch_snapshot(door_id, [this, door_id, generation](Bytes jpeg) {
    (void)generation;
    if (!client_ || !connected_) return;
    if (!snapshotPublishable(jpeg)) {
      DB_LOGW(kTag, "snapshot for " + door_id + " skipped (" + std::to_string(jpeg.size()) +
                        " bytes; empty, invalid, or above the image limit)");
      return;
    }
    pub(base_ + "/" + door_id + "/snapshot", std::string(jpeg.begin(), jpeg.end()), false);
    snapshot_at_[door_id] = loop_.clock().wallMs();
    publishDoorAttrs(door_id);
  });
}

void HaBridge::onEvent(const EventRecord& ev) {
  if (!client_ || !connected_) return;
  auto event_of = [&](const char* type, cJSON* extra) {
    auto o = json::obj();
    json::set(o.get(), "event_type", type);
    auto p = json::parse(ev.payload_json.empty() ? "{}" : ev.payload_json);
    if (p) {
      const std::string call_id = json::getString(p.get(), "call_id");
      if (!call_id.empty()) json::set(o.get(), "call_id", call_id);
    }
    if (extra) {
      cJSON* it = nullptr;
      cJSON_ArrayForEach(it, extra) {
        if (it->string) cJSON_AddItemToObject(o.get(), it->string, cJSON_Duplicate(it, 1));
      }
    }
    pub(base_ + "/" + ev.door + "/event", json::dump(o.get()), false);
  };

  if (ev.type == "press") {
    if (ev.door.empty()) return;

    auto o = json::obj();
    json::set(o.get(), "event_type", "press");
    auto p = json::parse(ev.payload_json.empty() ? "{}" : ev.payload_json);
    if (p) {
      const std::string purpose = json::getString(p.get(), "purpose");
      const std::string vlang = json::getString(p.get(), "visitor_lang");
      const std::string call_id = json::getString(p.get(), "call_id");
      if (!purpose.empty()) json::set(o.get(), "purpose", purpose);
      if (!vlang.empty()) json::set(o.get(), "visitor_lang", vlang);
      if (!call_id.empty()) json::set(o.get(), "call_id", call_id);
    }
    pub(base_ + "/" + ev.door + "/event", json::dump(o.get()), false);
    publishSnapshot(ev.door);
  } else if (ev.type == "visitor_message") {
    if (ev.door.empty()) return;
    // A message left without ringing is its own event type, so an automation on "press" does
    // not fire for it.
    auto p = json::parse(ev.payload_json.empty() ? "{}" : ev.payload_json);
    auto extra = json::obj();
    if (p) {
      for (const char* field : {"message_id", "step", "purpose", "visitor_lang"}) {
        const std::string value = json::getString(p.get(), field);
        if (!value.empty()) json::set(extra.get(), field, value);
      }
      const cJSON* text = json::get(p.get(), "text");
      const std::string japanese = json::getString(text, "ja");
      const std::string shown = !japanese.empty() ? japanese
          : (text && cJSON_IsString(text->child) ? std::string(text->child->valuestring)
                                                 : std::string());
      if (!shown.empty()) json::set(extra.get(), "text", shown);
      json::setBool(extra.get(), "has_snapshot",
                    !json::getString(json::get(p.get(), "snapshot"), "sha256").empty());
    }
    event_of("visitor_message", extra.get());
  } else if (ev.type == "call_answered") {
    if (ev.door.empty()) return;
    event_of("answered", nullptr);
  } else if (ev.type == "call_cancelled") {
    if (ev.door.empty()) return;
    event_of(missedCancellation(ev) ? "missed" : "cancelled", nullptr);
  } else if (ev.type == "reply") {
    auto p = json::parse(ev.payload_json.empty() ? "{}" : ev.payload_json);
    const std::string call_id = p ? json::getString(p.get(), "call_id") : "";
    const std::string reply_text = p ? json::getString(p.get(), "text") : "";
    if (!call_id.empty()) {
      reply_texts_.push_back({call_id, reply_text});
      while (reply_texts_.size() > kReplyTextMemory) reply_texts_.pop_front();
    }
    if (ev.door.empty()) return;
    auto extra = json::obj();
    if (!reply_text.empty()) json::set(extra.get(), "text", reply_text);
    event_of("replied", extra.get());
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

void HaBridge::handleQuickReplySelect(const std::string& door, const std::string& chosen) {
  if (!hooks_.on_reply) return;
  std::string reply_id;
  for (const auto& r : quickReplyOptions())
    if (r.second == chosen || r.first == chosen) reply_id = r.first;
  if (reply_id.empty()) {
    DB_LOGW(kTag, "quick reply select ignored: unknown option");
    return;
  }
  auto active = hooks_.active_call ? json::parse(hooks_.active_call(door)) : json::Doc();
  const std::string call_id = active ? json::getString(active.get(), "call_id") : "";
  const int revision = active ? static_cast<int>(json::getInt(active.get(), "stage_revision", -1)) : -1;
  if (call_id.empty() || revision < 0) {
    DB_LOGW(kTag, "quick reply select ignored: no live call at " + door);
    return;
  }
  if (!hooks_.on_reply(reply_id, "", door, call_id, revision))
    DB_LOGW(kTag, "quick reply select rejected because the call changed");
}

void HaBridge::onMessage(const std::string& topic, const std::string& payload, bool retained) {
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
    if (!retained && payload.size() <= 2048 && hooks_.on_operation_ack)
      hooks_.on_operation_ack(payload);
    return;
  }
  // Commands are momentary; a retained copy would replay on every reconnect.
  if (topic == base_ + "/emergency/set") {
    if (retained) return;
    if (!allowSosControl() || !hooks_.set_emergency) {
      DB_LOGW(kTag, "SOS command over MQTT ignored: integrations.ha.allow_sos_control is off");
      return;
    }
    if (payload == "ON" || payload == "OFF") hooks_.set_emergency(payload == "ON");
    return;
  }
  if (topic == base_ + "/notice/set") {
    if (retained) return;
    if (!allowNoticeControl() || !hooks_.set_notice) {
      DB_LOGW(kTag, "notice command over MQTT ignored: integrations.ha.allow_notice_control is off");
      return;
    }
    if (payload.size() <= 1024) hooks_.set_notice(payload);
    return;
  }
  const std::string head = base_ + "/";
  auto doorFor = [&](const std::string& tail) -> std::string {
    if (topic.size() <= head.size() + tail.size() || topic.compare(0, head.size(), head) != 0 ||
        topic.compare(topic.size() - tail.size(), tail.size(), tail) != 0)
      return "";
    const std::string door = topic.substr(head.size(), topic.size() - head.size() - tail.size());
    return door.find('/') == std::string::npos ? door : "";
  };
  // <base>/<door_id>/reply/select (HA select entity)
  {
    const std::string door = doorFor("/reply/select");
    if (!door.empty()) {
      if (!retained && payload.size() <= 1024) handleQuickReplySelect(door, payload);
      return;
    }
  }
  // <base>/<door_id>/reply/set
  const std::string door = doorFor("/reply/set");
  if (door.empty() || !hooks_.on_reply) return;

  auto scoped = json::parse(payload);
  bool accepted = false;
  if (scoped && cJSON_IsObject(scoped.get())) {
    const std::string reply_id = json::getString(scoped.get(), "reply_id");
    const std::string reply_text = json::getString(scoped.get(), "text");
    const std::string call_id = json::getString(scoped.get(), "call_id");
    const int revision = static_cast<int>(json::getInt(scoped.get(), "stage_revision", -1));
    if (!call_id.empty() && revision >= 0)
      accepted = hooks_.on_reply(reply_id, reply_text, door, call_id, revision);
  } else {
    cJSON* qr = json::get(cfgAt("quick_replies"), payload.c_str());
    accepted = qr ? hooks_.on_reply(payload, "", door, "", -1)
                  : hooks_.on_reply("", payload, door, "", -1);
  }
  if (!accepted)
    DB_LOGW(kTag, "quick reply rejected because the MQTT command was stale or unscoped");
}

}  // namespace db
