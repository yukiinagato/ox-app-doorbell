// MQTT 3.1.1 クライアントの実装 (mqtt_client.h 参照)。
// 1 本の IO スレッドが 接続→CONNECT/CONNACK→送受信ポンプ→(切断)→バックオフ→再接続 を回す。
// 起床は wake ペア (socket_compat)。コールバックは shared Impl 経由で Runloop へ post し、
// 実行時に mutex 下で読み直す — stop() 後に届く残りは無害な no-op になる。
#include "bridge/mqtt_client.h"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <deque>
#include <mutex>
#include <thread>

#include "mesh/socket_compat.h"
#include "util/log.h"

#if !defined(_WIN32)
#include <netdb.h>  // getaddrinfo (Windows は ws2tcpip.h が提供)
#endif

namespace db {

namespace mqtt {

namespace {
void putU16(Bytes& b, uint16_t v) {
  b.push_back(static_cast<uint8_t>(v >> 8));
  b.push_back(static_cast<uint8_t>(v & 0xff));
}

void putStr(Bytes& b, const std::string& s) {
  putU16(b, static_cast<uint16_t>(s.size()));
  b.insert(b.end(), s.begin(), s.end());
}

// 固定ヘッダ (1B + remaining length) を前置
Bytes withHeader(uint8_t first_byte, const Bytes& body) {
  Bytes out;
  uint8_t rl[4];
  size_t n = encodeRemainingLength(static_cast<uint32_t>(body.size()), rl);
  out.reserve(1 + n + body.size());
  out.push_back(first_byte);
  out.insert(out.end(), rl, rl + n);
  out.insert(out.end(), body.begin(), body.end());
  return out;
}

// 長さ前置 UTF-8 文字列の読み出し
bool readStr(const Bytes& b, size_t* pos, std::string* out) {
  if (b.size() < *pos + 2) return false;
  const size_t n = (static_cast<size_t>(b[*pos]) << 8) | b[*pos + 1];
  if (b.size() < *pos + 2 + n) return false;
  out->assign(b.begin() + *pos + 2, b.begin() + *pos + 2 + n);
  *pos += 2 + n;
  return true;
}
}  // namespace

size_t encodeRemainingLength(uint32_t len, uint8_t out[4]) {
  if (len > 268435455u) return 0;
  size_t i = 0;
  do {
    uint8_t d = static_cast<uint8_t>(len % 128);
    len /= 128;
    if (len) d |= 0x80;
    out[i++] = d;
  } while (len && i < 4);
  return i;
}

int decodeRemainingLength(const uint8_t* data, size_t len, uint32_t* value, size_t* used) {
  uint32_t mult = 1, v = 0;
  for (size_t i = 0; i < 4; i++) {
    if (i >= len) return 0;  // データ不足
    v += static_cast<uint32_t>(data[i] & 0x7f) * mult;
    if (!(data[i] & 0x80)) {
      *value = v;
      *used = i + 1;
      return 1;
    }
    mult *= 128;
  }
  return -1;  // 4 バイト目にも継続ビット = 不正
}

Bytes encodeConnect(const ConnectOpts& o) {
  Bytes b;
  putStr(b, "MQTT");
  b.push_back(4);  // protocol level 4 = 3.1.1
  uint8_t flags = 0;
  if (o.clean_session) flags |= 0x02;
  if (!o.will_topic.empty()) {
    flags |= 0x04;  // will flag (QoS0)
    if (o.will_retain) flags |= 0x20;
  }
  if (!o.username.empty()) {
    flags |= 0x80;
    if (!o.password.empty()) flags |= 0x40;
  }
  b.push_back(flags);
  putU16(b, o.keepalive_s);
  putStr(b, o.client_id);
  if (!o.will_topic.empty()) {
    putStr(b, o.will_topic);
    putStr(b, o.will_payload);
  }
  if (!o.username.empty()) {
    putStr(b, o.username);
    if (!o.password.empty()) putStr(b, o.password);
  }
  return withHeader(0x10, b);
}

Bytes encodePublish(const std::string& topic, const std::string& payload, bool retain) {
  Bytes b;
  putStr(b, topic);
  // QoS0 なので packet id なし — 直後が payload
  b.insert(b.end(), payload.begin(), payload.end());
  return withHeader(static_cast<uint8_t>(0x30 | (retain ? 0x01 : 0x00)), b);
}

Bytes encodeSubscribe(uint16_t packet_id, const std::vector<std::string>& filters) {
  Bytes b;
  putU16(b, packet_id);
  for (const auto& f : filters) {
    putStr(b, f);
    b.push_back(0);  // requested QoS 0
  }
  return withHeader(0x82, b);  // 予約ビット 0b0010 必須
}

Bytes encodePingReq() { return Bytes{0xC0, 0x00}; }
Bytes encodeDisconnect() { return Bytes{0xE0, 0x00}; }

int decodePacket(const uint8_t* data, size_t len, Packet* out) {
  if (len < 2) return 0;
  uint32_t rl = 0;
  size_t rl_used = 0;
  int r = decodeRemainingLength(data + 1, len - 1, &rl, &rl_used);
  if (r <= 0) return r;
  const size_t total = 1 + rl_used + rl;
  if (len < total) return 0;
  out->type = data[0] >> 4;
  out->flags = data[0] & 0x0f;
  out->body.assign(data + 1 + rl_used, data + total);
  return static_cast<int>(total);
}

bool parseConnack(const Packet& p, uint8_t* return_code) {
  if (p.type != kConnack || p.body.size() < 2) return false;
  *return_code = p.body[1];
  return true;
}

bool parsePublish(const Packet& p, std::string* topic, std::string* payload, bool* retain) {
  if (p.type != kPublish) return false;
  size_t pos = 0;
  if (!readStr(p.body, &pos, topic)) return false;
  const uint8_t qos = (p.flags >> 1) & 0x3;
  if (qos > 0) {  // packet id (本実装は QoS0 購読のみだが受信は寛容に)
    if (p.body.size() < pos + 2) return false;
    pos += 2;
  }
  payload->assign(p.body.begin() + pos, p.body.end());
  *retain = (p.flags & 0x01) != 0;
  return true;
}

}  // namespace mqtt

// ---------------------------------------------------------------- MqttClient

namespace {
constexpr const char* kTag = "mqtt";
constexpr int64_t kConnectTimeoutMs = 10000;
constexpr int64_t kStopFlushMs = 1000;                      // stop 時の送信残フラッシュ上限
constexpr int64_t kBackoffMs[] = {2000, 5000, 15000, 30000};  // 再接続バックオフ (cap 30s)

int64_t steadyMs() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}
}  // namespace

