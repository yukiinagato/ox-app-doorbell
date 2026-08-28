// InMemNet: テスト/シミュレーション用のプロセス内ネットワーク (mesh.h 宣言)。
// 配送はすべて Runloop.post/postDelayed 経由 (決定的)。故障注入:
//  - partition(groups): 組間の配送遮断 + 既存接続の切断イベント
//  - setDrop(prob,seed): 決定的 PRNG によるフレーム落とし (beacon にも適用)
//  - killNode(addr):     全接続切断 + listen/beacon 停止 (再 makeTransport で復活)
#include "mesh/mesh.h"

#include <algorithm>
#include <map>
#include <random>
#include <set>
#include <vector>

namespace db {

namespace {

constexpr int64_t kBeaconPeriodMs = 50;  // InMem beacon の再告知周期 (テスト時間スケール)

class InMemConnEnd;

// ネットワーク全体の共有状態。conn/transport が InMemNet より長生きしても安全なよう shared_ptr。
struct NetState {
  Runloop& loop;
  std::map<std::string, std::function<void(ConnPtr)>> listeners;   // listen addr → on_accept
  std::map<std::string, std::function<void(const DiscoveredPeer&)>> discoveries;  // addr → cb
  std::map<std::string, std::function<void(const PairBeacon&)>> pair_found;  // addr → 配対発見 cb
  std::set<std::string> killed;
  std::map<std::string, int> group;  // partition (空 = 全通)
  double drop_prob = 0.0;
  std::mt19937 drop_rng{1};
  int64_t delay_ms = 0;
  std::vector<std::weak_ptr<InMemConnEnd>> conns;

  explicit NetState(Runloop& l) : loop(l) {}

  bool reachable(const std::string& a, const std::string& b) const {
    if (killed.count(a) || killed.count(b)) return false;
    if (group.empty()) return true;
    auto ga = group.find(a);
    auto gb = group.find(b);
    const int ia = ga == group.end() ? -1 : ga->second;
    const int ib = gb == group.end() ? -1 : gb->second;
    return ia == ib;
  }

  bool dropFrame() {
    if (drop_prob <= 0.0) return false;
    return std::uniform_real_distribution<double>(0.0, 1.0)(drop_rng) < drop_prob;
  }

  void gcConns() {
    conns.erase(std::remove_if(conns.begin(), conns.end(),
                               [](const std::weak_ptr<InMemConnEnd>& w) { return w.expired(); }),
                conns.end());
  }
};

// 接続の片端。send は相手端の on_frame へ Runloop 経由で配送。
class InMemConnEnd : public IConn, public std::enable_shared_from_this<InMemConnEnd> {
 public:
  InMemConnEnd(std::shared_ptr<NetState> net, std::string local, std::string remote)
      : net_(std::move(net)), local_(std::move(local)), remote_(std::move(remote)) {}

  void send(const Bytes& frame) override {
    if (!open_) return;
    if (!net_->reachable(local_, remote_)) return;  // 分断/死亡中は闇に消える
    if (net_->dropFrame()) return;                  // 決定的フレーム落とし
    std::weak_ptr<InMemConnEnd> wp = peer_;
    net_->loop.postDelayed(net_->delay_ms, [wp, frame]() {
      if (auto p = wp.lock()) {
        if (!p->open_) return;
        // コピーを呼ぶ: 実行中に setCallbacks で差し替えられても閉包が壊れない
        auto cb = p->on_frame_;
        if (cb) cb(frame);
      }
    });
  }

  void close() override {
    if (!open_) return;
    open_ = false;
    // 相手端には切断イベントを配送 (自端の on_close は呼ばない — 自発 close のため)
    std::weak_ptr<InMemConnEnd> wp = peer_;
    net_->loop.post([wp]() {
      if (auto p = wp.lock()) p->faultClose();
    });
  }

  std::string remoteAddr() const override { return remote_; }

