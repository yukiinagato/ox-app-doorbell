

//   DB_MQTT_TEST=1 ./doorbell_tests -tc="mqtt:*"
#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <mutex>
#include <random>
#include <string>
#include <thread>
#include <vector>

#include "bridge/mqtt_client.h"
#include "doctest.h"
#include "mesh/mesh.h"
#include "node/node.h"
#include "util/clock.h"
#include "util/common.h"
#include "util/json.h"
#include "util/runloop.h"

#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>

using namespace db;



TEST_CASE("mqtt: remaining-length round trips across multibyte boundaries") {
  const uint32_t vals[] = {0,      1,      127,     128,     16383,
                           16384,  2097151, 2097152, 268435455};
  const size_t want_bytes[] = {1, 1, 1, 2, 2, 3, 3, 4, 4};
  for (size_t i = 0; i < sizeof(vals) / sizeof(vals[0]); i++) {
    CAPTURE(vals[i]);
    uint8_t buf[4];
    size_t n = mqtt::encodeRemainingLength(vals[i], buf);
    CHECK(n == want_bytes[i]);
    uint32_t out = 0;
    size_t used = 0;
    CHECK(mqtt::decodeRemainingLength(buf, n, &out, &used) == 1);
    CHECK(out == vals[i]);
    CHECK(used == n);
  }

  uint8_t buf[4];
  CHECK(mqtt::encodeRemainingLength(268435456u, buf) == 0);

  uint8_t cont[2] = {0x80, 0x80};
  uint32_t v = 0;
  size_t used = 0;
  CHECK(mqtt::decodeRemainingLength(cont, 1, &v, &used) == 0);
  CHECK(mqtt::decodeRemainingLength(cont, 2, &v, &used) == 0);

  uint8_t bad[5] = {0x80, 0x80, 0x80, 0x80, 0x01};
  CHECK(mqtt::decodeRemainingLength(bad, 5, &v, &used) == -1);
}

TEST_CASE("mqtt: encodes CONNECT with LWT, credentials, keepalive, and flags") {
  mqtt::ConnectOpts o;
  o.client_id = "cid";
  o.username = "user";
  o.password = "pw";
  o.keepalive_s = 30;
  o.will_topic = "w/t";
  o.will_payload = "offline";
  o.will_retain = true;
  Bytes b = mqtt::encodeConnect(o);
  REQUIRE(b.size() > 2);
  CHECK(b[0] == 0x10);
  mqtt::Packet p;
  REQUIRE(mqtt::decodePacket(b.data(), b.size(), &p) == static_cast<int>(b.size()));
  CHECK(p.type == mqtt::kConnect);

  REQUIRE(p.body.size() > 10);
  CHECK(std::string(p.body.begin() + 2, p.body.begin() + 6) == "MQTT");
  CHECK(p.body[6] == 4);
  const uint8_t flags = p.body[7];
  CHECK((flags & 0x02) != 0);  // clean session
  CHECK((flags & 0x04) != 0);  // will
  CHECK((flags & 0x20) != 0);  // will retain
  CHECK((flags & 0x40) != 0);  // password
  CHECK((flags & 0x80) != 0);  // username
  CHECK(((p.body[8] << 8) | p.body[9]) == 30);  // keepalive

  std::string all(p.body.begin() + 10, p.body.end());
  CHECK(all.find("cid") < all.find("w/t"));
  CHECK(all.find("w/t") < all.find("offline"));
  CHECK(all.find("offline") < all.find("user"));
  CHECK(all.find("user") < all.find("pw"));
}

TEST_CASE("mqtt: retained PUBLISH encode and decode round trip") {
  Bytes b = mqtt::encodePublish("a/b", "hello", true);
  mqtt::Packet p;
  REQUIRE(mqtt::decodePacket(b.data(), b.size(), &p) == static_cast<int>(b.size()));
  CHECK(p.type == mqtt::kPublish);
  std::string topic, payload;
  bool retain = false;
  REQUIRE(mqtt::parsePublish(p, &topic, &payload, &retain));
  CHECK(topic == "a/b");
  CHECK(payload == "hello");
  CHECK(retain);

  Bytes b2 = mqtt::encodePublish("a/b", "x", false);
  REQUIRE(mqtt::decodePacket(b2.data(), b2.size(), &p) == static_cast<int>(b2.size()));
  REQUIRE(mqtt::parsePublish(p, &topic, &payload, &retain));
  CHECK(!retain);

  CHECK(mqtt::decodePacket(b.data(), b.size() - 1, &p) == 0);
  CHECK(mqtt::decodePacket(b.data(), 1, &p) == 0);
}

