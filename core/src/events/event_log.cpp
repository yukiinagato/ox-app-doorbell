// イベントログの実装 (events.h 参照)。ID は (origin, seq) で全網冪等、順序付けは HLC。
#include "events/events.h"

#include <algorithm>

#include "store/store.h"
#include "util/json.h"

namespace db {

EventLog::EventLog(std::string self_id, HlcClock& hlc, Store& store)
    : self_id_(std::move(self_id)), hlc_(hlc), store_(store) {}

void EventLog::loadHeads() { heads_ = store_.eventHeads(); }

EventRecord EventLog::append(const std::string& type, const std::string& door,
                             const std::string& device, const std::string& payload_json) {
  EventRecord ev;
  ev.origin = self_id_;
  ev.seq = ++heads_[self_id_];  // 自 seq の採番 (loadHeads で復元済みの続き)
  ev.type = type;
  ev.door = door;
  ev.device = device;
  ev.hlc = hlc_.tick();
  // wall_ms は表示専用: HLC の物理部 (自分の壁時計と観測済み最大の大きい方) を使う
  int64_t ms = 0;
  HlcClock::parse(ev.hlc, &ms, nullptr, nullptr);
  ev.wall_ms = ms;
  ev.payload_json = payload_json;
  if (store_.eventPut(ev) && on_event_) on_event_(ev, true);
  return ev;
}

bool EventLog::applyRemote(const EventRecord& e) {
  // 既知 (origin,seq) — 自分発のイベントの還流も含め — は冪等に無視
  if (!store_.eventPut(e)) return false;
  uint64_t& head = heads_[e.origin];
  head = std::max(head, e.seq);  // 順序逆転配送でも前進のみ
  hlc_.observe(e.hlc);
  if (on_event_) on_event_(e, false);
  return true;
}

std::map<std::string, uint64_t> EventLog::heads() const { return heads_; }

std::vector<EventRecord> EventLog::deltaSince(const std::map<std::string, uint64_t>& remote_heads,
                                              size_t limit) const {
  return store_.eventsSince(remote_heads, limit);
}

bool EventLog::mergeNotify(const std::string& origin, uint64_t seq,
                           const std::string& notify_json) {
  auto ev = store_.eventGet(origin, seq);
  if (!ev) return false;
  json::Doc inc = json::parse(notify_json);
  if (!inc || !cJSON_IsObject(inc.get())) return false;  // notify_json はオブジェクト前提
  json::Doc cur = json::parse(ev->notify_json.empty() ? "{}" : ev->notify_json);
  if (!cur || !cJSON_IsObject(cur.get())) cur = json::obj();
  // 双方の top-level "hlc" (文字列) を比較し、大きい方を優先しつつフィールド和集合をとる。
  // 同値なら既存側を優先 (安定)。
  const std::string cur_hlc = json::getString(cur.get(), "hlc");
  const std::string inc_hlc = json::getString(inc.get(), "hlc");
  cJSON* winner = inc_hlc > cur_hlc ? inc.get() : cur.get();
  cJSON* loser = inc_hlc > cur_hlc ? cur.get() : inc.get();
  json::Doc merged(cJSON_Duplicate(loser, 1));
  cJSON* it = nullptr;
  cJSON_ArrayForEach(it, winner) {  // 衝突フィールドは勝者側で上書き
    cJSON_DeleteItemFromObjectCaseSensitive(merged.get(), it->string);
    cJSON_AddItemToObject(merged.get(), it->string, cJSON_Duplicate(it, 1));
  }
  if (cJSON_Compare(merged.get(), cur.get(), 1)) return false;  // 変化なし
  store_.eventSetNotify(origin, seq, json::dump(merged.get()));
  return true;
}

}  // namespace db
