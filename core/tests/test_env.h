#pragma once

// Shared test resources: listener ports and scratch file paths, both of which have to survive
// two copies of the suite running at once.
//
// Every test file used to carry its own copy of the same helper: draw a number from 40000-60000,
// bind it to see whether it is free, close the probe, and hand the number to a node that binds it
// a moment later. Two things go wrong on Linux and not on macOS. That range sits inside Linux's
// default ephemeral range (32768-60999), so in the gap between the probe and the real bind the
// kernel can hand the same port to any outbound connection as its source port -- a CI runner
// makes plenty. And each file had its own generator, so two nodes in one process could draw the
// same number. macOS starts its ephemeral range at 49152, which is why a REQUIRE(node->start())
// only ever failed on the Linux runner.
//
// This draws from 20000-32000, below the ephemeral range on both platforms, so the kernel never
// assigns one of these behind our back. It remembers every port it has returned in this process,
// and it probes the wildcard address rather than loopback because that is what a listener
// actually asks the kernel for.
//
// uniqueTempPath exists for the same reason on the filesystem side: a fixture written to a fixed
// path under /tmp is removed out from under the other process.

#include <atomic>
#include <chrono>
#include <mutex>
#include <random>
#include <set>
#include <string>

#include "mesh/socket_compat.h"

namespace db {
namespace testing {

inline uint32_t currentProcessId() {
#if defined(_WIN32)
  return static_cast<uint32_t>(::GetCurrentProcessId());
#else
  return static_cast<uint32_t>(::getpid());
#endif
}

inline bool portBindable(int port) {
  const net::socket_t fd = ::socket(AF_INET, SOCK_STREAM, 0);
  if (!net::valid(fd)) return false;
  sockaddr_in address{};
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_ANY);
  address.sin_port = htons(static_cast<uint16_t>(port));
  // Deliberately no SO_REUSEADDR: a port still in TIME_WAIT from an earlier case would look
  // free here and then refuse the listener that matters.
  const bool ok = ::bind(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0;
  net::closeSocket(fd);
  return ok;
}

// A port no listener in this process has been given yet, and that the kernel will accept right
// now. Returns -1 only if the whole range is unusable, which a caller should REQUIRE against.
inline int freeListenPort() {
  static std::mutex mu;
  static std::set<int> handed_out;
  static std::mt19937 rng(static_cast<uint32_t>(currentProcessId()) * 2654435761u ^
                          static_cast<uint32_t>(
                              std::chrono::steady_clock::now().time_since_epoch().count()));
  std::lock_guard<std::mutex> lk(mu);
  std::uniform_int_distribution<int> dist(20000, 32000);
  for (int attempt = 0; attempt < 400; attempt++) {
    const int port = dist(rng);
    if (handed_out.count(port)) continue;
    if (!portBindable(port)) continue;
    handed_out.insert(port);
    return port;
  }
  return -1;
}

// A scratch path no other process (or other call in this one) will use.
inline std::string uniqueTempPath(const std::string& prefix, const std::string& suffix) {
  static std::atomic<uint32_t> counter{0};
  return "/tmp/" + prefix + "_" + std::to_string(currentProcessId()) + "_" +
         std::to_string(counter.fetch_add(1)) + suffix;
}

}  // namespace testing
}  // namespace db
