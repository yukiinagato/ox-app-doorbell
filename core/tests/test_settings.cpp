#include <memory>
#include <string>
#include <vector>

#include "doctest.h"
#include "node/node.h"
#include "util/clock.h"
#include "util/json.h"
#include "util/runloop.h"

using namespace db;

namespace {

// One node on a manually pumped runloop: every public entry point is synchronous here, so a test
// can write configuration and read the materialized result without racing a background thread.
struct SettingsNode {
  SimClock clock{1'700'000'000'000LL, 0};
  Runloop loop{clock};
  std::unique_ptr<Node> node;
  std::vector<std::string> ui;

  explicit SettingsNode(const std::string& role = "indoor_panel",
                        const std::string& door = "", bool seed_defaults = true) {
    NodeOptions options;
    options.data_dir = ":memory:";
    options.name = "settings";
    options.role = role;
    options.door = door;
    options.listen_addr = "127.0.0.1:0";
    options.enable_beacon = false;
    options.http_port = 0;
    options.seed_default_config = seed_defaults;
    NodeDeps deps;
    deps.clock = &clock;
    deps.loop = &loop;
    node.reset(new Node(options, std::move(deps)));
    node->setUiEventCb([this](const std::string& event) { ui.push_back(event); });
    REQUIRE(node->start());
    loop.pumpDue();
  }

  ~SettingsNode() {
    if (node) node->stop();
  }

  void run(int64_t ms, int64_t step = 1000) {
    for (int64_t elapsed = 0; elapsed < ms; elapsed += step) {
      clock.advance(step);
      loop.pumpDue();
    }
  }

  // The published snapshots are rebuilt from the runloop, so drain it before reading one.
  json::Doc config() {
    loop.pumpDue();
    auto parsed = json::parse(node->configJson());
    REQUIRE(parsed);
    return parsed;
  }

  json::Doc status() {
    loop.pumpDue();
    auto parsed = json::parse(node->statusJson());
    REQUIRE(parsed);
    return parsed;
  }

  // Materialized value at a dot path, or nullptr.
  const cJSON* at(const std::string& path) {
    cached_config = config();
    cJSON* current = cached_config.get();
    size_t position = 0;
    while (current && position <= path.size()) {
      const size_t dot = path.find('.', position);
      const std::string part =
          path.substr(position, dot == std::string::npos ? std::string::npos : dot - position);
      current = json::get(current, part.c_str());
      if (dot == std::string::npos) return current;
      position = dot + 1;
    }
    return current;
  }

  int64_t intAt(const std::string& path, int64_t fallback = -1) {
    const cJSON* value = at(path);
    return cJSON_IsNumber(value) ? static_cast<int64_t>(value->valuedouble) : fallback;
  }

  std::string stringAt(const std::string& path) {
    const cJSON* value = at(path);
    return cJSON_IsString(value) ? value->valuestring : "";
  }

  size_t countEvents(const std::string& type) const {
    size_t total = 0;
    for (const auto& event : ui) {
      auto parsed = json::parse(event);
      if (parsed && json::getString(parsed.get(), "t") == type) total++;
    }
    return total;
  }

  json::Doc cached_config;
};

}  // namespace

