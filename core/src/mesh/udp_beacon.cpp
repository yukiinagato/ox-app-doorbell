
#include "mesh/udp_beacon.h"

#include <cstring>

#include "monocypher.h"
#include "util/json.h"
#include "util/log.h"

namespace db {

namespace {


std::string beaconMac(const std::array<uint8_t, 32>& psk, const std::string& id,
                      const std::string& addr) {
  static const uint8_t kTag[6] = {'b', 'e', 'a', 'c', 'o', 'n'};
  crypto_blake2b_ctx ctx;
  crypto_blake2b_keyed_init(&ctx, 32, psk.data(), psk.size());
  crypto_blake2b_update(&ctx, kTag, sizeof(kTag));
  crypto_blake2b_update(&ctx, reinterpret_cast<const uint8_t*>(id.data()), id.size());
  crypto_blake2b_update(&ctx, reinterpret_cast<const uint8_t*>(addr.data()), addr.size());
  uint8_t mac[32];
  crypto_blake2b_final(&ctx, mac);
  return hexEncode(mac, 16);
}

// An all-zero key means the node is unpaired. Such a node has no cluster to discover, and a MAC
// computed with it proves nothing, so zero-key HELLO packets are neither sent nor believed.
bool pskUsable(const std::array<uint8_t, 32>& psk) {
  for (uint8_t b : psk)
    if (b) return true;
  return false;
}

}  // namespace

UdpBeacon::UdpBeacon(Runloop& loop, const std::array<uint8_t, 32>& psk, const std::string& group,
                     uint16_t port, int64_t period_ms)
    : loop_(loop), psk_(psk), group_(group), port_(port), period_ms_(period_ms) {}

UdpBeacon::~UdpBeacon() { stop(); }

bool UdpBeacon::openSockets_() {

  send_fd_ = ::socket(AF_INET, SOCK_DGRAM, 0);
  if (!net::valid(send_fd_)) return false;
  net::setMulticastTtl(send_fd_, 1);
  net::setMulticastLoop(send_fd_, true);


  recv_fd_ = ::socket(AF_INET, SOCK_DGRAM, 0);
  if (!net::valid(recv_fd_)) {
    net::closeSocket(send_fd_);
    send_fd_ = net::kInvalidSocket;
    return false;
  }
  int yes = 1;

  net::setSockOpt(recv_fd_, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
#ifdef SO_REUSEPORT
  net::setSockOpt(recv_fd_, SOL_SOCKET, SO_REUSEPORT, &yes, sizeof(yes));
#endif
  sockaddr_in a{};
  a.sin_family = AF_INET;
  a.sin_port = htons(port_);
  a.sin_addr.s_addr = htonl(INADDR_ANY);
  if (::bind(recv_fd_, reinterpret_cast<sockaddr*>(&a), sizeof(a)) != 0) {
    DB_LOGW("beacon", "bind failed");
    net::closeSocket(recv_fd_);
    recv_fd_ = net::kInvalidSocket;

    return true;
  }
  ip_mreq mreq{};
  ::inet_pton(AF_INET, group_.c_str(), &mreq.imr_multiaddr);
  mreq.imr_interface.s_addr = htonl(INADDR_ANY);
  if (!net::setSockOpt(recv_fd_, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, sizeof(mreq))) {
    DB_LOGW("beacon", "multicast join failed");
  }

  net::setRecvTimeoutMs(recv_fd_, 200);
  return true;
}

void UdpBeacon::start(std::function<void(const DiscoveredPeer&)> on_found) {
  if (!net::valid(send_fd_) && !openSockets_()) {
    DB_LOGE("beacon", "socket setup failed");
    return;
  }
  {
    std::lock_guard<std::mutex> lk(mu_);
    on_found_ = std::move(on_found);
  }
  stopping_ = false;
  if (net::valid(recv_fd_) && !recv_thread_.joinable()) {
    recv_thread_ = std::thread([this]() { recvLoop_(); });
  }
}

void UdpBeacon::announce(const std::string& node_id, const std::string& addr) {
  {
    std::lock_guard<std::mutex> lk(mu_);
    node_id_ = node_id;
    adv_addr_ = addr;
  }
  if (!net::valid(send_fd_) && !openSockets_()) return;
  if (timer_id_) return;
  sendHello_();
  timer_id_ = loop_.postEvery(period_ms_, [this]() { sendHello_(); });
}

void UdpBeacon::setPairAnnounce(const PairAnnounce& announce) {
  {
    std::lock_guard<std::mutex> lk(mu_);
    pair_ = announce;
  }
  pair_on_.store(announce.on);
}

void UdpBeacon::setPairFound(std::function<void(const PairBeacon&)> cb) {
  std::lock_guard<std::mutex> lk(mu_);
  on_pair_found_ = std::move(cb);
}

void UdpBeacon::setPsk(const std::array<uint8_t, 32>& psk) {
  std::lock_guard<std::mutex> lk(mu_);
  psk_ = psk;
}

void UdpBeacon::sendHello_() {

  if (pair_on_.load()) {
    sendPairAnnounce_();
    return;
  }
  std::string node_id, adv_addr, mac;
  {
    std::lock_guard<std::mutex> lk(mu_);
    if (!pskUsable(psk_)) return;
    node_id = node_id_;
    adv_addr = adv_addr_;
    mac = beaconMac(psk_, node_id, adv_addr);
  }
  auto o = json::obj();
  json::set(o.get(), "v", int64_t{1});
  json::set(o.get(), "id", node_id);
  json::set(o.get(), "addr", adv_addr);
  json::set(o.get(), "mac", mac);
  const std::string pkt = json::dump(o.get());
  sockaddr_in dst{};
  dst.sin_family = AF_INET;
  dst.sin_port = htons(port_);
  ::inet_pton(AF_INET, group_.c_str(), &dst.sin_addr);
  int n = net::sendTo(send_fd_, pkt.data(), pkt.size(),
                      reinterpret_cast<sockaddr*>(&dst), sizeof(dst));
  if (n == static_cast<int>(pkt.size())) {
    sent_++;
  } else {
    send_err_++;
  }
}

void UdpBeacon::sendPairAnnounce_() {
  std::string node_id, adv_addr;
  PairAnnounce pair;
  {
    std::lock_guard<std::mutex> lk(mu_);
    node_id = node_id_;
    adv_addr = adv_addr_;
    pair = pair_;
  }
  auto o = json::obj();
  json::set(o.get(), "v", int64_t{1});
  json::set(o.get(), "pair", int64_t{1});
  json::set(o.get(), "id", node_id);
  json::set(o.get(), "addr", adv_addr);
  json::set(o.get(), "name", pair.name);
  json::set(o.get(), "role", pair.role);
  json::set(o.get(), "pk", pair.pk);
  json::set(o.get(), "model", pair.model);
  json::set(o.get(), "platform", pair.platform);
  json::set(o.get(), "sw", pair.sw);
  const std::string pkt = json::dump(o.get());
  sockaddr_in dst{};
  dst.sin_family = AF_INET;
  dst.sin_port = htons(port_);
  ::inet_pton(AF_INET, group_.c_str(), &dst.sin_addr);
  int n = net::sendTo(send_fd_, pkt.data(), pkt.size(), reinterpret_cast<sockaddr*>(&dst),
                      sizeof(dst));
  if (n == static_cast<int>(pkt.size())) {
    sent_++;
  } else {
    send_err_++;
  }
}

void UdpBeacon::recvLoop_() {
  char buf[2048];
  while (!stopping_) {
    int n = net::recvFrom(recv_fd_, buf, sizeof(buf) - 1);
    if (n <= 0) continue;
    buf[n] = '\0';
    json::Doc doc = json::parse(buf);
    if (!doc) continue;
    const std::string id = json::getString(doc.get(), "id");
    const std::string addr = json::getString(doc.get(), "addr");
    if (id.empty() || addr.empty()) continue;

    if (json::getInt(doc.get(), "pair", 0) == 1) {
      std::function<void(const PairBeacon&)> cb;
      {
        std::lock_guard<std::mutex> lk(mu_);
        if (id == node_id_) continue;
        cb = on_pair_found_;
      }
      if (cb) {
        PairBeacon pb{id, addr, json::getString(doc.get(), "name"),
                      json::getString(doc.get(), "role"), json::getString(doc.get(), "pk"),
                      json::getString(doc.get(), "model"),
                      json::getString(doc.get(), "platform"),
                      json::getString(doc.get(), "sw")};
        loop_.post([cb, pb]() { cb(pb); });
      }
      continue;
    }
    const std::string mac = json::getString(doc.get(), "mac");
    std::function<void(const DiscoveredPeer&)> cb;
    {
      std::lock_guard<std::mutex> lk(mu_);
      if (id == node_id_) continue;
      // A node that holds a real cluster key never accepts a HELLO MACed with the zero key.
      if (!pskUsable(psk_) || mac != beaconMac(psk_, id, addr)) continue;
      cb = on_found_;
    }
    DiscoveredPeer p{id, addr};
    if (cb) loop_.post([cb, p]() { cb(p); });
  }
}

void UdpBeacon::stop() {
  stopping_ = true;
  if (timer_id_) {
    loop_.cancel(timer_id_);
    timer_id_ = 0;
  }
  if (recv_thread_.joinable()) recv_thread_.join();
  if (net::valid(send_fd_)) {
    net::closeSocket(send_fd_);
    send_fd_ = net::kInvalidSocket;
  }
  if (net::valid(recv_fd_)) {
    net::closeSocket(recv_fd_);
    recv_fd_ = net::kInvalidSocket;
  }
}

}  // namespace db
