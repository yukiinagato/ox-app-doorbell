// Mesh 本体 (mesh.h 参照)。
//  - 成員: 全量ノード表 gossip (PEERS) + 直連心跳 (PING/PONG)。生死は hb_seq の前進で判定
//  - 選主: 無投票確定的 — duty 毎に (rank=cpu_score, node_id) 最大の eligible ノード + CLAIM lease
//  - 同期: SYNC_REQ/RESP push-pull (LwwMap vv / EventLog heads)、EVENT は TTL2 の即時 flood
//  - 配対: JOIN_* (PIN の HMAC チャレンジ) — 平文フレーム (kFrameJoin) で PSK 配布
// スレッド: 全 API・全コールバックは Runloop 上。
#include "mesh/mesh.h"

#include <algorithm>
#include <set>
#include <tuple>

#include "mesh/secure_channel.h"
#include "monocypher.h"
#include "store/store.h"
#include "util/common.h"
#include "util/ids.h"
#include "util/json.h"
#include "util/log.h"

namespace db {

namespace {

constexpr int64_t kJoinTokenTtlMs = 10 * 60 * 1000;  // 配対トークン 10 分
constexpr size_t kSyncEventLimit = 200;              // 1 応答の最大イベント数
constexpr int kEventTtl = 2;                         // EVENT 即時 push の flood TTL
constexpr int64_t kSnapTimeoutMs = 5000;             // 快照取得タイムアウト
constexpr size_t kSnapMaxBytes = 300 * 1024;         // 快照 JPEG 上限 (超過は失敗扱い)

// 予約メッセージ型 (将来 OTA 用 — 実装はまだ無い)
[[maybe_unused]] constexpr const char* kMsgVersionAnnounce = "VERSION_ANNOUNCE";
[[maybe_unused]] constexpr const char* kMsgFetchBlob = "FETCH_BLOB";

// ---- シリアライズ ----

json::Doc entryToJson(const LwwEntry& e) {
  auto o = json::obj();
  json::set(o.get(), "k", e.key);
  json::set(o.get(), "v", e.value_json);
  json::setBool(o.get(), "d", e.deleted);
  json::set(o.get(), "h", e.hlc);
  json::set(o.get(), "a", e.author);
  json::set(o.get(), "s", static_cast<int64_t>(e.seq));
  return o;
}

LwwEntry entryFromJson(const cJSON* o) {
  LwwEntry e;
  e.key = json::getString(o, "k");
  e.value_json = json::getString(o, "v");
  e.deleted = json::getBool(o, "d");
  e.hlc = json::getString(o, "h");
  e.author = json::getString(o, "a");
  e.seq = static_cast<uint64_t>(json::getInt(o, "s"));
  return e;
}

json::Doc eventToJson(const EventRecord& e) {
  auto o = json::obj();
  json::set(o.get(), "origin", e.origin);
  json::set(o.get(), "seq", static_cast<int64_t>(e.seq));
  json::set(o.get(), "type", e.type);
  json::set(o.get(), "door", e.door);
  json::set(o.get(), "device", e.device);
  json::set(o.get(), "hlc", e.hlc);
  json::set(o.get(), "wall", e.wall_ms);
  json::set(o.get(), "payload", e.payload_json);
  json::set(o.get(), "notify", e.notify_json);
  return o;
}

EventRecord eventFromJson(const cJSON* o) {
  EventRecord e;
  e.origin = json::getString(o, "origin");
  e.seq = static_cast<uint64_t>(json::getInt(o, "seq"));
  e.type = json::getString(o, "type");
  e.door = json::getString(o, "door");
  e.device = json::getString(o, "device");
  e.hlc = json::getString(o, "hlc");
  e.wall_ms = json::getInt(o, "wall");
  e.payload_json = json::getString(o, "payload");
  e.notify_json = json::getString(o, "notify");
  return e;
}

void mapToJson(cJSON* obj, const std::map<std::string, uint64_t>& m) {
  for (const auto& kv : m) json::set(obj, kv.first.c_str(), static_cast<int64_t>(kv.second));
}

std::map<std::string, uint64_t> mapFromJson(const cJSON* obj) {
  std::map<std::string, uint64_t> m;
  const cJSON* it = nullptr;
  cJSON_ArrayForEach(it, obj) {
    if (it->string && cJSON_IsNumber(it)) {
      m[it->string] = static_cast<uint64_t>(it->valuedouble);
    }
  }
  return m;
}

// ---- 配対の鍵導出 ----

// K = BLAKE2b-256(pin || salt)
std::array<uint8_t, 32> joinKey(const std::string& pin, const Bytes& salt) {
  crypto_blake2b_ctx ctx;
  crypto_blake2b_init(&ctx, 32);
  crypto_blake2b_update(&ctx, reinterpret_cast<const uint8_t*>(pin.data()), pin.size());
  crypto_blake2b_update(&ctx, salt.data(), salt.size());
  std::array<uint8_t, 32> k{};
  crypto_blake2b_final(&ctx, k.data());
  return k;
}

// HMAC(K, challenge || joiner_id)
std::array<uint8_t, 32> joinProof(const std::array<uint8_t, 32>& k, const Bytes& challenge,
                                  const std::string& joiner_id) {
  crypto_blake2b_ctx ctx;
  crypto_blake2b_keyed_init(&ctx, 32, k.data(), k.size());
  crypto_blake2b_update(&ctx, challenge.data(), challenge.size());
  crypto_blake2b_update(&ctx, reinterpret_cast<const uint8_t*>(joiner_id.data()),
                        joiner_id.size());
  std::array<uint8_t, 32> mac{};
  crypto_blake2b_final(&ctx, mac.data());
  return mac;
}

void sendJoinFrame(const ConnPtr& conn, const cJSON* msg) {
  std::string s = json::dump(msg);
  Bytes f;
  f.reserve(1 + s.size());
  f.push_back(kFrameJoin);
  f.insert(f.end(), s.begin(), s.end());
  conn->send(f);
}

const char* const kDuties[] = {"telegram", "mqtt_bridge"};

}  // namespace

// ============================================================================

struct Mesh::Impl {
  Runloop& loop;
  IClock& clock;
  HlcClock& hlc;
  ITransport& tp;
  IDiscovery* disc;
  Store& store;
  LwwMap& config;
  EventLog& events;
  MeshSettings& st;
  Callbacks cbs;
  bool running = false;

  // ---- 成員表 ----
  struct Peer {
    PeerInfo info;
    int64_t last_adv_mono = 0;  // (epoch, hb_seq) が前進したローカル時刻
  };
  std::map<std::string, Peer> peers;  // 自分含む