struct MqttClient::Impl : public std::enable_shared_from_this<MqttClient::Impl> {
  Runloop& loop;
  net::Init winsock;  // Winsock 参照 (POSIX では no-op)
  const Options opts;

  std::mutex mu;
  Callbacks cbs;
  std::thread io;
  bool started = false;
  bool stop_req = false;   // graceful (DISCONNECT を送る)
  bool abort_req = false;  // テスト用即断 (LWT を飛ばす)
  bool is_connected = false;
  std::deque<Bytes> outbox;
  uint16_t next_packet_id = 1;
  net::socket_t wake[2] = {net::kInvalidSocket, net::kInvalidSocket};

  Impl(Runloop& l, Options o, Callbacks c) : loop(l), opts(std::move(o)), cbs(std::move(c)) {}
  ~Impl() {
    if (net::valid(wake[0])) net::closeSocket(wake[0]);
    if (net::valid(wake[1])) net::closeSocket(wake[1]);
  }

  bool stopping() {
    std::lock_guard<std::mutex> lk(mu);
    return stop_req || abort_req;
  }

  void wakeIo() {
    if (net::valid(wake[1])) net::wakeSignal(wake[1]);
  }

  // ---------- Runloop への配送 (実行時に mutex 下でコールバックを読み直す) ----------
  void postConnected() {
    auto self = shared_from_this();
    loop.post([self] {
      std::function<void()> cb;
      {
        std::lock_guard<std::mutex> lk(self->mu);
        cb = self->cbs.on_connected;
      }
      if (cb) cb();
    });
  }

