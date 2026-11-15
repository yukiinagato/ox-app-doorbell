#include <memory>
#include <string>
#include <vector>

#include "doctest.h"
#include "doorbell/doorbell.h"
#include "mesh/mesh.h"
#include "node/node.h"
#include "sensors/mops_vida.h"
#include "util/clock.h"
#include "util/json.h"
#include "util/runloop.h"

using namespace db;

namespace {

std::vector<uint8_t> hex(const std::string& s) {
  std::vector<uint8_t> out;
  for (size_t i = 0; i + 1 < s.size(); i += 2)
    out.push_back(static_cast<uint8_t>(std::stoi(s.substr(i, 2), nullptr, 16)));
  return out;
}

mops_vida::Packet parseHex(const std::string& s) {
  const auto bytes = hex(s);
  return mops_vida::parse(bytes.data(), bytes.size());
}

struct AirFleet {
  SimClock clock{1'700'000'000'000LL, 0};
  Runloop loop{clock};
  InMemNet net{loop};
  std::array<uint8_t, 32> psk{};

  struct N {
    std::unique_ptr<Node> node;
    std::vector<std::string> ui;
    size_t count(const std::string& type) const {
      size_t n = 0;
      for (const auto& e : ui) {
        auto d = json::parse(e);
        if (d && json::getString(d.get(), "t") == type) n++;
      }
      return n;
    }
  };
  std::vector<std::unique_ptr<N>> nodes;

  AirFleet() { psk.fill(0x5a); }

  N& add(const std::string& addr, const std::string& name, const std::string& role,
         const std::string& door, bool seed) {
    NodeOptions o;
    o.data_dir = ":memory:";
    o.name = name;
    o.role = role;
    o.door = door;
    o.listen_addr = addr;
    o.advertise_addr = addr;
    o.psk = psk;
    o.enable_beacon = false;
    o.http_port = 0;
    o.seed_default_config = seed;
    MeshSettings m;
    m.heartbeat_ms = 30;
    m.suspect_ms = 90;
    m.dead_ms = 150;
    m.gossip_ms = 50;
    m.sync_ms = 50;
    m.claim_ttl_ms = 300;
    m.reconnect_ms = 50;
    o.mesh_timing_template = m;
    o.use_mesh_timing_template = true;
    NodeDeps d;
    d.clock = &clock;
    d.loop = &loop;
    d.transport = net.makeTransport(addr);
    d.discovery = net.makeDiscovery(addr);
    auto n = std::make_unique<N>();
    N* raw = n.get();
    n->node.reset(new Node(o, std::move(d)));
    n->node->setUiEventCb([raw](const std::string& e) { raw->ui.push_back(e); });
    nodes.push_back(std::move(n));
    return *nodes.back();
  }

  void run(int64_t ms, int64_t step = 10) {
    for (int64_t t = 0; t < ms; t += step) {
      clock.advance(step);
      loop.pumpDue();
    }
  }
};

bool writeOk(Node& node, const std::string& key, const std::string& value) {
  auto r = json::parse(node.setConfigJson(key, value));
  return r && json::getBool(r.get(), "ok");
}

json::Doc airDoc(Node& node) { return json::parse(node.airQualityJson()); }

void feed(Node& node, const std::string& sensor, const std::string& packet_hex) {
  const auto bytes = hex(packet_hex);
  node.airSensorPacket(sensor, bytes.data(), bytes.size());
}

}  // namespace

