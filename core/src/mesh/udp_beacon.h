// UDP multicast discovery at 239.255.71.71:47171. Paired HELLO packets carry a timestamped keyed
// MAC; a receiver accepts only a MAC under the current (or previous) cluster key within +-120 s
// of its wall clock. The receiver thread posts discovery callbacks to Runloop.



#pragma once

#include <array>
#include <atomic>
#include <memory>
#include <mutex>
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

  void setPairAnnounce(const PairAnnounce& announce) override;
  void setPairFound(std::function<void(const PairBeacon&)> cb) override;
  void setPsk(const std::array<uint8_t, 32>& psk) override;
  void setPreviousPsk(const std::array<uint8_t, 32>& psk) override;
  // HELLO MAC over tag || id || addr || unix_ms, truncated to 16 bytes and hex encoded. Exposed
  // for tests; receivers accept a timestamp within kBeaconSkewMs of their wall clock.
  static std::string helloMac(const std::array<uint8_t, 32>& psk, const std::string& id,
                              const std::string& addr, int64_t unix_ms);
  static constexpr int64_t kBeaconSkewMs = 120 * 1000;


  int64_t sentCount() const { return sent_.load(); }
  int64_t sendErrorCount() const { return send_err_.load(); }

 private:
  void sendHello_();
  void sendPairAnnounce_();
  void sendMulticast_(const std::string& packet);
  void recvLoop_();
  bool openSockets_();

  Runloop& loop_;

  [[maybe_unused]] net::Init winsock_;
  // mu_ guards every field the receive thread also touches: the live PSK, the identity used to
  // verify a HELLO MAC, and the discovery callbacks that Mesh reassigns when the node pairs.
  mutable std::mutex mu_;
  std::array<uint8_t, 32> psk_;
  std::array<uint8_t, 32> prev_psk_{};
  std::string group_;
  uint16_t port_;
  int64_t period_ms_;

  std::function<void(const DiscoveredPeer&)> on_found_;
  std::function<void(const PairBeacon&)> on_pair_found_;
  std::string node_id_, adv_addr_;


  std::atomic<bool> pair_on_{false};
  PairAnnounce pair_;
  uint64_t timer_id_ = 0;
  net::socket_t send_fd_ = net::kInvalidSocket;
  net::socket_t recv_fd_ = net::kInvalidSocket;
  std::thread recv_thread_;
  std::atomic<bool> stopping_{false};
  std::atomic<int64_t> sent_{0};
  std::atomic<int64_t> send_err_{0};
};

}  // namespace db
