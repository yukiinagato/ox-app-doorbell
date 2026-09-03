// The pairing QR payload, defined once so every shell renders and reads the same thing.
//
//   doorbell://pair?host=<ip:port>&pin=<6 digits>&exp=<unix seconds>&cluster=<name>
//
// A device with the app installed opens the link straight into the join flow. Only these four
// query keys are defined; a parser ignores any other key rather than failing, so the format can
// gain one later without breaking the shells shipping today. host and pin are required.
//
// Values are percent-encoded with the RFC 3986 unreserved set, so a cluster name with spaces or
// Japanese survives the round trip. "+" is a literal plus, never a space: cluster names are not
// form data.
#pragma once

#include <cstdint>
#include <string>

namespace db {
namespace pair_uri {

constexpr const char* kScheme = "doorbell://pair";

std::string percentEncode(const std::string& value);
// Decodes %XX escapes. A malformed escape is kept literally rather than dropped, so a name is
// never silently truncated.
std::string percentDecode(const std::string& value);

// exp_unix_s of zero leaves the expiry out; cluster may be empty and is then omitted.
std::string build(const std::string& host, const std::string& pin, int64_t exp_unix_s,
                  const std::string& cluster);

struct Parsed {
  bool ok = false;
  std::string err;  // bad_scheme | missing_pin | missing_host | expired
  std::string host;
  std::string pin;
  int64_t exp = 0;
  std::string cluster;
};

// now_unix_s of zero skips the expiry check, for a caller with no trustworthy clock.
Parsed parse(const std::string& uri, int64_t now_unix_s);

}  // namespace pair_uri
}  // namespace db