TEST_CASE("config: the time keys accept only resolvable zones and bounded NTP settings") {
  SettingsNode fleet;
  CHECK(fleet.stringAt("time.zone") == "Asia/Tokyo");
  CHECK(fleet.intAt("time.ntp.interval_s") == 900);
  CHECK(fleet.intAt("integrations.tz_offset_min") == 540);

  fleet.node->setConfigKey("time.zone", "\"Europe/Paris\"");
  CHECK(fleet.stringAt("time.zone") == "Europe/Paris");
  fleet.node->setConfigKey("time.zone", "\"Mars/Olympus\"");
  CHECK(fleet.stringAt("time.zone") == "Europe/Paris");
  fleet.node->setConfigKey("time.zone", "42");
  CHECK(fleet.stringAt("time.zone") == "Europe/Paris");

  fleet.node->setConfigKey("time.ntp.interval_s", "3600");
  CHECK(fleet.intAt("time.ntp.interval_s") == 3600);
  fleet.node->setConfigKey("time.ntp.interval_s", "59");
  fleet.node->setConfigKey("time.ntp.interval_s", "86401");
  fleet.node->setConfigKey("time.ntp.interval_s", "900.5");
  CHECK(fleet.intAt("time.ntp.interval_s") == 3600);

  fleet.node->setConfigKey("time.ntp.servers", "[\"ntp.example.org:1123\"]");
  CHECK(cJSON_GetArraySize(fleet.at("time.ntp.servers")) == 1);
  fleet.node->setConfigKey("time.ntp.servers", "[]");
  fleet.node->setConfigKey("time.ntp.servers",
                           "[\"a\",\"b\",\"c\",\"d\",\"e\"]");
  fleet.node->setConfigKey("time.ntp.servers", "[\"http://ntp.example.org\"]");
  fleet.node->setConfigKey("time.ntp.servers", "\"ntp.example.org\"");
  CHECK(cJSON_GetArraySize(fleet.at("time.ntp.servers")) == 1);
  CHECK(json::getString(fleet.at("time.ntp"), "servers") == "");

  // A container write is validated as a whole so a batch cannot smuggle a bad member in. It is
  // exercised on an installation with no seeded leaves, because a leaf and its parent object are
  // independent CRDT keys and the leaf keeps winning after a parent write.
  SettingsNode bare("indoor_panel", "", /*seed_defaults=*/false);
  bare.node->setConfigKey("time", "{\"zone\":\"Asia/Seoul\",\"ntp\":{\"interval_s\":120}}");
  CHECK(bare.stringAt("time.zone") == "Asia/Seoul");
  CHECK(bare.intAt("time.ntp.interval_s") == 120);
  bare.node->setConfigKey("time", "{\"zone\":\"Nowhere/Nothing\"}");
  CHECK(bare.stringAt("time.zone") == "Asia/Seoul");
  bare.node->setConfigKey("time", "{\"zone\":\"Asia/Tokyo\",\"surprise\":1}");
  CHECK(bare.stringAt("time.zone") == "Asia/Seoul");
  bare.node->setConfigKey("time", "{\"zone\":\"Asia/Tokyo\",\"ntp\":{\"interval_s\":5}}");
  CHECK(bare.stringAt("time.zone") == "Asia/Seoul");
  bare.node->setConfigKey("time.ntp", "{\"enabled\":\"yes\"}");
  CHECK(bare.intAt("time.ntp.interval_s") == 120);
}

TEST_CASE("config: volume levels are bounded at every scope") {
  SettingsNode fleet;
  CHECK(fleet.intAt("audio.volume.call") == 80);
  CHECK(fleet.intAt("audio.volume.sos") == 100);
  CHECK(fleet.intAt("audio.volume.idle") == 60);

  fleet.node->setConfigKey("audio.volume.call", "45");
  CHECK(fleet.intAt("audio.volume.call") == 45);
  fleet.node->setConfigKey("audio.volume.call", "101");
  fleet.node->setConfigKey("audio.volume.call", "-1");
  fleet.node->setConfigKey("audio.volume.call", "\"loud\"");
  CHECK(fleet.intAt("audio.volume.call") == 45);

  // Container writes are validated as a whole. As above they are exercised without seeded
  // leaves, because a leaf key and its parent object are independent CRDT entries.
  SettingsNode bare("indoor_panel", "", /*seed_defaults=*/false);
  bare.node->setConfigKey("audio.volume", "{\"call\":10,\"sos\":20,\"idle\":30}");
  CHECK(bare.intAt("audio.volume.idle") == 30);
  bare.node->setConfigKey("audio.volume", "{\"call\":11,\"sos\":900}");
  bare.node->setConfigKey("audio.volume", "{\"call\":11,\"unknown\":1}");
  bare.node->setConfigKey("audio", "{\"volume\":{\"call\":11,\"sos\":900}}");
  CHECK(bare.intAt("audio.volume.call") == 10);
  bare.node->setConfigKey("audio", "{\"volume\":{\"call\":11,\"sos\":21}}");
  CHECK(bare.intAt("audio.volume.call") == 11);

  const std::string device = "devices." + fleet.node->nodeId();
  fleet.node->setConfigKey(device + ".local.audio.volume.call", "12");
  CHECK(fleet.intAt(device + ".local.audio.volume.call") == 12);
  fleet.node->setConfigKey(device + ".local.audio.volume.call", "120");
  CHECK(fleet.intAt(device + ".local.audio.volume.call") == 12);
  fleet.node->setConfigKey(device + ".local.audio", "{\"volume\":{\"sos\":7}}");
  CHECK(fleet.intAt(device + ".local.audio.volume.sos") == 7);
  fleet.node->setConfigKey(device + ".local.audio", "{\"volume\":{\"sos\":700}}");
  CHECK(fleet.intAt(device + ".local.audio.volume.sos") == 7);
}

