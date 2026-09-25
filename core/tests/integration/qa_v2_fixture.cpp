#include <atomic>
#include <chrono>
#include <iostream>
#include <thread>
#include <vector>

#include "../test_env.h"
#include "node/node.h"
#include "util/clock.h"
#include "util/json.h"
#include "util/runloop.h"

// Real Core, HTTP server, embedded assets, image encoder, and rotating camera
// frames. No SIP service or OS camera is claimed by this host-only fixture.
int main() {
  db::RealClock clock;
  db::Runloop loop(clock);
  loop.start();
  db::NodeOptions options;
  options.data_dir = ":memory:";
  options.name = "qa-v2-door";
  options.role = "door_station";
  options.door = "front";
  options.listen_addr = "127.0.0.1:" + std::to_string(db::testing::freeListenPort());
  options.http_port = db::testing::freeListenPort();
  options.enable_beacon = false;
  options.caps_json = R"({"camera":true})";
  db::NodeDeps deps;
  deps.clock = &clock;
  deps.loop = &loop;
  db::Node node(options, std::move(deps));
  node.setSecureStore([](const std::string& key) {
    return key == "qa-v2.panel" ? std::string("qa-v2-local-only") : std::string();
  }, [](const std::string&, const std::string&) { return true; });
  if (!node.start()) return 2;
  node.setConfigKey("panel.token_refs", R"(["secret:qa-v2.panel"])");
  node.setConfigKey("doors.front", R"({"label":{"en":"Front"}})");
  node.setConfigKey("devices." + node.nodeId() + ".role", "\"door_station\"");
  node.setConfigKey("devices." + node.nodeId() + ".door", "\"front\"");
  std::atomic<bool> running{true};
  std::thread camera([&] {
    unsigned frame = 0;
    while (running) {
      std::vector<uint8_t> pixels(64 * 48 * 4, 255);
      const uint8_t level = static_cast<uint8_t>(30 + (frame++ % 8) * 26);
      for (size_t i = 0; i < pixels.size(); i += 4) {
        pixels[i] = level; pixels[i + 1] = level; pixels[i + 2] = level;
      }
      node.pushCameraFrame(pixels.data(), 3, 64, 48, 64 * 4, clock.wallMs());
      std::this_thread::sleep_for(std::chrono::milliseconds(120));
    }
  });
  auto ready = db::json::obj();
  db::json::set(ready.get(), "port", static_cast<int64_t>(options.http_port));
  db::json::set(ready.get(), "credential", "qa-v2-local-only");
  db::json::set(ready.get(), "node_id", node.nodeId());
  std::cout << db::json::dump(ready.get()) << std::endl;
  std::string command;
  std::getline(std::cin, command);
  running = false;
  camera.join();
  node.stop();
  loop.stop();
  return 0;
}
