#include "media/fmp4_demux.h"

#include <cstring>

#include "media/fmp4.h"

namespace db {
namespace fmp4 {

namespace {

constexpr uint32_t fourcc(const char* c) {
  return (static_cast<uint32_t>(static_cast<uint8_t>(c[0])) << 24) |
         (static_cast<uint32_t>(static_cast<uint8_t>(c[1])) << 16) |
         (static_cast<uint32_t>(static_cast<uint8_t>(c[2])) << 8) |
         static_cast<uint32_t>(static_cast<uint8_t>(c[3]));
}

constexpr uint32_t kFtyp = fourcc("ftyp");
constexpr uint32_t kMoov = fourcc("moov");
constexpr uint32_t kMoof = fourcc("moof");
constexpr uint32_t kMdat = fourcc("mdat");
constexpr uint32_t kDbts = fourcc("dbts");
constexpr uint32_t kTraf = fourcc("traf");
constexpr uint32_t kTfdt = fourcc("tfdt");
constexpr uint32_t kTrun = fourcc("trun");
constexpr uint32_t kAvcC = fourcc("avcC");

// Containers descended while looking for avcC inside moov.
constexpr uint32_t kInitContainers[] = {fourcc("moov"), fourcc("trak"), fourcc("mdia"),
                                        fourcc("minf"), fourcc("stbl"), fourcc("stsd")};

uint32_t be32(const uint8_t* p) {
  return (static_cast<uint32_t>(p[0]) << 24) | (static_cast<uint32_t>(p[1]) << 16) |
         (static_cast<uint32_t>(p[2]) << 8) | p[3];
}
uint64_t be64(const uint8_t* p) { return (static_cast<uint64_t>(be32(p)) << 32) | be32(p + 4); }
uint16_t be16(const uint8_t* p) { return static_cast<uint16_t>((p[0] << 8) | p[1]); }

const uint8_t kStartCode[4] = {0, 0, 0, 1};

void appendNal(Bytes* out, const uint8_t* nal, size_t n) {
  out->insert(out->end(), kStartCode, kStartCode + 4);
  out->insert(out->end(), nal, nal + n);
}

// avc1 is a sample entry (78 bytes of fixed fields before its child boxes); everything else
// in the init path is a plain container. stsd carries a full-box header plus entry_count.
bool findAvcC(const uint8_t* p, size_t n, const uint8_t** out, size_t* out_n, int depth) {
  if (depth > 8) return false;
  size_t i = 0;
  while (i + 8 <= n) {
    uint32_t size = be32(p + i);
    uint32_t type = be32(p + i + 4);
    size_t header = 8;
    uint64_t box_size = size;
    if (size == 1) {
      if (i + 16 > n) return false;
      box_size = be64(p + i + 8);
      header = 16;
    } else if (size == 0) {
      box_size = n - i;
    }
    if (box_size < header || i + box_size > n) return false;
    const uint8_t* body = p + i + header;
    size_t body_n = static_cast<size_t>(box_size - header);
    if (type == kAvcC) {
      *out = body;
      *out_n = body_n;
      return true;
    }
    size_t skip = 0;
    bool container = false;
    for (uint32_t c : kInitContainers) {
      if (type == c) container = true;
    }
    if (type == fourcc("stsd")) skip = 8;    // version/flags + entry_count
    if (type == fourcc("avc1") || type == fourcc("avc3")) {
      container = true;
      skip = 78;  // VisualSampleEntry fixed fields
    }
    if (container && body_n >= skip &&
        findAvcC(body + skip, body_n - skip, out, out_n, depth + 1))
      return true;
    i += static_cast<size_t>(box_size);
  }
  return false;
}

}  // namespace

bool Demuxer::parseAvcC(const uint8_t* p, size_t n, Bytes* sps, Bytes* pps, int* nal_len_size) {
  if (!p || n < 7 || p[0] != 1) return false;
  int len_size = (p[4] & 0x03) + 1;
  size_t i = 5;
  int sps_count = p[i++] & 0x1f;
  Bytes first_sps, first_pps;
  for (int k = 0; k < sps_count; k++) {
    if (i + 2 > n) return false;
    size_t len = be16(p + i);
    i += 2;
    if (i + len > n || len == 0) return false;
    if (first_sps.empty()) first_sps.assign(p + i, p + i + len);
    i += len;
  }
  if (i >= n) return false;
  int pps_count = p[i++];
  for (int k = 0; k < pps_count; k++) {
    if (i + 2 > n) return false;
    size_t len = be16(p + i);
    i += 2;
    if (i + len > n || len == 0) return false;
    if (first_pps.empty()) first_pps.assign(p + i, p + i + len);
    i += len;
  }
  if (first_sps.empty() || first_pps.empty()) return false;
  if (sps) *sps = std::move(first_sps);
  if (pps) *pps = std::move(first_pps);
  if (nal_len_size) *nal_len_size = len_size;
  return true;
}

void Demuxer::reset() {
  buf_.clear();
  error_.clear();
  failed_ = false;
  configured_ = false;
  config_ = Config();
  nal_len_size_ = 4;
  pending_.clear();
  capture_times_.clear();
  next_dts_ = 0;
  have_tfdt_ = false;
  samples_ = 0;
}

bool Demuxer::fail(const std::string& why) {
  failed_ = true;
  error_ = why;
  buf_.clear();
  pending_.clear();
  return false;
}

bool Demuxer::feed(const uint8_t* data, size_t len) {
  if (failed_) return false;
  if (data && len) buf_.insert(buf_.end(), data, data + len);
  size_t consumed = 0;
  while (buf_.size() - consumed >= 8) {
    const uint8_t* p = buf_.data() + consumed;
    uint32_t size = be32(p);
    uint32_t type = be32(p + 4);
    size_t header = 8;
    uint64_t box_size = size;
    if (size == 1) {
      if (buf_.size() - consumed < 16) break;
      box_size = be64(p + 8);
      header = 16;
    } else if (size == 0) {
      return fail("open-ended box in a live stream");
    }
    if (box_size < header) return fail("box smaller than its header");
    size_t max = kMaxOtherBox;
    if (type == kMoov) max = kMaxInitBox;
    else if (type == kMoof || type == kDbts) max = kMaxFragmentBox;
    else if (type == kMdat) max = kMaxMdatBox;
    if (box_size > max) return fail("box too large");
    if (buf_.size() - consumed < box_size) break;  // wait for the rest
    if (!handleBox(type, p + header, static_cast<size_t>(box_size - header))) return false;
    consumed += static_cast<size_t>(box_size);
  }
  if (consumed) buf_.erase(buf_.begin(), buf_.begin() + static_cast<std::ptrdiff_t>(consumed));
  return true;
}

bool Demuxer::handleBox(uint32_t type, const uint8_t* body, size_t n) {
  if (type == kMoov) return handleMoov(body, n);
  if (type == kMoof) return handleMoof(body, n);
  if (type == kMdat) return handleMdat(body, n);
  if (type == kDbts) {
    capture_times_.clear();
    if (n < 4) return true;
    uint32_t count = be32(body);
    if (count > 1024 || n < 4 + static_cast<size_t>(count) * 8) return true;  // ignore, not fatal
    for (uint32_t i = 0; i < count; i++)
      capture_times_.push_back(static_cast<int64_t>(be64(body + 4 + i * 8)));
    return true;
  }
  // ftyp, styp, free and anything unknown are skipped.
  (void)kFtyp;
  return true;
}

bool Demuxer::handleMoov(const uint8_t* body, size_t n) {
  const uint8_t* avcc = nullptr;
  size_t avcc_n = 0;
  if (!findAvcC(body, n, &avcc, &avcc_n, 0)) return fail("moov has no avcC");
  Config cfg;
  int len_size = 4;
  if (!parseAvcC(avcc, avcc_n, &cfg.sps, &cfg.pps, &len_size)) return fail("invalid avcC");
  parseSpsDims(cfg.sps.data(), cfg.sps.size(), &cfg.width, &cfg.height);
  config_ = cfg;
  nal_len_size_ = len_size;
  configured_ = true;
  pending_.clear();
  have_tfdt_ = false;
  if (on_config) on_config(config_);
  return true;
}

bool Demuxer::handleMoof(const uint8_t* body, size_t n) {
  if (!configured_) return fail("moof before the init segment");
  pending_.clear();
  bool saw_trun = false;
  // moof: mfhd, traf...; traf: tfhd, tfdt, trun.
  size_t i = 0;
  while (i + 8 <= n) {
    uint32_t size = be32(body + i);
    uint32_t type = be32(body + i + 4);
    if (size < 8 || i + size > n) return fail("corrupt moof child");
    if (type == kTraf) {
      size_t j = i + 8;
      size_t end = i + size;
      while (j + 8 <= end) {
        uint32_t csize = be32(body + j);
        uint32_t ctype = be32(body + j + 4);
        if (csize < 8 || j + csize > end) return fail("corrupt traf child");
        const uint8_t* c = body + j + 8;
        size_t cn = csize - 8;
        if (ctype == kTfdt) {
          if (cn < 4) return fail("short tfdt");
          uint8_t version = c[0];
          if (version == 1) {
            if (cn < 12) return fail("short tfdt v1");
            next_dts_ = be64(c + 4);
          } else {
            if (cn < 8) return fail("short tfdt v0");
            next_dts_ = be32(c + 4);
          }
          have_tfdt_ = true;
        } else if (ctype == kTrun) {
          if (cn < 8) return fail("short trun");
          uint32_t flags = be32(c) & 0x00ffffff;
          uint32_t count = be32(c + 4);
          if (count == 0 || count > 4096) return fail("trun sample count out of range");
          size_t k = 8;
          if (flags & 0x000001) k += 4;  // data_offset
          uint32_t first_flags = 0;
          bool have_first_flags = false;
          if (flags & 0x000004) {
            if (k + 4 > cn) return fail("short trun first flags");
            first_flags = be32(c + k);
            have_first_flags = true;
            k += 4;
          }
          for (uint32_t s = 0; s < count; s++) {
            TrunSample ts;
            if (flags & 0x000100) {
              if (k + 4 > cn) return fail("short trun duration");
              ts.dur = be32(c + k);
              k += 4;
            }
            if (flags & 0x000200) {
              if (k + 4 > cn) return fail("short trun size");
              ts.size = be32(c + k);
              k += 4;
            } else {
              return fail("trun without sample sizes");
            }
            if (flags & 0x000400) {
              if (k + 4 > cn) return fail("short trun flags");
              ts.flags = be32(c + k);
              k += 4;
            } else if (s == 0 && have_first_flags) {
              ts.flags = first_flags;
            }
            if (flags & 0x000800) {
              if (k + 4 > cn) return fail("short trun cts");
              k += 4;  // composition offset: ignored, this stream has no B-frames
            }
            pending_.push_back(ts);
          }
          saw_trun = true;
        }
        j += csize;
      }
    }
    i += size;
  }
  if (!saw_trun || pending_.empty()) return fail("moof without trun samples");
  return true;
}

bool Demuxer::handleMdat(const uint8_t* body, size_t n) {
  if (pending_.empty()) return fail("mdat without a preceding moof");
  size_t off = 0;
  for (size_t s = 0; s < pending_.size(); s++) {
    const TrunSample& ts = pending_[s];
    if (ts.size < static_cast<uint32_t>(nal_len_size_) || off + ts.size > n)
      return fail("trun sample size exceeds mdat");
    const uint8_t* sample = body + off;
    size_t remaining = ts.size;
    AccessUnit au;
    // sample_is_non_sync_sample is bit 16 of the sample flags; a set bit means "not a keyframe".
    bool non_sync = (ts.flags & 0x00010000u) != 0;
    bool has_idr = false;
    Bytes nals;
    size_t i = 0;
    while (i + static_cast<size_t>(nal_len_size_) <= remaining) {
      uint32_t len = 0;
      for (int b = 0; b < nal_len_size_; b++) len = (len << 8) | sample[i + b];
      i += static_cast<size_t>(nal_len_size_);
      if (len == 0 || i + len > remaining) return fail("AVCC NAL length exceeds sample");
      if ((sample[i] & 0x1f) == 5) has_idr = true;
      appendNal(&nals, sample + i, len);
      i += len;
    }
    au.key = has_idr || (!non_sync && ts.flags != 0);
    if (au.key) {
      appendNal(&au.annexb, config_.sps.data(), config_.sps.size());
      appendNal(&au.annexb, config_.pps.data(), config_.pps.size());
    }
    au.annexb.insert(au.annexb.end(), nals.begin(), nals.end());
    au.dts = next_dts_;
    au.dur_ms = ts.dur;
    au.capture_ms = s < capture_times_.size() ? capture_times_[s] : 0;
    next_dts_ += ts.dur;
    off += ts.size;
    samples_++;
    if (on_sample) on_sample(std::move(au));
  }
  pending_.clear();
  capture_times_.clear();
  return true;
}

}  // namespace fmp4
}  // namespace db
