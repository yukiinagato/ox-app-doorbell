// fMP4 (fragmented MP4) マキサ — 依存なしの純関数群 (Phase 6a)。
//   入力: 平台 HW エンコーダが吐く H.264 AnnexB (start code 区切り)。
//   出力: MSE / go2rtc / ffmpeg がそのまま食える init segment (ftyp+moov) と
//         media fragment (moof+mdat)。timescale は 1000 固定 (ms 直結)。
// コアは絶対に自前でエンコードしない (旧機保護) — 箱詰めだけを行う。
// 仕様参照: ISO/IEC 14496-12 (ISOBMFF) / 14496-15 (avcC)。
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "util/common.h"

namespace db {
namespace fmp4 {

// AnnexB バイト列の NAL 境界 (コピーなし — p は入力を指す)。
// type = nal_unit_type (先頭バイト下位 5bit)。start code は 3/4 バイト両対応。
struct NalView {
  const uint8_t* p = nullptr;  // NAL ヘッダバイトの先頭 (start code は含まない)
  size_t n = 0;
  int type = 0;
};
std::vector<NalView> splitAnnexB(const uint8_t* data, size_t len);

// SPS (NAL ヘッダ込み・エスケープ付き) から解像度を取り出す。失敗時 false。
// frame cropping / high profile (chroma_format_idc・scaling list) 対応。
bool parseSpsDims(const uint8_t* sps, size_t len, int* w, int* h);

// SPS から RFC 6381 コーデック文字列 ("avc1.42C01F" 等)。SPS 不足なら ""。
std::string codecString(const Bytes& sps);

// 1 サンプル (= 1 アクセスユニットの AVCC 変換済みデータ)
struct Sample {
  Bytes data;        // 4 バイト BE 長前置の NAL 列 (SPS/PPS/AUD/SEI は除外済み)
  bool key = false;  // IDR を含む
  int64_t ts_ms = 0; // エンコーダ付与の提示時刻 (フラグメント確定時に dur へ変換)
  uint32_t dur = 0;  // ms。buildFragment 呼び出し時には確定していること
};

// AnnexB アクセスユニット → Sample。SPS/PPS は *sps/*pps へ抽出して本体から除外
// (中身が変わった時だけ上書き)。AUD(9)/SEI(6) も除外。VCL が無ければ data は空。
Sample toSample(const uint8_t* annexb, size_t len, Bytes* sps, Bytes* pps);

// init segment (ftyp + moov)。track_id=1、timescale=1000。
// 解像度は sps から parse する (失敗時は 0x0 のまま箱詰め — 再生側は avcC を見る)。
Bytes buildInit(const Bytes& sps, const Bytes& pps);

// media fragment (moof + mdat)。seq: 1 始まりの通し番号 (mfhd)。
// base_dt: base media decode time (ms) — フラグメント間で連続していること (tfdt)。
Bytes buildFragment(uint32_t seq, uint64_t base_dt, const std::vector<Sample>& samples);

}  // namespace fmp4
}  // namespace db
