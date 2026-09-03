



#include "httpd/httpd.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <set>
#include <vector>
#include <thread>

#include "civetweb.h"
#include "mesh/socket_compat.h"
#include "util/log.h"

namespace db {

namespace {

constexpr int64_t kHandlerTimeoutMs = 5000;
// A live stream holds its worker thread for as long as it runs, so an idle one has to be able to
// notice a client that has gone away. Without a frame to write, nothing ever touches the socket
// and the worker is pinned for good -- which is exactly what a door station with no working
// camera produces.
constexpr int64_t kStreamIdleProbeMs = 2000;
constexpr int64_t kStreamIdleGiveUpMs = 30000;
constexpr size_t kMaxBodyBytes = 8 * 1024 * 1024;


constexpr int kMp4FirstChunkTimeoutMs = 15000;

int hexVal(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}


std::string urlDecode(const std::string& s) {
  std::string out;
  out.reserve(s.size());
  for (size_t i = 0; i < s.size(); i++) {
    char c = s[i];
    if (c == '+') {
      out.push_back(' ');
    } else if (c == '%' && i + 2 < s.size() && hexVal(s[i + 1]) >= 0 && hexVal(s[i + 2]) >= 0) {
      out.push_back(static_cast<char>((hexVal(s[i + 1]) << 4) | hexVal(s[i + 2])));
      i += 2;
    } else {
      out.push_back(c);
    }
  }
  return out;
}


bool findParam(const std::string& data, const std::string& key, std::string* out) {
  size_t pos = 0;
  while (pos <= data.size()) {
    size_t amp = data.find('&', pos);
    if (amp == std::string::npos) amp = data.size();
    size_t eq = data.find('=', pos);
    std::string k, v;
    if (eq != std::string::npos && eq < amp) {
      k = urlDecode(data.substr(pos, eq - pos));
      v = urlDecode(data.substr(eq + 1, amp - eq - 1));
    } else {
      k = urlDecode(data.substr(pos, amp - pos));
    }
    if (!k.empty() && k == key) {
      *out = std::move(v);
      return true;
    }
    if (amp >= data.size()) break;
    pos = amp + 1;
  }
  return false;
}

std::string toLowerCopy(const char* s) {
  std::string out(s ? s : "");
  for (char& c : out) {
    if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
  }
  return out;
}

const char* statusText(int code) {
  switch (code) {
    case 200: return "OK";
    case 201: return "Created";
    case 204: return "No Content";
    case 301: return "Moved Permanently";
    case 302: return "Found";
    case 304: return "Not Modified";
    case 400: return "Bad Request";
    case 401: return "Unauthorized";
    case 403: return "Forbidden";
    case 404: return "Not Found";
    case 405: return "Method Not Allowed";
    case 409: return "Conflict";
    case 413: return "Payload Too Large";
    case 500: return "Internal Server Error";
    case 501: return "Not Implemented";
    case 503: return "Service Unavailable";
    default: return "Status";
  }
}

}  // namespace

// ---------- HttpReq ----------

std::string HttpReq::param(const std::string& key, const std::string& def) const {
  std::string v;
  if (findParam(query, key, &v)) return v;
  auto it = headers.find("content-type");
  if (it != headers.end() &&
      it->second.find("application/x-www-form-urlencoded") != std::string::npos) {
    if (findParam(body, key, &v)) return v;
  }
  return def;
}

std::string HttpReq::cookie(const std::string& name) const {
  auto it = headers.find("cookie");
  if (it == headers.end()) return "";
  const std::string& h = it->second;
  size_t pos = 0;
  while (pos < h.size()) {
    size_t sc = h.find(';', pos);
    if (sc == std::string::npos) sc = h.size();
    size_t b = pos;
    while (b < sc && (h[b] == ' ' || h[b] == '\t')) b++;
    size_t e = sc;
    while (e > b && (h[e - 1] == ' ' || h[e - 1] == '\t')) e--;
    size_t eq = h.find('=', b);
    if (eq != std::string::npos && eq < e && h.compare(b, eq - b, name) == 0) {
      return h.substr(eq + 1, e - eq - 1);
    }
    pos = sc + 1;
  }
  return "";
}

// ---------- HttpResp ----------

HttpResp HttpResp::json(const std::string& body, int status) {
  HttpResp r;
  r.status = status;
  r.content_type = "application/json; charset=utf-8";
  r.body = body;
  return r;
}

HttpResp HttpResp::text(const std::string& body, int status) {
  HttpResp r;
  r.status = status;
  r.content_type = "text/plain; charset=utf-8";
  r.body = body;
  return r;
}

HttpResp HttpResp::notFound() { return text("not found", 404); }

// ---------- Httpd::Impl ----------

struct Httpd::Impl {
  explicit Impl(Runloop& l) : loop(l) {}

