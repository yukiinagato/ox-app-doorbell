#include "media/qr_scanner.h"

#include <chrono>
#include <cstring>
#include <memory>

#include "quirc.h"

namespace db {

namespace {

int64_t steadyMs() {
  using namespace std::chrono;
  return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

// quirc_code and quirc_data are several kilobytes each, so they live on the heap.
struct DecodeScratch {
  quirc_code code{};
  quirc_data data{};
};

bool decodeWith(quirc* q, const uint8_t* gray, int w, int h, std::string* text) {
  if (!q || !gray || w <= 0 || h <= 0) return false;
  if (quirc_resize(q, w, h) < 0) return false;
  int qw = 0, qh = 0;
  uint8_t* image = quirc_begin(q, &qw, &qh);
  if (!image || qw != w || qh != h) return false;
  std::memcpy(image, gray, static_cast<size_t>(w) * static_cast<size_t>(h));
  quirc_end(q);

  const int found = quirc_count(q);
  auto scratch = std::unique_ptr<DecodeScratch>(new DecodeScratch());
  for (int i = 0; i < found; i++) {
    quirc_extract(q, i, &scratch->code);
    if (quirc_decode(&scratch->code, &scratch->data) != QUIRC_SUCCESS) continue;
    const int len = scratch->data.payload_len;
    if (len <= 0) continue;
    text->assign(reinterpret_cast<const char*>(scratch->data.payload),
                 static_cast<size_t>(len));
    return true;
  }
  return false;
}


// Nearest-neighbour halving keeps the finder patterns square and costs one pass.
void halveLuma(std::vector<uint8_t>& luma, int& w, int& h) {
  const int nw = w / 2 > 0 ? w / 2 : 1;
  const int nh = h / 2 > 0 ? h / 2 : 1;
  std::vector<uint8_t> out(static_cast<size_t>(nw) * nh);
  for (int r = 0; r < nh; r++) {
    const uint8_t* r0 = luma.data() + static_cast<size_t>(r * 2) * w;
    const uint8_t* r1 = (r * 2 + 1 < h) ? r0 + w : r0;
    uint8_t* orow = out.data() + static_cast<size_t>(r) * nw;
    for (int c = 0; c < nw; c++) {
      const int c0 = c * 2;
      const int c1 = (c * 2 + 1 < w) ? c0 + 1 : c0;
      orow[c] = static_cast<uint8_t>((r0[c0] + r0[c1] + r1[c0] + r1[c1] + 2) / 4);
    }
  }
  luma.swap(out);
  w = nw;
  h = nh;
}

}  // namespace


bool qrDecodeGray(const uint8_t* gray, int w, int h, std::string* text) {
  if (!gray || !text || w <= 0 || h <= 0) return false;
  quirc* q = quirc_new();
  if (!q) return false;
  const bool ok = decodeWith(q, gray, w, h, text);
  quirc_destroy(q);
  return ok;
}


bool rawFrameToLuma(const RawFrame& frame, std::vector<uint8_t>* luma, int* out_w, int* out_h) {
  if (!luma || frame.w <= 0 || frame.h <= 0) return false;
  int stride = frame.stride;
  if (stride <= 0) {
    switch (frame.format) {
      case 0:
      case 1: stride = frame.w; break;
      case 2: stride = frame.w * 2; break;
      case 3: stride = frame.w * 4; break;
      default: return false;
    }
  }
  if (frame.data.size() < rawFrameBytes(frame.format, frame.w, frame.h, stride)) return false;

  int w = frame.w, h = frame.h;
  luma->assign(static_cast<size_t>(w) * h, 0);
  const uint8_t* src = frame.data.data();
  for (int r = 0; r < h; r++) {
    const uint8_t* row = src + static_cast<size_t>(r) * stride;
    uint8_t* orow = luma->data() + static_cast<size_t>(r) * w;
    switch (frame.format) {
      case 0:  // NV21: the luma plane comes first, so it is already what quirc wants.
      case 1:  // NV12
        std::memcpy(orow, row, static_cast<size_t>(w));
        break;
      case 2:  // YUY2: Y0 U Y1 V
        for (int c = 0; c < w; c++) orow[c] = row[static_cast<size_t>(c) * 2];
        break;
      case 3:  // BGRA
        for (int c = 0; c < w; c++) {
          const uint8_t* p = row + static_cast<size_t>(c) * 4;
          orow[c] = static_cast<uint8_t>((p[0] * 29 + p[1] * 150 + p[2] * 77) >> 8);
        }
        break;
      default:
        return false;
    }
  }
  while (w > kQrMaxWidth) halveLuma(*luma, w, h);
  if (out_w) *out_w = w;
  if (out_h) *out_h = h;
  return true;
}


QrScanner::~QrScanner() { stop(); }

void QrScanner::start(DecodeCb cb) {
  if (active_.load()) return;
  {
    std::lock_guard<std::mutex> lk(mu_);
    cb_ = std::move(cb);
    has_frame_ = false;
    last_frame_ms_ = 0;
    last_text_.clear();
    last_text_ms_ = 0;
  }
  stopping_.store(false);
  active_.store(true);
  worker_ = std::thread([this] { run(); });
}

void QrScanner::stop() {
  if (!active_.load() && !worker_.joinable()) return;
  active_.store(false);
  stopping_.store(true);
  cv_.notify_all();
  if (worker_.joinable()) worker_.join();
  std::lock_guard<std::mutex> lk(mu_);
  cb_ = nullptr;
  queued_ = RawFrame{};
  has_frame_ = false;
}

void QrScanner::submit(const RawFrame& frame) {
  if (!active_.load()) return;
  const int64_t now = steadyMs();
  {
    std::lock_guard<std::mutex> lk(mu_);
    // Decoding is far slower than capture; sampling keeps the worker at ten frames per second
    // and the caller's thread free.
    if (now - last_frame_ms_ < kMinFrameIntervalMs) return;
    last_frame_ms_ = now;
    queued_ = frame;
    has_frame_ = true;
  }
  cv_.notify_one();
}

void QrScanner::run() {
  quirc* q = quirc_new();
  std::vector<uint8_t> luma;
  while (!stopping_.load()) {
    RawFrame frame;
    DecodeCb cb;
    {
      std::unique_lock<std::mutex> lk(mu_);
      cv_.wait_for(lk, std::chrono::milliseconds(100),
                   [this] { return has_frame_ || stopping_.load(); });
      if (stopping_.load()) break;
      if (!has_frame_) continue;
      has_frame_ = false;
      frame = std::move(queued_);
      queued_ = RawFrame{};
      cb = cb_;
    }
    int w = 0, h = 0;
    if (!rawFrameToLuma(frame, &luma, &w, &h)) continue;
    std::string text;
    if (!decodeWith(q, luma.data(), w, h, &text)) continue;

    const int64_t now = steadyMs();
    {
      std::lock_guard<std::mutex> lk(mu_);
      // The same code stays in front of the camera for many frames; report it once.
      if (text == last_text_ && now - last_text_ms_ < kDebounceMs) continue;
      last_text_ = text;
      last_text_ms_ = now;
    }
    if (cb) cb(text);
  }
  if (q) quirc_destroy(q);
}

}  // namespace db
