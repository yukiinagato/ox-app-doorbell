#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "doctest.h"
#include "doorbell/doorbell.h"
#include "util/common.h"
#include "util/hlc.h"
#include "util/ids.h"
#include "util/json.h"
#include "util/runloop.h"

using namespace db;

TEST_CASE("db_core_qr_encode returns a valid matrix and rejects empty input") {
  int size = -1;
  CHECK(db_core_qr_encode("", &size) == nullptr);
  CHECK(size == 0);
  unsigned char* m = db_core_qr_encode("doorbell-pair:10.0.1.5:47172|abc123|deadbeef", &size);
  REQUIRE(m != nullptr);
  CHECK(size >= 21);
  CHECK((size % 2) == 1);

  CHECK(m[0 * size + 0] == 1);
  CHECK(m[6 * size + 6] == 1);
  CHECK(m[1 * size + 1] == 0);

  bool onlyBinary = true;
  for (int i = 0; i < size * size; i++)
    if (m[i] > 1) onlyBinary = false;
  CHECK(onlyBinary);
  db_free(reinterpret_cast<char*>(m));
}


namespace {

// QR のモジュール行列を quirc が読める 8bit グレースケール画像に描く。実機のカメラ映像に近づける
// ため、拡大率と 4 モジュールのクワイエットゾーンを付ける。暗いモジュールが 0、下地が 255。
std::vector<uint8_t> rasterizeQr(const unsigned char* modules, int size, int scale, int quiet,
                                 int* out_w, int* out_h) {
  const int side = (size + quiet * 2) * scale;
  std::vector<uint8_t> img(static_cast<size_t>(side) * side, 255);
  for (int r = 0; r < size; r++) {
    for (int c = 0; c < size; c++) {
      if (!modules[r * size + c]) continue;
      for (int dy = 0; dy < scale; dy++) {
        uint8_t* row = img.data() + static_cast<size_t>((r + quiet) * scale + dy) * side;
        std::fill(row + static_cast<size_t>(c + quiet) * scale,
                  row + static_cast<size_t>(c + quiet + 1) * scale, uint8_t{0});
      }
    }
  }
  *out_w = side;
  *out_h = side;
  return img;
}


// グレースケール画像を NV21 フレームに詰める。彩度平面は 128（無彩色）で埋めるだけで、
// 輝度平面がそのまま QR になる。
std::vector<uint8_t> lumaToNv21(const std::vector<uint8_t>& luma, int w, int h) {
  std::vector<uint8_t> nv21(static_cast<size_t>(w) * h +
                                static_cast<size_t>(w) * ((h + 1) / 2),
                            128);
  std::copy(luma.begin(), luma.end(), nv21.begin());
  return nv21;
}

}  // namespace


TEST_CASE("db_core_qr_decode round-trips a generated pairing QR code") {
  const std::string text = "doorbell-pair:10.0.1.5:47172|abc123|deadbeef";
  int size = 0;
  unsigned char* modules = db_core_qr_encode(text.c_str(), &size);
  REQUIRE(modules != nullptr);
  int w = 0, h = 0;
  const std::vector<uint8_t> img = rasterizeQr(modules, size, 8, 4, &w, &h);
  db_free(reinterpret_cast<char*>(modules));

  char* decoded = nullptr;
  CHECK(db_core_qr_decode(img.data(), w, h, &decoded) == 0);
  REQUIRE(decoded != nullptr);
  CHECK(std::string(decoded) == text);
  db_free(decoded);

  // 引数不正は -1、コードの写っていない画像は 1。どちらの場合も出力は NULL のまま。
  decoded = reinterpret_cast<char*>(1);
  CHECK(db_core_qr_decode(nullptr, w, h, &decoded) == -1);
  CHECK(decoded == nullptr);
  CHECK(db_core_qr_decode(img.data(), 0, h, &decoded) == -1);
  CHECK(db_core_qr_decode(img.data(), w, -1, &decoded) == -1);
  const std::vector<uint8_t> blank(static_cast<size_t>(w) * h, 255);
  CHECK(db_core_qr_decode(blank.data(), w, h, &decoded) == 1);
  CHECK(decoded == nullptr);
}