  Runloop& loop;
  struct mg_context* ctx = nullptr;
  int port = 0;
  std::atomic<bool> stopping{false};


  std::mutex mu;
  struct Route {
    std::string method;
    std::string path;
    bool prefix = false;
    Handler h;
  };
  std::vector<Route> routes;
  struct Asset {
    std::string content_type;
    Bytes content;
  };
  std::map<std::string, Asset> statics;
  std::function<Bytes(int64_t*)> jpeg_provider;
  std::function<int()> video_rotation_provider;
  int stream_fps = 8;
  std::function<Mp4Pull()> mp4_provider;
  Mp4ProxyProvider mp4_proxy_provider;
  std::function<bool(const HttpReq&)> gate;
  std::vector<std::string> public_prefixes;
};

namespace {


HttpReq buildReq(struct mg_connection* conn) {
  const struct mg_request_info* ri = mg_get_request_info(conn);
  HttpReq req;
  req.method = ri->request_method ? ri->request_method : "";
  req.uri = ri->local_uri ? ri->local_uri : "";
  req.query = ri->query_string ? ri->query_string : "";
  req.remote_addr = ri->remote_addr;
  for (int i = 0; i < ri->num_headers; i++) {
    req.headers[toLowerCopy(ri->http_headers[i].name)] =
        ri->http_headers[i].value ? ri->http_headers[i].value : "";
  }
  if (ri->content_length != 0) {
    char buf[4096];
    long long want = ri->content_length;
    for (;;) {
      int n = mg_read(conn, buf, sizeof(buf));
      if (n <= 0) break;
      req.body.append(buf, static_cast<size_t>(n));
      if (req.body.size() >= kMaxBodyBytes) break;
      if (want > 0 && static_cast<long long>(req.body.size()) >= want) break;
    }
  }
  return req;
}


void writeResp(struct mg_connection* conn, const HttpResp& r) {
  std::string head = "HTTP/1.1 " + std::to_string(r.status) + " " + statusText(r.status) + "\r\n";
  head += "Content-Type: " + r.content_type + "\r\n";
  head += "Content-Length: " + std::to_string(r.body.size()) + "\r\n";
  head += "Connection: close\r\n";
  for (const auto& kv : r.headers) head += kv.first + ": " + kv.second + "\r\n";
  head += "\r\n";
  mg_write(conn, head.data(), head.size());
  if (!r.body.empty()) mg_write(conn, r.body.data(), r.body.size());
}



int handleStream(struct mg_connection* conn, Httpd::Impl* impl) {
  std::function<Bytes(int64_t*)> prov;
  int fps;
  {
    std::lock_guard<std::mutex> lk(impl->mu);
    prov = impl->jpeg_provider;
    fps = impl->stream_fps;
  }
  if (!prov) {
    writeResp(conn, HttpResp::text("no frame source", 503));
    return 503;
  }
  const auto server_wall_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::system_clock::now().time_since_epoch()).count();
  char head[256];
  std::snprintf(head, sizeof(head),
      "HTTP/1.1 200 OK\r\n"
      "Content-Type: multipart/x-mixed-replace; boundary=frame\r\n"
      "Access-Control-Allow-Origin: *\r\n"
      "X-Doorbell-Server-Time-Ms: %lld\r\n"
      "Connection: close\r\n\r\n", static_cast<long long>(server_wall_ms));
  if (mg_write(conn, head, std::strlen(head)) <= 0) return 200;
  const auto interval = std::chrono::milliseconds(1000 / (fps > 0 ? fps : 8));
  auto last_frame = std::chrono::steady_clock::now();
  auto last_probe = last_frame;
  for (;;) {
    if (impl->stopping.load()) break;
    {
      std::lock_guard<std::mutex> lk(impl->mu);
      prov = impl->jpeg_provider;
    }
    if (!prov) break;
    int64_t capture_ms = 0;
    Bytes frame = prov(&capture_ms);
    const auto now = std::chrono::steady_clock::now();
    if (frame.empty()) {
      const auto idle = std::chrono::duration_cast<std::chrono::milliseconds>(
          now - last_frame).count();
      if (idle >= kStreamIdleGiveUpMs) {
        DB_LOGW("httpd", "/stream.mjpeg produced no frame for " + std::to_string(idle) +
                             "ms; releasing the connection");
        break;
      }
      // Touch the socket so a client that has gone away is detected even with no frames to send.
      // A bare CRLF between parts is ignored by every multipart reader.
      if (std::chrono::duration_cast<std::chrono::milliseconds>(now - last_probe).count() >=
          kStreamIdleProbeMs) {
        last_probe = now;
        if (mg_write(conn, "\r\n", 2) <= 0) break;
      }
    }
    if (!frame.empty()) {
      last_frame = now;
      last_probe = now;
      int rotation = 0;
      {
        std::lock_guard<std::mutex> lk(impl->mu);
        if (impl->video_rotation_provider) rotation = impl->video_rotation_provider();
      }
      char part[240];
      std::snprintf(part, sizeof(part),
                    "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: %u\r\n"
                    "X-Doorbell-Capture-Time-Ms: %lld\r\n"
                    "X-Doorbell-Video-Rotation: %d\r\n\r\n",
                    static_cast<unsigned>(frame.size()), static_cast<long long>(capture_ms),
                    rotation);
      if (mg_write(conn, part, std::strlen(part)) <= 0) break;
      if (mg_write(conn, frame.data(), frame.size()) <= 0) break;
      if (mg_write(conn, "\r\n", 2) <= 0) break;
    }
    std::this_thread::sleep_for(interval);
  }
  return 200;
}




int handleStreamMp4(struct mg_connection* conn, Httpd::Impl* impl) {
  std::function<Httpd::Mp4Pull()> provider;
  {
    std::lock_guard<std::mutex> lk(impl->mu);
    provider = impl->mp4_provider;
  }
  Httpd::Mp4Pull pull = provider ? provider() : nullptr;
  if (!pull) {
    writeResp(conn, HttpResp::text("h264 stream not available", 503));
    return 503;
  }

  Bytes chunk;
  bool ended = false;
  const auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::milliseconds(kMp4FirstChunkTimeoutMs);
  for (;;) {
    if (impl->stopping.load()) {
      writeResp(conn, HttpResp::text("shutting down", 503));
      return 503;
    }
    chunk = pull(&ended);
    if (!chunk.empty() || ended) break;
    if (std::chrono::steady_clock::now() >= deadline) break;
  }
  if (chunk.empty()) {
    writeResp(conn, HttpResp::text("no h264 source", 503));
    return 503;
  }
  const auto server_wall_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::system_clock::now().time_since_epoch()).count();
  char head[256];
  std::snprintf(head, sizeof(head),
      "HTTP/1.1 200 OK\r\n"
      "Content-Type: video/mp4\r\n"
      "Cache-Control: no-store\r\n"
      "Access-Control-Allow-Origin: *\r\n"
      "X-Doorbell-Server-Time-Ms: %lld\r\n"
      "Connection: close\r\n\r\n",
      static_cast<long long>(server_wall_ms));
  if (mg_write(conn, head, std::strlen(head)) <= 0) return 200;
  for (;;) {
    if (!chunk.empty()) {
      if (mg_write(conn, chunk.data(), chunk.size()) <= 0) break;
    } else {




      static const uint8_t kFreeBox[8] = {0, 0, 0, 8, 'f', 'r', 'e', 'e'};
      if (mg_write(conn, kFreeBox, sizeof(kFreeBox)) <= 0) break;
    }
    if (ended || impl->stopping.load()) break;
    {
      std::lock_guard<std::mutex> lk(impl->mu);
      if (!impl->mp4_provider) break;
    }
    chunk = pull(&ended);
  }
  return 200;
}

