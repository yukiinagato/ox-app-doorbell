



#include "mesh/tcp_transport.h"

#include <algorithm>
#include <cstring>
#include <deque>
#include <mutex>
#include <thread>
#include <vector>

#include "mesh/socket_compat.h"
#include "util/log.h"

namespace db {

namespace {

constexpr size_t kMaxFrame = 8 * 1024 * 1024;
constexpr int64_t kConnectTimeoutMs = 10000;


bool parseAddr(const std::string& addr, std::string* host, uint16_t* port) {
  size_t colon = addr.rfind(':');
  if (colon == std::string::npos || colon == 0 || colon + 1 >= addr.size()) return false;
  *host = addr.substr(0, colon);
  long p = std::strtol(addr.c_str() + colon + 1, nullptr, 10);
  if (p <= 0 || p > 65535) return false;
  *port = static_cast<uint16_t>(p);
  return true;
}

std::string peerName(net::socket_t fd) {
  sockaddr_in a{};
  net::socklen_v len = sizeof(a);
  if (::getpeername(fd, reinterpret_cast<sockaddr*>(&a), &len) != 0) return "";
  char buf[64];
  ::inet_ntop(AF_INET, &a.sin_addr, buf, sizeof(buf));
  return std::string(buf) + ":" + std::to_string(ntohs(a.sin_port));
}

int64_t steadyMs() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

}  // namespace

class TcpConn;

struct TcpTransport::Impl : public std::enable_shared_from_this<TcpTransport::Impl> {
  Runloop& loop;
  net::Init winsock;
  std::mutex mu;
  std::thread io;
  bool started = false;
  bool stopping = false;
  net::socket_t wake_pipe[2] = {net::kInvalidSocket, net::kInvalidSocket};
  std::deque<std::function<void()>> cmds;

  net::socket_t listen_fd = net::kInvalidSocket;
  std::string listen_addr;
  std::function<void(ConnPtr)> on_accept;

  struct PendingConnect {
    net::socket_t fd;
    std::function<void(ConnPtr)> cb;
    int64_t deadline;
  };
  std::vector<PendingConnect> connecting;
  std::vector<std::shared_ptr<TcpConn>> conns;

  explicit Impl(Runloop& l) : loop(l) {}
  ~Impl();

  void ensureIoThread();
  void wake();
  void postCmd(std::function<void()> fn);
  void ioMain();
  void removeConn(const std::shared_ptr<TcpConn>& c);
};


class TcpConn : public IConn, public std::enable_shared_from_this<TcpConn> {
 public:
  TcpConn(std::shared_ptr<TcpTransport::Impl> impl, net::socket_t fd, std::string remote)
      : impl_(std::move(impl)), fd_(fd), remote_(std::move(remote)) {}

  void send(const Bytes& frame) override {
    std::lock_guard<std::mutex> lk(impl_->mu);
    if (!open_ || closing_) return;
    Bytes framed(4 + frame.size());
    const uint32_t n = static_cast<uint32_t>(frame.size());
    framed[0] = static_cast<uint8_t>(n >> 24);
    framed[1] = static_cast<uint8_t>(n >> 16);
    framed[2] = static_cast<uint8_t>(n >> 8);
    framed[3] = static_cast<uint8_t>(n);
    std::memcpy(framed.data() + 4, frame.data(), frame.size());
    outbox_.push_back(std::move(framed));
    impl_->wake();
  }

  void close() override {
    std::lock_guard<std::mutex> lk(impl_->mu);
    if (!open_ || closing_) return;
    closing_ = true;
    impl_->wake();
  }

  std::string remoteAddr() const override { return remote_; }

  void setCallbacks(std::function<void(const Bytes&)> on_frame,
                    std::function<void()> on_close) override {
    std::vector<Bytes> backlog;
    {
      std::lock_guard<std::mutex> lk(impl_->mu);
      on_frame_ = std::move(on_frame);
      on_close_ = std::move(on_close);
      backlog.swap(pre_frames_);

      if (closed_before_cb_ && on_close_) pending_close_notify_ = true;
    }

    auto self = shared_from_this();
    if (!backlog.empty() || pending_close_notify_) {
      impl_->loop.post([self, backlog]() {
        for (const auto& f : backlog) {
          std::function<void(const Bytes&)> cb;
          {
            std::lock_guard<std::mutex> lk(self->impl_->mu);
            cb = self->on_frame_;
          }
          if (cb) cb(f);
        }
        if (self->pending_close_notify_) {
          self->pending_close_notify_ = false;
          self->notifyClose();
        }
      });
    }
  }



