#include <unistd.h>

#include <algorithm>

#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include "doctest.h"
#include "node/node.h"
#include "util/clock.h"
#include "util/json.h"
#include "util/common.h"
#include "util/runloop.h"
#include "util/tz.h"

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
    // A non-zero PSK is what "paired" means, which is the state these settings are written in.
    options.psk.fill(0x5a);
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

// Wall milliseconds of a UTC civil instant, for the appearance-schedule cases.
int64_t utcMsForAppearance(int year, int month, int day, int hour, int minute) {
  return tz::daysFromCivil(year, month, day) * 86'400'000LL + hour * 3'600'000LL +
         minute * 60'000LL;
}

// A flat 8-bit greyscale PNG with stored-deflate blocks, so a multi-megapixel fixture needs no
// compressor and stays about one byte per pixel on disk.
Bytes makeTestGreyPng(int width, int height, const Bytes& raw) {
  static const auto crc32Of = [](const uint8_t* data, size_t len) {
    static uint32_t table[256];
    static bool ready = false;
    if (!ready) {
      for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
        table[i] = c;
      }
      ready = true;
    }
    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < len; i++) crc = table[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
    return crc ^ 0xFFFFFFFFu;
  };
  auto append_be = [](Bytes& out, uint32_t value) {
    out.push_back(static_cast<uint8_t>(value >> 24));
    out.push_back(static_cast<uint8_t>(value >> 16));
    out.push_back(static_cast<uint8_t>(value >> 8));
    out.push_back(static_cast<uint8_t>(value));
  };
  auto append_chunk = [&](Bytes& out, const char tag[4], const Bytes& payload) {
    append_be(out, static_cast<uint32_t>(payload.size()));
    Bytes body(tag, tag + 4);
    body.insert(body.end(), payload.begin(), payload.end());
    out.insert(out.end(), body.begin(), body.end());
    append_be(out, crc32Of(body.data(), body.size()));
  };

  uint32_t a = 1, b = 0;
  for (uint8_t byte : raw) {
    a = (a + byte) % 65521;
    b = (b + a) % 65521;
  }
  Bytes zlib{0x78, 0x01};
  size_t offset = 0;
  while (offset < raw.size()) {
    const size_t block = std::min<size_t>(raw.size() - offset, 65535);
    const bool last = offset + block >= raw.size();
    zlib.push_back(last ? 1 : 0);
    zlib.push_back(static_cast<uint8_t>(block & 0xFF));
    zlib.push_back(static_cast<uint8_t>(block >> 8));
    zlib.push_back(static_cast<uint8_t>((~block) & 0xFF));
    zlib.push_back(static_cast<uint8_t>((~block) >> 8));
    zlib.insert(zlib.end(), raw.begin() + static_cast<std::ptrdiff_t>(offset),
                raw.begin() + static_cast<std::ptrdiff_t>(offset + block));
    offset += block;
  }
  append_be(zlib, (b << 16) | a);

  Bytes header;
  append_be(header, static_cast<uint32_t>(width));
  append_be(header, static_cast<uint32_t>(height));
  header.push_back(8);
  header.push_back(0);
  header.push_back(0);
  header.push_back(0);
  header.push_back(0);

  Bytes png{0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A};
  append_chunk(png, "IHDR", header);
  append_chunk(png, "IDAT", zlib);
  append_chunk(png, "IEND", {});
  return png;
}

std::string settingsTempDir() {
  char path[] = "/tmp/doorbell_settings_doors_XXXXXX";
  char* created = mkdtemp(path);
  REQUIRE(created != nullptr);
  return created;
}

void removeSettingsTempDir(const std::string& dir) {
  for (const char* name : {"doorbell.db", "doorbell.db-wal", "doorbell.db-shm"})
    std::remove((dir + "/" + name).c_str());
  ::rmdir((dir + "/assets").c_str());
  ::rmdir(dir.c_str());
}

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

