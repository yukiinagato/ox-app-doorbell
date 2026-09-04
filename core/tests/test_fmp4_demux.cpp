// Round trips the live fMP4 produced by fmp4::buildInit / VideoTrack through fmp4::Demuxer,
// which is what the Windows and Swift shells feed their platform decoders with.
#include <cstring>
#include <string>
#include <vector>

#include "doctest.h"
#include "media/fmp4.h"
#include "media/fmp4_demux.h"
#include "media/video_track.h"

using namespace db;

namespace {

struct BitWriter {
  Bytes out;
  uint32_t cur = 0;
  int nbits = 0;
  void bit(int b) {
    cur = (cur << 1) | (b & 1);
    if (++nbits == 8) {
      out.push_back(static_cast<uint8_t>(cur));
      cur = 0;
      nbits = 0;
    }
  }
  void u(uint32_t v, int n) {
    for (int i = n - 1; i >= 0; i--) bit((v >> i) & 1);
  }
  void ue(uint32_t v) {
    uint32_t k = v + 1;
    int n = 0;
    while ((k >> n) > 1) n++;
    u(0, n);
    u(k, n + 1);
  }
  void trailing() {
    bit(1);
    while (nbits) bit(0);
  }
};

Bytes makeNal(uint8_t header, const Bytes& rbsp) {
  Bytes nal;
  nal.push_back(header);
  int zeros = 0;
  for (uint8_t b : rbsp) {
    if (zeros >= 2 && b <= 3) {
      nal.push_back(0x03);
      zeros = 0;
    }
    nal.push_back(b);
    zeros = (b == 0) ? zeros + 1 : 0;
  }
  return nal;
}

Bytes makeSps(int mbs_w, int map_h) {
  BitWriter bw;
  bw.u(66, 8);
  bw.u(0, 8);
  bw.u(30, 8);
  bw.ue(0);
  bw.ue(0);
  bw.ue(2);
  bw.ue(1);
  bw.u(0, 1);
  bw.ue(static_cast<uint32_t>(mbs_w - 1));
  bw.ue(static_cast<uint32_t>(map_h - 1));
  bw.u(1, 1);
  bw.u(0, 1);
  bw.u(0, 1);
  bw.u(0, 1);
  bw.trailing();
  return makeNal(0x67, bw.out);
}

Bytes makePps() {
  BitWriter bw;
  for (int i = 0; i < 2; i++) bw.ue(0);
  bw.u(0, 2);
  for (int i = 0; i < 3; i++) bw.ue(0);
  bw.u(0, 1);
  bw.u(0, 2);
  for (int i = 0; i < 3; i++) bw.ue(0);
  bw.u(0, 3);
  bw.trailing();
  return makeNal(0x68, bw.out);
}

Bytes makeSlice(bool idr, size_t payload, uint8_t seed) {
  Bytes nal;
  nal.push_back(idr ? 0x65 : 0x41);
  for (size_t i = 0; i < payload; i++) nal.push_back(static_cast<uint8_t>(seed + (i % 0x40)));
  return nal;
}

Bytes annexb(const std::vector<Bytes>& nals) {
  Bytes out;
  for (const Bytes& n : nals) {
    const uint8_t sc[4] = {0, 0, 0, 1};
    out.insert(out.end(), sc, sc + 4);
    out.insert(out.end(), n.begin(), n.end());
  }
  return out;
}

struct Collected {
  std::vector<fmp4::Demuxer::Config> configs;
  std::vector<fmp4::Demuxer::AccessUnit> units;
  void attach(fmp4::Demuxer* d) {
    d->on_config = [this](const fmp4::Demuxer::Config& c) { configs.push_back(c); };
    d->on_sample = [this](fmp4::Demuxer::AccessUnit&& au) { units.push_back(std::move(au)); };
  }
};

// Pulls everything a subscriber would receive from the track right now.
Bytes drain(VideoTrack::Reader& reader) {
  Bytes out;
  for (;;) {
    bool ended = false;
    Bytes chunk = reader.pull(0, &ended);
    if (chunk.empty() || ended) break;
    out.insert(out.end(), chunk.begin(), chunk.end());
  }
  return out;
}

}  // namespace