int handleStreamProxyMp4(struct mg_connection* conn, Httpd::Impl* impl, const HttpReq& req) {
  Httpd::Mp4ProxyProvider provider;
  {
    std::lock_guard<std::mutex> lk(impl->mu);
    provider = impl->mp4_proxy_provider;
  }
  int status = 503;
  Httpd::Mp4Pull pull = provider ? provider(req, &status) : nullptr;
  if (!pull) {
    writeResp(conn, HttpResp::text(status == 403 ? "forbidden" : "h264 proxy unavailable", status));
    return status;
  }
  Bytes chunk;
  bool ended = false;
  const auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::milliseconds(kMp4FirstChunkTimeoutMs);
  while (!impl->stopping.load() && !ended && chunk.empty() &&
         std::chrono::steady_clock::now() < deadline)
    chunk = pull(&ended);
  if (chunk.empty()) {
    writeResp(conn, HttpResp::text("upstream h264 unavailable", 503));
    return 503;
  }
  const char* head =
      "HTTP/1.1 200 OK\r\n"
      "Content-Type: video/mp4\r\n"
      "Cache-Control: no-store\r\n"
      "X-Content-Type-Options: nosniff\r\n"
      "Connection: close\r\n\r\n";
  if (mg_write(conn, head, std::strlen(head)) <= 0) return 200;
  for (;;) {
    if (!chunk.empty() && mg_write(conn, chunk.data(), chunk.size()) <= 0) break;
    if (ended || impl->stopping.load()) break;
    chunk = pull(&ended);
  }
  return 200;
}



