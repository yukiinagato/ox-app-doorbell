
#include "events/events.h"

#include "store/store.h"
#include "util/json.h"
#include "util/log.h"

namespace db {

EventLog::EventLog(std::string self_id, HlcClock& hlc, Store& store)
    : self_id_(std::move(self_id)), hlc_(hlc), store_(store) {}

void EventLog::loadHeads() {
  frontiers_ = store_.eventHeads();
  dispatch_queue_.clear();
  dispatching_ = false;
  std::vector<std::string> origins;
  origins.reserve(frontiers_.size());
  for (const auto& entry : frontiers_) origins.push_back(entry.first);
  for (const auto& origin : origins)
    drainContiguous(origin, nullptr, /*dispatch=*/false);
  const auto latest = store_.recentEvents(1);
  if (!latest.empty()) hlc_.observe(latest.front().hlc);
}

void EventLog::replayRecovered() { dispatchPending(); }

EventRecord EventLog::append(const std::string& type, const std::string& door,
                             const std::string& device, const std::string& payload_json) {
  EventRecord ev;
  ev.origin = self_id_;
  ev.type = type;
  ev.door = door;
  ev.device = device;
  ev.hlc = hlc_.tick();

  int64_t ms = 0;
  HlcClock::parse(ev.hlc, &ms, nullptr, nullptr);
  ev.wall_ms = ms;
  ev.payload_json = payload_json;
  std::vector<EventRecord> applied;
  auto persisted = store_.eventAppendLocal(std::move(ev), &applied);
  if (!persisted) {
    DB_LOGE("events", "local event persistence failed; event was not emitted");
    return {};
  }
  for (const auto& record : applied) frontiers_[record.origin] = record.seq;
  if (!applied.empty()) dispatchPending();
  return *persisted;
}

bool EventLog::applyRemote(const EventRecord& e,
                           std::vector<EventRecord>* newly_applied) {
  if (newly_applied) newly_applied->clear();
  const bool inserted = store_.eventIngest(e);
  if (inserted) hlc_.observe(e.hlc);
  drainContiguous(e.origin, newly_applied);
  return inserted;
}

void EventLog::drainContiguous(const std::string& origin,
                               std::vector<EventRecord>* newly_applied,
                               bool dispatch) {
  while (auto record = store_.eventApplyNext(origin)) {
    if (newly_applied) newly_applied->push_back(*record);
    frontiers_[origin] = record->seq;
    if (dispatch && !dispatchPending()) break;
  }
}

bool EventLog::dispatchPending() {
  if (dispatching_ || !on_event_) return true;
  constexpr size_t kDispatchBatchSize = 128;
  dispatching_ = true;
  bool ok = true;
  try {
    while (true) {
      if (dispatch_queue_.empty()) {
        auto pending = store_.pendingEventDispatches(kDispatchBatchSize);
        if (pending.empty()) break;
        for (auto& record : pending) dispatch_queue_.push_back(std::move(record));
      }
      const EventRecord& record = dispatch_queue_.front();
      on_event_(record, record.origin == self_id_);
      if (!store_.eventAckDispatched(record.origin, record.seq)) {
        DB_LOGE("events", "event dispatch acknowledgement failed for " + record.origin + ":" +
                              std::to_string(record.seq));
        ok = false;
        break;
      }
      dispatch_queue_.pop_front();
    }
  } catch (...) {
    dispatching_ = false;
    throw;
  }
  dispatching_ = false;
  return ok;
}

std::map<std::string, uint64_t> EventLog::heads() const { return frontiers_; }

std::vector<EventRecord> EventLog::deltaSince(const std::map<std::string, uint64_t>& remote_heads,
                                              size_t limit) const {
  return store_.eventsSince(remote_heads, limit);
}

bool EventLog::mergeNotify(const std::string& origin, uint64_t seq,
                           const std::string& notify_json) {
  auto ev = store_.eventGet(origin, seq);
  if (!ev) return false;
  json::Doc inc = json::parse(notify_json);
  if (!inc || !cJSON_IsObject(inc.get())) return false;
  json::Doc cur = json::parse(ev->notify_json.empty() ? "{}" : ev->notify_json);
  if (!cur || !cJSON_IsObject(cur.get())) cur = json::obj();


  const std::string cur_hlc = json::getString(cur.get(), "hlc");
  const std::string inc_hlc = json::getString(inc.get(), "hlc");
  cJSON* winner = inc_hlc > cur_hlc ? inc.get() : cur.get();
  cJSON* loser = inc_hlc > cur_hlc ? cur.get() : inc.get();
  json::Doc merged(cJSON_Duplicate(loser, 1));
  cJSON* it = nullptr;
  cJSON_ArrayForEach(it, winner) {
    cJSON_DeleteItemFromObjectCaseSensitive(merged.get(), it->string);
    cJSON_AddItemToObject(merged.get(), it->string, cJSON_Duplicate(it, 1));
  }
  if (cJSON_Compare(merged.get(), cur.get(), 1)) return false;
  store_.eventSetNotify(origin, seq, json::dump(merged.get()));
  return true;
}

}  // namespace db
