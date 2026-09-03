


#include "store/store.h"

#include <algorithm>
#include <cstdio>
#include <ctime>
#include <limits>

#include "sqlite3.h"
#include "util/hlc.h"
#include "util/json.h"
#include "util/log.h"

namespace db {
namespace {

constexpr const char* kTag = "store";
constexpr int kSchemaVersion = 7;

bool isCorruptionCode(int code) {
  const int primary = code & 0xff;
  return primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB;
}

bool corruptionConfirmed(sqlite3* db) {
  if (!db || !isCorruptionCode(sqlite3_extended_errcode(db))) return false;
  sqlite3_stmt* statement = nullptr;
  const int prepare = sqlite3_prepare_v2(db, "PRAGMA quick_check(1)", -1, &statement, nullptr);
  if (prepare != SQLITE_OK) {
    if (statement) sqlite3_finalize(statement);
    return isCorruptionCode(sqlite3_extended_errcode(db));
  }
  const int step = sqlite3_step(statement);
  bool corrupt = false;
  if (step == SQLITE_ROW) {
    const unsigned char* result = sqlite3_column_text(statement, 0);
    corrupt = !result || std::string(reinterpret_cast<const char*>(result)) != "ok";
  } else {
    corrupt = isCorruptionCode(sqlite3_extended_errcode(db));
  }
  sqlite3_finalize(statement);
  return corrupt;
}

bool storeFileExists(const std::string& path) {
  FILE* file = std::fopen(path.c_str(), "rb");
  if (!file) return false;
  std::fclose(file);
  return true;
}

class Stmt {
 public:
  Stmt(sqlite3* db, const char* sql) : db_(db) {
    if (!db_) return;
    if (sqlite3_prepare_v2(db_, sql, -1, &st_, nullptr) != SQLITE_OK) {
      DB_LOGE(kTag, std::string("prepare failed: ") + sqlite3_errmsg(db_));
      st_ = nullptr;
    }
  }
  ~Stmt() {
    if (st_) sqlite3_finalize(st_);
  }
  Stmt(const Stmt&) = delete;
  Stmt& operator=(const Stmt&) = delete;

  bool ok() const { return st_ != nullptr; }
  void bind(int i, const std::string& v) {
    sqlite3_bind_text(st_, i, v.c_str(), -1, SQLITE_TRANSIENT);
  }
  void bind(int i, int64_t v) { sqlite3_bind_int64(st_, i, v); }
  void bindBlob(int i, const Bytes& v) {
    sqlite3_bind_blob(st_, i, v.empty() ? "" : reinterpret_cast<const char*>(v.data()),
                      static_cast<int>(v.size()), SQLITE_TRANSIENT);
  }
  int step() { return st_ ? sqlite3_step(st_) : SQLITE_ERROR; }
  std::string colText(int i) {
    const unsigned char* t = sqlite3_column_text(st_, i);
    return t ? reinterpret_cast<const char*>(t) : "";
  }
  int64_t colInt(int i) { return sqlite3_column_int64(st_, i); }
  Bytes colBlob(int i) {
    const void* p = sqlite3_column_blob(st_, i);
    const int n = sqlite3_column_bytes(st_, i);
    if (!p || n <= 0) return {};
    const uint8_t* b = static_cast<const uint8_t*>(p);
    return Bytes(b, b + n);
  }

