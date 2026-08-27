// SQLite 永続化層の実装 (store.h 参照)。
// 破損時は "<path>.corrupt-<epoch秒>" にリネームして再作成する
// (mesh から再同期できる設計のため損失許容)。
#include "store/store.h"

#include <cstdio>
#include <ctime>

#include "sqlite3.h"
#include "util/hlc.h"
#include "util/log.h"

namespace db {
namespace {

constexpr const char* kTag = "store";
constexpr int kSchemaVersion = 1;

// prepared statement の RAII 包み。都度 prepare で十分な規模 (store.h の注記通り)。
class Stmt {
 public:
  Stmt(sqlite3* db, const char* sql) : db_(db) {
    if (!db_) return;
    if (sqlite3_prepare_v2(db_, sql, -1, &st_, nullptr) != SQLITE_OK) {
      DB_LOGE(kTag, std::string("prepare 失敗: ") + sqlite3_errmsg(db_));
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
  int step() { return st_ ? sqlite3_step(st_) : SQLITE_ERROR; }
  std::string colText(int i) {
    const unsigned char* t = sqlite3_column_text(st_, i);
    return t ? reinterpret_cast<const char*>(t) : "";
  }
  int64_t colInt(int i) { return sqlite3_column_int64(st_, i); }

 private:
  sqlite3* db_ = nullptr;
  sqlite3_stmt* st_ = nullptr;
};

// events 行 (origin,seq,type,door,device,hlc,wall_ms,payload_json,notify_json の列順) を復元
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
  close();
  // 開いて WAL + busy_timeout を設定し、スキーマを流す。どこかで失敗したら破損とみなす。
  auto tryOpen = [&]() -> bool {
    if (sqlite3_open(path.c_str(), &db_) != SQLITE_OK) return false;
    sqlite3_busy_timeout(db_, 3000);
    if (!exec("PRAGMA journal_mode=WAL;")) return false;
    return migrate();
  };
  if (tryOpen()) return true;
  close();
  if (path == ":memory:") return false;
  // 既存ファイルをバックアップして再作成 (WAL/SHM の残骸は捨てる)
  std::string backup = path + ".corrupt-" + std::to_string(static_cast<long long>(std::time(nullptr)));
  std::rename(path.c_str(), backup.c_str());
  std::remove((path + "-wal").c_str());
  std::remove((path + "-shm").c_str());
  DB_LOGW(kTag, "DB を開けないためバックアップして再作成: " + backup);
  if (tryOpen()) return true;
  close();
  return false;
}

void Store::close() {
  if (db_) {
    sqlite3_close(db_);
    db_ = nullptr;
  }
}

bool Store::exec(const char* sql) {
  if (!db_) return false;
  char* err = nullptr;
  if (sqlite3_exec(db_, sql, nullptr, nullptr, &err) != SQLITE_OK) {
    DB_LOGE(kTag, std::string("SQL 失敗: ") + (err ? err : sqlite3_errmsg(db_)));
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
      "CREATE INDEX IF NOT EXISTS idx_events_hlc ON events(hlc);";
  if (!exec(ddl)) return false;
  // schema_version は meta に記録 (将来の段階的マイグレーションの起点)
  if (!metaGet("schema_version")) metaSet("schema_version", std::to_string(kSchemaVersion));
  return true;
}

// --- meta ---

std::optional<std::string> Store::metaGet(const std::string& key) {
  Stmt st(db_, "SELECT value FROM meta WHERE key=?1");
  if (!st.ok()) return std::nullopt;
  st.bind(1, key);
  if (st.step() != SQLITE_ROW) return std::nullopt;
  return st.colText(0);
}

void Store::metaSet(const std::string& key, const std::string& value) {
  Stmt st(db_, "INSERT OR REPLACE INTO meta(key,value) VALUES(?1,?2)");
  if (!st.ok()) return;
  st.bind(1, key);
  st.bind(2, value);
  st.step();
}

// --- config ---

void Store::configPut(const LwwEntry& e) {
  Stmt st(db_,
          "INSERT OR REPLACE INTO config(key,value_json,deleted,hlc,author,seq)"
          " VALUES(?1,?2,?3,?4,?5,?6)");
  if (!st.ok()) return;
  st.bind(1, e.key);
  st.bind(2, e.value_json);
  st.bind(3, static_cast<int64_t>(e.deleted ? 1 : 0));
  st.bind(4, e.hlc);
  st.bind(5, e.author);
  st.bind(6, static_cast<int64_t>(e.seq));
  st.step();
}

void Store::configDelete(const std::string& key) {
  Stmt st(db_, "DELETE FROM config WHERE key=?1");
  if (!st.ok()) return;
  st.bind(1, key);
  st.step();
}

std::vector<LwwEntry> Store::configLoadAll() {
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
  if (!db_) return false;
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
  return sqlite3_changes(db_) > 0;  // 既存 (origin,seq) は IGNORE され 0 件
}

bool Store::eventExists(const std::string& origin, uint64_t seq) {
  Stmt st(db_, "SELECT 1 FROM events WHERE origin=?1 AND seq=?2");
  if (!st.ok()) return false;
  st.bind(1, origin);
  st.bind(2, static_cast<int64_t>(seq));
  return st.step() == SQLITE_ROW;
}

void Store::eventSetNotify(const std::string& origin, uint64_t seq,
                           const std::string& notify_json) {
  Stmt st(db_, "UPDATE events SET notify_json=?3 WHERE origin=?1 AND seq=?2");
  if (!st.ok()) return;
  st.bind(1, origin);
  st.bind(2, static_cast<int64_t>(seq));
  st.bind(3, notify_json);
  st.step();
}

std::optional<EventRecord> Store::eventGet(const std::string& origin, uint64_t seq) {
  Stmt st(db_, ("SELECT " + std::string(kEventCols) +
                " FROM events WHERE origin=?1 AND seq=?2").c_str());
  if (!st.ok()) return std::nullopt;
  st.bind(1, origin);
  st.bind(2, static_cast<int64_t>(seq));
  if (st.step() != SQLITE_ROW) return std::nullopt;
  return rowToEvent(st);
}

std::map<std::string, uint64_t> Store::eventHeads() {
  std::map<std::string, uint64_t> out;
  Stmt st(db_, "SELECT origin, MAX(seq) FROM events GROUP BY origin");
  if (!st.ok()) return out;
  while (st.step() == SQLITE_ROW) out[st.colText(0)] = static_cast<uint64_t>(st.colInt(1));
  return out;
}

std::vector<EventRecord> Store::eventsSince(const std::map<std::string, uint64_t>& remote_heads,
                                            size_t limit) {
  // hlc 昇順で走査し、remote_heads が既に知る (origin, seq<=head) を飛ばして limit 件まで。
  std::vector<EventRecord> out;
  Stmt st(db_, ("SELECT " + std::string(kEventCols) + " FROM events ORDER BY hlc ASC").c_str());
  if (!st.ok()) return out;
  while (out.size() < limit && st.step() == SQLITE_ROW) {
    EventRecord e = rowToEvent(st);
    auto it = remote_heads.find(e.origin);
    if (it != remote_heads.end() && e.seq <= it->second) continue;
    out.push_back(std::move(e));
  }
  return out;
}

std::vector<EventRecord> Store::recentEvents(size_t limit) {
  std::vector<EventRecord> out;
  Stmt st(db_, ("SELECT " + std::string(kEventCols) +
                " FROM events ORDER BY hlc DESC LIMIT ?1").c_str());
  if (!st.ok()) return out;
  st.bind(1, static_cast<int64_t>(limit));
  while (st.step() == SQLITE_ROW) out.push_back(rowToEvent(st));
  return out;
}

size_t Store::pruneEvents(size_t max_events, int64_t cutoff_wall_ms) {
  if (!db_) return 0;
  size_t deleted = 0;
  // 1) hlc 物理部 (先頭 12 hex, HlcClock::format と同表現) が cutoff より古いもの
  {
    char cut[16];
    std::snprintf(cut, sizeof(cut), "%012llx",
                  static_cast<unsigned long long>(cutoff_wall_ms & 0xffffffffffffLL));
    Stmt st(db_, "DELETE FROM events WHERE substr(hlc,1,12) < ?1");
    if (st.ok()) {
      st.bind(1, std::string(cut));
      if (st.step() == SQLITE_DONE) deleted += static_cast<size_t>(sqlite3_changes(db_));
    }
  }
  // 2) 件数超過分を hlc 昇順で古い方から
  int64_t count = 0;
  {
    Stmt st(db_, "SELECT COUNT(*) FROM events");
    if (st.ok() && st.step() == SQLITE_ROW) count = st.colInt(0);
  }
  if (count > static_cast<int64_t>(max_events)) {
    Stmt st(db_,
            "DELETE FROM events WHERE rowid IN"
            " (SELECT rowid FROM events ORDER BY hlc ASC LIMIT ?1)");
    if (st.ok()) {
      st.bind(1, count - static_cast<int64_t>(max_events));
      if (st.step() == SQLITE_DONE) deleted += static_cast<size_t>(sqlite3_changes(db_));
    }
  }
  return deleted;
}

}  // namespace db
