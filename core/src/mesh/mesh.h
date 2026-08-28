// P2P 自愈メッシュ (設計書 mesh §1)。
//  - 発見: IDiscovery (UDP beacon / InMem) + seed peers + PEERS gossip 伝染
//  - 伝送: ITransport 上に PSK 認証付き暗号チャネル (Monocypher, 設計 §1.3)
//      握手: 双方 32B nonce 交換 → session_key = BLAKE2b(psk, nonceA||nonceB||idA||idB)
//      以降フレームは ChaCha20-Poly1305 AEAD (フレーム連番 nonce, 再生防止)
//  - 成員: 全量ノード表 gossip + 直連心跳 (PING/PONG)。suspect→dead 判定は設計値
//  - 選主: 無投票の確定的順序 (cap_rank 降順 → node_id) + CLAIM lease
//  - 同期: SYNC_REQ/RESP で LwwMap (vv) と EventLog (heads) の push-pull anti-entropy
//  - 配対: JOIN_REQ (PIN の HMAC チャレンジ) → PSK/seeds/設定スナップショット配布
// メッセージ種別 (1B): 設計 §1.4 準拠 + EVENT(即時push)/COMMAND/SNAP(快照取得)/
//   BLOB_REQ/RESP(統一資産の blob 転送 — 上限 3MB, base64 チャンク)
// スレッド: 全 API・全コールバックは Runloop 上。
#pragma once

#include <array>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "crdt/lww_map.h"
#include "events/events.h"
#include "mesh/transport.h"
#include "util/clock.h"
#include "util/hlc.h"
#include "util/runloop.h"

namespace db {

class Store;

struct MeshSettings {
  std::string node_id;         // 32 hex
  uint64_t epoch = 1;          // 起動毎 +1 (呼び出し側が Store から復元)
  std::string listen_addr;     // "0.0.0.0:47172" / InMem 任意文字列
  std::string advertise_addr;  // 他ノードに教える自アドレス ("10.0.1.21:47172")
  std::vector<std::string> seed_peers;
  std::array<uint8_t, 32> psk{};  // 集群共有鍵
  std::string psk_id = "k1";
  std::string role = "door_station";  // door_station | indoor_panel
  std::string sw_version = "0.0.1";
  std::string caps_json = "{}";  // {"tls12":bool,"wan":bool,"mains_power":bool,
                                 //  "mqtt_reachable":bool,"wall_clock_sane":bool,"cpu_score":int}
  // タイミング (テストでは縮小して決定的シミュレーションに使う)
  int64_t heartbeat_ms = 3000;
  int64_t suspect_ms = 9000;
  int64_t dead_ms = 15000;
  int64_t gossip_ms = 10000;      // PEERS 交換周期
  int64_t sync_ms = 10000;        // anti-entropy 周期
  int64_t claim_ttl_ms = 30000;   // leader lease
  int64_t reconnect_ms = 5000;    // 接続再試行
  int max_neighbors = 4;          // 維持する TCP 長連数 (min(4, N-1))
};

struct PeerInfo {
  std::string id;
  std::vector<std::string> addrs;
  uint64_t epoch = 0;
  uint64_t hb_seq = 0;         // 心跳系列 (gossip 経由の生存判定)
  std::string hb_hlc;
  std::string status;          // alive | suspect | dead
  std::string caps_json;
  std::string role;
  std::string sw_version;
  int64_t last_seen_mono = 0;  // ローカル観測時刻
  bool connected = false;      // 直連 TCP があるか
};

// duty: "telegram" | "mqtt_bridge"
class Mesh {
 public:
  struct Callbacks {
    std::function<void()> on_peers_changed;
    // 遷移: (duty, leader_node_id) — 自分が leader になったかは isLeader で判定
    std::function<void(const std::string&, const std::string&)> on_leader_changed;
    // 他ノードが dead / 復活した (offline/online イベント生成は Node 層の責務)
    std::function<void(const std::string& node_id, bool alive)> on_peer_alive_changed;
    // 即時 push されたイベント受信 (EventLog::applyRemote 済みの新規のみ)
    std::function<void(const EventRecord&)> on_event;
    // COMMAND 受信 ({"cmd":"chime","sound":"ding1"} 等)
    std::function<void(const std::string& from, const std::string& cmd_json)> on_command;
    // 近隣の未配対デバイス一覧が変化した (承認 UI 更新用)
    std::function<void()> on_pending_changed;
    // INVITE 受理 / PIN 参加で PSK を取得した (Node が boot 設定へ永続化 + 再起動)
    std::function<void()> on_paired;
  };

  Mesh(Runloop& loop, IClock& clock, HlcClock& hlc, ITransport& transport,
       IDiscovery* discovery /*nullable*/, Store& store, LwwMap& config, EventLog& events,
       MeshSettings settings, Callbacks cbs);
  ~Mesh();

  void start();
  void stop();

