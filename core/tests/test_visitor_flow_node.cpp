// Visitor flow at node level: notify, gating, snapshots, replication, configuration writes and
// the Telegram and indoor-alert mappings, against a simulated door station and indoor panel.
#include <array>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "mesh/mesh.h"
#include "node/node.h"
#include "operation_test_fixture.h"
#include "util/clock.h"
#include "util/common.h"
#include "util/json.h"
#include "util/runloop.h"

using namespace db;

namespace {

const std::string kCameraUrl = "https://192.0.2.20/snapshot.jpg";
const std::string kCameraSecret = R"({"username":"cam-user","password":"cam-pass-77"})";

Bytes cameraJpeg(const std::string& marker) {
  Bytes out = {0xFF, 0xD8, 0xFF, 0xE0};
  for (char c : "still:" + marker) out.push_back(static_cast<uint8_t>(c));
  out.push_back(0xFF);
  out.push_back(0xD9);
  return out;
}

struct FakeHttps {
  std::vector<std::pair<std::string, std::string>> calls;  // (url, body)
  Node::HttpsFn fn() {
    return [this](const std::string&, const std::string& url, const std::string&, const Bytes& body,
                  std::function<void(int, std::string)> done) {
      calls.emplace_back(url, std::string(body.begin(), body.end()));
      done(200, R"({"ok":true,"result":{"message_id":7}})");
    };
  }
  size_t count(const std::string& api) const {
    size_t n = 0;
    for (const auto& call : calls)
      if (call.first.find("/" + api) != std::string::npos) ++n;
    return n;
  }
  const std::string* lastBody(const std::string& api) const {
    for (auto it = calls.rbegin(); it != calls.rend(); ++it)
      if (it->first.find("/" + api) != std::string::npos) return &it->second;
    return nullptr;
  }
};

struct CameraRequest {
  std::string url;
  std::string headers;
};

struct Rig {
  SimClock clock{1'700'000'000'000LL, 0};
  Runloop loop{clock};
  InMemNet net{loop};
  std::array<uint8_t, 32> psk{};

  Rig() { psk.fill(0x5a); }

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
    FakeHttps https;
    std::map<std::string, std::string> secrets;
    std::vector<std::string> ui;
    std::vector<CameraRequest> camera_requests;
    // Answer for the next external-camera request; "hang" never completes it.
    std::function<bool(Bytes*)> camera_answer;

    std::vector<json::Doc> uiWhere(const std::string& t, const std::string& key = "",
                                   const std::string& value = "") const {
      std::vector<json::Doc> out;
      for (const auto& line : ui) {
        auto d = json::parse(line);
        if (!d || json::getString(d.get(), "t") != t) continue;
        if (!key.empty() && json::getString(d.get(), key.c_str()) != value) continue;
        out.push_back(std::move(d));
      }
      return out;
    }
    std::vector<json::Doc> messages() const { return uiWhere("event", "type", "visitor_message"); }
    std::vector<json::Doc> alerts() const { return uiWhere("device_alert", "kind", "visitor_message"); }
  };
  std::vector<std::unique_ptr<N>> nodes;

  N& add(const std::string& addr, const std::string& name, const std::string& role,
         const std::string& door, bool seed, const std::string& caps_json = "") {
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
    o.caps_json = caps_json;
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
    raw->secrets["telegram.test"] = "TESTTOKEN";
    raw->secrets["media.porch_camera"] = kCameraSecret;
    n->node->setSecureStore(
        [raw](const std::string& key) {
          auto it = raw->secrets.find(key);
          return it == raw->secrets.end() ? std::string() : it->second;
        },
        [raw](const std::string& key, const std::string& value) {
          raw->secrets[key] = value;
          return true;
        });
    n->node->setHttpsFn(raw->https.fn());
    n->node->setUiEventCb([raw](const std::string& e) { raw->ui.push_back(e); });
    n->node->setCameraFetchFn([raw](const std::string& url, const std::string& headers,
                                    std::function<void(int, Bytes)> done) {
      raw->camera_requests.push_back({url, headers});
      Bytes body;
      if (raw->camera_answer && !raw->camera_answer(&body)) return;
      done(body.empty() ? 404 : 200, body);
    });
    nodes.push_back(std::move(n));
    return *nodes.back();
  }

  void run(int64_t ms, int64_t step = 10) {
    for (int64_t t = 0; t < ms; t += step) {
      clock.advance(step);
      loop.pumpDue();
    }
  }
  template <class F>
  bool runUntil(F cond, int64_t max_ms, int64_t step = 10) {
    loop.pumpDue();
    if (cond()) return true;
    for (int64_t t = 0; t < max_ms; t += step) {
      clock.advance(step);
      loop.pumpDue();
      if (cond()) return true;
    }
    return false;
  }
};

const char* kManifest =
    R"({"schema_version":1,"units":"logical","viewport":{"minimum_touch":44,"scale_min":0.75,"scale_max":2.0},"elements":{"purpose.button":{"properties":["scale"],"defaults":{"scale":1.0},"safety_critical":false},"call.primary":{"properties":["scale"],"defaults":{"scale":1.0},"safety_critical":false},"cancel.call":{"properties":["scale"],"defaults":{"scale":1.0},"safety_critical":true}}})";

// Runtime capabilities replace the measured set, so the platform measurements are restated.
const char* kPlatform =
    R"("tls12":true,"wan":true,"mains_power":true,"mqtt_reachable":true,"wall_clock_sane":true)";

void advertiseFlowShell(Node& node) {
  node.setRuntimeCapabilities(
      std::string("{") + kPlatform +
      R"(,"cpu_score":20,"features":{"visitor_flow_v1":true,"ui_manifest_v1":true,"device_alert_v1":true}})");
  node.setUiManifest(kManifest);
}

const char* kMessage =
    R"({"ja":"ja-parcel","en":"A parcel was left at the door","zh":"zh-parcel"})";

std::string setOp(const std::string& key, const std::string& value) {
  return R"({"op":"set","key":")" + key + R"(","value":)" + value + "}";
}
std::string ops(const std::vector<std::string>& list) {
  std::string out = R"({"ops":[)";
  for (size_t i = 0; i < list.size(); ++i) out += (i ? "," : "") + list[i];
  return out + "]}";
}