  net::socket_t fd() const { return fd_; }
  bool wantWrite() {
    std::lock_guard<std::mutex> lk(impl_->mu);
    return !outbox_.empty();
  }
  bool closingAndDrained() {
    std::lock_guard<std::mutex> lk(impl_->mu);
    return closing_ && outbox_.empty();
  }


  bool onWritable() {
    for (;;) {
      Bytes chunk;
      size_t off;
      {
        std::lock_guard<std::mutex> lk(impl_->mu);
        if (outbox_.empty()) return true;
        chunk = outbox_.front();
        off = out_off_;
      }
      int n = net::sendSome(fd_, chunk.data() + off, chunk.size() - off);
      if (n < 0) return net::errWouldBlock(net::lastError());
      std::lock_guard<std::mutex> lk(impl_->mu);
      out_off_ += static_cast<size_t>(n);
      if (out_off_ >= outbox_.front().size()) {
        outbox_.pop_front();
        out_off_ = 0;
      }
    }
  }


  bool onReadable() {
    uint8_t buf[65536];
    for (;;) {
      int n = net::recvSome(fd_, buf, sizeof(buf));
      if (n == 0) return false;  // EOF
      if (n < 0) {
        if (net::errWouldBlock(net::lastError())) break;
        return false;
      }
      inbuf_.insert(inbuf_.end(), buf, buf + n);
      if (static_cast<size_t>(n) < sizeof(buf)) break;
    }

    size_t pos = 0;
    while (inbuf_.size() - pos >= 4) {
      const uint32_t len = (uint32_t(inbuf_[pos]) << 24) | (uint32_t(inbuf_[pos + 1]) << 16) |
                           (uint32_t(inbuf_[pos + 2]) << 8) | uint32_t(inbuf_[pos + 3]);
      if (len > kMaxFrame) return false;
      if (inbuf_.size() - pos - 4 < len) break;
      Bytes frame(inbuf_.begin() + pos + 4, inbuf_.begin() + pos + 4 + len);
      deliver(std::move(frame));
      pos += 4 + len;
    }
    inbuf_.erase(inbuf_.begin(), inbuf_.begin() + pos);
    return true;
  }

  void deliver(Bytes frame) {
    auto self = shared_from_this();
    impl_->loop.post([self, frame]() {
      std::function<void(const Bytes&)> cb;
      {
        std::lock_guard<std::mutex> lk(self->impl_->mu);
        cb = self->on_frame_;
        if (!cb) {
          self->pre_frames_.push_back(frame);
          return;
        }
      }
      cb(frame);
    });
  }


  void markClosed(bool notify) {
    bool had_cb;
    {
      std::lock_guard<std::mutex> lk(impl_->mu);
      open_ = false;
      had_cb = static_cast<bool>(on_close_);
      if (notify && !had_cb) closed_before_cb_ = true;
    }
    if (notify && had_cb) {
      auto self = shared_from_this();
      impl_->loop.post([self]() { self->notifyClose(); });
    }
  }

  void notifyClose() {
    std::function<void()> cb;
    {
      std::lock_guard<std::mutex> lk(impl_->mu);
      if (close_notified_) return;
      close_notified_ = true;
      cb = on_close_;
    }
    if (cb) cb();
  }

