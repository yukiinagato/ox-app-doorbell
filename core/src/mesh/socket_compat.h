
// POSIX/Winsock compatibility layer used by transports and discovery. Callers must enforce a
// connection deadline because WSAPoll may omit POLLERR for failed connects on older Windows.
#pragma once

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#if defined(__ANDROID__)
#include <linux/if_addr.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#endif
#endif

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <climits>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace db {
namespace net {

#if defined(_WIN32)
using socket_t = SOCKET;
using pollfd_t = WSAPOLLFD;
using socklen_v = int;
constexpr socket_t kInvalidSocket = INVALID_SOCKET;
#else
using socket_t = int;
using pollfd_t = ::pollfd;
using socklen_v = socklen_t;
constexpr socket_t kInvalidSocket = -1;
#endif

inline bool valid(socket_t s) { return s != kInvalidSocket; }



// getifaddrs is unavailable before Android API 24, so those targets use route netlink.
#if !defined(_WIN32) && !(defined(__ANDROID__) && __ANDROID_API__ < 24)
#define DB_HAVE_GETIFADDRS 1
#endif



inline std::string primaryIPv4ViaRoute() {
#if !defined(_WIN32)
  int fd = ::socket(AF_INET, SOCK_DGRAM, 0);
  if (fd < 0) return std::string();
  struct sockaddr_in dst;
  std::memset(&dst, 0, sizeof(dst));
  dst.sin_family = AF_INET;
  dst.sin_port = htons(9);  // Discard service; connect sends no packet here.
  ::inet_pton(AF_INET, "8.8.8.8", &dst.sin_addr);  // Select the default-route source address.
  std::string out;
  if (::connect(fd, reinterpret_cast<struct sockaddr*>(&dst), sizeof(dst)) == 0) {
    struct sockaddr_in local;
    std::memset(&local, 0, sizeof(local));
    socklen_t len = sizeof(local);
    if (::getsockname(fd, reinterpret_cast<struct sockaddr*>(&local), &len) == 0) {
      char buf[INET_ADDRSTRLEN] = {0};
      if (::inet_ntop(AF_INET, &local.sin_addr, buf, sizeof(buf))) out = buf;
    }
  }
  ::close(fd);
  return out;
#else
  return std::string();
#endif
}



// Android before API 24 enumerates IPv4/IPv6 through route netlink instead of getifaddrs.
inline std::vector<std::string> localAddresses(bool includeV6) {
  std::vector<std::string> out;
#if defined(DB_HAVE_GETIFADDRS)
  struct ifaddrs* head = nullptr;
  if (getifaddrs(&head) != 0 || head == nullptr) return out;
  for (struct ifaddrs* p = head; p != nullptr; p = p->ifa_next) {
    if (p->ifa_addr == nullptr) continue;
    if (!(p->ifa_flags & IFF_UP)) continue;
    if (p->ifa_flags & IFF_LOOPBACK) continue;
    int fam = p->ifa_addr->sa_family;
    char buf[INET6_ADDRSTRLEN] = {0};
    if (fam == AF_INET) {
      auto* sin = reinterpret_cast<struct sockaddr_in*>(p->ifa_addr);
      if (::inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf))) out.emplace_back(buf);
    } else if (includeV6 && fam == AF_INET6) {
      auto* s6 = reinterpret_cast<struct sockaddr_in6*>(p->ifa_addr);
      if (IN6_IS_ADDR_LINKLOCAL(&s6->sin6_addr)) continue;
      if (::inet_ntop(AF_INET6, &s6->sin6_addr, buf, sizeof(buf))) out.emplace_back(buf);
    }
  }
  freeifaddrs(head);
#elif defined(__ANDROID__)
  // Android API 21-23 cannot use the getifaddrs declaration/ABI. Route netlink is stable
  // there and, unlike SIOCGIFCONF, also returns AF_INET6 addresses.
  int fd = ::socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
  int flagFd = ::socket(AF_INET, SOCK_DGRAM, 0);
  if (fd >= 0) {
    struct {
      struct nlmsghdr hdr;
      struct ifaddrmsg msg;
    } req;
    std::memset(&req, 0, sizeof(req));
    req.hdr.nlmsg_len = NLMSG_LENGTH(sizeof(struct ifaddrmsg));
    req.hdr.nlmsg_type = RTM_GETADDR;
    req.hdr.nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP;
    req.hdr.nlmsg_seq = 1;
    req.msg.ifa_family = AF_UNSPEC;
    struct sockaddr_nl kernel;
    std::memset(&kernel, 0, sizeof(kernel));
    kernel.nl_family = AF_NETLINK;
    bool done = false;
    if (::sendto(fd, &req, req.hdr.nlmsg_len, 0,
                 reinterpret_cast<struct sockaddr*>(&kernel), sizeof(kernel)) >= 0) {
      while (!done) {
        char buf[16384];
        int got = static_cast<int>(::recv(fd, buf, sizeof(buf), 0));
        if (got <= 0) break;
        unsigned int remain = static_cast<unsigned int>(got);
        for (struct nlmsghdr* nh = reinterpret_cast<struct nlmsghdr*>(buf);
             NLMSG_OK(nh, remain); nh = NLMSG_NEXT(nh, remain)) {
          if (nh->nlmsg_type == NLMSG_DONE) { done = true; break; }
          if (nh->nlmsg_type == NLMSG_ERROR) { done = true; break; }
          if (nh->nlmsg_type != RTM_NEWADDR) continue;
          auto* info = reinterpret_cast<struct ifaddrmsg*>(NLMSG_DATA(nh));
          int family = info->ifa_family;
          if (family != AF_INET && (family != AF_INET6 || !includeV6)) continue;
          if (info->ifa_scope == RT_SCOPE_LINK || info->ifa_scope == RT_SCOPE_HOST) continue;

          char ifname[IFNAMSIZ] = {0};
          if (!::if_indextoname(info->ifa_index, ifname)) continue;
          if (flagFd >= 0) {
            struct ifreq flags;
            std::memset(&flags, 0, sizeof(flags));
            std::strncpy(flags.ifr_name, ifname, IFNAMSIZ - 1);
            if (::ioctl(flagFd, SIOCGIFFLAGS, &flags) != 0 ||
                !(flags.ifr_flags & IFF_UP) || (flags.ifr_flags & IFF_LOOPBACK)) continue;
          }

          const void* address = nullptr;
          unsigned int addrFlags = info->ifa_flags;
          bool preferred = true;
          int attrsLen = IFA_PAYLOAD(nh);
          for (struct rtattr* attr = IFA_RTA(info); RTA_OK(attr, attrsLen);
               attr = RTA_NEXT(attr, attrsLen)) {
            if (attr->rta_type == IFA_FLAGS && RTA_PAYLOAD(attr) >= sizeof(uint32_t))
              std::memcpy(&addrFlags, RTA_DATA(attr), sizeof(uint32_t));
            if (attr->rta_type == IFA_CACHEINFO &&
                RTA_PAYLOAD(attr) >= sizeof(struct ifa_cacheinfo)) {
              auto* cache = reinterpret_cast<const struct ifa_cacheinfo*>(RTA_DATA(attr));
              if (cache->ifa_prefered == 0) preferred = false;
            }
            if ((family == AF_INET && attr->rta_type == IFA_LOCAL) ||
                (address == nullptr && attr->rta_type == IFA_ADDRESS))
              address = RTA_DATA(attr);
          }
          if (!preferred || address == nullptr) continue;
          unsigned int bad = IFA_F_DEPRECATED | IFA_F_TENTATIVE | IFA_F_DADFAILED;
          if (family == AF_INET6) bad |= IFA_F_TEMPORARY;
          if ((addrFlags & bad) != 0) continue;

          char ip[INET6_ADDRSTRLEN] = {0};
          if (family == AF_INET6) {
            auto* a6 = reinterpret_cast<const struct in6_addr*>(address);
            if (IN6_IS_ADDR_LINKLOCAL(a6) || IN6_IS_ADDR_LOOPBACK(a6)) continue;
          }
          if (::inet_ntop(family, address, ip, sizeof(ip))) {
            std::string value(ip);
            if (std::find(out.begin(), out.end(), value) == out.end()) out.push_back(value);
          }
        }
      }
    }
    ::close(fd);
  }
  if (flagFd >= 0) ::close(flagFd);
  if (out.empty()) {
    std::string ip = primaryIPv4ViaRoute();
    if (!ip.empty()) out.push_back(ip);
  }
#else
  (void)includeV6;
  std::string ip = primaryIPv4ViaRoute();
  if (!ip.empty()) out.push_back(ip);
#endif
  return out;
}


