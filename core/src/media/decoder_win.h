// Windows Media Foundation H.264 decoder for the live fMP4 path. The WPF MediaElement/WMP HTTP
// source needs seconds to open the door station's endless stream (measured 4.5 s on the
// Toughpad); this feeds the demuxed access units straight into the H.264 decoder MFT in
// low-latency mode and hands BGRA frames to the shell, so the first picture is a matter of a
// few frames, not of a download heuristic. A bounded queue keeps the path live-only: overflow
// drops to the next random-access point instead of accumulating delay.
#pragma once

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <thread>

#include "media/fmp4_demux.h"
#include "util/common.h"

namespace db {

class DecoderWin {
 public:
  struct Frame {
    const uint8_t* bgra = nullptr;  // top-down BGRA, valid only during the callback
    int width = 0;
    int height = 0;
    int stride = 0;
    int64_t capture_ms = 0;
    uint64_t dts = 0;
  };
  using Output = std::function<void(const Frame&)>;
  // state: "configured" (detail = decoder label), "first_frame" (detail = ms since start),
  // "error" (detail = reason). Called on the decoder thread.
  using StateFn = std::function<void(const std::string& state, const std::string& detail)>;

  struct Stats {
    uint64_t received = 0;   // access units queued
    uint64_t decoded = 0;    // frames delivered
    uint64_t dropped = 0;    // access units discarded (overflow or waiting for a keyframe)
    uint64_t errors = 0;
    int width = 0;
    int height = 0;
    int first_frame_ms = -1;
    std::string decoder;
  };

  DecoderWin(Output out, StateFn state);
  ~DecoderWin();
  DecoderWin(const DecoderWin&) = delete;
  DecoderWin& operator=(const DecoderWin&) = delete;

  void start();
  void stop();
  bool running() const { return running_.load(); }

  // Thread-safe. A new configuration restarts the transform; the next unit must be a keyframe.
  void configure(const fmp4::Demuxer::Config& config);
  void feed(fmp4::Demuxer::AccessUnit&& au);
  Stats stats() const;

  static constexpr size_t kMaxQueued = 6;

 private:
  struct Item {
    bool is_config = false;
    fmp4::Demuxer::Config config;
    fmp4::Demuxer::AccessUnit au;
  };
  void run();
  bool pop(Item* out, int timeout_ms);

  Output out_;
  StateFn state_;
  std::thread th_;
  std::atomic<bool> running_{false};
  mutable std::mutex mu_;
  std::condition_variable cv_;
  std::deque<Item> queue_;
  bool wait_key_ = true;
  Stats stats_;
  std::chrono::steady_clock::time_point started_;
};

}  // namespace db
