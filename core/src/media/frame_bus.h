




// Thread-safe latest-frame slot with demand-driven JPEG conversion and one-frame caching.
#pragma once

#include <cstdint>
#include <functional>
#include <mutex>

#include "util/common.h"

namespace db {


// Formats: 0=NV21, 1=NV12, 2=YUY2, 3=BGRA.
struct RawFrame {
  int format = 0;
  int w = 0, h = 0;
  int stride = 0;
  int64_t ts_ms = 0;
  Bytes data;
};


size_t rawFrameBytes(int format, int w, int h, int stride);

class FrameBus {
 public:


  using ExternalEncoder = std::function<Bytes(const uint8_t* rgb, int w, int h, int quality)>;


  // Replaces the current frame without encoding; undersized buffers are rejected.
  void push(RawFrame&& f);



  Bytes latestJpeg();
  Bytes latestJpeg(int64_t* capture_ts_ms);


  void setJpegParams(int quality, int max_width);
  void setExternalEncoder(ExternalEncoder fn);


  uint64_t frameCount() const;
  uint64_t encodeCount() const;

 private:
  mutable std::mutex mu_;
  RawFrame latest_;
  uint64_t seq_ = 0;
  uint64_t encoded_seq_ = 0;
  uint64_t encode_count_ = 0;
  Bytes jpeg_cache_;
  int quality_ = 60;
  int max_width_ = 640;
  ExternalEncoder external_;
};

}  // namespace db
