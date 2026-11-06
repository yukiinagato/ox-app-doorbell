#pragma once

#include <atomic>
#include <condition_variable>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <thread>

#include "media/video_track.h"
#include "media/fmp4_demux.h"
#include "tls/tls.h"

namespace db {

// A lease owns one ordered fMP4 byte stream. Overflow terminates the lease
// instead of dropping dependent H.264 samples or unboundedly buffering video.
class StandbyLease {
 public:
  Bytes pull(int timeout_ms, bool* ended);
  bool awaitBegin(int timeout_ms);
  uint64_t token() const { return token_; }
  int64_t serverWallMs() const;
 private:
  friend class StandbyClient;
  explicit StandbyLease(uint64_t token);
  void accept(Bytes box);
  void finish();
  uint64_t token_;
  mutable std::mutex mu_;
  std::condition_variable cv_;
  std::deque<Bytes> queue_;
  size_t bytes_ = 0;
  bool ended_ = false, begun_ = false;
  int64_t server_wall_ms_ = 0, started_wall_ms_ = 0, clock_offset_ms_ = 0;
};

// Only the worker touches HttpStream. The owner must stop and join outside
// its state loop before destroying callbacks, sockets, or the run loop.
class StandbyClient {
 public:
  StandbyClient(tls::Endpoint endpoint, std::map<std::string, std::string> headers,
                std::string channel);
  ~StandbyClient();
  void start();
  void stop();
  void join();
  bool finished() const { return finished_.load(); }
  int status() const { return status_.load(); }
  bool ready() const;
  const std::string& channel() const { return channel_; }
  bool matches(const tls::Endpoint& endpoint) const;
  std::shared_ptr<StandbyLease> subscribe();
  uint64_t activeToken() const;
  int64_t idleAgeMs() const;
  int rotation() const { return rotation_.load(); }
  fmp4::Demuxer::Config decoderConfig() const;
 private:
  void run();
  tls::Endpoint endpoint_;
  std::map<std::string, std::string> headers_;
  std::string channel_;
  std::thread worker_;
  std::atomic<bool> stop_{false}, finished_{false}, ready_{false};
  std::atomic<int> rotation_{-1}, status_{0};
  std::atomic<int64_t> last_received_ms_{0}, connected_ms_{0};
  mutable std::mutex mu_;
  std::weak_ptr<StandbyLease> lease_;
  uint64_t next_token_ = 0;
  fmp4::Demuxer::Config decoder_config_;
};

class StandbyServer {
 public:
  struct Slot;
  std::shared_ptr<Slot> open(const std::string& owner, const std::string& channel,
                             VideoTrack& track);
  void command(const std::string& owner, const std::string& channel, uint64_t token);
  void retain(const std::set<std::string>& members);
  void clear();
  void setRotation(int rotation) { *rotation_ = rotation; }
  static Bytes pull(const std::shared_ptr<Slot>& slot, bool* ended);
 private:
  std::mutex mu_;
  std::map<std::string, std::shared_ptr<Slot>> slots_;
  std::shared_ptr<std::atomic<int>> rotation_ = std::make_shared<std::atomic<int>>(0);
};

}  // namespace db
