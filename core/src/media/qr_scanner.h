// QR decoding for the pairing flow. One decoder serves every camera platform: shells keep feeding
// the frames they already push to the core, and the core answers with decoded text.
//
// Decoding never runs on the caller's thread. QrScanner owns a worker that takes the most recent
// submitted frame, converts it to 8-bit luma, and runs quirc at most ten times a second.
#pragma once

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "media/frame_bus.h"

namespace db {

// Decode one 8-bit grayscale image. Returns true and assigns the payload on success.
bool qrDecodeGray(const uint8_t* gray, int w, int h, std::string* text);

// Convert a camera frame (NV21/NV12/YUY2/BGRA) to 8-bit luma, halving until at most
// kQrMaxWidth pixels wide. Returns false for an unknown format or an undersized buffer.
constexpr int kQrMaxWidth = 1280;
bool rawFrameToLuma(const RawFrame& frame, std::vector<uint8_t>* luma, int* out_w, int* out_h);

class QrScanner {
 public:
  using DecodeCb = std::function<void(const std::string& text)>;

  ~QrScanner();

  // The callback runs on the scanner thread; marshal to Runloop before touching node state.
  void start(DecodeCb cb);
  void stop();
  bool active() const { return active_.load(); }

  // Called from whichever thread delivers camera frames. Copies at most one frame and returns.
  void submit(const RawFrame& frame);

  // Distinct decoded text is reported at most once per debounce window.
  static constexpr int64_t kDebounceMs = 2000;
  static constexpr int64_t kMinFrameIntervalMs = 100;  // ten frames per second

 private:
  void run();

  std::atomic<bool> active_{false};
  std::atomic<bool> stopping_{false};
  std::thread worker_;
  std::mutex mu_;
  std::condition_variable cv_;
  RawFrame queued_;
  bool has_frame_ = false;
  DecodeCb cb_;
  int64_t last_frame_ms_ = 0;
  std::string last_text_;
  int64_t last_text_ms_ = 0;
};

}  // namespace db
