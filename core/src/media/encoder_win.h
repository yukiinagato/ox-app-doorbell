





// Windows Media Foundation H.264 encoder. A bounded two-frame queue feeds a dedicated encoder
// thread; overflow drops the oldest frame because this path is live-only.
#pragma once

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <mutex>
#include <thread>

#include "media/frame_bus.h"

namespace db {

class EncoderWin {
 public:
  struct Params {
    int fps = 25;
    int bitrate_kbps = 1500;  // config h264_bitrate_kbps
    int gop_s = 2;
  };

  using Output = std::function<void(const uint8_t* annexb, size_t len, bool key, int64_t ts_ms)>;

  explicit EncoderWin(Output out) : out_(std::move(out)) {}
  ~EncoderWin() { stop(); }

  EncoderWin(const EncoderWin&) = delete;
  EncoderWin& operator=(const EncoderWin&) = delete;



  void start(const Params& p);
  void stop();
  bool running() const { return running_.load(); }

  // Thread-safe edge consumed by the encoder thread once its MFT is ready.
  void requestKeyFrame() { keyframe_requested_.store(true); }



  void feed(const RawFrame& f);

 private:
  void run();
  bool popFrame(RawFrame* out, int timeout_ms);

  Output out_;
  Params params_;
  std::thread th_;
  std::atomic<bool> running_{false};
  std::atomic<bool> keyframe_requested_{false};
  std::mutex mu_;
  std::condition_variable cv_;
  std::deque<RawFrame> queue_;
  int64_t last_fed_ms_ = 0;
};

}  // namespace db
