


#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cstdio>
#include <functional>
#include <memory>
#include <random>
#include <string>
#include <vector>

#include <sqlite3.h>

#include "doctest.h"
#include "events/events.h"
#include "mesh/mesh.h"
#include "node/node.h"
#include "sipctl/sipctl.h"
#include "store/store.h"
#include "util/clock.h"
#include "util/json.h"
#include "util/runloop.h"

using namespace db;

namespace {

struct NFleet {
  SimClock clock{1'700'000'000'000LL, 0};
  Runloop loop{clock};
  InMemNet net{loop};
  std::array<uint8_t, 32> psk{};

  NFleet() { psk.fill(0x5a); }

  static MeshSettings timing() {
    MeshSettings m;
    m.heartbeat_ms = 30;
    m.suspect_ms = 90;
    m.dead_ms = 150;
    m.gossip_ms = 50;
    m.sync_ms = 50;
    m.claim_ttl_ms = 300;
    m.reconnect_ms = 50;
    return m;
  }

  struct N {
    std::unique_ptr<Node> node;
    std::vector<std::string> ui;
    std::vector<std::string> tts;
    size_t uiCount(const std::string& t, const std::string& type = "") const {
      size_t n = 0;
      for (const auto& e : ui) {
        auto d = json::parse(e);
        if (!d) continue;
        if (json::getString(d.get(), "t") != t) continue;
        if (!type.empty() && json::getString(d.get(), "type") != type) continue;
        n++;
      }
      return n;
    }
  };
  std::vector<std::unique_ptr<N>> nodes;

  N& add(const std::string& addr, const std::string& name, const std::string& role,
         const std::string& door, bool seed_cfg, bool zero_psk = false,
         const std::string& data_dir = ":memory:") {
    NodeOptions o;
    o.data_dir = data_dir;
    o.name = name;
    o.role = role;
    o.door = door;
    o.listen_addr = addr;
    o.advertise_addr = addr;
    o.psk = zero_psk ? std::array<uint8_t, 32>{} : psk;
    o.enable_beacon = false;
    o.http_port = 0;
    o.seed_default_config = seed_cfg;
    o.mesh_timing_template = timing();
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
    n->node->setTtsCb([raw](const std::string& t, const std::string&) { raw->tts.push_back(t); });
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

int openProbeListener(int* port) {
  int fd = ::socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return -1;
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
  sockaddr_in address{};
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  address.sin_port = 0;
  if (::bind(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0 ||
      ::listen(fd, 4) != 0) {
    ::close(fd);
    return -1;
  }
  socklen_t length = sizeof(address);
  if (::getsockname(fd, reinterpret_cast<sockaddr*>(&address), &length) != 0) {
    ::close(fd);
    return -1;
  }
  *port = ntohs(address.sin_port);
  return fd;
}

std::string nodeTempDir() {
  char path[] = "/tmp/doorbell_node_durability_XXXXXX";
  char* created = mkdtemp(path);
  REQUIRE(created != nullptr);
  return created;
}

bool setNodeConfigWriteFailure(const std::string& path, bool enabled) {
  sqlite3* db = nullptr;
  if (sqlite3_open(path.c_str(), &db) != SQLITE_OK) {
    if (db) sqlite3_close(db);
    return false;
  }
  const char* sql = enabled
      ? "CREATE TRIGGER fail_config_write BEFORE INSERT ON config "
        "BEGIN SELECT RAISE(FAIL,'injected config write failure'); END"
      : "DROP TRIGGER IF EXISTS fail_config_write";
  const bool ok = sqlite3_exec(db, sql, nullptr, nullptr, nullptr) == SQLITE_OK;
  sqlite3_close(db);
  return ok;
}

bool setNodeEventProjectionFailure(const std::string& path, bool enabled) {
  sqlite3* db = nullptr;
  if (sqlite3_open(path.c_str(), &db) != SQLITE_OK) {
    if (db) sqlite3_close(db);
    return false;
  }
  const char* sql = enabled
      ? "CREATE TRIGGER fail_event_projection BEFORE UPDATE OF frontier "
        "ON event_origin_state WHEN NEW.frontier > OLD.frontier "
        "BEGIN SELECT RAISE(FAIL,'injected event projection failure'); END"
      : "DROP TRIGGER IF EXISTS fail_event_projection";
  const bool ok = sqlite3_exec(db, sql, nullptr, nullptr, nullptr) == SQLITE_OK;
  sqlite3_close(db);
  return ok;
}

void removeNodeTempDir(const std::string& dir) {
  for (const char* name : {"doorbell.db", "doorbell.db-wal", "doorbell.db-shm"})
    std::remove((dir + "/" + name).c_str());
  ::rmdir((dir + "/assets").c_str());
  ::rmdir(dir.c_str());
}

}  // namespace

TEST_CASE("node: startup applies and replays a durable event beyond the saved frontier") {
  const std::string dir = nodeTempDir();
  NodeOptions options;
  options.data_dir = dir;
  options.name = "event-recovery";
  options.role = "indoor_panel";
  options.listen_addr = "127.0.0.1:0";
  options.psk.fill(0x41);
  options.enable_beacon = false;
  options.http_port = 0;

  {
    Node initial(options);
    REQUIRE(initial.start());
    initial.stop();
  }
  {
    Store store;
    REQUIRE(store.open(dir + "/doorbell.db"));
    EventRecord event;
    event.origin = "remote-sos-origin";
    event.seq = 1;
    event.type = "emergency";
    event.device = "remote-sos-origin";
    event.hlc = HlcClock::format(1'700'000'100'000LL, 0, "remote00");
    event.wall_ms = 1'700'000'100'000LL;
    event.payload_json = R"({"schema_version":2,"source":"remote-sos-origin"})";
    REQUIRE(store.eventIngest(event));
    CHECK(store.eventFrontier(event.origin) == 0);
  }

  std::vector<std::string> ui;
  Node recovered(options);
  recovered.setUiEventCb([&ui](const std::string& event) { ui.push_back(event); });
  REQUIRE(recovered.start());
  const auto status = json::parse(recovered.statusJson());
  REQUIRE(status);
  CHECK(json::getBool(json::get(status.get(), "emergency"), "active"));
  bool replayed = false;
  for (const auto& raw : ui) {
    const auto event = json::parse(raw);
    if (event && json::getString(event.get(), "t") == "event" &&
        json::getString(event.get(), "type") == "emergency")
      replayed = true;
  }
  CHECK(replayed);
  recovered.stop();
  {
    Store store;
    REQUIRE(store.open(dir + "/doorbell.db"));
    CHECK(store.eventFrontier("remote-sos-origin") == 1);
  }
  removeNodeTempDir(dir);
}

TEST_CASE("node: remote config persistence failure rolls back and retries anti-entropy") {
  NFleet fleet;
  const std::string target_dir = nodeTempDir();
  auto& source = fleet.add("A:1", "source", "door_station", "d_front", true);
  auto& target = fleet.add("B:1", "target", "indoor_panel", "", false, false,
                           target_dir);
  REQUIRE(source.node->start());
  REQUIRE(target.node->start());
  fleet.run(1'200);

  const std::string key = "durability.remote_retry";
  REQUIRE(setNodeConfigWriteFailure(target_dir + "/doorbell.db", true));
  source.node->setConfigKey(key, "7");
  fleet.run(600);
  CHECK(target.node->configJson().find("remote_retry") == std::string::npos);
  auto status = json::parse(target.node->statusJson());
  REQUIRE(status);
  cJSON* config_store = json::get(json::get(status.get(), "runtime"), "config_store");
  REQUIRE(config_store);
  CHECK(json::getBool(config_store, "fail_closed"));

  REQUIRE(setNodeConfigWriteFailure(target_dir + "/doorbell.db", false));
  fleet.run(1'200);
  CHECK(target.node->configJson().find("\"remote_retry\":7") != std::string::npos);
  status = json::parse(target.node->statusJson());
  REQUIRE(status);
  CHECK(json::get(json::get(status.get(), "runtime"), "config_store") == nullptr);

  source.node->stop();
  target.node->stop();
  {
    Store store;
    REQUIRE(store.open(target_dir + "/doorbell.db"));
    bool persisted = false;
    for (const auto& entry : store.configLoadAll())
      persisted = persisted || (entry.key == key && entry.value_json == "7" && !entry.deleted);
    CHECK(persisted);
  }
  removeNodeTempDir(target_dir);
}

TEST_CASE("node: two nodes join and replicate default config") {
  NFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true);
  auto& b = f.add("B:1", "kitchen", "indoor_panel", "", false);
  REQUIRE(a.node->start());
  REQUIRE(b.node->start());
  f.run(1500);


  auto st = json::parse(b.node->statusJson());
  REQUIRE(st);
  cJSON* peers = json::get(st.get(), "peers");
  REQUIRE(cJSON_GetArraySize(peers) == 2);
  cJSON* it = nullptr;
  cJSON_ArrayForEach(it, peers) { CHECK(json::getString(it, "status") == "alive"); }


  auto cfg = json::parse(b.node->configJson());
  REQUIRE(cfg);
  cJSON* qr = json::get(json::get(cfg.get(), "quick_replies"), "qr_away");
  REQUIRE(qr);
  CHECK(json::getString(json::get(qr, "label"), "ja") == "ただいま留守にしています");


  cJSON* devs = json::get(cfg.get(), "devices");
  CHECK(cJSON_GetArraySize(devs) == 2);

  a.node->stop();
  b.node->stop();
}

TEST_CASE("node: boot identity repairs stale self role and door leaves") {
  const std::string dir = nodeTempDir();
  std::string node_id;
  {
    NFleet fleet;
    auto& first = fleet.add("identity-old", "panel-old", "indoor_panel", "", true, false,
                            dir);
    REQUIRE(first.node->start());
    auto status = json::parse(first.node->statusJson());
    REQUIRE(status);
    node_id = json::getString(json::get(status.get(), "node"), "id");
    REQUIRE_FALSE(node_id.empty());
    first.node->setConfigKey("devices." + node_id + ".role", "\"indoor_panel\"");
    first.node->setConfigKey("devices." + node_id + ".door", "\"\"");
    first.node->stop();
  }

  {
    NFleet fleet;
    auto& restarted = fleet.add("identity-new", "front-door", "door_station", "door-r4nd0m",
                                true, false, dir);
    REQUIRE(restarted.node->start());
    auto cfg = json::parse(restarted.node->configJson());
    REQUIRE(cfg);
    const cJSON* self = json::get(json::get(cfg.get(), "devices"), node_id.c_str());
    CHECK(json::getString(self, "name") == "front-door");
    CHECK(json::getString(self, "role") == "door_station");
    CHECK(json::getString(self, "door") == "door-r4nd0m");
    restarted.node->stop();
  }
  removeNodeTempDir(dir);
}

TEST_CASE("node: playback strategy resolves pair, global, then legacy configuration") {
  NFleet f;
  auto& door = f.add("A:1", "front", "door_station", "d_front", true);
  auto& indoor = f.add("B:1", "kitchen", "indoor_panel", "", false);
  REQUIRE(door.node->start());
  REQUIRE(indoor.node->start());
  f.run(1200);
  const std::string door_id = door.node->nodeId();
  const std::string indoor_id = indoor.node->nodeId();

  auto profileForDoor = [&]() -> json::Doc {
    auto st = json::parse(indoor.node->statusJson());
    cJSON* p = nullptr;
    cJSON* it = nullptr;
    cJSON_ArrayForEach(it, json::get(st.get(), "peers")) {
      if (json::getString(it, "id") == door_id) { p = it; break; }
    }
    if (!p) return json::Doc(nullptr);
    return json::Doc(cJSON_Duplicate(json::get(p, "playback_profile"), true));
  };

  indoor.node->setConfigKey("devices." + indoor_id + ".local.video.playback", "\"hls\"");
  f.run(100);
  auto p = profileForDoor();
  REQUIRE(p);
  CHECK(json::getString(p.get(), "resolved_from") == "legacy");
  CHECK(json::getString(cJSON_GetArrayItem(json::get(p.get(), "strategies"), 0), "id") ==
        "h264_hls");

  const std::string global = R"({"strategies":[
    {"id":"mjpeg","enabled":true,"startup_timeout_ms":5000,"stall_timeout_ms":3000},
    {"id":"h264_low_latency","enabled":false,"startup_timeout_ms":300,"stall_timeout_ms":3000},
    {"id":"h264_hls","enabled":false,"startup_timeout_ms":300,"stall_timeout_ms":5000}]})";
  indoor.node->setConfigKey("video_playback.global", global);
  f.run(100);
  p = profileForDoor();
  REQUIRE(p);
  CHECK(json::getString(p.get(), "resolved_from") == "global");
  CHECK(json::getString(cJSON_GetArrayItem(json::get(p.get(), "strategies"), 0), "id") ==
        "mjpeg");

