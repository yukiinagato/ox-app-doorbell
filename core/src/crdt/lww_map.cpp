// LWW-Map CRDT の実装 (lww_map.h 参照)。
// 勝敗は (hlc, author) の辞書順比較 — hlc 文字列は辞書順 == HLC 順 (util/hlc.h 参照)。
#include "crdt/lww_map.h"

#include <algorithm>
#include <tuple>

#include "util/json.h"

namespace db {

namespace {

// a が b に勝つなら true。(hlc, author) 同値は「同一書き込み」なので引き分け (適用側で無視)。
bool wins(const LwwEntry& a, const LwwEntry& b) {
  return std::tie(a.hlc, a.author) > std::tie(b.hlc, b.author);
}

// fleet_min_vv が entry の (author, seq) を被覆済みか (author 不在は未被覆扱い)
bool covered(const VersionVector& vv, const LwwEntry& e) {
  auto it = vv.find(e.author);
  return it != vv.end() && it->second >= e.seq;
}

}  // namespace

LwwMap::LwwMap(std::string self_id, HlcClock& hlc) : self_id_(std::move(self_id)), hlc_(hlc) {}

void LwwMap::load(const std::vector<LwwEntry>& entries) {
  for (const LwwEntry& e : entries) {
    // 永続化済み刻印を観測: 再起動後に壁時計が巻き戻っていても (CMOS 電池切れ等)、
    // 以後のローカル tick が既存 entry より過去に落ちないようにする。
    hlc_.observe(e.hlc);
    uint64_t& known = vv_[e.author];
    if (e.seq > known) known = e.seq;
    if (e.author == self_id_ && e.seq > self_seq_) self_seq_ = e.seq;  // 採番の復元
    auto it = map_.find(e.key);
    if (it == map_.end()) {
      map_.emplace(e.key, e);
    } else if (wins(e, it->second)) {  // Store に同一 key が重複していても勝者だけ残す
      it->second = e;
    }
    // on_change は呼ばない (流し込みのみ)
  }
}

const LwwEntry& LwwMap::set(const std::string& key, const std::string& value_json) {
  LwwEntry e;
  e.key = key;
  e.value_json = value_json;
  e.hlc = hlc_.tick();  // 観測済み最大 HLC より必ず大きい → ローカル書き込みは常に現勝者に勝つ
  e.author = self_id_;
  e.seq = ++self_seq_;
  vv_[self_id_] = self_seq_;
  LwwEntry& slot = map_[key];
  slot = std::move(e);
  if (on_change_) on_change_(slot, true);
  return slot;
}

const LwwEntry& LwwMap::remove(const std::string& key) {
  LwwEntry e;
  e.key = key;
  e.deleted = true;  // tombstone (value_json は空)
  e.hlc = hlc_.tick();
  e.author = self_id_;
  e.seq = ++self_seq_;
  vv_[self_id_] = self_seq_;
  LwwEntry& slot = map_[key];
  slot = std::move(e);
  if (on_change_) on_change_(slot, true);
  return slot;
}

bool LwwMap::applyRemote(const LwwEntry& e) {
  // リモート刻印の観測 (以後のローカル tick がこの entry を必ず上回るように)。
  hlc_.observe(e.hlc);
  // vv は状態が変わらなくても常に前進。順序逆転で同一 author の古い seq が
  // 後から届いても max なので巻き戻らない。
  uint64_t& known = vv_[e.author];
  if (e.seq > known) known = e.seq;
  auto it = map_.find(e.key);
  if (it != map_.end()) {
    if (!wins(e, it->second)) return false;  // 敗者と同値 (二重配送) は無視
    it->second = e;
  } else {
    it = map_.emplace(e.key, e).first;
  }
  if (on_change_) on_change_(it->second, false);
  return true;
}

std::optional<std::string> LwwMap::get(const std::string& key) const {
  auto it = map_.find(key);
  if (it == map_.end() || it->second.deleted) return std::nullopt;
  return it->second.value_json;
}

std::vector<std::pair<std::string, std::string>> LwwMap::byPrefix(const std::string& prefix) const {
  std::vector<std::pair<std::string, std::string>> out;
  // map_ は key 昇順なので prefix 帯は連続 — lower_bound から一致が切れるまで走査
  for (auto it = map_.lower_bound(prefix); it != map_.end(); ++it) {
    if (it->first.compare(0, prefix.size(), prefix) != 0) break;
    if (!it->second.deleted) out.emplace_back(it->first, it->second.value_json);
  }
  return out;
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
  // (author, seq) の決定的順序 (受信側の適用・再送の比較を安定させる)
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

size_t LwwMap::gcTombstones(const VersionVector& fleet_min_vv, const std::string& older_than_hlc) {
  size_t erased = 0;
  for (auto it = map_.begin(); it != map_.end();) {
    const LwwEntry& e = it->second;
    // fleet 全員が受領済み (被覆) かつ十分古い tombstone のみ物理削除。
    // vv_ は消さない — 「知っている」事実は保持する。
    if (e.deleted && e.hlc < older_than_hlc && covered(fleet_min_vv, e)) {
      it = map_.erase(it);
      erased++;
    } else {
      ++it;
    }
  }
  return erased;
}

std::string LwwMap::materializeJson(const std::string& prefix) const {
  auto root = json::obj();
  // map_ 走査 = キー昇順の挿入。prefix は部分木の取り出し: prefix (と直後の '.') を
  // 取り除いた残りをドットパスとして組み立てる。
  for (auto it = map_.lower_bound(prefix); it != map_.end(); ++it) {
    if (it->first.compare(0, prefix.size(), prefix) != 0) break;
    const LwwEntry& e = it->second;
    if (e.deleted) continue;
    std::string rest = it->first.substr(prefix.size());
    if (!rest.empty() && rest[0] == '.') rest.erase(0, 1);
    // ドット分割 (空セグメントは飛ばす)
    std::vector<std::string> segs;
    size_t pos = 0;
    while (pos <= rest.size()) {
      size_t dot = rest.find('.', pos);
      if (dot == std::string::npos) dot = rest.size();
      if (dot > pos) segs.push_back(rest.substr(pos, dot - pos));
      pos = dot + 1;
    }
    if (segs.empty()) continue;  // key == prefix はルートに置き場が無いので出力しない
    cJSON* node = root.get();
    for (size_t i = 0; i + 1 < segs.size(); ++i) {
      cJSON* child = json::get(node, segs[i].c_str());
      if (!child || !cJSON_IsObject(child)) {
        // 途中ノードが無い/非オブジェクト → オブジェクトで置換 (深いパス優先)
        child = json::addObj(node, segs[i].c_str());
      }
      node = child;
    }
    const char* leaf = segs.back().c_str();
    cJSON* existing = json::get(node, leaf);
    if (existing && cJSON_IsObject(existing)) continue;  // より深いパスが作った枝は潰さない
    json::Doc val = json::parse(e.value_json);
    if (!val) val = json::Doc(cJSON_CreateString(e.value_json.c_str()));  // パース不能 → 文字列
    json::setItem(node, leaf, std::move(val));
  }
  return json::dump(root.get());
}

}  // namespace db