std::string notifyStep(const std::string& snapshot_json = "", const std::string& to = "e_thanks") {
  return R"({"kind":"notify","purpose":"p_delivery","message":)" + std::string(kMessage) +
         (snapshot_json.empty() ? "" : R"(,"snapshot":)" + snapshot_json) + R"(,"to":")" + to +
         R"("})";
}

// A start page whose options reach a call and four notify steps: text only, external camera,
// the door station's own camera, and a second text-only step for the rate-limit cases.
std::vector<std::string> flowOps() {
  auto option = [](const std::string& id, const std::string& label, const std::string& to,
                   bool primary = false) {
    return R"({"id":")" + id + R"(","label":{"ja":")" + label + R"("},"to":")" + to + "\"" +
           (primary ? R"(,"style":"primary")" : "") + "}";
  };
  return {
      setOp("media_sources.porch_camera",
            R"({"schema_version":1,"kind":"ip_camera","streams":{"snapshot":{"url":")" + kCameraUrl +
                R"("}},"secret_ref":"secret:media.porch_camera"})"),
      setOp("visitor_flow.enabled", "true"),
      setOp("visitor_flow.start", "\"s_home\""),
      setOp("visitor_flow.steps.s_home",
            R"({"kind":"page","title":{"ja":"home"},"options":[)" +
                option("o_call", "call", "c_any", true) + "," + option("o_text", "text", "n_text") +
                "," + option("o_text2", "text2", "n_text2") + "," +
                option("o_photo", "photo", "n_photo") + "," + option("o_door", "door", "n_door") +
                "]}"),
      setOp("visitor_flow.steps.c_any", R"({"kind":"call"})"),
      setOp("visitor_flow.steps.n_text", notifyStep()),
      setOp("visitor_flow.steps.n_text2", notifyStep()),
      setOp("visitor_flow.steps.n_photo",
            notifyStep(R"({"source":"media_source","id":"porch_camera"})")),
      setOp("visitor_flow.steps.n_door", notifyStep(R"({"source":"door_station"})")),
      setOp("visitor_flow.steps.e_thanks", R"({"kind":"end","title":{"ja":"thanks"}})"),
  };
}

json::Doc parsed(const std::string& text) {
  auto doc = json::parse(text);
  REQUIRE(doc);
  return doc;
}

bool batchOk(Node& node, const std::string& batch) {
  const std::string answer = node.configBatchJson(batch);
  const bool ok = json::getBool(parsed(answer).get(), "ok");
  if (!ok) MESSAGE("batch refused: " << answer);
  return ok;
}

json::Doc notify(Node& node, const std::string& step, const std::string& door = "") {
  return parsed(node.visitorNotifyJson(door, step));
}

void pushFrame(Node& n) {
  const int w = 32, h = 24;
  std::vector<uint8_t> px(static_cast<size_t>(w) * h * 4, 0x7f);
  n.pushCameraFrame(px.data(), 3, w, h, w * 4, 1000);
}

// A door station that serves the explicit flow, and an indoor panel that shows messages.
struct Home {
  Rig rig;
  Rig::N* door = nullptr;
  Rig::N* indoor = nullptr;

  Home() {
    door = &rig.add("A:1", "front", "door_station", "d_front", true);
    indoor = &rig.add("B:1", "hall", "indoor_panel", "", false);
    REQUIRE(door->node->start());
    REQUIRE(indoor->node->start());
    advertiseFlowShell(*door->node);
    indoor->node->setRuntimeCapabilities(std::string("{") + kPlatform +
                                         R"(,"cpu_score":10,"features":{"device_alert_v1":true}})");
    rig.run(1500);
    door->node->setConfigKey("doors.d_front", R"({"label":{"ja":"front-door"}})");
    REQUIRE(batchOk(*door->node, ops(flowOps())));
    rig.run(500);
  }
  ~Home() {
    door->node->stop();
    indoor->node->stop();
  }
  Node& a() { return *door->node; }
  Node& b() { return *indoor->node; }
};

size_t activeCalls(Node& node) {
  return static_cast<size_t>(
      cJSON_GetArraySize(json::get(parsed(node.statusJson()).get(), "active_calls")));
}

}  // namespace

TEST_CASE("visitor flow node: notify publishes one visitor_message without ringing") {
  Home h;
  auto result = notify(h.a(), "n_text");
  CHECK(json::getBool(result.get(), "ok"));
  CHECK_FALSE(json::getBool(result.get(), "throttled", true));
  const std::string id = json::getString(result.get(), "message_id");
  CHECK(id.size() == 32);
  CHECK(id.find_first_not_of("0123456789abcdef") == std::string::npos);
  h.rig.run(500);

  // Event feed on both nodes; the text comes from the step, never from the caller.
  for (auto* node : {h.door, h.indoor}) {
    auto messages = node->messages();
    REQUIRE(messages.size() == 1);
    const cJSON* m = messages[0].get();
    CHECK(json::getString(m, "message_id") == id);
    CHECK(json::getString(m, "step") == "n_text");
    CHECK(json::getString(m, "purpose") == "p_delivery");
    CHECK(json::getString(m, "visitor_lang") == "ja");
    CHECK(json::getString(json::get(m, "text"), "ja") == "ja-parcel");
    CHECK(json::getString(json::get(m, "text"), "en") == "A parcel was left at the door");
    CHECK(json::get(m, "snapshot") == nullptr);
  }
  // Indoor alert from the seeded rule.
  auto alerts = h.indoor->alerts();
  REQUIRE(alerts.size() == 1);
  const cJSON* alert = alerts[0].get();
  CHECK(json::getString(alert, "message_id") == id);
  CHECK(json::getString(alert, "door") == "d_front");
  CHECK(json::getBool(alert, "visual"));
  CHECK_FALSE(json::getBool(alert, "sticky", true));
  CHECK(json::getInt(alert, "ttl_s") == 60);
  CHECK(json::get(alert, "snapshot") == nullptr);
  CHECK(h.door->alerts().empty());  // the rule targets indoor panels

  // It is not a call: no press, no active call, nothing in the call log.
  CHECK(h.indoor->uiWhere("event", "type", "press").empty());
  CHECK(h.door->uiWhere("event", "type", "press").empty());
  CHECK(activeCalls(h.a()) == 0);
  CHECK(activeCalls(h.b()) == 0);
  auto log = parsed(h.a().callLogJson(0, 50));
  CHECK(cJSON_GetArraySize(json::get(log.get(), "calls")) == 0);
}

