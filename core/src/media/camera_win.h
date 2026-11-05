// Windows Media Foundation camera capture. Capture runs on a dedicated thread that keeps the
// device open, reopens it with bounded backoff after a failure, an unplug or a missing device,
// and reports failures without terminating the process.
//
// Lifetime: the capture thread owns a shared State, not the CameraWin object. stop() marks the
// state stopped, shuts the media source down so a blocked ReadSample returns, and waits a bounded
// time for the thread. A thread still stuck in a driver after that is detached; it can no longer
// reach the sink, because every sink call happens under State::sink_mu after a stopped check, and
// stop() acquires that mutex after setting stopped.
#pragma once

#include <functional>
#include <memory>
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

  // Starts the capture thread. Returns true when the thread was created; whether a device is
  // actually delivering frames is reported by capturing().
  bool start(const std::string& device_hint, int target_w = 640, int target_h = 480);
  // Bounded: returns within about three seconds even if the driver blocks.
  void stop();
  // True while the capture thread is alive and has not been told to stop.
  bool running() const;
  // True while a device is open and delivering samples.
  bool capturing() const;

  struct State;

 private:
  FrameSink sink_;
  std::shared_ptr<State> state_;
  std::thread th_;
};

}  // namespace db