TEST_CASE("qr scan mode decodes a camera frame and reports it once") {
  struct Sink {
    std::mutex mu;
    std::vector<std::string> events;

    int count(const std::string& type) {
      std::lock_guard<std::mutex> lk(mu);
      int n = 0;
      for (const auto& e : events)
        if (e.find("\"t\":\"" + type + "\"") != std::string::npos) n++;
      return n;
    }

    bool has(const std::string& needle) {
      std::lock_guard<std::mutex> lk(mu);
      for (const auto& e : events)
        if (e.find(needle) != std::string::npos) return true;
      return false;
    }
  } sink;

  const std::string text = "doorbell-pair:10.0.1.7:47172|feedface|"
                           "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
  int size = 0;
  unsigned char* modules = db_core_qr_encode(text.c_str(), &size);
  REQUIRE(modules != nullptr);
  int w = 0, h = 0;
  const std::vector<uint8_t> luma = rasterizeQr(modules, size, 6, 4, &w, &h);
  db_free(reinterpret_cast<char*>(modules));
  const std::vector<uint8_t> frame = lumaToNv21(luma, w, h);

  db_platform_v2 platform{};
  platform.struct_size = sizeof(platform);
  platform.version = DB_PLATFORM_V2_VERSION;
  db_core* core = db_core_create_v2(
      &platform, ":memory:",
      "{\"name\":\"qr-scan\",\"role\":\"door_station\",\"door\":\"d_front\","
      "\"listen_port\":0,\"http_port\":0}");
  REQUIRE(core != nullptr);
  db_core_set_ui_callback(
      core,
      [](void* user, const char* json) {
        auto* s = static_cast<Sink*>(user);
        std::lock_guard<std::mutex> lk(s->mu);
        s->events.push_back(json ? json : "");
      },
      &sink);
  REQUIRE(db_core_start(core) == 0);

  // 走査していない間は同じフレームを流しても何も起きない。
  db_core_on_camera_frame(core, frame.data(), 0, w, h, w, 1);
  std::this_thread::sleep_for(std::chrono::milliseconds(150));
  CHECK(sink.count("qr_scanned") == 0);

  db_core_qr_scan_start(core);
  CHECK(sink.count("qr_scan_state") == 1);
  CHECK(sink.has("\"t\":\"qr_scan_state\",\"active\":true"));

  bool scanned = false;
  for (int i = 0; i < 100 && !scanned; i++) {
    db_core_on_camera_frame(core, frame.data(), 0, w, h, w, 2 + i);
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    scanned = sink.count("qr_scanned") >= 1;
  }
  CHECK(scanned);
  CHECK(sink.has("\"text\":\"" + text + "\""));
  // クラスタ未参加なので招待は行われない。参加済みなら invited:true で invite_result が続く。
  CHECK(sink.has("\"invited\":false"));

  // 2 秒のデバウンス内は同じ内容を再通知しない。
  for (int i = 0; i < 10; i++) {
    db_core_on_camera_frame(core, frame.data(), 0, w, h, w, 200 + i);
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
  }
  CHECK(sink.count("qr_scanned") == 1);

  db_core_qr_scan_stop(core);
  CHECK(sink.has("\"t\":\"qr_scan_state\",\"active\":false"));
  CHECK(sink.count("qr_scan_state") == 2);

  // 停止後は再びフレームを無視する。
  const int before = sink.count("qr_scanned");
  db_core_on_camera_frame(core, frame.data(), 0, w, h, w, 400);
  std::this_thread::sleep_for(std::chrono::milliseconds(150));
  CHECK(sink.count("qr_scanned") == before);

  db_core_stop(core);
  db_core_destroy(core);
}

TEST_CASE("hex roundtrip") {
  Bytes b = {0x00, 0xff, 0x12, 0xab};
  std::string h = hexEncode(b);
  CHECK(h == "00ff12ab");
  Bytes out;
  CHECK(hexDecode(h, out));
  CHECK(out == b);
  CHECK_FALSE(hexDecode("0g", out));
  CHECK_FALSE(hexDecode("abc", out));
}

