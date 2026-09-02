// Minimal SNTP v4 client (RFC 4330) used by the optional independent time service.
//
// Core never touches the operating-system clock. It measures an offset against the configured
// servers and applies that offset on top of the platform wall clock, so a device whose OS time is
// wrong (or whose OS has no time source at all) still stamps events and renders clocks correctly.
// The packet helpers are pure so they can be exercised with fixed vectors in tests; only
// exchange() opens a socket.
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

namespace db {
namespace sntp {

constexpr size_t kPacketSize = 48;
// Seconds between the NTP epoch (1900-01-01) and the Unix epoch (1970-01-01).
constexpr int64_t kEpochDeltaS = 2'208'988'800LL;
constexpr int kDefaultPort = 123;

// Convert between Unix milliseconds and the 64-bit NTP fixed-point timestamp format. Era 0 only:
// the encoding rolls over in 2036 and this client is not expected to outlive that.
uint64_t toNtpTimestamp(int64_t unix_ms);
int64_t fromNtpTimestamp(uint64_t value);

// Build a client request (LI 0, VN 4, mode 3) whose transmit timestamp is transmit_unix_ms.
void buildRequest(uint8_t out[kPacketSize], int64_t transmit_unix_ms);

struct Reply {
  int64_t originate_ms = 0;  // t1 as echoed by the server
  int64_t receive_ms = 0;    // t2
  int64_t transmit_ms = 0;   // t3
  int stratum = 0;
  int leap = 0;
  int mode = 0;
};

// Reject a short packet, a version below 3, a non-server mode, leap indicator 3 ("alarm", the
// server is unsynchronized), stratum 0 (kiss-of-death) or above 15, a zero transmit timestamp,
// and an originate timestamp that does not echo the request that was sent.
bool parseReply(const uint8_t* data, size_t len, int64_t sent_unix_ms, Reply* out);

struct Sample {
  int64_t offset_ms = 0;
  int64_t rtt_ms = 0;
};

// offset = ((t2 - t1) + (t3 - t4)) / 2, round trip = (t4 - t1) - (t3 - t2).
Sample computeSample(int64_t t1, int64_t t2, int64_t t3, int64_t t4);

// A sample is usable only with a non-negative round trip of at most three seconds and an
// absolute offset below 24 hours; anything else is a broken server, a captive portal, or a
// wildly wrong local clock that a doorbell must not silently adopt.
bool sampleSane(const Sample& sample);

// Split "host" or "host:port" into its parts. The default port is 123. Returns false for an
// empty host, a port outside 1..65535, or trailing junk. Bracketed IPv6 literals are accepted
// as "[::1]:123"; a bare IPv6 literal is treated as a host with the default port.
bool parseServer(const std::string& spec, std::string* host, int* port);

// One bounded UDP request/response exchange. Blocking with a hard timeout, so callers run it on
// a worker thread rather than on the runloop. Returns false on any resolution, send, timeout, or
// short-read failure.
bool exchange(const std::string& host, int port, int timeout_ms,
              const uint8_t request[kPacketSize], uint8_t response[kPacketSize]);

}  // namespace sntp
}  // namespace db
