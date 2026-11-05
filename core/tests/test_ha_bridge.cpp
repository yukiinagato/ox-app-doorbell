#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "bridge/ha_bridge.h"
#include "bridge/mqtt_client.h"
#include "doctest.h"
#include "mesh/mesh.h"
#include "node/node.h"
#include "test_env.h"
#include "util/clock.h"
#include "util/json.h"
#include "util/runloop.h"

using namespace db;

namespace {

// Minimal MQTT 3.1.1 broker: accepts CONNECT, records every PUBLISH, and forwards injected
// publishes to every connected client. Subscriptions are not filtered.
class RecordingBroker {
 public:
  struct Msg {
    std::string topic, payload;
    bool retain = false;
  };
  RecordingBroker() : port(testing::freeListenPort()) {
    listener = ::socket(AF_INET, SOCK_STREAM, 0);
    REQUIRE(listener >= 0);
    int reuse = 1;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    REQUIRE(::bind(listener, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0);
    REQUIRE(::listen(listener, 4) == 0);
    worker = std::thread([this] { run(); });
  }
  ~RecordingBroker() {
    stopped = true;
    worker.join();
    ::close(listener);
  }
  void inject(const std::string& topic, const std::string& payload, bool retain = false) {
    std::lock_guard<std::mutex> lock(mu);
    outgoing.push_back(mqtt::encodePublish(topic, payload, retain));
  }
  std::vector<Msg> messages() {
    std::lock_guard<std::mutex> lock(mu);
    return received;
  }
  // Latest payload on a topic, or nullptr-equivalent "" plus found=false.
  bool latest(const std::string& topic, std::string* payload, bool* retain = nullptr) {
    std::lock_guard<std::mutex> lock(mu);
    for (auto it = received.rbegin(); it != received.rend(); ++it) {
      if (it->topic != topic) continue;
      if (payload) *payload = it->payload;
      if (retain) *retain = it->retain;
      return true;
    }
    return false;
  }
  size_t count(const std::string& topic) {
    std::lock_guard<std::mutex> lock(mu);
    size_t n = 0;
    for (const auto& m : received) n += m.topic == topic;
    return n;
  }
  bool connected() const { return connections.load() > 0; }
  void clear() {
    std::lock_guard<std::mutex> lock(mu);
    received.clear();
  }
  int port;

 private:
  void run() {
    std::map<int, Bytes> clients;
    while (!stopped) {
      std::vector<Bytes> packets;
      {
        std::lock_guard<std::mutex> lock(mu);
        packets.swap(outgoing);
      }
      for (const auto& bytes : packets)
        for (const auto& client : clients) ::send(client.first, bytes.data(), bytes.size(), 0);
      fd_set readable;
      FD_ZERO(&readable);
      FD_SET(listener, &readable);
      int maximum = listener;
      for (const auto& client : clients) {
        FD_SET(client.first, &readable);
        maximum = std::max(maximum, client.first);
      }
      timeval timeout{0, 20000};
      if (::select(maximum + 1, &readable, nullptr, nullptr, &timeout) <= 0) continue;
      if (FD_ISSET(listener, &readable)) {
        const int fd = ::accept(listener, nullptr, nullptr);
        if (fd >= 0) clients.emplace(fd, Bytes{});
      }
      for (auto it = clients.begin(); it != clients.end();) {
        if (!FD_ISSET(it->first, &readable)) {
          ++it;
          continue;
        }
        uint8_t bytes[65536];
        const ssize_t n = ::recv(it->first, bytes, sizeof(bytes), 0);
        if (n <= 0) {
          ::close(it->first);
          it = clients.erase(it);
          continue;
        }
        it->second.insert(it->second.end(), bytes, bytes + n);
        mqtt::Packet packet;
        int used = 0;
        while ((used = mqtt::decodePacket(it->second.data(), it->second.size(), &packet)) > 0) {
          it->second.erase(it->second.begin(), it->second.begin() + used);
          if (packet.type == mqtt::kConnect) {
            const uint8_t ack[] = {0x20, 2, 0, 0};
            ::send(it->first, ack, sizeof(ack), 0);
            ++connections;
          } else if (packet.type == mqtt::kPingReq) {
            const uint8_t pong[] = {0xd0, 0};
            ::send(it->first, pong, sizeof(pong), 0);
          } else if (packet.type == mqtt::kPublish) {
            Msg m;
            if (mqtt::parsePublish(packet, &m.topic, &m.payload, &m.retain)) {
              std::lock_guard<std::mutex> lock(mu);
              received.push_back(std::move(m));
            }
          }
        }
        ++it;
      }
    }
    for (const auto& client : clients) ::close(client.first);
  }
  int listener;
  std::atomic<bool> stopped{false};
  std::atomic<int> connections{0};
  std::thread worker;
  std::mutex mu;
  std::vector<Msg> received;
  std::vector<Bytes> outgoing;
};

bool waitUntil(const std::function<bool()>& predicate, int timeout_ms = 5000) {
  const auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
  do {
    if (predicate()) return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
  } while (std::chrono::steady_clock::now() < end);
  return predicate();
}

Bytes fakeJpeg(size_t size) {
  Bytes b(size, 0x11);
  b[0] = 0xff;
  b[1] = 0xd8;
  b[size - 2] = 0xff;
  b[size - 1] = 0xd9;
  return b;
}

// Shared state the hooks read and record. Accessed on the bridge's run loop only, except where
// the test thread reads it after waitUntil.
struct HookState {
  std::mutex mu;
  std::string call_state = "idle";
  std::string active_call;
  std::string last_call;
  int64_t unseen = 0;
  bool emergency = false;
  std::string emergency_info = "{}";
  Bytes snapshot;
  std::vector<std::string> replies;
  std::vector<bool> sos_commands;
  std::vector<std::string> notices;
};

struct BridgeHarness {
  RealClock clock;
  Runloop loop{clock};
  RecordingBroker broker;
  HookState state;
  std::unique_ptr<HaBridge> bridge;

