#include "doctest.h"
#include "util/common.h"
#include "util/hlc.h"
#include "util/ids.h"
#include "util/json.h"
#include "util/runloop.h"

using namespace db;

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

TEST_CASE("runloop threaded mode: post + callSync") {
  RealClock clock;
  Runloop loop(clock);
  loop.start();
  int x = 0;
  loop.callSync([&] { x = 42; });
  CHECK(x == 42);
  loop.stop();
}