inline std::string primaryIPv4() {
  auto v = localAddresses(false);
  if (!v.empty()) return v.front();
  return primaryIPv4ViaRoute();
}





// WSAStartup/WSACleanup are reference-counted, so each socket-owning component keeps one guard.
class Init {
 public:
#if defined(_WIN32)
  Init() {
    WSADATA wsd;
    ok_ = ::WSAStartup(MAKEWORD(2, 2), &wsd) == 0;
  }
  ~Init() {
    if (ok_) ::WSACleanup();
  }
#else
  Init() = default;
  ~Init() = default;
#endif
  Init(const Init&) = delete;
  Init& operator=(const Init&) = delete;

#if defined(_WIN32)
 private:
  bool ok_ = false;
#endif
};

inline void closeSocket(socket_t s) {
#if defined(_WIN32)
  ::closesocket(s);
#else
  ::close(s);
#endif
}

inline bool setNonBlock(socket_t s) {
#if defined(_WIN32)
  u_long on = 1;
  return ::ioctlsocket(s, FIONBIO, &on) == 0;
#else
  int fl = ::fcntl(s, F_GETFL, 0);
  return fl >= 0 && ::fcntl(s, F_SETFL, fl | O_NONBLOCK) == 0;
#endif
}

inline int poll(pollfd_t* fds, size_t n, int timeout_ms) {
#if defined(_WIN32)
  return ::WSAPoll(fds, static_cast<ULONG>(n), timeout_ms);
#else
  return ::poll(fds, static_cast<nfds_t>(n), timeout_ms);
#endif
}

