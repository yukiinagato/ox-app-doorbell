// VideoTrack — 符号化済み H.264 (AnnexB) の共有点 (Phase 6a)。
//   殻/平台エンコーダ (Android MediaCodec / Windows MF / iOS VideoToolbox) が push() し、
//   /stream.mp4 の各購読者 (Reader) が init segment + 以降の fragment を順に受け取る。
// リングは直近 fragment のみ (ライブ専用 — 録画はしない)。遅い購読者は fragment を
// 取りこぼす (次のキーフレームで自然回復 — MSE は RAP まで描画を待つだけ)。
// フラグメント戦略: 1 access unit/fragment (次フレーム到来時に即時確定)。
// 各 fragment 前の `dbts` box に室外機の採集 epoch-ms を格納する。
// スレッド: 全メソッド任意スレッド可 (mutex + condition_variable)。
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
  struct State;  // 前方宣言 (Reader と共有 — 破棄順に依らず安全)

 public:
  VideoTrack();
  ~VideoTrack();

  // 有効/無効 (config camera.codec: h264/auto = 有効, mjpeg = 無効)。
  // 無効化で全購読者を切断しストリーム状態 (SPS/PPS・連番) を捨てる。
  void setEnabled(bool on);
  bool enabled() const;

  // 符号化フレーム投入 (任意スレッド)。annexb は 1 アクセスユニット分
  // (SPS/PPS/AUD/SEI が同梱されていれば抽出/除去する)。key: IDR を含むか
  // (annexb 内に IDR NAL があればこの引数に依らずキー扱い)。
  void push(const uint8_t* annexb, size_t len, bool key, int64_t ts_ms);

  // 全購読者を起こして切断する (Node::stop 用 — httpd 停止前に呼ぶこと)。
  void stop();

  bool active() const;           // init segment 生成済み (SPS/PPS 受領済み)
  int subscriberCount() const;   // 生きている Reader 数 — encoder wanted の判定源
  std::string codecString() const;  // "avc1.42C01F" 等 ("" = 未受領)

  // 購読ハンドル。pull() は「次に書くべきバイト列」を返す:
  //   初回 = init segment (未生成なら timeout_ms 待って空 vector)。
  //   以降 = 直近 fragment (新着が無ければ timeout_ms 待って空 vector)。
  //   *ended = true → 購読終了 (stop()/setEnabled(false)/SPS 変化)。
  // Reader の破棄が購読解除 (subscriberCount が減る)。
  class Reader {
   public:
    explicit Reader(std::shared_ptr<State> st);
    ~Reader();
    Reader(const Reader&) = delete;
    Reader& operator=(const Reader&) = delete;
    Bytes pull(int timeout_ms, bool* ended);

   private:
    std::shared_ptr<State> st_;
    uint64_t generation_ = 0;   // 購読開始時の世代 (SPS 変化で世代が進むと ended)
    bool init_sent_ = false;
    uint64_t last_frag_ = 0;    // 受け取り済み fragment 連番
  };
  std::shared_ptr<Reader> subscribe();

 private:
  std::shared_ptr<State> st_;
};

}  // namespace db
