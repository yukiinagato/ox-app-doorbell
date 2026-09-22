#include <csignal>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <thread>

#include "node/node.h"
#include "util/json.h"

namespace {
volatile std::sig_atomic_t stopped = 0;
void stop(int) { stopped = 1; }

bool await(const std::function<bool()>& predicate) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(15);
  while (!stopped && std::chrono::steady_clock::now() < deadline) {
    if (predicate()) return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(25));
  }
  return false;
}

db::json::Doc snapshot(db::Node& node) { return db::json::parse(node.configSnapshotJson()); }

bool set(db::Node& node, const std::string& text) {
  auto current = snapshot(node);
  auto body = db::json::obj();
  db::json::set(body.get(), "schema_version", int64_t{2});
  db::json::set(body.get(), "expected_revision", db::json::getString(current.get(), "revision"));
  auto* op = db::json::pushObj(db::json::addArr(body.get(), "ops"));
  db::json::set(op, "op", "set");
  db::json::set(op, "key", "settings.partition_test");
  db::json::set(op, "value", text);
  auto result = db::json::parse(node.configCommitJson(db::json::dump(body.get())));
  return db::json::getBool(result.get(), "ok");
}

std::string visibleState(db::Node& node) {
  auto current = snapshot(node), output = db::json::obj();
  db::json::set(output.get(), "node_id", node.nodeId());
  db::json::set(output.get(), "revision", db::json::getString(current.get(), "revision"));
  for (const auto& key : {"edit_conflicts", "edit_journal"}) {
    const auto* value = db::json::get(current.get(), key);
    if (value) db::json::setItem(output.get(), key, db::json::Doc(cJSON_Duplicate(value, 1)));
  }
  const auto* settings = db::json::get(db::json::get(current.get(), "config"), "settings");
  if (settings) db::json::setItem(output.get(), "settings", db::json::Doc(cJSON_Duplicate(settings, 1)));
  return db::json::dump(output.get());
}
}

int main(int argc, char** argv) {
  if (argc != 3 && (argc != 4 || std::string(argv[3]) != "--deferred")) return 2;
  const bool deferred = argc == 4;
  const std::filesystem::path directory = argv[1], evidence = argv[2];
  std::filesystem::create_directories(directory / "a");
  std::filesystem::create_directories(directory / "b");
  std::filesystem::create_directories(evidence);
  db::RealClock clock;
  db::Runloop loop(clock);
  db::InMemNet net(loop);
  auto options = [&](const std::string& name, int port, bool seed) {
    db::NodeOptions value;
    value.name = "T28 isolated " + name;
    value.data_dir = (directory / name).string();
    value.role = "indoor_panel";
    value.listen_addr = value.advertise_addr = "t28-config-" + name;
    value.enable_beacon = false;
    value.has_https = false;
    value.http_port = port;
    value.seed_default_config = seed;
    value.psk.fill(0x72);
    auto& timing = value.mesh_timing_template;
    timing.heartbeat_ms = 30; timing.suspect_ms = 90; timing.dead_ms = 150;
    timing.gossip_ms = timing.sync_ms = timing.reconnect_ms = 50;
    timing.claim_ttl_ms = 300;
    value.use_mesh_timing_template = true;
    return value;
  };
  auto dependencies = [&](const std::string& name) {
    db::NodeDeps value; value.clock = &clock; value.loop = &loop;
    value.transport = net.makeTransport("t28-config-" + name);
    value.discovery = net.makeDiscovery("t28-config-" + name);
    return value;
  };
  auto depA = dependencies("a"), depB = dependencies("b");
  loop.start();
  db::Node a(options("a", 18766, true), std::move(depA));
  db::Node b(options("b", 18767, false), std::move(depB));
  std::signal(SIGINT, stop); std::signal(SIGTERM, stop);
  auto cleanup = [&] { a.stop(); b.stop(); loop.stop(); };
  if (!a.start()) { cleanup(); return 3; }
  a.setConfigKey("time.ntp.enabled", "false");
  if (a.setAdminPassword("", "T28-local-test-only") != 0 || !b.start()) { cleanup(); return 4; }
  if (!set(a, "Shared ancestor") || !await([&] {
      return b.configJson().find("Shared ancestor") != std::string::npos;
    })) { cleanup(); return 5; }
  auto conflict = [&] {
    loop.callSync([&] { net.partition({{"t28-config-a"}, {"t28-config-b"}}); });
    if (!set(a, "A intent") || !set(b, "B intent")) return false;
    loop.callSync([&] { net.heal(); });
    if (!await([&] {
        auto left = snapshot(a), right = snapshot(b);
        const auto* conflicts = db::json::get(left.get(), "edit_conflicts");
        return cJSON_GetArraySize(conflicts) == 1 && db::json::dump(conflicts) ==
            db::json::dump(db::json::get(right.get(), "edit_conflicts"));
      })) return false;
    std::ofstream(evidence / "conflict-a.json") << visibleState(a) << '\n';
    std::ofstream(evidence / "conflict-b.json") << visibleState(b) << '\n';
    return true;
  };
  if (!deferred && !conflict()) { cleanup(); return 6; }
  std::ofstream(evidence / "initial-a.json") << visibleState(a) << '\n';
  std::ofstream(evidence / "initial-b.json") << visibleState(b) << '\n';
  std::cout << "Ready: http://127.0.0.1:18766/admin/?lang=en and :18767; "
               "production HTTP wildcard listeners, authenticated in-memory mesh only" << std::endl;
  bool pending = deferred;
  while (!stopped) {
    if (pending && std::filesystem::exists(directory / "create-conflict")) {
      std::filesystem::remove(directory / "create-conflict"); pending = false;
      if (!conflict()) { cleanup(); return 7; }
      std::cout << "Partition edits healed; both production snapshots contain the conflict" << std::endl;
    }
    std::ofstream(evidence / "current-a.json") << visibleState(a) << '\n';
    std::ofstream(evidence / "current-b.json") << visibleState(b) << '\n';
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
  }
  std::ofstream(evidence / "final-a.json") << visibleState(a) << '\n';
  std::ofstream(evidence / "final-b.json") << visibleState(b) << '\n';
  cleanup();
  return 0;
}
