

#include "media/video_track.h"

#include <algorithm>
#include <chrono>

#include "util/log.h"

namespace db {

namespace {
constexpr const char* kTag = "video";

uint32_t clampDur(int64_t d) {
  if (d < 1) return 1;
  if (d > 1000) return 1000;
  return static_cast<uint32_t>(d);
}

// Private top-level box consumed by the kiosk's direct decoder. Generic fMP4
// players safely skip it. Payload: sample_count (u32), then capture epoch ms
// (u64) for each sample in the following moof/mdat.
Bytes withCaptureTimes(Bytes fragment, const std::vector<fmp4::Sample>& samples) {
  Bytes out;
  const uint32_t size = static_cast<uint32_t>(12 + samples.size() * 8);
  out.reserve(size + fragment.size());
  auto put32 = [&out](uint32_t v) {
    out.push_back(static_cast<uint8_t>(v >> 24));
    out.push_back(static_cast<uint8_t>(v >> 16));
    out.push_back(static_cast<uint8_t>(v >> 8));
    out.push_back(static_cast<uint8_t>(v));
  };
  put32(size);
  out.insert(out.end(), {'d', 'b', 't', 's'});
  put32(static_cast<uint32_t>(samples.size()));
  for (const auto& sample : samples) {
    uint64_t v = static_cast<uint64_t>(sample.ts_ms);
    for (int i = 7; i >= 0; --i)
      out.push_back(static_cast<uint8_t>(v >> (i * 8)));
  }
  out.insert(out.end(), fragment.begin(), fragment.end());
  return out;
}
}  // namespace

struct VideoTrack::State {
  std::mutex mu;
  std::condition_variable cv;
  bool enabled = false;
  bool stopped = false;
  uint64_t generation = 0;
  int subscribers = 0;

  Bytes sps, pps;
  Bytes init;
  std::string codec_str;

  int64_t last_ts_ms = 0;
  uint32_t frame_dur_ms = 33;
  bool have_last_ts = false;
  uint64_t frag_seq = 0;
  Bytes frag;
  uint64_t key_frag_seq = 0;
  Bytes key_frag;
  uint64_t base_dt = 0;
  bool keyframe_request_pending = false;

  // Counters for the debug line. They are cumulative for the life of the track and are not
  // cleared by resetLocked(), so a mid-stream SPS change does not look like a restart.
  uint64_t frames = 0;
  uint64_t keyframes = 0;
  uint64_t dropped_forward = 0;
  uint64_t keyframe_requests = 0;