HttpResp runOnLoop(Httpd::Impl* impl, const Httpd::Handler& h, const HttpReq& req) {
  struct Pending {
    std::mutex m;
    std::condition_variable cv;
    bool done = false;
    HttpResp resp;
  };
  auto p = std::make_shared<Pending>();
  const std::string uri = req.uri;
  impl->loop.post([p, h, req] {
    // The runloop is the single state thread for the whole node. An exception escaping a handler
    // here would unwind it, so a bad request is answered with a 500 instead of stopping calls,
    // the mesh, and every timer in the process.
    HttpResp r;
    try {
      r = h(req);
    } catch (const std::exception& e) {
      DB_LOGE("httpd", std::string("handler threw on the runloop: ") + e.what());
      r = HttpResp::text("internal error", 500);
    } catch (...) {
      DB_LOGE("httpd", "handler threw an unknown exception on the runloop");
      r = HttpResp::text("internal error", 500);
    }
    std::lock_guard<std::mutex> lk(p->m);
    p->resp = std::move(r);
    p->done = true;
    p->cv.notify_all();
  });
  std::unique_lock<std::mutex> lk(p->m);
  if (!p->cv.wait_for(lk, std::chrono::milliseconds(kHandlerTimeoutMs), [&] { return p->done; })) {
    // Worth a log: a stalled runloop shows up here first, one worker thread at a time.
    DB_LOGW("httpd", "handler timed out after " + std::to_string(kHandlerTimeoutMs) + "ms: " +
                         uri);
    return HttpResp::text("handler timeout", 503);
  }
  return std::move(p->resp);
}


int requestHandlerImpl(struct mg_connection* conn, void* cbdata);

// civetweb calls this from a C frame, so an escaping C++ exception would terminate the process
// rather than fail one request. Every request is answered, and the worker thread always returns
// to the pool.
int requestHandler(struct mg_connection* conn, void* cbdata) {
  try {
    return requestHandlerImpl(conn, cbdata);
  } catch (const std::exception& e) {
    DB_LOGE("httpd", std::string("request handler threw: ") + e.what());
  } catch (...) {
    DB_LOGE("httpd", "request handler threw an unknown exception");
  }
  writeResp(conn, HttpResp::text("internal error", 500));
  return 500;
}

