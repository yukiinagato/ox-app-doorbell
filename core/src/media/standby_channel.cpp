#include "media/standby_channel.h"

#include <algorithm>
#include <chrono>

namespace db {
namespace {
int64_t monoMs() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now().time_since_epoch()).count();
}
int64_t wallMs() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::system_clock::now().time_since_epoch()).count();
}
uint32_t be32(const uint8_t* p) {
  return uint32_t(p[0]) << 24 | uint32_t(p[1]) << 16 | uint32_t(p[2]) << 8 | p[3];
}
uint64_t be64(const uint8_t* p) { return uint64_t(be32(p)) << 32 | be32(p + 4); }
void put64(Bytes& b, uint64_t v) {
  for (int i = 7; i >= 0; --i) b.push_back(uint8_t(v >> (i * 8)));
}
Bytes heartbeat(int rotation) {
  return {0, 0, 0, 12, 'd', 'b', 'r', 't', 0, 0, uint8_t(rotation >> 8), uint8_t(rotation)};
}
}

StandbyLease::StandbyLease(uint64_t token) : token_(token), started_wall_ms_(wallMs()) {}

Bytes StandbyLease::pull(int timeout_ms, bool* ended) {
  std::unique_lock<std::mutex> lock(mu_);
  cv_.wait_for(lock, std::chrono::milliseconds(timeout_ms), [&] { return ended_ || !queue_.empty(); });
  *ended = ended_;
  if (ended_ || queue_.empty()) return {};
  Bytes box = std::move(queue_.front()); queue_.pop_front(); bytes_ -= box.size();
  return box;
}
bool StandbyLease::awaitBegin(int timeout_ms) {
  std::unique_lock<std::mutex> lock(mu_);
  cv_.wait_for(lock, std::chrono::milliseconds(timeout_ms), [&] { return ended_ || begun_; });
  return begun_ && !ended_;
}
int64_t StandbyLease::serverWallMs() const {
  std::lock_guard<std::mutex> lock(mu_); return begun_ ? wallMs() - clock_offset_ms_ : 0;
}
void StandbyLease::finish() {
  std::lock_guard<std::mutex> lock(mu_);
  ended_ = true; queue_.clear(); bytes_ = 0; cv_.notify_all();
}
void StandbyLease::accept(Bytes box) {
  std::lock_guard<std::mutex> lock(mu_);
  if (ended_) return;
  if (box.size() == 24 && be32(box.data() + 4) == 0x64626567) {
    begun_ = true; server_wall_ms_ = static_cast<int64_t>(be64(box.data() + 16));
    clock_offset_ms_ = started_wall_ms_ + (wallMs() - started_wall_ms_) / 2 - server_wall_ms_;
    cv_.notify_all(); return;
  }
  if (!begun_) return;
  if (bytes_ + box.size() > 4 * 1024 * 1024 || queue_.size() >= 128) {
    ended_ = true; queue_.clear(); bytes_ = 0;
  } else { bytes_ += box.size(); queue_.push_back(std::move(box)); }
  cv_.notify_all();
}
StandbyClient::StandbyClient(tls::Endpoint endpoint, std::map<std::string, std::string> headers,
                             std::string channel)
    : endpoint_(std::move(endpoint)), headers_(std::move(headers)), channel_(std::move(channel)) {}