 private:
  sqlite3* db_ = nullptr;
  sqlite3_stmt* st_ = nullptr;
};


EventRecord rowToEvent(Stmt& st) {
  EventRecord e;
  e.origin = st.colText(0);
  e.seq = static_cast<uint64_t>(st.colInt(1));
  e.type = st.colText(2);
  e.door = st.colText(3);
  e.device = st.colText(4);
  e.hlc = st.colText(5);
  e.wall_ms = st.colInt(6);
  e.payload_json = st.colText(7);
  e.notify_json = st.colText(8);
  return e;
}

constexpr const char* kEventCols =
    "origin,seq,type,door,device,hlc,wall_ms,payload_json,notify_json";

}  // namespace

Store::~Store() { close(); }

bool Store::open(const std::string& path) {
  std::lock_guard<std::mutex> lk(mu_);
  closeLocked();

  int failure_code = SQLITE_OK;
  bool confirmed_corruption = false;
  auto tryOpen = [&]() -> bool {
    const int opened = sqlite3_open(path.c_str(), &db_);
    if (opened != SQLITE_OK) {
      failure_code = db_ ? sqlite3_extended_errcode(db_) : opened;
      confirmed_corruption = corruptionConfirmed(db_);
      return false;
    }
    sqlite3_busy_timeout(db_, 3000);
    if (!exec("PRAGMA journal_mode=WAL;") || !migrate()) {
      failure_code = sqlite3_extended_errcode(db_);
      confirmed_corruption = corruptionConfirmed(db_);
      return false;
    }
    return true;
  };
  if (tryOpen()) return true;
  closeLocked();
  if (path == ":memory:" || !isCorruptionCode(failure_code) || !confirmed_corruption) {
    DB_LOGE(kTag, "database open failed without confirmed corruption; refusing to replace it");
    return false;
  }

  const std::string base =
      path + ".corrupt-" + std::to_string(static_cast<long long>(std::time(nullptr)));
  std::string backup = base;
  for (int suffix = 1; storeFileExists(backup); ++suffix)
    backup = base + "-" + std::to_string(suffix);
  const std::string wal = path + "-wal";
  const std::string shm = path + "-shm";
  const bool had_wal = storeFileExists(wal);
  const bool had_shm = storeFileExists(shm);
  if (std::rename(path.c_str(), backup.c_str()) != 0) {
    DB_LOGE(kTag, "confirmed corrupt database could not be moved aside safely");
    return false;
  }
  const bool moved_wal = !had_wal || std::rename(wal.c_str(), (backup + "-wal").c_str()) == 0;
  const bool moved_shm = !had_shm || std::rename(shm.c_str(), (backup + "-shm").c_str()) == 0;
  if (!moved_wal || !moved_shm) {
    if (moved_wal && had_wal) std::rename((backup + "-wal").c_str(), wal.c_str());
    if (moved_shm && had_shm) std::rename((backup + "-shm").c_str(), shm.c_str());
    std::rename(backup.c_str(), path.c_str());
    DB_LOGE(kTag, "confirmed corrupt database sidecars could not be moved aside safely");
    return false;
  }
  DB_LOGW(kTag, "database could not be opened; backed up and recreated: " + backup);
  failure_code = SQLITE_OK;
  confirmed_corruption = false;
  if (tryOpen()) return true;
  closeLocked();
  return false;
}

void Store::close() {
  std::lock_guard<std::mutex> lk(mu_);
  closeLocked();
}


void Store::closeLocked() {
  if (db_) {
    sqlite3_close(db_);
    db_ = nullptr;
  }
}

bool Store::exec(const char* sql) {
  if (!db_) return false;
  char* err = nullptr;
  if (sqlite3_exec(db_, sql, nullptr, nullptr, &err) != SQLITE_OK) {
    DB_LOGE(kTag, std::string("SQL failed: ") + (err ? err : sqlite3_errmsg(db_)));
    sqlite3_free(err);
    return false;
  }
  return true;
}

bool Store::migrate() {
  const char* ddl =
      "CREATE TABLE IF NOT EXISTS meta("
      "  key TEXT PRIMARY KEY, value TEXT);"
      "CREATE TABLE IF NOT EXISTS config("
      "  key TEXT PRIMARY KEY, value_json TEXT, deleted INT, hlc TEXT, author TEXT, seq INT);"
      "CREATE TABLE IF NOT EXISTS events("
      "  origin TEXT, seq INT, type TEXT, door TEXT, device TEXT, hlc TEXT, wall_ms INT,"
      "  payload_json TEXT, notify_json TEXT, PRIMARY KEY(origin, seq));"
      "CREATE INDEX IF NOT EXISTS idx_events_hlc ON events(hlc);"
      "CREATE TABLE IF NOT EXISTS event_origin_state("
      "  origin TEXT PRIMARY KEY, frontier INT NOT NULL, max_seq INT NOT NULL,"
      "  dispatch_frontier INT NOT NULL DEFAULT 0);"
      "CREATE TABLE IF NOT EXISTS tg_queue("
      "  id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT, chat_id TEXT, payload TEXT,"
      "  snapshot BLOB, attempts INT, next_retry_ms INT, created_ms INT);"
      "CREATE TABLE IF NOT EXISTS net_probe("
      "  ts_ms INT, target TEXT, host TEXT, ok INT, rtt_ms INT);"
      "CREATE INDEX IF NOT EXISTS idx_net_probe_ts ON net_probe(ts_ms);"
      "CREATE TABLE IF NOT EXISTS call_projection("
      "  call_id TEXT PRIMARY KEY, door TEXT NOT NULL, origin TEXT NOT NULL, purpose TEXT,"
      "  state TEXT NOT NULL, stage_revision INT NOT NULL, expires_wall_ms INT NOT NULL,"
      "  updated_hlc TEXT NOT NULL, terminal_reason TEXT,"
      "  press_wall_ms INT NOT NULL DEFAULT 0, press_seq INT NOT NULL DEFAULT 0,"
      "  answered_wall_ms INT NOT NULL DEFAULT 0,"
      "  ended_wall_ms INT NOT NULL DEFAULT 0, visitor_lang TEXT NOT NULL DEFAULT '',"
      "  snapshot_hash TEXT NOT NULL DEFAULT '');"
      "CREATE INDEX IF NOT EXISTS idx_call_projection_active"
      "  ON call_projection(state, door);"
      "CREATE TABLE IF NOT EXISTS call_door_fence("
      "  door TEXT PRIMARY KEY, call_id TEXT NOT NULL, hlc TEXT NOT NULL);";
  if (!exec(ddl)) return false;




  auto schema = metaGetLocked("schema_version");
  int previous_schema = 0;
  if (schema) {
    try {
      previous_schema = std::stoi(*schema);
    } catch (...) {
      previous_schema = 0;
    }
  }
  auto has_column = [this](const std::string& table, const std::string& name) {
    const std::string sql = "PRAGMA table_info(" + table + ")";
    Stmt columns(db_, sql.c_str());
    if (!columns.ok()) return false;
    while (columns.step() == SQLITE_ROW)
      if (columns.colText(1) == name) return true;
    return false;
  };
  if (previous_schema < 3) {
    if (!has_column("call_projection", "dialog_owner") &&
        !exec("ALTER TABLE call_projection ADD COLUMN dialog_owner TEXT NOT NULL DEFAULT ''"))
      return false;
    if (!has_column("call_projection", "answered_hlc") &&
        !exec("ALTER TABLE call_projection ADD COLUMN answered_hlc TEXT NOT NULL DEFAULT ''"))
      return false;
  }
  if (previous_schema < 4) {
    if (!exec("DELETE FROM event_origin_state")) return false;
    std::map<std::string, std::pair<uint64_t, uint64_t>> states;
    Stmt events(db_, "SELECT origin,seq FROM events ORDER BY origin ASC,seq ASC");
    if (!events.ok()) return false;
    while (events.step() == SQLITE_ROW) {
      const std::string origin = events.colText(0);
      const int64_t raw_seq = events.colInt(1);
      if (origin.empty() || raw_seq <= 0) continue;
      const uint64_t seq = static_cast<uint64_t>(raw_seq);
      auto& state = states[origin];
      state.second = std::max(state.second, seq);
      if (seq == state.first + 1) state.first = seq;
    }
    for (const auto& item : states) {
      Stmt insert(db_,
                  "INSERT INTO event_origin_state(origin,frontier,max_seq) VALUES(?1,?2,?3)");
      if (!insert.ok()) return false;
      insert.bind(1, item.first);
      insert.bind(2, static_cast<int64_t>(item.second.first));
      insert.bind(3, static_cast<int64_t>(item.second.second));
      if (insert.step() != SQLITE_DONE) return false;
    }
  }
  if (previous_schema < 4) {
    std::vector<EventRecord> lifecycle;
    Stmt events(db_,
                "SELECT e.origin,e.seq,e.type,e.door,e.device,e.hlc,e.wall_ms,"
                " e.payload_json,e.notify_json FROM events e"
                " JOIN event_origin_state s ON s.origin=e.origin"
                " WHERE e.seq<=s.frontier ORDER BY e.hlc ASC");
    if (!events.ok()) return false;
    while (events.step() == SQLITE_ROW) lifecycle.push_back(rowToEvent(events));
    if (!exec("BEGIN IMMEDIATE") || !exec("DELETE FROM call_projection")) {
      exec("ROLLBACK");
      return false;
    }
    for (const auto& event : lifecycle) {
      if (!applyCallProjectionLocked(event)) {
        exec("ROLLBACK");
        return false;
      }
    }
    if (!exec("COMMIT")) {
      exec("ROLLBACK");
      return false;
    }
  }
  if (previous_schema < 5) {
    if (!has_column("event_origin_state", "dispatch_frontier") &&
        !exec("ALTER TABLE event_origin_state ADD COLUMN dispatch_frontier"
              " INT NOT NULL DEFAULT 0"))
      return false;
    // Schema v4 invoked callbacks before any durable acknowledgement existed. Treat its applied
    // frontier as already dispatched so upgrading cannot replay the complete event history.
    if (!exec("UPDATE event_origin_state SET dispatch_frontier=frontier")) return false;
  }
  if (previous_schema < 6) {
    if (!exec(
            "INSERT OR REPLACE INTO call_door_fence(door,call_id,hlc)"
            " SELECT p.door,p.call_id,p.updated_hlc FROM call_projection p"
            " WHERE (p.state='cancelled' OR (p.state='ended' AND"
            " p.terminal_reason NOT IN ('concurrent_press_loser',"
            " 'concurrent_answer_loser','terminal_fence')))"
            " AND NOT EXISTS (SELECT 1 FROM call_projection newer"
            " WHERE newer.door=p.door AND (newer.state='cancelled' OR"
            " (newer.state='ended' AND newer.terminal_reason NOT IN"
            " ('concurrent_press_loser','concurrent_answer_loser','terminal_fence')))"
            " AND (newer.updated_hlc>p.updated_hlc OR"
            " (newer.updated_hlc=p.updated_hlc AND newer.call_id<p.call_id)));"
            "UPDATE call_projection SET state='ended',terminal_reason='terminal_fence'"
            " WHERE state='ringing' AND EXISTS (SELECT 1 FROM call_door_fence f"
            " WHERE f.door=call_projection.door AND f.hlc>=call_projection.updated_hlc);"))
      return false;
  }
  if (previous_schema < 7) {
    // Call history needs wall clocks, the visitor language, and the door snapshot reference that
    // schema v6 never materialized. Add the columns, then rebuild the projection and its door
    // fence by replaying every applied lifecycle event, exactly as the v4 backfill did.
    const char* const kCallLogColumns[] = {"press_wall_ms", "press_seq", "answered_wall_ms",
                                          "ended_wall_ms"};
    for (const char* column : kCallLogColumns) {
      if (has_column("call_projection", column)) continue;
      const std::string sql = std::string("ALTER TABLE call_projection ADD COLUMN ") + column +
                              " INT NOT NULL DEFAULT 0";
      if (!exec(sql.c_str())) return false;
    }
    for (const char* column : {"visitor_lang", "snapshot_hash"}) {
      if (has_column("call_projection", column)) continue;
      const std::string sql = std::string("ALTER TABLE call_projection ADD COLUMN ") + column +
                              " TEXT NOT NULL DEFAULT ''";
      if (!exec(sql.c_str())) return false;
    }
    std::vector<EventRecord> lifecycle;
    Stmt events(db_,
                "SELECT e.origin,e.seq,e.type,e.door,e.device,e.hlc,e.wall_ms,"
                " e.payload_json,e.notify_json FROM events e"
                " JOIN event_origin_state s ON s.origin=e.origin"
                " WHERE e.seq<=s.frontier ORDER BY e.hlc ASC");
    if (!events.ok()) return false;
    while (events.step() == SQLITE_ROW) lifecycle.push_back(rowToEvent(events));
    if (!exec("BEGIN IMMEDIATE") || !exec("DELETE FROM call_projection") ||
        !exec("DELETE FROM call_door_fence")) {
      exec("ROLLBACK");
      return false;
    }
    for (const auto& event : lifecycle) {
      if (!applyCallProjectionLocked(event)) {
        exec("ROLLBACK");
        return false;
      }
    }
    if (!exec("COMMIT")) {
      exec("ROLLBACK");
      return false;
    }
  }
  if ((!schema || *schema != std::to_string(kSchemaVersion)) &&
      !metaSetLocked("schema_version", std::to_string(kSchemaVersion)))
    return false;

  if (!metaGetLocked("stat_press_total") &&
      !metaSetLocked("stat_press_total", std::to_string(countEventsOfTypeLocked("press"))))
    return false;
  return true;
}

// --- meta ---


std::optional<std::string> Store::metaGetLocked(const std::string& key) {
  Stmt st(db_, "SELECT value FROM meta WHERE key=?1");
  if (!st.ok()) return std::nullopt;
  st.bind(1, key);
  if (st.step() != SQLITE_ROW) return std::nullopt;
  return st.colText(0);
}

bool Store::metaSetLocked(const std::string& key, const std::string& value) {
  Stmt st(db_, "INSERT OR REPLACE INTO meta(key,value) VALUES(?1,?2)");
  if (!st.ok()) return false;
  st.bind(1, key);
  st.bind(2, value);
  return st.step() == SQLITE_DONE;
}

std::optional<std::string> Store::metaGet(const std::string& key) {
  std::lock_guard<std::mutex> lk(mu_);
  return metaGetLocked(key);
}

bool Store::metaSet(const std::string& key, const std::string& value) {
  std::lock_guard<std::mutex> lk(mu_);
  return metaSetLocked(key, value);
}

bool Store::metaSetBatch(
    const std::vector<std::pair<std::string, std::string>>& entries) {
  if (entries.empty()) return true;
  std::lock_guard<std::mutex> lk(mu_);
  if (!db_ || !exec("BEGIN IMMEDIATE")) return false;
  for (const auto& entry : entries) {
    if (!metaSetLocked(entry.first, entry.second)) {
      exec("ROLLBACK");
      return false;
    }
  }
  if (!exec("COMMIT")) {
    exec("ROLLBACK");
    return false;
  }
  return true;
}

// --- config ---

bool Store::configPut(const LwwEntry& e) {
  std::lock_guard<std::mutex> lk(mu_);
  Stmt st(db_,
          "INSERT OR REPLACE INTO config(key,value_json,deleted,hlc,author,seq)"
          " VALUES(?1,?2,?3,?4,?5,?6)");
  if (!st.ok()) return false;
  st.bind(1, e.key);
  st.bind(2, e.value_json);
  st.bind(3, static_cast<int64_t>(e.deleted ? 1 : 0));
  st.bind(4, e.hlc);
  st.bind(5, e.author);
  st.bind(6, static_cast<int64_t>(e.seq));
  return st.step() == SQLITE_DONE;
}

bool Store::configPutBatch(const std::vector<LwwEntry>& entries) {
  if (entries.empty()) return true;
  std::lock_guard<std::mutex> lk(mu_);
  if (!db_ || !exec("BEGIN IMMEDIATE")) return false;
  bool ok = true;
  for (const auto& e : entries) {
    Stmt st(db_,
            "INSERT OR REPLACE INTO config(key,value_json,deleted,hlc,author,seq)"
            " VALUES(?1,?2,?3,?4,?5,?6)");
    if (!st.ok()) {
      ok = false;
      break;
    }
    st.bind(1, e.key);
    st.bind(2, e.value_json);
    st.bind(3, static_cast<int64_t>(e.deleted ? 1 : 0));
    st.bind(4, e.hlc);
    st.bind(5, e.author);
    st.bind(6, static_cast<int64_t>(e.seq));
    if (st.step() != SQLITE_DONE) {
      ok = false;
      break;
    }
  }
  if (!ok) {
    exec("ROLLBACK");
    return false;
  }
  if (!exec("COMMIT")) {
    exec("ROLLBACK");
    return false;
  }
  return true;
}

void Store::configDelete(const std::string& key) {
  std::lock_guard<std::mutex> lk(mu_);
  Stmt st(db_, "DELETE FROM config WHERE key=?1");
  if (!st.ok()) return;
  st.bind(1, key);
  st.step();
}

bool Store::configDeleteAll() {
  std::lock_guard<std::mutex> lk(mu_);
  Stmt st(db_, "DELETE FROM config");
  return st.ok() && st.step() == SQLITE_DONE;
}

size_t Store::metaDeletePrefix(const std::string& prefix) {
  std::lock_guard<std::mutex> lk(mu_);
  if (prefix.empty()) return 0;
  // GLOB rather than LIKE: the pattern is a literal key prefix and LIKE would treat an
  // underscore in it as a wildcard, which every one of these prefixes contains.
  const std::string pattern = prefix + "*";
  size_t removed = 0;
  {
    Stmt count(db_, "SELECT COUNT(*) FROM meta WHERE key GLOB ?1");
    if (count.ok()) {
      count.bind(1, pattern);
      if (count.step() == SQLITE_ROW) removed = static_cast<size_t>(count.colInt(0));
    }
  }
  Stmt st(db_, "DELETE FROM meta WHERE key GLOB ?1");
  if (!st.ok()) return 0;
  st.bind(1, pattern);
  return st.step() == SQLITE_DONE ? removed : 0;
}

std::vector<LwwEntry> Store::configLoadAll() {
  std::lock_guard<std::mutex> lk(mu_);
  std::vector<LwwEntry> out;
  Stmt st(db_, "SELECT key,value_json,deleted,hlc,author,seq FROM config ORDER BY key");
  if (!st.ok()) return out;
  while (st.step() == SQLITE_ROW) {
    LwwEntry e;
    e.key = st.colText(0);
    e.value_json = st.colText(1);
    e.deleted = st.colInt(2) != 0;
    e.hlc = st.colText(3);
    e.author = st.colText(4);
    e.seq = static_cast<uint64_t>(st.colInt(5));
    out.push_back(std::move(e));
  }
  return out;
}

// --- events ---

bool Store::eventPut(const EventRecord& e) {
  const bool inserted = eventIngest(e);
  while (eventApplyNext(e.origin)) {}
  return inserted;
}

bool Store::persistEventLocked(const EventRecord& e, bool allow_existing, bool* inserted) {
  if (inserted) *inserted = false;
  Stmt st(db_,
          "INSERT OR IGNORE INTO events(origin,seq,type,door,device,hlc,wall_ms,"
          "payload_json,notify_json) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)");
  if (!st.ok()) return false;
  st.bind(1, e.origin);
  st.bind(2, static_cast<int64_t>(e.seq));
  st.bind(3, e.type);
  st.bind(4, e.door);
  st.bind(5, e.device);
  st.bind(6, e.hlc);
  st.bind(7, e.wall_ms);
  st.bind(8, e.payload_json);
  st.bind(9, e.notify_json);
  if (st.step() != SQLITE_DONE) return false;
  const bool did_insert = sqlite3_changes(db_) > 0;
  if (!did_insert) {
    if (!allow_existing) return false;
    Stmt existing(db_, "SELECT 1 FROM events WHERE origin=?1 AND seq=?2");
    if (!existing.ok()) return false;
    existing.bind(1, e.origin);
    existing.bind(2, static_cast<int64_t>(e.seq));
    if (existing.step() != SQLITE_ROW) return false;
  }

  Stmt ensure(db_,
              "INSERT OR IGNORE INTO event_origin_state("
              " origin,frontier,max_seq,dispatch_frontier) VALUES(?1,0,?2,0)");
  if (!ensure.ok()) return false;
  ensure.bind(1, e.origin);
  ensure.bind(2, static_cast<int64_t>(e.seq));
  if (ensure.step() != SQLITE_DONE) return false;
  Stmt persist(db_,
               "UPDATE event_origin_state SET max_seq=CASE WHEN max_seq<?2 THEN ?2 ELSE max_seq END"
               " WHERE origin=?1");
  if (!persist.ok()) return false;
  persist.bind(1, e.origin);
  persist.bind(2, static_cast<int64_t>(e.seq));
  if (persist.step() != SQLITE_DONE || sqlite3_changes(db_) != 1) return false;
  if (inserted) *inserted = did_insert;
  return true;
}

std::optional<EventRecord> Store::eventAppendLocal(
    EventRecord e, std::vector<EventRecord>* newly_applied) {
  std::lock_guard<std::mutex> lk(mu_);
  if (newly_applied) newly_applied->clear();
  if (!db_ || e.origin.empty() || !exec("BEGIN IMMEDIATE")) return std::nullopt;

  uint64_t max_seq = 0;
  {
    Stmt current(db_, "SELECT max_seq FROM event_origin_state WHERE origin=?1");
    if (!current.ok()) {
      exec("ROLLBACK");
      return std::nullopt;
    }
    current.bind(1, e.origin);
    if (current.step() == SQLITE_ROW)
      max_seq = static_cast<uint64_t>(current.colInt(0));
  }
  if (max_seq >= static_cast<uint64_t>(std::numeric_limits<int64_t>::max())) {
    exec("ROLLBACK");
    return std::nullopt;
  }

  e.seq = max_seq + 1;
  bool inserted = false;
  std::vector<EventRecord> applied;
  if (!persistEventLocked(e, /*allow_existing=*/false, &inserted) || !inserted) {
    exec("ROLLBACK");
    return std::nullopt;
  }
  while (true) {
    EventRecord next;
    const EventApplyResult result = eventApplyNextLocked(e.origin, &next);
    if (result == EventApplyResult::Error) {
      exec("ROLLBACK");
      return std::nullopt;
    }
    if (result == EventApplyResult::NoNext) break;
    applied.push_back(std::move(next));
  }
  if (!exec("COMMIT")) {
    exec("ROLLBACK");
    return std::nullopt;
  }
  if (newly_applied) *newly_applied = std::move(applied);
  return e;
}

bool Store::eventIngest(const EventRecord& e) {
  std::lock_guard<std::mutex> lk(mu_);
  if (!db_ || e.origin.empty() || e.seq == 0 ||
      e.seq > static_cast<uint64_t>(std::numeric_limits<int64_t>::max()))
    return false;
  if (!exec("BEGIN IMMEDIATE")) return false;
  bool inserted = false;
  if (!persistEventLocked(e, /*allow_existing=*/true, &inserted) || !exec("COMMIT")) {
    exec("ROLLBACK");
    return false;
  }
  return inserted;
}

Store::EventApplyResult Store::eventApplyNextLocked(const std::string& origin,
                                                     EventRecord* applied) {
  if (!db_ || origin.empty() || !applied) return EventApplyResult::Error;
  uint64_t frontier = 0;
  uint64_t max_seq = 0;
  {
    Stmt current(db_,
                 "SELECT frontier,max_seq FROM event_origin_state WHERE origin=?1");
    if (!current.ok()) return EventApplyResult::Error;
    current.bind(1, origin);
    if (current.step() != SQLITE_ROW) return EventApplyResult::NoNext;
    frontier = static_cast<uint64_t>(current.colInt(0));
    max_seq = static_cast<uint64_t>(current.colInt(1));
  }
  if (frontier >= static_cast<uint64_t>(std::numeric_limits<int64_t>::max()))
    return EventApplyResult::NoNext;
  EventRecord next;
  {
    Stmt event(db_, ("SELECT " + std::string(kEventCols) +
                     " FROM events WHERE origin=?1 AND seq=?2").c_str());
    if (!event.ok()) return EventApplyResult::Error;
    event.bind(1, origin);
    event.bind(2, static_cast<int64_t>(frontier + 1));
    if (event.step() != SQLITE_ROW) return EventApplyResult::NoNext;
    next = rowToEvent(event);
  }
  if (!applyCallProjectionLocked(next)) return EventApplyResult::Error;
  if (next.type == "press") {
    long long n = 0;
    auto current = metaGetLocked("stat_press_total");
    if (current) {
      try {
        n = std::stoll(*current);
      } catch (...) {
        n = 0;
      }
    }
    if (!metaSetLocked("stat_press_total", std::to_string(n + 1)))
      return EventApplyResult::Error;
  }
  Stmt advance(db_,
               "UPDATE event_origin_state SET frontier=?2,max_seq=?3 WHERE origin=?1");
  if (!advance.ok()) return EventApplyResult::Error;
  advance.bind(1, origin);
  advance.bind(2, static_cast<int64_t>(next.seq));
  advance.bind(3, static_cast<int64_t>(std::max(max_seq, next.seq)));
  if (advance.step() != SQLITE_DONE || sqlite3_changes(db_) != 1)
    return EventApplyResult::Error;
  *applied = std::move(next);
  return EventApplyResult::Applied;
}

std::optional<EventRecord> Store::eventApplyNext(const std::string& origin) {
  std::lock_guard<std::mutex> lk(mu_);
  if (!db_ || origin.empty() || !exec("BEGIN IMMEDIATE")) return std::nullopt;
  EventRecord applied;
  const EventApplyResult result = eventApplyNextLocked(origin, &applied);
  if (result == EventApplyResult::Error || !exec("COMMIT")) {
    exec("ROLLBACK");
    return std::nullopt;
  }
  return result == EventApplyResult::Applied
      ? std::optional<EventRecord>(std::move(applied))
      : std::nullopt;
}

std::optional<std::string> Store::callDoorFenceLocked(const std::string& door) {
  Stmt fence(db_, "SELECT hlc FROM call_door_fence WHERE door=?1");
  if (!fence.ok()) return std::nullopt;
  fence.bind(1, door);
  if (fence.step() != SQLITE_ROW) return std::nullopt;
  return fence.colText(0);
}

bool Store::advanceCallDoorFenceLocked(const std::string& door,
                                       const std::string& call_id,
                                       const std::string& hlc) {
  if (door.empty() || call_id.empty() || hlc.empty()) return true;

  {
    Stmt established(db_,
                     "SELECT 1 FROM call_projection WHERE door=?1 AND state='in_call'"
                     " AND call_id<>?2 LIMIT 1");
    if (!established.ok()) return false;
    established.bind(1, door);
    established.bind(2, call_id);
    if (established.step() == SQLITE_ROW) return true;
  }
  {
    Stmt advance(db_,
                 "INSERT INTO call_door_fence(door,call_id,hlc) VALUES(?1,?2,?3)"
                 " ON CONFLICT(door) DO UPDATE SET call_id=excluded.call_id,hlc=excluded.hlc"
                 " WHERE excluded.hlc>call_door_fence.hlc OR"
                 " (excluded.hlc=call_door_fence.hlc AND"
                 " excluded.call_id<call_door_fence.call_id)");
    if (!advance.ok()) return false;
    advance.bind(1, door);
    advance.bind(2, call_id);
    advance.bind(3, hlc);
    if (advance.step() != SQLITE_DONE) return false;
  }

  const auto effective = callDoorFenceLocked(door);
  if (!effective) return false;
  {
    Stmt expire(db_,
                "UPDATE call_projection SET state='ended',terminal_reason='terminal_fence'"
                " WHERE door=?1 AND answered_hlc='' AND updated_hlc<=?2 AND ("
                " state='ringing' OR (state='ended' AND"
                " terminal_reason='concurrent_press_loser'))");
    if (!expire.ok()) return false;
    expire.bind(1, door);
    expire.bind(2, *effective);
    if (expire.step() != SQLITE_DONE) return false;
  }

  std::string winner;
  {
    Stmt pending(db_,
                 "SELECT call_id FROM call_projection WHERE door=?1 AND answered_hlc=''"
                 " AND updated_hlc>?2 AND (state='ringing' OR"
                 " (state='ended' AND terminal_reason='concurrent_press_loser'))"
                 " ORDER BY call_id LIMIT 1");
    if (!pending.ok()) return false;
    pending.bind(1, door);
    pending.bind(2, *effective);
    if (pending.step() == SQLITE_ROW) winner = pending.colText(0);
  }
  if (winner.empty()) return true;
  {
    Stmt reject(db_,
                "UPDATE call_projection SET state='ended',"
                " terminal_reason='concurrent_press_loser' WHERE door=?1"
                " AND call_id<>?2 AND answered_hlc='' AND updated_hlc>?3 AND ("
                " state='ringing' OR (state='ended' AND"
                " terminal_reason='concurrent_press_loser'))");
    if (!reject.ok()) return false;
    reject.bind(1, door);
    reject.bind(2, winner);
    reject.bind(3, *effective);
    if (reject.step() != SQLITE_DONE) return false;
  }
  Stmt promote(db_,
               "UPDATE call_projection SET state='ringing',terminal_reason='',"
               " dialog_owner='',answered_hlc='' WHERE call_id=?1 AND door=?2"
               " AND answered_hlc='' AND updated_hlc>?3 AND (state='ringing' OR"
               " (state='ended' AND terminal_reason='concurrent_press_loser'))");
  if (!promote.ok()) return false;
  promote.bind(1, winner);
  promote.bind(2, door);
  promote.bind(3, *effective);
  return promote.step() == SQLITE_DONE;
}

bool Store::applyCallProjectionLocked(const EventRecord& e) {
  if (e.type != "press" && e.type != "purpose_selected" &&
      e.type != "call_answered" && e.type != "call_cancelled" &&
      e.type != "call_ended" && e.type != "reply")
    return true;

  auto payload = json::parse(e.payload_json.empty() ? "{}" : e.payload_json);
  std::string call_id = payload ? json::getString(payload.get(), "call_id") : "";
  if (call_id.empty() && e.type == "press")
    call_id = e.origin + ":" + std::to_string(e.seq);

  if (e.type == "reply") {
    const int64_t revision = payload ? json::getInt(payload.get(), "stage_revision", -1) : -1;
    const std::string call_origin = payload ? json::getString(payload.get(), "call_origin") : "";
    if (call_id.empty() || call_origin.empty() || revision < 0) return true;
    Stmt terminal(
        db_,
        "INSERT INTO call_projection(call_id,door,origin,purpose,state,stage_revision,"
        " expires_wall_ms,updated_hlc,terminal_reason,ended_wall_ms)"
        " VALUES(?1,?2,?3,'','ended',?4,0,?5,'reply',?6)"
        " ON CONFLICT(call_id) DO UPDATE SET state='ended',updated_hlc=excluded.updated_hlc,"
        " terminal_reason='reply',ended_wall_ms=excluded.ended_wall_ms"
        " WHERE call_projection.door=excluded.door"
        " AND call_projection.origin=excluded.origin"
        " AND (call_projection.state='ringing' OR"
        " (call_projection.state='cancelled' AND call_projection.stage_revision=excluded.stage_revision))"
        " AND call_projection.stage_revision=excluded.stage_revision"
        " AND (excluded.updated_hlc>=call_projection.updated_hlc OR"
        " call_projection.state='cancelled')");
    if (!terminal.ok()) return false;
    terminal.bind(1, call_id);
    terminal.bind(2, e.door);
    terminal.bind(3, call_origin);
    terminal.bind(4, revision);
    terminal.bind(5, e.hlc);
    terminal.bind(6, e.wall_ms);
    if (terminal.step() != SQLITE_DONE) return false;
    Stmt winner(db_, "SELECT state,updated_hlc,terminal_reason FROM call_projection"
                     " WHERE call_id=?1 AND door=?2 AND origin=?3");
    if (!winner.ok()) return false;
    winner.bind(1, call_id);
    winner.bind(2, e.door);
    winner.bind(3, call_origin);
    const bool accepted = winner.step() == SQLITE_ROW && winner.colText(0) == "ended" &&
                          winner.colText(1) == e.hlc && winner.colText(2) == "reply";
    return !accepted || advanceCallDoorFenceLocked(e.door, call_id, e.hlc);
  }
  if (call_id.empty()) return true;

  if (e.type == "press") {
    const std::string press_lang =
        payload ? json::getString(payload.get(), "visitor_lang") : "";
    const std::string press_snapshot = payload ? json::getString(payload.get(), "snapshot") : "";
    const auto fence = callDoorFenceLocked(e.door);
    if (fence && e.hlc <= *fence) {
      Stmt stale(db_,
                 "INSERT INTO call_projection(call_id,door,origin,purpose,state,stage_revision,"
                 " expires_wall_ms,updated_hlc,terminal_reason,"
                 " press_wall_ms,press_seq,visitor_lang,snapshot_hash)"
                 " VALUES(?1,?2,?3,?4,'ended',?5,?6,?7,'terminal_fence',?8,?11,?9,?10)"
                 " ON CONFLICT(call_id) DO UPDATE SET state='ended',"
                 " terminal_reason='terminal_fence'"
                 " WHERE call_projection.door=excluded.door"
                 " AND call_projection.origin=excluded.origin"
                 " AND call_projection.state<>'in_call'"
                 " AND excluded.updated_hlc>=call_projection.updated_hlc");
      if (!stale.ok()) return false;
      stale.bind(1, call_id);
      stale.bind(2, e.door);
      stale.bind(3, e.origin);
      stale.bind(4, payload ? json::getString(payload.get(), "purpose") : "");
      stale.bind(5, payload ? json::getInt(payload.get(), "stage_revision", 0) : 0);
      stale.bind(6, payload ? json::getInt(payload.get(), "expires_at_ms", e.wall_ms + 60'000)
                            : e.wall_ms + 60'000);
      stale.bind(7, e.hlc);
      stale.bind(8, e.wall_ms);
      stale.bind(9, press_lang);
      stale.bind(10, press_snapshot);
      stale.bind(11, static_cast<int64_t>(e.seq));
      return stale.step() == SQLITE_DONE;
    }
    bool accept = true;
    std::string active_id;
    std::string active_state;
    {
      Stmt current(db_,
                   "SELECT call_id,state FROM call_projection WHERE door=?1"
                   " AND state IN ('ringing','in_call')"
                   " ORDER BY CASE state WHEN 'in_call' THEN 0 ELSE 1 END,call_id LIMIT 1");
      if (!current.ok()) return false;
      current.bind(1, e.door);
      if (current.step() == SQLITE_ROW) {
        active_id = current.colText(0);
        active_state = current.colText(1);
        if (active_id != call_id)
          accept = active_state != "in_call" && call_id < active_id;
      }
    }
    if (!accept) {
      Stmt rejected(db_,
                    "INSERT INTO call_projection(call_id,door,origin,purpose,state,stage_revision,"
                    " expires_wall_ms,updated_hlc,terminal_reason,"
                    " press_wall_ms,press_seq,visitor_lang,snapshot_hash)"
                    " VALUES(?1,?2,?3,?4,'ended',?5,?6,?7,'concurrent_press_loser',?8,?11,?9,?10)"
                    " ON CONFLICT(call_id) DO NOTHING");
      if (!rejected.ok()) return false;
      rejected.bind(1, call_id);
      rejected.bind(2, e.door);
      rejected.bind(3, e.origin);
      rejected.bind(4, payload ? json::getString(payload.get(), "purpose") : "");
      rejected.bind(5, payload ? json::getInt(payload.get(), "stage_revision", 0) : 0);
      rejected.bind(6, payload ? json::getInt(payload.get(), "expires_at_ms", e.wall_ms + 60'000)
                               : e.wall_ms + 60'000);
      rejected.bind(7, e.hlc);
      rejected.bind(8, e.wall_ms);
      rejected.bind(9, press_lang);
      rejected.bind(10, press_snapshot);
      rejected.bind(11, static_cast<int64_t>(e.seq));
      return rejected.step() == SQLITE_DONE;
    }
    {
      Stmt supersede(db_,
                     "UPDATE call_projection SET state='ended',"
                     " terminal_reason='concurrent_press_loser' WHERE door=?1 AND call_id<>?2"
                     " AND state='ringing'");
      if (!supersede.ok()) return false;
      supersede.bind(1, e.door);
      supersede.bind(2, call_id);
      if (supersede.step() != SQLITE_DONE) return false;
    }
    Stmt upsert(db_,
                "INSERT INTO call_projection(call_id,door,origin,purpose,state,stage_revision,"
                " expires_wall_ms,updated_hlc,terminal_reason,"
                " press_wall_ms,press_seq,visitor_lang,snapshot_hash)"
                " VALUES(?1,?2,?3,?4,'ringing',?5,?6,?7,'',?8,?11,?9,?10)"
                " ON CONFLICT(call_id) DO UPDATE SET door=excluded.door,origin=excluded.origin,"
                " purpose=excluded.purpose,state='ringing',"
                " stage_revision=excluded.stage_revision,expires_wall_ms=excluded.expires_wall_ms,"
                " updated_hlc=excluded.updated_hlc,terminal_reason='',"
                " press_wall_ms=excluded.press_wall_ms,press_seq=excluded.press_seq,"
                " visitor_lang=excluded.visitor_lang,"
                " snapshot_hash=excluded.snapshot_hash"
                " WHERE excluded.updated_hlc>=call_projection.updated_hlc");
    if (!upsert.ok()) return false;
    upsert.bind(1, call_id);
    upsert.bind(2, e.door);
    upsert.bind(3, e.origin);
    upsert.bind(4, payload ? json::getString(payload.get(), "purpose") : "");
    upsert.bind(5, payload ? json::getInt(payload.get(), "stage_revision", 0) : 0);
    upsert.bind(6, payload ? json::getInt(payload.get(), "expires_at_ms", e.wall_ms + 60'000)
                           : e.wall_ms + 60'000);
    upsert.bind(7, e.hlc);
    upsert.bind(8, e.wall_ms);
    upsert.bind(9, press_lang);
    upsert.bind(10, press_snapshot);
    upsert.bind(11, static_cast<int64_t>(e.seq));
    return upsert.step() == SQLITE_DONE;
  }

  if (e.type == "purpose_selected") {
    const int64_t revision = payload ? json::getInt(payload.get(), "stage_revision", -1) : -1;
    if (revision <= 0) return true;
    Stmt update(db_,
                "UPDATE call_projection SET purpose=?3,state='ringing',stage_revision=?4,"
                " expires_wall_ms=CASE WHEN ?5>0 THEN ?5 ELSE expires_wall_ms END,"
                " updated_hlc=?6,terminal_reason='',dialog_owner='',answered_hlc='',"
                " visitor_lang=CASE WHEN ?7<>'' THEN ?7 ELSE visitor_lang END"
                " WHERE call_id=?1 AND door=?2 AND ?4=stage_revision+1 AND ("
                " (state='ringing' AND answered_hlc='' AND ?6>updated_hlc) OR"
                " (state='in_call' AND answered_hlc<>'' AND ?6<answered_hlc))");
    if (!update.ok()) return false;
    update.bind(1, call_id);
    update.bind(2, e.door);
    update.bind(3, payload ? json::getString(payload.get(), "purpose") : "");
    update.bind(4, revision);
    update.bind(5, payload ? json::getInt(payload.get(), "expires_at_ms", 0) : 0);
    update.bind(6, e.hlc);
    update.bind(7, payload ? json::getString(payload.get(), "visitor_lang") : "");
    return update.step() == SQLITE_DONE;
  }

  if (e.type == "call_answered") {
    const int64_t revision = payload ? json::getInt(payload.get(), "stage_revision", 0) : 0;
    const std::string owner = e.device.empty() ? e.origin : e.device;
    const std::string purpose = payload ? json::getString(payload.get(), "purpose") : "";
    const std::string call_origin = payload
        ? json::getString(payload.get(), "call_origin", e.origin.c_str()) : e.origin;
    const int64_t expires = payload ? json::getInt(payload.get(), "expires_at_ms", 0) : 0;

    // An answer is a claim for one exact revision.  A purpose event may reach
    // this replica before an older answer from a different origin; accepting
    // that stale answer would roll the projection back from revision N+1 to N
    // solely because of delivery order.  Conversely, a purpose that is older
    // than an already-established answer is allowed to demote that answer in
    // the purpose branch above.  Keep the two paths symmetric here.
    std::string own_state;
    std::string own_updated_hlc;
    std::string own_answered_hlc;
    std::string own_terminal_reason;
    int64_t own_revision = -1;
    bool rolls_back_purpose = false;
    {
      Stmt own(db_,
               "SELECT state,stage_revision,updated_hlc,answered_hlc,terminal_reason"
               " FROM call_projection WHERE call_id=?1 AND door=?2");
      if (!own.ok()) return false;
      own.bind(1, call_id);
      own.bind(2, e.door);
      if (own.step() == SQLITE_ROW) {
        own_state = own.colText(0);
        own_revision = own.colInt(1);
        own_updated_hlc = own.colText(2);
        own_answered_hlc = own.colText(3);
        own_terminal_reason = own.colText(4);
      }
    }
    if (!own_state.empty()) {
      bool exact_claim = revision == own_revision;
      if (own_state == "ringing") {
        // Normal answers claim the current ringing revision.  If the only
        // newer state is a purpose increment, however, an earlier answer
        // deterministically wins and rolls that purpose back.  This mirrors
        // the purpose-selected path, which may roll back a later answer.
        exact_claim = (revision == own_revision && e.hlc >= own_updated_hlc) ||
                      (revision + 1 == own_revision && e.hlc < own_updated_hlc);
        rolls_back_purpose = revision + 1 == own_revision && e.hlc < own_updated_hlc;
      } else if (own_state == "in_call") {
        // A duplicate/competing answer for the same revision may only replace
        // a later owner deterministically; equal HLC is already applied.
        exact_claim = exact_claim && !own_answered_hlc.empty() &&
                      e.hlc < own_answered_hlc;
      } else if (own_state == "ended" &&
                 own_terminal_reason == "concurrent_press_loser") {
        // A call that only lost a concurrent press can still establish if its
        // answer is newer than the rejected press.
        exact_claim = exact_claim && e.hlc >= own_updated_hlc;
      } else {
        exact_claim = false;
      }
      if (!exact_claim) return true;
    }

    std::string established_id;
    std::string established_answered_hlc;
    {
      Stmt current(db_, "SELECT call_id,answered_hlc FROM call_projection WHERE door=?1"
                         " AND state='in_call' AND call_id<>?2 LIMIT 1");
      if (!current.ok()) return false;
      current.bind(1, e.door);
      current.bind(2, call_id);
      if (current.step() == SQLITE_ROW) {
        established_id = current.colText(0);
        established_answered_hlc = current.colText(1);
      }
    }
    const bool incoming_wins = established_id.empty() ||
        e.hlc < established_answered_hlc ||
        (e.hlc == established_answered_hlc && call_id < established_id);
    if (!incoming_wins) {
      Stmt loser(db_,
                 "INSERT INTO call_projection(call_id,door,origin,purpose,state,stage_revision,"
                 " expires_wall_ms,updated_hlc,terminal_reason,dialog_owner,answered_hlc,"
                 " answered_wall_ms)"
                 " VALUES(?1,?2,?3,?4,'ended',?5,?6,?7,'concurrent_answer_loser',?8,?7,?9)"
                 " ON CONFLICT(call_id) DO UPDATE SET state='ended',"
                 " terminal_reason=CASE WHEN call_projection.terminal_reason='concurrent_press_loser'"
                 " THEN call_projection.terminal_reason ELSE 'concurrent_answer_loser' END"
                 " WHERE call_projection.door=excluded.door AND call_projection.state<>'in_call'");
      if (!loser.ok()) return false;
      loser.bind(1, call_id);
      loser.bind(2, e.door);
      loser.bind(3, call_origin);
      loser.bind(4, purpose);
      loser.bind(5, revision);
      loser.bind(6, expires);
      loser.bind(7, e.hlc);
      loser.bind(8, owner);
      loser.bind(9, e.wall_ms);
      return loser.step() == SQLITE_DONE;
    }

    Stmt demote(db_,
                "UPDATE call_projection SET state='ended',terminal_reason="
                "CASE WHEN state='in_call' THEN 'concurrent_answer_loser'"
                " ELSE 'concurrent_press_loser' END"
                " WHERE door=?1 AND call_id<>?2 AND state IN ('ringing','in_call')");
    if (!demote.ok()) return false;
    demote.bind(1, e.door);
    demote.bind(2, call_id);
    if (demote.step() != SQLITE_DONE) return false;

    Stmt update(db_,
                "INSERT INTO call_projection(call_id,door,origin,purpose,state,stage_revision,"
                " expires_wall_ms,updated_hlc,terminal_reason,dialog_owner,answered_hlc,"
                " answered_wall_ms)"
                " VALUES(?1,?2,?3,?4,'in_call',?5,?6,?7,'',?8,?7,?10)"
                " ON CONFLICT(call_id) DO UPDATE SET state='in_call',"
                " purpose=CASE WHEN ?9=1 THEN '' WHEN excluded.purpose<>'' THEN excluded.purpose"
                " ELSE call_projection.purpose END,stage_revision=excluded.stage_revision,"
                " expires_wall_ms=CASE WHEN excluded.expires_wall_ms>0"
                " THEN excluded.expires_wall_ms ELSE call_projection.expires_wall_ms END,"
                " updated_hlc=excluded.updated_hlc,terminal_reason='',dialog_owner=excluded.dialog_owner,"
                " answered_hlc=excluded.answered_hlc,"
                " answered_wall_ms=excluded.answered_wall_ms"
                " WHERE call_projection.door=excluded.door"
                " AND (call_projection.state IN ('ringing','ended') OR"
                " (call_projection.state='in_call' AND excluded.answered_hlc<call_projection.answered_hlc))");
    if (!update.ok()) return false;
    update.bind(1, call_id);
    update.bind(2, e.door);
    update.bind(3, call_origin);
    update.bind(4, purpose);
    update.bind(5, revision);
    update.bind(6, expires);
    update.bind(7, e.hlc);
    update.bind(8, owner);
    update.bind(9, rolls_back_purpose ? 1 : 0);
    update.bind(10, e.wall_ms);
    return update.step() == SQLITE_DONE;
  }

  if (e.type == "call_ended") {
    const int64_t revision = payload ? json::getInt(payload.get(), "stage_revision", -1) : -1;
    if (revision < 0) return true;
    const std::string reason = payload ? json::getString(payload.get(), "reason") : "";
    const std::string owner = e.device.empty() ? e.origin : e.device;
    Stmt terminal(db_,
                  "INSERT INTO call_projection(call_id,door,origin,purpose,state,stage_revision,"
                  " expires_wall_ms,updated_hlc,terminal_reason,dialog_owner,answered_hlc,"
                  " ended_wall_ms)"
                  " VALUES(?1,?2,?3,'','ended',?4,0,?5,?6,?7,'',?8)"
                  " ON CONFLICT(call_id) DO UPDATE SET state='ended',"
                  " updated_hlc=excluded.updated_hlc,terminal_reason=excluded.terminal_reason,"
                  " ended_wall_ms=excluded.ended_wall_ms"
                  " WHERE excluded.updated_hlc>=call_projection.updated_hlc"
                  " AND call_projection.state IN ('in_call','ended')"
                  " AND call_projection.door=excluded.door"
                  " AND call_projection.stage_revision=excluded.stage_revision"
                  " AND call_projection.dialog_owner=excluded.dialog_owner");
    if (!terminal.ok()) return false;
    terminal.bind(1, call_id);
    terminal.bind(2, e.door);
    terminal.bind(3, e.origin);
    terminal.bind(4, revision);
    terminal.bind(5, e.hlc);
    terminal.bind(6, reason);
    terminal.bind(7, owner);
    terminal.bind(8, e.wall_ms);
    if (terminal.step() != SQLITE_DONE) return false;
    Stmt winner(db_, "SELECT state,updated_hlc,terminal_reason,dialog_owner"
                     " FROM call_projection WHERE call_id=?1 AND door=?2");
    if (!winner.ok()) return false;
    winner.bind(1, call_id);
    winner.bind(2, e.door);
    const bool accepted = winner.step() == SQLITE_ROW && winner.colText(0) == "ended" &&
                          winner.colText(1) == e.hlc && winner.colText(2) == reason &&
                          winner.colText(3) == owner;
    return !accepted || advanceCallDoorFenceLocked(e.door, call_id, e.hlc);
  }

  const std::string state = "cancelled";
  const std::string reason = payload ? json::getString(payload.get(), "reason") : "";
  if (e.type == "call_cancelled" && reason != "recovery_failed" &&
      reason != "recovery_timeout") {
    Stmt current(db_, "SELECT state,terminal_reason FROM call_projection WHERE call_id=?1");
    if (!current.ok()) return false;
    current.bind(1, call_id);
    if (current.step() == SQLITE_ROW) {
      const std::string current_state = current.colText(0);
      const std::string current_reason = current.colText(1);
      if (current_state == "in_call" ||
          (current_state == "ended" && current_reason == "reply"))
        return true;
    }
  }
  Stmt terminal(db_,
                "INSERT INTO call_projection(call_id,door,origin,purpose,state,stage_revision,"
                " expires_wall_ms,updated_hlc,terminal_reason,ended_wall_ms)"
                " VALUES(?1,?2,?3,'',?4,0,0,?5,?6,?7)"
                " ON CONFLICT(call_id) DO UPDATE SET state=excluded.state,"
                " updated_hlc=excluded.updated_hlc,terminal_reason=excluded.terminal_reason,"
                " ended_wall_ms=excluded.ended_wall_ms"
                " WHERE excluded.updated_hlc>=call_projection.updated_hlc");
  if (!terminal.ok()) return false;
  terminal.bind(1, call_id);
  terminal.bind(2, e.door);
  terminal.bind(3, e.origin);
  terminal.bind(4, state);
  terminal.bind(5, e.hlc);
  terminal.bind(6, reason);
  terminal.bind(7, e.wall_ms);
  if (terminal.step() != SQLITE_DONE) return false;
  Stmt winner(db_, "SELECT state,updated_hlc,terminal_reason FROM call_projection"
                   " WHERE call_id=?1 AND door=?2");
  if (!winner.ok()) return false;
  winner.bind(1, call_id);
  winner.bind(2, e.door);
  const bool accepted = winner.step() == SQLITE_ROW && winner.colText(0) == state &&
                        winner.colText(1) == e.hlc && winner.colText(2) == reason;
  return !accepted || advanceCallDoorFenceLocked(e.door, call_id, e.hlc);
}

bool Store::eventExists(const std::string& origin, uint64_t seq) {
  std::lock_guard<std::mutex> lk(mu_);
  Stmt st(db_, "SELECT 1 FROM events WHERE origin=?1 AND seq=?2");
  if (!st.ok()) return false;
  st.bind(1, origin);
  st.bind(2, static_cast<int64_t>(seq));
  return st.step() == SQLITE_ROW;
}

void Store::eventSetNotify(const std::string& origin, uint64_t seq,
                           const std::string& notify_json) {
  std::lock_guard<std::mutex> lk(mu_);
  Stmt st(db_, "UPDATE events SET notify_json=?3 WHERE origin=?1 AND seq=?2");
  if (!st.ok()) return;
  st.bind(1, origin);
  st.bind(2, static_cast<int64_t>(seq));
  st.bind(3, notify_json);
  st.step();
}

std::optional<EventRecord> Store::eventGet(const std::string& origin, uint64_t seq) {
  std::lock_guard<std::mutex> lk(mu_);
  Stmt st(db_, ("SELECT " + std::string(kEventCols) +
                " FROM events WHERE origin=?1 AND seq=?2").c_str());
  if (!st.ok()) return std::nullopt;
  st.bind(1, origin);
  st.bind(2, static_cast<int64_t>(seq));
  if (st.step() != SQLITE_ROW) return std::nullopt;
  return rowToEvent(st);
}

std::map<std::string, uint64_t> Store::eventHeads() {
  std::lock_guard<std::mutex> lk(mu_);
  std::map<std::string, uint64_t> out;
  Stmt st(db_, "SELECT origin,frontier FROM event_origin_state ORDER BY origin ASC");
  if (!st.ok()) return out;
  while (st.step() == SQLITE_ROW) out[st.colText(0)] = static_cast<uint64_t>(st.colInt(1));
  return out;
}

uint64_t Store::eventFrontier(const std::string& origin) {
  std::lock_guard<std::mutex> lk(mu_);
  Stmt st(db_, "SELECT frontier FROM event_origin_state WHERE origin=?1");
  if (!st.ok()) return 0;
  st.bind(1, origin);
  if (st.step() != SQLITE_ROW) return 0;
  return static_cast<uint64_t>(st.colInt(0));
}

uint64_t Store::eventMaxSeq(const std::string& origin) {
  std::lock_guard<std::mutex> lk(mu_);
  Stmt st(db_, "SELECT max_seq FROM event_origin_state WHERE origin=?1");
  if (!st.ok()) return 0;
  st.bind(1, origin);
  if (st.step() != SQLITE_ROW) return 0;
  return static_cast<uint64_t>(st.colInt(0));
}

std::vector<EventRecord> Store::pendingEventDispatches(size_t limit) {
  std::lock_guard<std::mutex> lk(mu_);
  std::vector<EventRecord> out;
  if (!db_ || limit == 0) return out;
  Stmt st(db_,
          "SELECT e.origin,e.seq,e.type,e.door,e.device,e.hlc,e.wall_ms,"
          " e.payload_json,e.notify_json FROM events e"
          " JOIN event_origin_state s ON s.origin=e.origin"
          " WHERE e.seq>s.dispatch_frontier AND e.seq<=s.frontier"
          " ORDER BY e.origin ASC,e.seq ASC LIMIT ?1");
  if (!st.ok()) return out;
  st.bind(1, static_cast<int64_t>(std::min(
                 limit, static_cast<size_t>(std::numeric_limits<int64_t>::max()))));
  while (st.step() == SQLITE_ROW) out.push_back(rowToEvent(st));
  return out;
}

bool Store::eventAckDispatched(const std::string& origin, uint64_t seq) {
  std::lock_guard<std::mutex> lk(mu_);
  if (!db_ || origin.empty() || seq == 0 ||
      seq > static_cast<uint64_t>(std::numeric_limits<int64_t>::max()))
    return false;
  Stmt st(db_,
          "UPDATE event_origin_state SET dispatch_frontier=?2"
          " WHERE origin=?1 AND dispatch_frontier=?3 AND frontier>=?2");
  if (!st.ok()) return false;
  st.bind(1, origin);
  st.bind(2, static_cast<int64_t>(seq));
  st.bind(3, static_cast<int64_t>(seq - 1));
  return st.step() == SQLITE_DONE && sqlite3_changes(db_) == 1;
}

uint64_t Store::eventDispatchFrontier(const std::string& origin) {
  std::lock_guard<std::mutex> lk(mu_);
  Stmt st(db_, "SELECT dispatch_frontier FROM event_origin_state WHERE origin=?1");
  if (!st.ok()) return 0;
  st.bind(1, origin);
  if (st.step() != SQLITE_ROW) return 0;
  return static_cast<uint64_t>(st.colInt(0));
}

std::vector<EventRecord> Store::eventsSince(const std::map<std::string, uint64_t>& remote_heads,
                                            size_t limit) {
  std::lock_guard<std::mutex> lk(mu_);

  std::vector<EventRecord> out;
  if (!db_ || limit == 0 ||
      !exec("CREATE TEMP TABLE IF NOT EXISTS remote_event_frontier("
            "origin TEXT PRIMARY KEY,frontier INT NOT NULL)") ||
      !exec("DELETE FROM remote_event_frontier"))
    return out;
  for (const auto& item : remote_heads) {
    Stmt insert(db_,
                "INSERT OR REPLACE INTO remote_event_frontier(origin,frontier) VALUES(?1,?2)");
    if (!insert.ok()) return {};
    insert.bind(1, item.first);
    insert.bind(2, static_cast<int64_t>(std::min(
                       item.second,
                       static_cast<uint64_t>(std::numeric_limits<int64_t>::max()))));
    if (insert.step() != SQLITE_DONE) return {};
  }
  Stmt events(db_,
              "SELECT e.origin,e.seq,e.type,e.door,e.device,e.hlc,e.wall_ms,"
              " e.payload_json,e.notify_json FROM events e"
              " LEFT JOIN remote_event_frontier r ON r.origin=e.origin"
              " WHERE e.seq>COALESCE(r.frontier,0)"
              " ORDER BY e.seq-COALESCE(r.frontier,0) ASC,e.hlc ASC LIMIT ?1");
  if (!events.ok()) return {};
  events.bind(1, static_cast<int64_t>(std::min(
                      limit, static_cast<size_t>(std::numeric_limits<int64_t>::max()))));
  while (events.step() == SQLITE_ROW) out.push_back(rowToEvent(events));
  return out;
}

size_t Store::countEventsOfType(const std::string& type) {
  std::lock_guard<std::mutex> lk(mu_);
  return countEventsOfTypeLocked(type);
}


size_t Store::countEventsOfTypeLocked(const std::string& type) {
  if (!db_) return 0;
  Stmt st(db_,
          "SELECT COUNT(*) FROM events e"
          " JOIN event_origin_state s ON s.origin=e.origin"
          " WHERE e.type=?1 AND e.seq<=s.frontier");
  if (!st.ok()) return 0;
  st.bind(1, type);
  if (st.step() != SQLITE_ROW) return 0;
  return static_cast<size_t>(st.colInt(0));
}

std::vector<EventRecord> Store::recentEvents(size_t limit) {
  std::lock_guard<std::mutex> lk(mu_);
  std::vector<EventRecord> out;
  Stmt st(db_,
          "SELECT e.origin,e.seq,e.type,e.door,e.device,e.hlc,e.wall_ms,"
          " e.payload_json,e.notify_json FROM events e"
          " JOIN event_origin_state s ON s.origin=e.origin"
          " WHERE e.seq<=s.frontier ORDER BY e.hlc DESC LIMIT ?1");
  if (!st.ok()) return out;
  st.bind(1, static_cast<int64_t>(limit));
  while (st.step() == SQLITE_ROW) out.push_back(rowToEvent(st));
  return out;
}

std::optional<EventRecord> Store::latestEventOfTypes(const std::string& t1,
                                                    const std::string& t2) {
  std::lock_guard<std::mutex> lk(mu_);
  Stmt st(db_,
          "SELECT e.origin,e.seq,e.type,e.door,e.device,e.hlc,e.wall_ms,"
          " e.payload_json,e.notify_json FROM events e"
          " JOIN event_origin_state s ON s.origin=e.origin"
          " WHERE e.seq<=s.frontier AND (e.type=?1 OR e.type=?2)"
          " ORDER BY e.hlc DESC LIMIT 1");
  if (!st.ok()) return std::nullopt;
  st.bind(1, t1);
  st.bind(2, t2);
  if (st.step() != SQLITE_ROW) return std::nullopt;
  return rowToEvent(st);
}

std::vector<Store::CallProjection> Store::activeCallProjections() {
  std::lock_guard<std::mutex> lk(mu_);
  std::vector<CallProjection> out;
  Stmt st(db_,
          "SELECT call_id,door,origin,purpose,state,stage_revision,expires_wall_ms,updated_hlc,"
          " terminal_reason,dialog_owner,answered_hlc,press_wall_ms,answered_wall_ms,"
          " ended_wall_ms,visitor_lang,snapshot_hash"
          " FROM call_projection WHERE state IN ('ringing','in_call')"
          " ORDER BY updated_hlc ASC");
  if (!st.ok()) return out;
  while (st.step() == SQLITE_ROW) {
    CallProjection p;
    p.call_id = st.colText(0);
    p.door = st.colText(1);
    p.origin = st.colText(2);
    p.purpose = st.colText(3);
    p.state = st.colText(4);
    p.stage_revision = static_cast<int>(st.colInt(5));
    p.expires_wall_ms = st.colInt(6);
    p.updated_hlc = st.colText(7);
    p.terminal_reason = st.colText(8);
    p.dialog_owner = st.colText(9);
    p.answered_hlc = st.colText(10);
    p.press_wall_ms = st.colInt(11);
    p.answered_wall_ms = st.colInt(12);
    p.ended_wall_ms = st.colInt(13);
    p.visitor_lang = st.colText(14);
    p.snapshot_hash = st.colText(15);
    out.push_back(std::move(p));
  }
  return out;
}

std::optional<Store::CallProjection> Store::callProjection(const std::string& call_id) {
  std::lock_guard<std::mutex> lk(mu_);
  Stmt st(db_,
          "SELECT call_id,door,origin,purpose,state,stage_revision,expires_wall_ms,updated_hlc,"
          " terminal_reason,dialog_owner,answered_hlc,press_wall_ms,answered_wall_ms,"
          " ended_wall_ms,visitor_lang,snapshot_hash FROM call_projection WHERE call_id=?1");
  if (!st.ok()) return std::nullopt;
  st.bind(1, call_id);
  if (st.step() != SQLITE_ROW) return std::nullopt;
  CallProjection p;
  p.call_id = st.colText(0);
  p.door = st.colText(1);
  p.origin = st.colText(2);
  p.purpose = st.colText(3);
  p.state = st.colText(4);
  p.stage_revision = static_cast<int>(st.colInt(5));
  p.expires_wall_ms = st.colInt(6);
  p.updated_hlc = st.colText(7);
  p.terminal_reason = st.colText(8);
  p.dialog_owner = st.colText(9);
  p.answered_hlc = st.colText(10);
  p.press_wall_ms = st.colInt(11);
  p.answered_wall_ms = st.colInt(12);
  p.ended_wall_ms = st.colInt(13);
  p.visitor_lang = st.colText(14);
  p.snapshot_hash = st.colText(15);
  return p;
}

namespace {

constexpr const char* kCallLogSeenKey = "call_log_seen_hlc";
constexpr const char* kEventCoverageKey = "event_coverage";

// Outcome derivation shared by every call-history query. Losers, fenced calls, and calls that are
// still live never appear, so the SQL filter and the projected outcome stay in one place.
constexpr const char* kCallLogOutcomeSql =
    "CASE WHEN state='ended' AND terminal_reason='reply' THEN 'replied'"
    " WHEN state='ended' THEN 'answered'"
    " WHEN state='cancelled' AND (terminal_reason='timeout'"
    "   OR substr(terminal_reason,1,9)='recovery_') THEN 'missed'"
    " WHEN state='cancelled' THEN 'cancelled' ELSE '' END";
constexpr const char* kCallLogVisibleSql =
    "((state='ended' AND terminal_reason NOT IN ('concurrent_press_loser',"
    "  'concurrent_answer_loser','terminal_fence')) OR state='cancelled')";

}  // namespace

std::vector<Store::CallLogRow> Store::callLog(const CallLogQuery& query) {
  std::lock_guard<std::mutex> lk(mu_);
  std::vector<CallLogRow> out;
  if (!db_ || query.limit == 0) return out;
  const std::string seen_hlc = metaGetLocked(kCallLogSeenKey).value_or("");
  const std::string ts_sql = "(CASE WHEN press_wall_ms>0 THEN press_wall_ms"
                             " ELSE ended_wall_ms END)";
  const std::string sql =
      "SELECT call_id,origin,press_seq,door,purpose,visitor_lang," + std::string(kCallLogOutcomeSql) +
      ",dialog_owner,answered_wall_ms,ended_wall_ms,snapshot_hash,updated_hlc," + ts_sql +
      " FROM call_projection WHERE " + kCallLogVisibleSql +
      " AND (?1=0 OR " + ts_sql + ">=?1)"
      " AND (?2=0 OR " + ts_sql + "<?2)"
      " AND (?3='' OR door=?3)"
      " AND (?4='' OR " + kCallLogOutcomeSql + "=?4)"
      " ORDER BY " + ts_sql + " DESC,updated_hlc DESC,call_id ASC LIMIT ?5";
  Stmt st(db_, sql.c_str());
  if (!st.ok()) return out;
  st.bind(1, query.since_ms);
  st.bind(2, query.before_ms);
  st.bind(3, query.door);
  st.bind(4, query.outcome);
  st.bind(5, static_cast<int64_t>(
                 std::min(query.limit,
                          static_cast<size_t>(std::numeric_limits<int64_t>::max()))));
  while (st.step() == SQLITE_ROW) {
    CallLogRow row;
    row.call_id = st.colText(0);
    const std::string origin = st.colText(1);
    const int64_t press_seq = st.colInt(2);
    row.id = press_seq > 0 && !origin.empty()
        ? origin + ":" + std::to_string(press_seq)
        : row.call_id;
    row.door = st.colText(3);
    row.purpose = st.colText(4);
    row.visitor_lang = st.colText(5);
    row.outcome = st.colText(6);
    const int64_t answered_wall_ms = st.colInt(8);
    const int64_t ended_wall_ms = st.colInt(9);
    // A device that never answered still records the terminal event; only a real answer produces
    // an owner and a duration.
    row.answered_by = row.outcome == "answered" ? st.colText(7) : "";
    row.duration_ms = row.outcome == "answered" && answered_wall_ms > 0 &&
            ended_wall_ms > answered_wall_ms
        ? ended_wall_ms - answered_wall_ms
        : 0;
    row.snapshot = st.colText(10);
    row.updated_hlc = st.colText(11);
    row.ts = st.colInt(12);
    row.seen = !seen_hlc.empty() && row.updated_hlc <= seen_hlc;
    out.push_back(std::move(row));
  }
  return out;
}

size_t Store::unreadMissedCount() {
  std::lock_guard<std::mutex> lk(mu_);
  if (!db_) return 0;
  const std::string seen_hlc = metaGetLocked(kCallLogSeenKey).value_or("");
  const std::string sql = "SELECT COUNT(*) FROM call_projection WHERE " +
                          std::string(kCallLogVisibleSql) + " AND " + kCallLogOutcomeSql +
                          "='missed' AND updated_hlc>?1";
  Stmt st(db_, sql.c_str());
  if (!st.ok()) return 0;
  st.bind(1, seen_hlc);
  if (st.step() != SQLITE_ROW) return 0;
  return static_cast<size_t>(st.colInt(0));
}

std::string Store::callLogSeenHlc() {
  std::lock_guard<std::mutex> lk(mu_);
  return metaGetLocked(kCallLogSeenKey).value_or("");
}

bool Store::callLogMarkSeen(const std::string& up_to_hlc) {
  std::lock_guard<std::mutex> lk(mu_);
  if (!db_) return false;
  std::string target = up_to_hlc;
  if (target.empty()) {
    const std::string sql = "SELECT MAX(updated_hlc) FROM call_projection WHERE " +
                            std::string(kCallLogVisibleSql);
    Stmt newest(db_, sql.c_str());
    if (!newest.ok()) return false;
    if (newest.step() == SQLITE_ROW) target = newest.colText(0);
  }
  const std::string current = metaGetLocked(kCallLogSeenKey).value_or("");
  // The watermark is device-local and monotonic; a stale client must not resurrect a badge.
  if (target.empty() || target <= current) return true;
  return metaSetLocked(kCallLogSeenKey, target);
}

bool Store::eventCoverageSet(const std::map<std::string, uint64_t>& coverage) {
  std::lock_guard<std::mutex> lk(mu_);
  if (!db_) return false;
  auto o = json::obj();
  for (const auto& item : coverage)
    json::set(o.get(), item.first.c_str(),
              static_cast<int64_t>(std::min(
                  item.second, static_cast<uint64_t>(std::numeric_limits<int64_t>::max()))));
  return metaSetLocked(kEventCoverageKey, json::dump(o.get()));
}

std::map<std::string, uint64_t> Store::eventCoverage() {
  std::lock_guard<std::mutex> lk(mu_);
  std::map<std::string, uint64_t> out;
  auto raw = metaGetLocked(kEventCoverageKey);
  if (!raw) return out;
  auto doc = json::parse(*raw);
  if (!doc) return out;
  const cJSON* item = nullptr;
  cJSON_ArrayForEach(item, doc.get()) {
    if (!item->string || !cJSON_IsNumber(item)) continue;
    const double value = item->valuedouble;
    if (value <= 0) continue;
    out[item->string] = static_cast<uint64_t>(value);
  }
  return out;
}

size_t Store::pruneEvents(size_t max_events, int64_t cutoff_wall_ms) {
  std::lock_guard<std::mutex> lk(mu_);
  if (!db_) return 0;
  std::map<std::string, uint64_t> coverage;
  {
    auto raw = metaGetLocked(kEventCoverageKey);
    auto doc = raw ? json::parse(*raw) : json::Doc();
    const cJSON* item = nullptr;
    if (doc) {
      cJSON_ArrayForEach(item, doc.get()) {
        if (!item->string || !cJSON_IsNumber(item) || item->valuedouble <= 0) continue;
        coverage[item->string] = static_cast<uint64_t>(item->valuedouble);
      }
    }
  }
  if (coverage.empty()) {
    // The steady state today: no replication mechanism records event coverage yet, so retention
    // stays a no-op instead of destroying history a peer may still need.
    DB_LOGD(kTag, "event pruning refused because no replicated coverage snapshot exists");
    return 0;
  }
  if (!exec("CREATE TEMP TABLE IF NOT EXISTS event_prune_coverage("
            "origin TEXT PRIMARY KEY,covered INT NOT NULL)") ||
      !exec("DELETE FROM event_prune_coverage"))
    return 0;
  for (const auto& item : coverage) {
    Stmt insert(db_,
                "INSERT OR REPLACE INTO event_prune_coverage(origin,covered) VALUES(?1,?2)");
    if (!insert.ok()) return 0;
    insert.bind(1, item.first);
    insert.bind(2, static_cast<int64_t>(std::min(
                       item.second,
                       static_cast<uint64_t>(std::numeric_limits<int64_t>::max()))));
    if (insert.step() != SQLITE_DONE) return 0;
  }
  // Retention keeps the newest max_events per origin and everything at or after cutoff_wall_ms.
  // Deletion additionally requires that the record is applied, dispatched, and proven to exist on
  // every cluster member, so anti-entropy can never be asked for an event this node destroyed.
  Stmt del(db_,
           "DELETE FROM events WHERE rowid IN ("
           " SELECT e.rowid FROM events e"
           " JOIN event_origin_state s ON s.origin=e.origin"
           " JOIN event_prune_coverage c ON c.origin=e.origin"
           " WHERE e.wall_ms<?1 AND e.seq<=MIN(s.frontier,s.dispatch_frontier)"
           " AND e.seq<=c.covered"
           " AND (SELECT COUNT(*) FROM events n WHERE n.origin=e.origin AND n.seq>e.seq)>=?2)");
  if (!del.ok()) return 0;
  del.bind(1, cutoff_wall_ms);
  del.bind(2, static_cast<int64_t>(std::min(
                  max_events, static_cast<size_t>(std::numeric_limits<int64_t>::max()))));
  if (del.step() != SQLITE_DONE) return 0;
  const size_t removed = static_cast<size_t>(std::max(0, sqlite3_changes(db_)));
  if (removed)
    DB_LOGI(kTag, "pruned " + std::to_string(removed) + " replicated events");
  return removed;
}

// --- tg_queue ---

namespace {

Store::TgQueueItem rowToTgItem(Stmt& st) {
  Store::TgQueueItem it;
  it.id = st.colInt(0);
  it.kind = st.colText(1);
  it.chat_id = st.colText(2);
  it.payload = st.colText(3);
  it.snapshot = st.colBlob(4);
  it.attempts = static_cast<int>(st.colInt(5));
  it.next_retry_ms = st.colInt(6);
  it.created_ms = st.colInt(7);
  return it;
}
constexpr const char* kTgCols = "id,kind,chat_id,payload,snapshot,attempts,next_retry_ms,created_ms";
}  // namespace

int64_t Store::tgQueuePut(const TgQueueItem& item) {
  std::lock_guard<std::mutex> lk(mu_);
  if (!db_) return 0;
  Stmt st(db_,
          "INSERT INTO tg_queue(kind,chat_id,payload,snapshot,attempts,next_retry_ms,created_ms)"
          " VALUES(?1,?2,?3,?4,?5,?6,?7)");
  if (!st.ok()) return 0;
  st.bind(1, item.kind);
  st.bind(2, item.chat_id);
  st.bind(3, item.payload);
  st.bindBlob(4, item.snapshot);
  st.bind(5, static_cast<int64_t>(item.attempts));
  st.bind(6, item.next_retry_ms);
  st.bind(7, item.created_ms);
  if (st.step() != SQLITE_DONE) return 0;
  return sqlite3_last_insert_rowid(db_);
}

std::vector<Store::TgQueueItem> Store::tgQueueDue(int64_t now_ms, size_t limit) {
  std::lock_guard<std::mutex> lk(mu_);
  std::vector<TgQueueItem> out;
  Stmt st(db_, ("SELECT " + std::string(kTgCols) +
                " FROM tg_queue WHERE next_retry_ms<=?1 ORDER BY id ASC LIMIT ?2").c_str());
  if (!st.ok()) return out;
  st.bind(1, now_ms);
  st.bind(2, static_cast<int64_t>(limit));
  while (st.step() == SQLITE_ROW) out.push_back(rowToTgItem(st));
  return out;
}

void Store::tgQueueRetry(int64_t id, int attempts, int64_t next_retry_ms) {
  std::lock_guard<std::mutex> lk(mu_);
  Stmt st(db_, "UPDATE tg_queue SET attempts=?2, next_retry_ms=?3 WHERE id=?1");
  if (!st.ok()) return;
  st.bind(1, id);
  st.bind(2, static_cast<int64_t>(attempts));
  st.bind(3, next_retry_ms);
  st.step();
}

void Store::tgQueueDelete(int64_t id) {
  std::lock_guard<std::mutex> lk(mu_);
  Stmt st(db_, "DELETE FROM tg_queue WHERE id=?1");
  if (!st.ok()) return;
  st.bind(1, id);
  st.step();
}

size_t Store::tgQueuePrune(int64_t cutoff_created_ms) {
  std::lock_guard<std::mutex> lk(mu_);
  if (!db_) return 0;
  Stmt st(db_, "DELETE FROM tg_queue WHERE created_ms<?1");
  if (!st.ok()) return 0;
  st.bind(1, cutoff_created_ms);
  if (st.step() != SQLITE_DONE) return 0;
  return static_cast<size_t>(sqlite3_changes(db_));
}

size_t Store::tgQueueCount() {
  std::lock_guard<std::mutex> lk(mu_);
  Stmt st(db_, "SELECT COUNT(*) FROM tg_queue");
  if (!st.ok() || st.step() != SQLITE_ROW) return 0;
  return static_cast<size_t>(st.colInt(0));
}

// --- net_probe ---
void Store::netProbePut(const NetProbe& p) {
  std::lock_guard<std::mutex> lk(mu_);
  if (!db_) return;
  Stmt st(db_, "INSERT INTO net_probe(ts_ms,target,host,ok,rtt_ms) VALUES(?1,?2,?3,?4,?5)");
  if (!st.ok()) return;
  st.bind(1, p.ts_ms);
  st.bind(2, p.target);
  st.bind(3, p.host);
  st.bind(4, static_cast<int64_t>(p.ok ? 1 : 0));
  st.bind(5, static_cast<int64_t>(p.rtt_ms));
  st.step();
}

std::vector<Store::NetProbe> Store::netProbesSince(int64_t since_ms, size_t limit) {
  std::lock_guard<std::mutex> lk(mu_);
  std::vector<NetProbe> out;
  if (!db_) return out;
  Stmt st(db_, "SELECT ts_ms,target,host,ok,rtt_ms FROM net_probe"
               " WHERE ts_ms>=?1 ORDER BY ts_ms ASC LIMIT ?2");
  if (!st.ok()) return out;
  st.bind(1, since_ms);
  st.bind(2, static_cast<int64_t>(limit));
  while (st.step() == SQLITE_ROW) {
    NetProbe p;
    p.ts_ms = st.colInt(0);
    p.target = st.colText(1);
    p.host = st.colText(2);
    p.ok = st.colInt(3) != 0;
    p.rtt_ms = static_cast<int>(st.colInt(4));
    out.push_back(std::move(p));
  }
  return out;
}

size_t Store::netProbePrune(int64_t cutoff_ms) {
  std::lock_guard<std::mutex> lk(mu_);
  if (!db_) return 0;
  Stmt st(db_, "DELETE FROM net_probe WHERE ts_ms<?1");
  if (!st.ok()) return 0;
  st.bind(1, cutoff_ms);
  if (st.step() != SQLITE_DONE) return 0;
  return static_cast<size_t>(sqlite3_changes(db_));
}

}  // namespace db