  // ---- 接続 ----
  std::map<std::string, std::shared_ptr<SecureChannel>> chans;  // 確立済み peer_id → chan
  std::vector<std::shared_ptr<SecureChannel>> pending;          // 握手中
  std::set<std::string> dialing;                                // connect() 応答待ちの addr
  std::set<std::string> known_addrs;                            // 接続候補 addr
  std::map<std::string, std::string> addr_owner;                // addr → node_id (既知分)

  // ---- 選主 ----
  struct DutyState {
    std::string leader;
    int64_t last_claim_mono = -(int64_t{1} << 60);
    uint64_t term = 0;
  };
  std::map<std::string, DutyState> duties;

  // ---- 配対 (host) ----
  struct Token {
    std::string pin;
    int64_t expires_mono = 0;
    int fails = 0;
    bool active = false;
  } token;

  // 受理直後の生接続 (握手/JOIN の種別判定前 + JOIN 進行中)
  struct Inbound {
    ConnPtr conn;
    Bytes challenge, salt;
    bool challenged = false;
  };
  std::vector<std::shared_ptr<Inbound>> inbound;

  // ---- 配対 (joiner) ----
  struct JoinRun {
    ConnPtr conn;
    std::string pin;
    std::array<uint8_t, 32> k{};
    bool key_ready = false;
    std::function<void(bool, const std::string&)> done;
    uint64_t timeout_id = 0;
    bool finished = false;
  };
  std::shared_ptr<JoinRun> join;

  // ---- 快照 ----
  std::function<Bytes()> snap_provider;  // 自ノードの最新 JPEG (Node が配線)
  struct SnapWait {
    std::function<void(Bytes)> cb;
    uint64_t timeout_id = 0;
  };
  std::map<uint64_t, SnapWait> snap_waits;  // rid → 応答待ち
  uint64_t snap_rid = 0;

  std::vector<uint64_t> timers;
  uint64_t sync_rr = 0;  // anti-entropy の相手選択 (決定的 round-robin)
  // 生存トークン: post 済みラムダ/接続コールバックが Impl 破棄後に this へ触れないための弱参照
  std::shared_ptr<char> alive = std::make_shared<char>(0);

  // Impl 生存確認付きの post (`fn` は Impl メンバを触ってよい)
  void postGuarded(std::function<void()> fn) {
    std::weak_ptr<char> w = alive;
    loop.post([w, fn] {
      if (!w.expired()) fn();
    });
  }

  Impl(Runloop& l, IClock& c, HlcClock& h, ITransport& t, IDiscovery* d, Store& s, LwwMap& cfg,
       EventLog& ev, MeshSettings& settings, Callbacks callbacks)
      : loop(l), clock(c), hlc(h), tp(t), disc(d), store(s), config(cfg), events(ev),
        st(settings), cbs(std::move(callbacks)) {}

  int64_t now() { return clock.monoMs(); }
  int64_t hsTimeoutMs() const { return st.reconnect_ms; }

  // ------------------------------------------------------------------ 起動/停止

  void start() {
    if (running) return;
    running = true;
    // 自分の成員レコード
    Peer& self = peers[st.node_id];
    self.info.id = st.node_id;
    self.info.addrs = {st.advertise_addr};
    self.info.epoch = st.epoch;
    self.info.hb_seq = 0;
    self.info.hb_hlc = hlc.tick();
    self.info.status = "alive";
    self.info.caps_json = st.caps_json;
    self.info.role = st.role;
    self.info.sw_version = st.sw_version;
    self.last_adv_mono = now();

    for (const auto& a : st.seed_peers) {
      if (!isSelfAddr(a)) known_addrs.insert(a);
    }

    tp.listen(st.listen_addr, [this](ConnPtr c) { onAccept(std::move(c)); });
    if (disc) {
      disc->start([this](const DiscoveredPeer& p) { onDiscovered(p); });
      disc->announce(st.node_id, st.advertise_addr);
    }

    timers.push_back(loop.postEvery(st.heartbeat_ms, [this] { heartbeatTick(); }));
    timers.push_back(loop.postEvery(st.gossip_ms, [this] { gossipAll(); }));
    timers.push_back(loop.postEvery(st.sync_ms, [this] { syncTick(); }));
    timers.push_back(loop.postEvery(std::max<int64_t>(1, st.claim_ttl_ms / 3),
                                    [this] { leaderTick(); }));
    timers.push_back(loop.postEvery(st.reconnect_ms, [this] { maintain(); }));
    postGuarded([this] {
      if (running) maintain();
    });
  }

  void stop() {
    if (!running) return;
    running = false;
    for (uint64_t id : timers) loop.cancel(id);
    timers.clear();
    // コールバックを外してから閉じる (post 済みラムダから this へ触れないように)
    for (auto& kv : chans) {
      kv.second->setCallbacks({});
      kv.second->close();
    }
    chans.clear();
    for (auto& ch : pending) {
      ch->setCallbacks({});
      ch->close();
    }
    pending.clear();
    for (auto& ib : inbound) {
      ib->conn->setCallbacks([](const Bytes&) {}, [] {});
      ib->conn->close();
    }
    inbound.clear();
    // 快照待ちは失敗で解決してから捨てる (呼び出し側を待たせ続けない)
    for (auto& kv : snap_waits) {
      loop.cancel(kv.second.timeout_id);
      if (kv.second.cb) kv.second.cb(Bytes());
    }
    snap_waits.clear();
    if (join) abortJoin("stopped");
    tp.stopListening();
    if (disc) disc->stop();
  }

  bool isSelfAddr(const std::string& a) const {
    return a == st.advertise_addr || a == st.listen_addr;
  }

  // ------------------------------------------------------------------ 接続受理

  void onAccept(ConnPtr conn) {
    if (!running) {
      conn->close();
      return;
    }
    auto ib = std::make_shared<Inbound>();
    ib->conn = std::move(conn);
    inbound.push_back(ib);
    std::weak_ptr<Inbound> wib = ib;
    ib->conn->setCallbacks(
        [this, wib](const Bytes& f) {
          if (auto p = wib.lock()) onInboundFrame(p, f);
        },
        [this, wib] {
          if (auto p = wib.lock()) dropInbound(p);
        });
    // 何も言ってこない接続はタイムアウトで捨てる
    std::weak_ptr<char> wa = alive;
    loop.postDelayed(hsTimeoutMs() * 4, [this, wa, wib] {
      if (wa.expired()) return;
      if (auto p = wib.lock()) {
        p->conn->close();
        dropInbound(p);
      }
    });
  }

  void dropInbound(const std::shared_ptr<Inbound>& ib) {
    inbound.erase(std::remove(inbound.begin(), inbound.end(), ib), inbound.end());
  }

