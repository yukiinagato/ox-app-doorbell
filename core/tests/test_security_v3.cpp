// Security protocol v3 (docs/en/security-v3.md): TLS identity and listener, pinned Core-to-Core
// HTTPS, media authentication, Argon2id administrator digests, the native admin window, SIP
// admission on both the peer and registrar paths, and the MQTT packet cap.
#include "doctest.h"

#include <chrono>
#include <map>
#include <string>
#include <thread>

#include "bridge/mqtt_client.h"
#include "doorbell/doorbell.h"
#include "httpd/httpd.h"
#include "node/admin_password.h"
#include "node/node.h"
#include "sipctl/sip_auth.h"
#include "test_env.h"
#include "tls/tls.h"
#include "util/clock.h"
#include "util/common.h"
#include "util/json.h"
#include "util/runloop.h"

using namespace db;

namespace {

bool waitUntil(const std::function<bool()>& predicate, int timeout_ms) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
  while (std::chrono::steady_clock::now() < deadline) {
    if (predicate()) return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
  }
  return predicate();
}

struct Reply {
  int status = 0;
  std::string body;
};

Reply fetch(const tls::Endpoint& endpoint, const std::string& path,
            std::map<std::string, std::string> headers = {}, const std::string& method = "GET",
            const std::string& body = "", std::string* set_cookie = nullptr) {
  tls::HttpStream stream(endpoint, path, std::move(headers), method, body);
  Reply reply;
  if (!stream.open(5000)) return reply;
  reply.status = stream.status();
  if (set_cookie) *set_cookie = stream.header("set-cookie");
  Bytes bytes;
  stream.readAll(1024 * 1024, 5000, &bytes);
  reply.body.assign(bytes.begin(), bytes.end());
  return reply;
}

}  // namespace

TEST_CASE("security v3: TLS identity round-trips and rejects a mismatched key") {
  tls::Identity first, second, loaded;
  std::string error;
  REQUIRE(tls::generateIdentity("doorbell-test", &first, &error));
  REQUIRE(tls::generateIdentity("doorbell-other", &second, &error));
  CHECK(first.sha256_hex.size() == 64);
  CHECK(first.sha256_hex != second.sha256_hex);
  CHECK(first.cert_pem.find("BEGIN CERTIFICATE") != std::string::npos);
  CHECK(first.key_pem.find("PRIVATE KEY") != std::string::npos);
  REQUIRE(tls::loadIdentity(first.cert_pem, first.key_pem, &loaded));
  CHECK(loaded.sha256_hex == first.sha256_hex);
  CHECK_FALSE(tls::loadIdentity(first.cert_pem, second.key_pem, &loaded));
  CHECK_FALSE(tls::loadIdentity("", first.key_pem, &loaded));
}

TEST_CASE("security v3: redirect target and loopback classification") {
  CHECK(httpLoopbackAddress("127.0.0.1"));
  CHECK(httpLoopbackAddress("127.8.9.10"));
  CHECK(httpLoopbackAddress("::1"));
  CHECK(httpLoopbackAddress("::ffff:127.0.0.1"));
  CHECK_FALSE(httpLoopbackAddress("10.0.0.5"));
  CHECK_FALSE(httpLoopbackAddress("::ffff:10.0.0.5"));
  CHECK_FALSE(httpLoopbackAddress(""));
  CHECK(httpsRedirectLocation("10.0.0.5:47180", 47443, "/admin/", "") ==
        "https://10.0.0.5:47443/admin/");
  CHECK(httpsRedirectLocation("doorbell.local", 47443, "/panel/door.html", "k=1") ==
        "https://doorbell.local:47443/panel/door.html?k=1");
  CHECK(httpsRedirectLocation("[fe80::1]:47180", 47443, "/", "") == "https://[fe80::1]:47443/");
  CHECK(httpsRedirectLocation("evil.example\r\nX: y", 47443, "/", "").empty());
  CHECK(httpsRedirectLocation("", 47443, "/", "").empty());
  CHECK(httpsRedirectLocation("10.0.0.5", 0, "/", "").empty());
}