TEST_CASE("air quality: MOPS VIDA packets parse with the reference vectors") {
  auto sensor = parseHex("AA5006001E00005F52358C025F52358D05");
  CHECK(sensor.kind == mops_vida::PacketKind::sensor);
  CHECK(sensor.pm25 == 30);
  auto battery = parseHex("AA500464640000000000000000000000000000C6");
  CHECK(battery.kind == mops_vida::PacketKind::battery);
  CHECK(battery.battery_pct == 100);
  CHECK_FALSE(battery.charging);
  auto version = parseHex("AA5400100001000110");
  CHECK(version.kind == mops_vida::PacketKind::version);
  CHECK(version.firmware == "1.16");
  CHECK(parseHex("AA1601C1").kind == mops_vida::PacketKind::other);
  // One flipped checksum bit, a wrong header, and a truncated frame are all rejected.
  CHECK(parseHex("AA5006001E00005F52358C025F52358D04").kind == mops_vida::PacketKind::invalid);
  CHECK(parseHex("AB5006001E00005F52358C025F52358D06").kind == mops_vida::PacketKind::invalid);
  CHECK(parseHex("AA").kind == mops_vida::PacketKind::invalid);
  CHECK(mops_vida::parse(nullptr, 0).kind == mops_vida::PacketKind::invalid);
}

TEST_CASE("air quality: set-RTC command matches the reference encoding") {
  // AA095F5A2FE883 is 2020-09-10T13:53:44Z in the reference packet tests.
  CHECK(mops_vida::toHex(mops_vida::setRtcCommand(1'599'746'024'000LL)) == "aa095f5a2fe883");
}

TEST_CASE("air quality: PM2.5 levels follow the six published bands") {
  CHECK(std::string(air_quality::levelFor(0)) == "good");
  CHECK(std::string(air_quality::levelFor(9)) == "good");
  CHECK(std::string(air_quality::levelFor(10)) == "moderate");
  CHECK(std::string(air_quality::levelFor(35)) == "moderate");
  CHECK(std::string(air_quality::levelFor(36)) == "sensitive");
  CHECK(std::string(air_quality::levelFor(55)) == "sensitive");
  CHECK(std::string(air_quality::levelFor(56)) == "unhealthy");
  CHECK(std::string(air_quality::levelFor(125)) == "unhealthy");
  CHECK(std::string(air_quality::levelFor(126)) == "very_unhealthy");
  CHECK(std::string(air_quality::levelFor(225)) == "very_unhealthy");
  CHECK(std::string(air_quality::levelFor(226)) == "hazardous");
  CHECK(std::string(air_quality::levelFor(-1)) == "unknown");
}

TEST_CASE("air quality: configuration is validated") {
  AirFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true);
  REQUIRE(a.node->start());
  f.run(200);
  const std::string self = a.node->nodeId();
  CHECK(writeOk(*a.node, "air_sensors.s_hall",
                R"({"name":"Hall","host":")" + self + R"(","address":"AA:BB","kind":"mops_vida_pm25"})"));
  CHECK_FALSE(writeOk(*a.node, "air_sensors.s_hall2", R"({"name":"Hall","host":"x"})"));
  CHECK_FALSE(writeOk(*a.node, "air_sensors.s_hall2",
                      R"({"name":"Hall","host":"x","address":"y","kind":"other"})"));
  CHECK_FALSE(writeOk(*a.node, "air_sensors.bad.id", R"("x")"));
  CHECK_FALSE(writeOk(*a.node, "air_sensors.s_hall.colour", R"("red")"));
  CHECK(writeOk(*a.node, "air_sensors.s_hall.name", R"("Entrance")"));
  CHECK_FALSE(writeOk(*a.node, "air_sensors.s_hall.name", R"("")"));
  CHECK(writeOk(*a.node, "devices." + self + ".local.air_quality",
                R"({"show":true,"sensor":"s_hall","host":true})"));
  CHECK(writeOk(*a.node, "devices." + self + ".local.air_quality.show", "false"));
  CHECK_FALSE(writeOk(*a.node, "devices." + self + ".local.air_quality.show", R"("yes")"));
  CHECK_FALSE(writeOk(*a.node, "devices." + self + ".local.air_quality.sensor", R"("a b")"));
  CHECK_FALSE(writeOk(*a.node, "devices." + self + ".local.air_quality",
                      R"({"show":true,"extra":1})"));
  CHECK(writeOk(*a.node, "air_sensors.s_hall", "null"));
}