TEST_CASE("sha256 known vector from FIPS 180-4") {
  CHECK(sha256Hex(Bytes{}) ==
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
  CHECK(sha256Hex(toBytes("abc")) ==
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  CHECK(sha256Hex(toBytes("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")) ==
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");

  CHECK(sha256Hex(Bytes(1'000'000, 'a')) ==
        "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");

  CHECK(sha256Hex(Bytes(56, 'x')) == sha256Hex(Bytes(56, 'x')));
  CHECK(sha256Hex(Bytes(55, 'x')) != sha256Hex(Bytes(56, 'x')));
}

TEST_CASE("file IO covers writeFileBytes, readFileBytes, and listDir") {
  const std::string dir = tempDir() + "/db-test-io-" + genTokenHex(8);
  REQUIRE(makeDir(dir));
  const std::string path = dir + "/blob";
  Bytes data = {0x00, 0x01, 0xff, 0x7f, 0x0a, 0x0d};
  CHECK_FALSE(fileExists(path));
  REQUIRE(writeFileBytes(path, data));
  CHECK(fileExists(path));
  Bytes back;
  REQUIRE(readFileBytes(path, back));
  CHECK(back == data);
  auto names = listDir(dir);
  REQUIRE(names.size() == 1);
  CHECK(names[0] == "blob");
  CHECK(removeFile(path));
  CHECK_FALSE(fileExists(path));
}

TEST_CASE("ids") {
  CHECK(genNodeId().size() == 32);
  CHECK(genNodeId() != genNodeId());
  std::string pin = genPin6();
  CHECK(pin.size() == 6);
}

TEST_CASE("hlc monotonic + lexicographic order") {
  SimClock clock(1000);
  HlcClock hlc(clock, "aabbccdd");
  std::string a = hlc.tick();
  std::string b = hlc.tick();
  CHECK(a < b);
  clock.advance(5);
  std::string c = hlc.tick();
  CHECK(b < c);


  clock.setWall(500);
  std::string d = hlc.tick();
  CHECK(c < d);


  int64_t ms;
  int cnt;
  std::string node;
  REQUIRE(HlcClock::parse(d, &ms, &cnt, &node));
  CHECK(node == "aabbccdd");
  CHECK(HlcClock::format(ms, cnt, node) == d);
}

TEST_CASE("hlc observe merges remote and corrects wall") {
  SimClock clock(1000);
  HlcClock hlc(clock, "aa");
  hlc.observe(HlcClock::format(999'999, 3, "bb"));
  std::string t = hlc.tick();
  int64_t ms;
  int cnt;
  REQUIRE(HlcClock::parse(t, &ms, &cnt, nullptr));
  CHECK(ms == 999'999);
  CHECK(cnt == 4);
  CHECK(hlc.correctedWallMs() == 999'999);
}

TEST_CASE("json helpers") {
  auto doc = json::parse(R"({"a":"x","n":42,"b":true,"o":{"k":1}})");
  REQUIRE(doc);
  CHECK(json::getString(doc.get(), "a") == "x");
  CHECK(json::getInt(doc.get(), "n") == 42);
  CHECK(json::getBool(doc.get(), "b"));
  CHECK(json::getInt(json::get(doc.get(), "o"), "k") == 1);
  CHECK(json::getString(doc.get(), "missing", "d") == "d");

  auto o = json::obj();
  json::set(o.get(), "s", "v");
  json::set(o.get(), "i", int64_t{7});
  cJSON* arr = json::addArr(o.get(), "l");
  json::push(arr, json::parse("1"));
  auto round = json::parse(json::dump(o.get()));
  REQUIRE(round);
  CHECK(json::getInt(round.get(), "i") == 7);
}

TEST_CASE("runloop manual mode: ordering, periodic, cancel") {
  SimClock clock(0, 0);
  Runloop loop(clock);
  std::vector<int> got;
  loop.post([&] { got.push_back(1); });
  loop.postDelayed(10, [&] { got.push_back(3); });
  loop.post([&] { got.push_back(2); });
  CHECK(loop.pumpDue() == 2);
  clock.advance(10);
  loop.pumpDue();
  CHECK(got == std::vector<int>{1, 2, 3});

  int ticks = 0;
  uint64_t id = loop.postEvery(5, [&] { ticks++; });
  for (int i = 0; i < 4; i++) {
    clock.advance(5);
    loop.pumpDue();
  }
  CHECK(ticks == 4);
  loop.cancel(id);
  clock.advance(20);
  loop.pumpDue();
  CHECK(ticks == 4);


  int n = 0;
  uint64_t id2 = 0;
  id2 = loop.postEvery(5, [&] {
    n++;
    if (n == 2) loop.cancel(id2);
  });
  for (int i = 0; i < 5; i++) {
    clock.advance(5);
    loop.pumpDue();
  }
  CHECK(n == 2);
}

TEST_CASE("runloop threaded mode: call and post behavior after stop") {
  RealClock clock;
  Runloop loop(clock);
  loop.start();
  loop.stop();
  int count = 0;
  CHECK(loop.postDelayed(1, [&count] { ++count; }) == 0);
  CHECK_FALSE(loop.post([&count] { ++count; }));
  CHECK_FALSE(loop.callSync([&count] { ++count; }));
  CHECK(count == 0);
}

TEST_CASE("runloop manual mode: callSync is inline and pumpDue executes posts") {
  SimClock clock(0, 0);
  Runloop loop(clock);
  int value = 0;
  CHECK(loop.callSync([&value] { value = 7; }) == true);
  CHECK(value == 7);
  CHECK(loop.callSync([&] { CHECK(loop.post([&value] { value = 8; })); }) == true);
  CHECK(loop.pumpDue() == 1);
  CHECK(value == 8);
  CHECK(loop.post([&value] { value = 9; }));
  CHECK(loop.pumpDue() == 1);
  CHECK(value == 9);
}

TEST_CASE("runloop: callSync does not deadlock while stopping") {
  RealClock clock;
  Runloop loop(clock);
  loop.start();

  std::atomic<bool> allow{false};
  std::atomic<int> value{0};

  loop.post([&allow, &value] {
    while (!allow.load()) {
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    ++value;
  });

  bool call_ok = false;
  std::thread worker([&] { call_ok = loop.callSync([&value] { ++value; }); });

  std::this_thread::sleep_for(std::chrono::milliseconds(50));
  allow.store(true);
  auto start = std::chrono::steady_clock::now();
  loop.stop();
  worker.join();
  auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                     std::chrono::steady_clock::now() - start)
                     .count();
  CHECK(elapsed < 5000);
  CHECK((call_ok == true || call_ok == false));
  CHECK(value.load() >= 1);
}

TEST_CASE("runloop: cancel(0) no-op") { RealClock clock; Runloop loop(clock); CHECK_NOTHROW(loop.cancel(0)); }

TEST_CASE("runloop threaded mode: post + callSync") {
  RealClock clock;
  Runloop loop(clock);
  loop.start();
  int x = 0;
  loop.callSync([&] { x = 42; });
  CHECK(x == 42);
  loop.stop();
}
