// 動体検知 (MotionDetector): 帧総線の第 4 消費者。輝度面だけを使う軽量ブロック差分方式。
//   RawFrame → 32x24 程度へ平均縮小 → 前フレームとの絶対差 → 変化ブロック率 (%) を算出し、
//   閾値以上が連続 2 フレーム続いたら on_motion を発火する。
// 設計メモ:
//   - FrameBus とは独立したクラス。配線 (どのスレッドがどの頻度で feed するか) は Node 側の仕事。
//   - スレッド: 全メソッドは呼び出し側スレッドで完結する。内部ロックは持たない —
//     feed/setConfig/onMotion は同一スレッド (または外部で直列化) から呼ぶこと。
//   - 最初の数フレーム (学習期間) と min_interval_s 以内の再発火は抑制する。
#pragma once

#include <cstdint>
#include <functional>
#include <vector>

#include "media/frame_bus.h"

namespace db {

// 設定 (docs/config-schema.md の doors[].motion に対応)
struct MotionConfig {
  bool enabled = true;
  int sensitivity = 40;   // 0-100。大きいほど敏感 (閾値が下がる)
  int min_interval_s = 30;  // 発火後この秒数は再発火しない
};

class MotionDetector {
 public:
  // ts_ms: 発火フレームのタイムスタンプ / changed_pct: 変化ブロック率 (0-100)
  using MotionCallback = std::function<void(int64_t ts_ms, double changed_pct)>;

  // 縮小グリッド (フレームが小さい時は w/h に合わせて縮む)
  static constexpr int kGridW = 32;
  static constexpr int kGridH = 24;
  // 学習期間: 最初の kLearnFrames 回の feed では発火しない
  static constexpr int kLearnFrames = 3;
  // ブロック輝度差がこの値未満なら「変化なし」(センサノイズ ±数階調を吸収)
  static constexpr int kBlockDiffThreshold = 12;

  // sensitivity (0-100) → 発火に必要な変化ブロック率 (%)。単調減少: 0→50%, 100→1%
  static double thresholdPercent(int sensitivity);

  void setConfig(const MotionConfig& cfg);
  const MotionConfig& config() const { return cfg_; }
  void onMotion(MotionCallback cb) { cb_ = std::move(cb); }

  // 1 フレーム処理する。閾値連続 2 回 + 抑制条件クリアで cb_ を同スレッドで呼ぶ。
  // 未知形式・データ不足のフレームは無視。フレーム寸法が変わったら学習をやり直す。
  void feed(const RawFrame& f);

  // 直近 feed の変化ブロック率 (%)。学習中/無効中は 0。テスト・診断用。
  double lastChangedPercent() const { return last_pct_; }

 private:
  // f の輝度面を gw_×gh_ ブロック平均へ縮小して out に書く。非対応形式は false。
  // stride: 補完済み (0 でない) の Y 面 (packed 形式は行) バイト幅。
  bool downscaleLuma(const RawFrame& f, int stride, std::vector<uint8_t>& out) const;

  MotionConfig cfg_;
  MotionCallback cb_;
  std::vector<uint8_t> prev_;   // 前フレームの縮小輝度 (gw_*gh_)
  int gw_ = 0, gh_ = 0;         // 現在のグリッド寸法
  int frame_w_ = 0, frame_h_ = 0;  // 学習し直し検出用
  int seen_ = 0;                // 現寸法で feed した枚数 (学習期間判定)
  int streak_ = 0;              // 閾値以上が連続した回数
  int64_t last_fire_ms_ = INT64_MIN;  // 最後に発火した ts_ms
  double last_pct_ = 0.0;
};

}  // namespace db
