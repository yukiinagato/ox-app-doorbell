

#include "crdt/lww_map.h"

#include <algorithm>
#include <limits>
#include <set>
#include <tuple>

#include "util/json.h"

namespace db {

namespace {

// These records share the config transaction but never enter the user-visible CRDT map. The exact
// sentinel author and seq prevent an ordinary deleted config key from being treated as coverage.
constexpr char kCoverageMarkerPrefix[] = "__doorbell_internal.crdt_coverage.";
constexpr char kCoverageMarkerAuthor[] = "__doorbell_crdt_coverage_v1";


bool wins(const LwwEntry& a, const LwwEntry& b) {
  return std::tie(a.hlc, a.author) > std::tie(b.hlc, b.author);
}


bool covered(const VersionVector& vv, const LwwEntry& e) {
  auto it = vv.find(e.author);
  return it != vv.end() && it->second >= e.seq;
}

bool parseUint64(const std::string& text, uint64_t* out) {
  if (!out || text.empty()) return false;
  uint64_t value = 0;
  for (char c : text) {
    if (c < '0' || c > '9') return false;
    const uint64_t digit = static_cast<uint64_t>(c - '0');
    if (value > (std::numeric_limits<uint64_t>::max() - digit) / 10) return false;
    value = value * 10 + digit;
  }
  *out = value;
  return true;
}

bool parseCoverageMarker(const LwwEntry& entry, std::string* covered_author,
                         uint64_t* covered_seq) {
  if (!entry.deleted || entry.author != kCoverageMarkerAuthor || entry.seq != 0 ||
      entry.key.compare(0, sizeof(kCoverageMarkerPrefix) - 1, kCoverageMarkerPrefix) != 0 ||
      entry.key.size() == sizeof(kCoverageMarkerPrefix) - 1) {
    return false;
  }
  uint64_t seq = 0;
  if (!parseUint64(entry.value_json, &seq) || seq == 0) return false;
  if (covered_author)
    *covered_author = entry.key.substr(sizeof(kCoverageMarkerPrefix) - 1);
  if (covered_seq) *covered_seq = seq;
  return true;
}

LwwEntry makeCoverageMarker(const std::string& covered_author, uint64_t covered_seq) {
  LwwEntry marker;
  marker.key = std::string(kCoverageMarkerPrefix) + covered_author;
  marker.value_json = std::to_string(covered_seq);
  marker.deleted = true;
  marker.author = kCoverageMarkerAuthor;
  return marker;
}

}  // namespace

LwwMap::LwwMap(std::string self_id, HlcClock& hlc) : self_id_(std::move(self_id)), hlc_(hlc) {}

// Records rollback state for the lifetime of one tentative operation. Without a commit hook the
// operation cannot be rejected, so nothing is recorded.
class LwwMap::UndoScope {
 public:
  explicit UndoScope(LwwMap& map) : map_(map) {
    if (!map_.on_commit_) return;
    state_.emplace(map_.snapshot());
    map_.undo_ = &*state_;
  }
  ~UndoScope() { map_.undo_ = nullptr; }
  void rollback() {
    map_.undo_ = nullptr;
    if (state_) map_.restore(std::move(*state_));
  }

