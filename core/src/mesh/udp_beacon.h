// UDP multicast beacon discovery (239.255.71.71:47171)。
// HELLO パケット: JSON {"v":1,"id":node_id,"addr":advertise_addr,"mac":hex}
//   mac = BLAKE2b-256(key=psk, "beacon"||id||addr) の先頭 16B hex — 他クラスタの HELLO は無視。
// 送信は Runloop タイマー、受信は専用スレッド (on_found は Runloop に post)。
#pragma once

#include <array>
#include <atomic>
#include <memory>
#include <string>
#include <thread>

#include "mesh/socket_compat.h"
#include "mesh/transport.h"
#include "util/runloop.h"

namespace db {

class UdpBeacon : public IDiscovery {
 public:
  UdpBeacon(Runloop& loop, const std::array<uint8_t, 32>& psk,
            const std::string& group = "239.255.71.71", uint16_t port = 47171,
            int64_t period_ms = 2000);
  ~UdpBeacon() override;

  void start(std::function<void(const DiscoveredPeer&)> on_found) override;
  void announce(const std::string& node_id, const std::string& addr) override;
  void stop() override;

  // 煙試験用の観測点 (CI ではループバック multicast が不安定なため送信可否のみ見る)
  int64_t sentCount() const { return sent_.load(); }
  int64_t sendErrorCount() const { return send_err_.load(); }

 private:
  void sendHello_();
  void recvLoop_();
  bool openSockets_();

  Runloop& loop_;
  // Winsock 参照 (POSIX では no-op のため maybe_unused)。ソケットより先に構築される
  [[maybe_unused]] net::Init winsock_;
  std::array<uint8_t, 32> psk_;
  std::string group_;
  uint16_t port_;
  int64_t period_ms_;

  std::function<void(const DiscoveredPeer&)> on_found_;
  std::string node_id_, adv_addr_;
  uint64_t timer_id_ = 0;
  net::socket_t send_fd_ = net::kInvalidSocket;
  net::socket_t recv_fd_ = net::kInvalidSocket;
  std::thread recv_thread_;
  std::atomic<bool> stopping_{false};
  std::atomic<int64_t> sent_{0};
  std::atomic<int64_t> send_err_{0};
};

}  // namespace db
