


#include "media/fmp4.h"

#include <algorithm>
#include <cstdio>
#include <cstring>

namespace db {
namespace fmp4 {

namespace {


struct BitReader {
  const uint8_t* p;
  size_t n;
  size_t pos = 0;
  bool bad = false;

  BitReader(const uint8_t* data, size_t len) : p(data), n(len) {}

  uint32_t u(int bits) {
    uint32_t v = 0;
    for (int i = 0; i < bits; i++) {
      if (pos >= n * 8) {
        bad = true;
        return 0;
      }
      v = (v << 1) | ((p[pos >> 3] >> (7 - (pos & 7))) & 1);
      pos++;
    }
    return v;
  }
  uint32_t ue() {
    int zeros = 0;
    while (!bad && u(1) == 0) {
      if (++zeros > 31) {
        bad = true;
        return 0;
      }
    }
    if (bad) return 0;
    const uint64_t value = ((uint64_t{1} << zeros) - 1) + u(zeros);
    if (bad || value > UINT32_MAX) {
      bad = true;
      return 0;
    }
    return static_cast<uint32_t>(value);
  }
  int32_t se() {
    uint32_t k = ue();
    const int64_t value = (k & 1) ? static_cast<int64_t>(k / 2) + 1
                                  : -static_cast<int64_t>(k / 2);
    if (bad || value < INT32_MIN || value > INT32_MAX) {
      bad = true;
      return 0;
    }
    return static_cast<int32_t>(value);
  }
  bool moreRbspData() const {
    if (bad || pos >= n * 8) return false;
    if (((p[pos >> 3] >> (7 - (pos & 7))) & 1) == 0) return true;
    for (size_t bit = pos + 1; bit < n * 8; bit++)
      if ((p[bit >> 3] >> (7 - (bit & 7))) & 1) return true;
    return false;
  }
  bool trailingBits() {
    if (u(1) != 1) return false;
    while (pos & 7) if (u(1) != 0) return false;
    return !bad && pos == n * 8;
  }
};


Bytes unescapeRbsp(const uint8_t* nal, size_t len) {
  Bytes out;
  if (len < 1) return out;
  out.reserve(len - 1);
  size_t zeros = 0;
  for (size_t i = 1; i < len; i++) {
    uint8_t b = nal[i];
    if (zeros >= 2 && b == 0x03) {
      zeros = 0;
      continue;
    }
    zeros = (b == 0) ? zeros + 1 : 0;
    out.push_back(b);
  }
  return out;
}

bool parseSpsId(const uint8_t* sps, size_t len, uint32_t* id) {
  if (!sps || len < 4 || (sps[0] & 0x1f) != 7) return false;
  Bytes rbsp = unescapeRbsp(sps, len);
  if (rbsp.size() < 4) return false;
  BitReader br(rbsp.data(), rbsp.size());
  br.u(8);  // profile_idc
  br.u(8);  // constraint flags + reserved
  br.u(8);  // level_idc
  const uint32_t parsed = br.ue();
  if (br.bad || parsed > 31) return false;
  *id = parsed;
  return true;
}

bool validEscapedNal(const uint8_t* nal, size_t len, size_t max_len = 65535) {
  if (!nal || len < 2 || len > max_len || (nal[0] & 0x80) != 0) return false;
  size_t zeros = 0;
  for (size_t i = 1; i < len; ++i) {
    const uint8_t byte = nal[i];
    if (zeros >= 2) {
      if (byte == 0x03) {
        if (i + 1 >= len || nal[i + 1] > 0x03) return false;
        zeros = 0;
        continue;
      }
      if (byte <= 0x02) return false;
    }
    zeros = byte == 0 ? zeros + 1 : 0;
  }
  return true;
}

void skipScalingList(BitReader& br, int size);

bool spsChromaFormat(const Bytes& sps, uint32_t* chroma_format) {
  if (!chroma_format || sps.size() < 4 || (sps[0] & 0x1f) != 7) return false;
  Bytes rbsp = unescapeRbsp(sps.data(), sps.size());
  BitReader br(rbsp.data(), rbsp.size());
  const uint32_t profile = br.u(8);
  br.u(8);
  br.u(8);
  br.ue();
  uint32_t chroma = 1;
  switch (profile) {
    case 100: case 110: case 122: case 244: case 44:
    case 83: case 86: case 118: case 128: case 138: case 139: case 134: case 135:
      chroma = br.ue();
      break;
    default:
      break;
  }
  if (br.bad || chroma > 3) return false;
  *chroma_format = chroma;
  return true;
}

bool parsePpsSyntax(const Bytes& pps, uint32_t chroma_format,
                    uint32_t* pps_id, uint32_t* sps_id) {
  if (!validEscapedNal(pps.data(), pps.size()) || (pps[0] & 0x1f) != 8 ||
      (pps[0] & 0x60) == 0 || chroma_format > 3)
    return false;
  Bytes rbsp = unescapeRbsp(pps.data(), pps.size());
  BitReader br(rbsp.data(), rbsp.size());
  const uint32_t parsed_pps = br.ue();
  const uint32_t parsed_sps = br.ue();
  if (br.bad || parsed_pps > 255 || parsed_sps > 31) return false;
  br.u(1);  // entropy_coding_mode_flag
  br.u(1);  // bottom_field_pic_order_in_frame_present_flag
  const uint32_t groups_minus1 = br.ue();
  if (groups_minus1 > 7) return false;
  if (groups_minus1 > 0) {
    const uint32_t map_type = br.ue();
    if (map_type == 0) {
      for (uint32_t i = 0; i <= groups_minus1; ++i)
        if (br.ue() > 1'048'575) return false;
    } else if (map_type == 2) {
      for (uint32_t i = 0; i < groups_minus1; ++i) {
        if (br.ue() > 1'048'575 || br.ue() > 1'048'575) return false;
      }
    } else if (map_type >= 3 && map_type <= 5) {
      br.u(1);
      if (br.ue() > 1'048'575) return false;
    } else if (map_type == 6) {
      const uint32_t map_units_minus1 = br.ue();
      if (map_units_minus1 > 1'048'575) return false;
      int bits = 0;
      while ((1u << bits) < groups_minus1 + 1) ++bits;
      for (uint32_t i = 0; i <= map_units_minus1; ++i)
        if (br.u(bits) > groups_minus1) return false;
    } else {
      return false;
    }
  }
  if (br.ue() > 31 || br.ue() > 31) return false;
  br.u(1);
  if (br.u(2) > 2) return false;
  const int32_t init_qp = br.se();
  const int32_t init_qs = br.se();
  const int32_t chroma_qp = br.se();
  if (init_qp < -26 || init_qp > 25 || init_qs < -26 || init_qs > 25 ||
      chroma_qp < -12 || chroma_qp > 12)
    return false;
  br.u(1);
  br.u(1);
  br.u(1);
  if (br.bad) return false;
  if (br.moreRbspData()) {
    const uint32_t transform_8x8 = br.u(1);
    if (br.u(1)) {
      const uint32_t lists = 6 + (transform_8x8 ? (chroma_format == 3 ? 6 : 2) : 0);
      for (uint32_t i = 0; i < lists; ++i)
        if (br.u(1)) skipScalingList(br, i < 6 ? 16 : 64);
    }
    const int32_t second_chroma_qp = br.se();
    if (second_chroma_qp < -12 || second_chroma_qp > 12) return false;
  }
  if (!br.trailingBits()) return false;
  *pps_id = parsed_pps;
  *sps_id = parsed_sps;
  return true;
}

struct SpsSliceInfo {
  uint32_t id = 0;
  uint32_t frame_num_bits = 0;
  uint32_t poc_type = 0;
  uint32_t poc_lsb_bits = 0;
  bool delta_pic_order_always_zero = false;
  bool frame_mbs_only = true;
  uint32_t picture_mbs = 0;
};

struct PpsSliceInfo {
  uint32_t id = 0;
  bool bottom_field_pic_order = false;
  bool redundant_pic_cnt = false;
  bool deblocking_filter_control = false;
  uint32_t slice_groups_minus1 = 0;
};

bool parseSpsSliceInfo(const Bytes& sps, SpsSliceInfo* info) {
  if (!info || !validEscapedNal(sps.data(), sps.size()) || (sps[0] & 0x1f) != 7)
    return false;
  int width = 0, height = 0;
  if (!parseSpsDims(sps.data(), sps.size(), &width, &height)) return false;
  Bytes rbsp = unescapeRbsp(sps.data(), sps.size());
  BitReader br(rbsp.data(), rbsp.size());
  const uint32_t profile = br.u(8);
  br.u(8);
  br.u(8);
  const uint32_t id = br.ue();
  switch (profile) {
    case 100: case 110: case 122: case 244: case 44:
    case 83: case 86: case 118: case 128: case 138: case 139: case 134: case 135: {
      const uint32_t chroma = br.ue();
      if (chroma > 3) return false;
      if (chroma == 3) br.u(1);
      if (br.ue() > 6 || br.ue() > 6) return false;
      br.u(1);
      if (br.u(1)) {
        const int lists = chroma == 3 ? 12 : 8;
        for (int i = 0; i < lists; ++i)
          if (br.u(1)) skipScalingList(br, i < 6 ? 16 : 64);
      }
      break;
    }
    default:
      break;
  }
  const uint32_t frame_num_minus4 = br.ue();
  const uint32_t poc_type = br.ue();
  if (frame_num_minus4 > 12 || poc_type > 2) return false;
  uint32_t poc_bits = 0;
  bool delta_zero = false;
  if (poc_type == 0) {
    const uint32_t poc_minus4 = br.ue();
    if (poc_minus4 > 12) return false;
    poc_bits = poc_minus4 + 4;
  } else if (poc_type == 1) {
    delta_zero = br.u(1) != 0;
    br.se();
    br.se();
    const uint32_t cycle = br.ue();
    if (cycle > 256) return false;
    for (uint32_t i = 0; i < cycle; ++i) br.se();
  }
  br.ue();
  br.u(1);
  const uint32_t width_mbs_minus1 = br.ue();
  const uint32_t height_map_units_minus1 = br.ue();
  if (width_mbs_minus1 >= 1024 || height_map_units_minus1 >= 1024) return false;
  const uint32_t width_mbs = width_mbs_minus1 + 1;
  const uint32_t height_map_units = height_map_units_minus1 + 1;
  const bool frame_only = br.u(1) != 0;
  if (!frame_only) br.u(1);
  const uint64_t picture_mbs = static_cast<uint64_t>(width_mbs) * height_map_units *
                               (frame_only ? 1 : 2);
  if (br.bad || picture_mbs == 0 || picture_mbs > 1'048'576) return false;
  info->id = id;
  info->frame_num_bits = frame_num_minus4 + 4;
  info->poc_type = poc_type;
  info->poc_lsb_bits = poc_bits;
  info->delta_pic_order_always_zero = delta_zero;
  info->frame_mbs_only = frame_only;
  info->picture_mbs = static_cast<uint32_t>(picture_mbs);
  return true;
}

bool parsePpsSliceInfo(const Bytes& pps, uint32_t chroma_format, PpsSliceInfo* info) {
  uint32_t sps_id = 0;
  if (!info || !parsePpsSyntax(pps, chroma_format, &info->id, &sps_id)) return false;
  Bytes rbsp = unescapeRbsp(pps.data(), pps.size());
  BitReader br(rbsp.data(), rbsp.size());
  br.ue();
  br.ue();
  br.u(1);
  info->bottom_field_pic_order = br.u(1) != 0;
  info->slice_groups_minus1 = br.ue();
  if (info->slice_groups_minus1 != 0) return false;
  br.ue();
  br.ue();
  br.u(1);
  br.u(2);
  br.se();
  br.se();
  br.se();
  info->deblocking_filter_control = br.u(1) != 0;
  br.u(1);
  info->redundant_pic_cnt = br.u(1) != 0;
  return !br.bad;
}

struct SlicePictureIdentity {
  uint32_t pps_id = 0;
  uint32_t slice_type = 0;
  uint32_t frame_num = 0;
  uint32_t idr_pic_id = 0;
  uint32_t poc_lsb = 0;
  int32_t delta_bottom = 0;
  int32_t delta_poc0 = 0;
  int32_t delta_poc1 = 0;
  bool field_pic = false;
  bool bottom_field = false;
  bool no_output_of_prior_pics = false;
  bool long_term_reference = false;
};

bool parseIdrSlice(const NalView& nal, const SpsSliceInfo& sps,
                   const PpsSliceInfo& pps, SlicePictureIdentity* picture,
                   uint32_t* first_mb) {
  if (!validEscapedNal(nal.p, nal.n, 4 * 1024 * 1024) || nal.type != 5 ||
      (nal.p[0] & 0x60) == 0)
    return false;
  Bytes rbsp = unescapeRbsp(nal.p, nal.n);
  BitReader br(rbsp.data(), rbsp.size());
  SlicePictureIdentity parsed;
  const uint32_t parsed_first_mb = br.ue();
  const uint32_t slice_type = br.ue();
  parsed.pps_id = br.ue();
  if (br.bad || parsed_first_mb >= sps.picture_mbs || slice_type > 9 ||
      slice_type % 5 != 2 || parsed.pps_id != pps.id || pps.slice_groups_minus1 != 0)
    return false;
  parsed.slice_type = slice_type;
  parsed.frame_num = br.u(sps.frame_num_bits);
  if (!sps.frame_mbs_only) {
    parsed.field_pic = br.u(1) != 0;
    if (parsed.field_pic) parsed.bottom_field = br.u(1) != 0;
  }
  parsed.idr_pic_id = br.ue();
  if (parsed.idr_pic_id > 65535) return false;
  if (sps.poc_type == 0) {
    parsed.poc_lsb = br.u(sps.poc_lsb_bits);
    if (pps.bottom_field_pic_order && !parsed.field_pic)
      parsed.delta_bottom = br.se();
  } else if (sps.poc_type == 1 && !sps.delta_pic_order_always_zero) {
    parsed.delta_poc0 = br.se();
    if (pps.bottom_field_pic_order && !parsed.field_pic)
      parsed.delta_poc1 = br.se();
  }
  if (pps.redundant_pic_cnt && br.ue() > 127) return false;
  parsed.no_output_of_prior_pics = br.u(1) != 0;
  parsed.long_term_reference = br.u(1) != 0;
  const int32_t slice_qp_delta = br.se();
  if (slice_qp_delta < -26 || slice_qp_delta > 25) return false;
  if (pps.deblocking_filter_control) {
    const uint32_t disable_deblocking = br.ue();
    if (disable_deblocking > 2) return false;
    if (disable_deblocking != 1) {
      const int32_t alpha = br.se();
      const int32_t beta = br.se();
      if (alpha < -6 || alpha > 6 || beta < -6 || beta > 6) return false;
    }
  }
  if (br.bad || !br.moreRbspData()) return false;
  *picture = parsed;
  *first_mb = parsed_first_mb;
  return true;
}


void skipScalingList(BitReader& br, int size) {
  int last = 8, next = 8;
  for (int i = 0; i < size && !br.bad; i++) {
    if (next != 0) next = (last + br.se() + 256) % 256;
    if (next != 0) last = next;
  }
}


struct BoxWriter {
  Bytes buf;