int requestHandlerImpl(struct mg_connection* conn, void* cbdata) {
  auto* impl = static_cast<Httpd::Impl*>(cbdata);
  HttpReq req = buildReq(conn);


  std::function<bool(const HttpReq&)> gate;
  {
    std::lock_guard<std::mutex> lk(impl->mu);
    if (impl->gate) {
      bool is_public = false;
      for (const auto& p : impl->public_prefixes) {
        if (req.uri.compare(0, p.size(), p) == 0) {
          is_public = true;
          break;
        }
      }
      if (!is_public) gate = impl->gate;
    }
  }
  if (gate && !gate(req)) {
    writeResp(conn, HttpResp::text("unauthorized", 401));
    return 401;
  }


  if (req.method == "GET" || req.method == "HEAD") {
    std::lock_guard<std::mutex> lk(impl->mu);
    auto it = impl->statics.find(req.uri);
    if (it != impl->statics.end()) {
      HttpResp r;
      r.content_type = it->second.content_type;
      r.body = toString(it->second.content);
      writeResp(conn, r);
      return r.status;
    }
  }

  // --- 2. /snapshot.jpg ---
  if (req.uri == "/snapshot.jpg") {
    std::function<Bytes(int64_t*)> prov;
    {
      std::lock_guard<std::mutex> lk(impl->mu);
      prov = impl->jpeg_provider;
    }
    Bytes frame = prov ? prov(nullptr) : Bytes{};
    if (frame.empty()) {
      writeResp(conn, HttpResp::text("no frame", 503));
      return 503;
    }
    HttpResp r;
    r.content_type = "image/jpeg";
    r.body = toString(frame);
    writeResp(conn, r);
    return 200;
  }

  // --- 3. local streams and authenticated same-origin H.264 proxy ---
  if (req.uri == "/stream.mjpeg") return handleStream(conn, impl);
  if (req.uri == "/stream.mp4") return handleStreamMp4(conn, impl);
  if (req.uri == "/stream-proxy.mp4") return handleStreamProxyMp4(conn, impl, req);


  Httpd::Handler h;
  {
    std::lock_guard<std::mutex> lk(impl->mu);
    size_t best_len = 0;
    bool exact = false;
    for (const auto& r : impl->routes) {
      if (r.method != req.method) continue;
      if (!r.prefix) {
        if (r.path == req.uri) {
          h = r.h;
          exact = true;
          break;
        }
      } else if (!exact && req.uri.compare(0, r.path.size(), r.path) == 0 &&
                 r.path.size() >= best_len) {

        best_len = r.path.size();
        h = r.h;
      }
    }
  }
  if (!h) {
    writeResp(conn, HttpResp::notFound());
    return 404;
  }
  HttpResp resp = runOnLoop(impl, h, req);
  writeResp(conn, resp);
  return resp.status;
}

}  // namespace

// ---------- Httpd ----------

Httpd::Httpd(Runloop& loop) : impl_(new Impl(loop)) {}

Httpd::~Httpd() { stop(); }

// civetweb explains a failed bind in a log line and nothing else -- mg_start just returns null.
// Without this the only record of "address already in use" was a test asserting false.
//
// It has to stay cheap, and it has to stay quiet when it repeats. mg_cry_ctx_internal fires from
// the accept loop on the master thread, and on a platform that refuses setsockopt on accepted
// sockets it fires twice for every single connection -- iOS 5 does exactly that, with EINVAL for
// both SO_KEEPALIVE and TCP_NODELAY. Each call here takes a global mutex, writes to stderr and
// hands the line to the shell's log sink, all on the thread whose job is to keep accepting. So a
// message that has already been reported is counted rather than logged again: the first one
// still reaches the log, and the accept loop stops paying for the rest.
namespace {
std::mutex g_log_mu;
std::set<std::string> g_logged;
uint64_t g_log_suppressed = 0;
constexpr size_t kMaxRememberedMessages = 64;
}  // namespace

bool httpdShouldLogCivetwebMessage(const std::string& text) {
  std::lock_guard<std::mutex> lk(g_log_mu);
  if (!g_logged.insert(text).second) {
    g_log_suppressed++;
    return false;
  }
  // Bounded: civetweb has a small vocabulary, and forgetting it occasionally costs one repeated
  // line rather than unbounded memory.
  if (g_logged.size() > kMaxRememberedMessages) g_logged.clear();
  return true;
}

static int httpdLogMessage(const struct mg_connection* /*conn*/, const char* message) {
  const std::string text = message ? message : "";
  if (httpdShouldLogCivetwebMessage(text)) DB_LOGW("httpd", "civetweb: " + text);
  return 1;
}