TEST_CASE("mqtt: long payload round trip uses a two-byte remaining length") {
  std::string big(200, 'x');
  Bytes b = mqtt::encodePublish("t", big, false);
  CHECK((b[1] & 0x80) != 0);
  mqtt::Packet p;
  REQUIRE(mqtt::decodePacket(b.data(), b.size(), &p) == static_cast<int>(b.size()));
  std::string topic, payload;
  bool retain;
  REQUIRE(mqtt::parsePublish(p, &topic, &payload, &retain));
  CHECK(payload == big);
}

TEST_CASE("mqtt: encodes SUBSCRIBE, PINGREQ, and DISCONNECT") {
  Bytes s = mqtt::encodeSubscribe(7, {"a/#", "b/+/c"});
  CHECK(s[0] == 0x82);
  mqtt::Packet p;
  REQUIRE(mqtt::decodePacket(s.data(), s.size(), &p) == static_cast<int>(s.size()));
  CHECK(p.type == mqtt::kSubscribe);
  REQUIRE(p.body.size() >= 2);
  CHECK(((p.body[0] << 8) | p.body[1]) == 7);  // packet id
  std::string body(p.body.begin() + 2, p.body.end());
  CHECK(body.find("a/#") != std::string::npos);
  CHECK(body.find("b/+/c") != std::string::npos);
  CHECK(p.body.back() == 0);

  Bytes ping = mqtt::encodePingReq();
  REQUIRE(ping.size() == 2);
  CHECK(ping[0] == 0xC0);
  CHECK(ping[1] == 0x00);
  Bytes disc = mqtt::encodeDisconnect();
  REQUIRE(disc.size() == 2);
  CHECK(disc[0] == 0xE0);
  CHECK(disc[1] == 0x00);

  REQUIRE(mqtt::decodePacket(ping.data(), 2, &p) == 2);
  CHECK(p.type == mqtt::kPingReq);
  CHECK(p.body.empty());
}



namespace {

bool mqttTestEnabled() { return std::getenv("DB_MQTT_TEST") != nullptr; }

constexpr const char* kBroker = "127.0.0.1";


struct TestCli {
  RealClock clock;
  Runloop loop{clock};
  struct Msg {
    std::string topic, payload;
    bool retain;
  };
  std::mutex mu;
  std::condition_variable cv;
  std::vector<Msg> msgs;
  int connects = 0;
  int disconnects = 0;
  std::unique_ptr<MqttClient> cli;

  explicit TestCli(MqttClient::Options o) {
    loop.start();
    MqttClient::Callbacks cbs;
    cbs.on_connected = [this] {
      std::lock_guard<std::mutex> lk(mu);
      connects++;
      cv.notify_all();
    };
    cbs.on_disconnected = [this] {
      std::lock_guard<std::mutex> lk(mu);
      disconnects++;
      cv.notify_all();
    };
    cbs.on_message = [this](const std::string& t, const std::string& p, bool r) {
      std::lock_guard<std::mutex> lk(mu);
      msgs.push_back({t, p, r});
      cv.notify_all();
    };
    cli.reset(new MqttClient(loop, std::move(o), std::move(cbs)));
    cli->start();
  }

  ~TestCli() {
    cli.reset();  // stop + join
    loop.stop();
  }

  bool waitConnected(int ms = 5000) {
    std::unique_lock<std::mutex> lk(mu);
    return cv.wait_for(lk, std::chrono::milliseconds(ms), [this] { return connects > 0; });
  }


  template <typename Pred>
  bool waitMsgs(Pred pred, int ms = 5000) {
    std::unique_lock<std::mutex> lk(mu);
    return cv.wait_for(lk, std::chrono::milliseconds(ms), [&] { return pred(msgs); });
  }

  std::vector<Msg> snapshot() {
    std::lock_guard<std::mutex> lk(mu);
    return msgs;
  }
};

MqttClient::Options basicOpts(const std::string& cid) {
  MqttClient::Options o;
  o.host = kBroker;
  o.port = 1883;
  o.client_id = cid;
  return o;
}

std::string uniqueSuffix() {
  static std::mt19937 rng(static_cast<uint32_t>(::getpid()) ^
                          static_cast<uint32_t>(std::chrono::steady_clock::now()
                                                    .time_since_epoch()
                                                    .count()));
  return std::to_string(rng() % 1000000);
}


template <typename Pred>
bool waitFor(Pred pred, int ms = 10000, int step_ms = 50) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(ms);
  while (std::chrono::steady_clock::now() < deadline) {
    if (pred()) return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(step_ms));
  }
  return pred();
}

