
#include "media/frame_bus.h"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <vector>

#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBI_WRITE_NO_STDIO
#if defined(__GNUC__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wmissing-field-initializers"
#endif
#include "stb_image_write.h"
#if defined(__GNUC__)
#pragma GCC diagnostic pop
#endif

namespace db {

namespace {

int64_t steadyNowMs() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

inline uint8_t clamp8(int v) {
  return static_cast<uint8_t>(v < 0 ? 0 : (v > 255 ? 255 : v));
}


inline void yuvToRgb(int y, int u, int v, uint8_t* rgb) {
  int c = y - 16, d = u - 128, e = v - 128;
  rgb[0] = clamp8((298 * c + 409 * e + 128) >> 8);
  rgb[1] = clamp8((298 * c - 100 * d - 208 * e + 128) >> 8);
  rgb[2] = clamp8((298 * c + 516 * d + 128) >> 8);
}


void nvToRgb(const uint8_t* data, int w, int h, int stride, bool vu, uint8_t* out) {
  const uint8_t* yp = data;
  const uint8_t* uvp = data + static_cast<size_t>(stride) * h;
  for (int r = 0; r < h; r++) {
    const uint8_t* yrow = yp + static_cast<size_t>(r) * stride;
    const uint8_t* uvrow = uvp + static_cast<size_t>(r / 2) * stride;
    uint8_t* orow = out + static_cast<size_t>(r) * w * 3;
    for (int c = 0; c < w; c++) {
      int ci = (c / 2) * 2;
      int u = vu ? uvrow[ci + 1] : uvrow[ci];
      int v = vu ? uvrow[ci] : uvrow[ci + 1];
      yuvToRgb(yrow[c], u, v, orow + c * 3);
    }
  }
}


void yuy2ToRgb(const uint8_t* data, int w, int h, int stride, uint8_t* out) {
  for (int r = 0; r < h; r++) {
    const uint8_t* row = data + static_cast<size_t>(r) * stride;
    uint8_t* orow = out + static_cast<size_t>(r) * w * 3;
    for (int c = 0; c < w; c++) {
      const uint8_t* q = row + (c / 2) * 4;
      yuvToRgb(q[(c & 1) * 2], q[1], q[3], orow + c * 3);
    }
  }
}

void bgraToRgb(const uint8_t* data, int w, int h, int stride, uint8_t* out) {
  for (int r = 0; r < h; r++) {
    const uint8_t* row = data + static_cast<size_t>(r) * stride;
    uint8_t* orow = out + static_cast<size_t>(r) * w * 3;
    for (int c = 0; c < w; c++) {
      orow[c * 3 + 0] = row[c * 4 + 2];  // R
      orow[c * 3 + 1] = row[c * 4 + 1];  // G
      orow[c * 3 + 2] = row[c * 4 + 0];  // B
    }
  }
}


void halveRgb(std::vector<uint8_t>& rgb, int& w, int& h) {
  int nw = w / 2 > 0 ? w / 2 : 1;
  int nh = h / 2 > 0 ? h / 2 : 1;
  std::vector<uint8_t> out(static_cast<size_t>(nw) * nh * 3);
  for (int r = 0; r < nh; r++) {
    const uint8_t* r0 = rgb.data() + static_cast<size_t>(r * 2) * w * 3;
    const uint8_t* r1 = (r * 2 + 1 < h) ? r0 + static_cast<size_t>(w) * 3 : r0;
    uint8_t* orow = out.data() + static_cast<size_t>(r) * nw * 3;
    for (int c = 0; c < nw; c++) {
      int c0 = c * 2 * 3;
      int c1 = (c * 2 + 1 < w) ? c0 + 3 : c0;
      for (int k = 0; k < 3; k++) {
        orow[c * 3 + k] = static_cast<uint8_t>(
            (r0[c0 + k] + r0[c1 + k] + r1[c0 + k] + r1[c1 + k] + 2) / 4);
      }
    }
  }
  rgb.swap(out);
  w = nw;
  h = nh;
}

void appendBytes(void* ctx, void* data, int size) {
  auto* out = static_cast<Bytes*>(ctx);
  const auto* p = static_cast<const uint8_t*>(data);
  out->insert(out->end(), p, p + size);
}

}  // namespace

FrameBus::~FrameBus() { setWarmCacheFps(0); }

size_t rawFrameBytes(int format, int w, int h, int stride) {
  size_t s = static_cast<size_t>(stride);
  switch (format) {
    case 0:  // NV21
    case 1:  // NV12
      if (!s) s = static_cast<size_t>(w);
      return s * h + s * ((h + 1) / 2);
    case 2:  // YUY2
      if (!s) s = static_cast<size_t>(w) * 2;
      return s * h;
    case 3:  // BGRA
      if (!s) s = static_cast<size_t>(w) * 4;
      return s * h;
    default:
      return 0;
  }
}

void FrameBus::push(RawFrame&& f) {
  if (f.w <= 0 || f.h <= 0) return;
  if (f.stride == 0) {
    f.stride = f.format == 2 ? f.w * 2 : (f.format == 3 ? f.w * 4 : f.w);
  }
  size_t need = rawFrameBytes(f.format, f.w, f.h, f.stride);
  if (need == 0 || f.data.size() < need) return;
  std::lock_guard<std::mutex> lk(mu_);
  latest_ = std::move(f);
  seq_++;
  warm_cv_.notify_all();
}

Bytes FrameBus::latestJpeg() { return latestJpeg(nullptr); }

Bytes FrameBus::latestJpeg(int64_t* capture_ts_ms) {
  std::lock_guard<std::mutex> lk(mu_);
  if (seq_ == 0) return {};
  if (capture_ts_ms) *capture_ts_ms = latest_.ts_ms;
  if (encoded_seq_ == seq_) return jpeg_cache_;


  int w = latest_.w, h = latest_.h;
  std::vector<uint8_t> rgb(static_cast<size_t>(w) * h * 3);
  switch (latest_.format) {
    case 0: nvToRgb(latest_.data.data(), w, h, latest_.stride, true, rgb.data()); break;
    case 1: nvToRgb(latest_.data.data(), w, h, latest_.stride, false, rgb.data()); break;
    case 2: yuy2ToRgb(latest_.data.data(), w, h, latest_.stride, rgb.data()); break;
    case 3: bgraToRgb(latest_.data.data(), w, h, latest_.stride, rgb.data()); break;
    default: return {};
  }


  while (max_width_ > 0 && w > max_width_ && w >= 2 && h >= 2) halveRgb(rgb, w, h);


  Bytes jpeg;
  if (external_) jpeg = external_(rgb.data(), w, h, quality_);
  if (jpeg.empty()) {
    stbi_write_jpg_to_func(&appendBytes, &jpeg, w, h, 3, rgb.data(), quality_);
  }
  if (jpeg.empty()) return {};

  jpeg_cache_ = std::move(jpeg);
  encoded_seq_ = seq_;
  encoded_capture_ts_ms_ = latest_.ts_ms;
  encoded_at_steady_ms_ = steadyNowMs();
  encode_count_++;
  return jpeg_cache_;
}

Bytes FrameBus::previewJpeg(int64_t* capture_ts_ms) {
  {
    std::lock_guard<std::mutex> lk(mu_);
    const int64_t age_ms = steadyNowMs() - encoded_at_steady_ms_;
    if (!jpeg_cache_.empty() && encoded_at_steady_ms_ > 0 && age_ms >= 0 && age_ms <= 250) {
      if (capture_ts_ms) *capture_ts_ms = encoded_capture_ts_ms_;
      return jpeg_cache_;
    }
  }
  return latestJpeg(capture_ts_ms);
}

void FrameBus::setWarmCacheFps(int fps) {
  fps = std::max(0, std::min(fps, 15));
  std::thread stopped;
  {
    std::lock_guard<std::mutex> lk(mu_);
    warm_fps_ = fps;
    if (fps > 0 && !warm_thread_.joinable()) {
      warm_stop_ = false;
      warm_thread_ = std::thread([this] {
        auto next = std::chrono::steady_clock::now();
        for (;;) {
          int active_fps = 0;
          {
            std::unique_lock<std::mutex> lk(mu_);
            warm_cv_.wait_until(lk, next, [this] {
              return warm_stop_ || (warm_fps_ > 0 && seq_ != encoded_seq_);
            });
            if (warm_stop_) return;
            active_fps = warm_fps_;
          }
          if (active_fps <= 0) continue;
          const auto now = std::chrono::steady_clock::now();
          if (now < next) {
            std::this_thread::sleep_until(next);
          }
          latestJpeg();
          next = std::chrono::steady_clock::now() +
              std::chrono::milliseconds(1000 / active_fps);
        }
      });
    } else if (fps == 0 && warm_thread_.joinable()) {
      warm_stop_ = true;
      warm_cv_.notify_all();
      stopped = std::move(warm_thread_);
    }
  }
  if (stopped.joinable()) stopped.join();
}

void FrameBus::setJpegParams(int quality, int max_width) {
  {
    std::lock_guard<std::mutex> lk(mu_);
    if (quality < 1) quality = 1;
    if (quality > 100) quality = 100;
    if (quality_ != quality || max_width_ != max_width) {
      encoded_seq_ = 0;
      encoded_at_steady_ms_ = 0;
    }
    quality_ = quality;
    max_width_ = max_width;
  }
  warm_cv_.notify_all();
}

void FrameBus::setExternalEncoder(ExternalEncoder fn) {
  {
    std::lock_guard<std::mutex> lk(mu_);
    external_ = std::move(fn);
    encoded_seq_ = 0;
    encoded_at_steady_ms_ = 0;
  }
  warm_cv_.notify_all();
}

uint64_t FrameBus::frameCount() const {
  std::lock_guard<std::mutex> lk(mu_);
  return seq_;
}

uint64_t FrameBus::encodeCount() const {
  std::lock_guard<std::mutex> lk(mu_);
  return encode_count_;
}

}  // namespace db
