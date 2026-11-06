#include "tls/tls.h"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstring>
#include <ctime>
#include <mutex>

#include "mbedtls/ecp.h"
#include "mbedtls/error.h"
#include "mbedtls/net_sockets.h"
#include "mbedtls/pk.h"
#include "mbedtls/ssl.h"
#include "mbedtls/x509_crt.h"
#include "mesh/socket_compat.h"
#include "util/log.h"

extern "C" int db_tls_random(void*, unsigned char* out, size_t len) {
  if (len == 0) return 0;
  const db::Bytes bytes = db::randomBytes(len);
  if (bytes.size() != len) return -1;
  std::memcpy(out, bytes.data(), len);
  return 0;
}

namespace db {
namespace tls {
namespace {

std::string derSha256Hex(const mbedtls_x509_crt& crt) {
  return sha256Hex(crt.raw.p, crt.raw.len);
}

std::string utcStamp(std::time_t t) {
  std::tm tm{};
#if defined(_WIN32)
  gmtime_s(&tm, &t);
#else
  gmtime_r(&t, &tm);
#endif
  char out[16];
  std::strftime(out, sizeof(out), "%Y%m%d%H%M%S", &tm);
  return out;
}

bool hexEqualConstantTime(const std::string& a, const std::string& b) {
  if (a.size() != b.size() || a.empty()) return false;
  unsigned char diff = 0;
  for (size_t i = 0; i < a.size(); ++i)
    diff |= static_cast<unsigned char>(std::tolower(static_cast<unsigned char>(a[i])) ^
                                       std::tolower(static_cast<unsigned char>(b[i])));
  return diff == 0;
}

}  // namespace

bool generateIdentity(const std::string& common_name, Identity* out, std::string* error) {
  mbedtls_pk_context key;
  mbedtls_x509write_cert writer;
  mbedtls_pk_init(&key);
  mbedtls_x509write_crt_init(&writer);
  auto fail = [&](const char* step, int rc) {
    if (error) *error = std::string(step) + " (" + std::to_string(rc) + ")";
    mbedtls_x509write_crt_free(&writer);
    mbedtls_pk_free(&key);
    return false;
  };
  int rc = mbedtls_pk_setup(&key, mbedtls_pk_info_from_type(MBEDTLS_PK_ECKEY));
  if (rc != 0) return fail("pk_setup", rc);
  rc = mbedtls_ecp_gen_key(MBEDTLS_ECP_DP_SECP256R1, mbedtls_pk_ec(key), db_tls_random, nullptr);
  if (rc != 0) return fail("ecp_gen_key", rc);

  std::string cn;
  for (char c : common_name)
    if (std::isalnum(static_cast<unsigned char>(c)) || c == '-' || c == '.' || c == '_') cn += c;
  if (cn.empty()) cn = "doorbell";
  const std::string subject = "CN=" + cn.substr(0, 60) + ",O=Doorbell";
  mbedtls_x509write_crt_set_version(&writer, MBEDTLS_X509_CRT_VERSION_3);
  mbedtls_x509write_crt_set_md_alg(&writer, MBEDTLS_MD_SHA256);
  mbedtls_x509write_crt_set_subject_key(&writer, &key);
  mbedtls_x509write_crt_set_issuer_key(&writer, &key);
  if ((rc = mbedtls_x509write_crt_set_subject_name(&writer, subject.c_str())) != 0 ||
      (rc = mbedtls_x509write_crt_set_issuer_name(&writer, subject.c_str())) != 0)
    return fail("set_name", rc);
  Bytes serial = randomBytes(16);
  serial[0] &= 0x7f;
  if ((rc = mbedtls_x509write_crt_set_serial_raw(&writer, serial.data(), serial.size())) != 0)
    return fail("set_serial", rc);
  const std::time_t now = std::time(nullptr);
  const std::string not_before = utcStamp(now - 86400);
  const std::string not_after = utcStamp(now + static_cast<std::time_t>(20) * 365 * 86400);
  if ((rc = mbedtls_x509write_crt_set_validity(&writer, not_before.c_str(), not_after.c_str())) != 0)
    return fail("set_validity", rc);
  if ((rc = mbedtls_x509write_crt_set_basic_constraints(&writer, 0, -1)) != 0)
    return fail("set_basic_constraints", rc);
  mbedtls_x509write_crt_set_key_usage(&writer, MBEDTLS_X509_KU_DIGITAL_SIGNATURE);

  std::string cert_pem(4096, '\0');
  rc = mbedtls_x509write_crt_pem(&writer, reinterpret_cast<unsigned char*>(&cert_pem[0]),
                                 cert_pem.size(), db_tls_random, nullptr);
  if (rc != 0) return fail("write_crt", rc);
  cert_pem.resize(std::strlen(cert_pem.c_str()));
  std::string key_pem(2048, '\0');
  rc = mbedtls_pk_write_key_pem(&key, reinterpret_cast<unsigned char*>(&key_pem[0]),
                                key_pem.size());
  if (rc != 0) return fail("write_key", rc);
  key_pem.resize(std::strlen(key_pem.c_str()));
  mbedtls_x509write_crt_free(&writer);
  mbedtls_pk_free(&key);
  Identity identity;
  if (!loadIdentity(cert_pem, key_pem, &identity)) {
    if (error) *error = "generated identity failed validation";
    return false;
  }
  *out = std::move(identity);
  return true;
}

bool loadIdentity(const std::string& cert_pem, const std::string& key_pem, Identity* out) {
  if (cert_pem.empty() || key_pem.empty()) return false;
  mbedtls_x509_crt crt;
  mbedtls_pk_context key;
  mbedtls_x509_crt_init(&crt);
  mbedtls_pk_init(&key);
  bool ok = mbedtls_x509_crt_parse(&crt, reinterpret_cast<const unsigned char*>(cert_pem.c_str()),
                                   cert_pem.size() + 1) == 0 &&
            mbedtls_pk_parse_key(&key, reinterpret_cast<const unsigned char*>(key_pem.c_str()),
                                 key_pem.size() + 1, nullptr, 0, db_tls_random, nullptr) == 0 &&
            mbedtls_pk_check_pair(&crt.pk, &key, db_tls_random, nullptr) == 0;
  if (ok && out) {
    out->cert_pem = cert_pem;
    out->key_pem = key_pem;
    out->sha256_hex = derSha256Hex(crt);
  }
  mbedtls_pk_free(&key);
  mbedtls_x509_crt_free(&crt);
  return ok;
}

std::string listenerPem(const Identity& identity) {
  std::string pem = identity.cert_pem;
  if (!pem.empty() && pem.back() != '\n') pem += '\n';
  return pem + identity.key_pem;
}

struct HttpStream::Impl {
  net::socket_t fd = net::kInvalidSocket;
  bool tls = false;
  bool ssl_ready = false;
  mbedtls_ssl_context ssl;
  mbedtls_ssl_config conf;