int freeTcpPort() {
  int fd = ::socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return -1;
  sockaddr_in sa{};
  sa.sin_family = AF_INET;
  sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  sa.sin_port = 0;
  socklen_t len = sizeof(sa);
  int port = -1;
  if (::bind(fd, reinterpret_cast<sockaddr*>(&sa), sizeof(sa)) == 0 &&
      ::getsockname(fd, reinterpret_cast<sockaddr*>(&sa), &len) == 0)
    port = ntohs(sa.sin_port);
  ::close(fd);
  return port;
}

}  // namespace

TEST_CASE("mqtt: client connects, publishes retained data, and emits LWT on disconnect") {
  if (!mqttTestEnabled()) return;
  const std::string ns = "dbtest" + uniqueSuffix();


  TestCli b(basicOpts(ns + "-sub"));
  REQUIRE(b.waitConnected());
  b.cli->subscribe(ns + "/#");


  MqttClient::Options ao = basicOpts(ns + "-pub");
  ao.will_topic = ns + "/lwt";
  ao.will_payload = "offline";
  ao.keepalive_s = 5;
  TestCli a(std::move(ao));
  REQUIRE(a.waitConnected());
  a.cli->publish(ns + "/state", "v1", true);


  REQUIRE(b.waitMsgs([&](const std::vector<TestCli::Msg>& m) {
    for (const auto& x : m)
      if (x.topic == ns + "/state" && x.payload == "v1") return true;
    return false;
  }));


  {
    TestCli c(basicOpts(ns + "-late"));
    REQUIRE(c.waitConnected());
    c.cli->subscribe(ns + "/state");
    REQUIRE(c.waitMsgs([&](const std::vector<TestCli::Msg>& m) {
      for (const auto& x : m)
        if (x.topic == ns + "/state" && x.payload == "v1" && x.retain) return true;
      return false;
    }));
  }


  a.cli->abortForTest();
  REQUIRE(b.waitMsgs([&](const std::vector<TestCli::Msg>& m) {
    for (const auto& x : m)
      if (x.topic == ns + "/lwt" && x.payload == "offline") return true;
    return false;
  }));


  b.cli->publish(ns + "/state", "", true);
}