  void setCallbacks(std::function<void(const Bytes&)> on_frame,
                    std::function<void()> on_close) override {
    on_frame_ = std::move(on_frame);
    on_close_ = std::move(on_close);
  }

  // 故障注入/相手切断による強制クローズ (on_close を発火)
  void faultClose() {
    if (!open_) return;
    open_ = false;
    auto self = shared_from_this();
    net_->loop.post([self]() {
      auto cb = self->on_close_;  // コピーを呼ぶ (差し替え耐性)
      if (cb) cb();
    });
  }

  const std::string& localAddr() const { return local_; }
  void setPeer(std::weak_ptr<InMemConnEnd> p) { peer_ = std::move(p); }

 private:
  std::shared_ptr<NetState> net_;
  std::string local_, remote_;
  std::weak_ptr<InMemConnEnd> peer_;
  bool open_ = true;
  std::function<void(const Bytes&)> on_frame_;
  std::function<void()> on_close_;
};

// addr を跨ぐ既存接続を切断 (pred(local, remote) が true の端を faultClose)
void severIf(NetState& net, const std::function<bool(const std::string&, const std::string&)>& pred) {
  net.gcConns();
  for (auto& w : net.conns) {
    if (auto c = w.lock()) {
      if (pred(c->localAddr(), c->remoteAddr())) c->faultClose();
    }
  }
}

class InMemTransport : public ITransport {
 public:
  InMemTransport(std::shared_ptr<NetState> net, std::string addr)
      : net_(std::move(net)), addr_(std::move(addr)) {}

  ~InMemTransport() override { stopListening(); }

  bool listen(const std::string& addr, std::function<void(ConnPtr)> on_accept) override {
    if (net_->listeners.count(addr)) return false;  // 二重 listen
    listen_addr_ = addr;
    net_->listeners[addr] = std::move(on_accept);
    return true;
  }

  void stopListening() override {
    if (listen_addr_.empty()) return;
    net_->listeners.erase(listen_addr_);
    listen_addr_.clear();
  }

  void connect(const std::string& addr, std::function<void(ConnPtr)> cb) override {
    auto net = net_;
    const std::string from = addr_;
    net_->loop.post([net, from, addr, cb]() {
      auto it = net->listeners.find(addr);
      if (it == net->listeners.end() || !net->reachable(from, addr)) {
        cb(nullptr);
        return;
      }
      auto a = std::make_shared<InMemConnEnd>(net, from, addr);   // 発起側
      auto b = std::make_shared<InMemConnEnd>(net, addr, from);   // 受理側
      a->setPeer(b);
      b->setPeer(a);
      net->conns.push_back(a);
      net->conns.push_back(b);
      cb(a);
      // cb 内で callbacks 設定済みになってから accept を渡す (同一 post 内で順に)
      it->second(b);
    });
  }

  std::string listenAddr() const override { return listen_addr_.empty() ? addr_ : listen_addr_; }

 private:
  std::shared_ptr<NetState> net_;
  std::string addr_;
  std::string listen_addr_;
};

class InMemDiscovery : public IDiscovery {
 public:
  InMemDiscovery(std::shared_ptr<NetState> net, std::string addr)
      : net_(std::move(net)), addr_(std::move(addr)) {}

  ~InMemDiscovery() override { stop(); }

  void start(std::function<void(const DiscoveredPeer&)> on_found) override {
    net_->discoveries[addr_] = std::move(on_found);
  }

  void announce(const std::string& node_id, const std::string& addr) override {
    node_id_ = node_id;
    adv_addr_ = addr;
    if (timer_id_) return;  // 既に周期告知中 (内容だけ更新)
    broadcast_();
    timer_id_ = net_->loop.postEvery(kBeaconPeriodMs, [this]() { broadcast_(); });
  }

