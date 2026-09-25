
//   /api/config/delete (tombstone) / /api/config/import / /api/join-token /

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
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
#include "doorbell/doorbell.h"
#include "test_env.h"
#include "node/node.h"
#include "node/admin_sessions.h"
#include "util/json.h"
#include "util/clock.h"

using namespace db;

namespace {

std::map<std::string, std::string> admin_csrf_by_token;

int adminFreePort(std::mt19937& /*rng*/) {
  // Ports come from one process-wide allocator; see core/tests/test_ports.h.
  return db::testing::freeListenPort();
}


std::string adminReq(int port, const std::string& method, const std::string& path,
                     const std::string& body = "", const std::string& cookie = "",
                     const std::string& extra_headers = "", bool send_csrf = true) {
  int fd = ::socket(AF_INET, SOCK_STREAM, 0);
  REQUIRE(fd >= 0);
  sockaddr_in sa{};
  sa.sin_family = AF_INET;
  sa.sin_port = htons(static_cast<uint16_t>(port));
  sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  REQUIRE(::connect(fd, reinterpret_cast<sockaddr*>(&sa), sizeof(sa)) == 0);
  std::string r = method + " " + path + " HTTP/1.1\r\nHost: 127.0.0.1\r\n";
  r += extra_headers;
  if (send_csrf && method != "GET" && method != "HEAD" &&
      extra_headers.find("X-Doorbell-CSRF:") == std::string::npos) {
    const std::string token = cookie.rfind("dbsess=", 0) == 0 ? cookie.substr(7) : cookie;
    const auto csrf = admin_csrf_by_token.find(token);
    if (csrf != admin_csrf_by_token.end())
      r += "Origin: http://127.0.0.1:" + std::to_string(port) +
          "\r\nX-Doorbell-CSRF: " + csrf->second + "\r\n";
  }
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
  const std::string token = r.substr(p + 7, e - (p + 7));
  const size_t body = r.find("\r\n\r\n");
  auto response = json::parse(body == std::string::npos ? "" : r.substr(body + 4));
  REQUIRE(response);
  admin_csrf_by_token[token] = json::getString(response.get(), "csrf_token");
  REQUIRE_FALSE(admin_csrf_by_token[token].empty());
  return token;
}

std::string panelLogin(int port, const std::string& credential, std::string* csrf = nullptr) {
  std::string r = adminReq(port, "POST", "/api/panel/session",
                           "{\"credential\":\"" + credential + "\"}");
  REQUIRE(r.find("HTTP/1.1 200") == 0);
  if (csrf) {
    const size_t body = r.find("\r\n\r\n");
    auto response = json::parse(body == std::string::npos ? "" : r.substr(body + 4));
    REQUIRE(response);
    *csrf = json::getString(response.get(), "csrf_token");
    REQUIRE_FALSE(csrf->empty());
  }
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
  CHECK(video_meta.find("Access-Control-Allow-Origin: *") != std::string::npos);


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
  // A colour whose contrast falls short is the operator's choice: the write succeeds and the
  // measured ratio comes back as a warning so the admin can show it inline.
  auto low_contrast = bodyJson(adminReq(http_port, "POST", "/api/config/batch",
                                        style_batch("cancel.call",
                                                    R"({"foreground":"#000000"})"), sess));
  REQUIRE(low_contrast);
  CHECK(json::getBool(low_contrast.get(), "ok"));
  const cJSON* warnings = json::get(low_contrast.get(), "warnings");
  REQUIRE(cJSON_IsArray(warnings));
  REQUIRE(cJSON_GetArraySize(warnings) >= 1);
  const cJSON* first = cJSON_GetArrayItem(warnings, 0);
  CHECK(json::getString(first, "property") == "foreground");
  CHECK(json::getString(first, "message_key") == "theme.low_contrast");
  CHECK(json::getNum(first, "contrast") >= 1.0);
  CHECK(json::getNum(first, "contrast") < 4.5);
  CHECK(node.configJson() != before_single_color);
  CHECK(node.configJson().find("\"foreground\":\"#000000\"") != std::string::npos);

  // Format is still enforced: a colour that is not #RRGGBB is refused outright.
  const std::string before_bad_color = node.configJson();
  CHECK(adminReq(http_port, "POST", "/api/config/batch",
                 style_batch("cancel.call", R"({"foreground":"black"})"), sess)
            .find("400") != std::string::npos);
  CHECK(node.configJson() == before_bad_color);

  // Non-colour constraints are unchanged; only the contrast checks became advisory.
  CHECK(adminReq(http_port, "POST", "/api/config/batch",
                 style_batch("call.primary", R"({"scale":0.75})"), sess)
            .find("400") != std::string::npos);
  CHECK(adminReq(http_port, "POST", "/api/config/batch",
                 style_batch("call.primary", R"({"scale":1.75})"), sess)
            .find("400") != std::string::npos);
  auto low_border = bodyJson(adminReq(http_port, "POST", "/api/config/batch",
                                      style_batch("cancel.call", R"({"border":"#111111"})"),
                                      sess));
  REQUIRE(low_border);
  CHECK(json::getBool(low_border.get(), "ok"));
  CHECK(cJSON_IsArray(json::get(low_border.get(), "warnings")));
  // A comfortable set produces no warning at all. Every colour of the element is written here
  // because the check runs against the resolved element, not against this write alone.
  auto readable = bodyJson(adminReq(http_port, "POST", "/api/config/batch",
                                    style_batch("cancel.call",
                                                R"({"foreground":"#FFFFFF","background":"#000000","border":"#FFFFFF"})"),
                                    sess));
  REQUIRE(readable);
  CHECK(json::getBool(readable.get(), "ok"));
  CHECK(json::get(readable.get(), "warnings") == nullptr);
  const std::string before_single_color_2 = node.configJson();
  CHECK(adminReq(http_port, "POST", "/api/config/batch",
                 style_batch("call.primary", R"({"radius":8})"), sess)
            .find("400") != std::string::npos);
  CHECK(adminReq(http_port, "POST", "/api/config/batch",
                 "{\"ops\":[{\"op\":\"set\",\"key\":"
                 "\"devices.unknown.local.ui.elements.call.primary\","
                 "\"value\":{\"scale\":1.0}}]}", sess)
            .find("400") != std::string::npos);
  CHECK(node.configJson() == before_single_color_2);

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
  const std::string admin_a = adminLogin(http_a);
  auto waitFor = [](const std::function<bool()>& ready, int timeout_ms = 8'000) {
    const auto deadline = std::chrono::steady_clock::now() +
        std::chrono::milliseconds(timeout_ms);
    while (std::chrono::steady_clock::now() < deadline) {
      if (ready()) return true;
      std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    return ready();
  };
  const auto initial_config = json::parse(a.configJson());
  const auto initial_password = json::dump(json::get(json::get(initial_config.get(), "admin"),
                                                    "password_hash"));
  REQUIRE(initial_password != "null");
  REQUIRE(b.start());
  // Initialize one cluster credential before issuing sessions on the second node. Otherwise
  // concurrent first logins can correctly revoke the losing credential version's session.
  REQUIRE(waitFor([&] {
    const auto replicated = json::parse(b.configJson());
    return json::dump(json::get(json::get(replicated.get(), "admin"), "password_hash")) ==
        initial_password;
  }));
  const std::string admin_b = adminLogin(http_b);
  CHECK(adminReq(http_a, "POST", "/api/config",
                 R"({"key":"panel.token_generation","value":"\"invalid\""})", admin_a)
            .find("HTTP/1.1 400") == 0);
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
  CHECK(adminReq(http_port, "GET", "/api/pairing", "", sess).find("401") != std::string::npos);
  const std::string unpaired_session = adminLogin(http_port);
  {
    auto d = bodyJson(adminReq(http_port, "GET", "/api/pairing", "", unpaired_session));
    REQUIRE(d);
    CHECK(json::getString(d.get(), "state") == "unpaired");
    CHECK(json::getString(d.get(), "psk_source") == "none");
    CHECK_FALSE(json::getBool(d.get(), "paired"));
  }

  // クラスタ未参加の端末は「追加」できない。旧 /mode も新 /start も 409 で断る。
  CHECK(adminReq(http_port, "POST", "/api/pairing/mode", "{\"seconds\":600}", unpaired_session)
            .find("HTTP/1.1 409") == 0);
  const std::string refused =
      adminReq(http_port, "POST", "/api/pairing/start", "{\"seconds\":600}", unpaired_session);
  CHECK(refused.find("HTTP/1.1 409") == 0);
  CHECK(refused.find("host_unpaired") != std::string::npos);
  node.stop();
}

TEST_CASE("admin API: announcements and the manual time sync enforce their own callers") {
  std::mt19937 rng(static_cast<uint32_t>(::getpid()) ^ 0x7c19u);
  const int mesh_port = adminFreePort(rng);
  const int http_port = adminFreePort(rng);
  REQUIRE(mesh_port > 0);
  REQUIRE(http_port > 0);

  NodeOptions options;
  options.data_dir = ":memory:";
  options.name = "notice-api";
  options.role = "door_station";
  options.door = "d_front";
  options.listen_addr = "127.0.0.1:" + std::to_string(mesh_port);
  options.psk.fill(0x71);
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
        secure_values[key] = value;
        return true;
      });
  REQUIRE(node.start());
  const std::string session = adminLogin(http_port);
  node.setConfigKey("doors.d_front", "{\"label\":{\"ja\":\"正面玄関\"}}");

  // No session and no panel credential: refused before anything is written.
  CHECK(adminReq(http_port, "POST", "/api/doors/d_front/notice", "{\"text\":\"hi\"}")
            .find("HTTP/1.1 403") == 0);
  // A path that is not the notice resource is not reachable through the prefix route.
  CHECK(adminReq(http_port, "POST", "/api/doors/d_front", "{\"text\":\"hi\"}", session)
            .find("HTTP/1.1 404") == 0);
  CHECK(adminReq(http_port, "POST", "/api/doors/d_front/../secrets", "{}", session)
            .find("HTTP/1.1 200") != 0);

  auto published = bodyJson(adminReq(http_port, "POST", "/api/doors/d_front/notice",
                                     "{\"text\":\"Side gate today\",\"ttl_s\":3600}", session));
  REQUIRE(published);
  CHECK(json::getBool(published.get(), "ok"));
  auto config = json::parse(node.configJson());
  REQUIRE(config);
  const cJSON* notice =
      json::get(json::get(json::get(config.get(), "doors"), "d_front"), "notice");
  REQUIRE(cJSON_IsObject(notice));
  CHECK(json::getString(notice, "text") == "Side gate today");
  CHECK(json::getInt(notice, "expires_ms") > 0);

  // An oversized announcement is refused and leaves the current one untouched.
  CHECK(adminReq(http_port, "POST", "/api/doors/d_front/notice",
                 "{\"text\":\"" + std::string(201, 'x') + "\"}", session)
            .find("HTTP/1.1 400") == 0);
  CHECK(adminReq(http_port, "POST", "/api/doors/d_unknown/notice", "{\"text\":\"hi\"}", session)
            .find("HTTP/1.1 400") == 0);

  // An indoor panel publishes with its panel credential, which is the same dialog as the web.
  auto rotation =
      bodyJson(adminReq(http_port, "POST", "/api/panel-token/rotate", "{}", session));
  REQUIRE(rotation);
  const std::string credential = json::getString(rotation.get(), "token");
  REQUIRE(credential.size() == 32);
  std::string panel_csrf;
  const std::string panel_session = panelLogin(http_port, credential, &panel_csrf);
  CHECK(adminReq(http_port, "POST", "/api/doors/d_front/notice",
                 "{\"text\":\"From the indoor panel\"}", "dbpanel=" + panel_session)
            .find("HTTP/1.1 403") == 0);
  CHECK(adminReq(http_port, "POST", "/api/doors/d_front/notice",
                 "{\"text\":\"From the indoor panel\"}", "dbpanel=" + panel_session,
                 "Origin: http://127.0.0.1:" + std::to_string(http_port) +
                     "\r\nX-Doorbell-CSRF: " + panel_csrf + "\r\n")
            .find("HTTP/1.1 200") == 0);
  CHECK(node.configJson().find("From the indoor panel") != std::string::npos);

  CHECK(adminReq(http_port, "DELETE", "/api/doors/d_front/notice", "", session)
            .find("HTTP/1.1 200") == 0);
  CHECK(node.configJson().find("From the indoor panel") == std::string::npos);

  // The manual sync button reports a clear reason instead of pretending to work while the
  // independent time service is switched off.
  auto refused = bodyJson(adminReq(http_port, "POST", "/api/time/sync", "{}", session));
  REQUIRE(refused);
  CHECK_FALSE(json::getBool(refused.get(), "ok"));
  CHECK(json::getString(refused.get(), "err") == "ntp_disabled");
  CHECK(adminReq(http_port, "POST", "/api/time/sync", "{}").find("HTTP/1.1 401") == 0);

  auto status = bodyJson(adminReq(http_port, "GET", "/api/status", "", session));
  REQUIRE(status);
  const cJSON* time = json::get(status.get(), "time");
  REQUIRE(cJSON_IsObject(time));
  CHECK(json::getString(time, "zone") == "Asia/Tokyo");
  CHECK(json::getString(time, "source") == "system");
  CHECK(json::getBool(time, "enabled") == false);
  CHECK(json::getInt(time, "offset_min") == 540);
  CHECK(cJSON_IsObject(json::get(time, "local")));
  node.stop();
}

TEST_CASE("T03: unlock requires the selected door's explicit command") {
  std::mt19937 rng(0x703u);
  const int http_port = adminFreePort(rng);
  NodeOptions options;
  options.data_dir = ":memory:";
  options.name = "T03-unlock-test";
  options.role = "door_station";
  options.door = "d_front";
  options.listen_addr = "127.0.0.1:" + std::to_string(adminFreePort(rng));
  options.psk.fill(0x73);
  options.enable_beacon = false;
  options.http_port = http_port;
  Node node(options);
  REQUIRE(node.start());
  const std::string session = adminLogin(http_port);
  node.setConfigKey("time.ntp.enabled", "false");
  node.setConfigKey("doors.d_front", "{\"label\":{\"en\":\"Front\"}}");
  node.setConfigKey("doors.d_back", "{\"label\":{\"en\":\"Back\"}}");
  node.setConfigKey("sip.dtmf_actions",
      "{\"*1\":{\"type\":\"ha_command\",\"command\":\"light_on\",\"door\":\"self\"}}");

  auto unlock = [&] {
    auto status = bodyJson(adminReq(http_port, "GET", "/api/status", "", session));
    REQUIRE(status);
    return json::Doc(cJSON_Duplicate(json::get(
        json::get(json::get(status.get(), "doors"), "d_front"), "unlock"), 1));
  };
  auto commands = [&] {
    auto events = bodyJson(adminReq(http_port, "GET", "/api/events?type=dtmf_action",
                                    "", session));
    REQUIRE(events);
    return json::Doc(cJSON_Duplicate(json::get(events.get(), "events"), 1));
  };
  auto rejected = [&] {
    const auto response = adminReq(http_port, "POST", "/api/doors/d_front/open", "{}",
                                   session);
    CHECK(response.find("HTTP/1.1 409") == 0);
    const auto body = bodyJson(response);
    REQUIRE(body);
    CHECK_FALSE(json::getBool(body.get(), "ok"));
    CHECK(json::getString(body.get(), "err") == "unlock_not_configured");
    CHECK(cJSON_GetArraySize(commands().get()) == 0);
  };

  SUBCASE("T03-01: a light feature code is not an unlock binding") {
    CHECK_FALSE(json::getBool(unlock().get(), "configured"));
    CHECK_FALSE(json::getBool(unlock().get(), "show_button"));
    CHECK_FALSE(node.openDoor("d_front"));
    rejected();
  }
  SUBCASE("T03-02: removing front binding never selects back or a feature code") {
    node.setConfigKey("doors.d_front.unlock.command", "\"front_gate\"");
    node.setConfigKey("doors.d_back.unlock.command", "\"back_gate\"");
    auto removed = json::parse(node.deleteConfigKeyJson("doors.d_front.unlock.command"));
    REQUIRE(removed);
    REQUIRE(json::getBool(removed.get(), "ok"));
    CHECK_FALSE(json::getBool(unlock().get(), "configured"));
    rejected();
  }
  SUBCASE("T03-03: one request emits only the selected door command once") {
    node.setConfigKey("doors.d_front.unlock.command", "\"front_gate\"");
    node.setConfigKey("doors.d_back.unlock.command", "\"back_gate\"");
    CHECK(json::getBool(unlock().get(), "configured"));
    CHECK(json::getString(unlock().get(), "command") == "front_gate");
    const auto response = adminReq(http_port, "POST", "/api/doors/d_front/open", "{}",
                                   session);
    CHECK(response.find("HTTP/1.1 200") == 0);
    const auto emitted = commands();
    REQUIRE(cJSON_GetArraySize(emitted.get()) == 1);
    const auto event = cJSON_GetArrayItem(emitted.get(), 0);
    CHECK(json::getString(event, "door") == "d_front");
    const auto payload = json::parse(json::getString(event, "payload"));
    REQUIRE(payload);
    CHECK(json::getString(payload.get(), "command") == "front_gate");
  }
  SUBCASE("T03-04: forced visibility never authorizes an unconfigured unlock") {
    node.setConfigKey("doors.d_front.unlock.show_button", "true");
    CHECK(json::getBool(unlock().get(), "show_button"));
    CHECK_FALSE(json::getBool(unlock().get(), "configured"));
    rejected();
  }
  auto config = json::parse(node.configJson());
  REQUIRE(config);
  CHECK(json::getString(json::get(json::get(json::get(config.get(), "sip"),
      "dtmf_actions"), "*1"), "command") == "light_on");
  node.stop();
}

TEST_CASE("T03: native ABI unlock rejects feature codes and shares the explicit binding") {
  db_platform_v2 platform{};
  platform.struct_size = sizeof(platform);
  platform.version = DB_PLATFORM_V2_VERSION;
  db_core* core = db_core_create_v2(&platform, ":memory:",
      "{\"name\":\"T03-native-test\",\"role\":\"indoor_panel\","
      "\"listen_port\":0,\"http_port\":0}");
  REQUIRE(core != nullptr);
  std::atomic<int> dispatches{0};
  db_core_set_ui_callback(core, [](void* context, const char* raw) {
    auto event = json::parse(raw);
    if (event && json::getString(event.get(), "t") == "event" &&
        json::getString(event.get(), "type") == "dtmf_action")
      static_cast<std::atomic<int>*>(context)->fetch_add(1);
  }, &dispatches);
  REQUIRE(db_core_start(core) == 0);
  REQUIRE(db_core_set_config_json(core, "time.ntp.enabled", "false") == 0);
  REQUIRE(db_core_set_config_json(core, "doors.d_front",
      "{\"label\":{\"en\":\"Front\"},\"unlock\":{\"show_button\":true}}") == 0);
  REQUIRE(db_core_set_config_json(core, "sip.dtmf_actions",
      "{\"*1\":{\"type\":\"ha_command\",\"command\":\"light_on\",\"door\":\"self\"}}") == 0);
  auto snapshotBarrier = [&] {
    // This synchronous read queues after the config change's published-snapshot update.
    char* snapshot = db_core_pairing_json(core);
    REQUIRE(snapshot != nullptr);
    db_free(snapshot);
  };
  snapshotBarrier();
  CHECK(db_core_open_door(core, "d_front") == -3);
  CHECK(dispatches.load() == 0);
  REQUIRE(db_core_set_config_json(core, "doors.d_front.unlock.command", "\"front_gate\"") == 0);
  snapshotBarrier();
  CHECK(db_core_open_door(core, "d_front") == 0);
  CHECK(dispatches.load() == 1);
  REQUIRE(db_core_delete_config_key(core, "doors.d_front.unlock.command") == 0);
  snapshotBarrier();
  CHECK(db_core_open_door(core, "d_front") == -3);
  CHECK(dispatches.load() == 1);
  db_core_set_ui_callback(core, nullptr, nullptr);
  db_core_stop(core);
  db_core_destroy(core);
}

TEST_CASE("admin API: the cluster-wide notice, the unlock trigger, and PIN minting") {
  std::mt19937 rng(static_cast<uint32_t>(::getpid()) ^ 0x51a2u);
  const int mesh_port = adminFreePort(rng);
  const int http_port = adminFreePort(rng);
  REQUIRE(mesh_port > 0);
  REQUIRE(http_port > 0);

  NodeOptions options;
  options.data_dir = ":memory:";
  options.name = "round4-api";
  options.role = "door_station";
  options.door = "d_front";
  options.listen_addr = "127.0.0.1:" + std::to_string(mesh_port);
  options.psk.fill(0x64);
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
        secure_values[key] = value;
        return true;
      });
  REQUIRE(node.start());
  const std::string session = adminLogin(http_port);
  node.setConfigKey("doors.d_front", "{\"label\":{\"ja\":\"正面玄関\"}}");

  CHECK(adminReq(http_port, "POST", "/api/emergency", R"({"active":true})", session)
            .find("HTTP/1.1 200") == 0);
  CHECK(adminReq(http_port, "POST", "/api/emergency", R"({"active":false})", session,
                 "", false).find("HTTP/1.1 403") == 0);
  auto emergency_status = bodyJson(adminReq(http_port, "GET", "/api/status", "", session));
  REQUIRE(emergency_status);
  CHECK(json::getBool(json::get(emergency_status.get(), "emergency"), "active"));
  CHECK(adminReq(http_port, "POST", "/api/emergency", R"({"active":false})", session,
                 "Origin: https://untrusted.invalid\r\nX-Doorbell-CSRF: " +
                     admin_csrf_by_token.at(session) + "\r\n")
            .find("HTTP/1.1 403") == 0);
  emergency_status = bodyJson(adminReq(http_port, "GET", "/api/status", "", session));
  REQUIRE(emergency_status);
  CHECK(json::getBool(json::get(emergency_status.get(), "emergency"), "active"));
  CHECK(adminReq(http_port, "POST", "/api/emergency", R"({"active":false})", session)
            .find("HTTP/1.1 200") == 0);
  emergency_status = bodyJson(adminReq(http_port, "GET", "/api/status", "", session));
  REQUIRE(emergency_status);
  CHECK_FALSE(json::getBool(json::get(emergency_status.get(), "emergency"), "active"));

  // The cluster-wide announcement is its own resource, not a bulk per-door write.
  CHECK(adminReq(http_port, "POST", "/api/notice", "{\"text\":\"House message\"}")
            .find("HTTP/1.1 403") == 0);
  CHECK(adminReq(http_port, "POST", "/api/notice", "{\"text\":\"House message\"}",
                 session, "", false).find("HTTP/1.1 403") == 0);
  CHECK(adminReq(http_port, "POST", "/api/notice", "{\"text\":\"House message\"}", session)
            .find("HTTP/1.1 200") == 0);
  CHECK(node.configJson().find("House message") != std::string::npos);
  auto status = bodyJson(adminReq(http_port, "GET", "/api/status", "", session));
  REQUIRE(status);
  const cJSON* front = json::get(json::get(status.get(), "doors"), "d_front");
  REQUIRE(cJSON_IsObject(front));
  CHECK(json::getString(json::get(front, "notice"), "text") == "House message");
  CHECK(json::getString(json::get(front, "notice"), "scope") == "global");
  CHECK(json::getBool(json::get(status.get(), "notice"), "global_active"));
  CHECK(adminReq(http_port, "POST", "/api/notice",
                 "{\"text\":\"" + std::string(201, 'x') + "\"}", session)
            .find("HTTP/1.1 400") == 0);
  CHECK(adminReq(http_port, "DELETE", "/api/notice", "", session).find("HTTP/1.1 200") == 0);
  CHECK(node.configJson().find("House message") == std::string::npos);

  // The unlock trigger refuses clearly when nothing is configured, rather than reporting a
  // success that did nothing.
  auto unconfigured = bodyJson(adminReq(http_port, "POST", "/api/doors/d_front/open", "{}",
                                        session));
  REQUIRE(unconfigured);
  CHECK_FALSE(json::getBool(unconfigured.get(), "ok"));
  CHECK(json::getString(unconfigured.get(), "err") == "unlock_not_configured");
  CHECK(adminReq(http_port, "POST", "/api/doors/d_missing/open", "{}", session)
            .find("HTTP/1.1 404") == 0);
  CHECK(adminReq(http_port, "POST", "/api/doors/d_front/open", "{}").find("HTTP/1.1 403") == 0);

  node.setConfigKey(
      "sip.dtmf_actions",
      "{\"*1\":{\"type\":\"ha_command\",\"command\":\"unlock\",\"door\":\"self\"}}");
  CHECK(adminReq(http_port, "POST", "/api/doors/d_front/open", "{}", session)
            .find("HTTP/1.1 409") == 0);
  node.setConfigKey("doors.d_front.unlock.command", "\"unlock\"");
  auto unlock_events = bodyJson(adminReq(http_port, "GET", "/api/events?type=dtmf_action",
                                          "", session));
  REQUIRE(unlock_events);
  CHECK(cJSON_GetArraySize(json::get(unlock_events.get(), "events")) == 0);
  CHECK(adminReq(http_port, "POST", "/api/doors/d_front/open", "{}", session,
                 "", false).find("HTTP/1.1 403") == 0);
  unlock_events = bodyJson(adminReq(http_port, "GET", "/api/events?type=dtmf_action",
                                    "", session));
  REQUIRE(unlock_events);
  CHECK(cJSON_GetArraySize(json::get(unlock_events.get(), "events")) == 0);
  CHECK(adminReq(http_port, "POST", "/api/doors/d_front/open", "{}", session,
                 "Origin: http://127.0.0.1:" + std::to_string(http_port + 1) +
                     "\r\nX-Doorbell-CSRF: " + admin_csrf_by_token.at(session) + "\r\n")
            .find("HTTP/1.1 403") == 0);
  unlock_events = bodyJson(adminReq(http_port, "GET", "/api/events?type=dtmf_action",
                                    "", session));
  REQUIRE(unlock_events);
  CHECK(cJSON_GetArraySize(json::get(unlock_events.get(), "events")) == 0);
  CHECK(adminReq(http_port, "POST", "/api/doors/d_front/open", "{}",
                 session + "; dbpanel=stale-panel-cookie", "", false)
            .find("HTTP/1.1 403") == 0);
  CHECK(adminReq(http_port, "POST", "/api/doors/d_front/open", "{}", session)
            .find("HTTP/1.1 200") == 0);
  auto with_unlock = bodyJson(adminReq(http_port, "GET", "/api/status", "", session));
  REQUIRE(with_unlock);
  const cJSON* unlock =
      json::get(json::get(json::get(with_unlock.get(), "doors"), "d_front"), "unlock");
  CHECK(json::getBool(unlock, "configured"));
  CHECK(json::getBool(unlock, "show_button"));
  CHECK(json::getString(unlock, "command") == "unlock");

  // Minting a PIN must not open the bulk-add window; only /api/pairing/start does that.
  auto minted = bodyJson(adminReq(http_port, "POST", "/api/join-token", "{}", session));
  REQUIRE(minted);
  CHECK(json::getBool(minted.get(), "ok"));
  CHECK(json::getString(minted.get(), "pin").size() == 6);
  CHECK_FALSE(json::getString(minted.get(), "host").empty());
  CHECK(json::getInt(minted.get(), "expires_s") > 0);
  auto pairing = bodyJson(adminReq(http_port, "GET", "/api/pairing", "", session));
  REQUIRE(pairing);
  CHECK_FALSE(json::getBool(json::get(pairing.get(), "pending"), "pairing_mode"));
  CHECK(json::getBool(json::get(pairing.get(), "token"), "active"));

  auto started = bodyJson(adminReq(http_port, "POST", "/api/pairing/start",
                                   "{\"seconds\":600}", session));
  REQUIRE(started);
  CHECK(json::getBool(started.get(), "ok"));
  auto opened = bodyJson(adminReq(http_port, "GET", "/api/pairing", "", session));
  REQUIRE(opened);
  CHECK(json::getBool(json::get(opened.get(), "pending"), "pairing_mode"));

  CHECK(node.setAdminPassword("testpw", "rotated-test-password") == 0);
  CHECK(adminReq(http_port, "POST", "/api/doors/d_front/open", "{}", session)
            .find("HTTP/1.1 403") == 0);
  CHECK(adminReq(http_port, "GET", "/api/status", "", session)
            .find("HTTP/1.1 401") == 0);

  node.stop();
}

TEST_CASE("admin API: a door station with no working camera keeps serving HTTP after a press") {
  // Real-device finding: an iPad 1 door station with no usable camera served pairing and
  // POST /api/press, then port 47180 stopped accepting entirely -- refused even on loopback --
  // while the mesh port stayed open, the process kept running and nothing crashed.
  std::mt19937 rng(static_cast<uint32_t>(::getpid()) ^ 0x3f0du);
  const int mesh_port = adminFreePort(rng);
  const int http_port = adminFreePort(rng);
  REQUIRE(mesh_port > 0);
  REQUIRE(http_port > 0);

  NodeOptions options;
  options.data_dir = ":memory:";
  options.name = "no-camera";
  options.role = "door_station";
  options.door = "door-ipad1";
  options.listen_addr = "127.0.0.1:" + std::to_string(mesh_port);
  options.psk.fill(0x5c);
  options.enable_beacon = false;
  options.http_port = http_port;
  options.mesh_timing_template = adminTiming();
  options.use_mesh_timing_template = true;
  Node node(options);
  REQUIRE(node.start());
  const std::string session = adminLogin(http_port);

  // No camera: the snapshot source never yields a frame.
  CHECK(adminReq(http_port, "GET", "/snapshot.jpg").find("HTTP/1.1 503") == 0);

  auto press = bodyJson(adminReq(http_port, "POST", "/api/press",
                                 "{\"door\":\"door-ipad1\"}", session));
  REQUIRE(press);
  CHECK(json::getBool(press.get(), "ok"));

  // The listener must still answer afterwards, repeatedly, on every kind of route.
  for (int i = 0; i < 5; i++) {
    auto status = bodyJson(adminReq(http_port, "GET", "/api/status", "", session));
    REQUIRE(status);
    CHECK(json::getString(json::get(status.get(), "node"), "role") == "door_station");
    CHECK(adminReq(http_port, "GET", "/video-meta").find("HTTP/1.1 200") == 0);
  }

  // A live view against a camera-less station must not pin a worker thread for good. Several
  // viewers open and go away; the port has to keep accepting throughout.
  for (int round = 0; round < 6; round++) {
    int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    REQUIRE(fd >= 0);
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_port = htons(static_cast<uint16_t>(http_port));
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    REQUIRE(::connect(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0);
    const std::string request =
        "GET /stream.mjpeg HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
    ::send(fd, request.data(), request.size(), 0);
    // Abandon it the way a panel that navigates away does.
    ::close(fd);
    auto status = bodyJson(adminReq(http_port, "GET", "/api/status", "", session));
    REQUIRE(status);
    CHECK(json::getString(json::get(status.get(), "node"), "door") == "door-ipad1");
  }

  // And the press path itself is still usable, which is what the operator was locked out of.
  CHECK(adminReq(http_port, "POST", "/api/press", "{\"door\":\"door-ipad1\"}", session)
            .find("HTTP/1.1 200") == 0);
  node.stop();
}

TEST_CASE("admin API: the pairing QR payload comes from core, on every surface that mints a PIN") {
  std::mt19937 rng(static_cast<uint32_t>(::getpid()) ^ 0x9b21u);
  const int mesh_port = adminFreePort(rng);
  const int http_port = adminFreePort(rng);
  REQUIRE(mesh_port > 0);
  REQUIRE(http_port > 0);

  NodeOptions options;
  options.data_dir = ":memory:";
  options.name = "qr-host";
  options.role = "indoor_panel";
  options.listen_addr = "127.0.0.1:" + std::to_string(mesh_port);
  options.advertise_addr = "127.0.0.1:" + std::to_string(mesh_port);
  options.psk.fill(0x77);
  options.enable_beacon = false;
  options.http_port = http_port;
  options.mesh_timing_template = adminTiming();
  options.use_mesh_timing_template = true;
  Node node(options);
  REQUIRE(node.start());
  const std::string session = adminLogin(http_port);
  // A name a shell must not have to encode itself.
  node.setConfigKey("cluster.name", "\"京阪 ハウス\"");

  auto checkUri = [&](const std::string& uri, const std::string& pin) {
    CAPTURE(uri);
    CHECK(uri.rfind("doorbell://pair?", 0) == 0);
    CHECK(uri.find("\xe4\xba\xac") == std::string::npos);  // percent-encoded, never raw
    auto parsed = bodyJson(adminReq(http_port, "GET", "/api/status", "", session));
    (void)parsed;
    auto round_trip = json::parse(node.parsePairUriJson(uri));
    REQUIRE(round_trip);
    CHECK(json::getBool(round_trip.get(), "ok"));
    CHECK(json::getString(round_trip.get(), "pin") == pin);
    CHECK(json::getString(round_trip.get(), "host") ==
          "127.0.0.1:" + std::to_string(mesh_port));
    CHECK(json::getString(round_trip.get(), "cluster") == "京阪 ハウス");
    CHECK(json::getInt(round_trip.get(), "exp") > 0);
  };

  // Minting a PIN.
  auto minted = bodyJson(adminReq(http_port, "POST", "/api/join-token", "{}", session));
  REQUIRE(minted);
  REQUIRE(json::getBool(minted.get(), "ok"));
  checkUri(json::getString(minted.get(), "uri"), json::getString(minted.get(), "pin"));

  // The bulk-add button.
  auto started = bodyJson(adminReq(http_port, "POST", "/api/pairing/start",
                                   "{\"seconds\":600}", session));
  REQUIRE(started);
  REQUIRE(json::getBool(started.get(), "ok"));
  checkUri(json::getString(started.get(), "uri"), json::getString(started.get(), "pin"));

  // The PIN card in the pairing snapshot, which is what the admin page renders.
  auto pairing = bodyJson(adminReq(http_port, "GET", "/api/pairing", "", session));
  REQUIRE(pairing);
  const cJSON* token = json::get(pairing.get(), "token");
  REQUIRE(cJSON_IsObject(token));
  REQUIRE(json::getBool(token, "active"));
  checkUri(json::getString(token, "uri"), json::getString(token, "pin"));
  // The host and PIN stay printed beside the code for a plain camera app.
  CHECK_FALSE(json::getString(token, "host").empty());
  CHECK(json::getString(token, "pin").size() == 6);

  // A scanned code is validated the same way everywhere, including the failures.
  auto rejected = json::parse(node.parsePairUriJson("https://example.invalid/pair"));
  REQUIRE(rejected);
  CHECK_FALSE(json::getBool(rejected.get(), "ok"));
  CHECK(json::getString(rejected.get(), "err") == "bad_scheme");
  auto no_pin = json::parse(node.parsePairUriJson("doorbell://pair?host=10.0.1.10%3A47172"));
  CHECK(json::getString(no_pin.get(), "err") == "missing_pin");
  auto stale = json::parse(node.parsePairUriJson(
      "doorbell://pair?host=10.0.1.10%3A47172&pin=123456&exp=1000000000"));
  CHECK(json::getString(stale.get(), "err") == "expired");

  node.stop();
}

TEST_CASE("admin API: a follower forwards Telegram tests to the elected node") {
  std::mt19937 rng(2042);
  NodeOptions source;
  source.data_dir = ":memory:";
  source.name = "telegram-source";
  source.role = "indoor_panel";
  source.listen_addr = "127.0.0.1:" + std::to_string(adminFreePort(rng));
  source.advertise_addr = source.listen_addr;
  source.http_port = adminFreePort(rng);
  source.psk.fill(0x71);
  source.enable_beacon = false;
  source.caps_json = adminTgCaps();
  source.mesh_timing_template = adminTiming();
  source.use_mesh_timing_template = true;
  NodeOptions follower = source;
  follower.name = "telegram-follower";
  follower.role = "door_station";
  follower.listen_addr = "127.0.0.1:" + std::to_string(adminFreePort(rng));
  follower.advertise_addr = follower.listen_addr;
  follower.http_port = adminFreePort(rng);
  follower.seed_peers = {source.listen_addr};
  follower.seed_default_config = false;
  follower.caps_json = "{}";
  Node a(source), b(follower);
  AdminMockHttps https;
  a.setHttpsFn(https.fn());
  a.setSecureStore([](const std::string& key) {
    return key == "telegram.forward" ? std::string("TESTTOKEN") : std::string();
  }, [](const std::string&, const std::string&) { return true; });
  REQUIRE(a.start());
  a.setConfigKey("integrations.telegram.bot_token_ref", "\"secret:telegram.forward\"");
  REQUIRE(b.start());
  bool ready = false;
  for (int i = 0; i < 120 && !ready; ++i) {
    auto state = json::parse(b.statusJson());
    ready = json::getString(json::get(state.get(), "leaders"), "telegram") == a.nodeId();
    if (!ready) std::this_thread::sleep_for(std::chrono::milliseconds(50));
  }
  REQUIRE(ready);
  const std::string session = adminLogin(follower.http_port);
  auto pending = bodyJson(adminReq(follower.http_port, "POST", "/api/test/telegram",
                                   R"({"chat_id":"999"})", session));
  REQUIRE(json::getBool(pending.get(), "pending"));
  const std::string request = json::getString(pending.get(), "request");
  REQUIRE(request.size() == 32);
  bool complete = false;
  for (int i = 0; i < 100 && !complete; ++i) {
    auto result = bodyJson(adminReq(follower.http_port, "GET", "/api/test/telegram/" + request,
                                   "", session));
    complete = !json::getBool(result.get(), "pending") && json::getBool(result.get(), "ok");
    if (!complete) std::this_thread::sleep_for(std::chrono::milliseconds(50));
  }
  REQUIRE(complete);
  CHECK(https.count("sendMessage", "\"chat_id\":\"999\"") == 1);
  b.stop();
  a.stop();
}

TEST_CASE("admin API: device removal requires a session and cannot remove self") {
  std::mt19937 rng(3042);
  NodeOptions options;
  options.data_dir = ":memory:";
  options.listen_addr = "127.0.0.1:" + std::to_string(adminFreePort(rng));
  options.http_port = adminFreePort(rng);
  options.psk.fill(0x72);
  options.enable_beacon = false;
  Node node(options);
  REQUIRE(node.start());
  const std::string old = "0123456789abcdef0123456789abcdef";
  const std::string body = "{\"id\":\"" + old + "\"}";
  node.setConfigKey("devices." + old + ".name", "\"old\"");
  CHECK(adminReq(options.http_port, "POST", "/api/devices/remove", body).find("HTTP/1.1 401") == 0);
  const std::string session = adminLogin(options.http_port);
  auto result = bodyJson(adminReq(options.http_port, "POST", "/api/devices/remove", body, session));
  CHECK(json::getBool(result.get(), "ok"));
  auto cfg = json::parse(node.configJson());
  CHECK(json::get(json::get(cfg.get(), "devices"), old.c_str()) == nullptr);
  CHECK(adminReq(options.http_port, "POST", "/api/devices/remove",
                 "{\"id\":\"" + node.nodeId() + "\"}", session).find("HTTP/1.1 400") == 0);
  node.stop();
}

TEST_CASE("admin API: cloud speech caches, deduplicates and invalidates generated replies") {
  std::mt19937 rng(static_cast<uint32_t>(::getpid()) ^ 0x7713u);
  const std::string dir = adminTempDir();
  NodeOptions o;
  o.data_dir = dir;
  o.role = "door_station";
  o.door = "front";
  o.listen_addr = "127.0.0.1:" + std::to_string(adminFreePort(rng));
  o.http_port = adminFreePort(rng);
  o.enable_beacon = false;
  o.psk.fill(0x32);
  Node node(o);
  std::atomic<int> requests{0};
  std::atomic<bool> fail{false};
  std::atomic<bool> credentials_ok{true};
  std::atomic<int> cached_playback{0}, system_speech{0};
  node.setTtsCb([&](const std::string&, const std::string&) { system_speech++; });
  node.setUiEventCb([&](const std::string& value) {
    auto ev = json::parse(value);
    if (json::getString(ev.get(), "t") == "reply" &&
        !json::getString(ev.get(), "audio_path").empty()) cached_playback++;
  });
  node.setSecureStore([](const std::string& key) {
    return key == "speech.test" ? "test-cloud-key" : "";
  }, [](const std::string&, const std::string&) { return true; });
  node.setHttpsFn([&](const std::string& method, const std::string& url, const std::string& headers,
                      const Bytes& body, std::function<void(int, std::string)> done) {
    if (url != "https://texttospeech.googleapis.com/v1/text:synthesize") { done(503, ""); return; }
    requests++;
    auto h = json::parse(headers);
    auto request = json::parse(std::string(body.begin(), body.end()));
    if (method != "POST" || json::getString(h.get(), "X-Goog-Api-Key") != "test-cloud-key" ||
        json::getString(json::get(request.get(), "audioConfig"), "audioEncoding") != "MP3")
      credentials_ok = false;
    done(fail ? 429 : 200, fail ? "provider details must not leak" : "{\"audioContent\":\"SUQzbW9jay1hdWRpbw==\"}");
  });
  REQUIRE(node.start());
  const std::string session = adminLogin(o.http_port);
  auto cfg = json::parse(node.configJson());
  cJSON* reply = nullptr;
  cJSON_ArrayForEach(reply, json::get(cfg.get(), "quick_replies")) {
    if (reply->string) node.deleteConfigKeyJson("quick_replies." + std::string(reply->string));
  }
  node.setConfigKey("quick_replies.test", R"({"label":{"en":"Please wait."},"speak":true})");
  node.setConfigKey("speech", "{\"provider\":\"google\",\"generator_node\":\"" + node.nodeId() +
      "\",\"google_key_ref\":\"secret:speech.test\",\"auto_cache\":true}");
  auto status = [&]() { return adminReq(o.http_port, "GET", "/api/tts", "", session); };
  auto waitFor = [&](const std::string& expected) {
    for (int i = 0; i < 100; ++i) {
      if (status().find(expected) != std::string::npos) return true;
      usleep(50000);
    }
    return false;
  };
  REQUIRE(waitFor("\"state\":\"ready\""));
  CHECK(requests == 1);
  CHECK(credentials_ok);
  node.setVisitorLang("front", "en");
  node.sendQuickReply("test", "", "front", "app");
  for (int i = 0; i < 100 && cached_playback == 0; ++i) usleep(10000);
  CHECK(cached_playback == 1);
  CHECK(system_speech == 0);
  CHECK(status().find("test-cloud-key") == std::string::npos);
  CHECK(adminReq(o.http_port, "GET", "/api/tts").find("HTTP/1.1 200") != 0);
  // Identical text, voice and language reuse one synthesis even across reply IDs.
  node.setConfigKey("quick_replies.copy", R"({"label":{"en":"Please wait."},"speak":true})");
  usleep(1200000);
  CHECK(requests == 1);
  node.setConfigKey("speech.speaking_rate", "1.2");
  REQUIRE(waitFor("\"state\":\"ready\""));
  CHECK(requests == 2);
  fail = true;
  node.setConfigKey("quick_replies.test.label.en", "\"Changed reply.\"");
  REQUIRE(waitFor("provider_http_429"));
  node.sendQuickReply("test", "", "front", "app");
  for (int i = 0; i < 100 && system_speech == 0; ++i) usleep(10000);
  CHECK(system_speech == 1);
  const int failed_count = requests;
  usleep(1500000);
  CHECK(requests == failed_count);
  CHECK(status().find("provider details") == std::string::npos);
  fail = false;
  CHECK(adminReq(o.http_port, "POST", "/api/tts/cache", "{}", session).find("HTTP/1.1 200") == 0);
  for (int i = 0; i < 100 && requests == failed_count; ++i) usleep(50000);
  REQUIRE(waitFor("\"state\":\"ready\""));
  CHECK(status().find("Changed reply.") == std::string::npos);
  CHECK(status().find("\"state\":\"failed\"") == std::string::npos);
  CHECK(requests == failed_count + 1);
  node.stop();
}

TEST_CASE("admin sessions: background reads expire despite raw clock rollback") {
  SimClock clock;
  NodeOptions options;
  options.data_dir = ":memory:";
  options.listen_addr = "127.0.0.1:" + std::to_string(db::testing::freeListenPort());
  options.http_port = db::testing::freeListenPort();
  options.enable_beacon = false;
  options.psk.fill(0x31);
  NodeDeps deps;
  deps.clock = &clock;
  Node node(options, std::move(deps));
  REQUIRE(node.start());
  const std::string token = adminLogin(options.http_port);
  for (int minute = 0; minute < 30; ++minute) {
    CHECK(adminReq(options.http_port, "GET", "/api/status", "", token)
              .find("HTTP/1.1 200") == 0);
    clock.advance(60'000);
    clock.setWall(clock.systemWallMs() - 300'000);
  }
  CHECK(adminReq(options.http_port, "GET", "/api/status", "", token)
            .find("HTTP/1.1 401") == 0);
  const std::string active = adminLogin(options.http_port);
  const auto session_response = adminReq(options.http_port, "GET", "/api/session", "", active);
  REQUIRE(session_response.find("Cache-Control: no-store") != std::string::npos);
  auto session_json = bodyJson(session_response);
  const std::string csrf = json::getString(session_json.get(), "csrf_token");
  REQUIRE(csrf.size() == 32);
  const std::string origin = "http://127.0.0.1:" + std::to_string(options.http_port);
  const std::string activity_headers = "Origin: " + origin + "\r\nX-Doorbell-CSRF: " + csrf + "\r\n";
  const std::string second = adminLogin(options.http_port);
  CHECK(adminReq(options.http_port, "POST", "/api/session/activity", "{}", second,
                 activity_headers).find("HTTP/1.1 403") == 0);
  for (const std::string& bad : std::vector<std::string>{"", "null", "https://untrusted.example", origin + ".evil", origin + "/"}) {
    CHECK(adminReq(options.http_port, "POST", "/api/session/activity", "{}", active,
                   "Origin: " + bad + "\r\nX-Doorbell-CSRF: " + csrf +
                   "\r\nX-Forwarded-Host: 127.0.0.1\r\n").find("HTTP/1.1 403") == 0);
  }
  CHECK(adminReq(options.http_port, "POST", "/api/session/activity", "{}", active,
                 "Origin: " + origin + "\r\nX-Doorbell-CSRF: wrong\r\n")
            .find("HTTP/1.1 403") == 0);
  node.setConfigKey("web.allowed_origins", "[\"https://admin.example\"]");
  CHECK(adminReq(options.http_port, "POST", "/api/session/activity", "{}", active,
                 "Origin: https://admin.example\r\nX-Doorbell-CSRF: " + csrf + "\r\n")
            .find("HTTP/1.1 200") == 0);
  clock.advance(20 * 60'000);
  CHECK(adminReq(options.http_port, "POST", "/api/session/activity", "{}", active, "", false)
            .find("HTTP/1.1 403") == 0);
  CHECK(adminReq(options.http_port, "POST", "/api/session/activity", "{}", active,
                 activity_headers).find("HTTP/1.1 200") == 0);
  clock.advance(20 * 60'000);
  CHECK(adminReq(options.http_port, "GET", "/api/status", "", active)
            .find("HTTP/1.1 200") == 0);
  clock.advance(10 * 60'000);
  CHECK(adminReq(options.http_port, "POST", "/api/session/activity", "{}", active,
                 activity_headers).find("HTTP/1.1 401") == 0);
  node.stop();
}

TEST_CASE("admin sessions: replicated credentials revoke after partition healing") {
  SimClock clock;
  Runloop loop(clock);
  InMemNet net(loop);
  NodeOptions options;
  options.data_dir = ":memory:";
  options.name = "session-a";
  options.role = "indoor_panel";
  options.listen_addr = "session-a:1";
  options.advertise_addr = options.listen_addr;
  options.http_port = db::testing::freeListenPort();
  options.psk.fill(0x43);
  options.enable_beacon = false;
  options.mesh_timing_template = adminTiming();
  options.use_mesh_timing_template = true;
  NodeDeps da;
  da.clock = &clock; da.loop = &loop;
  da.transport = net.makeTransport(options.listen_addr);
  da.discovery = net.makeDiscovery(options.listen_addr);
  const int port_a = options.http_port;
  Node a(options, std::move(da));
  options.name = "session-b";
  options.listen_addr = "session-b:1";
  options.advertise_addr = options.listen_addr;
  options.seed_peers = {"session-a:1"};
  options.http_port = db::testing::freeListenPort();
  options.seed_default_config = false;
  NodeDeps db;
  db.clock = &clock; db.loop = &loop;
  db.transport = net.makeTransport(options.listen_addr);
  db.discovery = net.makeDiscovery(options.listen_addr);
  const int port_b = options.http_port;
  Node b(options, std::move(db));
  loop.start();
  REQUIRE(a.start());
  const std::string token_a = adminLogin(port_a);
  REQUIRE(b.start());
  auto credential = [](Node& node) {
    auto cfg = json::parse(node.configJson());
    auto* value = json::get(json::get(cfg.get(), "admin"), "password_hash");
    return value ? json::dump(value) : "";
  };
  auto awaitSync = [&] {
    for (int i = 0; i < 200; ++i) {
      clock.advance(50);
      loop.callSync([] {});
      if (!credential(a).empty() && credential(a) == credential(b)) return true;
      std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    return false;
  };
  REQUIRE(awaitSync());
  const std::string token_b = adminLogin(port_b);
  REQUIRE(adminReq(port_b, "GET", "/api/status", "", token_b).find("HTTP/1.1 200") == 0);
  loop.callSync([&] { net.partition({{"session-a:1"}, {"session-b:1"}}); });
  REQUIRE(a.setAdminPassword("testpw", "next-password") == 0);
  CHECK(adminReq(port_a, "GET", "/api/status", "", token_a).find("HTTP/1.1 401") == 0);
  CHECK(adminReq(port_b, "GET", "/api/status", "", token_b).find("HTTP/1.1 200") == 0);
  const std::string partition_login = adminLogin(port_b);
  loop.callSync([&] { net.heal(); });
  REQUIRE(awaitSync());
  CHECK(adminReq(port_b, "GET", "/api/status", "", token_b).find("HTTP/1.1 401") == 0);
  CHECK(adminReq(port_b, "GET", "/api/status", "", partition_login).find("HTTP/1.1 401") == 0);
  CHECK(adminReq(port_b, "POST", "/api/login", R"({"password":"next-password"})")
            .find("HTTP/1.1 200") == 0);
  a.stop(); b.stop(); loop.stop();
}

TEST_CASE("admin sessions: capacity retains a new low-sorting token and uses interaction order") {
  AdminSessions sessions;
  sessions.publishCredential("credential-v1");
  for (int i = 0; i < 64; ++i)
    REQUIRE(sessions.issue("old-" + std::to_string(i), "credential-v1", 0));
  REQUIRE(sessions.check("old-0", 1, true));
  REQUIRE(sessions.issue("000-new", "credential-v1", 2));
  CHECK(sessions.check("000-new", 2));
  CHECK(sessions.check("old-0", 2));
  CHECK_FALSE(sessions.check("old-1", 2));
  for (int i = 2; i < 64; ++i) CHECK(sessions.check("old-" + std::to_string(i), 2));
  CHECK_FALSE(sessions.issue("000-new", "credential-v1", 3));
  sessions.publishCredential("credential-v2");
  CHECK_FALSE(sessions.check("000-new", 3));
  CHECK_FALSE(sessions.issue("stale", "credential-v1", 3));
  CHECK(sessions.issue("current", "credential-v2", 3));
}

TEST_CASE("admin sessions: interaction cannot extend eight hours or reverse monotonic age") {
  AdminSessions sessions;
  sessions.publishCredential("credential");
  REQUIRE(sessions.issue("active", "credential", 0));
  for (int64_t minute = 20; minute < 480; minute += 20)
    CHECK(sessions.check("active", minute * 60'000, true));
  CHECK_FALSE(sessions.check("active", AdminSessions::kAbsoluteMs, true));
  REQUIRE(sessions.issue("rollback", "credential", 1'000));
  CHECK_FALSE(sessions.check("rollback", 999, true));
  REQUIRE(sessions.issue("idle", "credential", 10'000));
  CHECK(sessions.check("idle", 10'000 + AdminSessions::kIdleMs - 1));
  CHECK_FALSE(sessions.check("idle", 10'000 + AdminSessions::kIdleMs));
}

TEST_CASE("admin sessions: credential and version roll back together on either storage failure") {
  const std::string dir = adminTempDir();
  NodeOptions options;
  options.data_dir = dir;
  options.listen_addr = "127.0.0.1:" + std::to_string(db::testing::freeListenPort());
  options.http_port = db::testing::freeListenPort();
  options.enable_beacon = false;
  options.psk.fill(0x38);
  {
    Node node(options);
    REQUIRE(node.start());
    const std::string token = adminLogin(options.http_port);
    const std::string before = node.configJson();
    REQUIRE(setAdminMetaWriteFailure(dir + "/doorbell.db", true));
    CHECK(node.setAdminPassword("testpw", "not-committed-meta") == -4);
    CHECK(node.configJson() == before);
    CHECK(node.verifyAdminPassword("testpw") == 1);
    CHECK(node.verifyAdminPassword("not-committed-meta") == 0);
    CHECK(adminReq(options.http_port, "GET", "/api/status", "", token).find("HTTP/1.1 200") == 0);
    REQUIRE(setAdminMetaWriteFailure(dir + "/doorbell.db", false));
    REQUIRE(setAdminConfigWriteFailure(dir + "/doorbell.db", true));
    CHECK(node.setAdminPassword("testpw", "not-committed-config") == -4);
    CHECK(node.configJson() == before);
    CHECK(node.verifyAdminPassword("testpw") == 1);
    REQUIRE(setAdminConfigWriteFailure(dir + "/doorbell.db", false));
    REQUIRE(node.setAdminPassword("testpw", "committed-password") == 0);
    CHECK(adminReq(options.http_port, "GET", "/api/status", "", token).find("HTTP/1.1 401") == 0);
    node.stop();
  }
  {
    Store store;
    REQUIRE(store.open(dir + "/doorbell.db"));
    SimClock clock;
    HlcClock hlc(clock, "reopen");
    LwwMap config("test-reopen", hlc);
    config.load(store.configLoadAll());
    auto document = json::parse(config.materializeJson());
    auto* credential = json::get(json::get(document.get(), "admin"), "password_hash");
    REQUIRE(credential);
    CHECK(store.metaGet("admin_pw_salt").value_or("") == json::getString(credential, "salt"));
    CHECK(store.metaGet("admin_pw_hash").value_or("") == json::getString(credential, "hash"));
  }
  for (const char* file : {"doorbell.db", "doorbell.db-wal", "doorbell.db-shm"})
    std::remove((dir + "/" + file).c_str());
  ::rmdir((dir + "/assets").c_str());
  ::rmdir(dir.c_str());
}

TEST_CASE("admin API: configuration conditional batch rejects a stale shared base") {
  NodeOptions options;
  options.data_dir = ":memory:";
  options.listen_addr = "127.0.0.1:" + std::to_string(db::testing::freeListenPort());
  options.http_port = db::testing::freeListenPort();
  options.enable_beacon = false;
  Node node(options);
  REQUIRE(node.start());
  const std::string session = adminLogin(options.http_port);
  auto protection = bodyJson(adminReq(options.http_port, "GET", "/api/session", "", session));
  const std::string headers = "Origin: http://127.0.0.1:" + std::to_string(options.http_port) +
      "\r\nX-Doorbell-CSRF: " + json::getString(protection.get(), "csrf_token") + "\r\n";
  auto baseline = json::parse(node.configBatchJson(
      R"({"ops":[{"op":"set","key":"cas.document","value":{"name":"base","future":42}}]})"));
  REQUIRE(json::getBool(baseline.get(), "ok"));
  const std::string revision = json::getString(baseline.get(), "revision");
  REQUIRE_FALSE(revision.empty());
  auto mutation = [&](const char* name) {
    auto request = json::obj();
    json::set(request.get(), "expected_revision", revision);
    auto* op = json::pushObj(json::addArr(request.get(), "ops"));
    json::set(op, "op", "set");
    json::set(op, "key", "cas.document.name");
    json::set(op, "value", name);
    return json::dump(request.get());
  };
  auto first = json::parse(node.configBatchJson(mutation("first")));
  REQUIRE(json::getBool(first.get(), "ok"));
  const auto second = adminReq(options.http_port, "POST", "/api/config/batch",
                               mutation("second"), session, headers);
  CHECK(second.find("HTTP/1.1 409") == 0);
  CHECK(second.find("config_conflict") != std::string::npos);
  auto current = json::parse(node.configJson());
  const auto* document = json::get(json::get(current.get(), "cas"), "document");
  CHECK(json::getString(document, "name") == "first");
  CHECK(json::getInt(document, "future") == 42);
  node.stop();
}

namespace {
std::string casRequest(const std::string& revision, const std::string& operations) {
  auto request = json::obj();
  json::set(request.get(), "schema_version", int64_t{2});
  json::set(request.get(), "expected_revision", revision);
  json::setItem(request.get(), "ops", json::parse(operations));
  return json::dump(request.get());
}
std::string casRevision(Node& node) {
  auto snapshot = json::parse(node.configSnapshotJson());
  REQUIRE(json::getInt(snapshot.get(), "schema_version") == 2);
  return json::getString(snapshot.get(), "revision");
}
NodeOptions casOptions() {
  NodeOptions options;
  options.data_dir = ":memory:";
  options.listen_addr = "127.0.0.1:" + std::to_string(db::testing::freeListenPort());
  options.http_port = db::testing::freeListenPort();
  options.enable_beacon = false;
  return options;
}
}

TEST_CASE("config CAS: object intent preserves unknown fields and distinguishes null from delete") {
  Node node(casOptions());
  REQUIRE(node.start());
  node.setConfigKey("cas.document", R"({"name":"base","future":{"flag":true},"nullable":"old","items":[1,2]})");
  const auto initial = casRevision(node);
  auto result = json::parse(node.configCommitJson(casRequest(initial,
      R"([{"op":"set","key":"cas.document","value":{"name":"mine","nullable":null,"items":[3]}}])")));
  REQUIRE(json::getBool(result.get(), "ok"));
  CHECK(json::getString(result.get(), "revision") != initial);
  auto document = json::parse(node.configJson());
  const auto* value = json::get(json::get(document.get(), "cas"), "document");
  CHECK(json::getString(value, "name") == "mine");
  CHECK(json::getBool(json::get(value, "future"), "flag"));
  CHECK(cJSON_IsNull(json::get(value, "nullable")));
  REQUIRE(cJSON_GetArraySize(json::get(value, "items")) == 1);
  CHECK(cJSON_GetArrayItem(json::get(value, "items"), 0)->valuedouble == 3);
  result = json::parse(node.configCommitJson(casRequest(casRevision(node),
      R"([{"op":"delete","key":"cas.document.nullable"}])")));
  REQUIRE(json::getBool(result.get(), "ok"));
  document = json::parse(node.configJson());
  value = json::get(json::get(document.get(), "cas"), "document");
  CHECK(json::get(value, "nullable") == nullptr);
  CHECK(json::getBool(json::get(value, "future"), "flag"));
  node.stop();
}

TEST_CASE("config CAS: invalid batches and failed durable commits publish nothing") {
  auto options = casOptions();
  options.data_dir = adminTempDir();
  {
    Node node(options);
    REQUIRE(node.start());
    node.setConfigKey("cas.document", R"({"name":"base","future":42})");
    const auto before = node.configJson();
    const auto revision = casRevision(node);
    const auto invalid = casRequest(revision,
        R"([{"op":"set","key":"cas.document","value":{"name":"invalid"}},{"op":"set","key":"call.indoor.return_s","value":-1}])");
    auto rejected = json::parse(node.configCommitJson(invalid));
    CHECK_FALSE(json::getBool(rejected.get(), "ok"));
    CHECK(json::getString(rejected.get(), "error_code") == "invalid_request");
    CHECK(node.configJson() == before);
    CHECK(casRevision(node) == revision);
    REQUIRE(setAdminConfigWriteFailure(options.data_dir + "/doorbell.db", true));
    const auto valid = casRequest(revision,
        R"([{"op":"set","key":"cas.document","value":{"name":"committed"}},{"op":"set","key":"cas.other","value":true}])");
    rejected = json::parse(node.configCommitJson(valid));
    CHECK_FALSE(json::getBool(rejected.get(), "ok"));
    CHECK(json::getString(rejected.get(), "error_code") == "config_persistence_failed");
    CHECK(node.configJson() == before);
    CHECK(casRevision(node) == revision);
    REQUIRE(setAdminConfigWriteFailure(options.data_dir + "/doorbell.db", false));
    auto accepted = json::parse(node.configCommitJson(valid));
    CHECK(json::getBool(accepted.get(), "ok"));
    CHECK(casRevision(node) != revision);
    node.stop();
  }
  {
    Store store;
    REQUIRE(store.open(options.data_dir + "/doorbell.db"));
    SimClock clock;
    HlcClock hlc(clock, "reopen-cas");
    LwwMap restored("reopen-cas", hlc);
    restored.load(store.configLoadAll());
    auto document = json::parse(restored.materializeJson());
    const auto* cas = json::get(document.get(), "cas");
    CHECK(json::getBool(cas, "other"));
    CHECK(json::getString(json::get(cas, "document"), "name") == "committed");
    CHECK(json::getInt(json::get(cas, "document"), "future") == 42);
  }
  removeAdminTempDir(options.data_dir);
}

TEST_CASE("config CAS: concurrent HTTP and native writers share one compare and commit") {
  auto options = casOptions();
  Node node(options);
  REQUIRE(node.start());
  const auto session = adminLogin(options.http_port);
  auto protection = bodyJson(adminReq(options.http_port, "GET", "/api/session", "", session));
  const std::string headers = "Origin: http://127.0.0.1:" + std::to_string(options.http_port) +
      "\r\nX-Doorbell-CSRF: " + json::getString(protection.get(), "csrf_token") + "\r\n";
  node.setConfigKey("cas.document", R"({"name":"base","future":42})");
  for (int round = 0; round < 4; ++round) {
    const auto revision = casRevision(node);
    std::atomic<int> ready{0};
    std::atomic<bool> go{false};
    std::vector<std::string> results(12);
    std::vector<std::thread> writers;
    for (int i = 0; i < 12; ++i) {
      writers.emplace_back([&, i] {
        const auto request = casRequest(revision,
            "[{\"op\":\"set\",\"key\":\"cas.document\",\"value\":{\"name\":\"writer-" +
            std::to_string(i) + "\"}}]");
        ++ready;
        while (!go.load()) std::this_thread::yield();
        if (i % 2) {
          const auto raw = adminReq(options.http_port, "POST", "/api/config/commit", request,
                                     session, headers);
          auto body = bodyJson(raw);
          results[i] = json::dump(body.get());
          CHECK(raw.find(json::getBool(body.get(), "ok") ? "HTTP/1.1 200" : "HTTP/1.1 409") == 0);
        } else results[i] = node.configCommitJson(request);
      });
    }
    while (ready.load() != 12) std::this_thread::yield();
    go = true;
    for (auto& writer : writers) writer.join();
    int committed = 0;
    int winner = -1;
    for (int i = 0; i < 12; ++i) {
      auto result = json::parse(results[i]);
      if (json::getBool(result.get(), "ok")) { ++committed; winner = i; }
      else CHECK(json::getString(result.get(), "error_code") == "config_conflict");
    }
    REQUIRE(committed == 1);
    auto document = json::parse(node.configJson());
    const auto* value = json::get(json::get(document.get(), "cas"), "document");
    CHECK(json::getString(value, "name") == "writer-" + std::to_string(winner));
    CHECK(json::getInt(value, "future") == 42);
  }
  node.stop();
}

TEST_CASE("config CAS: snapshots omit digests and commits require authenticated intent") {
  auto options = casOptions();
  Node node(options);
  REQUIRE(node.start());
  auto capabilities = json::parse(node.statusJson());
  CHECK(json::getBool(json::get(capabilities.get(), "features"), "config_cas_v1"));
  const auto session = adminLogin(options.http_port);
  const auto revision = casRevision(node);
  const auto request = casRequest(revision, R"([{"op":"set","key":"cas.value","value":1}])");
  CHECK(adminReq(options.http_port, "GET", "/api/config/snapshot").find("HTTP/1.1 401") == 0);
  auto snapshot = adminReq(options.http_port, "GET", "/api/config/snapshot", "", session);
  CHECK(snapshot.find("Cache-Control: no-store") != std::string::npos);
  auto body = bodyJson(snapshot);
  CHECK(json::get(json::get(json::get(body.get(), "config"), "admin"), "password_hash") == nullptr);
  CHECK(adminReq(options.http_port, "POST", "/api/config/commit", request, session, "", false)
            .find("HTTP/1.1 403") == 0);
  auto protection = bodyJson(adminReq(options.http_port, "GET", "/api/session", "", session));
  const auto wrong_origin = "Origin: http://untrusted.invalid\r\nX-Doorbell-CSRF: " +
      json::getString(protection.get(), "csrf_token") + "\r\n";
  CHECK(adminReq(options.http_port, "POST", "/api/config/commit", request, session, wrong_origin)
            .find("HTTP/1.1 403") == 0);
  CHECK(casRevision(node) == revision);
  for (const auto& invalid : {std::string("{}"),
      std::string("{\"schema_version\":2,\"expected_revision\":\"x\",\"ops\":[]}"),
      casRequest(revision, R"([{"op":"set","key":"cas.value","value":1},{"op":"delete","key":"cas.value"}])"),
      casRequest(revision, R"([{"op":"delete","key":"cas.value","value":null}])")}) {
    auto result = json::parse(node.configCommitJson(invalid));
    CHECK_FALSE(json::getBool(result.get(), "ok"));
    CHECK(casRevision(node) == revision);
  }
  const auto before = node.configJson();
  auto oversized = json::parse(node.configCommitJson(std::string(256 * 1024 + 1, ' ')));
  CHECK(json::getString(oversized.get(), "error_code") == "capacity_exceeded");
  CHECK(node.configJson() == before);
  node.setConfigKey("cas.legacy", "true");
  auto stale = json::parse(node.configCommitJson(request));
  CHECK(json::getString(stale.get(), "error_code") == "config_conflict");
  node.stop();
}

TEST_CASE("config CAS: versioned C ABI returns owned snapshots and rejects stale commits") {
  auto boot = json::obj();
  json::set(boot.get(), "data_dir", ":memory:");
  json::set(boot.get(), "http_port", int64_t{0});
  json::set(boot.get(), "listen_port", int64_t{0});
  json::setBool(boot.get(), "enable_beacon", false);
  db_platform_v2 platform{};
  platform.version = DB_PLATFORM_V2_VERSION;
  platform.struct_size = sizeof(platform);
  db_core* core = db_core_create_v2(&platform, ":memory:", json::dump(boot.get()).c_str());
  REQUIRE(core != nullptr);
  REQUIRE(db_core_start(core) == 0);
  char* raw = db_core_config_snapshot_json_v2(core);
  REQUIRE(raw != nullptr);
  auto snapshot = json::parse(raw);
  db_free(raw);
  const auto request = casRequest(json::getString(snapshot.get(), "revision"),
      R"([{"op":"set","key":"cas.native","value":{"preserved":true}}])");
  raw = db_core_config_commit_json_v2(core, request.c_str());
  REQUIRE(raw != nullptr);
  auto result = json::parse(raw);
  db_free(raw);
  CHECK(json::getBool(result.get(), "ok"));
  raw = db_core_config_commit_json_v2(core, request.c_str());
  REQUIRE(raw != nullptr);
  result = json::parse(raw);
  db_free(raw);
  CHECK(json::getString(result.get(), "error_code") == "config_conflict");
  db_core_stop(core);
  db_core_destroy(core);
}

TEST_CASE("config CAS: parent patches update existing child records without reviving removed fields") {
  Node node(casOptions());
  REQUIRE(node.start());
  node.setConfigKey("cas.document", R"({"future":42,"nested":{"unknown":true}})");
  node.setConfigKey("cas.document.name", R"("old")");
  node.setConfigKey("cas.document.nested.value", "1");
  node.setConfigKey("cas.document.removed", "true");
  REQUIRE(json::getBool(json::parse(node.deleteConfigKeyJson("cas.document.removed")).get(), "ok"));
  auto result = json::parse(node.configCommitJson(casRequest(casRevision(node),
      R"([{"op":"set","key":"cas.document","value":{"name":"new","nested":{"value":2}}}])")));
  REQUIRE(json::getBool(result.get(), "ok"));
  auto document = json::parse(node.configJson());
  auto* value = json::get(json::get(document.get(), "cas"), "document");
  CHECK(json::getString(value, "name") == "new");
  CHECK(json::getInt(value, "future") == 42);
  CHECK(json::getInt(json::get(value, "nested"), "value") == 2);
  CHECK(json::getBool(json::get(value, "nested"), "unknown"));
  CHECK(json::get(value, "removed") == nullptr);
  result = json::parse(node.configCommitJson(casRequest(casRevision(node),
      R"([{"op":"set","key":"cas.document.nested","value":null}])")));
  REQUIRE(json::getBool(result.get(), "ok"));
  document = json::parse(node.configJson());
  value = json::get(json::get(document.get(), "cas"), "document");
  CHECK(cJSON_IsNull(json::get(value, "nested")));
  result = json::parse(node.configCommitJson(casRequest(casRevision(node),
      R"([{"op":"set","key":"cas.document","value":{"name":"overlap"}},{"op":"set","key":"cas.document.name","value":"conflicting"}])")));
  CHECK(json::getString(result.get(), "error_code") == "overlapping_keys");
  result = json::parse(node.configCommitJson(casRequest(casRevision(node),
      R"([{"op":"delete","key":"cas.document"}])")));
  REQUIRE(json::getBool(result.get(), "ok"));
  document = json::parse(node.configJson());
  CHECK(json::get(json::get(document.get(), "cas"), "document") == nullptr);
  result = json::parse(node.configCommitJson(casRequest(casRevision(node),
      R"([{"op":"set","key":"cas.document","value":{"fresh":true}}])")));
  REQUIRE(json::getBool(result.get(), "ok"));
  document = json::parse(node.configJson());
  value = json::get(json::get(document.get(), "cas"), "document");
  CHECK(json::getBool(value, "fresh"));
  CHECK(json::get(value, "name") == nullptr);
  node.stop();
}

TEST_CASE("config CAS: materialized schema rejects child writes that corrupt typed parents") {
  Node node(casOptions());
  REQUIRE(node.start());
  node.setConfigKey("call.indoor.return_s", "30");
  node.setConfigKey("doors.front.unlock.command", R"("front_gate")");
  const auto before = node.configJson();
  const auto revision = casRevision(node);
  for (const char* operations : {
      R"([{"op":"set","key":"call.indoor.return_s.inner","value":1}])",
      R"([{"op":"set","key":"doors.front.unlock.command.inner","value":1}])",
      R"([{"op":"set","key":"doors","value":{"back":{"unlock":{"command":false}}}}])"}) {
    auto rejected = json::parse(node.configCommitJson(casRequest(revision, operations)));
    CHECK_FALSE(json::getBool(rejected.get(), "ok"));
    CHECK(json::getString(rejected.get(), "error_code") == "invalid_request");
    CHECK(node.configJson() == before);
    CHECK(casRevision(node) == revision);
  }
  node.stop();
}

TEST_CASE("config CAS: versioned ABI is defined before start and after stop") {
  db_platform_v2 platform{};
  platform.struct_size = sizeof(platform);
  platform.version = DB_PLATFORM_V2_VERSION;
  db_core* core = db_core_create_v2(&platform, ":memory:",
      R"({"listen_port":0,"http_port":0,"enable_beacon":false})");
  REQUIRE(core != nullptr);
  auto unavailable = [&] {
    for (bool commit : {false, true}) {
      char* raw = commit ? db_core_config_commit_json_v2(core, "{}") : db_core_config_snapshot_json_v2(core);
      REQUIRE(raw != nullptr);
      auto result = json::parse(raw);
      db_free(raw);
      CHECK(json::getString(result.get(), "error_code") == "not_started");
    }
  };
  unavailable();
  REQUIRE(db_core_start(core) == 0);
  db_core_stop(core);
  unavailable();
  db_core_destroy(core);
}

namespace {
struct CasCommitBarrier {
  std::mutex mutex;
  std::condition_variable changed;
  bool entered = false;
  bool released = false;
};
CasCommitBarrier* casCommitBarrier = nullptr;
void waitAtCasCommit(sqlite3_context* context, int, sqlite3_value**) {
  auto* barrier = casCommitBarrier;
  if (!barrier) { sqlite3_result_int(context, 1); return; }
  std::unique_lock<std::mutex> lock(barrier->mutex);
  barrier->entered = true;
  barrier->changed.notify_all();
  if (!barrier->changed.wait_for(lock, std::chrono::seconds(10), [&] { return barrier->released; }))
    sqlite3_result_error(context, "test commit barrier timeout", -1);
  else sqlite3_result_int(context, 1);
}
int installCasCommitBarrier(sqlite3* database, char**, const sqlite3_api_routines*) {
  return sqlite3_create_function(database, "t26_commit_barrier", 0, SQLITE_UTF8, nullptr,
                                  waitAtCasCommit, nullptr, nullptr);
}
}

TEST_CASE("config CAS: a competing native write queued inside persistence cannot cross the compare boundary") {
  REQUIRE(sqlite3_auto_extension(reinterpret_cast<void(*)()>(installCasCommitBarrier)) == SQLITE_OK);
  auto options = casOptions();
  options.data_dir = adminTempDir();
  RealClock clock;
  Runloop loop(clock);
  loop.start();
  NodeDeps dependencies;
  dependencies.clock = &clock;
  dependencies.loop = &loop;
  {
    Node node(options, std::move(dependencies));
    REQUIRE(node.start());
    node.setConfigKey("cas.document", R"({"name":"base","future":42})");
    const auto revision = casRevision(node);
    sqlite3* database = nullptr;
    REQUIRE(sqlite3_open((options.data_dir + "/doorbell.db").c_str(), &database) == SQLITE_OK);
    REQUIRE(sqlite3_exec(database, "CREATE TRIGGER t26_pause_commit BEFORE INSERT ON config "
        "WHEN NEW.key='cas.document' BEGIN SELECT t26_commit_barrier(); END", nullptr, nullptr, nullptr) == SQLITE_OK);
    sqlite3_close(database);
    CasCommitBarrier barrier;
    casCommitBarrier = &barrier;
    std::string first, second;
    std::atomic<bool> competing_entered{false};
    std::thread writer([&] {
      first = node.configCommitJson(casRequest(revision,
          R"([{"op":"set","key":"cas.document","value":{"name":"first"}}])"));
    });
    bool entered = false;
    {
      std::unique_lock<std::mutex> lock(barrier.mutex);
      entered = barrier.changed.wait_for(lock, std::chrono::seconds(10), [&] { return barrier.entered; });
    }
    CHECK(entered);
    const bool queued = loop.post([&] {
      competing_entered = true;
      second = node.configCommitJson(casRequest(revision,
          R"([{"op":"set","key":"cas.document","value":{"name":"second"}}])"));
    });
    CHECK(queued);
    CHECK_FALSE(competing_entered.load());
    auto published = json::parse(node.configJson());
    CHECK(json::getString(json::get(json::get(published.get(), "cas"), "document"), "name") == "base");
    {
      std::lock_guard<std::mutex> lock(barrier.mutex);
      barrier.released = true;
    }
    barrier.changed.notify_all();
    writer.join();
    loop.callSync([] {});
    casCommitBarrier = nullptr;
    CHECK(competing_entered.load());
    CHECK(json::getBool(json::parse(first).get(), "ok"));
    CHECK(json::getString(json::parse(second).get(), "error_code") == "config_conflict");
    auto current = json::parse(node.configJson());
    CHECK(json::getString(json::get(json::get(current.get(), "cas"), "document"), "name") == "first");
    node.stop();
  }
  loop.stop();
  sqlite3_cancel_auto_extension(reinterpret_cast<void(*)()>(installCasCommitBarrier));
  removeAdminTempDir(options.data_dir);
}

TEST_CASE("notice CAS: stale administrators cannot replace a newer notice and Core owns its time") {
  auto options = casOptions();
  Node node(options);
  REQUIRE(node.start());
  node.setConfigKey("doors.front", R"({"name":"Front"})");
  node.setConfigKey("time.zone", R"("Asia/Kolkata")");
  const auto session = adminLogin(options.http_port);
  auto protection = bodyJson(adminReq(options.http_port, "GET", "/api/session", "", session));
  const std::string headers = "Origin: http://127.0.0.1:" + std::to_string(options.http_port) +
      "\r\nX-Doorbell-CSRF: " + json::getString(protection.get(), "csrf_token") + "\r\n";
  for (const auto& path : {std::string("/api/notice"), std::string("/api/doors/front/notice")}) {
    const auto base = casRevision(node);
    auto body = json::obj();
    json::set(body.get(), "expected_revision", base);
    json::set(body.get(), "text", "First administrator");
    json::set(body.get(), "ttl_s", int64_t{60});
    const auto first = adminReq(options.http_port, "POST", path, json::dump(body.get()), session, headers);
    INFO(first);
    REQUIRE(first.find("HTTP/1.1 200") == 0);
    auto result = bodyJson(first);
    CHECK(json::getBool(result.get(), "ok"));
    CHECK(json::getString(result.get(), "revision") == casRevision(node));
    CHECK(casRevision(node) != base);
    auto snapshot = json::parse(node.configJson());
    const auto* notice = path == "/api/notice"
        ? json::get(json::get(snapshot.get(), "notice"), "global")
        : json::get(json::get(json::get(snapshot.get(), "doors"), "front"), "notice");
    REQUIRE(cJSON_IsObject(notice));
    CHECK(json::getString(notice, "text") == "First administrator");
    CHECK_FALSE(json::getString(notice, "from_device").empty());
    CHECK(json::getInt(notice, "created_ms") > 0);
    CHECK(json::getInt(notice, "expires_ms") - json::getInt(notice, "created_ms") == 60000);
    const auto before = node.configJson();
    json::set(body.get(), "text", "Stale administrator");
    auto stale = adminReq(options.http_port, "POST", path, json::dump(body.get()), session, headers);
    CHECK(stale.find("HTTP/1.1 409") == 0);
    CHECK(json::getString(bodyJson(stale).get(), "error_code") == "config_conflict");
    CHECK(node.configJson() == before);
    json::set(body.get(), "expected_revision", casRevision(node));
    json::set(body.get(), "ttl_s", int64_t{0});
    json::set(body.get(), "expiry", "today");
    auto today = adminReq(options.http_port, "POST", path, json::dump(body.get()), session, headers);
    INFO(today);
    REQUIRE(today.find("HTTP/1.1 200") == 0);
    auto after = json::parse(node.configJson());
    const auto* final_notice = path == "/api/notice"
        ? json::get(json::get(after.get(), "notice"), "global")
        : json::get(json::get(json::get(after.get(), "doors"), "front"), "notice");
    const auto created = json::getInt(final_notice, "created_ms");
    const auto expires = json::getInt(final_notice, "expires_ms");
    const int64_t zone = 330;
    CHECK(expires > created);
    CHECK(expires - created <= 86'400'000LL);
    CHECK((expires + zone * 60'000LL) % 86'400'000LL == 0);
  }
  node.stop();
}

TEST_CASE("notice CAS: conditional writes require admin intent and reject client timestamps") {
  auto options = casOptions();
  Node node(options);
  REQUIRE(node.start());
  node.setConfigKey("doors.front", R"({"name":"Front"})");
  const auto session = adminLogin(options.http_port);
  auto protection = bodyJson(adminReq(options.http_port, "GET", "/api/session", "", session));
  const std::string csrf = json::getString(protection.get(), "csrf_token");
  const std::string headers = "Origin: http://127.0.0.1:" + std::to_string(options.http_port) +
      "\r\nX-Doorbell-CSRF: " + csrf + "\r\n";
  const auto revision = casRevision(node);
  for (const auto& path : {std::string("/api/notice"), std::string("/api/doors/front/notice")}) {
    auto body = json::obj();
    json::set(body.get(), "expected_revision", revision);
    json::set(body.get(), "text", "Protected notice");
    CHECK(adminReq(options.http_port, "POST", path, json::dump(body.get()), session, "", false)
              .find("HTTP/1.1 403") == 0);
    CHECK(adminReq(options.http_port, "POST", path, json::dump(body.get()), session,
              "Origin: http://untrusted.invalid\r\nX-Doorbell-CSRF: " + csrf + "\r\n")
              .find("HTTP/1.1 403") == 0);
    for (const char* field : {"created_ms", "expires_ms", "from_device"}) {
      json::set(body.get(), field, int64_t{1});
      CHECK(adminReq(options.http_port, "POST", path, json::dump(body.get()), session, headers)
                .find("HTTP/1.1 400") == 0);
      cJSON_DeleteItemFromObjectCaseSensitive(body.get(), field);
    }
    for (const char* invalid : {"-1", "1.5", "2147483648", "\"60\"", "null"}) {
      json::setItem(body.get(), "ttl_s", json::parse(invalid));
      CHECK(adminReq(options.http_port, "POST", path, json::dump(body.get()), session, headers)
                .find("HTTP/1.1 400") == 0);
    }
    CHECK(casRevision(node) == revision);
  }
  node.stop();
}

TEST_CASE("config CAS: explicit object field removal combines with updates without losing unknown fields") {
  Node node(casOptions());
  REQUIRE(node.start());
  node.setConfigKey("cas.document", R"({"name":"before","nullable":null,"removed":1,"future":{"v":42}})");
  node.setConfigKey("cas.document.removed", "2");
  auto result = json::parse(node.configCommitJson(casRequest(casRevision(node),
      R"([{"op":"set","key":"cas.document","value":{"name":"after"},"remove_fields":["removed"]}])")));
  REQUIRE(json::getBool(result.get(), "ok"));
  auto snapshot = json::parse(node.configJson());
  const auto* document = json::get(json::get(snapshot.get(), "cas"), "document");
  CHECK(json::getString(document, "name") == "after");
  CHECK(cJSON_IsNull(json::get(document, "nullable")));
  CHECK(json::get(document, "removed") == nullptr);
  CHECK(json::getInt(json::get(document, "future"), "v") == 42);
  const auto base = casRevision(node);
  for (const auto& operations : {
      R"([{"op":"set","key":"cas.document","value":{"name":"conflict"},"remove_fields":["name"]}])",
      R"([{"op":"set","key":"cas.document","value":1,"remove_fields":["name"]}])",
      R"([{"op":"set","key":"cas.document","value":{},"remove_fields":["name","name"]}])",
      R"([{"op":"delete","key":"cas.document","remove_fields":["name"]}])",
      R"([{"op":"set","key":"cas.document","value":{},"remove_fields":[]}])"}) {
    auto rejected = json::parse(node.configCommitJson(casRequest(base, operations)));
    CHECK_FALSE(json::getBool(rejected.get(), "ok"));
    CHECK(casRevision(node) == base);
  }
  node.stop();
}

TEST_CASE("config CAS: semantic style reset and update share one validated operation") {
  Node node(casOptions());
  REQUIRE(node.start());
  const auto key = "devices." + node.nodeId() + ".local.ui.elements.call.primary";
  auto seed = json::obj();
  auto* operation = json::pushObj(json::addArr(seed.get(), "ops"));
  json::set(operation, "op", "set");
  json::set(operation, "key", key);
  json::setItem(operation, "value", json::parse(R"({"radius":8,"foreground":"#FFFFFF"})"));
  auto established = json::parse(node.configCommitJson(casRequest(casRevision(node),
      json::dump(json::get(seed.get(), "ops")))));
  REQUIRE(json::getBool(established.get(), "ok"));
  json::setItem(operation, "value", json::parse(R"({"radius":12})"));
  json::setItem(operation, "remove_fields", json::parse(R"(["foreground"] )"));
  auto updated = json::parse(node.configCommitJson(casRequest(casRevision(node),
      json::dump(json::get(seed.get(), "ops")))));
  REQUIRE(json::getBool(updated.get(), "ok"));
  auto snapshot = json::parse(node.configJson());
  const auto* elements = json::get(json::get(json::get(json::get(json::get(snapshot.get(), "devices"),
      node.nodeId().c_str()), "local"), "ui"), "elements");
  const auto* style = json::get(json::get(elements, "call"), "primary");
  CHECK(json::getInt(style, "radius") == 12);
  CHECK(json::get(style, "foreground") == nullptr);
  json::setItem(operation, "value", json::parse(R"({"radius":200})"));
  json::setItem(operation, "remove_fields", json::parse(R"(["scale"] )"));
  const auto base = casRevision(node);
  auto invalid = json::parse(node.configCommitJson(casRequest(base,
      json::dump(json::get(seed.get(), "ops")))));
  CHECK_FALSE(json::getBool(invalid.get(), "ok"));
  CHECK(casRevision(node) == base);
  node.stop();
}
