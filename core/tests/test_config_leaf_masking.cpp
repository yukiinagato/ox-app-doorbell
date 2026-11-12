// How a leaf entry ("a.b.c") and a whole-object entry for its parent ("a.b") combine. The Admin
// page commits object patches through the revision-checked commit; native shells write leaves.
#include <string>

#include "crdt/lww_map.h"
#include "doctest.h"
#include "node/node.h"
#include "test_env.h"
#include "util/clock.h"
#include "util/json.h"

using namespace db;

namespace {
const std::string kAdminNode = "aaaa000000000000";
const std::string kShellNode = "bbbb000000000000";

struct MaskReplica {
  SimClock clock;
  HlcClock hlc;
  LwwMap map;
  MaskReplica(const std::string& id, int64_t wall_start)
      : clock(wall_start), hlc(clock, id), map(id, hlc) {}
};

int64_t cameraFps(const std::string& materialized) {
  auto document = json::parse(materialized);
  return json::getInt(json::get(json::get(document.get(), "cas"), "camera"), "fps");
}

std::string commitRequest(Node& node, const std::string& operations) {
  auto snapshot = json::parse(node.configSnapshotJson());
  auto request = json::obj();
  json::set(request.get(), "schema_version", int64_t{2});
  json::set(request.get(), "expected_revision", json::getString(snapshot.get(), "revision"));
  json::setItem(request.get(), "ops", json::parse(operations));
  return json::dump(request.get());
}

NodeOptions maskOptions() {
  NodeOptions options;
  options.data_dir = ":memory:";
  options.listen_addr = "127.0.0.1:" + std::to_string(db::testing::freeListenPort());
  options.http_port = db::testing::freeListenPort();
  options.enable_beacon = false;
  return options;
}
}  // namespace

