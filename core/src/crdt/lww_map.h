// LWW-Map CRDT (設計書 mesh §2)。
// フラットな key→JSON値。key はドットパス ("doors.d_front.label" 等)。
// 勝敗: (hlc, author) の大きい方。削除は tombstone (deleted=true) で表現。
// delta 同期: author 毎の単調 seq による版本ベクトル。
// スレッド: Runloop 上でのみ触る (内部ロック無し)。永続化は呼び出し側 (onChange で Store へ)。
#pragma once

#include <cstdint>
#include <functional>
#include <map>
#include <optional>
#include <string>
#include <vector>

#include "util/hlc.h"

namespace db {

struct LwwEntry {
  std::string key;
  std::string value_json;  // 任意の JSON テキスト (tombstone 時は空)
  bool deleted = false;
  std::string hlc;     // 刻印
  std::string author;  // 書いたノードの node_id
  uint64_t seq = 0;    // author 内の単調連番 (1 始まり)
};

using VersionVector = std::map<std::string, uint64_t>;  // node_id → 最大 seq

class LwwMap {
 public:
  // on_change(entry, is_local): 状態が変わる度に呼ぶ (load 中は呼ばない)。
  // 呼び出し側はこれで Store 永続化・gossip push・設定再構築を行う。
  using ChangeCb = std::function<void(const LwwEntry&, bool is_local)>;

  LwwMap(std::string self_id, HlcClock& hlc);

  // 起動時に Store から全件流し込む。self の seq カウンタも復元する。
  void load(const std::vector<LwwEntry>& entries);

  // ローカル書き込み (hlc/seq を採番し on_change(_, true))
  const LwwEntry& set(const std::string& key, const std::string& value_json);
  const LwwEntry& remove(const std::string& key);  // tombstone

  // リモート適用。状態が変わったら true (+ on_change(_, false))。
  // 変わらなくても version vector は前進し得る。
  bool applyRemote(const LwwEntry& e);

  std::optional<std::string> get(const std::string& key) const;  // tombstone は nullopt
  // prefix 一致の (key, value_json) 一覧 (tombstone 除く、key 昇順)
  std::vector<std::pair<std::string, std::string>> byPrefix(const std::string& prefix) const;

  VersionVector versionVector() const;
  // remote_vv が知らない entry (自分の vv が上回る分) を返す
  std::vector<LwwEntry> deltaSince(const VersionVector& remote_vv) const;
  std::vector<LwwEntry> all() const;  // tombstone 含む (永続化・デバッグ用)

  // fleet 全員の vv が到達済み && hlc が older_than_hlc より古い tombstone を物理削除
  size_t gcTombstones(const VersionVector& fleet_min_vv, const std::string& older_than_hlc);

  // ドットパス群から入れ子 JSON 文書を組み立てる (設定スナップショット用)。
  // 値はそのまま埋め込む。配列は「値としての JSON 配列」で表現されている前提。
  std::string materializeJson(const std::string& prefix = "") const;

  void onChange(ChangeCb cb) { on_change_ = std::move(cb); }
  const std::string& selfId() const { return self_id_; }

 private:
  std::string self_id_;
  HlcClock& hlc_;
  std::map<std::string, LwwEntry> map_;  // key → 現勝者 (tombstone 含む)
  VersionVector vv_;
  uint64_t self_seq_ = 0;
  ChangeCb on_change_;
};

}  // namespace db