TEST_CASE("visitor flow node: notify refuses unknown doors, steps and a disabled flow") {
  Home h;
  CHECK(json::getString(notify(h.a(), "n_text", "d_nowhere").get(), "err") == "unknown_door");
  for (const char* step : {"", "nope", "c_any", "s_home", "e_thanks", "__call"}) {
    CAPTURE(step);
    auto result = notify(h.a(), step);
    CHECK_FALSE(json::getBool(result.get(), "ok"));
    CHECK(json::getString(result.get(), "err") == "unknown_step");
  }
  REQUIRE(batchOk(h.a(), ops({setOp("visitor_flow.enabled", "false")})));
  auto off = notify(h.a(), "n_text");
  CHECK_FALSE(json::getBool(off.get(), "ok"));
  CHECK(json::getString(off.get(), "err") == "flow_disabled");
  h.rig.run(300);
  CHECK(h.indoor->messages().empty());
}

TEST_CASE("visitor flow node: idempotency window, spacing and per-door rate limit") {
  Home h;
  h.a().setConfigKey("doors.d_back", R"({"label":{"ja":"back-door"}})");
  h.rig.run(100);

  auto first = notify(h.a(), "n_text");
  const std::string id = json::getString(first.get(), "message_id");
  REQUIRE_FALSE(id.empty());
  // The same step again within 60 s returns the first message and sends nothing.
  h.rig.run(5000);
  auto again = notify(h.a(), "n_text");
  CHECK(json::getBool(again.get(), "ok"));
  CHECK(json::getBool(again.get(), "duplicate"));
  CHECK_FALSE(json::getBool(again.get(), "throttled", true));
  CHECK(json::getString(again.get(), "message_id") == id);

  // Another step within 30 s of the last message is throttled and reported as success.
  auto spaced = notify(h.a(), "n_text2");
  CHECK(json::getBool(spaced.get(), "ok"));
  CHECK(json::getBool(spaced.get(), "throttled"));
  CHECK(json::get(spaced.get(), "message_id") == nullptr);

  // Another door has its own counters.
  auto other_door = notify(h.a(), "n_text", "d_back");
  CHECK(json::getBool(other_door.get(), "ok"));
  CHECK_FALSE(json::getBool(other_door.get(), "throttled", true));
  CHECK(json::getString(other_door.get(), "message_id") != id);

  // Past the spacing the other step goes through. Six messages fit in ten minutes.
  h.rig.run(26'000);
  CHECK(json::getString(notify(h.a(), "n_text2").get(), "message_id").size() == 32);
  const char* alternate[] = {"n_text", "n_text2", "n_text", "n_text2"};
  for (const char* step : alternate) {
    h.rig.run(31'000);
    auto result = notify(h.a(), step);
    CHECK_FALSE(json::getBool(result.get(), "throttled", true));
    CHECK(json::getString(result.get(), "message_id").size() == 32);
  }
  h.rig.run(31'000);
  auto over = notify(h.a(), "n_text");
  CHECK(json::getBool(over.get(), "ok"));
  CHECK(json::getBool(over.get(), "throttled"));
  h.rig.run(1000);
  size_t front = 0;
  for (const auto& m : h.indoor->messages()) front += json::getString(m.get(), "door") == "d_front";
  CHECK(front == 6);  // the repeat and the throttled attempts sent nothing

  // The window slides: ten minutes after the first message there is room again.
  h.rig.run(600'000);
  auto later = notify(h.a(), "n_text2");
  CHECK_FALSE(json::getBool(later.get(), "throttled", true));
  CHECK(json::getString(later.get(), "message_id").size() == 32);
}

TEST_CASE("visitor flow node: a shell that does not advertise visitor_flow_v1 gets no flow") {
  Rig rig;
  auto& door = rig.add("A:1", "front", "door_station", "d_front", true);
  REQUIRE(door.node->start());
  rig.run(1500);
  auto state = [&] { return parsed(door.node->visitorFlowJson("")); };

  CHECK_FALSE(json::getBool(state().get(), "enabled", true));
  CHECK(json::getString(state().get(), "reason") == "unsupported_shell");
  // The feature alone is not enough: the manifest must carry the elements the pages are built from.
  door.node->setRuntimeCapabilities(R"({"features":{"visitor_flow_v1":true,"ui_manifest_v1":true}})");
  rig.run(50);
  CHECK(json::getString(state().get(), "reason") == "unsupported_shell");
  // A manifest without the feature does not help either.
  door.node->setRuntimeCapabilities(R"({"features":{"ui_manifest_v1":true}})");
  door.node->setUiManifest(kManifest);
  rig.run(50);
  CHECK(json::getString(state().get(), "reason") == "unsupported_shell");

  const size_t before = door.uiWhere("visitor_flow_changed").size();
  advertiseFlowShell(*door.node);
  rig.run(100);
  auto on = state();
  CHECK(json::getBool(on.get(), "enabled"));
  CHECK(json::getString(on.get(), "source") == "default");
  CHECK(json::getString(on.get(), "door") == "d_front");
  CHECK(door.uiWhere("visitor_flow_changed").size() == before + 1);

  // A manifest that lacks one required element withdraws the flow again.
  door.node->setUiManifest(
      R"({"schema_version":1,"units":"logical","viewport":{"minimum_touch":44,"scale_min":0.75,"scale_max":2.0},"elements":{"purpose.button":{"properties":["scale"],"defaults":{"scale":1.0},"safety_critical":false},"cancel.call":{"properties":["scale"],"defaults":{"scale":1.0},"safety_critical":true}}})");
  rig.run(100);
  CHECK(json::getString(state().get(), "reason") == "unsupported_shell");
  door.node->stop();
}

TEST_CASE("visitor flow node: external camera snapshot selection with a fake fetcher") {
  Home h;
  h.door->camera_answer = [](Bytes* body) {
    *body = cameraJpeg("porch");
    return true;
  };
  auto result = notify(h.a(), "n_photo");
  CHECK(json::getBool(result.get(), "ok"));
  const std::string id = json::getString(result.get(), "message_id");
  REQUIRE(h.rig.runUntil([&] { return !h.indoor->alerts().empty(); }, 6000));

  // One request, to the configured address, with the credential only as a header.
  REQUIRE(h.door->camera_requests.size() == 1);
  CHECK(h.door->camera_requests[0].url == kCameraUrl);
  auto headers = parsed(h.door->camera_requests[0].headers);
  CHECK(json::getString(headers.get(), "Authorization") ==
        "Basic " + base64Encode(toBytes("cam-user:cam-pass-77")));
  CHECK(json::getString(headers.get(), "Accept") == "image/jpeg");

  const std::string hash = sha256Hex(cameraJpeg("porch"));
  auto messages = h.door->messages();
  REQUIRE(messages.size() == 1);
  const cJSON* snapshot = json::get(messages[0].get(), "snapshot");
  REQUIRE(snapshot);
  CHECK(json::getString(messages[0].get(), "message_id") == id);
  CHECK(json::getString(snapshot, "sha256") == hash);
  CHECK(json::getString(snapshot, "url") == "/asset/" + hash);
  CHECK(h.a().assetPath(hash) != "");

  // The indoor panel fetched the picture by hash from the node that took it.
  auto alerts = h.indoor->alerts();
  const cJSON* alert_snapshot = json::get(alerts[0].get(), "snapshot");
  REQUIRE(alert_snapshot);
  CHECK(json::getString(alert_snapshot, "sha256") == hash);
  CHECK(cJSON_IsString(json::get(alert_snapshot, "path")));
  CHECK(h.b().assetPath(hash) != "");

  // Neither the address, the credential nor the reference name leaves in an event.
  std::string everything;
  for (const auto* node : {h.door, h.indoor})
    for (const auto& line : node->ui) everything += line;
  CHECK(everything.find("192.0.2.20") == std::string::npos);
  CHECK(everything.find("cam-pass-77") == std::string::npos);
  CHECK(everything.find("secret:media") == std::string::npos);
  // The shell's document never names a camera either.
  CHECK(h.a().visitorFlowJson("").find("porch_camera") == std::string::npos);
}

TEST_CASE("visitor flow node: a camera that fails, hangs or sends junk leaves a text message") {
  Home h;
  struct Case {
    const char* name;
    std::function<bool(Bytes*)> answer;
    int64_t wait_ms;
  };
  const std::vector<Case> cases = {
      {"status error", [](Bytes*) { return true; }, 500},
      {"not a jpeg", [](Bytes* body) { *body = toBytes("<html>login</html>"); return true; }, 500},
      {"truncated jpeg",
       [](Bytes* body) { *body = {0xFF, 0xD8, 0xFF, 0xE0, 'x', 'y'}; return true; }, 500},
      {"never answers", [](Bytes*) { return false; }, 5000},
  };
  size_t expected = 0;
  for (const auto& c : cases) {
    CAPTURE(c.name);
    h.rig.run(31'000);
    h.rig.run(61'000);  // clear the repeat window and the spacing between cases
    h.door->camera_answer = c.answer;
    auto result = notify(h.a(), "n_photo");
    CHECK(json::getBool(result.get(), "ok"));
    CHECK(h.rig.runUntil([&] { return h.door->messages().size() == expected + 1; }, 6000));
    ++expected;
    auto messages = h.door->messages();
    CHECK(json::get(messages.back().get(), "snapshot") == nullptr);
    CHECK(json::getString(json::get(messages.back().get(), "text"), "ja") == "ja-parcel");
  }
  // An unreachable external camera must not fall back to the door station's own camera.
  pushFrame(h.a());
  h.rig.run(61'000);
  h.door->camera_answer = [](Bytes*) { return true; };
  notify(h.a(), "n_photo");
  CHECK(h.rig.runUntil([&] { return h.door->messages().size() == expected + 1; }, 6000));
  CHECK(json::get(h.door->messages().back().get(), "snapshot") == nullptr);
}

TEST_CASE("visitor flow node: the door station camera is used only when the step names it") {
  Home h;
  h.door->camera_answer = [](Bytes* body) {
    *body = cameraJpeg("external");
    return true;
  };
  // No frame yet: text only, and the external camera is not asked.
  notify(h.a(), "n_door");
  REQUIRE(h.rig.runUntil([&] { return h.door->messages().size() == 1; }, 6000));
  CHECK(json::get(h.door->messages()[0].get(), "snapshot") == nullptr);
  CHECK(h.door->camera_requests.empty());

  pushFrame(h.a());
  h.rig.run(61'000);
  notify(h.a(), "n_door");
  REQUIRE(h.rig.runUntil([&] { return h.door->messages().size() == 2; }, 6000));
  auto messages = h.door->messages();
  const cJSON* snapshot = json::get(messages[1].get(), "snapshot");
  REQUIRE(snapshot);
  const std::string hash = json::getString(snapshot, "sha256");
  CHECK(hash.size() == 64);
  CHECK(hash != sha256Hex(cameraJpeg("external")));
  CHECK(h.door->camera_requests.empty());
  CHECK(h.a().assetPath(hash) != "");
}

TEST_CASE("visitor flow node: configuration batches validate the whole graph") {
  Home h;
  const std::string before = h.a().configJson();
  auto rejected = [&](const std::string& batch, const std::string& code) {
    CAPTURE(code);
    auto result = parsed(h.a().configBatchJson(batch));
    CHECK_FALSE(json::getBool(result.get(), "ok"));
    CHECK(json::getString(result.get(), "err").rfind(code, 0) == 0);
    CHECK(h.a().configJson() == before);
  };
  // An option that points at a step that does not exist.
  rejected(ops({setOp("visitor_flow.steps.s_x",
                      R"({"kind":"page","title":{"ja":"x"},"options":[{"id":"o","label":{"ja":"x"},"to":"c_missing"}]})")}),
           "visitor_flow.unknown_target");
  // A notify that does not lead to an end page.
  rejected(ops({setOp("visitor_flow.steps.n_text", notifyStep("", "c_any"))}),
           "visitor_flow.bad_target_kind");
  // A key below a step and a container write.
  rejected(ops({setOp("visitor_flow.steps.n_text.to", "\"e_thanks\"")}), "visitor_flow.step_leaf_write");
  rejected(ops({setOp("visitor_flow.steps", "{}")}), "visitor_flow.container_write");
  // An unknown step kind and a camera that does not exist.
  rejected(ops({setOp("visitor_flow.steps.q", R"({"kind":"survey"})")}), "visitor_flow.unknown_kind");
  rejected(ops({setOp("visitor_flow.steps.n_text",
                      notifyStep(R"({"source":"media_source","id":"ghost"})"))}),
           "visitor_flow.unknown_camera");
  // Deleting the end page everything points at.
  rejected(R"({"ops":[{"op":"delete","key":"visitor_flow.steps.e_thanks"}]})",
           "visitor_flow.unknown_target");
  // The same refusal through the single-key setter, which leaves the document alone.
  h.a().setConfigKey("visitor_flow.steps.n_text", notifyStep("", "c_missing"));
  CHECK(h.a().configJson() == before);

  // A step and the step it points to arrive together: accepted.
  CHECK(batchOk(h.a(), ops({setOp("visitor_flow.steps.n_new", notifyStep("", "e_new")),
                            setOp("visitor_flow.steps.e_new", R"({"kind":"end","title":{"ja":"bye"}})")})));
  CHECK(json::get(json::get(parsed(h.a().visitorFlowJson("")).get(), "steps"), "n_new") != nullptr);
}

TEST_CASE("visitor flow node: visitor_flow.require_call works both ways") {
  Home h;
  // A flow whose only way out is a message.
  const auto notify_only = [](bool with_switch, bool value) {
    std::vector<std::string> list = {
        setOp("visitor_flow.start", "\"s_only\""),
        setOp("visitor_flow.steps.s_only",
              R"({"kind":"page","title":{"ja":"only"},"options":[{"id":"o","label":{"ja":"leave"},"to":"n_text"}]})"),
    };
    if (with_switch) list.push_back(setOp("visitor_flow.require_call", value ? "true" : "false"));
    return ops(list);
  };
  const std::string before = h.a().configJson();
  auto strict = parsed(h.a().configBatchJson(notify_only(false, false)));
  CHECK_FALSE(json::getBool(strict.get(), "ok"));
  CHECK(json::getString(strict.get(), "err") == "visitor_flow.no_reachable_call: start");
  CHECK(h.a().configJson() == before);
  auto explicit_true = parsed(h.a().configBatchJson(notify_only(true, true)));
  CHECK_FALSE(json::getBool(explicit_true.get(), "ok"));

  auto relaxed = parsed(h.a().configBatchJson(notify_only(true, false)));
  CHECK(json::getBool(relaxed.get(), "ok"));
  bool warned = false;
  const cJSON* warning = nullptr;
  cJSON_ArrayForEach(warning, json::get(relaxed.get(), "warnings"))
      warned = warned || json::getString(warning, "message_key") == "visitor_flow.no_call";
  CHECK(warned);
  auto doc = parsed(h.a().visitorFlowJson(""));
  CHECK(json::getString(doc.get(), "source") == "config");
  CHECK(json::getString(doc.get(), "start") == "s_only");
  CHECK_FALSE(json::getBool(doc.get(), "require_call", true));
  CHECK(json::get(json::get(doc.get(), "steps"), "__call") == nullptr);

  // Switching it back on while the flow cannot reach a call is refused as a single leaf write.
  const std::string relaxed_config = h.a().configJson();
  h.a().setConfigKey("visitor_flow.require_call", "true");
  CHECK(h.a().configJson() == relaxed_config);
  // Adding a way to a call makes the strict setting acceptable again.
  CHECK(batchOk(h.a(), ops({setOp("visitor_flow.steps.s_only",
                                  R"({"kind":"page","title":{"ja":"only"},"options":[{"id":"o","label":{"ja":"leave"},"to":"n_text"},{"id":"c","label":{"ja":"ring"},"to":"c_any","style":"primary"}]})"),
                            setOp("visitor_flow.require_call", "true")})));
}

TEST_CASE("visitor flow node: the default wizard follows the delivery purpose") {
  Rig rig;
  auto& door = rig.add("A:1", "front", "door_station", "d_front", true);
  REQUIRE(door.node->start());
  advertiseFlowShell(*door.node);
  rig.run(1500);
  door.node->setConfigKey("doors.d_front", R"({"label":{"ja":"front-door"}})");
  auto kinds = [&](const json::Doc& doc) {
    std::map<std::string, int> count;
    const cJSON* step = nullptr;
    cJSON_ArrayForEach(step, json::get(doc.get(), "steps")) ++count[json::getString(step, "kind")];
    return count;
  };

  auto with = parsed(door.node->visitorFlowJson(""));
  CHECK(json::getBool(with.get(), "enabled"));
  CHECK(json::getString(with.get(), "source") == "default");
  auto with_kinds = kinds(with);
  CHECK(with_kinds["notify"] == 1);
  CHECK(with_kinds["end"] >= 1);
  CHECK(with_kinds["call"] >= 1);
  CHECK(with_kinds["page"] >= 3);  // start, the leave-at-door question, the instructions
  // The notify step of the built-in wizard works with generic text and no photo.
  std::string notify_step;
  const cJSON* step = nullptr;
  cJSON_ArrayForEach(step, json::get(with.get(), "steps"))
      if (json::getString(step, "kind") == "notify") notify_step = step->string;
  auto sent = notify(*door.node, notify_step);
  CHECK(json::getBool(sent.get(), "ok"));
  CHECK(rig.runUntil([&] { return door.messages().size() == 1; }, 200));
  auto messages = door.messages();
  CHECK(json::get(messages[0].get(), "snapshot") == nullptr);
  CHECK(json::getString(json::get(messages[0].get(), "text"), "en").size() > 5);

  // The wizard has no delivery question when no delivery-like purpose is enabled.
  for (const char* purpose : {"p_delivery"})
    door.node->setConfigKey(std::string("visit_purposes.") + purpose + ".enabled", "false");
  rig.run(100);
  auto without = parsed(door.node->visitorFlowJson(""));
  CHECK(json::getBool(without.get(), "enabled"));
  CHECK(json::getString(without.get(), "source") == "default");
  CHECK(kinds(without)["notify"] == 0);
  CHECK(kinds(without)["page"] == 1);
  CHECK(json::get(json::get(without.get(), "steps"), notify_step.c_str()) == nullptr);
  CHECK(json::getString(notify(*door.node, notify_step).get(), "err") == "unknown_step");

  // The legacy mode wins while nothing was written: the classic screen is kept.
  door.node->setConfigKey("visit_purposes.p_delivery.enabled", "true");
  door.node->setConfigKey("ui.call_flow", "\"ring_then_purpose\"");
  rig.run(100);
  auto legacy = parsed(door.node->visitorFlowJson(""));
  CHECK_FALSE(json::getBool(legacy.get(), "enabled", true));
  CHECK(json::getString(legacy.get(), "reason") == "legacy_call_flow");
  door.node->stop();
}

namespace {

struct Pair {
  Rig rig;
  Rig::N* a = nullptr;
  Rig::N* b = nullptr;
  Pair() {
    a = &rig.add("A:1", "front", "door_station", "d_front", true);
    b = &rig.add("B:1", "hall", "indoor_panel", "", false);
    REQUIRE(a->node->start());
    REQUIRE(b->node->start());
    advertiseFlowShell(*a->node);
    rig.run(1500);
    a->node->setConfigKey("doors.d_front", R"({"label":{"ja":"front-door"}})");
    REQUIRE(batchOk(*a->node, ops(flowOps())));
    rig.run(1000);
  }
  ~Pair() {
    a->node->stop();
    b->node->stop();
  }
  static std::string stored(Node& node, const std::string& id) {
    auto config = parsed(node.configJson());
    const cJSON* step =
        json::get(json::get(json::get(config.get(), "visitor_flow"), "steps"), id.c_str());
    return step ? json::dump(step) : std::string();
  }
  static size_t conflicts(Node& node) {
    return static_cast<size_t>(
        cJSON_GetArraySize(json::get(parsed(node.configSnapshotJson()).get(), "edit_conflicts")));
  }
};

}  // namespace

TEST_CASE("visitor flow node: edits to different steps on two nodes both survive the merge") {
  Pair p;
  REQUIRE(Pair::stored(*p.b->node, "n_text") == Pair::stored(*p.a->node, "n_text"));
  REQUIRE_FALSE(Pair::stored(*p.b->node, "n_text").empty());

  // Both write before they hear from each other.
  REQUIRE(batchOk(*p.a->node, ops({setOp("visitor_flow.steps.e_thanks",
                                         R"({"kind":"end","title":{"ja":"from-a"}})")})));
  p.rig.clock.advance(5);
  std::string edited = notifyStep();
  edited.replace(edited.find("ja-parcel"), 9, "from-b");
  REQUIRE(batchOk(*p.b->node, ops({setOp("visitor_flow.steps.n_text", edited)})));
  p.rig.run(1000);
  for (auto* node : {p.a, p.b}) {
    CHECK(Pair::stored(*node->node, "e_thanks").find("from-a") != std::string::npos);
    CHECK(Pair::stored(*node->node, "n_text").find("from-b") != std::string::npos);
  }
  // The retained-conflict journal treats a whole configuration section as one entity, so the
  // two partitions are reported for the administrator even though the values merged; ordinary
  // edits of the section wait for that resolution. Editors must surface unresolved_config_conflict.
  CHECK(Pair::conflicts(*p.a->node) == 1);
  CHECK(Pair::conflicts(*p.b->node) == 1);
  auto refused = parsed(p.a->node->configBatchJson(
      ops({setOp("visitor_flow.steps.e_thanks", R"({"kind":"end","title":{"ja":"later"}})")})));
  CHECK_FALSE(json::getBool(refused.get(), "ok"));
  CHECK(json::getString(refused.get(), "err") == "unresolved_config_conflict");
  // Messages keep flowing from the merged document.
  CHECK(json::getBool(notify(*p.a->node, "n_text").get(), "ok"));
}

TEST_CASE("visitor flow node: the same step edited on two nodes is replaced whole by the later write") {
  Pair p;
  REQUIRE(batchOk(*p.a->node, ops({setOp("visitor_flow.steps.e_thanks",
                                         R"({"kind":"end","title":{"ja":"a-wins"},"return_s":30})")})));
  p.rig.clock.advance(5);
  REQUIRE(batchOk(*p.b->node, ops({setOp("visitor_flow.steps.e_thanks",
                                         R"({"kind":"end","title":{"ja":"b-wins"}})")})));
  p.rig.run(1000);
  for (auto* node : {p.a, p.b}) {
    const std::string step = Pair::stored(*node->node, "e_thanks");
    CHECK(step.find("b-wins") != std::string::npos);
    CHECK(step.find("a-wins") == std::string::npos);
    CHECK(step.find("return_s") == std::string::npos);  // no member of the losing write remains
  }
}

TEST_CASE("visitor flow node: deleting a step or the whole flow replicates") {
  Pair p;
  // Deleting a step that nothing refers to replicates as a tombstone.
  REQUIRE(batchOk(*p.a->node, ops({setOp("visitor_flow.steps.c_spare", R"({"kind":"call"})")})));
  p.rig.run(500);
  CHECK_FALSE(Pair::stored(*p.b->node, "c_spare").empty());
  CHECK(json::getBool(parsed(p.a->node->deleteConfigKeyJson("visitor_flow.steps.c_spare")).get(), "ok"));
  p.rig.run(500);
  CHECK(Pair::stored(*p.b->node, "c_spare").empty());
  CHECK(Pair::stored(*p.a->node, "c_spare").empty());
  // A step that is still referenced cannot be deleted.
  CHECK_FALSE(json::getBool(parsed(p.a->node->deleteConfigKeyJson("visitor_flow.steps.e_thanks")).get(), "ok"));
  CHECK_FALSE(Pair::stored(*p.a->node, "e_thanks").empty());

  // "Reset to the built-in wizard" is one delete of visitor_flow; every node follows.
  CHECK(json::getBool(parsed(p.a->node->deleteConfigKeyJson("visitor_flow")).get(), "ok"));
  p.rig.run(1000);
  CHECK(json::getString(parsed(p.a->node->visitorFlowJson("")).get(), "source") == "default");
  CHECK(json::get(parsed(p.b->node->configJson()).get(), "visitor_flow") == nullptr);
  // The next flow is written from scratch with no leftover steps.
  CHECK(Pair::stored(*p.b->node, "n_text").empty());
}

TEST_CASE("visitor flow node: an older core accepts and merges the unknown visitor_flow key") {
  // An older core has no visitor_flow validation: configWriteValid has no list of known top-level
  // keys and the merge is key-path generic. Today's behaviour is pinned with a key such a core
  // does not know about, written whole or per path, and a nested value of any shape.
  Rig rig;
  auto& a = rig.add("A:1", "front", "door_station", "d_front", true);
  auto& b = rig.add("B:1", "hall", "indoor_panel", "", false);
  REQUIRE(a.node->start());
  REQUIRE(b.node->start());
  rig.run(1500);
  auto at = [](Node& node, const char* path) {
    auto config = parsed(node.configJson());
    const cJSON* item = config.get();
    std::string rest = path;
    while (item && !rest.empty()) {
      const size_t dot = rest.find('.');
      item = json::get(item, rest.substr(0, dot).c_str());
      rest = dot == std::string::npos ? "" : rest.substr(dot + 1);
    }
    return item ? json::dump(item) : std::string();
  };
  CHECK(batchOk(*a.node, ops({setOp("future_flow.enabled", "true"),
                              setOp("future_flow.steps.s_one", R"({"kind":"page","options":[]})"),
                              setOp("future_flow.steps.s_two", R"({"kind":"survey","x":[1,2]})")})));
  rig.run(1000);
  CHECK(batchOk(*b.node, ops({setOp("future_flow.steps.s_three", R"({"kind":"call"})"),
                              setOp("future_flow.idle_s", "999")})));
  rig.run(1000);
  for (auto* node : {&a, &b}) {
    CHECK(at(*node->node, "future_flow.enabled") == "true");
    CHECK(at(*node->node, "future_flow.idle_s") == "999");
    CHECK(at(*node->node, "future_flow.steps.s_one") == R"({"kind":"page","options":[]})");
    CHECK(at(*node->node, "future_flow.steps.s_two") == R"({"kind":"survey","x":[1,2]})");
    CHECK(at(*node->node, "future_flow.steps.s_three") == R"({"kind":"call"})");
  }
  // Deleting and overwriting behave like any other key.
  CHECK(json::getBool(parsed(a.node->deleteConfigKeyJson("future_flow.steps.s_one")).get(), "ok"));
  a.node->setConfigKey("future_flow.steps.s_two", R"({"kind":"call"})");
  rig.run(1000);
  CHECK(at(*b.node, "future_flow.steps.s_one").empty());
  CHECK(at(*b.node, "future_flow.steps.s_two") == R"({"kind":"call"})");

  // This core, which does know the key, still refuses the same shapes on a local write, and a
  // replicated copy of the flow key never breaks the commits that follow it.
  CHECK(json::getString(parsed(a.node->configBatchJson(ops({setOp(
                            "visitor_flow.steps.s_two", R"({"kind":"survey"})")}))).get(), "err") ==
        "visitor_flow.unknown_kind: s_two");
  a.node->setConfigKey("ui.visitor_lang_revert_s", "30");
  rig.run(500);
  CHECK(at(*b.node, "ui.visitor_lang_revert_s") == "30");
  a.node->stop();
  b.node->stop();
}

TEST_CASE("visitor flow node: Telegram sends the message as plain text or with the snapshot") {
  Home h;
  h.a().setConfigKey("households.h_ox", R"({"telegram_chat_ids":[111]})");
  h.a().setConfigKey("integrations.telegram.bot_token_ref", "\"secret:telegram.test\"");
  h.rig.run(1500);

  auto result = notify(h.a(), "n_text");
  REQUIRE(h.rig.runUntil([&] { return h.door->https.count("sendMessage") == 1; }, 5000));
  {
    const std::string body = *h.door->https.lastBody("sendMessage");
    auto request = parsed(body);
    const std::string text = json::getString(request.get(), "text");
    CHECK(text.find("ja-parcel") != std::string::npos);
    CHECK(text.find("front-door") != std::string::npos);
    CHECK(json::get(request.get(), "reply_markup") == nullptr);  // no call to answer
    CHECK(text.find("p_delivery") == std::string::npos);
  }
  CHECK(h.door->https.count("sendPhoto") == 0);

  h.door->camera_answer = [](Bytes* body) {
    *body = cameraJpeg("telegram");
    return true;
  };
  h.rig.run(61'000);
  notify(h.a(), "n_photo");
  REQUIRE(h.rig.runUntil([&] { return h.door->https.count("sendPhoto") == 1; }, 8000));
  const std::string photo = *h.door->https.lastBody("sendPhoto");
  CHECK(photo.find("still:telegram") != std::string::npos);
  CHECK(photo.find("ja-parcel") != std::string::npos);
  CHECK(photo.find("filename=") != std::string::npos);
  CHECK(h.door->https.count("sendMessage") == 1);

  // A rule that asks for no snapshot sends text only even when the step took one.
  h.a().setConfigKey("trigger_rules.r_visitor_message_default",
                     R"({"enabled":true,"when":{"type":"visitor_message"},"actions":[{"type":"telegram","households":"all","with_snapshot":false}]})");
  h.rig.run(61'000);
  notify(h.a(), "n_photo");
  REQUIRE(h.rig.runUntil([&] { return h.door->https.count("sendMessage") == 2; }, 8000));
  CHECK(h.door->https.count("sendPhoto") == 1);
  // The bot token never appears in anything delivered to the shell.
  for (const auto& line : h.door->ui) CHECK(line.find("TESTTOKEN") == std::string::npos);
}

TEST_CASE("visitor flow node: HTTP routes and snapshot access") {
  NodeOptions o;
  o.data_dir = ":memory:";
  o.name = "front";
  o.role = "door_station";
  o.door = "d_front";
  o.listen_addr = "127.0.0.1:" + std::to_string(db::testing::freeListenPort());
  o.enable_beacon = false;
  o.psk.fill(0x5a);
  o.http_port = db::testing::freeListenPort();
  Node node(o);
  std::mutex mu;
  std::vector<std::string> ui;
  const Bytes jpeg = cameraJpeg("live");
  node.setUiEventCb([&](const std::string& e) {
    std::lock_guard<std::mutex> lock(mu);
    ui.push_back(e);
  });
  node.setSecureStore(
      [](const std::string& key) {
        return key == "media.porch_camera" ? kCameraSecret : std::string();
      },
      [](const std::string&, const std::string&) { return true; });
  node.setCameraFetchFn([&](const std::string&, const std::string&,
                            std::function<void(int, Bytes)> done) { done(200, jpeg); });
  REQUIRE(node.start());
  node.setConfigKey("doors.d_front", R"({"label":{"ja":"front-door"}})");
  REQUIRE(batchOk(node, ops(flowOps())));

  const auto login = operationHttp(o.http_port, "POST", "/api/login", R"({"password":"pw-12345"})");
  REQUIRE(login.status == 200);
  const std::string csrf = json::getString(parsed(login.body).get(), "csrf_token");
  const std::string cookie = login.cookie;
  auto get = [&](const std::string& path, bool signed_in) {
    return operationHttp(o.http_port, "GET", path, "", signed_in ? cookie : "");
  };
  auto post = [&](const std::string& path, const std::string& body, bool signed_in = true) {
    return operationHttp(o.http_port, "POST", path, body, signed_in ? cookie : "",
                         signed_in ? csrf : "");
  };

  // The resolved document is an administrator read and is not gated by the shell's capability,
  // while the native ABI withholds it from a shell that never advertised the feature.
  CHECK(get("/api/visitor-flow?door=d_front", false).status == 401);
  auto served = get("/api/visitor-flow?door=d_front", true);
  REQUIRE(served.status == 200);
  CHECK(json::getBool(parsed(served.body).get(), "enabled"));
  CHECK(json::getString(parsed(served.body).get(), "source") == "config");
  CHECK(json::getString(parsed(node.visitorFlowJson("")).get(), "reason") == "unsupported_shell");
  auto templ = get("/api/visitor-flow/template?name=delivery", true);
  CHECK(templ.status == 200);
  CHECK(json::getBool(parsed(templ.body).get(), "ok"));
  CHECK(json::get(parsed(templ.body).get(), "flow") != nullptr);
  CHECK(get("/api/visitor-flow/template?name=nope", true).status == 404);

  // Notify over HTTP: statuses and bodies.
  CHECK(post("/api/visitor-notify", R"({"door":"d_front","step":"n_photo"})", false).status == 401);
  auto first = post("/api/visitor-notify", R"({"door":"d_front","step":"n_photo"})");
  CHECK(first.status == 200);
  const std::string id = json::getString(parsed(first.body).get(), "message_id");
  CHECK(id.size() == 32);
  auto repeat = post("/api/visitor-notify", R"({"door":"d_front","step":"n_photo"})");
  CHECK(repeat.status == 200);
  CHECK(json::getBool(parsed(repeat.body).get(), "duplicate"));
  CHECK(json::getString(parsed(repeat.body).get(), "message_id") == id);
  auto throttled = post("/api/visitor-notify", R"({"door":"d_front","step":"n_text"})");
  CHECK(throttled.status == 200);
  CHECK(json::getBool(parsed(throttled.body).get(), "throttled"));
  CHECK(post("/api/visitor-notify", R"({"door":"d_front","step":"c_any"})").status == 400);
  CHECK(post("/api/visitor-notify", R"({"door":"d_gone","step":"n_text"})").status == 400);
  CHECK(post("/api/visitor-notify", R"({"door":"d_front","step":"n_text","text":"hello"})").status == 200);

  // The picture is in place once the message exists.
  const std::string hash = sha256Hex(jpeg);
  REQUIRE(operationWait([&] {
    std::lock_guard<std::mutex> lock(mu);
    for (const auto& line : ui)
      if (line.find("\"visitor_message\"") != std::string::npos &&
          line.find(hash) != std::string::npos)
        return true;
    return false;
  }));
  // A snapshot needs the authorisation live media needs; the public route is not enough.
  const auto anonymous = get("/asset/" + hash, false);
  CHECK(anonymous.status == 401);
  CHECK(anonymous.body.find("still:live") == std::string::npos);
  const auto allowed = get("/asset/" + hash, true);
  CHECK(allowed.status == 200);
  CHECK(allowed.body == std::string(jpeg.begin(), jpeg.end()));
  // A flow image is a ledger asset and stays readable by the visitor screen.
  const Bytes image = toBytes("\x89PNG-flow-image");
  const std::string image_hash = node.addAsset(image, "image/png", "spot.png");
  REQUIRE(image_hash.size() == 64);
  const auto flow_image = get("/asset/" + image_hash, false);
  CHECK(flow_image.status == 200);
  CHECK(flow_image.body == std::string(image.begin(), image.end()));
  // The same hash with the wrong credential kind is refused, never served.
  CHECK(operationHttp(o.http_port, "GET", "/asset/" + hash, "", "dbsess=not-a-session").status == 401);

  // A disabled flow answers 409 on the notify route.
  REQUIRE(batchOk(node, ops({setOp("visitor_flow.enabled", "false")})));
  CHECK(post("/api/visitor-notify", R"({"door":"d_front","step":"n_text2"})").status == 409);
  node.stop();
}
