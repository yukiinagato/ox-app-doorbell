// VideoTrack 実装。状態 (State) は shared_ptr で Reader と共有 — Node 破棄と
// httpd ワーカーの生存順に依らずダングリングしない。
#include "media/video_track.h"

#include <algorithm>
#include <chrono>

#include "util/log.h"

namespace db {

namespace {
constexpr const char* kTag = "video";

uint32_t clampDur(int64_t d) {
  if (d < 1) return 1;        // 非増加 ts (時計巻き戻り等) でも前進させる
  if (d > 1000) return 1000;  // 長すぎる間隙 (エンコーダ停止明け) は 1s に丸める
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
  uint64_t generation = 0;  // setEnabled(false) / SPS 変化で +1 → 既存購読者は ended
  int subscribers = 0;

  Bytes sps, pps;
  Bytes init;  // init segment (SPS+PPS が揃った時点で生成)
  std::string codec_str;

  int64_t last_ts_ms = 0;             // 直前 access unit の採集時刻
  uint32_t frame_dur_ms = 33;         // 直前区間から推定 (初回のみ 30fps 扱い)
  bool have_last_ts = false;
  uint64_t frag_seq = 0;              // 直近 fragment の連番 (1 始まり)
  Bytes frag;                         // 直近 fragment (リングは 1 本のみ — ライブ専用)
  uint64_t base_dt = 0;               // 次 fragment の base media decode time (ms 累計)

  // ストリーム状態を捨てる (無効化 / SPS 変化時)。mu 保持前提。
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
    base_dt = 0;
  }
};

VideoTrack::VideoTrack() : st_(std::make_shared<State>()) {}

VideoTrack::~VideoTrack() { stop(); }

void VideoTrack::setEnabled(bool on) {
  std::lock_guard<std::mutex> lk(st_->mu);
  if (on) st_->stopped = false;  // Node 再 start 時の蘇生 (stop() 後の再有効化)
  if (st_->enabled == on) return;
  st_->enabled = on;
  if (!on) {
    st_->resetLocked();
    st_->cv.notify_all();
    DB_LOGI(kTag, "h264 track 無効化 (codec=mjpeg)");
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
  // SPS が変わった (解像度/プロファイル変更) → ストリーム仕切り直し。
  // 既存購読者は ended → クライアントが再接続して新 init を受け取る (自己修復)。
  if (!s.init.empty() && !old_sps.empty() && s.sps != old_sps) {
    Bytes new_sps = s.sps, new_pps = s.pps;
    s.resetLocked();
    s.sps = std::move(new_sps);
    s.pps = std::move(new_pps);
    s.cv.notify_all();
    DB_LOGI(kTag, "SPS 変化 — h264 ストリームを仕切り直し");
  }
  if (s.init.empty() && !s.sps.empty() && !s.pps.empty()) {
    s.init = fmp4::buildInit(s.sps, s.pps);
    s.codec_str = fmp4::codecString(s.sps);
    s.cv.notify_all();
    DB_LOGI(kTag, "h264 init segment 生成 (" + s.codec_str + ")");
  }
  if (sample.data.empty()) return;  // SPS/PPS のみの push (MediaCodec の config 等)
  sample.key = sample.key || key;
  sample.ts_ms = ts_ms;

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
  s.base_dt += current[0].dur;  // base-media-decode-time の連続性 (tfdt)
  s.cv.notify_all();
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
  return std::make_shared<Reader>(st_);
}

// ---------- Reader ----------

VideoTrack::Reader::Reader(std::shared_ptr<State> st) : st_(std::move(st)) {
  std::lock_guard<std::mutex> lk(st_->mu);
  generation_ = st_->generation;
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
    return s.frag_seq > last_frag_;
  };
  if (!ready()) s.cv.wait_for(lk, std::chrono::milliseconds(timeout_ms), ready);
  if (s.stopped || s.generation != generation_ || !s.enabled) {
    *ended = true;
    return {};
  }
  if (!init_sent_) {
    if (s.init.empty()) return {};  // タイムアウト (エンコーダ起動待ち等) — 呼び直し可
    init_sent_ = true;
    last_frag_ = s.frag_seq;  // ライブ端から: 次に確定する fragment から送る
    return s.init;
  }
  if (s.frag_seq > last_frag_) {
    last_frag_ = s.frag_seq;  // 取りこぼした中間 fragment は捨てる (ライブ専用)
    return s.frag;
  }
  return {};
}

}  // namespace db
