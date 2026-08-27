// TCP トランスポートの実装 (tcp_transport.h 参照)。
// 1 本の IO スレッドが poll() で listen/接続/送受信を面倒みる。self-pipe で起床。
// フレーム: [len 4B BE][payload]。コールバックはすべて Runloop へ post。
#include "mesh/tcp_transport.h"

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cerrno>
#include <cstring>
#include <deque>
#include <mutex>
#include <thread>
#include <vector>

#include "util/log.h"

namespace db {

namespace {

constexpr size_t kMaxFrame = 8 * 1024 * 1024;  // プロトコル上限 (これ超えは即切断)
constexpr int64_t kConnectTimeoutMs = 10000;

// "host:port" を分解。失敗時 false。
bool parseAddr(const std::string& addr, std::string* host, uint16_t* port) {
  size_t colon = addr.rfind(':');
  if (colon == std::string::npos || colon == 0 || colon + 1 >= addr.size()) return false;
  *host = addr.substr(0, colon);
  long p = std::strtol(addr.c_str() + colon + 1, nullptr, 10);
  if (p <= 0 || p > 65535) return false;
  *port = static_cast<uint16_t>(p);
  return true;
}

bool setNonBlock(int fd) {
  int fl = ::fcntl(fd, F_GETFL, 0);
  return fl >= 0 && ::fcntl(fd, F_SETFL, fl | O_NONBLOCK) == 0;
}

std::string peerName(int fd) {
  sockaddr_in a{};
  socklen_t len = sizeof(a);
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
  std::mutex mu;
  std::thread io;
  bool started = false;
  bool stopping = false;
  int wake_pipe[2] = {-1, -1};
  std::deque<std::function<void()>> cmds;  // IO スレッドで実行するコマンド

  int listen_fd = -1;
  std::string listen_addr;
  std::function<void(ConnPtr)> on_accept;

  struct PendingConnect {
    int fd;
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

// 1 本の TCP 接続。outbox/コールバックは Impl::mu で保護。
class TcpConn : public IConn, public std::enable_shared_from_this<TcpConn> {
 public:
  TcpConn(std::shared_ptr<TcpTransport::Impl> impl, int fd, std::string remote)
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
    closing_ = true;  // outbox を吐き切ってから IO スレッドが閉じる
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
      // コールバック設定前に閉じていた場合も通知を落とさない
      if (closed_before_cb_ && on_close_) pending_close_notify_ = true;
    }
    // 設定前に届いていたフレームを順に流す (Runloop 上で)
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

  // ---- IO スレッド側 ----

  int fd() const { return fd_; }
  bool wantWrite() {
    std::lock_guard<std::mutex> lk(impl_->mu);
    return !outbox_.empty();
  }
  bool closingAndDrained() {
    std::lock_guard<std::mutex> lk(impl_->mu);
    return closing_ && outbox_.empty();
  }

  // 送信。致命エラーで false。
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
      ssize_t n = ::send(fd_, chunk.data() + off, chunk.size() - off, 0);
      if (n < 0) return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR;
      std::lock_guard<std::mutex> lk(impl_->mu);
      out_off_ += static_cast<size_t>(n);
      if (out_off_ >= outbox_.front().size()) {
        outbox_.pop_front();
        out_off_ = 0;
      }
    }
  }