TEST_CASE("config: the SOS trigger keys validate and the legacy hold duration stays accepted") {
  SettingsNode fleet;
  CHECK(fleet.stringAt("emergency.trigger.mode") == "slide");
  CHECK(fleet.intAt("emergency.trigger.countdown_s") == 3);

  fleet.node->setConfigKey("emergency.trigger.countdown_s", "5");
  CHECK(fleet.intAt("emergency.trigger.countdown_s") == 5);
  fleet.node->setConfigKey("emergency.trigger.countdown_s", "11");
  CHECK(fleet.intAt("emergency.trigger.countdown_s") == 5);
  // "hold" remains a valid stored value so a configuration written before the slide control
  // keeps replicating instead of being tombstoned by every node that reads it.
  fleet.node->setConfigKey("emergency.trigger.mode", "\"hold\"");
  CHECK(fleet.stringAt("emergency.trigger.mode") == "hold");
  fleet.node->setConfigKey("emergency.trigger.mode", "\"shake\"");
  CHECK(fleet.stringAt("emergency.trigger.mode") == "hold");
  fleet.node->setConfigKey("emergency.trigger.mode", "\"slide\"");
  CHECK(fleet.stringAt("emergency.trigger.mode") == "slide");

  fleet.node->setConfigKey("emergency.hold_to_trigger_s", "4");
  CHECK(fleet.intAt("emergency.hold_to_trigger_s") == 4);
  fleet.node->setConfigKey("emergency.hold_to_trigger_s", "99");
  CHECK(fleet.intAt("emergency.hold_to_trigger_s") == 4);
}

TEST_CASE("volumes: the effective level resolves device, cluster, then built-in defaults") {
  SettingsNode fleet;
  const std::string self = fleet.node->nodeId();

  auto audio = [&fleet](const std::string& device) {
    auto parsed = json::parse(fleet.node->audioJson(device));
    REQUIRE(parsed);
    return parsed;
  };

  auto seeded = audio("");
  CHECK(json::getString(seeded.get(), "device") == self);
  CHECK(json::getInt(seeded.get(), "call") == 80);
  CHECK(json::getInt(seeded.get(), "sos") == 100);
  CHECK(json::getInt(seeded.get(), "idle") == 60);
  CHECK(json::getString(seeded.get(), "source") == "cluster");

  fleet.node->setConfigKey("audio.volume.call", "55");
  fleet.node->setConfigKey("devices." + self + ".local.audio.volume.idle", "5");
  auto mixed = audio(self);
  CHECK(json::getInt(mixed.get(), "call") == 55);
  CHECK(json::getInt(mixed.get(), "idle") == 5);
  CHECK(json::getString(json::get(mixed.get(), "sources"), "call") == "cluster");
  CHECK(json::getString(json::get(mixed.get(), "sources"), "idle") == "device");
  CHECK(json::getString(mixed.get(), "source") == "device");

  // A device with no override of its own inherits the cluster values.
  auto other = audio("0f1e2d3c4b5a69788766554433221100");
  CHECK(json::getInt(other.get(), "idle") == 60);
  CHECK(json::getString(other.get(), "source") == "cluster");

  // An installation that predates audio.volume has no cluster defaults at all: the built-in
  // levels apply and the SOS level follows the legacy alarm volume.
  SettingsNode legacy_fleet("indoor_panel", "", /*seed_defaults=*/false);
  legacy_fleet.node->setConfigKey("emergency.alarm_volume", "42");
  auto legacy = json::parse(legacy_fleet.node->audioJson(""));
  REQUIRE(legacy);
  CHECK(json::getInt(legacy.get(), "sos") == 42);
  CHECK(json::getInt(legacy.get(), "call") == 80);
  CHECK(json::getInt(legacy.get(), "idle") == 60);
  CHECK(json::getString(legacy.get(), "source") == "default");
}