  void u8(uint8_t v) { buf.push_back(v); }
  void u16(uint16_t v) {
    buf.push_back(static_cast<uint8_t>(v >> 8));
    buf.push_back(static_cast<uint8_t>(v));
  }
  void u32(uint32_t v) {
    for (int i = 3; i >= 0; i--) buf.push_back(static_cast<uint8_t>(v >> (i * 8)));
  }
  void u64(uint64_t v) {
    for (int i = 7; i >= 0; i--) buf.push_back(static_cast<uint8_t>(v >> (i * 8)));
  }
  void bytes(const uint8_t* p, size_t n) { buf.insert(buf.end(), p, p + n); }
  void bytes(const Bytes& b) { buf.insert(buf.end(), b.begin(), b.end()); }
  void zeros(size_t n) { buf.insert(buf.end(), n, 0); }
  void fourcc(const char* c) { bytes(reinterpret_cast<const uint8_t*>(c), 4); }


  size_t open(const char* type) {
    size_t at = buf.size();
    u32(0);
    fourcc(type);
    return at;
  }

  size_t openFull(const char* type, uint8_t version, uint32_t flags) {
    size_t at = open(type);
    u32((static_cast<uint32_t>(version) << 24) | (flags & 0xffffff));
    return at;
  }
  void close(size_t at) {
    uint32_t size = static_cast<uint32_t>(buf.size() - at);
    buf[at] = static_cast<uint8_t>(size >> 24);
    buf[at + 1] = static_cast<uint8_t>(size >> 16);
    buf[at + 2] = static_cast<uint8_t>(size >> 8);
    buf[at + 3] = static_cast<uint8_t>(size);
  }
};

constexpr uint32_t kTimescale = 1000;
constexpr uint32_t kTrackId = 1;

}  // namespace



std::vector<NalView> splitAnnexB(const uint8_t* data, size_t len) {
  std::vector<NalView> out;
  if (!data || len < 4) return out;
  size_t i = 0;
  size_t start = SIZE_MAX;
  while (i + 2 < len) {
    if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1) {
      if (start != SIZE_MAX) {
        size_t end = i;
        while (end > start && data[end - 1] == 0) end--;
        if (end > start) out.push_back({data + start, end - start, data[start] & 0x1f});
      }
      start = i + 3;
      i += 3;
    } else {
      i++;
    }
  }
  if (start != SIZE_MAX && start < len)
    out.push_back({data + start, len - start, data[start] & 0x1f});
  return out;
}



bool parseSpsDims(const uint8_t* sps, size_t len, int* w, int* h) {
  if (!sps || len < 4 || (sps[0] & 0x1f) != 7) return false;
  Bytes rbsp = unescapeRbsp(sps, len);
  if (rbsp.size() < 3) return false;
  BitReader br(rbsp.data(), rbsp.size());
  uint32_t profile_idc = br.u(8);
  br.u(8);  // constraint flags + reserved
  br.u(8);  // level_idc
  br.ue();  // seq_parameter_set_id
  uint32_t chroma_format_idc = 1;
  bool separate_colour = false;
  switch (profile_idc) {
    case 100: case 110: case 122: case 244: case 44:
    case 83: case 86: case 118: case 128: case 138: case 139: case 134: case 135: {
      chroma_format_idc = br.ue();
      if (chroma_format_idc == 3) separate_colour = br.u(1) != 0;
      br.ue();  // bit_depth_luma_minus8
      br.ue();  // bit_depth_chroma_minus8
      br.u(1);  // qpprime_y_zero_transform_bypass_flag
      if (br.u(1)) {  // seq_scaling_matrix_present_flag
        int lists = (chroma_format_idc != 3) ? 8 : 12;
        for (int i = 0; i < lists; i++) {
          if (br.u(1)) skipScalingList(br, i < 6 ? 16 : 64);
        }
      }
      break;
    }
    default:
      break;
  }
  br.ue();  // log2_max_frame_num_minus4
  uint32_t poc_type = br.ue();
  if (poc_type == 0) {
    br.ue();  // log2_max_pic_order_cnt_lsb_minus4
  } else if (poc_type == 1) {
    br.u(1);  // delta_pic_order_always_zero_flag
    br.se();  // offset_for_non_ref_pic
    br.se();  // offset_for_top_to_bottom_field
    uint32_t cycle = br.ue();
    if (cycle > 256) return false;
    for (uint32_t i = 0; i < cycle; i++) br.se();
  }
  br.ue();  // max_num_ref_frames
  br.u(1);  // gaps_in_frame_num_value_allowed_flag
  uint32_t mbs_w = br.ue() + 1;
  uint32_t map_h = br.ue() + 1;
  uint32_t frame_mbs_only = br.u(1);
  if (!frame_mbs_only) br.u(1);  // mb_adaptive_frame_field_flag
  br.u(1);                       // direct_8x8_inference_flag
  uint32_t crop_l = 0, crop_r = 0, crop_t = 0, crop_b = 0;
  if (br.u(1)) {  // frame_cropping_flag
    crop_l = br.ue();
    crop_r = br.ue();
    crop_t = br.ue();
    crop_b = br.ue();
  }
  if (br.bad) return false;

  uint32_t sub_w = (chroma_format_idc == 1 || chroma_format_idc == 2) ? 2 : 1;
  uint32_t sub_h = (chroma_format_idc == 1) ? 2 : 1;
  if (chroma_format_idc == 0 || separate_colour) sub_w = sub_h = 1;
  uint32_t unit_y = sub_h * (2 - frame_mbs_only);
  int64_t width = static_cast<int64_t>(mbs_w) * 16 - static_cast<int64_t>(crop_l + crop_r) * sub_w;
  int64_t height = static_cast<int64_t>((2 - frame_mbs_only) * map_h) * 16 -
                   static_cast<int64_t>(crop_t + crop_b) * unit_y;
  if (width <= 0 || height <= 0 || width > 16384 || height > 16384) return false;
  *w = static_cast<int>(width);
  *h = static_cast<int>(height);
  return true;
}

bool validParameterSets(const Bytes& sps, const Bytes& pps) {
  int width = 0, height = 0;
  uint32_t sps_id = 0, pps_id = 0, pps_sps_id = 0, chroma_format = 0;
  return validEscapedNal(sps.data(), sps.size()) && (sps[0] & 0x1f) == 7 &&
      (sps[0] & 0x60) != 0 &&
      parseSpsDims(sps.data(), sps.size(), &width, &height) &&
      parseSpsId(sps.data(), sps.size(), &sps_id) &&
      spsChromaFormat(sps, &chroma_format) &&
      parsePpsSyntax(pps, chroma_format, &pps_id, &pps_sps_id) &&
      sps_id == pps_sps_id;
}

bool idrReferencesPps(const uint8_t* annexb, size_t len, const Bytes& sps,
                      const Bytes& pps) {
  if (!annexb || len == 0 || len > 4 * 1024 * 1024 ||
      !validParameterSets(sps, pps)) return false;
  uint32_t chroma_format = 0, pps_id = 0, pps_sps_id = 0;
  SpsSliceInfo sps_info;
  PpsSliceInfo pps_info;
  if (!spsChromaFormat(sps, &chroma_format) ||
      !parseSpsSliceInfo(sps, &sps_info) ||
      !parsePpsSyntax(pps, chroma_format, &pps_id, &pps_sps_id) ||
      pps_sps_id != sps_info.id || !parsePpsSliceInfo(pps, chroma_format, &pps_info) ||
      pps_info.id != pps_id)
    return false;
  const std::vector<NalView> nals = splitAnnexB(annexb, len);
  if (nals.empty() || nals.size() > 128) return false;
  bool saw_slice = false;
  SlicePictureIdentity first_picture;
  std::vector<uint32_t> first_mbs;
  for (const NalView& nal : nals) {
    if (nal.type < 1 || nal.type > 5) continue;
    if (nal.type != 5) return false;
    SlicePictureIdentity picture;
    uint32_t first_mb = 0;
    if (!parseIdrSlice(nal, sps_info, pps_info, &picture, &first_mb)) return false;
    if (!saw_slice) {
      first_picture = picture;
      saw_slice = true;
    } else if (picture.pps_id != first_picture.pps_id ||
               picture.slice_type != first_picture.slice_type ||
               picture.frame_num != first_picture.frame_num ||
               picture.idr_pic_id != first_picture.idr_pic_id ||
               picture.poc_lsb != first_picture.poc_lsb ||
               picture.delta_bottom != first_picture.delta_bottom ||
               picture.delta_poc0 != first_picture.delta_poc0 ||
               picture.delta_poc1 != first_picture.delta_poc1 ||
               picture.field_pic != first_picture.field_pic ||
               picture.bottom_field != first_picture.bottom_field ||
               picture.no_output_of_prior_pics != first_picture.no_output_of_prior_pics ||
               picture.long_term_reference != first_picture.long_term_reference)
      return false;
    if (std::find(first_mbs.begin(), first_mbs.end(), first_mb) != first_mbs.end())
      return false;
    first_mbs.push_back(first_mb);
  }
  return saw_slice;
}

std::string codecString(const Bytes& sps) {
  if (sps.size() < 4) return "";
  char buf[32];
  std::snprintf(buf, sizeof(buf), "avc1.%02X%02X%02X", sps[1], sps[2], sps[3]);
  return buf;
}

// ---------- AnnexB → Sample (AVCC) ----------

Sample toSample(const uint8_t* annexb, size_t len, Bytes* sps, Bytes* pps) {
  Sample s;
  for (const NalView& nal : splitAnnexB(annexb, len)) {
    switch (nal.type) {
      case 7:  // SPS
        if (sps && (sps->size() != nal.n || std::memcmp(sps->data(), nal.p, nal.n) != 0))
          sps->assign(nal.p, nal.p + nal.n);
        continue;
      case 8:  // PPS
        if (pps && (pps->size() != nal.n || std::memcmp(pps->data(), nal.p, nal.n) != 0))
          pps->assign(nal.p, nal.p + nal.n);
        continue;
      case 9:   // AUD
      case 6:   // SEI
        continue;
      default:
        break;
    }
    if (nal.type == 5) s.key = true;

    uint32_t n = static_cast<uint32_t>(nal.n);
    s.data.push_back(static_cast<uint8_t>(n >> 24));
    s.data.push_back(static_cast<uint8_t>(n >> 16));
    s.data.push_back(static_cast<uint8_t>(n >> 8));
    s.data.push_back(static_cast<uint8_t>(n));
    s.data.insert(s.data.end(), nal.p, nal.p + nal.n);
  }
  return s;
}

// ---------- init segment ----------

Bytes buildInit(const Bytes& sps, const Bytes& pps) {
  int w = 0, h = 0;
  parseSpsDims(sps.data(), sps.size(), &w, &h);

  BoxWriter bw;
  // ftyp
  {
    size_t b = bw.open("ftyp");
    bw.fourcc("isom");
    bw.u32(0x200);  // minor_version
    bw.fourcc("isom");
    bw.fourcc("iso5");
    bw.fourcc("avc1");
    bw.fourcc("mp41");
    bw.close(b);
  }
  // moov
  size_t moov = bw.open("moov");
  {
    size_t mvhd = bw.openFull("mvhd", 0, 0);
    bw.u32(0);           // creation_time
    bw.u32(0);           // modification_time
    bw.u32(kTimescale);  // timescale
    bw.u32(0);
    bw.u32(0x00010000);  // rate 1.0
    bw.u16(0x0100);      // volume 1.0
    bw.zeros(2 + 8);     // reserved

    const uint32_t mat[9] = {0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000};
    for (uint32_t m : mat) bw.u32(m);
    bw.zeros(6 * 4);     // pre_defined
    bw.u32(kTrackId + 1);  // next_track_ID
    bw.close(mvhd);
  }
  size_t trak = bw.open("trak");
  {
    size_t tkhd = bw.openFull("tkhd", 0, 3);  // enabled | in_movie
    bw.u32(0);         // creation_time
    bw.u32(0);         // modification_time
    bw.u32(kTrackId);  // track_ID
    bw.u32(0);         // reserved
    bw.u32(0);         // duration
    bw.zeros(8);       // reserved
    bw.u16(0);         // layer
    bw.u16(0);         // alternate_group
    bw.u16(0);         // volume (video)
    bw.u16(0);         // reserved
    const uint32_t mat[9] = {0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000};
    for (uint32_t m : mat) bw.u32(m);
    bw.u32(static_cast<uint32_t>(w) << 16);
    bw.u32(static_cast<uint32_t>(h) << 16);  // height
    bw.close(tkhd);
  }
  size_t mdia = bw.open("mdia");
  {
    size_t mdhd = bw.openFull("mdhd", 0, 0);
    bw.u32(0);           // creation_time
    bw.u32(0);           // modification_time
    bw.u32(kTimescale);  // timescale
    bw.u32(0);           // duration
    bw.u16(0x55c4);      // language "und"
    bw.u16(0);           // pre_defined
    bw.close(mdhd);
  }
  {
    size_t hdlr = bw.openFull("hdlr", 0, 0);
    bw.u32(0);  // pre_defined
    bw.fourcc("vide");
    bw.zeros(12);  // reserved
    const char* name = "VideoHandler";
    bw.bytes(reinterpret_cast<const uint8_t*>(name), std::strlen(name) + 1);
    bw.close(hdlr);
  }
  size_t minf = bw.open("minf");
  {
    size_t vmhd = bw.openFull("vmhd", 0, 1);
    bw.u16(0);    // graphicsmode
    bw.zeros(6);  // opcolor
    bw.close(vmhd);
  }
  {
    size_t dinf = bw.open("dinf");
    size_t dref = bw.openFull("dref", 0, 0);
    bw.u32(1);  // entry_count
    size_t url = bw.openFull("url ", 0, 1);  // self-contained
    bw.close(url);
    bw.close(dref);
    bw.close(dinf);
  }
  size_t stbl = bw.open("stbl");
  {
    size_t stsd = bw.openFull("stsd", 0, 0);
    bw.u32(1);  // entry_count
    size_t avc1 = bw.open("avc1");
    bw.zeros(6);  // reserved
    bw.u16(1);    // data_reference_index
    bw.zeros(16); // pre_defined + reserved
    bw.u16(static_cast<uint16_t>(w));
    bw.u16(static_cast<uint16_t>(h));
    bw.u32(0x00480000);  // horizresolution 72dpi
    bw.u32(0x00480000);  // vertresolution
    bw.u32(0);           // reserved
    bw.u16(1);           // frame_count
    bw.zeros(32);
    bw.u16(0x0018);      // depth
    bw.u16(0xffff);      // pre_defined -1
    {
      size_t avcC = bw.open("avcC");
      bw.u8(1);                                  // configurationVersion
      bw.u8(sps.size() > 1 ? sps[1] : 0);        // AVCProfileIndication
      bw.u8(sps.size() > 2 ? sps[2] : 0);        // profile_compatibility
      bw.u8(sps.size() > 3 ? sps[3] : 0);        // AVCLevelIndication
      bw.u8(0xff);                               // lengthSizeMinusOne = 3
      bw.u8(0xe1);                               // numOfSequenceParameterSets = 1
      bw.u16(static_cast<uint16_t>(sps.size()));
      bw.bytes(sps);
      bw.u8(1);                                  // numOfPictureParameterSets
      bw.u16(static_cast<uint16_t>(pps.size()));
      bw.bytes(pps);
      bw.close(avcC);
    }
    bw.close(avc1);
    bw.close(stsd);
  }
  {
    size_t stts = bw.openFull("stts", 0, 0);
    bw.u32(0);
    bw.close(stts);
    size_t stsc = bw.openFull("stsc", 0, 0);
    bw.u32(0);
    bw.close(stsc);
    size_t stsz = bw.openFull("stsz", 0, 0);
    bw.u32(0);  // sample_size
    bw.u32(0);  // sample_count
    bw.close(stsz);
    size_t stco = bw.openFull("stco", 0, 0);
    bw.u32(0);
    bw.close(stco);
  }
  bw.close(stbl);
  bw.close(minf);
  bw.close(mdia);
  bw.close(trak);
  {
    size_t mvex = bw.open("mvex");
    size_t trex = bw.openFull("trex", 0, 0);
    bw.u32(kTrackId);  // track_ID
    bw.u32(1);         // default_sample_description_index
    bw.u32(0);         // default_sample_duration
    bw.u32(0);         // default_sample_size
    bw.u32(0);         // default_sample_flags
    bw.close(trex);
    bw.close(mvex);
  }
  bw.close(moov);
  return std::move(bw.buf);
}

// ---------- media fragment ----------

Bytes buildFragment(uint32_t seq, uint64_t base_dt, const std::vector<Sample>& samples) {
  BoxWriter bw;
  size_t moof = bw.open("moof");
  {
    size_t mfhd = bw.openFull("mfhd", 0, 0);
    bw.u32(seq);
    bw.close(mfhd);
  }
  size_t traf = bw.open("traf");
  {

    size_t tfhd = bw.openFull("tfhd", 0, 0x020000);
    bw.u32(kTrackId);
    bw.close(tfhd);
  }
  {
    size_t tfdt = bw.openFull("tfdt", 1, 0);
    bw.u64(base_dt);
    bw.close(tfdt);
  }
  size_t data_offset_at;
  {
    // data-offset(0x01) + sample-duration(0x100) + sample-size(0x200) + sample-flags(0x400)
    size_t trun = bw.openFull("trun", 0, 0x000701);
    bw.u32(static_cast<uint32_t>(samples.size()));
    data_offset_at = bw.buf.size();
    bw.u32(0);
    for (const Sample& s : samples) {
      bw.u32(s.dur);
      bw.u32(static_cast<uint32_t>(s.data.size()));
      // sample_depends_on=2 (I) / =1 + non_sync (P/B)
      bw.u32(s.key ? 0x02000000u : 0x01010000u);
    }
    bw.close(trun);
  }
  bw.close(traf);
  bw.close(moof);

  uint32_t off = static_cast<uint32_t>(bw.buf.size() + 8);
  bw.buf[data_offset_at] = static_cast<uint8_t>(off >> 24);
  bw.buf[data_offset_at + 1] = static_cast<uint8_t>(off >> 16);
  bw.buf[data_offset_at + 2] = static_cast<uint8_t>(off >> 8);
  bw.buf[data_offset_at + 3] = static_cast<uint8_t>(off);
  size_t mdat = bw.open("mdat");
  for (const Sample& s : samples) bw.bytes(s.data);
  bw.close(mdat);
  return std::move(bw.buf);
}

}  // namespace fmp4
}  // namespace db