TEST_CASE("security v3: HTTPS listener with a pinned client and Secure cookies") {
  RealClock clock;
  Runloop loop(clock);
  loop.start();
  tls::Identity identity, other;
  std::string error;
  REQUIRE(tls::generateIdentity("listener", &identity, &error));
  REQUIRE(tls::generateIdentity("impostor", &other, &error));
  Httpd httpd(loop);
  httpd.route("GET", "/hello", [](const HttpReq& req) {
    return HttpResp::json(std::string("{\"tls\":") + (req.tls ? "true" : "false") + "}");
  });
  const int port = testing::freeListenPort();
  const int tls_port = testing::freeListenPort();
  httpd.setTls(Httpd::TlsConfig{tls_port, tls::listenerPem(identity)});
  REQUIRE(httpd.start(port, Httpd::Ipv6Mode::Off));
  REQUIRE(httpd.tlsActive());
  CHECK(httpd.tlsPort() == tls_port);

  const Reply secure = fetch({"127.0.0.1", tls_port, true, identity.sha256_hex}, "/hello");
  CHECK(secure.status == 200);
  CHECK(secure.body == "{\"tls\":true}");

  tls::HttpStream wrong_pin({"127.0.0.1", tls_port, true, other.sha256_hex}, "/hello", {});
  CHECK_FALSE(wrong_pin.open(5000));
  CHECK(wrong_pin.error() == "pin_mismatch");

  const Reply plain = fetch({"127.0.0.1", port, false, ""}, "/hello");
  CHECK(plain.status == 200);
  CHECK(plain.body == "{\"tls\":false}");
  httpd.stop();
  loop.stop();
}

TEST_CASE("security v3: media requires a local token, a session, or a peer MAC") {
  NodeOptions options;
  options.data_dir = ":memory:";
  options.role = "door_station";
  options.door = "front";
  options.listen_addr = "127.0.0.1:" + std::to_string(testing::freeListenPort());
  options.http_port = testing::freeListenPort();
  options.enable_beacon = false;
  options.psk.fill(0x44);
  options.local_token = "local-media-token-for-tests-000000000000";
  Node node(options);
  node.setSecureStore(
      [](const std::string& key) { return key == "panel.ha" ? "ha-camera-credential" : ""; },
      [](const std::string&, const std::string&) { return true; });
  REQUIRE(node.start());
  node.setConfigKey("panel.token_refs", "[\"secret:panel.ha\"]");
  CHECK(node.localToken() == options.local_token);
  const tls::Endpoint self{"127.0.0.1", options.http_port, false, ""};
  for (const char* path : {"/snapshot.jpg", "/video-meta", "/stream.mjpeg", "/stream.mp4"}) {
    INFO(path);
    CHECK(fetch(self, path).status == 401);
    CHECK(fetch(self, path, {{"X-Doorbell-Local", "wrong"}}).status == 401);
    CHECK(fetch(self, path, {{"X-Doorbell-Peer", "v1.0123456789abcdef0123456789abcdef.1.00"}})
              .status == 401);
  }
  const Reply meta = fetch(self, "/video-meta", {{"X-Doorbell-Local", options.local_token}});
  CHECK(meta.status == 200);
  // Home Assistant / go2rtc: Basic credentials carrying a panel credential with the view grant.
  const std::string good = "Basic " + base64Encode(toBytes("ha:ha-camera-credential"));
  const std::string bad = "Basic " + base64Encode(toBytes("ha:not-the-credential"));
  CHECK(fetch(self, "/video-meta", {{"Authorization", good}}).status == 200);
  CHECK(fetch(self, "/snapshot.jpg", {{"Authorization", good}}).status == 503);  // no frame yet
  CHECK(fetch(self, "/video-meta", {{"Authorization", bad}}).status == 401);
  CHECK(meta.body.find("rotation") != std::string::npos);
  // A /media/peer route for an unknown peer refuses before contacting anyone.
  CHECK(fetch(self, "/media/peer/0123456789abcdef0123456789abcdef/video-meta",
              {{"X-Doorbell-Local", options.local_token}}).status == 503);
  CHECK(fetch(self, "/media/peer/not-a-peer/video-meta",
              {{"X-Doorbell-Local", options.local_token}}).status == 404);
  node.stop();
}