TEST_CASE("air quality: a reading hosted on one device is displayed on another") {
  AirFleet f;
  auto& door = f.add("A:1", "front", "door_station", "d_front", true);
  auto& panel = f.add("B:1", "kitchen", "indoor_panel", "", false);
  REQUIRE(door.node->start());
  REQUIRE(panel.node->start());
  f.run(1500);
  const std::string host = door.node->nodeId();
  const std::string viewer = panel.node->nodeId();

  // Nothing is shown until an administrator turns the display on.
  CHECK(json::getString(airDoc(*panel.node).get(), "state") == "hidden");

  REQUIRE(writeOk(*panel.node, "devices." + host + ".local.air_quality.host", "true"));
  REQUIRE(writeOk(*panel.node, "air_sensors.s_hall",
                  R"({"name":"Hall","host":")" + host + R"(","address":"AA:BB:CC:DD:EE:FF"})"));
  REQUIRE(writeOk(*panel.node, "devices." + viewer + ".local.air_quality",
                  R"({"show":true,"sensor":"s_hall"})"));
  f.run(800);

  auto plan = json::parse(door.node->airSensorPlanJson());
  REQUIRE(plan);
  CHECK(json::getBool(plan.get(), "host"));
  CHECK(json::getBool(plan.get(), "scan"));
  const cJSON* sensors = json::get(plan.get(), "sensors");
  REQUIRE(cJSON_GetArraySize(sensors) == 1);
  CHECK(json::getString(cJSON_GetArrayItem(sensors, 0), "address") == "AA:BB:CC:DD:EE:FF");
  CHECK(door.count("air_sensor_plan_changed") >= 1);
  // The viewer hosts nothing and has no plan.
  CHECK_FALSE(json::getBool(json::parse(panel.node->airSensorPlanJson()).get(), "host"));

  CHECK(json::getString(airDoc(*panel.node).get(), "state") == "waiting");
  const size_t before = panel.count("air_quality_changed");

  feed(*door.node, "s_hall", "AA5006001E00005F52358C025F52358D05");
  feed(*door.node, "s_hall", "AA500464640000000000000000000000000000C6");
  door.node->airSensorReport(
      R"({"ble":"ready","discovered":[{"address":"AA:BB:CC:DD:EE:FF","name":"x","rssi":-60}]})");
  f.run(800);

  auto shown = airDoc(*panel.node);
  CHECK(json::getString(shown.get(), "state") == "ok");
  CHECK(json::getInt(shown.get(), "pm25") == 30);
  CHECK(json::getString(shown.get(), "level") == "moderate");
  CHECK(json::getString(shown.get(), "name") == "Hall");
  CHECK(json::getInt(shown.get(), "battery_pct") == 100);
  CHECK(panel.count("air_quality_changed") > before);

  // The administrator view lists the sensor with its reading and the scanning host's results.
  auto status = json::parse(panel.node->statusJson());
  const cJSON* air = json::get(status.get(), "air_quality");
  REQUIRE(cJSON_GetArraySize(json::get(air, "sensors")) == 1);
  CHECK(json::getInt(json::get(cJSON_GetArrayItem(json::get(air, "sensors"), 0), "reading"),
                     "pm25") == 30);
  bool saw_host = false;
  const cJSON* h = nullptr;
  cJSON_ArrayForEach(h, json::get(air, "hosts")) {
    if (json::getString(h, "device") != host) continue;
    saw_host = true;
    CHECK(json::getString(h, "ble") == "ready");
    CHECK(cJSON_GetArraySize(json::get(h, "discovered")) == 1);
  }
  CHECK(saw_host);

  // A packet for a sensor bound to another host is ignored.
  feed(*panel.node, "s_hall", "AA5006009600005F52358C025F52358D7D");
  f.run(200);
  CHECK(json::getInt(airDoc(*panel.node).get(), "pm25") == 30);

  // Without new readings the value goes stale after fifteen minutes.
  f.run(16 * 60 * 1000, 1000);
  CHECK(json::getString(airDoc(*panel.node).get(), "state") == "stale");

  // Turning the display off hides it again.
  REQUIRE(writeOk(*panel.node, "devices." + viewer + ".local.air_quality.show", "false"));
  f.run(200);
  CHECK(json::getString(airDoc(*panel.node).get(), "state") == "hidden");
}

