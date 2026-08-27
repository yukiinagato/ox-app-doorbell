// MQTT — パケット純関数の単体テスト (常時実行) と、稼働中 Mosquitto を使う結合テスト。
// 結合は既定ではスキップ — DB_MQTT_TEST=1 で有効化 (127.0.0.1:1883 に匿名可の broker が必要):
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

// ============================================================ 単体: パケット純関数

TEST_CASE("mqtt: remaining length の多バイト境界往復 (127/128/16383/16384)") {
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
  // 上限超は encode 不可
  uint8_t buf[4];
  CHECK(mqtt::encodeRemainingLength(268435456u, buf) == 0);
  // 継続ビットが立ったままデータが切れる → 0 (不足)
  uint8_t cont[2] = {0x80, 0x80};
  uint32_t v = 0;
  size_t used = 0;
  CHECK(mqtt::decodeRemainingLength(cont, 1, &v, &used) == 0);
  CHECK(mqtt::decodeRemainingLength(cont, 2, &v, &used) == 0);
  // 4 バイト目にも継続ビット → -1 (不正)
  uint8_t bad[5] = {0x80, 0x80, 0x80, 0x80, 0x01};
  CHECK(mqtt::decodeRemainingLength(bad, 5, &v, &used) == -1);
}

TEST_CASE("mqtt: CONNECT の encode (LWT/user/pass/keepalive/フラグ)") {
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
  // 可変ヘッダ: "MQTT" level=4 flags keepalive
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
  // ペイロード順: client_id, will topic, will payload, user, pass
  std::string all(p.body.begin() + 10, p.body.end());
  CHECK(all.find("cid") < all.find("w/t"));
  CHECK(all.find("w/t") < all.find("offline"));
  CHECK(all.find("offline") < all.find("user"));
  CHECK(all.find("user") < all.find("pw"));
}

TEST_CASE("mqtt: PUBLISH retain の encode/decode 往復") {
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
  // retain なし
  Bytes b2 = mqtt::encodePublish("a/b", "x", false);
  REQUIRE(mqtt::decodePacket(b2.data(), b2.size(), &p) == static_cast<int>(b2.size()));
  REQUIRE(mqtt::parsePublish(p, &topic, &payload, &retain));
  CHECK(!retain);
  // データ不足なら 0 (途中で切る)
  CHECK(mqtt::decodePacket(b.data(), b.size() - 1, &p) == 0);
  CHECK(mqtt::decodePacket(b.data(), 1, &p) == 0);
}

TEST_CASE("mqtt: 長い payload で remaining length が 2 バイトになる往復") {
  std::string big(200, 'x');  // 固定ヘッダ後 200+ バイト → RL 2 バイト
  Bytes b = mqtt::encodePublish("t", big, false);
  CHECK((b[1] & 0x80) != 0);  // RL 1 バイト目に継続ビット
  mqtt::Packet p;
  REQUIRE(mqtt::decodePacket(b.data(), b.size(), &p) == static_cast<int>(b.size()));
  std::string topic, payload;
  bool retain;
  REQUIRE(mqtt::parsePublish(p, &topic, &payload, &retain));
  CHECK(payload == big);
}

TEST_CASE("mqtt: SUBSCRIBE/PINGREQ/DISCONNECT の encode") {
  Bytes s = mqtt::encodeSubscribe(7, {"a/#", "b/+/c"});
  CHECK(s[0] == 0x82);  // 予約ビット 0b0010
  mqtt::Packet p;
  REQUIRE(mqtt::decodePacket(s.data(), s.size(), &p) == static_cast<int>(s.size()));
  CHECK(p.type == mqtt::kSubscribe);
  REQUIRE(p.body.size() >= 2);
  CHECK(((p.body[0] << 8) | p.body[1]) == 7);  // packet id
  std::string body(p.body.begin() + 2, p.body.end());
  CHECK(body.find("a/#") != std::string::npos);
  CHECK(body.find("b/+/c") != std::string::npos);
  CHECK(p.body.back() == 0);  // 最後の requested QoS = 0

  Bytes ping = mqtt::encodePingReq();
  REQUIRE(ping.size() == 2);
  CHECK(ping[0] == 0xC0);
  CHECK(ping[1] == 0x00);
  Bytes disc = mqtt::encodeDisconnect();
  REQUIRE(disc.size() == 2);
  CHECK(disc[0] == 0xE0);
  CHECK(disc[1] == 0x00);
  // 2 バイトパケットのデコード
  REQUIRE(mqtt::decodePacket(ping.data(), 2, &p) == 2);
  CHECK(p.type == mqtt::kPingReq);
  CHECK(p.body.empty());
}

