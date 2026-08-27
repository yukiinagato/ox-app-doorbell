// イベントログ (複製・冪等) とトリガールールエンジン (設計書 mesh §3, 計画書)。
// スレッド: Runloop 上でのみ。
#pragma once

#include <cstdint>
#include <functional>
#include <map>
#include <string>
#include <vector>

#include "util/hlc.h"
#include "util/json.h"

namespace db {

class Store;

// イベントID = (origin, seq) — 全網で冪等。
struct EventRecord {
  std::string origin;     // 発生ノード node_id
  uint64_t seq = 0;       // origin 内の単調連番 (1 始まり)
  std::string type;       // press | motion | answered | missed | reply | offline | online |
                          // config_changed | emergency | emergency_cancel | visitor_lang
  std::string door;       // door_id ("" 可: offline 等は device ベース)
  std::string device;     // 対象 device (node_id)
  std::string hlc;        // 順序付け
  int64_t wall_ms = 0;    // origin の壁時計 (表示専用・信頼しない)
  std::string payload_json;  // 種別ごとの追加情報 (snapshot_ref 等)
  std::string notify_json;   // 通知回執 (claimed_by/notified_at/telegram_msg_ids) — LWW マージ
};

class EventLog {
 public:
  // on_event(ev, is_local): 新規に受理されたイベント毎 (通知回執の更新では呼ばない)
  using EventCb = std::function<void(const EventRecord&, bool is_local)>;

  EventLog(std::string self_id, HlcClock& hlc, Store& store);

  void loadHeads();  // 起動時: Store から heads と自 seq を復元

  EventRecord append(const std::string& type, const std::string& door,
                     const std::string& device, const std::string& payload_json);
  bool applyRemote(const EventRecord& e);  // 既知 (origin,seq) なら false

  std::map<std::string, uint64_t> heads() const;  // origin → 最大 seq
  // remote_heads が知らないイベント (古い順、最大 limit 件)
  std::vector<EventRecord> deltaSince(const std::map<std::string, uint64_t>& remote_heads,
                                      size_t limit) const;

  // 通知回執の LWW マージ (フィールド単位, hlc 比較)。変化したら true。
  bool mergeNotify(const std::string& origin, uint64_t seq, const std::string& notify_json);

  void onEvent(EventCb cb) { on_event_ = std::move(cb); }
  const std::string& selfId() const { return self_id_; }

 private:
  std::string self_id_;
  HlcClock& hlc_;
  Store& store_;
  std::map<std::string, uint64_t> heads_;
  EventCb on_event_;
};

// ---- ルールエンジン ----
// config JSON (materialize 済み全文) の trigger_rules / quiet_hours を評価し、
// イベントに対して実行すべきアクション一覧を返す。純関数的 (状態は設定のみ)。
struct Action {
  std::string type;         // sip_call | telegram | ha_event | chime | auto_reply
  std::string params_json;  // 例: {"target_extension":"600"} / {"households":[...],"with_snapshot":true}
                            //     / {"devices":[...],"sound":"ding1"} / {"reply_id":"qr_okihai"}
};

class RuleEngine {
 public:
  // 設定変更のたびに全文を渡して差し替える
  void setConfig(const std::string& config_json);

  // corrected_wall_ms: HlcClock::correctedWallMs() を渡す (時計狂い対策)。
  // tz_offset_min: 現地時刻オフセット (分)。スケジュール窓 ("22:00"-"06:00") と
  // quiet_hours はこの現地時刻で判定する。
  std::vector<Action> evaluate(const EventRecord& ev, int64_t corrected_wall_ms,
                               int tz_offset_min) const;

 private:
  std::string config_json_;
  json::Doc config_;  // setConfig でパース済みのツリー (evaluate 毎の再パースを避ける)
};

}  // namespace db
