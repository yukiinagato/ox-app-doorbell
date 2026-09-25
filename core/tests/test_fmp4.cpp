






#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <vector>

#include "doctest.h"
#include "test_env.h"
#include "media/fmp4.h"
#include "media/fmp4_demux.h"
#include "media/video_track.h"
#include "node/node.h"
#include "util/json.h"

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
  void se(int32_t v) { ue(v <= 0 ? static_cast<uint32_t>(-2LL * v)
                                  : static_cast<uint32_t>(2LL * v - 1)); }
  void trailing() {  // rbsp_trailing_bits
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


Bytes makeSps(int mbs_w, int map_h, uint32_t crop_bottom) {
  BitWriter bw;
  bw.u(66, 8);   // profile_idc = baseline
  bw.u(0, 8);    // constraint flags + reserved
  bw.u(30, 8);   // level_idc = 3.0
  bw.ue(0);      // seq_parameter_set_id
  bw.ue(0);      // log2_max_frame_num_minus4
  bw.ue(2);
  bw.ue(1);      // max_num_ref_frames
  bw.u(0, 1);    // gaps_in_frame_num_value_allowed_flag
  bw.ue(static_cast<uint32_t>(mbs_w - 1));  // pic_width_in_mbs_minus1
  bw.ue(static_cast<uint32_t>(map_h - 1));  // pic_height_in_map_units_minus1
  bw.u(1, 1);    // frame_mbs_only_flag
  bw.u(0, 1);    // direct_8x8_inference_flag
  if (crop_bottom > 0) {
    bw.u(1, 1);  // frame_cropping_flag
    bw.ue(0);    // left
    bw.ue(0);    // right
    bw.ue(0);    // top
    bw.ue(crop_bottom);
  } else {
    bw.u(0, 1);
  }
  bw.u(0, 1);    // vui_parameters_present_flag
  bw.trailing();
  return makeNal(0x67, bw.out);  // nal_ref_idc=3, type=7
}

Bytes makePps(uint32_t pps_id = 0, uint32_t sps_id = 0,
              bool entropy_coding_mode = false) {
  BitWriter bw;
  bw.ue(pps_id);    // pic_parameter_set_id
  bw.ue(sps_id);    // seq_parameter_set_id
  bw.u(entropy_coding_mode ? 1 : 0, 1);  // entropy_coding_mode_flag
  bw.u(0, 1);  // bottom_field_pic_order_in_frame_present_flag
  bw.ue(0);    // num_slice_groups_minus1
  bw.ue(0);    // num_ref_idx_l0_default_active_minus1
  bw.ue(0);    // num_ref_idx_l1_default_active_minus1
  bw.u(0, 1);  // weighted_pred_flag
  bw.u(0, 2);  // weighted_bipred_idc
  bw.ue(0);    // pic_init_qp_minus26 (ue(se(0))=0)
  bw.ue(0);    // pic_init_qs_minus26
  bw.ue(0);    // chroma_qp_index_offset
  bw.u(0, 1);  // deblocking_filter_control_present_flag
  bw.u(0, 1);  // constrained_intra_pred_flag
  bw.u(0, 1);  // redundant_pic_cnt_present_flag
  bw.trailing();
  return makeNal(0x68, bw.out);  // type=8
}


Bytes makeSlice(bool idr, size_t payload, uint32_t pps_id = 0,
                uint32_t slice_type = 2) {
  BitWriter bw;
  bw.ue(0);  // first_mb_in_slice
  bw.ue(slice_type);
  bw.ue(pps_id);  // pic_parameter_set_id
  bw.u(0, 4);  // frame_num for makeSps' four-bit syntax
  if (idr) {
    bw.ue(0);  // idr_pic_id
    bw.u(0, 1);  // no_output_of_prior_pics_flag
    bw.u(0, 1);  // long_term_reference_flag
  }
  bw.se(0);  // slice_qp_delta
  for (size_t i = 0; i < payload; ++i)
    bw.u(static_cast<uint32_t>(0x80 + (i % 0x40)), 8);
  bw.trailing();
  Bytes nal = makeNal(idr ? 0x65 : 0x41, bw.out);  // type 5 (IDR) / 1 (non-IDR)
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



struct Box {
  std::string type;
  size_t off = 0;
  size_t size = 0;
  size_t payload = 0;
};

std::vector<Box> childBoxes(const Bytes& buf, size_t start, size_t end) {
  std::vector<Box> out;
  size_t p = start;
  while (p + 8 <= end) {
    uint32_t sz = (static_cast<uint32_t>(buf[p]) << 24) | (buf[p + 1] << 16) |
                  (buf[p + 2] << 8) | buf[p + 3];
    if (sz < 8 || p + sz > end) break;
    Box b;
    b.type.assign(reinterpret_cast<const char*>(&buf[p + 4]), 4);
    b.off = p;
    b.size = sz;
    b.payload = p + 8;
    out.push_back(b);
    p += sz;
  }
  return out;
}

const Box* findBox(const std::vector<Box>& boxes, const std::string& type) {
  for (const auto& b : boxes)
    if (b.type == type) return &b;
  return nullptr;
}

uint32_t be32(const Bytes& b, size_t at) {
  return (static_cast<uint32_t>(b[at]) << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];
}
uint64_t be64(const Bytes& b, size_t at) {
  return (static_cast<uint64_t>(be32(b, at)) << 32) | be32(b, at + 4);
}

bool contains(const Bytes& hay, const Bytes& needle) {
  if (needle.empty() || hay.size() < needle.size()) return false;
  for (size_t i = 0; i + needle.size() <= hay.size(); i++) {
    if (std::memcmp(&hay[i], needle.data(), needle.size()) == 0) return true;
  }
  return false;
}

}  // namespace

TEST_CASE("fmp4: splits Annex B with three- and four-byte start codes") {
  Bytes sps = makeSps(80, 45, 0), pps = makePps(), idr = makeSlice(true, 16);

  Bytes au;
  const uint8_t sc4[4] = {0, 0, 0, 1}, sc3[3] = {0, 0, 1};
  au.insert(au.end(), sc4, sc4 + 4);
  au.insert(au.end(), sps.begin(), sps.end());
  au.insert(au.end(), sc3, sc3 + 3);
  au.insert(au.end(), pps.begin(), pps.end());
  au.insert(au.end(), sc4, sc4 + 4);
  au.insert(au.end(), idr.begin(), idr.end());

  auto nals = fmp4::splitAnnexB(au.data(), au.size());
  REQUIRE(nals.size() == 3);
  CHECK(nals[0].type == 7);
  CHECK(nals[0].n == sps.size());
  CHECK(std::memcmp(nals[0].p, sps.data(), sps.size()) == 0);
  CHECK(nals[1].type == 8);
  CHECK(nals[2].type == 5);
  CHECK(nals[2].n == idr.size());


  CHECK(fmp4::splitAnnexB(nullptr, 0).empty());
  CHECK(fmp4::splitAnnexB(au.data(), 3).empty());
}

TEST_CASE("fmp4: parses SPS dimensions, cropping, EPB, and invalid input") {
  int w = 0, h = 0;
  SUBCASE("1280x720 (80x45 MB)") {
    Bytes sps = makeSps(80, 45, 0);
    REQUIRE(fmp4::parseSpsDims(sps.data(), sps.size(), &w, &h));
    CHECK(w == 1280);
    CHECK(h == 720);
  }
  SUBCASE("640x360 with 40x23 macroblocks and an eight-pixel bottom crop") {
    Bytes sps = makeSps(40, 23, 4);
    REQUIRE(fmp4::parseSpsDims(sps.data(), sps.size(), &w, &h));
    CHECK(w == 640);
    CHECK(h == 360);
  }
  SUBCASE("removes EPB bytes from an SPS before parsing") {


    Bytes sps = makeSps(120, 68, 0);  // 1920x1088
    REQUIRE(fmp4::parseSpsDims(sps.data(), sps.size(), &w, &h));
    CHECK(w == 1920);
    CHECK(h == 1088);
  }
  SUBCASE("invalid input returns false") {
    Bytes pps = makePps();
    CHECK(!fmp4::parseSpsDims(pps.data(), pps.size(), &w, &h));  // type != 7
    Bytes sps = makeSps(80, 45, 0);
    CHECK(!fmp4::parseSpsDims(sps.data(), 3, &w, &h));
    CHECK(!fmp4::parseSpsDims(nullptr, 0, &w, &h));
  }
}

TEST_CASE("fmp4: codecString reports SPS profile, constraints, and level") {
  Bytes sps = makeSps(80, 45, 0);
  CHECK(fmp4::codecString(sps) == "avc1.42001E");  // 66/0x00/30
  CHECK(fmp4::codecString(Bytes{0x67}) == "");
}

TEST_CASE("fmp4: toSample converts AVCC, filters metadata NALUs, and detects keyframes") {
  Bytes sps = makeSps(80, 45, 0), pps = makePps();
  Bytes idr = makeSlice(true, 20), p_sl = makeSlice(false, 12);
  Bytes aud = {0x09, 0x10};
  Bytes sei = {0x06, 0x05, 0x01, 0x88, 0x80};

  Bytes got_sps, got_pps;
  Bytes au = annexb({sps, pps, aud, sei, idr});
  fmp4::Sample s = fmp4::toSample(au.data(), au.size(), &got_sps, &got_pps);
  CHECK(got_sps == sps);
  CHECK(got_pps == pps);
  CHECK(s.key);

  REQUIRE(s.data.size() == 4 + idr.size());
  CHECK(be32(s.data, 0) == idr.size());
  CHECK(std::memcmp(&s.data[4], idr.data(), idr.size()) == 0);


  Bytes au2 = annexb({p_sl});
  fmp4::Sample s2 = fmp4::toSample(au2.data(), au2.size(), &got_sps, &got_pps);
  CHECK(!s2.key);
  CHECK(got_sps == sps);
  REQUIRE(s2.data.size() == 4 + p_sl.size());
  CHECK(be32(s2.data, 0) == p_sl.size());


  Bytes au3 = annexb({sps, pps});
  fmp4::Sample s3 = fmp4::toSample(au3.data(), au3.size(), &got_sps, &got_pps);
  CHECK(s3.data.empty());
}

TEST_CASE("fmp4: init segment contains valid ftyp, moov, avc1, and avcC boxes") {
  Bytes sps = makeSps(80, 45, 0), pps = makePps();
  Bytes init = fmp4::buildInit(sps, pps);
  REQUIRE(init.size() > 100);

  auto top = childBoxes(init, 0, init.size());
  REQUIRE(top.size() == 2);
  CHECK(top[0].type == "ftyp");
  CHECK(top[1].type == "moov");

  CHECK(top[0].size + top[1].size == init.size());

  const Box& moov = top[1];
  auto in_moov = childBoxes(init, moov.payload, moov.off + moov.size);
  REQUIRE(findBox(in_moov, "mvhd"));
  REQUIRE(findBox(in_moov, "trak"));
  REQUIRE(findBox(in_moov, "mvex"));
  // mvhd timescale = 1000
  const Box* mvhd = findBox(in_moov, "mvhd");
  CHECK(be32(init, mvhd->payload + 4 + 8) == 1000);

  const Box* trak = findBox(in_moov, "trak");
  auto in_trak = childBoxes(init, trak->payload, trak->off + trak->size);
  const Box* tkhd = findBox(in_trak, "tkhd");
  REQUIRE(tkhd);

  size_t wh = tkhd->off + tkhd->size - 8;
  CHECK(be32(init, wh) == (1280u << 16));
  CHECK(be32(init, wh + 4) == (720u << 16));

  const Box* mdia = findBox(in_trak, "mdia");
  REQUIRE(mdia);
  auto in_mdia = childBoxes(init, mdia->payload, mdia->off + mdia->size);
  REQUIRE(findBox(in_mdia, "mdhd"));
  REQUIRE(findBox(in_mdia, "hdlr"));
  const Box* minf = findBox(in_mdia, "minf");
  REQUIRE(minf);
  auto in_minf = childBoxes(init, minf->payload, minf->off + minf->size);
  REQUIRE(findBox(in_minf, "vmhd"));
  REQUIRE(findBox(in_minf, "dinf"));
  const Box* stbl = findBox(in_minf, "stbl");
  REQUIRE(stbl);
  auto in_stbl = childBoxes(init, stbl->payload, stbl->off + stbl->size);
  REQUIRE(findBox(in_stbl, "stsd"));
  REQUIRE(findBox(in_stbl, "stts"));
  REQUIRE(findBox(in_stbl, "stsc"));
  REQUIRE(findBox(in_stbl, "stsz"));
  REQUIRE(findBox(in_stbl, "stco"));


  const Box* stsd = findBox(in_stbl, "stsd");
  auto in_stsd = childBoxes(init, stsd->payload + 8, stsd->off + stsd->size);  // ver/flags+count
  const Box* avc1 = findBox(in_stsd, "avc1");
  REQUIRE(avc1);

  CHECK(((init[avc1->payload + 24] << 8) | init[avc1->payload + 26 - 1]) >= 0);
  size_t dims = avc1->payload + 24;
  CHECK(((init[dims] << 8) | init[dims + 1]) == 1280);
  CHECK(((init[dims + 2] << 8) | init[dims + 3]) == 720);
  auto in_avc1 = childBoxes(init, avc1->payload + 78, avc1->off + avc1->size);
  const Box* avcC = findBox(in_avc1, "avcC");
  REQUIRE(avcC);
  size_t p = avcC->payload;
  CHECK(init[p] == 1);          // configurationVersion
  CHECK(init[p + 1] == 66);     // profile (baseline)
  CHECK(init[p + 3] == 30);     // level
  CHECK(init[p + 4] == 0xff);   // lengthSizeMinusOne = 3
  CHECK(init[p + 5] == 0xe1);
  uint16_t sps_len = static_cast<uint16_t>((init[p + 6] << 8) | init[p + 7]);
  REQUIRE(sps_len == sps.size());
  CHECK(std::memcmp(&init[p + 8], sps.data(), sps.size()) == 0);
  size_t q = p + 8 + sps_len;
  CHECK(init[q] == 1);
  uint16_t pps_len = static_cast<uint16_t>((init[q + 1] << 8) | init[q + 2]);
  REQUIRE(pps_len == pps.size());
  CHECK(std::memcmp(&init[q + 3], pps.data(), pps.size()) == 0);
}

TEST_CASE("fmp4: fragments contain sequential mfhd, tfdt, trun, and mdat boxes") {
  Bytes sps, pps;
  Bytes au1 = annexb({makeSlice(true, 24)});
  Bytes au2 = annexb({makeSlice(false, 10)});
  std::vector<fmp4::Sample> samples;
  samples.push_back(fmp4::toSample(au1.data(), au1.size(), &sps, &pps));
  samples.push_back(fmp4::toSample(au2.data(), au2.size(), &sps, &pps));
  samples[0].dur = 40;
  samples[1].dur = 60;

  Bytes frag = fmp4::buildFragment(7, 12345, samples);
  auto top = childBoxes(frag, 0, frag.size());
  REQUIRE(top.size() == 2);
  CHECK(top[0].type == "moof");
  CHECK(top[1].type == "mdat");
  CHECK(top[0].size + top[1].size == frag.size());

  const Box& moof = top[0];
  auto in_moof = childBoxes(frag, moof.payload, moof.off + moof.size);
  const Box* mfhd = findBox(in_moof, "mfhd");
  REQUIRE(mfhd);
  CHECK(be32(frag, mfhd->payload + 4) == 7);  // sequence_number
  const Box* traf = findBox(in_moof, "traf");
  REQUIRE(traf);
  auto in_traf = childBoxes(frag, traf->payload, traf->off + traf->size);
  const Box* tfhd = findBox(in_traf, "tfhd");
  REQUIRE(tfhd);
  CHECK((be32(frag, tfhd->payload) & 0xffffff) == 0x020000);  // default-base-is-moof
  CHECK(be32(frag, tfhd->payload + 4) == 1);                  // track_ID
  const Box* tfdt = findBox(in_traf, "tfdt");
  REQUIRE(tfdt);
  CHECK(frag[tfdt->payload] == 1);                 // version 1 (64bit)
  CHECK(be64(frag, tfdt->payload + 4) == 12345);   // baseMediaDecodeTime
  const Box* trun = findBox(in_traf, "trun");
  REQUIRE(trun);
  CHECK((be32(frag, trun->payload) & 0xffffff) == 0x000701);  // offset+dur+size+flags
  CHECK(be32(frag, trun->payload + 4) == 2);                  // sample_count

  CHECK(be32(frag, trun->payload + 8) == moof.size + 8);

  size_t e0 = trun->payload + 12;
  CHECK(be32(frag, e0) == 40);
  CHECK(be32(frag, e0 + 4) == samples[0].data.size());
  CHECK(be32(frag, e0 + 8) == 0x02000000u);
  size_t e1 = e0 + 12;
  CHECK(be32(frag, e1) == 60);
  CHECK(be32(frag, e1 + 8) == 0x01010000u);  // non-sync

  const Box& mdat = top[1];
  REQUIRE(mdat.size == 8 + samples[0].data.size() + samples[1].data.size());
  CHECK(std::memcmp(&frag[mdat.payload], samples[0].data.data(), samples[0].data.size()) == 0);
}

TEST_CASE("video_track: emits per-frame fragments with capture time and continuous decode time") {
  VideoTrack track;
  track.setEnabled(true);
  CHECK(!track.active());

  Bytes sps = makeSps(80, 45, 0), pps = makePps();
  auto reader = track.subscribe();
  CHECK(track.subscriberCount() == 1);


  Bytes k1 = annexb({sps, pps, makeSlice(true, 30)});
  track.push(k1.data(), k1.size(), true, 1000);
  CHECK(track.active());
  CHECK(track.codecString() == "avc1.42001E");

  bool ended = false;
  Bytes init = reader->pull(100, &ended);
  REQUIRE(!init.empty());
  CHECK(!ended);
  CHECK(std::memcmp(&init[4], "ftyp", 4) == 0);

  Bytes initial_key = reader->pull(100, &ended);
  REQUIRE(!initial_key.empty());
  {
    auto top = childBoxes(initial_key, 0, initial_key.size());
    REQUIRE(top.size() == 3);
    CHECK(top[0].type == "dbts");
    CHECK(be64(initial_key, top[0].payload + 4) == 1000);
    CHECK(top[1].type == "moof");
  }


  Bytes p1 = annexb({makeSlice(false, 8)});
  track.push(p1.data(), p1.size(), false, 1100);
  Bytes frag1 = reader->pull(100, &ended);
  REQUIRE(!frag1.empty());
  {
    auto top = childBoxes(frag1, 0, frag1.size());
    REQUIRE(top.size() == 3);
    CHECK(top[0].type == "dbts");
    CHECK(be32(frag1, top[0].payload) == 1);
    CHECK(be64(frag1, top[0].payload + 4) == 1100);
    CHECK(top[1].type == "moof");
    auto in_moof = childBoxes(frag1, top[1].payload, top[1].off + top[1].size);
    const Box* mfhd = findBox(in_moof, "mfhd");
    CHECK(be32(frag1, mfhd->payload + 4) == 2);
    auto in_traf = childBoxes(frag1, findBox(in_moof, "traf")->payload,
                              findBox(in_moof, "traf")->off + findBox(in_moof, "traf")->size);
    const Box* tfdt = findBox(in_traf, "tfdt");
    CHECK(be64(frag1, tfdt->payload + 4) == 33);
    const Box* trun = findBox(in_traf, "trun");
    CHECK(be32(frag1, trun->payload + 4) == 1);
    CHECK(be32(frag1, trun->payload + 12) == 100);
  }

  track.push(p1.data(), p1.size(), false, 1200);
  Bytes frag2 = reader->pull(100, &ended);
  REQUIRE(!frag2.empty());
  {
    auto top = childBoxes(frag2, 0, frag2.size());
    CHECK(be64(frag2, top[0].payload + 4) == 1200);
    auto in_moof = childBoxes(frag2, top[1].payload, top[1].off + top[1].size);
    auto in_traf = childBoxes(frag2, findBox(in_moof, "traf")->payload,
                              findBox(in_moof, "traf")->off + findBox(in_moof, "traf")->size);
    CHECK(be64(frag2, findBox(in_traf, "tfdt")->payload + 4) == 133);
    CHECK(be32(frag2, findBox(in_traf, "trun")->payload + 4) == 1);
  }


  track.setEnabled(false);
  Bytes after = reader->pull(100, &ended);
  CHECK(after.empty());
  CHECK(ended);
  CHECK(!track.active());
  reader.reset();
  CHECK(track.subscriberCount() == 0);
}

TEST_CASE("video_track: slow live subscribers receive only the latest fragment") {
  VideoTrack track;
  track.setEnabled(true);
  Bytes sps = makeSps(80, 45, 0), pps = makePps();
  auto reader = track.subscribe();

  Bytes k = annexb({sps, pps, makeSlice(true, 16)});
  track.push(k.data(), k.size(), true, 0);
  bool ended = false;
  REQUIRE(!reader->pull(100, &ended).empty());  // init
  REQUIRE(!reader->pull(100, &ended).empty());  // cached random-access fragment


  Bytes kk = annexb({makeSlice(true, 16)});
  for (int i = 1; i <= 3; i++) track.push(kk.data(), kk.size(), true, i * 600);

  Bytes frag = reader->pull(100, &ended);
  REQUIRE(!frag.empty());
  auto top = childBoxes(frag, 0, frag.size());
  REQUIRE(top.size() == 3);
  auto in_moof = childBoxes(frag, top[1].payload, top[1].off + top[1].size);
  CHECK(be32(frag, findBox(in_moof, "mfhd")->payload + 4) == 4);
  CHECK(reader->pull(10, &ended).empty());
  CHECK(!ended);


  track.stop();
  reader->pull(10, &ended);
  CHECK(ended);
}

TEST_CASE("video_track: a late subscriber receives the cached keyframe and requests a new one") {
  VideoTrack track;
  track.setEnabled(true);
  Bytes sps = makeSps(80, 45, 0), pps = makePps();
  Bytes key = annexb({sps, pps, makeSlice(true, 16)});
  Bytes delta = annexb({makeSlice(false, 8)});
  track.push(key.data(), key.size(), true, 1000);
  track.push(delta.data(), delta.size(), false, 1040);

  auto reader = track.subscribe();
  CHECK(track.takeKeyframeRequest());
  CHECK(!track.takeKeyframeRequest());

  bool ended = false;
  REQUIRE(!reader->pull(100, &ended).empty());  // init
  Bytes cached = reader->pull(100, &ended);
  REQUIRE(!cached.empty());
  auto top = childBoxes(cached, 0, cached.size());
  REQUIRE(top.size() == 3);
  CHECK(be64(cached, top[0].payload + 4) == 1000);
  CHECK(reader->pull(10, &ended).empty());

  track.push(key.data(), key.size(), true, 1080);
  Bytes fresh = reader->pull(100, &ended);
  REQUIRE(!fresh.empty());
  top = childBoxes(fresh, 0, fresh.size());
  CHECK(be64(fresh, top[0].payload + 4) == 1080);
  CHECK(track.stats().keyframe_requests == 1);
}

TEST_CASE("[V01] VideoTrack merges in-flight recovery requests and counts each discarded fragment") {
  VideoTrack track;
  track.setEnabled(true);
  const Bytes sps = makeSps(80, 45, 0), pps = makePps();
  const Bytes idr = annexb({sps, pps, makeSlice(true, 16)});
  const Bytes delta = annexb({makeSlice(false, 16)});
  track.push(idr.data(), idr.size(), true, 1000);

  auto first = track.subscribe();
  auto second = track.subscribe();
  CHECK(track.takeKeyframeRequest());
  CHECK_FALSE(track.takeKeyframeRequest());
  bool ended = false;
  REQUIRE_FALSE(first->pull(0, &ended).empty());
  REQUIRE_FALSE(first->pull(0, &ended).empty());
  REQUIRE_FALSE(second->pull(0, &ended).empty());
  REQUIRE_FALSE(second->pull(0, &ended).empty());

  Bytes first_fresh = annexb({makeSlice(true, 16)});
  track.push(first_fresh.data(), first_fresh.size(), false, 1040);
  REQUIRE_FALSE(first->pull(0, &ended).empty());
  REQUIRE_FALSE(second->pull(0, &ended).empty());

  for (int i = 0; i < 3; ++i)
    track.push(delta.data(), delta.size(), false, 1080 + i * 40);
  CHECK(first->pull(0, &ended).empty());
  CHECK(track.takeKeyframeRequest());
  CHECK(second->pull(0, &ended).empty());
  CHECK_FALSE(track.takeKeyframeRequest());

  Bytes recovery = annexb({makeSlice(true, 16)});
  track.push(recovery.data(), recovery.size(), false, 1240);
  CHECK_FALSE(first->pull(0, &ended).empty());

  track.push(delta.data(), delta.size(), false, 1280);
  track.push(delta.data(), delta.size(), false, 1320);
  CHECK(first->pull(0, &ended).empty());
  CHECK(track.takeKeyframeRequest());
}

TEST_CASE("[V01] VideoTrack counts every undisplayed fragment once per reader") {
  VideoTrack track;
  track.setEnabled(true);
  const Bytes sps = makeSps(80, 45, 0), pps = makePps();
  const Bytes idr = annexb({sps, pps, makeSlice(true, 16)});
  const Bytes delta = annexb({makeSlice(false, 16)});
  auto reader = track.subscribe();
  track.push(idr.data(), idr.size(), true, 1000);
  bool ended = false;
  REQUIRE_FALSE(reader->pull(0, &ended).empty());
  REQUIRE_FALSE(reader->pull(0, &ended).empty());
  for (int i = 0; i < 3; ++i)
    track.push(delta.data(), delta.size(), false, 1040 + i * 40);
  Bytes recovery = annexb({makeSlice(true, 16)});
  track.push(recovery.data(), recovery.size(), false, 1160);
  REQUIRE_FALSE(reader->pull(0, &ended).empty());
  CHECK(track.stats().dropped_forward == 3);
  CHECK(reader->pull(0, &ended).empty());
  CHECK(track.stats().dropped_forward == 3);
}

TEST_CASE("[B3][M05] VideoTrack commits a PPS update only at its matching IDR") {
  VideoTrack track;
  track.setEnabled(true);
  const Bytes sps = makeSps(80, 45, 0), pps = makePps();
  const Bytes idr = annexb({sps, pps, makeSlice(true, 16)});
  auto old_reader = track.subscribe();
  track.push(idr.data(), idr.size(), true, 1000);
  bool ended = false;
  Bytes old_init = old_reader->pull(0, &ended);
  REQUIRE_FALSE(old_init.empty());
  REQUIRE_FALSE(old_reader->pull(0, &ended).empty());

  Bytes changed_pps = makePps(0, 0, true);
  Bytes pps_update = annexb({changed_pps});
  track.push(pps_update.data(), pps_update.size(), false, 1040);
  CHECK(old_reader->pull(0, &ended).empty());
  CHECK_FALSE(ended);

  // The staged pair cannot use the old random-access point. A matching parsed IDR is the
  // commit point, after which the old reader ends and the new init is decoder-consumable.
  Bytes changed_idr = annexb({makeSlice(true, 16)});
  track.push(changed_idr.data(), changed_idr.size(), true, 1080);
  CHECK(old_reader->pull(0, &ended).empty());
  CHECK(ended);

  auto new_reader = track.subscribe();
  Bytes new_init = new_reader->pull(0, &ended);
  REQUIRE_FALSE(new_init.empty());
  CHECK(new_init != old_init);
  fmp4::Demuxer software_decoder;
  CHECK(software_decoder.feed(new_init.data(), new_init.size()));
  CHECK(software_decoder.configured());
}

TEST_CASE("[M05] VideoTrack retains the last valid configuration after malformed parameters") {
  VideoTrack track;
  track.setEnabled(true);
  const Bytes sps = makeSps(80, 45, 0), pps = makePps();
  const Bytes idr = annexb({sps, pps, makeSlice(true, 16)});
  auto reader = track.subscribe();
  track.push(idr.data(), idr.size(), true, 1000);
  bool ended = false;
  const Bytes old_init = reader->pull(0, &ended);
  REQUIRE_FALSE(old_init.empty());
  REQUIRE_FALSE(reader->pull(0, &ended).empty());

  const Bytes bad_pps = {0x68, 0xc0};
  const Bytes unsafe = annexb({bad_pps, makeSlice(true, 16)});
  track.push(unsafe.data(), unsafe.size(), true, 1040);
  CHECK(reader->pull(0, &ended).empty());
  CHECK_FALSE(ended);

  const Bytes next = annexb({makeSlice(true, 16)});
  track.push(next.data(), next.size(), true, 1080);
  CHECK_FALSE(reader->pull(0, &ended).empty());
  CHECK(track.active());
  CHECK(track.codecString() == "avc1.42001E");
}

TEST_CASE("[M05] VideoTrack drops an invalid parameter update with a delta frame") {
  VideoTrack track;
  track.setEnabled(true);
  const Bytes sps = makeSps(80, 45, 0), pps = makePps();
  auto reader = track.subscribe();
  const Bytes initial = annexb({sps, pps, makeSlice(true, 16)});
  track.push(initial.data(), initial.size(), true, 1000);
  bool ended = false;
  REQUIRE_FALSE(reader->pull(0, &ended).empty());
  REQUIRE_FALSE(reader->pull(0, &ended).empty());

  const Bytes bad_pps = {0x68, 0xc0};
  const Bytes unsafe_delta = annexb({bad_pps, makeSlice(false, 16)});
  track.push(unsafe_delta.data(), unsafe_delta.size(), false, 1040);
  CHECK(reader->pull(0, &ended).empty());
  CHECK_FALSE(ended);

  CHECK(track.takeKeyframeRequest());
  auto late = track.subscribe();
  REQUIRE_FALSE(late->pull(0, &ended).empty());
  CHECK(late->pull(0, &ended).empty());
  const Bytes delta = annexb({makeSlice(false, 16)});
  for (int i = 0; i < 3; ++i) {
    track.push(delta.data(), delta.size(), false, 1050 + i * 10);
    CHECK(reader->pull(0, &ended).empty());
    CHECK(late->pull(0, &ended).empty());
    CHECK_FALSE(track.takeKeyframeRequest());
  }
  CHECK(track.stats().frames == 1);
  const Bytes recovery = annexb({makeSlice(true, 16)});
  track.push(recovery.data(), recovery.size(), true, 1080);
  CHECK_FALSE(reader->pull(0, &ended).empty());
  CHECK_FALSE(late->pull(0, &ended).empty());
  track.push(delta.data(), delta.size(), false, 1120);
  CHECK_FALSE(reader->pull(0, &ended).empty());
  CHECK_FALSE(late->pull(0, &ended).empty());
}

TEST_CASE("VideoTrack rejected parameter-only updates do not break a reference chain") {
  VideoTrack track;
  track.setEnabled(true);
  auto reader = track.subscribe();
  const Bytes initial = annexb({makeSps(80, 45, 0), makePps(), makeSlice(true, 16)});
  track.push(initial.data(), initial.size(), true, 1000);
  bool ended = false;
  REQUIRE_FALSE(reader->pull(0, &ended).empty());
  REQUIRE_FALSE(reader->pull(0, &ended).empty());
  const Bytes invalid = annexb({{0x68, 0x00}});
  track.push(invalid.data(), invalid.size(), false, 1040);
  const Bytes delta = annexb({makeSlice(false, 16)});
  track.push(delta.data(), delta.size(), false, 1080);
  CHECK_FALSE(reader->pull(0, &ended).empty());
  CHECK_FALSE(track.takeKeyframeRequest());
}

TEST_CASE("[M05] VideoTrack does not reset for an identical valid configuration") {
  VideoTrack track;
  track.setEnabled(true);
  const Bytes sps = makeSps(80, 45, 0), pps = makePps();
  const Bytes initial = annexb({sps, pps, makeSlice(true, 16)});
  auto reader = track.subscribe();
  track.push(initial.data(), initial.size(), true, 1000);
  bool ended = false;
  REQUIRE_FALSE(reader->pull(0, &ended).empty());
  REQUIRE_FALSE(reader->pull(0, &ended).empty());

  track.push(initial.data(), initial.size(), true, 1040);
  CHECK_FALSE(reader->pull(0, &ended).empty());
  CHECK_FALSE(ended);
  CHECK(track.active());
}

TEST_CASE("[M05] H.264 parameter and slice association rejects a mismatched PPS") {
  const Bytes sps = makeSps(80, 45, 0);
  const Bytes pps = makePps(1, 0);
  CHECK(fmp4::validParameterSets(sps, pps));
  Bytes idr = annexb({makeSlice(true, 16, 0)});
  CHECK_FALSE(fmp4::idrReferencesPps(idr.data(), idr.size(), sps, pps));
  idr = annexb({makeSlice(true, 16, 1)});
  CHECK(fmp4::idrReferencesPps(idr.data(), idr.size(), sps, pps));
}

TEST_CASE("[F04] H.264 parameter validation rejects truncated PPS syntax and forbidden headers") {
  const Bytes sps = makeSps(80, 45, 0);
  const Bytes truncated_after_ids = {0x68, 0xc0};
  const Bytes forbidden_header = {0xe8, 0xce, 0x3c, 0x80};
  const Bytes truncated_fields = {0x68, 0xce, 0x3c};
  const Bytes valid_pps = makePps();

  CHECK(fmp4::validParameterSets(sps, valid_pps));
  CHECK_FALSE(fmp4::validParameterSets(sps, truncated_after_ids));
  CHECK_FALSE(fmp4::validParameterSets(sps, forbidden_header));
  CHECK_FALSE(fmp4::validParameterSets(sps, truncated_fields));
}

TEST_CASE("[F05] IDR recovery requires every VCL slice to be a consistent legal IDR") {
  const Bytes configured_pps = makePps(0, 0);
  const Bytes other_pps = makePps(1, 0);
  const Bytes legal = annexb({makeSlice(true, 16, 0)});
  const Bytes illegal_slice_type = annexb({makeSlice(true, 16, 0, 10)});
  const Bytes truncated_header = annexb({makeSlice(true, 0, 0)});
  const Bytes configured_then_other = annexb(
      {makeSlice(true, 16, 0), makeSlice(true, 16, 1)});
  const Bytes other_then_configured = annexb(
      {makeSlice(true, 16, 1), makeSlice(true, 16, 0)});

  const Bytes sps = makeSps(80, 45, 0);
  CHECK(fmp4::idrReferencesPps(legal.data(), legal.size(), sps, configured_pps));
  CHECK_FALSE(fmp4::idrReferencesPps(illegal_slice_type.data(), illegal_slice_type.size(),
                                     sps, configured_pps));
  CHECK_FALSE(fmp4::idrReferencesPps(truncated_header.data(), truncated_header.size(),
                                     sps, configured_pps));
  CHECK_FALSE(fmp4::idrReferencesPps(configured_then_other.data(),
                                     configured_then_other.size(), sps, configured_pps));
  CHECK_FALSE(fmp4::idrReferencesPps(other_then_configured.data(),
                                     other_then_configured.size(), sps, configured_pps));
}

TEST_CASE("[F05] VideoTrack keeps the recovery barrier after a mixed-PPS IDR access unit") {
  VideoTrack track;
  track.setEnabled(true);
  const Bytes sps = makeSps(80, 45, 0), pps = makePps();
  const Bytes initial = annexb({sps, pps, makeSlice(true, 16)});
  track.push(initial.data(), initial.size(), true, 1000);
  auto reader = track.subscribe();
  bool ended = false;
  const Bytes old_init = reader->pull(0, &ended);
  REQUIRE_FALSE(old_init.empty());
  REQUIRE_FALSE(reader->pull(0, &ended).empty());

  const Bytes updated_pps = makePps(0, 0, true);
  const Bytes mixed_recovery = annexb(
      {updated_pps, makeSlice(true, 16, 0), makeSlice(true, 16, 1)});
  track.push(mixed_recovery.data(), mixed_recovery.size(), true, 1040);
  CHECK(reader->pull(0, &ended).empty());
  CHECK_FALSE(ended);
  CHECK(track.takeKeyframeRequest());

  const Bytes delta = annexb({makeSlice(false, 16)});
  track.push(delta.data(), delta.size(), false, 1080);
  CHECK(reader->pull(0, &ended).empty());
  CHECK_FALSE(track.takeKeyframeRequest());

  const Bytes valid_recovery = annexb({makeSlice(true, 16, 0)});
  track.push(valid_recovery.data(), valid_recovery.size(), false, 1120);
  CHECK(reader->pull(0, &ended).empty());
  CHECK(ended);
  auto new_reader = track.subscribe();
  const Bytes new_init = new_reader->pull(0, &ended);
  REQUIRE_FALSE(new_init.empty());
  CHECK(new_init != old_init);
  CHECK_FALSE(new_reader->pull(0, &ended).empty());
  CHECK_FALSE(ended);
}

TEST_CASE("video_track: ignores pushes while the H.264 track is disabled") {
  VideoTrack track;
  Bytes sps = makeSps(80, 45, 0), pps = makePps();
  Bytes k = annexb({sps, pps, makeSlice(true, 16)});
  track.push(k.data(), k.size(), true, 0);
  CHECK(!track.active());
  CHECK(track.codecString() == "");
}



namespace {

int freePort(std::mt19937& /*rng*/) {
  // Ports come from one process-wide allocator; see core/tests/test_ports.h.
  return db::testing::freeListenPort();
}

int connectTo(int port, int rcv_timeout_ms) {
  int fd = ::socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return -1;
  sockaddr_in sa{};
  sa.sin_family = AF_INET;
  sa.sin_port = htons(static_cast<uint16_t>(port));
  sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (::connect(fd, reinterpret_cast<sockaddr*>(&sa), sizeof(sa)) != 0) {
    ::close(fd);
    return -1;
  }
  timeval tv{rcv_timeout_ms / 1000, (rcv_timeout_ms % 1000) * 1000};
  ::setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  return fd;
}

std::string httpGet(int port, const std::string& path, const std::string& bearer = "") {
  int fd = connectTo(port, 5000);
  REQUIRE(fd >= 0);
  std::string req = "GET " + path + " HTTP/1.1\r\nHost: 127.0.0.1\r\n";
  if (!bearer.empty()) req += "Authorization: Bearer " + bearer + "\r\n";
  req += "Connection: close\r\n\r\n";
  REQUIRE(::send(fd, req.data(), req.size(), 0) == static_cast<ssize_t>(req.size()));
  std::string resp;
  char buf[4096];
  for (;;) {
    ssize_t n = ::recv(fd, buf, sizeof(buf), 0);
    if (n <= 0) break;
    resp.append(buf, static_cast<size_t>(n));
  }
  ::close(fd);
  return resp;
}

bool hasMarker(const std::string& s, const char* fourcc) {
  return s.find(fourcc) != std::string::npos;
}

bool hasAlivePeer(Node& node, const std::string& peer_id) {
  auto status = json::parse(node.statusJson());
  if (!status) return false;
  cJSON* peer = nullptr;
  cJSON_ArrayForEach(peer, json::get(status.get(), "peers")) {
    if (json::getString(peer, "id") == peer_id &&
        json::getString(peer, "status") == "alive") return true;
  }
  return false;
}

template <typename Predicate>
bool waitFor(Predicate predicate, int timeout_ms) {
  for (int elapsed = 0; elapsed < timeout_ms; elapsed += 50) {
    if (predicate()) return true;
    usleep(50 * 1000);
  }
  return predicate();
}

}  // namespace

TEST_CASE("fmp4: Node serves encoded frames through GET /stream.mp4") {
  std::mt19937 rng(static_cast<uint32_t>(::getpid()) ^ 0x6d70u);
  int mesh_port = freePort(rng);
  int http_port = freePort(rng);
  REQUIRE(mesh_port > 0);
  REQUIRE(http_port > 0);

  NodeOptions o;
  o.data_dir = ":memory:";
  o.name = "h264cam";
  o.role = "door_station";
  o.door = "d_front";
  o.listen_addr = "127.0.0.1:" + std::to_string(mesh_port);
  o.psk.fill(0x5b);
  o.enable_beacon = false;
  o.http_port = http_port;
  Node node(o);
  node.setSecureStore(
      [](const std::string& key) { return key == "panel.test" ? "fmp4-panel-token" : ""; },
      [](const std::string&, const std::string&) { return true; });
  REQUIRE(node.start());
  node.setConfigKey("panel.token_refs", "[\"secret:panel.test\"]");


  node.setConfigKey("devices." + node.nodeId() + ".local.camera",
                    "{\"codec\":\"h264\",\"h264_resolution\":\"1280x720\",\"h264_fps\":25,"
                    "\"h264_bitrate_kbps\":1500}");
  node.setConfigKey("doors.d_front", "{\"label\":{\"ja\":\"正面玄関\"}}");


  CHECK(node.videoEncoderWanted());

  Bytes sps = makeSps(80, 45, 0), pps = makePps();
  Bytes key_au = annexb({sps, pps, makeSlice(true, 40)});


  int fd = connectTo(http_port, 200);
  REQUIRE(fd >= 0);
  std::string req = "GET /stream.mp4 HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
  REQUIRE(::send(fd, req.data(), req.size(), 0) == static_cast<ssize_t>(req.size()));

  std::string got;
  bool wanted_seen = false;
  char buf[8192];
  for (int i = 0; i < 200; i++) {
    if (node.videoEncoderWanted()) wanted_seen = true;

    node.pushEncodedFrame(key_au.data(), key_au.size(), true, 600 * (i + 1));
    ssize_t n = ::recv(fd, buf, sizeof(buf), 0);
    if (n > 0) got.append(buf, static_cast<size_t>(n));
    if (hasMarker(got, "moof") && hasMarker(got, "mdat")) break;
  }
  ::close(fd);

  CHECK(wanted_seen);
  REQUIRE(got.rfind("HTTP/1.1 200", 0) == 0);
  CHECK(got.find("Content-Type: video/mp4") != std::string::npos);
  CHECK(got.find("Access-Control-Allow-Origin: *") != std::string::npos);

  size_t body = got.find("\r\n\r\n");
  REQUIRE(body != std::string::npos);
  body += 4;
  REQUIRE(got.size() >= body + 8);
  CHECK(got.compare(body + 4, 4, "ftyp") == 0);
  CHECK(hasMarker(got, "moov"));
  CHECK(hasMarker(got, "moof"));
  CHECK(hasMarker(got, "mdat"));


  CHECK(node.videoEncoderWanted());


  {
    std::string st = node.statusJson();
    auto j = json::parse(st);
    REQUIRE(j);
    cJSON* video = json::get(j.get(), "video");
    REQUIRE(video);
    CHECK(json::getString(video, "codec") == "h264");
    CHECK(!json::getBool(video, "active", true));
    CHECK(st.find("stream_mp4") != std::string::npos);
  }


  {
    std::string state = httpGet(http_port, "/api/panel/state", "fmp4-panel-token");
    CHECK(state.find("\"stream_mp4\":") != std::string::npos);
    CHECK(state.find("/stream.mp4") != std::string::npos);
  }


  node.setConfigKey("devices." + node.nodeId() + ".local.camera", "{\"codec\":\"mjpeg\"}");
  CHECK(!node.videoEncoderWanted());
  std::string resp = httpGet(http_port, "/stream.mp4");
  CHECK(resp.rfind("HTTP/1.1 503", 0) == 0);

  node.stop();
}

TEST_CASE("fmp4: authenticated same-origin proxy streams from an alive mesh peer") {
  // The station intentionally uses a non-default HTTP port; the reserved default prevents
  // the random port helper from accidentally making this a compatibility-only test.
  std::mt19937 rng(static_cast<uint32_t>(::getpid()) ^ 0x51a9u);
  std::vector<int> reserved{47180};
  auto distinctPort = [&] {
    for (;;) {
      const int port = freePort(rng);
      if (port <= 0) return port;
      if (std::find(reserved.begin(), reserved.end(), port) == reserved.end()) {
        reserved.push_back(port);
        return port;
      }
    }
  };
  const int door_mesh_port = distinctPort();
  const int door_http_port = distinctPort();
  const int panel_mesh_port = distinctPort();
  const int panel_http_port = distinctPort();
  REQUIRE(door_mesh_port > 0);
  REQUIRE(door_http_port > 0);
  REQUIRE(panel_mesh_port > 0);
  REQUIRE(panel_http_port > 0);

  std::array<uint8_t, 32> psk{};
  psk.fill(0x6d);
  NodeOptions door_options;
  door_options.data_dir = ":memory:";
  door_options.name = "proxy-door";
  door_options.role = "door_station";
  door_options.door = "d_proxy";
  door_options.listen_addr = "127.0.0.1:" + std::to_string(door_mesh_port);
  door_options.advertise_addr = door_options.listen_addr;
  door_options.psk = psk;
  door_options.enable_beacon = false;
  door_options.http_port = door_http_port;
  door_options.seed_default_config = true;

  NodeOptions panel_options;
  panel_options.data_dir = ":memory:";
  panel_options.name = "proxy-panel";
  panel_options.role = "indoor_panel";
  panel_options.listen_addr = "127.0.0.1:" + std::to_string(panel_mesh_port);
  panel_options.advertise_addr = panel_options.listen_addr;
  panel_options.seed_peers = {door_options.listen_addr};
  panel_options.psk = psk;
  panel_options.enable_beacon = false;
  panel_options.http_port = panel_http_port;
  panel_options.seed_default_config = false;

  Node door(door_options);
  Node panel(panel_options);
  panel.setSecureStore(
      [](const std::string& key) { return key == "panel.proxy" ? "proxy-contract-token" : ""; },
      [](const std::string&, const std::string&) { return true; });
  REQUIRE(door.start());
  REQUIRE(panel.start());
  REQUIRE(waitFor([&] {
    return hasAlivePeer(panel, door.nodeId()) && hasAlivePeer(door, panel.nodeId());
  }, 8'000));

  const std::string camera =
      R"({"codec":"h264","h264_resolution":"640x360","h264_fps":15,"h264_bitrate_kbps":600})";
  door.setConfigKey("devices." + door.nodeId() + ".local.camera", camera);
  REQUIRE(waitFor([&] {
    auto status = json::parse(door.statusJson());
    return status && json::getString(json::get(status.get(), "video"), "codec") == "h264";
  }, 2'000));
  panel.setConfigKey("devices." + door.nodeId(),
                     R"({"role":"door_station","door":"d_proxy","local":{"camera":{"codec":"h264"}}})");
  panel.setConfigKey("doors.d_proxy", R"({"label":{"en":"Proxy door"}})");
  panel.setConfigKey("panel.token_refs", R"(["secret:panel.proxy"])");

  REQUIRE(waitFor([&] {
    const std::string info = httpGet(panel_http_port,
        "/api/panel/call-info", "proxy-contract-token");
    return info.find("http://127.0.0.1:" + std::to_string(door_http_port)) !=
           std::string::npos;
  }, 3'000));
  std::vector<uint8_t> snapshot_pixels(64 * 48 * 4, 0xff);
  for (size_t i = 0; i < snapshot_pixels.size(); i += 4) {
    snapshot_pixels[i] = 40;
    snapshot_pixels[i + 1] = 80;
    snapshot_pixels[i + 2] = 220;
  }
  door.pushCameraFrame(snapshot_pixels.data(), 3, 64, 48, 64 * 4, 1000);
  std::string snapshot;
  REQUIRE(waitFor([&] {
    snapshot = httpGet(panel_http_port, "/snapshot-proxy?door=d_proxy",
                       "proxy-contract-token");
    return snapshot.rfind("HTTP/1.1 200", 0) == 0;
  }, 3'000));
  CHECK(snapshot.rfind("HTTP/1.1 200", 0) == 0);
  CHECK(snapshot.find("Content-Type: image/jpeg") != std::string::npos);
  CHECK(snapshot.find("\xFF\xD8\xFF") != std::string::npos);
  CHECK(snapshot.find("Location:") == std::string::npos);
  CHECK(snapshot.find("Access-Control-Allow-Origin") == std::string::npos);
  for (size_t i = 0; i < snapshot_pixels.size(); i += 4) {
    snapshot_pixels[i] = 220;
    snapshot_pixels[i + 1] = 35;
    snapshot_pixels[i + 2] = 60;
  }
  door.pushCameraFrame(snapshot_pixels.data(), 3, 64, 48, 64 * 4, 2000);
  const size_t first_body = snapshot.find("\r\n\r\n");
  REQUIRE(first_body != std::string::npos);
  const std::string first_jpeg = snapshot.substr(first_body + 4);
  std::string next_snapshot;
  REQUIRE(waitFor([&] {
    next_snapshot = httpGet(panel_http_port,
        "/snapshot-proxy?door=d_proxy&live=1", "proxy-contract-token");
    const size_t body = next_snapshot.find("\r\n\r\n");
    return next_snapshot.rfind("HTTP/1.1 200", 0) == 0 && body != std::string::npos &&
           next_snapshot.substr(body + 4) != first_jpeg;
  }, 3'000));

  const std::string denied =
      httpGet(panel_http_port, "/stream-proxy.mp4?door=d_proxy", "wrong");
  REQUIRE(denied.rfind("HTTP/1.1 403", 0) == 0);

  int fd = connectTo(panel_http_port, 200);
  REQUIRE(fd >= 0);
  const std::string request =
      "GET /stream-proxy.mp4?door=d_proxy HTTP/1.1\r\n"
      "Host: 127.0.0.1\r\nAuthorization: Bearer proxy-contract-token\r\n"
      "Connection: close\r\n\r\n";
  REQUIRE(::send(fd, request.data(), request.size(), 0) ==
          static_cast<ssize_t>(request.size()));

  const Bytes key_au = annexb({makeSps(40, 23, 4), makePps(), makeSlice(true, 48)});
  std::string response;
  char buf[8192];
  for (int i = 0; i < 100; i++) {
    door.pushEncodedFrame(key_au.data(), key_au.size(), true, 600 * (i + 1));
    const ssize_t n = ::recv(fd, buf, sizeof(buf), 0);
    if (n > 0) response.append(buf, static_cast<size_t>(n));
    if (hasMarker(response, "moof") && hasMarker(response, "mdat")) break;
  }
  ::close(fd);

  REQUIRE(response.rfind("HTTP/1.1 200", 0) == 0);
  CHECK(response.rfind("HTTP/1.1 503", 0) != 0);
  CHECK(response.find("Content-Type: video/mp4") != std::string::npos);
  CHECK(response.find("\r\nLocation:") == std::string::npos);
  CHECK(response.find("Access-Control-Allow-Origin") == std::string::npos);
  CHECK(response.find("http://127.0.0.1:47180") == std::string::npos);
  CHECK(hasMarker(response, "ftyp"));
  CHECK(hasMarker(response, "moov"));
  CHECK(hasMarker(response, "moof"));
  CHECK(hasMarker(response, "mdat"));

  panel.setConfigKey("devices.duplicate-station",
                     R"({"role":"door_station","door":"d_proxy"})");
  CHECK(waitFor([&] {
    return httpGet(panel_http_port, "/snapshot-proxy?door=d_proxy",
                   "proxy-contract-token").rfind("HTTP/1.1 409", 0) == 0;
  }, 3'000));
  CHECK(httpGet(panel_http_port, "/stream-proxy.mp4?door=d_proxy",
                "proxy-contract-token").rfind("HTTP/1.1 409", 0) == 0);

  panel.stop();
  door.stop();
}

TEST_CASE("fmp4: validates parsing with ffprobe when available") {
  if (std::system("which ffprobe >/dev/null 2>&1") != 0) {
    MESSAGE("ffprobe is unavailable; skipping external validation");
    return;
  }
  Bytes sps = makeSps(80, 45, 0), pps = makePps();
  Bytes init = fmp4::buildInit(sps, pps);
  Bytes got_sps, got_pps;
  Bytes au = annexb({makeSlice(true, 400)});
  std::vector<fmp4::Sample> samples;
  samples.push_back(fmp4::toSample(au.data(), au.size(), &got_sps, &got_pps));
  samples[0].dur = 40;
  Bytes frag = fmp4::buildFragment(1, 0, samples);

  std::string path = "/tmp/doorbell_fmp4_test_" + std::to_string(::getpid()) + ".mp4";
  FILE* f = std::fopen(path.c_str(), "wb");
  REQUIRE(f);
  std::fwrite(init.data(), 1, init.size(), f);
  std::fwrite(frag.data(), 1, frag.size(), f);
  std::fclose(f);


  std::string cmd = "ffprobe -v error -show_streams -show_format " + path + " 2>/dev/null";
  FILE* pipe = ::popen(cmd.c_str(), "r");
  REQUIRE(pipe);
  std::string out;
  char buf[512];
  while (std::fgets(buf, sizeof(buf), pipe)) out += buf;
  int rc = ::pclose(pipe);
  std::remove(path.c_str());
  CHECK(rc == 0);
  CHECK(out.find("codec_name=h264") != std::string::npos);
  CHECK(out.find("width=1280") != std::string::npos);
  CHECK(out.find("height=720") != std::string::npos);
}