 private:
  friend struct TcpTransport::Impl;
  std::shared_ptr<TcpTransport::Impl> impl_;
  net::socket_t fd_;
  std::string remote_;
  bool open_ = true;
  bool closing_ = false;
  bool close_notified_ = false;
  bool closed_before_cb_ = false;
  bool pending_close_notify_ = false;
  std::deque<Bytes> outbox_;
  size_t out_off_ = 0;
  std::vector<uint8_t> inbuf_;
  std::vector<Bytes> pre_frames_;
  std::function<void(const Bytes&)> on_frame_;
  std::function<void()> on_close_;
};

// ---------------------------------------------------------------- Impl

TcpTransport::Impl::~Impl() {
  if (net::valid(wake_pipe[0])) net::closeSocket(wake_pipe[0]);
  if (net::valid(wake_pipe[1])) net::closeSocket(wake_pipe[1]);
}

void TcpTransport::Impl::ensureIoThread() {
  std::lock_guard<std::mutex> lk(mu);
  if (started) return;
  if (!net::makeWakePair(wake_pipe)) return;
  started = true;
  auto self = shared_from_this();
  io = std::thread([self]() { self->ioMain(); });
}

void TcpTransport::Impl::wake() {
  if (net::valid(wake_pipe[1])) net::wakeSignal(wake_pipe[1]);
}

void TcpTransport::Impl::postCmd(std::function<void()> fn) {
  {
    std::lock_guard<std::mutex> lk(mu);
    cmds.push_back(std::move(fn));
  }
  wake();
}

void TcpTransport::Impl::removeConn(const std::shared_ptr<TcpConn>& c) {
  conns.erase(std::remove(conns.begin(), conns.end(), c), conns.end());
}

void TcpTransport::Impl::ioMain() {
  for (;;) {

    std::deque<std::function<void()>> q;
    {
      std::lock_guard<std::mutex> lk(mu);
      q.swap(cmds);
    }
    for (auto& fn : q) fn();
    {
      std::unique_lock<std::mutex> lk(mu);
      if (stopping) {
        const net::socket_t lfd2 = listen_fd;
        listen_fd = net::kInvalidSocket;
        auto pcs = std::move(connecting);
        connecting.clear();
        auto cs = std::move(conns);
        conns.clear();
        lk.unlock();
        if (net::valid(lfd2)) net::closeSocket(lfd2);
        for (auto& pc : pcs) net::closeSocket(pc.fd);
        for (auto& c : cs) {
          net::closeSocket(c->fd());
          c->markClosed(false);
        }
        return;
      }
    }


    std::vector<net::pollfd_t> pfds;
    std::vector<std::shared_ptr<TcpConn>> pconns;
    net::socket_t lfd;
    {
      std::lock_guard<std::mutex> lk(mu);
      pfds.push_back({wake_pipe[0], POLLIN, 0});
      lfd = listen_fd;
      if (net::valid(lfd)) pfds.push_back({lfd, POLLIN, 0});
      for (auto& pc : connecting) pfds.push_back({pc.fd, POLLOUT, 0});
      pconns = conns;
    }
    const size_t conn_base = pfds.size();
    for (auto& c : pconns) {
      short ev = POLLIN;
      if (c->wantWrite()) ev |= POLLOUT;
      pfds.push_back({c->fd(), ev, 0});
    }

    net::poll(pfds.data(), pfds.size(), 200);


    if (pfds[0].revents & POLLIN) net::wakeDrain(wake_pipe[0]);

    // accept
    size_t idx = 1;
    if (net::valid(lfd)) {
      if (pfds[idx].revents & POLLIN) {
        for (;;) {
          net::socket_t fd = ::accept(lfd, nullptr, nullptr);
          if (!net::valid(fd)) break;
          net::setNonBlock(fd);
          int yes = 1;
          net::setSockOpt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
          auto conn = std::make_shared<TcpConn>(shared_from_this(), fd, peerName(fd));
          std::function<void(ConnPtr)> cb;
          {
            std::lock_guard<std::mutex> lk(mu);
            conns.push_back(conn);
            cb = on_accept;
          }
          if (cb) loop.post([cb, conn]() { cb(conn); });
        }
      }
      idx++;
    }


    std::vector<PendingConnect> pcs;
    {
      std::lock_guard<std::mutex> lk(mu);
      pcs.swap(connecting);
    }
    const int64_t now = steadyMs();
    for (auto& pc : pcs) {
      bool writable = false;
      for (size_t i = idx; i < conn_base; i++) {
        if (pfds[i].fd == pc.fd && (pfds[i].revents & (POLLOUT | POLLERR | POLLHUP))) {
          writable = true;
          break;
        }
      }
      if (writable) {
        const int err = net::getSockError(pc.fd);
        auto cb = pc.cb;
        if (err == 0) {
          int yes = 1;
          net::setSockOpt(pc.fd, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
          auto conn = std::make_shared<TcpConn>(shared_from_this(), pc.fd, peerName(pc.fd));
          {
            std::lock_guard<std::mutex> lk(mu);
            conns.push_back(conn);
          }
          loop.post([cb, conn]() { cb(conn); });
        } else {
          net::closeSocket(pc.fd);
          loop.post([cb]() { cb(nullptr); });
        }
      } else if (now >= pc.deadline) {
        net::closeSocket(pc.fd);
        auto cb = pc.cb;
        loop.post([cb]() { cb(nullptr); });
      } else {
        std::lock_guard<std::mutex> lk(mu);
        connecting.push_back(pc);
      }
    }


    for (size_t i = 0; i < pconns.size(); i++) {
      auto& c = pconns[i];
      const short rev = pfds[conn_base + i].revents;
      bool ok = true;
      if (rev & (POLLERR | POLLHUP | POLLNVAL)) ok = (rev & POLLIN) != 0;
      if (ok && (rev & POLLIN)) ok = c->onReadable();
      if (ok && (rev & POLLOUT)) ok = c->onWritable();
      if (ok && c->closingAndDrained()) {
        net::closeSocket(c->fd());
        c->markClosed(false);
        std::lock_guard<std::mutex> lk(mu);
        removeConn(c);
      } else if (!ok) {
        net::closeSocket(c->fd());
        c->markClosed(true);
        std::lock_guard<std::mutex> lk(mu);
        removeConn(c);
      }
    }
  }
}



TcpTransport::TcpTransport(Runloop& loop) : impl_(std::make_shared<Impl>(loop)) {}

TcpTransport::~TcpTransport() {
  {
    std::lock_guard<std::mutex> lk(impl_->mu);
    impl_->stopping = true;
  }
  impl_->wake();
  if (impl_->io.joinable()) impl_->io.join();
}

bool TcpTransport::listen(const std::string& addr, std::function<void(ConnPtr)> on_accept) {
  std::string host;
  uint16_t port = 0;
  if (!parseAddr(addr, &host, &port)) return false;
  net::socket_t fd = ::socket(AF_INET, SOCK_STREAM, 0);
  if (!net::valid(fd)) return false;
  net::setReuseAddr(fd);
  sockaddr_in a{};
  a.sin_family = AF_INET;
  a.sin_port = htons(port);
  if (::inet_pton(AF_INET, host.c_str(), &a.sin_addr) != 1) {
    a.sin_addr.s_addr = htonl(INADDR_ANY);
  }
  if (::bind(fd, reinterpret_cast<sockaddr*>(&a), sizeof(a)) != 0 || ::listen(fd, 16) != 0) {
    net::closeSocket(fd);
    return false;
  }
  net::setNonBlock(fd);
  {
    std::lock_guard<std::mutex> lk(impl_->mu);
    if (net::valid(impl_->listen_fd)) {
      net::closeSocket(fd);
      return false;
    }
    impl_->listen_fd = fd;
    impl_->listen_addr = addr;
    impl_->on_accept = std::move(on_accept);
  }
  impl_->ensureIoThread();
  impl_->wake();
  return true;
}

void TcpTransport::stopListening() {
  auto impl = impl_;
  impl->postCmd([impl]() {
    std::lock_guard<std::mutex> lk(impl->mu);
    if (net::valid(impl->listen_fd)) {
      net::closeSocket(impl->listen_fd);
      impl->listen_fd = net::kInvalidSocket;
    }
    impl->on_accept = nullptr;
  });
}

void TcpTransport::connect(const std::string& addr, std::function<void(ConnPtr)> cb) {
  std::string host;
  uint16_t port = 0;
  if (!parseAddr(addr, &host, &port)) {
    impl_->loop.post([cb]() { cb(nullptr); });
    return;
  }
  impl_->ensureIoThread();
  auto impl = impl_;
  impl->postCmd([impl, host, port, cb]() {
    net::socket_t fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (!net::valid(fd)) {
      impl->loop.post([cb]() { cb(nullptr); });
      return;
    }
    net::setNonBlock(fd);
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    if (::inet_pton(AF_INET, host.c_str(), &a.sin_addr) != 1) {
      net::closeSocket(fd);
      impl->loop.post([cb]() { cb(nullptr); });
      return;
    }
    int r = ::connect(fd, reinterpret_cast<sockaddr*>(&a), sizeof(a));
    if (r == 0 || net::errConnectInProgress(net::lastError())) {
      std::lock_guard<std::mutex> lk(impl->mu);
      impl->connecting.push_back({fd, cb, steadyMs() + kConnectTimeoutMs});
    } else {
      net::closeSocket(fd);
      impl->loop.post([cb]() { cb(nullptr); });
    }
  });
}

std::string TcpTransport::listenAddr() const {
  std::lock_guard<std::mutex> lk(impl_->mu);
  return impl_->listen_addr;
}

}  // namespace db
