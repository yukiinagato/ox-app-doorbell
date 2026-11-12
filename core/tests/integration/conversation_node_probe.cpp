#include <poll.h>
#include <unistd.h>
#include <map>
#include <set>
#include <memory>
#include <mutex>
#include <string>
#include <cstdio>
#include <iostream>
#include <fstream>
#include <sstream>
#include <sys/stat.h>
#include "node/node.h"
#include "sipctl/sipctl.h"
#include "util/json.h"
#include "minisip.h"
using namespace db;
struct External {
  Node* node;
  std::string mode;
  ms_session* session = nullptr;
  ~External() { if (session) ms_free(session); }
  static void state(ms_state state, void* user) {
    auto* self = static_cast<External*>(user);
    if (state == MS_STATE_IN_CALL || state == MS_STATE_ENDED)
      self->node->reportConversationExternalMedia(self->mode, state == MS_STATE_IN_CALL);
  }
};
int main(int argc, char** argv) {
  if (argc != 6) return 2;
  NodeOptions options;
  options.data_dir = argv[1]; options.role = argv[2]; options.door = argv[3];
  options.name = options.role + std::string(argv[4]);
  options.listen_addr = std::string("127.0.0.1:") + argv[4]; options.advertise_addr = options.listen_addr;
  options.enable_beacon = false; options.sip_null_audio = true;
  options.seed_default_config = options.role == "door_station";
  options.psk.fill(0x37);
  options.seed_peers.push_back(std::string("127.0.0.1:") + argv[5]);
  options.use_mesh_timing_template = true;
  options.mesh_timing_template.heartbeat_ms = 500;
  options.mesh_timing_template.suspect_ms = 3000;
  options.mesh_timing_template.dead_ms = 5000;
  options.mesh_timing_template.gossip_ms = 500;
  options.mesh_timing_template.sync_ms = 500;
  options.mesh_timing_template.claim_ttl_ms = 3000;
  std::mutex mutex;
  std::string desired;
  Node node(options);
  // The test keychain persists only this isolated fixture's generated identity across restarts.
  const auto keychain_path = options.data_dir + "/test-keychain.json";
  std::ifstream stored(keychain_path);
  std::stringstream saved; saved << stored.rdbuf();
  auto keychain = json::parse(saved.str());
  if (!keychain) keychain = json::obj();
  std::mutex keychain_mutex;
  node.setSecureStore([&](const std::string& key) {
    std::lock_guard<std::mutex> lock(keychain_mutex);
    return json::getString(keychain.get(), key.c_str());
  }, [&](const std::string& key, const std::string& value) {
    std::lock_guard<std::mutex> lock(keychain_mutex);
    json::set(keychain.get(), key.c_str(), value);
    std::ofstream output(keychain_path, std::ios::trunc);
    output << json::dump(keychain.get());
    output.close();
    chmod(keychain_path.c_str(), 0600);
    return output.good();
  });
  node.setUiEventCb([&](const std::string& json) {
    auto event = json::parse(json);
    if (json::getString(event.get(), "t") == "conversation_transport") {
      std::lock_guard<std::mutex> lock(mutex); desired = json;
    }
  });
  if (!node.start()) return 3;
  if (!sipBackendAvailable()) node.setConversationExternalTransport(true);
  std::map<std::string, std::unique_ptr<External>> sessions;
  auto reply = [](const std::string& body) { std::cout << "RESULT " << body << std::endl; };
  reply("{\"ready\":true}");
  bool done = false;
  while (!done) {
    std::string transport;
    { std::lock_guard<std::mutex> lock(mutex); transport.swap(desired); }
    if (!transport.empty()) {
      auto event = json::parse(transport);
      std::set<std::string> wanted;
      const cJSON* item = nullptr;
      cJSON_ArrayForEach(item, json::get(event.get(), "sessions")) {
        const auto mode = json::getString(item, "mode");
        wanted.insert(mode);
        if (sessions.count(mode)) continue;
        const auto target = json::getString(item, "target");
        const auto separator = target.rfind(':');
        if (target.rfind("sip:", 0) != 0 || separator <= 4) continue;
        auto peer = std::make_unique<External>();
        peer->node = &node; peer->mode = mode;
        const auto auth = node.sipPeerAuthHeader(mode);
        ms_callbacks callbacks{}; callbacks.on_state = External::state; callbacks.user = peer.get();
        peer->session = ms_call_authenticated(target.substr(4, separator - 4).c_str(),
            std::stoi(target.substr(separator + 1)), mode.c_str(), auth.c_str(), &callbacks);
        if (peer->session) sessions.emplace(mode, std::move(peer));
        else node.reportConversationExternalMedia(mode, false);
      }
      for (auto it = sessions.begin(); it != sessions.end(); )
        if (!wanted.count(it->first)) it = sessions.erase(it); else ++it;
    }
    for (auto& entry : sessions) ms_poll(entry.second->session, 0);
    pollfd descriptor{STDIN_FILENO, POLLIN, 0};
    if (poll(&descriptor, 1, 5) <= 0) continue;
    std::string line;
    if (!std::getline(std::cin, line)) break;
    auto command = json::parse(line);
    const auto operation = json::getString(command.get(), "op");
    if (operation == "status") reply(node.statusJson());
    else if (operation == "action") reply(node.conversationRequestJson(line));
    else if (operation == "press") {
      auto out = json::obj(); json::set(out.get(), "call_id", node.pressV2(options.door)); reply(json::dump(out.get()));
    } else if (operation == "exit") { done = true; reply("{}"); }
    else reply("{\"error\":\"invalid_request\"}");
  }
  sessions.clear();
  node.stop();
  return 0;
}
