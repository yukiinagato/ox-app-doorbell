







// PSK-authenticated encrypted channel over IConn. The handshake exchanges nonces and IDs, derives
// a session key without sending the PSK, confirms both sides, then protects monotonically numbered
// frames with XChaCha20-Poly1305. Authentication, replay, or framing failure closes immediately.
// All methods and callbacks run on Runloop.
#pragma once

#include <array>
#include <cstdint>
#include <deque>
#include <memory>
#include <string>

#include "mesh/transport.h"
#include "util/runloop.h"

namespace db {


enum : uint8_t {
  kFrameHs1 = 0x01,
  kFrameHs2 = 0x02,
  kFrameConfirm = 0x03,  // [type][dir 1][hmac 32]
  kFrameData = 0x10,     // [type][dir 1][frame_no 8BE][mac 16][cipher...]
  kFrameJoin = 0x40,
};

class SecureChannel : public std::enable_shared_from_this<SecureChannel> {
 public:
  struct Callbacks {
    std::function<void()> on_established;
    std::function<void(const std::string&)> on_message;
    std::function<void()> on_close;
  };


  SecureChannel(Runloop& loop, ConnPtr conn, bool initiator, const std::array<uint8_t, 32>& psk,
                std::string self_id, int64_t handshake_timeout_ms);
  ~SecureChannel();

  void setCallbacks(Callbacks cbs) { cbs_ = std::move(cbs); }


  void start();

  void handleRawFrame(const Bytes& f);


  void sendMessage(const std::string& msg_json);
  void close();

  bool established() const { return state_ == State::kOpen; }
  const std::string& peerId() const { return peer_id_; }
  bool isInitiator() const { return initiator_; }
  std::string remoteAddr() const { return conn_ ? conn_->remoteAddr() : ""; }

 private:
  enum class State { kAwaitHs, kAwaitConfirm, kOpen, kClosed };

  void sendHello_(uint8_t type);
  void deriveKey_();
  void sendConfirm_();
  bool checkConfirm_(const Bytes& f);
  void becomeOpen_();
  void fail_(const char* why);
  void notifyClose_();
  Bytes confirmMac_(uint8_t dir) const;

  Runloop& loop_;
  ConnPtr conn_;
  bool initiator_;
  std::array<uint8_t, 32> psk_;
  std::string self_id_;
  std::string peer_id_;
  int64_t hs_timeout_ms_;
  uint64_t timeout_id_ = 0;

  State state_ = State::kAwaitHs;
  std::array<uint8_t, 32> nonce_a_{};
  std::array<uint8_t, 32> nonce_b_{};
  std::array<uint8_t, 32> key_{};      // session_key
  bool key_ready_ = false;
  bool peer_confirmed_ = false;

  uint64_t send_no_ = 0;
  uint64_t recv_min_no_ = 0;  // Rejects replay while allowing gaps from transport loss.
  std::deque<std::string> pending_;
  Callbacks cbs_;
  bool close_notified_ = false;
};

}  // namespace db
