// HLC (Hybrid Logical Clock)
// 文字列表現: "%012llx-%04x-%s" = 48bit 物理ms + 16bit カウンタ + node_id 先頭8文字。
// 文字列の辞書順 == HLC 順 (同一物理ms・同一カウンタは node8 でタイブレーク)。
// CRDT/イベントの順序付けは必ずこれを使う (壁時計は信頼しない)。
#pragma once

#include <cstdint>
#include <mutex>
#include <string>

#include "util/clock.h"

namespace db {

class HlcClock {
 public:
  // node8: node_id の先頭 8 文字 (タイブレーク用)
  HlcClock(IClock& clock, std::string node8);

  // ローカル事象の刻印
  std::string tick();
  // リモート HLC の観測 (受信メッセージすべてで呼ぶ)
  void observe(const std::string& remote_hlc);

  // 観測済み最大物理時刻と自分の壁時計の大きい方 = 「補正済み壁時計」。
  // スケジュール判定 (夜間帯など) はこちらを使う。
  int64_t correctedWallMs();

  // 解析。失敗時 false。
  static bool parse(const std::string& hlc, int64_t* physical_ms, int* counter,
                    std::string* node8);
  static std::string format(int64_t physical_ms, int counter, const std::string& node8);

 private:
  IClock& clock_;
  std::string node8_;
  std::mutex mu_;
  int64_t last_ms_ = 0;  // 観測済み最大物理ms
  int counter_ = 0;
};

}  // namespace db