  // --- 成員・リーダー ---
  std::vector<PeerInfo> peers() const;  // 自分含む
  std::string leaderFor(const std::string& duty) const;  // "" = 不在
  bool isLeader(const std::string& duty) const;
  void setCaps(const std::string& caps_json);  // 変化時に再 gossip・再選主

  // --- データ面 ---
  // ローカル発イベントの即時 push (gossip 周期を待たない; press 用)
  void broadcastEvent(const EventRecord& ev);
  // LwwMap のローカル書き込み後に呼ぶ (隣接へ即時 delta push)
  void pushConfigDelta(const std::vector<LwwEntry>& entries);
  void sendCommand(const std::string& node_id, const std::string& cmd_json);
  void broadcastCommand(const std::string& cmd_json);

  // --- 快照 (Telegram 通知の写真用) ---
  // 自ノードの最新 JPEG 供給者を登録 (Node が FrameBus::latestJpeg を配線)。
  // 空 Bytes = 提供不可 (カメラ無し等)。SNAP_REQ への応答に使う。
  void setSnapshotProvider(std::function<Bytes()> provider);
  // node_id の最新 JPEG を取得 (SNAP_REQ/SNAP_RESP, base64, 上限 300KB, 5 秒タイムアウト)。
  // 自分宛は provider を直接呼ぶ。直連チャネルが無い/失敗/超過は空 Bytes。
  void fetchSnapshot(const std::string& node_id, std::function<void(Bytes jpeg)> cb);

  // --- 資産 blob (統一資産システム — docs/config-schema.md assets) ---
  // 自ノードの blob 供給者 (hash → 実体; 空 = 持っていない)。Node が assets/ を配線する。
  // BLOB_REQ への応答に使う (SNAP_REQ の一般化)。
  void setBlobProvider(std::function<Bytes(const std::string& hash)> provider);
  // hash の blob を取得 (BLOB_REQ/BLOB_RESP, base64 チャンク, 上限 3MB)。
  // 自分の provider が持っていればそれを返し、無ければ直連 peer を順に試して
  // 最初に持っているノードから取る。全滅/超過/タイムアウトは空 Bytes。
  // ハッシュの検証は呼び出し側 (Node) の責務。
  void fetchBlob(const std::string& hash, std::function<void(Bytes data)> cb);

  // --- 配対 (設計 §1.6) ---
  struct JoinToken {
    std::string pin;          // 6 桁
    int64_t expires_mono = 0; // 10 分
  };
  JoinToken createJoinToken();
  // 新ノード側: host へ JOIN。成功時 done(true,"") — PSK/seeds/設定は適用済み。
  // psk が未設定 (全ゼロ) の状態で呼ぶ。
  void joinCluster(const std::string& host_addr, const std::string& pin,
                   std::function<void(bool ok, const std::string& err)> done);

  // --- 配対 (発見 → 招待 push; QR/承認/配対モード。§1.6 拡張) ---
  bool isPaired() const;            // 全ゼロ PSK = 未配対
  std::string pairingSelfJson();    // 未配対の当機の告知内容 (QR に載せる id/addr/pk)
  std::string pendingJson();        // 近隣で発見した未配対デバイス一覧 + 配対モード状態
  void inviteDevice(const std::string& id);  // 一覧の 1 台へ {psk,seeds,cfg} を封緘 push
  // QR/入力から得た addr+pk へ直接招待 (発見前でも可 — 跨網段/QR スキャン用)
  void inviteDeviceDirect(const std::string& addr, const std::string& pk);
  void setPairingMode(int64_t ttl_ms);       // 配対モードを ttl_ms 間 ON (発見即自動招待)

  const MeshSettings& settings() const { return settings_; }

  // 内部実装 (mesh.cpp 側で定義)
  struct Impl;

 private:
  MeshSettings settings_;
  std::unique_ptr<Impl> impl_;
};

// テスト/シミュレーション用インメモリ実装 (mesh モジュール内で提供):
//  - InMemNet: アドレス→ノードのレジストリ + 故障注入
//      partition(groups) / heal() / setDrop(prob,seed) / setDelay(ms)
//  - InMemNet::makeTransport(addr) -> ITransport*
//  - InMemDiscovery: 同一 InMemNet 内の announce を配送
class InMemNet {
 public:
  explicit InMemNet(Runloop& loop);
  ~InMemNet();

  std::unique_ptr<ITransport> makeTransport(const std::string& addr);
  std::unique_ptr<IDiscovery> makeDiscovery(const std::string& addr);

  // 故障注入 (アドレス単位)
  void partition(const std::vector<std::vector<std::string>>& groups);  // 組間を遮断
  void heal();
  void setDrop(double probability, uint32_t seed);  // 決定的 PRNG
  void setDelayMs(int64_t delay_ms);
  void killNode(const std::string& addr);   // 全接続切断 + listen 停止
  struct Impl;

 private:
  std::unique_ptr<Impl> impl_;
};

}  // namespace db