  // 初回フレームの種別で JOIN (平文) と暗号握手を振り分ける
  void onInboundFrame(const std::shared_ptr<Inbound>& ib, const Bytes& f) {
    if (f.empty()) return;
    if (f[0] == kFrameJoin) {
      handleJoinHostFrame(ib, f);
      return;
    }
    // 暗号チャネルへ昇格 (以降のフレームは channel が受ける)
    dropInbound(ib);
    auto ch = makeChannel(ib->conn, /*initiator=*/false);
    ch->start();
    ch->handleRawFrame(f);
  }

  // ------------------------------------------------------------------ 暗号チャネル

  std::shared_ptr<SecureChannel> makeChannel(ConnPtr conn, bool initiator) {
    auto ch = std::make_shared<SecureChannel>(loop, std::move(conn), initiator, st.psk,
                                              st.node_id, hsTimeoutMs());
    pending.push_back(ch);
    std::weak_ptr<SecureChannel> wch = ch;
    SecureChannel::Callbacks c;
    c.on_established = [this, wch] {
      if (auto p = wch.lock()) onChanEstablished(p);
    };
    c.on_message = [this, wch](const std::string& msg) {
      if (auto p = wch.lock()) handleMessage(p, msg);
    };
    c.on_close = [this, wch] {
      if (auto p = wch.lock()) onChanClosed(p);
    };
    ch->setCallbacks(std::move(c));
    return ch;
  }

  void detachAndClose(const std::shared_ptr<SecureChannel>& ch) {
    ch->setCallbacks({});
    ch->close();
    pending.erase(std::remove(pending.begin(), pending.end(), ch), pending.end());
  }

  void onChanEstablished(const std::shared_ptr<SecureChannel>& ch) {
    pending.erase(std::remove(pending.begin(), pending.end(), ch), pending.end());
    const std::string pid = ch->peerId();
    if (pid.empty() || pid == st.node_id) {  // 自己接続は捨てる
      detachAndClose(ch);
      return;
    }
    auto it = chans.find(pid);
    if (it != chans.end() && it->second != ch) {
      // 同時双方向接続の重複解消: node_id が小さい側の発起を残す規約
      auto initiatorId = [&](const std::shared_ptr<SecureChannel>& c) {
        return c->isInitiator() ? st.node_id : pid;
      };
      if (initiatorId(ch) < initiatorId(it->second)) {
        detachAndClose(it->second);
        it->second = ch;
      } else {
        detachAndClose(ch);
        return;
      }
    } else {
      chans[pid] = ch;
    }
    Peer& p = peers[pid];
    if (p.info.id.empty()) {  // 握手で初めて知ったノード
      p.info.id = pid;
      p.info.status = "alive";
      p.last_adv_mono = now();
    }
    p.info.connected = true;
    if (ch->isInitiator()) rememberAddr(ch->remoteAddr(), pid);
    // 即時に成員表と anti-entropy を交換 (収束の高速化)
    sendPeersTo(*ch);
    sendSyncReq(*ch);
    if (cbs.on_peers_changed) cbs.on_peers_changed();
  }

  void onChanClosed(const std::shared_ptr<SecureChannel>& ch) {
    pending.erase(std::remove(pending.begin(), pending.end(), ch), pending.end());
    const std::string pid = ch->peerId();
    auto it = chans.find(pid);
    if (it != chans.end() && it->second == ch) {
      chans.erase(it);
      auto p = peers.find(pid);
      if (p != peers.end()) p->second.info.connected = false;
      if (cbs.on_peers_changed) cbs.on_peers_changed();
    }
  }

  void rememberAddr(const std::string& addr, const std::string& owner) {
    if (addr.empty() || isSelfAddr(addr)) return;
    known_addrs.insert(addr);
    if (!owner.empty()) addr_owner[addr] = owner;
  }

  void onDiscovered(const DiscoveredPeer& p) {
    if (!running || p.node_id == st.node_id) return;
    rememberAddr(p.addr, p.node_id);
    Peer& peer = peers[p.node_id];
    if (peer.info.id.empty()) {
      peer.info.id = p.node_id;
      peer.info.status = "alive";
      peer.info.addrs = {p.addr};
      peer.last_adv_mono = now();
      if (cbs.on_peers_changed) cbs.on_peers_changed();
      postGuarded([this] {
        if (running) maintain();
      });
    }
  }

  // ------------------------------------------------------------------ 接続維持

  bool dialInProgress(const std::string& addr) const {
    if (dialing.count(addr)) return true;
    for (const auto& ch : pending) {
      if (ch->isInitiator() && ch->remoteAddr() == addr) return true;
    }
    return false;
  }

  void maintain() {
    if (!running) return;
    const int budget = st.max_neighbors - static_cast<int>(chans.size());
    if (budget <= 0) return;
    // 候補: (優先度, 整列キー, addr)。優先: seed → leader → node_id 順 → 未知アドレス
    std::vector<std::tuple<int, std::string, std::string>> cand;
    std::set<std::string> leader_ids;
    for (const auto& d : duties) {
      if (!d.second.leader.empty()) leader_ids.insert(d.second.leader);
    }
    auto isSeedAddr = [this](const std::string& a) {
      return std::find(st.seed_peers.begin(), st.seed_peers.end(), a) != st.seed_peers.end();
    };
    std::set<std::string> covered_addrs;
    for (const auto& kv : peers) {
      const Peer& p = kv.second;
      if (p.info.id == st.node_id || p.info.connected || p.info.status == "dead") continue;
      std::string addr;
      bool seed = false;
      for (const auto& a : p.info.addrs) {
        if (a.empty() || isSelfAddr(a)) continue;
        if (addr.empty()) addr = a;
        if (isSeedAddr(a)) {
          addr = a;
          seed = true;
        }
        covered_addrs.insert(a);
      }
      if (addr.empty() || dialInProgress(addr)) continue;
      const int pri = seed ? 0 : (leader_ids.count(p.info.id) ? 1 : 2);
      cand.emplace_back(pri, p.info.id, addr);
    }
    for (const auto& a : known_addrs) {  // 持ち主未知のアドレス (bootstrap 用)
      if (covered_addrs.count(a) || dialInProgress(a)) continue;
      auto own = addr_owner.find(a);
      if (own != addr_owner.end() && (chans.count(own->second) || own->second == st.node_id)) {
        continue;  // 既に接続済みのノードの別アドレス
      }
      cand.emplace_back(3, a, a);
    }
    std::sort(cand.begin(), cand.end());
    int n = budget;
    for (const auto& c : cand) {
      if (n-- <= 0) break;
      dial(std::get<2>(c));
    }
  }

