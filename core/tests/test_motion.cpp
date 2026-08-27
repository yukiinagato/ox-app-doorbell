// MotionDetector (動体検知) のテスト。
//  - 静止画連続 → 発火なし / 一部領域の変化 → 発火 / min_interval_s 抑制
//  - sensitivity 境界 (変化率がちょうど閾値を跨ぐ) / ノイズ (±2 輝度揺れ) 耐性
//  - 学習期間 (最初の数フレームは発火禁止) / 無効時は完全に無反応
// ts_ms はテストが SimClock 的に自分で刻む (実時間には依存しない)。
#include <cstdint>
#include <functional>
#include <random>
#include <vector>

#include "doctest.h"
#include "media/motion_detector.h"

using namespace db;

namespace {

// ---------- 合成フレーム ----------

// NV12。Y 面は yfn(r,c)、色度面は 128 固定 (輝度しか使わないので値は無関係)。
RawFrame makeNv12(int w, int h, int64_t ts_ms,
                  const std::function<uint8_t(int, int)>& yfn) {
  RawFrame f;
  f.format = 1;
  f.w = w;
  f.h = h;
  f.stride = w;
  f.ts_ms = ts_ms;
  f.data.assign(static_cast<size_t>(w) * h + static_cast<size_t>(w) * ((h + 1) / 2), 128);
  for (int r = 0; r < h; r++)
    for (int c = 0; c < w; c++) f.data[static_cast<size_t>(r) * w + c] = yfn(r, c);
  return f;
}

// 一様輝度
RawFrame flat(int w, int h, int64_t ts_ms, uint8_t y) {
  return makeNv12(w, h, ts_ms, [y](int, int) { return y; });
}

// 左上の rw×rh 画素の矩形だけ輝度 hi、残り lo
RawFrame withRect(int w, int h, int64_t ts_ms, int rw, int rh, uint8_t lo, uint8_t hi) {
  return makeNv12(w, h, ts_ms, [=](int r, int c) { return (r < rh && c < rw) ? hi : lo; });
}

// 発火を数えるだけの器
struct FireLog {
  std::vector<int64_t> ts;
  std::vector<double> pct;
  void attach(MotionDetector& md) {
    md.onMotion([this](int64_t t, double p) {
      ts.push_back(t);
      pct.push_back(p);
    });
  }
};

// 64x48 フレーム → 32x24 グリッド (1 ブロック = 2x2 画素)
constexpr int W = 64, H = 48;

}  // namespace

TEST_CASE("motion: 静止画連続では発火しない") {
  MotionDetector md;
  md.setConfig({true, 100, 0});  // 最も敏感な設定でも
  FireLog log;
  log.attach(md);
  for (int i = 0; i < 20; i++) md.feed(flat(W, H, i * 100, 80));
  CHECK(log.ts.empty());
  CHECK(md.lastChangedPercent() == doctest::Approx(0.0));
}

TEST_CASE("motion: 一部領域が動くと発火する") {
  MotionDetector md;
  md.setConfig({true, 50, 0});  // 閾値 25.5%
  FireLog log;
  log.attach(md);
  int64_t t = 0;
  // 学習期間: 静止画
  for (int i = 0; i < MotionDetector::kLearnFrames; i++) md.feed(flat(W, H, t += 100, 60));
  // 画面の約 4 割の矩形が現れたり消えたり (交互差分は常に ~41.7%)
  for (int i = 0; i < 4; i++) {
    if (i % 2 == 0)
      md.feed(withRect(W, H, t += 100, 40, 32, 60, 200));  // 20x16 ブロック = 41.7%
    else
      md.feed(flat(W, H, t += 100, 60));
  }
  REQUIRE(!log.ts.empty());
  CHECK(log.pct[0] == doctest::Approx(100.0 * 20 * 16 / (32.0 * 24.0)));
  // min_interval_s=0 なので閾値越えが続く限り発火し続けてよい (単発ではないことだけ確認)
  CHECK(log.ts.front() >= 100 * (MotionDetector::kLearnFrames + 2));  // 連続 2 フレーム後
}

TEST_CASE("motion: 発火は閾値越え連続 2 フレームが必要 (単発スパイクは無視)") {
  MotionDetector md;
  md.setConfig({true, 50, 0});
  FireLog log;
  log.attach(md);
  int64_t t = 0;
  for (int i = 0; i < MotionDetector::kLearnFrames; i++) md.feed(flat(W, H, t += 100, 60));
  // 1 フレームだけ大変化 → 直後に元通り 2 フレーム: B との差は 1 回ずつしか続かない…
  // 実際は A→B, B→A の両方が「変化」なので、単発スパイクは B を 1 回だけ挟み
  // その後 A を長く続けると streak は 1 (A→B) → 2 (B→A) になってしまう。
  // 真の単発 (変化 1 回のみ) は「フェードで戻る」: B→A' (差分小) を使う。
  md.feed(withRect(W, H, t += 100, 40, 32, 60, 200));  // A→B: 変化 (streak 1)
  md.feed(withRect(W, H, t += 100, 40, 32, 60, 205));  // B→B': ほぼ同じ (streak 0)
  for (int i = 0; i < 5; i++) md.feed(withRect(W, H, t += 100, 40, 32, 60, 205));
  CHECK(log.ts.empty());
}