  void postDisconnected() {
    auto self = shared_from_this();
    loop.post([self] {
      std::function<void()> cb;
      {
        std::lock_guard<std::mutex> lk(self->mu);
        cb = self->cbs.on_disconnected;
      }
      if (cb) cb();
    });
  }

  void postMessage(std::string topic, std::string payload, bool retain) {
    auto self = shared_from_this();
    loop.post([self, topic, payload, retain] {
      std::function<void(const std::string&, const std::string&, bool)> cb;
      {
        std::lock_guard<std::mutex> lk(self->mu);
        cb = self->cbs.on_message;
      }
      if (cb) cb(topic, payload, retain);
    });
  }

  // ---------- IO スレッド ----------
  // バックオフ待ち。wake で中断可。stop/abort が来たら false。
  bool sleepBackoff(int64_t ms) {
    const int64_t deadline = steadyMs() + ms;
    for (;;) {
      if (stopping()) return false;
      const int64_t left = deadline - steadyMs();
      if (left <= 0) return true;
      net::pollfd_t fds[1] = {{wake[0], POLLIN, 0}};
      net::poll(fds, 1, static_cast<int>(std::min<int64_t>(left, 200)));
      if (fds[0].revents & POLLIN) net::wakeDrain(wake[0]);
    }
  }

  // TCP 接続 (名前解決 + 非ブロッキング connect + デッドライン)。失敗は kInvalidSocket。
  net::socket_t connectTcp() {
    sockaddr_in sa{};
    sa.sin_family = AF_INET;
    sa.sin_port = htons(opts.port);
    if (::inet_pton(AF_INET, opts.host.c_str(), &sa.sin_addr) != 1) {
      addrinfo hints{};
      hints.ai_family = AF_INET;
      hints.ai_socktype = SOCK_STREAM;
      addrinfo* res = nullptr;
      if (::getaddrinfo(opts.host.c_str(), nullptr, &hints, &res) != 0 || !res) {
        DB_LOGW(kTag, "名前解決失敗: " + opts.host);
        return net::kInvalidSocket;
      }
      sa.sin_addr = reinterpret_cast<sockaddr_in*>(res->ai_addr)->sin_addr;
      ::freeaddrinfo(res);
    }
    net::socket_t fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (!net::valid(fd)) return net::kInvalidSocket;
    net::setNonBlock(fd);
    int r = ::connect(fd, reinterpret_cast<sockaddr*>(&sa), sizeof(sa));
    if (r != 0 && !net::errConnectInProgress(net::lastError())) {
      net::closeSocket(fd);
      return net::kInvalidSocket;
    }
    const int64_t deadline = steadyMs() + kConnectTimeoutMs;
    for (;;) {
      if (stopping() || steadyMs() >= deadline) {
        net::closeSocket(fd);
        return net::kInvalidSocket;
      }
      net::pollfd_t fds[2] = {{wake[0], POLLIN, 0}, {fd, POLLOUT, 0}};
      net::poll(fds, 2, 200);
      if (fds[0].revents & POLLIN) net::wakeDrain(wake[0]);
      if (fds[1].revents & (POLLOUT | POLLERR | POLLHUP)) {
        if (net::getSockError(fd) == 0) {
          int yes = 1;
          net::setSockOpt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
          return fd;
        }
        net::closeSocket(fd);
        return net::kInvalidSocket;
      }
    }
  }