  explicit BridgeHarness(const std::string& extra_cfg = "") {
    loop.start();
    HaBridge::Hooks hooks;
    hooks.on_reply = [this](const std::string& rid, const std::string& text,
                            const std::string& door, const std::string& call_id, int revision) {
      std::lock_guard<std::mutex> lock(state.mu);
      state.replies.push_back(rid + "|" + text + "|" + door + "|" + call_id + "|" +
                              std::to_string(revision));
      return true;
    };
    hooks.emergency_active = [this] {
      std::lock_guard<std::mutex> lock(state.mu);
      return state.emergency;
    };
    hooks.language = [] { return std::string("en"); };
    hooks.text = [](const std::string& key) {
      if (key == "core.ha.entity.call_state") return std::string("Call state");
      if (key == "core.ha.entity.emergency") return std::string("Emergency");
      return std::string();
    };
    hooks.call_state = [this](const std::string&) {
      std::lock_guard<std::mutex> lock(state.mu);
      return state.call_state;
    };
    hooks.active_call = [this](const std::string&) {
      std::lock_guard<std::mutex> lock(state.mu);
      return state.active_call;
    };
    hooks.last_call = [this](const std::string&) {
      std::lock_guard<std::mutex> lock(state.mu);
      return state.last_call;
    };
    hooks.unseen_missed = [this](const std::string&) {
      std::lock_guard<std::mutex> lock(state.mu);
      return state.unseen;
    };
    hooks.fetch_snapshot = [this](const std::string&, std::function<void(Bytes)> done) {
      Bytes copy;
      {
        std::lock_guard<std::mutex> lock(state.mu);
        copy = state.snapshot;
      }
      loop.post([done, copy] { done(copy); });
    };
    hooks.emergency_info = [this] {
      std::lock_guard<std::mutex> lock(state.mu);
      return state.emergency_info;
    };
    hooks.set_emergency = [this](bool on) {
      std::lock_guard<std::mutex> lock(state.mu);
      state.sos_commands.push_back(on);
      return true;
    };
    hooks.set_notice = [this](const std::string& text) {
      std::lock_guard<std::mutex> lock(state.mu);
      state.notices.push_back(text);
      return true;
    };
    bridge.reset(new HaBridge(loop, std::move(hooks)));
    configure(extra_cfg);
    REQUIRE(waitUntil([this] { return broker.connected(); }));
    REQUIRE(waitUntil([this] { return broker.count("homeassistant/binary_sensor/doorbell_emergency/config") > 0; }));
    // Subscriptions are sent right after the discovery/state burst.
    std::this_thread::sleep_for(std::chrono::milliseconds(150));
  }
  ~BridgeHarness() {
    loop.callSync([this] { bridge->stop(); });
    bridge.reset();
    loop.stop();
  }
  std::string cfg(const std::string& extra) const {
    return std::string("{\"integrations\":{\"mqtt\":{\"host\":\"127.0.0.1\",\"port\":") +
        std::to_string(broker.port) +
        "},\"ha\":{" + extra + "}},"
        "\"doors\":{\"front\":{\"label\":{\"ja\":\"正面\",\"en\":\"Front\"}}},"
        "\"devices\":{\"n1\":{\"name\":\"Station\",\"door\":\"front\"}},"
        "\"quick_replies\":{\"qr_wait\":{\"label\":{\"ja\":\"少々\",\"en\":\"One moment\"},\"order\":2},"
        "\"qr_away\":{\"label\":{\"ja\":\"留守\",\"en\":\"Away\"},\"order\":1}},"
        "\"notice\":{\"global\":{\"text\":\"Side gate\"}}}";
  }
  void configure(const std::string& extra) {
    const std::string doc = cfg(extra);
    loop.callSync([this, doc] { bridge->configure(doc, "n1", true); });
  }
  void event(const std::string& type, const std::string& payload, const std::string& door = "front") {
    EventRecord ev;
    ev.type = type;
    ev.door = door;
    ev.device = "n1";
    ev.payload_json = payload;
    ev.wall_ms = clock.wallMs();
    loop.callSync([this, ev] { bridge->onEvent(ev); });
  }
  std::string latest(const std::string& topic) {
    std::string p;
    broker.latest(topic, &p);
    return p;
  }
  // Publishes leave through the MQTT client thread; wait for the expected value to arrive.
  bool waitValue(const std::string& topic, const std::string& expected) {
    return waitUntil([&] { return latest(topic) == expected; });
  }
  bool waitEvent(const std::string& type) {
    return waitUntil([&] {
      auto doc = json::parse(latest("doorbell/front/event"));
      return doc && json::getString(doc.get(), "event_type") == type;
    });
  }
};

}  // namespace

TEST_CASE("ha bridge: discovery publishes per-door call, history, image and select entities") {
  BridgeHarness h;
  for (const char* topic :
       {"homeassistant/event/doorbell_front/config",
        "homeassistant/sensor/doorbell_front_call_state/config",
        "homeassistant/sensor/doorbell_front_last_call/config",
        "homeassistant/sensor/doorbell_front_missed_calls/config",
        "homeassistant/image/doorbell_front_snapshot/config",
        "homeassistant/select/doorbell_front_quick_reply/config"}) {
    CAPTURE(topic);
    CHECK(h.broker.count(topic) > 0);
  }
  auto event = json::parse(h.latest("homeassistant/event/doorbell_front/config"));
  REQUIRE(event);
  std::vector<std::string> types;
  cJSON* t = nullptr;
  cJSON_ArrayForEach(t, json::get(event.get(), "event_types")) types.push_back(t->valuestring);
  CHECK(types == std::vector<std::string>{"press", "answered", "missed", "replied", "cancelled"});
  CHECK(json::getString(event.get(), "object_id") == "doorbell_front");

  auto call_state = json::parse(h.latest("homeassistant/sensor/doorbell_front_call_state/config"));
  CHECK(json::getString(call_state.get(), "name") == "Call state");
  CHECK(json::getString(json::get(call_state.get(), "device"), "name") == "Front");

  auto select = json::parse(h.latest("homeassistant/select/doorbell_front_quick_reply/config"));
  cJSON* options = json::get(select.get(), "options");
  REQUIRE(cJSON_GetArraySize(options) == 2);
  CHECK(std::string(cJSON_GetArrayItem(options, 0)->valuestring) == "Away");
  CHECK(std::string(cJSON_GetArrayItem(options, 1)->valuestring) == "One moment");

  auto image = json::parse(h.latest("homeassistant/image/doorbell_front_snapshot/config"));
  CHECK(json::getString(image.get(), "image_topic") == "doorbell/front/snapshot");
  CHECK(json::getString(image.get(), "content_type") == "image/jpeg");

  // Control entities stay removed while their flags are off.
  CHECK(h.latest("homeassistant/button/doorbell_sos_clear/config").empty());
  CHECK(h.latest("homeassistant/button/doorbell_sos_trigger/config").empty());
  CHECK(h.latest("homeassistant/text/doorbell_notice/config").empty());
  CHECK(h.waitValue("doorbell/front/call_state", "idle"));
  CHECK(h.waitValue("doorbell/front/last_call", "none"));
  CHECK(h.waitValue("doorbell/front/missed", "0"));
}

TEST_CASE("ha bridge: call outcomes become doorbell events and history state") {
  BridgeHarness h;
  {
    std::lock_guard<std::mutex> lock(h.state.mu);
    h.state.call_state = "ringing";
    h.state.snapshot = fakeJpeg(1024);
  }
  h.event("press", "{\"call_id\":\"c1\",\"purpose\":\"p_delivery\"}");
  REQUIRE(waitUntil([&] { return h.broker.count("doorbell/front/snapshot") == 1; }));
  REQUIRE(h.waitEvent("press"));
  auto press = json::parse(h.latest("doorbell/front/event"));
  CHECK(json::getString(press.get(), "event_type") == "press");
  CHECK(json::getString(press.get(), "purpose") == "p_delivery");
  CHECK(json::getString(press.get(), "call_id") == "c1");
  CHECK(h.latest("doorbell/front/snapshot").size() == 1024);
  REQUIRE(waitUntil([&] {
    auto attrs = json::parse(h.latest("doorbell/front/attrs"));
    return attrs && !json::getString(attrs.get(), "image_last_updated").empty();
  }));

  h.loop.callSync([&] { h.bridge->onCallLogChanged(); });
  CHECK(h.waitValue("doorbell/front/call_state", "ringing"));

  h.event("reply", "{\"call_id\":\"c1\",\"text\":\"One moment\"}");
  REQUIRE(h.waitEvent("replied"));
  auto replied = json::parse(h.latest("doorbell/front/event"));
  CHECK(json::getString(replied.get(), "event_type") == "replied");
  CHECK(json::getString(replied.get(), "text") == "One moment");

  h.event("call_cancelled", "{\"call_id\":\"c1\",\"reason\":\"timeout\"}");
  CHECK(h.waitEvent("missed"));
  h.event("call_cancelled", "{\"call_id\":\"c2\",\"reason\":\"visitor\"}");
  CHECK(h.waitEvent("cancelled"));
  h.event("call_answered", "{\"call_id\":\"c3\"}");
  CHECK(h.waitEvent("answered"));

  {
    std::lock_guard<std::mutex> lock(h.state.mu);
    h.state.call_state = "idle";
    h.state.unseen = 2;
    h.state.last_call =
        "{\"call_id\":\"c1\",\"outcome\":\"replied\",\"ts\":1700000000000,"
        "\"purpose\":\"p_delivery\",\"visitor_lang\":\"en\",\"duration_ms\":0,\"seen\":false}";
  }
  h.loop.callSync([&] { h.bridge->onCallLogChanged(); });
  CHECK(h.waitValue("doorbell/front/call_state", "idle"));
  CHECK(h.waitValue("doorbell/front/last_call", "replied"));
  CHECK(h.waitValue("doorbell/front/missed", "2"));
  auto attrs = json::parse(h.latest("doorbell/front/last_call/attrs"));
  CHECK(json::getString(attrs.get(), "reply_text") == "One moment");
  CHECK(json::getString(attrs.get(), "time") == "2023-11-14T22:13:20Z");
  CHECK(json::getString(attrs.get(), "visitor_lang") == "en");
  CHECK_FALSE(json::getString(attrs.get(), "image_last_updated").empty());
}

TEST_CASE("ha bridge: snapshots above the image limit or not JPEG are not published") {
  CHECK(HaBridge::snapshotPublishable(fakeJpeg(HaBridge::kMaxSnapshotBytes)));
  CHECK_FALSE(HaBridge::snapshotPublishable(fakeJpeg(HaBridge::kMaxSnapshotBytes + 1)));
  Bytes not_jpeg(100, 0);
  CHECK_FALSE(HaBridge::snapshotPublishable(not_jpeg));
  CHECK_FALSE(HaBridge::snapshotPublishable(Bytes()));

  BridgeHarness h;
  {
    std::lock_guard<std::mutex> lock(h.state.mu);
    h.state.snapshot = fakeJpeg(HaBridge::kMaxSnapshotBytes + 1);
  }
  h.event("press", "{\"call_id\":\"c9\"}");
  REQUIRE(waitUntil([&] { return !h.latest("doorbell/front/event").empty(); }));
  std::this_thread::sleep_for(std::chrono::milliseconds(200));
  CHECK(h.broker.count("doorbell/front/snapshot") == 0);
}

TEST_CASE("ha bridge: emergency attributes carry the source and times") {
  BridgeHarness h;
  {
    std::lock_guard<std::mutex> lock(h.state.mu);
    h.state.emergency = true;
    h.state.emergency_info =
        "{\"source\":\"n1\",\"source_name\":\"Station\",\"door\":\"front\",\"via\":\"panel\","
        "\"triggered_at\":1700000000000,\"cleared_at\":0}";
  }
  h.event("emergency", "{}", "");
  REQUIRE(h.waitValue("doorbell/emergency", "ON"));
  REQUIRE(waitUntil([&] {
    auto doc = json::parse(h.latest("doorbell/emergency/attrs"));
    return doc && json::getBool(doc.get(), "active");
  }));
  auto attrs = json::parse(h.latest("doorbell/emergency/attrs"));
  REQUIRE(attrs);
  CHECK(json::getBool(attrs.get(), "active"));
  CHECK(json::getString(attrs.get(), "source_name") == "Station");
  CHECK(json::getString(attrs.get(), "door") == "front");
  CHECK(json::getString(attrs.get(), "triggered_at_iso") == "2023-11-14T22:13:20Z");
  auto discovery = json::parse(h.latest("homeassistant/binary_sensor/doorbell_emergency/config"));
  CHECK(json::getString(discovery.get(), "json_attributes_topic") == "doorbell/emergency/attrs");
  CHECK(json::getString(discovery.get(), "name") == "Emergency");
}

TEST_CASE("ha bridge: SOS and announcement commands obey their opt-in flags") {
  BridgeHarness h;
  h.broker.inject("doorbell/emergency/set", "OFF");
  h.broker.inject("doorbell/notice/set", "Hello");
  std::this_thread::sleep_for(std::chrono::milliseconds(300));
  {
    std::lock_guard<std::mutex> lock(h.state.mu);
    CHECK(h.state.sos_commands.empty());
    CHECK(h.state.notices.empty());
  }
  CHECK(h.latest("doorbell/notice").empty());

  h.configure("\"allow_sos_control\":true,\"allow_notice_control\":true");
  REQUIRE(waitUntil([&] {
    return !h.latest("homeassistant/button/doorbell_sos_clear/config").empty() &&
           !h.latest("homeassistant/text/doorbell_notice/config").empty();
  }));
  auto clear = json::parse(h.latest("homeassistant/button/doorbell_sos_clear/config"));
  CHECK(json::getString(clear.get(), "payload_press") == "OFF");
  auto trigger = json::parse(h.latest("homeassistant/button/doorbell_sos_trigger/config"));
  CHECK(json::getString(trigger.get(), "payload_press") == "ON");
  CHECK(h.waitValue("doorbell/notice", "Side gate"));

  h.broker.inject("doorbell/emergency/set", "OFF");
  h.broker.inject("doorbell/emergency/set", "ON", /*retain=*/true);  // replayed retained: ignored
  h.broker.inject("doorbell/notice/set", "Hello");
  REQUIRE(waitUntil([&] {
    std::lock_guard<std::mutex> lock(h.state.mu);
    return h.state.sos_commands.size() == 1 && h.state.notices.size() == 1;
  }));
  std::lock_guard<std::mutex> lock(h.state.mu);
  CHECK(h.state.sos_commands.front() == false);
  CHECK(h.state.notices.front() == "Hello");
}

TEST_CASE("ha bridge: quick reply select is scoped to the live call") {
  BridgeHarness h;
  h.broker.inject("doorbell/front/reply/select", "Away");
  std::this_thread::sleep_for(std::chrono::milliseconds(300));
  {
    std::lock_guard<std::mutex> lock(h.state.mu);
    CHECK(h.state.replies.empty());  // No live call: nothing is sent.
    h.state.active_call = "{\"call_id\":\"c7\",\"stage_revision\":3}";
  }
  h.broker.inject("doorbell/front/reply/select", "Away");
  h.broker.inject("doorbell/front/reply/select", "Not an option");
  REQUIRE(waitUntil([&] {
    std::lock_guard<std::mutex> lock(h.state.mu);
    return !h.state.replies.empty();
  }));
  std::this_thread::sleep_for(std::chrono::milliseconds(200));
  std::lock_guard<std::mutex> lock(h.state.mu);
  REQUIRE(h.state.replies.size() == 1);
  CHECK(h.state.replies.front() == "qr_away||front|c7|3");
}

TEST_CASE("ha bridge: a Node feeds call state, history and SOS details through its hooks") {
  RecordingBroker broker;
  NodeOptions o;
  o.data_dir = ":memory:";
  o.name = "front";
  o.role = "door_station";
  o.door = "d_front";
  o.listen_addr = "127.0.0.1:" + std::to_string(testing::freeListenPort());
  o.enable_beacon = false;
  o.psk.fill(0x6c);
  o.http_port = 0;
  o.caps_json = "{\"mqtt_reachable\":true,\"mains_power\":true,\"cpu_score\":10}";
  MeshSettings mt;
  mt.heartbeat_ms = 100;
  mt.suspect_ms = 300;
  mt.dead_ms = 500;
  mt.gossip_ms = mt.sync_ms = mt.reconnect_ms = 200;
  mt.claim_ttl_ms = 900;
  o.mesh_timing_template = mt;
  o.use_mesh_timing_template = true;

  Node node(o);
  REQUIRE(node.start());
  node.setConfigKey("ui.languages", "[\"en\",\"ja\"]");
  node.setConfigKey("doors.d_front", "{\"label\":{\"ja\":\"正面玄関\",\"en\":\"Front door\"}}");
  node.setConfigKey("integrations.mqtt.host", "\"127.0.0.1\"");
  node.setConfigKey("integrations.mqtt.port", std::to_string(broker.port));

  auto latest = [&](const std::string& topic) {
    std::string p;
    broker.latest(topic, &p);
    return p;
  };
  REQUIRE(waitUntil([&] {
    auto d = json::parse(latest("homeassistant/sensor/doorbell_d_front_call_state/config"));
    return d && json::getString(d.get(), "name") == "Call state" &&
           json::getString(json::get(d.get(), "device"), "name") == "Front door";
  }, 10000));
  auto emergency_cfg = json::parse(latest("homeassistant/binary_sensor/doorbell_emergency/config"));
  CHECK(json::getString(emergency_cfg.get(), "name") == "Emergency");
  CHECK(waitUntil([&] { return latest("doorbell/d_front/call_state") == "idle"; }));

  const std::string call_id = node.pressV2("d_front");
  REQUIRE_FALSE(call_id.empty());
  CHECK(waitUntil([&] { return latest("doorbell/d_front/call_state") == "ringing"; }));
  CHECK(waitUntil([&] {
    auto ev = json::parse(latest("doorbell/d_front/event"));
    return ev && json::getString(ev.get(), "event_type") == "press" &&
           json::getString(ev.get(), "call_id") == call_id;
  }));

  REQUIRE(node.cancelCallV2("d_front", call_id, "visitor"));
  CHECK(waitUntil([&] {
    auto ev = json::parse(latest("doorbell/d_front/event"));
    return ev && json::getString(ev.get(), "event_type") == "cancelled";
  }));
  CHECK(waitUntil([&] {
    return latest("doorbell/d_front/call_state") == "idle" &&
           latest("doorbell/d_front/last_call") == "cancelled";
  }));
  auto attrs = json::parse(latest("doorbell/d_front/last_call/attrs"));
  CHECK(json::getString(attrs.get(), "call_id") == call_id);

  REQUIRE(node.setEmergencyV2(true, "panel"));
  CHECK(waitUntil([&] {
    auto a = json::parse(latest("doorbell/emergency/attrs"));
    return latest("doorbell/emergency") == "ON" && a && json::getBool(a.get(), "active") &&
           json::getString(a.get(), "source") == node.nodeId() &&
           json::getString(a.get(), "via") == "panel" &&
           json::getInt(a.get(), "triggered_at", 0) > 0;
  }));
  node.stop();
}