TEST_CASE("motion: min_interval_s 内は再発火しない") {
  MotionDetector md;
  md.setConfig({true, 50, 1});  // 1 秒抑制
  FireLog log;
  log.attach(md);
  int64_t t = 0;
  for (int i = 0; i < MotionDetector::kLearnFrames; i++) md.feed(flat(W, H, t += 100, 60));
  // 動き続ける (100ms 間隔で 3 秒分)
  for (int i = 0; i < 30; i++) {
    uint8_t hi = (i % 2 == 0) ? 200 : 60;  // 矩形が点滅 = 毎フレーム大変化
    md.feed(withRect(W, H, t += 100, 40, 32, 60, hi));
  }
  REQUIRE(log.ts.size() >= 2);  // 抑制が明けたら再発火はする
  for (size_t i = 1; i < log.ts.size(); i++) {
    CHECK(log.ts[i] - log.ts[i - 1] >= 1000);  // 発火間隔は必ず 1 秒以上
  }
}

TEST_CASE("motion: sensitivity 境界 — 変化率 25% ちょうどを跨ぐ") {
  // 16x12 ブロック矩形 = 192/768 = ちょうど 25.0%
  // thresholdPercent(51) = 25.01 → 発火しない / thresholdPercent(52) = 24.52 → 発火する
  REQUIRE(MotionDetector::thresholdPercent(51) > 25.0);
  REQUIRE(MotionDetector::thresholdPercent(52) < 25.0);
  for (int sens : {51, 52}) {
    MotionDetector md;
    md.setConfig({true, sens, 0});
    FireLog log;
    log.attach(md);
    int64_t t = 0;
    for (int i = 0; i < MotionDetector::kLearnFrames; i++) md.feed(flat(W, H, t += 100, 60));
    for (int i = 0; i < 6; i++) {
      uint8_t hi = (i % 2 == 0) ? 200 : 60;
      md.feed(withRect(W, H, t += 100, 32, 24, 60, hi));  // 32x24 画素 = 16x12 ブロック
    }
    CHECK(md.lastChangedPercent() == doctest::Approx(25.0));
    if (sens == 51)
      CHECK(log.ts.empty());
    else
      CHECK(!log.ts.empty());
  }
}

TEST_CASE("motion: ±2 程度の輝度ノイズでは誤発火しない") {
  MotionDetector md;
  md.setConfig({true, 100, 0});  // 最も敏感 (閾値 1%)
  FireLog log;
  log.attach(md);
  std::mt19937 rng(12345);
  std::uniform_int_distribution<int> jitter(-2, 2);
  int64_t t = 0;
  for (int i = 0; i < 30; i++) {
    md.feed(makeNv12(W, H, t += 100, [&](int r, int c) {
      int base = 40 + (r + c) % 60;  // 適当な模様
      return static_cast<uint8_t>(base + jitter(rng));
    }));
  }
  CHECK(log.ts.empty());
}

TEST_CASE("motion: 学習期間中は大変化でも発火しない") {
  MotionDetector md;
  md.setConfig({true, 100, 0});
  FireLog log;
  log.attach(md);
  // 最初から毎フレーム全面が変わる過酷な入力
  int64_t t = 0;
  int fed = 0;
  auto feedFlip = [&] { md.feed(flat(W, H, t += 100, (fed++ % 2) ? 200 : 20)); };
  for (int i = 0; i < MotionDetector::kLearnFrames; i++) feedFlip();
  CHECK(log.ts.empty());  // 学習期間内はゼロ
  feedFlip();             // streak 1
  feedFlip();             // streak 2 → ここで初めて発火してよい
  CHECK(log.ts.size() == 1);
}

TEST_CASE("motion: enabled=false では何もしない / 再有効化で学習し直す") {
  MotionDetector md;
  md.setConfig({false, 100, 0});
  FireLog log;
  log.attach(md);
  int64_t t = 0;
  for (int i = 0; i < 10; i++) md.feed(flat(W, H, t += 100, (i % 2) ? 200 : 20));
  CHECK(log.ts.empty());
  // 再有効化: 学習し直すので、直後の数フレームも発火しない
  md.setConfig({true, 100, 0});
  for (int i = 0; i < MotionDetector::kLearnFrames; i++)
    md.feed(flat(W, H, t += 100, (i % 2) ? 200 : 20));
  CHECK(log.ts.empty());
}

TEST_CASE("motion: フレーム寸法が変わると学習し直す") {
  MotionDetector md;
  md.setConfig({true, 100, 0});
  FireLog log;
  log.attach(md);
  int64_t t = 0;
  for (int i = 0; i < MotionDetector::kLearnFrames + 2; i++) md.feed(flat(W, H, t += 100, 60));
  // 寸法変更 + 全面輝度変化 — 学習し直し中なので発火しない
  for (int i = 0; i < MotionDetector::kLearnFrames; i++)
    md.feed(flat(W * 2, H * 2, t += 100, (i % 2) ? 200 : 20));
  CHECK(log.ts.empty());
}
