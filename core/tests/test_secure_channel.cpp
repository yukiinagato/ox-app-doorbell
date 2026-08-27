// SecureChannel 単体テスト: 握手・双方向 AEAD・PSK 不一致・改竄・再生。
// 配送はテストが完全制御する Wire (キュー) で行い、改竄/再生を注入する。
#include <algorithm>
#include <deque>
#include <memory>
#include <string>
#include <vector>

#include "doctest.h"
#include "mesh/secure_channel.h"
#include "util/clock.h"
#include "util/runloop.h"

using namespace db;

namespace {

// テスト制御の双方向キュー。フレームは pump されるまで滞留する。
struct Wire {
  std::deque<Bytes> a2b, b2a;
  std::vector<Bytes> log;  // 線上に流れた全フレーム (PSK 漏れ検査用)
};

struct TestConn : public IConn {
  Wire& wire;
  bool is_a;
  bool open = true;
  TestConn* peer = nullptr;
  std::function<void(const Bytes&)> on_frame;
  std::function<void()> on_close;

  TestConn(Wire& w, bool a) : wire(w), is_a(a) {}

  void send(const Bytes& f) override {
    if (!open) return;
    wire.log.push_back(f);
    (is_a ? wire.a2b : wire.b2a).push_back(f);
  }
  void close() override {
    if (!open) return;
    open = false;
    if (peer && peer->open) {
      peer->open = false;
      if (peer->on_close) peer->on_close();
    }
  }
  std::string remoteAddr() const override { return is_a ? "B" : "A"; }
  void setCallbacks(std::function<void(const Bytes&)> f, std::function<void()> c) override {
    on_frame = std::move(f);
    on_close = std::move(c);
  }
};

// 両側 1 式 (SimClock/Runloop 共有)
struct Pair {
  SimClock clock{0, 0};
  Runloop loop{clock};
  Wire wire;
  std::shared_ptr<TestConn> ca, cb;
  std::shared_ptr<SecureChannel> a, b;
  std::vector<std::string> got_a, got_b;
  int close_a = 0, close_b = 0, est_a = 0, est_b = 0;

  Pair(const std::array<uint8_t, 32>& psk_a, const std::array<uint8_t, 32>& psk_b,
       const std::string& ida = "aaaa000000000000", const std::string& idb = "bbbb000000000000") {
    ca = std::make_shared<TestConn>(wire, true);
    cb = std::make_shared<TestConn>(wire, false);
    ca->peer = cb.get();
    cb->peer = ca.get();
    a = std::make_shared<SecureChannel>(loop, ca, /*initiator=*/true, psk_a, ida, 1000);
    b = std::make_shared<SecureChannel>(loop, cb, /*initiator=*/false, psk_b, idb, 1000);
    SecureChannel::Callbacks cba;
    cba.on_established = [this] { est_a++; };
    cba.on_message = [this](const std::string& m) { got_a.push_back(m); };
    cba.on_close = [this] { close_a++; };
    a->setCallbacks(std::move(cba));
    SecureChannel::Callbacks cbb;
    cbb.on_established = [this] { est_b++; };
    cbb.on_message = [this](const std::string& m) { got_b.push_back(m); };
    cbb.on_close = [this] { close_b++; };
    b->setCallbacks(std::move(cbb));
    a->start();
    b->start();
  }

  // キューのフレームを交互に配送 (滞留が無くなるまで)
  void pump() {
    for (;;) {
      loop.pumpDue();
      bool progress = false;
      if (!wire.a2b.empty()) {
        Bytes f = wire.a2b.front();
        wire.a2b.pop_front();
        if (cb->open && cb->on_frame) cb->on_frame(f);
        progress = true;
      }
      if (!wire.b2a.empty()) {
        Bytes f = wire.b2a.front();
        wire.b2a.pop_front();
        if (ca->open && ca->on_frame) ca->on_frame(f);
        progress = true;
      }
      if (!progress) break;
    }
    loop.pumpDue();
  }
};

std::array<uint8_t, 32> mkPsk(uint8_t fill) {
  std::array<uint8_t, 32> k{};
  k.fill(fill);
  return k;
}

// needle が haystack 内に現れるか (PSK 漏れ検査)
bool containsBytes(const Bytes& hay, const uint8_t* needle, size_t n) {
  if (hay.size() < n) return false;
  return std::search(hay.begin(), hay.end(), needle, needle + n) != hay.end();
}

}  // namespace

