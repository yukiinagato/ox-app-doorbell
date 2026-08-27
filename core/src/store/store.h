// SQLite 永続化層 (WAL)。テーブル: meta / config / events。
// スレッド: Runloop 上でのみ (SQLITE_THREADSAFE でも直列前提)。
// 破損時は自動でバックアップ後に再生成 (mesh から再同期できる設計のため損失許容)。
#pragma once

#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <vector>

#include "crdt/lww_map.h"
#include "events/events.h"

struct sqlite3;

namespace db {

class Store {
 public:
  Store() = default;
  ~Store();
  Store(const Store&) = delete;
  Store& operator=(const Store&) = delete;

  // path: ファイルパス、":memory:" も可 (テスト)。失敗時 false。
  bool open(const std::string& path);
  void close();
  bool isOpen() const { return db_ != nullptr; }

  // --- meta (node_id, epoch, 管理パスワード hash 等の単純 KV) ---
  std::optional<std::string> metaGet(const std::string& key);
  void metaSet(const std::string& key, const std::string& value);

  // --- config (LWW entries 全量) ---
  void configPut(const LwwEntry& e);  // upsert (key が主キー)
  void configDelete(const std::string& key);  // tombstone GC 後の物理削除
  std::vector<LwwEntry> configLoadAll();

  // --- events ---
  // 既存 (origin,seq) なら無視して false
  bool eventPut(const EventRecord& e);
  bool eventExists(const std::string& origin, uint64_t seq);
  void eventSetNotify(const std::string& origin, uint64_t seq, const std::string& notify_json);
  std::optional<EventRecord> eventGet(const std::string& origin, uint64_t seq);
  std::map<std::string, uint64_t> eventHeads();  // origin → MAX(seq)
  // remote_heads を超える分を (hlc 昇順, limit 件まで)
  std::vector<EventRecord> eventsSince(const std::map<std::string, uint64_t>& remote_heads,
                                       size_t limit);
  // 新しい順に limit 件 (管理画面用)
  std::vector<EventRecord> recentEvents(size_t limit);
  // 上限管理: 件数 > max_events または hlc物理部が cutoff_wall_ms より古いものを削除
  size_t pruneEvents(size_t max_events, int64_t cutoff_wall_ms);

 private:
  bool exec(const char* sql);
  bool migrate();
  sqlite3* db_ = nullptr;
};

}  // namespace db