  void dial(const std::string& addr) {
    dialing.insert(addr);
    std::weak_ptr<char> w = alive;
    tp.connect(addr, [this, w, addr](ConnPtr conn) {
      if (w.expired()) {
        if (conn) conn->close();
        return;
      }
      dialing.erase(addr);
      if (!conn) return;  // 次の maintain で再試行
      if (!running) {
        conn->close();
        return;
      }
      makeChannel(std::move(conn), /*initiator=*/true)->start();
    });
  }

  // ------------------------------------------------------------------ 心跳と生死

  void heartbeatTick() {
    Peer& self = peers[st.node_id];
    self.info.hb_seq++;
    self.info.hb_hlc = hlc.tick();
    self.last_adv_mono = now();
    auto ping = json::obj();
    json::set(ping.get(), "t", "PING");
    fillHb(ping.get());
    broadcast(json::dump(ping.get()));
    checkLiveness();
  }

  void fillHb(cJSON* o) {
    const Peer& self = peers[st.node_id];
    json::set(o, "id", st.node_id);
    json::set(o, "epoch", static_cast<int64_t>(st.epoch));
    json::set(o, "hb", static_cast<int64_t>(self.info.hb_seq));
    json::set(o, "hlc", self.info.hb_hlc);
  }

  void checkLiveness() {
    const int64_t t = now();
    bool changed = false;
    bool leader_dirty = false;
    for (auto& kv : peers) {
      Peer& p = kv.second;
      if (p.info.id == st.node_id) continue;
      const int64_t idle = t - p.last_adv_mono;
      std::string ns = idle >= st.dead_ms ? "dead" : (idle >= st.suspect_ms ? "suspect" : "alive");
      if (ns == p.info.status) continue;
      const bool was_dead = p.info.status == "dead";
      p.info.status = ns;
      changed = true;
      if (ns == "dead") {
        leader_dirty = true;
        if (cbs.on_peer_alive_changed) cbs.on_peer_alive_changed(p.info.id, false);
      } else if (was_dead) {
        leader_dirty = true;
        if (cbs.on_peer_alive_changed) cbs.on_peer_alive_changed(p.info.id, true);
      }
    }
    if (changed && cbs.on_peers_changed) cbs.on_peers_changed();
    if (leader_dirty) leaderTick();
  }

  // hb 前進の観測 (PING/PONG/PEERS 共通)。前進したら true。
  bool observeHb(const std::string& id, uint64_t epoch, uint64_t hb, const std::string& hb_hlc) {
    if (id.empty() || id == st.node_id) return false;
    if (!hb_hlc.empty()) hlc.observe(hb_hlc);
    Peer& p = peers[id];
    const bool fresh = p.info.id.empty();
    if (fresh) {
      p.info.id = id;
      p.info.status = "alive";
    }
    if (!fresh && std::tie(epoch, hb) <= std::tie(p.info.epoch, p.info.hb_seq)) return false;
    p.info.epoch = epoch;
    p.info.hb_seq = hb;
    p.info.hb_hlc = hb_hlc;
    p.last_adv_mono = now();
    if (p.info.status == "dead") {  // epoch 増加 (再起動) 含め、前進が見えたら即復活
      p.info.status = "alive";
      if (cbs.on_peer_alive_changed) cbs.on_peer_alive_changed(id, true);
      if (cbs.on_peers_changed) cbs.on_peers_changed();
      leaderTick();
    } else if (p.info.status == "suspect") {
      p.info.status = "alive";
      if (cbs.on_peers_changed) cbs.on_peers_changed();
    } else if (fresh && cbs.on_peers_changed) {
      cbs.on_peers_changed();
    }
    return true;
  }

  // ------------------------------------------------------------------ PEERS gossip

  void sendPeersTo(SecureChannel& ch) {
    auto o = json::obj();
    json::set(o.get(), "t", "PEERS");
    cJSON* arr = json::addArr(o.get(), "peers");
    for (const auto& kv : peers) {
      const PeerInfo& p = kv.second.info;
      cJSON* e = json::pushObj(arr);
      json::set(e, "id", p.id);
      cJSON* addrs = json::addArr(e, "addrs");
      for (const auto& a : p.addrs) json::push(addrs, json::Doc(cJSON_CreateString(a.c_str())));
      json::set(e, "epoch", static_cast<int64_t>(p.epoch));
      json::set(e, "hb", static_cast<int64_t>(p.hb_seq));
      json::set(e, "hlc", p.hb_hlc);
      json::set(e, "status", p.status);
      json::set(e, "caps", p.caps_json);
      json::set(e, "role", p.role);
      json::set(e, "sw", p.sw_version);
    }
    ch.sendMessage(json::dump(o.get()));
  }

  void gossipAll() {
    for (auto& kv : chans) sendPeersTo(*kv.second);
  }

  void handlePeers(const cJSON* doc) {
    const cJSON* arr = json::get(doc, "peers");
    const cJSON* e = nullptr;
    bool leader_dirty = false;
    bool new_node = false;
    cJSON_ArrayForEach(e, arr) {
      const std::string id = json::getString(e, "id");
      if (id.empty() || id == st.node_id) continue;  // 自分の情報は自分が正
      const bool fresh = peers.find(id) == peers.end();
      const bool advanced = observeHb(id, static_cast<uint64_t>(json::getInt(e, "epoch")),
                                      static_cast<uint64_t>(json::getInt(e, "hb")),
                                      json::getString(e, "hlc"));
      Peer& p = peers[id];
      if (fresh || advanced) {  // epoch/hb_seq の max 合成 — 古い情報では巻き戻らない
        std::vector<std::string> addrs;
        const cJSON* a = nullptr;
        cJSON_ArrayForEach(a, json::get(e, "addrs")) {
          if (cJSON_IsString(a)) addrs.push_back(a->valuestring);
        }
        if (!addrs.empty()) p.info.addrs = addrs;
        for (const auto& ad : p.info.addrs) rememberAddr(ad, id);
        const std::string caps = json::getString(e, "caps");
        if (!caps.empty() && caps != p.info.caps_json) {
          p.info.caps_json = caps;
          leader_dirty = true;
        }
        p.info.role = json::getString(e, "role", p.info.role);
        p.info.sw_version = json::getString(e, "sw", p.info.sw_version);
      }
      if (fresh) new_node = true;
    }
    if (leader_dirty) leaderTick();
    if (new_node) {
      postGuarded([this] {
        if (running) maintain();
      });
    }
  }

  // ------------------------------------------------------------------ 選主