// True when a connection accepted from a listener of this family survives the socket options
// civetweb sets on every accept. A listener that binds is not proof: iOS 5 binds the dual-stack
// wildcard happily and then refuses setsockopt on everything it accepts. The probe runs on an
// ephemeral port over loopback, so the real port is never touched.
bool httpdFamilyServable(int family) {
  if (family != AF_INET && family != AF_INET6) return false;
  const net::socket_t listener = ::socket(family, SOCK_STREAM, 0);
  if (!net::valid(listener)) return false;

  sockaddr_storage bound{};
  socklen_t bound_len = 0;
  if (family == AF_INET) {
    auto* address = reinterpret_cast<sockaddr_in*>(&bound);
    address->sin_family = AF_INET;
    address->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    bound_len = sizeof(sockaddr_in);
  } else {
    auto* address = reinterpret_cast<sockaddr_in6*>(&bound);
    address->sin6_family = AF_INET6;
    address->sin6_addr = in6addr_loopback;
    bound_len = sizeof(sockaddr_in6);
  }
  auto give_up = [&](net::socket_t a, net::socket_t b, net::socket_t c) {
    if (net::valid(a)) net::closeSocket(a);
    if (net::valid(b)) net::closeSocket(b);
    if (net::valid(c)) net::closeSocket(c);
    return false;
  };
  if (::bind(listener, reinterpret_cast<sockaddr*>(&bound), bound_len) != 0 ||
      ::listen(listener, 1) != 0)
    return give_up(listener, net::kInvalidSocket, net::kInvalidSocket);
  socklen_t actual_len = bound_len;
  if (::getsockname(listener, reinterpret_cast<sockaddr*>(&bound), &actual_len) != 0)
    return give_up(listener, net::kInvalidSocket, net::kInvalidSocket);

  const net::socket_t client = ::socket(family, SOCK_STREAM, 0);
  if (!net::valid(client)) return give_up(listener, net::kInvalidSocket, net::kInvalidSocket);
  net::setNonBlock(client);
  if (::connect(client, reinterpret_cast<sockaddr*>(&bound), actual_len) != 0) {
    const int error = net::lastError();
    if (!net::errWouldBlock(error) && error != EINPROGRESS)
      return give_up(listener, client, net::kInvalidSocket);
  }
  // The listener is blocking, and the connection is already on the queue or arriving on
  // loopback, so this accept does not wait on anything real.
  net::pollfd_t waiting{};
  waiting.fd = listener;
  waiting.events = POLLIN;
  if (net::poll(&waiting, 1, 250) <= 0) return give_up(listener, client, net::kInvalidSocket);
  const net::socket_t accepted = ::accept(listener, nullptr, nullptr);
  if (!net::valid(accepted)) return give_up(listener, client, net::kInvalidSocket);

  // Exactly what accept_new_connection does, in the same order.
  int on = 1;
  const bool keepalive_ok =
      ::setsockopt(accepted, SOL_SOCKET, SO_KEEPALIVE,
                   reinterpret_cast<const char*>(&on), sizeof(on)) == 0;
  const bool nodelay_ok =
      ::setsockopt(accepted, IPPROTO_TCP, TCP_NODELAY,
                   reinterpret_cast<const char*>(&on), sizeof(on)) == 0;
  net::closeSocket(accepted);
  net::closeSocket(client);
  net::closeSocket(listener);
  return keepalive_ok && nodelay_ok;
}

std::string httpdListeningPorts(int port, bool ipv6_usable) {
  const std::string text = std::to_string(port);
  return ipv6_usable ? text + ",[::]:" + text : text;
}