  void stop() override {
    if (timer_id_) {
      net_->loop.cancel(timer_id_);
      timer_id_ = 0;
    }
    auto it = net_->discoveries.find(addr_);
    if (it != net_->discoveries.end()) net_->discoveries.erase(it);
    auto pit = net_->pair_found.find(addr_);
    if (pit != net_->pair_found.end()) net_->pair_found.erase(pit);
  }

  void setPairAnnounce(bool on, const std::string& name, const std::string& role,
                       const std::string& pk) override {
    pair_on_ = on;
    pair_name_ = name;
    pair_role_ = role;
    pair_pk_ = pk;
  }

  void setPairFound(std::function<void(const PairBeacon&)> cb) override {
    net_->pair_found[addr_] = std::move(cb);
  }

 private:
  void broadcast_() {
    if (net_->killed.count(addr_)) return;
    if (pair_on_) {  // 未配対 → PAIR-ANNOUNCE を撒く (集群 HELLO は出さない)
      for (auto& kv : net_->pair_found) {
        if (kv.first == addr_) continue;
        if (!net_->reachable(addr_, kv.first)) continue;
        if (net_->dropFrame()) continue;
        PairBeacon pb{node_id_, adv_addr_, pair_name_, pair_role_, pair_pk_};
        auto cb = kv.second;
        net_->loop.post([cb, pb]() { cb(pb); });
      }
      return;
    }
    for (auto& kv : net_->discoveries) {
      if (kv.first == addr_) continue;
      if (!net_->reachable(addr_, kv.first)) continue;
      if (net_->dropFrame()) continue;  // beacon も落ち得る (UDP 相当)
      DiscoveredPeer p{node_id_, adv_addr_};
      auto cb = kv.second;
      net_->loop.post([cb, p]() { cb(p); });
    }
  }

  std::shared_ptr<NetState> net_;
  std::string addr_;
  std::string node_id_, adv_addr_;
  bool pair_on_ = false;
  std::string pair_name_, pair_role_, pair_pk_;
  uint64_t timer_id_ = 0;
};

}  // namespace

struct InMemNet::Impl {
  std::shared_ptr<NetState> net;
  explicit Impl(Runloop& loop) : net(std::make_shared<NetState>(loop)) {}
};

InMemNet::InMemNet(Runloop& loop) : impl_(new Impl(loop)) {}
InMemNet::~InMemNet() = default;

std::unique_ptr<ITransport> InMemNet::makeTransport(const std::string& addr) {
  impl_->net->killed.erase(addr);  // kill からの復活
  return std::unique_ptr<ITransport>(new InMemTransport(impl_->net, addr));
}

std::unique_ptr<IDiscovery> InMemNet::makeDiscovery(const std::string& addr) {
  impl_->net->killed.erase(addr);
  return std::unique_ptr<IDiscovery>(new InMemDiscovery(impl_->net, addr));
}

void InMemNet::partition(const std::vector<std::vector<std::string>>& groups) {
  auto& net = *impl_->net;
  net.group.clear();
  for (size_t g = 0; g < groups.size(); g++) {
    for (const auto& addr : groups[g]) net.group[addr] = static_cast<int>(g);
  }
  severIf(net, [&net](const std::string& a, const std::string& b) { return !net.reachable(a, b); });
}

void InMemNet::heal() { impl_->net->group.clear(); }

void InMemNet::setDrop(double probability, uint32_t seed) {
  impl_->net->drop_prob = probability;
  impl_->net->drop_rng.seed(seed);
}

void InMemNet::setDelayMs(int64_t delay_ms) { impl_->net->delay_ms = delay_ms; }

void InMemNet::killNode(const std::string& addr) {
  auto& net = *impl_->net;
  net.killed.insert(addr);
  net.listeners.erase(addr);
  net.discoveries.erase(addr);
  net.pair_found.erase(addr);
  severIf(net, [&addr](const std::string& a, const std::string& b) { return a == addr || b == addr; });
}

}  // namespace db
