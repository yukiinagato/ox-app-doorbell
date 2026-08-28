// VideoTrack 実装。状態 (State) は shared_ptr で Reader と共有 — Node 破棄と
// httpd ワーカーの生存順に依らずダングリングしない。
#include "media/video_track.h"

#include <algorithm>
#include <chrono>

#include "util/log.h"

namespace db {

namespace {
constexpr const char* kTag = "video";
constexpr int64_t kMaxFragmentMs = 500;  // フラグメント上限 (GOP がこれより長い時の分割点)

uint32_t clampDur(int64_t d) {
  if (d < 1) return 1;        // 非増加 ts (時計巻き戻り等) でも前進させる
  if (d > 1000) return 1000;  // 長すぎる間隙 (エンコーダ停止明け) は 1s に丸める
  return static_cast<uint32_t>(d);
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

  std::vector<fmp4::Sample> pending;  // 進行中フラグメントのサンプル (dur 未確定)
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
    pending.clear();
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

  // フラグメント確定: キーフレーム到来 (=1 GOP) or 500ms 超過の早い方。
  // 新サンプルの ts で末尾サンプルの dur が決まるため「次が来た時に閉じる」方式。
  if (!s.pending.empty() &&
      (sample.key || ts_ms - s.pending.front().ts_ms >= kMaxFragmentMs)) {
    uint64_t total = 0;
    for (size_t i = 0; i < s.pending.size(); i++) {
      int64_t next_ts = (i + 1 < s.pending.size()) ? s.pending[i + 1].ts_ms : ts_ms;
      s.pending[i].dur = clampDur(next_ts - s.pending[i].ts_ms);
      total += s.pending[i].dur;
    }
    s.frag = fmp4::buildFragment(static_cast<uint32_t>(++s.frag_seq), s.base_dt, s.pending);
    s.base_dt += total;  // base-media-decode-time の連続性 (tfdt)
    s.pending.clear();
    s.cv.notify_all();
  }
  s.pending.push_back(std::move(sample));
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