  Impl() {
    mbedtls_ssl_init(&ssl);
    mbedtls_ssl_config_init(&conf);
  }
  ~Impl() {
    if (ssl_ready) mbedtls_ssl_close_notify(&ssl);
    mbedtls_ssl_free(&ssl);
    mbedtls_ssl_config_free(&conf);
    if (net::valid(fd)) net::closeSocket(fd);
  }

  static int bioSend(void* ctx, const unsigned char* buf, size_t len) {
    auto* self = static_cast<Impl*>(ctx);
    const int n = net::sendSome(self->fd, buf, len);
    if (n >= 0) return n;
    return net::errWouldBlock(net::lastError()) ? MBEDTLS_ERR_SSL_WANT_WRITE
                                                : MBEDTLS_ERR_NET_SEND_FAILED;
  }
  static int bioRecv(void* ctx, unsigned char* buf, size_t len) {
    auto* self = static_cast<Impl*>(ctx);
    const int n = net::recvSome(self->fd, buf, len);
    if (n >= 0) return n;
    return net::errWouldBlock(net::lastError()) ? MBEDTLS_ERR_SSL_WANT_READ
                                                : MBEDTLS_ERR_NET_RECV_FAILED;
  }

  bool waitFor(short events, int timeout_ms) {
    net::pollfd_t pfd{};
    pfd.fd = fd;
    pfd.events = events;
    return net::poll(&pfd, 1, timeout_ms) > 0 &&
           !(pfd.revents & (POLLERR | POLLNVAL));
  }