StandbyClient::~StandbyClient() { stop(); join(); }
void StandbyClient::start() { worker_ = std::thread([this] { run(); }); }
void StandbyClient::stop() { stop_ = true; }
void StandbyClient::join() { if (worker_.joinable()) worker_.join(); }
bool StandbyClient::matches(const tls::Endpoint& e) const {
  return endpoint_.host == e.host && endpoint_.port == e.port && endpoint_.tls == e.tls &&
         endpoint_.pin_sha256 == e.pin_sha256;
}
bool StandbyClient::ready() const {
  return ready_.load() && !stop_.load() && monoMs() - last_received_ms_.load() < 6000;
}
int64_t StandbyClient::idleAgeMs() const {
  const int64_t at = connected_ms_; return at > 0 ? monoMs() - at : 0;
}
std::shared_ptr<StandbyLease> StandbyClient::subscribe() {
  std::lock_guard<std::mutex> lock(mu_);
  if (!ready() || !lease_.expired()) return {};
  auto lease = std::shared_ptr<StandbyLease>(new StandbyLease(++next_token_));
  lease_ = lease; return lease;
}
fmp4::Demuxer::Config StandbyClient::decoderConfig() const {
  std::lock_guard<std::mutex> lock(mu_); return decoder_config_;
}
uint64_t StandbyClient::activeToken() const {
  std::lock_guard<std::mutex> lock(mu_);
  auto lease = lease_.lock(); return lease ? lease->token() : 0;
}
void StandbyClient::run() {
  {
    tls::HttpStream stream(endpoint_, "/media-standby.mp4", headers_);
    const bool opened = stream.open(5000);
    status_ = stream.status();
    if (opened && stream.status() == 200 &&
        stream.header("content-type") == "application/x-doorbell-standby-v1") {
      connected_ms_ = monoMs(); last_received_ms_ = monoMs();
      Bytes pending;
      uint64_t token = 0;
      bool ended = false;
      while (!stop_.load() && !ended) {
        Bytes bytes = stream.pull(&ended);
        if (!bytes.empty()) last_received_ms_ = monoMs();
        if (monoMs() - last_received_ms_.load() > 6000) break;
        pending.insert(pending.end(), bytes.begin(), bytes.end());
        size_t offset = 0;
        while (pending.size() - offset >= 8) {
          const uint32_t size = be32(pending.data() + offset);
          if (size < 8 || size > 2 * 1024 * 1024) { ended = true; break; }
          if (pending.size() - offset < size) break;
          const uint32_t type = be32(pending.data() + offset + 4);
          if (type == 0x64627274) {
            if (size != 12) { ended = true; break; }
            const uint32_t rotation = be32(pending.data() + offset + 8);
            if (rotation != 0 && rotation != 90 && rotation != 180 && rotation != 270) { ended = true; break; }
            rotation_ = static_cast<int>(rotation); ready_ = true;
          }
          if (type == 0x6d6f6f76) {
            fmp4::Demuxer config;
            config.on_config = [this](const fmp4::Demuxer::Config& value) {
              std::lock_guard<std::mutex> lock(mu_); decoder_config_ = value;
            };
            if (!config.feed(pending.data() + offset, size)) { ended = true; break; }
          }
          if (type == 0x64626567) {
            if (size != 24) { ended = true; break; }
            token = be64(pending.data() + offset + 8);
          }
          if (type != 0x66726565 && type != 0x64627274) {
            std::shared_ptr<StandbyLease> lease;
            { std::lock_guard<std::mutex> lock(mu_); lease = lease_.lock(); }
            if (lease && lease->token() == token)
              lease->accept(Bytes(pending.begin() + offset, pending.begin() + offset + size));
          }
          offset += size;
        }
        pending.erase(pending.begin(), pending.begin() + offset);
        if (pending.size() > 2 * 1024 * 1024) break;
      }
    }
  }
  ready_ = false;
  { std::lock_guard<std::mutex> lock(mu_); if (auto lease = lease_.lock()) lease->finish(); }
  finished_ = true;
}

