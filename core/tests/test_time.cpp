#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include "doctest.h"
#include "events/events.h"
#include "node/node.h"
#include "util/clock.h"
#include "util/json.h"
#include "util/runloop.h"
#include "util/sntp.h"
#include "util/tz.h"

using namespace db;

namespace {

constexpr int64_t kDayMs = 86'400'000LL;

// Wall milliseconds of a UTC civil instant.
int64_t utcMs(int year, int month, int day, int hour, int minute) {
  return tz::daysFromCivil(year, month, day) * kDayMs + hour * 3'600'000LL + minute * 60'000LL;
}

int offsetOf(const std::string& zone, int64_t at_ms) {
  int offset = -9999;
  REQUIRE(tz::offsetMinAt(zone, at_ms, &offset));
  return offset;
}

// Minimal loopback SNTP server that answers with a clock shifted by skew_ms.
class FakeNtpServer {
 public:
  explicit FakeNtpServer(int64_t skew_ms) : skew_ms_(skew_ms) {}

  bool start() {
    fd_ = ::socket(AF_INET, SOCK_DGRAM, 0);
    if (fd_ < 0) return false;
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    if (::bind(fd_, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) return false;
    socklen_t length = sizeof(address);
    if (::getsockname(fd_, reinterpret_cast<sockaddr*>(&address), &length) != 0) return false;
    port_ = ntohs(address.sin_port);
    running_ = true;
    thread_ = std::thread([this] { serve(); });
    return true;
  }

  void stop() {
    running_ = false;
    if (fd_ >= 0) ::shutdown(fd_, SHUT_RDWR);
    if (fd_ >= 0) ::close(fd_);
    fd_ = -1;
    if (thread_.joinable()) thread_.join();
  }

  int port() const { return port_; }
  int requests() const { return requests_.load(); }

 private:
  void serve() {
    while (running_) {
      uint8_t buffer[128];
      sockaddr_in from{};
      socklen_t from_length = sizeof(from);
      const ssize_t received = ::recvfrom(fd_, buffer, sizeof(buffer), 0,
                                          reinterpret_cast<sockaddr*>(&from), &from_length);
      if (received < static_cast<ssize_t>(sntp::kPacketSize)) continue;
      requests_++;
      const int64_t now = std::chrono::duration_cast<std::chrono::milliseconds>(
                              std::chrono::system_clock::now().time_since_epoch())
                              .count() +
                          skew_ms_;
      uint8_t reply[sntp::kPacketSize];
      std::memset(reply, 0, sizeof(reply));
      reply[0] = static_cast<uint8_t>((0 << 6) | (4 << 3) | 4);  // LI 0, VN 4, mode 4 (server)
      reply[1] = 2;                                              // stratum
      std::memcpy(reply + 24, buffer + 40, 8);                   // originate echoes our transmit
      writeTimestamp(reply + 32, now);
      writeTimestamp(reply + 40, now);
      ::sendto(fd_, reply, sizeof(reply), 0, reinterpret_cast<sockaddr*>(&from), from_length);
    }
  }

  static void writeTimestamp(uint8_t* out, int64_t unix_ms) {
    const uint64_t value = sntp::toNtpTimestamp(unix_ms);
    for (int i = 0; i < 8; i++) out[i] = static_cast<uint8_t>(value >> (56 - 8 * i));
  }

  int64_t skew_ms_;
  int fd_ = -1;
  int port_ = 0;
  std::atomic<bool> running_{false};
  std::atomic<int> requests_{0};
  std::thread thread_;
};

}  // namespace

TEST_CASE("tz: the bundled table resolves fixed-offset zones") {
  CHECK(tz::zoneKnown("Asia/Tokyo"));
  CHECK(tz::zoneKnown("UTC"));
  CHECK_FALSE(tz::zoneKnown("Mars/Olympus"));
  CHECK_FALSE(tz::zoneKnown(""));
  CHECK(tz::zoneCount() > 60);
  CHECK(tz::regionOf("Asia/Tokyo") == "Asia");
  CHECK(tz::regionOf("UTC") == "UTC");

  const int64_t midsummer = utcMs(2026, 7, 1, 0, 0);
  const int64_t midwinter = utcMs(2026, 1, 15, 0, 0);
  CHECK(offsetOf("Asia/Tokyo", midsummer) == 540);
  CHECK(offsetOf("Asia/Tokyo", midwinter) == 540);
  CHECK(offsetOf("Asia/Kolkata", midsummer) == 330);
  CHECK(offsetOf("Asia/Kathmandu", midsummer) == 345);
  CHECK(offsetOf("UTC", midsummer) == 0);
  CHECK(offsetOf("America/Phoenix", midsummer) == -420);
  CHECK(offsetOf("Australia/Brisbane", midsummer) == 600);

  // Every listed zone must resolve; a typo in the table would otherwise only surface in the UI.
  for (size_t i = 0; i < tz::zoneCount(); i++) {
    const std::string id = tz::zoneIdAt(i);
    CAPTURE(id);
    CHECK(tz::zoneKnown(id));
    int offset = -9999;
    CHECK(tz::offsetMinAt(id, midsummer, &offset));
    CHECK(offset >= -12 * 60);
    CHECK(offset <= 14 * 60);
  }
  CHECK(tz::zoneIdAt(tz::zoneCount()) == "");
}

TEST_CASE("tz: daylight saving follows each regime's transition instants") {
  // European Union: last Sunday of March / October, 01:00 UTC. 2026-03-29 and 2026-10-25.
  CHECK(offsetOf("Europe/Berlin", utcMs(2026, 3, 29, 0, 59)) == 60);
  CHECK(offsetOf("Europe/Berlin", utcMs(2026, 3, 29, 1, 0)) == 120);
  CHECK(offsetOf("Europe/Berlin", utcMs(2026, 10, 25, 0, 59)) == 120);
  CHECK(offsetOf("Europe/Berlin", utcMs(2026, 10, 25, 1, 0)) == 60);
  CHECK(offsetOf("Europe/London", utcMs(2026, 7, 1, 12, 0)) == 60);
  CHECK(offsetOf("Europe/London", utcMs(2026, 1, 1, 12, 0)) == 0);

  // North America: second Sunday of March 02:00 local standard, first Sunday of November 02:00
  // local daylight. 2026-03-08 and 2026-11-01, New York being UTC-5 in winter.
  CHECK(offsetOf("America/New_York", utcMs(2026, 3, 8, 6, 59)) == -300);
  CHECK(offsetOf("America/New_York", utcMs(2026, 3, 8, 7, 0)) == -240);
  CHECK(offsetOf("America/New_York", utcMs(2026, 11, 1, 5, 59)) == -240);
  CHECK(offsetOf("America/New_York", utcMs(2026, 11, 1, 6, 0)) == -300);

  // Southern hemisphere: daylight saving wraps the new year.
  CHECK(offsetOf("Australia/Sydney", utcMs(2026, 1, 15, 0, 0)) == 660);
  CHECK(offsetOf("Australia/Sydney", utcMs(2026, 6, 15, 0, 0)) == 600);
  CHECK(offsetOf("Australia/Sydney", utcMs(2026, 12, 15, 0, 0)) == 660);
  CHECK(offsetOf("Pacific/Auckland", utcMs(2026, 1, 15, 0, 0)) == 780);
  CHECK(offsetOf("Pacific/Auckland", utcMs(2026, 6, 15, 0, 0)) == 720);
  CHECK(offsetOf("America/Santiago", utcMs(2026, 1, 15, 0, 0)) == -180);
  CHECK(offsetOf("America/Santiago", utcMs(2026, 6, 15, 0, 0)) == -240);
}

TEST_CASE("tz: local time renders civil fields and falls back for an unknown zone") {
  // 2026-09-02T12:34:56Z is 21:34:56 on a Wednesday in Tokyo.
  const int64_t at = utcMs(2026, 9, 2, 12, 34) + 56'000;
  auto parsed = json::parse(tz::localTimeJson("Asia/Tokyo", at, 0));
  REQUIRE(parsed);
  CHECK(json::getString(parsed.get(), "iso") == "2026-09-02T21:34:56+09:00");
  CHECK(json::getString(parsed.get(), "date") == "2026-09-02");
  CHECK(json::getInt(parsed.get(), "hh") == 21);
  CHECK(json::getInt(parsed.get(), "mm") == 34);
  CHECK(json::getInt(parsed.get(), "ss") == 56);
  CHECK(json::getString(parsed.get(), "weekday") == "wed");
  CHECK(json::getInt(parsed.get(), "weekday_num") == 3);
  CHECK(json::getInt(parsed.get(), "offset_min") == 540);
  CHECK(json::getBool(parsed.get(), "known"));
  CHECK(json::getString(parsed.get(), "tz") == "Asia/Tokyo");

  // A negative offset must render as a negative ISO suffix and may cross the date line.
  auto ny = json::parse(tz::localTimeJson("America/New_York", utcMs(2026, 1, 1, 2, 0), 0));
  REQUIRE(ny);
  CHECK(json::getString(ny.get(), "iso") == "2025-12-31T21:00:00-05:00");
  CHECK(json::getString(ny.get(), "weekday") == "wed");

  // A half-hour zone keeps its minutes in the ISO suffix.
  auto kolkata = json::parse(tz::localTimeJson("Asia/Kolkata", utcMs(2026, 5, 5, 0, 0), 0));
  REQUIRE(kolkata);
  CHECK(json::getString(kolkata.get(), "iso") == "2026-05-05T05:30:00+05:30");

  // Unknown zone: the caller's fixed offset is used and known reports the difference.
  auto unknown = json::parse(tz::localTimeJson("Mars/Olympus", utcMs(2026, 5, 5, 0, 0), 480));
  REQUIRE(unknown);
  CHECK_FALSE(json::getBool(unknown.get(), "known"));
  CHECK(json::getInt(unknown.get(), "offset_min") == 480);
  CHECK(json::getString(unknown.get(), "iso") == "2026-05-05T08:00:00+08:00");
}

TEST_CASE("sntp: request and reply encoding round-trips with fixed vectors") {
  const int64_t t1 = 1'772'000'000'123LL;
  uint8_t request[sntp::kPacketSize];
  sntp::buildRequest(request, t1);
  CHECK(request[0] == 0x23);  // LI 0, VN 4, mode 3
  CHECK(request[1] == 0);
  CHECK(sntp::fromNtpTimestamp(sntp::toNtpTimestamp(t1)) == t1);

  // Build the reply the way a server does: echo the originate timestamp, then fill receive and
  // transmit from a clock that is exactly one minute ahead.
  const int64_t t2 = t1 + 60'000 + 10;
  const int64_t t3 = t1 + 60'000 + 12;
  uint8_t reply[sntp::kPacketSize];
  std::memset(reply, 0, sizeof(reply));
  reply[0] = 0x24;  // LI 0, VN 4, mode 4
  reply[1] = 3;     // stratum
  auto write64 = [](uint8_t* out, uint64_t value) {
    for (int i = 0; i < 8; i++) out[i] = static_cast<uint8_t>(value >> (56 - 8 * i));
  };
  std::memcpy(reply + 24, request + 40, 8);
  write64(reply + 32, sntp::toNtpTimestamp(t2));
  write64(reply + 40, sntp::toNtpTimestamp(t3));

  sntp::Reply parsed;
  REQUIRE(sntp::parseReply(reply, sizeof(reply), t1, &parsed));
  CHECK(parsed.stratum == 3);
  CHECK(parsed.mode == 4);
  CHECK(parsed.originate_ms == t1);
  CHECK(parsed.receive_ms == t2);
  CHECK(parsed.transmit_ms == t3);

  const int64_t t4 = t1 + 22;
  const sntp::Sample sample = sntp::computeSample(t1, parsed.receive_ms, parsed.transmit_ms, t4);
  CHECK(sample.offset_ms == 60'000);
  CHECK(sample.rtt_ms == 20);
  CHECK(sntp::sampleSane(sample));

  // Rejections: short packet, alarm leap, kiss-of-death stratum, client mode, and a reply that
  // does not echo the request we actually sent.
  CHECK_FALSE(sntp::parseReply(reply, sntp::kPacketSize - 1, t1, &parsed));
  CHECK_FALSE(sntp::parseReply(reply, sizeof(reply), t1 + 1, &parsed));
  uint8_t broken[sntp::kPacketSize];
  std::memcpy(broken, reply, sizeof(broken));
  broken[0] = 0xE4;  // leap 3 = unsynchronized
  CHECK_FALSE(sntp::parseReply(broken, sizeof(broken), t1, &parsed));
  std::memcpy(broken, reply, sizeof(broken));
  broken[1] = 0;  // kiss-of-death
  CHECK_FALSE(sntp::parseReply(broken, sizeof(broken), t1, &parsed));
  std::memcpy(broken, reply, sizeof(broken));
  broken[0] = 0x23;  // client mode
  CHECK_FALSE(sntp::parseReply(broken, sizeof(broken), t1, &parsed));
  std::memcpy(broken, reply, sizeof(broken));
  std::memset(broken + 40, 0, 8);  // zero transmit timestamp
  CHECK_FALSE(sntp::parseReply(broken, sizeof(broken), t1, &parsed));
}

TEST_CASE("sntp: implausible samples are rejected and the lowest round trip wins") {
  CHECK(sntp::sampleSane({0, 0}));
  CHECK(sntp::sampleSane({86'400'000LL, 3000}));
  CHECK_FALSE(sntp::sampleSane({86'400'001LL, 10}));
  CHECK_FALSE(sntp::sampleSane({-86'400'001LL, 10}));
  CHECK_FALSE(sntp::sampleSane({0, 3001}));
  CHECK_FALSE(sntp::sampleSane({0, -1}));

  // Offset selection: the sample with the smallest round trip is the one to adopt.
  const sntp::Sample slow = sntp::computeSample(1000, 5000, 5400, 2800);
  const sntp::Sample quick = sntp::computeSample(1000, 4020, 4030, 1040);
  CHECK(slow.rtt_ms == 1400);
  CHECK(quick.rtt_ms == 30);
  CHECK(quick.offset_ms == 3005);
  CHECK(quick.rtt_ms < slow.rtt_ms);
}

TEST_CASE("sntp: server specifications are parsed and rejected consistently") {
  std::string host;
  int port = 0;
  REQUIRE(sntp::parseServer("ntp.nict.jp", &host, &port));
  CHECK(host == "ntp.nict.jp");
  CHECK(port == 123);
  REQUIRE(sntp::parseServer("10.0.1.5:1123", &host, &port));
  CHECK(host == "10.0.1.5");
  CHECK(port == 1123);
  REQUIRE(sntp::parseServer("[fd00::1]:123", &host, &port));
  CHECK(host == "fd00::1");
  CHECK(port == 123);
  REQUIRE(sntp::parseServer("fd00::1", &host, &port));
  CHECK(host == "fd00::1");
  CHECK(port == 123);
  CHECK_FALSE(sntp::parseServer("", nullptr, nullptr));
  CHECK_FALSE(sntp::parseServer("host:0", nullptr, nullptr));
  CHECK_FALSE(sntp::parseServer("host:99999", nullptr, nullptr));
  CHECK_FALSE(sntp::parseServer("host:", nullptr, nullptr));
  CHECK_FALSE(sntp::parseServer("http://host", nullptr, nullptr));
  CHECK_FALSE(sntp::parseServer("host name", nullptr, nullptr));
}

TEST_CASE("clock: the time-service offset corrects every wall reading") {
  SimClock clock(1'700'000'000'000LL, 0);
  CHECK(clock.wallMs() == 1'700'000'000'000LL);
  CHECK(clock.systemWallMs() == 1'700'000'000'000LL);
  clock.setWallOffsetMs(90'000);
  CHECK(clock.wallOffsetMs() == 90'000);
  CHECK(clock.wallMs() == 1'700'000'090'000LL);
  // The platform clock itself is untouched, so a correction is always reversible.
  CHECK(clock.systemWallMs() == 1'700'000'000'000LL);
  clock.setWallOffsetMs(0);
  CHECK(clock.wallMs() == 1'700'000'000'000LL);
}

TEST_CASE("rules: schedules and quiet hours follow the configured zone across daylight saving") {
  RuleEngine engine;
  engine.setConfig(R"({
    "trigger_rules": {
      "r_night": { "enabled": true,
        "when": { "type": "button" },
        "schedule": { "windows": [ { "from": "22:00", "to": "06:00" } ] },
        "actions": [ { "type": "telegram" } ] } },
    "quiet_hours": { "default": { "windows": [ { "from": "23:00", "to": "07:00" } ],
                                  "suppress": ["telegram"] } }
  })");
  EventRecord press;
  press.type = "press";
  press.door = "d_front";

  // 22:30 Berlin local time in winter is 21:30 UTC; in summer it is 20:30 UTC. Evaluating with
  // the zone's offset for the instant keeps the same local window matching in both.
  const int64_t winter = utcMs(2026, 1, 15, 21, 30);
  const int64_t summer = utcMs(2026, 7, 15, 20, 30);
  CHECK(engine.evaluate(press, winter, offsetOf("Europe/Berlin", winter)).size() == 1);
  CHECK(engine.evaluate(press, summer, offsetOf("Europe/Berlin", summer)).size() == 1);
  // A frozen winter offset applied in summer would put the same instant at 21:30 local, outside
  // the window, which is exactly the bug a fixed tz_offset_min produces.
  CHECK(engine.evaluate(press, summer, 60).empty());

  // Quiet hours suppress the same action at 23:30 local in both halves of the year.
  const int64_t winter_quiet = utcMs(2026, 1, 15, 22, 30);
  const int64_t summer_quiet = utcMs(2026, 7, 15, 21, 30);
  CHECK(engine.evaluate(press, winter_quiet, offsetOf("Europe/Berlin", winter_quiet)).empty());
  CHECK(engine.evaluate(press, summer_quiet, offsetOf("Europe/Berlin", summer_quiet)).empty());
}

TEST_CASE("node: the time service adopts a measured offset and falls back when it goes stale") {
  FakeNtpServer server(90'000);
  REQUIRE(server.start());

  RealClock clock;
  Runloop loop(clock);
  NodeOptions options;
  options.data_dir = ":memory:";
  options.name = "time-service";
  options.role = "indoor_panel";
  options.listen_addr = "127.0.0.1:0";
  options.enable_beacon = false;
  options.http_port = 0;
  NodeDeps deps;
  deps.clock = &clock;
  deps.loop = &loop;
  Node node(options, std::move(deps));
  std::vector<std::string> ui;
  node.setUiEventCb([&ui](const std::string& event) { ui.push_back(event); });
  REQUIRE(node.start());

  auto status = [&node] {
    auto parsed = json::parse(node.statusJson());
    REQUIRE(parsed);
    auto time = json::Doc(cJSON_Duplicate(json::get(parsed.get(), "time"), 1));
    REQUIRE(time);
    return time;
  };

  // NTP is off by default: the source is the system clock and no correction is applied.
  CHECK(json::getString(status().get(), "source") == "system");
  CHECK(json::getInt(status().get(), "offset_ms") == 0);
  CHECK(clock.wallOffsetMs() == 0);
  CHECK(node.syncTimeNow() == false);

  node.setConfigKey("time.ntp.servers",
                    "[\"127.0.0.1:" + std::to_string(server.port()) + "\"]");
  node.setConfigKey("time.ntp.enabled", "true");
  loop.pumpDue();
  REQUIRE(node.syncTimeNow());

  bool synced = false;
  for (int i = 0; i < 400 && !synced; i++) {
    loop.pumpDue();
    synced = json::getBool(status().get(), "ok", false);
    if (!synced) std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  REQUIRE(synced);
  auto after = status();
  CHECK(json::getString(after.get(), "source") == "ntp");
  CHECK(json::getInt(after.get(), "offset_ms") >= 89'000);
  CHECK(json::getInt(after.get(), "offset_ms") <= 91'000);
  CHECK(json::getInt(after.get(), "rtt_ms") >= 0);
  CHECK(json::getString(after.get(), "server") ==
        "127.0.0.1:" + std::to_string(server.port()));
  CHECK(json::getInt(after.get(), "last_sync_ms") > 0);
  // The correction reaches the shared clock, and therefore the HLC and every event timestamp.
  CHECK(clock.wallOffsetMs() >= 89'000);
  bool time_changed = false;
  for (const auto& event : ui) {
    auto parsed = json::parse(event);
    if (parsed && json::getString(parsed.get(), "t") == "time_changed" &&
        json::getString(parsed.get(), "source") == "ntp")
      time_changed = true;
  }
  CHECK(time_changed);

  // Disabling NTP withdraws the correction immediately and reports the system clock again.
  node.setConfigKey("time.ntp.enabled", "false");
  loop.pumpDue();
  CHECK(json::getString(status().get(), "source") == "system");
  CHECK(json::getInt(status().get(), "offset_ms") == 0);
  CHECK(clock.wallOffsetMs() == 0);
  // The measurement itself is retained so the admin panel can still show what was measured.
  CHECK(json::getInt(status().get(), "measured_offset_ms") >= 89'000);

  node.stop();
  server.stop();
  CHECK(server.requests() >= 1);
}

TEST_CASE("node: the configured zone drives local time and the derived compatibility offset") {
  SimClock clock(utcMs(2026, 7, 15, 12, 0), 0);
  Runloop loop(clock);
  NodeOptions options;
  options.data_dir = ":memory:";
  options.name = "time-zone";
  options.role = "indoor_panel";
  options.listen_addr = "127.0.0.1:0";
  options.enable_beacon = false;
  options.http_port = 0;
  NodeDeps deps;
  deps.clock = &clock;
  deps.loop = &loop;
  Node node(options, std::move(deps));
  REQUIRE(node.start());
  loop.pumpDue();

  auto local = json::parse(node.localTimeJson(0));
  REQUIRE(local);
  CHECK(json::getString(local.get(), "tz") == "Asia/Tokyo");
  CHECK(json::getInt(local.get(), "offset_min") == 540);
  CHECK(json::getString(local.get(), "iso") == "2026-07-15T21:00:00+09:00");

  node.setConfigKey("time.zone", "\"Europe/Berlin\"");
  loop.pumpDue();
  auto berlin = json::parse(node.localTimeJson(0));
  REQUIRE(berlin);
  CHECK(json::getString(berlin.get(), "tz") == "Europe/Berlin");
  CHECK(json::getInt(berlin.get(), "offset_min") == 120);
  // integrations.tz_offset_min stays valid for the Telegram bridge and older shells, derived
  // from the zone including its current daylight-saving state.
  auto config = json::parse(node.configJson());
  REQUIRE(config);
  CHECK(json::getInt(json::get(config.get(), "integrations"), "tz_offset_min") == 120);

  // An explicit instant is rendered in the same zone rather than "now".
  auto explicit_instant = json::parse(node.localTimeJson(utcMs(2026, 1, 15, 12, 0)));
  REQUIRE(explicit_instant);
  CHECK(json::getString(explicit_instant.get(), "iso") == "2026-01-15T13:00:00+01:00");

  node.stop();
}

TEST_CASE("node: the read-only time and volume exports never wait for the run loop") {
  // Device finding: both shells drove a one-second clock from db_core_local_time_json on their
  // main thread, and the call took about three seconds whenever the loop was mid-SNTP or
  // building a status document -- the displayed seconds advanced in threes. These exports are
  // served from a published snapshot and must not enter the loop at all.
  RealClock clock;
  Runloop loop(clock);
  NodeOptions options;
  options.data_dir = ":memory:";
  options.name = "snapshot-exports";
  options.role = "indoor_panel";
  options.listen_addr = "127.0.0.1:0";
  options.enable_beacon = false;
  options.http_port = 0;
  NodeDeps deps;
  deps.clock = &clock;
  deps.loop = &loop;
  Node node(options, std::move(deps));
  REQUIRE(node.start());
  node.setConfigKey("time.zone", "\"Asia/Tokyo\"");
  node.setConfigKey("audio.volume.call", "37");
  loop.pumpDue();

  loop.start();
  // Occupy the loop for half a second, the way one SNTP exchange or a large status build does.
  std::atomic<bool> occupied{false};
  REQUIRE(loop.post([&occupied] {
    occupied = true;
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
  }));
  for (int i = 0; i < 500 && !occupied; i++)
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  REQUIRE(occupied.load());

  const auto started_at = std::chrono::steady_clock::now();
  const std::string first = node.localTimeJson(0);
  const std::string volumes = node.audioJson("");
  const auto elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                              std::chrono::steady_clock::now() - started_at)
                              .count();
  CHECK(elapsed_ms < 100);

  // The snapshot is a real answer, not a placeholder.
  auto local = json::parse(first);
  REQUIRE(local);
  CHECK(json::getString(local.get(), "tz") == "Asia/Tokyo");
  CHECK(json::getInt(local.get(), "offset_min") == 540);
  CHECK(json::getBool(local.get(), "known", false));
  auto audio = json::parse(volumes);
  REQUIRE(audio);
  CHECK(json::getInt(audio.get(), "call") == 37);
  CHECK(json::getString(json::get(audio.get(), "sources"), "call") == "cluster");

  // Only the instant is read live, so a clock driven by this export keeps ticking through the
  // stall instead of freezing until the loop drains.
  std::this_thread::sleep_for(std::chrono::milliseconds(120));
  auto later = json::parse(node.localTimeJson(0));
  REQUIRE(later);
  CHECK(json::getInt(later.get(), "wall_ms") > json::getInt(local.get(), "wall_ms"));

  // Control: an export that still marshals to the loop does wait for it, which is what proves
  // the loop was genuinely busy for the checks above.
  const auto before_blocking = std::chrono::steady_clock::now();
  node.debugJson();
  const auto blocked_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                              std::chrono::steady_clock::now() - before_blocking)
                              .count();
  CHECK(blocked_ms >= 200);

  node.stop();
  loop.stop();
}
