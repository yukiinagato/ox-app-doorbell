// Windows H.264 エンコード (Media Foundation encoder MFT) — WIN32 のみコンパイル。
//   camera_win の FrameSink から分岐した NV12/YUY2 フレームを専用スレッドで食わせ、
//   AnnexB (start code 区切り、SPS/PPS はキーフレームに同梱) をコールバックへ吐く。
//   HW MFT (async — QSV/AMD/NVIDIA) 優先 → SW MFT (sync, 内蔵 H.264 encoder) 回落。
// 稼働制御は Node (video_track の購読者がいる間だけ start — 省電力)。
// ※ mingw クロスでのコンパイル確認のみ — 実動作は Windows VM 検証待ち。
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
    int fps = 25;           // config h264_fps (入力の間引きにも使う)
    int bitrate_kbps = 1500;  // config h264_bitrate_kbps
    int gop_s = 2;          // キーフレーム間隔 (秒) — MSE 参加者の初描画待ちに直結
  };
  // 符号化出力 (エンコードスレッドから)。annexb: 1 アクセスユニット分。
  using Output = std::function<void(const uint8_t* annexb, size_t len, bool key, int64_t ts_ms)>;

  explicit EncoderWin(Output out) : out_(std::move(out)) {}
  ~EncoderWin() { stop(); }

  EncoderWin(const EncoderWin&) = delete;
  EncoderWin& operator=(const EncoderWin&) = delete;

  // エンコードスレッド起動 (即 true)。MFT の実初期化は最初のフレーム到着時
  // (解像度が要るため)。失敗はログのみ — running は落ちる。再 start 安全。
  void start(const Params& p);
  void stop();
  bool running() const { return running_.load(); }

  // 採集スレッドから (camera_win FrameSink の分岐)。未稼働なら即 return。
  // fps 間引き + NV12 詰め直しをしてキューへ (満杯なら古い方を捨てる — ライブ専用)。
  void feed(const RawFrame& f);

 private:
  void run();
  bool popFrame(RawFrame* out, int timeout_ms);

  Output out_;
  Params params_;
  std::thread th_;
  std::atomic<bool> running_{false};
  std::mutex mu_;
  std::condition_variable cv_;
  std::deque<RawFrame> queue_;  // NV12 (stride = w) に正規化済み。深さ 2 まで
  int64_t last_fed_ms_ = 0;     // fps 間引き用
};

}  // namespace db