  // >0 bytes, 0 EOF, -1 would block, -2 error.
  int readSome(uint8_t* buf, size_t len) {
    if (!tls) {
      const int n = net::recvSome(fd, buf, len);
      if (n >= 0) return n;
      return net::errWouldBlock(net::lastError()) ? -1 : -2;
    }
    const int n = mbedtls_ssl_read(&ssl, buf, len);
    if (n > 0) return n;
    if (n == 0 || n == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY) return 0;
    if (n == MBEDTLS_ERR_SSL_WANT_READ || n == MBEDTLS_ERR_SSL_WANT_WRITE) return -1;
    return -2;
  }
  bool pendingInTls() { return tls && mbedtls_ssl_get_bytes_avail(&ssl) > 0; }

  bool writeAll(const std::string& data, std::chrono::steady_clock::time_point deadline) {
    size_t sent = 0;
    while (sent < data.size()) {
      int n;
      if (tls) {
        n = mbedtls_ssl_write(&ssl, reinterpret_cast<const unsigned char*>(data.data()) + sent,
                              data.size() - sent);
        if (n == MBEDTLS_ERR_SSL_WANT_READ || n == MBEDTLS_ERR_SSL_WANT_WRITE) n = -1;
        else if (n < 0) return false;
      } else {
        n = net::sendSome(fd, data.data() + sent, data.size() - sent);
        if (n < 0 && !net::errWouldBlock(net::lastError())) return false;
      }
      if (n > 0) {
        sent += static_cast<size_t>(n);
        continue;
      }
      const auto left = std::chrono::duration_cast<std::chrono::milliseconds>(
          deadline - std::chrono::steady_clock::now()).count();
      if (left <= 0 || !waitFor(POLLOUT, static_cast<int>(std::min<int64_t>(left, 500))))
        if (std::chrono::steady_clock::now() >= deadline) return false;
    }
    return true;
  }
};

HttpStream::HttpStream(Endpoint endpoint, std::string path_and_query,
                       std::map<std::string, std::string> headers, std::string method,
                       std::string body)
    : endpoint_(std::move(endpoint)), path_(std::move(path_and_query)),
      headers_(std::move(headers)), method_(std::move(method)), body_(std::move(body)) {}

HttpStream::~HttpStream() { close(); }

void HttpStream::close() {
  impl_.reset();
  closed_ = true;
}

std::string HttpStream::header(const std::string& lowercase_name) const {
  const auto found = response_headers_.find(lowercase_name);
  return found == response_headers_.end() ? std::string() : found->second;
}

bool HttpStream::open(int timeout_ms) {
  if (opened_) return status_ != 0;
  opened_ = true;
  started_at_ = std::chrono::steady_clock::now();
  auto elapsed = [&] { return std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - started_at_).count(); };
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
  auto remaining = [&] {
    return static_cast<int>(std::max<int64_t>(0, std::chrono::duration_cast<std::chrono::milliseconds>(
        deadline - std::chrono::steady_clock::now()).count()));
  };
  if (endpoint_.port < 1 || endpoint_.port > 65535 || endpoint_.host.empty()) {
    error_ = "bad_endpoint";
    return false;
  }
  if (endpoint_.tls && endpoint_.pin_sha256.size() != 64) {
    error_ = "missing_pin";
    return false;
  }
  impl_.reset(new Impl());
  impl_->tls = endpoint_.tls;
  std::string resolver_host = endpoint_.host;
  if (resolver_host.size() > 2 && resolver_host.front() == '[' && resolver_host.back() == ']')
    resolver_host = resolver_host.substr(1, resolver_host.size() - 2);
  addrinfo hints{};
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  addrinfo* addresses = nullptr;
  const std::string service = std::to_string(endpoint_.port);
  if (::getaddrinfo(resolver_host.c_str(), service.c_str(), &hints, &addresses) != 0 || !addresses) {
    error_ = "resolve_failed";
    return false;
  }
  timings_.resolve_ms = elapsed();
  for (addrinfo* p = addresses; p && !net::valid(impl_->fd); p = p->ai_next) {
    net::socket_t candidate = ::socket(p->ai_family, p->ai_socktype, p->ai_protocol);
    if (!net::valid(candidate)) continue;
    net::setNonBlock(candidate);
    const int rc = ::connect(candidate, p->ai_addr, static_cast<net::socklen_v>(p->ai_addrlen));
    if (rc != 0 && !net::errConnectInProgress(net::lastError())) {
      net::closeSocket(candidate);
      continue;
    }
    net::pollfd_t pfd{};
    pfd.fd = candidate;
    pfd.events = POLLOUT;
    const int left = std::min(remaining(), 3000);
    if (rc == 0 || (left > 0 && net::poll(&pfd, 1, left) > 0 && net::getSockError(candidate) == 0))
      impl_->fd = candidate;
    else
      net::closeSocket(candidate);
  }
  ::freeaddrinfo(addresses);
  if (!net::valid(impl_->fd)) {
    error_ = "connect_failed";
    return false;
  }
  timings_.connect_ms = elapsed() - timings_.resolve_ms;
  int yes = 1;
  net::setSockOpt(impl_->fd, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));

