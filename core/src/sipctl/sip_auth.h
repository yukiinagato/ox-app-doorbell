// Inbound SIP admission, independent of PJSIP so every build tests it.
//
// Two inbound paths exist:
//  - Peer: another cluster member called this node directly. Its INVITE must carry
//    X-Doorbell-Auth: v1.<node_id>.<unix_ms>.<nonce>.<mac>, where
//    mac = BLAKE2b-keyed(key, node_id "\n" unix_ms "\n" nonce "\n" X-Doorbell-Mode) and key is
//    derived from the cluster PSK. The timestamp must be within +-60 s and the nonce unseen.
//    The source address must also be a current member's address.
//  - Registrar: the INVITE arrives from the configured SIP server's resolved address (for
//    example Asterisk dialling 800X with Alert-Info answer-after=0). It needs no header; the
//    existing auto-answer rules apply and SRTP stays optional toward that server.
// Anything else is refused with 403. There is no "empty list allows everyone".
#pragma once

#include <array>
#include <cstdint>
#include <deque>
#include <mutex>
#include <set>
#include <string>
#include <utility>

namespace db {

enum class SipInboundPath { Peer, Registrar, Rejected };

std::string sipPeerAuthValue(const std::array<uint8_t, 32>& key, const std::string& node_id,
                             int64_t unix_ms, const std::string& nonce, const std::string& mode);

class SipPeerAuth {
 public:
  void setKey(const std::string& node_id, const std::array<uint8_t, 32>& key);
  // Key of the previous cluster PSK during its rotation grace period; all-zero clears it.
  // Only verification uses it; outbound INVITEs are always signed with the current key.
  void setPreviousKey(const std::array<uint8_t, 32>& key);
  bool hasKey() const;
  // Header value for an outbound INVITE, or empty when no key is set.
  std::string sign(const std::string& mode, int64_t unix_ms) const;
  // Validates and consumes the nonce. peer_out receives the claimed node id on success.
  bool verify(const std::string& header, const std::string& mode, int64_t now_ms,
              std::string* peer_out);

 private:
  mutable std::mutex mu_;
  std::string node_id_;
  std::array<uint8_t, 32> key_{};
  bool has_key_ = false;
  std::array<uint8_t, 32> prev_key_{};
  bool has_prev_key_ = false;
  std::deque<std::pair<int64_t, std::string>> seen_;
  std::set<std::string> seen_set_;
};

// peer_sources: current members' addresses. registrar_sources: resolved addresses of the
// configured SIP server (empty when no server is configured).
SipInboundPath classifySipInbound(const std::string& source, bool peer_auth_valid,
                                  const std::set<std::string>& peer_sources,
                                  const std::set<std::string>& registrar_sources);

// Resolves a configured server host to its numeric addresses. Bounded by the system resolver.
std::set<std::string> resolveSipHost(const std::string& host);

}  // namespace db
