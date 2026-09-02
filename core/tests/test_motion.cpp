




#include <cstdint>
#include <functional>
#include <random>
#include <vector>

#include "doctest.h"
#include "media/motion_detector.h"

using namespace db;

namespace {




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


RawFrame flat(int w, int h, int64_t ts_ms, uint8_t y) {
  return makeNv12(w, h, ts_ms, [y](int, int) { return y; });
}


RawFrame withRect(int w, int h, int64_t ts_ms, int rw, int rh, uint8_t lo, uint8_t hi) {
  return makeNv12(w, h, ts_ms, [=](int r, int c) { return (r < rh && c < rw) ? hi : lo; });
}


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


constexpr int W = 64, H = 48;

}  // namespace

TEST_CASE("motion: consecutive still frames do not trigger") {
  MotionDetector md;
  md.setConfig({true, 100, 0});
  FireLog log;
  log.attach(md);
  for (int i = 0; i < 20; i++) md.feed(flat(W, H, i * 100, 80));
  CHECK(log.ts.empty());
  CHECK(md.lastChangedPercent() == doctest::Approx(0.0));
}

TEST_CASE("motion: movement in part of the frame triggers") {
  MotionDetector md;
  md.setConfig({true, 50, 0});
  FireLog log;
  log.attach(md);
  int64_t t = 0;

  for (int i = 0; i < MotionDetector::kLearnFrames; i++) md.feed(flat(W, H, t += 100, 60));

  for (int i = 0; i < 4; i++) {
    if (i % 2 == 0)
      md.feed(withRect(W, H, t += 100, 40, 32, 60, 200));
    else
      md.feed(flat(W, H, t += 100, 60));
  }
  REQUIRE(!log.ts.empty());
  CHECK(log.pct[0] == doctest::Approx(100.0 * 20 * 16 / (32.0 * 24.0)));

  CHECK(log.ts.front() >= 100 * (MotionDetector::kLearnFrames + 2));
}

TEST_CASE("motion: triggering requires two consecutive frames above threshold") {
  MotionDetector md;
  md.setConfig({true, 50, 0});
  FireLog log;
  log.attach(md);
  int64_t t = 0;
  for (int i = 0; i < MotionDetector::kLearnFrames; i++) md.feed(flat(W, H, t += 100, 60));




  md.feed(withRect(W, H, t += 100, 40, 32, 60, 200));
  md.feed(withRect(W, H, t += 100, 40, 32, 60, 205));
  for (int i = 0; i < 5; i++) md.feed(withRect(W, H, t += 100, 40, 32, 60, 205));
  CHECK(log.ts.empty());
}

TEST_CASE("motion: does not retrigger within min_interval_s") {
  MotionDetector md;
  md.setConfig({true, 50, 1});
  FireLog log;
  log.attach(md);
  int64_t t = 0;
  for (int i = 0; i < MotionDetector::kLearnFrames; i++) md.feed(flat(W, H, t += 100, 60));

  for (int i = 0; i < 30; i++) {
    uint8_t hi = (i % 2 == 0) ? 200 : 60;
    md.feed(withRect(W, H, t += 100, 40, 32, 60, hi));
  }
  REQUIRE(log.ts.size() >= 2);
  for (size_t i = 1; i < log.ts.size(); i++) {
    CHECK(log.ts[i] - log.ts[i - 1] >= 1000);
  }
}

TEST_CASE("motion: sensitivity boundary distinguishes a 25 percent change") {


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
      md.feed(withRect(W, H, t += 100, 32, 24, 60, hi));
    }
    CHECK(md.lastChangedPercent() == doctest::Approx(25.0));
    if (sens == 51)
      CHECK(log.ts.empty());
    else
      CHECK(!log.ts.empty());
  }
}

TEST_CASE("motion: small luminance noise does not cause a false trigger") {
  MotionDetector md;
  md.setConfig({true, 100, 0});
  FireLog log;
  log.attach(md);
  std::mt19937 rng(12345);
  std::uniform_int_distribution<int> jitter(-2, 2);
  int64_t t = 0;
  for (int i = 0; i < 30; i++) {
    md.feed(makeNv12(W, H, t += 100, [&](int r, int c) {
      int base = 40 + (r + c) % 60;
      return static_cast<uint8_t>(base + jitter(rng));
    }));
  }
  CHECK(log.ts.empty());
}

TEST_CASE("motion: large changes do not trigger during the learning period") {
  MotionDetector md;
  md.setConfig({true, 100, 0});
  FireLog log;
  log.attach(md);

  int64_t t = 0;
  int fed = 0;
  auto feedFlip = [&] { md.feed(flat(W, H, t += 100, (fed++ % 2) ? 200 : 20)); };
  for (int i = 0; i < MotionDetector::kLearnFrames; i++) feedFlip();
  CHECK(log.ts.empty());
  feedFlip();             // streak 1
  feedFlip();
  CHECK(log.ts.size() == 1);
}

TEST_CASE("motion: disabling is inert and re-enabling restarts learning") {
  MotionDetector md;
  md.setConfig({false, 100, 0});
  FireLog log;
  log.attach(md);
  int64_t t = 0;
  for (int i = 0; i < 10; i++) md.feed(flat(W, H, t += 100, (i % 2) ? 200 : 20));
  CHECK(log.ts.empty());

  md.setConfig({true, 100, 0});
  for (int i = 0; i < MotionDetector::kLearnFrames; i++)
    md.feed(flat(W, H, t += 100, (i % 2) ? 200 : 20));
  CHECK(log.ts.empty());
}

TEST_CASE("motion: dimension changes restart learning") {
  MotionDetector md;
  md.setConfig({true, 100, 0});
  FireLog log;
  log.attach(md);
  int64_t t = 0;
  for (int i = 0; i < MotionDetector::kLearnFrames + 2; i++) md.feed(flat(W, H, t += 100, 60));

  for (int i = 0; i < MotionDetector::kLearnFrames; i++)
    md.feed(flat(W * 2, H * 2, t += 100, (i % 2) ? 200 : 20));
  CHECK(log.ts.empty());
}