// Measure TCP reachability and RTT without requiring ICMP privileges. A refused
// connection proves that the host is reachable, but not that the endpoint is available.
inline bool tcpProbePolicy(const std::string& host, int port, int timeout_ms, int* rtt_ms,
                           bool refused_is_reachable) {
  if (rtt_ms) *rtt_ms = -1;
  struct addrinfo hints;
  std::memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  char portstr[16];
  std::snprintf(portstr, sizeof(portstr), "%d", port);
  struct addrinfo* res = nullptr;
  if (::getaddrinfo(host.c_str(), portstr, &hints, &res) != 0 || res == nullptr) return false;
  bool reachable = false;
  auto t0 = std::chrono::steady_clock::now();
  for (struct addrinfo* p = res; p != nullptr && !reachable; p = p->ai_next) {
    socket_t fd = ::socket(p->ai_family, p->ai_socktype, p->ai_protocol);
    if (!valid(fd)) continue;
    setNonBlock(fd);
    int rc = ::connect(fd, p->ai_addr, static_cast<socklen_v>(p->ai_addrlen));
    if (rc == 0) {
      reachable = true;
    } else {
      pollfd_t pfd;
      std::memset(&pfd, 0, sizeof(pfd));
      pfd.fd = fd;
      pfd.events = POLLOUT;
      int pr = net::poll(&pfd, 1, timeout_ms);
      if (pr > 0) {
        int err = 0;
        socklen_v len = sizeof(err);
        ::getsockopt(fd, SOL_SOCKET, SO_ERROR, reinterpret_cast<char*>(&err), &len);
        if (err == 0 || (refused_is_reachable && err == ECONNREFUSED)) reachable = true;
      }
    }
    closeSocket(fd);
  }
  auto t1 = std::chrono::steady_clock::now();
  ::freeaddrinfo(res);
  if (reachable && rtt_ms)
    *rtt_ms = static_cast<int>(
        std::chrono::duration_cast<std::chrono::milliseconds>(t1 - t0).count());
  return reachable;
}

inline bool tcpProbe(const std::string& host, int port, int timeout_ms, int* rtt_ms) {
  return tcpProbePolicy(host, port, timeout_ms, rtt_ms, true);
}

// Unlike the host probe, this reports true only when the configured service accepts TCP.
inline bool tcpEndpointProbe(const std::string& host, int port, int timeout_ms, int* rtt_ms) {
  return tcpProbePolicy(host, port, timeout_ms, rtt_ms, false);
}


inline int lastError() {
#if defined(_WIN32)
  return ::WSAGetLastError();
#else
  return errno;
#endif
}


inline bool errWouldBlock(int e) {
#if defined(_WIN32)
  return e == WSAEWOULDBLOCK || e == WSAEINTR;
#else
  return e == EAGAIN || e == EWOULDBLOCK || e == EINTR;
#endif
}


inline bool errConnectInProgress(int e) {
#if defined(_WIN32)
  return e == WSAEWOULDBLOCK || e == WSAEINPROGRESS;
#else
  return e == EINPROGRESS;
#endif
}


inline int sendSome(socket_t s, const void* buf, size_t len) {
  if (len > INT_MAX) len = INT_MAX;
#if defined(_WIN32)
  return ::send(s, static_cast<const char*>(buf), static_cast<int>(len), 0);
#else
  return static_cast<int>(::send(s, buf, len, 0));
#endif
}

inline int recvSome(socket_t s, void* buf, size_t len) {
  if (len > INT_MAX) len = INT_MAX;
#if defined(_WIN32)
  return ::recv(s, static_cast<char*>(buf), static_cast<int>(len), 0);
#else
  return static_cast<int>(::recv(s, buf, len, 0));
#endif
}

inline int sendTo(socket_t s, const void* buf, size_t len, const sockaddr* addr, socklen_v alen) {
  if (len > INT_MAX) len = INT_MAX;
#if defined(_WIN32)
  return ::sendto(s, static_cast<const char*>(buf), static_cast<int>(len), 0, addr, alen);
#else
  return static_cast<int>(::sendto(s, buf, len, 0, addr, alen));
#endif
}