  const std::string pair = R"({"strategies":[
    {"id":"h264_low_latency","enabled":true,"startup_timeout_ms":300,"stall_timeout_ms":3000},
    {"id":"mjpeg","enabled":true,"startup_timeout_ms":5000,"stall_timeout_ms":3000}]})";
  indoor.node->setConfigKey("video_playback.pairs." + indoor_id + "." + door_id, pair);
  f.run(100);
  p = profileForDoor();
  REQUIRE(p);
  CHECK(json::getString(p.get(), "resolved_from") == "pair");
  CHECK(json::getString(cJSON_GetArrayItem(json::get(p.get(), "strategies"), 0), "id") ==
        "h264_low_latency");

  // A pair profile with every strategy disabled safely falls back to the global profile.
  indoor.node->setConfigKey("video_playback.pairs." + indoor_id + "." + door_id,
                            R"({"strategies":[{"id":"mjpeg","enabled":false,
                            "startup_timeout_ms":5000,"stall_timeout_ms":3000}]})");
  f.run(100);
  p = profileForDoor();
  REQUIRE(p);
  CHECK(json::getString(p.get(), "resolved_from") == "global");

  door.node->stop();
  indoor.node->stop();
}

TEST_CASE("node: status and config snapshot JSON are available after start") {
  NFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true);
  REQUIRE(a.node->start());
  std::string status = a.node->statusJson();
  std::string config = a.node->configJson();
  CHECK(status != "{}");
  CHECK(config != "{}");
  CHECK(json::parse(status));
  CHECK(json::parse(config));
  a.node->stop();
}

TEST_CASE("node: setConfigKey becomes visible through the deferred snapshot") {
  NFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true);
  REQUIRE(a.node->start());
  a.node->setConfigKey("ui.snapshot_test", "\"updated\"");
  f.clock.advance(35);
  f.run(40);
  auto cfg = json::parse(a.node->configJson());
  REQUIRE(cfg);
  CHECK(json::getString(json::get(cfg.get(), "ui"), "snapshot_test") == "updated");
  a.node->stop();
}

TEST_CASE("node: video rotation follows the sensor unless fixed by an administrator") {
  NFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true);
  REQUIRE(a.node->start());

  a.node->setVideoSensorRotation(91);  // Normalize to a cardinal angle.
  f.run(20);
  auto st = json::parse(a.node->statusJson());
  REQUIRE(st);
  CHECK(json::getInt(json::get(st.get(), "video"), "rotation") == 90);

  a.node->setConfigKey("devices." + a.node->nodeId() + ".local.video.rotation", "270");
  f.run(20);
  a.node->setVideoSensorRotation(180);  // The fixed 270-degree override remains effective.
  f.run(20);
  st = json::parse(a.node->statusJson());
  REQUIRE(st);
  CHECK(json::getInt(json::get(st.get(), "video"), "rotation") == 270);

  a.node->setConfigKey("devices." + a.node->nodeId() + ".local.video.rotation", "\"auto\"");
  f.run(20);
  st = json::parse(a.node->statusJson());
  REQUIRE(st);
  CHECK(json::getInt(json::get(st.get(), "video"), "rotation") == 180);
  a.node->stop();
}

TEST_CASE("sanitizeCaps suppresses HTTPS when only TLS 1.2 is available") {
  auto caps1 = sanitizeCaps(R"({"tls12":true,"wan":true})", false);
  auto j1 = json::parse(caps1);
  REQUIRE(j1);
  CHECK(json::getBool(j1.get(), "tls12") == false);
  CHECK(json::getBool(j1.get(), "wan") == true);

  auto caps2 = sanitizeCaps(R"({"tls12":true,"wan":true})", true);
  auto j2 = json::parse(caps2);
  REQUIRE(j2);
  CHECK(json::getBool(j2.get(), "tls12") == true);

  auto invalid_without_https = json::parse(sanitizeCaps("not-json", false));
  REQUIRE(invalid_without_https);
  CHECK(json::getBool(invalid_without_https.get(), "tls12") == false);
  auto invalid_with_https = json::parse(sanitizeCaps("not-json", true));
  REQUIRE(invalid_with_https);
  CHECK(cJSON_IsObject(invalid_with_https.get()));
}

TEST_CASE("runtime capabilities: administrator overrides cannot exceed hardware measurements") {
  NFleet fleet;
  auto& node = fleet.add("A:1", "front", "door_station", "d_front", true);
  REQUIRE(node.node->start());
  node.node->setRuntimeCapabilities(
      R"({"tls12":true,"wan":false,"mains_power":true,"h264_encode":false,"camera":true,"cpu_score":40})");
  fleet.run(20);
  const std::string key = "devices." + node.node->nodeId() + ".caps_override";
  node.node->setConfigKey(
      key,
      R"({"wan":true,"h264_encode":true,"camera":false,"cpu_score":99,"sip_backend":"pjsip"})");
  fleet.run(20);

  auto manifest = json::parse(node.node->capabilitiesJson());
  REQUIRE(manifest);
  cJSON* caps = json::get(manifest.get(), "caps");
  REQUIRE(caps);
  CHECK(json::getBool(caps, "wan") == true);  // operational state may be overridden
  CHECK(json::getBool(caps, "h264_encode") == false);  // hardware false cannot be raised
  CHECK(json::getBool(caps, "camera") == false);       // hardware true may be disabled
  CHECK(json::getInt(caps, "cpu_score") == 40);        // numeric ceiling is measured
  CHECK(json::getString(caps, "sip_backend").empty()); // unmeasured features cannot be invented
  node.node->stop();
}