TEST_CASE("security v3: two nodes exchange media over pinned HTTPS with a peer MAC") {
  NodeOptions door_options, panel_options;
  door_options.data_dir = panel_options.data_dir = ":memory:";
  door_options.role = "door_station";
  door_options.door = "front";
  panel_options.role = "indoor_panel";
  door_options.enable_beacon = panel_options.enable_beacon = false;
  door_options.psk.fill(0x55);
  panel_options.psk.fill(0x55);
  door_options.listen_addr = "127.0.0.1:" + std::to_string(testing::freeListenPort());
  panel_options.listen_addr = "127.0.0.1:" + std::to_string(testing::freeListenPort());
  door_options.advertise_addr = door_options.listen_addr;
  panel_options.advertise_addr = panel_options.listen_addr;
  panel_options.seed_peers = {door_options.listen_addr};
  door_options.http_port = testing::freeListenPort();
  panel_options.http_port = testing::freeListenPort();
  door_options.https_port = testing::freeListenPort();
  panel_options.https_port = testing::freeListenPort();
  panel_options.local_token = "panel-local-token-0000000000000000000000";
  Node door(door_options), panel(panel_options);
  std::map<std::string, std::string> door_store, panel_store;
  door.setSecureStore([&](const std::string& k) { return door_store[k]; },
                      [&](const std::string& k, const std::string& v) {
                        door_store[k] = v;
                        return true;
                      });
  panel.setSecureStore([&](const std::string& k) { return panel_store[k]; },
                       [&](const std::string& k, const std::string& v) {
                         panel_store[k] = v;
                         return true;
                       });
  REQUIRE(door.start());
  REQUIRE(panel.start());
  const std::string door_pin = door.tlsFingerprint();
  REQUIRE(door_pin.size() == 64);
  CHECK(door_store["tls.key"].find("PRIVATE KEY") != std::string::npos);

  // The panel learns the door's port and pin through the mesh and replicated configuration.
  REQUIRE(waitUntil([&] {
    auto status = json::parse(panel.statusJson());
    return status && status.get() &&
           json::dump(status.get()).find("/media/peer/" + door.nodeId() + "/stream.mjpeg") !=
               std::string::npos &&
           panel.configJson().find(door_pin) != std::string::npos;
  }, 15000));

  const tls::Endpoint panel_local{"127.0.0.1", panel_options.http_port, false, ""};
  const std::string base = "/media/peer/" + door.nodeId();
  const Reply meta = fetch(panel_local, base + "/video-meta",
                           {{"X-Doorbell-Local", panel_options.local_token}});
  CHECK(meta.status == 200);
  CHECK(meta.body.find("rotation") != std::string::npos);
  CHECK(fetch(panel_local, base + "/video-meta").status == 401);

  // The door's own HTTPS port serves the peer, never an anonymous LAN client.
  const tls::Endpoint door_tls{"127.0.0.1", door_options.https_port, true, door_pin};
  CHECK(fetch(door_tls, "/video-meta").status == 401);
  CHECK(fetch(door_tls, "/video-meta",
              {{"X-Doorbell-Peer", "v1." + panel.nodeId() + ".1." + std::string(64, '0')}})
            .status == 401);

  // A page on another origin cannot claim the unconfigured cluster through a browser.
  std::string cookie;
  const Reply foreign = fetch(door_tls, "/api/login",
                              {{"Content-Type", "application/json"},
                               {"Origin", "https://evil.example"}},
                              "POST", "{\"password\":\"long-enough-password\"}", &cookie);
  CHECK(foreign.status == 403);
  CHECK(fetch(door_tls, "/api/login",
              {{"Content-Type", "application/json"},
               {"Origin", "https://127.0.0.1:" + std::to_string(door_options.https_port)}},
              "POST", "{\"password\":\"short\"}").status == 400);
  // A login over HTTPS receives a Secure, HttpOnly, SameSite=Strict cookie.
  const Reply trusted = fetch(
      door_tls, "/api/login",
      {{"Content-Type", "application/json"},
       {"Origin", "https://127.0.0.1:" + std::to_string(door_options.https_port)}},
      "POST", "{\"password\":\"long-enough-password\"}", &cookie);
  CHECK(trusted.status == 200);
  CHECK(cookie.find("HttpOnly") != std::string::npos);
  CHECK(cookie.find("Secure") != std::string::npos);
  CHECK(cookie.find("SameSite=Strict") != std::string::npos);

  panel.stop();
  door.stop();
}

