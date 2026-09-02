#include "util/sntp.h"

#include <cstdlib>
#include <cstring>

#include "mesh/socket_compat.h"

namespace db {
namespace sntp {
namespace {

constexpr int64_t kMaxOffsetMs = 24LL * 3600LL * 1000LL;
constexpr int64_t kMaxRttMs = 3000;

int64_t floorDivI(int64_t a, int64_t b) {
  const int64_t q = a / b;
  return (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q;
}

uint32_t readU32(const uint8_t* p) {
  return (static_cast<uint32_t>(p[0]) << 24) | (static_cast<uint32_t>(p[1]) << 16) |
         (static_cast<uint32_t>(p[2]) << 8) | static_cast<uint32_t>(p[3]);
}

void writeU32(uint8_t* p, uint32_t value) {
  p[0] = static_cast<uint8_t>(value >> 24);
  p[1] = static_cast<uint8_t>(value >> 16);
  p[2] = static_cast<uint8_t>(value >> 8);
  p[3] = static_cast<uint8_t>(value);
}

uint64_t readU64(const uint8_t* p) {
  return (static_cast<uint64_t>(readU32(p)) << 32) | readU32(p + 4);
}

void writeU64(uint8_t* p, uint64_t value) {
  writeU32(p, static_cast<uint32_t>(value >> 32));
  writeU32(p + 4, static_cast<uint32_t>(value));
}

}  // namespace

uint64_t toNtpTimestamp(int64_t unix_ms) {
  const int64_t seconds = floorDivI(unix_ms, 1000);
  const int64_t millis = unix_ms - seconds * 1000;
  const uint64_t ntp_seconds = static_cast<uint64_t>(seconds + kEpochDeltaS);
  // Round rather than truncate so a millisecond survives the encode/decode round trip.
  const uint64_t fraction = ((static_cast<uint64_t>(millis) << 32) + 500ULL) / 1000ULL;
  return (ntp_seconds << 32) | (fraction & 0xffffffffULL);
}

int64_t fromNtpTimestamp(uint64_t value) {
  const int64_t seconds = static_cast<int64_t>(value >> 32) - kEpochDeltaS;
  const int64_t millis =
      static_cast<int64_t>((((value & 0xffffffffULL) * 1000ULL) + (1ULL << 31)) >> 32);
  return seconds * 1000 + millis;
}

void buildRequest(uint8_t out[kPacketSize], int64_t transmit_unix_ms) {
  std::memset(out, 0, kPacketSize);
  // LI = 0 (no warning), VN = 4, mode = 3 (client).
  out[0] = static_cast<uint8_t>((0 << 6) | (4 << 3) | 3);
  writeU64(out + 40, toNtpTimestamp(transmit_unix_ms));
}

bool parseReply(const uint8_t* data, size_t len, int64_t sent_unix_ms, Reply* out) {
  if (!data || !out || len < kPacketSize) return false;
  const int leap = (data[0] >> 6) & 0x3;
  const int version = (data[0] >> 3) & 0x7;
  const int mode = data[0] & 0x7;
  const int stratum = data[1];
  if (leap == 3) return false;
  if (version < 3 || version > 4) return false;
  if (mode != 4 && mode != 5) return false;
  if (stratum == 0 || stratum > 15) return false;
  const uint64_t originate = readU64(data + 24);
  const uint64_t receive = readU64(data + 32);
  const uint64_t transmit = readU64(data + 40);
  if (transmit == 0 || receive == 0 || originate == 0) return false;
  if (originate != toNtpTimestamp(sent_unix_ms)) return false;
  out->leap = leap;
  out->mode = mode;
  out->stratum = stratum;
  out->originate_ms = fromNtpTimestamp(originate);
  out->receive_ms = fromNtpTimestamp(receive);
  out->transmit_ms = fromNtpTimestamp(transmit);
  return true;
}

Sample computeSample(int64_t t1, int64_t t2, int64_t t3, int64_t t4) {
  Sample sample;
  sample.offset_ms = ((t2 - t1) + (t3 - t4)) / 2;
  sample.rtt_ms = (t4 - t1) - (t3 - t2);
  return sample;
}

bool sampleSane(const Sample& sample) {
  if (sample.rtt_ms < 0 || sample.rtt_ms > kMaxRttMs) return false;
  const int64_t magnitude = sample.offset_ms < 0 ? -sample.offset_ms : sample.offset_ms;
  return magnitude <= kMaxOffsetMs;
}

bool parseServer(const std::string& spec, std::string* host, int* port) {
  if (spec.empty() || spec.size() > 255) return false;
  std::string name = spec;
  int parsed_port = kDefaultPort;
  if (name[0] == '[') {
    const size_t close = name.find(']');
    if (close == std::string::npos) return false;
    const std::string rest = name.substr(close + 1);
    name = name.substr(1, close - 1);
    if (!rest.empty()) {
      if (rest[0] != ':') return false;
      parsed_port = std::atoi(rest.c_str() + 1);
      if (rest.size() < 2) return false;
      for (size_t i = 1; i < rest.size(); i++) {
        if (rest[i] < '0' || rest[i] > '9') return false;
      }
    }
  } else {
    const size_t colon = name.rfind(':');
    // More than one colon means a bare IPv6 literal, which carries no port.
    if (colon != std::string::npos && name.find(':') == colon) {
      const std::string port_text = name.substr(colon + 1);
      if (port_text.empty()) return false;
      for (char c : port_text) {
        if (c < '0' || c > '9') return false;
      }
      parsed_port = std::atoi(port_text.c_str());
      name = name.substr(0, colon);
    }
  }
  if (name.empty() || parsed_port < 1 || parsed_port > 65535) return false;
  for (char c : name) {
    const bool allowed = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                         (c >= '0' && c <= '9') || c == '.' || c == '-' || c == ':' || c == '_';
    if (!allowed) return false;
  }
  if (host) *host = name;
  if (port) *port = parsed_port;
  return true;
}

bool exchange(const std::string& host, int port, int timeout_ms,
              const uint8_t request[kPacketSize], uint8_t response[kPacketSize]) {
  if (host.empty() || port < 1 || port > 65535 || !request || !response) return false;
  addrinfo hints{};
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_DGRAM;
  hints.ai_protocol = IPPROTO_UDP;
  addrinfo* addresses = nullptr;
  const std::string service = std::to_string(port);
  if (::getaddrinfo(host.c_str(), service.c_str(), &hints, &addresses) != 0 || !addresses)
    return false;
  bool ok = false;
  for (addrinfo* p = addresses; p && !ok; p = p->ai_next) {
    net::socket_t fd = ::socket(p->ai_family, p->ai_socktype, p->ai_protocol);
    if (!net::valid(fd)) continue;
    net::setNonBlock(fd);
    const int sent = net::sendTo(fd, request, kPacketSize, p->ai_addr,
                                 static_cast<net::socklen_v>(p->ai_addrlen));
    if (sent == static_cast<int>(kPacketSize)) {
      net::pollfd_t pfd{};
      pfd.fd = fd;
      pfd.events = POLLIN;
      if (net::poll(&pfd, 1, timeout_ms) > 0 && (pfd.revents & POLLIN)) {
        uint8_t buffer[256];
        const int received = net::recvFrom(fd, buffer, sizeof(buffer));
        if (received >= static_cast<int>(kPacketSize)) {
          std::memcpy(response, buffer, kPacketSize);
          ok = true;
        }
      }
    }
    net::closeSocket(fd);
  }
  ::freeaddrinfo(addresses);
  return ok;
}

}  // namespace sntp
}  // namespace db
