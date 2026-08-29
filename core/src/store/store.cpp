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
  std::lock_guard<std::mutex> lk(mu_);
  closeLocked();
  // 開いて WAL + busy_timeout を設定し、スキーマを流す。どこかで失敗したら破損とみなす。
  auto tryOpen = [&]() -> bool {
    if (sqlite3_open(path.c_str(), &db_) != SQLITE_OK) return false;
    sqlite3_busy_timeout(db_, 3000);
    if (!exec("PRAGMA journal_mode=WAL;")) return false;
    return migrate();
  };
  if (tryOpen()) return true;
  closeLocked();  // 旧: close() — mu_ 二重ロック (macOS デッドロック / iOS5 で破壊) だった
  if (path == ":memory:") return false;
  // 既存ファイルをバックアップして再作成 (WAL/SHM の残骸は捨てる)
  std::string backup = path + ".corrupt-" + std::to_string(static_cast<long long>(std::time(nullptr)));
  std::rename(path.c_str(), backup.c_str());
  std::remove((path + "-wal").c_str());
  std::remove((path + "-shm").c_str());
  DB_LOGW(kTag, "DB を開けないためバックアップして再作成: " + backup);
  if (tryOpen()) return true;
  closeLocked();  // 同上
  return false;
}

void Store::close() {
  std::lock_guard<std::mutex> lk(mu_);
  closeLocked();
}

// mu_ 保持中に呼ぶこと (open/close 内部用)
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
      "CREATE INDEX IF NOT EXISTS idx_events_hlc ON events(hlc);"
      "CREATE TABLE IF NOT EXISTS tg_queue("
      "  id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT, chat_id TEXT, payload TEXT,"
      "  snapshot BLOB, attempts INT, next_retry_ms INT, created_ms INT);"
      "CREATE TABLE IF NOT EXISTS net_probe("
      "  ts_ms INT, target TEXT, host TEXT, ok INT, rtt_ms INT);"
      "CREATE INDEX IF NOT EXISTS idx_net_probe_ts ON net_probe(ts_ms);";
  if (!exec(ddl)) return false;
  // schema_version は meta に記録 (将来の段階的マイグレーションの起点)
  // 注意: ここは open() が mu_ を保持している内側。Locked 版を使うこと
  // (旧実装は公開版 metaGet/metaSet を呼び、非再帰 mutex を二重ロック —
  //  macOS では即デッドロック、iOS5 では通ってしまい SQLite 並行進入 → メモリ破壊)。
  if (!metaGetLocked("schema_version"))
    metaSetLocked("schema_version", std::to_string(kSchemaVersion));
  // 累計触発カウンタの初回バックフィル (既存 press をカウント。以後は eventPut が +1)
  if (!metaGetLocked("stat_press_total"))
    metaSetLocked("stat_press_total",
                  std::to_string(countEventsOfTypeLocked("press")));
  return true;
}

// --- meta ---

// mu_ 保持中に呼ぶ内部版。ロック取得なし (migrate / eventPut 専用)。
std::optional<std::string> Store::metaGetLocked(const std::string& key) {
  Stmt st(db_, "SELECT value FROM meta WHERE key=?1");
  if (!st.ok()) return std::nullopt;
  st.bind(1, key);
  if (st.step() != SQLITE_ROW) return std::nullopt;
  return st.colText(0);
}

void Store::metaSetLocked(const std::string& key, const std::string& value) {
  Stmt st(db_, "INSERT OR REPLACE INTO meta(key,value) VALUES(?1,?2)");
  if (!st.ok()) return;
  st.bind(1, key);
  st.bind(2, value);
  st.step();
}

std::optional<std::string> Store::metaGet(const std::string& key) {
  std::lock_guard<std::mutex> lk(mu_);
  return metaGetLocked(key);
}

void Store::metaSet(const std::string& key, const std::string& value) {
  std::lock_guard<std::mutex> lk(mu_);
  metaSetLocked(key, value);
}

// --- config ---

void Store::configPut(const LwwEntry& e) {
  std::lock_guard<std::mutex> lk(mu_);
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
  std::lock_guard<std::mutex> lk(mu_);
  Stmt st(db_, "DELETE FROM config WHERE key=?1");
  if (!st.ok()) return;
  st.bind(1, key);
  st.step();
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
  std::lock_guard<std::mutex> lk(mu_);
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
  bool inserted = sqlite3_changes(db_) > 0;  // 既存 (origin,seq) は IGNORE され 0 件
  if (inserted && e.type == "press") {
    // 累計触発カウンタを O(1) で維持 (毎回 COUNT(*) を走らせない・prune でも減らない)
    // 注意: ここは mu_ 保持中 — 公開版 metaGet/metaSet は二重ロックになるので Locked 版を使う
    // (旧実装の二重ロックは macOS でデッドロック / iOS5 で SQLite 並行進入・メモリ破壊)。
    long long n = 0;
    auto cur = metaGetLocked("stat_press_total");
    if (cur) { try { n = std::stoll(*cur); } catch (...) { n = 0; } }
    metaSetLocked("stat_press_total", std::to_string(n + 1));
  }
  return inserted;
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
  Stmt st(db_, "SELECT origin, MAX(seq) FROM events GROUP BY origin");
  if (!st.ok()) return out;
  while (st.step() == SQLITE_ROW) out[st.colText(0)] = static_cast<uint64_t>(st.colInt(1));
  return out;
}

std::vector<EventRecord> Store::eventsSince(const std::map<std::string, uint64_t>& remote_heads,
                                            size_t limit) {
  std::lock_guard<std::mutex> lk(mu_);
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

size_t Store::countEventsOfType(const std::string& type) {
  std::lock_guard<std::mutex> lk(mu_);
  return countEventsOfTypeLocked(type);
}

// mu_ 保持中に呼ぶ内部版 (migrate 専用)。
size_t Store::countEventsOfTypeLocked(const std::string& type) {
  if (!db_) return 0;
  Stmt st(db_, "SELECT COUNT(*) FROM events WHERE type=?1");
  if (!st.ok()) return 0;
  st.bind(1, type);
  if (st.step() != SQLITE_ROW) return 0;
  return static_cast<size_t>(st.colInt(0));
}

std::vector<EventRecord> Store::recentEvents(size_t limit) {
  std::lock_guard<std::mutex> lk(mu_);
  std::vector<EventRecord> out;
  Stmt st(db_, ("SELECT " + std::string(kEventCols) +
                " FROM events ORDER BY hlc DESC LIMIT ?1").c_str());
  if (!st.ok()) return out;
  st.bind(1, static_cast<int64_t>(limit));
  while (st.step() == SQLITE_ROW) out.push_back(rowToEvent(st));
  return out;
}

std::optional<EventRecord> Store::latestEventOfTypes(const std::string& t1,
                                                    const std::string& t2) {
  std::lock_guard<std::mutex> lk(mu_);
  Stmt st(db_, ("SELECT " + std::string(kEventCols) +
                " FROM events WHERE type=?1 OR type=?2 ORDER BY hlc DESC LIMIT 1").c_str());
  if (!st.ok()) return std::nullopt;
  st.bind(1, t1);
  st.bind(2, t2);
  if (st.step() != SQLITE_ROW) return std::nullopt;
  return rowToEvent(st);
}

size_t Store::pruneEvents(size_t max_events, int64_t cutoff_wall_ms) {
  std::lock_guard<std::mutex> lk(mu_);
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

// --- tg_queue ---

namespace {
// tg_queue 行 (id,kind,chat_id,payload,snapshot,attempts,next_retry_ms,created_ms) を復元
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