  static bool capsEligible(const cJSON* caps, const std::string& duty) {
    if (duty == "telegram") {
      return json::getBool(caps, "tls12") && json::getBool(caps, "wan") &&
             json::getBool(caps, "mains_power") && json::getBool(caps, "wall_clock_sane", true);
    }
    if (duty == "mqtt_bridge") {
      return json::getBool(caps, "mqtt_reachable") && json::getBool(caps, "mains_power");
    }
    return false;
  }

  int64_t rankOf(const std::string& id) const {
    auto it = peers.find(id);
    if (it == peers.end()) return 0;
    json::Doc caps = json::parse(it->second.info.caps_json);
    return caps ? json::getInt(caps.get(), "cpu_score") : 0;  // rank = cpu_score (欠損 0)
  }

  bool notDead(const std::string& id) const {
    if (id == st.node_id) return true;
    auto it = peers.find(id);
    return it != peers.end() && it->second.info.status != "dead";
  }

  // duty の確定的勝者 = eligible な生存ノードのうち (rank, node_id) 最大
  std::string computeLeader(const std::string& duty) const {
    std::string best;
    int64_t best_rank = 0;
    for (const auto& kv : peers) {
      const Peer& p = kv.second;
      if (p.info.id != st.node_id && p.info.status == "dead") continue;
      json::Doc caps = json::parse(p.info.caps_json);
      if (!caps || !capsEligible(caps.get(), duty)) continue;
      const int64_t r = json::getInt(caps.get(), "cpu_score");
      if (best.empty() || std::tie(r, p.info.id) > std::tie(best_rank, best)) {
        best = p.info.id;
        best_rank = r;
      }
    }
    return best;
  }

  void setLeader(const std::string& duty, const std::string& id) {
    DutyState& d = duties[duty];
    if (d.leader == id) return;
    d.leader = id;
    if (cbs.on_leader_changed) cbs.on_leader_changed(duty, id);
  }

  void leaderTick() {
    for (const char* duty : kDuties) {
      DutyState& d = duties[duty];
      const std::string w = computeLeader(duty);
      if (w == st.node_id && !w.empty()) {
        // 自分が leader だと信じる → claim_ttl/3 周期の CLAIM 広播 (lease 更新)
        if (d.leader != w) d.term++;
        setLeader(duty, w);
        d.last_claim_mono = now();
        broadcastClaim(duty);
      } else {
        const bool lease_ok = !d.leader.empty() && notDead(d.leader) &&
                              (now() - d.last_claim_mono) < st.claim_ttl_ms;
        if (!lease_ok) setLeader(duty, w);  // lease 切れ → 再計算に追随
      }
    }
  }

  void broadcastClaim(const std::string& duty) {
    const DutyState& d = duties[duty];
    auto o = json::obj();
    json::set(o.get(), "t", "CLAIM");
    json::set(o.get(), "duty", duty);
    json::set(o.get(), "leader", st.node_id);
    json::set(o.get(), "term", static_cast<int64_t>(d.term));
    json::set(o.get(), "rank", rankOf(st.node_id));
    broadcast(json::dump(o.get()));
  }

  void handleClaim(const cJSON* doc) {
    const std::string duty = json::getString(doc, "duty");
    const std::string leader = json::getString(doc, "leader");
    const int64_t rank = json::getInt(doc, "rank");
    const uint64_t term = static_cast<uint64_t>(json::getInt(doc, "term"));
    if (duty.empty() || leader.empty()) return;
    DutyState& d = duties[duty];
    if (leader == d.leader) {  // 現 leader の lease 更新
      d.last_claim_mono = now();
      d.term = std::max(d.term, term);
      return;
    }
    if (!notDead(leader)) return;
    const bool lease_expired = d.leader.empty() || !notDead(d.leader) ||
                               (now() - d.last_claim_mono) >= st.claim_ttl_ms;
    // より高い (rank, id) の CLAIM で追随。lease 切れなら無条件に受ける。
    if (lease_expired ||
        std::make_tuple(rank, leader) > std::make_tuple(rankOf(d.leader), d.leader)) {
      setLeader(duty, leader);
      d.term = std::max(d.term, term);
      d.last_claim_mono = now();
    }
  }

  // ------------------------------------------------------------------ 同期

  void syncTick() {
    if (chans.empty()) return;
    std::vector<std::string> ids;
    ids.reserve(chans.size());
    for (const auto& kv : chans) ids.push_back(kv.first);
    // 決定的な round-robin (テスト再現性のため乱数を使わない)
    const std::string& pick = ids[sync_rr++ % ids.size()];
    sendSyncReq(*chans[pick]);
  }

  void sendSyncReq(SecureChannel& ch) {
    auto o = json::obj();
    json::set(o.get(), "t", "SYNC_REQ");
    mapToJson(json::addObj(o.get(), "vv"), config.versionVector());
    mapToJson(json::addObj(o.get(), "heads"), events.heads());
    ch.sendMessage(json::dump(o.get()));
  }

  // 相手の vv/heads に対する差分を SYNC_RESP に詰める
  json::Doc buildSyncResp(const cJSON* remote, bool fin) {
    auto o = json::obj();
    json::set(o.get(), "t", "SYNC_RESP");
    json::setBool(o.get(), "fin", fin);
    if (!fin) {  // 受けた側は差分を返しつつ自分の vv/heads も伝える (push-pull)
      mapToJson(json::addObj(o.get(), "vv"), config.versionVector());
      mapToJson(json::addObj(o.get(), "heads"), events.heads());
    }
    cJSON* cfg = json::addArr(o.get(), "cfg");
    VersionVector rvv;
    std::map<std::string, uint64_t> rheads;
    if (remote) {
      rvv = mapFromJson(json::get(remote, "vv"));
      rheads = mapFromJson(json::get(remote, "heads"));
    }
    for (const auto& e : config.deltaSince(rvv)) json::push(cfg, entryToJson(e));
    cJSON* ev = json::addArr(o.get(), "ev");
    for (const auto& r : events.deltaSince(rheads, kSyncEventLimit)) {
      json::push(ev, eventToJson(r));
    }
    return o;
  }

  void applySyncPayload(const cJSON* doc) {
    const cJSON* e = nullptr;
    cJSON_ArrayForEach(e, json::get(doc, "cfg")) { config.applyRemote(entryFromJson(e)); }
    cJSON_ArrayForEach(e, json::get(doc, "ev")) {
      EventRecord rec = eventFromJson(e);
      if (rec.origin.empty() || rec.seq == 0) continue;
      if (events.applyRemote(rec)) {
        if (cbs.on_event) cbs.on_event(rec);
      } else if (!rec.notify_json.empty()) {
        events.mergeNotify(rec.origin, rec.seq, rec.notify_json);  // 通知回執の LWW マージ
      }
    }
  }

