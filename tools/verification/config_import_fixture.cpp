#include <csignal>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <thread>

#include "node/node.h"

namespace {
volatile std::sig_atomic_t stopped = 0;
void stop(int) { stopped = 1; }
}

int main(int argc, char** argv) {
  if (argc != 3) return 2;
  db::RealClock clock;
  db::Runloop loop(clock);
  db::InMemNet network(loop);
  db::NodeOptions options;
  options.data_dir = argv[1];
  options.http_port = std::atoi(argv[2]);
  if (options.http_port < 1024 || options.http_port > 65535) return 2;
  options.name = "T30 isolated import fixture";
  options.role = "indoor_panel";
  options.listen_addr = "T30";
  options.advertise_addr = "127.0.0.1:1";
  options.enable_beacon = false;
  options.has_https = false;
  options.psk.fill(0x73);
  db::NodeDeps dependencies;
  dependencies.clock = &clock;
  dependencies.loop = &loop;
  dependencies.transport = network.makeTransport("T30");
  loop.start();
  db::Node node(options, std::move(dependencies));
  if (!node.start()) { loop.stop(); return 3; }
  node.setConfigKey("time.ntp.enabled", "false");
  if (node.setAdminPassword("", "T30-local-test-only") != 0) {
    node.stop(); loop.stop(); return 4;
  }
  std::signal(SIGINT, stop); std::signal(SIGTERM, stop);
  std::cout << "Ready: http://127.0.0.1:" << options.http_port << "/admin/?lang=en" << std::endl;
  while (!stopped) std::this_thread::sleep_for(std::chrono::milliseconds(50));
  std::ofstream(std::filesystem::path(options.data_dir) / "final-snapshot.json")
      << node.configSnapshotJson() << '\n';
  node.stop(); loop.stop();
  return 0;
}
