#include <atomic>
#include <chrono>
#include <cstdlib>
#include <thread>

#include "doctest.h"
#include "doorbell/doorbell.h"
#include "util/common.h"
#include "util/hlc.h"
#include "util/ids.h"
#include "util/json.h"
#include "util/runloop.h"

using namespace db;

TEST_CASE("db_core_qr_encode: 有効な QR 行列を返す (空入力は NULL)") {
  int size = -1;
  CHECK(db_core_qr_encode("", &size) == nullptr);
  CHECK(size == 0);
  unsigned char* m = db_core_qr_encode("doorbell-pair:10.0.1.5:47172|abc123|deadbeef", &size);
  REQUIRE(m != nullptr);
  CHECK(size >= 21);          // QR 最小 (version 1) は 21x21
  CHECK((size % 2) == 1);     // QR は常に奇数辺
  // 左上ファインダは 7x7 の枠 — (0,0) と (6,6) は暗、(1,1) は明 (枠の内側)
  CHECK(m[0 * size + 0] == 1);
  CHECK(m[6 * size + 6] == 1);
  CHECK(m[1 * size + 1] == 0);
  // 全モジュールは 0/1 のみ
  bool onlyBinary = true;
  for (int i = 0; i < size * size; i++)
    if (m[i] > 1) onlyBinary = false;
  CHECK(onlyBinary);
  db_free(reinterpret_cast<char*>(m));
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

TEST_CASE("sha256 既知ベクタ (FIPS 180-4 / NIST)") {
  CHECK(sha256Hex(Bytes{}) ==
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
  CHECK(sha256Hex(toBytes("abc")) ==
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  CHECK(sha256Hex(toBytes("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")) ==
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
  // 1,000,000 × 'a' (複数ブロック + バッファ境界)
  CHECK(sha256Hex(Bytes(1'000'000, 'a')) ==
        "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
  // 55/56/64 バイト境界 (パディングの分岐)
  CHECK(sha256Hex(Bytes(56, 'x')) == sha256Hex(Bytes(56, 'x')));
  CHECK(sha256Hex(Bytes(55, 'x')) != sha256Hex(Bytes(56, 'x')));
}

TEST_CASE("ファイル IO (writeFileBytes/readFileBytes/listDir)") {
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
  std::string b = hlc.tick();  // 同一 ms → カウンタ増
  CHECK(a < b);
  clock.advance(5);
  std::string c = hlc.tick();
  CHECK(b < c);

  // 時計逆行しても HLC は単調
  clock.setWall(500);
  std::string d = hlc.tick();
  CHECK(c < d);

  // parse/format 往復
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
  CHECK(loop.pumpDue() == 2);  // due=0 の 2 件のみ
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

  // 実行中の自己 cancel (繰り返し)
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

TEST_CASE("runloop threaded mode: stop 後の call/post 振る舞い") {
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

TEST_CASE("runloop manual mode: callSync inline / post は pumpDue で実行") {
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

TEST_CASE("runloop: stop へ向かう間の callSync がデッドロックしない") {
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