inline int recvFrom(socket_t s, void* buf, size_t len) {
  if (len > INT_MAX) len = INT_MAX;
#if defined(_WIN32)
  return ::recvfrom(s, static_cast<char*>(buf), static_cast<int>(len), 0, nullptr, nullptr);
#else
  return static_cast<int>(::recvfrom(s, buf, len, 0, nullptr, nullptr));
#endif
}


inline bool setSockOpt(socket_t s, int level, int opt, const void* val, socklen_v len) {
#if defined(_WIN32)
  return ::setsockopt(s, level, opt, static_cast<const char*>(val), len) == 0;
#else
  return ::setsockopt(s, level, opt, val, len) == 0;
#endif
}

inline int getSockError(socket_t s) {
  int err = 0;
  socklen_v len = sizeof(err);
#if defined(_WIN32)
  ::getsockopt(s, SOL_SOCKET, SO_ERROR, reinterpret_cast<char*>(&err), &len);
#else
  ::getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len);
#endif
  return err;
}



inline bool setReuseAddr(socket_t s) {
#if defined(_WIN32)
  (void)s;
  return true;
#else
  int yes = 1;
  return setSockOpt(s, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
#endif
}


inline bool setRecvTimeoutMs(socket_t s, int ms) {
#if defined(_WIN32)
  DWORD v = static_cast<DWORD>(ms);
  return setSockOpt(s, SOL_SOCKET, SO_RCVTIMEO, &v, sizeof(v));
#else
  timeval tv{};
  tv.tv_sec = ms / 1000;
  tv.tv_usec = (ms % 1000) * 1000;
  return setSockOpt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
#endif
}

// multicast TTL / loopback (POSIX=u_char / Windows=DWORD)
inline bool setMulticastTtl(socket_t s, int ttl) {
#if defined(_WIN32)
  DWORD v = static_cast<DWORD>(ttl);
  return setSockOpt(s, IPPROTO_IP, IP_MULTICAST_TTL, &v, sizeof(v));
#else
  unsigned char v = static_cast<unsigned char>(ttl);
  return setSockOpt(s, IPPROTO_IP, IP_MULTICAST_TTL, &v, sizeof(v));
#endif
}

inline bool setMulticastLoop(socket_t s, bool on) {
#if defined(_WIN32)
  DWORD v = on ? 1 : 0;
  return setSockOpt(s, IPPROTO_IP, IP_MULTICAST_LOOP, &v, sizeof(v));
#else
  unsigned char v = on ? 1 : 0;
  return setSockOpt(s, IPPROTO_IP, IP_MULTICAST_LOOP, &v, sizeof(v));
#endif
}




inline bool makeWakePair(socket_t out[2]) {
#if defined(_WIN32)
  out[0] = out[1] = kInvalidSocket;
  socket_t lst = ::socket(AF_INET, SOCK_STREAM, 0);
  if (!valid(lst)) return false;
  sockaddr_in a{};
  a.sin_family = AF_INET;
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  a.sin_port = 0;
  socklen_v alen = sizeof(a);
  socket_t w = kInvalidSocket, r = kInvalidSocket;
  bool ok = ::bind(lst, reinterpret_cast<sockaddr*>(&a), sizeof(a)) == 0 &&
            ::listen(lst, 1) == 0 &&
            ::getsockname(lst, reinterpret_cast<sockaddr*>(&a), &alen) == 0;
  if (ok) {
    w = ::socket(AF_INET, SOCK_STREAM, 0);
    ok = valid(w) && ::connect(w, reinterpret_cast<sockaddr*>(&a), sizeof(a)) == 0;
  }
  if (ok) {
    r = ::accept(lst, nullptr, nullptr);
    ok = valid(r);
  }
  closeSocket(lst);
  if (!ok) {
    if (valid(w)) closeSocket(w);
    if (valid(r)) closeSocket(r);
    return false;
  }
  int yes = 1;
  setSockOpt(w, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
  setNonBlock(r);
  setNonBlock(w);
  out[0] = r;
  out[1] = w;
  return true;
#else
  if (::socketpair(AF_UNIX, SOCK_STREAM, 0, out) != 0) {
    out[0] = out[1] = kInvalidSocket;
    return false;
  }
  setNonBlock(out[0]);
  setNonBlock(out[1]);
  return true;
#endif
}


inline void wakeSignal(socket_t s) {
  const char b = 'w';
  (void)sendSome(s, &b, 1);
}


inline void wakeDrain(socket_t s) {
  char buf[256];
  while (recvSome(s, buf, sizeof(buf)) > 0) {
  }
}

}  // namespace net
}  // namespace db
