// 帧総線 (FrameBus): カメラ生フレームの単一「最新フレーム」スロット。
//   採集側 (camera_win / capi) が push し、消費者 (/snapshot.jpg・/stream.mjpeg・
//   将来の UI プレビュー / 動体検知 / SIP ビデオ) が必要な時だけ JPEG 化する。
// 需要駆動: 購読者ゼロならエンコードゼロ。同一フレームの再要求はキャッシュ返却。
// スレッド: 全メソッド任意スレッド可 (mutex 1 本 — 低 fps 前提で十分)。
#pragma once

#include <cstdint>
#include <functional>
#include <mutex>

#include "util/common.h"

namespace db {

// 生フレーム。format は doorbell.h db_core_on_camera_frame と同じ値:
//   0=NV21, 1=NV12, 2=YUY2, 3=BGRA
struct RawFrame {
  int format = 0;
  int w = 0, h = 0;
  int stride = 0;  // Y 面 (packed 形式は行) のバイト幅。0 = 詰め詰め既定
  int64_t ts_ms = 0;
  Bytes data;
};

// format に応じた必要バイト数 (stride==0 なら詰め詰め幅で計算)
size_t rawFrameBytes(int format, int w, int h, int stride);

class FrameBus {
 public:
  // 平台エンコーダ (SPI 経由差し替え)。rgb は w*h*3 (RGB24)。
  // 空 Bytes を返したら失敗 → stb フォールバック。
  using ExternalEncoder = std::function<Bytes(const uint8_t* rgb, int w, int h, int quality)>;

  // 最新フレームを差し替える (エンコードはしない)。データ不足フレームは破棄。
  void push(RawFrame&& f);

  // 最新フレームの JPEG。フレーム無しなら空。
  // 前回エンコードと同じフレームならキャッシュを返す (エンコードしない)。
  Bytes latestJpeg();
  Bytes latestJpeg(int64_t* capture_ts_ms);

  // quality: 1-100 / max_width: 超えたら 1/2 縮小を繰り返す (0 = 無制限)
  void setJpegParams(int quality, int max_width);
  void setExternalEncoder(ExternalEncoder fn);

  // テスト/診断用の観測値
  uint64_t frameCount() const;
  uint64_t encodeCount() const;

 private:
  mutable std::mutex mu_;
  RawFrame latest_;
  uint64_t seq_ = 0;          // push 毎に +1 (0 = フレーム無し)
  uint64_t encoded_seq_ = 0;  // jpeg_cache_ が対応する seq
  uint64_t encode_count_ = 0;
  Bytes jpeg_cache_;
  int quality_ = 60;
  int max_width_ = 640;
  ExternalEncoder external_;
};

}  // namespace db