TEST_CASE("security v3: Argon2id digests, legacy upgrade and minimum length") {
  const auto record = admin_password::create("correct horse");
  CHECK(record.algo == "argon2id");
  CHECK(record.hash.size() == 64);
  CHECK(admin_password::verify(record, "correct horse"));
  CHECK_FALSE(admin_password::verify(record, "correct horsf"));
  CHECK_FALSE(admin_password::needsUpgrade(record));

  admin_password::Record legacy;
  legacy.algo = "blake2b-256";
  legacy.salt = "00112233445566778899aabbccddeeff";
  legacy.hash = admin_password::legacyBlake2bHex("old-password", legacy.salt);
  CHECK(admin_password::verify(legacy, "old-password"));
  CHECK(admin_password::needsUpgrade(legacy));

  admin_password::Record hostile = record;
  hostile.m_kib = 1u << 30;
  CHECK_FALSE(admin_password::verify(hostile, "correct horse"));

  NodeOptions options;
  options.data_dir = ":memory:";
  options.role = "indoor_panel";
  options.listen_addr = "127.0.0.1:" + std::to_string(testing::freeListenPort());
  options.enable_beacon = false;
  options.psk.fill(0x66);
  Node node(options);
  REQUIRE(node.start());
  CHECK(node.setAdminPassword("", "short") == -1);
  auto legacy_value = json::obj();
  json::set(legacy_value.get(), "salt", legacy.salt);
  json::set(legacy_value.get(), "hash", legacy.hash);
  json::set(legacy_value.get(), "algo", "blake2b-256");
  node.setConfigKey("admin.password_hash", json::dump(legacy_value.get()));
  REQUIRE(node.adminPasswordConfigured());
  CHECK(node.verifyAdminPassword("old-password") == 1);
  CHECK(waitUntil([&] {
    return node.configJson().find("argon2id") != std::string::npos;
  }, 5000));
  CHECK(node.verifyAdminPassword("old-password") == 1);
  CHECK(node.verifyAdminPassword("wrong-password") == 0);
  node.stop();
}

TEST_CASE("security v3: native admin window gates ABI configuration writes") {
  db_platform_v2 platform{};
  platform.struct_size = sizeof(platform);
  platform.version = DB_PLATFORM_V2_VERSION;
  db_core* core = db_core_create_v2(
      &platform, ":memory:",
      "{\"name\":\"window\",\"role\":\"indoor_panel\",\"listen_port\":0,\"http_port\":0}");
  REQUIRE(core != nullptr);
  REQUIRE(db_core_start(core) == 0);
  REQUIRE(std::string(db_core_local_token(core)).size() == 64);

  // No password yet: first-run setup writes freely.
  CHECK(db_core_admin_window_open(core) == 1);
  CHECK(db_core_set_config_json(core, "audio.volume.idle", "40") == 0);
  REQUIRE(db_core_admin_password_set(core, "", "window-password") == 0);
  CHECK(db_core_admin_window_open(core) == 1);
  db_core_admin_lock(core);
  CHECK(db_core_admin_window_open(core) == 0);
  CHECK(db_core_set_config_json(core, "audio.volume.idle", "41") == DB_RESULT_ADMIN_REQUIRED);
  CHECK(db_core_delete_config_key(core, "audio.volume.idle") == DB_RESULT_ADMIN_REQUIRED);
  CHECK(db_core_remove_device_v2(core, "0123456789abcdef0123456789abcdef") ==
        DB_RESULT_ADMIN_REQUIRED);
  char* batch = db_core_config_batch_json(core, "[{\"op\":\"set\",\"key\":\"a.b\",\"value\":1}]");
  REQUIRE(batch != nullptr);
  CHECK(std::string(batch).find("admin_required") != std::string::npos);
  db_free(batch);
  char* pin = db_core_mint_join_token_json(core, 0);
  REQUIRE(pin != nullptr);
  CHECK(std::string(pin).find("admin_required") != std::string::npos);
  db_free(pin);
  // Household operations are never gated.
  CHECK(db_core_emergency_v2(core, 1) == 1);
  CHECK(db_core_emergency_v2(core, 0) == 1);

  CHECK(db_core_admin_password_verify(core, "wrong-password") == 0);
  CHECK(db_core_admin_window_open(core) == 0);
  REQUIRE(db_core_admin_password_verify(core, "window-password") > 0);
  CHECK(db_core_set_config_json(core, "audio.volume.idle", "42") == 0);
  // An unknown (offline) record can be removed; the marker replicates.
  CHECK(db_core_remove_device_v2(core, "0123456789abcdef0123456789abcdef") == 0);
  CHECK(db_core_remove_device_v2(core, "short") == -1);
  db_core_stop(core);
  db_core_destroy(core);
}