 private:
  LwwMap& map_;
  std::optional<StateSnapshot> state_;
};

LwwMap::StateSnapshot LwwMap::snapshot() const {
  return {{}, vv_, out_of_order_sequences_, durable_remote_frontier_, self_seq_};
}

void LwwMap::remember(const std::string& key) {
  if (!undo_ || undo_->touched.count(key)) return;
  auto it = map_.find(key);
  undo_->touched.emplace(key, it == map_.end() ? std::nullopt
                                               : std::optional<LwwEntry>(it->second));
}

bool LwwMap::remoteHlcAcceptable(const std::string& hlc) {
  int64_t physical = 0;
  int counter = 0;
  std::string node8;
  if (hlc.size() > 64 || !HlcClock::parse(hlc, &physical, &counter, &node8) ||
      HlcClock::format(physical, counter, node8) != hlc)
    return false;
  return physical <= hlc_.correctedWallMs() + kMaxRemoteAheadMs;
}

void LwwMap::restore(StateSnapshot&& state) {
  for (auto& [key, previous] : state.touched) {
    if (previous) {
      map_[key] = std::move(*previous);
    } else {
      map_.erase(key);
    }
  }
  vv_ = std::move(state.vv);
  out_of_order_sequences_ = std::move(state.out_of_order_sequences);
  durable_remote_frontier_ = std::move(state.durable_remote_frontier);
  self_seq_ = state.self_seq;
}

bool LwwMap::commit(const std::vector<LwwEntry>& changed, bool is_local, bool batch) {
  return commit(changed, changed, is_local, batch);
}

bool LwwMap::commit(const std::vector<LwwEntry>& durable_changed,
                    const std::vector<LwwEntry>& visible_changed, bool is_local, bool batch) {
  if (on_commit_ &&
      !on_commit_(durable_changed, is_local, batch || durable_changed.size() > 1)) {
    return false;
  }
  if (visible_changed.empty()) return true;
  if ((batch || visible_changed.size() > 1) && on_batch_change_) {
    on_batch_change_(visible_changed, is_local);
  } else if (on_change_) {
    for (const auto& e : visible_changed) on_change_(e, is_local);
  }
  return true;
}

std::vector<LwwEntry> LwwMap::advanceDurableRemoteFrontiers() {
  std::vector<LwwEntry> markers;
  for (const auto& [author, seq] : vv_) {
    if (author.empty() || author == self_id_ || seq == 0) continue;
    uint64_t& durable = durable_remote_frontier_[author];
    if (seq <= durable) continue;
    durable = seq;
    markers.push_back(makeCoverageMarker(author, seq));
  }
  return markers;
}

void LwwMap::observeSequence(const std::string& author, uint64_t seq) {
  if (author.empty() || seq == 0) return;

  uint64_t& frontier = vv_[author];
  if (seq <= frontier) return;

  auto pending_it = out_of_order_sequences_.try_emplace(author).first;
  pending_it->second.insert(seq);
  while (frontier != std::numeric_limits<uint64_t>::max()) {
    const auto next = pending_it->second.find(frontier + 1);
    if (next == pending_it->second.end()) break;
    pending_it->second.erase(next);
    ++frontier;
  }
  if (pending_it->second.empty()) out_of_order_sequences_.erase(pending_it);
}

void LwwMap::trustSequencePrefix(const std::string& author, uint64_t seq) {
  if (author.empty() || seq == 0) return;

  uint64_t& frontier = vv_[author];
  frontier = std::max(frontier, seq);
  auto pending_it = out_of_order_sequences_.find(author);
  if (pending_it == out_of_order_sequences_.end()) return;

  auto& pending = pending_it->second;
  pending.erase(pending.begin(), pending.upper_bound(frontier));
  while (frontier != std::numeric_limits<uint64_t>::max()) {
    const auto next = pending.find(frontier + 1);
    if (next == pending.end()) break;
    pending.erase(next);
    ++frontier;
  }
  if (pending.empty()) out_of_order_sequences_.erase(pending_it);
}

void LwwMap::load(const std::vector<LwwEntry>& entries) {
  VersionVector trusted_frontier;
  for (const LwwEntry& e : entries) {
    std::string covered_author;
    uint64_t covered_seq = 0;
    if (parseCoverageMarker(e, &covered_author, &covered_seq)) {
      uint64_t& trusted = trusted_frontier[covered_author];
      trusted = std::max(trusted, covered_seq);
      uint64_t& durable = durable_remote_frontier_[covered_author];
      durable = std::max(durable, covered_seq);
      continue;
    }
    hlc_.observePersisted(e.hlc);
    if (e.author == self_id_) {
      self_seq_ = std::max(self_seq_, e.seq);
      // A persisted mutation authored by this replica proves that every earlier local sequence
      // was allocated, even when an overwritten value is no longer present in the state map.
      trustSequencePrefix(e.author, e.seq);
    } else {
      observeSequence(e.author, e.seq);
    }
    auto it = map_.find(e.key);
    if (it == map_.end()) {
      map_.emplace(e.key, e);
    } else if (wins(e, it->second)) {
      it->second = e;
    }
  }
  for (const auto& [author, seq] : trusted_frontier) trustSequencePrefix(author, seq);
}

const LwwEntry& LwwMap::set(const std::string& key, const std::string& value_json) {
  UndoScope undo(*this);
  LwwEntry e;
  e.key = key;
  e.value_json = value_json;
  e.hlc = hlc_.tick();
  e.author = self_id_;
  e.seq = ++self_seq_;
  trustSequencePrefix(self_id_, self_seq_);
  remember(key);
  LwwEntry& slot = map_[key];
  slot = std::move(e);
  const std::vector<LwwEntry> changed{slot};
  if (!commit(changed, true, false)) {
    rejected_entry_ = changed.front();
    undo.rollback();
    last_mutation_committed_ = false;
    return rejected_entry_;
  }
  last_mutation_committed_ = true;
  return slot;
}

const LwwEntry& LwwMap::remove(const std::string& key) {
  UndoScope undo(*this);
  LwwEntry e;
  e.key = key;
  e.deleted = true;
  e.hlc = hlc_.tick();
  e.author = self_id_;
  e.seq = ++self_seq_;
  trustSequencePrefix(self_id_, self_seq_);
  remember(key);
  LwwEntry& slot = map_[key];
  slot = std::move(e);
  const std::vector<LwwEntry> changed{slot};
  if (!commit(changed, true, false)) {
    rejected_entry_ = changed.front();
    undo.rollback();
    last_mutation_committed_ = false;
    return rejected_entry_;
  }
  last_mutation_committed_ = true;
  return slot;
}

std::vector<LwwEntry> LwwMap::mutate(const std::vector<LwwMutation>& mutations) {
  UndoScope undo(*this);
  std::vector<LwwEntry> changed;
  changed.reserve(mutations.size());
  for (const auto& mutation : mutations) {
    LwwEntry e;
    e.key = mutation.key;
    e.value_json = mutation.deleted ? "" : mutation.value_json;
    e.deleted = mutation.deleted;
    e.hlc = hlc_.tick();
    e.author = self_id_;
    e.seq = ++self_seq_;
    trustSequencePrefix(self_id_, self_seq_);
    remember(e.key);
    LwwEntry& slot = map_[e.key];
    slot = std::move(e);
    changed.push_back(slot);
  }
  if (!changed.empty() && !commit(changed, true, true)) {
    undo.rollback();
    last_mutation_committed_ = false;
    return {};
  }
  last_mutation_committed_ = true;
  return changed;
}

std::string LwwMap::seedHlc() const { return HlcClock::format(0, 0, self_id_.substr(0, 8)); }

std::vector<LwwEntry> LwwMap::seed(const std::vector<LwwMutation>& mutations) {
  UndoScope undo(*this);
  std::vector<LwwEntry> changed;
  for (const auto& mutation : mutations) {
    if (mutation.deleted || map_.count(mutation.key)) continue;
    LwwEntry e;
    e.key = mutation.key;
    e.value_json = mutation.value_json;
    e.hlc = seedHlc();
    e.author = self_id_;
    e.seq = ++self_seq_;
    trustSequencePrefix(self_id_, self_seq_);
    remember(e.key);
    LwwEntry& slot = map_[e.key];
    slot = std::move(e);
    changed.push_back(slot);
  }
  if (!changed.empty() && !commit(changed, true, true)) {
    undo.rollback();
    last_mutation_committed_ = false;
    return {};
  }
  last_mutation_committed_ = true;
  return changed;
}

bool LwwMap::applyRemote(const LwwEntry& e) {
  if (parseCoverageMarker(e, nullptr, nullptr)) return false;
  UndoScope undo(*this);
  observeSequence(e.author, e.seq);
  bool winner_changed = false;
  std::vector<LwwEntry> changed;
  if (!remoteHlcAcceptable(e.hlc)) {
    ++rejected_remote_entries_;
  } else {
    hlc_.observe(e.hlc);
    auto it = map_.find(e.key);
    if (it == map_.end() || wins(e, it->second)) {
      remember(e.key);
      map_[e.key] = e;
      winner_changed = true;
      changed.push_back(e);
    }
  }
  std::vector<LwwEntry> durable_changed = changed;
  auto markers = advanceDurableRemoteFrontiers();
  durable_changed.insert(durable_changed.end(), markers.begin(), markers.end());
  if (!durable_changed.empty() && !commit(durable_changed, changed, false, false)) {
    undo.rollback();
    last_mutation_committed_ = false;
    return false;
  }
  last_mutation_committed_ = true;
  return winner_changed;
}

std::vector<LwwEntry> LwwMap::applyRemoteBatch(const std::vector<LwwEntry>& entries) {
  return applyRemoteBatchImpl(entries, nullptr);
}

std::vector<LwwEntry> LwwMap::applyRemoteSnapshot(
    const std::vector<LwwEntry>& entries, const VersionVector& complete_frontier) {
  return applyRemoteBatchImpl(entries, &complete_frontier);
}

std::vector<LwwEntry> LwwMap::applyRemoteBatchImpl(
    const std::vector<LwwEntry>& entries, const VersionVector* complete_frontier) {
  UndoScope undo(*this);
  std::set<std::string> changed_keys;
  for (const auto& e : entries) {
    if (parseCoverageMarker(e, nullptr, nullptr)) continue;
    observeSequence(e.author, e.seq);
    if (!remoteHlcAcceptable(e.hlc)) {
      ++rejected_remote_entries_;
      continue;
    }
    hlc_.observe(e.hlc);
    auto it = map_.find(e.key);
    if (it != map_.end() && !wins(e, it->second)) continue;
    remember(e.key);
    map_[e.key] = e;
    changed_keys.insert(e.key);
  }
  if (complete_frontier) {
    for (const auto& [author, seq] : *complete_frontier) {
      if (author != self_id_) trustSequencePrefix(author, seq);
    }
  }
  std::vector<LwwEntry> changed;
  changed.reserve(changed_keys.size());
  for (const auto& key : changed_keys) changed.push_back(map_.at(key));
  std::vector<LwwEntry> durable_changed = changed;
  auto markers = advanceDurableRemoteFrontiers();
  durable_changed.insert(durable_changed.end(), markers.begin(), markers.end());
  if (!durable_changed.empty() && !commit(durable_changed, changed, false, true)) {
    undo.rollback();
    last_mutation_committed_ = false;
    return {};
  }
  last_mutation_committed_ = true;
  return changed;
}

std::optional<std::string> LwwMap::get(const std::string& key) const {
  auto it = map_.find(key);
  if (it == map_.end() || it->second.deleted) return std::nullopt;
  return it->second.value_json;
}

std::vector<std::pair<std::string, std::string>> LwwMap::byPrefix(const std::string& prefix) const {
  std::vector<std::pair<std::string, std::string>> out;

  for (auto it = map_.lower_bound(prefix); it != map_.end(); ++it) {
    if (it->first.compare(0, prefix.size(), prefix) != 0) break;
    if (!it->second.deleted) out.emplace_back(it->first, it->second.value_json);
  }
  return out;
}

void LwwMap::resetReplica() {
  map_.clear();
  vv_.clear();
  out_of_order_sequences_.clear();
  durable_remote_frontier_.clear();
  // Keep our own contiguous prefix: the identity survives unpair, so a later write must not
  // reuse a sequence number the previous cluster still associates with different content.
  if (self_seq_ > 0) vv_[self_id_] = self_seq_;
  last_mutation_committed_ = true;
}

VersionVector LwwMap::versionVector() const { return vv_; }

std::vector<LwwEntry> LwwMap::deltaSince(const VersionVector& remote_vv) const {
  std::vector<LwwEntry> out;
  for (const auto& kv : map_) {
    const LwwEntry& e = kv.second;
    auto it = remote_vv.find(e.author);
    uint64_t known = (it == remote_vv.end()) ? 0 : it->second;
    if (e.seq > known) out.push_back(e);
  }

  std::sort(out.begin(), out.end(), [](const LwwEntry& a, const LwwEntry& b) {
    return std::tie(a.author, a.seq) < std::tie(b.author, b.seq);
  });
  return out;
}

std::vector<LwwEntry> LwwMap::all() const {
  std::vector<LwwEntry> out;
  out.reserve(map_.size());
  for (const auto& kv : map_) out.push_back(kv.second);
  return out;
}

std::vector<std::string> LwwMap::gcTombstones(
    const VersionVector& fleet_min_vv, const std::string& older_than_hlc,
    const std::function<bool(const std::string&)>& keep) {
  std::vector<std::string> erased;
  for (auto it = map_.begin(); it != map_.end();) {
    const LwwEntry& e = it->second;
    bool removable = e.deleted && e.hlc < older_than_hlc && covered(fleet_min_vv, e) &&
                     !(keep && keep(e.key));
    if (removable) {
      // A live descendant this tombstone dominates is hidden only by this tombstone.
      const std::string child_prefix = e.key + ".";
      for (auto child = map_.lower_bound(child_prefix);
           child != map_.end() && child->first.compare(0, child_prefix.size(), child_prefix) == 0;
           ++child) {
        if (!child->second.deleted && wins(e, child->second)) {
          removable = false;
          break;
        }
      }
    }
    if (removable) {
      // An older live ancestor object would regain the member this tombstone removed.
      for (size_t dot = e.key.find('.'); dot != std::string::npos;
           dot = e.key.find('.', dot + 1)) {
        auto ancestor = map_.find(e.key.substr(0, dot));
        if (ancestor != map_.end() && !ancestor->second.deleted && wins(e, ancestor->second)) {
          removable = false;
          break;
        }
      }
    }
    if (removable) {
      erased.push_back(it->first);
      it = map_.erase(it);
    } else {
      ++it;
    }
  }
  return erased;
}

std::string LwwMap::materializeJson(const std::string& prefix) const {
  auto root = json::obj();


  for (auto it = map_.lower_bound(prefix); it != map_.end(); ++it) {
    if (it->first.compare(0, prefix.size(), prefix) != 0) break;
    const LwwEntry& e = it->second;
    if (e.deleted || e.key == "_config_changes" || e.key.rfind("_config_changes.", 0) == 0) continue;
    bool hidden = false;
    for (size_t dot = e.key.find('.'); dot != std::string::npos;
         dot = e.key.find('.', dot + 1)) {
      auto ancestor = map_.find(e.key.substr(0, dot));
      if (ancestor != map_.end() && ancestor->second.deleted &&
          std::tie(ancestor->second.hlc, ancestor->second.author) >= std::tie(e.hlc, e.author)) {
        hidden = true;
        break;
      }
    }
    if (hidden) continue;
    std::string rest = it->first.substr(prefix.size());
    if (!rest.empty() && rest[0] == '.') rest.erase(0, 1);

    std::vector<std::string> segs;
    size_t pos = 0;
    while (pos <= rest.size()) {
      size_t dot = rest.find('.', pos);
      if (dot == std::string::npos) dot = rest.size();
      if (dot > pos) segs.push_back(rest.substr(pos, dot - pos));
      pos = dot + 1;
    }
    if (segs.empty()) continue;
    cJSON* node = root.get();
    for (size_t i = 0; i + 1 < segs.size(); ++i) {
      cJSON* child = json::get(node, segs[i].c_str());
      if (!child || !cJSON_IsObject(child)) {

        child = json::addObj(node, segs[i].c_str());
      }
      node = child;
    }
    const char* leaf = segs.back().c_str();
    bool newer_parent_object = false;
    if (cJSON_IsObject(json::get(node, leaf))) {
      for (size_t dot = e.key.find('.'); dot != std::string::npos;
           dot = e.key.find('.', dot + 1)) {
        auto ancestor = map_.find(e.key.substr(0, dot));
        if (ancestor == map_.end() || ancestor->second.deleted || !wins(ancestor->second, e))
          continue;
        auto value = json::parse(ancestor->second.value_json);
        const cJSON* embedded = value.get();
        size_t begin = dot + 1;
        while (embedded && begin < e.key.size()) {
          size_t end = e.key.find('.', begin);
          embedded = json::get(embedded, e.key.substr(begin, end - begin).c_str());
          if (end == std::string::npos) break;
          begin = end + 1;
        }
        if (cJSON_IsObject(embedded)) { newer_parent_object = true; break; }
      }
    }
    if (newer_parent_object) continue;
    json::Doc val = json::parse(e.value_json);
    if (!val) val = json::Doc(cJSON_CreateString(e.value_json.c_str()));
    // A child tombstone also removes a member embedded in an older parent object.
    const std::string child_prefix = e.key + ".";
    for (auto child = map_.lower_bound(child_prefix); child != map_.end() &&
         child->first.compare(0, child_prefix.size(), child_prefix) == 0; ++child) {
      if (!child->second.deleted ||
          std::tie(child->second.hlc, child->second.author) < std::tie(e.hlc, e.author)) continue;
      std::string path = child->first.substr(child_prefix.size());
      cJSON* parent = val.get();
      size_t dot;
      while (parent && (dot = path.find('.')) != std::string::npos) {
        parent = json::get(parent, path.substr(0, dot).c_str());
        path.erase(0, dot + 1);
      }
      if (cJSON_IsObject(parent)) cJSON_DeleteItemFromObjectCaseSensitive(parent, path.c_str());
    }
    json::setItem(node, leaf, std::move(val));
  }
  return json::dump(root.get());
}

}  // namespace db
