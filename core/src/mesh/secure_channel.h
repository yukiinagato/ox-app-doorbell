// Mutually authenticated encrypted channel over IConn (protocol v3).
//
// Each side sends a hello carrying an ephemeral X25519 key, a nonce, its Ed25519 identity public
// key, the cluster key IDs it holds, and its node ID. The newest key ID both sides hold is used:
//   transcript = BLAKE2b("doorbell-mesh-v3" || key_id || hello_initiator || hello_responder)
//   session    = BLAKE2b-keyed(psk, X25519(eph, peer_eph) || transcript)
// Each confirmation carries a MAC under the session and an Ed25519 signature over the transcript,
// so the channel opens only when the peer holds the cluster key, proves possession of the
// identity key that `authorize` accepted for its node ID, and contributes forward secrecy.
// Data frames use XChaCha20-Poly1305 with one key per direction. A v2 hello, an unauthorized
// identity, a missing common key, or any framing or authentication failure closes immediately.
// All methods and callbacks run on Runloop.
#pragma once

#include <array>
#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "mesh/transport.h"
#include "util/runloop.h"

namespace db {

enum : uint8_t {
  kFrameHs1 = 0x01,
  kFrameHs2 = 0x02,
  kFrameConfirm = 0x03,  // [type][dir 1][mac 32][signature 64]
  kFrameData = 0x10,     // [type][dir 1][frame_no 8BE][mac 16][cipher...]
  kFrameJoin = 0x40,
};

constexpr uint8_t kMeshProtocolVersion = 0x03;

struct PskSlot {
  std::string id;  // "k<n>" optionally followed by ".<suffix>"
  std::array<uint8_t, 32> key{};
};

// Orders cluster key IDs: higher generation first, then the lexicographically larger ID. Returns
// a negative, zero, or positive value like strcmp.
int comparePskIds(const std::string& a, const std::string& b);

struct ChannelIdentity {
  std::vector<PskSlot> psks;               // every cluster key this node currently accepts
  std::array<uint8_t, 32> identity_seed{};  // Ed25519 seed of this node
  // Decides whether `peer_id` may present `peer_pk` using key `psk_id`. Null accepts everyone,
  // which only the standalone channel tests rely on.
  std::function<bool(const std::string& peer_id, const std::array<uint8_t, 32>& peer_pk,
                     const std::string& psk_id)>
      authorize;
};

class SecureChannel : public std::enable_shared_from_this<SecureChannel> {
 public:
  struct Callbacks {
    std::function<void()> on_established;
    std::function<void(const std::string&)> on_message;
    std::function<void()> on_close;
    // Reported once before on_close when the handshake fails for a classified reason:
    // protocol_upgrade_required | no_common_psk | unauthorized_peer | bad_signature.
    // peer_id may be empty when the hello could not be parsed.
    std::function<void(const std::string& reason, const std::string& peer_id)> on_rejected;
  };

  SecureChannel(Runloop& loop, ConnPtr conn, bool initiator, ChannelIdentity identity,
                std::string self_id, int64_t handshake_timeout_ms);
  // Single key "k1", a random identity, and no authorization: for channel-level tests.
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
  const std::array<uint8_t, 32>& peerIdentity() const { return peer_identity_; }
  const std::string& pskId() const { return psk_id_; }
  bool isInitiator() const { return initiator_; }
  std::string remoteAddr() const { return conn_ ? conn_->remoteAddr() : ""; }
  // Raise the transport frame limit once the peer is authenticated.
  void setMaxInboundFrame(size_t bytes) {
    if (conn_) conn_->setMaxInboundFrame(bytes);
  }

 private:
  enum class State { kAwaitHs, kAwaitConfirm, kOpen, kClosed };

  Bytes buildHello_(uint8_t type);
  bool parseHello_(const Bytes& f, uint8_t expect_type);
  bool derive_();
  void sendConfirm_();
  bool checkConfirm_(const Bytes& f);
  Bytes confirmMac_(uint8_t dir) const;
  void becomeOpen_();
  void reject_(const char* reason);
  void fail_(const char* why);
  void notifyClose_();

  Runloop& loop_;
  ConnPtr conn_;
  bool initiator_;
  ChannelIdentity identity_;
  std::string self_id_;
  std::string peer_id_;
  int64_t hs_timeout_ms_;
  uint64_t timeout_id_ = 0;
  State state_ = State::kAwaitHs;

  std::array<uint8_t, 32> eph_sk_{};
  std::array<uint8_t, 32> eph_pk_{};
  std::array<uint8_t, 32> nonce_{};
  std::array<uint8_t, 64> sign_sk_{};
  std::array<uint8_t, 32> sign_pk_{};
  Bytes hello_self_;
  Bytes hello_peer_;
  std::array<uint8_t, 32> peer_eph_{};
  std::array<uint8_t, 32> peer_identity_{};
  std::vector<std::string> peer_psk_ids_;
  std::string psk_id_;
  std::array<uint8_t, 32> transcript_{};
  std::array<uint8_t, 32> session_{};
  std::array<uint8_t, 32> dir_key_[2]{};
  bool key_ready_ = false;

  uint64_t send_no_ = 0;
  uint64_t recv_min_no_ = 0;  // Rejects replay while allowing gaps from transport loss.
  std::deque<std::string> pending_;
  Callbacks cbs_;
  bool close_notified_ = false;
  bool rejected_ = false;
};

}  // namespace db
