
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cstdio>
#include <map>
#include <memory>
#include <random>
#include <string>
#include <vector>

#include <sqlite3.h>

#include "doctest.h"
#include "test_env.h"
#include "node/node.h"
#include "util/clock.h"
#include "util/json.h"

using namespace db;

namespace {

const std::string kPanelCredential = "test-panel-credential";
std::string panel_auth;

void installPanelSecret(Node& node) {
  auto values = std::make_shared<std::map<std::string, std::string>>();
  (*values)["panel.test"] = kPanelCredential;
  (*values)["webrtc.test"] = "pw";
  node.setSecureStore(
      [values](const std::string& key) {
        auto it = values->find(key);
        return it == values->end() ? std::string() : it->second;
      },
      [values](const std::string& key, const std::string& value) {
        if (value.empty()) values->erase(key);
        else (*values)[key] = value;
        return true;
      });
}

void stripTestCredential(std::string* value) {
  size_t pos = value->find("k=");
  while (pos != std::string::npos) {
    if (pos == 0 || (*value)[pos - 1] == '?' || (*value)[pos - 1] == '&') {
      size_t end = value->find('&', pos);
      if (end == std::string::npos) {
        value->erase(pos == 0 ? pos : pos - 1);
      } else {
        value->erase(pos, end - pos + 1);
      }
    }
    pos = value->find("k=", pos + 1);
  }
}

int panelFreePort(std::mt19937& /*rng*/) {
  // Ports come from one process-wide allocator; see core/tests/test_ports.h.
  return db::testing::freeListenPort();
}

std::string panelTempDir() {
  char path[] = "/tmp/doorbell_panel_XXXXXX";
  char* created = mkdtemp(path);
  REQUIRE(created != nullptr);
  return created;
}

bool setPanelEventProjectionFailure(const std::string& path, bool enabled) {
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

std::string panelReq(int port, const std::string& method, const std::string& path,
                     const std::string& body = "", const std::string& ctype = "") {
  int fd = ::socket(AF_INET, SOCK_STREAM, 0);
  REQUIRE(fd >= 0);
  sockaddr_in sa{};
  sa.sin_family = AF_INET;
  sa.sin_port = htons(static_cast<uint16_t>(port));
  sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  REQUIRE(::connect(fd, reinterpret_cast<sockaddr*>(&sa), sizeof(sa)) == 0);
  std::string safe_path = path, safe_body = body;
  stripTestCredential(&safe_path);
  stripTestCredential(&safe_body);
  std::string r = method + " " + safe_path + " HTTP/1.1\r\nHost: 127.0.0.1\r\n";
  if (!panel_auth.empty()) r += "Authorization: Bearer " + panel_auth + "\r\n";
  if (!safe_body.empty())
    r += "Content-Type: " + (ctype.empty() ? "application/json" : ctype) +
         "\r\nContent-Length: " + std::to_string(safe_body.size()) + "\r\n";
  r += "Connection: close\r\n\r\n" + safe_body;
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

json::Doc panelBodyJson(const std::string& response) {
  const size_t body = response.find("\r\n\r\n");
  return json::parse(body == std::string::npos ? "" : response.substr(body + 4));
}


std::vector<uint8_t> bgra(int w, int h, uint8_t base, uint8_t right) {
  std::vector<uint8_t> d(static_cast<size_t>(w) * h * 4);
  for (int y = 0; y < h; y++)
    for (int x = 0; x < w; x++) {
      uint8_t v = x < w / 2 ? base : right;
      size_t i = (static_cast<size_t>(y) * w + x) * 4;
      d[i] = d[i + 1] = d[i + 2] = v;
      d[i + 3] = 255;
    }
  return d;
}

}  // namespace

TEST_CASE("panel API: token auth / state / press / snapshot proxy / motion detection") {
  std::mt19937 rng(static_cast<uint32_t>(::getpid()) ^ 0x51a7u);
  int mesh_port = panelFreePort(rng);
  int http_port = panelFreePort(rng);
  REQUIRE(mesh_port > 0);
  REQUIRE(http_port > 0);

  NodeOptions o;
  o.data_dir = ":memory:";
  o.name = "panel-test";
  o.role = "door_station";
  o.door = "d_front";
  o.listen_addr = "127.0.0.1:" + std::to_string(mesh_port);
  o.psk.fill(0x77);
  o.enable_beacon = false;
  o.http_port = http_port;
  Node node(o);
  installPanelSecret(node);
  REQUIRE(node.start());
  node.setRuntimeCapabilities(
      R"({"features":{"call_flow_v2":true,"call_cancel_v2":true,"ui_manifest_v1":true}})");
  node.setUiManifest(
      R"({"schema_version":1,"units":"logical","viewport":{"minimum_touch":44,"scale_min":0.75,"scale_max":2.0},"elements":{"purpose.button":{"properties":["scale"],"defaults":{"scale":1.0},"safety_critical":false},"cancel.call":{"properties":["scale"],"defaults":{"scale":1.0},"safety_critical":true},"call.end":{"properties":["scale"],"defaults":{"scale":1.0},"safety_critical":true}}})");
  node.setConfigKey("doors.d_front", "{\"label\":{\"ja\":\"正面玄関\"}}");
  node.setConfigKey("panel.token_refs", "[\"secret:panel.test\"]");
  const std::string k = kPanelCredential;


  panel_auth.clear();
  CHECK(panelReq(http_port, "GET", "/api/panel/state").find("403") != std::string::npos);
  CHECK(panelReq(http_port, "GET", "/api/panel/state?k=wrong").find("403") != std::string::npos);
  panel_auth = k;


  std::string st = panelReq(http_port, "GET", "/api/panel/state?k=" + k);
  CHECK(st.find("HTTP/1.1 200") == 0);
  CHECK(st.find("\"d_front\"") != std::string::npos);
  CHECK(st.find("正面玄関") != std::string::npos);
  CHECK(st.find("\"calling\":false") != std::string::npos);
  CHECK(st.find("\"reply\":null") != std::string::npos);
  CHECK(st.find("\"source_node_id\"") != std::string::npos);
  CHECK(st.find("\"stream_mjpeg\":\"/stream.mjpeg\"") != std::string::npos);
  CHECK(st.find("\"playback_profile\"") != std::string::npos);
  CHECK(st.find("\"web_ui\"") != std::string::npos);
  CHECK(st.find("\"device_id\":\"" + node.nodeId() + "\"") != std::string::npos);
  auto initial_state = panelBodyJson(st);
  REQUIRE(initial_state);
  const cJSON* web_manifest = json::get(json::get(initial_state.get(), "web_ui"), "manifest");
  REQUIRE(cJSON_IsObject(web_manifest));
  CHECK(json::getString(web_manifest, "units") == "effective_px");
  const cJSON* web_elements = json::get(web_manifest, "elements");
  CHECK(cJSON_IsObject(json::get(web_elements, "call.primary")));
  const cJSON* web_sos = json::get(web_elements, "sos.trigger");
  REQUIRE(cJSON_IsObject(web_sos));
  CHECK(json::getBool(web_sos, "safety_critical"));
  CHECK(cJSON_GetArraySize(json::get(web_sos, "properties")) == 7);
  CHECK(cJSON_IsObject(json::get(web_elements, "reply.button")));
  CHECK(cJSON_IsObject(json::get(web_elements, "monitor.close")));
  const cJSON* quick_replies = json::get(initial_state.get(), "quick_replies");
  REQUIRE(cJSON_IsArray(quick_replies));
  bool found_away_reply = false;
  const cJSON* quick_reply = nullptr;
  cJSON_ArrayForEach(quick_reply, quick_replies) {
    if (json::getString(quick_reply, "id") != "qr_away") continue;
    found_away_reply = true;
    CHECK(!json::getString(quick_reply, "label").empty());
    CHECK(cJSON_IsObject(json::get(quick_reply, "labels")));
  }
  CHECK(found_away_reply);
  const cJSON* cancel_properties =
      json::get(json::get(web_elements, "cancel.call"), "properties");
  REQUIRE(cJSON_IsArray(cancel_properties));
  CHECK(cJSON_GetArraySize(cancel_properties) == 1);
  const cJSON* cancel_property = cJSON_GetArrayItem(cancel_properties, 0);
  REQUIRE(cJSON_IsString(cancel_property));
  CHECK(std::string(cancel_property->valuestring) == "scale");

  node.setConfigKey("devices." + node.nodeId() + ".local.ui.elements.ring.title",
                    R"({"foreground":"#FFFFFF"})");
  bool saw_web_only_style = false;
  for (int i = 0; i < 20; ++i) {
    auto config = json::parse(node.configJson());
    const cJSON* value = config.get();
    for (const std::string& part : {std::string("devices"), node.nodeId(),
                                    std::string("local"), std::string("ui"),
                                    std::string("elements"), std::string("ring"),
                                    std::string("title")})
      value = json::get(value, part.c_str());
    const cJSON* title = value;
    saw_web_only_style = json::getString(title, "foreground") == "#FFFFFF";
    if (saw_web_only_style) break;
    usleep(20 * 1000);
  }
  CHECK(saw_web_only_style);

  node.setConfigKey("devices." + node.nodeId() + ".local.ui.elements.cancel.call",
                    R"({"scale":1.25})");
  for (int i = 0; i < 20; ++i) {
    st = panelReq(http_port, "GET", "/api/panel/state?k=" + k);
    if (st.find("\"scale\":1.25") != std::string::npos) break;
    usleep(20 * 1000);
  }
  CHECK(st.find("\"scale\":1.25") != std::string::npos);

  CHECK(panelReq(http_port, "POST", "/api/panel/ui-report",
                 R"({"schema_version":1,"page":"door","applied":true,"rejected":false,"lkg_used":false,"lkg_persisted":true,"last_error":"","elements":["cancel.call"]})")
            .find("\"ok\":true") != std::string::npos);
  bool saw_web_report = false;
  for (int i = 0; i < 20; ++i) {
    const std::string status = node.statusJson();
    saw_web_report = status.find("\"web_ui_style\"") != std::string::npos &&
                     status.find("\"client\":\"web\"") != std::string::npos;
    if (saw_web_report) break;
    usleep(20 * 1000);
  }
  CHECK(saw_web_report);
  CHECK(panelReq(http_port, "POST", "/api/panel/ui-report",
                 R"({"schema_version":1,"page":"door","applied":true,"elements":[]})")
            .find("400") != std::string::npos);


  {
    size_t body_at = st.find("\r\n\r\n");
    REQUIRE(body_at != std::string::npos);
    auto sj = json::parse(st.substr(body_at + 4));
    REQUIRE(sj);
    cJSON* ps = json::get(sj.get(), "purposes");
    REQUIRE(cJSON_IsArray(ps));
    REQUIRE(cJSON_GetArraySize(ps) == 6);
    cJSON* first = cJSON_GetArrayItem(ps, 0);
    CHECK(json::getString(first, "id") == "p_visit");
    CHECK(json::getString(first, "icon") == "🏠");
    CHECK(json::getString(json::get(first, "label"), "en") == "Visit");
    cJSON* langs = json::get(sj.get(), "languages");
    REQUIRE(cJSON_IsArray(langs));
    CHECK(cJSON_GetArraySize(langs) == 3);  // ja/en/zh
  }


  panel_auth.clear();
  CHECK(panelReq(http_port, "GET", "/api/panel/i18n").find("403") != std::string::npos);
  panel_auth = k;
  {
    std::string r = panelReq(http_port, "GET", "/api/panel/i18n?k=" + k);
    CHECK(r.find("HTTP/1.1 200") == 0);
    CHECK(r.find("\"overrides\":{}") != std::string::npos);
  }
  node.setConfigKey("i18n_overrides.ja",
                    "{\"idle.touch_to_call\":\"タッチして呼び出してください\"}");
  {
    std::string r = panelReq(http_port, "GET", "/api/panel/i18n?k=" + k);
    CHECK(r.find("タッチして呼び出してください") != std::string::npos);
    CHECK(r.find("\"languages\"") != std::string::npos);
  }


  const std::string first_press = panelReq(http_port, "POST", "/api/panel/press",
                                           "door=d_front&k=" + k,
                                           "application/x-www-form-urlencoded");
  CHECK(first_press.find("\"ok\":true") != std::string::npos);
  auto first_press_json = panelBodyJson(first_press);
  REQUIRE(first_press_json);
  const std::string first_call_id = json::getString(first_press_json.get(), "call_id");
  REQUIRE(!first_call_id.empty());
  const std::string browser_dialog = "0123456789abcdef0123456789abcdef";
  st = panelReq(http_port, "GET", "/api/panel/state?k=" + k);
  CHECK(st.find("\"calling\":true") != std::string::npos);
  CHECK(st.find("\"press\"") != std::string::npos);

  CHECK(panelReq(http_port, "POST", "/api/panel/press", "door=nope&k=" + k,
                 "application/x-www-form-urlencoded")
            .find("400") != std::string::npos);
  CHECK(panelReq(http_port, "POST", "/api/panel/hangup",
                 "door=d_front&call_id=" + first_call_id + "&k=" + k,
                 "application/x-www-form-urlencoded").find("409") != std::string::npos);
  CHECK(panelReq(http_port, "POST", "/api/panel/call-lifecycle",
                 "door=d_front&call_id=" + first_call_id +
                     "&stage_revision=1&state=answered&dialog_id=" + browser_dialog + "&k=" + k,
                 "application/x-www-form-urlencoded").find("409") != std::string::npos);
  CHECK(panelReq(http_port, "POST", "/api/panel/call-lifecycle",
                 "door=d_front&call_id=" + first_call_id +
                     "&stage_revision=0&state=answered&dialog_id=" + browser_dialog + "&k=" + k,
                 "application/x-www-form-urlencoded").find("\"ok\":true") !=
        std::string::npos);
  const std::string losing_dialog = "fedcba9876543210fedcba9876543210";
  CHECK(panelReq(http_port, "POST", "/api/panel/call-lifecycle",
                 "door=d_front&call_id=" + first_call_id +
                     "&stage_revision=0&state=answered&dialog_id=" + losing_dialog + "&k=" + k,
                 "application/x-www-form-urlencoded").find("409") != std::string::npos);
  CHECK(panelReq(http_port, "POST", "/api/panel/call-lifecycle",
                 "door=d_front&call_id=" + first_call_id +
                     "&stage_revision=0&state=heartbeat&dialog_id=" + browser_dialog + "&k=" + k,
                 "application/x-www-form-urlencoded").find("\"ok\":true") !=
        std::string::npos);
  CHECK(panelReq(http_port, "POST", "/api/panel/call-lifecycle",
                 "door=d_front&call_id=" + first_call_id +
                     "&stage_revision=0&state=heartbeat&dialog_id=" + losing_dialog + "&k=" + k,
                 "application/x-www-form-urlencoded").find("409") != std::string::npos);
  CHECK(panelReq(http_port, "POST", "/api/panel/cancel",
                 "door=d_front&call_id=" + first_call_id + "&k=" + k,
                 "application/x-www-form-urlencoded").find("409") != std::string::npos);
  CHECK(panelReq(http_port, "POST", "/api/panel/hangup",
                 "door=d_front&call_id=" + first_call_id + "&k=" + k,
                 "application/x-www-form-urlencoded").find("\"ok\":true") !=
        std::string::npos);
  st = panelReq(http_port, "GET", "/api/panel/state?k=" + k);
  {
    auto state = panelBodyJson(st);
    REQUIRE(state);
    const cJSON* door = cJSON_GetArrayItem(json::get(state.get(), "doors"), 0);
    REQUIRE(cJSON_IsObject(door));
    CHECK_FALSE(json::getBool(door, "calling"));
    CHECK(json::getString(door, "call_id") == first_call_id);
    CHECK(json::getString(door, "call_state") == "ended");
    CHECK(json::getString(door, "terminal_reason") == "visitor_hangup");
    CHECK(json::getInt(door, "terminal_at_ms") > 0);
    CHECK_FALSE(json::getBool(door, "recovery_required"));
  }
  // A shell callback racing the panel hangup is idempotent for the same call and revision.
  CHECK(panelReq(http_port, "POST", "/api/panel/call-lifecycle",
                 "door=d_front&call_id=" + first_call_id +
                     "&stage_revision=0&state=ended&dialog_id=" + browser_dialog +
                     "&reason=sip_ended&k=" + k,
                 "application/x-www-form-urlencoded").find("\"ok\":true") !=
        std::string::npos);

  const std::string delivery_press = panelReq(
      http_port, "POST", "/api/panel/press",
      "door=d_front&purpose=p_delivery&k=" + k,
      "application/x-www-form-urlencoded");
  CHECK(delivery_press.find("\"ok\":true") != std::string::npos);
  auto delivery_press_json = panelBodyJson(delivery_press);
  REQUIRE(delivery_press_json);
  const std::string delivery_call_id = json::getString(delivery_press_json.get(), "call_id");
  REQUIRE(!delivery_call_id.empty());
  st = panelReq(http_port, "GET", "/api/panel/state?k=" + k);
  CHECK(st.find("\"purpose\":\"p_delivery\"") != std::string::npos);
  CHECK(panelReq(http_port, "POST", "/api/panel/press", "door=d_front&purpose=p_nope&k=" + k,
                 "application/x-www-form-urlencoded")
            .find("400") != std::string::npos);

  REQUIRE(node.cancelCallV2("d_front", delivery_call_id, "visitor"));
  st = panelReq(http_port, "GET", "/api/panel/state?k=" + k);
  {
    auto state = panelBodyJson(st);
    REQUIRE(state);
    const cJSON* door = cJSON_GetArrayItem(json::get(state.get(), "doors"), 0);
    REQUIRE(cJSON_IsObject(door));
    CHECK(json::getString(door, "call_id") == delivery_call_id);
    CHECK(json::getString(door, "call_state") == "cancelled");
    CHECK(json::getString(door, "terminal_reason") == "visitor");
  }

  const std::string expiring_call_id = node.pressV2("d_front", "p_delivery");
  REQUIRE(!expiring_call_id.empty());
  REQUIRE(node.cancelCallV2("d_front", expiring_call_id, "timeout"));
  st = panelReq(http_port, "GET", "/api/panel/state?k=" + k);
  {
    auto state = panelBodyJson(st);
    REQUIRE(state);
    const cJSON* door = cJSON_GetArrayItem(json::get(state.get(), "doors"), 0);
    REQUIRE(cJSON_IsObject(door));
    CHECK(json::getString(door, "call_id") == expiring_call_id);
    CHECK(json::getString(door, "call_state") == "expired");
    CHECK(json::getString(door, "terminal_reason") == "timeout");
  }

  const std::string reply_call_id = node.pressV2("d_front", "p_delivery");
  REQUIRE(!reply_call_id.empty());
  CHECK(panelReq(http_port, "POST", "/api/panel/reply",
                 "reply_id=missing&door=d_front&call_id=" + reply_call_id +
                     "&stage_revision=0&k=" + k,
                 "application/x-www-form-urlencoded").find("400") != std::string::npos);
  CHECK(panelReq(http_port, "POST", "/api/panel/reply",
                 "reply_id=qr_away&door=d_front&call_id=stale&stage_revision=0&k=" + k,
                 "application/x-www-form-urlencoded").find("409") != std::string::npos);
  CHECK(panelReq(http_port, "POST", "/api/panel/reply",
                 "reply_id=qr_away&door=d_front&call_id=" + reply_call_id +
                     "&stage_revision=0&k=" + k,
                 "application/x-www-form-urlencoded").find("\"ok\":true") !=
        std::string::npos);
  st = panelReq(http_port, "GET", "/api/panel/state?k=" + k);
  CHECK(st.find("ただいま留守にしています") != std::string::npos);
  CHECK(st.find("\"calling\":false") != std::string::npos);


  CHECK(panelReq(http_port, "GET", "/snapshot-proxy?door=d_front&k=" + k)
            .find("503") != std::string::npos);
  auto f0 = bgra(64, 48, 100, 100);
  node.pushCameraFrame(f0.data(), 3 /*BGRA*/, 64, 48, 64 * 4, 1000);
  std::string snap = panelReq(http_port, "GET", "/snapshot-proxy?door=d_front&k=" + k);
  CHECK(snap.find("HTTP/1.1 200") == 0);
  CHECK(snap.find("image/jpeg") != std::string::npos);
  CHECK(snap.find("\xFF\xD8\xFF") != std::string::npos);  // JPEG SOI


  for (int i = 0; i < 6; i++) node.pushCameraFrame(f0.data(), 3, 64, 48, 64 * 4, 2000 + i);

  auto f1 = bgra(64, 48, 100, 250);
  auto f2 = bgra(64, 48, 100, 60);
  node.pushCameraFrame(f1.data(), 3, 64, 48, 64 * 4, 3000);
  node.pushCameraFrame(f2.data(), 3, 64, 48, 64 * 4, 3100);

  for (int i = 0; i < 50; i++) {
    st = panelReq(http_port, "GET", "/api/panel/state?k=" + k);
    if (st.find("\"motion\"") != std::string::npos) break;
    usleep(100 * 1000);
  }
  CHECK(st.find("\"motion\"") != std::string::npos);

  // Rules decorate active-page presentation, while replicated SOS state remains visible even to
  // a different or zero-recipient Web group.
  node.setConfigKey(
      "trigger_rules.r_sos_default_on",
      "{\"enabled\":true,\"when\":{\"type\":\"emergency_on\"},\"actions\":[{"
      "\"type\":\"device_alert\",\"targets\":{\"web_profiles\":[\"guards\"]},"
      "\"channels\":[\"in_app\"],\"presentation\":{\"background\":\"#102040\","
      "\"foreground\":\"#FFFFFF\",\"accent\":\"#FFD166\"}}]}" );
  node.setEmergency(true, "test");
  for (int i = 0; i < 20; ++i) {
    st = panelReq(http_port, "GET", "/api/panel/state?group=guards&k=" + k);
    if (st.find("\"device_alert\":{\"schema_version\":2,\"active\":true") !=
        std::string::npos)
      break;
    usleep(20 * 1000);
  }
  CHECK(st.find("\"device_alert\":{\"schema_version\":2,\"active\":true") !=
        std::string::npos);
  {
    auto state = panelBodyJson(st);
    REQUIRE(state);
    const cJSON* presentation =
        json::get(json::get(state.get(), "device_alert"), "presentation");
    REQUIRE(cJSON_IsObject(presentation));
    CHECK(json::getBool(presentation, "visual"));
    CHECK(json::getBool(presentation, "sticky"));
    CHECK(json::getString(presentation, "sound") == "siren1");
    CHECK(json::getInt(presentation, "volume") == 100);
    CHECK(json::getString(presentation, "background") == "#102040");
    CHECK(json::getString(presentation, "foreground") == "#FFFFFF");
    CHECK(json::getString(presentation, "accent") == "#FFD166");
  }
  st = panelReq(http_port, "GET", "/api/panel/state?group=residents&k=" + k);
  CHECK(st.find("\"emergency\":{\"active\":true") != std::string::npos);
  CHECK(st.find("\"web_active_page_alerts\":true") != std::string::npos);
  CHECK(st.find("\"device_alert\":null") != std::string::npos);
  node.setConfigKey("emergency.web_active_page_alerts", "false");
  for (int i = 0; i < 20; ++i) {
    st = panelReq(http_port, "GET", "/api/panel/state?group=residents&k=" + k);
    if (st.find("\"web_active_page_alerts\":false") != std::string::npos) break;
    usleep(20 * 1000);
  }
  CHECK(st.find("\"emergency\":{\"active\":true") != std::string::npos);
  CHECK(st.find("\"web_active_page_alerts\":false") != std::string::npos);

  // With raw active-page handling disabled, a matching Web-Push-only rule remains projected so
  // the next state poll does not erase the Push overlay before its TTL or an explicit clear.
  node.setConfigKey(
      "trigger_rules.r_sos_default_on",
      "{\"enabled\":true,\"when\":{\"type\":\"emergency_on\"},\"actions\":[{"
      "\"type\":\"device_alert\",\"targets\":{\"web_profiles\":[\"guards\"]},"
      "\"channels\":[\"web_push\"],\"presentation\":{\"sticky\":true}}]}" );
  for (int i = 0; i < 20; ++i) {
    st = panelReq(http_port, "GET", "/api/panel/state?group=guards&k=" + k);
    if (st.find("\"device_alert\":{\"schema_version\":2,\"active\":true") !=
        std::string::npos)
      break;
    usleep(20 * 1000);
  }
  CHECK(st.find("\"device_alert\":{\"schema_version\":2,\"active\":true") !=
        std::string::npos);
  CHECK(st.find("\"channels\":[\"web_push\"]") != std::string::npos);

  node.stop();
}

TEST_CASE("panel dialog lease retries a failed durable recovery cancellation") {
  std::mt19937 rng(static_cast<uint32_t>(::getpid()) ^ 0x1ea5eu);
  const int mesh_port = panelFreePort(rng);
  const int http_port = panelFreePort(rng);
  const std::string dir = panelTempDir();
  const std::string db_path = dir + "/doorbell.db";
  REQUIRE(mesh_port > 0);
  REQUIRE(http_port > 0);

  SimClock clock(1'700'000'000'000LL, 0);
  Runloop loop(clock);
  loop.start();
  NodeOptions options;
  options.data_dir = dir;
  options.name = "panel-lease-retry";
  options.role = "door_station";
  options.door = "d_front";
  options.listen_addr = "127.0.0.1:" + std::to_string(mesh_port);
  options.psk.fill(0x6d);
  options.enable_beacon = false;
  options.http_port = http_port;
  NodeDeps deps;
  deps.clock = &clock;
  deps.loop = &loop;
  Node node(options, std::move(deps));
  installPanelSecret(node);
  REQUIRE(node.start());
  node.setConfigKey("doors.d_front", "{\"label\":{\"en\":\"Front door\"}}");
  node.setConfigKey("panel.token_refs", "[\"secret:panel.test\"]");
  panel_auth = kPanelCredential;

  auto pressed = panelBodyJson(panelReq(http_port, "POST", "/api/panel/press",
                                        "door=d_front&k=" + kPanelCredential,
                                        "application/x-www-form-urlencoded"));
  REQUIRE(pressed);
  const std::string call_id = json::getString(pressed.get(), "call_id");
  REQUIRE(!call_id.empty());
  const std::string dialog_id = "0123456789abcdef0123456789abcdef";
  CHECK(panelReq(http_port, "POST", "/api/panel/call-lifecycle",
                 "door=d_front&call_id=" + call_id +
                     "&stage_revision=0&state=answered&dialog_id=" + dialog_id +
                     "&k=" + kPanelCredential,
                 "application/x-www-form-urlencoded").find("\"ok\":true") !=
        std::string::npos);

  REQUIRE(setPanelEventProjectionFailure(db_path, true));
  clock.advance(9'999);
  std::string state = panelReq(http_port, "GET", "/api/panel/state?k=" + kPanelCredential);
  CHECK(state.find("\"call_id\":\"" + call_id + "\"") != std::string::npos);
  CHECK(state.find("\"call_state\":\"in_call\"") != std::string::npos);
  clock.advance(1);
  state = panelReq(http_port, "GET", "/api/panel/state?k=" + kPanelCredential);
  CHECK(state.find("\"call_state\":\"in_call\"") != std::string::npos);

  REQUIRE(setPanelEventProjectionFailure(db_path, false));
  clock.advance(1'999);
  state = panelReq(http_port, "GET", "/api/panel/state?k=" + kPanelCredential);
  CHECK(state.find("\"call_state\":\"in_call\"") != std::string::npos);
  clock.advance(1);
  state = panelReq(http_port, "GET", "/api/panel/state?k=" + kPanelCredential);
  CHECK(state.find("\"call_id\":\"" + call_id + "\"") != std::string::npos);
  CHECK(state.find("\"call_state\":\"cancelled\"") != std::string::npos);
  CHECK(state.find("\"terminal_reason\":\"recovery_timeout\"") != std::string::npos);

  node.stop();
  loop.stop();
  panel_auth.clear();
  {
    Store store;
    REQUIRE(store.open(db_path));
    CHECK(store.countEventsOfType("call_cancelled") == 1);
  }
  for (const char* name : {"doorbell.db", "doorbell.db-wal", "doorbell.db-shm"})
    std::remove((dir + "/" + name).c_str());
  ::rmdir((dir + "/assets").c_str());
  ::rmdir(dir.c_str());
}

TEST_CASE("panel state retains terminal calls across restart for a bounded interval") {
  std::mt19937 rng(static_cast<uint32_t>(::getpid()) ^ 0x7e4du);
  const int mesh_port = panelFreePort(rng);
  const int http_port = panelFreePort(rng);
  const std::string dir = panelTempDir();
  REQUIRE(mesh_port > 0);
  REQUIRE(http_port > 0);

  NodeOptions options;
  options.data_dir = dir;
  options.name = "panel-terminal";
  options.role = "door_station";
  options.door = "d_front";
  options.listen_addr = "127.0.0.1:" + std::to_string(mesh_port);
  options.psk.fill(0x7b);
  options.enable_beacon = false;
  options.http_port = http_port;
  SimClock clock(1'700'000'000'000LL, 0);
  std::string call_id;

  {
    NodeDeps deps;
    deps.clock = &clock;
    Node node(options, std::move(deps));
    installPanelSecret(node);
    REQUIRE(node.start());
    node.setConfigKey("doors.d_front", "{\"label\":{\"en\":\"Front door\"}}");
    node.setConfigKey("panel.token_refs", "[\"secret:panel.test\"]");
    panel_auth = kPanelCredential;
    call_id = node.pressV2("d_front", "");
    REQUIRE(!call_id.empty());
    REQUIRE(node.cancelCallV2("d_front", call_id, "visitor"));
    auto state = panelBodyJson(panelReq(http_port, "GET", "/api/panel/state"));
    REQUIRE(state);
    const cJSON* door = cJSON_GetArrayItem(json::get(state.get(), "doors"), 0);
    REQUIRE(cJSON_IsObject(door));
    CHECK(json::getString(door, "call_id") == call_id);
    CHECK(json::getString(door, "call_state") == "cancelled");
    node.stop();
  }

  {
    NodeDeps deps;
    deps.clock = &clock;
    Node node(options, std::move(deps));
    installPanelSecret(node);
    REQUIRE(node.start());
    panel_auth = kPanelCredential;
    auto state = panelBodyJson(panelReq(http_port, "GET", "/api/panel/state"));
    REQUIRE(state);
    const cJSON* restored = cJSON_GetArrayItem(json::get(state.get(), "doors"), 0);
    REQUIRE(cJSON_IsObject(restored));
    CHECK(json::getString(restored, "call_id") == call_id);
    CHECK(json::getString(restored, "call_state") == "cancelled");
    CHECK_FALSE(json::getBool(restored, "recovery_required"));

    clock.advance(30'001);
    state = panelBodyJson(panelReq(http_port, "GET", "/api/panel/state"));
    REQUIRE(state);
    const cJSON* expired = cJSON_GetArrayItem(json::get(state.get(), "doors"), 0);
    REQUIRE(cJSON_IsObject(expired));
    CHECK(json::getString(expired, "call_id").empty());
    CHECK(json::getString(expired, "call_state").empty());
    node.stop();
  }

  panel_auth.clear();
  for (const char* name : {"doorbell.db", "doorbell.db-wal", "doorbell.db-shm"})
    std::remove((dir + "/" + name).c_str());
  ::rmdir((dir + "/assets").c_str());
  ::rmdir(dir.c_str());
}

TEST_CASE("panel recovery reports a restored visitor call exactly once") {
  std::mt19937 rng(static_cast<uint32_t>(::getpid()) ^ 0x4ec0u);
  const int mesh_port = panelFreePort(rng);
  const int http_port = panelFreePort(rng);
  const std::string dir = panelTempDir();
  REQUIRE(mesh_port > 0);
  REQUIRE(http_port > 0);

  NodeOptions options;
  options.data_dir = dir;
  options.name = "panel-recovery";
  options.role = "door_station";
  options.door = "d_front";
  options.listen_addr = "127.0.0.1:" + std::to_string(mesh_port);
  options.psk.fill(0x79);
  options.enable_beacon = false;
  options.http_port = http_port;

  std::string token = kPanelCredential;
  std::string call_id;
  {
    Node node(options);
    installPanelSecret(node);
    REQUIRE(node.start());
    node.setConfigKey("doors.d_front", "{\"label\":{\"en\":\"Front door\"}}");
    node.setConfigKey("panel.token_refs", "[\"secret:panel.test\"]");
    panel_auth = token;
    auto pressed = panelBodyJson(panelReq(http_port, "POST", "/api/panel/press",
                                          "door=d_front&k=" + token,
                                          "application/x-www-form-urlencoded"));
    REQUIRE(pressed);
    call_id = json::getString(pressed.get(), "call_id");
    REQUIRE(!call_id.empty());
    node.stop();
  }

  {
    Node node(options);
    installPanelSecret(node);
    REQUIRE(node.start());
    panel_auth = token;
    std::string state = panelReq(http_port, "GET", "/api/panel/state?k=" + token);
    CHECK(state.find("\"call_id\":\"" + call_id + "\"") != std::string::npos);
    CHECK(state.find("\"recovery_required\":true") != std::string::npos);
    panel_auth.clear();
    CHECK(panelReq(http_port, "POST", "/api/panel/recovery",
                   "door=d_front&call_id=" + call_id + "&restored=true&k=wrong",
                   "application/x-www-form-urlencoded").find("403") != std::string::npos);
    panel_auth = token;
    CHECK(panelReq(http_port, "POST", "/api/panel/recovery",
                   "door=d_front&call_id=stale&restored=true&k=" + token,
                   "application/x-www-form-urlencoded").find("409") != std::string::npos);
    CHECK(panelReq(http_port, "POST", "/api/panel/recovery",
                   "door=d_front&call_id=" + call_id + "&restored=true&k=" + token,
                   "application/x-www-form-urlencoded").find("\"ok\":true") !=
          std::string::npos);
    CHECK(panelReq(http_port, "POST", "/api/panel/recovery",
                   "door=d_front&call_id=" + call_id + "&restored=true&k=" + token,
                   "application/x-www-form-urlencoded").find("409") != std::string::npos);
    state = panelReq(http_port, "GET", "/api/panel/state?k=" + token);
    CHECK(state.find("\"recovery_required\":false") != std::string::npos);
    node.stop();
  }

  for (const char* name : {"doorbell.db", "doorbell.db-wal", "doorbell.db-shm"})
    std::remove((dir + "/" + name).c_str());
  ::rmdir((dir + "/assets").c_str());
  ::rmdir(dir.c_str());
}

TEST_CASE("panel recovery cannot claim a restarted native SIP dialog") {
  std::mt19937 rng(static_cast<uint32_t>(::getpid()) ^ 0x5ec0u);
  const int mesh_port = panelFreePort(rng);
  const int http_port = panelFreePort(rng);
  const std::string dir = panelTempDir();
  REQUIRE(mesh_port > 0);
  REQUIRE(http_port > 0);

  NodeOptions options;
  options.data_dir = dir;
  options.name = "panel-native-recovery";
  options.role = "door_station";
  options.door = "d_front";
  options.listen_addr = "127.0.0.1:" + std::to_string(mesh_port);
  options.psk.fill(0x7a);
  options.enable_beacon = false;
  options.http_port = http_port;

  std::string call_id;
  {
    Node node(options);
    installPanelSecret(node);
    REQUIRE(node.start());
    node.setConfigKey("doors.d_front", "{\"label\":{\"en\":\"Front door\"}}");
    node.setConfigKey("panel.token_refs", "[\"secret:panel.test\"]");
    call_id = node.pressV2("d_front", "");
    REQUIRE(!call_id.empty());
    CHECK(node.reportCallAnsweredV2("d_front", call_id, 0));
    node.stop();
  }

  {
    Node node(options);
    installPanelSecret(node);
    REQUIRE(node.start());
    panel_auth = kPanelCredential;
    CHECK(panelReq(http_port, "POST", "/api/panel/recovery",
                   "door=d_front&call_id=" + call_id + "&restored=true",
                   "application/x-www-form-urlencoded")
              .find("native dialog recovery requires platform ABI") != std::string::npos);
    CHECK(panelReq(http_port, "POST", "/api/panel/recovery",
                   "door=d_front&call_id=" + call_id + "&restored=false",
                   "application/x-www-form-urlencoded").find("\"ok\":true") !=
          std::string::npos);
    auto state = panelBodyJson(panelReq(http_port, "GET", "/api/panel/state"));
    REQUIRE(state);
    const cJSON* door = cJSON_GetArrayItem(json::get(state.get(), "doors"), 0);
    REQUIRE(cJSON_IsObject(door));
    CHECK(json::getString(door, "call_id") == call_id);
    CHECK(json::getString(door, "call_state") == "cancelled");
    CHECK(json::getString(door, "terminal_reason") == "recovery_failed");
    CHECK_FALSE(json::getBool(door, "recovery_required"));
    node.stop();
  }

  for (const char* name : {"doorbell.db", "doorbell.db-wal", "doorbell.db-shm"})
    std::remove((dir + "/" + name).c_str());
  ::rmdir((dir + "/assets").c_str());
  ::rmdir(dir.c_str());
}

TEST_CASE("panel API: call-frame / peer-frame.jpg / call-info web call contract") {
  std::mt19937 rng(static_cast<uint32_t>(::getpid()) ^ 0xca11u);
  int mesh_port = panelFreePort(rng);
  int http_port = panelFreePort(rng);
  REQUIRE(mesh_port > 0);
  REQUIRE(http_port > 0);

  NodeOptions o;
  o.data_dir = ":memory:";
  o.name = "callframe-test";
  o.role = "door_station";
  o.door = "d_front";
  o.listen_addr = "127.0.0.1:" + std::to_string(mesh_port);
  o.psk.fill(0x78);
  o.enable_beacon = false;
  o.http_port = http_port;
  Node node(o);
  installPanelSecret(node);
  REQUIRE(node.start());
  node.setConfigKey("doors.d_front", "{\"label\":{\"ja\":\"正面玄関\"}}");
  node.setConfigKey("panel.token_refs", "[\"secret:panel.test\"]");
  node.setConfigKey("sip.accounts." + node.nodeId(), "{\"user\":\"8001\"}");
  node.setConfigKey("integrations.webrtc",
                    "{\"ws_url\":\"ws://10.0.1.5:8088/ws\",\"sip_user\":\"260\","
                    "\"sip_pass_ref\":\"secret:webrtc.test\"}");
  const std::string k = kPanelCredential;


  std::string jpg = "\xFF\xD8\xFF\xE0 fake-jpeg-body";


  panel_auth.clear();
  std::string r = panelReq(http_port, "POST", "/call-frame?door=d_front", jpg, "image/jpeg");
  CHECK(r.find("403") != std::string::npos);
  CHECK(r.find("Access-Control-Allow-Origin: *") != std::string::npos);
  panel_auth = k;

  r = panelReq(http_port, "POST", "/call-frame?door=d_front&k=" + k, jpg, "image/jpeg");
  CHECK(r.find("409") != std::string::npos);
  CHECK(r.find("not in call") != std::string::npos);

  r = panelReq(http_port, "POST", "/call-frame?door=d_other&k=" + k, jpg, "image/jpeg");
  CHECK(r.find("404") != std::string::npos);
  // CORS preflight
  r = panelReq(http_port, "OPTIONS", "/call-frame");
  CHECK(r.find("204") != std::string::npos);
  CHECK(r.find("Access-Control-Allow-Methods: POST, OPTIONS") != std::string::npos);


  r = panelReq(http_port, "GET", "/peer-frame.jpg");
  CHECK(r.find("404") != std::string::npos);


  r = panelReq(http_port, "GET", "/api/panel/call-info?k=" + k);
  CHECK(r.find("HTTP/1.1 200") == 0);
  CHECK(r.find("ws://10.0.1.5:8088/ws") != std::string::npos);
  CHECK(r.find("\"sip_user\":\"260\"") != std::string::npos);
  CHECK(r.find("\"extension\":\"8001\"") != std::string::npos);
  CHECK(r.find("\"online\":true") != std::string::npos);
  CHECK(r.find("\"stream_mjpeg\":\"/stream.mjpeg\"") != std::string::npos);
  CHECK(r.find("\"playback_profile\"") != std::string::npos);

  panel_auth.clear();
  CHECK(panelReq(http_port, "GET", "/api/panel/call-info").find("403") != std::string::npos);

  node.stop();
}