  // 受信 + フレーム切り出し。致命エラー/EOF で false。
  bool onReadable() {
    uint8_t buf[65536];
    for (;;) {
      ssize_t n = ::recv(fd_, buf, sizeof(buf), 0);
      if (n == 0) return false;  // EOF
      if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) break;
        return false;
      }
      inbuf_.insert(inbuf_.end(), buf, buf + n);
      if (static_cast<size_t>(n) < sizeof(buf)) break;
    }
    // フレーム抽出
    size_t pos = 0;
    while (inbuf_.size() - pos >= 4) {
      const uint32_t len = (uint32_t(inbuf_[pos]) << 24) | (uint32_t(inbuf_[pos + 1]) << 16) |
                           (uint32_t(inbuf_[pos + 2]) << 8) | uint32_t(inbuf_[pos + 3]);
      if (len > kMaxFrame) return false;  // 異常フレームは即切断
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
          self->pre_frames_.push_back(frame);  // setCallbacks 前 → 取り置き
          return;
        }
      }
      cb(frame);
    });
  }

  // IO スレッドが fd を閉じた後に呼ぶ (相手切断/エラー時のみ notify=true)
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
  int fd_;
  std::string remote_;
  bool open_ = true;
  bool closing_ = false;         // 自発 close (flush 後にクローズ)
  bool close_notified_ = false;
  bool closed_before_cb_ = false;
  bool pending_close_notify_ = false;
  std::deque<Bytes> outbox_;
  size_t out_off_ = 0;
  std::vector<uint8_t> inbuf_;    // IO スレッド専用
  std::vector<Bytes> pre_frames_;  // setCallbacks 前に届いたフレームの取り置き
  std::function<void(const Bytes&)> on_frame_;
  std::function<void()> on_close_;
};

// ---------------------------------------------------------------- Impl

TcpTransport::Impl::~Impl() {
  if (wake_pipe[0] >= 0) ::close(wake_pipe[0]);
  if (wake_pipe[1] >= 0) ::close(wake_pipe[1]);
}

void TcpTransport::Impl::ensureIoThread() {
  std::lock_guard<std::mutex> lk(mu);
  if (started) return;
  if (::pipe(wake_pipe) != 0) return;
  setNonBlock(wake_pipe[0]);
  setNonBlock(wake_pipe[1]);
  started = true;
  auto self = shared_from_this();
  io = std::thread([self]() { self->ioMain(); });
}