  // 全量送信 (デッドライン付き)。stop/abort でも CONNECT/DISCONNECT のため送り切りを試みる。
  bool sendAll(net::socket_t fd, const Bytes& data, int64_t deadline) {
    size_t off = 0;
    while (off < data.size()) {
      if (steadyMs() >= deadline) return false;
      int n = net::sendSome(fd, data.data() + off, data.size() - off);
      if (n > 0) {
        off += static_cast<size_t>(n);
        continue;
      }
      if (n < 0 && !net::errWouldBlock(net::lastError())) return false;
      net::pollfd_t fds[1] = {{fd, POLLOUT, 0}};
      net::poll(fds, 1, 100);
    }
    return true;
  }

  // パケット 1 個受信 (デッドライン付き)。inbuf は接続ローカルの受信バッファ。
  bool readPacket(net::socket_t fd, std::vector<uint8_t>* inbuf, mqtt::Packet* out,
                  int64_t deadline) {
    for (;;) {
      int used = mqtt::decodePacket(inbuf->data(), inbuf->size(), out);
      if (used < 0) return false;
      if (used > 0) {
        inbuf->erase(inbuf->begin(), inbuf->begin() + used);
        return true;
      }
      if (stopping() || steadyMs() >= deadline) return false;
      net::pollfd_t fds[2] = {{wake[0], POLLIN, 0}, {fd, POLLIN, 0}};
      net::poll(fds, 2, 200);
      if (fds[0].revents & POLLIN) net::wakeDrain(wake[0]);
      if (!(fds[1].revents & (POLLIN | POLLERR | POLLHUP))) continue;
      uint8_t buf[4096];
      int n = net::recvSome(fd, buf, sizeof(buf));
      if (n == 0) return false;  // EOF
      if (n < 0) {
        if (net::errWouldBlock(net::lastError())) continue;
        return false;
      }
      inbuf->insert(inbuf->end(), buf, buf + n);
    }
  }

  // CONNECT → CONNACK。true = 受理。
  bool mqttHandshake(net::socket_t fd, std::vector<uint8_t>* inbuf) {
    mqtt::ConnectOpts co;
    co.client_id = opts.client_id;
    co.username = opts.username;
    co.password = opts.password;
    co.keepalive_s = opts.keepalive_s;
    co.will_topic = opts.will_topic;
    co.will_payload = opts.will_payload;
    co.will_retain = opts.will_retain;
    const int64_t deadline = steadyMs() + kConnectTimeoutMs;
    if (!sendAll(fd, mqtt::encodeConnect(co), deadline)) return false;
    mqtt::Packet p;
    if (!readPacket(fd, inbuf, &p, deadline)) return false;
    uint8_t rc = 0xff;
    if (!mqtt::parseConnack(p, &rc) || rc != 0) {
      DB_LOGW(kTag, "CONNACK 拒否 rc=" + std::to_string(rc));
      return false;
    }
    return true;
  }

  void handlePacket(const mqtt::Packet& p) {
    if (p.type == mqtt::kPublish) {
      std::string topic, payload;
      bool retain = false;
      if (mqtt::parsePublish(p, &topic, &payload, &retain)) postMessage(topic, payload, retain);
    }
    // PINGRESP/SUBACK は受信時刻の更新 (pump 側) だけで十分
  }

  // outbox を書けるだけ書く。致命エラーで false。*wrote = 1 バイトでも書けたか。
  bool flushSome(net::socket_t fd, bool* wrote) {
    for (;;) {
      Bytes chunk;
      size_t off;
      {
        std::lock_guard<std::mutex> lk(mu);
        if (outbox.empty()) return true;
        chunk = outbox.front();
        off = out_off;
      }
      int n = net::sendSome(fd, chunk.data() + off, chunk.size() - off);
      if (n < 0) return net::errWouldBlock(net::lastError());
      *wrote = true;
      std::lock_guard<std::mutex> lk(mu);
      out_off += static_cast<size_t>(n);
      if (out_off >= outbox.front().size()) {
        outbox.pop_front();
        out_off = 0;
      }
    }
  }
  size_t out_off = 0;  // outbox 先頭の送信済みオフセット (IO スレッドのみ)

