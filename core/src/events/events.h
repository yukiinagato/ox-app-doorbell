

// Idempotent replicated event log and stateless trigger-rule evaluator. Use only on Runloop.
#pragma once

#include <cstdint>
#include <deque>
#include <functional>
#include <map>
#include <string>
#include <vector>

#include "util/hlc.h"
#include "util/json.h"

namespace db {

class Store;


// Event identity is the globally idempotent (origin, seq) pair.
struct EventRecord {
  std::string origin;
  uint64_t seq = 0;
  std::string type;       // press | motion | answered | missed | reply | offline | online |
                          // config_changed | emergency | emergency_cancel | visitor_lang
  std::string door;
  std::string device;
  std::string hlc;
  int64_t wall_ms = 0;
  std::string payload_json;
  std::string notify_json;
};

class EventLog {
 public:

  using EventCb = std::function<void(const EventRecord&, bool is_local)>;

  EventLog(std::string self_id, HlcClock& hlc, Store& store);

  void loadHeads();
  // Delivers every applied event that has no durable dispatch acknowledgement. Call this only
  // after all event consumers are initialized. A crash during delivery can replay the event.
  void replayRecovered();

  // A zero-sequence record reports that durable local emission failed.
  EventRecord append(const std::string& type, const std::string& door,
                     const std::string& device, const std::string& payload_json);
  bool applyRemote(const EventRecord& e,
                   std::vector<EventRecord>* newly_applied = nullptr);

  std::map<std::string, uint64_t> heads() const;

  std::vector<EventRecord> deltaSince(const std::map<std::string, uint64_t>& remote_heads,
                                      size_t limit) const;


  bool mergeNotify(const std::string& origin, uint64_t seq, const std::string& notify_json);

  void onEvent(EventCb cb) { on_event_ = std::move(cb); }
  const std::string& selfId() const { return self_id_; }

 private:
  std::string self_id_;
  HlcClock& hlc_;
  Store& store_;
  std::map<std::string, uint64_t> frontiers_;
  std::deque<EventRecord> dispatch_queue_;
  EventCb on_event_;
  bool dispatching_ = false;

  void drainContiguous(const std::string& origin,
                       std::vector<EventRecord>* newly_applied = nullptr,
                       bool dispatch = true);
  bool dispatchPending();
};




struct Action {
  std::string type;         // sip_call | telegram | ha_event | chime | auto_reply | device_alert
  std::string params_json;
                            //     / {"devices":[...],"sound":"ding1"} / {"reply_id":"qr_okihai"}
};

class RuleEngine {
 public:

  void setConfig(const std::string& config_json);




  std::vector<Action> evaluate(const EventRecord& ev, int64_t corrected_wall_ms,
                               int tz_offset_min) const;

 private:
  std::string config_json_;
  json::Doc config_;
};

}  // namespace db
