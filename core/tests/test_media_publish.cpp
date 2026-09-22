#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>

#include <map>
#include <string>

#include "doctest.h"
#include "test_env.h"
#include "media/frame_bus.h"
#include "node/node.h"
#include "util/json.h"

using namespace db;

namespace {
struct MediaReply {
  int status = 0;
  std::string body;
  std::map<std::string, std::string> headers;
};

struct MediaSession { std::string cookie, csrf; };

MediaReply mediaRequest(int port, const std::string& method, const std::string& path,
                        const std::string& body = "", const MediaSession& session = {},
                        const std::string& type = "application/json",
                        const std::string& origin = "local") {
  const int fd = ::socket(AF_INET, SOCK_STREAM, 0);
  REQUIRE(fd >= 0);
  sockaddr_in address{};
  address.sin_family = AF_INET;
  address.sin_port = htons(static_cast<uint16_t>(port));
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  REQUIRE(::connect(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0);
  std::string request = method + " " + path + " HTTP/1.1\r\nHost: 127.0.0.1:" +
      std::to_string(port) + "\r\nConnection: close\r\n";
  if (!session.cookie.empty()) request += "Cookie: " + session.cookie + "\r\n";
  if (!session.csrf.empty()) request += "X-Doorbell-CSRF: " + session.csrf + "\r\n";
  if (!origin.empty()) request += "Origin: " + (origin == "local" ?
      "http://127.0.0.1:" + std::to_string(port) : origin) + "\r\n";
  request += "Content-Type: " + type + "\r\nContent-Length: " +
      std::to_string(body.size()) + "\r\n\r\n" + body;
  size_t sent = 0;
  while (sent < request.size()) {
    const ssize_t count = ::send(fd, request.data() + sent, request.size() - sent, 0);
    REQUIRE(count > 0);
    sent += static_cast<size_t>(count);
  }
  timeval timeout{5, 0};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
  std::string response;
  char buffer[8192];
  for (;;) {
    const ssize_t count = ::recv(fd, buffer, sizeof(buffer), 0);
    if (count <= 0) break;
    response.append(buffer, static_cast<size_t>(count));
  }
  ::close(fd);
  MediaReply result;
  if (response.size() >= 12) result.status = std::stoi(response.substr(9, 3));
  size_t start = response.find("\r\n") + 2;
  for (;;) {
    const size_t end = response.find("\r\n", start);
    if (end == std::string::npos) break;
    if (end == start) { result.body = response.substr(end + 2); break; }
    const size_t colon = response.find(": ", start);
    if (colon < end) result.headers[response.substr(start, colon - start)] =
        response.substr(colon + 2, end - colon - 2);
    start = end + 2;
  }
  return result;
}

MediaSession loginMediaSession(int port) {
  const auto response = mediaRequest(port, "POST", "/api/panel/session",
      R"({"credential":"media-test-credential"})");
  REQUIRE(response.status == 200);
  MediaSession result;
  const auto found = response.headers.find("Set-Cookie");
  REQUIRE(found != response.headers.end());
  result.cookie = found->second.substr(0, found->second.find(';'));
  auto body = json::parse(response.body);
  result.csrf = json::getString(body.get(), "csrf_token");
  return result;
}

std::string mediaIdentity(const std::string& call) {
  return "door=front&call_id=" + call + "&stage_revision=0";
}

std::string testJpeg() {
  FrameBus bus;
  RawFrame frame;
  frame.format = 3; frame.w = 8; frame.h = 8; frame.stride = 32; frame.ts_ms = 1;
  frame.data.assign(8 * 8 * 4, 128);
  bus.push(std::move(frame));
  const auto bytes = bus.latestJpeg();
  return std::string(bytes.begin(), bytes.end());
}
}  // namespace

TEST_CASE("media publishing binds session call owner generation and ordered frame") {
  SimClock clock(1'700'000'000'000LL, 1000);
  Runloop loop(clock); loop.start();
  NodeOptions options;
  options.data_dir = ":memory:"; options.door = "front";
  options.listen_addr = "127.0.0.1:" + std::to_string(db::testing::freeListenPort());
  options.http_port = db::testing::freeListenPort(); options.enable_beacon = false;
  options.psk.fill(0x39);
  NodeDeps deps; deps.clock = &clock; deps.loop = &loop;
  Node node(options, std::move(deps));
  node.setSecureStore([](const std::string& key) {
    return key == "media.test" ? std::string("media-test-credential") : std::string();
  }, [](const std::string&, const std::string&) { return true; });
  REQUIRE(node.start());
  node.setConfigKey("panel.token_refs", R"(["secret:media.test"])");
  node.setConfigKey("doors.front", R"({"label":{"en":"Front"}})");
  const int port = options.http_port;
  const auto owner = loginMediaSession(port), stranger = loginMediaSession(port);
  const std::string jpeg = testJpeg();
  REQUIRE(jpeg.size() > 100);
  const std::string call_a = node.pressV2("front", "");
  REQUIRE(!call_a.empty());
  auto answered = mediaRequest(port, "POST", "/api/panel/call-lifecycle",
      mediaIdentity(call_a) + "&state=answered&dialog_id=0123456789abcdef0123456789abcdef", owner,
      "application/x-www-form-urlencoded");
  REQUIRE(answered.status == 200);

  auto grant = mediaRequest(port, "POST", "/api/panel/media-authorize",
      mediaIdentity(call_a), owner, "application/x-www-form-urlencoded");
  REQUIRE(grant.status == 200);
  const auto grant_json = json::parse(grant.body);
  const std::string generation = json::getString(grant_json.get(), "media_generation");
  REQUIRE(generation.size() == 32);
  CHECK(generation.find_first_not_of("0123456789abcdef") == std::string::npos);
  CHECK(json::getInt(grant_json.get(), "publish_remaining_ms") == 10000);
  const std::string upload = "/call-frame?" + mediaIdentity(call_a) +
      "&media_generation=" + generation + "&frame_sequence=";
  const std::string read = "/peer-frame.jpg?" + mediaIdentity(call_a);

  SUBCASE("T15-01 delayed A frame cannot appear in B") {
    REQUIRE(mediaRequest(port, "POST", upload + "1", jpeg, owner, "image/jpeg").status == 200);
    CHECK(mediaRequest(port, "GET", read).body == jpeg);
    REQUIRE(mediaRequest(port, "POST", "/api/panel/call-lifecycle", mediaIdentity(call_a) +
        "&state=ended&dialog_id=0123456789abcdef0123456789abcdef", owner,
        "application/x-www-form-urlencoded").status == 200);
    const std::string call_b = node.pressV2("front", "");
    REQUIRE(!call_b.empty());
    CHECK(mediaRequest(port, "POST", upload + "2", jpeg, owner, "image/jpeg").status == 409);
    CHECK(mediaRequest(port, "GET", "/peer-frame.jpg?" + mediaIdentity(call_b)).status == 404);
    CHECK(mediaRequest(port, "GET", read).status == 404);
  }
  SUBCASE("T15-02 another authenticated session cannot impersonate the owner") {
    CHECK(mediaRequest(port, "POST", "/api/panel/media-authorize", mediaIdentity(call_a),
                       stranger, "application/x-www-form-urlencoded").status == 403);
    CHECK(mediaRequest(port, "POST", upload + "1", jpeg, stranger, "image/jpeg").status == 403);
    CHECK(mediaRequest(port, "POST", "/api/panel/call-lifecycle", mediaIdentity(call_a) +
        "&state=answered&dialog_id=0123456789abcdef0123456789abcdef", stranger,
        "application/x-www-form-urlencoded").status == 403);
    CHECK(mediaRequest(port, "POST", upload + "1", jpeg, owner, "image/jpeg").status == 200);
  }
  SUBCASE("T16 another authenticated panel cannot read the publisher return video") {
    REQUIRE(mediaRequest(port, "POST", upload + "1", jpeg, owner, "image/jpeg").status == 200);
    CHECK(mediaRequest(port, "GET", read, "", stranger).status == 403);
    CHECK(mediaRequest(port, "GET", read, "", owner).body == jpeg);
    CHECK(mediaRequest(port, "GET", read).body == jpeg);
  }
  SUBCASE("T15-03 end invalidates an otherwise unexpired grant") {
    REQUIRE(mediaRequest(port, "POST", "/api/panel/call-lifecycle", mediaIdentity(call_a) +
        "&state=ended&dialog_id=0123456789abcdef0123456789abcdef", owner,
        "application/x-www-form-urlencoded").status == 200);
    CHECK(mediaRequest(port, "POST", upload + "1", jpeg, owner, "image/jpeg").status == 409);
    CHECK(mediaRequest(port, "GET", read).status == 404);
  }
  SUBCASE("T15-04 late sequence cannot replace the current frame") {
    REQUIRE(mediaRequest(port, "POST", upload + "10", jpeg, owner, "image/jpeg").status == 200);
    CHECK(mediaRequest(port, "POST", upload + "9", jpeg, owner, "image/jpeg").status == 409);
    CHECK(mediaRequest(port, "POST", upload + "10", jpeg, owner, "image/jpeg").status == 409);
    const auto frame = mediaRequest(port, "GET", read);
    CHECK(frame.status == 200);
    CHECK(frame.body == jpeg);
    CHECK(frame.headers.at("X-Doorbell-Frame-Sequence") == "10");
    CHECK(frame.headers.at("X-Doorbell-Media-Generation") == generation);
    CHECK(frame.headers.at("X-Doorbell-Call-Id") == call_a);
    CHECK(frame.headers.at("X-Doorbell-Stage-Revision") == "0");
    CHECK(frame.headers.at("X-Doorbell-Dialog-Owner") ==
          json::getString(grant_json.get(), "dialog_owner"));
  }
  SUBCASE("renewal revokes the previous generation and sequence validation is strict") {
    for (const auto* sequence : {"0", "01", "-1", "1e2", "9223372036854775808", "99999999999999999999"})
      CHECK(mediaRequest(port, "POST", upload + sequence, jpeg, owner, "image/jpeg").status == 400);
    REQUIRE(mediaRequest(port, "POST", upload + "9223372036854775807", jpeg, owner, "image/jpeg").status == 200);
    auto renewed = mediaRequest(port, "POST", "/api/panel/media-authorize", mediaIdentity(call_a),
        owner, "application/x-www-form-urlencoded");
    REQUIRE(renewed.status == 200);
    auto body = json::parse(renewed.body);
    CHECK(json::getString(body.get(), "media_generation") != generation);
    CHECK(mediaRequest(port, "POST", upload + "9223372036854775807", jpeg, owner, "image/jpeg").status == 409);
    CHECK(mediaRequest(port, "GET", read).status == 404);
  }
  SUBCASE("csrf origin expiry revocation and metadata are required") {
    auto no_csrf = owner; no_csrf.csrf.clear();
    CHECK(mediaRequest(port, "POST", upload + "1", jpeg, no_csrf, "image/jpeg").status == 403);
    CHECK(mediaRequest(port, "POST", upload + "1", jpeg, owner, "image/jpeg", "https://evil.example").status == 403);
    CHECK(mediaRequest(port, "GET", read, "", {}, "", "https://evil.example").status == 403);
    CHECK(mediaRequest(port, "GET", "/peer-frame.jpg").status == 409);
    CHECK(mediaRequest(port, "POST", "/call-frame?door=front", jpeg, owner, "image/jpeg").status == 400);
    REQUIRE(mediaRequest(port, "POST", upload + "1", jpeg, owner, "image/jpeg").status == 200);
    clock.advance(3001);
    CHECK(mediaRequest(port, "GET", read).status == 404);
    clock.advance(7000);
    CHECK(mediaRequest(port, "POST", upload + "2", jpeg, owner, "image/jpeg").status == 409);
  }
  SUBCASE("credential revocation clears publication and cached frames") {
    REQUIRE(mediaRequest(port, "POST", upload + "1", jpeg, owner, "image/jpeg").status == 200);
    node.setConfigKey("panel.token_generation", "\"11111111111111111111111111111111\"");
    REQUIRE(node.configJson().find("11111111111111111111111111111111") != std::string::npos);
    CHECK(mediaRequest(port, "POST", upload + "2", jpeg, owner, "image/jpeg").status == 403);
    CHECK(mediaRequest(port, "GET", read).status == 404);
    CHECK(mediaRequest(port, "GET", "/api/panel/session", "", owner).status == 403);
  }
  SUBCASE("background session reads do not extend idle expiry and peer publication is unsupported") {
    CHECK(mediaRequest(port, "POST", "/api/panel/media-authorize",
        "door=other&call_id=" + call_a + "&stage_revision=0", owner,
        "application/x-www-form-urlencoded").status == 501);
    clock.advance(29 * 60 * 1000);
    CHECK(mediaRequest(port, "GET", "/api/panel/session", "", owner).status == 200);
    clock.advance(60 * 1000);
    CHECK(mediaRequest(port, "GET", "/api/panel/session", "", owner).status == 403);
    CHECK(mediaRequest(port, "GET", read).status == 404);
  }
  node.stop(); loop.stop();
}
