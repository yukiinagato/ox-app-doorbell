







// Embedded CivetWeb wrapper. Route handlers are marshaled synchronously to Runloop with a bounded
// timeout. Authentication and media providers run on HTTP workers and must be thread-safe.
#pragma once

#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>

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

struct HttpReq {
  std::string method;  // GET/POST/...
  std::string uri;
  std::string query;
  std::string body;
  std::map<std::string, std::string> headers;
  std::string remote_addr;

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

  bool start(int port, Ipv6Mode ipv6 = Ipv6Mode::Auto);  // 0.0.0.0:port
  void stop();
  int port() const;



  // A trailing * performs prefix matching; other paths are exact.
  void route(const std::string& method, const std::string& path, Handler h);


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

  struct Impl;

 private:
  std::unique_ptr<Impl> impl_;
};

}  // namespace db