TEST_CASE("fmp4_demux: round-trips VideoTrack output into Annex-B access units") {
  const Bytes sps = makeSps(40, 23);  // 640x368
  const Bytes pps = makePps();
  VideoTrack track;
  track.setEnabled(true);
  auto reader = track.subscribe();

  // The track keeps only the newest fragment for a subscriber, so drain after every push, the
  // way the HTTP writer does.
  Bytes idr = annexb({sps, pps, makeSlice(true, 300, 0x80)});
  track.push(idr.data(), idr.size(), true, 1000);
  Bytes stream = drain(*reader);
  Bytes p1 = annexb({makeSlice(false, 120, 0x90)});
  track.push(p1.data(), p1.size(), false, 1040);
  Bytes more = drain(*reader);
  stream.insert(stream.end(), more.begin(), more.end());
  Bytes p2 = annexb({makeSlice(false, 130, 0xa0)});
  track.push(p2.data(), p2.size(), false, 1080);
  more = drain(*reader);
  stream.insert(stream.end(), more.begin(), more.end());
  // A keepalive box, exactly as httpd writes it while nothing is pending.
  const uint8_t free_box[8] = {0, 0, 0, 8, 'f', 'r', 'e', 'e'};
  stream.insert(stream.end(), free_box, free_box + 8);

  fmp4::Demuxer d;
  Collected got;
  got.attach(&d);

  SUBCASE("whole stream at once") {
    REQUIRE(d.feed(stream.data(), stream.size()));
  }
  SUBCASE("one byte at a time") {
    for (uint8_t b : stream) REQUIRE(d.feed(&b, 1));
  }
  SUBCASE("odd chunk sizes") {
    size_t i = 0;
    size_t n = 7;
    while (i < stream.size()) {
      size_t take = std::min(n, stream.size() - i);
      REQUIRE(d.feed(stream.data() + i, take));
      i += take;
      n = (n * 3) % 61 + 1;
    }
  }

  REQUIRE(d.error().empty());
  REQUIRE(got.configs.size() == 1);
  CHECK(got.configs[0].sps == sps);
  CHECK(got.configs[0].pps == pps);
  CHECK(got.configs[0].width == 640);
  CHECK(got.configs[0].height == 368);

  REQUIRE(got.units.size() == 3);
  CHECK(got.units[0].key);
  CHECK_FALSE(got.units[1].key);
  CHECK_FALSE(got.units[2].key);
  // The keyframe carries SPS and PPS ahead of the IDR slice, all with 4-byte start codes.
  CHECK(got.units[0].annexb == annexb({sps, pps, makeSlice(true, 300, 0x80)}));
  CHECK(got.units[1].annexb == p1);
  CHECK(got.units[2].annexb == p2);
  // Capture times come from the dbts box; decode times follow the track's own timeline.
  CHECK(got.units[0].capture_ms == 1000);
  CHECK(got.units[1].capture_ms == 1040);
  CHECK(got.units[2].capture_ms == 1080);
  CHECK(got.units[1].dts == got.units[0].dts + got.units[0].dur_ms);
  CHECK(got.units[2].dts == got.units[1].dts + got.units[1].dur_ms);
  CHECK(d.buffered() == 0);
  CHECK(d.samples() == 3);
}

TEST_CASE("fmp4_demux: a new init segment replaces the configuration") {
  const Bytes sps_a = makeSps(40, 23), sps_b = makeSps(80, 45), pps = makePps();
  fmp4::Demuxer d;
  Collected got;
  got.attach(&d);
  Bytes init_a = fmp4::buildInit(sps_a, pps);
  Bytes init_b = fmp4::buildInit(sps_b, pps);
  REQUIRE(d.feed(init_a.data(), init_a.size()));
  REQUIRE(d.feed(init_b.data(), init_b.size()));
  REQUIRE(got.configs.size() == 2);
  CHECK(got.configs[0].width == 640);
  CHECK(got.configs[1].width == 1280);
  CHECK(got.configs[1].sps == sps_b);
}

