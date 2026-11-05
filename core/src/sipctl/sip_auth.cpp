#include "sipctl/sip_auth.h"

#include <cstdlib>

#include "mesh/socket_compat.h"
#include "monocypher.h"
#include "util/common.h"

namespace db {
namespace {

constexpr int64_t kSkewMs = 60'000;
constexpr size_t kMaxSeen = 512;

std::string macHex(const std::array<uint8_t, 32>& key, const std::string& node_id,
                   const std::string& stamp, const std::string& nonce, const std::string& mode) {
  const std::string text = node_id + "\n" + stamp + "\n" + nonce + "\n" + mode;
  uint8_t mac[32];
  crypto_blake2b_keyed(mac, sizeof(mac), key.data(), key.size(),
                       reinterpret_cast<const uint8_t*>(text.data()), text.size());
  return hexEncode(mac, sizeof(mac));
}

bool equalConstantTime(const std::string& a, const std::string& b) {
  if (a.size() != b.size() || a.empty()) return false;
  unsigned char diff = 0;
  for (size_t i = 0; i < a.size(); ++i)
    diff = static_cast<unsigned char>(diff | (static_cast<unsigned char>(a[i]) ^
                                              static_cast<unsigned char>(b[i])));
  return diff == 0;
}

bool lowerHex(const std::string& s, size_t size) {
  return s.size() == size && s.find_first_not_of("0123456789abcdef") == std::string::npos;
}

}  // namespace

std::string sipPeerAuthValue(const std::array<uint8_t, 32>& key, const std::string& node_id,
                             int64_t unix_ms, const std::string& nonce, const std::string& mode) {
  const std::string stamp = std::to_string(unix_ms);
  return "v1." + node_id + "." + stamp + "." + nonce + "." + macHex(key, node_id, stamp, nonce, mode);
}

void SipPeerAuth::setKey(const std::string& node_id, const std::array<uint8_t, 32>& key) {
  std::lock_guard<std::mutex> lock(mu_);
  node_id_ = node_id;
  key_ = key;
  has_key_ = false;
  for (uint8_t b : key) has_key_ = has_key_ || b != 0;
}

void SipPeerAuth::setPreviousKey(const std::array<uint8_t, 32>& key) {
  std::lock_guard<std::mutex> lock(mu_);
  prev_key_ = key;
  has_prev_key_ = false;
  for (uint8_t b : key) has_prev_key_ = has_prev_key_ || b != 0;
}

bool SipPeerAuth::hasKey() const {
  std::lock_guard<std::mutex> lock(mu_);
  return has_key_;
}

std::string SipPeerAuth::sign(const std::string& mode, int64_t unix_ms) const {
  std::lock_guard<std::mutex> lock(mu_);
  if (!has_key_ || node_id_.empty()) return "";
  return sipPeerAuthValue(key_, node_id_, unix_ms, hexEncode(randomBytes(16)), mode);
}

bool SipPeerAuth::verify(const std::string& header, const std::string& mode, int64_t now_ms,
                         std::string* peer_out) {
  if (header.size() > 256 || header.compare(0, 3, "v1.") != 0) return false;
  std::string fields[4];
  size_t from = 3;
  for (int i = 0; i < 4; ++i) {
    const size_t dot = i < 3 ? header.find('.', from) : std::string::npos;
    if (i < 3 && dot == std::string::npos) return false;
    fields[i] = header.substr(from, i < 3 ? dot - from : std::string::npos);
    from = dot + 1;
  }
  const std::string& node = fields[0];
  const std::string& stamp = fields[1];
  const std::string& nonce = fields[2];
  const std::string& mac = fields[3];
  if (!lowerHex(node, 32) || stamp.empty() || stamp.size() > 15 ||
      stamp.find_first_not_of("0123456789") != std::string::npos || !lowerHex(nonce, 32) ||
      !lowerHex(mac, 64))
    return false;
  const int64_t sent = std::strtoll(stamp.c_str(), nullptr, 10);
  if (std::llabs(now_ms - sent) > kSkewMs) return false;
  std::lock_guard<std::mutex> lock(mu_);
  if (!has_key_ || node == node_id_) return false;
  const bool current_ok = equalConstantTime(macHex(key_, node, stamp, nonce, mode), mac);
  const bool previous_ok =
      has_prev_key_ && equalConstantTime(macHex(prev_key_, node, stamp, nonce, mode), mac);
  if (!current_ok && !previous_ok) return false;
  while (!seen_.empty() && (seen_.front().first < now_ms - 2 * kSkewMs || seen_.size() >= kMaxSeen)) {
    seen_set_.erase(seen_.front().second);
    seen_.pop_front();
  }
  if (!seen_set_.insert(nonce).second) return false;
  seen_.emplace_back(now_ms, nonce);
  if (peer_out) *peer_out = node;
  return true;
}

SipInboundPath classifySipInbound(const std::string& source, bool peer_auth_valid,
                                  const std::set<std::string>& peer_sources,
                                  const std::set<std::string>& registrar_sources) {
  if (source.empty()) return SipInboundPath::Rejected;
  if (peer_auth_valid && peer_sources.count(source)) return SipInboundPath::Peer;
  if (registrar_sources.count(source)) return SipInboundPath::Registrar;
  return SipInboundPath::Rejected;
}

std::set<std::string> resolveSipHost(const std::string& host) {
  std::set<std::string> out;
  if (host.empty() || host.size() > 253) return out;
  std::string name = host;
  if (name.size() > 2 && name.front() == '[' && name.back() == ']')
    name = name.substr(1, name.size() - 2);
  addrinfo hints{};
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_DGRAM;
  addrinfo* list = nullptr;
  if (::getaddrinfo(name.c_str(), nullptr, &hints, &list) != 0 || !list) return out;
  for (addrinfo* p = list; p; p = p->ai_next) {
    char text[64] = {0};
    if (p->ai_family == AF_INET) {
      ::inet_ntop(AF_INET, &reinterpret_cast<sockaddr_in*>(p->ai_addr)->sin_addr, text,
                  sizeof(text));
    } else if (p->ai_family == AF_INET6) {
      ::inet_ntop(AF_INET6, &reinterpret_cast<sockaddr_in6*>(p->ai_addr)->sin6_addr, text,
                  sizeof(text));
    }
    if (text[0]) out.insert(text);
  }
  ::freeaddrinfo(list);
  return out;
}

}  // namespace db
