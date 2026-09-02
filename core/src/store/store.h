// Mutex-serialized SQLite WAL store. Public methods are safe across HTTP workers, Runloop, and
// platform threads. Corrupt databases are backed up before recreation so the mesh can resync.
#pragma once

#include <cstdint>
#include <map>
#include <mutex>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "crdt/lww_map.h"
#include "events/events.h"
#include "util/common.h"

struct sqlite3;

namespace db {

class Store {
 public:
  Store() = default;
  ~Store();
  Store(const Store&) = delete;
  Store& operator=(const Store&) = delete;


  bool open(const std::string& path);
  void close();
  bool isOpen() const { return db_ != nullptr; }


  std::optional<std::string> metaGet(const std::string& key);
  bool metaSet(const std::string& key, const std::string& value);
  bool metaSetBatch(const std::vector<std::pair<std::string, std::string>>& entries);


  bool configPut(const LwwEntry& e);
  bool configPutBatch(const std::vector<LwwEntry>& entries);
  void configDelete(const std::string& key);
  // Hard local wipe of the replicated configuration, for unpair and revoke. Rows are removed,
  // not tombstoned, so nothing about the old cluster can replicate into the next one.
  bool configDeleteAll();
  // Remove every meta key with this prefix and report how many went. Used to drop the cached
  // peer contracts of a cluster this device has left.
  size_t metaDeletePrefix(const std::string& prefix);
  std::vector<LwwEntry> configLoadAll();

  // --- events ---

  bool eventPut(const EventRecord& e);
  // Allocates the origin sequence, persists the event, and advances every newly contiguous local
  // record and its projection in one transaction. A failed write does not consume a sequence;
  // the returned empty optional must be treated as an emission failure.
  std::optional<EventRecord> eventAppendLocal(EventRecord e,
                                              std::vector<EventRecord>* newly_applied = nullptr);
  bool eventIngest(const EventRecord& e);
  std::optional<EventRecord> eventApplyNext(const std::string& origin);
  bool eventExists(const std::string& origin, uint64_t seq);
  void eventSetNotify(const std::string& origin, uint64_t seq, const std::string& notify_json);
  std::optional<EventRecord> eventGet(const std::string& origin, uint64_t seq);
  // The advertised head is the largest contiguous sequence starting at one. max_seq is a
  // separate durable allocation watermark and is not reduced when old events are pruned.
  std::map<std::string, uint64_t> eventHeads();
  uint64_t eventFrontier(const std::string& origin);
  uint64_t eventMaxSeq(const std::string& origin);
  // Applied events remain pending until their callback returns and this durable frontier is
  // advanced. The query is bounded and preserves sequence order within every origin.
  std::vector<EventRecord> pendingEventDispatches(size_t limit);
  bool eventAckDispatched(const std::string& origin, uint64_t seq);
  uint64_t eventDispatchFrontier(const std::string& origin);

  std::vector<EventRecord> eventsSince(const std::map<std::string, uint64_t>& remote_heads,
                                       size_t limit);

  // Runtime queries expose only records at or below each origin's applied frontier. eventGet and
  // eventsSince intentionally retain access to buffered gaps for anti-entropy.
  std::vector<EventRecord> recentEvents(size_t limit);

  size_t countEventsOfType(const std::string& type);

  std::optional<EventRecord> latestEventOfTypes(const std::string& t1, const std::string& t2);

  // Applied events cannot be deleted until replication carries an equivalent materialized-state
  // snapshot and its complete per-origin coverage vector. Until such a coverage vector is
  // recorded with eventCoverageSet, pruning still fails closed.
  //
  // Retention policy: an event survives when it is inside the newest max_events of its origin,
  // when its wall clock is at or after cutoff_wall_ms, when it is still above the origin's
  // applied or dispatch frontier, or when the recorded coverage vector does not prove that every
  // cluster member already holds it.
  size_t pruneEvents(size_t max_events, int64_t cutoff_wall_ms);

  // Durable per-origin replication coverage. A sequence recorded here is held by every cluster
  // member, so events at or below it may be pruned locally without losing cluster history.
  bool eventCoverageSet(const std::map<std::string, uint64_t>& coverage);
  std::map<std::string, uint64_t> eventCoverage();

