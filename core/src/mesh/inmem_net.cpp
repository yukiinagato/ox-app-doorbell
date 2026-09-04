




#include "mesh/mesh.h"

#include <algorithm>
#include <map>
#include <random>
#include <set>
#include <vector>

namespace db {

namespace {

constexpr int64_t kBeaconPeriodMs = 50;

class InMemConnEnd;


struct NetState {
  Runloop& loop;
  std::map<std::string, std::function<void(ConnPtr)>> listeners;   // listen addr → on_accept
  std::map<std::string, std::function<void(const DiscoveredPeer&)>> discoveries;  // addr → cb
  std::map<std::string, std::function<void(const PairBeacon&)>> pair_found;
  // Mirrors the UDP beacon MAC: a HELLO is delivered only between nodes that share a cluster key.
  std::map<std::string, std::array<uint8_t, 32>> disc_psk;
  std::set<std::string> killed;
  std::map<std::string, int> group;
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


class InMemConnEnd : public IConn, public std::enable_shared_from_this<InMemConnEnd> {
 public:
  InMemConnEnd(std::shared_ptr<NetState> net, std::string local, std::string remote)
      : net_(std::move(net)), local_(std::move(local)), remote_(std::move(remote)) {}

  void send(const Bytes& frame) override {
    if (!open_) return;
    if (!net_->reachable(local_, remote_)) return;
    if (net_->dropFrame()) return;
    std::weak_ptr<InMemConnEnd> wp = peer_;
    net_->loop.postDelayed(net_->delay_ms, [wp, frame]() {
      if (auto p = wp.lock()) {
        if (!p->open_) return;

        auto cb = p->on_frame_;
        if (cb) cb(frame);
      }
    });
  }

  void close() override {
    if (!open_) return;
    open_ = false;

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


  void faultClose() {
    if (!open_) return;
    open_ = false;
    auto self = shared_from_this();
    net_->loop.post([self]() {
      auto cb = self->on_close_;
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
    if (net_->listeners.count(addr)) return false;
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
      auto a = std::make_shared<InMemConnEnd>(net, from, addr);
      auto b = std::make_shared<InMemConnEnd>(net, addr, from);
      a->setPeer(b);
      b->setPeer(a);
      net->conns.push_back(a);
      net->conns.push_back(b);
      cb(a);

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
    if (timer_id_) return;
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
    auto kit = net_->disc_psk.find(addr_);
    if (kit != net_->disc_psk.end()) net_->disc_psk.erase(kit);
  }

  void setPairAnnounce(const PairAnnounce& announce) override { pair_ = announce; }

  void setPairFound(std::function<void(const PairBeacon&)> cb) override {
    net_->pair_found[addr_] = std::move(cb);
  }

  void setPsk(const std::array<uint8_t, 32>& psk) override {
    psk_ = psk;
    net_->disc_psk[addr_] = psk;
  }

 private:
  static bool usable(const std::array<uint8_t, 32>& psk) {
    for (uint8_t b : psk)
      if (b) return true;
    return false;
  }

  void broadcast_() {
    if (net_->killed.count(addr_)) return;
    if (pair_.on) {
      for (auto& kv : net_->pair_found) {
        if (kv.first == addr_ || !kv.second) continue;
        if (!net_->reachable(addr_, kv.first)) continue;
        if (net_->dropFrame()) continue;
        const auto addrs = pair_.addrs.empty() ? std::vector<std::string>{adv_addr_} : pair_.addrs;
        PairBeacon pb{node_id_, adv_addr_, addrs, pair_.name, pair_.role,
                      pair_.pk,  pair_.model, pair_.platform, pair_.sw};
        auto cb = kv.second;
        net_->loop.post([cb, pb]() { cb(pb); });
      }
      return;
    }
    // Only a keyed HELLO is discoverable, and only by a receiver holding the same key.
    if (!usable(psk_)) return;
    for (auto& kv : net_->discoveries) {
      if (kv.first == addr_ || !kv.second) continue;
      if (!net_->reachable(addr_, kv.first)) continue;
      auto peer_key = net_->disc_psk.find(kv.first);
      if (peer_key == net_->disc_psk.end() || peer_key->second != psk_) continue;
      if (net_->dropFrame()) continue;
      DiscoveredPeer p{node_id_, adv_addr_};
      auto cb = kv.second;
      net_->loop.post([cb, p]() { cb(p); });
    }
  }

  std::shared_ptr<NetState> net_;
  std::string addr_;
  std::string node_id_, adv_addr_;
  PairAnnounce pair_;
  std::array<uint8_t, 32> psk_{};
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
  impl_->net->killed.erase(addr);
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
  net.disc_psk.erase(addr);
  severIf(net, [&addr](const std::string& a, const std::string& b) { return a == addr || b == addr; });
}

}  // namespace db
