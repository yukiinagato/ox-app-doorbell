




// Flat dot-path LWW-map CRDT. Winners are ordered by (HLC, author); deletes are tombstones and
// per-author sequence numbers form the version vector. Use only on Runloop; there is no lock.
#pragma once

#include <cstdint>
#include <functional>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include "util/hlc.h"

namespace db {

struct LwwEntry {
  std::string key;
  std::string value_json;
  bool deleted = false;
  std::string hlc;
  std::string author;
  uint64_t seq = 0;
};

struct LwwMutation {
  std::string key;
  std::string value_json;
  bool deleted = false;
};

// Each value is the highest contiguous sequence known for its author. Advertising a sparse
// maximum would make an earlier delayed mutation invisible to anti-entropy.
using VersionVector = std::map<std::string, uint64_t>;

class LwwMap {
 public:


  using ChangeCb = std::function<void(const LwwEntry&, bool is_local)>;
  using BatchChangeCb = std::function<void(const std::vector<LwwEntry>&, bool is_local)>;
  // Runs after a tentative mutation but before observers. Returning false restores the complete
  // pre-mutation CRDT state, including sequence/frontier bookkeeping, so durable stores can form
  // the commit boundary without exposing or advertising an unpersisted winner.
  using CommitCb =
      std::function<bool(const std::vector<LwwEntry>&, bool is_local, bool batch)>;

  LwwMap(std::string self_id, HlcClock& hlc);


  void load(const std::vector<LwwEntry>& entries);


  const LwwEntry& set(const std::string& key, const std::string& value_json);
  const LwwEntry& remove(const std::string& key);  // tombstone
  // Applies a pre-validated local batch without exposing intermediate states to observers.
  std::vector<LwwEntry> mutate(const std::vector<LwwMutation>& mutations);
  // Writes first-run defaults at the minimum HLC, so any real write or tombstone from any replica
  // wins over them. Keys that already have an entry here (live, deleted, or seeded) are skipped.
  // Deletions are not seeds and are ignored.
  std::vector<LwwEntry> seed(const std::vector<LwwMutation>& mutations);
  // The HLC this replica's seeded entries carry: physical time zero, so it orders before every
  // clock-generated timestamp. The node suffix matches the author like any other HLC.
  std::string seedHlc() const;



  bool applyRemote(const LwwEntry& e);
  // Applies remote winners as one visible state transition. Version-vector knowledge is advanced
  // for every entry, including duplicates and losing values.
  std::vector<LwwEntry> applyRemoteBatch(const std::vector<LwwEntry>& entries);
  // Applies an untruncated anti-entropy state delta and records the sender's contiguous frontier.
  // Callers must not use this for live pushes or truncated pages: the advertised prefix is trusted
  // even when overwritten mutations are no longer present in entries.
  std::vector<LwwEntry> applyRemoteSnapshot(const std::vector<LwwEntry>& entries,
                                            const VersionVector& complete_frontier);

  std::optional<std::string> get(const std::string& key) const;

  std::vector<std::pair<std::string, std::string>> byPrefix(const std::string& prefix) const;

  VersionVector versionVector() const;

  std::vector<LwwEntry> deltaSince(const VersionVector& remote_vv) const;
  // Returns user-visible winners and tombstones; internal persistence metadata is excluded.
  std::vector<LwwEntry> all() const;


  // Erases tombstones older than older_than_hlc that every replica in fleet_min_vv has observed.
  // A tombstone is kept while it still hides an older live descendant or removes a member from an
  // older live ancestor object, because erasing it would make that older value visible again.
  // Returns the erased keys; the caller deletes them from durable storage.
  // keep, when set, protects keys whose tombstone must outlive GC (for example a key a first-run
  // seed could recreate on a device that joins after the tombstone was collected).
  std::vector<std::string> gcTombstones(
      const VersionVector& fleet_min_vv, const std::string& older_than_hlc,
      const std::function<bool(const std::string&)>& keep = {});

  // Remote entries whose HLC is malformed or further ahead of local wall time than
  // kMaxRemoteAheadMs are counted here and never become winners. Their sequence numbers still
  // advance the version vector, so one bad entry cannot stall replication from its author.
  static constexpr int64_t kMaxRemoteAheadMs = HlcClock::kMaxObserveAheadMs;
  uint64_t rejectedRemoteEntries() const { return rejected_remote_entries_; }

  // Discard this replica of a cluster's state, for unpair and revoke. Every entry and every
  // remote author's sequence knowledge is dropped locally, so a cluster joined afterwards is
  // re-fetched in full rather than merged into stale rows. Nothing is tombstoned: a tombstone
  // would replicate, and re-joining the same cluster would then delete the very entries this
  // replica had forgotten. The local author's sequence counter is preserved so writes made after
  // the reset never reuse an (author, seq) pair the old cluster may still hold.
  void resetReplica();



  std::string materializeJson(const std::string& prefix = "") const;

  void onChange(ChangeCb cb) { on_change_ = std::move(cb); }
  void onBatchChange(BatchChangeCb cb) { on_batch_change_ = std::move(cb); }
  void onCommit(CommitCb cb) { on_commit_ = std::move(cb); }
  bool lastMutationCommitted() const { return last_mutation_committed_; }
  const std::string& selfId() const { return self_id_; }

 private:
  // Rollback state for one tentative operation. Only the keys the operation touches are saved,
  // so a write costs O(touched keys + authors) instead of a copy of the whole map.
  struct StateSnapshot {
    std::map<std::string, std::optional<LwwEntry>> touched;
    VersionVector vv;
    std::map<std::string, std::set<uint64_t>> out_of_order_sequences;
    VersionVector durable_remote_frontier;
    uint64_t self_seq = 0;
  };

  class UndoScope;
  StateSnapshot snapshot() const;
  void restore(StateSnapshot&& state);
  void remember(const std::string& key);
  bool remoteHlcAcceptable(const std::string& hlc);
  bool commit(const std::vector<LwwEntry>& changed, bool is_local, bool batch);
  bool commit(const std::vector<LwwEntry>& durable_changed,
              const std::vector<LwwEntry>& visible_changed, bool is_local, bool batch);
  std::vector<LwwEntry> applyRemoteBatchImpl(const std::vector<LwwEntry>& entries,
                                             const VersionVector* complete_frontier);
  std::vector<LwwEntry> advanceDurableRemoteFrontiers();
  void observeSequence(const std::string& author, uint64_t seq);
  void trustSequencePrefix(const std::string& author, uint64_t seq);

  std::string self_id_;
  HlcClock& hlc_;
  std::map<std::string, LwwEntry> map_;
  VersionVector vv_;
  std::map<std::string, std::set<uint64_t>> out_of_order_sequences_;
  VersionVector durable_remote_frontier_;
  uint64_t self_seq_ = 0;
  LwwEntry rejected_entry_;
  StateSnapshot* undo_ = nullptr;
  uint64_t rejected_remote_entries_ = 0;
  bool last_mutation_committed_ = true;
  CommitCb on_commit_;
  ChangeCb on_change_;
  BatchChangeCb on_batch_change_;
};

}  // namespace db