void TcpTransport::Impl::wake() {
  if (wake_pipe[1] >= 0) {
    const char b = 'w';
    (void)!::write(wake_pipe[1], &b, 1);
  }
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
    // コマンド処理
    std::deque<std::function<void()>> q;
    {
      std::lock_guard<std::mutex> lk(mu);
      q.swap(cmds);
    }
    for (auto& fn : q) fn();
    {
      std::unique_lock<std::mutex> lk(mu);
      if (stopping) {  // 全 fd を回収して終了 (markClosed は mu を取るため unlock 後に)
        const int lfd2 = listen_fd;
        listen_fd = -1;
        auto pcs = std::move(connecting);
        connecting.clear();
        auto cs = std::move(conns);
        conns.clear();
        lk.unlock();
        if (lfd2 >= 0) ::close(lfd2);
        for (auto& pc : pcs) ::close(pc.fd);
        for (auto& c : cs) {
          ::close(c->fd());
          c->markClosed(false);
        }
        return;
      }
    }

    // poll セット構築
    std::vector<pollfd> pfds;
    std::vector<std::shared_ptr<TcpConn>> pconns;
    int lfd;
    {
      std::lock_guard<std::mutex> lk(mu);
      pfds.push_back({wake_pipe[0], POLLIN, 0});
      lfd = listen_fd;
      if (lfd >= 0) pfds.push_back({lfd, POLLIN, 0});
      for (auto& pc : connecting) pfds.push_back({pc.fd, POLLOUT, 0});
      pconns = conns;
    }
    const size_t conn_base = pfds.size();
    for (auto& c : pconns) {
      short ev = POLLIN;
      if (c->wantWrite()) ev |= POLLOUT;
      pfds.push_back({c->fd(), ev, 0});
    }

    ::poll(pfds.data(), static_cast<nfds_t>(pfds.size()), 200);

    // wake pipe 排水
    if (pfds[0].revents & POLLIN) {
      char buf[256];
      while (::read(wake_pipe[0], buf, sizeof(buf)) > 0) {
      }
    }

    // accept
    size_t idx = 1;
    if (lfd >= 0) {
      if (pfds[idx].revents & POLLIN) {
        for (;;) {
          int fd = ::accept(lfd, nullptr, nullptr);
          if (fd < 0) break;
          setNonBlock(fd);
          int yes = 1;
          ::setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
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

    // 接続完了判定
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
        int err = 0;
        socklen_t len = sizeof(err);
        ::getsockopt(pc.fd, SOL_SOCKET, SO_ERROR, &err, &len);
        auto cb = pc.cb;
        if (err == 0) {
          int yes = 1;
          ::setsockopt(pc.fd, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
          auto conn = std::make_shared<TcpConn>(shared_from_this(), pc.fd, peerName(pc.fd));
          {
            std::lock_guard<std::mutex> lk(mu);
            conns.push_back(conn);
          }
          loop.post([cb, conn]() { cb(conn); });
        } else {
          ::close(pc.fd);
          loop.post([cb]() { cb(nullptr); });
        }
      } else if (now >= pc.deadline) {
        ::close(pc.fd);
        auto cb = pc.cb;
        loop.post([cb]() { cb(nullptr); });
      } else {
        std::lock_guard<std::mutex> lk(mu);
        connecting.push_back(pc);
      }
    }

    // 送受信
    for (size_t i = 0; i < pconns.size(); i++) {
      auto& c = pconns[i];
      const short rev = pfds[conn_base + i].revents;
      bool ok = true;
      if (rev & (POLLERR | POLLHUP | POLLNVAL)) ok = (rev & POLLIN) != 0;  // 読み残し優先
      if (ok && (rev & POLLIN)) ok = c->onReadable();
      if (ok && (rev & POLLOUT)) ok = c->onWritable();
      if (ok && c->closingAndDrained()) {  // 自発 close: flush 後にクローズ (通知しない)
        ::close(c->fd());
        c->markClosed(false);
        std::lock_guard<std::mutex> lk(mu);
        removeConn(c);
      } else if (!ok) {  // 相手切断/エラー
        ::close(c->fd());
        c->markClosed(true);
        std::lock_guard<std::mutex> lk(mu);
        removeConn(c);
      }
    }
  }
}

// ---------------------------------------------------------------- 公開 API

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
  int fd = ::socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return false;
  int yes = 1;
  ::setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
  sockaddr_in a{};
  a.sin_family = AF_INET;
  a.sin_port = htons(port);
  if (::inet_pton(AF_INET, host.c_str(), &a.sin_addr) != 1) {
    a.sin_addr.s_addr = htonl(INADDR_ANY);
  }
  if (::bind(fd, reinterpret_cast<sockaddr*>(&a), sizeof(a)) != 0 || ::listen(fd, 16) != 0) {
    ::close(fd);
    return false;
  }
  setNonBlock(fd);
  {
    std::lock_guard<std::mutex> lk(impl_->mu);
    if (impl_->listen_fd >= 0) {
      ::close(fd);
      return false;  // 二重 listen
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
    if (impl->listen_fd >= 0) {
      ::close(impl->listen_fd);
      impl->listen_fd = -1;
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
    int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
      impl->loop.post([cb]() { cb(nullptr); });
      return;
    }
    setNonBlock(fd);
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    if (::inet_pton(AF_INET, host.c_str(), &a.sin_addr) != 1) {
      ::close(fd);
      impl->loop.post([cb]() { cb(nullptr); });
      return;
    }
    int r = ::connect(fd, reinterpret_cast<sockaddr*>(&a), sizeof(a));
    if (r == 0 || errno == EINPROGRESS) {
      std::lock_guard<std::mutex> lk(impl->mu);
      impl->connecting.push_back({fd, cb, steadyMs() + kConnectTimeoutMs});
    } else {
      ::close(fd);
      impl->loop.post([cb]() { cb(nullptr); });
    }
  });
}

std::string TcpTransport::listenAddr() const {
  std::lock_guard<std::mutex> lk(impl_->mu);
  return impl_->listen_addr;
}

}  // namespace db
