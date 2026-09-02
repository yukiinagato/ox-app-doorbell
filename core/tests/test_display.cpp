

#include <memory>
#include <string>
#include <vector>

#include "doctest.h"
#include "mesh/mesh.h"
#include "node/node.h"
#include "util/clock.h"
#include "util/json.h"
#include "util/runloop.h"

using namespace db;

namespace {


struct DispFleet {
  SimClock clock{1'700'000'000'000LL, 0};
  Runloop loop{clock};
  InMemNet net{loop};
  std::array<uint8_t, 32> psk{};
  std::unique_ptr<Node> node;
  std::vector<std::string> ui;

  DispFleet() {
    psk.fill(0x5a);
    NodeOptions o;
    o.data_dir = ":memory:";
    o.name = "front";
    o.role = "door_station";
    o.door = "d_front";
    o.listen_addr = "A:1";
    o.advertise_addr = "A:1";
    o.psk = psk;
    o.enable_beacon = false;
    o.http_port = 0;
    o.seed_default_config = true;
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
    d.transport = net.makeTransport("A:1");
    d.discovery = net.makeDiscovery("A:1");
    node.reset(new Node(o, std::move(d)));
    node->setUiEventCb([this](const std::string& e) { ui.push_back(e); });
  }

  void run(int64_t ms, int64_t step = 10) {
    for (int64_t t = 0; t < ms; t += step) {
      clock.advance(step);
      loop.pumpDue();
    }
  }


  json::Doc lastDisplay() const {
    for (auto it = ui.rbegin(); it != ui.rend(); ++it) {
      auto d = json::parse(*it);
      if (d && json::getString(d.get(), "t") == "display") return d;
    }
    return nullptr;
  }

  size_t displayCount() const {
    size_t n = 0;
    for (const auto& e : ui) {
      auto d = json::parse(e);
      if (d && json::getString(d.get(), "t") == "display") n++;
    }
    return n;
  }
};

}  // namespace

TEST_CASE("display: publishes defaults and status once immediately after start") {
  DispFleet f;
  REQUIRE(f.node->start());
  f.loop.pumpDue();


  auto d = f.lastDisplay();
  REQUIRE(d);
  CHECK(json::getInt(d.get(), "brightness") == 70);
  CHECK(json::getBool(d.get(), "night") == false);
  CHECK(json::getBool(d.get(), "red_tint") == false);
  CHECK(json::getInt(d.get(), "screensaver_after_s") == 120);
  CHECK(json::getInt(d.get(), "pixel_shift_s") == 300);


  const size_t n0 = f.displayCount();
  f.run(90'000);
  CHECK(f.displayCount() == n0);


  auto st = json::parse(f.node->statusJson());
  REQUIRE(st);
  cJSON* disp = json::get(st.get(), "display");
  REQUIRE(disp);
  CHECK(json::getInt(disp, "brightness") == 70);
  CHECK(json::getInt(disp, "pixel_shift_s") == 300);

  f.node->stop();
}

TEST_CASE("display: config changes re-evaluate and the device-local value wins") {
  DispFleet f;
  REQUIRE(f.node->start());
  f.loop.pumpDue();

  f.node->setConfigKey("display.brightness", "55");
  f.loop.pumpDue();
  auto d = f.lastDisplay();
  REQUIRE(d);
  CHECK(json::getInt(d.get(), "brightness") == 55);


  f.node->setConfigKey("devices." + f.node->nodeId() + ".local.display.brightness", "40");
  f.loop.pumpDue();
  d = f.lastDisplay();
  REQUIRE(d);
  CHECK(json::getInt(d.get(), "brightness") == 40);


  f.node->setConfigKey("display.screensaver_after_s", "60");
  f.node->setConfigKey("display.pixel_shift_s", "120");
  f.loop.pumpDue();
  d = f.lastDisplay();
  REQUIRE(d);
  CHECK(json::getInt(d.get(), "screensaver_after_s") == 60);
  CHECK(json::getInt(d.get(), "pixel_shift_s") == 120);
  CHECK(json::getInt(d.get(), "brightness") == 40);

  f.node->stop();
}

TEST_CASE("display: night mode uses the adjusted clock and supports midnight spans") {
  DispFleet f;
  REQUIRE(f.node->start());
  f.loop.pumpDue();



  f.node->setConfigKey(
      "display.night",
      "{\"enabled\":true,\"from\":\"07:00\",\"to\":\"08:00\",\"brightness\":15,\"red_tint\":true}");
  f.loop.pumpDue();
  auto d = f.lastDisplay();
  REQUIRE(d);
  CHECK(json::getBool(d.get(), "night") == true);
  CHECK(json::getBool(d.get(), "red_tint") == true);
  CHECK(json::getInt(d.get(), "brightness") == 15);


  f.node->setConfigKey(
      "display.night",
      "{\"enabled\":true,\"from\":\"23:00\",\"to\":\"07:20\",\"brightness\":10,\"red_tint\":false}");
  f.loop.pumpDue();
  d = f.lastDisplay();
  REQUIRE(d);
  CHECK(json::getBool(d.get(), "night") == true);
  CHECK(json::getBool(d.get(), "red_tint") == false);
  CHECK(json::getInt(d.get(), "brightness") == 10);


  f.node->setConfigKey(
      "display.night",
      "{\"enabled\":true,\"from\":\"22:00\",\"to\":\"06:00\",\"brightness\":15,\"red_tint\":true}");
  f.loop.pumpDue();
  d = f.lastDisplay();
  REQUIRE(d);
  CHECK(json::getBool(d.get(), "night") == false);
  CHECK(json::getInt(d.get(), "brightness") == 70);


  f.node->setConfigKey(
      "display.night",
      "{\"enabled\":false,\"from\":\"07:00\",\"to\":\"08:00\",\"brightness\":15,\"red_tint\":true}");
  f.loop.pumpDue();
  d = f.lastDisplay();
  REQUIRE(d);
  CHECK(json::getBool(d.get(), "night") == false);

  f.node->stop();
}

TEST_CASE("display: periodic timer emits uiNotify when entering the night interval") {
  DispFleet f;
  REQUIRE(f.node->start());
  f.loop.pumpDue();


  f.node->setConfigKey(
      "display.night",
      "{\"enabled\":true,\"from\":\"07:15\",\"to\":\"09:00\",\"brightness\":20,\"red_tint\":true}");
  f.loop.pumpDue();
  auto d = f.lastDisplay();
  REQUIRE(d);
  CHECK(json::getBool(d.get(), "night") == false);


  bool flipped = false;
  for (int i = 0; i < 18 && !flipped; i++) {
    f.run(10'000);
    auto cur = f.lastDisplay();
    if (cur && json::getBool(cur.get(), "night")) flipped = true;
  }
  CHECK(flipped);
  d = f.lastDisplay();
  REQUIRE(d);
  CHECK(json::getInt(d.get(), "brightness") == 20);
  CHECK(json::getBool(d.get(), "red_tint") == true);

  f.node->stop();
}