  if (endpoint_.tls) {
    mbedtls_ssl_config& conf = impl_->conf;
    if (mbedtls_ssl_config_defaults(&conf, MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_STREAM,
                                    MBEDTLS_SSL_PRESET_DEFAULT) != 0) {
      error_ = "tls_config";
      return false;
    }
    // Peers present self-signed certificates; trust comes from the replicated pin checked
    // after the handshake, not from a CA chain.
    mbedtls_ssl_conf_authmode(&conf, MBEDTLS_SSL_VERIFY_OPTIONAL);
    mbedtls_ssl_conf_rng(&conf, db_tls_random, nullptr);
    mbedtls_ssl_conf_min_tls_version(&conf, MBEDTLS_SSL_VERSION_TLS1_2);
    if (mbedtls_ssl_setup(&impl_->ssl, &conf) != 0) {
      error_ = "tls_setup";
      return false;
    }
    mbedtls_ssl_set_bio(&impl_->ssl, impl_.get(), &Impl::bioSend, &Impl::bioRecv, nullptr);
    for (;;) {
      const int rc = mbedtls_ssl_handshake(&impl_->ssl);
      if (rc == 0) break;
      if (rc != MBEDTLS_ERR_SSL_WANT_READ && rc != MBEDTLS_ERR_SSL_WANT_WRITE) {
        error_ = "tls_handshake";
        return false;
      }
      const int left = remaining();
      if (left <= 0 ||
          !impl_->waitFor(rc == MBEDTLS_ERR_SSL_WANT_WRITE ? POLLOUT : POLLIN, std::min(left, 500))) {
        if (remaining() <= 0) {
          error_ = "tls_timeout";
          return false;
        }
      }
    }
    impl_->ssl_ready = true;
    const mbedtls_x509_crt* peer = mbedtls_ssl_get_peer_cert(&impl_->ssl);
    if (!peer || !hexEqualConstantTime(derSha256Hex(*peer), endpoint_.pin_sha256)) {
      error_ = "pin_mismatch";
      return false;
    }
  }

  timings_.tls_ms = elapsed() - timings_.resolve_ms - timings_.connect_ms;
  std::string authority = endpoint_.host;
  if (authority.find(':') != std::string::npos && authority.front() != '[')
    authority = "[" + authority + "]";
  if (method_.empty() || method_.find_first_not_of("ABCDEFGHIJKLMNOPQRSTUVWXYZ") != std::string::npos) {
    error_ = "bad_method";
    return false;
  }
  std::string request = method_ + " " + path_ + " HTTP/1.1\r\nHost: " + authority + ":" +
                        service + "\r\nConnection: close\r\n";
  if (method_ != "GET" || !body_.empty())
    request += "Content-Length: " + std::to_string(body_.size()) + "\r\n";
  for (const auto& kv : headers_) {
    if (kv.first.find_first_of("\r\n:") != std::string::npos ||
        kv.second.find_first_of("\r\n") != std::string::npos)
      continue;
    request += kv.first + ": " + kv.second + "\r\n";
  }
  request += "\r\n" + body_;
  if (!impl_->writeAll(request, deadline)) {
    error_ = "send_failed";
    return false;
  }

