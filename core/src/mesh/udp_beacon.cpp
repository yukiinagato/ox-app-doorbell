// UDP multicast beacon の実装 (udp_beacon.h 参照)。
#include "mesh/udp_beacon.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cstring>

#include "monocypher.h"
#include "util/json.h"
#include "util/log.h"

namespace db {

namespace {

// mac = keyed BLAKE2b(psk, "beacon"||id||addr) の先頭 16B
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

}  // namespace

UdpBeacon::UdpBeacon(Runloop& loop, const std::array<uint8_t, 32>& psk, const std::string& group,
                     uint16_t port, int64_t period_ms)
    : loop_(loop), psk_(psk), group_(group), port_(port), period_ms_(period_ms) {}

UdpBeacon::~UdpBeacon() { stop(); }

bool UdpBeacon::openSockets_() {
  // 送信ソケット
  send_fd_ = ::socket(AF_INET, SOCK_DGRAM, 0);
  if (send_fd_ < 0) return false;
  unsigned char ttl = 1;  // 同一 L2 のみ
  ::setsockopt(send_fd_, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, sizeof(ttl));
  unsigned char loop_on = 1;  // 同一ホスト内テスト用
  ::setsockopt(send_fd_, IPPROTO_IP, IP_MULTICAST_LOOP, &loop_on, sizeof(loop_on));

  // 受信ソケット (ポート共有 + multicast join)
  recv_fd_ = ::socket(AF_INET, SOCK_DGRAM, 0);
  if (recv_fd_ < 0) {
    ::close(send_fd_);
    send_fd_ = -1;
    return false;
  }
  int yes = 1;
  ::setsockopt(recv_fd_, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
#ifdef SO_REUSEPORT
  ::setsockopt(recv_fd_, SOL_SOCKET, SO_REUSEPORT, &yes, sizeof(yes));
#endif
  sockaddr_in a{};
  a.sin_family = AF_INET;
  a.sin_port = htons(port_);
  a.sin_addr.s_addr = htonl(INADDR_ANY);
  if (::bind(recv_fd_, reinterpret_cast<sockaddr*>(&a), sizeof(a)) != 0) {
    DB_LOGW("beacon", "bind failed");
    ::close(recv_fd_);
    recv_fd_ = -1;
    // 送信専用でも続行 (受信できないだけ)
    return true;
  }
  ip_mreq mreq{};
  ::inet_pton(AF_INET, group_.c_str(), &mreq.imr_multiaddr);
  mreq.imr_interface.s_addr = htonl(INADDR_ANY);
  if (::setsockopt(recv_fd_, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, sizeof(mreq)) != 0) {
    DB_LOGW("beacon", "multicast join failed");
  }
  // recv タイムアウト (stop の応答性のため)
  timeval tv{0, 200 * 1000};
  ::setsockopt(recv_fd_, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  return true;
}

void UdpBeacon::start(std::function<void(const DiscoveredPeer&)> on_found) {
  if (send_fd_ < 0 && !openSockets_()) {
    DB_LOGE("beacon", "socket setup failed");
    return;
  }
  on_found_ = std::move(on_found);
  stopping_ = false;
  if (recv_fd_ >= 0 && !recv_thread_.joinable()) {
    recv_thread_ = std::thread([this]() { recvLoop_(); });
  }
}

void UdpBeacon::announce(const std::string& node_id, const std::string& addr) {
  node_id_ = node_id;
  adv_addr_ = addr;
  if (send_fd_ < 0 && !openSockets_()) return;
  if (timer_id_) return;  // 既に周期送信中
  sendHello_();
  timer_id_ = loop_.postEvery(period_ms_, [this]() { sendHello_(); });
}

void UdpBeacon::sendHello_() {
  auto o = json::obj();
  json::set(o.get(), "v", int64_t{1});
  json::set(o.get(), "id", node_id_);
  json::set(o.get(), "addr", adv_addr_);
  json::set(o.get(), "mac", beaconMac(psk_, node_id_, adv_addr_));
  const std::string pkt = json::dump(o.get());
  sockaddr_in dst{};
  dst.sin_family = AF_INET;
  dst.sin_port = htons(port_);
  ::inet_pton(AF_INET, group_.c_str(), &dst.sin_addr);
  ssize_t n = ::sendto(send_fd_, pkt.data(), pkt.size(), 0,
                       reinterpret_cast<sockaddr*>(&dst), sizeof(dst));
  if (n == static_cast<ssize_t>(pkt.size())) {
    sent_++;
  } else {
    send_err_++;
  }
}

void UdpBeacon::recvLoop_() {
  char buf[2048];
  while (!stopping_) {
    ssize_t n = ::recvfrom(recv_fd_, buf, sizeof(buf) - 1, 0, nullptr, nullptr);
    if (n <= 0) continue;  // タイムアウト/エラーはループ継続 (stopping_ で抜ける)
    buf[n] = '\0';
    json::Doc doc = json::parse(buf);
    if (!doc) continue;
    const std::string id = json::getString(doc.get(), "id");
    const std::string addr = json::getString(doc.get(), "addr");
    const std::string mac = json::getString(doc.get(), "mac");
    if (id.empty() || addr.empty()) continue;
    if (id == node_id_) continue;                       // 自分の HELLO
    if (mac != beaconMac(psk_, id, addr)) continue;     // 他クラスタ/改竄 → 無視
    DiscoveredPeer p{id, addr};
    auto cb = on_found_;
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
  if (send_fd_ >= 0) {
    ::close(send_fd_);
    send_fd_ = -1;
  }
  if (recv_fd_ >= 0) {
    ::close(recv_fd_);
    recv_fd_ = -1;
  }
}

}  // namespace db