// ============================================================ 結合 (DB_MQTT_TEST=1)

namespace {

bool mqttTestEnabled() { return std::getenv("DB_MQTT_TEST") != nullptr; }

constexpr const char* kBroker = "127.0.0.1";

// RealClock + threaded Runloop 上のテスト用クライアント。受信/接続を mutex+cv で記録。
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

  // pred(msgs) が真になるまで待つ
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

// 実時間の条件待ち (Node 統合用)
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

TEST_CASE("mqtt: クライアント単体 — 接続/PUBLISH retain/ソケット断で LWT が飛ぶ") {
  if (!mqttTestEnabled()) return;
  const std::string ns = "dbtest" + uniqueSuffix();

  // 購読側 B (先に subscribe しておく)
  TestCli b(basicOpts(ns + "-sub"));
  REQUIRE(b.waitConnected());
  b.cli->subscribe(ns + "/#");

  // A: LWT 付きで接続 → retain publish → DISCONNECT なしのソケット断
  MqttClient::Options ao = basicOpts(ns + "-pub");
  ao.will_topic = ns + "/lwt";
  ao.will_payload = "offline";
  ao.keepalive_s = 5;
  TestCli a(std::move(ao));
  REQUIRE(a.waitConnected());
  a.cli->publish(ns + "/state", "v1", true);

  // B にライブ配送 (この時点では retain フラグなし)
  REQUIRE(b.waitMsgs([&](const std::vector<TestCli::Msg>& m) {
    for (const auto& x : m)
      if (x.topic == ns + "/state" && x.payload == "v1") return true;
    return false;
  }));

  // 後から購読した C には retained として届く (retain フラグ付き)
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

  // A を DISCONNECT なしで即断 → broker が LWT を発行し B が受ける
  a.cli->abortForTest();
  REQUIRE(b.waitMsgs([&](const std::vector<TestCli::Msg>& m) {
    for (const auto& x : m)
      if (x.topic == ns + "/lwt" && x.payload == "offline") return true;
    return false;
  }));

  // 後始末: retained を消す (空 payload + retain)
  b.cli->publish(ns + "/state", "", true);
}

TEST_CASE("mqtt: Node 統合 — discovery(retain)/press/reply/HA 再起動再発行") {
  if (!mqttTestEnabled()) return;
  const std::string ns = "dbtest" + uniqueSuffix();
  const std::string base = ns + "-db";     // base_topic
  const std::string prefix = ns + "-ha";   // discovery_prefix

  // --- 実 TCP Node (sip なし・http なし)。caps で mqtt_bridge leader になれるようにする ---
  const int mesh_port = freeTcpPort();
  REQUIRE(mesh_port > 0);
  NodeOptions o;
  o.data_dir = ":memory:";
  o.name = "front";
  o.role = "door_station";
  o.door = "d_front";
  o.listen_addr = "127.0.0.1:" + std::to_string(mesh_port);
  // PSK はランダム — 同一ホストで動いている他の doorbell (dev demo 等) と合流しないため
  {
    Bytes r = randomBytes(o.psk.size());
    std::copy(r.begin(), r.end(), o.psk.begin());
  }
  o.http_port = 0;
  o.caps_json = "{\"mqtt_reachable\":true,\"mains_power\":true,\"cpu_score\":10}";
  // 実時間だが選主を速く (claim_ttl/3 = 300ms 周期で leaderTick)
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

  // door/building と MQTT 設定を投入 → デバウンス後に bridge が起動する
  node.setConfigKey("doors.d_front",
                    "{\"building\":\"b_main\",\"label\":{\"ja\":\"正面玄関\"}}");
  node.setConfigKey("buildings.b_main", "{\"label\":{\"ja\":\"母屋\"}}");
  node.setConfigKey("integrations.mqtt.host", "\"127.0.0.1\"");
  node.setConfigKey("integrations.mqtt.port", "1883");
  node.setConfigKey("integrations.mqtt.base_topic", "\"" + base + "\"");
  node.setConfigKey("integrations.mqtt.discovery_prefix", "\"" + prefix + "\"");

  // 接続まで待つ (leader 就任 → configure → CONNECT)
  REQUIRE(waitFor([&] {
    auto st = json::parse(node.statusJson());
    return st && json::getString(json::get(st.get(), "bridge"), "mqtt") == "connected";
  }));

  // --- discovery が retain で並ぶ: 発行後に購読して retained として受ける ---
  // (接続直後の discovery 発行が broker に落ち着くまで少し待ってから購読する)
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

  // discovery payload の中身を確認 (event entity)
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
      CHECK(json::getString(dev, "manufacturer") == "Keihan");
      CHECK(json::getString(dev, "suggested_area") == "母屋");
      checked = true;
    }
    CHECK(checked);
    // availability も検証: bridge/door が online (retain)
    bool avail_ok = false;
    for (const auto& m : msgs)
      if (m.topic == base + "/bridge/availability" && m.payload == "online") avail_ok = true;
    CHECK(avail_ok);
  }

  // --- press → event topic (非 retain) ---
  node.press("");
  REQUIRE(sub.waitMsgs([&](const std::vector<TestCli::Msg>& m) {
    for (const auto& x : m)
      if (x.topic == base + "/d_front/event" && !x.retain) {
        auto d = json::parse(x.payload);
        if (d && json::getString(d.get(), "event_type") == "press") return true;
      }
    return false;
  }));

  // --- 訪客言語 → <base>/<door>/attrs (retain) + press payload の purpose/visitor_lang ---
  REQUIRE(sub.waitMsgs(hasRetained(prefix + "/sensor/doorbell_d_front_visitor_lang/config")));
  // 初期値は主言語 ja (retain — 後から購読しても現在値が判る)
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
  // 用件付き按鈴 → event payload に purpose と visitor_lang が載る (HA の用件別自動化用)
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
  node.setVisitorLang("d_front", "ja");  // 後続の検証に影響させない

  // --- reply/set → uiNotify reply (via=mqtt で quickReply が回る) ---
  sub.cli->publish(base + "/d_front/reply/set", "qr_away", false);
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
  // 自由文も通る
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

  // --- SOS 緊急モード: discovery (safety) + <base>/emergency retain の ON/OFF ---
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
  // 初期状態 OFF (retain — 後から購読した sub に retained として届いている)
  REQUIRE(sub.waitMsgs([&](const std::vector<TestCli::Msg>& m) {
    for (const auto& x : m)
      if (x.topic == base + "/emergency" && x.payload == "OFF" && x.retain) return true;
    return false;
  }));
  // 発報 → ON / 解除 → OFF
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
    return off >= 2;  // 初期 OFF + 解除 OFF
  }));

  // --- HA 再起動 (homeassistant/status = online) → discovery 再発行 ---
  sub.cli->publish(prefix + "/status", "online", false);
  REQUIRE(sub.waitMsgs([&](const std::vector<TestCli::Msg>& m) {
    size_t n = 0;
    for (const auto& x : m)
      if (x.topic.compare(0, prefix.size(), prefix) == 0 && x.topic.size() > 7 &&
          x.topic.compare(x.topic.size() - 7, 7, "/config") == 0)
        n++;
    return n >= discovery_count_before * 2;  // 全 discovery がもう一巡届いた
  }));

  // --- 停止: graceful に bridge/availability=offline (retain) が出る ---
  node.stop();
  REQUIRE(sub.waitMsgs([&](const std::vector<TestCli::Msg>& m) {
    for (const auto& x : m)
      if (x.topic == base + "/bridge/availability" && x.payload == "offline") return true;
    return false;
  }));

  // 後始末: この試験が撒いた retained を消す (ns はユニークだが dev broker を汚さない)。
  // ライブ配送では retain フラグが 0 になるため、見えた全 topic を無条件でクリアする
  // (retained が無い topic への空 publish は無害)。
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