TEST_CASE("runtime feature gating requires measured shell support and a real UI manifest") {
  NFleet fleet;
  auto& node = fleet.add("A:1", "front", "door_station", "d_front", true);
  REQUIRE(node.node->start());
  fleet.run(20);

  auto initial = json::parse(node.node->capabilitiesJson());
  REQUIRE(initial);
  cJSON* initial_features = json::get(initial.get(), "features");
  CHECK_FALSE(json::getBool(initial_features, "call_lifecycle_v2"));
  CHECK_FALSE(json::getBool(initial_features, "call_flow_v2"));
  CHECK_FALSE(json::getBool(initial_features, "call_cancel_v2"));
  CHECK_FALSE(json::getBool(initial_features, "device_alert_v1"));
  CHECK_FALSE(json::getBool(initial_features, "ui_manifest_v1"));
  CHECK(cJSON_GetArraySize(json::get(json::get(initial.get(), "ui_manifest"), "elements")) == 0);

  node.node->setRuntimeCapabilities(
      R"({"call_flow_v2":true,"call_cancel_v2":true,"device_alert_v1":true,"runtime_recovery":true,"helper_policy_v1":true})");
  fleet.run(20);
  auto legacy_caps = json::parse(node.node->capabilitiesJson());
  REQUIRE(legacy_caps);
  cJSON* legacy_features = json::get(legacy_caps.get(), "features");
  CHECK_FALSE(json::getBool(legacy_features, "call_flow_v2"));
  CHECK_FALSE(json::getBool(legacy_features, "call_cancel_v2"));
  CHECK_FALSE(json::getBool(legacy_features, "call_lifecycle_v2"));
  CHECK_FALSE(json::getBool(legacy_features, "device_alert_v1"));
  CHECK_FALSE(json::getBool(legacy_features, "runtime_recovery_v1"));
  CHECK_FALSE(json::getBool(legacy_features, "helper_policy_v1"));

  node.node->setConfigKey("ui.call_flow", "\"ring_then_purpose\"");
  const std::string legacy_call = node.node->pressV2("d_front", "");
  fleet.run(20);
  auto legacy_status = json::parse(node.node->statusJson());
  REQUIRE(legacy_status);
  cJSON* legacy_calls = json::get(legacy_status.get(), "active_calls");
  REQUIRE(cJSON_GetArraySize(legacy_calls) == 1);
  CHECK(json::getString(cJSON_GetArrayItem(legacy_calls, 0), "call_flow") == "purpose_first");
  CHECK(node.node->cancelCallV2("d_front", legacy_call, "visitor"));

  node.node->setRuntimeCapabilities(
      R"({"features":{"platform_v2":true,"call_flow_v2":true,"call_cancel_v2":true,"call_lifecycle_v2":true,"device_alert_v1":true,"ui_manifest_v1":true,"runtime_recovery_v1":true}})");
  node.node->setUiManifest(
      R"({"schema_version":1,"units":"logical","viewport":{"minimum_touch":44,"scale_min":0.75,"scale_max":2.0},"elements":{"purpose.button":{"properties":["scale","foreground","background"],"defaults":{"scale":1.0,"foreground":"#000000","background":"#FFFFFF"},"safety_critical":false},"cancel.call":{"properties":["scale","foreground","background"],"defaults":{"scale":1.0,"foreground":"#FFFFFF","background":"#000000"},"safety_critical":true},"sos.trigger":{"properties":["scale"],"defaults":{"scale":1.0},"safety_critical":true},"sos.cancel":{"properties":["scale"],"defaults":{"scale":1.0},"safety_critical":true}}})");
  fleet.run(20);
  const std::string modern_call = node.node->pressV2("d_front", "");
  fleet.run(20);
  auto modern_status = json::parse(node.node->statusJson());
  REQUIRE(modern_status);
  cJSON* modern_calls = json::get(modern_status.get(), "active_calls");
  REQUIRE(cJSON_GetArraySize(modern_calls) == 1);
  CHECK(json::getString(cJSON_GetArrayItem(modern_calls, 0), "call_flow") ==
        "ring_then_purpose");
  cJSON* modern_features = json::get(modern_status.get(), "features");
  CHECK(json::getBool(modern_features, "call_flow_v2"));
  CHECK(json::getBool(modern_features, "call_cancel_v2"));
  CHECK(json::getBool(modern_features, "call_lifecycle_v2"));
  CHECK(json::getBool(modern_features, "device_alert_v1"));
  CHECK(json::getBool(modern_features, "ui_manifest_v1"));
  const std::string accepted_manifest =
      json::dump(json::get(modern_status.get(), "ui_manifest"));
  node.node->setUiManifest(
      R"({"schema_version":1,"units":"logical","viewport":{"minimum_touch":44,"scale_min":0.75,"scale_max":2.0},"elements":{"cancel.call":{"properties":["scale"],"safety_critical":true}}})");
  fleet.run(20);
  auto after_invalid_manifest = json::parse(node.node->statusJson());
  REQUIRE(after_invalid_manifest);
  CHECK(json::dump(json::get(after_invalid_manifest.get(), "ui_manifest")) ==
        accepted_manifest);
  CHECK(json::getBool(json::get(after_invalid_manifest.get(), "features"),
                      "ui_manifest_v1"));

  const std::string style_key =
      "devices." + node.node->nodeId() + ".local.ui.elements.cancel.call";
  node.node->setConfigKey(
      style_key,
      R"({"scale":1.0,"foreground":"#FFFFFF","background":"#000000","border":"#FFFFFF"})");
  const std::string safe_config = node.node->configJson();
  node.node->setConfigKey(style_key, R"({"foreground":"#000000"})");
  CHECK(node.node->configJson() == safe_config);
  node.node->setConfigKey(style_key, R"({"foreground":"#FFFFFFFF"})");
  CHECK(node.node->configJson() == safe_config);
  node.node->setConfigKey(style_key, R"({"scale":0.9})");
  CHECK(node.node->configJson() == safe_config);

  CHECK(node.node->cancelCallV2("d_front", modern_call, "visitor"));
  node.node->stop();
}

TEST_CASE("mixed fleet derives call flow from the originating door shell") {
  NFleet fleet;
  auto& door = fleet.add("A:1", "front", "door_station", "d_front", true);
  auto& indoor = fleet.add("B:1", "hall", "indoor_panel", "", false);
  REQUIRE(door.node->start());
  REQUIRE(indoor.node->start());
  door.node->setConfigKey("ui.call_flow", "\"ring_then_purpose\"");
  fleet.run(1'000);

  const std::string legacy_call = door.node->pressV2("d_front", "");
  fleet.run(300);
  auto legacy = json::parse(indoor.node->statusJson());
  REQUIRE(legacy);
  cJSON* calls = json::get(legacy.get(), "active_calls");
  REQUIRE(cJSON_GetArraySize(calls) == 1);
  CHECK(json::getString(cJSON_GetArrayItem(calls, 0), "call_flow") == "purpose_first");
  CHECK(door.node->cancelCallV2("d_front", legacy_call, "visitor"));
  fleet.run(200);

  door.node->setRuntimeCapabilities(
      R"({"features":{"call_flow_v2":true,"call_cancel_v2":true,"ui_manifest_v1":true}})");
  door.node->setUiManifest(
      R"({"schema_version":1,"units":"logical","viewport":{"minimum_touch":44,"scale_min":0.75,"scale_max":2.0},"elements":{"purpose.button":{"properties":["scale"],"defaults":{"scale":1.0},"safety_critical":false},"cancel.call":{"properties":["scale"],"defaults":{"scale":1.0},"safety_critical":true}}})");
  fleet.run(1'000);
  const std::string modern_call = door.node->pressV2("d_front", "");
  fleet.run(300);
  auto modern = json::parse(indoor.node->statusJson());
  REQUIRE(modern);
  calls = json::get(modern.get(), "active_calls");
  REQUIRE(cJSON_GetArraySize(calls) == 1);
  CHECK(json::getString(cJSON_GetArrayItem(calls, 0), "call_flow") ==
        "ring_then_purpose");
  cJSON* peers = json::get(modern.get(), "peers");
  bool advertised = false;
  cJSON* peer = nullptr;
  cJSON_ArrayForEach(peer, peers) {
    if (json::getString(peer, "id") != door.node->nodeId()) continue;
    advertised = json::getBool(json::get(peer, "features"), "call_flow_v2") &&
                 json::getBool(json::get(peer, "features"), "ui_manifest_v1");
  }
  CHECK(advertised);

  CHECK(door.node->cancelCallV2("d_front", modern_call, "visitor"));
  door.node->stop();
  indoor.node->stop();
}

TEST_CASE("offline semantic UI edits use the persisted last-valid peer manifest") {
  const std::string dir = "/tmp/doorbell_ui_contract_" + std::to_string(::getpid());
  std::string peer_id;
  {
    NFleet fleet;
    auto& admin = fleet.add("A:1", "admin", "indoor_panel", "", true, false, dir);
    auto& peer = fleet.add("B:1", "remote", "indoor_panel", "", false);
    REQUIRE(admin.node->start());
    REQUIRE(peer.node->start());
    peer_id = peer.node->nodeId();
    admin.node->setConfigKey("devices." + peer_id,
                             R"({"name":"Remote panel","role":"indoor_panel"})");
    peer.node->setRuntimeCapabilities(
        R"({"device_alert_channels":["in_app"],"features":{"ui_manifest_v1":true}})");
    peer.node->setUiManifest(
        R"({"schema_version":1,"units":"pt","viewport":{"minimum_touch":44,"scale_min":0.75,"scale_max":2.0},"elements":{"ring.title":{"properties":["foreground","background"],"defaults":{"foreground":"#FFFFFF","background":"#101418"},"safety_critical":false}}})");
    peer.node->setRuntimeStatus(
        R"({"schema_version":1,"safe_mode":true,"device_alert":{"schema_version":1,"active":true,"result":"presented","secret":"private"},"ui_style":{"schema_version":1,"applied":["ring.title"],"rejected":[],"last_known_good":{"used":[],"persisted":["ring.title"]},"last_error":"","updated_at_ms":1700000000123,"elements":{"ring.title":{"source":"override","applied":true,"rejected":false,"lkg_persisted":true,"error":""}}}})");
    fleet.run(1'000);
    auto live = json::parse(admin.node->statusJson());
    REQUIRE(live);
    bool manifest_seen = false;
    bool runtime_seen = false;
    const cJSON* item = nullptr;
    cJSON_ArrayForEach(item, json::get(live.get(), "peers")) {
      if (json::getString(item, "id") == peer_id) {
        manifest_seen = cJSON_IsObject(json::get(
            json::get(item, "ui_manifest"), "elements"));
        const cJSON* runtime = json::get(item, "runtime");
        const cJSON* ui_style = json::get(runtime, "ui_style");
        runtime_seen = cJSON_IsObject(ui_style) &&
                       json::getInt(ui_style, "schema_version") == 1 &&
                       cJSON_IsObject(json::get(json::get(ui_style, "elements"),
                                                "ring.title")) &&
                       json::getBool(runtime, "safe_mode") &&
                       json::getBool(json::get(runtime, "device_alert"), "active") &&
                       json::get(json::get(runtime, "device_alert"), "secret") == nullptr;
      }
    }
    CHECK(manifest_seen);
    CHECK(runtime_seen);
    admin.node->stop();
    peer.node->stop();
  }
  {
    NFleet fleet;
    auto& admin = fleet.add("A:1", "admin", "indoor_panel", "", false, false, dir);
    REQUIRE(admin.node->start());
    fleet.run(50);
    auto offline = json::parse(admin.node->statusJson());
    REQUIRE(offline);
    bool cached_seen = false;
    const cJSON* item = nullptr;
    cJSON_ArrayForEach(item, json::get(offline.get(), "peers")) {
      if (json::getString(item, "id") != peer_id) continue;
      cached_seen = json::getString(item, "status") == "offline" &&
                    json::getBool(item, "cached_contract") &&
                    cJSON_IsObject(json::get(json::get(item, "ui_manifest"), "elements")) &&
                    cJSON_IsObject(json::get(
                        json::get(json::get(item, "runtime"), "ui_style"), "elements"));
    }
    CHECK(cached_seen);
    admin.node->setConfigKey("devices." + peer_id + ".local.ui.elements.ring.title",
                             R"({"foreground":"#F0F0F0"})");
    fleet.run(50);
    CHECK(admin.node->configJson().find("#F0F0F0") != std::string::npos);
    admin.node->stop();
  }
  for (const char* name : {"doorbell.db", "doorbell.db-wal", "doorbell.db-shm"})
    std::remove((dir + "/" + name).c_str());
  ::rmdir((dir + "/assets").c_str());
  ::rmdir(dir.c_str());
}

TEST_CASE("a live configured door authority expires a call after its origin stops") {
  NFleet fleet;
  auto& origin = fleet.add("A:1", "front-a", "door_station", "d_front", true);
  auto& standby = fleet.add("B:1", "front-b", "door_station", "d_front", false);
  REQUIRE(origin.node->start());
  REQUIRE(standby.node->start());
  fleet.run(1'000);
  const std::string call_id = origin.node->pressV2("d_front", "");
  REQUIRE(!call_id.empty());
  fleet.run(300);
  CHECK(standby.node->statusJson().find(call_id) != std::string::npos);

  origin.node->stop();
  fleet.run(61'000);
  CHECK(standby.uiCount("event", "call_cancelled") == 1);
  CHECK(standby.node->statusJson().find(call_id) == std::string::npos);
  fleet.run(10'000);
  CHECK(standby.uiCount("event", "call_cancelled") == 1);
  standby.node->stop();
}

TEST_CASE("a dead dialog owner is cancelled once by the deterministic survivor") {
  const std::string door_dir = nodeTempDir();
  NFleet fleet;
  auto& door = fleet.add("A:1", "front", "door_station", "d_front", true, false,
                         door_dir);
  auto& owner = fleet.add("B:1", "hall", "indoor_panel", "", false);
  REQUIRE(door.node->start());
  REQUIRE(owner.node->start());
  fleet.run(1'000);

  const std::string call_id = door.node->pressV2("d_front", "");
  REQUIRE(!call_id.empty());
  fleet.run(300);
  REQUIRE(owner.node->reportCallAnsweredV2("d_front", call_id, 0));
  fleet.run(300);
  CHECK(door.node->statusJson().find("\"state\":\"in_call\"") != std::string::npos);

  const std::string owner_id = owner.node->nodeId();
  owner.node->stop();
  bool owner_dead = false;
  for (int i = 0; i < 50 && !owner_dead; ++i) {
    fleet.run(20);
    auto status = json::parse(door.node->statusJson());
    const cJSON* peer = nullptr;
    cJSON_ArrayForEach(peer, json::get(status.get(), "peers")) {
      if (json::getString(peer, "id") == owner_id)
        owner_dead = json::getString(peer, "status") == "dead";
    }
  }
  REQUIRE(owner_dead);

  door.node->reportCallRecovery(call_id, true);
  REQUIRE(setNodeEventProjectionFailure(door_dir + "/doorbell.db", true));
  fleet.run(9'990);
  CHECK(door.uiCount("event", "call_cancelled") == 0);
  fleet.run(20);
  CHECK(door.uiCount("event", "call_cancelled") == 0);
  CHECK(door.node->statusJson().find(call_id) != std::string::npos);
  REQUIRE(setNodeEventProjectionFailure(door_dir + "/doorbell.db", false));
  fleet.run(2'010);
  CHECK(door.uiCount("event", "call_cancelled") == 1);
  CHECK(door.node->statusJson().find(call_id) == std::string::npos);
  fleet.run(11'000);
  CHECK(door.uiCount("event", "call_cancelled") == 1);
  door.node->stop();
  removeNodeTempDir(door_dir);
}

TEST_CASE("a returning dialog owner cancels the survivor takeover lease") {
  const std::string owner_dir =
      "/tmp/doorbell_dialog_owner_return_" + std::to_string(::getpid());
  NFleet fleet;
  auto& door = fleet.add("A:1", "front", "door_station", "d_front", true);
  auto& owner = fleet.add("B:1", "hall", "indoor_panel", "", false, false, owner_dir);
  REQUIRE(door.node->start());
  REQUIRE(owner.node->start());
  fleet.run(1'000);

  const std::string owner_id = owner.node->nodeId();
  const std::string call_id = door.node->pressV2("d_front", "");
  REQUIRE(!call_id.empty());
  fleet.run(300);
  REQUIRE(owner.node->reportCallAnsweredV2("d_front", call_id, 0));
  fleet.run(300);

  owner.node->stop();
  bool owner_dead = false;
  for (int i = 0; i < 50 && !owner_dead; ++i) {
    fleet.run(20);
    auto status = json::parse(door.node->statusJson());
    const cJSON* peer = nullptr;
    cJSON_ArrayForEach(peer, json::get(status.get(), "peers")) {
      if (json::getString(peer, "id") == owner_id)
        owner_dead = json::getString(peer, "status") == "dead";
    }
  }
  REQUIRE(owner_dead);
  door.node->reportCallRecovery(call_id, false);
  fleet.run(20);
  CHECK(door.node->statusJson().find(call_id) != std::string::npos);

  owner.node.reset();
  NodeOptions options;
  options.data_dir = owner_dir;
  options.name = "hall";
  options.role = "indoor_panel";
  options.listen_addr = "B:1";
  options.advertise_addr = "B:1";
  options.psk = fleet.psk;
  options.enable_beacon = false;
  options.http_port = 0;
  options.seed_default_config = false;
  options.caps_json = R"({"features":{"runtime_recovery_v1":true}})";
  options.mesh_timing_template = NFleet::timing();
  options.use_mesh_timing_template = true;
  NodeDeps deps;
  deps.clock = &fleet.clock;
  deps.loop = &fleet.loop;
  deps.transport = fleet.net.makeTransport("B:1");
  deps.discovery = fleet.net.makeDiscovery("B:1");
  NFleet::N* owner_shell = &owner;
  owner.node.reset(new Node(options, std::move(deps)));
  owner.node->setUiEventCb(
      [owner_shell](const std::string& event) { owner_shell->ui.push_back(event); });
  owner.node->setTtsCb([owner_shell](const std::string& text, const std::string&) {
    owner_shell->tts.push_back(text);
  });
  REQUIRE(owner.node->start());
  CHECK(owner.node->nodeId() == owner_id);
  owner.node->reportCallRecovery(call_id, true);
  fleet.run(20);

  bool owner_alive = false;
  for (int i = 0; i < 250 && !owner_alive; ++i) {
    fleet.run(20);
    auto status = json::parse(door.node->statusJson());
    const cJSON* peer = nullptr;
    cJSON_ArrayForEach(peer, json::get(status.get(), "peers")) {
      if (json::getString(peer, "id") == owner_id)
        owner_alive = json::getString(peer, "status") == "alive";
    }
  }
  REQUIRE(owner_alive);
  fleet.run(11'000);
  CHECK(door.uiCount("event", "call_cancelled") == 0);
  CHECK(door.node->statusJson().find(call_id) != std::string::npos);
  CHECK(owner.node->statusJson().find(call_id) != std::string::npos);
  CHECK(owner.node->reportCallEndedV2("d_front", call_id, 0, "hangup"));
  fleet.run(500);
  CHECK(door.node->statusJson().find(call_id) == std::string::npos);

  door.node->stop();
  owner.node->stop();
  owner.node.reset();
  for (const char* name : {"doorbell.db", "doorbell.db-wal", "doorbell.db-shm"})
    std::remove((owner_dir + "/" + name).c_str());
  ::rmdir((owner_dir + "/assets").c_str());
  ::rmdir(owner_dir.c_str());
}

TEST_CASE("configured MQTT reachability is measured and administrator overrides stay explicit") {
  int mqtt_port = 0;
  int listener = openProbeListener(&mqtt_port);
  REQUIRE(listener >= 0);

  NFleet fleet;
  auto& node = fleet.add("A:1", "bridge", "indoor_panel", "", true);
  REQUIRE(node.node->start());
  node.node->setRuntimeCapabilities(
      R"({"mains_power":true,"mqtt_reachable":false,"wall_clock_sane":true})");
  node.node->setConfigKey("integrations.mqtt.host", "\"127.0.0.1\"");
  node.node->setConfigKey("integrations.mqtt.port", std::to_string(mqtt_port));
  fleet.run(20);
  auto unmeasured = json::parse(node.node->capabilitiesJson());
  REQUIRE(unmeasured);
  CHECK_FALSE(json::getBool(json::get(unmeasured.get(), "caps"), "mqtt_reachable"));
  auto before_probe = json::parse(node.node->statusJson());
  REQUIRE(before_probe);
  CHECK(json::getString(json::get(before_probe.get(), "leaders"), "mqtt_bridge").empty());
  fleet.run(6'100);

  auto reachable = json::parse(node.node->capabilitiesJson());
  REQUIRE(reachable);
  cJSON* caps = json::get(reachable.get(), "caps");
  CHECK(json::getBool(caps, "mqtt_reachable"));
  CHECK(json::getString(caps, "mqtt_reachability_source") ==
        "configured_endpoint_probe");
  auto status = json::parse(node.node->statusJson());
  REQUIRE(status);
  CHECK(json::getString(json::get(status.get(), "leaders"), "mqtt_bridge") ==
        node.node->nodeId());

  ::close(listener);
  int unreachable_port = 0;
  int temporary_listener = openProbeListener(&unreachable_port);
  REQUIRE(temporary_listener >= 0);
  ::close(temporary_listener);
  node.node->setConfigKey("integrations.mqtt.port", std::to_string(unreachable_port));
  fleet.run(6'100);
  auto unreachable = json::parse(node.node->capabilitiesJson());
  REQUIRE(unreachable);
  caps = json::get(unreachable.get(), "caps");
  CHECK_FALSE(json::getBool(caps, "mqtt_reachable"));
  CHECK(json::getString(caps, "mqtt_reachability_source") ==
        "configured_endpoint_probe");

  node.node->setConfigKey(
      "devices." + node.node->nodeId() + ".caps_override",
      R"({"mqtt_reachable":true})");
  fleet.run(20);
  auto overridden = json::parse(node.node->capabilitiesJson());
  REQUIRE(overridden);
  caps = json::get(overridden.get(), "caps");
  CHECK(json::getBool(caps, "mqtt_reachable"));
  CHECK(json::getString(caps, "mqtt_reachability_source") ==
        "administrator_override");
  node.node->stop();
}

TEST_CASE("pairing: secure-store failure never exposes a mesh PSK") {
  NFleet fleet;
  auto& node = fleet.add("J:1", "newpad", "indoor_panel", "", false, true);
  node.node->setSecureStore(
      [](const std::string&) { return std::string(); },
      [](const std::string&, const std::string&) { return false; });
  REQUIRE(node.node->start());
  CHECK(node.node->foundCluster());
  fleet.run(20);
  CHECK(node.uiCount("paired") == 0);
  CHECK(node.uiCount("pairing_persistence_error") == 1);
  for (const auto& event : node.ui) CHECK(event.find("psk_hex") == std::string::npos);
  auto pairing = json::parse(node.node->pairingJson());
  REQUIRE(pairing);
  CHECK(json::getBool(pairing.get(), "paired") == true);
  CHECK(json::getBool(pairing.get(), "persistence_ready") == false);
  node.node->stop();
}

TEST_CASE("node: pairing discovers and invites an unpaired device and supplies PSK") {
  NFleet f;
  auto& host = f.add("A:1", "front", "door_station", "d_front", /*seed_cfg=*/true);
  auto& joiner = f.add("J:1", "newpad", "indoor_panel", "", /*seed_cfg=*/false,
                       /*zero_psk=*/true);
  std::string stored_psk;
  joiner.node->setSecureStore(
      [](const std::string&) { return std::string(); },
      [&stored_psk](const std::string& key, const std::string& value) {
        if (key != "mesh.psk") return false;
        stored_psk = value;
        return true;
      });
  REQUIRE(host.node->start());
  REQUIRE(joiner.node->start());


  auto pj0 = json::parse(joiner.node->pairingJson());
  REQUIRE(pj0);
  CHECK(json::getBool(pj0.get(), "paired") == false);
  CHECK(json::getBool(pj0.get(), "persistence_ready") == false);
  cJSON* self = json::get(pj0.get(), "self");
  REQUIRE(self);
  CHECK(json::getString(self, "pk").size() == 64);
  CHECK(json::getString(pj0.get(), "pair_qr").rfind("doorbell-pair:", 0) == 0);


  REQUIRE([&] {
    for (int i = 0; i < 200; i++) {
      f.run(50);
      auto pj = json::parse(host.node->pairingJson());
      cJSON* pend = pj ? json::get(pj.get(), "pending") : nullptr;
      cJSON* devs = pend ? json::get(pend, "devices") : nullptr;
      cJSON* it = nullptr;
      cJSON_ArrayForEach(it, devs) {
        if (json::getString(it, "id") == joiner.node->nodeId()) return true;
      }
    }
    return false;
  }());


  host.node->inviteDevice(joiner.node->nodeId());
  REQUIRE([&] {
    for (int i = 0; i < 200; i++) {
      f.run(50);
      if (joiner.uiCount("paired") >= 1) return true;
    }
    return false;
  }());
  // Core stores the PSK through the platform SPI and exposes only its opaque reference.
  std::string psk_ref;
  bool leaked_psk = false;
  for (const auto& e : joiner.ui) {
    auto d = json::parse(e);
    if (d && json::getString(d.get(), "t") == "paired") {
      psk_ref = json::getString(d.get(), "psk_ref");
      leaked_psk = json::get(d.get(), "psk_hex") != nullptr;
    }
  }
  CHECK(psk_ref == "secret:mesh.psk");
  CHECK(leaked_psk == false);
  CHECK(stored_psk.size() == 64);
  CHECK(stored_psk != std::string(64, '0'));

  auto pj1 = json::parse(joiner.node->pairingJson());
  CHECK(json::getBool(pj1.get(), "paired") == true);
  CHECK(json::getBool(pj1.get(), "persistence_ready") == true);
  REQUIRE([&] {
    for (int i = 0; i < 200; i++) {
      f.run(50);
      auto cfg = json::parse(joiner.node->configJson());
      cJSON* qr = cfg ? json::get(json::get(cfg.get(), "quick_replies"), "qr_away") : nullptr;
      if (qr) return true;
    }
    return false;
  }());

  host.node->stop();
  joiner.node->stop();
}

TEST_CASE("node: press evaluates rules and replicates chime, SIP, and events exactly once") {
  NFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true);
  auto& b = f.add("B:1", "kitchen", "indoor_panel", "", false);
  REQUIRE(a.node->start());
  REQUIRE(b.node->start());
  f.run(1000);


  std::string rule = std::string("{\"enabled\":true,") +
      "\"when\":{\"type\":\"button\",\"doors\":[\"d_front\"]}," +
      "\"actions\":[{\"type\":\"chime\",\"devices\":[\"" + b.node->nodeId() + "\"],\"sound\":\"ding1\"}," +
      "{\"type\":\"sip_call\",\"target_extension\":\"600\"}]}";
  a.node->setConfigKey("trigger_rules.r1", rule);
  f.run(500);

  a.node->press("");
  f.run(800);


  CHECK(b.uiCount("event", "press") == 1);
  CHECK(b.uiCount("chime") == 1);
  CHECK(a.uiCount("event", "press") == 1);
  CHECK(a.uiCount("state") == 1);


  f.run(1000);
  CHECK(b.uiCount("event", "press") == 1);
  CHECK(b.uiCount("chime") == 1);

  a.node->stop();
  b.node->stop();
}

TEST_CASE("node: quick replies reach the door-station display and TTS") {
  NFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true);
  auto& b = f.add("B:1", "kitchen", "indoor_panel", "", false);
  REQUIRE(a.node->start());
  REQUIRE(b.node->start());
  f.run(1500);

  const std::string first_call = a.node->pressV2("d_front", "");
  REQUIRE(!first_call.empty());
  f.run(300);


  REQUIRE(b.node->sendQuickReplyV2("qr_away", "", "d_front", first_call, 0));
  f.run(500);

  CHECK(a.uiCount("reply") == 1);
  REQUIRE(a.tts.size() == 1);
  CHECK(a.tts[0] == "ただいま留守にしています");


  CHECK(a.uiCount("event", "reply") == 1);
  CHECK(b.uiCount("event", "reply") == 1);


  b.node->sendQuickReply("", "10分で戻ります", "d_front", "web");
  f.run(500);
  REQUIRE(a.tts.size() == 2);
  CHECK(a.tts[1] == "10分で戻ります");

  const std::string established_call = a.node->pressV2("d_front", "");
  REQUIRE(!established_call.empty());
  f.run(300);
  REQUIRE(b.node->reportCallAnsweredV2("d_front", established_call, 0));
  f.run(300);
  const size_t replies_before = a.uiCount("reply");
  const size_t tts_before = a.tts.size();
  CHECK_FALSE(b.node->sendQuickReplyV2("qr_away", "", "d_front", established_call, 0));
  b.node->sendQuickReply("qr_away", "", "d_front", "web");
  f.run(500);
  CHECK(a.uiCount("reply") == replies_before);
  CHECK(a.tts.size() == tts_before);
  CHECK(b.node->reportCallEndedV2("d_front", established_call, 0));
  f.run(300);

  a.node->stop();
  b.node->stop();
}

TEST_CASE("node: node death records one offline event") {
  NFleet f;
  auto& a = f.add("A:1", "front", "door_station", "d_front", true);
  auto& b = f.add("B:1", "annex", "door_station", "d_annex", false);
  auto& c = f.add("C:1", "kitchen", "indoor_panel", "", false);
  REQUIRE(a.node->start());
  REQUIRE(b.node->start());
  REQUIRE(c.node->start());
  f.run(1500);

  f.net.killNode("B:1");
  f.run(1000);


  CHECK(a.uiCount("event", "offline") == 1);
  CHECK(c.uiCount("event", "offline") == 1);

  a.node->stop();
  b.node->stop();
  c.node->stop();
}



namespace {
int freePort(std::mt19937& rng) {
  std::uniform_int_distribution<int> dist(40000, 60000);
  for (int i = 0; i < 50; i++) {
    int port = dist(rng);
    int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) continue;
    sockaddr_in sa{};
    sa.sin_family = AF_INET;
    sa.sin_port = htons(static_cast<uint16_t>(port));
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int ok = ::bind(fd, reinterpret_cast<sockaddr*>(&sa), sizeof(sa));
    ::close(fd);
    if (ok == 0) return port;
  }
  return -1;
}


std::string httpReq(int port, const std::string& raw) {
  int fd = ::socket(AF_INET, SOCK_STREAM, 0);
  REQUIRE(fd >= 0);
  sockaddr_in sa{};
  sa.sin_family = AF_INET;
  sa.sin_port = htons(static_cast<uint16_t>(port));
  sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  REQUIRE(::connect(fd, reinterpret_cast<sockaddr*>(&sa), sizeof(sa)) == 0);
  REQUIRE(::send(fd, raw.data(), raw.size(), 0) == static_cast<ssize_t>(raw.size()));
  std::string resp;
  char buf[4096];
  timeval tv{5, 0};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  for (;;) {
    ssize_t n = ::recv(fd, buf, sizeof(buf), 0);
    if (n <= 0) break;
    resp.append(buf, static_cast<size_t>(n));
  }
  ::close(fd);
  return resp;
}

std::string simpleReq(int port, const std::string& method, const std::string& path,
                      const std::string& body = "", const std::string& cookie = "") {
  std::string r = method + " " + path + " HTTP/1.1\r\nHost: 127.0.0.1\r\n";
  if (!cookie.empty()) r += "Cookie: " + cookie + "\r\n";
  if (!body.empty()) {
    r += "Content-Type: application/json\r\nContent-Length: " + std::to_string(body.size()) + "\r\n";
  }
  r += "Connection: close\r\n\r\n" + body;
  return httpReq(port, r);
}
}  // namespace

TEST_CASE("node: real TCP and HTTP API smoke test covers login, status, press, and events") {
  std::mt19937 rng(static_cast<uint32_t>(::getpid()) ^ 0x9e37u);
  int mesh_port = freePort(rng);
  int http_port = freePort(rng);
  REQUIRE(mesh_port > 0);
  REQUIRE(http_port > 0);

  NodeOptions o;
  o.data_dir = ":memory:";
  o.name = "real";
  o.role = "door_station";
  o.door = "d_front";
  o.listen_addr = "127.0.0.1:" + std::to_string(mesh_port);
  o.psk.fill(0x5a);
  o.enable_beacon = false;
  o.http_port = http_port;
  Node node(o);
  REQUIRE(node.start());


  CHECK(simpleReq(http_port, "GET", "/api/status").rfind("HTTP/1.1 401", 0) == 0);
  CHECK(simpleReq(http_port, "GET", "/admin/").find("200") != std::string::npos);


  std::string login = simpleReq(http_port, "POST", "/api/login", "{\"password\":\"test123\"}");
  REQUIRE(login.rfind("HTTP/1.1 200", 0) == 0);
  auto cpos = login.find("dbsess=");
  REQUIRE(cpos != std::string::npos);
  std::string cookie = login.substr(cpos, login.find(';', cpos) - cpos);


  CHECK(simpleReq(http_port, "POST", "/api/login", "{\"password\":\"wrong\"}")
            .rfind("HTTP/1.1 401", 0) == 0);

  // status / press / events
  std::string st = simpleReq(http_port, "GET", "/api/status", "", cookie);
  CHECK(st.find("\"peers\"") != std::string::npos);
  CHECK(simpleReq(http_port, "POST", "/api/press", "{\"door\":\"d_front\"}", cookie)
            .rfind("HTTP/1.1 200", 0) == 0);
  std::string ev = simpleReq(http_port, "GET", "/api/events?limit=10", "", cookie);
  CHECK(ev.find("\"press\"") != std::string::npos);


  CHECK(simpleReq(http_port, "GET", "/locale/ja.json").find("呼び出し中") != std::string::npos);

  node.stop();
}


// ---------------------------------------------------------------------------
// Pairing contract: the authoritative state, its events, and the recovery paths.
// ---------------------------------------------------------------------------

namespace {

json::Doc pairingDoc(Node& node) { return json::parse(node.pairingJson()); }

std::string pairingState(Node& node) {
  auto d = pairingDoc(node);
  return d ? json::getString(d.get(), "state") : "";
}

// Last value of one field across every event of a type, or "" when never emitted.
std::string lastEventField(const std::vector<std::string>& ui, const std::string& type,
                           const std::string& field) {
  std::string out;
  for (const auto& e : ui) {
    auto d = json::parse(e);
    if (!d || json::getString(d.get(), "t") != type) continue;
    out = json::getString(d.get(), field.c_str());
  }
  return out;
}

}  // namespace

TEST_CASE("pairing: an unpaired node reports the unpaired state and its own device card") {
  NFleet f;
  auto& node = f.add("A:1", "front", "door_station", "d_front", true, /*zero_psk=*/true);
  REQUIRE(node.node->start());
  f.run(50);

  auto d = pairingDoc(*node.node);
  REQUIRE(d);
  CHECK(json::getString(d.get(), "state") == "unpaired");
  CHECK_FALSE(json::getBool(d.get(), "paired"));
  CHECK_FALSE(json::getBool(d.get(), "is_founder"));
  CHECK(json::getString(d.get(), "psk_source") == "none");
  CHECK(cJSON_IsNull(json::get(d.get(), "psk_ref")));
  const cJSON* self = json::get(d.get(), "self");
  REQUIRE(self);
  CHECK(json::getString(self, "model") == "unknown");
  CHECK(json::getString(self, "platform") == "unknown");
  CHECK_FALSE(json::getString(self, "sw").empty());
  const cJSON* token = json::get(d.get(), "token");
  REQUIRE(token);
  CHECK_FALSE(json::getBool(token, "active"));
  CHECK(json::get(token, "pin") == nullptr);
  const cJSON* home = json::get(d.get(), "home");
  REQUIRE(home);
  CHECK(json::getInt(home, "member_count", 0) == 1);
  node.node->stop();
}

TEST_CASE("pairing: creating a cluster reports ready, the founder badge, and secure storage") {
  NFleet f;
  auto& node = f.add("A:1", "front", "door_station", "d_front", true, /*zero_psk=*/true);
  std::map<std::string, std::string> secrets;
  node.node->setSecureStore(
      [&](const std::string& key) {
        auto it = secrets.find(key);
        return it == secrets.end() ? std::string() : it->second;
      },
      [&](const std::string& key, const std::string& value) {
        secrets[key] = value;
        return true;
      });
  REQUIRE(node.node->start());
  CHECK(node.node->foundCluster());
  f.run(50);

  CHECK(node.uiCount("paired") == 1);
  CHECK(node.uiCount("pairing_state") >= 1);
  CHECK(lastEventField(node.ui, "pairing_state", "state") == "ready");
  CHECK(lastEventField(node.ui, "pairing_state", "psk_source") == "secure_store");

  auto d = pairingDoc(*node.node);
  REQUIRE(d);
  CHECK(json::getString(d.get(), "state") == "ready");
  CHECK(json::getBool(d.get(), "is_founder"));
  CHECK(json::getString(d.get(), "psk_source") == "secure_store");
  CHECK(json::getString(d.get(), "psk_ref") == "secret:mesh.psk");
  CHECK(secrets["mesh.psk"].size() == 64);
  node.node->stop();
}

TEST_CASE("pairing: the snapshot is rebuilt on every call so countdowns tick") {
  NFleet f;
  auto& node = f.add("A:1", "front", "door_station", "d_front", true);
  REQUIRE(node.node->start());
  auto started = json::parse(node.node->startPairingJson(600));
  REQUIRE(started);
  REQUIRE(json::getBool(started.get(), "ok"));

  auto first = pairingDoc(*node.node);
  REQUIRE(first);
  const cJSON* token = json::get(first.get(), "token");
  REQUIRE(token);
  CHECK(json::getBool(token, "active"));
  CHECK(json::getString(token, "pin").size() == 6);
  CHECK(json::getString(token, "host") == "A:1");
  const int64_t before = json::getInt(token, "expires_s", 0);
  const int64_t mode_before =
      json::getInt(json::get(first.get(), "pending"), "pairing_mode_left_s", 0);
  CHECK(before > 0);

  f.run(5000);
  auto later = pairingDoc(*node.node);
  REQUIRE(later);
  CHECK(json::getInt(json::get(later.get(), "token"), "expires_s", 0) < before);
  CHECK(json::getInt(json::get(later.get(), "pending"), "pairing_mode_left_s", 0) < mode_before);
  node.node->stop();
}

TEST_CASE("pairing: a secure-store failure is retried without rejoining the cluster") {
  NFleet f;
  auto& node = f.add("A:1", "front", "door_station", "d_front", true, /*zero_psk=*/true);
  bool store_ok = false;
  std::map<std::string, std::string> secrets;
  node.node->setSecureStore(
      [&](const std::string&) { return std::string(); },
      [&](const std::string& key, const std::string& value) {
        if (!store_ok) return false;
        secrets[key] = value;
        return true;
      });
  REQUIRE(node.node->start());
  CHECK(node.node->foundCluster());
  f.run(50);

  CHECK(node.uiCount("paired") == 0);
  CHECK(node.uiCount("pairing_persistence_error") == 1);
  CHECK(lastEventField(node.ui, "pairing_state", "state") == "persist_error");
  CHECK(pairingState(*node.node) == "persist_error");

  CHECK_FALSE(node.node->retryPairingPersistence());
  CHECK(node.uiCount("pairing_persistence_error") == 2);

  store_ok = true;
  CHECK(node.node->retryPairingPersistence());
  f.run(20);
  CHECK(node.uiCount("paired") == 1);
  CHECK(lastEventField(node.ui, "pairing_state", "state") == "ready");
  CHECK(pairingState(*node.node) == "ready");
  CHECK(secrets["mesh.psk"].size() == 64);
  for (const auto& event : node.ui) CHECK(event.find("psk_hex") == std::string::npos);
  node.node->stop();
}

TEST_CASE("pairing: unpair clears the stored secret and returns to the unpaired state") {
  NFleet f;
  auto& node = f.add("A:1", "front", "door_station", "d_front", true, /*zero_psk=*/true);
  std::map<std::string, std::string> secrets;
  std::vector<std::string> deleted;
  node.node->setSecureStore(
      [&](const std::string& key) {
        auto it = secrets.find(key);
        return it == secrets.end() ? std::string() : it->second;
      },
      [&](const std::string& key, const std::string& value) {
        secrets[key] = value;
        return true;
      });
  node.node->setSecureDelete([&](const std::string& key) {
    deleted.push_back(key);
    secrets.erase(key);
    return true;
  });
  REQUIRE(node.node->start());
  CHECK(node.node->foundCluster());
  f.run(50);
  CHECK(pairingState(*node.node) == "ready");

  node.node->unpair();
  f.run(20);
  CHECK(pairingState(*node.node) == "unpaired");
  CHECK(lastEventField(node.ui, "pairing_state", "state") == "unpaired");
  REQUIRE(deleted.size() == 1);
  CHECK(deleted[0] == "mesh.psk");
  CHECK(secrets.find("mesh.psk") == secrets.end());

  auto d = pairingDoc(*node.node);
  REQUIRE(d);
  CHECK_FALSE(json::getBool(d.get(), "paired"));
  CHECK_FALSE(json::getBool(d.get(), "is_founder"));
  CHECK(json::getString(d.get(), "psk_source") == "none");
  node.node->stop();
}

TEST_CASE("pairing: a platform without secure deletion still unpairs") {
  NFleet f;
  auto& node = f.add("A:1", "front", "door_station", "d_front", true, /*zero_psk=*/true);
  node.node->setSecureStore([](const std::string&) { return std::string(); },
                            [](const std::string&, const std::string&) { return true; });
  REQUIRE(node.node->start());
  CHECK(node.node->foundCluster());
  f.run(20);
  node.node->unpair();
  f.run(20);
  CHECK(pairingState(*node.node) == "unpaired");
  node.node->stop();
}

TEST_CASE("pairing: joining while already paired reports already_paired instead of silence") {
  NFleet f;
  auto& node = f.add("A:1", "front", "door_station", "d_front", true);
  REQUIRE(node.node->start());
  node.node->joinCluster("B:1", "123456");
  f.run(200);
  CHECK(node.uiCount("join_result") == 1);
  CHECK(lastEventField(node.ui, "join_result", "err") == "already_paired");
  CHECK(pairingState(*node.node) == "ready");
  node.node->stop();
}

TEST_CASE("pairing: an administrator revocation unpairs the device") {
  NFleet f;
  auto& panel = f.add("P:1", "panel", "indoor_panel", "", /*seed_cfg=*/true);
  auto& door = f.add("D:1", "front", "door_station", "d_front", /*seed_cfg=*/false);
  door.node->setSecureStore([](const std::string&) { return std::string(); },
                            [](const std::string&, const std::string&) { return true; });
  REQUIRE(panel.node->start());
  REQUIRE(door.node->start());
  REQUIRE([&] {
    for (int i = 0; i < 200; i++) {
      f.run(50);
      auto st = json::parse(panel.node->statusJson());
      const cJSON* it = nullptr;
      cJSON_ArrayForEach(it, json::get(st.get(), "peers")) {
        if (json::getString(it, "id") == door.node->nodeId() &&
            json::getString(it, "status") == "alive")
          return true;
      }
    }
    return false;
  }());

  panel.node->removeDevice(door.node->nodeId());
  REQUIRE([&] {
    for (int i = 0; i < 200; i++) {
      f.run(50);
      if (door.uiCount("pairing_revoked") >= 1) return true;
    }
    return false;
  }());
  f.run(100);
  CHECK(pairingState(*door.node) == "unpaired");
  CHECK(lastEventField(door.ui, "pairing_state", "state") == "unpaired");
  panel.node->stop();
  door.node->stop();
}

TEST_CASE("pairing: an invited device reports invite_result, device_joined, and membership") {
  NFleet f;
  auto& host = f.add("A:1", "front", "door_station", "d_front", /*seed_cfg=*/true);
  auto& joiner = f.add("J:1", "newpad", "indoor_panel", "", /*seed_cfg=*/false,
                       /*zero_psk=*/true);
  joiner.node->setSecureStore([](const std::string&) { return std::string(); },
                              [](const std::string&, const std::string&) { return true; });
  REQUIRE(host.node->start());
  REQUIRE(joiner.node->start());

  REQUIRE([&] {
    for (int i = 0; i < 200; i++) {
      f.run(50);
      auto d = pairingDoc(*host.node);
      const cJSON* it = nullptr;
      cJSON_ArrayForEach(it, json::get(json::get(d.get(), "pending"), "devices")) {
        if (json::getString(it, "id") == joiner.node->nodeId()) return true;
      }
    }
    return false;
  }());

  host.node->inviteDevice(joiner.node->nodeId());
  REQUIRE([&] {
    for (int i = 0; i < 200; i++) {
      f.run(50);
      if (host.uiCount("device_joined") >= 1) return true;
    }
    return false;
  }());
  CHECK(host.uiCount("invite_result") >= 1);
  CHECK(lastEventField(host.ui, "invite_result", "id") == joiner.node->nodeId());
  CHECK(lastEventField(host.ui, "device_joined", "id") == joiner.node->nodeId());
  CHECK(lastEventField(joiner.ui, "pairing_state", "state") == "ready");

  auto d = pairingDoc(*host.node);
  REQUIRE(d);
  CHECK(json::getInt(json::get(d.get(), "home"), "member_count", 0) == 2);
  CHECK(json::getInt(json::get(d.get(), "home"), "connected_count", 0) == 2);
  host.node->stop();
  joiner.node->stop();
}

TEST_CASE("pairing: a scanned QR payload invites the device it names") {
  NFleet f;
  auto& host = f.add("A:1", "front", "door_station", "d_front", /*seed_cfg=*/true);
  auto& joiner = f.add("J:1", "newpad", "indoor_panel", "", /*seed_cfg=*/false,
                       /*zero_psk=*/true);
  joiner.node->setSecureStore([](const std::string&) { return std::string(); },
                              [](const std::string&, const std::string&) { return true; });
  REQUIRE(host.node->start());
  REQUIRE(joiner.node->start());
  f.run(100);

  auto jd = pairingDoc(*joiner.node);
  REQUIRE(jd);
  const std::string qr = json::getString(jd.get(), "pair_qr");
  CHECK(qr.rfind("doorbell-pair:", 0) == 0);

  CHECK_FALSE(host.node->inviteFromQrText("https://example.invalid/not-a-pairing-code"));
  CHECK(host.node->inviteFromQrText(qr));
  REQUIRE([&] {
    for (int i = 0; i < 200; i++) {
      f.run(50);
      if (joiner.uiCount("paired") >= 1) return true;
    }
    return false;
  }());
  CHECK(pairingState(*joiner.node) == "ready");
  host.node->stop();
  joiner.node->stop();
}

TEST_CASE("pairing: denying a device removes it from the pending list") {
  NFleet f;
  auto& host = f.add("A:1", "front", "door_station", "d_front", /*seed_cfg=*/true);
  auto& joiner = f.add("J:1", "newpad", "indoor_panel", "", /*seed_cfg=*/false,
                       /*zero_psk=*/true);
  REQUIRE(host.node->start());
  REQUIRE(joiner.node->start());
  auto pendingCount = [&] {
    auto d = pairingDoc(*host.node);
    return cJSON_GetArraySize(json::get(json::get(d.get(), "pending"), "devices"));
  };
  REQUIRE([&] {
    for (int i = 0; i < 200; i++) {
      f.run(50);
      if (pendingCount() > 0) return true;
    }
    return false;
  }());

  host.node->denyDevice(joiner.node->nodeId());
  f.run(500);
  CHECK(pendingCount() == 0);
  host.node->stop();
  joiner.node->stop();
}

TEST_CASE("pairing: a PIN join reports join_result before paired and never fakes success") {
  // ui イベントの中で type と一致する最初の位置。順序の検証に使う。
  auto indexOf = [](const std::vector<std::string>& ui, const std::string& type) {
    for (size_t i = 0; i < ui.size(); i++) {
      auto d = json::parse(ui[i]);
      if (d && json::getString(d.get(), "t") == type) return static_cast<int>(i);
    }
    return -1;
  };
  // 真偽値フィールド用。lastEventField は文字列専用なので流用できない。
  auto lastEventBool = [](const std::vector<std::string>& ui, const std::string& type,
                          const char* field) {
    bool out = false;
    for (const auto& e : ui) {
      auto d = json::parse(e);
      if (!d || json::getString(d.get(), "t") != type) continue;
      out = json::getBool(d.get(), field);
    }
    return out;
  };

  SUBCASE("a secure-store failure is reported as persist_failed, not as a joined cluster") {
    NFleet f;
    auto& host = f.add("A:1", "front", "door_station", "d_front", /*seed_cfg=*/true);
    auto& joiner = f.add("J:1", "newpad", "indoor_panel", "", /*seed_cfg=*/false,
                         /*zero_psk=*/true);
    joiner.node->setSecureStore([](const std::string&) { return std::string(); },
                                [](const std::string&, const std::string&) { return false; });
    REQUIRE(host.node->start());
    auto started = json::parse(host.node->startPairingJson(600));
    REQUIRE(started);
    REQUIRE(json::getBool(started.get(), "ok"));
    // PIN だけを試すので「まとめて追加」は切る。付けたままだと自動招待が先に成立して
    // どちらの経路で参加したのか分からなくなる。
    host.node->setPairingMode(0);
    f.run(20);

    // 招待が届かないことを確かめてから新端末を起動する。
    REQUIRE(joiner.node->start());
    f.run(50);
    CHECK(pairingState(*joiner.node) == "unpaired");

    joiner.node->joinCluster("A:1", json::getString(started.get(), "pin"));
    REQUIRE([&] {
      for (int i = 0; i < 200; i++) {
        f.run(50);
        if (joiner.uiCount("join_result") >= 1) return true;
      }
      return false;
    }());
    CHECK(joiner.uiCount("join_result") == 1);
    CHECK_FALSE(lastEventBool(joiner.ui, "join_result", "ok"));
    CHECK(lastEventField(joiner.ui, "join_result", "err") == "persist_failed");
    CHECK(joiner.uiCount("paired") == 0);
    CHECK(joiner.uiCount("pairing_persistence_error") == 1);
    CHECK(pairingState(*joiner.node) == "persist_error");
    for (const auto& event : joiner.ui) CHECK(event.find("psk_hex") == std::string::npos);

    // C7: 再試行が通れば join をやり直さずに ready になる。
    joiner.node->setSecureStore([](const std::string&) { return std::string(); },
                                [](const std::string&, const std::string&) { return true; });
    CHECK(joiner.node->retryPairingPersistence());
    f.run(50);
    CHECK(joiner.uiCount("paired") == 1);
    CHECK(pairingState(*joiner.node) == "ready");
    host.node->stop();
    joiner.node->stop();
  }

  SUBCASE("a successful join emits join_result ahead of paired and pairing_state ready") {
    NFleet f;
    auto& host = f.add("A:1", "front", "door_station", "d_front", /*seed_cfg=*/true);
    auto& joiner = f.add("J:1", "newpad", "indoor_panel", "", /*seed_cfg=*/false,
                         /*zero_psk=*/true);
    joiner.node->setSecureStore([](const std::string&) { return std::string(); },
                                [](const std::string&, const std::string&) { return true; });
    REQUIRE(host.node->start());
    auto started = json::parse(host.node->startPairingJson(600));
    REQUIRE(started);
    REQUIRE(json::getBool(started.get(), "ok"));
    // PIN だけを試すので「まとめて追加」は切る。付けたままだと自動招待が先に成立して
    // どちらの経路で参加したのか分からなくなる。
    host.node->setPairingMode(0);
    f.run(20);

    // 招待が届かないことを確かめてから新端末を起動する。
    REQUIRE(joiner.node->start());
    f.run(50);
    CHECK(pairingState(*joiner.node) == "unpaired");

    joiner.node->joinCluster("A:1", json::getString(started.get(), "pin"));
    REQUIRE([&] {
      for (int i = 0; i < 200; i++) {
        f.run(50);
        if (joiner.uiCount("paired") >= 1) return true;
      }
      return false;
    }());
    const int join_at = indexOf(joiner.ui, "join_result");
    const int paired_at = indexOf(joiner.ui, "paired");
    REQUIRE(join_at >= 0);
    REQUIRE(paired_at >= 0);
    CHECK(join_at < paired_at);
    CHECK(lastEventBool(joiner.ui, "join_result", "ok"));
    CHECK(lastEventField(joiner.ui, "pairing_state", "state") == "ready");
    CHECK_FALSE(json::getBool(pairingDoc(*joiner.node).get(), "is_founder"));
    host.node->stop();
    joiner.node->stop();
  }

  SUBCASE("a wrong PIN reports bad_pin and leaves the node unpaired") {
    NFleet f;
    auto& host = f.add("A:1", "front", "door_station", "d_front", /*seed_cfg=*/true);
    auto& joiner = f.add("J:1", "newpad", "indoor_panel", "", /*seed_cfg=*/false,
                         /*zero_psk=*/true);
    REQUIRE(host.node->start());
    REQUIRE(json::getBool(json::parse(host.node->startPairingJson(600)).get(), "ok"));
    // PIN だけを試すので「まとめて追加」は切る。付けたままだと自動招待が先に成立して
    // どちらの経路で参加したのか分からなくなる。
    host.node->setPairingMode(0);
    f.run(20);

    // 招待が届かないことを確かめてから新端末を起動する。
    REQUIRE(joiner.node->start());
    f.run(50);
    CHECK(pairingState(*joiner.node) == "unpaired");

    joiner.node->joinCluster("A:1", "000000");
    REQUIRE([&] {
      for (int i = 0; i < 200; i++) {
        f.run(50);
        if (joiner.uiCount("join_result") >= 1) return true;
      }
      return false;
    }());
    CHECK_FALSE(lastEventBool(joiner.ui, "join_result", "ok"));
    CHECK(lastEventField(joiner.ui, "join_result", "err") == "bad_pin");
    CHECK(joiner.uiCount("paired") == 0);
    CHECK(pairingState(*joiner.node) == "unpaired");
    CHECK(lastEventField(joiner.ui, "pairing_state", "state") == "unpaired");
    host.node->stop();
    joiner.node->stop();
  }
}

TEST_CASE("pairing: pairing mode is refused while the node is not in a cluster") {
  NFleet f;
  auto& node = f.add("A:1", "front", "door_station", "d_front", true, /*zero_psk=*/true);
  REQUIRE(node.node->start());
  auto started = json::parse(node.node->startPairingJson(600));
  REQUIRE(started);
  CHECK_FALSE(json::getBool(started.get(), "ok"));
  CHECK(json::getString(started.get(), "err") == "host_unpaired");

  node.node->setPairingMode(600);
  f.run(50);
  auto d = pairingDoc(*node.node);
  REQUIRE(d);
  CHECK_FALSE(json::getBool(json::get(d.get(), "pending"), "pairing_mode"));
  node.node->stop();
}

TEST_CASE("pairing: minting a PIN neither opens the bulk-add window nor invites anyone") {
  NFleet f;
  auto& host = f.add("A:1", "front", "door_station", "d_front", /*seed_cfg=*/true);
  auto& joiner = f.add("J:1", "newpad", "indoor_panel", "", /*seed_cfg=*/false,
                       /*zero_psk=*/true);
  joiner.node->setSecureStore([](const std::string&) { return std::string(); },
                              [](const std::string&, const std::string&) { return true; });
  REQUIRE(host.node->start());
  REQUIRE(joiner.node->start());

  // Wait for the unpaired device to be discovered, so the host has something it *could*
  // auto-invite if minting a PIN opened the window.
  REQUIRE([&] {
    for (int i = 0; i < 200; i++) {
      f.run(50);
      auto snapshot = json::parse(host.node->pairingJson());
      const cJSON* pending = snapshot ? json::get(snapshot.get(), "pending") : nullptr;
      const cJSON* devices = pending ? json::get(pending, "devices") : nullptr;
      const cJSON* device = nullptr;
      cJSON_ArrayForEach(device, devices) {
        if (json::getString(device, "id") == joiner.node->nodeId()) return true;
      }
    }
    return false;
  }());

  auto minted = json::parse(host.node->mintJoinTokenJson(0));
  REQUIRE(minted);
  CHECK(json::getBool(minted.get(), "ok"));
  // Same shape as the bulk-add response, so one card can render either.
  CHECK(json::getString(minted.get(), "pin").size() == 6);
  CHECK_FALSE(json::getString(minted.get(), "host").empty());
  CHECK(json::getInt(minted.get(), "expires_s") > 0);

  auto after_mint = json::parse(host.node->pairingJson());
  REQUIRE(after_mint);
  const cJSON* pending = json::get(after_mint.get(), "pending");
  // The window stayed shut: showing a PIN is not a decision to add whatever is nearby.
  CHECK_FALSE(json::getBool(pending, "pairing_mode"));
  CHECK(json::getInt(pending, "pairing_mode_left_s") == 0);
  CHECK(json::getBool(json::get(after_mint.get(), "token"), "active"));

  // Give the host ample time to auto-invite; it must not, and the device must stay pending.
  f.run(2000);
  CHECK(joiner.uiCount("paired") == 0);
  auto still_pending = json::parse(host.node->pairingJson());
  REQUIRE(still_pending);
  const cJSON* devices = json::get(json::get(still_pending.get(), "pending"), "devices");
  bool listed = false;
  const cJSON* device = nullptr;
  cJSON_ArrayForEach(device, devices) {
    if (json::getString(device, "id") != joiner.node->nodeId()) continue;
    listed = true;
    CHECK(json::getString(device, "invite_state") == "none");
  }
  CHECK(listed);
  CHECK_FALSE(json::getBool(json::get(still_pending.get(), "pending"), "pairing_mode"));

  // Minting again refreshes the PIN rather than reusing it, and still leaves the window shut.
  const std::string first_pin = json::getString(minted.get(), "pin");
  auto refreshed = json::parse(host.node->mintJoinTokenJson(60));
  REQUIRE(refreshed);
  CHECK(json::getBool(refreshed.get(), "ok"));
  CHECK(json::getString(refreshed.get(), "pin") != first_pin);
  CHECK(json::getInt(refreshed.get(), "expires_s") <= 60);
  auto after_refresh = json::parse(host.node->pairingJson());
  CHECK_FALSE(json::getBool(json::get(after_refresh.get(), "pending"), "pairing_mode"));

  // The explicit bulk-add button is what opens the window, and it returns the same shape.
  auto bulk = json::parse(host.node->startPairingJson(600));
  REQUIRE(bulk);
  CHECK(json::getBool(bulk.get(), "ok"));
  CHECK(json::getString(bulk.get(), "pin").size() == 6);
  auto after_bulk = json::parse(host.node->pairingJson());
  CHECK(json::getBool(json::get(after_bulk.get(), "pending"), "pairing_mode"));

  // An unpaired node has no cluster to mint for.
  auto refused = json::parse(joiner.node->mintJoinTokenJson(0));
  REQUIRE(refused);
  CHECK_FALSE(json::getBool(refused.get(), "ok"));
  CHECK(json::getString(refused.get(), "err") == "host_unpaired");

  host.node->stop();
  joiner.node->stop();
}

TEST_CASE("doors: an indoor panel lists a live door station's door even without a config entry") {
  NFleet f;
  auto& indoor = f.add("I:1", "living", "indoor_panel", "", /*seed_cfg=*/true);
  auto& station = f.add("A:1", "front-panel", "door_station", "d_front", /*seed_cfg=*/false);
  REQUIRE(indoor.node->start());
  REQUIRE(station.node->start());

  auto doorsOf = [](Node& node) {
    auto status = json::parse(node.statusJson());
    REQUIRE(status);
    return json::Doc(cJSON_Duplicate(json::get(status.get(), "doors"), 1));
  };

  // The door station seeds its own entry, which replicates to the panel.
  REQUIRE([&] {
    for (int i = 0; i < 200; i++) {
      f.run(50);
      auto doors = doorsOf(*indoor.node);
      if (doors && cJSON_IsObject(json::get(doors.get(), "d_front"))) return true;
    }
    return false;
  }());
  auto seeded = doorsOf(*indoor.node);
  const cJSON* entry = json::get(seeded.get(), "d_front");
  REQUIRE(cJSON_IsObject(entry));
  CHECK(json::getBool(entry, "configured"));
  CHECK(json::getString(entry, "label") == "front-panel");

  // Now model the upgrade case: the door entry is gone but the station is still alive. The
  // panel must keep the tile so announcements and unlock visibility have something to target.
  auto removed = json::parse(indoor.node->deleteConfigKeyJson("doors.d_front"));
  REQUIRE(removed);
  REQUIRE(json::getBool(removed.get(), "ok"));
  f.run(500);
  auto degraded = doorsOf(*indoor.node);
  const cJSON* live = json::get(degraded.get(), "d_front");
  REQUIRE(cJSON_IsObject(live));
  CHECK_FALSE(json::getBool(live, "configured"));
  // The label falls back to the peer's device name rather than showing a blank tile.
  CHECK(json::getString(live, "label") == "front-panel");
  CHECK(cJSON_IsObject(json::get(live, "unlock")));

  // The panel can still post an announcement to the door it is showing.
  REQUIRE(indoor.node->setDoorNotice("d_front", "Side gate today", 0));
  REQUIRE([&] {
    for (int i = 0; i < 200; i++) {
      f.run(50);
      auto doors = doorsOf(*station.node);
      const cJSON* notice = doors ? json::get(json::get(doors.get(), "d_front"), "notice")
                                  : nullptr;
      if (cJSON_IsObject(notice) &&
          json::getString(notice, "text") == "Side gate today")
        return true;
    }
    return false;
  }());

  // A door nobody serves is still refused.
  CHECK_FALSE(indoor.node->setDoorNotice("d_nowhere", "hello", 0));

  indoor.node->stop();
  station.node->stop();
}

TEST_CASE("pairing: unpair then found leaves no peer from the previous cluster") {
  // The regression: after unpairing all three devices and founding a fresh cluster on one of
  // them, /api/status still listed the old cluster's members as offline peers. They came from
  // devices.<id> entries that survived unpair in the replicated configuration, so the founder's
  // brand-new cluster appeared to have members it had never met.
  NFleet f;
  auto& founder = f.add("A:1", "front-panel", "door_station", "d_front", /*seed_cfg=*/true);
  auto& joiner = f.add("J:1", "living", "indoor_panel", "", /*seed_cfg=*/false);
  REQUIRE(founder.node->start());
  REQUIRE(joiner.node->start());
  const std::string joiner_id = joiner.node->nodeId();

  // Let the two become a cluster, so the founder learns the other device for real.
  REQUIRE([&] {
    for (int i = 0; i < 300; i++) {
      f.run(50);
      auto config = json::parse(founder.node->configJson());
      if (config && json::get(json::get(config.get(), "devices"), joiner_id.c_str()))
        return true;
    }
    return false;
  }());
  founder.node->setConfigKey("devices." + joiner_id + ".name", "\"doorbell-android\"");
  f.run(200);

  auto peerIds = [](Node& node) {
    auto status = json::parse(node.statusJson());
    REQUIRE(status);
    std::set<std::string> ids;
    const cJSON* peers = json::get(status.get(), "peers");
    const cJSON* peer = nullptr;
    cJSON_ArrayForEach(peer, peers) ids.insert(json::getString(peer, "id"));
    return ids;
  };
  CHECK(peerIds(*founder.node).count(joiner_id) == 1);

  // Both devices leave, as an operator resetting the house would do.
  joiner.node->unpair();
  founder.node->unpair();
  f.run(200);

  // The founder's own identity survives; the other device is gone from configuration entirely,
  // not merely marked offline.
  auto after = json::parse(founder.node->configJson());
  REQUIRE(after);
  const cJSON* devices = json::get(after.get(), "devices");
  CHECK(json::get(devices, joiner_id.c_str()) == nullptr);
  CHECK(cJSON_IsObject(json::get(devices, founder.node->nodeId().c_str())));
  // The first-run defaults are re-seeded immediately, so the device is usable while unpaired.
  CHECK(json::getInt(after.get(), "schema_version") == 1);

  // Founding a fresh cluster starts with this device and nothing else.
  REQUIRE(founder.node->foundCluster());
  f.run(300);
  const std::set<std::string> fresh = peerIds(*founder.node);
  CHECK(fresh.count(joiner_id) == 0);
  for (const std::string& id : fresh) CHECK(id == founder.node->nodeId());

  // The history this device recorded is its own and is deliberately kept, even though its
  // attribution may still name a device that has left.
  auto history = json::parse(founder.node->callLogJson(0, 50));
  REQUIRE(history);
  CHECK(cJSON_IsArray(json::get(history.get(), "rows")));

  founder.node->stop();
  joiner.node->stop();
}

TEST_CASE("pairing: a replicated devices entry from the old cluster does not resurrect") {
  // Purging must not be done with tombstones. A tombstone replicates, so re-pairing to the same
  // cluster would push a deletion for every device the leaving node had forgotten -- and the
  // forgotten entries must come back from the cluster instead.
  NFleet f;
  auto& keeper = f.add("K:1", "living", "indoor_panel", "", /*seed_cfg=*/true);
  auto& leaver = f.add("L:1", "front-panel", "door_station", "d_front", /*seed_cfg=*/false);
  REQUIRE(keeper.node->start());
  REQUIRE(leaver.node->start());
  const std::string keeper_id = keeper.node->nodeId();
  const std::string leaver_id = leaver.node->nodeId();

  REQUIRE([&] {
    for (int i = 0; i < 300; i++) {
      f.run(50);
      auto config = json::parse(leaver.node->configJson());
      if (config && json::get(json::get(config.get(), "devices"), keeper_id.c_str()))
        return true;
    }
    return false;
  }());
  // A third device that only ever existed in configuration, like an old cluster member.
  const std::string ghost_id(32, 'c');
  keeper.node->setConfigKey("devices." + ghost_id + ".name", "\"doorbell-iPadmini3\"");
  keeper.node->setConfigKey("devices." + ghost_id + ".role", "\"door_station\"");
  REQUIRE([&] {
    for (int i = 0; i < 300; i++) {
      f.run(50);
      auto config = json::parse(leaver.node->configJson());
      if (config && json::get(json::get(config.get(), "devices"), ghost_id.c_str()))
        return true;
    }
    return false;
  }());

  leaver.node->unpair();
  f.run(200);
  // Locally forgotten, including the ghost it had only ever replicated.
  auto local = json::parse(leaver.node->configJson());
  REQUIRE(local);
  CHECK(json::get(json::get(local.get(), "devices"), ghost_id.c_str()) == nullptr);
  CHECK(json::get(json::get(local.get(), "devices"), keeper_id.c_str()) == nullptr);

  // The cluster it left is untouched: no deletion was replicated to it.
  f.run(600);
  auto remote = json::parse(keeper.node->configJson());
  REQUIRE(remote);
  const cJSON* remote_devices = json::get(remote.get(), "devices");
  CHECK(cJSON_IsObject(json::get(remote_devices, ghost_id.c_str())));
  CHECK(cJSON_IsObject(json::get(remote_devices, keeper_id.c_str())));
  CHECK(cJSON_IsObject(json::get(remote_devices, leaver_id.c_str())));

  keeper.node->stop();
  leaver.node->stop();
}

TEST_CASE("calls: joining a cluster imports the history silently") {
  // Owner observation: a newly paired indoor panel rang many times right after joining. Every
  // historical press replicated by anti-entropy was dispatched while its projection was briefly
  // "ringing", so the panel re-enacted calls the house had taken days earlier.
  NFleet f;
  auto& station = f.add("A:1", "front-panel", "door_station", "d_front", /*seed_cfg=*/true);
  REQUIRE(station.node->start());
  f.run(200);

  for (int i = 0; i < 20; i++) {
    const std::string call = station.node->pressV2("d_front", "");
    REQUIRE_FALSE(call.empty());
    REQUIRE(station.node->cancelCallV2("d_front", call, "visitor"));
    f.run(2000);
  }
  // Every one of those calls is now well past its ring window.
  f.run(180'000, 1000);

  auto& panel = f.add("P:1", "living", "indoor_panel", "", /*seed_cfg=*/false);
  REQUIRE(panel.node->start());
  REQUIRE([&] {
    for (int i = 0; i < 400; i++) {
      f.run(50);
      auto history = json::parse(panel.node->callLogJson(0, 100));
      if (history && cJSON_GetArraySize(json::get(history.get(), "rows")) == 20) return true;
    }
    return false;
  }());

  // The history is there in full, and not one of those calls rang.
  auto history = json::parse(panel.node->callLogJson(0, 100));
  REQUIRE(history);
  CHECK(cJSON_GetArraySize(json::get(history.get(), "rows")) == 20);
  CHECK(panel.uiCount("chime") == 0);
  CHECK(panel.uiCount("event", "press") == 0);
  CHECK(panel.tts.empty());

  // A call that is genuinely ringing when the panel joins rings exactly once.
  panel.ui.clear();
  const std::string live = station.node->pressV2("d_front", "p_delivery");
  REQUIRE_FALSE(live.empty());
  REQUIRE([&] {
    for (int i = 0; i < 300; i++) {
      f.run(50);
      if (panel.uiCount("chime") >= 1) return true;
    }
    return false;
  }());
  f.run(2000);
  CHECK(panel.uiCount("chime") == 1);
  CHECK(panel.uiCount("event", "press") == 1);

  station.node->stop();
  panel.node->stop();
}

TEST_CASE("calls: an indoor panel rings and never answers by itself") {
  // Real-device finding: the call log recorded outcome "answered", answered_by an indoor panel
  // nobody had touched. SipSettings::auto_answer defaulted to true for every role, so an
  // unconfigured panel picked up the incoming SIP call and its shell reported it as answered.
  NFleet f;
  auto& station = f.add("A:1", "front-panel", "door_station", "d_front", /*seed_cfg=*/true);
  auto& panel = f.add("P:1", "living", "indoor_panel", "", /*seed_cfg=*/false);
  REQUIRE(station.node->start());
  REQUIRE(panel.node->start());
  f.run(300);

  auto answerMode = [](Node& node) {
    auto status = json::parse(node.statusJson());
    REQUIRE(status);
    return json::getString(json::get(status.get(), "sip"), "answer_mode");
  };
  // The documented defaults, now actually applied: the door answers, the panel waits.
  CHECK(answerMode(*station.node) == "auto");
  CHECK(answerMode(*panel.node) == "ring");

  // A household that wants an intercom can still opt in, per device.
  panel.node->setConfigKey(
      "sip.accounts." + panel.node->nodeId() + ".answer_mode", "\"auto\"");
  f.run(300);
  CHECK(answerMode(*panel.node) == "auto");
  panel.node->setConfigKey(
      "sip.accounts." + panel.node->nodeId() + ".answer_mode", "\"ring\"");
  f.run(300);
  CHECK(answerMode(*panel.node) == "ring");

  // A ringing call that nobody answers is never attributed to anyone, and opening a listen-in
  // (monitor) session while it rings is not an answer either. A monitor dialog is one-way audio
  // that a panel opens by itself; core reports a call answered only for the primary dialog it
  // owns, so a storm of monitor sessions cannot promote a ringing call to answered.
  const std::string call = station.node->pressV2("d_front", "");
  REQUIRE_FALSE(call.empty());
  for (int i = 0; i < 20; i++) {
    panel.node->sipCall("sip:127.0.0.1:47190", "monitor");
    f.run(50);
  }
  f.run(1000);
  auto history = json::parse(panel.node->callLogJson(0, 10));
  REQUIRE(history);
  const cJSON* rows = json::get(history.get(), "rows");
  const cJSON* row = nullptr;
  cJSON_ArrayForEach(row, rows) {
    CHECK(json::getString(row, "outcome") != "answered");
    CHECK(json::getString(row, "answered_by").empty());
  }

  station.node->stop();
  panel.node->stop();
}

TEST_CASE("calls: a monitor dialog leaves a ringing call ringing") {
  // The mode of the dialog in the primary slot is what decides whether it may answer. A panel
  // opening listen-in must leave the call ringing and the history untouched.
  NFleet f;
  auto& station = f.add("A:1", "front-panel", "door_station", "d_front", /*seed_cfg=*/true);
  auto& panel = f.add("P:1", "living", "indoor_panel", "", /*seed_cfg=*/false);
  REQUIRE(station.node->start());
  REQUIRE(panel.node->start());
  f.run(300);

  auto dialogMode = [](Node& node) {
    auto status = json::parse(node.statusJson());
    REQUIRE(status);
    return json::getString(json::get(status.get(), "call"), "dialog_mode");
  };
  CHECK(dialogMode(*panel.node).empty());

  const std::string call = station.node->pressV2("d_front", "");
  REQUIRE_FALSE(call.empty());
  f.run(300);

  // The panel opens listen-in. The dialog mode follows it, and that mode is what the answer
  // guard reads.
  panel.node->sipCall("sip:127.0.0.1:47190", "monitor");
  f.run(3000);  // let the published status snapshot catch up
  CHECK(dialogMode(*panel.node) == "monitor");
  CHECK_FALSE(SipCtl::dialogCanAnswer(dialogMode(*panel.node)));

  // The call is still ringing on the door station and nothing has been attributed to anyone.
  auto status = json::parse(station.node->statusJson());
  REQUIRE(status);
  const cJSON* calls = json::get(status.get(), "active_calls");
  bool still_ringing = false;
  const cJSON* entry = nullptr;
  cJSON_ArrayForEach(entry, calls) {
    if (json::getString(entry, "call_id") != call) continue;
    still_ringing = json::getString(entry, "state") == "ringing";
  }
  CHECK(still_ringing);
  for (Node* node : {station.node.get(), panel.node.get()}) {
    auto history = json::parse(node->callLogJson(0, 10));
    REQUIRE(history);
    const cJSON* row = nullptr;
    cJSON_ArrayForEach(row, json::get(history.get(), "rows")) {
      CHECK(json::getString(row, "outcome") != "answered");
      CHECK(json::getString(row, "answered_by").empty());
    }
  }

  // A talk dialog is a different matter and is allowed to answer.
  panel.node->sipCall("sip:127.0.0.1:47190", "answer");
  f.run(3000);
  CHECK(dialogMode(*panel.node) == "answer");
  CHECK(SipCtl::dialogCanAnswer(dialogMode(*panel.node)));

  station.node->stop();
  panel.node->stop();
}

TEST_CASE("doors: served_by and the peer list never disagree about a station") {
  // Device finding: /api/status listed a door station as "offline" in peers[] while
  // doors["door-mini3"].served_by named that same station, and the node was answering HTTP the
  // whole time. served_by is documented as the *alive* station, so the two views contradicted
  // each other. They now read one liveness map, built once per status document.
  NFleet f;
  auto& panel = f.add("I:1", "living", "indoor_panel", "", /*seed_cfg=*/true);
  auto& station = f.add("A:1", "mini3", "door_station", "door-mini3", /*seed_cfg=*/false);
  REQUIRE(panel.node->start());
  REQUIRE(station.node->start());

  struct View {
    std::string served_by;
    std::string peer_status;
    bool has_door = false;
  };
  auto view = [&](Node& node, const std::string& door, const std::string& peer_id) {
    auto status = json::parse(node.statusJson());
    REQUIRE(status);
    View out;
    const cJSON* entry = json::get(json::get(status.get(), "doors"), door.c_str());
    out.has_door = cJSON_IsObject(entry);
    if (out.has_door) {
      const cJSON* served = json::get(entry, "served_by");
      out.served_by = cJSON_IsString(served) ? served->valuestring : "";
    }
    const cJSON* peer = nullptr;
    cJSON_ArrayForEach(peer, json::get(status.get(), "peers")) {
      if (json::getString(peer, "id") == peer_id) out.peer_status = json::getString(peer, "status");
    }
    return out;
  };
  const std::string station_id = station.node->nodeId();
  auto settle = [&](const std::function<bool(const View&)>& done) {
    for (int i = 0; i < 600; i++) {
      f.run(50);
      if (done(view(*panel.node, "door-mini3", station_id))) return true;
    }
    return false;
  };
  // Whatever the state, the two halves of the status document must tell the same story.
  auto consistent = [](const View& seen) {
    if (!seen.served_by.empty() && seen.peer_status != "alive") return false;
    if (seen.peer_status != "alive" && !seen.served_by.empty()) return false;
    return true;
  };

  REQUIRE(settle([&](const View& seen) { return seen.served_by == station_id; }));
  {
    const View seen = view(*panel.node, "door-mini3", station_id);
    CHECK(seen.served_by == station_id);
    CHECK(seen.peer_status == "alive");
    CHECK(consistent(seen));
  }

  // Flip the station offline: served_by must go null as soon as the peer stops being alive.
  f.net.partition({{"I:1"}, {"A:1"}});
  REQUIRE(settle([&](const View& seen) { return seen.served_by.empty(); }));
  {
    const View seen = view(*panel.node, "door-mini3", station_id);
    CHECK(seen.served_by.empty());
    CHECK(seen.peer_status != "alive");
    // The door itself stays: it is configured, it simply has nobody serving it right now.
    CHECK(seen.has_door);
    CHECK(consistent(seen));
  }

  // ...and back. The same node id returns rather than arriving as a second entry.
  f.net.heal();
  REQUIRE(settle([&](const View& seen) { return seen.served_by == station_id; }));
  {
    const View seen = view(*panel.node, "door-mini3", station_id);
    CHECK(seen.peer_status == "alive");
    CHECK(consistent(seen));
    auto status = json::parse(panel.node->statusJson());
    REQUIRE(status);
    size_t entries = 0;
    const cJSON* peer = nullptr;
    cJSON_ArrayForEach(peer, json::get(status.get(), "peers")) {
      if (json::getString(peer, "id") == station_id) entries++;
    }
    CHECK(entries == 1);
  }

  // The agreement holds while the cluster keeps running, not only at the moments checked above.
  for (int i = 0; i < 40; i++) {
    f.run(100);
    CHECK(consistent(view(*panel.node, "door-mini3", station_id)));
  }

  panel.node->stop();
  station.node->stop();
}