  void handleSyncReq(SecureChannel& ch, const cJSON* doc) {
    auto resp = buildSyncResp(doc, /*fin=*/false);
    ch.sendMessage(json::dump(resp.get()));
  }

  void handleSyncResp(SecureChannel& ch, const cJSON* doc) {
    applySyncPayload(doc);
    if (!json::getBool(doc, "fin", true) && json::get(doc, "vv")) {
      auto resp = buildSyncResp(doc, /*fin=*/true);  // pull の返し (3 往復目で完結)
      ch.sendMessage(json::dump(resp.get()));
    }
  }

  // ------------------------------------------------------------------ EVENT / CMD

  void broadcastEvent(const EventRecord& ev) {
    auto o = json::obj();
    json::set(o.get(), "t", "EVENT");
    json::set(o.get(), "ttl", int64_t{kEventTtl});
    json::setItem(o.get(), "ev", eventToJson(ev));
    broadcast(json::dump(o.get()));
  }

  void handleEvent(SecureChannel& src, const cJSON* doc) {
    const cJSON* eo = json::get(doc, "ev");
    if (!eo) return;
    EventRecord rec = eventFromJson(eo);
    if (rec.origin.empty() || rec.seq == 0) return;
    if (!events.applyRemote(rec)) {
      if (!rec.notify_json.empty()) events.mergeNotify(rec.origin, rec.seq, rec.notify_json);
      return;  // 既知 → 転送もしない (flood 抑制)
    }
    if (cbs.on_event) cbs.on_event(rec);
    const int64_t ttl = json::getInt(doc, "ttl", 1);
    if (ttl > 1) {  // 自分の接続先へ転送 (発信元は除く)
      auto o = json::obj();
      json::set(o.get(), "t", "EVENT");
      json::set(o.get(), "ttl", ttl - 1);
      json::setItem(o.get(), "ev", eventToJson(rec));
      const std::string msg = json::dump(o.get());
      for (auto& kv : chans) {
        if (kv.second.get() != &src) kv.second->sendMessage(msg);
      }
    }
  }

  void pushConfigDelta(const std::vector<LwwEntry>& entries) {
    if (entries.empty() || chans.empty()) return;
    auto o = json::obj();
    json::set(o.get(), "t", "SYNC_RESP");
    json::setBool(o.get(), "fin", true);
    cJSON* cfg = json::addArr(o.get(), "cfg");
    for (const auto& e : entries) json::push(cfg, entryToJson(e));
    json::addArr(o.get(), "ev");
    broadcast(json::dump(o.get()));
  }

  json::Doc makeCmdMsg(const std::string& cmd_json) {
    auto o = json::obj();
    json::set(o.get(), "t", "CMD");
    json::set(o.get(), "from", st.node_id);
    json::set(o.get(), "cmd", cmd_json);
    return o;
  }

  void sendCommand(const std::string& node_id, const std::string& cmd_json) {
    auto it = chans.find(node_id);
    if (it == chans.end()) {
      DB_LOGW("mesh", "sendCommand: no direct channel to " + node_id);
      return;
    }
    auto o = makeCmdMsg(cmd_json);
    it->second->sendMessage(json::dump(o.get()));
  }

  void broadcastCommand(const std::string& cmd_json) {
    auto o = makeCmdMsg(cmd_json);
    broadcast(json::dump(o.get()));
  }

  void broadcast(const std::string& msg) {
    for (auto& kv : chans) kv.second->sendMessage(msg);
  }

  // ------------------------------------------------------------------ 快照

  void fetchSnapshot(const std::string& node_id, std::function<void(Bytes)> cb) {
    if (node_id == st.node_id) {  // 自分の快照は provider を直接
      Bytes jpeg = snap_provider ? snap_provider() : Bytes();
      if (jpeg.size() > kSnapMaxBytes) jpeg.clear();
      loop.post([cb, jpeg] { cb(jpeg); });
      return;
    }
    auto it = chans.find(node_id);
    if (it == chans.end()) {  // 直連チャネル無し (MVP: 中継しない) → 即失敗
      DB_LOGW("mesh", "fetchSnapshot: no direct channel to " + node_id.substr(0, 8));
      loop.post([cb] { cb(Bytes()); });
      return;
    }
    const uint64_t rid = ++snap_rid;
    SnapWait& w = snap_waits[rid];
    w.cb = std::move(cb);
    std::weak_ptr<char> wa = alive;
    w.timeout_id = loop.postDelayed(kSnapTimeoutMs, [this, wa, rid] {
      if (wa.expired()) return;
      auto sit = snap_waits.find(rid);
      if (sit == snap_waits.end()) return;
      auto done = std::move(sit->second.cb);
      snap_waits.erase(sit);
      if (done) done(Bytes());
    });
    auto o = json::obj();
    json::set(o.get(), "t", "SNAP_REQ");
    json::set(o.get(), "rid", static_cast<int64_t>(rid));
    it->second->sendMessage(json::dump(o.get()));
  }

  void handleSnapReq(SecureChannel& ch, const cJSON* doc) {
    const int64_t rid = json::getInt(doc, "rid");
    Bytes jpeg = snap_provider ? snap_provider() : Bytes();
    if (jpeg.size() > kSnapMaxBytes) jpeg.clear();  // 上限超は失敗扱い (空応答)
    auto o = json::obj();
    json::set(o.get(), "t", "SNAP_RESP");
    json::set(o.get(), "rid", rid);
    json::set(o.get(), "jpeg", base64Encode(jpeg));  // 空 = 提供不可
    ch.sendMessage(json::dump(o.get()));
  }

  void handleSnapResp(const cJSON* doc) {
    const uint64_t rid = static_cast<uint64_t>(json::getInt(doc, "rid"));
    auto it = snap_waits.find(rid);
    if (it == snap_waits.end()) return;  // タイムアウト済み/未知
    loop.cancel(it->second.timeout_id);
    auto done = std::move(it->second.cb);
    snap_waits.erase(it);
    Bytes jpeg;
    base64Decode(json::getString(doc, "jpeg"), jpeg);
    if (done) done(std::move(jpeg));
  }

  // ------------------------------------------------------------------ メッセージ分配

