#pragma once
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <functional>
#include <map>
#include <mutex>
#include <thread>

#include "bridge/mqtt_client.h"
#include "bridge/ha_bridge.h"
#include "doctest.h"
#include "node/node.h"
#include "test_env.h"
#include "util/json.h"

using namespace db;

namespace {
bool operationWait(const std::function<bool()>& predicate, int timeout_ms = 8000) {
  const auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
  do {
    if (predicate()) return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
  } while (std::chrono::steady_clock::now() < end);
  return predicate();
}

struct OperationHttpResult {
  int status = 0;
  std::string body;
  std::string cookie;
};
OperationHttpResult operationHttp(int port, const std::string& method, const std::string& path,
    const std::string& body = "", const std::string& cookie = "", const std::string& csrf = "",
    bool discard_response = false, const std::string& origin = "local") {
  int fd = ::socket(AF_INET, SOCK_STREAM, 0);
  REQUIRE(fd >= 0);
  sockaddr_in address{};
  address.sin_family = AF_INET;
  address.sin_port = htons(port);
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  REQUIRE(::connect(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0);
  std::string request = method + " " + path + " HTTP/1.1\r\nHost: 127.0.0.1:" +
      std::to_string(port) + "\r\nConnection: close\r\nContent-Type: application/json\r\n";
  request += "Content-Length: " + std::to_string(body.size()) + "\r\n";
  if (!cookie.empty()) request += "Cookie: " +
      (cookie.find('=') == std::string::npos ? "dbsess=" + cookie : cookie) + "\r\n";
  if (!csrf.empty()) {
    request += "X-Doorbell-CSRF: " + csrf + "\r\n";
    if (!origin.empty()) request += "Origin: " + (origin == "local" ?
        "http://127.0.0.1:" + std::to_string(port) : origin) + "\r\n";
  }
  request += "\r\n" + body;
  REQUIRE(::send(fd, request.data(), request.size(), 0) == static_cast<ssize_t>(request.size()));
  std::string response;
  timeval timeout{6, 0};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
  char buffer[4096];
  for (;;) {
    const ssize_t n = ::recv(fd, buffer, sizeof(buffer), 0);
    if (n <= 0) break;
    response.append(buffer, n);
  }
  ::close(fd);
  if (discard_response) return {};  // Transport read is deliberately unavailable to the caller.
  OperationHttpResult result;
  std::sscanf(response.c_str(), "HTTP/1.1 %d", &result.status);
  const auto split = response.find("\r\n\r\n");
  if (split != std::string::npos) result.body = response.substr(split + 4);
  const auto cookie_start = response.find("dbsess=");
  if (cookie_start != std::string::npos)
    result.cookie = response.substr(cookie_start + 7, response.find(';', cookie_start) - cookie_start - 7);
  const auto panel_start = response.find("dbpanel=");
  if (panel_start != std::string::npos)
    result.cookie = response.substr(panel_start, response.find(';', panel_start) - panel_start);
  return result;
}

// A local protocol fixture, with no lock or Home Assistant connection. Production MqttClient
// sockets still send CONNECT/PUBLISH, and the recorded bytes are the adapter dispatch evidence.
class OperationBroker {
 public:
  OperationBroker() : port(testing::freeListenPort()) {
    listener = ::socket(AF_INET, SOCK_STREAM, 0);
    REQUIRE(listener >= 0);
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    REQUIRE(::bind(listener, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0);
    REQUIRE(::listen(listener, 8) == 0);
    worker = std::thread([this] { run(); });
  }
  ~OperationBroker() {
    stopped = true;
    worker.join();
    ::close(listener);
  }
  size_t count(const std::string& id) {
    std::lock_guard<std::mutex> lock(mu);
    return counts[id];
  }
  std::string command(const std::string& id) {
    std::lock_guard<std::mutex> lock(mu);
    return commands[id];
  }
  void publish(const std::string& payload, bool retained = false) {
    std::lock_guard<std::mutex> lock(mu);
    incoming.push_back(mqtt::encodePublish("operation-test/cmd/ack", payload, retained));
  }
  void disconnect() { drop_clients = true; }
  int port;
 private:
  void run() {
    std::map<int, Bytes> clients;
    while (!stopped) {
      if (drop_clients.exchange(false)) {
        for (const auto& client : clients) ::close(client.first);
        clients.clear();
      }
      std::vector<Bytes> packets;
      {
        std::lock_guard<std::mutex> lock(mu);
        packets.swap(incoming);
      }
      for (const auto& bytes : packets) for (const auto& client : clients)
        ::send(client.first, bytes.data(), bytes.size(), 0);
      fd_set readable;
      FD_ZERO(&readable);
      FD_SET(listener, &readable);
      int maximum = listener;
      for (const auto& client : clients) { FD_SET(client.first, &readable); maximum = std::max(maximum, client.first); }
      timeval timeout{0, 20000};
      if (::select(maximum + 1, &readable, nullptr, nullptr, &timeout) <= 0) continue;
      if (FD_ISSET(listener, &readable)) {
        const int fd = ::accept(listener, nullptr, nullptr);
        if (fd >= 0) {
#ifdef SO_NOSIGPIPE
          int enabled = 1;
          setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
#endif
          clients.emplace(fd, Bytes{});
        }
      }
      for (auto it = clients.begin(); it != clients.end();) {
        if (!FD_ISSET(it->first, &readable)) { ++it; continue; }
        uint8_t bytes[8192];
        const ssize_t count = ::recv(it->first, bytes, sizeof(bytes), 0);
        if (count <= 0) { ::close(it->first); it = clients.erase(it); continue; }
        it->second.insert(it->second.end(), bytes, bytes + count);
        mqtt::Packet packet;
        int used = 0;
        while ((used = mqtt::decodePacket(it->second.data(), it->second.size(), &packet)) > 0) {
          it->second.erase(it->second.begin(), it->second.begin() + used);
          if (packet.type == mqtt::kConnect) {
            const uint8_t ack[] = {0x20, 2, 0, 0};
            ::send(it->first, ack, sizeof(ack), 0);
          } else if (packet.type == mqtt::kPingReq) {
            const uint8_t pong[] = {0xd0, 0};
            ::send(it->first, pong, sizeof(pong), 0);
          } else if (packet.type == mqtt::kPublish) {
            std::string topic, payload;
            bool retain = false;
            if (mqtt::parsePublish(packet, &topic, &payload, &retain) &&
                topic.size() >= 11 && topic.substr(topic.size() - 11) == "/cmd/unlock") {
              auto body = json::parse(payload);
              const auto id = json::getString(body.get(), "operation_id");
              if (!id.empty()) {
                std::lock_guard<std::mutex> lock(mu);
                ++counts[id];
                commands[id] = payload;
              }
            }
          }
        }
        ++it;
      }
    }
    for (const auto& client : clients) ::close(client.first);
  }
  int listener;
  std::atomic<bool> stopped{false};
  std::thread worker;
  std::mutex mu;
  std::map<std::string, size_t> counts;
  std::map<std::string, std::string> commands;
  std::vector<Bytes> incoming;
  std::atomic<bool> drop_clients{false};
};

struct OperationFleet {
  NodeOptions a_opts, b_opts;
  std::unique_ptr<Node> a, b;
  std::string cookie, csrf;
  explicit OperationFleet(const std::string& authority_directory = ":memory:") {
    a_opts.data_dir = ":memory:";
    b_opts.data_dir = authority_directory;
    a_opts.role = "indoor_panel";
    b_opts.role = "door_station";
    b_opts.door = "front";
    a_opts.name = "operation-page";
    b_opts.name = "operation-authority";
    a_opts.psk.fill(0x5b); b_opts.psk = a_opts.psk;
    a_opts.enable_beacon = b_opts.enable_beacon = false;
    a_opts.http_port = testing::freeListenPort();
    b_opts.http_port = testing::freeListenPort();
    a_opts.listen_addr = "127.0.0.1:" + std::to_string(testing::freeListenPort());
    b_opts.listen_addr = "127.0.0.1:" + std::to_string(testing::freeListenPort());
    a_opts.advertise_addr = a_opts.listen_addr; b_opts.advertise_addr = b_opts.listen_addr;
    a_opts.seed_peers = {b_opts.listen_addr}; b_opts.seed_peers = {a_opts.listen_addr};
    a_opts.caps_json = "{\"mqtt_reachable\":false,\"cpu_score\":1}";
    b_opts.caps_json = "{\"mqtt_reachable\":true,\"mains_power\":true,\"cpu_score\":100}";
    auto& timing = a_opts.mesh_timing_template;
    timing.heartbeat_ms = 100; timing.suspect_ms = 500; timing.dead_ms = 1500;
    timing.gossip_ms = timing.sync_ms = timing.reconnect_ms = 100; timing.claim_ttl_ms = 1000;
    b_opts.mesh_timing_template = timing;
    a_opts.use_mesh_timing_template = b_opts.use_mesh_timing_template = true;
    a.reset(new Node(a_opts)); b.reset(new Node(b_opts));
    REQUIRE(b->start()); REQUIRE(a->start());
    const auto login = operationHttp(a_opts.http_port, "POST", "/api/login", "{\"password\":\"testpw\"}");
    REQUIRE(login.status == 200);
    cookie = login.cookie;
    auto body = json::parse(login.body);
    csrf = json::getString(body.get(), "csrf_token");
    REQUIRE(!csrf.empty());
    REQUIRE(operationWait([&] { return b->verifyAdminPassword("testpw") == 1; }));
    a->setConfigKey("devices." + a->nodeId() + ".operations", "{\"doors\":[\"front\"],\"sos_start\":true,\"sos_clear\":true}");
    a->setConfigKey("devices." + b->nodeId() + ".operations", "{\"doors\":[\"front\"],\"sos_start\":true,\"sos_clear\":true}");
    a->setConfigKey("doors.front.unlock.command", "\"unlock\"");
    a->setConfigKey("doors.front.operations.authority_node", "\"" + b->nodeId() + "\"");
    a->setConfigKey("cluster.operations.sos_authority_node", "\"" + b->nodeId() + "\"");
    REQUIRE(operationWait([&] {
      return b->configJson().find("sos_authority_node") != std::string::npos &&
             b->configJson().find("sos_clear") != std::string::npos;
    }));
  }
  ~OperationFleet() { a->stop(); b->stop(); }
  std::string request(const std::string& action, const std::string& id = "") {
    auto body = json::obj();
    json::set(body.get(), "schema_version", int64_t{2});
    json::set(body.get(), "action", action);
    if (action == "door_open") json::set(body.get(), "door", "front");
    if (!id.empty()) {
      json::set(body.get(), "operation_id", id);
      json::set(body.get(), "authority_node", b->nodeId());
    }
    return json::dump(body.get());
  }
  OperationHttpResult prepare(const std::string& action) {
    return operationHttp(a_opts.http_port, "POST", "/api/operations/prepare", request(action), cookie, csrf);
  }
  OperationHttpResult execute(const std::string& action, const std::string& id, bool discard = false) {
    return operationHttp(a_opts.http_port, "POST", "/api/operations/" + id + "/execute",
        request(action, id), cookie, csrf, discard);
  }
  OperationHttpResult query(const std::string& action, const std::string& id, int port = 0,
                             const std::string& session = "") {
    return operationHttp(port ? port : a_opts.http_port, "GET", "/api/operations/" + id +
        "?authority_node=" + b->nodeId() + "&action=" + action +
        (action == "door_open" ? "&door=front" : ""), "", session.empty() ? cookie : session);
  }
};
std::string operationField(const OperationHttpResult& result, const char* key) {
  auto body = json::parse(result.body);
  return json::getString(body.get(), key);
}
}  // namespace