TEST_CASE("security v3: SIP peer path needs a fresh signed INVITE, registrar path does not") {
  std::array<uint8_t, 32> key{};
  key.fill(0x77);
  const std::string a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  const std::string b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
  SipPeerAuth signer, verifier;
  signer.setKey(a, key);
  verifier.setKey(b, key);
  const int64_t now = 1'800'000'000'000LL;
  const std::string header = signer.sign("monitor", now);
  REQUIRE(header.rfind("v1." + a + ".", 0) == 0);
  std::string peer;
  CHECK(verifier.verify(header, "monitor", now + 1000, &peer));
  CHECK(peer == a);
  CHECK_FALSE(verifier.verify(header, "monitor", now + 1000, nullptr));  // replay
  const std::string second = signer.sign("monitor", now);
  CHECK_FALSE(verifier.verify(second, "", now, nullptr));              // mode is bound
  CHECK_FALSE(verifier.verify(second, "monitor", now + 61'000, nullptr));  // too old
  std::array<uint8_t, 32> other{};
  other.fill(0x78);
  SipPeerAuth stranger;
  stranger.setKey(a, other);
  CHECK_FALSE(verifier.verify(stranger.sign("", now), "", now, nullptr));
  CHECK_FALSE(verifier.verify("v1.x.1.2.3", "", now, nullptr));
  CHECK_FALSE(verifier.verify("", "", now, nullptr));

  const std::set<std::string> peers = {"10.0.0.20"};
  const std::set<std::string> registrar = {"10.0.0.2"};
  // Peer path: valid header from a member's address.
  CHECK(classifySipInbound("10.0.0.20", true, peers, registrar) == SipInboundPath::Peer);
  CHECK(classifySipInbound("10.0.0.20", false, peers, registrar) == SipInboundPath::Rejected);
  CHECK(classifySipInbound("10.0.0.99", true, peers, registrar) == SipInboundPath::Rejected);
  // Registrar path (Asterisk 600/601 and 800X answer-after=0 monitor): no header needed.
  CHECK(classifySipInbound("10.0.0.2", false, peers, registrar) == SipInboundPath::Registrar);
  CHECK(classifySipInbound("10.0.0.2", false, peers, {}) == SipInboundPath::Rejected);
  // Deny by default: nothing configured admits nothing.
  CHECK(classifySipInbound("10.0.0.20", false, {}, {}) == SipInboundPath::Rejected);
  CHECK(resolveSipHost("127.0.0.1").count("127.0.0.1") == 1);
}

TEST_CASE("security v3: Node SIP admission uses membership and the configured registrar") {
  NodeOptions a_options, b_options;
  a_options.data_dir = b_options.data_dir = ":memory:";
  a_options.role = "door_station";
  a_options.door = "front";
  b_options.role = "indoor_panel";
  a_options.enable_beacon = b_options.enable_beacon = false;
  a_options.psk.fill(0x21);
  b_options.psk.fill(0x21);
  a_options.listen_addr = "127.0.0.1:" + std::to_string(testing::freeListenPort());
  b_options.listen_addr = "127.0.0.1:" + std::to_string(testing::freeListenPort());
  a_options.advertise_addr = a_options.listen_addr;
  b_options.advertise_addr = b_options.listen_addr;
  b_options.seed_peers = {a_options.listen_addr};
  Node a(a_options), b(b_options);
  REQUIRE(a.start());
  REQUIRE(b.start());
  std::string header;
  REQUIRE(waitUntil([&] {
    header = b.sipPeerAuthHeader("monitor");
    return !header.empty() && a.sipInboundCheck("127.0.0.1", header, "monitor") == 1;
  }, 15000));
  CHECK(a.sipInboundCheck("127.0.0.1", header, "monitor") == 0);  // single use
  CHECK(a.sipInboundCheck("127.0.0.1", "", "") == 0);
  a.setConfigKey("sip.server", "\"127.0.0.2\"");
  CHECK(waitUntil([&] { return a.sipInboundCheck("127.0.0.2", "", "monitor") == 2; }, 5000));
  CHECK(a.sipInboundCheck("127.0.0.3", "", "") == 0);
  b.stop();
  a.stop();
}

TEST_CASE("security v3: MQTT refuses packets larger than the cap") {
  Bytes packet = {0x30};
  uint8_t length[4];
  const size_t used = mqtt::encodeRemainingLength(mqtt::kMaxPacketBytes + 1, length);
  packet.insert(packet.end(), length, length + used);
  mqtt::Packet out;
  CHECK(mqtt::decodePacket(packet.data(), packet.size(), &out) < 0);
  Bytes small = {0x30};
  const size_t small_used = mqtt::encodeRemainingLength(4, length);
  small.insert(small.end(), length, length + small_used);
  small.insert(small.end(), {0, 1, 't', 'x'});
  CHECK(mqtt::decodePacket(small.data(), small.size(), &out) == static_cast<int>(small.size()));
}
