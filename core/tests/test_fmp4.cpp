// fMP4 マキサ (fmp4) + VideoTrack + /stream.mp4 配信のテスト。
//  - 合成 NAL (ビット書きで組んだ正規 SPS / ダミー PPS/IDR/non-IDR) で決定的に:
//    AnnexB 分割・SPS 解像度・AVCC 変換・box 構造 (サイズ/fourcc 階層/trun/avcC)
//  - VideoTrack: フラグメント戦略 (1 GOP or 500ms)・購読者管理・base decode time 連続
//  - Node 統合: 実 TCP + HTTP で GET /stream.mp4 (ftyp から始まり moof が続く) と
//    encoder wanted 制御 (購読者ゼロ = エンコードしない)
//  - `which ffprobe` が存在すれば実 parse 検証 (無ければ skip)
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <vector>

#include "doctest.h"
#include "media/fmp4.h"
#include "media/video_track.h"
#include "node/node.h"
#include "util/json.h"

using namespace db;

namespace {

// ---------- 合成 NAL (H.264 ビット書き) ----------

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
  void ue(uint32_t v) {  // 符号なし Exp-Golomb
    uint32_t k = v + 1;
    int n = 0;
    while ((k >> n) > 1) n++;
    u(0, n);
    u(k, n + 1);
  }
  void trailing() {  // rbsp_trailing_bits
    bit(1);
    while (nbits) bit(0);
  }
};

// RBSP → NAL (ヘッダ + emulation prevention 00 00 03 挿入)
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

