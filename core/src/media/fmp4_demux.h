// Streaming demuxer for the repository's live fMP4 (/stream.mp4): the init segment produced by
// fmp4::buildInit, then per-frame `dbts` + moof + mdat triples from VideoTrack, with `free`
// keepalive boxes between them. It turns each mdat back into one Annex-B access unit so a
// platform decoder (Media Foundation on Windows) can be fed directly, without an HTTP media
// source that first wants to know the file length. Dependency-free and host-testable.
#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

#include "util/common.h"

namespace db {
namespace fmp4 {

class Demuxer {
 public:
  struct Config {
    Bytes sps;   // raw NAL (no start code)
    Bytes pps;
    int width = 0;
    int height = 0;
  };

  struct AccessUnit {
    Bytes annexb;          // 00 00 00 01 + NAL, SPS/PPS prepended on random-access points
    bool key = false;
    uint64_t dts = 0;      // tfdt + accumulated durations, 1000-unit timescale
    uint32_t dur_ms = 0;
    int64_t capture_ms = 0;  // from the dbts box; 0 when absent
  };

  // Called from feed() on the caller's thread. A new Config replaces the previous one (SPS
  // change: the track restarts and the next sample is a keyframe).
  std::function<void(const Config&)> on_config;
  std::function<void(AccessUnit&&)> on_sample;

  // Appends stream bytes and parses every complete top-level box. Returns false on a fatal
  // parse error (the caller reconnects); error() then explains why. Bytes after a fatal error
  // are ignored until reset().
  bool feed(const uint8_t* data, size_t len);
  void reset();

  const std::string& error() const { return error_; }
  bool configured() const { return configured_; }
  size_t buffered() const { return buf_.size(); }
  uint64_t samples() const { return samples_; }

  // Box size ceilings: anything larger is treated as a corrupt stream, never buffered.
  static constexpr size_t kMaxInitBox = 1 << 20;
  static constexpr size_t kMaxFragmentBox = 64 << 10;
  static constexpr size_t kMaxMdatBox = 8 << 20;
  static constexpr size_t kMaxOtherBox = 64 << 10;

  // Exposed for tests: parse an avcC payload into SPS/PPS.
  static bool parseAvcC(const uint8_t* p, size_t n, Bytes* sps, Bytes* pps, int* nal_len_size);

 private:
  struct TrunSample {
    uint32_t dur = 0;
    uint32_t size = 0;
    uint32_t flags = 0;
  };

  bool handleBox(uint32_t type, const uint8_t* body, size_t n);
  bool handleMoov(const uint8_t* body, size_t n);
  bool handleMoof(const uint8_t* body, size_t n);
  bool handleMdat(const uint8_t* body, size_t n);
  bool fail(const std::string& why);

  Bytes buf_;
  std::string error_;
  bool failed_ = false;
  bool configured_ = false;
  Config config_;
  int nal_len_size_ = 4;
  std::vector<TrunSample> pending_;
  std::vector<int64_t> capture_times_;
  uint64_t next_dts_ = 0;
  bool have_tfdt_ = false;
  uint64_t samples_ = 0;
};

}  // namespace fmp4
}  // namespace db
