
//   /api/config/delete (tombstone) / /api/config/import / /api/join-token /

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <functional>
#include <mutex>
#include <map>
#include <random>
#include <string>
#include <thread>
#include <vector>

#include <sqlite3.h>

#include "doctest.h"
#include "node/node.h"
#include "util/json.h"

using namespace db;

namespace {

int adminFreePort(std::mt19937& rng) {
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


std::string adminReq(int port, const std::string& method, const std::string& path,
                     const std::string& body = "", const std::string& cookie = "") {
  int fd = ::socket(AF_INET, SOCK_STREAM, 0);
  REQUIRE(fd >= 0);
  sockaddr_in sa{};
  sa.sin_family = AF_INET;
  sa.sin_port = htons(static_cast<uint16_t>(port));
  sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  REQUIRE(::connect(fd, reinterpret_cast<sockaddr*>(&sa), sizeof(sa)) == 0);
  std::string r = method + " " + path + " HTTP/1.1\r\nHost: 127.0.0.1\r\n";
  if (!cookie.empty())
    r += "Cookie: " + (cookie.find('=') == std::string::npos ? "dbsess=" + cookie : cookie) +
         "\r\n";
  if (!body.empty())
    r += "Content-Type: application/json\r\nContent-Length: " + std::to_string(body.size()) +
         "\r\n";
  r += "Connection: close\r\n\r\n" + body;
  REQUIRE(::send(fd, r.data(), r.size(), 0) == static_cast<ssize_t>(r.size()));
  std::string resp;
  char buf[8192];
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


std::string adminLogin(int port) {
  std::string r = adminReq(port, "POST", "/api/login", "{\"password\":\"testpw\"}");
  REQUIRE(r.find("HTTP/1.1 200") == 0);
  size_t p = r.find("dbsess=");
  REQUIRE(p != std::string::npos);
  size_t e = r.find(';', p);
  return r.substr(p + 7, e - (p + 7));
}

std::string panelLogin(int port, const std::string& credential) {
  std::string r = adminReq(port, "POST", "/api/panel/session",
                           "{\"credential\":\"" + credential + "\"}");
  REQUIRE(r.find("HTTP/1.1 200") == 0);
  size_t p = r.find("dbpanel=");
  REQUIRE(p != std::string::npos);
  size_t e = r.find(';', p);
  return r.substr(p + 8, e - (p + 8));
}


json::Doc bodyJson(const std::string& resp) {
  size_t p = resp.find("\r\n\r\n");
  return json::parse(p == std::string::npos ? "" : resp.substr(p + 4));
}


std::string adminTgCaps() {
  auto o = json::obj();
  json::setBool(o.get(), "tls12", true);
  json::setBool(o.get(), "wan", true);
  json::setBool(o.get(), "mains_power", true);
  json::setBool(o.get(), "wall_clock_sane", true);
  json::set(o.get(), "cpu_score", int64_t{10});
  return json::dump(o.get());
}


MeshSettings adminTiming() {
  MeshSettings m;
  m.heartbeat_ms = 100;
  m.suspect_ms = 300;
  m.dead_ms = 500;
  m.gossip_ms = 200;
  m.sync_ms = 200;
  m.claim_ttl_ms = 450;
  m.reconnect_ms = 200;
  return m;
}

std::string adminTempDir() {
  char path[] = "/tmp/doorbell_admin_durability_XXXXXX";
  char* created = mkdtemp(path);
  REQUIRE(created != nullptr);
  return created;
}

bool setAdminConfigWriteFailure(const std::string& path, bool enabled) {
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

bool setAdminEventProjectionFailure(const std::string& path, bool enabled) {
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

bool setAdminMetaWriteFailure(const std::string& path, bool enabled) {
  sqlite3* db = nullptr;
  if (sqlite3_open(path.c_str(), &db) != SQLITE_OK) {
    if (db) sqlite3_close(db);
    return false;
  }
  const char* sql = enabled
      ? "CREATE TRIGGER fail_meta_write BEFORE INSERT ON meta "
        "BEGIN SELECT RAISE(FAIL,'injected metadata write failure'); END"
      : "DROP TRIGGER IF EXISTS fail_meta_write";
  const bool ok = sqlite3_exec(db, sql, nullptr, nullptr, nullptr) == SQLITE_OK;
  sqlite3_close(db);
  return ok;
}

void removeAdminTempDir(const std::string& dir) {
  for (const char* name : {"doorbell.db", "doorbell.db-wal", "doorbell.db-shm"})
    std::remove((dir + "/" + name).c_str());
  ::rmdir((dir + "/assets").c_str());
  ::rmdir(dir.c_str());
}



struct AdminMockHttps {
  std::mutex mu;
  std::vector<std::pair<std::string, std::string>> reqs;  // (url, body)
  Node::HttpsFn fn() {
    return [this](const std::string&, const std::string& u, const std::string&, const Bytes& b,
                  std::function<void(int, std::string)> done) {
      {
        std::lock_guard<std::mutex> lk(mu);
        reqs.push_back({u, std::string(b.begin(), b.end())});
      }
      if (u.find("/getUpdates") != std::string::npos) {
        done(200, "{\"ok\":true,\"result\":[]}");
        return;
      }
      done(200, "{\"ok\":true,\"result\":{\"message_id\":42}}");
    };
  }

  size_t count(const std::string& api, const std::string& needle) {
    std::lock_guard<std::mutex> lk(mu);
    size_t n = 0;
    for (const auto& r : reqs)
      if (r.first.find("/" + api) != std::string::npos &&
          r.second.find(needle) != std::string::npos)
        n++;
    return n;
  }
};

}  // namespace

TEST_CASE("admin API: initial password is issued only after an atomic durable write") {
  std::mt19937 rng(static_cast<uint32_t>(::getpid()) ^ 0xa11ceu);
  const int mesh_port = adminFreePort(rng);
  const int http_port = adminFreePort(rng);
  REQUIRE(mesh_port > 0);
  REQUIRE(http_port > 0);
  const std::string dir = adminTempDir();

  NodeOptions options;
  options.data_dir = dir;
  options.name = "credential-durability";
  options.role = "indoor_panel";
  options.listen_addr = "127.0.0.1:" + std::to_string(mesh_port);
  options.psk.fill(0x26);
  options.enable_beacon = false;
  options.http_port = http_port;
  options.mesh_timing_template = adminTiming();
  options.use_mesh_timing_template = true;

  Node node(options);
  REQUIRE(node.start());
  REQUIRE(setAdminMetaWriteFailure(dir + "/doorbell.db", true));
  const std::string failed = adminReq(
      http_port, "POST", "/api/login", R"({"password":"must-not-stick"})");
  CHECK(failed.find("HTTP/1.1 500") == 0);
  CHECK(failed.find("credential_persistence_failed") != std::string::npos);
  CHECK(failed.find("Set-Cookie") == std::string::npos);

  REQUIRE(setAdminMetaWriteFailure(dir + "/doorbell.db", false));
  const std::string initialized = adminReq(
      http_port, "POST", "/api/login", R"({"password":"durable-password"})");
  CHECK(initialized.find("HTTP/1.1 200") == 0);
  CHECK(initialized.find("dbsess=") != std::string::npos);
  const std::string rejected = adminReq(
      http_port, "POST", "/api/login", R"({"password":"must-not-stick"})");
  CHECK(rejected.find("HTTP/1.1 401") == 0);
  node.stop();

  {
    Store store;
    REQUIRE(store.open(dir + "/doorbell.db"));
    CHECK(store.metaGet("admin_pw_salt").has_value());
    CHECK(store.metaGet("admin_pw_hash").has_value());
  }
  removeAdminTempDir(dir);
}

TEST_CASE("admin API: config persistence failure keeps last-known-good state") {
  std::mt19937 rng(static_cast<uint32_t>(::getpid()) ^ 0xd17abu);
  const int mesh_port = adminFreePort(rng);
  const int http_port = adminFreePort(rng);
  REQUIRE(mesh_port > 0);
  REQUIRE(http_port > 0);
  const std::string dir = adminTempDir();

  NodeOptions options;
  options.data_dir = dir;
  options.name = "config-durability";
  options.role = "door_station";
  options.door = "d_front";
  options.listen_addr = "127.0.0.1:" + std::to_string(mesh_port);
  options.psk.fill(0x27);
  options.enable_beacon = false;
  options.http_port = http_port;
  options.mesh_timing_template = adminTiming();
  options.use_mesh_timing_template = true;

  {
    Node node(options);
    REQUIRE(node.start());
    const std::string session = adminLogin(http_port);
    REQUIRE(adminReq(http_port, "POST", "/api/config",
                     R"({"key":"durability.keep","value":"9"})", session)
                .find("\"ok\":true") != std::string::npos);
    REQUIRE(setAdminConfigWriteFailure(dir + "/doorbell.db", true));

    const std::string direct = adminReq(
        http_port, "POST", "/api/config",
        R"({"key":"durability.direct","value":"1"})", session);
    CHECK(direct.find("HTTP/1.1 500") == 0);
    CHECK(direct.find("config_persistence_failed") != std::string::npos);

    const std::string batch = adminReq(
        http_port, "POST", "/api/config/batch",
        R"({"ops":[{"op":"set","key":"durability.batch_a","value":2},{"op":"set","key":"durability.batch_b","value":3}]})",
        session);
    CHECK(batch.find("HTTP/1.1 500") == 0);
    CHECK(batch.find("config_persistence_failed") != std::string::npos);

    const std::string imported = adminReq(
        http_port, "POST", "/api/config/import",
        R"({"entries":[{"key":"durability.import_a","value":4},{"key":"durability.import_b","value":5}]})",
        session);
    CHECK(imported.find("HTTP/1.1 500") == 0);
    CHECK(imported.find("config_persistence_failed") != std::string::npos);

    const std::string removed = adminReq(
        http_port, "POST", "/api/config/delete", R"({"key":"durability.keep"})", session);
    CHECK(removed.find("HTTP/1.1 500") == 0);
    CHECK(removed.find("config_persistence_failed") != std::string::npos);

    const std::string config = adminReq(http_port, "GET", "/api/config", "", session);
    CHECK(config.find("\"keep\":9") != std::string::npos);
    for (const char* key : {"direct", "batch_a", "batch_b", "import_a", "import_b"})
      CHECK(config.find(key) == std::string::npos);

    auto status = bodyJson(adminReq(http_port, "GET", "/api/status", "", session));
    REQUIRE(status);
    cJSON* config_store = json::get(json::get(status.get(), "runtime"), "config_store");
    REQUIRE(config_store);
    CHECK_FALSE(json::getBool(config_store, "ok", true));
    CHECK(json::getBool(config_store, "fail_closed"));
    CHECK(json::getString(config_store, "active_state") == "last_known_good");

    REQUIRE(setAdminConfigWriteFailure(dir + "/doorbell.db", false));
    const std::string retry = adminReq(
        http_port, "POST", "/api/config",
        R"({"key":"durability.direct","value":"1"})", session);
    CHECK(retry.find("\"ok\":true") != std::string::npos);
    status = bodyJson(adminReq(http_port, "GET", "/api/status", "", session));
    REQUIRE(status);
    CHECK(json::get(json::get(status.get(), "runtime"), "config_store") == nullptr);

    REQUIRE(setAdminEventProjectionFailure(dir + "/doorbell.db", true));
    const std::string failed_press = adminReq(
        http_port, "POST", "/api/press", R"({"door":"d_front"})", session);
    CHECK(failed_press.find("HTTP/1.1 500") == 0);
    CHECK(failed_press.find("event_persistence_failed") != std::string::npos);
    const std::string failed_sos = adminReq(
        http_port, "POST", "/api/emergency", R"({"active":true})", session);
    CHECK(failed_sos.find("HTTP/1.1 500") == 0);
    CHECK(failed_sos.find("event_persistence_failed") != std::string::npos);

    REQUIRE(setAdminEventProjectionFailure(dir + "/doorbell.db", false));
    const auto successful_press = bodyJson(adminReq(
        http_port, "POST", "/api/press", R"({"door":"d_front"})", session));
    REQUIRE(successful_press);
    CHECK(json::getBool(successful_press.get(), "ok"));
    CHECK_FALSE(json::getString(successful_press.get(), "call_id").empty());
    CHECK(json::getString(successful_press.get(), "call_state") == "ringing");
    CHECK(json::getInt(successful_press.get(), "stage_revision", -1) == 0);
    CHECK(json::getInt(successful_press.get(), "expires_at_ms", 0) > 0);
    node.stop();
  }

  {
    Store store;
    REQUIRE(store.open(dir + "/doorbell.db"));
    const auto entries = store.configLoadAll();
    bool kept = false;
    bool retried = false;
    for (const auto& entry : entries) {
      kept = kept || (entry.key == "durability.keep" && !entry.deleted);
      retried = retried || (entry.key == "durability.direct" && !entry.deleted);
      CHECK(entry.key != "durability.batch_a");
      CHECK(entry.key != "durability.batch_b");
      CHECK(entry.key != "durability.import_a");
      CHECK(entry.key != "durability.import_b");
    }
    CHECK(kept);
    CHECK(retried);
  }
  removeAdminTempDir(dir);
}

TEST_CASE("admin API: session gate + config delete/import + join-token + panel-token rotate") {
  std::mt19937 rng(static_cast<uint32_t>(::getpid()) ^ 0xad31u);
  int mesh_port = adminFreePort(rng);
  int http_port = adminFreePort(rng);
  REQUIRE(mesh_port > 0);
  REQUIRE(http_port > 0);

  NodeOptions o;
  o.data_dir = ":memory:";
  o.name = "admin-test";
  o.role = "door_station";
  o.door = "d_front";
  o.listen_addr = "127.0.0.1:" + std::to_string(mesh_port);
  o.psk.fill(0x33);
  o.caps_json = adminTgCaps();
  o.enable_beacon = false;
  o.http_port = http_port;
  o.mesh_timing_template = adminTiming();
  o.use_mesh_timing_template = true;
  Node node(o);
  std::map<std::string, std::string> secure_values;
  std::atomic<int> web_push_requests{0};
  std::atomic<bool> web_push_group_payload{false};
  std::atomic<bool> web_push_catalog_payload{false};
  node.setSecureStore(
      [&](const std::string& key) {
        auto it = secure_values.find(key);
        return it == secure_values.end() ? std::string() : it->second;
      },
      [&](const std::string& key, const std::string& value) {
        if (value.empty()) secure_values.erase(key);
        else secure_values[key] = value;
        return true;
      });
  node.setHttpsFn([&](const std::string&, const std::string& url, const std::string&,
                      const Bytes& body, std::function<void(int, std::string)> done) {
    if (url == "https://push-sender.invalid/send") {
      const std::string request(body.begin(), body.end());
      web_push_group_payload =
          request.find("\"web_subscription_groups\":[\"guards\"]") != std::string::npos;
      web_push_catalog_payload =
          request.find("\"title\":\"紧急情况\"") != std::string::npos &&
          request.find("\"body\":\"紧急模式已触发\"") != std::string::npos;
      ++web_push_requests;
    }
    done(200, "{\"results\":[]}");
  });
  REQUIRE(node.start());
  node.setUiManifest(
      R"({"schema_version":1,"units":"logical","viewport":{"minimum_touch":44,"scale_min":1.0,"scale_max":1.5},"elements":{"call.primary":{"properties":["scale","foreground","background"],"defaults":{"scale":1.0,"foreground":"#FFFFFF","background":"#000000"},"safety_critical":false},"cancel.call":{"properties":["scale","foreground","background","border"],"defaults":{"scale":1.0,"foreground":"#FFFFFF","background":"#000000","border":"#FFFFFF"},"safety_critical":true},"sos.trigger":{"properties":["scale","foreground","background"],"defaults":{"scale":1.0,"foreground":"#FFFFFF","background":"#7F1D1D"},"safety_critical":true}}})");

  // Panels read video orientation from this LAN-visible endpoint without an admin cookie.
  std::string video_meta = adminReq(http_port, "GET", "/video-meta");
  CHECK(video_meta.find("HTTP/1.1 200") == 0);
  CHECK(video_meta.find("{\"rotation\":0}") != std::string::npos);
  CHECK(video_meta.find("Cache-Control: no-store") != std::string::npos);


  CHECK(adminReq(http_port, "POST", "/api/config/delete", "{\"key\":\"x\"}").find("401") !=
        std::string::npos);
  CHECK(adminReq(http_port, "POST", "/api/join-token", "{}").find("401") != std::string::npos);

  std::string sess = adminLogin(http_port);

  // Secrets are written to the platform store and never materialized in config.
  node.setConfigKey("sip.accounts." + node.nodeId() + ".pass_ref", "\"secret:sip_self\"");
  std::this_thread::sleep_for(std::chrono::milliseconds(350));
  {
    auto status = json::parse(node.statusJson());
    REQUIRE(status);
    CHECK(json::getString(json::get(status.get(), "sip"), "credential_source") == "none");
  }
  CHECK(adminReq(http_port, "POST", "/api/secrets",
                 "{\"secret_ref\":\"secret:sip_self\",\"value\":\"self-password\"}", sess)
            .find("{\"ok\":true}") != std::string::npos);
  for (int i = 0; i < 50; ++i) {
    auto status = json::parse(node.statusJson());
    const cJSON* sip = status ? json::get(status.get(), "sip") : nullptr;
    if (json::getString(sip, "credential_source") == "secure_store") break;
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
  }
  {
    auto status = json::parse(node.statusJson());
    REQUIRE(status);
    CHECK(json::getString(json::get(status.get(), "sip"), "credential_source") ==
          "secure_store");
  }
  CHECK(adminReq(http_port, "POST", "/api/secrets",
                 "{\"secret_ref\":\"secret:tg_bot\",\"value\":\"token-value\"}", sess)
            .find("{\"ok\":true}") != std::string::npos);
  CHECK(secure_values["tg_bot"] == "token-value");
  CHECK(node.configJson().find("token-value") == std::string::npos);
  CHECK(adminReq(http_port, "DELETE", "/api/secrets",
                 "{\"secret_ref\":\"secret:tg_bot\"}", sess)
            .find("{\"ok\":true}") != std::string::npos);
  CHECK(secure_values.count("tg_bot") == 0);

  CHECK(adminReq(http_port, "POST", "/api/secrets",
                 "{\"secret_ref\":\"secret:shared_sip\",\"value\":\"shared-value\"}", sess)
            .find("{\"ok\":true}") != std::string::npos);
  CHECK(adminReq(http_port, "POST", "/api/config",
                 "{\"key\":\"sip.accounts.shared\",\"value\":\"{\\\"user\\\":\\\"201\\\",\\\"pass_ref\\\":\\\"secret:shared_sip\\\"}\"}",
                 sess)
            .find("{\"ok\":true}") != std::string::npos);
  CHECK(adminReq(http_port, "DELETE", "/api/secrets",
                 "{\"secret_ref\":\"secret:shared_sip\"}", sess)
            .find("409") != std::string::npos);
  CHECK(secure_values["shared_sip"] == "shared-value");
  CHECK(adminReq(http_port, "POST", "/api/config/delete",
                 "{\"key\":\"sip.accounts.shared\"}", sess)
            .find("{\"ok\":true}") != std::string::npos);
  CHECK(adminReq(http_port, "DELETE", "/api/secrets",
                 "{\"secret_ref\":\"secret:shared_sip\"}", sess)
            .find("{\"ok\":true}") != std::string::npos);
  CHECK(secure_values.count("shared_sip") == 0);


  CHECK(adminReq(http_port, "POST", "/api/config",
                 "{\"key\":\"doors.d_tmp\",\"value\":\"{\\\"label\\\":{\\\"ja\\\":\\\"仮\\\"}}\"}",
                 sess)
            .find("{\"ok\":true}") != std::string::npos);
  CHECK(adminReq(http_port, "GET", "/api/config", "", sess).find("d_tmp") != std::string::npos);
  CHECK(adminReq(http_port, "POST", "/api/config/delete", "{\"key\":\"doors.d_tmp\"}", sess)
            .find("{\"ok\":true}") != std::string::npos);
  CHECK(adminReq(http_port, "GET", "/api/config", "", sess).find("d_tmp") == std::string::npos);
  CHECK(node.configJson().find("d_tmp") == std::string::npos);

  CHECK(adminReq(http_port, "POST", "/api/config/delete", "{}", sess).find("400") !=
        std::string::npos);


  std::string imp =
      "{\"entries\":[{\"key\":\"buildings.b_x\",\"value\":{\"label\":{\"ja\":\"別館\"}}},"
      "{\"key\":\"integrations.tz_offset_min\",\"value\":480},"
      "{\"key\":\"devices.n_x.local.camera\",\"value\":{\"mjpeg_fps\":12}}]}";
  std::string ir = adminReq(http_port, "POST", "/api/config/import", imp, sess);
  CHECK(ir.find("\"ok\":true") != std::string::npos);
  CHECK(ir.find("\"n\":3") != std::string::npos);
  std::string cfg = adminReq(http_port, "GET", "/api/config", "", sess);
  CHECK(cfg.find("別館") != std::string::npos);
  CHECK(cfg.find("480") != std::string::npos);
  CHECK(cfg.find("\"mjpeg_fps\":12") != std::string::npos);

  CHECK(adminReq(http_port, "POST", "/api/config/import", "{}", sess).find("400") !=
        std::string::npos);

  // ---- batch: all operations validate before one CRDT/storage commit ----
  const std::string ui_base =
      "devices." + node.nodeId() + ".local.ui.elements.";
  auto style_batch = [&ui_base](const std::string& element, const std::string& value) {
    return "{\"ops\":[{\"op\":\"set\",\"key\":\"" + ui_base + element +
           "\",\"value\":" + value + "}]}";
  };
  const std::string batch =
      "{\"ops\":[{\"op\":\"set\",\"key\":\"ui.call_flow\","
      "\"value\":\"ring_then_purpose\"},{\"op\":\"set\","
      "\"key\":\"" + ui_base + "call.primary\","
      "\"value\":{\"scale\":1.25,\"background\":\"#123456\"}},"
      "{\"op\":\"delete\",\"key\":\"buildings.b_x\"}]}";
  auto batch_result = bodyJson(adminReq(http_port, "POST", "/api/config/batch", batch, sess));
  REQUIRE(batch_result);
  CHECK(json::getBool(batch_result.get(), "ok"));
  CHECK(json::getInt(batch_result.get(), "n") == 3);
  CHECK_FALSE(json::getString(batch_result.get(), "revision").empty());
  const std::string after_batch = node.configJson();
  CHECK(after_batch.find("ring_then_purpose") != std::string::npos);
  CHECK(after_batch.find("#123456") != std::string::npos);
  CHECK(after_batch.find("b_x") == std::string::npos);

  CHECK(adminReq(http_port, "POST", "/api/config/batch",
                 style_batch("cancel.call",
                             R"({"scale":1.0,"foreground":"#FFFFFF","background":"#000000","border":"#FFFFFF"})"),
                 sess)
            .find("\"ok\":true") != std::string::npos);
  const std::string before_single_color = node.configJson();
  CHECK(adminReq(http_port, "POST", "/api/config/batch",
                 style_batch("cancel.call", R"({"foreground":"#000000"})"), sess)
            .find("400") != std::string::npos);
  CHECK(node.configJson() == before_single_color);
  CHECK(adminReq(http_port, "POST", "/api/config/batch",
                 style_batch("call.primary", R"({"scale":0.75})"), sess)
            .find("400") != std::string::npos);
  CHECK(adminReq(http_port, "POST", "/api/config/batch",
                 style_batch("call.primary", R"({"scale":1.75})"), sess)
            .find("400") != std::string::npos);
  CHECK(adminReq(http_port, "POST", "/api/config/batch",
                 style_batch("cancel.call", R"({"border":"#111111"})"), sess)
            .find("400") != std::string::npos);
  CHECK(node.configJson() == before_single_color);
  CHECK(adminReq(http_port, "POST", "/api/config/batch",
                 style_batch("call.primary", R"({"radius":8})"), sess)
            .find("400") != std::string::npos);
  CHECK(adminReq(http_port, "POST", "/api/config/batch",
                 "{\"ops\":[{\"op\":\"set\",\"key\":"
                 "\"devices.unknown.local.ui.elements.call.primary\","
                 "\"value\":{\"scale\":1.0}}]}", sess)
            .find("400") != std::string::npos);
  CHECK(node.configJson() == before_single_color);

  CHECK(adminReq(http_port, "POST", "/api/config/batch",
                 "{\"ops\":[{\"op\":\"set\",\"key\":"
                 "\"devices.n_x.local.recovery.helper_mode\",\"value\":\"auto\"}]}", sess)
            .find("\"ok\":true") != std::string::npos);
  const std::string before_bad_batch = node.configJson();
  CHECK(adminReq(http_port, "POST", "/api/config/batch",
                 "{\"ops\":[{\"op\":\"set\",\"key\":"
                 "\"devices.n_x.local.recovery.helper_mode\",\"value\":\"shell\"}]}", sess)
            .find("400") != std::string::npos);
  CHECK(node.configJson() == before_bad_batch);
  CHECK(adminReq(http_port, "POST", "/api/config/batch",
                 "{\"ops\":[{\"op\":\"set\",\"key\":\"x.good\",\"value\":1},"
                 "{\"op\":\"set\",\"key\":\"bad..key\",\"value\":2}]}", sess)
            .find("400") != std::string::npos);
  CHECK(node.configJson() == before_bad_batch);

  CHECK(adminReq(http_port, "POST", "/api/config/batch",
                 style_batch("sos.trigger",
                             R"({"scale":0.2,"foreground":"#777777","background":"#777777"})"),
                 sess)
            .find("400") != std::string::npos);
  CHECK(node.configJson() == before_bad_batch);

  CHECK(adminReq(http_port, "POST", "/api/config/batch",
                 "{\"ops\":[{\"op\":\"set\",\"key\":\"devices.n_x.local.ui\","
                 "\"value\":{\"elements\":{\"sos\":{\"trigger\":{\"scale\":0.1}}}}}]}", sess)
            .find("400") != std::string::npos);
  CHECK(node.configJson() == before_bad_batch);

  CHECK(adminReq(http_port, "POST", "/api/config/import",
                 "{\"entries\":[{\"key\":\"x.would_have_been_written\",\"value\":1},"
                 "{\"key\":\"" + ui_base + "cancel.call\","
                 "\"value\":{\"background\":\"#00000000\"}}]}", sess)
            .find("400") != std::string::npos);
  CHECK(node.configJson() == before_bad_batch);

  CHECK(adminReq(http_port, "POST", "/api/config/batch",
                 "{\"ops\":[{\"op\":\"set\",\"key\":"
                 "\"integrations.telegram.bot_token\",\"value\":\"must-not-leak\"}]}", sess)
            .find("400") != std::string::npos);
  CHECK(node.configJson().find("must-not-leak") == std::string::npos);
  CHECK(adminReq(http_port, "POST", "/api/config/batch",
                 "{\"ops\":[{\"op\":\"set\",\"key\":\"sip\",\"value\":{"
                 "\"accounts\":{\"nested\":{\"user\":\"201\",\"pass\":\"nested-leak\"}}}}]}",
                 sess).find("400") != std::string::npos);
  CHECK(adminReq(http_port, "POST", "/api/config/import",
                 "{\"entries\":[{\"key\":\"integrations\",\"value\":{"
                 "\"mqtt\":{\"host\":\"broker\",\"pass\":\"nested-leak\"},"
                 "\"telegram\":{\"bot_token_ref\":\"not-a-secret-ref\"}}}]}", sess)
            .find("400") != std::string::npos);
  CHECK(adminReq(http_port, "POST", "/api/config/batch",
                 "{\"ops\":[{\"op\":\"set\",\"key\":\"custom.integration\",\"value\":{"
                 "\"endpoint\":\"https://user:password@example.invalid/api\"}}]}", sess)
            .find("400") != std::string::npos);
  CHECK(adminReq(http_port, "POST", "/api/config",
                 "{\"key\":\"integrations\",\"value\":\"{\\\"web_push\\\":"
                 "{\\\"vapid_private_key\\\":\\\"direct-leak\\\"}}\"}", sess)
            .find("400") != std::string::npos);
  CHECK(node.configJson().find("nested-leak") == std::string::npos);
  CHECK(node.configJson().find("direct-leak") == std::string::npos);

  const std::string valid_media =
      R"({"front":{"schema_version":1,"kind":"ip_camera","streams":{"h264":{"url":"rtsp://192.0.2.20/live","transport":"tcp","profile":"baseline"},"mjpeg":{"url":"https://192.0.2.20/live.mjpeg"}},"secret_ref":"secret:media.front"}})";
  CHECK(adminReq(http_port, "POST", "/api/config/batch",
                 "{\"ops\":[{\"op\":\"set\",\"key\":\"media_sources\",\"value\":" +
                     valid_media + "}]}",
                 sess).find("\"ok\":true") != std::string::npos);
  const std::string before_bad_media = node.configJson();
  const std::string bad_media =
      R"({"front":{"schema_version":1,"kind":"ip_camera","streams":{"h264":{"url":"rtsp://192.0.2.20/live","transport":"tcp","profile":"baseline","authorization":"Bearer plaintext"}}}})";
  CHECK(adminReq(http_port, "POST", "/api/config/batch",
                 "{\"ops\":[{\"op\":\"set\",\"key\":\"media_sources\",\"value\":" +
                     bad_media + "}]}",
                 sess).find("400") != std::string::npos);
  CHECK(adminReq(http_port, "POST", "/api/config/import",
                 "{\"entries\":[{\"key\":\"media_sources\",\"value\":" + bad_media +
                     "}]}",
                 sess).find("400") != std::string::npos);
  node.setConfigKey("media_sources", bad_media);
  CHECK(node.configJson() == before_bad_media);
  CHECK(node.configJson().find("Bearer plaintext") == std::string::npos);
  CHECK(adminReq(http_port, "POST", "/api/config/batch",
                 "{\"ops\":[{\"op\":\"set\",\"key\":\"media_sources.front.streams\","
                 "\"value\":{\"mjpeg\":{\"url\":\"http://192.0.2.20/live\"}}}]}", sess)
            .find("400") != std::string::npos);
  const std::string encoded_url_media =
      R"({"front":{"schema_version":1,"kind":"ip_camera","streams":{"snapshot":{"url":"https://camera.invalid/s.jpg?access%255ftoken=plaintext"}},"secret_ref":"secret:media.front"}})";
  CHECK(adminReq(http_port, "POST", "/api/config/batch",
                 "{\"ops\":[{\"op\":\"set\",\"key\":\"media_sources\",\"value\":" +
                     encoded_url_media + "}]}", sess).find("400") != std::string::npos);
  const std::string semicolon_url_media =
      R"({"front":{"schema_version":1,"kind":"ip_camera","streams":{"mjpeg":{"url":"https://camera.invalid/live?quality=4;auth=plaintext"}},"secret_ref":"secret:media.front"}})";
  CHECK(adminReq(http_port, "POST", "/api/config/import",
                 "{\"entries\":[{\"key\":\"media_sources\",\"value\":" +
                     semicolon_url_media + "}]}", sess).find("400") != std::string::npos);
  node.setConfigKey("media_sources", encoded_url_media);
  CHECK(node.configJson() == before_bad_media);
  CHECK(adminReq(http_port, "POST", "/api/config/batch",
                 R"({"ops":[{"op":"set","key":"custom.camera","value":{"camera_password":"plaintext"}}]})",
                 sess).find("400") != std::string::npos);
  CHECK(adminReq(http_port, "POST", "/api/config/import",
                 R"({"entries":[{"key":"custom.sender","value":{"sender_credential":"plaintext"}}]})",
                 sess).find("400") != std::string::npos);
  node.setConfigKey("custom.integration", R"({"foo_token":"plaintext"})");
  CHECK(node.configJson().find("foo_token") == std::string::npos);

  CHECK(adminReq(http_port, "POST", "/api/config",
                 R"({"key":"custom.integration.password_ref","value":"\"plaintext\""})",
                 sess).find("400") != std::string::npos);
  CHECK(adminReq(http_port, "POST", "/api/config/batch",
                 R"({"ops":[{"op":"set","key":"custom.integration.api-key-ref","value":"plaintext"}]})",
                 sess).find("400") != std::string::npos);
  CHECK(adminReq(http_port, "POST", "/api/config/import",
                 R"({"entries":[{"key":"custom.integration.authorization.ref","value":"plaintext"}]})",
                 sess).find("400") != std::string::npos);
  node.setConfigKey("custom.integration.credential_ref", "\"plaintext\"");
  CHECK(node.configJson().find("credential_ref") == std::string::npos);
  node.setConfigKey("custom.integration.basic_auth", "\"plaintext\"");
  CHECK(node.configJson().find("basic_auth") == std::string::npos);
  CHECK(adminReq(http_port, "POST", "/api/config",
                 R"({"key":"custom.integration.password_ref","value":"\"secret:custom.password\""})",
                 sess).find("\"ok\":true") != std::string::npos);

  CHECK(adminReq(http_port, "POST", "/api/config/batch",
                 R"({"ops":[{"op":"set","key":"custom.fragment","value":"https://service.invalid/callback#access_token=plaintext"}]})",
                 sess).find("400") != std::string::npos);
  CHECK(adminReq(http_port, "POST", "/api/config/import",
                 R"({"entries":[{"key":"custom.fragment","value":"https://service.invalid/#view=1;basic_auth=plaintext"}]})",
                 sess).find("400") != std::string::npos);
  std::string encoded_separator = "%5f";
  for (int pass = 1; pass < 8; ++pass)
    encoded_separator = "%25" + encoded_separator.substr(1);
  node.setConfigKey("custom.fragment",
                    "\"https://service.invalid/#access" + encoded_separator +
                        "token=plaintext\"");
  CHECK(node.configJson().find("access" + encoded_separator + "token") ==
        std::string::npos);
  node.setConfigKey(
      "devices",
      R"({"other":{"role":"indoor_panel","local":{"ui":{"elements":{"sos.trigger":{"scale":0.1}}}}}})");
  CHECK(node.configJson().find("\"scale\":0.1") == std::string::npos);

  // Subscription records are writable only in the Core-generated sealed schema. A raw endpoint
  // with an auth_ref must not bypass the generic secret scanner through any config entry point.
  const std::string push_record_key =
      "web_push.subscriptions.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  const std::string raw_push_record =
      R"({"subscription":{"endpoint":"https://push.invalid/capability","keys":{"p256dh":"public","auth_ref":"secret:webpush.auth"}},"group":"all"})";
  auto raw_push_direct = json::obj();
  json::set(raw_push_direct.get(), "key", push_record_key);
  json::set(raw_push_direct.get(), "value", raw_push_record);
  CHECK(adminReq(http_port, "POST", "/api/config", json::dump(raw_push_direct.get()), sess)
            .find("400") != std::string::npos);
  CHECK(adminReq(http_port, "POST", "/api/config/batch",
                 "{\"ops\":[{\"op\":\"set\",\"key\":\"" + push_record_key +
                     "\",\"value\":" + raw_push_record + "}]}", sess)
            .find("400") != std::string::npos);
  CHECK(adminReq(http_port, "POST", "/api/config/import",
                 "{\"entries\":[{\"key\":\"" + push_record_key +
                     "\",\"value\":" + raw_push_record + "}]}", sess)
            .find("400") != std::string::npos);
  node.setConfigKey(push_record_key, raw_push_record);
  CHECK(node.configJson().find("https://push.invalid/capability") == std::string::npos);
  CHECK(adminReq(http_port, "POST", "/api/config/batch",
                 R"({"ops":[{"op":"set","key":"web_push.subscriptions","value":{}}]})",
                 sess).find("400") != std::string::npos);


  auto jt = bodyJson(adminReq(http_port, "POST", "/api/join-token", "{}", sess));
  REQUIRE(jt);
  CHECK(json::getBool(jt.get(), "ok"));
  std::string pin = json::getString(jt.get(), "pin");
  CHECK(pin.size() == 6);
  for (char c : pin) CHECK((c >= '0' && c <= '9'));
  int64_t exp = json::getInt(jt.get(), "expires_s");
  CHECK(exp > 0);
  CHECK(exp <= 600);

  // ---- panel credential: only a secure reference is exported; a bearer is exchanged once for
  // an HttpOnly session and rotation revokes both the old secret and existing sessions. ----
  auto first_rotation = bodyJson(adminReq(http_port, "POST", "/api/panel-token/rotate", "{}", sess));
  REQUIRE(first_rotation);
  const std::string old_tok = json::getString(first_rotation.get(), "token");
  REQUIRE(old_tok.size() == 32);
  const std::string old_panel_session = panelLogin(http_port, old_tok);
  CHECK(node.configJson().find(old_tok) == std::string::npos);
  CHECK(node.configJson().find("panel.access.") != std::string::npos);
  CHECK(node.configJson().find("\"tokens\"") == std::string::npos);
  CHECK(adminReq(http_port, "GET", "/api/panel/state?k=" + old_tok).find("403") !=
        std::string::npos);
  CHECK(adminReq(http_port, "GET", "/api/panel/state", "", "dbpanel=" + old_panel_session)
            .find("HTTP/1.1 200") == 0);
  const std::string valid_vapid_public =
      "BGsX0fLhLEJH-Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT-NC4v4af5uO5-tKfA-eFivOM1drMV7Oy7ZAaDe_UfU";
  const std::string invalid_vapid_public =
      "BAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
  const std::string off_curve_vapid_public =
      "BGsX0fLhLEJH-Lzm5WOkQPJ3A32BLeszoPShOUXYmMKXT-NC4v4af5uO5-tKfA-eFivOM1drMV7Oy7ZAaDe_UfU";
  node.setConfigKey("integrations.web_push.vapid_public_key", "\"x\"");
  CHECK(adminReq(http_port, "GET", "/api/panel/push-vapid-public-key", "",
                 "dbpanel=" + old_panel_session).find("501") != std::string::npos);
  node.setConfigKey("integrations.web_push.vapid_public_key",
                    "\"" + off_curve_vapid_public + "\"");
  CHECK(adminReq(http_port, "GET", "/api/panel/push-vapid-public-key", "",
                 "dbpanel=" + old_panel_session).find("501") != std::string::npos);
  node.setConfigKey("integrations.web_push.vapid_public_key",
                    "\"" + valid_vapid_public + "\"");
  CHECK(adminReq(http_port, "GET", "/api/panel/push-vapid-public-key", "",
                 "dbpanel=" + old_panel_session)
            .find("\"public_key\":\"" + valid_vapid_public + "\"") != std::string::npos);
  node.setConfigKey("integrations.web_push.vapid_public_key",
                    "\"" + invalid_vapid_public + "\"");
  CHECK(adminReq(http_port, "GET", "/api/panel/push-vapid-public-key", "",
                 "dbpanel=" + old_panel_session).find("501") != std::string::npos);
  node.setConfigKey("integrations.web_push.vapid_public_key",
                    "\"" + valid_vapid_public + "\"");
  const std::string push_body =
      "{\"subscription\":{\"endpoint\":\"https://push.example/sub/one\","
      "\"keys\":{\"p256dh\":\"client-key\",\"auth\":\"auth-key\"}},"
      "\"page\":\"/panel/monitor.html\",\"group\":\"guards\"}";
  CHECK(adminReq(http_port, "POST", "/api/panel/push-subscription", push_body,
                 "dbpanel=" + old_panel_session).find("\"subscriptions\":1") != std::string::npos);
  const std::string sealed_push_config = node.configJson();
  CHECK(sealed_push_config.find("sealed_subscription") != std::string::npos);
  CHECK(sealed_push_config.find("https://push.example/sub/one") == std::string::npos);
  CHECK(sealed_push_config.find("client-key") == std::string::npos);
  CHECK(sealed_push_config.find("auth-key") == std::string::npos);

  secure_values["webpush.private"] = "private-vapid-material";
  node.setConfigKey("integrations.web_push.vapid_private_key_ref",
                    "\"secret:webpush.private\"");
  node.setConfigKey("integrations.web_push.vapid_subject",
                    "\"mailto:doorbell@example.com\"");
  node.setConfigKey("integrations.web_push.sender_secret_ref",
                    "\"secret:webpush.sender\"");
  node.setConfigKey("integrations.web_push.sender_url", "\"https://\"");
  {
    auto status = json::parse(node.statusJson());
    REQUIRE(status);
    const cJSON* push = json::get(status.get(), "web_push");
    REQUIRE(push);
    CHECK_FALSE(json::getBool(push, "configured"));
    CHECK_FALSE(json::getBool(push, "delivery_backend"));
  }
  node.setConfigKey("integrations.web_push.sender_url",
                    "\"https://push-sender.invalid/send\"");
  for (int i = 0; i < 20; ++i) {
    auto status = json::parse(node.statusJson());
    const cJSON* push = status ? json::get(status.get(), "web_push") : nullptr;
    if (push && !json::getBool(push, "delivery_backend")) break;
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
  }
  {
    auto status = json::parse(node.statusJson());
    REQUIRE(status);
    const cJSON* push = json::get(status.get(), "web_push");
    REQUIRE(push);
    CHECK(json::getBool(push, "configured"));
    CHECK_FALSE(json::getBool(push, "local_secret_ready"));
    CHECK_FALSE(json::getBool(push, "delivery_backend"));
    CHECK(json::getString(push, "leader").empty());
  }
  CHECK(adminReq(http_port, "POST", "/api/secrets",
                 "{\"secret_ref\":\"secret:webpush.sender\",\"value\":\"sender-bearer\"}",
                 sess).find("{\"ok\":true}") != std::string::npos);
  for (int i = 0; i < 20; ++i) {
    auto status = json::parse(node.statusJson());
    const cJSON* push = status ? json::get(status.get(), "web_push") : nullptr;
    if (json::getBool(push, "delivery_backend")) break;
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
  }
  {
    auto status = json::parse(node.statusJson());
    REQUIRE(status);
    const cJSON* push = json::get(status.get(), "web_push");
    REQUIRE(push);
    CHECK(json::getBool(push, "configured"));
    CHECK(json::getBool(push, "local_secret_ready"));
    CHECK(json::getBool(push, "delivery_backend"));
    CHECK(json::getString(push, "leader") == node.nodeId());
  }
  node.setConfigKey(
      "trigger_rules.r_sos_default_on",
      "{\"enabled\":true,\"when\":{\"type\":\"emergency_on\"},\"actions\":[{"
      "\"type\":\"device_alert\",\"targets\":{\"roles\":[\"indoor_panel\"]},"
      "\"channels\":[\"web_push\"]}]}");
  node.setEmergency(true, "test");
  std::this_thread::sleep_for(std::chrono::milliseconds(300));
  CHECK(web_push_requests.load() == 0);  // Native-only targets never leak to Web subscribers.

  node.setEmergency(false, "test");
  std::this_thread::sleep_for(std::chrono::milliseconds(100));
  web_push_requests = 0;
  web_push_group_payload = false;
  web_push_catalog_payload = false;
  node.setConfigKey("devices." + node.nodeId() + ".local.ui_lang", "\"zh\"");
  CHECK(node.configJson().find("\"ui_lang\":\"zh\"") != std::string::npos);
  node.setConfigKey(
      "trigger_rules.r_sos_default_on",
      "{\"enabled\":true,\"when\":{\"type\":\"emergency_on\"},\"actions\":[{"
      "\"type\":\"device_alert\",\"targets\":{\"web_subscription_groups\":[\"guards\"]},"
      "\"channels\":[\"web_push\"]}]}");
  node.setEmergency(true, "test");
  for (int i = 0; i < 20 && web_push_requests.load() == 0; ++i)
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
  CHECK(web_push_requests.load() == 1);
  CHECK(web_push_group_payload.load());
  CHECK(web_push_catalog_payload.load());
  node.setEmergency(false, "test");
  CHECK(adminReq(http_port, "DELETE", "/api/panel/push-subscription",
                 "{\"endpoint\":\"https://push.example/sub/one\"}",
                 "dbpanel=" + old_panel_session)
            .find("{\"ok\":true}") != std::string::npos);
  CHECK(node.configJson().find("https://push.example/sub/one") == std::string::npos);
  auto rot = bodyJson(adminReq(http_port, "POST", "/api/panel-token/rotate", "{}", sess));
  REQUIRE(rot);
  CHECK(json::getBool(rot.get(), "ok"));
  std::string new_tok = json::getString(rot.get(), "token");
  CHECK(new_tok.size() == 32);
  CHECK(new_tok != old_tok);
  bool old_secret_still_present = false;
  for (const auto& item : secure_values)
    old_secret_still_present = old_secret_still_present || item.second == old_tok;
  CHECK_FALSE(old_secret_still_present);
  CHECK(adminReq(http_port, "GET", "/api/panel/state", "", "dbpanel=" + old_panel_session)
            .find("403") !=
        std::string::npos);
  const std::string new_panel_session = panelLogin(http_port, new_tok);
  CHECK(adminReq(http_port, "GET", "/api/panel/state", "", "dbpanel=" + new_panel_session)
            .find("HTTP/1.1 200") == 0);

  node.stop();
}

TEST_CASE("admin API: failed panel rotation keeps the previous fleet credential atomic") {
  std::mt19937 rng(static_cast<uint32_t>(::getpid()) ^ 0x5a70u);
  const int mesh_port = adminFreePort(rng);
  int http_port = adminFreePort(rng);
  while (http_port == mesh_port) http_port = adminFreePort(rng);
  REQUIRE(mesh_port > 0);
  REQUIRE(http_port > 0);
  const std::string dir = adminTempDir();

  NodeOptions options;
  options.data_dir = dir;
  options.name = "panel-rotation-durability";
  options.role = "indoor_panel";
  options.listen_addr = "127.0.0.1:" + std::to_string(mesh_port);
  options.psk.fill(0x59);
  options.enable_beacon = false;
  options.http_port = http_port;
  options.mesh_timing_template = adminTiming();
  options.use_mesh_timing_template = true;

  Node node(options);
  std::map<std::string, std::string> secure_values;
  node.setSecureStore(
      [&](const std::string& key) {
        auto it = secure_values.find(key);
        return it == secure_values.end() ? std::string() : it->second;
      },
      [&](const std::string& key, const std::string& value) {
        if (value.empty()) secure_values.erase(key);
        else secure_values[key] = value;
        return true;
      });
  REQUIRE(node.start());
  const std::string admin_session = adminLogin(http_port);
  auto first_rotation = bodyJson(adminReq(
      http_port, "POST", "/api/panel-token/rotate", "{}", admin_session));
  REQUIRE(first_rotation);
  const std::string token = json::getString(first_rotation.get(), "token");
  REQUIRE(token.size() == 32);
  const std::string panel_session = panelLogin(http_port, token);
  const std::string config_before =
      adminReq(http_port, "GET", "/api/config", "", admin_session);
  REQUIRE(config_before.find("token_generation") != std::string::npos);

  REQUIRE(setAdminConfigWriteFailure(dir + "/doorbell.db", true));
  const std::string failed_rotation = adminReq(
      http_port, "POST", "/api/panel-token/rotate", "{}", admin_session);
  CHECK(failed_rotation.find("HTTP/1.1 500") == 0);
  CHECK(failed_rotation.find("config_persistence_failed") != std::string::npos);
  REQUIRE(setAdminConfigWriteFailure(dir + "/doorbell.db", false));

  CHECK(adminReq(http_port, "GET", "/api/config", "", admin_session) == config_before);
  CHECK(adminReq(http_port, "GET", "/api/panel/state", "",
                 "dbpanel=" + panel_session).find("HTTP/1.1 200") == 0);
  CHECK(secure_values.size() == 1);
  CHECK(secure_values.begin()->second == token);
  node.stop();
  removeAdminTempDir(dir);
}

TEST_CASE("admin API: panel sessions follow replicated rotation and per-node provisioning") {
  std::mt19937 rng(static_cast<uint32_t>(::getpid()) ^ 0x5a71u);
  std::vector<int> ports;
  auto nextPort = [&] {
    for (;;) {
      const int port = adminFreePort(rng);
      if (port <= 0 || std::find(ports.begin(), ports.end(), port) != ports.end()) continue;
      ports.push_back(port);
      return port;
    }
  };
  const int mesh_a = nextPort();
  const int mesh_b = nextPort();
  const int http_a = nextPort();
  const int http_b = nextPort();

  NodeOptions a_options;
  a_options.data_dir = ":memory:";
  a_options.name = "panel-primary";
  a_options.role = "indoor_panel";
  a_options.listen_addr = "127.0.0.1:" + std::to_string(mesh_a);
  a_options.advertise_addr = a_options.listen_addr;
  a_options.psk.fill(0x5a);
  a_options.enable_beacon = false;
  a_options.http_port = http_a;
  a_options.seed_default_config = true;
  a_options.mesh_timing_template = adminTiming();
  a_options.use_mesh_timing_template = true;

  NodeOptions b_options = a_options;
  b_options.name = "panel-failover";
  b_options.listen_addr = "127.0.0.1:" + std::to_string(mesh_b);
  b_options.advertise_addr = b_options.listen_addr;
  b_options.seed_peers = {a_options.listen_addr};
  b_options.http_port = http_b;
  b_options.seed_default_config = false;

  struct SecureValues {
    std::mutex mu;
    std::map<std::string, std::string> values;
  } secure_a, secure_b;
  auto installSecureStore = [](Node& node, SecureValues& secure) {
    node.setSecureStore(
        [&secure](const std::string& key) {
          std::lock_guard<std::mutex> lk(secure.mu);
          auto it = secure.values.find(key);
          return it == secure.values.end() ? std::string() : it->second;
        },
        [&secure](const std::string& key, const std::string& value) {
          std::lock_guard<std::mutex> lk(secure.mu);
          if (value.empty()) secure.values.erase(key);
          else secure.values[key] = value;
          return true;
        });
  };

  Node a(a_options);
  Node b(b_options);
  installSecureStore(a, secure_a);
  installSecureStore(b, secure_b);
  REQUIRE(a.start());
  REQUIRE(b.start());
  const std::string admin_a = adminLogin(http_a);
  const std::string admin_b = adminLogin(http_b);
  CHECK(adminReq(http_a, "POST", "/api/config",
                 R"({"key":"panel.token_generation","value":"\"invalid\""})", admin_a)
            .find("HTTP/1.1 400") == 0);

  auto waitFor = [](const std::function<bool()>& ready, int timeout_ms = 8'000) {
    const auto deadline = std::chrono::steady_clock::now() +
        std::chrono::milliseconds(timeout_ms);
    while (std::chrono::steady_clock::now() < deadline) {
      if (ready()) return true;
      std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    return ready();
  };
  auto panelRef = [](const std::string& config_json) {
    auto config = json::parse(config_json);
    const cJSON* refs = config ? json::get(json::get(config.get(), "panel"), "token_refs")
                               : nullptr;
    const cJSON* first = cJSON_IsArray(refs) ? cJSON_GetArrayItem(refs, 0) : nullptr;
    return cJSON_IsString(first) && first->valuestring ? std::string(first->valuestring)
                                                       : std::string();
  };

  auto first_rotation = bodyJson(
      adminReq(http_a, "POST", "/api/panel-token/rotate", "{}", admin_a));
  REQUIRE(first_rotation);
  const std::string first_token = json::getString(first_rotation.get(), "token");
  REQUIRE(first_token.size() == 32);
  REQUIRE(waitFor([&] {
    return b.configJson().find("panel.access.") != std::string::npos &&
        b.configJson().find("token_generation") != std::string::npos;
  }));
  const std::string first_ref = panelRef(b.configJson());
  REQUIRE_FALSE(first_ref.empty());
  CHECK(first_ref.rfind("secret:panel.access.", 0) == 0);
  CHECK(b.configJson().find(first_token) == std::string::npos);
  CHECK(adminReq(http_b, "POST", "/api/panel/session",
                 "{\"credential\":\"" + first_token + "\"}")
            .find("HTTP/1.1 403") == 0);

  const std::string provision_first =
      "{\"secret_ref\":\"" + first_ref + "\",\"token\":\"" + first_token + "\"}";
  CHECK(adminReq(http_b, "POST", "/api/panel-token/provision", provision_first)
            .find("HTTP/1.1 401") == 0);
  CHECK(adminReq(http_b, "POST", "/api/panel-token/provision",
                 "{\"secret_ref\":\"secret:panel.access.stale\",\"token\":\"" +
                     first_token + "\"}", admin_b)
            .find("HTTP/1.1 409") == 0);
  const std::string config_before_first_provision = b.configJson();
  const std::string first_provision_response =
      adminReq(http_b, "POST", "/api/panel-token/provision", provision_first, admin_b);
  CHECK(first_provision_response.find("HTTP/1.1 200") == 0);
  CHECK(first_provision_response.find("Cache-Control: no-store") != std::string::npos);
  CHECK(first_provision_response.find(first_token) == std::string::npos);
  CHECK(b.configJson() == config_before_first_provision);
  const std::string first_b_session = panelLogin(http_b, first_token);
  CHECK(adminReq(http_b, "GET", "/api/panel/state", "",
                 "dbpanel=" + first_b_session).find("HTTP/1.1 200") == 0);

  // The generic secure-store endpoint must not bypass local session revocation for an active ref.
  const std::string config_before_generic_provision = b.configJson();
  CHECK(adminReq(http_b, "POST", "/api/secrets",
                 "{\"secret_ref\":\"" + first_ref + "\",\"value\":\"" +
                     first_token + "\"}", admin_b)
            .find("HTTP/1.1 200") == 0);
  CHECK(b.configJson() == config_before_generic_provision);
  CHECK(adminReq(http_b, "GET", "/api/panel/state", "",
                 "dbpanel=" + first_b_session).find("HTTP/1.1 403") == 0);
  const std::string generic_rebound_b_session = panelLogin(http_b, first_token);

  // A generation-only fleet change must revoke cookies even when the active ref and value stay.
  const std::string generation_only = "11111111111111111111111111111111";
  a.setConfigKey("panel.token_generation", "\"" + generation_only + "\"");
  REQUIRE(waitFor([&] { return b.configJson().find(generation_only) != std::string::npos; }));
  CHECK(panelRef(b.configJson()) == first_ref);
  CHECK(adminReq(http_b, "GET", "/api/panel/state", "",
                 "dbpanel=" + generic_rebound_b_session).find("HTTP/1.1 403") == 0);
  const std::string rebound_b_session = panelLogin(http_b, first_token);

  auto second_rotation = bodyJson(
      adminReq(http_a, "POST", "/api/panel-token/rotate", "{}", admin_a));
  REQUIRE(second_rotation);
  const std::string second_token = json::getString(second_rotation.get(), "token");
  REQUIRE(second_token.size() == 32);
  REQUIRE(second_token != first_token);
  REQUIRE(waitFor([&] {
    const std::string ref = panelRef(b.configJson());
    return !ref.empty() && ref != first_ref;
  }));
  const std::string second_ref = panelRef(b.configJson());
  {
    std::lock_guard<std::mutex> lk(secure_b.mu);
    CHECK(secure_b.values[first_ref.substr(7)] == first_token);
  }
  CHECK(adminReq(http_b, "GET", "/api/panel/state", "",
                 "dbpanel=" + rebound_b_session).find("HTTP/1.1 403") == 0);
  CHECK(adminReq(http_b, "POST", "/api/panel/session",
                 "{\"credential\":\"" + first_token + "\"}")
            .find("HTTP/1.1 403") == 0);
  CHECK(adminReq(http_b, "POST", "/api/panel/session",
                 "{\"credential\":\"" + second_token + "\"}")
            .find("HTTP/1.1 403") == 0);

  const std::string config_before_failover_provision = b.configJson();
  const std::string provision_second =
      "{\"secret_ref\":\"" + second_ref + "\",\"token\":\"" + second_token + "\"}";
  CHECK(adminReq(http_b, "POST", "/api/panel-token/provision", provision_second, admin_b)
            .find("HTTP/1.1 200") == 0);
  CHECK(b.configJson() == config_before_failover_provision);
  const std::string failover_session = panelLogin(http_b, second_token);
  a.stop();
  CHECK(adminReq(http_b, "GET", "/api/panel/state", "",
                 "dbpanel=" + failover_session).find("HTTP/1.1 200") == 0);
  b.stop();
}

TEST_CASE("admin API: /api/test/telegram with a mock HttpsFn") {
  std::mt19937 rng(static_cast<uint32_t>(::getpid()) ^ 0xad32u);
  int mesh_port = adminFreePort(rng);
  int http_port = adminFreePort(rng);
  REQUIRE(mesh_port > 0);
  REQUIRE(http_port > 0);

  NodeOptions o;
  o.data_dir = ":memory:";
  o.name = "tg-admin";
  o.role = "door_station";
  o.door = "d_front";
  o.listen_addr = "127.0.0.1:" + std::to_string(mesh_port);
  o.psk.fill(0x34);
  o.enable_beacon = false;
  o.http_port = http_port;
  o.caps_json = adminTgCaps();
  o.mesh_timing_template = adminTiming();
  o.use_mesh_timing_template = true;
  Node node(o);
  AdminMockHttps https;
  node.setHttpsFn(https.fn());
  std::map<std::string, std::string> telegram_secrets{{"telegram.test", "TESTTOKEN"}};
  node.setSecureStore(
      [&](const std::string& key) {
        auto it = telegram_secrets.find(key);
        return it == telegram_secrets.end() ? std::string() : it->second;
      },
      [&](const std::string& key, const std::string& value) {
        if (value.empty()) telegram_secrets.erase(key);
        else telegram_secrets[key] = value;
        return true;
      });
  REQUIRE(node.start());
  std::string sess = adminLogin(http_port);


  CHECK(adminReq(http_port, "POST", "/api/test/telegram", "{}", sess).find("no_token") !=
        std::string::npos);

  node.setConfigKey("households.h_ox", "{\"telegram_chat_ids\":[111]}");
  node.setConfigKey("integrations.telegram.bot_token_ref", "\"secret:telegram.test\"");


  bool leader = false;
  for (int i = 0; i < 100 && !leader; i++) {
    auto st = json::parse(node.statusJson());
    if (st &&
        json::getString(json::get(st.get(), "leaders"), "telegram") == node.nodeId())
      leader = true;
    else
      usleep(50 * 1000);
  }
  REQUIRE(leader);


  CHECK(adminReq(http_port, "POST", "/api/test/telegram", "{}", sess)
            .find("{\"ok\":true}") != std::string::npos);
  bool sent = false;
  for (int i = 0; i < 100 && !sent; i++) {
    if (https.count("sendMessage", "ドアホン テスト通知") >= 1 &&
        https.count("sendMessage", "\"chat_id\":\"111\"") >= 1)
      sent = true;
    else
      usleep(50 * 1000);
  }
  CHECK(sent);


  CHECK(adminReq(http_port, "POST", "/api/test/telegram", "{\"chat_id\":\"999\"}", sess)
            .find("{\"ok\":true}") != std::string::npos);
  bool sent999 = false;
  for (int i = 0; i < 100 && !sent999; i++) {
    if (https.count("sendMessage", "\"chat_id\":\"999\"") >= 1)
      sent999 = true;
    else
      usleep(50 * 1000);
  }
  CHECK(sent999);

  node.stop();
}

TEST_CASE("admin API: /api/test/telegram returns an error on a non-leader") {
  std::mt19937 rng(static_cast<uint32_t>(::getpid()) ^ 0xad33u);
  int mesh_port = adminFreePort(rng);
  int http_port = adminFreePort(rng);
  REQUIRE(mesh_port > 0);
  REQUIRE(http_port > 0);

  NodeOptions o;
  o.data_dir = ":memory:";
  o.name = "tg-nolead";
  o.role = "indoor_panel";
  o.listen_addr = "127.0.0.1:" + std::to_string(mesh_port);
  o.psk.fill(0x35);
  o.enable_beacon = false;
  o.http_port = http_port;
  o.caps_json = "{}";
  o.mesh_timing_template = adminTiming();
  o.use_mesh_timing_template = true;
  Node node(o);
  std::map<std::string, std::string> telegram_secrets{{"telegram.test", "TESTTOKEN"}};
  node.setSecureStore(
      [&](const std::string& key) {
        auto it = telegram_secrets.find(key);
        return it == telegram_secrets.end() ? std::string() : it->second;
      },
      [&](const std::string& key, const std::string& value) {
        if (value.empty()) telegram_secrets.erase(key);
        else telegram_secrets[key] = value;
        return true;
      });
  REQUIRE(node.start());
  std::string sess = adminLogin(http_port);
  node.setConfigKey("integrations.telegram.bot_token_ref", "\"secret:telegram.test\"");
  CHECK(adminReq(http_port, "POST", "/api/test/telegram", "{}", sess).find("not_leader") !=
        std::string::npos);
  node.stop();
}

TEST_CASE("admin API: pairing routes expose state, PIN, deny, scan, retry, and unpair") {
  std::mt19937 rng(static_cast<uint32_t>(::getpid()) ^ 0x9a17u);
  int mesh_port = adminFreePort(rng);
  int http_port = adminFreePort(rng);
  REQUIRE(mesh_port > 0);
  REQUIRE(http_port > 0);

  NodeOptions o;
  o.data_dir = ":memory:";
  o.name = "pairing-http";
  o.role = "door_station";
  o.door = "d_front";
  o.listen_addr = "127.0.0.1:" + std::to_string(mesh_port);
  o.psk.fill(0x44);  // boot.json の平文鍵で起動した既存クラスタ参加済み端末。
  o.enable_beacon = false;
  o.http_port = http_port;
  o.caps_json = "{}";
  o.mesh_timing_template = adminTiming();
  o.use_mesh_timing_template = true;
  Node node(o);
  std::map<std::string, std::string> secrets;
  std::vector<std::string> deleted;
  node.setSecureStore(
      [&](const std::string& key) {
        auto it = secrets.find(key);
        return it == secrets.end() ? std::string() : it->second;
      },
      [&](const std::string& key, const std::string& value) {
        secrets[key] = value;
        return true;
      });
  node.setSecureDelete([&](const std::string& key) {
    deleted.push_back(key);
    return secrets.erase(key) > 0;
  });
  REQUIRE(node.start());

  // ペアリング系はすべて管理セッション必須。公開プレフィックスには入れない。
  for (const char* path : {"/api/pairing/start", "/api/pairing/stop", "/api/pairing/deny",
                           "/api/pairing/retry-persist", "/api/pairing/unpair",
                           "/api/pairing/scan"}) {
    CHECK(adminReq(http_port, "POST", path, "{}").find("401") != std::string::npos);
  }
  CHECK(adminReq(http_port, "GET", "/api/pairing").find("401") != std::string::npos);

  const std::string sess = adminLogin(http_port);

  {
    auto d = bodyJson(adminReq(http_port, "GET", "/api/pairing", "", sess));
    REQUIRE(d);
    CHECK(json::getString(d.get(), "state") == "ready");
    CHECK(json::getString(d.get(), "psk_source") == "boot_plaintext");
    CHECK(cJSON_IsNull(json::get(d.get(), "psk_ref")));
    CHECK(json::getString(d.get(), "pair_qr").rfind("doorbell-pair:", 0) == 0);
    CHECK(json::getInt(json::get(d.get(), "home"), "member_count", 0) == 1);
  }

  // start は「まとめて追加」の窓と PIN を一度に返す。
  std::string pin;
  {
    auto d = bodyJson(adminReq(http_port, "POST", "/api/pairing/start", "{\"seconds\":600}", sess));
    REQUIRE(d);
    CHECK(json::getBool(d.get(), "ok"));
    pin = json::getString(d.get(), "pin");
    CHECK(pin.size() == 6);
    CHECK(json::getInt(d.get(), "expires_s", 0) > 0);
    CHECK_FALSE(json::getString(d.get(), "host").empty());
  }
  {
    auto d = bodyJson(adminReq(http_port, "GET", "/api/pairing", "", sess));
    REQUIRE(d);
    const cJSON* token = json::get(d.get(), "token");
    CHECK(json::getBool(token, "active"));
    CHECK(json::getString(token, "pin") == pin);
    CHECK(json::getInt(token, "attempts_left", 0) == 3);
    CHECK(json::getBool(json::get(d.get(), "pending"), "pairing_mode"));
  }

  CHECK(json::getBool(
      bodyJson(adminReq(http_port, "POST", "/api/pairing/stop", "{}", sess)).get(), "ok"));
  {
    auto d = bodyJson(adminReq(http_port, "GET", "/api/pairing", "", sess));
    REQUIRE(d);
    CHECK_FALSE(json::getBool(json::get(d.get(), "pending"), "pairing_mode"));
    // 停止しても PIN は生きたまま（入力中の端末を締め出さない）。
    CHECK(json::getBool(json::get(d.get(), "token"), "active"));
  }

  CHECK(adminReq(http_port, "POST", "/api/pairing/deny", "{}", sess).find("400") !=
        std::string::npos);
  CHECK(json::getBool(
      bodyJson(adminReq(http_port, "POST", "/api/pairing/deny",
                        "{\"id\":\"00000000000000000000000000000001\"}", sess))
          .get(),
      "ok"));

  // 貼り付け経路。壊れた文字列は 400、正しい QR 文字列は招待として受理される。
  CHECK(adminReq(http_port, "POST", "/api/pairing/scan", "{\"text\":\"https://example.invalid\"}",
                 sess)
            .find("bad_qr") != std::string::npos);
  const std::string qr = "doorbell-pair:127.0.0.1:1|00000000000000000000000000000002|" +
                         std::string(64, 'a');
  CHECK(json::getBool(
      bodyJson(adminReq(http_port, "POST", "/api/pairing/scan", "{\"text\":\"" + qr + "\"}", sess))
          .get(),
      "ok"));

  // すでに保存済み（起動時から鍵を持っている）端末では retry-persist は何もしない冪等な
  // 成功応答になる。書き直しが要るのは persist_error のときだけ。
  CHECK(json::getBool(
      bodyJson(adminReq(http_port, "POST", "/api/pairing/retry-persist", "{}", sess)).get(), "ok"));
  CHECK(secrets.empty());
  {
    auto d = bodyJson(adminReq(http_port, "GET", "/api/pairing", "", sess));
    REQUIRE(d);
    CHECK(json::getString(d.get(), "state") == "ready");
    CHECK(json::getBool(d.get(), "persistence_ready"));
  }

  CHECK(json::getBool(bodyJson(adminReq(http_port, "POST", "/api/pairing/unpair", "{}", sess)).get(),
                      "ok"));
  CHECK(deleted == std::vector<std::string>{"mesh.psk"});
  {
    auto d = bodyJson(adminReq(http_port, "GET", "/api/pairing", "", sess));
    REQUIRE(d);
    CHECK(json::getString(d.get(), "state") == "unpaired");
    CHECK(json::getString(d.get(), "psk_source") == "none");
    CHECK_FALSE(json::getBool(d.get(), "paired"));
  }

  // クラスタ未参加の端末は「追加」できない。旧 /mode も新 /start も 409 で断る。
  CHECK(adminReq(http_port, "POST", "/api/pairing/mode", "{\"seconds\":600}", sess)
            .find("HTTP/1.1 409") == 0);
  const std::string refused =
      adminReq(http_port, "POST", "/api/pairing/start", "{\"seconds\":600}", sess);
  CHECK(refused.find("HTTP/1.1 409") == 0);
  CHECK(refused.find("host_unpaired") != std::string::npos);
  node.stop();
}