  // 接続確立後の送受信ポンプ。戻り値: true = エラー/EOF による切断 (再接続へ)、
  // false = stop/abort による終了。fd はこの中で必ず閉じる。
  bool pump(net::socket_t fd, std::vector<uint8_t>* inbuf) {
    const int64_t ka_ms = static_cast<int64_t>(opts.keepalive_s) * 1000;
    int64_t last_send = steadyMs(), last_recv = last_send, last_ping = 0;
    for (;;) {
      {
        std::lock_guard<std::mutex> lk(mu);
        if (abort_req) {  // テスト用即断 — DISCONNECT を送らない = ブローカーが LWT を発火
          net::closeSocket(fd);
          return false;
        }
        if (stop_req) {
          outbox.push_back(mqtt::encodeDisconnect());
        }
      }
      if (stopping()) {  // graceful: 送信残 (+DISCONNECT) を吐き切ってから閉じる
        const int64_t deadline = steadyMs() + kStopFlushMs;
        bool wrote = false;
        while (steadyMs() < deadline) {
          if (!flushSome(fd, &wrote)) break;
          {
            std::lock_guard<std::mutex> lk(mu);
            if (outbox.empty()) break;
          }
          net::pollfd_t fds[1] = {{fd, POLLOUT, 0}};
          net::poll(fds, 1, 100);
        }
        net::closeSocket(fd);
        return false;
      }

      bool want_write;
      {
        std::lock_guard<std::mutex> lk(mu);
        want_write = !outbox.empty();
      }
      net::pollfd_t fds[2] = {{wake[0], POLLIN, 0},
                              {fd, static_cast<short>(POLLIN | (want_write ? POLLOUT : 0)), 0}};
      net::poll(fds, 2, 200);
      if (fds[0].revents & POLLIN) net::wakeDrain(wake[0]);
      const int64_t now = steadyMs();
      const short rev = fds[1].revents;
      if ((rev & (POLLERR | POLLHUP | POLLNVAL)) && !(rev & POLLIN)) {
        net::closeSocket(fd);
        return true;
      }
      if (rev & POLLIN) {
        uint8_t buf[65536];
        for (;;) {
          int n = net::recvSome(fd, buf, sizeof(buf));
          if (n == 0) {  // EOF
            net::closeSocket(fd);
            return true;
          }
          if (n < 0) {
            if (net::errWouldBlock(net::lastError())) break;
            net::closeSocket(fd);
            return true;
          }
          inbuf->insert(inbuf->end(), buf, buf + n);
          if (static_cast<size_t>(n) < sizeof(buf)) break;
        }
        last_recv = now;
        size_t pos = 0;
        for (;;) {
          mqtt::Packet p;
          int used = mqtt::decodePacket(inbuf->data() + pos, inbuf->size() - pos, &p);
          if (used == 0) break;
          if (used < 0) {  // プロトコル不正は即切断
            net::closeSocket(fd);
            return true;
          }
          handlePacket(p);
          pos += static_cast<size_t>(used);
        }
        inbuf->erase(inbuf->begin(), inbuf->begin() + pos);
      }
      bool wrote = false;
      if (!flushSome(fd, &wrote)) {
        net::closeSocket(fd);
        return true;
      }
      if (wrote) last_send = now;
      // keepalive: 半周期の無送信で PINGREQ、2 周期の無受信で死んだとみなす
      if (ka_ms > 0) {
        if (now - std::max(last_send, last_ping) >= ka_ms / 2) {
          std::lock_guard<std::mutex> lk(mu);
          outbox.push_back(mqtt::encodePingReq());
          last_ping = now;
        }
        if (now - last_recv >= ka_ms * 2) {
          DB_LOGW(kTag, "keepalive 途絶 — 再接続する");
          net::closeSocket(fd);
          return true;
        }
      }
    }
  }