  timings_.request_ms = elapsed() - timings_.resolve_ms - timings_.connect_ms - timings_.tls_ms;
  const int64_t head_start = elapsed();
  std::string response;
  while (response.find("\r\n\r\n") == std::string::npos && response.size() < 64 * 1024) {
    if (!impl_->pendingInTls()) {
      const int left = remaining();
      if (left <= 0) {
        error_ = "head_timeout";
        return false;
      }
      if (!impl_->waitFor(POLLIN, std::min(left, 500))) continue;
    }
    uint8_t buf[8192];
    const int n = impl_->readSome(buf, sizeof(buf));
    if (n == -1) continue;
    if (n <= 0) {
      error_ = "closed";
      return false;
    }
    response.append(reinterpret_cast<const char*>(buf), static_cast<size_t>(n));
  }
  const size_t end = response.find("\r\n\r\n");
  if (end == std::string::npos || response.compare(0, 5, "HTTP/") != 0) {
    error_ = "bad_head";
    return false;
  }
  const size_t sp = response.find(' ');
  if (sp == std::string::npos || sp > end) {
    error_ = "bad_status";
    return false;
  }
  status_ = std::atoi(response.c_str() + sp + 1);
  size_t line = response.find("\r\n");
  while (line != std::string::npos && line < end) {
    const size_t next = response.find("\r\n", line + 2);
    const std::string text = response.substr(line + 2, (next == std::string::npos ? end : next) -
                                                           line - 2);
    const size_t colon = text.find(':');
    if (colon != std::string::npos) {
      std::string name = text.substr(0, colon);
      std::transform(name.begin(), name.end(), name.begin(),
                     [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
      std::string value = text.substr(colon + 1);
      while (!value.empty() && (value.front() == ' ' || value.front() == '\t')) value.erase(0, 1);
      response_headers_[name] = value;
    }
    if (next == std::string::npos || next >= end) break;
    line = next;
  }
  timings_.headers_ms = elapsed() - head_start;
  if (path_ == "/stream.mp4" || path_ == "/media-standby.mp4")
    DB_LOGI("media-startup", "resolve_ms=" + std::to_string(timings_.resolve_ms) +
        " tcp_ms=" + std::to_string(timings_.connect_ms) + " tls_ms=" + std::to_string(timings_.tls_ms) +
        " request_ms=" + std::to_string(timings_.request_ms) + " headers_ms=" + std::to_string(timings_.headers_ms) +
        " total_ms=" + std::to_string(elapsed()) + " status=" + std::to_string(status_));
  pending_.assign(response.begin() + static_cast<std::ptrdiff_t>(end + 4), response.end());
  return status_ != 0;
}

Bytes HttpStream::pull(bool* ended) {
  auto note_body = [&] {
    if (timed_body_) return;
    timed_body_ = true;
    timings_.first_body_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - started_at_).count();
    if (path_ == "/stream.mp4" || path_ == "/media-standby.mp4")
      DB_LOGI("media-startup", "first_body_ms=" + std::to_string(timings_.first_body_ms));
  };
  if (ended) *ended = false;
  if (closed_ || !impl_ || status_ == 0) {
    if (ended) *ended = true;
    return {};
  }
  if (!pending_.empty()) {
    Bytes out;
    const size_t n = std::min<size_t>(pending_.size(), 64 * 1024);
    out.insert(out.end(), pending_.begin(), pending_.begin() + static_cast<std::ptrdiff_t>(n));
    pending_.erase(pending_.begin(), pending_.begin() + static_cast<std::ptrdiff_t>(n));
    note_body();
    return out;
  }
  if (!impl_->pendingInTls()) {
    net::pollfd_t pfd{};
    pfd.fd = impl_->fd;
    pfd.events = POLLIN;
    const int pr = net::poll(&pfd, 1, 500);
    if (pr == 0) return {};
    if (pr < 0 || (pfd.revents & (POLLERR | POLLNVAL))) {
      close();
      if (ended) *ended = true;
      return {};
    }
  }
  Bytes buf(64 * 1024);
  const int n = impl_->readSome(buf.data(), buf.size());
  if (n > 0) {
    buf.resize(static_cast<size_t>(n));
    note_body();
    return buf;
  }
  if (n == -1) return {};
  close();
  if (ended) *ended = true;
  return {};
}

bool HttpStream::readAll(size_t max_bytes, int timeout_ms, Bytes* out) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
  out->clear();
  for (;;) {
    bool ended = false;
    Bytes chunk = pull(&ended);
    if (out->size() + chunk.size() > max_bytes) return false;
    out->insert(out->end(), chunk.begin(), chunk.end());
    if (ended) return true;
    if (std::chrono::steady_clock::now() >= deadline) return false;
  }
}

}  // namespace tls
}  // namespace db