  void handleMessage(const std::shared_ptr<SecureChannel>& ch, const std::string& msg) {
    if (!running) return;
    json::Doc doc = json::parse(msg);
    if (!doc) {
      DB_LOGW("mesh", "bad message from " + ch->peerId());
      return;
    }
    const std::string t = json::getString(doc.get(), "t");
    if (t == "PEERS") {
      handlePeers(doc.get());
    } else if (t == "PING" || t == "PONG") {
      observeHb(json::getString(doc.get(), "id"),
                static_cast<uint64_t>(json::getInt(doc.get(), "epoch")),
                static_cast<uint64_t>(json::getInt(doc.get(), "hb")),
                json::getString(doc.get(), "hlc"));
      if (t == "PING") {
        auto o = json::obj();
        json::set(o.get(), "t", "PONG");
        fillHb(o.get());
        ch->sendMessage(json::dump(o.get()));
      }
    } else if (t == "SYNC_REQ") {
      handleSyncReq(*ch, doc.get());
    } else if (t == "SYNC_RESP") {
      handleSyncResp(*ch, doc.get());
    } else if (t == "CLAIM") {
      handleClaim(doc.get());
    } else if (t == "EVENT") {
      handleEvent(*ch, doc.get());
    } else if (t == "SNAP_REQ") {
      handleSnapReq(*ch, doc.get());
    } else if (t == "SNAP_RESP") {
      handleSnapResp(doc.get());
    } else if (t == "CMD") {
      if (cbs.on_command) {
        cbs.on_command(json::getString(doc.get(), "from"), json::getString(doc.get(), "cmd"));
      }
    }  // 未知の型は無視 (前方互換)
  }

  // ------------------------------------------------------------------ 配対 host

  void sendJoinErr(const ConnPtr& conn, const std::string& err) {
    auto o = json::obj();
    json::set(o.get(), "t", "JOIN_ERR");
    json::set(o.get(), "err", err);
    sendJoinFrame(conn, o.get());
  }

  void handleJoinHostFrame(const std::shared_ptr<Inbound>& ib, const Bytes& f) {
    json::Doc doc = json::parse(std::string(f.begin() + 1, f.end()));
    if (!doc) return;
    const std::string t = json::getString(doc.get(), "t");
    if (t == "JOIN_REQ1") {
      if (!token.active) {
        sendJoinErr(ib->conn, "no_token");
        return;
      }
      if (now() >= token.expires_mono) {  // 期限切れ (10 分)
        token.active = false;
        sendJoinErr(ib->conn, "expired");
        return;
      }
      ib->challenge = randomBytes(32);
      ib->salt = randomBytes(16);
      ib->challenged = true;
      auto o = json::obj();
      json::set(o.get(), "t", "JOIN_CHALLENGE");
      json::set(o.get(), "challenge", hexEncode(ib->challenge));
      json::set(o.get(), "salt", hexEncode(ib->salt));
      sendJoinFrame(ib->conn, o.get());
    } else if (t == "JOIN_PROOF") {
      if (!ib->challenged || !token.active || now() >= token.expires_mono) {
        sendJoinErr(ib->conn, "no_token");
        return;
      }
      const std::string joiner_id = json::getString(doc.get(), "id");
      Bytes mac;
      if (!hexDecode(json::getString(doc.get(), "hmac"), mac) || mac.size() != 32) {
        sendJoinErr(ib->conn, "bad_pin");
        return;
      }
      const auto k = joinKey(token.pin, ib->salt);
      const auto expect = joinProof(k, ib->challenge, joiner_id);
      if (crypto_verify32(mac.data(), expect.data()) != 0) {
        if (++token.fails >= 3) token.active = false;  // 3 回失敗で token 失効
        sendJoinErr(ib->conn, "bad_pin");
        return;
      }
      // 検証 OK → K で暗号化した {psk, seeds, 設定スナップショット} を配布
      auto payload = json::obj();
      json::set(payload.get(), "psk", hexEncode(st.psk.data(), st.psk.size()));
      json::set(payload.get(), "psk_id", st.psk_id);
      cJSON* seeds = json::addArr(payload.get(), "seeds");
      std::set<std::string> seen;
      auto addSeed = [&](const std::string& a) {
        if (!a.empty() && seen.insert(a).second) {
          json::push(seeds, json::Doc(cJSON_CreateString(a.c_str())));
        }
      };
      addSeed(st.advertise_addr);
      for (const auto& a : st.seed_peers) addSeed(a);
      cJSON* cfg = json::addArr(payload.get(), "cfg");
      for (const auto& e : config.all()) json::push(cfg, entryToJson(e));
      const std::string plain = json::dump(payload.get());
      Bytes nonce = randomBytes(24);
      Bytes out(16 + plain.size());  // mac(16) || cipher
      crypto_aead_lock(out.data() + 16, out.data(), k.data(), nonce.data(), nullptr, 0,
                       reinterpret_cast<const uint8_t*>(plain.data()), plain.size());
      auto o = json::obj();
      json::set(o.get(), "t", "JOIN_OK");
      json::set(o.get(), "n", hexEncode(nonce));
      json::set(o.get(), "c", hexEncode(out));
      sendJoinFrame(ib->conn, o.get());
      token.active = false;  // 成功で消費
    }
  }

  // ------------------------------------------------------------------ 配対 joiner

  // j は値渡し: 呼び出し元の閉包が実行中に破棄されても安全に使い切る
  void finishJoin(std::shared_ptr<JoinRun> j, bool ok, const std::string& err) {
    if (j->finished) return;
    j->finished = true;
    if (j->timeout_id) {
      loop.cancel(j->timeout_id);
      j->timeout_id = 0;
    }
    if (j->conn) {
      j->conn->setCallbacks([](const Bytes&) {}, [] {});
      j->conn->close();
    }
    if (join == j) join.reset();
    auto done = j->done;
    loop.post([done, ok, err] {
      if (done) done(ok, err);
    });
    if (ok) {
      postGuarded([this] {
        if (running) maintain();  // 正規接続へ移行
      });
    }
  }

  void abortJoin(const std::string& err) {
    if (join) finishJoin(join, false, err);
  }

  void joinCluster(const std::string& host_addr, const std::string& pin,
                   std::function<void(bool, const std::string&)> done) {
    if (join) {
      loop.post([done] { done(false, "join_in_progress"); });
      return;
    }
    auto j = std::make_shared<JoinRun>();
    j->pin = pin;
    j->done = std::move(done);
    join = j;
    std::weak_ptr<char> wt = alive;
    j->timeout_id = loop.postDelayed(st.claim_ttl_ms, [this, wt, j] {
      if (wt.expired()) return;
      j->timeout_id = 0;
      finishJoin(j, false, "timeout");
    });
    std::weak_ptr<char> w = alive;
    tp.connect(host_addr, [this, w, j, host_addr](ConnPtr conn) {
      if (w.expired()) {
        if (conn) conn->close();
        return;
      }
      if (j->finished) {
        if (conn) conn->close();
        return;
      }
      if (!conn) {
        finishJoin(j, false, "connect_failed");
        return;
      }
      j->conn = conn;
      rememberAddr(host_addr, "");
      conn->setCallbacks(
          [this, w, j](const Bytes& f) {
            if (!w.expired()) handleJoinClientFrame(j, f);
          },
          [this, w, j] {
            if (!w.expired()) finishJoin(j, false, "closed");
          });
      auto o = json::obj();
      json::set(o.get(), "t", "JOIN_REQ1");
      json::set(o.get(), "id", st.node_id);
      sendJoinFrame(conn, o.get());
    });
  }