TEST_CASE("air quality: a shell cannot inject the Core-owned runtime section") {
  std::string projected;
  REQUIRE(projectMeshRuntimeJson(
      R"({"air_sensors":{"ble":"bogus","readings":{"s1":{"pm25":99999,"link":"weird","x":1}},)"
      R"("discovered":[{"address":"","name":"n"}]}})",
      &projected));
  auto doc = json::parse(projected);
  const cJSON* air = json::get(doc.get(), "air_sensors");
  CHECK(json::getString(air, "ble") == "unknown");
  const cJSON* r = json::get(json::get(air, "readings"), "s1");
  CHECK(json::getInt(r, "pm25") == 2000);
  CHECK(json::getString(r, "link") == "disconnected");
  CHECK_FALSE(json::get(r, "x"));
  CHECK(cJSON_GetArraySize(json::get(air, "discovered")) == 0);
}

TEST_CASE("air quality: C ABI entry points") {
  CHECK(db_core_air_quality_json(nullptr) == nullptr);
  CHECK(db_core_air_sensor_plan_json(nullptr) == nullptr);
  CHECK(db_core_air_sensor_connect_command_hex(nullptr) == nullptr);
  db_core_air_sensor_packet(nullptr, "s", nullptr, 0);
  db_core_air_sensor_report_json(nullptr, "{}");

  db_platform_v2 platform{};
  platform.struct_size = sizeof(platform);
  platform.version = DB_PLATFORM_V2_VERSION;
  db_core* core = db_core_create_v2(
      &platform, ":memory:",
      "{\"name\":\"air-capi\",\"role\":\"indoor_panel\",\"listen_port\":0,\"http_port\":0}");
  REQUIRE(core != nullptr);
  REQUIRE(db_core_start(core) == 0);
  char* shown = db_core_air_quality_json(core);
  REQUIRE(shown != nullptr);
  CHECK(std::string(shown).find("\"state\":\"hidden\"") != std::string::npos);
  db_free(shown);
  char* plan = db_core_air_sensor_plan_json(core);
  REQUIRE(plan != nullptr);
  CHECK(std::string(plan).find("6e400003-b5a3-f393-e0a9-e50e24dcca9e") != std::string::npos);
  db_free(plan);
  char* cmd = db_core_air_sensor_connect_command_hex(core);
  REQUIRE(cmd != nullptr);
  CHECK(std::string(cmd).rfind("aa09", 0) == 0);
  CHECK(std::string(cmd).size() == 14);
  db_free(cmd);
  db_core_stop(core);
  db_core_destroy(core);
}

TEST_CASE("air quality: shell features reach the status document") {
  AirFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true);
  a.node->setRuntimeCapabilities(
      R"({"features":{"air_quality_display_v1":true,"ble_air_sensor_v1":true}})");
  REQUIRE(a.node->start());
  f.run(300);
  auto status = json::parse(a.node->statusJson());
  const cJSON* features = json::get(status.get(), "features");
  CHECK(json::getBool(features, "air_quality_display_v1"));
  CHECK(json::getBool(features, "ble_air_sensor_v1"));

  AirFleet g;
  auto& b = g.add("A:1", "front", "door_station", "d_front", true);
  REQUIRE(b.node->start());
  g.run(300);
  auto plain = json::parse(b.node->statusJson());
  CHECK_FALSE(json::getBool(json::get(plain.get(), "features"), "air_quality_display_v1"));
  CHECK_FALSE(json::getBool(json::get(plain.get(), "features"), "ble_air_sensor_v1"));
}