struct StandbyServer::Slot {
  Slot(std::string id, VideoTrack& source, std::shared_ptr<std::atomic<int>> angle)
      : channel(std::move(id)), track(source), rotation(std::move(angle)) {}
  std::mutex mu;
  std::condition_variable cv;
  std::string channel;
  VideoTrack& track;
  std::shared_ptr<std::atomic<int>> rotation;
  int last_rotation = -1;
  std::shared_ptr<VideoTrack::Reader> reader;
  uint64_t token = 0, announced = 0;
  int64_t expires_ms = 0;
  bool stopped = false, initial = true;
  Bytes announced_init;
  void stop() {
    std::lock_guard<std::mutex> lock(mu);
    stopped = true; reader.reset(); cv.notify_all();
  }
};
std::shared_ptr<StandbyServer::Slot> StandbyServer::open(
    const std::string& owner, const std::string& channel, VideoTrack& track) {
  std::lock_guard<std::mutex> lock(mu_);
  auto found = slots_.find(owner);
  if (found == slots_.end() && slots_.size() >= 8) return {};
  if (found != slots_.end()) found->second->stop();
  auto slot = std::make_shared<Slot>(channel, track, rotation_); slots_[owner] = slot; return slot;
}
void StandbyServer::command(const std::string& owner, const std::string& channel, uint64_t token) {
  std::lock_guard<std::mutex> lock(mu_);
  auto found = slots_.find(owner);
  if (found == slots_.end()) return;
  auto& slot = *found->second;
  std::lock_guard<std::mutex> state(slot.mu);
  if (slot.stopped || slot.channel != channel) return;
  if (slot.token != token) {
    slot.reader.reset(); slot.token = token;
    if (token) slot.reader = slot.track.subscribe(true);
  }
  slot.expires_ms = monoMs() + 15000; slot.cv.notify_all();
}
void StandbyServer::retain(const std::set<std::string>& members) {
  std::lock_guard<std::mutex> lock(mu_);
  for (auto it = slots_.begin(); it != slots_.end();) {
    if (!members.count(it->first)) { it->second->stop(); it = slots_.erase(it); }
    else {
      auto& slot = *it->second;
      std::lock_guard<std::mutex> state(slot.mu);
      if (slot.reader && monoMs() > slot.expires_ms) { slot.reader.reset(); slot.token = 0; }
      ++it;
    }
  }
}
void StandbyServer::clear() {
  std::lock_guard<std::mutex> lock(mu_);
  for (auto& item : slots_) item.second->stop();
  slots_.clear();
}
Bytes StandbyServer::pull(const std::shared_ptr<Slot>& slot, bool* ended) {
  *ended = false;
  std::shared_ptr<VideoTrack::Reader> reader;
  uint64_t token;
  {
    std::unique_lock<std::mutex> lock(slot->mu);
    const int rotation = slot->rotation->load();
    if (slot->initial || rotation != slot->last_rotation) {
      slot->initial = false; slot->last_rotation = rotation; return heartbeat(rotation);
    }
    if (slot->reader && monoMs() > slot->expires_ms) {
      slot->reader.reset(); slot->token = 0;
    }
    if (!slot->reader && !slot->stopped) {
      Bytes init = slot->track.initialization();
      if (!init.empty() && init != slot->announced_init) { slot->announced_init = init; return init; }
    }
    if (!slot->reader && !slot->stopped)
      slot->cv.wait_for(lock, std::chrono::seconds(1));
    if (slot->stopped) { *ended = true; return {}; }
    token = slot->token;
    reader = slot->reader;
    if (reader && slot->announced != token) {
      slot->announced = token;
      Bytes begin = {0, 0, 0, 24, 'd', 'b', 'e', 'g'};
      put64(begin, token); put64(begin, static_cast<uint64_t>(wallMs())); return begin;
    }
  }
  if (!reader) return heartbeat(slot->rotation->load());
  bool source_ended = false;
  Bytes bytes = reader->pull(500, &source_ended);
  std::lock_guard<std::mutex> lock(slot->mu);
  if (slot->stopped || source_ended) { *ended = true; return {}; }
  if (slot->token != token) return heartbeat(slot->rotation->load());
  return bytes.empty() ? heartbeat(slot->rotation->load()) : bytes;
}
}  // namespace db