TEST_CASE("leaf masking: a scalar leaf entry replaces the parent object's member whatever their order") {
  MaskReplica replica(kAdminNode, 1000);
  const LwwEntry leaf = replica.map.set("cas.camera.fps", "8");
  replica.clock.advance(60'000);
  // A later whole-object write does not win over the older leaf: materialization applies the
  // parent first and then every live scalar leaf, without comparing timestamps.
  const LwwEntry object = replica.map.set("cas.camera", R"({"fps":15,"quality":60})");
  REQUIRE(object.hlc > leaf.hlc);
  CHECK(cameraFps(replica.map.materializeJson()) == 8);
  // Only removing the leaf entry, or rewriting it, lets the object's value show.
  replica.clock.advance(1);
  replica.map.set("cas.camera.fps", "15");
  CHECK(cameraFps(replica.map.materializeJson()) == 15);
}

TEST_CASE("leaf masking: a revision-checked object commit rewrites the leaf entries it can see") {
  Node node(maskOptions());
  REQUIRE(node.start());
  // A native shell writes one leaf; the plain write path stores exactly that entry.
  node.setConfigKey("cas.camera.fps", "8");
  node.setConfigKey("cas.camera.codec", R"("auto")");
  // The Admin page then commits an object patch for the parent.
  auto result = json::parse(node.configCommitJson(commitRequest(node,
      R"([{"op":"set","key":"cas.camera","value":{"fps":15,"quality":60}}])")));
  REQUIRE(json::getBool(result.get(), "ok"));
  CHECK(cameraFps(node.configJson()) == 15);
  auto document = json::parse(node.configJson());
  auto* camera = json::get(json::get(document.get(), "cas"), "camera");
  CHECK(json::getInt(camera, "quality") == 60);
  CHECK(json::getString(camera, "codec") == "auto");
  // The same commit accepts leaf keys under that object, which is what the Admin page sends for
  // a changed field, and a leaf delete removes the member the object entry still embeds.
  result = json::parse(node.configCommitJson(commitRequest(node,
      R"([{"op":"set","key":"cas.camera.fps","value":20},{"op":"delete","key":"cas.camera.quality"}])")));
  REQUIRE(json::getBool(result.get(), "ok"));
  CHECK(cameraFps(node.configJson()) == 20);
  document = json::parse(node.configJson());
  camera = json::get(json::get(document.get(), "cas"), "camera");
  CHECK(json::get(camera, "quality") == nullptr);
  CHECK(json::getString(camera, "codec") == "auto");
  // An object patch can drop a member whose name contains a dot.
  node.setConfigKey("cas.texts", R"({"idle.title":"Touch","calling.title":"Ringing"})");
  result = json::parse(node.configCommitJson(commitRequest(node,
      R"([{"op":"set","key":"cas.texts","value":{"incall.end":"Stop"},"remove_fields":["calling.title"]}])")));
  REQUIRE(json::getBool(result.get(), "ok"));
  document = json::parse(node.configJson());
  auto* texts = json::get(json::get(document.get(), "cas"), "texts");
  CHECK(json::getString(texts, "idle.title") == "Touch");
  CHECK(json::getString(texts, "incall.end") == "Stop");
  CHECK(json::get(texts, "calling.title") == nullptr);
  // A later leaf write from the shell still wins over the committed object.
  node.setConfigKey("cas.camera.fps", "30");
  CHECK(cameraFps(node.configJson()) == 30);
  node.stop();
}

TEST_CASE("leaf masking: leaf commits for device camera, motion and theme pass validation") {
  Node node(maskOptions());
  REQUIRE(node.start());
  const std::string device = "devices.a1b2c3d4e5f60718293a4b5c6d7e8f90";
  node.setConfigKey(device + ".local.camera", R"({"mjpeg_fps":8,"mjpeg_quality":60})");
  node.setConfigKey(device + ".local.motion", R"({"enabled":true,"sensitivity":40})");
  node.setConfigKey("display.theme", R"({"bg_color":"#12202c","backdrop":{"opacity":55}})");
  const std::string operations = std::string("[") +
      R"({"op":"set","key":")" + device + R"(.local.camera.mjpeg_fps","value":15},)" +
      R"({"op":"set","key":")" + device + R"(.local.motion.enabled","value":false},)" +
      R"({"op":"set","key":"display.theme.bg_color","value":"#101418"},)" +
      R"({"op":"set","key":"display.theme.backdrop.opacity","value":70},)" +
      R"({"op":"set","key":"display.theme.glass.blur_radius","value":20}])";
  auto result = json::parse(node.configCommitJson(commitRequest(node, operations)));
  REQUIRE(json::getBool(result.get(), "ok"));
  auto document = json::parse(node.configJson());
  auto* local = json::get(json::get(json::get(document.get(), "devices"),
                                    "a1b2c3d4e5f60718293a4b5c6d7e8f90"), "local");
  CHECK(json::getInt(json::get(local, "camera"), "mjpeg_fps") == 15);
  CHECK(json::getInt(json::get(local, "camera"), "mjpeg_quality") == 60);
  CHECK_FALSE(json::getBool(json::get(local, "motion"), "enabled"));
  auto* theme = json::get(json::get(document.get(), "display"), "theme");
  CHECK(json::getString(theme, "bg_color") == "#101418");
  CHECK(json::getInt(json::get(theme, "backdrop"), "opacity") == 70);
  CHECK(json::getInt(json::get(theme, "glass"), "blur_radius") == 20);
  node.stop();
}

TEST_CASE("leaf masking: an older leaf from another replica masks a newer object commit when it arrives late") {
  // Current behaviour, recorded so a change to it is deliberate: the commit can only rewrite
  // leaves present on the committing replica. A leaf written earlier on a replica that had not
  // synchronized yet still hides the newer object member once it replicates.
  MaskReplica shell(kShellNode, 1000), admin(kAdminNode, 1000);
  shell.map.set("cas.camera.fps", "8");
  admin.clock.advance(60'000);
  const LwwEntry object = admin.map.set("cas.camera", R"({"fps":15})");
  CHECK(cameraFps(admin.map.materializeJson()) == 15);
  const auto late = shell.map.all();
  REQUIRE(late.size() == 1);
  REQUIRE(late.front().hlc < object.hlc);
  admin.map.applyRemoteBatch(late);
  CHECK(cameraFps(admin.map.materializeJson()) == 8);
  // A leaf written by the Admin replica at the object's time would have won by plain LWW.
  MaskReplica leaves(kAdminNode, 1000);
  leaves.clock.advance(60'000);
  leaves.map.set("cas.camera.fps", "15");
  leaves.map.applyRemoteBatch(late);
  CHECK(cameraFps(leaves.map.materializeJson()) == 15);
}
