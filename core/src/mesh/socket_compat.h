// ソケット API の POSIX / Winsock2 差異を閉じ込める互換層。
// 方針: 呼び出し側 (tcp_transport / udp_beacon) には #ifdef を書かせない。
//  - ハンドル型   : socket_t (POSIX=int / Windows=SOCKET) + kInvalidSocket
//  - poll         : net::poll (Windows は WSAPoll)
//  - 起床ペア     : makeWakePair (POSIX=socketpair / Windows=ループバック TCP ペア)
//  - エラー判定   : errno / WSAGetLastError() の差異は lastError() + 述語に吸収
//  - setsockopt   : Windows の char* キャストと型差 (SO_RCVTIMEO=DWORD ms 等) を吸収
// 注意 (Windows): WSAPoll は Win10 以前だと接続失敗を POLLERR で報告しないことがある。
// 呼び出し側は必ず接続デッドラインを併用すること (tcp_transport は kConnectTimeoutMs で対応済)。
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
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#endif

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
using socklen_v = int;  // sockaddr 長・オプション長 (POSIX の socklen_t 相当)
constexpr socket_t kInvalidSocket = INVALID_SOCKET;
#else
using socket_t = int;
using pollfd_t = ::pollfd;
using socklen_v = socklen_t;
constexpr socket_t kInvalidSocket = -1;
#endif

inline bool valid(socket_t s) { return s != kInvalidSocket; }

// getifaddrs は POSIX だが Android では API24+ でしか宣言されない (minSdk 21 → 不可)。
// 使える環境でだけ列挙し、他 (Windows / Android<24) はルート法へ回落する。
#if !defined(_WIN32) && !(defined(__ANDROID__) && __ANDROID_API__ < 24)
#define DB_HAVE_GETIFADDRS 1
#endif

// ルーティング経由で主 IPv4 を得る (UDP connect → getsockname)。
// パケットは飛ばさない。getifaddrs が使えない環境でも効く堅牢な方法。
inline std::string primaryIPv4ViaRoute() {
#if !defined(_WIN32)
  int fd = ::socket(AF_INET, SOCK_DGRAM, 0);
  if (fd < 0) return std::string();
  struct sockaddr_in dst;
  std::memset(&dst, 0, sizeof(dst));
  dst.sin_family = AF_INET;
  dst.sin_port = htons(9);  // discard
  ::inet_pton(AF_INET, "8.8.8.8", &dst.sin_addr);  // 既定経路の送信元 IP を解決させる
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

// 実際の非ループバック ローカルアドレスを列挙する (advertise/表示用)。
// includeV6=true で グローバル IPv6 も含める (リンクローカル fe80:: は除外)。
// getifaddrs が無い環境 (Windows / Android<24) は主 IPv4 のみをルート法で返す。
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
      if (IN6_IS_ADDR_LINKLOCAL(&s6->sin6_addr)) continue;  // fe80:: は到達性が乏しい
      if (::inet_ntop(AF_INET6, &s6->sin6_addr, buf, sizeof(buf))) out.emplace_back(buf);
    }
  }
  freeifaddrs(head);
#else
  (void)includeV6;
  std::string ip = primaryIPv4ViaRoute();  // getifaddrs 無し → 主 IPv4 のみ
  if (!ip.empty()) out.push_back(ip);
#endif
  return out;
}

// 主 IPv4。getifaddrs → 失敗ならルート法。両方失敗で空。
inline std::string primaryIPv4() {
  auto v = localAddresses(false);
  if (!v.empty()) return v.front();
  return primaryIPv4ViaRoute();
}
// (tcpProbe は closeSocket/setNonBlock/poll 定義後に置く — 下方)

// Winsock 初期化の RAII (POSIX では何もしない)。
// WSAStartup/WSACleanup は OS 側で参照カウントされるため、
// ソケットを持つオブジェクト (TcpTransport::Impl / UdpBeacon) が 1 個ずつ持てば足りる。
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

// TCP 接続で到達性 + RTT を測る (ICMP 不要 = 特権不要・全 OS で動く)。
// 接続成功 or 拒否(RST) は「到達」(host は生きている)。timeout は未到達。
// host は IPv4/IPv6 リテラルでもホスト名でも可 (getaddrinfo)。rtt_ms に往復 ms (未到達で -1)。
inline bool tcpProbe(const std::string& host, int port, int timeout_ms, int* rtt_ms) {
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
        // 接続成功(0) も 拒否(ECONNREFUSED) も「host 到達」とみなす
        if (err == 0 || err == ECONNREFUSED) reachable = true;
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

// 直前のソケット呼び出しのエラーコード (呼び出し直後に取ること)
inline int lastError() {
#if defined(_WIN32)
  return ::WSAGetLastError();
#else
  return errno;
#endif
}

// 「今は進めない、後で再試行」系 (EAGAIN/EWOULDBLOCK/EINTR 相当)
inline bool errWouldBlock(int e) {
#if defined(_WIN32)
  return e == WSAEWOULDBLOCK || e == WSAEINTR;
#else
  return e == EAGAIN || e == EWOULDBLOCK || e == EINTR;
#endif
}

// 非ブロッキング connect の「進行中」判定 (POSIX=EINPROGRESS / Winsock=WSAEWOULDBLOCK)
inline bool errConnectInProgress(int e) {
#if defined(_WIN32)
  return e == WSAEWOULDBLOCK || e == WSAEINPROGRESS;
#else
  return e == EINPROGRESS;
#endif
}

// 送受信。負値=エラー (lastError() で詳細)。len は int 上限へクランプ。
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

// setsockopt (Windows の const char* キャストを吸収)
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

// TIME_WAIT 再バインド許可。Windows では既定で再バインドできるうえ、
// SO_REUSEADDR は listen 中ポートの乗っ取りまで許してしまうため付けない。
inline bool setReuseAddr(socket_t s) {
#if defined(_WIN32)
  (void)s;
  return true;
#else
  int yes = 1;
  return setSockOpt(s, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
#endif
}

// recv タイムアウト (POSIX=timeval / Windows=DWORD ミリ秒)
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

// IO スレッド起床用ペア。out[0]=読み側 (poll 対象)、out[1]=書き側。両方 non-block。
// POSIX は socketpair、Windows は 127.0.0.1 のループバック TCP ペアで代用
// (Winsock の pipe は poll 不可のため)。
inline bool makeWakePair(socket_t out[2]) {
#if defined(_WIN32)
  out[0] = out[1] = kInvalidSocket;
  socket_t lst = ::socket(AF_INET, SOCK_STREAM, 0);
  if (!valid(lst)) return false;
  sockaddr_in a{};
  a.sin_family = AF_INET;
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  a.sin_port = 0;  // OS 任せ
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

// 起床通知 (1 byte 書く)。バッファ満杯 = 既に起床要求済みなので失敗は無視してよい。
inline void wakeSignal(socket_t s) {
  const char b = 'w';
  (void)sendSome(s, &b, 1);
}

// 起床通知の排水 (読み尽くす)
inline void wakeDrain(socket_t s) {
  char buf[256];
  while (recvSome(s, buf, sizeof(buf)) > 0) {
  }
}

}  // namespace net
}  // namespace db