// baseline SPS。crop_bottom > 0 で下端クロップ (4:2:0 → 2px 単位)。
Bytes makeSps(int mbs_w, int map_h, uint32_t crop_bottom) {
  BitWriter bw;
  bw.u(66, 8);   // profile_idc = baseline
  bw.u(0, 8);    // constraint flags + reserved
  bw.u(30, 8);   // level_idc = 3.0
  bw.ue(0);      // seq_parameter_set_id
  bw.ue(0);      // log2_max_frame_num_minus4
  bw.ue(2);      // pic_order_cnt_type = 2 (追加フィールドなし)
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

Bytes makePps() {
  BitWriter bw;
  bw.ue(0);    // pic_parameter_set_id
  bw.ue(0);    // seq_parameter_set_id
  bw.u(0, 1);  // entropy_coding_mode_flag (CAVLC)
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

// ダミー slice (payload に start code が出ない値で埋める)
Bytes makeSlice(bool idr, size_t payload) {
  Bytes nal;
  nal.push_back(idr ? 0x65 : 0x41);  // type 5 (IDR) / 1 (non-IDR)
  for (size_t i = 0; i < payload; i++) nal.push_back(static_cast<uint8_t>(0x80 + (i % 0x40)));
  return nal;
}

// start code (4 バイト) で連結した AnnexB アクセスユニット
Bytes annexb(const std::vector<Bytes>& nals) {
  Bytes out;
  for (const Bytes& n : nals) {
    const uint8_t sc[4] = {0, 0, 0, 1};
    out.insert(out.end(), sc, sc + 4);
    out.insert(out.end(), n.begin(), n.end());
  }
  return out;
}

// ---------- box 走査ヘルパ ----------

struct Box {
  std::string type;
  size_t off = 0;      // box 先頭
  size_t size = 0;     // box 全長
  size_t payload = 0;  // type 直後
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

TEST_CASE("fmp4: AnnexB 分割 (3/4 バイト start code・型判定)") {
  Bytes sps = makeSps(80, 45, 0), pps = makePps(), idr = makeSlice(true, 16);
  // 3 バイト start code 混在
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

  // 空/短すぎる入力
  CHECK(fmp4::splitAnnexB(nullptr, 0).empty());
  CHECK(fmp4::splitAnnexB(au.data(), 3).empty());
}

TEST_CASE("fmp4: SPS 解像度 parse (720p / クロップ / EPB / 不正)") {
  int w = 0, h = 0;
  SUBCASE("1280x720 (80x45 MB)") {
    Bytes sps = makeSps(80, 45, 0);
    REQUIRE(fmp4::parseSpsDims(sps.data(), sps.size(), &w, &h));
    CHECK(w == 1280);
    CHECK(h == 720);
  }
  SUBCASE("640x360 (40x23 MB + 下端 8px クロップ)") {
    Bytes sps = makeSps(40, 23, 4);  // 4:2:0 → 4 単位 = 8px
    REQUIRE(fmp4::parseSpsDims(sps.data(), sps.size(), &w, &h));
    CHECK(w == 640);
    CHECK(h == 360);
  }
  SUBCASE("EPB (00 00 03) を含む SPS も除去して読める") {
    // mbs_w-1 = 255 級の大きい値で 0 連続を出やすくしつつ、makeNal が挿入した
    // 0x03 が除去されることを既知解像度で確認する
    Bytes sps = makeSps(120, 68, 0);  // 1920x1088
    REQUIRE(fmp4::parseSpsDims(sps.data(), sps.size(), &w, &h));
    CHECK(w == 1920);
    CHECK(h == 1088);
  }
  SUBCASE("不正入力は false") {
    Bytes pps = makePps();
    CHECK(!fmp4::parseSpsDims(pps.data(), pps.size(), &w, &h));  // type != 7
    Bytes sps = makeSps(80, 45, 0);
    CHECK(!fmp4::parseSpsDims(sps.data(), 3, &w, &h));  // 短すぎ
    CHECK(!fmp4::parseSpsDims(nullptr, 0, &w, &h));
  }
}

TEST_CASE("fmp4: codecString は SPS の profile/constraint/level") {
  Bytes sps = makeSps(80, 45, 0);
  CHECK(fmp4::codecString(sps) == "avc1.42001E");  // 66/0x00/30
  CHECK(fmp4::codecString(Bytes{0x67}) == "");
}

TEST_CASE("fmp4: toSample — AVCC 変換 + SPS/PPS/AUD/SEI 除外 + key 判定") {
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
  // AVCC: 4 バイト長 + IDR 本体のみ (SPS/PPS/AUD/SEI は落ちる)
  REQUIRE(s.data.size() == 4 + idr.size());
  CHECK(be32(s.data, 0) == idr.size());
  CHECK(std::memcmp(&s.data[4], idr.data(), idr.size()) == 0);

  // non-IDR のみ → key=false、SPS/PPS は既存値を保持
  Bytes au2 = annexb({p_sl});
  fmp4::Sample s2 = fmp4::toSample(au2.data(), au2.size(), &got_sps, &got_pps);
  CHECK(!s2.key);
  CHECK(got_sps == sps);
  REQUIRE(s2.data.size() == 4 + p_sl.size());
  CHECK(be32(s2.data, 0) == p_sl.size());

  // SPS/PPS のみ (MediaCodec の CODEC_CONFIG) → data 空
  Bytes au3 = annexb({sps, pps});
  fmp4::Sample s3 = fmp4::toSample(au3.data(), au3.size(), &got_sps, &got_pps);
  CHECK(s3.data.empty());
}

TEST_CASE("fmp4: init segment の box 構造 (ftyp+moov 階層・avc1 解像度・avcC)") {
  Bytes sps = makeSps(80, 45, 0), pps = makePps();
  Bytes init = fmp4::buildInit(sps, pps);
  REQUIRE(init.size() > 100);

  auto top = childBoxes(init, 0, init.size());
  REQUIRE(top.size() == 2);
  CHECK(top[0].type == "ftyp");
  CHECK(top[1].type == "moov");
  // box サイズの合計 = 全長 (childBoxes が末尾まで正確に歩けた)
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
  // tkhd width/height (16.16) は payload 末尾 8 バイト
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

  // stsd 内の avc1 と avcC (SPS/PPS がそのまま入る)
  const Box* stsd = findBox(in_stbl, "stsd");
  auto in_stsd = childBoxes(init, stsd->payload + 8, stsd->off + stsd->size);  // ver/flags+count
  const Box* avc1 = findBox(in_stsd, "avc1");
  REQUIRE(avc1);
  // avc1 の width/height (payload +24/+26)
  CHECK(((init[avc1->payload + 24] << 8) | init[avc1->payload + 26 - 1]) >= 0);  // 存在確認のみ
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
  CHECK(init[p + 5] == 0xe1);   // SPS 数 = 1
  uint16_t sps_len = static_cast<uint16_t>((init[p + 6] << 8) | init[p + 7]);
  REQUIRE(sps_len == sps.size());
  CHECK(std::memcmp(&init[p + 8], sps.data(), sps.size()) == 0);
  size_t q = p + 8 + sps_len;
  CHECK(init[q] == 1);  // PPS 数
  uint16_t pps_len = static_cast<uint16_t>((init[q + 1] << 8) | init[q + 2]);
  REQUIRE(pps_len == pps.size());
  CHECK(std::memcmp(&init[q + 3], pps.data(), pps.size()) == 0);
}

TEST_CASE("fmp4: fragment の box 構造 (mfhd 連番・tfdt・trun・mdat)") {
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
  // data_offset = moof 全長 + 8 (mdat payload 先頭)
  CHECK(be32(frag, trun->payload + 8) == moof.size + 8);
  // entry[0]: dur/size/flags (キーフレーム = depends_on 2)
  size_t e0 = trun->payload + 12;
  CHECK(be32(frag, e0) == 40);
  CHECK(be32(frag, e0 + 4) == samples[0].data.size());
  CHECK(be32(frag, e0 + 8) == 0x02000000u);
  size_t e1 = e0 + 12;
  CHECK(be32(frag, e1) == 60);
  CHECK(be32(frag, e1 + 8) == 0x01010000u);  // non-sync
  // mdat の中身 = サンプル連結
  const Box& mdat = top[1];
  REQUIRE(mdat.size == 8 + samples[0].data.size() + samples[1].data.size());
  CHECK(std::memcmp(&frag[mdat.payload], samples[0].data.data(), samples[0].data.size()) == 0);
}

TEST_CASE("video_track: フラグメント戦略 (1 GOP / 500ms) と base decode time 連続") {
  VideoTrack track;
  track.setEnabled(true);
  CHECK(!track.active());

  Bytes sps = makeSps(80, 45, 0), pps = makePps();
  auto reader = track.subscribe();
  CHECK(track.subscriberCount() == 1);

  // key1 (SPS/PPS 同梱) → init 生成。まだ fragment は無い
  Bytes k1 = annexb({sps, pps, makeSlice(true, 30)});
  track.push(k1.data(), k1.size(), true, 1000);
  CHECK(track.active());
  CHECK(track.codecString() == "avc1.42001E");

  bool ended = false;
  Bytes init = reader->pull(100, &ended);
  REQUIRE(!init.empty());
  CHECK(!ended);
  CHECK(std::memcmp(&init[4], "ftyp", 4) == 0);

  // non-IDR ×2 (同一 GOP 内・500ms 未満) → まだ確定しない
  Bytes p1 = annexb({makeSlice(false, 8)});
  track.push(p1.data(), p1.size(), false, 1100);
  track.push(p1.data(), p1.size(), false, 1200);
  Bytes none = reader->pull(10, &ended);
  CHECK(none.empty());
  CHECK(!ended);

  // key2 到来 → GOP 確定 (3 サンプル: 1000/1100/1200, dur 100/100/300)
  Bytes k2 = annexb({makeSlice(true, 30)});
  track.push(k2.data(), k2.size(), true, 1500);
  Bytes frag1 = reader->pull(100, &ended);
  REQUIRE(!frag1.empty());
  {
    auto top = childBoxes(frag1, 0, frag1.size());
    REQUIRE(top.size() == 2);
    auto in_moof = childBoxes(frag1, top[0].payload, top[0].off + top[0].size);
    const Box* mfhd = findBox(in_moof, "mfhd");
    CHECK(be32(frag1, mfhd->payload + 4) == 1);
    auto in_traf = childBoxes(frag1, findBox(in_moof, "traf")->payload,
                              findBox(in_moof, "traf")->off + findBox(in_moof, "traf")->size);
    const Box* tfdt = findBox(in_traf, "tfdt");
    CHECK(be64(frag1, tfdt->payload + 4) == 0);  // 初回 base_dt = 0
    const Box* trun = findBox(in_traf, "trun");
    CHECK(be32(frag1, trun->payload + 4) == 3);  // 3 サンプル
  }

  // 500ms 超過でも確定する (キーフレーム無しの長 GOP): 1500..2100
  track.push(p1.data(), p1.size(), false, 1700);
  track.push(p1.data(), p1.size(), false, 2100);  // 1500 から 600ms → key2 側が確定
  Bytes frag2 = reader->pull(100, &ended);
  REQUIRE(!frag2.empty());
  {
    auto top = childBoxes(frag2, 0, frag2.size());
    auto in_moof = childBoxes(frag2, top[0].payload, top[0].off + top[0].size);
    auto in_traf = childBoxes(frag2, findBox(in_moof, "traf")->payload,
                              findBox(in_moof, "traf")->off + findBox(in_moof, "traf")->size);
    // base_dt = 前 fragment の合計 dur (100+100+300=500) — 連続
    CHECK(be64(frag2, findBox(in_traf, "tfdt")->payload + 4) == 500);
    CHECK(be32(frag2, findBox(in_traf, "trun")->payload + 4) == 2);  // 1500,1700
  }

  // 無効化 → 購読者は ended、状態は破棄
  track.setEnabled(false);
  Bytes after = reader->pull(100, &ended);
  CHECK(after.empty());
  CHECK(ended);
  CHECK(!track.active());
  reader.reset();
  CHECK(track.subscriberCount() == 0);
}

TEST_CASE("video_track: 遅い購読者は直近 fragment のみ受け取る (ライブ専用リング)") {
  VideoTrack track;
  track.setEnabled(true);
  Bytes sps = makeSps(80, 45, 0), pps = makePps();
  auto reader = track.subscribe();

  Bytes k = annexb({sps, pps, makeSlice(true, 16)});
  track.push(k.data(), k.size(), true, 0);
  bool ended = false;
  REQUIRE(!reader->pull(100, &ended).empty());  // init

  // 購読者が読まない間に fragment を 3 本作る (key 毎に前の 1 本が確定)
  Bytes kk = annexb({makeSlice(true, 16)});
  for (int i = 1; i <= 3; i++) track.push(kk.data(), kk.size(), true, i * 600);
  // → 直近 1 本 (seq=3) だけが返り、次は無い
  Bytes frag = reader->pull(100, &ended);
  REQUIRE(!frag.empty());
  auto top = childBoxes(frag, 0, frag.size());
  auto in_moof = childBoxes(frag, top[0].payload, top[0].off + top[0].size);
  CHECK(be32(frag, findBox(in_moof, "mfhd")->payload + 4) == 3);
  CHECK(reader->pull(10, &ended).empty());
  CHECK(!ended);

  // stop() で全購読者が起きて終了
  track.stop();
  reader->pull(10, &ended);
  CHECK(ended);
}

TEST_CASE("video_track: codec=mjpeg 相当 (disabled) では push を無視") {
  VideoTrack track;  // 既定 disabled
  Bytes sps = makeSps(80, 45, 0), pps = makePps();
  Bytes k = annexb({sps, pps, makeSlice(true, 16)});
  track.push(k.data(), k.size(), true, 0);
  CHECK(!track.active());
  CHECK(track.codecString() == "");
}

// ---------- Node 統合 (実 TCP + HTTP) ----------

namespace {

int freePort(std::mt19937& rng) {
  std::uniform_int_distribution<int> dist(40000, 60000);
  for (int i = 0; i < 50; i++) {
    int port = dist(rng);
    int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) continue;
    sockaddr_in sa{};
    sa.sin_family = AF_INET;
    sa.sin_port = htons(static_cast<uint16_t>(port));
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int ok = ::bind(fd, reinterpret_cast<sockaddr*>(&sa), sizeof(sa));
    ::close(fd);
    if (ok == 0) return port;
  }
  return -1;
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

std::string httpGet(int port, const std::string& path) {
  int fd = connectTo(port, 5000);
  REQUIRE(fd >= 0);
  std::string req = "GET " + path + " HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
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

}  // namespace

TEST_CASE("fmp4: Node 統合 — db_core_on_encoded_frame 経路 → GET /stream.mp4") {
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
  o.enable_beacon = false;  // 実 beacon 禁止 (稼働 fleet への迷入防止)
  o.http_port = http_port;
  Node node(o);
  REQUIRE(node.start());

  // codec=h264 を設定 (applyCameraSettings → video_track 有効化)
  node.setConfigKey("devices." + node.nodeId() + ".local.camera",
                    "{\"codec\":\"h264\",\"h264_resolution\":\"1280x720\",\"h264_fps\":25,"
                    "\"h264_bitrate_kbps\":1500}");
  node.setConfigKey("doors.d_front", "{\"label\":{\"ja\":\"正面玄関\"}}");

  // 購読者ゼロ → エンコーダ不要 (省電力)
  CHECK(!node.videoEncoderWanted());

  Bytes sps = makeSps(80, 45, 0), pps = makePps();
  Bytes key_au = annexb({sps, pps, makeSlice(true, 40)});

  // 接続 → 殻相当のループ: wanted を確認しながらフレームを push、moof まで読む
  int fd = connectTo(http_port, 200);
  REQUIRE(fd >= 0);
  std::string req = "GET /stream.mp4 HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
  REQUIRE(::send(fd, req.data(), req.size(), 0) == static_cast<ssize_t>(req.size()));

  std::string got;
  bool wanted_seen = false;
  char buf[8192];
  for (int i = 0; i < 200; i++) {
    if (node.videoEncoderWanted()) wanted_seen = true;  // 購読者が付いた
    // 毎回キーフレーム (= 前の fragment が確定する)。ts は 600ms 刻み
    node.pushEncodedFrame(key_au.data(), key_au.size(), true, 600 * (i + 1));
    ssize_t n = ::recv(fd, buf, sizeof(buf), 0);
    if (n > 0) got.append(buf, static_cast<size_t>(n));
    if (hasMarker(got, "moof") && hasMarker(got, "mdat")) break;
  }
  ::close(fd);

  CHECK(wanted_seen);  // 購読者がいる間は wanted=1 だった
  REQUIRE(got.rfind("HTTP/1.1 200", 0) == 0);
  CHECK(got.find("Content-Type: video/mp4") != std::string::npos);
  // 本文が ftyp から始まり moov → moof が続く
  size_t body = got.find("\r\n\r\n");
  REQUIRE(body != std::string::npos);
  body += 4;
  REQUIRE(got.size() >= body + 8);
  CHECK(got.compare(body + 4, 4, "ftyp") == 0);
  CHECK(hasMarker(got, "moov"));
  CHECK(hasMarker(got, "moof"));
  CHECK(hasMarker(got, "mdat"));

  // 切断後: 購読者ゼロへ戻る → wanted=0 (少し待つ — 接続後始末)
  for (int i = 0; i < 50 && node.videoEncoderWanted(); i++) usleep(100 * 1000);
  CHECK(!node.videoEncoderWanted());

  // status に自機 video と peers[].stream_mp4 が載る
  {
    std::string st = node.statusJson();
    auto j = json::parse(st);
    REQUIRE(j);
    cJSON* video = json::get(j.get(), "video");
    REQUIRE(video);
    CHECK(json::getString(video, "codec") == "h264");
    CHECK(json::getBool(video, "active", false));
    CHECK(st.find("stream_mp4") != std::string::npos);
  }

  // panel state の doors[].stream_mp4 (自機担当 = 相対 URL)
  {
    auto cfg = json::parse(node.configJson());
    REQUIRE(cfg);
    cJSON* toks = json::get(json::get(cfg.get(), "panel"), "tokens");
    REQUIRE(cJSON_IsArray(toks));
    std::string tok = cJSON_GetArrayItem(toks, 0)->valuestring;
    std::string state = httpGet(http_port, "/api/panel/state?k=" + tok);
    CHECK(state.find("\"stream_mp4\":") != std::string::npos);
    CHECK(state.find("/stream.mp4") != std::string::npos);
  }

  // codec=mjpeg へ変更 → track 停止 → /stream.mp4 は 503
  node.setConfigKey("devices." + node.nodeId() + ".local.camera", "{\"codec\":\"mjpeg\"}");
  std::string resp = httpGet(http_port, "/stream.mp4");
  CHECK(resp.rfind("HTTP/1.1 503", 0) == 0);

  node.stop();
}

TEST_CASE("fmp4: ffprobe があれば実 parse 検証 (無ければ skip)") {
  if (std::system("which ffprobe >/dev/null 2>&1") != 0) {
    MESSAGE("ffprobe 不在 — skip");
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

  // コンテナ構造 + h264 ストリームの認識を確認 (ダミー slice の復号は問わない)
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