TEST_CASE("announcements: a cluster-wide notice is overridden by a door-specific one") {
  SettingsNode fleet("door_station", "d_front");
  fleet.node->setConfigKey("doors.d_front", "{\"label\":{\"ja\":\"正面玄関\"}}");
  fleet.node->setConfigKey("doors.d_back", "{\"label\":{\"ja\":\"勝手口\"}}");
  fleet.ui.clear();

  // status reports an explicit JSON null when a door has no announcement, so "absent" is
  // distinguishable from "this door is not configured".
  auto doorNotice = [&fleet](const std::string& door) {
    auto status = fleet.status();
    const cJSON* entry = json::get(json::get(status.get(), "doors"), door.c_str());
    const cJSON* notice = json::get(entry, "notice");
    if (!notice || cJSON_IsNull(notice)) return json::Doc{};
    return json::Doc(cJSON_Duplicate(notice, 1));
  };

  REQUIRE(fleet.node->setDoorNotice("*", "House-wide message", 0));
  CHECK(fleet.stringAt("notice.global.text") == "House-wide message");
  // Every door shows it, tagged with the scope it came from.
  for (const char* door : {"d_front", "d_back"}) {
    auto notice = doorNotice(door);
    REQUIRE(notice);
    CHECK(json::getString(notice.get(), "text") == "House-wide message");
    CHECK(json::getString(notice.get(), "scope") == "global");
  }
  // The wildcard target is reported so a shell can refresh every door at once.
  bool wildcard = false;
  for (const auto& event : fleet.ui) {
    auto parsed = json::parse(event);
    if (parsed && json::getString(parsed.get(), "t") == "notice_changed" &&
        json::getString(parsed.get(), "door") == "*")
      wildcard = true;
  }
  CHECK(wildcard);

  // A door-specific announcement wins for that door only.
  REQUIRE(fleet.node->setDoorNotice("d_front", "Side gate today", 0));
  auto front = doorNotice("d_front");
  REQUIRE(front);
  CHECK(json::getString(front.get(), "text") == "Side gate today");
  CHECK(json::getString(front.get(), "scope") == "door");
  auto back = doorNotice("d_back");
  REQUIRE(back);
  CHECK(json::getString(back.get(), "text") == "House-wide message");

  // Clearing the door-specific one falls back to the cluster-wide message rather than to none.
  REQUIRE(fleet.node->clearDoorNotice("d_front"));
  auto restored = doorNotice("d_front");
  REQUIRE(restored);
  CHECK(json::getString(restored.get(), "text") == "House-wide message");
  CHECK(json::getString(restored.get(), "scope") == "global");

  // The cluster-wide announcement expires on the same housekeeping tick.
  REQUIRE(fleet.node->setDoorNotice("*", "Until six", fleet.clock.wallMs() + 90'000));
  fleet.run(180'000);
  CHECK(fleet.at("notice.global") == nullptr);
  CHECK(doorNotice("d_front") == nullptr);
}

TEST_CASE("config: the announcement presets are seeded once and stay editable") {
  SettingsNode fleet;
  const cJSON* presets = fleet.at("notice.presets");
  REQUIRE(cJSON_IsArray(presets));
  CHECK(cJSON_GetArraySize(presets) == 3);
  CHECK(json::getString(cJSON_GetArrayItem(presets, 0), "id") == "np_absent");
  CHECK_FALSE(json::getString(cJSON_GetArrayItem(presets, 0), "text").empty());

  fleet.node->setConfigKey("notice.presets",
                           "[{\"id\":\"np_one\",\"text\":\"Only one\"}]");
  CHECK(cJSON_GetArraySize(fleet.at("notice.presets")) == 1);
  // At most eight, each with a usable id and a bounded message.
  fleet.node->setConfigKey(
      "notice.presets",
      "[{\"id\":\"a\",\"text\":\"1\"},{\"id\":\"b\",\"text\":\"2\"},"
      "{\"id\":\"c\",\"text\":\"3\"},{\"id\":\"d\",\"text\":\"4\"},"
      "{\"id\":\"e\",\"text\":\"5\"},{\"id\":\"f\",\"text\":\"6\"},"
      "{\"id\":\"g\",\"text\":\"7\"},{\"id\":\"h\",\"text\":\"8\"},"
      "{\"id\":\"i\",\"text\":\"9\"}]");
  fleet.node->setConfigKey("notice.presets", "[{\"id\":\"a\",\"text\":\"\"}]");
  fleet.node->setConfigKey("notice.presets", "[{\"id\":\"bad id\",\"text\":\"x\"}]");
  fleet.node->setConfigKey("notice.presets",
                           "[{\"id\":\"a\",\"text\":\"1\"},{\"id\":\"a\",\"text\":\"2\"}]");
  fleet.node->setConfigKey("notice.presets", "[{\"id\":\"a\"}]");
  fleet.node->setConfigKey("notice.presets", "{\"a\":\"1\"}");
  CHECK(cJSON_GetArraySize(fleet.at("notice.presets")) == 1);
  CHECK(json::getString(cJSON_GetArrayItem(fleet.at("notice.presets"), 0), "id") == "np_one");
}

TEST_CASE("doors: the unlock control appears only when an unlock action exists") {
  SettingsNode fleet("door_station", "d_front");
  fleet.node->setConfigKey("doors.d_front", "{\"label\":{\"ja\":\"正面玄関\"}}");

  auto unlock = [&fleet]() {
    auto status = fleet.status();
    const cJSON* entry = json::get(json::get(status.get(), "doors"), "d_front");
    return json::Doc(cJSON_Duplicate(json::get(entry, "unlock"), 1));
  };

  // Nothing configured: no command, and the control is hidden by default.
  auto initial = unlock();
  REQUIRE(initial);
  CHECK_FALSE(json::getBool(initial.get(), "configured"));
  CHECK_FALSE(json::getBool(initial.get(), "show_button"));
  CHECK(json::getString(initial.get(), "source") == "default");
  CHECK(fleet.node->openDoor("d_front") == false);

  // The existing feature-code action is what makes the door openable.
  fleet.node->setConfigKey(
      "sip.dtmf_actions",
      "{\"*1\":{\"type\":\"ha_command\",\"command\":\"unlock\",\"door\":\"self\"}}");
  auto configured = unlock();
  REQUIRE(configured);
  CHECK(json::getBool(configured.get(), "configured"));
  CHECK(json::getBool(configured.get(), "show_button"));
  CHECK(json::getString(configured.get(), "command") == "unlock");
  CHECK(json::getString(configured.get(), "source") == "default");
  CHECK(fleet.node->openDoor("d_front"));
  CHECK(fleet.node->openDoor("d_missing") == false);

  // An administrator may hide it even though it works, or show it even though it does not.
  fleet.node->setConfigKey("doors.d_front.unlock.show_button", "false");
  CHECK_FALSE(json::getBool(unlock().get(), "show_button"));
  CHECK(json::getString(unlock().get(), "source") == "admin");
  CHECK(fleet.node->openDoor("d_front"));

  // A door may name its own command, which wins over the feature-code default.
  fleet.node->setConfigKey("doors.d_front.unlock.command", "\"gate\"");
  CHECK(json::getString(unlock().get(), "command") == "gate");
  fleet.node->setConfigKey("doors.d_front.unlock.command", "\"bad command\"");
  CHECK(json::getString(unlock().get(), "command") == "gate");
  fleet.node->setConfigKey("doors.d_front.unlock.show_button", "\"yes\"");
  CHECK(json::getString(unlock().get(), "source") == "admin");
}

TEST_CASE("display: appearance resolves in the configured zone and per device") {
  SettingsNode fleet;
  auto appearance = [&fleet]() {
    auto status = fleet.status();
    return json::Doc(
        cJSON_Duplicate(json::get(json::get(status.get(), "display"), "appearance"), 1));
  };

  auto initial = appearance();
  REQUIRE(initial);
  CHECK(json::getString(initial.get(), "configured") == "auto_system");
  CHECK(json::getBool(initial.get(), "follow_system"));

  // An explicit choice is reported as-is and stops the shell consulting the system.
  fleet.node->setConfigKey("display.appearance", "\"dark\"");
  CHECK(json::getString(appearance().get(), "effective") == "dark");
  CHECK_FALSE(json::getBool(appearance().get(), "follow_system"));
  fleet.node->setConfigKey("display.appearance", "\"light\"");
  CHECK(json::getString(appearance().get(), "effective") == "light");
  fleet.node->setConfigKey("display.appearance", "\"sepia\"");
  CHECK(json::getString(appearance().get(), "configured") == "light");

  // auto_schedule is evaluated against the cluster time zone, not UTC.
  fleet.node->setConfigKey("time.zone", "\"Asia/Tokyo\"");
  fleet.node->setConfigKey("display.appearance", "\"auto_schedule\"");
  fleet.node->setConfigKey("display.appearance_schedule",
                           "{\"dark_from\":\"19:00\",\"light_from\":\"06:30\"}");
  // The clock only ever moves forward here: the hybrid logical clock refuses to go backwards,
  // so each step in this test is later than the last. The monotonic clock is moved too, because
  // the published snapshot is rebuilt on a timer rather than on every wall-clock read.
  auto jumpTo = [&fleet](int64_t wall_ms) {
    fleet.clock.setWall(wall_ms);
    fleet.clock.setMono(fleet.clock.monoMs() + 2500);
    fleet.loop.pumpDue();
  };
  // 2026-09-02T02:00Z is 11:00 in Tokyo, outside the dark window.
  jumpTo(utcMsForAppearance(2026, 9, 2, 2, 0));
  CHECK(json::getString(appearance().get(), "effective") == "light");
  // 2026-09-02T12:00Z is 21:00 in Tokyo, inside it.
  jumpTo(utcMsForAppearance(2026, 9, 2, 12, 0));
  CHECK(json::getString(appearance().get(), "effective") == "dark");
  // The same instant is 08:00 in New York, so the zone decides the answer, not UTC.
  fleet.node->setConfigKey("time.zone", "\"America/New_York\"");
  fleet.loop.pumpDue();
  CHECK(json::getString(appearance().get(), "effective") == "light");

  // A per-device override wins over the cluster default.
  fleet.node->setConfigKey(
      "devices." + fleet.node->nodeId() + ".local.display.appearance", "\"light\"");
  CHECK(json::getString(appearance().get(), "effective") == "light");
  CHECK(json::getString(appearance().get(), "configured") == "light");

  fleet.node->setConfigKey("display.appearance_schedule", "{\"dark_from\":\"25:00\"}");
  CHECK(json::getString(json::get(appearance().get(), "schedule"), "dark_from") == "19:00");
}

TEST_CASE("display: the automatic theme is published and overridable") {
  SettingsNode fleet;
  auto theme = [&fleet]() {
    auto status = fleet.status();
    return json::Doc(
        cJSON_Duplicate(json::get(json::get(status.get(), "display"), "theme"), 1));
  };

  fleet.node->setConfigKey("display.theme.bg_color", "\"#9BD748\"");
  auto light = theme();
  REQUIRE(light);
  CHECK(json::getString(json::get(light.get(), "auto_background"), "color") == "#9BD748");
  CHECK(json::getString(json::get(light.get(), "auto_background"), "source") == "color");
  // A light background asks for dark ink in every region.
  CHECK(json::getString(json::get(light.get(), "auto_ink"), "clock") == "dark");
  CHECK(json::getString(json::get(light.get(), "auto_ink"), "footer") == "dark");
  CHECK(json::getString(json::get(light.get(), "auto_accent"), "call_button") == "#8144D6");
  CHECK(json::getString(light.get(), "call_button_bg") == "#8144D6");
  CHECK(json::getString(light.get(), "call_button_ink") == "light");

  // A dark background flips the ink and produces a different button.
  fleet.node->setConfigKey("display.theme.bg_color", "\"#101418\"");
  auto dark = theme();
  CHECK(json::getString(json::get(dark.get(), "auto_ink"), "clock") == "light");
  CHECK(json::getString(dark.get(), "call_button_bg") !=
        json::getString(light.get(), "call_button_bg"));

  // An administrator override replaces the computed button; the computed value stays visible.
  fleet.node->setConfigKey("display.theme.call_button_bg", "\"#1155AA\"");
  auto overridden = theme();
  CHECK(json::getString(overridden.get(), "call_button_bg") == "#1155AA");
  CHECK(json::getString(json::get(overridden.get(), "auto_accent"), "call_button") ==
        json::getString(dark.get(), "call_button_bg"));
  CHECK(json::getString(overridden.get(), "call_button_ink") == "light");

  // Per-region ink overrides are passed through for the regions the manifest knows.
  fleet.node->setConfigKey("display.theme.ink_override.clock", "\"#FF8800\"");
  CHECK(json::getString(json::get(theme().get(), "ink_override"), "clock") == "#FF8800");
  fleet.node->setConfigKey("display.theme.ink_override.nonsense", "\"#FF8800\"");
  CHECK(json::get(json::get(theme().get(), "ink_override"), "nonsense") == nullptr);
  fleet.node->setConfigKey("display.theme.ink_override.date", "\"orange\"");
  CHECK(json::get(json::get(theme().get(), "ink_override"), "date") == nullptr);

  // The computed fields are core's to publish, not an administrator's to set.
  fleet.node->setConfigKey("display.theme.auto_accent",
                           "{\"call_button\":\"#000000\"}");
  CHECK(json::getString(json::get(theme().get(), "auto_accent"), "call_button") !=
        "#000000");
  fleet.node->setConfigKey("display.theme.auto_ink", "{\"clock\":\"dark\"}");
  CHECK(json::getString(json::get(theme().get(), "auto_ink"), "clock") == "light");
}

TEST_CASE("video: the publish-side counters describe what this node produced") {
  SettingsNode fleet("door_station", "d_front");
  auto publish = [&fleet]() {
    auto status = fleet.status();
    return json::Doc(
        cJSON_Duplicate(json::get(json::get(status.get(), "video"), "publish"), 1));
  };
  auto counters = publish();
  REQUIRE(counters);
  CHECK(json::getInt(counters.get(), "frames") == 0);
  CHECK(json::getInt(counters.get(), "keyframes") == 0);
  CHECK(json::getInt(counters.get(), "fragments") == 0);
  CHECK(json::getInt(counters.get(), "dropped_forward") == 0);
  // fps is derived from the measured capture interval rather than the configured one.
  CHECK(json::getInt(counters.get(), "frame_interval_ms") > 0);
  CHECK(json::getInt(counters.get(), "fps_x10") > 0);
}

TEST_CASE("purposes: a disabled purpose is kept but never offered to a visitor") {
  SettingsNode fleet("door_station", "d_front");
  fleet.node->setConfigKey("doors.d_front", "{\"label\":{\"ja\":\"正面玄関\"}}");

  // The flag is a boolean and nothing else.
  fleet.node->setConfigKey("visit_purposes.p_sales.enabled", "\"no\"");
  CHECK(fleet.at("visit_purposes.p_sales.enabled") == nullptr);
  fleet.node->setConfigKey("visit_purposes.p_sales.enabled", "false");
  const cJSON* flag = fleet.at("visit_purposes.p_sales.enabled");
  REQUIRE(cJSON_IsBool(flag));
  CHECK_FALSE(cJSON_IsTrue(flag));
  // Switching a purpose off keeps its wording, icon and order for when it comes back.
  CHECK(fleet.at("visit_purposes.p_sales.label") != nullptr);
  CHECK(fleet.at("visit_purposes.p_sales.icon") != nullptr);

  // A door station still showing the disabled button is stale. The call goes through -- the
  // visitor should never be punished for that -- but it carries no purpose.
  const std::string stale_call = fleet.node->pressV2("d_front", "p_sales");
  REQUIRE_FALSE(stale_call.empty());
  bool carried_purpose = false;
  for (const auto& event : fleet.ui) {
    auto parsed = json::parse(event);
    if (parsed && json::getString(parsed.get(), "purpose") == "p_sales") carried_purpose = true;
  }
  CHECK_FALSE(carried_purpose);
  REQUIRE(fleet.node->cancelCallV2("d_front", stale_call, "visitor"));

  // A visitor cannot attach a disabled purpose to a call, while an enabled one still works.
  const std::string call = fleet.node->pressV2("d_front", "p_delivery");
  CHECK_FALSE(call.empty());
  CHECK_FALSE(fleet.node->selectPurposeV2("d_front", call, "p_sales"));
  CHECK(fleet.node->selectPurposeV2("d_front", call, "p_mail"));

  // Re-enabling restores it without the administrator retyping anything.
  fleet.node->setConfigKey("visit_purposes.p_sales.enabled", "true");
  CHECK(fleet.node->selectPurposeV2("d_front", call, "p_sales"));
}

TEST_CASE("theme: a hard-to-read colour is saved and reported, never refused") {
  SettingsNode fleet;
  auto write = [&fleet](const std::string& ops) {
    auto parsed = json::parse(fleet.node->configBatchJson(ops));
    REQUIRE(parsed);
    return parsed;
  };

  // A whole-theme write is inspected in place: the Theme tab sends one object, not leaves.
  auto low = write(
      "[{\"op\":\"set\",\"key\":\"display.theme\","
      "\"value\":{\"bg_color\":\"#9BD748\",\"call_button_bg\":\"#9BD749\","
      "\"ink_override\":{\"clock\":\"#9CD84A\"}}}]");
  CHECK(json::getBool(low.get(), "ok"));
  const cJSON* warnings = json::get(low.get(), "warnings");
  REQUIRE(cJSON_IsArray(warnings));
  CHECK(cJSON_GetArraySize(warnings) == 2);
  std::set<std::string> properties;
  const cJSON* warning = nullptr;
  cJSON_ArrayForEach(warning, warnings) {
    properties.insert(json::getString(warning, "property"));
    CHECK(json::getString(warning, "message_key") == "theme.low_contrast");
    CHECK(json::getNum(warning, "contrast") >= 1.0);
    CHECK(json::getNum(warning, "contrast") < 4.5);
  }
  CHECK(properties.count("call_button_bg") == 1);
  CHECK(properties.count("clock") == 1);
  // The value is saved regardless: the warning is advice, not a rejection.
  CHECK(fleet.stringAt("display.theme.call_button_bg") == "#9BD749");

  // A readable pair produces no warning at all.
  auto readable = write(
      "[{\"op\":\"set\",\"key\":\"display.theme\","
      "\"value\":{\"bg_color\":\"#101418\",\"call_button_bg\":\"#7F5E3D\"}}]");
  CHECK(json::getBool(readable.get(), "ok"));
  CHECK(json::get(readable.get(), "warnings") == nullptr);

  // Format is still refused outright, and nothing is written.
  auto malformed = write(
      "[{\"op\":\"set\",\"key\":\"display.theme.call_button_bg\",\"value\":\"orange\"}]");
  CHECK_FALSE(json::getBool(malformed.get(), "ok"));
  CHECK(fleet.stringAt("display.theme.call_button_bg") == "#7F5E3D");

  // A leaf write is measured against the effective background, not against nothing.
  auto leaf = write(
      "[{\"op\":\"set\",\"key\":\"display.theme.ink_override.clock\",\"value\":\"#111820\"}]");
  CHECK(json::getBool(leaf.get(), "ok"));
  REQUIRE(cJSON_IsArray(json::get(leaf.get(), "warnings")));
  CHECK(json::getString(cJSON_GetArrayItem(json::get(leaf.get(), "warnings"), 0), "property") ==
        "clock");
}

TEST_CASE("doors: a door station founding a cluster gets a door entry to target") {
  // The regression: devices.<id>.door pointed at a door that had no doors.<id> entry, so
  // status.doors was empty and every door-keyed surface had nothing to address.
  SettingsNode fleet("door_station", "d_front");
  CHECK(fleet.at("doors.d_front") != nullptr);
  CHECK(fleet.stringAt("doors.d_front.label.ja") == "settings");
  CHECK(fleet.stringAt("doors.d_front.label.en") == "settings");
  CHECK(fleet.stringAt("doors.d_front.label.zh") == "settings");
  CHECK(fleet.stringAt("devices." + fleet.node->nodeId() + ".door") == "d_front");

  auto status = fleet.status();
  const cJSON* entry = json::get(json::get(status.get(), "doors"), "d_front");
  REQUIRE(cJSON_IsObject(entry));
  CHECK(json::getBool(entry, "configured"));
  CHECK(json::getString(entry, "label") == "settings");

  // Everything keyed by door now has a target.
  REQUIRE(fleet.node->setDoorNotice("d_front", "Side gate today", 0));
  CHECK(fleet.stringAt("doors.d_front.notice.text") == "Side gate today");

  // An indoor panel owns no door and seeds nothing.
  SettingsNode indoor("indoor_panel", "");
  CHECK(indoor.at("doors") == nullptr);
  auto indoor_status = indoor.status();
  const cJSON* indoor_doors = json::get(indoor_status.get(), "doors");
  REQUIRE(cJSON_IsObject(indoor_doors));
  CHECK(cJSON_GetArraySize(indoor_doors) == 0);
}

TEST_CASE("doors: seeding a door entry never overwrites what an administrator wrote") {
  const std::string dir = settingsTempDir();
  NodeOptions options;
  options.data_dir = dir;
  options.name = "front-panel";
  options.role = "door_station";
  options.door = "d_front";
  options.listen_addr = "127.0.0.1:0";
  options.enable_beacon = false;
  options.http_port = 0;
  options.psk.fill(0x5a);

  {
    Node node(options);
    REQUIRE(node.start());
    auto config = json::parse(node.configJson());
    REQUIRE(config);
    const cJSON* door = json::get(json::get(config.get(), "doors"), "d_front");
    REQUIRE(cJSON_IsObject(door));
    CHECK(json::getString(json::get(door, "label"), "ja") == "front-panel");
    // The administrator renames it and files it under a building, as the doors tab does.
    node.setConfigKey("doors.d_front.label.ja", "\"正面玄関\"");
    node.setConfigKey("doors.d_front.label.en", "\"Front entrance\"");
    node.setConfigKey("doors.d_front.building", "\"b_main\"");
    node.stop();
  }
  {
    // Every later start re-checks the entry, and must leave those edits alone.
    Node node(options);
    REQUIRE(node.start());
    auto config = json::parse(node.configJson());
    REQUIRE(config);
    const cJSON* door = json::get(json::get(config.get(), "doors"), "d_front");
    REQUIRE(cJSON_IsObject(door));
    CHECK(json::getString(json::get(door, "label"), "ja") == "正面玄関");
    CHECK(json::getString(json::get(door, "label"), "en") == "Front entrance");
    CHECK(json::getString(door, "building") == "b_main");
    node.stop();
  }
  removeSettingsTempDir(dir);
}

TEST_CASE("doors: a live door with no configuration entry still appears and is addressable") {
  // The upgrade case: a cluster configured before this fix has devices.<id>.door but no
  // doors.<id>. The tile must still render and still accept an announcement.
  SettingsNode fleet("door_station", "d_front");
  REQUIRE(fleet.at("doors.d_front") != nullptr);
  // Simulate the old configuration by removing the entry the fix created.
  auto removed = json::parse(fleet.node->deleteConfigKeyJson("doors.d_front"));
  REQUIRE(removed);
  REQUIRE(json::getBool(removed.get(), "ok"));
  CHECK(fleet.at("doors.d_front") == nullptr);

  auto status = fleet.status();
  const cJSON* entry = json::get(json::get(status.get(), "doors"), "d_front");
  REQUIRE(cJSON_IsObject(entry));
  CHECK_FALSE(json::getBool(entry, "configured"));
  // The label falls back to the device name so the tile is not blank.
  CHECK(json::getString(entry, "label") == "settings");
  CHECK(cJSON_IsObject(json::get(entry, "unlock")));
  CHECK(cJSON_IsNull(json::get(entry, "notice")));

  // An announcement posted to the tile the shell is showing must not be refused.
  REQUIRE(fleet.node->setDoorNotice("d_front", "Still reachable", 0));
  CHECK(fleet.stringAt("doors.d_front.notice.text") == "Still reachable");
  auto after = fleet.status();
  const cJSON* live = json::get(json::get(after.get(), "doors"), "d_front");
  CHECK(json::getString(json::get(live, "notice"), "text") == "Still reachable");
  // Writing the notice creates doors.d_front, so the door reports configured from now on.
  CHECK(json::getBool(live, "configured"));

  // A door nobody serves is still unknown.
  CHECK_FALSE(fleet.node->setDoorNotice("d_nowhere", "hello", 0));
}

TEST_CASE("display: a configured background that cannot be sampled is never reported as color") {
  // The regression: an oversized background made the sampler fail, and the theme then reported
  // source "color" with the flat theme colour. Shells trusted that and painted ink chosen for
  // #101418 over a photograph that looked nothing like it.
  const std::string dir = settingsTempDir();
  NodeOptions options;
  options.data_dir = dir;
  options.name = "theme-source";
  options.role = "indoor_panel";
  options.listen_addr = "127.0.0.1:0";
  options.enable_beacon = false;
  options.http_port = 0;
  options.psk.fill(0x5a);

  SimClock clock(1'700'000'000'000LL, 0);
  Runloop loop(clock);
  NodeDeps deps;
  deps.clock = &clock;
  deps.loop = &loop;
  Node node(options, std::move(deps));
  REQUIRE(node.start());
  loop.pumpDue();

  auto background = [&node, &loop]() {
    loop.pumpDue();
    auto status = json::parse(node.statusJson());
    REQUIRE(status);
    const cJSON* theme = json::get(json::get(status.get(), "display"), "theme");
    return json::Doc(cJSON_Duplicate(json::get(theme, "auto_background"), 1));
  };

  // No image configured: the flat colour is the honest answer and carries no reason.
  node.setConfigKey("display.theme.bg_color", "\"#9BD748\"");
  auto flat = background();
  REQUIRE(flat);
  CHECK(json::getString(flat.get(), "source") == "color");
  CHECK(json::getString(flat.get(), "color") == "#9BD748");
  CHECK(json::get(flat.get(), "reason") == nullptr);

  // An image that is configured but not cached here yet is not "color" either.
  const std::string hash(64, 'a');
  node.setConfigKey("display.theme.bg_image", "\"" + hash + "\"");
  auto uncached = background();
  CHECK(json::getString(uncached.get(), "source") == "image_unsampled");
  CHECK(json::getString(uncached.get(), "reason") == "missing");

  // A cached asset that is not a decodable image says so, rather than falling back silently.
  Bytes junk(96, 0x41);
  REQUIRE(writeFileBytes(dir + "/assets/" + hash, junk));
  node.setConfigKey("display.theme.bg_color", "\"#9BD749\"");  // force a recompute
  auto undecodable = background();
  CHECK(json::getString(undecodable.get(), "source") == "image_unsampled");
  CHECK(json::getString(undecodable.get(), "reason") == "decode_failed");
  // The published colour still has to be something, but the source says not to trust it.
  CHECK(json::getString(undecodable.get(), "color") == "#9BD749");

  // A real photograph above the old 4 MP budget is sampled and reported as an image.
  const std::string photo_hash(64, 'b');
  Bytes photo;
  {
    // 2200x2609 flat grey, the shape of the background this was reported against.
    const int width = 2200, height = 2609;
    Bytes raw;
    raw.reserve(static_cast<size_t>(height) * (width + 1));
    for (int y = 0; y < height; y++) {
      raw.push_back(0);
      raw.insert(raw.end(), static_cast<size_t>(width), 0xC8);
    }
    photo = makeTestGreyPng(width, height, raw);
  }
  REQUIRE(writeFileBytes(dir + "/assets/" + photo_hash, photo));
  node.setConfigKey("display.theme.bg_image", "\"" + photo_hash + "\"");
  auto sampled = background();
  CHECK(json::getString(sampled.get(), "source") == "image");
  CHECK(json::getString(sampled.get(), "color") == "#C8C8C8");
  CHECK(json::get(sampled.get(), "reason") == nullptr);

  node.stop();
  std::remove((dir + "/assets/" + hash).c_str());
  std::remove((dir + "/assets/" + photo_hash).c_str());
  removeSettingsTempDir(dir);
}

TEST_CASE("doors: a device that stops serving a door takes back the entry it seeded") {
  // Device finding: the Moto was switched from door_station to indoor_panel and the door entry
  // it had auto-seeded stayed in cluster configuration, so every dashboard showed a ghost tile
  // for a door nobody serves.
  const std::string dir = settingsTempDir();
  NodeOptions options;
  options.data_dir = dir;
  options.name = "doorbell-android";
  options.role = "door_station";
  options.door = "door-b8a9a651";
  options.listen_addr = "127.0.0.1:0";
  options.enable_beacon = false;
  options.http_port = 0;
  options.psk.fill(0x5a);

  {
    Node node(options);
    REQUIRE(node.start());
    auto config = json::parse(node.configJson());
    REQUIRE(config);
    const cJSON* door = json::get(json::get(config.get(), "doors"), "door-b8a9a651");
    REQUIRE(cJSON_IsObject(door));
    // Provenance, so only the device that created it may take it back.
    CHECK(json::getString(door, "seeded_by") == node.nodeId());
    CHECK(json::getString(door, "seeded_label") == "doorbell-android");
    node.stop();
  }
  {
    // The same device comes back as an indoor panel.
    NodeOptions changed = options;
    changed.role = "indoor_panel";
    changed.door = "";
    Node node(changed);
    REQUIRE(node.start());
    auto config = json::parse(node.configJson());
    REQUIRE(config);
    CHECK(json::get(json::get(config.get(), "doors"), "door-b8a9a651") == nullptr);
    // Nothing serves it, so nothing shows it either.
    auto status = json::parse(node.statusJson());
    REQUIRE(status);
    CHECK(json::get(json::get(status.get(), "doors"), "door-b8a9a651") == nullptr);
    node.stop();
  }
  removeSettingsTempDir(dir);
}

TEST_CASE("doors: an entry an administrator has adopted outlives the device that seeded it") {
  const std::string dir = settingsTempDir();
  NodeOptions options;
  options.data_dir = dir;
  options.name = "doorbell-android";
  options.role = "door_station";
  options.door = "door-b8a9a651";
  options.listen_addr = "127.0.0.1:0";
  options.enable_beacon = false;
  options.http_port = 0;
  options.psk.fill(0x5a);

  {
    Node node(options);
    REQUIRE(node.start());
    // An administrator renames it in the doors tab. That alone makes it theirs.
    node.setConfigKey("doors.door-b8a9a651.label.ja", "\"正面玄関\"");
    node.stop();
  }
  {
    NodeOptions changed = options;
    changed.role = "indoor_panel";
    changed.door = "";
    Node node(changed);
    REQUIRE(node.start());
    auto config = json::parse(node.configJson());
    REQUIRE(config);
    const cJSON* door = json::get(json::get(config.get(), "doors"), "door-b8a9a651");
    REQUIRE(cJSON_IsObject(door));
    CHECK(json::getString(json::get(door, "label"), "ja") == "正面玄関");
    // It shows, and it shows as served by nobody -- which is the honest state for a station
    // that is down, and is what an administrator needs to see to fix it.
    auto status = json::parse(node.statusJson());
    REQUIRE(status);
    const cJSON* entry = json::get(json::get(status.get(), "doors"), "door-b8a9a651");
    REQUIRE(cJSON_IsObject(entry));
    CHECK(cJSON_IsNull(json::get(entry, "served_by")));
    CHECK(json::getBool(entry, "configured"));
    node.stop();
  }
  removeSettingsTempDir(dir);

  // The same protection for any other field an administrator adds.
  for (const char* edit : {"doors.door-b8a9a651.building",
                           "doors.door-b8a9a651.unlock.command"}) {
    const std::string dir2 = settingsTempDir();
    NodeOptions first = options;
    first.data_dir = dir2;
    {
      Node node(first);
      REQUIRE(node.start());
      node.setConfigKey(edit, "\"b_main\"");
      node.stop();
    }
    NodeOptions changed = first;
    changed.role = "indoor_panel";
    changed.door = "";
    Node node(changed);
    REQUIRE(node.start());
    auto config = json::parse(node.configJson());
    REQUIRE(config);
    CAPTURE(edit);
    CHECK(cJSON_IsObject(json::get(json::get(config.get(), "doors"), "door-b8a9a651")));
    node.stop();
    removeSettingsTempDir(dir2);
  }
}

TEST_CASE("doors: served_by names the alive station, and is null when nobody serves the door") {
  SettingsNode fleet("door_station", "d_front");
  auto entry = [&fleet](const char* door) {
    auto status = fleet.status();
    return json::Doc(cJSON_Duplicate(json::get(json::get(status.get(), "doors"), door), 1));
  };
  auto own = entry("d_front");
  REQUIRE(own);
  CHECK(json::getString(own.get(), "served_by") == fleet.node->nodeId());

  // A door that exists in configuration but has no station is reported as served by nobody,
  // which is what distinguishes "the station is offline" from "there is no station".
  fleet.node->setConfigKey("doors.d_ghost", "{\"label\":{\"ja\":\"離れ\"}}");
  auto ghost = entry("d_ghost");
  REQUIRE(ghost);
  CHECK(cJSON_IsNull(json::get(ghost.get(), "served_by")));
  CHECK(json::getBool(ghost.get(), "configured"));
}
