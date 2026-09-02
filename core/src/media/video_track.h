







// Thread-safe live H.264 fan-out. It retains only the latest fMP4 fragment, so slow subscribers
// drop forward and recover at the next random-access point; it is not a recorder.
#pragma once

#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "media/fmp4.h"
#include "util/common.h"

namespace db {

class VideoTrack {
  struct State;

 public:
  VideoTrack();
  ~VideoTrack();



  // Disabling wakes subscribers and discards SPS/PPS and sequence state.
  void setEnabled(bool on);
  bool enabled() const;




  void push(const uint8_t* annexb, size_t len, bool key, int64_t ts_ms);


  void stop();

  bool active() const;
  int subscriberCount() const;
  std::string codecString() const;

  // Publish-side counters for the debug line. These describe what this node produced and handed
  // out, not what a receiver managed to display: latency, jitter and displayed frames belong to
  // each shell's own player and are reported through its runtime status instead.
  struct Stats {
    uint64_t frames = 0;          // access units accepted
    uint64_t keyframes = 0;
    uint64_t fragments = 0;       // fMP4 fragments published
    uint64_t dropped_forward = 0; // fragments a slow subscriber skipped past
    uint32_t frame_interval_ms = 0;
    int64_t last_frame_ts_ms = 0;
  };
  Stats stats() const;






  class Reader {
   public:
    explicit Reader(std::shared_ptr<State> st);
    ~Reader();
    Reader(const Reader&) = delete;
    Reader& operator=(const Reader&) = delete;
    // Returns init data first, then new fragments; ended signals generation change or shutdown.
    Bytes pull(int timeout_ms, bool* ended);

   private:
    std::shared_ptr<State> st_;
    uint64_t generation_ = 0;
    bool init_sent_ = false;
    uint64_t last_frag_ = 0;
  };
  std::shared_ptr<Reader> subscribe();

 private:
  std::shared_ptr<State> st_;
};

}  // namespace db
