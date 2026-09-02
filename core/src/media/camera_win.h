



// Windows Media Foundation camera capture. ReadSample runs on a dedicated thread; failures are
// reported without terminating the process and start/stop are restart-safe.
#pragma once

#include <atomic>
#include <functional>
#include <string>
#include <thread>

#include "media/frame_bus.h"

namespace db {

class CameraWin {
 public:

  // Called once per frame from the capture thread.
  using FrameSink = std::function<void(RawFrame&&)>;
  explicit CameraWin(FrameSink sink) : sink_(std::move(sink)) {}
  ~CameraWin() { stop(); }

  CameraWin(const CameraWin&) = delete;
  CameraWin& operator=(const CameraWin&) = delete;




  bool start(const std::string& device_hint, int target_w = 640, int target_h = 480);
  void stop();
  bool running() const { return running_.load(); }

 private:
  void run(std::string hint, int tw, int th);

  FrameSink sink_;
  std::thread th_;
  std::atomic<bool> running_{false};
};

}  // namespace db
