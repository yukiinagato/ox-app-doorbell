// TLS identity and pinned Core-to-Core HTTP(S) client built on mbedTLS. The identity is a
// per-node ECDSA P-256 key with a self-signed certificate; peers pin the SHA-256 of the
// certificate's DER encoding, which each member replicates as devices.<id>.tls_sha256.
#pragma once

#include <cstdint>
#include <chrono>
#include <map>
#include <memory>
#include <string>

#include "util/common.h"

namespace db {
namespace tls {

struct Identity {
  std::string cert_pem;
  std::string key_pem;
  std::string sha256_hex;  // Lowercase hex SHA-256 of the certificate DER.
};

// Creates a fresh key and a self-signed certificate valid for twenty years.
bool generateIdentity(const std::string& common_name, Identity* out, std::string* error);

// Validates that the key matches the certificate and fills sha256_hex.
bool loadIdentity(const std::string& cert_pem, const std::string& key_pem, Identity* out);

// The PEM handed to the HTTPS listener: certificate followed by key.
std::string listenerPem(const Identity& identity);

struct Endpoint {
  std::string host;  // Literal address or name; IPv6 may be bracketed.
  int port = 0;
  bool tls = false;
  std::string pin_sha256;  // Required when tls is true.
};

// One bounded HTTP/1.1 request (GET unless method says otherwise). open() connects, completes the handshake, sends the request and
// reads the response head within the timeout; pull() then streams the body. All calls block
// for at most their stated bound and may run on any single thread at a time.
class HttpStream {
 public:
  HttpStream(Endpoint endpoint, std::string path_and_query,
             std::map<std::string, std::string> headers, std::string method = "GET",
             std::string body = "");
  ~HttpStream();
  HttpStream(const HttpStream&) = delete;
  HttpStream& operator=(const HttpStream&) = delete;

  struct Timings {
    int64_t resolve_ms = 0, connect_ms = 0, tls_ms = 0, request_ms = 0, headers_ms = 0;
    int64_t first_body_ms = -1;
  };
  const Timings& timings() const { return timings_; }
  bool open(int timeout_ms = 5000);
  int status() const { return status_; }
  // Lowercased response header value, or empty.
  std::string header(const std::string& lowercase_name) const;
  // Returns up to 64 KiB; empty with *ended false means "nothing yet" after a 500 ms wait.
  Bytes pull(bool* ended);
  // Reads the remaining body up to max_bytes within timeout_ms. False on overflow or error.
  bool readAll(size_t max_bytes, int timeout_ms, Bytes* out);
  const std::string& error() const { return error_; }

  struct Impl;

 private:
  void close();

  Timings timings_;
  std::chrono::steady_clock::time_point started_at_;
  bool timed_body_ = false;
  Endpoint endpoint_;
  std::string path_;
  std::map<std::string, std::string> headers_;
  std::string method_;
  std::string body_;
  std::unique_ptr<Impl> impl_;
  int status_ = 0;
  std::map<std::string, std::string> response_headers_;
  Bytes pending_;
  bool opened_ = false;
  bool closed_ = false;
  std::string error_;
};

}  // namespace tls
}  // namespace db

extern "C" int db_tls_random(void* ctx, unsigned char* out, size_t len);