TEST_CASE("fmp4_demux: rejects corrupt or oversized input instead of buffering it") {
  const Bytes sps = makeSps(40, 23), pps = makePps();
  Bytes init = fmp4::buildInit(sps, pps);

  SUBCASE("moof before the init segment") {
    fmp4::Demuxer d;
    fmp4::Sample s;
    s.data = {0, 0, 0, 1, 0x65};
    s.key = true;
    Bytes frag = fmp4::buildFragment(1, 0, {s});
    CHECK_FALSE(d.feed(frag.data(), frag.size()));
    CHECK(d.error() == "moof before the init segment");
    CHECK_FALSE(d.feed(init.data(), init.size()));  // stays failed until reset
    d.reset();
    CHECK(d.feed(init.data(), init.size()));
    CHECK(d.configured());
  }
  SUBCASE("box larger than its ceiling") {
    fmp4::Demuxer d;
    const uint8_t huge[8] = {0x01, 0, 0, 0, 'm', 'd', 'a', 't'};  // 16 MB mdat header
    CHECK_FALSE(d.feed(huge, sizeof(huge)));
    CHECK(d.error() == "box too large");
  }
  SUBCASE("moov without avcC") {
    fmp4::Demuxer d;
    const uint8_t moov[16] = {0, 0, 0, 16, 'm', 'o', 'o', 'v', 0, 0, 0, 8, 'f', 'r', 'e', 'e'};
    CHECK_FALSE(d.feed(moov, sizeof(moov)));
    CHECK(d.error() == "moov has no avcC");
  }
  SUBCASE("sample size larger than mdat") {
    fmp4::Demuxer d;
    REQUIRE(d.feed(init.data(), init.size()));
    fmp4::Sample s;
    s.data = {0, 0, 0, 1, 0x65};
    s.key = true;
    Bytes frag = fmp4::buildFragment(1, 0, {s});
    // Shrink the mdat payload to zero bytes: keep the moof, then write an 8-byte empty mdat.
    size_t moof_size = (static_cast<size_t>(frag[0]) << 24) | (frag[1] << 16) | (frag[2] << 8) |
                       frag[3];
    Bytes broken(frag.begin(), frag.begin() + static_cast<std::ptrdiff_t>(moof_size));
    const uint8_t mdat[8] = {0, 0, 0, 8, 'm', 'd', 'a', 't'};
    broken.insert(broken.end(), mdat, mdat + 8);
    CHECK_FALSE(d.feed(broken.data(), broken.size()));
    CHECK(d.error() == "trun sample size exceeds mdat");
  }
}

TEST_CASE("fmp4_demux: parseAvcC reads the first SPS and PPS and the NAL length size") {
  const Bytes sps = makeSps(40, 23), pps = makePps();
  Bytes avcc;
  avcc.push_back(1);
  avcc.push_back(sps[1]);
  avcc.push_back(sps[2]);
  avcc.push_back(sps[3]);
  avcc.push_back(0xfc | 1);  // lengthSizeMinusOne = 1 → 2-byte lengths
  avcc.push_back(0xe0 | 1);
  avcc.push_back(static_cast<uint8_t>(sps.size() >> 8));
  avcc.push_back(static_cast<uint8_t>(sps.size()));
  avcc.insert(avcc.end(), sps.begin(), sps.end());
  avcc.push_back(1);
  avcc.push_back(static_cast<uint8_t>(pps.size() >> 8));
  avcc.push_back(static_cast<uint8_t>(pps.size()));
  avcc.insert(avcc.end(), pps.begin(), pps.end());
  Bytes got_sps, got_pps;
  int len_size = 0;
  REQUIRE(fmp4::Demuxer::parseAvcC(avcc.data(), avcc.size(), &got_sps, &got_pps, &len_size));
  CHECK(got_sps == sps);
  CHECK(got_pps == pps);
  CHECK(len_size == 2);
  CHECK_FALSE(fmp4::Demuxer::parseAvcC(avcc.data(), 6, nullptr, nullptr, nullptr));
}