  struct CallProjection {
    std::string call_id;
    std::string door;
    std::string origin;
    std::string purpose;
    std::string state;
    int stage_revision = 0;
    int64_t expires_wall_ms = 0;
    std::string updated_hlc;
    std::string terminal_reason;
    std::string dialog_owner;
    std::string answered_hlc;
    int64_t press_wall_ms = 0;
    int64_t answered_wall_ms = 0;
    int64_t ended_wall_ms = 0;
    std::string visitor_lang;
    std::string snapshot_hash;
  };

  // One finished call as shown in the call history. outcome is derived from state and
  // terminal_reason; concurrency losers, fenced calls, and live calls are never returned.
  struct CallLogRow {
    std::string id;           // "<origin>:<seq>" of the originating press when known.
    std::string call_id;
    int64_t ts = 0;           // Press wall clock, falling back to the terminal wall clock.
    std::string door;
    std::string purpose;
    std::string visitor_lang;
    std::string outcome;      // answered | replied | missed | cancelled
    std::string answered_by;
    int64_t duration_ms = 0;
    std::string snapshot;     // sha256 of the door snapshot asset, empty until phase 2.
    std::string updated_hlc;
    bool seen = true;
  };
  struct CallLogQuery {
    int64_t since_ms = 0;     // Inclusive lower bound on ts; zero disables the bound.
    int64_t before_ms = 0;    // Exclusive upper bound on ts for paging older; zero disables it.
    size_t limit = 50;
    std::string door;         // Empty matches every door.
    std::string outcome;      // Empty matches every outcome.
  };
  // Newest first. seen is resolved against the device-local watermark.
  std::vector<CallLogRow> callLog(const CallLogQuery& query);
  // Missed calls whose projection is newer than the device-local seen watermark.
  size_t unreadMissedCount();
  std::string callLogSeenHlc();
  // Empty up_to_hlc marks every currently known call as seen. The watermark never moves back.
  bool callLogMarkSeen(const std::string& up_to_hlc);
  // Each contiguous frontier advancement and its lifecycle projection share one transaction.
  std::vector<CallProjection> activeCallProjections();
  std::optional<CallProjection> callProjection(const std::string& call_id);


  struct TgQueueItem {
    int64_t id = 0;
    std::string kind;         // "photo" | "message"
    std::string chat_id;
    std::string payload;
    Bytes snapshot;
    int attempts = 0;
    int64_t next_retry_ms = 0;
    int64_t created_ms = 0;
  };

  struct NetProbe {
    int64_t ts_ms = 0;
    std::string target;
    std::string host;
    bool ok = false;
    int rtt_ms = -1;
  };
  void netProbePut(const NetProbe& p);

  std::vector<NetProbe> netProbesSince(int64_t since_ms, size_t limit);
  size_t netProbePrune(int64_t cutoff_ms);

  int64_t tgQueuePut(const TgQueueItem& item);

  std::vector<TgQueueItem> tgQueueDue(int64_t now_ms, size_t limit);
  void tgQueueRetry(int64_t id, int attempts, int64_t next_retry_ms);
  void tgQueueDelete(int64_t id);
  size_t tgQueuePrune(int64_t cutoff_created_ms);
  size_t tgQueueCount();

 private:
  bool exec(const char* sql);
  bool migrate();  // Requires mu_.
  void closeLocked();  // Requires mu_.





  // Locked helpers avoid recursively acquiring the non-recursive mutex. This matters on old iOS
  // pthread implementations, where re-entry can corrupt SQLite-owned return buffers.
  std::optional<std::string> metaGetLocked(const std::string& key);
  bool metaSetLocked(const std::string& key, const std::string& value);
  size_t countEventsOfTypeLocked(const std::string& type);
  bool persistEventLocked(const EventRecord& e, bool allow_existing, bool* inserted);
  enum class EventApplyResult { Applied, NoNext, Error };
  EventApplyResult eventApplyNextLocked(const std::string& origin, EventRecord* applied);
  std::optional<std::string> callDoorFenceLocked(const std::string& door);
  bool advanceCallDoorFenceLocked(const std::string& door, const std::string& call_id,
                                  const std::string& hlc);
  bool applyCallProjectionLocked(const EventRecord& e);
  sqlite3* db_ = nullptr;
  mutable std::mutex mu_;  // Serializes the single SQLite connection.
};

}  // namespace db