bool Httpd::start(int port, Ipv6Mode ipv6) {
  if (impl_->ctx) return false;
  impl_->stopping = false;
  std::string p = std::to_string(port);
  struct mg_callbacks cb;
  std::memset(&cb, 0, sizeof(cb));
  cb.log_message = &httpdLogMessage;

  // Ask the platform rather than assuming it. Falling back to IPv4 is silent: a device with no
  // usable IPv6 is not misconfigured, it is just old, and a warning every boot teaches nobody
  // anything. The listening line below reports what was actually opened.
  const bool ipv6_usable = ipv6 == Ipv6Mode::Auto && httpdFamilyServable(AF_INET6);
  // Nagle off is worth having and not worth failing over. Where the platform refuses the option
  // on accepted sockets, asking for it only produces a log line per connection from the accept
  // loop; civetweb serves the request either way.
  const bool nodelay = httpdFamilyServable(AF_INET);

  auto tryStart = [&](const std::string& ports) -> struct mg_context* {
    // Every live stream holds one worker for as long as it runs, so the pool has to be larger
    // than the number of viewers a house can open at once. With four workers, four live views
    // pinned the pool and the port stopped accepting anything -- the process kept running and
    // the mesh kept heartbeating on its own thread, so it looked like the listener had died.
    std::vector<const char*> opts = {"listening_ports", ports.c_str(),
                                     "num_threads", "16"};
    if (nodelay) {
      opts.push_back("tcp_nodelay");
      opts.push_back("1");
    }
    opts.push_back(nullptr);
    return mg_start(&cb, nullptr, opts.data());
  };

  const std::string preferred = httpdListeningPorts(port, ipv6_usable);
  struct mg_context* ctx = tryStart(preferred);
  std::string mode = preferred;
  // Second net: a listener string the platform probed as usable can still be refused, and an
  // IPv4-only server is worth far more than none.
  if (!ctx && ipv6_usable) {
    ctx = tryStart(p);
    mode = p;
  }
  if (!ctx) {
    // Say who holds the port, not just that we failed to take it.
    std::string reason = "unknown";
    const net::socket_t probe = ::socket(AF_INET, SOCK_STREAM, 0);
    if (net::valid(probe)) {
      sockaddr_in address{};
      address.sin_family = AF_INET;
      address.sin_addr.s_addr = htonl(INADDR_ANY);
      address.sin_port = htons(static_cast<uint16_t>(port));
      reason = ::bind(probe, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0
                   ? "the port is bindable now, so civetweb refused it for another reason"
                   : "bind: " + std::to_string(net::lastError());
      net::closeSocket(probe);
    }
    DB_LOGE("httpd", "mg_start failed port=" + p + ": " + reason);
    return false;
  }
  impl_->ctx = ctx;
  impl_->port = port;
  mg_set_request_handler(ctx, "/", &requestHandler, impl_.get());
  DB_LOGI("httpd", "listening on " + mode);
  return true;
}

void Httpd::stop() {
  if (!impl_->ctx) return;
  {
    // Say how much was collapsed rather than letting it vanish: on a platform that refuses
    // setsockopt on accepted sockets this is roughly two per connection served.
    std::lock_guard<std::mutex> lk(g_log_mu);
    if (g_log_suppressed)
      DB_LOGI("httpd", "suppressed " + std::to_string(g_log_suppressed) +
                           " repeated civetweb messages");
    g_log_suppressed = 0;
    g_logged.clear();
  }
  impl_->stopping = true;
  {


    std::lock_guard<std::mutex> lk(impl_->mu);
    impl_->jpeg_provider = nullptr;
    impl_->mp4_provider = nullptr;
    impl_->mp4_proxy_provider = nullptr;
  }
  mg_stop(impl_->ctx);
  impl_->ctx = nullptr;
  DB_LOGI("httpd", "stopped");
}

int Httpd::port() const { return impl_->port; }

void Httpd::route(const std::string& method, const std::string& path, Handler h) {
  Impl::Route r;
  r.method = method;
  if (!path.empty() && path.back() == '*') {
    r.prefix = true;
    r.path = path.substr(0, path.size() - 1);
  } else {
    r.path = path;
  }
  r.h = std::move(h);
  std::lock_guard<std::mutex> lk(impl_->mu);
  impl_->routes.push_back(std::move(r));
}

void Httpd::setStatic(const std::string& path, const std::string& content_type, Bytes content) {
  std::lock_guard<std::mutex> lk(impl_->mu);
  impl_->statics[path] = Impl::Asset{content_type, std::move(content)};
}

void Httpd::setJpegProvider(std::function<Bytes(int64_t*)> provider, int stream_fps) {
  std::lock_guard<std::mutex> lk(impl_->mu);
  impl_->jpeg_provider = std::move(provider);
  impl_->stream_fps = stream_fps;
}

void Httpd::setVideoRotationProvider(std::function<int()> provider) {
  std::lock_guard<std::mutex> lk(impl_->mu);
  impl_->video_rotation_provider = std::move(provider);
}

void Httpd::setMp4Provider(std::function<Mp4Pull()> provider) {
  std::lock_guard<std::mutex> lk(impl_->mu);
  impl_->mp4_provider = std::move(provider);
}

void Httpd::setMp4ProxyProvider(Mp4ProxyProvider provider) {
  std::lock_guard<std::mutex> lk(impl_->mu);
  impl_->mp4_proxy_provider = std::move(provider);
}

void Httpd::setAuth(std::function<bool(const HttpReq&)> gate,
                    std::vector<std::string> public_prefixes) {
  std::lock_guard<std::mutex> lk(impl_->mu);
  impl_->gate = std::move(gate);
  impl_->public_prefixes = std::move(public_prefixes);
}

}  // namespace db