TEST_CASE("announcements: a door notice replicates, expires, and can be cleared") {
  SettingsNode fleet("door_station", "d_front");
  fleet.node->setConfigKey("doors.d_front", "{\"label\":{\"ja\":\"正面玄関\"}}");
  fleet.ui.clear();

  CHECK(fleet.node->setDoorNotice("d_unknown", "hello", 0) == false);
  CHECK(fleet.node->setDoorNotice("d_front", "", 0) == false);
  CHECK(fleet.node->setDoorNotice("d_front", std::string(201, 'x'), 0) == false);
  CHECK(fleet.countEvents("notice_changed") == 0);

  REQUIRE(fleet.node->setDoorNotice("d_front", "Deliveries to the side gate", 0));
  CHECK(fleet.stringAt("doors.d_front.notice.text") == "Deliveries to the side gate");
  CHECK(fleet.stringAt("doors.d_front.notice.from_device") == fleet.node->nodeId());
  CHECK(fleet.intAt("doors.d_front.notice.expires_ms") == 0);
  CHECK(fleet.intAt("doors.d_front.notice.created_ms") > 0);
  CHECK(fleet.countEvents("notice_changed") == 1);
  // The door label survives a notice write: the notice is a leaf, not a door replacement.
  CHECK(fleet.at("doors.d_front.label") != nullptr);

  // An open-ended notice is never pruned.
  fleet.run(180'000);
  CHECK(fleet.at("doors.d_front.notice") != nullptr);

  REQUIRE(fleet.node->clearDoorNotice("d_front"));
  CHECK(fleet.at("doors.d_front.notice") == nullptr);
  CHECK(fleet.countEvents("notice_changed") == 2);
  // Clearing an announcement that is not there is a no-op rather than an error.
  CHECK(fleet.node->clearDoorNotice("d_front"));
  CHECK(fleet.countEvents("notice_changed") == 2);

  // A notice with a deadline disappears on the housekeeping tick after that deadline.
  const int64_t expires = fleet.clock.wallMs() + 90'000;
  REQUIRE(fleet.node->setDoorNotice("d_front", "Back at 18:00", expires));
  CHECK(fleet.at("doors.d_front.notice") != nullptr);
  fleet.run(60'000);
  CHECK(fleet.at("doors.d_front.notice") != nullptr);
  fleet.run(120'000);
  CHECK(fleet.at("doors.d_front.notice") == nullptr);
  CHECK(fleet.countEvents("notice_changed") == 4);
}

TEST_CASE("power: a reported battery reaches status, capabilities, and the change event") {
  SettingsNode fleet;
  auto self_power = [&fleet]() {
    auto status = fleet.status();
    return json::Doc(cJSON_Duplicate(json::get(json::get(status.get(), "self"), "power"), 1));
  };
  CHECK(self_power() == nullptr);

  std::string reading = "{\"battery_pct\":82,\"charging\":false,\"mains\":false}";
  fleet.node->setPowerStateFn([&reading] { return reading; });
  fleet.loop.pumpDue();

  auto first = self_power();
  REQUIRE(first);
  CHECK(json::getInt(first.get(), "battery_pct") == 82);
  CHECK(json::getBool(first.get(), "charging") == false);
  CHECK(json::getBool(first.get(), "mains") == false);
  CHECK(fleet.countEvents("power_changed") == 1);
  // status.node carries the same object; status.self is the documented alias of it.
  auto status = fleet.status();
  CHECK(json::getInt(json::get(json::get(status.get(), "node"), "power"), "battery_pct") == 82);
  // A measured absence of mains power withdraws the mains_power capability.
  CHECK(json::getBool(json::get(json::get(status.get(), "node"), "caps"), "mains_power") ==
        false);
  // The self entry of the peer list carries it too, which is what the dashboard column reads.
  const cJSON* peers = json::get(status.get(), "peers");
  const cJSON* peer = nullptr;
  bool found_self = false;
  cJSON_ArrayForEach(peer, peers) {
    if (!json::getBool(peer, "self")) continue;
    found_self = true;
    CHECK(json::getInt(json::get(peer, "power"), "battery_pct") == 82);
  }
  CHECK(found_self);

  // A drift below five points is not worth an event.
  reading = "{\"battery_pct\":80,\"charging\":false,\"mains\":false}";
  fleet.run(60'000);
  CHECK(fleet.countEvents("power_changed") == 1);
  CHECK(json::getInt(self_power().get(), "battery_pct") == 80);

  // A charging flip always is, and so is a five-point move.
  reading = "{\"battery_pct\":80,\"charging\":true,\"mains\":true}";
  fleet.run(60'000);
  CHECK(fleet.countEvents("power_changed") == 2);
  CHECK(json::getBool(self_power().get(), "charging"));
  CHECK(json::getBool(json::get(json::get(fleet.status().get(), "node"), "caps"),
                      "mains_power"));
  reading = "{\"battery_pct\":74,\"charging\":true,\"mains\":true}";
  fleet.run(60'000);
  CHECK(fleet.countEvents("power_changed") == 3);

  // A device without a battery reports -1 so the shell can hide the indicator entirely.
  reading = "{\"battery_pct\":-1,\"charging\":false,\"mains\":true}";
  fleet.run(60'000);
  CHECK(json::getInt(self_power().get(), "battery_pct") == -1);

  // An unreadable sample leaves the last known reading in place.
  reading = "";
  fleet.run(60'000);
  CHECK(json::getInt(self_power().get(), "battery_pct") == -1);
}
