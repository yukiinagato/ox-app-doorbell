#include "util/pair_uri.h"

#include <cstdlib>

namespace db {
namespace pair_uri {
namespace {

bool unreserved(char c) {
  return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
         c == '-' || c == '.' || c == '_' || c == '~';
}

int hexValue(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

}  // namespace

std::string percentEncode(const std::string& value) {
  static const char* kHex = "0123456789ABCDEF";
  std::string out;
  out.reserve(value.size());
  for (unsigned char c : value) {
    if (unreserved(static_cast<char>(c))) {
      out.push_back(static_cast<char>(c));
      continue;
    }
    out.push_back('%');
    out.push_back(kHex[c >> 4]);
    out.push_back(kHex[c & 0x0F]);
  }
  return out;
}

std::string percentDecode(const std::string& value) {
  std::string out;
  out.reserve(value.size());
  for (size_t i = 0; i < value.size(); i++) {
    if (value[i] != '%' || i + 2 >= value.size()) {
      out.push_back(value[i]);
      continue;
    }
    const int high = hexValue(value[i + 1]);
    const int low = hexValue(value[i + 2]);
    if (high < 0 || low < 0) {
      out.push_back(value[i]);
      continue;
    }
    out.push_back(static_cast<char>(high * 16 + low));
    i += 2;
  }
  return out;
}

std::string build(const std::string& host, const std::string& pin, int64_t exp_unix_s,
                  const std::string& cluster) {
  std::string out = std::string(kScheme) + "?host=" + percentEncode(host) +
                    "&pin=" + percentEncode(pin);
  if (exp_unix_s > 0) out += "&exp=" + std::to_string(exp_unix_s);
  if (!cluster.empty()) out += "&cluster=" + percentEncode(cluster);
  return out;
}

Parsed parse(const std::string& uri, int64_t now_unix_s) {
  Parsed result;
  const std::string prefix = std::string(kScheme) + "?";
  // The scheme is matched case-insensitively in its literal part, because some QR readers
  // normalise the scheme of a URI before handing it over.
  if (uri.size() <= prefix.size()) {
    result.err = "bad_scheme";
    return result;
  }
  std::string head = uri.substr(0, prefix.size());
  for (char& c : head) {
    if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
  }
  if (head != prefix) {
    result.err = "bad_scheme";
    return result;
  }

  const std::string query = uri.substr(prefix.size());
  size_t position = 0;
  while (position <= query.size()) {
    const size_t next = query.find('&', position);
    const std::string pair =
        query.substr(position, next == std::string::npos ? std::string::npos : next - position);
    const size_t equals = pair.find('=');
    if (equals != std::string::npos) {
      const std::string key = pair.substr(0, equals);
      const std::string value = percentDecode(pair.substr(equals + 1));
      // Unknown keys are ignored on purpose, so the format can grow without breaking parsers.
      if (key == "host") result.host = value;
      else if (key == "pin") result.pin = value;
      else if (key == "cluster") result.cluster = value;
      else if (key == "exp") result.exp = std::strtoll(value.c_str(), nullptr, 10);
    }
    if (next == std::string::npos) break;
    position = next + 1;
  }

  if (result.pin.empty()) {
    result.err = "missing_pin";
    return result;
  }
  if (result.host.empty()) {
    result.err = "missing_host";
    return result;
  }
  if (result.exp > 0 && now_unix_s > 0 && now_unix_s > result.exp) {
    result.err = "expired";
    return result;
  }
  result.ok = true;
  return result;
}

}  // namespace pair_uri
}  // namespace db