TEST_CASE("mqtt: Node handles retained discovery, press, reply, and HA republish") {
  if (!mqttTestEnabled()) return;
  const std::string ns = "dbtest" + uniqueSuffix();
  const std::string base = ns + "-db";     // base_topic
  const std::string prefix = ns + "-ha";   // discovery_prefix


  const int mesh_port = freeTcpPort();
  REQUIRE(mesh_port > 0);
  NodeOptions o;
  o.data_dir = ":memory:";
  o.name = "front";
  o.role = "door_station";
  o.door = "d_front";
  o.listen_addr = "127.0.0.1:" + std::to_string(mesh_port);

  {
    Bytes r = randomBytes(o.psk.size());
    std::copy(r.begin(), r.end(), o.psk.begin());
  }
  o.http_port = 0;
  o.caps_json = "{\"mqtt_reachable\":true,\"mains_power\":true,\"cpu_score\":10}";

  MeshSettings mt;
  mt.heartbeat_ms = 100;
  mt.suspect_ms = 300;
  mt.dead_ms = 500;
  mt.gossip_ms = 200;
  mt.sync_ms = 200;
  mt.claim_ttl_ms = 900;
  mt.reconnect_ms = 200;
  o.mesh_timing_template = mt;
  o.use_mesh_timing_template = true;

  Node node(o);
  std::mutex ui_mu;
  std::vector<std::string> ui;
  node.setUiEventCb([&](const std::string& e) {
    std::lock_guard<std::mutex> lk(ui_mu);
    ui.push_back(e);
  });
  REQUIRE(node.start());


  node.setConfigKey("doors.d_front",
                    "{\"building\":\"b_main\",\"label\":{\"ja\":\"正面玄関\"}}");
  node.setConfigKey("buildings.b_main", "{\"label\":{\"ja\":\"母屋\"}}");
  node.setConfigKey("integrations.mqtt.host", "\"127.0.0.1\"");
  node.setConfigKey("integrations.mqtt.port", "1883");
  node.setConfigKey("integrations.mqtt.base_topic", "\"" + base + "\"");
  node.setConfigKey("integrations.mqtt.discovery_prefix", "\"" + prefix + "\"");


  REQUIRE(waitFor([&] {
    auto st = json::parse(node.statusJson());
    return st && json::getString(json::get(st.get(), "bridge"), "mqtt") == "connected";
  }));



  std::this_thread::sleep_for(std::chrono::milliseconds(500));
  TestCli sub(basicOpts(ns + "-watch"));
  REQUIRE(sub.waitConnected());
  sub.cli->subscribe(prefix + "/#");
  sub.cli->subscribe(base + "/#");
  auto hasRetained = [&](const std::string& topic) {
    return [&, topic](const std::vector<TestCli::Msg>& m) {
      for (const auto& x : m)
        if (x.topic == topic && x.retain) return true;
      return false;
    };
  };
  REQUIRE(sub.waitMsgs(hasRetained(prefix + "/event/doorbell_d_front/config")));
  REQUIRE(sub.waitMsgs(hasRetained(prefix + "/binary_sensor/doorbell_d_front_motion/config")));
  REQUIRE(sub.waitMsgs(hasRetained(prefix + "/binary_sensor/doorbell_bridge_online/config")));
  REQUIRE(sub.waitMsgs(hasRetained(base + "/bridge/availability")));
  REQUIRE(sub.waitMsgs(hasRetained(base + "/d_front/availability")));
  const std::string nid = node.nodeId();
  REQUIRE(sub.waitMsgs(hasRetained(prefix + "/binary_sensor/doorbell_node_" +
                                   nid.substr(0, 8) + "/config")));
  REQUIRE(sub.waitMsgs(hasRetained(base + "/node/" + nid + "/availability")));


  size_t discovery_count_before = 0;
  {
    auto msgs = sub.snapshot();
    bool checked = false;
    for (const auto& m : msgs) {
      if (m.topic.compare(0, prefix.size(), prefix) == 0 &&
          m.topic.size() > 7 && m.topic.compare(m.topic.size() - 7, 7, "/config") == 0)
        discovery_count_before++;
      if (m.topic != prefix + "/event/doorbell_d_front/config" || checked) continue;
      auto d = json::parse(m.payload);
      REQUIRE(d);
      CHECK(json::getString(d.get(), "device_class") == "doorbell");
      CHECK(json::getString(d.get(), "state_topic") == base + "/d_front/event");
      CHECK(json::getString(d.get(), "unique_id") == "doorbell_d_front_event");
      CHECK(json::getString(d.get(), "availability_mode") == "all");
      cJSON* dev = json::get(d.get(), "device");
      REQUIRE(dev);
      CHECK(json::getString(dev, "name") == "正面玄関");
      CHECK(json::getString(dev, "manufacturer") == "ox");
      CHECK(json::getString(dev, "suggested_area") == "母屋");
      checked = true;
    }
    CHECK(checked);

    bool avail_ok = false;
    for (const auto& m : msgs)
      if (m.topic == base + "/bridge/availability" && m.payload == "online") avail_ok = true;
    CHECK(avail_ok);
  }


  const std::string mqtt_call = node.pressV2("d_front", "");
  REQUIRE(!mqtt_call.empty());
  REQUIRE(sub.waitMsgs([&](const std::vector<TestCli::Msg>& m) {
    for (const auto& x : m)
      if (x.topic == base + "/d_front/event" && !x.retain) {
        auto d = json::parse(x.payload);
        if (d && json::getString(d.get(), "event_type") == "press") return true;
      }
    return false;
  }));


  REQUIRE(sub.waitMsgs(hasRetained(prefix + "/sensor/doorbell_d_front_visitor_lang/config")));

  REQUIRE(sub.waitMsgs([&](const std::vector<TestCli::Msg>& m) {
    for (const auto& x : m)
      if (x.topic == base + "/d_front/attrs" && x.retain) {
        auto d = json::parse(x.payload);
        if (d && json::getString(d.get(), "visitor_lang") == "ja") return true;
      }
    return false;
  }));
  node.setVisitorLang("d_front", "en");
  REQUIRE(sub.waitMsgs([&](const std::vector<TestCli::Msg>& m) {
    for (const auto& x : m)
      if (x.topic == base + "/d_front/attrs") {
        auto d = json::parse(x.payload);
        if (d && json::getString(d.get(), "visitor_lang") == "en") return true;
      }
    return false;
  }));

  node.press("", "p_delivery");
  REQUIRE(sub.waitMsgs([&](const std::vector<TestCli::Msg>& m) {
    for (const auto& x : m)
      if (x.topic == base + "/d_front/event" && !x.retain) {
        auto d = json::parse(x.payload);
        if (d && json::getString(d.get(), "event_type") == "press" &&
            json::getString(d.get(), "purpose") == "p_delivery" &&
            json::getString(d.get(), "visitor_lang") == "en")
          return true;
      }
    return false;
  }));
  node.setVisitorLang("d_front", "ja");


  sub.cli->publish(base + "/d_front/reply/set",
                   "{\"reply_id\":\"qr_away\",\"call_id\":\"" + mqtt_call +
                       "\",\"stage_revision\":0}",
                   false);
  REQUIRE(waitFor([&] {
    std::lock_guard<std::mutex> lk(ui_mu);
    for (const auto& e : ui) {
      auto d = json::parse(e);
      if (d && json::getString(d.get(), "t") == "reply" &&
          json::getString(d.get(), "text") == "ただいま留守にしています")
        return true;
    }
    return false;
  }));

  sub.cli->publish(base + "/d_front/reply/set", "10分で戻ります", false);
  REQUIRE(waitFor([&] {
    std::lock_guard<std::mutex> lk(ui_mu);
    for (const auto& e : ui) {
      auto d = json::parse(e);
      if (d && json::getString(d.get(), "t") == "reply" &&
          json::getString(d.get(), "text") == "10分で戻ります")
        return true;
    }
    return false;
  }));


  REQUIRE(sub.waitMsgs(hasRetained(prefix + "/binary_sensor/doorbell_emergency/config")));
  {
    bool checked = false;
    for (const auto& m : sub.snapshot()) {
      if (m.topic != prefix + "/binary_sensor/doorbell_emergency/config" || checked) continue;
      auto d = json::parse(m.payload);
      REQUIRE(d);
      CHECK(json::getString(d.get(), "device_class") == "safety");
      CHECK(json::getString(d.get(), "state_topic") == base + "/emergency");
      CHECK(json::getString(d.get(), "unique_id") == "doorbell_emergency");
      checked = true;
    }
    CHECK(checked);
  }

  REQUIRE(sub.waitMsgs([&](const std::vector<TestCli::Msg>& m) {
    for (const auto& x : m)
      if (x.topic == base + "/emergency" && x.payload == "OFF" && x.retain) return true;
    return false;
  }));

  node.setEmergency(true, "admin");
  REQUIRE(sub.waitMsgs([&](const std::vector<TestCli::Msg>& m) {
    for (const auto& x : m)
      if (x.topic == base + "/emergency" && x.payload == "ON") return true;
    return false;
  }));
  node.setEmergency(false, "admin");
  REQUIRE(sub.waitMsgs([&](const std::vector<TestCli::Msg>& m) {
    size_t off = 0;
    for (const auto& x : m)
      if (x.topic == base + "/emergency" && x.payload == "OFF") off++;
    return off >= 2;
  }));


  sub.cli->publish(prefix + "/status", "online", false);
  REQUIRE(sub.waitMsgs([&](const std::vector<TestCli::Msg>& m) {
    size_t n = 0;
    for (const auto& x : m)
      if (x.topic.compare(0, prefix.size(), prefix) == 0 && x.topic.size() > 7 &&
          x.topic.compare(x.topic.size() - 7, 7, "/config") == 0)
        n++;
    return n >= discovery_count_before * 2;
  }));


  node.stop();
  REQUIRE(sub.waitMsgs([&](const std::vector<TestCli::Msg>& m) {
    for (const auto& x : m)
      if (x.topic == base + "/bridge/availability" && x.payload == "offline") return true;
    return false;
  }));




  {
    auto msgs = sub.snapshot();
    std::vector<std::string> topics;
    for (const auto& m : msgs) {
      if (std::find(topics.begin(), topics.end(), m.topic) == topics.end())
        topics.push_back(m.topic);
    }
    for (const auto& t : topics) sub.cli->publish(t, "", true);
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
  }
}