  void handleJoinClientFrame(std::shared_ptr<JoinRun> j, const Bytes& f) {
    if (j->finished || f.empty() || f[0] != kFrameJoin) return;
    json::Doc doc = json::parse(std::string(f.begin() + 1, f.end()));
    if (!doc) return;
    const std::string t = json::getString(doc.get(), "t");
    if (t == "JOIN_CHALLENGE") {
      Bytes challenge, salt;
      if (!hexDecode(json::getString(doc.get(), "challenge"), challenge) ||
          !hexDecode(json::getString(doc.get(), "salt"), salt)) {
        finishJoin(j, false, "bad_challenge");
        return;
      }
      j->k = joinKey(j->pin, salt);
      j->key_ready = true;
      const auto proof = joinProof(j->k, challenge, st.node_id);
      auto o = json::obj();
      json::set(o.get(), "t", "JOIN_PROOF");
      json::set(o.get(), "id", st.node_id);
      json::set(o.get(), "hmac", hexEncode(proof.data(), proof.size()));
      sendJoinFrame(j->conn, o.get());
    } else if (t == "JOIN_OK") {
      Bytes nonce, enc;
      if (!j->key_ready || !hexDecode(json::getString(doc.get(), "n"), nonce) ||
          !hexDecode(json::getString(doc.get(), "c"), enc) || nonce.size() != 24 ||
          enc.size() < 16) {
        finishJoin(j, false, "bad_payload");
        return;
      }
      Bytes plain(enc.size() - 16);
      if (crypto_aead_unlock(plain.data(), enc.data(), j->k.data(), nonce.data(), nullptr, 0,
                             enc.data() + 16, plain.size()) != 0) {
        finishJoin(j, false, "decrypt_failed");
        return;
      }
      json::Doc payload = json::parse(std::string(plain.begin(), plain.end()));
      if (!payload) {
        finishJoin(j, false, "bad_payload");
        return;
      }
      Bytes psk;
      if (!hexDecode(json::getString(payload.get(), "psk"), psk) || psk.size() != 32) {
        finishJoin(j, false, "bad_payload");
        return;
      }
      std::copy(psk.begin(), psk.end(), st.psk.begin());
      st.psk_id = json::getString(payload.get(), "psk_id", st.psk_id);
      const cJSON* a = nullptr;
      cJSON_ArrayForEach(a, json::get(payload.get(), "seeds")) {
        if (!cJSON_IsString(a)) continue;
        const std::string addr = a->valuestring;
        if (isSelfAddr(addr)) continue;
        if (std::find(st.seed_peers.begin(), st.seed_peers.end(), addr) == st.seed_peers.end()) {
          st.seed_peers.push_back(addr);
        }
        rememberAddr(addr, "");
      }
      const cJSON* e = nullptr;
      cJSON_ArrayForEach(e, json::get(payload.get(), "cfg")) {
        config.applyRemote(entryFromJson(e));  // 設定スナップショットの適用
      }
      finishJoin(j, true, "");
    } else if (t == "JOIN_ERR") {
      finishJoin(j, false, json::getString(doc.get(), "err", "error"));
    }
  }
};

// ============================================================================ 公開 API

Mesh::Mesh(Runloop& loop, IClock& clock, HlcClock& hlc, ITransport& transport,
           IDiscovery* discovery, Store& store, LwwMap& config, EventLog& events,
           MeshSettings settings, Callbacks cbs)
    : settings_(std::move(settings)),
      impl_(new Impl(loop, clock, hlc, transport, discovery, store, config, events, settings_,
                     std::move(cbs))) {}

Mesh::~Mesh() { impl_->stop(); }

void Mesh::start() { impl_->start(); }
void Mesh::stop() { impl_->stop(); }

std::vector<PeerInfo> Mesh::peers() const {
  std::vector<PeerInfo> out;
  out.reserve(impl_->peers.size());
  for (const auto& kv : impl_->peers) out.push_back(kv.second.info);
  return out;
}

std::string Mesh::leaderFor(const std::string& duty) const {
  auto it = impl_->duties.find(duty);
  return it == impl_->duties.end() ? "" : it->second.leader;
}

bool Mesh::isLeader(const std::string& duty) const { return leaderFor(duty) == settings_.node_id; }

void Mesh::setCaps(const std::string& caps_json) {
  settings_.caps_json = caps_json;
  auto it = impl_->peers.find(settings_.node_id);
  if (it != impl_->peers.end()) it->second.info.caps_json = caps_json;
  if (impl_->running) {
    impl_->gossipAll();   // 変化を即 gossip
    impl_->leaderTick();  // 再選主
  }
}

void Mesh::broadcastEvent(const EventRecord& ev) { impl_->broadcastEvent(ev); }

void Mesh::pushConfigDelta(const std::vector<LwwEntry>& entries) {
  impl_->pushConfigDelta(entries);
}

void Mesh::sendCommand(const std::string& node_id, const std::string& cmd_json) {
  impl_->sendCommand(node_id, cmd_json);
}

void Mesh::broadcastCommand(const std::string& cmd_json) { impl_->broadcastCommand(cmd_json); }

void Mesh::setSnapshotProvider(std::function<Bytes()> provider) {
  impl_->snap_provider = std::move(provider);
}

void Mesh::fetchSnapshot(const std::string& node_id, std::function<void(Bytes)> cb) {
  impl_->fetchSnapshot(node_id, std::move(cb));
}

Mesh::JoinToken Mesh::createJoinToken() {
  impl_->token.pin = genPin6();
  impl_->token.expires_mono = impl_->now() + kJoinTokenTtlMs;
  impl_->token.fails = 0;
  impl_->token.active = true;
  JoinToken t;
  t.pin = impl_->token.pin;
  t.expires_mono = impl_->token.expires_mono;
  return t;
}

void Mesh::joinCluster(const std::string& host_addr, const std::string& pin,
                       std::function<void(bool, const std::string&)> done) {
  impl_->joinCluster(host_addr, pin, std::move(done));
}

}  // namespace db