  void resetLocked() {
    generation++;
    sps.clear();
    pps.clear();
    init.clear();
    codec_str.clear();
    last_ts_ms = 0;
    frame_dur_ms = 33;
    have_last_ts = false;
    frag_seq = 0;
    frag.clear();
    key_frag_seq = 0;
    key_frag.clear();
    keyframe_request_pending = false;
    base_dt = 0;
  }
};

VideoTrack::VideoTrack() : st_(std::make_shared<State>()) {}

VideoTrack::~VideoTrack() { stop(); }

void VideoTrack::setEnabled(bool on) {
  std::lock_guard<std::mutex> lk(st_->mu);
  if (on) st_->stopped = false;
  if (st_->enabled == on) return;
  st_->enabled = on;
  if (!on) {
    st_->resetLocked();
    st_->cv.notify_all();
    DB_LOGI(kTag, "H.264 track disabled because codec=mjpeg");
  }
}

bool VideoTrack::enabled() const {
  std::lock_guard<std::mutex> lk(st_->mu);
  return st_->enabled;
}

void VideoTrack::push(const uint8_t* annexb, size_t len, bool key, int64_t ts_ms) {
  if (!annexb || len == 0) return;
  std::lock_guard<std::mutex> lk(st_->mu);
  State& s = *st_;
  if (!s.enabled || s.stopped) return;

  const Bytes old_sps = s.sps;
  fmp4::Sample sample = fmp4::toSample(annexb, len, &s.sps, &s.pps);


  if (!s.init.empty() && !old_sps.empty() && s.sps != old_sps) {
    Bytes new_sps = s.sps, new_pps = s.pps;
    s.resetLocked();
    s.sps = std::move(new_sps);
    s.pps = std::move(new_pps);
    s.cv.notify_all();
    DB_LOGI(kTag, "SPS changed; restarting the H.264 stream");
  }
  if (s.init.empty() && !s.sps.empty() && !s.pps.empty()) {
    s.init = fmp4::buildInit(s.sps, s.pps);
    s.codec_str = fmp4::codecString(s.sps);
    s.cv.notify_all();
    DB_LOGI(kTag, "generated H.264 init segment (" + s.codec_str + ")");
  }
  if (sample.data.empty()) return;
  sample.key = sample.key || key;
  sample.ts_ms = ts_ms;
  s.frames++;
  if (sample.key) s.keyframes++;

  // Ultra-low-latency live mode: publish the current access unit immediately.
  // Its duration is inferred from the previous capture interval. Waiting for
  // the next timestamp made every frame one whole frame late (33--60ms on the
  // door station), while duration is only timeline metadata for this live path.
  if (s.have_last_ts) s.frame_dur_ms = clampDur(ts_ms - s.last_ts_ms);
  sample.dur = s.frame_dur_ms;
  s.last_ts_ms = ts_ms;
  s.have_last_ts = true;

  std::vector<fmp4::Sample> current;
  current.push_back(std::move(sample));
  s.frag = withCaptureTimes(
      fmp4::buildFragment(static_cast<uint32_t>(++s.frag_seq), s.base_dt, current),
      current);
  if (current[0].key) {
    s.key_frag_seq = s.frag_seq;
    s.key_frag = s.frag;
  }
  s.base_dt += current[0].dur;
  s.cv.notify_all();
}

bool VideoTrack::takeKeyframeRequest() {
  std::lock_guard<std::mutex> lk(st_->mu);
  if (!st_->keyframe_request_pending) return false;
  st_->keyframe_request_pending = false;
  return true;
}

void VideoTrack::stop() {
  std::lock_guard<std::mutex> lk(st_->mu);
  st_->stopped = true;
  st_->cv.notify_all();
}

bool VideoTrack::active() const {
  std::lock_guard<std::mutex> lk(st_->mu);
  return st_->enabled && !st_->init.empty();
}

int VideoTrack::subscriberCount() const {
  std::lock_guard<std::mutex> lk(st_->mu);
  return st_->subscribers;
}

std::string VideoTrack::codecString() const {
  std::lock_guard<std::mutex> lk(st_->mu);
  return st_->codec_str;
}

std::shared_ptr<VideoTrack::Reader> VideoTrack::subscribe() {
  auto reader = std::make_shared<Reader>(st_);
  {
    std::lock_guard<std::mutex> lk(st_->mu);
    if (st_->enabled && !st_->stopped) {
      st_->keyframe_request_pending = true;
      st_->keyframe_requests++;
    }
  }
  st_->cv.notify_all();
  return reader;
}

// ---------- Reader ----------

VideoTrack::Reader::Reader(std::shared_ptr<State> st) : st_(std::move(st)) {
  std::lock_guard<std::mutex> lk(st_->mu);
  generation_ = st_->generation;
  subscribed_key_seq_ = st_->key_frag_seq;
  st_->subscribers++;
}

VideoTrack::Reader::~Reader() {
  std::lock_guard<std::mutex> lk(st_->mu);
  st_->subscribers--;
}

Bytes VideoTrack::Reader::pull(int timeout_ms, bool* ended) {
  *ended = false;
  std::unique_lock<std::mutex> lk(st_->mu);
  State& s = *st_;
  auto ready = [&] {
    if (s.stopped || s.generation != generation_ || !s.enabled) return true;
    if (!init_sent_) return !s.init.empty();
    if (key_pending_) return !s.key_frag.empty();
    if (waiting_for_fresh_key_) return s.key_frag_seq > last_frag_;
    return s.frag_seq > last_frag_;
  };
  if (!ready()) s.cv.wait_for(lk, std::chrono::milliseconds(timeout_ms), ready);
  if (s.stopped || s.generation != generation_ || !s.enabled) {
    *ended = true;
    return {};
  }
  if (!init_sent_) {
    if (s.init.empty()) return {};
    init_sent_ = true;
    return s.init;
  }
  if (key_pending_) {
    if (s.key_frag.empty()) return {};
    key_pending_ = false;
    last_frag_ = s.key_frag_seq;
    // If this random-access point predates the subscription, keep it on screen as the immediate
    // preview but do not feed dependency-breaking delta frames. Resume on the requested fresh IDR.
    waiting_for_fresh_key_ = subscribed_key_seq_ != 0 && s.key_frag_seq <= subscribed_key_seq_;
    return s.key_frag;
  }
  if (waiting_for_fresh_key_) {
    if (s.key_frag_seq <= last_frag_) return {};
    waiting_for_fresh_key_ = false;
    last_frag_ = s.key_frag_seq;
    return s.key_frag;
  }
  if (s.frag_seq > last_frag_) {
    // Only the newest fragment is retained, so a subscriber that fell behind skips the ones in
    // between. That is the design, and counting the skips is what makes it visible.
    if (s.frag_seq > last_frag_ + 1) s.dropped_forward += s.frag_seq - last_frag_ - 1;
    last_frag_ = s.frag_seq;
    return s.frag;
  }
  return {};
}

VideoTrack::Stats VideoTrack::stats() const {
  std::lock_guard<std::mutex> lk(st_->mu);
  Stats out;
  out.frames = st_->frames;
  out.keyframes = st_->keyframes;
  out.fragments = st_->frag_seq;
  out.dropped_forward = st_->dropped_forward;
  out.keyframe_requests = st_->keyframe_requests;
  out.frame_interval_ms = st_->frame_dur_ms;
  out.last_frame_ts_ms = st_->last_ts_ms;
  return out;
}

}  // namespace db