  void ioMain() {
    size_t backoff_idx = 0;
    bool first = true;
    while (!stopping()) {
      if (!first) {
        const size_t i = std::min<size_t>(backoff_idx, 3);
        if (!sleepBackoff(kBackoffMs[i])) break;
        if (backoff_idx < 3) backoff_idx++;
      }
      first = false;
      net::socket_t fd = connectTcp();
      if (!net::valid(fd)) continue;
      std::vector<uint8_t> inbuf;
      if (!mqttHandshake(fd, &inbuf)) {
        net::closeSocket(fd);
        continue;
      }
      backoff_idx = 0;
      {
        std::lock_guard<std::mutex> lk(mu);
        is_connected = true;
        out_off = 0;
      }
      DB_LOGI(kTag, "接続 " + opts.host + ":" + std::to_string(opts.port));
      postConnected();
      const bool err = pump(fd, &inbuf);
      {
        std::lock_guard<std::mutex> lk(mu);
        is_connected = false;
        outbox.clear();  // 古い接続宛の残りは捨てる (呼び出し側が再接続時に再発行)
        out_off = 0;
      }
      if (err) {
        DB_LOGW(kTag, "切断 — バックオフ再接続へ");
        postDisconnected();
      }
    }
  }
};

// ---------------------------------------------------------------- 公開 API

MqttClient::MqttClient(Runloop& loop, Options opts, Callbacks cbs)
    : impl_(std::make_shared<Impl>(loop, std::move(opts), std::move(cbs))) {}

MqttClient::~MqttClient() {
  stop();
  if (impl_->io.joinable()) impl_->io.join();
}

void MqttClient::start() {
  std::lock_guard<std::mutex> lk(impl_->mu);
  if (impl_->started) return;
  if (!net::makeWakePair(impl_->wake)) {
    DB_LOGE(kTag, "wake ペア作成失敗");
    return;
  }
  impl_->started = true;
  auto self = impl_;
  impl_->io = std::thread([self] { self->ioMain(); });
}

void MqttClient::stop() {
  {
    std::lock_guard<std::mutex> lk(impl_->mu);
    impl_->stop_req = true;
    // 以後のコールバックを無効化 (post 済みの残りも実行時に no-op になる)
    impl_->cbs = Callbacks{};
  }
  impl_->wakeIo();
  if (impl_->io.joinable()) impl_->io.join();
}

void MqttClient::abortForTest() {
  {
    std::lock_guard<std::mutex> lk(impl_->mu);
    impl_->abort_req = true;
    impl_->cbs = Callbacks{};
  }
  impl_->wakeIo();
  if (impl_->io.joinable()) impl_->io.join();
}

void MqttClient::publish(const std::string& topic, const std::string& payload, bool retain) {
  {
    std::lock_guard<std::mutex> lk(impl_->mu);
    if (!impl_->is_connected) {
      DB_LOGD(kTag, "未接続 publish 破棄: " + topic);
      return;
    }
    impl_->outbox.push_back(mqtt::encodePublish(topic, payload, retain));
  }
  impl_->wakeIo();
}

void MqttClient::subscribe(const std::string& topic_filter) {
  {
    std::lock_guard<std::mutex> lk(impl_->mu);
    if (!impl_->is_connected) {
      DB_LOGD(kTag, "未接続 subscribe 破棄: " + topic_filter);
      return;
    }
    uint16_t pid = impl_->next_packet_id++;
    if (impl_->next_packet_id == 0) impl_->next_packet_id = 1;  // 0 は不正
    impl_->outbox.push_back(mqtt::encodeSubscribe(pid, {topic_filter}));
  }
  impl_->wakeIo();
}

bool MqttClient::connected() const {
  std::lock_guard<std::mutex> lk(impl_->mu);
  return impl_->is_connected;
}

}  // namespace db
