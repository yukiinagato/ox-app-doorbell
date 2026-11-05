







// Embedded CivetWeb wrapper. Route handlers are marshaled synchronously to Runloop with a bounded
// timeout. Queued expiry prevents execution with 503 not_started. A handler that is still running
// at the deadline reports 202 with "outcome":"unknown": a mutation may already have taken effect,
// so callers must re-read state instead of retrying blindly.
// Authentication and media providers run on HTTP workers and must be thread-safe.
//
// Listeners: the plain port serves only loopback clients; any other plain request is redirected
// to the HTTPS port (or refused with 403 tls_required while TLS is unavailable).
#pragma once

#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>

#if defined(DB_HTTPD_TEST_HOOKS)
#include <chrono>
#endif

#include "util/common.h"
#include "util/runloop.h"

namespace db {

// The civetweb "listening_ports" string for a port. Separated out so the decision can be tested
// without standing up a server.
std::string httpdListeningPorts(int port, bool ipv6_usable);

// Whether this civetweb message should reach the log, or has already been reported. The accept
// loop calls this for every connection on a platform that refuses setsockopt on accepted
// sockets, so a repeat costs a set lookup rather than a mutex, a stderr write and a shell sink.
bool httpdShouldLogCivetwebMessage(const std::string& text);

// True when a connection accepted from a listener of this address family tolerates the socket
// options civetweb sets on every accept. Probed on an ephemeral port over loopback.
bool httpdFamilyServable(int family);

// 127.0.0.0/8, ::1 and IPv4-mapped loopback.
bool httpLoopbackAddress(const std::string& address);

// The redirect for a plain non-loopback request, or empty when the Host header is unusable.
std::string httpsRedirectLocation(const std::string& host_header, int https_port,
                                  const std::string& uri, const std::string& query);

struct HttpReq {
  std::string method;  // GET/POST/...
  std::string uri;
  std::string query;
  std::string body;
  std::map<std::string, std::string> headers;
  std::string remote_addr;
  bool tls = false;

  bool loopback() const { return httpLoopbackAddress(remote_addr); }
  std::string param(const std::string& key, const std::string& def = "") const;
  std::string cookie(const std::string& name) const;
};

struct HttpResp {
  int status = 200;
  std::string content_type = "application/json; charset=utf-8";
  std::string body;
  std::map<std::string, std::string> headers;
  static HttpResp json(const std::string& body, int status = 200);
  static HttpResp text(const std::string& body, int status = 200);
  static HttpResp notFound();
};

class Httpd {
 public:
  using Handler = std::function<HttpResp(const HttpReq&)>;

  explicit Httpd(Runloop& loop);
  ~Httpd();

  // Whether to add an IPv6 wildcard listener beside the IPv4 one.
  //
  // Auto probes the platform first. iOS 5 will accept a connection from a dual-stack listener
  // and then refuse setsockopt on the accepted socket, so a listener that binds is not by
  // itself proof that the platform can serve from it. A shell that already knows better can
  // pass Off and skip the probe.
  enum class Ipv6Mode { Auto, Off };

  // TLS listener settings; set before start(). pem is the certificate followed by its key.
  struct TlsConfig {
    int port = 0;
    std::string pem;
  };
  void setTls(TlsConfig config);
  bool tlsActive() const;
  int tlsPort() const;

  bool start(int port, Ipv6Mode ipv6 = Ipv6Mode::Auto);  // 0.0.0.0:port
  void stop();
  int port() const;

#if defined(DB_HTTPD_TEST_HOOKS)
  // Pauses only the HTTP waiter after posting, to exercise the loop's own deadline check.
  void setDispatchBeforeWaitForTesting(
      std::function<void(std::chrono::steady_clock::time_point)> hook);
#endif



  // A trailing * performs prefix matching; other paths are exact.
  void route(const std::string& method, const std::string& path, Handler h);

  // For protocols that await asynchronous loop/network completion on the HTTP worker. The
  // handler must own its request state, bound its wait, and be cancelled by its owner before
  // stop(); stop joins every worker before releasing the registered handlers.
  void routeWorker(const std::string& method, const std::string& path, Handler h);


  void setStatic(const std::string& path, const std::string& content_type, Bytes content);



  // The provider may be called from any thread; empty bytes produce a temporary unavailable reply.
  void setJpegProvider(std::function<Bytes(int64_t*)> provider, int stream_fps = 8);

  // Clockwise video rotation (0/90/180/270), exposed in MJPEG part headers and
  // /video-meta. The provider must return quickly and be safe on arbitrary threads.
  void setVideoRotationProvider(std::function<int()> provider);







  // Pull functions must bound blocking so stop and client disconnects remain responsive.
  using Mp4Pull = std::function<Bytes(bool* ended)>;
  void setMp4Provider(std::function<Mp4Pull()> provider);

  // Same-origin panel proxy. The factory authenticates and resolves the requested door,
  // then returns a bounded pull stream. status receives 400/403/404/503 on refusal.
  using Mp4ProxyProvider = std::function<Mp4Pull(const HttpReq&, int* status)>;
  void setMp4ProxyProvider(Mp4ProxyProvider provider);



  void setAuth(std::function<bool(const HttpReq&)> gate,
               std::vector<std::string> public_prefixes);

  // Checked before /stream.mjpeg, /stream.mp4 and /snapshot.jpg are served. Returns 0 to allow,
  // otherwise the HTTP status to answer with. Runs on HTTP workers.
  void setMediaAuth(std::function<int(const HttpReq&)> check);

  // Concurrent long-lived media responses; more receive 503 with Retry-After.
  void setMaxStreams(unsigned max_streams);
  unsigned activeStreams() const;

  // A GET prefix route whose response body is streamed from a bounded pull on the worker.
  struct StreamResponse {
    int status = 503;
    std::string content_type = "application/json; charset=utf-8";
    std::map<std::string, std::string> headers;
    std::string body;  // Used when pull is empty.
    Mp4Pull pull;      // Streams until ended; counts against setMaxStreams.
  };
  using StreamFactory = std::function<StreamResponse(const HttpReq&)>;
  void routeStream(const std::string& path_prefix, StreamFactory factory);

  struct Impl;

 private:
  void registerRoute(const std::string& method, const std::string& path, Handler h, bool worker);
  std::unique_ptr<Impl> impl_;
};

}  // namespace db