TEST_CASE("secure_channel: 正常握手 + 双方向 AEAD + PSK は線上に流れない") {
  auto psk = mkPsk(0x42);
  Pair p(psk, psk);
  p.pump();
  CHECK(p.est_a == 1);
  CHECK(p.est_b == 1);
  CHECK(p.a->established());
  CHECK(p.b->established());
  CHECK(p.a->peerId() == "bbbb000000000000");
  CHECK(p.b->peerId() == "aaaa000000000000");

  p.a->sendMessage("{\"n\":1}");
  p.a->sendMessage("{\"n\":2}");
  p.b->sendMessage("{\"r\":9}");
  p.pump();
  REQUIRE(p.got_b.size() == 2);  // 順序保存
  CHECK(p.got_b[0] == "{\"n\":1}");
  CHECK(p.got_b[1] == "{\"n\":2}");
  REQUIRE(p.got_a.size() == 1);
  CHECK(p.got_a[0] == "{\"r\":9}");
  CHECK(p.close_a == 0);
  CHECK(p.close_b == 0);

  // 平文が暗号化されている (線上のフレームに現れない) + PSK も流れない
  for (const auto& f : p.wire.log) {
    const std::string needle = "\"n\":1";
    CHECK_FALSE(containsBytes(f, reinterpret_cast<const uint8_t*>(needle.data()), needle.size()));
    CHECK_FALSE(containsBytes(f, psk.data(), psk.size()));
  }
}

TEST_CASE("secure_channel: 確立前の送信はキューされ確立後に流れる") {
  auto psk = mkPsk(0x01);
  Pair p(psk, psk);
  p.a->sendMessage("early");  // 握手完了前
  CHECK_FALSE(p.a->established());
  p.pump();
  CHECK(p.a->established());
  REQUIRE(p.got_b.size() == 1);
  CHECK(p.got_b[0] == "early");
}

TEST_CASE("secure_channel: PSK 不一致は確立前に拒否 (別クラスタに混ざらない)") {
  Pair p(mkPsk(0x11), mkPsk(0x22));
  p.a->sendMessage("secret");
  p.pump();
  CHECK_FALSE(p.a->established());
  CHECK_FALSE(p.b->established());
  CHECK(p.est_a == 0);
  CHECK(p.est_b == 0);
  CHECK(p.close_a + p.close_b >= 1);  // 少なくとも一方が確認失敗で切断
  CHECK(p.got_b.empty());
  // キューされていた平文は一切流れていない
  for (const auto& f : p.wire.log) {
    const std::string needle = "secret";
    CHECK_FALSE(containsBytes(f, reinterpret_cast<const uint8_t*>(needle.data()), needle.size()));
  }
}

TEST_CASE("secure_channel: 改竄フレームで即切断") {
  auto psk = mkPsk(0x33);
  Pair p(psk, psk);
  p.pump();
  REQUIRE(p.a->established());
  p.a->sendMessage("{\"x\":\"tamper-me\"}");
  REQUIRE(p.wire.a2b.size() == 1);
  p.wire.a2b.front().back() ^= 0x01;  // 暗号文の末尾 1bit 反転
  p.pump();
  CHECK(p.got_b.empty());
  CHECK(p.close_b >= 1);  // 復号失敗 → 即切断
  CHECK_FALSE(p.b->established());
}

TEST_CASE("secure_channel: ヘッダ (フレーム番号) 改竄も検出して切断") {
  auto psk = mkPsk(0x44);
  Pair p(psk, psk);
  p.pump();
  REQUIRE(p.a->established());
  p.a->sendMessage("m");
  REQUIRE(p.wire.a2b.size() == 1);
  p.wire.a2b.front()[9] ^= 0x01;  // frame_no の最下位バイト (AD として認証されている)
  p.pump();
  CHECK(p.got_b.empty());
  CHECK(p.close_b >= 1);
}

TEST_CASE("secure_channel: 再生 (同一フレーム再送) は拒否・切断") {
  auto psk = mkPsk(0x55);
  Pair p(psk, psk);
  p.pump();
  REQUIRE(p.a->established());
  p.a->sendMessage("once");
  REQUIRE(p.wire.a2b.size() == 1);
  const Bytes replay = p.wire.a2b.front();  // 生フレームを控えておく
  p.pump();
  REQUIRE(p.got_b.size() == 1);
  CHECK(p.close_b == 0);
  // 同一フレームを再注入 → フレーム番号の巻き戻り検出で切断
  p.cb->on_frame(replay);
  p.pump();
  CHECK(p.got_b.size() == 1);  // 二重配送されない
  CHECK(p.close_b >= 1);
  CHECK_FALSE(p.b->established());
}

TEST_CASE("secure_channel: 欠番 (フレーム損失) は許容 — 後続フレームは通る") {
  auto psk = mkPsk(0x66);
  Pair p(psk, psk);
  p.pump();
  REQUIRE(p.a->established());
  p.a->sendMessage("lost");
  p.a->sendMessage("kept");
  REQUIRE(p.wire.a2b.size() == 2);
  p.wire.a2b.pop_front();  // 1 枚目を落とす (lossy リンクの模擬)
  p.pump();
  REQUIRE(p.got_b.size() == 1);
  CHECK(p.got_b[0] == "kept");
  CHECK(p.close_b == 0);  // 損失では切断しない
}

TEST_CASE("secure_channel: 握手タイムアウトで切断") {
  auto psk = mkPsk(0x77);
  Pair p(psk, psk);
  // pump しない = HS1 が届かないまま時間だけ進める
  p.clock.advance(1001);
  p.loop.pumpDue();
  CHECK_FALSE(p.a->established());
  CHECK(p.close_a >= 1);
}
