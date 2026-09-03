#include "node/node.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <atomic>
#include <chrono>
#include <cctype>
#include <cmath>
#include <deque>
#include <mutex>
#include <thread>
#include <set>
#include <tuple>

#include "bridge/ha_bridge.h"
#include "bridge/telegram.h"
#include "httpd/webui_assets.h"
#include "media/frame_bus.h"
#include "media/qr_scanner.h"
#include "media/motion_detector.h"
#include "media/video_track.h"
#include "mesh/socket_compat.h"
#include "mesh/tcp_transport.h"
#include "mesh/udp_beacon.h"
#include "monocypher.h"
#include "sipctl/sipctl.h"
#ifdef _WIN32
#include "media/camera_win.h"
#include "media/encoder_win.h"
#endif
#include "util/color.h"
#include "util/common.h"
#include "util/ids.h"
#include "util/json.h"
#include "util/pair_uri.h"
#include "util/log.h"
#include "util/sntp.h"
#include "util/tz.h"

namespace db {

std::string sanitizeCaps(const std::string& caps_json, bool has_https) {
  auto doc = json::parse(caps_json);
  if (!doc || !cJSON_IsObject(doc.get())) doc = json::obj();
  if (!has_https) json::setBool(doc.get(), "tls12", false);
  return json::dump(doc.get());
}

namespace {
constexpr const char* kTag = "node";

std::string hashPassword(const std::string& pw, const std::string& salt_hex) {
  Bytes salt;
  hexDecode(salt_hex, salt);
  Bytes buf = salt;
  buf.insert(buf.end(), pw.begin(), pw.end());
  uint8_t out[32];
  crypto_blake2b(out, sizeof(out), buf.data(), buf.size());
  return hexEncode(out, sizeof(out));
}

// Comparison whose duration does not depend on where two digests first differ.
bool constantTimeEquals(const std::string& a, const std::string& b) {
  if (a.size() != b.size()) return false;
  unsigned char diff = 0;
  for (size_t i = 0; i < a.size(); i++)
    diff = static_cast<unsigned char>(diff | (static_cast<unsigned char>(a[i]) ^
                                              static_cast<unsigned char>(b[i])));
  return diff == 0;
}

// "host:port" → host
std::string hostOf(const std::string& addr) {
  auto p = addr.rfind(':');
  return p == std::string::npos ? addr : addr.substr(0, p);
}

// Mesh advertisements can contain the same interfaces in a different order on every refresh.
// Pick a deterministic HTTP endpoint so live views are not torn down merely because that order
// changed. Private IPv4 is preferred because it is directly reachable across the supported LAN.
std::string preferredPeerHost(const std::vector<std::string>& addrs) {
  std::vector<std::pair<int, std::string>> candidates;
  for (const auto& addr : addrs) {
    const std::string host = hostOf(addr);
    if (host.empty()) continue;
    int rank = 2;
    int first = -1, second = -1, third = -1, fourth = -1;
    char tail = '\0';
    const bool ipv4 = std::sscanf(host.c_str(), "%d.%d.%d.%d%c", &first, &second,
                                  &third, &fourth, &tail) == 4;
    if (ipv4 && (first == 10 || (first == 192 && second == 168) ||
                 (first == 172 && second >= 16 && second <= 31)))
      rank = 0;
    else if (ipv4)
      rank = 1;
    candidates.emplace_back(rank, host);
  }
  if (candidates.empty()) return "";
  std::sort(candidates.begin(), candidates.end());
  return candidates.front().second;
}

bool safeProbeHost(const std::string& host) {
  if (host.empty() || host.size() > 253) return false;
  for (unsigned char ch : host) {
    if (!(std::isalnum(ch) || ch == '.' || ch == '-' || ch == ':' || ch == '[' || ch == ']'))
      return false;
  }
  return true;
}



bool parseSipRemote(const std::string& remote, std::string* user, std::string* host) {
  std::string uri = remote;
  size_t lt = uri.find('<');
  if (lt != std::string::npos) {
    size_t gt = uri.find('>', lt);
    uri = uri.substr(lt + 1, gt == std::string::npos ? std::string::npos : gt - lt - 1);
  }
  size_t s = uri.find("sip:");
  if (s == std::string::npos) return false;
  uri = uri.substr(s + 4);
  size_t sc = uri.find(';');
  if (sc != std::string::npos) uri = uri.substr(0, sc);
  size_t at = uri.find('@');
  if (at != std::string::npos) {
    *user = uri.substr(0, at);
    uri = uri.substr(at + 1);
  } else {
    user->clear();
  }
  *host = hostOf(uri);
  return !host->empty();
}


int parseHhmm(const std::string& s) {
  int h = 0, m = 0;
  char tail = 0;
  if (std::sscanf(s.c_str(), "%d:%d%c", &h, &m, &tail) != 2) return -1;
  if (h < 0 || h > 24 || m < 0 || m > 59) return -1;
  return h * 60 + m;
}


int64_t floorDiv(int64_t a, int64_t b) {
  int64_t q = a / b;
  if ((a % b) != 0 && ((a < 0) != (b < 0))) --q;
  return q;
}


constexpr size_t kAssetMaxBytes = 3 * 1024 * 1024;
// Event retention: the newest records of every origin always survive, whatever the age cutoff is.
constexpr size_t kEventRetentionPerOrigin = 5000;
// Call history defaults. A page is bounded so one HTTP call cannot serialize the whole database.
constexpr size_t kCallLogDefaultLimit = 50;
constexpr size_t kCallLogMaxLimit = 500;
constexpr int64_t kAssetGcGraceMs = 10 * 60 * 1000;
constexpr const char* kAssetTypes[] = {"image/jpeg", "image/png", "audio/mpeg", "audio/wav"};

bool assetTypeAllowed(const std::string& type) {
  for (const char* t : kAssetTypes)
    if (type == t) return true;
  return false;
}

bool parseStyleColor(const std::string& value, double* luminance, int* alpha) {
  if (value.size() != 7 || value[0] != '#') return false;
  auto nibble = [](char c) -> int {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
  };
  int bytes[4] = {0, 0, 0, 255};
  for (size_t i = 0; i < (value.size() - 1) / 2; ++i) {
    int hi = nibble(value[1 + i * 2]);
    int lo = nibble(value[2 + i * 2]);
    if (hi < 0 || lo < 0) return false;
    bytes[i] = hi * 16 + lo;
  }
  auto linear = [](double c) {
    c /= 255.0;
    return c <= 0.04045 ? c / 12.92 : std::pow((c + 0.055) / 1.055, 2.4);
  };
  if (luminance)
    *luminance = 0.2126 * linear(bytes[0]) + 0.7152 * linear(bytes[1]) +
                 0.0722 * linear(bytes[2]);
  if (alpha) *alpha = bytes[3];
  return true;
}

struct EmergencyPalette {
  std::string background = "#8F1010";
  std::string foreground = "#FFFFFF";
  std::string accent = "#FFD166";
};

EmergencyPalette safeEmergencyPalette(const cJSON* presentation) {
  EmergencyPalette fallback;
  EmergencyPalette candidate;
  candidate.background = json::getString(presentation, "background", fallback.background);
  candidate.foreground = json::getString(presentation, "foreground", fallback.foreground);
  candidate.accent = json::getString(presentation, "accent", fallback.accent);
  double background = 0, foreground = 0, accent = 0;
  int alpha = 255;
  if (!parseStyleColor(candidate.background, &background, &alpha) ||
      !parseStyleColor(candidate.foreground, &foreground, &alpha) ||
      !parseStyleColor(candidate.accent, &accent, &alpha))
    return fallback;
  auto contrast = [](double a, double b) {
    return (std::max(a, b) + 0.05) / (std::min(a, b) + 0.05);
  };
  if (contrast(foreground, background) < 4.5 || contrast(accent, background) < 3.0)
    return fallback;
  return candidate;
}

bool safetyUiElement(const std::string& element) {
  return element == "sos.trigger" || element == "sos.cancel" ||
      element == "cancel.call" || element == "call.end" ||
      element == "maintenance.exit";
}

// A readability finding that does not block the write. Custom colours are the operator's
// choice: core reports the measured WCAG ratio and saves anyway, so a deliberate low-contrast
// theme is possible and an accidental one is visible.
struct ConfigWarning {
  std::string key;
  std::string property;
  double contrast = 0;
  std::string message_key;
};

void addContrastWarning(std::vector<ConfigWarning>* warnings, const std::string& key,
                        const std::string& property, double ratio) {
  if (!warnings) return;
  ConfigWarning warning;
  warning.key = key;
  warning.property = property;
  // One decimal is what the UI shows; keeping more invites a diff on every render.
  warning.contrast = std::floor(ratio * 10.0 + 0.5) / 10.0;
  warning.message_key = "theme.low_contrast";
  warnings->push_back(std::move(warning));
}

bool uiStyleOverrideValid(const std::string& key, const cJSON* value, std::string* error,
                          std::vector<ConfigWarning>* warnings = nullptr) {
  const std::string marker = ".local.ui.elements.";
  const size_t marker_pos = key.find(marker);
  if (key.compare(0, 8, "devices.") != 0 || marker_pos == std::string::npos) return true;
  if (!cJSON_IsObject(value)) {
    *error = "style value must be an object";
    return false;
  }
  const std::string element = key.substr(marker_pos + marker.size());
  const bool safety = safetyUiElement(element);
  double foreground = -1.0, background = -1.0, accent = -1.0, border = -1.0;
  const cJSON* field = nullptr;
  cJSON_ArrayForEach(field, value) {
    if (!field->string) continue;
    const std::string name = field->string;
    if (name == "scale" || name == "font_scale") {
      if (!cJSON_IsNumber(field) || field->valuedouble < 0.75 || field->valuedouble > 2.0) {
        *error = name + " must be within 0.75..2.0";
        return false;
      }
      if (safety && field->valuedouble < 1.0) {
        *error = "safety-critical scale and font_scale must be at least 1.0";
        return false;
      }
      continue;
    }
    if (name == "radius") {
      if (!cJSON_IsNumber(field) || field->valuedouble < 0 || field->valuedouble > 64) {
        *error = "radius must be within 0..64";
        return false;
      }
      continue;
    }
    if (name == "foreground" || name == "background" || name == "accent" ||
        name == "border") {
      int alpha = 255;
      double lum = 0;
      if (!cJSON_IsString(field) || !parseStyleColor(field->valuestring, &lum, &alpha)) {
        *error = name + " must be #RRGGBB";
        return false;
      }
      if (name == "foreground") foreground = lum;
      if (name == "background") background = lum;
      if (name == "accent") accent = lum;
      if (name == "border") border = lum;
      continue;
    }
    *error = "unsupported style property: " + name;
    return false;
  }
  auto contrast = [](double a, double b) {
    return (std::max(a, b) + 0.05) / (std::min(a, b) + 0.05);
  };
  // WCAG 2.1 AA: 4.5:1 for text, 3:1 for large text and UI components. A shortfall is reported,
  // not refused; the operator sees the measured ratio inline and decides.
  if (foreground >= 0 && background >= 0 && contrast(foreground, background) < 4.5)
    addContrastWarning(warnings, key, "foreground", contrast(foreground, background));
  if (accent >= 0 && background >= 0 && contrast(accent, background) < 3.0)
    addContrastWarning(warnings, key, "accent", contrast(accent, background));
  if (border >= 0 && background >= 0 && contrast(border, background) < 3.0)
    addContrastWarning(warnings, key, "border", contrast(border, background));
  return true;
}

bool uiStyleViewportValid(const std::string& key, const cJSON* value, const cJSON* viewport,
                          std::string* error,
                          std::vector<ConfigWarning>* warnings = nullptr) {
  if (!uiStyleOverrideValid(key, value, error, warnings)) return false;
  if (key.find(".local.ui.elements.") == std::string::npos) return true;
  const double scale_min = json::get(viewport, "scale_min") &&
          cJSON_IsNumber(json::get(viewport, "scale_min"))
      ? json::get(viewport, "scale_min")->valuedouble : 0.75;
  const double scale_max = json::get(viewport, "scale_max") &&
          cJSON_IsNumber(json::get(viewport, "scale_max"))
      ? json::get(viewport, "scale_max")->valuedouble : 2.0;
  const double minimum_touch = json::get(viewport, "minimum_touch") &&
          cJSON_IsNumber(json::get(viewport, "minimum_touch"))
      ? json::get(viewport, "minimum_touch")->valuedouble : 44.0;
  for (const char* property : {"scale", "font_scale"}) {
    const cJSON* field = json::get(value, property);
    if (field && (!cJSON_IsNumber(field) || field->valuedouble < scale_min ||
                  field->valuedouble > scale_max)) {
      *error = std::string(property) + " is outside the target viewport limit";
      return false;
    }
  }
  const cJSON* radius = json::get(value, "radius");
  if (radius && (!cJSON_IsNumber(radius) || radius->valuedouble > minimum_touch)) {
    *error = "radius exceeds the target viewport touch metric";
    return false;
  }
  return true;
}

bool uiManifestValid(const std::string& manifest_json, std::string* error) {
  auto manifest = json::parse(manifest_json);
  if (!manifest || !cJSON_IsObject(manifest.get()) ||
      json::getInt(manifest.get(), "schema_version") != 1) {
    *error = "ui_manifest must be a schema version 1 object";
    return false;
  }
  const cJSON* viewport = json::get(manifest.get(), "viewport");
  const std::string units = json::getString(manifest.get(), "units");
  if (units != "logical" && units != "dp" && units != "pt" && units != "effective_px") {
    *error = "ui_manifest units must be logical, dp, pt, or effective_px";
    return false;
  }
  auto number = [viewport](const char* name) {
    const cJSON* value = json::get(viewport, name);
    return cJSON_IsNumber(value) ? value->valuedouble : 0.0;
  };
  const double minimum_touch = number("minimum_touch");
  const double scale_min = number("scale_min");
  const double scale_max = number("scale_max");
  if (!cJSON_IsObject(viewport) || minimum_touch < 44 || scale_min < 0.75 ||
      scale_max > 2.0 || scale_min > scale_max) {
    *error = "ui_manifest viewport violates touch or scale limits";
    return false;
  }
  const cJSON* elements = json::get(manifest.get(), "elements");
  if (!cJSON_IsObject(elements) || !elements->child) {
    *error = "ui_manifest requires semantic elements";
    return false;
  }
  const std::set<std::string> allowed = {"scale", "font_scale", "foreground", "background",
                                         "accent", "border", "radius"};
  const cJSON* element = nullptr;
  cJSON_ArrayForEach(element, elements) {
    const std::string id = element->string ? element->string : "";
    if (id.empty() || id.size() > 128 || !cJSON_IsObject(element)) {
      *error = "ui_manifest contains an invalid semantic element";
      return false;
    }
    for (char ch : id) {
      if (!(std::isalnum(static_cast<unsigned char>(ch)) || ch == '.' || ch == '_' ||
            ch == '-')) {
        *error = "ui_manifest semantic IDs use an invalid character";
        return false;
      }
    }
    const cJSON* properties = json::get(element, "properties");
    const cJSON* defaults = json::get(element, "defaults");
    const cJSON* safety = json::get(element, "safety_critical");
    if (!cJSON_IsArray(properties) || cJSON_GetArraySize(properties) == 0 ||
        !cJSON_IsObject(defaults) || !cJSON_IsBool(safety) ||
        (safetyUiElement(id) && !cJSON_IsTrue(safety))) {
      *error = "ui_manifest elements require properties, defaults, and safety_critical";
      return false;
    }
    std::set<std::string> declared;
    const cJSON* property = nullptr;
    cJSON_ArrayForEach(property, properties) {
      const std::string name = cJSON_IsString(property) && property->valuestring
          ? property->valuestring : "";
      if (!allowed.count(name) || !declared.insert(name).second || !json::get(defaults, name.c_str())) {
        *error = "ui_manifest properties must be unique, supported, and have defaults";
        return false;
      }
    }
    const cJSON* default_value = nullptr;
    cJSON_ArrayForEach(default_value, defaults) {
      if (!default_value->string || !declared.count(default_value->string)) {
        *error = "ui_manifest defaults may contain only declared properties";
        return false;
      }
    }
    std::string style_error;
    if (!uiStyleViewportValid("devices.manifest.local.ui.elements." + id, defaults, viewport,
                              &style_error)) {
      *error = "ui_manifest default for " + id + " is invalid: " + style_error;
      return false;
    }
  }
  return true;
}

const char* baseWebUiManifestJson() {
  return R"({"schema_version":1,"units":"effective_px","viewport":{"minimum_touch":44,"scale_min":0.75,"scale_max":2.0},"elements":{"call.primary":{"properties":["scale","font_scale","foreground","background","accent","border","radius"],"defaults":{"scale":1,"font_scale":1,"foreground":"#E8EDF2","background":"#1A2027","accent":"#4DA3FF","border":"#4DA3FF","radius":12},"safety_critical":false},"cancel.call":{"properties":["scale","font_scale","foreground","background","accent","border","radius"],"defaults":{"scale":1,"font_scale":1,"foreground":"#FFFFFF","background":"#8D2932","accent":"#FFFFFF","border":"#FFFFFF","radius":12},"safety_critical":true},"call.end":{"properties":["scale","font_scale","foreground","background","accent","border","radius"],"defaults":{"scale":1,"font_scale":1,"foreground":"#FFFFFF","background":"#8D2932","accent":"#FFFFFF","border":"#FFFFFF","radius":12},"safety_critical":true},"purpose.button":{"properties":["scale","font_scale","foreground","background","accent","border","radius"],"defaults":{"scale":1,"font_scale":1,"foreground":"#E8EDF2","background":"#1A2027","accent":"#4DA3FF","border":"#4DA3FF","radius":12},"safety_critical":false},"ring.title":{"properties":["scale","font_scale","foreground","background","accent","border","radius"],"defaults":{"scale":1,"font_scale":1,"foreground":"#E8EDF2","background":"#1A2027","accent":"#4DA3FF","border":"#4DA3FF","radius":12},"safety_critical":false},"ring.action":{"properties":["scale","font_scale","foreground","background","accent","border","radius"],"defaults":{"scale":1,"font_scale":1,"foreground":"#E8EDF2","background":"#1A2027","accent":"#4DA3FF","border":"#4DA3FF","radius":12},"safety_critical":false},"status.offline":{"properties":["scale","font_scale","foreground","background","accent","border","radius"],"defaults":{"scale":1,"font_scale":1,"foreground":"#FFFFFF","background":"#8D2932","accent":"#FFFFFF","border":"#FFFFFF","radius":12},"safety_critical":false}}})";
}

const char* webOnlyUiElementsJson() {
  return R"({"sos.trigger":{"properties":["scale","font_scale","foreground","background","accent","border","radius"],"defaults":{"scale":1,"font_scale":1,"foreground":"#FFFFFF","background":"#8F1010","accent":"#FFD166","border":"#FFFFFF","radius":12},"safety_critical":true},"reply.button":{"properties":["scale","font_scale","foreground","background","accent","border","radius"],"defaults":{"scale":1,"font_scale":1,"foreground":"#E8EDF2","background":"#1A2027","accent":"#4DA3FF","border":"#4DA3FF","radius":12},"safety_critical":false},"monitor.close":{"properties":["scale","font_scale","foreground","background","accent","border","radius"],"defaults":{"scale":1,"font_scale":1,"foreground":"#FFFFFF","background":"#274261","accent":"#4DA3FF","border":"#4DA3FF","radius":12},"safety_critical":false}})";
}

bool secretRefValid(const std::string& ref) {
  if (ref.rfind("secret:", 0) != 0 || ref.size() <= 7 || ref.size() > 135) return false;
  for (size_t i = 7; i < ref.size(); ++i) {
    const unsigned char c = static_cast<unsigned char>(ref[i]);
    if (!(std::isalnum(c) || c == '.' || c == '_' || c == '-')) return false;
  }
  return true;
}

bool webPushSenderUrlValid(const std::string& url) {
  if (url.size() < 9 || url.size() > 2048 || url.rfind("https://", 0) != 0)
    return false;
  for (unsigned char ch : url) {
    if (ch <= 0x20 || ch >= 0x7f || ch == '\\') return false;
  }
  const size_t authority_begin = 8;
  const size_t authority_end = url.find_first_of("/?#", authority_begin);
  const std::string authority = url.substr(
      authority_begin, authority_end == std::string::npos
          ? std::string::npos : authority_end - authority_begin);
  if (authority.empty() || authority.find('@') != std::string::npos) return false;

  std::string host;
  std::string port;
  if (authority[0] == '[') {
    const size_t close = authority.find(']');
    if (close == std::string::npos || close == 1) return false;
    host = authority.substr(1, close - 1);
    for (unsigned char ch : host) {
      if (!(std::isxdigit(ch) || ch == ':' || ch == '.')) return false;
    }
    if (close + 1 < authority.size()) {
      if (authority[close + 1] != ':') return false;
      port = authority.substr(close + 2);
    }
  } else {
    const size_t colon = authority.rfind(':');
    if (colon != std::string::npos) {
      if (authority.find(':') != colon) return false;
      host = authority.substr(0, colon);
      port = authority.substr(colon + 1);
    } else {
      host = authority;
    }
    if (host.empty() || host.front() == '.' || host.back() == '.' ||
        host.front() == '-' || host.back() == '-' || host.find("..") != std::string::npos)
      return false;
    for (unsigned char ch : host) {
      if (!(std::isalnum(ch) || ch == '.' || ch == '-')) return false;
    }
  }
  if (!port.empty()) {
    if (port.size() > 5 ||
        !std::all_of(port.begin(), port.end(), [](unsigned char ch) { return std::isdigit(ch); }))
      return false;
    const long parsed = std::strtol(port.c_str(), nullptr, 10);
    if (parsed < 1 || parsed > 65535) return false;
  } else if (!authority.empty() && authority.back() == ':') {
    return false;
  }
  return true;
}

struct P256Field {
  uint32_t limb[8]{};  // Little-endian base-2^32 limbs.
};

constexpr uint32_t kP256Prime[8] = {
    0xffffffffU, 0xffffffffU, 0xffffffffU, 0x00000000U,
    0x00000000U, 0x00000000U, 0x00000001U, 0xffffffffU,
};
constexpr uint32_t kP256B[8] = {
    0x27d2604bU, 0x3bce3c3eU, 0xcc53b0f6U, 0x651d06b0U,
    0x769886bcU, 0xb3ebbd55U, 0xaa3a93e7U, 0x5ac635d8U,
};

bool p256AtLeast(const uint32_t* value, const uint32_t* bound) {
  for (int i = 7; i >= 0; --i) {
    if (value[i] != bound[i]) return value[i] > bound[i];
  }
  return true;
}

void p256SubtractRaw(uint32_t* value, const uint32_t* subtrahend) {
  uint64_t borrow = 0;
  for (size_t i = 0; i < 8; ++i) {
    const uint64_t sub = static_cast<uint64_t>(subtrahend[i]) + borrow;
    const uint64_t current = value[i];
    value[i] = static_cast<uint32_t>(current - sub);
    borrow = current < sub ? 1 : 0;
  }
}

P256Field p256Add(const P256Field& left, const P256Field& right) {
  P256Field out;
  uint64_t carry = 0;
  for (size_t i = 0; i < 8; ++i) {
    const uint64_t sum = static_cast<uint64_t>(left.limb[i]) + right.limb[i] + carry;
    out.limb[i] = static_cast<uint32_t>(sum);
    carry = sum >> 32;
  }
  if (carry || p256AtLeast(out.limb, kP256Prime)) p256SubtractRaw(out.limb, kP256Prime);
  return out;
}

P256Field p256Subtract(const P256Field& left, const P256Field& right) {
  P256Field out;
  uint64_t borrow = 0;
  for (size_t i = 0; i < 8; ++i) {
    const uint64_t sub = static_cast<uint64_t>(right.limb[i]) + borrow;
    const uint64_t current = left.limb[i];
    out.limb[i] = static_cast<uint32_t>(current - sub);
    borrow = current < sub ? 1 : 0;
  }
  if (borrow) {
    uint64_t carry = 0;
    for (size_t i = 0; i < 8; ++i) {
      const uint64_t sum = static_cast<uint64_t>(out.limb[i]) + kP256Prime[i] + carry;
      out.limb[i] = static_cast<uint32_t>(sum);
      carry = sum >> 32;
    }
  }
  return out;
}

P256Field p256Reduce(const uint32_t* wide) {
  uint32_t remainder[9]{};
  for (int bit = 511; bit >= 0; --bit) {
    uint64_t carry = static_cast<uint64_t>((wide[bit / 32] >> (bit % 32)) & 1U);
    for (size_t i = 0; i < 9; ++i) {
      const uint64_t shifted = (static_cast<uint64_t>(remainder[i]) << 1) | carry;
      remainder[i] = static_cast<uint32_t>(shifted);
      carry = shifted >> 32;
    }
    if (remainder[8] != 0 || p256AtLeast(remainder, kP256Prime)) {
      uint64_t borrow = 0;
      for (size_t i = 0; i < 8; ++i) {
        const uint64_t sub = static_cast<uint64_t>(kP256Prime[i]) + borrow;
        const uint64_t current = remainder[i];
        remainder[i] = static_cast<uint32_t>(current - sub);
        borrow = current < sub ? 1 : 0;
      }
      remainder[8] = static_cast<uint32_t>(remainder[8] - borrow);
    }
  }
  P256Field out;
  for (size_t i = 0; i < 8; ++i) out.limb[i] = remainder[i];
  return out;
}

P256Field p256Multiply(const P256Field& left, const P256Field& right) {
  uint32_t wide[16]{};
  for (size_t i = 0; i < 8; ++i) {
    uint64_t carry = 0;
    for (size_t j = 0; j < 8; ++j) {
      const uint64_t value = static_cast<uint64_t>(wide[i + j]) +
                             static_cast<uint64_t>(left.limb[i]) * right.limb[j] + carry;
      wide[i + j] = static_cast<uint32_t>(value);
      carry = value >> 32;
    }
    for (size_t k = i + 8; carry != 0 && k < 16; ++k) {
      const uint64_t value = static_cast<uint64_t>(wide[k]) + carry;
      wide[k] = static_cast<uint32_t>(value);
      carry = value >> 32;
    }
  }
  return p256Reduce(wide);
}

P256Field p256FieldFromBigEndian(const Bytes& bytes, size_t offset) {
  P256Field out;
  for (size_t i = 0; i < 8; ++i) {
    const size_t at = offset + (7 - i) * 4;
    out.limb[i] = (static_cast<uint32_t>(bytes[at]) << 24) |
                  (static_cast<uint32_t>(bytes[at + 1]) << 16) |
                  (static_cast<uint32_t>(bytes[at + 2]) << 8) |
                  static_cast<uint32_t>(bytes[at + 3]);
  }
  return out;
}

bool p256PublicPointValid(const Bytes& encoded) {
  if (encoded.size() != 65 || encoded[0] != 0x04) return false;
  const P256Field x = p256FieldFromBigEndian(encoded, 1);
  const P256Field y = p256FieldFromBigEndian(encoded, 33);
  if (p256AtLeast(x.limb, kP256Prime) || p256AtLeast(y.limb, kP256Prime)) return false;

  const P256Field lhs = p256Multiply(y, y);
  P256Field rhs = p256Multiply(p256Multiply(x, x), x);
  rhs = p256Subtract(rhs, x);
  rhs = p256Subtract(rhs, x);
  rhs = p256Subtract(rhs, x);
  P256Field b;
  for (size_t i = 0; i < 8; ++i) b.limb[i] = kP256B[i];
  rhs = p256Add(rhs, b);
  return std::equal(lhs.limb, lhs.limb + 8, rhs.limb);
}

bool vapidPublicKeyValid(const std::string& key) {
  if (key.size() != 87 && key.size() != 88) return false;
  std::string encoded = key;
  for (size_t i = 0; i < encoded.size(); ++i) {
    const unsigned char ch = static_cast<unsigned char>(encoded[i]);
    const bool padding = ch == '=' && i + 1 == encoded.size();
    if (!(std::isalnum(ch) || ch == '-' || ch == '_' || padding)) return false;
    if (encoded[i] == '-') encoded[i] = '+';
    else if (encoded[i] == '_') encoded[i] = '/';
  }
  while (encoded.size() % 4) encoded.push_back('=');
  Bytes decoded;
  return base64Decode(encoded, decoded) && p256PublicPointValid(decoded);
}

bool vapidSubjectValid(const std::string& subject) {
  if (subject.empty() || subject.size() > 512) return false;
  for (unsigned char ch : subject)
    if (ch <= 0x20 || ch >= 0x7f) return false;
  if (subject.rfind("mailto:", 0) == 0) {
    const std::string address = subject.substr(7);
    const size_t at = address.find('@');
    return at > 0 && at + 1 < address.size() && address.find('@', at + 1) == std::string::npos;
  }
  return webPushSenderUrlValid(subject);
}

bool webPushConfigSyntaxValid(const cJSON* config) {
  if (!cJSON_IsObject(config)) return false;
  const std::string sender_ref = json::getString(config, "sender_secret_ref");
  return webPushSenderUrlValid(json::getString(config, "sender_url")) &&
         vapidPublicKeyValid(json::getString(config, "vapid_public_key")) &&
         vapidSubjectValid(json::getString(config, "vapid_subject")) &&
         secretRefValid(json::getString(config, "vapid_private_key_ref")) &&
         (sender_ref.empty() || secretRefValid(sender_ref));
}

bool jsonContainsExactString(const cJSON* value, const std::string& needle) {
  if (!value) return false;
  if (cJSON_IsString(value))
    return value->valuestring && needle == value->valuestring;
  if (!cJSON_IsArray(value) && !cJSON_IsObject(value)) return false;
  const cJSON* child = nullptr;
  cJSON_ArrayForEach(child, value) {
    if (jsonContainsExactString(child, needle)) return true;
  }
  return false;
}

std::string lowerAscii(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
    return static_cast<char>(std::tolower(c));
  });
  return value;
}

std::string lastPathPart(const std::string& path) {
  const size_t dot = path.rfind('.');
  return lowerAscii(dot == std::string::npos ? path : path.substr(dot + 1));
}

std::string percentDecodeForCredentialCheck(std::string value) {
  auto hex = [](unsigned char ch) -> int {
    if (ch >= '0' && ch <= '9') return ch - '0';
    if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
    return -1;
  };
  for (int pass = 0; pass < 8; ++pass) {
    std::string decoded;
    decoded.reserve(value.size());
    bool changed = false;
    for (size_t i = 0; i < value.size(); ++i) {
      if (value[i] == '%' && i + 2 < value.size()) {
        const int hi = hex(static_cast<unsigned char>(value[i + 1]));
        const int lo = hex(static_cast<unsigned char>(value[i + 2]));
        if (hi >= 0 && lo >= 0) {
          decoded.push_back(static_cast<char>(hi * 16 + lo));
          i += 2;
          changed = true;
          continue;
        }
      }
      decoded.push_back(value[i]);
    }
    value.swap(decoded);
    if (!changed) break;
  }
  return value;
}

bool sensitiveCredentialName(std::string name, bool include_identity = false) {
  name = lowerAscii(std::move(name));
  name.erase(std::remove_if(name.begin(), name.end(), [](char ch) {
               return ch == '_' || ch == '-' || ch == '.';
             }), name.end());
  static const std::set<std::string> exact = {
      "accesstoken", "apikey", "apitoken", "auth", "authorization", "basicauth",
      "bearer", "bearertoken", "bottoken", "clientsecret", "credential",
      "credentials", "digestauth", "pass", "passwd", "password", "privatekey",
      "proxyauth", "proxyauthorization", "psk", "pskhex", "refreshtoken", "secret",
      "sippass", "token",
      "vapidprivatekey", "xapikey"};
  if (exact.count(name) || (include_identity && (name == "user" || name == "username")))
    return true;
  for (const char* suffix : {"password", "passwd", "secret", "credential",
                             "authorization", "auth", "token", "apikey", "privatekey",
                             "psk"}) {
    const size_t n = std::strlen(suffix);
    if (name.size() > n && name.compare(name.size() - n, n, suffix) == 0) return true;
  }
  return false;
}

bool credentialUrl(const std::string& raw_value) {
  const std::string value = percentDecodeForCredentialCheck(raw_value);
  const size_t scheme = value.find("://");
  if (scheme == std::string::npos) return false;
  const size_t authority = scheme + 3;
  const size_t authority_end = value.find_first_of("/?#", authority);
  const size_t at = value.find('@', authority);
  if (at != std::string::npos && (authority_end == std::string::npos || at < authority_end))
    return true;

  auto contains_credential_parameter = [&](size_t begin, size_t end) {
    size_t pos = begin;
    while (pos < end) {
      size_t part_end = value.find_first_of("&;", pos);
      if (part_end == std::string::npos || part_end > end) part_end = end;
      const size_t eq = value.find('=', pos);
      size_t name_begin = pos;
      const size_t nested_query = value.rfind('?', eq == std::string::npos || eq > part_end
                                                       ? part_end : eq);
      if (nested_query != std::string::npos && nested_query >= pos)
        name_begin = nested_query + 1;
      const size_t name_end = eq == std::string::npos || eq > part_end ? part_end : eq;
      if (sensitiveCredentialName(value.substr(name_begin, name_end - name_begin), true))
        return true;
      if (part_end >= end) break;
      pos = part_end + 1;
    }
    return false;
  };

  const size_t query = value.find('?', authority);
  const size_t fragment = value.find('#', authority);
  if (query != std::string::npos && (fragment == std::string::npos || query < fragment) &&
      contains_credential_parameter(query + 1,
                                    fragment == std::string::npos ? value.size() : fragment))
    return true;
  if (fragment != std::string::npos &&
      contains_credential_parameter(fragment + 1, value.size()))
    return true;
  return false;
}

bool plaintextSecretName(const std::string& path) {
  const std::string leaf = lastPathPart(path);
  std::string canonical = leaf;
  canonical.erase(std::remove_if(canonical.begin(), canonical.end(), [](char ch) {
                    return ch == '_' || ch == '-';
                  }), canonical.end());
  if (lowerAscii(path) == "panel.tokens") return true;
  return sensitiveCredentialName(canonical);
}

bool secretRefName(const std::string& path) {
  const std::string leaf = lastPathPart(path);
  std::string canonical = leaf;
  canonical.erase(std::remove_if(canonical.begin(), canonical.end(), [](char ch) {
                    return ch == '_' || ch == '-';
                  }), canonical.end());
  if (canonical.size() > 3 && canonical.compare(canonical.size() - 3, 3, "ref") == 0 &&
      sensitiveCredentialName(canonical.substr(0, canonical.size() - 3)))
    return true;
  if (canonical != "ref") return false;
  const size_t leaf_dot = path.rfind('.');
  if (leaf_dot == std::string::npos || leaf_dot == 0) return false;
  const size_t base_dot = path.rfind('.', leaf_dot - 1);
  const size_t base_begin = base_dot == std::string::npos ? 0 : base_dot + 1;
  return sensitiveCredentialName(path.substr(base_begin, leaf_dot - base_begin));
}

bool secretRefsName(const std::string& path) {
  return lastPathPart(path) == "token_refs";
}

bool panelTokenGenerationValid(const std::string& key, const cJSON* value,
                               std::string* error) {
  const cJSON* generation_value = value;
  if (key == "panel") {
    generation_value = json::get(value, "token_generation");
    if (!generation_value) return true;
  } else if (key != "panel.token_generation") {
    return true;
  }
  const std::string generation = cJSON_IsString(generation_value) &&
          generation_value->valuestring
      ? generation_value->valuestring : "";
  if (generation.size() != 32 ||
      !std::all_of(generation.begin(), generation.end(), [](unsigned char ch) {
        return std::isdigit(ch) || (ch >= 'a' && ch <= 'f');
      })) {
    *error = "panel token generation must be 32 lowercase hexadecimal characters";
    return false;
  }
  return true;
}

bool legacyRuntimeSecretPath(const std::string& path, std::string* ref_path,
                             std::string* ref_field, std::string* kind) {
  std::string field;
  if (path == "integrations.mqtt.pass") {
    field = "pass_ref";
    *kind = "mqtt";
  } else if (path == "integrations.telegram.bot_token") {
    field = "bot_token_ref";
    *kind = "telegram";
  } else if (path == "integrations.webrtc.sip_pass") {
    field = "sip_pass_ref";
    *kind = "webrtc";
  } else if (path.rfind("sip.accounts.", 0) == 0 && path.size() > 18 &&
             path.compare(path.size() - 5, 5, ".pass") == 0) {
    field = "pass_ref";
    *kind = "sip";
  } else {
    return false;
  }
  const size_t dot = path.rfind('.');
  *ref_path = path.substr(0, dot + 1) + field;
  *ref_field = std::move(field);
  return true;
}

bool secretContractValid(const std::string& path, const cJSON* value, std::string* error) {
  if (secretRefName(path)) {
    if (!cJSON_IsString(value) || !secretRefValid(value->valuestring ? value->valuestring : "")) {
      *error = "invalid secret reference at " + path;
      return false;
    }
    return true;
  }
  if (plaintextSecretName(path)) {
    *error = "plaintext secret field " + path + " is forbidden; store a secret_ref instead";
    return false;
  }
  if (secretRefsName(path)) {
    if (!cJSON_IsArray(value) || cJSON_GetArraySize(value) == 0) {
      *error = "secret reference list must be a non-empty array at " + path;
      return false;
    }
    const cJSON* item = nullptr;
    cJSON_ArrayForEach(item, value) {
      if (!cJSON_IsString(item) ||
          !secretRefValid(item->valuestring ? item->valuestring : "")) {
        *error = "invalid secret reference in " + path;
        return false;
      }
    }
    return true;
  }
  if (cJSON_IsString(value) && credentialUrl(value->valuestring ? value->valuestring : "")) {
    *error = "credentials in URLs are forbidden at " + path + "; use secret_ref";
    return false;
  }
  if (cJSON_IsObject(value)) {
    cJSON* child = nullptr;
    cJSON_ArrayForEach(child, value) {
      if (!child->string) continue;
      const std::string child_path = path.empty() ? child->string : path + "." + child->string;
      if (!secretContractValid(child_path, child, error)) return false;
    }
  } else if (cJSON_IsArray(value)) {
    const cJSON* child = nullptr;
    cJSON_ArrayForEach(child, value) {
      if (!secretContractValid(path, child, error)) return false;
    }
  }
  return true;
}

bool mediaSourceIdValid(const std::string& id) {
  if (id.empty() || id.size() > 128) return false;
  for (unsigned char ch : id)
    if (!(std::isalnum(ch) || ch == '_' || ch == '-')) return false;
  return true;
}

bool objectHasOnly(const cJSON* object, const std::set<std::string>& allowed,
                   const std::string& label, std::string* error) {
  if (!cJSON_IsObject(object)) {
    *error = label + " must be an object";
    return false;
  }
  const cJSON* field = nullptr;
  cJSON_ArrayForEach(field, object) {
    const std::string name = field->string ? field->string : "";
    if (!allowed.count(name)) {
      *error = label + " contains unsupported field " + name;
      return false;
    }
  }
  return true;
}

bool mediaSourceDefinitionValid(const cJSON* value, std::string* error) {
  if (!objectHasOnly(value, {"schema_version", "kind", "streams", "secret_ref"},
                     "media source", error))
    return false;
  if (json::getInt(value, "schema_version") != 1 ||
      json::getString(value, "kind") != "ip_camera") {
    *error = "unsupported media source schema or kind";
    return false;
  }
  const cJSON* secret_ref = json::get(value, "secret_ref");
  if (secret_ref &&
      (!cJSON_IsString(secret_ref) ||
       !secretRefValid(secret_ref->valuestring ? secret_ref->valuestring : ""))) {
    *error = "invalid media source secret_ref";
    return false;
  }
  const cJSON* streams = json::get(value, "streams");
  if (!objectHasOnly(streams, {"h264", "mjpeg", "snapshot"},
                     "media source streams", error))
    return false;
  bool any = false;
  for (const char* name : {"h264", "mjpeg", "snapshot"}) {
    const cJSON* stream = json::get(streams, name);
    if (!stream) continue;
    any = true;
    const bool h264 = std::string(name) == "h264";
    if (!objectHasOnly(stream, h264 ? std::set<std::string>{"url", "transport", "profile"}
                                    : std::set<std::string>{"url"},
                       std::string("media stream ") + name, error))
      return false;
    const std::string url = json::getString(stream, "url");
    const bool scheme_ok = h264 ? url.rfind("rtsp://", 0) == 0
                                : (url.rfind("http://", 0) == 0 ||
                                   url.rfind("https://", 0) == 0);
    if (!scheme_ok || url.size() > 4096 || credentialUrl(url)) {
      *error = std::string("invalid or credential-bearing ") + name + " stream URL";
      return false;
    }
    if (h264 && (json::getString(stream, "transport") != "tcp" ||
                 json::getString(stream, "profile") != "baseline")) {
      *error = "H.264 IP cameras require RTSP-over-TCP Baseline profile";
      return false;
    }
  }
  if (!any) {
    *error = "media source must declare at least one stream";
    return false;
  }
  return true;
}

bool webGroupNameValid(const std::string& group) {
  return !group.empty() && group.size() <= 64 &&
         std::all_of(group.begin(), group.end(), [](unsigned char ch) {
           return std::isalnum(ch) || ch == '_' || ch == '.' || ch == ':' || ch == '-';
         });
}

bool webPushSealedRecordValid(const std::string& key, const cJSON* value,
                              std::string* error) {
  const std::string prefix = "web_push.subscriptions.";
  if (key.rfind(prefix, 0) != 0) return true;
  const std::string id = key.substr(prefix.size());
  const auto is_hex = [](const std::string& text, size_t exact = 0) {
    if ((exact && text.size() != exact) || text.empty() || text.size() % 2 != 0) return false;
    return std::all_of(text.begin(), text.end(), [](unsigned char ch) {
      return std::isdigit(ch) || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F');
    });
  };
  if (!is_hex(id, 32) || !cJSON_IsObject(value) ||
      json::getInt(value, "schema_version") != 2) {
    *error = "Web Push subscriptions require a sealed schema version 2 record";
    return false;
  }
  const std::set<std::string> record_fields = {
      "schema_version", "sealed_subscription", "page", "group", "updated_at_ms"};
  const cJSON* field = nullptr;
  cJSON_ArrayForEach(field, value) {
    if (!field->string || !record_fields.count(field->string)) {
      *error = "sealed Web Push records contain an unknown field";
      return false;
    }
  }
  const cJSON* sealed = json::get(value, "sealed_subscription");
  if (!cJSON_IsObject(sealed) ||
      json::getString(sealed, "algorithm") != "xchacha20-poly1305") {
    *error = "Web Push subscription ciphertext must use XChaCha20-Poly1305";
    return false;
  }
  const std::set<std::string> sealed_fields = {"algorithm", "nonce", "ciphertext"};
  cJSON_ArrayForEach(field, sealed) {
    if (!field->string || !sealed_fields.count(field->string)) {
      *error = "sealed Web Push ciphertext contains an unknown field";
      return false;
    }
  }
  const std::string nonce = json::getString(sealed, "nonce");
  const std::string ciphertext = json::getString(sealed, "ciphertext");
  if (!is_hex(nonce, 48) || !is_hex(ciphertext) || ciphertext.size() < 34 ||
      ciphertext.size() > 32 * 1024) {
    *error = "sealed Web Push ciphertext has an invalid size or encoding";
    return false;
  }
  const std::string page = json::getString(value, "page");
  const std::string group = json::getString(value, "group");
  const cJSON* updated = json::get(value, "updated_at_ms");
  if (page.rfind("/panel/", 0) != 0 || page.size() > 256 || !webGroupNameValid(group) ||
      !cJSON_IsNumber(updated)) {
    *error = "sealed Web Push metadata is invalid";
    return false;
  }
  return true;
}

// events.retention_days is the age floor for the local event-retention sweep. One day keeps a
// short-lived diagnostic window; ten years effectively disables age-based pruning.
bool eventRetentionValid(const std::string& key, const cJSON* value, std::string* error) {
  const cJSON* days = nullptr;
  if (key == "events.retention_days") {
    days = value;
  } else if (key == "events") {
    if (!objectHasOnly(value, {"retention_days"}, "events", error)) return false;
    days = json::get(value, "retention_days");
    if (!days) return true;
  } else {
    return true;
  }
  if (!cJSON_IsNumber(days) || days->valuedouble < 1 || days->valuedouble > 3650 ||
      days->valuedouble != static_cast<double>(static_cast<int64_t>(days->valuedouble))) {
    *error = "events.retention_days must be a whole number of days between 1 and 3650";
    return false;
  }
  return true;
}

// True when value is a whole number inside [low, high].
bool wholeNumberInRange(const cJSON* value, int64_t low, int64_t high) {
  if (!cJSON_IsNumber(value)) return false;
  if (value->valuedouble != static_cast<double>(static_cast<int64_t>(value->valuedouble)))
    return false;
  const int64_t whole = static_cast<int64_t>(value->valuedouble);
  return whole >= low && whole <= high;
}

bool volumeLevelValid(const cJSON* value, const std::string& path, std::string* error) {
  if (wholeNumberInRange(value, 0, 100)) return true;
  *error = path + " must be a whole number between 0 and 100";
  return false;
}

// {call,sos,idle} container, each entry optional.
bool volumeObjectValid(const cJSON* value, const std::string& path, std::string* error) {
  if (!objectHasOnly(value, {"call", "sos", "idle"}, path, error)) return false;
  for (const char* field : {"call", "sos", "idle"}) {
    const cJSON* level = json::get(value, field);
    if (level && !volumeLevelValid(level, path + "." + field, error)) return false;
  }
  return true;
}

// The "audio" container: {"volume": {call,sos,idle}}. A null pointer means the enclosing write
// did not carry one, which is fine.
bool audioObjectValid(const cJSON* audio, const std::string& path, std::string* error) {
  if (!audio) return true;
  if (!objectHasOnly(audio, {"volume"}, path, error)) return false;
  const cJSON* volume = json::get(audio, "volume");
  return !volume || volumeObjectValid(volume, path + ".volume", error);
}

// audio.volume.{call,sos,idle} and devices.<id>.local.audio.volume.{call,sos,idle}. Container
// writes are validated as a whole so an atomic batch cannot smuggle an out-of-range level in
// through a parent object.
bool audioVolumeValid(const std::string& key, const cJSON* value, std::string* error) {
  std::string tail;
  std::string path;
  if (key == "audio" || key.rfind("audio.", 0) == 0) {
    tail = key;
    path = key;
  } else if (key.rfind("devices.", 0) == 0) {
    const size_t local = key.find(".local");
    if (local == std::string::npos)
      return audioObjectValid(json::get(json::get(value, "local"), "audio"),
                              key + ".local.audio", error);
    const std::string after = key.substr(local + std::string(".local").size());
    if (after.empty())
      return audioObjectValid(json::get(value, "audio"), key + ".audio", error);
    if (after.rfind(".audio", 0) != 0) return true;
    tail = after.substr(1);  // drop the leading dot
    path = key;
  } else {
    return true;
  }
  if (tail == "audio") return audioObjectValid(value, path, error);
  if (tail == "audio.volume") return volumeObjectValid(value, path, error);
  if (tail == "audio.volume.call" || tail == "audio.volume.sos" || tail == "audio.volume.idle")
    return volumeLevelValid(value, path, error);
  *error = "unknown audio configuration key " + key;
  return false;
}

bool ntpServerListValid(const cJSON* value, std::string* error) {
  if (!cJSON_IsArray(value)) {
    *error = "time.ntp.servers must be an array of 1 to 4 host or host:port entries";
    return false;
  }
  const int count = cJSON_GetArraySize(value);
  if (count < 1 || count > 4) {
    *error = "time.ntp.servers must contain between 1 and 4 entries";
    return false;
  }
  const cJSON* entry = nullptr;
  cJSON_ArrayForEach(entry, value) {
    if (!cJSON_IsString(entry) || !sntp::parseServer(entry->valuestring, nullptr, nullptr)) {
      *error = "time.ntp.servers entries must be \"host\" or \"host:port\"";
      return false;
    }
  }
  return true;
}

bool ntpObjectValid(const cJSON* value, const std::string& path, std::string* error) {
  if (!objectHasOnly(value, {"enabled", "servers", "interval_s"}, path, error)) return false;
  const cJSON* enabled = json::get(value, "enabled");
  if (enabled && !cJSON_IsBool(enabled)) {
    *error = "time.ntp.enabled must be a boolean";
    return false;
  }
  const cJSON* servers = json::get(value, "servers");
  if (servers && !ntpServerListValid(servers, error)) return false;
  const cJSON* interval = json::get(value, "interval_s");
  if (interval && !wholeNumberInRange(interval, 3600, 604800)) {
    *error = "time.ntp.interval_s must be a whole number of seconds between 3600 and 604800 "
        "(one hour to seven days); a clock correction is stable for days, so syncing more "
        "often only costs battery and traffic";
    return false;
  }
  return true;
}

// time.zone / time.ntp.*. A zone must be one the bundled table can actually resolve, otherwise
// every clock in the fleet would silently fall back to a different offset than the one shown.
bool timeConfigValid(const std::string& key, const cJSON* value, std::string* error) {
  if (key != "time" && key.rfind("time.", 0) != 0) return true;
  auto zone_valid = [&error](const cJSON* zone) {
    if (cJSON_IsString(zone) && tz::zoneKnown(zone->valuestring)) return true;
    *error = "time.zone must be an IANA identifier from the bundled time-zone table";
    return false;
  };
  if (key == "time") {
    if (!objectHasOnly(value, {"zone", "ntp"}, "time", error)) return false;
    const cJSON* zone = json::get(value, "zone");
    if (zone && !zone_valid(zone)) return false;
    const cJSON* ntp = json::get(value, "ntp");
    return !ntp || ntpObjectValid(ntp, "time.ntp", error);
  }
  if (key == "time.zone") return zone_valid(value);
  if (key == "time.ntp") return ntpObjectValid(value, key, error);
  if (key == "time.ntp.enabled") {
    if (cJSON_IsBool(value)) return true;
    *error = "time.ntp.enabled must be a boolean";
    return false;
  }
  if (key == "time.ntp.servers") return ntpServerListValid(value, error);
  if (key == "time.ntp.interval_s") {
    if (wholeNumberInRange(value, 3600, 604800)) return true;
    *error = "time.ntp.interval_s must be a whole number of seconds between 3600 and 604800 "
        "(one hour to seven days); a clock correction is stable for days, so syncing more "
        "often only costs battery and traffic";
    return false;
  }
  *error = "unknown time configuration key " + key;
  return false;
}

// Number of Unicode code points in a UTF-8 string, used for the announcement length limit so a
// Japanese notice is measured the way an operator counts it.
size_t utf8Length(const std::string& text) {
  size_t count = 0;
  for (unsigned char c : text) {
    if ((c & 0xC0) != 0x80) count++;
  }
  return count;
}

// The announcement record shared by doors.<id>.notice and notice.global.
bool noticeRecordValid(const cJSON* value, const std::string& path, std::string* error) {
  if (cJSON_IsNull(value)) return true;
  if (!objectHasOnly(value, {"text", "from_device", "created_ms", "expires_ms"}, path, error))
    return false;
  const cJSON* text = json::get(value, "text");
  if (!cJSON_IsString(text) || utf8Length(text->valuestring) == 0 ||
      utf8Length(text->valuestring) > 200) {
    *error = "announcement text must be between 1 and 200 characters";
    return false;
  }
  const cJSON* from_device = json::get(value, "from_device");
  if (from_device && !cJSON_IsString(from_device)) {
    *error = "announcement from_device must be a string";
    return false;
  }
  for (const char* field : {"created_ms", "expires_ms"}) {
    const cJSON* stamp = json::get(value, field);
    if (stamp && !wholeNumberInRange(stamp, 0, 4'102'444'800'000LL)) {
      *error = std::string("announcement ") + field + " must be a whole millisecond timestamp";
      return false;
    }
  }
  return true;
}

bool simpleIdValid(const std::string& id, size_t max_len) {
  if (id.empty() || id.size() > max_len) return false;
  for (char c : id) {
    const bool allowed = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                         (c >= '0' && c <= '9') || c == '_' || c == '-';
    if (!allowed) return false;
  }
  return true;
}

// notice.global (the cluster-wide announcement a door-specific one overrides) and
// notice.presets, the administrator-editable list the announcement dialogs render.
bool noticeConfigValid(const std::string& key, const cJSON* value, std::string* error) {
  auto presets_valid = [&error](const cJSON* presets) {
    if (!cJSON_IsArray(presets)) {
      *error = "notice.presets must be an array of {id, text} entries";
      return false;
    }
    if (cJSON_GetArraySize(presets) > 8) {
      *error = "notice.presets holds at most 8 entries";
      return false;
    }
    std::set<std::string> seen;
    const cJSON* entry = nullptr;
    cJSON_ArrayForEach(entry, presets) {
      if (!objectHasOnly(entry, {"id", "text"}, "notice.presets entry", error)) return false;
      const std::string id = json::getString(entry, "id");
      const std::string text = json::getString(entry, "text");
      if (!simpleIdValid(id, 32)) {
        *error = "a notice preset id must be 1..32 characters of letters, digits, _ or -";
        return false;
      }
      if (!seen.insert(id).second) {
        *error = "duplicate notice preset id: " + id;
        return false;
      }
      if (utf8Length(text) == 0 || utf8Length(text) > 200) {
        *error = "notice preset text must be between 1 and 200 characters";
        return false;
      }
    }
    return true;
  };
  if (key == "notice") {
    if (!objectHasOnly(value, {"global", "presets"}, "notice", error)) return false;
    const cJSON* global = json::get(value, "global");
    if (global && !noticeRecordValid(global, "notice.global", error)) return false;
    const cJSON* presets = json::get(value, "presets");
    return !presets || presets_valid(presets);
  }
  if (key == "notice.global") return noticeRecordValid(value, key, error);
  if (key == "notice.presets") return presets_valid(value);
  if (key.rfind("notice.", 0) == 0) {
    *error = "unknown announcement configuration key " + key;
    return false;
  }
  return true;
}

// doors.<id>.unlock.show_button decides whether the unlock control appears; the door may also
// name the command the unlock action publishes.
bool doorUnlockValid(const std::string& key, const cJSON* value, std::string* error) {
  auto object_valid = [&error](const cJSON* unlock, const std::string& path) {
    if (cJSON_IsNull(unlock)) return true;
    if (!objectHasOnly(unlock, {"show_button", "command"}, path, error)) return false;
    const cJSON* show = json::get(unlock, "show_button");
    if (show && !cJSON_IsBool(show)) {
      *error = path + ".show_button must be a boolean";
      return false;
    }
    const cJSON* command = json::get(unlock, "command");
    if (command && (!cJSON_IsString(command) || !simpleIdValid(command->valuestring, 32))) {
      *error = path + ".command must be 1..32 characters of letters, digits, _ or -";
      return false;
    }
    return true;
  };
  if (key.rfind("doors.", 0) != 0) return true;
  const std::string show_suffix = ".unlock.show_button";
  const std::string command_suffix = ".unlock.command";
  const std::string unlock_suffix = ".unlock";
  auto ends_with = [&key](const std::string& suffix) {
    return key.size() > suffix.size() &&
           key.compare(key.size() - suffix.size(), suffix.size(), suffix) == 0;
  };
  if (ends_with(show_suffix)) {
    if (cJSON_IsBool(value)) return true;
    *error = key + " must be a boolean";
    return false;
  }
  if (ends_with(command_suffix)) {
    if (cJSON_IsString(value) && simpleIdValid(value->valuestring, 32)) return true;
    *error = key + " must be 1..32 characters of letters, digits, _ or -";
    return false;
  }
  if (ends_with(unlock_suffix)) return object_valid(value, key);
  // A whole-door write may carry the object inline.
  if (cJSON_IsObject(value)) {
    const cJSON* embedded = json::get(value, "unlock");
    if (embedded) return object_valid(embedded, key + ".unlock");
  }
  return true;
}

// doors.<id>.notice: {text, from_device, created_ms, expires_ms} or null to clear.
bool doorNoticeValid(const std::string& key, const cJSON* value, std::string* error) {
  const std::string suffix = ".notice";
  if (key.rfind("doors.", 0) != 0) return true;
  const bool is_notice = key.size() > suffix.size() &&
      key.compare(key.size() - suffix.size(), suffix.size(), suffix) == 0;
  if (!is_notice) {
    // A whole-door write may still carry a notice object; validate it in place.
    if (!cJSON_IsObject(value)) return true;
    const cJSON* embedded = json::get(value, "notice");
    if (!embedded || cJSON_IsNull(embedded)) return true;
    return doorNoticeValid(key + ".notice", embedded, error);
  }
  return noticeRecordValid(value, key, error);
}

// The semantic regions the automatic ink decision is published for. They are the ids the shells
// already use for text drawn straight onto the theme background.
const char* const kInkRegions[] = {"clock",      "date",   "status_line", "hint",
                                   "tile_label", "footer", "notice"};

bool inkRegionKnown(const std::string& region) {
  for (const char* known : kInkRegions) {
    if (region == known) return true;
  }
  return false;
}

bool hhmmValid(const cJSON* value) {
  return cJSON_IsString(value) && parseHhmm(value->valuestring) >= 0;
}

// display.appearance and its schedule, at cluster scope and per device.
bool appearanceValid(const std::string& key, const cJSON* value, std::string* error) {
  auto mode_valid = [&error](const cJSON* mode) {
    const std::string text = cJSON_IsString(mode) ? mode->valuestring : "";
    if (text == "auto_system" || text == "auto_schedule" || text == "light" || text == "dark")
      return true;
    *error = "appearance must be auto_system, auto_schedule, light, or dark";
    return false;
  };
  auto schedule_valid = [&error](const cJSON* schedule, const std::string& path) {
    if (!objectHasOnly(schedule, {"dark_from", "light_from"}, path, error)) return false;
    for (const char* field : {"dark_from", "light_from"}) {
      const cJSON* at = json::get(schedule, field);
      if (at && !hhmmValid(at)) {
        *error = path + "." + field + " must be a HH:MM time of day";
        return false;
      }
    }
    return true;
  };
  const std::string mode_suffix = "display.appearance";
  const std::string schedule_suffix = "display.appearance_schedule";
  auto ends_with = [&key](const std::string& suffix) {
    return key.size() >= suffix.size() &&
           key.compare(key.size() - suffix.size(), suffix.size(), suffix) == 0;
  };
  if (ends_with(schedule_suffix)) return schedule_valid(value, key);
  if (ends_with(mode_suffix)) return mode_valid(value);
  // A display container write may carry either inline.
  if (ends_with("display") && cJSON_IsObject(value)) {
    const cJSON* mode = json::get(value, "appearance");
    if (mode && !mode_valid(mode)) return false;
    const cJSON* schedule = json::get(value, "appearance_schedule");
    return !schedule || schedule_valid(schedule, key + ".appearance_schedule");
  }
  return true;
}

// display.theme.* and devices.<id>.local.theme.*: the automatic ink and accent overrides. Colour
// format is enforced; readability is reported as a warning, never a rejection.
bool themeOverrideValid(const std::string& key, const cJSON* value, std::string* error) {
  const std::string ink_marker = "theme.ink_override";
  const std::string button_suffix = "theme.call_button_bg";
  auto ends_with = [&key](const std::string& suffix) {
    return key.size() >= suffix.size() &&
           key.compare(key.size() - suffix.size(), suffix.size(), suffix) == 0;
  };
  auto color_valid = [&error](const cJSON* color, const std::string& path) {
    double luminance = 0;
    int alpha = 255;
    if (cJSON_IsString(color) && parseStyleColor(color->valuestring, &luminance, &alpha))
      return true;
    *error = path + " must be #RRGGBB";
    return false;
  };
  auto ink_map_valid = [&error, &color_valid](const cJSON* map, const std::string& path) {
    if (cJSON_IsNull(map)) return true;
    if (!cJSON_IsObject(map)) {
      *error = path + " must be an object of region ids";
      return false;
    }
    const cJSON* item = nullptr;
    cJSON_ArrayForEach(item, map) {
      const std::string region = item->string ? item->string : "";
      if (!inkRegionKnown(region)) {
        *error = path + " has no region " + region;
        return false;
      }
      if (!color_valid(item, path + "." + region)) return false;
    }
    return true;
  };
  // The published results are computed, never stored.
  if (key.find("theme.auto_ink") != std::string::npos ||
      key.find("theme.auto_accent") != std::string::npos) {
    *error = "auto_ink and auto_accent are computed by core and cannot be written";
    return false;
  }
  // The darkening layer a shell composites between the background image and the text. Every
  // leaf is optional and a null clears an override, so a device can darken more than the
  // cluster without restating the colour.
  auto backdrop_leaf_valid = [&error, &color_valid](const std::string& leaf, const cJSON* value,
                                                    const std::string& path) {
    if (cJSON_IsNull(value)) return true;
    if (leaf == "enabled") {
      if (cJSON_IsBool(value)) return true;
      *error = path + " must be true or false";
      return false;
    }
    if (leaf == "color") return color_valid(value, path);
    if (leaf == "opacity") {
      if (wholeNumberInRange(value, 0, 100)) return true;
      *error = path + " must be a whole number between 0 and 100";
      return false;
    }
    *error = path + " is not a backdrop setting";
    return false;
  };
  auto backdrop_object_valid = [&backdrop_leaf_valid, &error](const cJSON* value,
                                                              const std::string& path) {
    if (cJSON_IsNull(value)) return true;
    if (!cJSON_IsObject(value)) {
      *error = path + " must be an object";
      return false;
    }
    const cJSON* item = nullptr;
    cJSON_ArrayForEach(item, value) {
      const std::string leaf = item->string ? item->string : "";
      if (!backdrop_leaf_valid(leaf, item, path + "." + leaf)) return false;
    }
    return true;
  };
  const std::string backdrop_marker = "theme.backdrop";
  const size_t backdrop_pos = key.find(backdrop_marker);
  if (backdrop_pos != std::string::npos) {
    const std::string tail = key.substr(backdrop_pos + backdrop_marker.size());
    if (tail.empty()) return backdrop_object_valid(value, key);
    if (tail[0] == '.') return backdrop_leaf_valid(tail.substr(1), value, key);
  }

  auto glass_valid = [&error](const cJSON* value, const std::string& path) {
    if (cJSON_IsNull(value)) return true;
    if (!cJSON_IsObject(value)) {
      *error = path + " must be an object";
      return false;
    }
    const cJSON* item = nullptr;
    cJSON_ArrayForEach(item, value) {
      const std::string leaf = item->string ? item->string : "";
      if (leaf == "blur_radius" && wholeNumberInRange(item, 0, 40)) continue;
      *error = path + "." + leaf +
               (leaf == "blur_radius" ? " must be a whole number between 0 and 40"
                                      : " is not a frosted-glass setting");
      return false;
    }
    return true;
  };
  const std::string glass_marker = "theme.glass";
  const size_t glass_pos = key.find(glass_marker);
  if (glass_pos != std::string::npos) {
    const std::string tail = key.substr(glass_pos + glass_marker.size());
    if (tail.empty()) return glass_valid(value, key);
    if (tail == ".blur_radius") {
      if (cJSON_IsNull(value) || wholeNumberInRange(value, 0, 40)) return true;
      *error = key + " must be a whole number between 0 and 40";
      return false;
    }
  }

  const size_t ink_pos = key.find(ink_marker);
  if (ink_pos != std::string::npos) {
    const std::string tail = key.substr(ink_pos + ink_marker.size());
    if (tail.empty()) return ink_map_valid(value, key);
    if (tail[0] != '.') return true;
    const std::string region = tail.substr(1);
    if (!inkRegionKnown(region)) {
      *error = "unknown ink region " + region;
      return false;
    }
    return cJSON_IsNull(value) ? true : color_valid(value, key);
  }
  if (ends_with(button_suffix))
    return cJSON_IsNull(value) ? true : color_valid(value, key);
  // A theme container write may carry either inline.
  if (ends_with("theme") && cJSON_IsObject(value)) {
    const cJSON* button = json::get(value, "call_button_bg");
    if (button && !cJSON_IsNull(button) && !color_valid(button, key + ".call_button_bg"))
      return false;
    const cJSON* ink = json::get(value, "ink_override");
    if (ink && !ink_map_valid(ink, key + ".ink_override")) return false;
    const cJSON* backdrop = json::get(value, "backdrop");
    if (backdrop && !backdrop_object_valid(backdrop, key + ".backdrop")) return false;
    const cJSON* glass = json::get(value, "glass");
    if (glass && !glass_valid(glass, key + ".glass")) return false;
    if (json::get(value, "auto_ink") || json::get(value, "auto_accent")) {
      *error = "auto_ink and auto_accent are computed by core and cannot be written";
      return false;
    }
  }
  return true;
}

// emergency.trigger.{mode,countdown_s}. "hold" stays accepted so a configuration written before
// the slide control keeps validating; the shells implement slide only.
bool emergencyTriggerValid(const std::string& key, const cJSON* value, std::string* error) {
  auto mode_valid = [&error](const cJSON* mode) {
    const std::string text = cJSON_IsString(mode) ? mode->valuestring : "";
    if (text == "slide" || text == "hold") return true;
    *error = "emergency.trigger.mode must be slide or hold";
    return false;
  };
  auto countdown_valid = [&error](const cJSON* seconds) {
    if (wholeNumberInRange(seconds, 0, 10)) return true;
    *error = "emergency.trigger.countdown_s must be a whole number of seconds between 0 and 10";
    return false;
  };
  if (key == "emergency.trigger.mode") return mode_valid(value);
  if (key == "emergency.trigger.countdown_s") return countdown_valid(value);
  if (key == "emergency.hold_to_trigger_s") return countdown_valid(value);
  if (key == "emergency.trigger" || key == "emergency") {
    const cJSON* trigger = key == "emergency" ? json::get(value, "trigger") : value;
    if (!trigger) return true;
    if (!objectHasOnly(trigger, {"mode", "countdown_s"}, "emergency.trigger", error))
      return false;
    const cJSON* mode = json::get(trigger, "mode");
    if (mode && !mode_valid(mode)) return false;
    const cJSON* countdown = json::get(trigger, "countdown_s");
    return !countdown || countdown_valid(countdown);
  }
  return true;
}

// visit_purposes.<id>.enabled hides a purpose from the visitor without deleting it, so the
// wording and ordering survive being switched off and back on.
bool visitPurposeValid(const std::string& key, const cJSON* value, std::string* error) {
  if (key.rfind("visit_purposes", 0) != 0) return true;
  const std::string suffix = ".enabled";
  const bool is_enabled_leaf =
      key.size() > suffix.size() &&
      key.compare(key.size() - suffix.size(), suffix.size(), suffix) == 0;
  if (is_enabled_leaf) {
    if (cJSON_IsBool(value)) return true;
    *error = key + " must be a boolean";
    return false;
  }
  if (!cJSON_IsObject(value)) return true;
  // A whole-purpose or whole-container write may carry the flag inline.
  const cJSON* enabled = json::get(value, "enabled");
  if (enabled && !cJSON_IsBool(enabled)) {
    *error = key + ".enabled must be a boolean";
    return false;
  }
  if (key != "visit_purposes") return true;
  const cJSON* purpose = nullptr;
  cJSON_ArrayForEach(purpose, value) {
    const cJSON* flag = json::get(purpose, "enabled");
    if (flag && !cJSON_IsBool(flag)) {
      *error = "visit_purposes." + std::string(purpose->string ? purpose->string : "") +
               ".enabled must be a boolean";
      return false;
    }
  }
  return true;
}

// call.indoor.return_s and its per-device override: how long an indoor panel stays on the
// incoming-call page before returning home.
bool callReturnValid(const std::string& key, const cJSON* value, std::string* error) {
  auto seconds_valid = [&error](const cJSON* seconds, const std::string& path) {
    if (wholeNumberInRange(seconds, 5, 600)) return true;
    *error = path + " must be a whole number of seconds between 5 and 600";
    return false;
  };
  const std::string cluster_leaf = "call.indoor.return_s";
  const std::string device_leaf = ".local.call.return_s";
  auto ends_with = [&key](const std::string& suffix) {
    return key.size() >= suffix.size() &&
           key.compare(key.size() - suffix.size(), suffix.size(), suffix) == 0;
  };
  if (key == cluster_leaf || (key.rfind("devices.", 0) == 0 && ends_with(device_leaf)))
    return seconds_valid(value, key);
  // Container writes carry it inline.
  if (key == "call" || key == "call.indoor") {
    const cJSON* indoor = key == "call" ? json::get(value, "indoor") : value;
    if (key == "call" && !objectHasOnly(value, {"indoor"}, "call", error)) return false;
    if (!indoor) return true;
    if (!objectHasOnly(indoor, {"return_s"}, "call.indoor", error)) return false;
    const cJSON* seconds = json::get(indoor, "return_s");
    return !seconds || seconds_valid(seconds, "call.indoor.return_s");
  }
  if (key.rfind("devices.", 0) == 0 && cJSON_IsObject(value)) {
    const cJSON* local = key.find(".local") == std::string::npos
        ? json::get(value, "local") : value;
    const cJSON* call = json::get(local, "call");
    if (ends_with(".local.call")) call = value;
    const cJSON* seconds = json::get(call, "return_s");
    if (seconds) return seconds_valid(seconds, key + ".return_s");
  }
  return true;
}

bool configWriteValid(const std::string& key, const cJSON* value, std::string* error,
                      std::vector<ConfigWarning>* warnings = nullptr) {
  if (!callReturnValid(key, value, error)) return false;
  if (!secretContractValid(key, value, error)) return false;
  if (!visitPurposeValid(key, value, error)) return false;
  if (!eventRetentionValid(key, value, error)) return false;
  if (!timeConfigValid(key, value, error)) return false;
  if (!audioVolumeValid(key, value, error)) return false;
  if (!doorNoticeValid(key, value, error)) return false;
  if (!noticeConfigValid(key, value, error)) return false;
  if (!doorUnlockValid(key, value, error)) return false;
  if (!appearanceValid(key, value, error)) return false;
  if (!themeOverrideValid(key, value, error)) return false;
  if (!emergencyTriggerValid(key, value, error)) return false;
  if (!panelTokenGenerationValid(key, value, error)) return false;
  if (key == "web_push.subscriptions") {
    *error = "the Web Push subscription container is read-only";
    return false;
  }
  if (!webPushSealedRecordValid(key, value, error)) return false;
  if (key == "devices") {
    *error = "the devices container is read-only; write one device or semantic element leaf";
    return false;
  }
  const std::string ui_path = ".local.ui";
  const std::string element_path = ".local.ui.elements.";
  const size_t ui_pos = key.find(ui_path);
  const bool ui_namespace = ui_pos != std::string::npos &&
      (ui_pos + ui_path.size() == key.size() || key[ui_pos + ui_path.size()] == '.');
  const bool element_leaf = key.find(element_path) != std::string::npos;
  if (key.rfind("devices.", 0) == 0 && ui_namespace && !element_leaf) {
    *error = "UI containers are read-only; write one semantic element override at a time";
    return false;
  }
  if (key.rfind("devices.", 0) == 0 && cJSON_IsObject(value) && !ui_namespace) {
    const cJSON* embedded_ui = nullptr;
    if (key.size() >= 6 && key.compare(key.size() - 6, 6, ".local") == 0)
      embedded_ui = json::get(value, "ui");
    else if (key.find(".local.") == std::string::npos)
      embedded_ui = json::get(json::get(value, "local"), "ui");
    if (embedded_ui) {
      *error = "embedded UI containers are forbidden; use semantic element leaf keys";
      return false;
    }
  }
  if (!uiStyleOverrideValid(key, value, error, warnings)) return false;
  const std::string helper_suffix = ".local.recovery.helper_mode";
  if (key.rfind("devices.", 0) == 0 && key.size() >= helper_suffix.size() &&
      key.compare(key.size() - helper_suffix.size(), helper_suffix.size(), helper_suffix) == 0) {
    const std::string mode = cJSON_IsString(value) ? value->valuestring : "";
    if (mode != "off" && mode != "auto" && mode != "on") {
      *error = "helper_mode must be off, auto, or on";
      return false;
    }
  }
  if (key == "media_sources") {
    if (!cJSON_IsObject(value)) {
      *error = "media_sources must be an object";
      return false;
    }
    const cJSON* source = nullptr;
    cJSON_ArrayForEach(source, value) {
      const std::string id = source->string ? source->string : "";
      if (!mediaSourceIdValid(id) || !mediaSourceDefinitionValid(source, error)) {
        if (error->empty()) *error = "invalid media source identifier";
        return false;
      }
    }
  } else if (key.rfind("media_sources.", 0) == 0) {
    const std::string id = key.substr(std::string("media_sources.").size());
    if (!mediaSourceIdValid(id)) {
      *error = "media source writes must replace one complete source definition";
      return false;
    }
    if (!mediaSourceDefinitionValid(value, error)) return false;
  }
  return true;
}

class RemoteMp4Stream {
 public:
  explicit RemoteMp4Stream(std::string host) : host_(std::move(host)) {}
  ~RemoteMp4Stream() { close(); }

  Bytes pull(bool* ended) {
    if (ended) *ended = false;
    if (!opened_ && !open()) {
      if (ended) *ended = true;
      return {};
    }
    if (!pending_.empty()) {
      Bytes out;
      const size_t n = std::min<size_t>(pending_.size(), 64 * 1024);
      out.insert(out.end(), pending_.begin(), pending_.begin() + n);
      pending_.erase(pending_.begin(), pending_.begin() + n);
      return out;
    }
    net::pollfd_t pfd{};
    pfd.fd = fd_;
    pfd.events = POLLIN;
    const int pr = net::poll(&pfd, 1, 500);
    if (pr == 0) return {};
    if (pr < 0 || (pfd.revents & (POLLERR | POLLHUP | POLLNVAL))) {
      close();
      if (ended) *ended = true;
      return {};
    }
    uint8_t buf[64 * 1024];
    const int n = net::recvSome(fd_, buf, sizeof(buf));
    if (n > 0) return Bytes(buf, buf + n);
    if (n < 0 && net::errWouldBlock(net::lastError())) return {};
    close();
    if (ended) *ended = true;
    return {};
  }

 private:
  bool open() {
    opened_ = true;
    addrinfo hints{};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    addrinfo* addresses = nullptr;
    if (::getaddrinfo(host_.c_str(), "47180", &hints, &addresses) != 0 || !addresses)
      return false;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    for (addrinfo* p = addresses; p && !net::valid(fd_); p = p->ai_next) {
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
      const auto left = std::chrono::duration_cast<std::chrono::milliseconds>(
          deadline - std::chrono::steady_clock::now()).count();
      if (rc == 0 || (left > 0 && net::poll(&pfd, 1, static_cast<int>(left)) > 0 &&
                      net::getSockError(candidate) == 0)) {
        fd_ = candidate;
      } else {
        net::closeSocket(candidate);
      }
    }
    ::freeaddrinfo(addresses);
    if (!net::valid(fd_)) return false;
    int yes = 1;
    net::setSockOpt(fd_, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
    const std::string request = "GET /stream.mp4 HTTP/1.1\r\nHost: " + host_ +
                                "\r\nAccept: video/mp4\r\nConnection: close\r\n\r\n";
    size_t sent = 0;
    while (sent < request.size()) {
      const int n = net::sendSome(fd_, request.data() + sent, request.size() - sent);
      if (n > 0) {
        sent += static_cast<size_t>(n);
        continue;
      }
      if (n < 0 && net::errWouldBlock(net::lastError())) {
        net::pollfd_t pfd{};
        pfd.fd = fd_;
        pfd.events = POLLOUT;
        if (net::poll(&pfd, 1, 500) > 0) continue;
      }
      close();
      return false;
    }
    std::string response;
    const auto header_deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (response.find("\r\n\r\n") == std::string::npos && response.size() < 64 * 1024 &&
           std::chrono::steady_clock::now() < header_deadline) {
      net::pollfd_t pfd{};
      pfd.fd = fd_;
      pfd.events = POLLIN;
      if (net::poll(&pfd, 1, 500) <= 0) continue;
      char buf[8192];
      const int n = net::recvSome(fd_, buf, sizeof(buf));
      if (n <= 0) {
        if (n < 0 && net::errWouldBlock(net::lastError())) continue;
        close();
        return false;
      }
      response.append(buf, static_cast<size_t>(n));
    }
    const size_t end = response.find("\r\n\r\n");
    if (end == std::string::npos ||
        (response.rfind("HTTP/1.1 200", 0) != 0 && response.rfind("HTTP/1.0 200", 0) != 0)) {
      close();
      return false;
    }
    std::string headers = response.substr(0, end);
    std::transform(headers.begin(), headers.end(), headers.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    if (headers.find("content-type: video/mp4") == std::string::npos) {
      close();
      return false;
    }
    pending_.assign(response.begin() + static_cast<std::ptrdiff_t>(end + 4), response.end());
    return true;
  }

  void close() {
    if (net::valid(fd_)) net::closeSocket(fd_);
    fd_ = net::kInvalidSocket;
  }

  std::string host_;
  net::socket_t fd_ = net::kInvalidSocket;
  bool opened_ = false;
  Bytes pending_;
};


bool isSha256HexStr(const std::string& s) {
  if (s.size() != 64) return false;
  for (char c : s) {
    if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
  }
  return true;
}


std::string assetRefHash(const std::string& v) {
  if (v.rfind("asset:", 0) != 0) return "";
  std::string h = v.substr(6);
  return isSha256HexStr(h) ? h : "";
}





struct BuiltinText {
  const char* key;
  const char* ja;
  const char* en;
  const char* zh;
};
constexpr BuiltinText kBuiltinTexts[] = {
    {"event.press", "{door} に来客です ({time})", "Visitor at {door} ({time})",
     "{door} 有访客 ({time})"},
    {"event.motion", "{door} で動きを検知 ({time})", "Motion at {door} ({time})",
     "{door} 检测到移动 ({time})"},
    {"event.offline", "⚠ {device} オフライン (最終応答 {time})",
     "⚠ {device} offline (last seen {time})", "⚠ {device} 离线 (最后在线 {time})"},
    {"event.online", "{device} オンライン復帰", "{device} back online", "{device} 恢复在线"},
    {"emergency.title", "緊急事態", "EMERGENCY", "紧急情况"},
    {"emergency.notified", "家族に通知しました", "Family has been notified", "已通知家人"},
    {"emergency.notify_on", "🚨 緊急事態です — {device} から発報 ({time})",
     "🚨 Emergency — triggered by {device} ({time})", "🚨 紧急情况 — 由 {device} 触发 ({time})"},
    {"emergency.notify_off", "✅ 緊急解除", "✅ Emergency cleared", "✅ 警报已解除"},
    {"emergency.active_detail", "緊急モードが発報されています", "Emergency mode is active",
     "紧急模式已触发"},
    {"reply.answered", "応答済み ({text})", "Replied ({text})", "已回复 ({text})"},
    {"notify.test", "ドアホン テスト通知", "Doorbell test notification", "门铃测试通知"},
};


const char* builtinText(const std::string& key, const std::string& lang) {
  for (const auto& t : kBuiltinTexts) {
    if (key != t.key) continue;
    if (lang == "en") return t.en;
    if (lang == "zh") return t.zh;
    return t.ja;
  }
  return nullptr;
}


void substArgs(std::string& s, const std::vector<std::pair<std::string, std::string>>& args) {
  for (const auto& kv : args) {
    const std::string ph = "{" + kv.first + "}";
    size_t pos = 0;
    while ((pos = s.find(ph, pos)) != std::string::npos) {
      s.replace(pos, ph.size(), kv.second);
      pos += kv.second.size();
    }
  }
}
}  // namespace

struct Node::Impl {
  NodeOptions opts;

  std::unique_ptr<RealClock> owned_clock;
  IClock* clock = nullptr;
  std::unique_ptr<Runloop> owned_loop;
  Runloop* loop = nullptr;
  bool external_loop = false;

  Store store;
  std::unique_ptr<HlcClock> hlc;
  std::unique_ptr<LwwMap> config;
  std::unique_ptr<EventLog> events;
  RuleEngine rules;
  std::unique_ptr<ITransport> transport;
  std::unique_ptr<IDiscovery> discovery;
  std::unique_ptr<Mesh> mesh;
  std::unique_ptr<Httpd> httpd;
  std::unique_ptr<SipCtl> sipctl;
  std::unique_ptr<HaBridge> bridge;
  std::unique_ptr<TelegramBridge> tg;
  FrameBus frame_bus;
  // Pairing QR scan mode: fed from the same camera frames the door station already pushes.
  QrScanner qr_scanner;
  uint64_t qr_scan_timer = 0;
  static constexpr int64_t kQrScanTtlMs = 120'000;


  VideoTrack video_track;
  // Shell sensor angle and its administrator-resolved effective value are read by HTTP workers.
  std::atomic<int> sensor_video_rotation{0};
  std::atomic<int> effective_video_rotation{0};

  // ---------- time service ----------
  // A measured SNTP offset. It is applied to the shared clock (and therefore to the HLC, event
  // timestamps and every rendered clock) only while NTP is enabled and the last sync is recent.
  struct TimeState {
    bool ok = false;
    int64_t offset_ms = 0;
    int64_t last_sync_wall_ms = 0;
    int64_t last_sync_mono_ms = 0;
    bool ever_synced = false;
    int64_t rtt_ms = 0;
    std::string server;
    std::string last_error;
  };
  TimeState time_state;
  uint64_t time_sync_timer = 0;
  // Backoff after a failed round, in seconds. Zero means the next round is due at the configured
  // interval; a day is far too long to wait after one failed exchange, and retrying at one
  // minute forever is what the long interval exists to avoid.
  static constexpr int kTimeSyncBackoffMinS = 60;
  static constexpr int kTimeSyncBackoffMaxS = 3600;
  int time_sync_backoff_s = 0;
  bool time_sync_armed = false;
  std::string time_sync_servers_key;
  std::thread time_sync_thread;
  bool time_sync_busy = false;
  std::atomic<bool> time_sync_abort{false};
  std::string reported_time_source = "system";
  int64_t reported_time_offset_ms = 0;

  // ---------- power ----------
  struct PowerState {
    bool known = false;
    int battery_pct = -1;
    bool charging = false;
    bool mains = false;
  };
  PowerState power;
  PowerState reported_power;
  Node::PowerStateFn power_state_fn;
  uint64_t minute_timer = 0;

  MotionDetector motion;
  std::mutex motion_mu;

  std::map<std::string, int64_t> door_calling_until;
  enum class RecoveryLeaseKind { None, LocalProcess, DeadOwnerTakeover };
  struct ActiveCall {
    std::string call_id;
    std::string door;
    std::string origin;
    std::string dialog_owner;
    std::string purpose;
    std::string state = "ringing";
    int stage_revision = 0;
    int64_t expires_wall_ms = 0;
    uint64_t timeout_timer = 0;
    unsigned timeout_retry_step = 0;
    bool local_sip_established = false;
    uint64_t recovery_timer = 0;
    int64_t recovery_deadline_mono = 0;
    bool recovery_notified = false;
    unsigned recovery_retry_step = 0;
    std::string recovery_reason;
    RecoveryLeaseKind recovery_kind = RecoveryLeaseKind::None;
  };
  std::map<std::string, ActiveCall> active_calls;  // door -> active call
  struct TerminalCall {
    std::string call_id;
    std::string door;
    std::string purpose;
    std::string state;
    std::string reason;
    std::string dialog_owner;
    int stage_revision = 0;
    int64_t expires_wall_ms = 0;
    int64_t terminal_wall_ms = 0;
    int64_t visible_until_mono = 0;
    uint64_t order = 0;
  };
  static constexpr int64_t kPanelTerminalCallTtlMs = 30'000;
  static constexpr size_t kMaxPanelTerminalCalls = 256;
  std::map<std::string, TerminalCall> terminal_calls;  // door -> recent terminal state
  uint64_t terminal_call_order = 0;
  struct PendingLifecycle {
    std::string call_id;
    std::string door;
    std::string owner;
    std::string end_reason;
    int stage_revision = 0;
    bool answer_pending = false;
    bool end_pending = false;
    unsigned retry_step = 0;
    uint64_t retry_timer = 0;
    uint64_t order = 0;
  };
  static constexpr size_t kMaxPendingLifecycles = 256;
  std::map<std::string, PendingLifecycle> pending_lifecycles;  // call_id -> ordered writes
  uint64_t pending_lifecycle_order = 0;
  struct WebDialogLease {
    std::string door;
    std::string owner;
    uint64_t timer = 0;
    unsigned retry_step = 0;
  };
  std::map<std::string, WebDialogLease> web_dialog_timers;  // call_id -> authority lease
  std::set<std::string> cancelled_call_ids;
  std::deque<std::string> cancelled_call_order;
  std::set<std::string> presented_reply_event_ids;
  std::deque<std::string> presented_reply_event_order;
  std::string sip_call_id;
  std::string last_reply_text;
  int64_t last_reply_ts = 0;
#ifdef _WIN32
  std::unique_ptr<CameraWin> camera;


  std::unique_ptr<EncoderWin> encoder;
  uint64_t encoder_timer = 0;
#endif

  json::Doc cfg;
  std::string measured_caps_json = "{}";
  std::string effective_caps_json = "{}";
  std::string runtime_status_json = "{}";
  std::string web_ui_style_report_json = "{}";
  std::string ui_manifest_json = "{}";
  bool suppress_config_callbacks = false;
  bool config_persistence_failed = false;
  uint64_t config_persistence_failures = 0;
  std::string node_id;
  uint64_t epoch = 1;
  bool started = false;
  std::mutex snap_mu;
  std::string status_snap;
  std::string config_snap;
  std::string pairing_snap;
  bool snap_scheduled = false;

  // Read-only exports a shell polls must never queue behind the run loop. Devices measured
  // three-second stalls in db_core_local_time_json while the loop was mid-SNTP or building a
  // status document, which is long enough for a one-second clock to visibly skip. The loop
  // republishes these records whenever their inputs change; a reader swaps in a shared_ptr copy,
  // which is a refcount bump on any thread and never waits for anything.
  struct TimeSnapshot {
    // Configured IANA zone, empty when the cluster has never set one.
    std::string zone;
    // integrations.tz_offset_min, used when no zone is configured or the zone is not in the
    // bundled table.
    int legacy_offset_min = 540;
    // "ntp" while a fresh measurement is being applied, "system" otherwise.
    std::string source = "system";
    // Correction currently applied to the platform clock, and when it was last measured.
    int64_t offset_ms = 0;
    int64_t last_sync_wall_ms = 0;
    // The HLC's monotonic floor, so a rendered clock keeps the same lower bound it had when the
    // value was read on the loop. It only ever rises, so a slightly old copy is harmless.
    int64_t hlc_floor_ms = 0;
  };
  std::shared_ptr<const TimeSnapshot> time_snap{std::make_shared<TimeSnapshot>()};

  // Effective volumes are a pure function of configuration, so the loop publishes the inputs and
  // the export resolves them on the caller's thread. One entry per configured device keeps a
  // request for another node's volumes off the loop too.
  struct AudioSnapshot {
    struct Level {
      bool present = false;
      int64_t value = 0;
    };
    struct Levels {
      Level call;
      Level sos;
      Level idle;
    };
    std::string self_id;
    Levels cluster;
    int64_t alarm_volume = 100;
    std::map<std::string, Levels> devices;
  };
  std::shared_ptr<const AudioSnapshot> audio_snap{std::make_shared<AudioSnapshot>()};
  uint64_t snapshot_timer = 0;
  std::set<std::string> playback_invalid_logged;


  std::string last_press_door;
  std::map<std::string, std::pair<std::string, uint64_t>> last_press_by_door;


  SipRegState sip_reg = SipRegState::Idle;
  SipCallState sip_call = SipCallState::Idle;

  std::string sip_peer_node;
  std::string sip_peer_stream;


  Bytes peer_frame;
  int64_t peer_frame_mono = 0;
  std::string dtmf_buf;
  uint64_t dtmf_timer = 0;
  uint64_t sip_reapply_timer = 0;
  uint64_t bridge_reapply_timer = 0;


  bool tg_was_active = false;


  std::string last_display_json;
  uint64_t display_timer = 0;
  uint64_t event_retention_timer = 0;


  std::string assets_dir;
  std::set<std::string> asset_fetching;
  std::map<std::string, int64_t> asset_unref_since;
  uint64_t asset_prefetch_timer = 0;



  std::map<std::string, std::string> visitor_lang_by_door;
  std::map<std::string, uint64_t> visitor_lang_revert_timer;  // door → timer id


  bool emergency_active = false;
  std::string emergency_hlc;


  std::mutex cb_mu;
  UiEventCb ui_cb;
  TtsCb tts_cb;
  HttpsFn https_fn;
  SecureGetFn secure_get_fn;
  SecurePutFn secure_put_fn;
  Node::SecureDeleteFn secure_delete_fn;
  std::set<std::string> secret_migration_warnings;
  std::string sip_credential_source = "none";
  bool pairing_persistence_ready = false;
  // Authoritative pairing state, reported as pairing.state and pairing_state events.
  bool pairing_is_founder = false;
  bool pairing_joining = false;   // a code join or an arriving invitation is being applied
  bool pairing_revoked = false;   // removed by an administrator; the shell wipes and restarts
  // A PIN join succeeded on the wire; its join_result waits for the secure-store outcome.
  bool pairing_join_awaiting_persist = false;
  std::string pairing_psk_source = "none";
  std::string pairing_psk_ref;


  std::shared_ptr<char> alive = std::make_shared<char>(0);


  std::mutex sess_mu;
  std::mutex admin_credential_mu;
  // One lockout counter for every surface that checks the administrator password: the web login,
  // the C ABI a native settings screen uses, and anything else added later. Five failures buy a
  // ten-minute pause, so a four-digit code cannot be walked through from the LAN.
  // Scratch used while building one status document: node id -> alive | suspect | dead | offline.
  // served_by and the peers array both read it, so the two can never contradict each other.
  std::map<std::string, std::string> status_peer_status;

  // peers_changed must report change, not traffic. Devices measured it arriving several times a
  // second on a three-node cluster: every shell rebuilt its home screen on each one, and the
  // rebuilds saturated core's own run loop until the mesh timers starved and httpd stalled --
  // which made heartbeats late, which flapped peers between alive and suspect, which emitted
  // more events. The digest below covers exactly the fields a shell renders, so heartbeats,
  // sequence numbers and volatile runtime telemetry (battery, uptime, frame counters) never
  // qualify; battery has power_changed of its own. Emission is additionally coalesced, so a
  // peer flapping alive/suspect/alive inside the window -- the very thing a busy loop causes --
  // produces no event at all.
  static constexpr int64_t kPeersEventMinGapMs = 500;
  std::string emitted_peers_digest;
  bool peers_ever_emitted = false;
  int64_t peers_emitted_mono = 0;
  uint64_t peers_emit_timer = 0;
  // Peer id -> digest of the contract last written to the cache, so a quiet cluster costs no
  // database traffic at all rather than one read (previously one write) per peer per event.
  std::map<std::string, std::string> cached_contract_digests;
  // Door (or "*") -> the announcement last reported, so re-writing an identical notice is silent.
  std::map<std::string, std::string> emitted_notice_digests;
  // Remembered when there is no SIP backend to hold it, so the toggle keeps its position.
  bool mic_muted_without_sip = false;
  int admin_auth_failures = 0;
  int64_t admin_lockout_until_mono = 0;
  static constexpr int kAdminAuthMaxFailures = 5;
  static constexpr int64_t kAdminLockoutMs = 10 * 60 * 1000;
  std::set<std::string> sessions;
  struct PanelCredentialBinding {
    std::string generation;
    std::vector<std::string> refs;
  };
  std::map<std::string, PanelCredentialBinding> panel_sessions;



  Node::DeviceInfoFn device_info_fn;
  std::string device_info_json;
  std::string net_leader_addr;
  std::vector<std::pair<std::string, std::string>> net_custom;
  uint64_t net_refresh_timer = 0;
  uint64_t net_probe_timer = 0;
  size_t net_tick = 0;                     // round-robin index
  std::string mqtt_probe_host;
  int mqtt_probe_port = 1883;
  bool mqtt_probe_known = false;
  bool mqtt_probe_reachable = false;

  // ---------- helpers ----------
  bool uiNotify(const std::string& event_json) {




    if (started && loop->onLoopThread()) {
      refreshSnapshots();
    } else {
      scheduleSnapshotRefresh();
    }
    UiEventCb cb;
    {
      std::lock_guard<std::mutex> lk(cb_mu);
      cb = ui_cb;
    }
    if (cb) cb(event_json);
    return static_cast<bool>(cb);
  }

  std::string secretValue(const std::string& ref) {
    if (!secretRefValid(ref)) return "";
    SecureGetFn get;
    {
      std::lock_guard<std::mutex> lk(cb_mu);
      get = secure_get_fn;
    }
    return get ? get(ref.substr(7)) : "";
  }

  bool putSecret(const std::string& ref, const std::string& value) {
    if (!secretRefValid(ref) || value.size() > 64 * 1024) return false;
    SecurePutFn put;
    {
      std::lock_guard<std::mutex> lk(cb_mu);
      put = secure_put_fn;
    }
    return put && put(ref.substr(7), value);
  }

  bool secureStoreAvailable(bool require_put) {
    std::lock_guard<std::mutex> lk(cb_mu);
    return require_put ? static_cast<bool>(secure_put_fn) : static_cast<bool>(secure_get_fn);
  }

  bool secureStoreReadWrite() { return secureStoreAvailable(false) && secureStoreAvailable(true); }

  std::string migratedSecretRef(const std::string& logical_path) const {
    uint8_t digest[16];
    crypto_blake2b(digest, sizeof(digest),
                   reinterpret_cast<const uint8_t*>(logical_path.data()), logical_path.size());
    return "secret:migrated." + hexEncode(digest, sizeof(digest));
  }

  void noteSecretMigrationFailure(const std::string& kind, const std::string& reason) {
    const std::string warning = "legacy_" + kind + "_credential_" + reason;
    secret_migration_warnings.insert(warning);
    DB_LOGW(kTag, "removed a legacy " + kind + " credential from replicated config; " + reason);
  }

  bool migrateLegacySecret(const std::string& logical_path, const std::string& kind,
                           const cJSON* legacy_value, const std::string& configured_ref,
                           std::string* effective_ref, bool* ref_changed) {
    const bool existing_ref_valid = secretRefValid(configured_ref);
    if (existing_ref_valid && !secretValue(configured_ref).empty()) {
      *effective_ref = configured_ref;
      *ref_changed = false;
      return true;
    }
    if (!cJSON_IsString(legacy_value) || !legacy_value->valuestring ||
        !*legacy_value->valuestring) {
      *effective_ref = existing_ref_valid ? configured_ref : "";
      *ref_changed = false;
      noteSecretMigrationFailure(kind, "invalid_value");
      return false;
    }
    if (!secureStoreReadWrite()) {
      *effective_ref = existing_ref_valid ? configured_ref : "";
      *ref_changed = false;
      noteSecretMigrationFailure(kind, "secure_store_unavailable");
      return false;
    }
    const std::string ref = existing_ref_valid ? configured_ref
                                                : migratedSecretRef(logical_path);
    if (!putSecret(ref, legacy_value->valuestring)) {
      *effective_ref = existing_ref_valid ? configured_ref : "";
      *ref_changed = false;
      noteSecretMigrationFailure(kind, "secure_store_failed");
      return false;
    }
    *effective_ref = ref;
    *ref_changed = !existing_ref_valid;
    return true;
  }

  bool migrateLegacySecretsInObject(cJSON* object, const std::string& object_path) {
    if (!cJSON_IsObject(object)) return false;
    std::vector<std::string> fields;
    cJSON* child = nullptr;
    cJSON_ArrayForEach(child, object) {
      if (child->string) fields.emplace_back(child->string);
    }
    bool changed = false;
    for (const auto& field : fields) {
      child = json::get(object, field.c_str());
      if (!child) continue;
      const std::string path = object_path.empty() ? field : object_path + "." + field;
      std::string ref_path;
      std::string ref_field;
      std::string kind;
      if (legacyRuntimeSecretPath(path, &ref_path, &ref_field, &kind)) {
        const cJSON* sibling_ref = json::get(object, ref_field.c_str());
        std::string configured_ref = cJSON_IsString(sibling_ref) && sibling_ref->valuestring
            ? sibling_ref->valuestring : "";
        if (!secretRefValid(configured_ref)) {
          const cJSON* materialized_ref = cfgAt(ref_path);
          configured_ref = cJSON_IsString(materialized_ref) && materialized_ref->valuestring
              ? materialized_ref->valuestring : "";
        }
        std::string effective_ref;
        bool ref_changed = false;
        const bool migrated = migrateLegacySecret(path, kind, child, configured_ref,
                                                  &effective_ref, &ref_changed);
        cJSON_DeleteItemFromObjectCaseSensitive(object, field.c_str());
        if (migrated && (ref_changed || !secretRefValid(
                cJSON_IsString(sibling_ref) && sibling_ref->valuestring
                    ? sibling_ref->valuestring : "")))
          json::set(object, ref_field.c_str(), effective_ref);
        else if (!migrated && sibling_ref && !secretRefValid(
                     cJSON_IsString(sibling_ref) && sibling_ref->valuestring
                         ? sibling_ref->valuestring : ""))
          cJSON_DeleteItemFromObjectCaseSensitive(object, ref_field.c_str());
        changed = true;
        continue;
      }
      if (cJSON_IsObject(child))
        changed = migrateLegacySecretsInObject(child, path) || changed;
      else if (cJSON_IsArray(child)) {
        cJSON* item = nullptr;
        cJSON_ArrayForEach(item, child) {
          if (cJSON_IsObject(item))
            changed = migrateLegacySecretsInObject(item, path) || changed;
        }
      }
    }
    return changed;
  }

  bool migrateLegacyRuntimeCredentials() {
    std::vector<LwwMutation> mutations;
    for (const auto& entry : config->all()) {
      if (entry.deleted) continue;
      auto value = json::parse(entry.value_json);
      if (!value) value = json::Doc(cJSON_CreateString(entry.value_json.c_str()));
      std::string ref_path;
      std::string ref_field;
      std::string kind;
      if (legacyRuntimeSecretPath(entry.key, &ref_path, &ref_field, &kind)) {
        std::string configured_ref;
        const cJSON* materialized_ref = cfgAt(ref_path);
        if (cJSON_IsString(materialized_ref) && materialized_ref->valuestring)
          configured_ref = materialized_ref->valuestring;
        std::string effective_ref;
        bool ref_changed = false;
        const bool migrated = migrateLegacySecret(entry.key, kind, value.get(), configured_ref,
                                                  &effective_ref, &ref_changed);
        if (migrated && ref_changed) {
          auto ref_value = json::Doc(cJSON_CreateString(effective_ref.c_str()));
          mutations.push_back({ref_path, json::dump(ref_value.get()), false});
        }
        mutations.push_back({entry.key, "", true});
        continue;
      }
      if (migrateLegacySecretsInObject(value.get(), entry.key))
        mutations.push_back({entry.key, json::dump(value.get()), false});
    }
    if (mutations.empty()) return true;
    config->mutate(mutations);
    if (!config->lastMutationCommitted()) {
      secret_migration_warnings.insert("legacy_secret_scrub_config_persistence_failed");
      DB_LOGE(kTag, "legacy secret scrub could not be persisted; refusing startup");
      return false;
    }
    return true;
  }

  static bool constantTimeEqual(const std::string& a, const std::string& b) {
    size_t diff = a.size() ^ b.size();
    const size_t n = std::max(a.size(), b.size());
    for (size_t i = 0; i < n; ++i) {
      const unsigned char av = i < a.size() ? static_cast<unsigned char>(a[i]) : 0;
      const unsigned char bv = i < b.size() ? static_cast<unsigned char>(b[i]) : 0;
      diff |= static_cast<size_t>(av ^ bv);
    }
    return diff == 0;
  }

  std::vector<std::string> panelSecretRefs() {
    std::vector<std::string> refs;
    cJSON* configured = cfgAt("panel.token_refs");
    const cJSON* item = nullptr;
    cJSON_ArrayForEach(item, configured) {
      if (!cJSON_IsString(item)) continue;
      const std::string ref = item->valuestring ? item->valuestring : "";
      if (secretRefValid(ref)) refs.push_back(ref);
    }
    return refs;
  }

  PanelCredentialBinding panelCredentialBinding() {
    PanelCredentialBinding binding;
    binding.refs = panelSecretRefs();
    std::sort(binding.refs.begin(), binding.refs.end());
    binding.refs.erase(std::unique(binding.refs.begin(), binding.refs.end()),
                       binding.refs.end());
    const cJSON* generation = cfgAt("panel.token_generation");
    if (cJSON_IsString(generation) && generation->valuestring)
      binding.generation = generation->valuestring;
    return binding;
  }

  static bool samePanelCredentialBinding(const PanelCredentialBinding& a,
                                         const PanelCredentialBinding& b) {
    return a.generation == b.generation && a.refs == b.refs;
  }

  void invalidatePanelSessions() {
    std::lock_guard<std::mutex> lk(sess_mu);
    panel_sessions.clear();
  }

  bool panelCredentialOk(const std::string& candidate) {
    if (candidate.empty()) return false;
    bool matched = false;
    for (const auto& ref : panelSecretRefs()) {
      const std::string expected = secretValue(ref);
      matched = constantTimeEqual(candidate, expected) || matched;
    }
    return matched;
  }

  bool issuePanelCredential(std::string* token, std::string* ref) {
    if (!secureStoreReadWrite()) return false;
    *token = genTokenHex(16);
    *ref = "secret:panel.access." + genTokenHex(8);
    return putSecret(*ref, *token);
  }

  bool migrateRawPanelCredentials() {
    const auto raw_json = config->get("panel.tokens");
    if (!raw_json) return true;
    auto raw = json::parse(*raw_json);
    std::vector<std::string> refs;
    if (secureStoreReadWrite() && cJSON_IsArray(raw.get())) {
      const cJSON* item = nullptr;
      cJSON_ArrayForEach(item, raw.get()) {
        if (!cJSON_IsString(item) || !item->valuestring || !*item->valuestring) continue;
        const std::string ref = "secret:panel.access.migrated." + genTokenHex(8);
        if (putSecret(ref, item->valuestring)) refs.push_back(ref);
      }
    }
    std::vector<LwwMutation> mutations;
    if (!refs.empty()) {
      auto values = json::arr();
      for (const auto& ref : refs)
        json::push(values.get(), json::Doc(cJSON_CreateString(ref.c_str())));
      mutations.push_back({"panel.token_refs", json::dump(values.get()), false});
    }
    mutations.push_back({"panel.tokens", "", true});
    config->mutate(mutations);
    if (!config->lastMutationCommitted()) {
      for (const auto& ref : refs) putSecret(ref, "");
      secret_migration_warnings.insert(
          "legacy_panel_credential_scrub_config_persistence_failed");
      DB_LOGE(kTag, "legacy panel credential scrub could not be persisted; refusing startup");
      return false;
    }
    DB_LOGI(kTag, refs.empty()
                      ? "removed legacy persisted panel credentials; rotate from Admin"
                      : "migrated legacy panel credentials to platform secure storage");
    return true;
  }

  static const char* webPushSealAad() { return "doorbell.web_push.subscription.v1"; }

  bool webPushSealKey(std::array<uint8_t, 32>* key) const {
    const std::array<uint8_t, 32>& live_psk = mesh ? mesh->settings().psk : opts.psk;
    const bool configured = std::any_of(live_psk.begin(), live_psk.end(),
                                        [](uint8_t value) { return value != 0; });
    if (!configured) return false;
    Bytes material(live_psk.begin(), live_psk.end());
    const char* aad = webPushSealAad();
    material.insert(material.end(), aad, aad + std::strlen(aad));
    crypto_blake2b(key->data(), key->size(), material.data(), material.size());
    return true;
  }

  static json::Doc normalizedWebPushSubscription(const cJSON* subscription) {
    if (!cJSON_IsObject(subscription)) return {};
    const std::string endpoint = json::getString(subscription, "endpoint");
    const cJSON* keys = json::get(subscription, "keys");
    const std::string p256dh = json::getString(keys, "p256dh");
    const std::string auth = json::getString(keys, "auth");
    if (endpoint.rfind("https://", 0) != 0 || endpoint.size() > 4096 ||
        !cJSON_IsObject(keys) || p256dh.empty() || p256dh.size() > 1024 || auth.empty() ||
        auth.size() > 512)
      return {};
    auto normalized = json::obj();
    json::set(normalized.get(), "endpoint", endpoint);
    if (const cJSON* expiration = json::get(subscription, "expirationTime")) {
      if (cJSON_IsNull(expiration) || cJSON_IsNumber(expiration))
        json::setItem(normalized.get(), "expirationTime",
                      json::Doc(cJSON_Duplicate(expiration, 1)));
    }
    cJSON* normalized_keys = json::addObj(normalized.get(), "keys");
    json::set(normalized_keys, "p256dh", p256dh);
    json::set(normalized_keys, "auth", auth);
    return normalized;
  }

  json::Doc sealWebPushRecord(const cJSON* subscription, const std::string& page,
                              const std::string& group, int64_t updated_at_ms) const {
    auto normalized = normalizedWebPushSubscription(subscription);
    std::array<uint8_t, 32> key{};
    if (!normalized || !webPushSealKey(&key)) return {};
    const std::string plain = json::dump(normalized.get());
    Bytes nonce = randomBytes(24);
    Bytes cipher(16 + plain.size());
    const char* aad = webPushSealAad();
    crypto_aead_lock(cipher.data() + 16, cipher.data(), key.data(), nonce.data(),
                     reinterpret_cast<const uint8_t*>(aad), std::strlen(aad),
                     reinterpret_cast<const uint8_t*>(plain.data()), plain.size());
    crypto_wipe(key.data(), key.size());

    auto record = json::obj();
    json::set(record.get(), "schema_version", static_cast<int64_t>(2));
    cJSON* sealed = json::addObj(record.get(), "sealed_subscription");
    json::set(sealed, "algorithm", "xchacha20-poly1305");
    json::set(sealed, "nonce", hexEncode(nonce));
    json::set(sealed, "ciphertext", hexEncode(cipher));
    json::set(record.get(), "page", page);
    json::set(record.get(), "group", group);
    json::set(record.get(), "updated_at_ms", updated_at_ms);
    return record;
  }

  json::Doc openWebPushRecord(const cJSON* record) const {
    if (!cJSON_IsObject(record) || json::getInt(record, "schema_version") != 2) return {};
    const cJSON* sealed = json::get(record, "sealed_subscription");
    if (!cJSON_IsObject(sealed) ||
        json::getString(sealed, "algorithm") != "xchacha20-poly1305")
      return {};
    Bytes nonce, cipher;
    if (!hexDecode(json::getString(sealed, "nonce"), nonce) || nonce.size() != 24 ||
        !hexDecode(json::getString(sealed, "ciphertext"), cipher) || cipher.size() < 17 ||
        cipher.size() > 16 * 1024)
      return {};
    std::array<uint8_t, 32> key{};
    if (!webPushSealKey(&key)) return {};
    Bytes plain(cipher.size() - 16);
    const char* aad = webPushSealAad();
    const int rc = crypto_aead_unlock(
        plain.data(), cipher.data(), key.data(), nonce.data(),
        reinterpret_cast<const uint8_t*>(aad), std::strlen(aad),
        cipher.data() + 16, plain.size());
    crypto_wipe(key.data(), key.size());
    if (rc != 0) return {};
    auto subscription = json::parse(std::string(plain.begin(), plain.end()));
    crypto_wipe(plain.data(), plain.size());
    auto normalized = subscription ? normalizedWebPushSubscription(subscription.get()) : json::Doc{};
    if (!normalized) return {};
    auto opened = json::obj();
    json::setItem(opened.get(), "subscription", std::move(normalized));
    json::set(opened.get(), "page", json::getString(record, "page", "/panel/monitor"));
    json::set(opened.get(), "group", json::getString(record, "group", "all"));
    json::set(opened.get(), "updated_at_ms", json::getInt(record, "updated_at_ms"));
    return opened;
  }

  json::Doc webPushSubscriptions() {
    auto subscriptions = json::arr();
    const cJSON* records = cfgAt("web_push.subscriptions");
    const cJSON* record = nullptr;
    cJSON_ArrayForEach(record, records) {
      auto opened = openWebPushRecord(record);
      if (opened) json::push(subscriptions.get(), std::move(opened));
    }
    return subscriptions;
  }

  bool migrateLegacyWebPushSubscriptions() {
    std::vector<LwwMutation> mutations;
    for (const auto& entry : config->all()) {
      if (entry.deleted || entry.key.rfind("web_push.subscriptions.", 0) != 0) continue;
      auto legacy = json::parse(entry.value_json);
      if (!legacy || json::get(legacy.get(), "sealed_subscription")) continue;
      cJSON* subscription = json::get(legacy.get(), "subscription");
      auto temporary = subscription ? json::Doc(cJSON_Duplicate(subscription, 1)) : json::Doc{};
      cJSON* keys = temporary ? json::get(temporary.get(), "keys") : nullptr;
      if (cJSON_IsObject(keys) && json::getString(keys, "auth").empty()) {
        const std::string auth_ref = json::getString(keys, "auth_ref");
        const std::string auth = secretValue(auth_ref);
        if (!auth.empty()) json::set(keys, "auth", auth);
      }
      auto sealed = temporary
          ? sealWebPushRecord(temporary.get(), json::getString(legacy.get(), "page", "/panel/monitor"),
                              json::getString(legacy.get(), "group", "all"),
                              json::getInt(legacy.get(), "updated_at_ms"))
          : json::Doc{};
      if (sealed)
        mutations.push_back({entry.key, json::dump(sealed.get()), false});
      else
        mutations.push_back({entry.key, "", true});
    }
    if (!mutations.empty()) {
      config->mutate(mutations);
      if (!config->lastMutationCommitted()) {
        secret_migration_warnings.insert(
            "legacy_web_push_scrub_config_persistence_failed");
        DB_LOGE(kTag, "legacy Web Push scrub could not be persisted; refusing startup");
        return false;
      }
      DB_LOGI(kTag, "sealed legacy Web Push subscriptions with the mesh credential; " +
                        std::to_string(mutations.size()) + " record(s) processed");
    }
    return true;
  }

  static std::string webPushSubscriptionKey(const std::string& endpoint) {
    uint8_t digest[16];
    crypto_blake2b(digest, sizeof(digest),
                   reinterpret_cast<const uint8_t*>(endpoint.data()), endpoint.size());
    return hexEncode(digest, sizeof(digest));
  }

  void tts(const std::string& text, const std::string& lang) {
    TtsCb cb;
    {
      std::lock_guard<std::mutex> lk(cb_mu);
      cb = tts_cb;
    }
    if (cb) cb(text, lang);
  }

  // The configured IANA zone, or an empty string when the cluster has never set one. An empty
  // zone keeps integrations.tz_offset_min authoritative, which is what an upgraded installation
  // that only ever had the fixed offset expects.
  std::string configuredTimeZone() const {
    return json::getString(json::get(cfg.get(), "time"), "zone");
  }

  int legacyTzOffsetMin() const {
    const cJSON* integ = json::get(cfg.get(), "integrations");
    return static_cast<int>(json::getInt(integ, "tz_offset_min", 540));
  }

  // Offset east of UTC at a given instant, so schedules and quiet hours follow daylight saving
  // instead of a frozen snapshot.
  int tzOffsetMinAt(int64_t wall_ms) const {
    const std::string zone = configuredTimeZone();
    int offset = 0;
    if (!zone.empty() && tz::offsetMinAt(zone, wall_ms, &offset)) return offset;
    return legacyTzOffsetMin();
  }

  int tzOffsetMin() { return tzOffsetMinAt(hlc->correctedWallMs()); }

  // Pure: the caller supplies the instant, so this runs on any thread from a published record.
  static std::string renderLocalTime(const TimeSnapshot& snap, int64_t wall_ms, int64_t now_ms) {
    const int64_t at = wall_ms > 0 ? wall_ms : std::max(now_ms, snap.hlc_floor_ms);
    return tz::localTimeJson(snap.zone, at, snap.legacy_offset_min);
  }

  std::shared_ptr<const TimeSnapshot> buildTimeSnapshot() {
    auto snap = std::make_shared<TimeSnapshot>();
    snap->zone = configuredTimeZone();
    snap->legacy_offset_min = legacyTzOffsetMin();
    const bool active = ntpActive();
    snap->source = active ? "ntp" : "system";
    snap->offset_ms = active ? time_state.offset_ms : 0;
    snap->last_sync_wall_ms = time_state.ever_synced ? time_state.last_sync_wall_ms : 0;
    snap->hlc_floor_ms = hlc ? hlc->correctedWallMs() : clock->wallMs();
    return snap;
  }

  // Called wherever the zone, the offset or the sync result can have changed. Cheap enough to
  // run unconditionally: readers only ever see a fully built record.
  void publishTimeSnapshot() {
    std::atomic_store(&time_snap, std::shared_ptr<const TimeSnapshot>(buildTimeSnapshot()));
  }

  std::string localTimeJsonOnLoop(int64_t wall_ms) {
    return renderLocalTime(*buildTimeSnapshot(), wall_ms, clock->wallMs());
  }

  // ---------- time service ----------
  bool ntpEnabled() const {
    return json::getBool(json::get(json::get(cfg.get(), "time"), "ntp"), "enabled", false);
  }

  // Once a day by default. A measured offset does not drift meaningfully over hours, so the
  // old fifteen-minute round trip bought nothing and cost battery, traffic, and a wake-up on
  // every device in the house. Configuration written before this rule is clamped on read.
  int ntpIntervalS() const {
    const int64_t seconds =
        json::getInt(json::get(json::get(cfg.get(), "time"), "ntp"), "interval_s", 86400);
    if (seconds < 3600) return 3600;
    if (seconds > 604800) return 604800;
    return static_cast<int>(seconds);
  }

  std::vector<std::string> ntpServers() const {
    std::vector<std::string> servers;
    const cJSON* list = json::get(json::get(json::get(cfg.get(), "time"), "ntp"), "servers");
    const cJSON* entry = nullptr;
    cJSON_ArrayForEach(entry, list) {
      if (cJSON_IsString(entry) && servers.size() < 4) servers.push_back(entry->valuestring);
    }
    if (servers.empty()) {
      servers.push_back("ntp.nict.jp");
      servers.push_back("time.google.com");
    }
    return servers;
  }

  // A measured offset is trusted for three sync intervals. After that the source falls back to
  // system time rather than drifting on a stale correction.
  bool timeSyncFresh() const {
    if (!time_state.ok) return false;
    const int64_t age = clock->monoMs() - time_state.last_sync_mono_ms;
    return age >= 0 && age <= 3LL * ntpIntervalS() * 1000LL;
  }

  bool ntpActive() const { return ntpEnabled() && timeSyncFresh(); }

  // Apply (or withdraw) the offset on the shared clock and report a meaningful change.
  void applyTimeOffset() {
    const bool active = ntpActive();
    const int64_t offset = active ? time_state.offset_ms : 0;
    if (clock->wallOffsetMs() != offset) clock->setWallOffsetMs(offset);
    const std::string source = active ? "ntp" : "system";
    // A sync result must reach db_core_local_time_json now, not at the next periodic refresh.
    publishTimeSnapshot();
    const int64_t moved = offset - reported_time_offset_ms;
    if (source == reported_time_source && (moved > -500 && moved < 500)) return;
    reported_time_source = source;
    reported_time_offset_ms = offset;
    auto event = json::obj();
    json::set(event.get(), "t", "time_changed");
    json::set(event.get(), "source", source);
    json::set(event.get(), "offset_ms", offset);
    json::set(event.get(), "zone", configuredTimeZone());
    uiNotify(json::dump(event.get()));
  }

  json::Doc timeStatusDoc() {
    auto out = json::obj();
    const std::string zone = configuredTimeZone();
    json::set(out.get(), "zone", zone);
    json::setBool(out.get(), "zone_known", !zone.empty() && tz::zoneKnown(zone));
    const bool active = ntpActive();
    json::set(out.get(), "source", active ? "ntp" : "system");
    json::setBool(out.get(), "enabled", ntpEnabled());
    json::setBool(out.get(), "ok", time_state.ok);
    json::set(out.get(), "offset_ms", active ? time_state.offset_ms : static_cast<int64_t>(0));
    json::set(out.get(), "measured_offset_ms", time_state.offset_ms);
    json::set(out.get(), "last_sync_ms", time_state.ever_synced ? time_state.last_sync_wall_ms
                                                               : static_cast<int64_t>(0));
    json::set(out.get(), "rtt_ms", time_state.rtt_ms);
    json::set(out.get(), "server", time_state.server);
    json::set(out.get(), "interval_s", static_cast<int64_t>(ntpIntervalS()));
    json::set(out.get(), "offset_min", static_cast<int64_t>(tzOffsetMin()));
    json::setBool(out.get(), "syncing", time_sync_busy);
    // Zero while the schedule is running normally; the seconds until the next retry after a
    // failed round, so an administrator can see the service is backing off rather than idle.
    json::set(out.get(), "retry_in_s", static_cast<int64_t>(time_sync_backoff_s));
    if (!time_state.last_error.empty()) json::set(out.get(), "err", time_state.last_error);
    // The identifiers core can actually resolve, grouped the way a picker lists them. A shell
    // that offered a zone outside this table would show a setting core rejects on save.
    {
      cJSON* zones = json::addObj(out.get(), "zones");
      for (size_t i = 0; i < tz::zoneCount(); i++) {
        const std::string id = tz::zoneIdAt(i);
        const std::string region = tz::regionOf(id);
        cJSON* group = json::get(zones, region.c_str());
        if (!group) group = json::addArr(zones, region.c_str());
        json::push(group, json::Doc(cJSON_CreateString(id.c_str())));
      }
    }
    auto local = json::parse(localTimeJsonOnLoop(0));
    json::setItem(out.get(), "local", local ? std::move(local) : json::obj());
    return out;
  }

  void cancelTimeSyncTimer() {
    if (!time_sync_timer) return;
    loop->cancel(time_sync_timer);
    time_sync_timer = 0;
  }

  // One shot at a time, re-armed when each round finishes, so a failure can come back sooner
  // than the interval without a second timer racing the first.
  void armTimeSyncTimer() {
    cancelTimeSyncTimer();
    if (!started || !ntpEnabled()) return;
    const int64_t delay_ms = time_sync_backoff_s > 0
        ? static_cast<int64_t>(time_sync_backoff_s) * 1000LL
        : static_cast<int64_t>(ntpIntervalS()) * 1000LL;
    time_sync_timer = loop->postDelayed(delay_ms, [this] {
      time_sync_timer = 0;
      if (!startTimeSync()) armTimeSyncTimer();
    });
  }

  // Exactly one round when the service is switched on, when the servers change, and at
  // start-up -- then the interval. Changing the interval alone re-arms the timer without
  // spending a round trip, which is the difference between an administrator adjusting a
  // setting and a device deciding to talk to the internet.
  void reapplyTimeSchedule() {
    if (!ntpEnabled()) {
      cancelTimeSyncTimer();
      time_sync_armed = false;
      time_sync_servers_key.clear();
      time_sync_backoff_s = 0;
      applyTimeOffset();
      return;
    }
    std::string servers_key;
    for (const auto& server : ntpServers()) servers_key += server + "\n";
    const bool sync_now = !time_sync_armed || servers_key != time_sync_servers_key;
    time_sync_armed = true;
    time_sync_servers_key = servers_key;
    if (!sync_now) {
      armTimeSyncTimer();
      return;
    }
    time_sync_backoff_s = 0;
    // A round in flight arms the next timer when it completes; one that refused to start still
    // needs a schedule.
    if (!startTimeSync()) armTimeSyncTimer();
  }

  // Kick one synchronization round. The exchange itself runs on a short-lived worker thread: a
  // handful of UDP round trips must never stall the state runloop.
  bool startTimeSync() {
    if (!started || !ntpEnabled()) return false;
    if (time_sync_busy) return true;
    if (time_sync_thread.joinable()) time_sync_thread.join();
    time_sync_busy = true;
    time_sync_abort.store(false);
    auto servers = ntpServers();
    time_sync_thread = std::thread([this, servers] { timeSyncWorker(servers); });
    scheduleSnapshotRefresh();
    return true;
  }

  void timeSyncWorker(const std::vector<std::string>& servers) {
    const int64_t deadline_mono = clock->monoMs() + 5000;
    bool ok = false;
    sntp::Sample best{};
    std::string best_server;
    std::string last_error = "no_response";
    for (const auto& spec : servers) {
      std::string host;
      int port = sntp::kDefaultPort;
      if (!sntp::parseServer(spec, &host, &port)) {
        last_error = "bad_server";
        continue;
      }
      for (int attempt = 0; attempt < 3; attempt++) {
        if (time_sync_abort.load() || clock->monoMs() > deadline_mono) break;
        uint8_t request[sntp::kPacketSize];
        uint8_t response[sntp::kPacketSize];
        const int64_t t1 = clock->systemWallMs();
        sntp::buildRequest(request, t1);
        if (!sntp::exchange(host, port, 800, request, response)) continue;
        const int64_t t4 = clock->systemWallMs();
        sntp::Reply reply;
        if (!sntp::parseReply(response, sizeof(response), t1, &reply)) {
          last_error = "bad_reply";
          continue;
        }
        const sntp::Sample sample =
            sntp::computeSample(t1, reply.receive_ms, reply.transmit_ms, t4);
        if (!sntp::sampleSane(sample)) {
          last_error = "implausible";
          continue;
        }
        if (!ok || sample.rtt_ms < best.rtt_ms) {
          best = sample;
          best_server = spec;
          ok = true;
        }
      }
      if (time_sync_abort.load() || clock->monoMs() > deadline_mono) break;
    }
    const int64_t offset = best.offset_ms;
    const int64_t rtt = best.rtt_ms;
    loop->post([this, ok, offset, rtt, best_server, last_error] {
      time_sync_busy = false;
      if (ok) {
        time_state.ok = true;
        time_state.ever_synced = true;
        time_state.offset_ms = offset;
        time_state.rtt_ms = rtt;
        time_state.server = best_server;
        time_state.last_sync_mono_ms = clock->monoMs();
        time_state.last_sync_wall_ms = clock->systemWallMs() + offset;
        time_state.last_error.clear();
        time_sync_backoff_s = 0;
      } else {
        time_state.last_error = last_error;
        // Come back sooner than the interval, but doubling each time: a device with no route to
        // a time server settles at one attempt an hour instead of one a minute forever.
        time_sync_backoff_s = time_sync_backoff_s > 0
            ? std::min(time_sync_backoff_s * 2, kTimeSyncBackoffMaxS)
            : kTimeSyncBackoffMinS;
      }
      applyTimeOffset();
      armTimeSyncTimer();
      scheduleSnapshotRefresh();
    });
  }

  void stopTimeSync() {
    time_sync_abort.store(true);
    if (time_sync_thread.joinable()) time_sync_thread.join();
    time_sync_busy = false;
  }

  // ---------- power ----------
  json::Doc powerDoc() const {
    auto out = json::obj();
    json::set(out.get(), "battery_pct", static_cast<int64_t>(power.battery_pct));
    json::setBool(out.get(), "charging", power.charging);
    json::setBool(out.get(), "mains", power.mains);
    return out;
  }

  void pollPowerState() {
    Node::PowerStateFn fn;
    {
      std::lock_guard<std::mutex> lk(cb_mu);
      fn = power_state_fn;
    }
    if (!fn) return;
    const std::string raw = fn();
    auto parsed = json::parse(raw);
    if (!parsed || !cJSON_IsObject(parsed.get())) return;
    PowerState next;
    next.known = true;
    int64_t pct = json::getInt(parsed.get(), "battery_pct", -1);
    if (pct < -1) pct = -1;
    if (pct > 100) pct = 100;
    next.battery_pct = static_cast<int>(pct);
    next.charging = json::getBool(parsed.get(), "charging", false);
    next.mains = json::getBool(parsed.get(), "mains", false);
    const bool first = !power.known;
    power = next;
    const int delta = next.battery_pct - reported_power.battery_pct;
    const bool moved = delta >= 5 || delta <= -5;
    if (first || moved || next.charging != reported_power.charging ||
        next.mains != reported_power.mains ||
        (next.battery_pct < 0) != (reported_power.battery_pct < 0)) {
      reported_power = next;
      publishMeshRuntime();
      applyEffectiveCaps();
      auto event = json::obj();
      json::set(event.get(), "t", "power_changed");
      json::set(event.get(), "battery_pct", static_cast<int64_t>(next.battery_pct));
      json::setBool(event.get(), "charging", next.charging);
      json::setBool(event.get(), "mains", next.mains);
      uiNotify(json::dump(event.get()));
      scheduleSnapshotRefresh();
    }
  }

  // Peer-visible runtime carries the core-owned power section on top of whatever the shell
  // published, so peers[].power works without every shell learning a new contract.
  std::string meshRuntimeJson() const {
    auto doc = json::parse(runtime_status_json);
    if (!doc || !cJSON_IsObject(doc.get())) doc = json::obj();
    if (power.known) json::setItem(doc.get(), "power", powerDoc());
    return json::dump(doc.get());
  }

  void publishMeshRuntime() {
    if (mesh) mesh->setRuntime(meshRuntimeJson());
  }

  // ---------- announcements ----------
  // "*" addresses the cluster-wide announcement stored at notice.global. A door-specific
  // announcement always wins over it, so a station can override the house-wide message.
  static bool isGlobalNoticeTarget(const std::string& door) { return door == "*"; }

  std::string noticeKeyFor(const std::string& door) const {
    return isGlobalNoticeTarget(door) ? std::string("notice.global")
                                      : "doors." + door + ".notice";
  }

  // The announcement a given door actually shows, with the scope it came from.
  json::Doc effectiveDoorNoticeDoc(const std::string& door) {
    const cJSON* specific =
        json::get(json::get(json::get(cfg.get(), "doors"), door.c_str()), "notice");
    const cJSON* global = json::get(json::get(cfg.get(), "notice"), "global");
    const cJSON* chosen = cJSON_IsObject(specific) ? specific : global;
    if (!cJSON_IsObject(chosen)) return {};
    auto out = json::Doc(cJSON_Duplicate(chosen, 1));
    if (out) json::set(out.get(), "scope", cJSON_IsObject(specific) ? "door" : "global");
    return out;
  }

  json::Doc doorNoticeDoc(const std::string& text, int64_t expires_ms) const {
    auto out = json::obj();
    json::set(out.get(), "text", text);
    json::set(out.get(), "from_device", node_id);
    json::set(out.get(), "created_ms", hlc->correctedWallMs());
    json::set(out.get(), "expires_ms", expires_ms > 0 ? expires_ms : static_cast<int64_t>(0));
    return out;
  }

  // A purpose a visitor may still choose: configured and not switched off by an administrator.
  bool purposeSelectable(const std::string& purpose) {
    const cJSON* entry = cfgAt("visit_purposes." + purpose);
    return entry != nullptr && json::getBool(entry, "enabled", true);
  }

  // A door is addressable when it is configured OR when a live door station is serving it. The
  // second case is the degraded one an older configuration leaves behind: the tile is on screen,
  // so posting an announcement to it must work rather than reporting "unknown door".
  bool doorExists(const std::string& door) {
    if (door.empty()) return false;
    if (cJSON_IsObject(json::get(json::get(cfg.get(), "doors"), door.c_str()))) return true;
    if (opts.role == "door_station" && opts.door == door) return true;
    if (!mesh) return false;
    for (const auto& peer : mesh->peers()) {
      if (peer.status != "alive") continue;
      const cJSON* device = cfgAt("devices." + peer.id);
      std::string role = json::getString(device, "role");
      if (role.empty()) role = peer.role;
      if (role != "door_station") continue;
      std::string peer_door = json::getString(device, "door");
      if (peer_door.empty()) peer_door = peer.door;
      if (peer_door == door) return true;
    }
    return false;
  }

  bool setDoorNoticeOnLoop(const std::string& door, const std::string& text, int64_t expires_ms) {
    if (door.empty()) return false;
    if (!isGlobalNoticeTarget(door) && !doorExists(door)) return false;
    auto value = doorNoticeDoc(text, expires_ms);
    std::string error;
    const std::string key = noticeKeyFor(door);
    if (!configWriteValid(key, value.get(), &error)) {
      DB_LOGW(kTag, "rejected door notice for " + door + " (" + error + ")");
      return false;
    }
    config->mutate({{key, json::dump(value.get()), false}});
    return config->lastMutationCommitted();
  }

  bool clearDoorNoticeOnLoop(const std::string& door) {
    if (door.empty()) return false;
    const std::string key = noticeKeyFor(door);
    const cJSON* current =
        isGlobalNoticeTarget(door)
            ? json::get(json::get(cfg.get(), "notice"), "global")
            : json::get(json::get(json::get(cfg.get(), "doors"), door.c_str()), "notice");
    if (!current) return true;
    config->mutate({{key, "", true}});
    return config->lastMutationCommitted();
  }

  // ---------- door unlock ----------
  // The unlock action is the existing feature-code path: a configured ha_command that the MQTT
  // bridge republishes as <base>/cmd/<command>. A door may name its own command; otherwise the
  // first ha_command among the SIP feature codes is used. An empty result means no unlock action
  // is configured anywhere, which the shells must say out loud rather than silently doing nothing.
  std::string unlockCommandFor(const std::string& door) {
    const std::string configured =
        json::getString(json::get(cfgAt("doors." + door), "unlock"), "command");
    if (!configured.empty()) return configured;
    const cJSON* actions = cfgAt("sip.dtmf_actions");
    const cJSON* action = nullptr;
    cJSON_ArrayForEach(action, actions) {
      if (json::getString(action, "type") != "ha_command") continue;
      const std::string command = json::getString(action, "command");
      if (!command.empty()) return command;
    }
    return "";
  }

  json::Doc doorUnlockDoc(const std::string& door) {
    const std::string command = unlockCommandFor(door);
    const cJSON* unlock = json::get(cfgAt("doors." + door), "unlock");
    const cJSON* configured_visibility = json::get(unlock, "show_button");
    auto out = json::obj();
    json::setBool(out.get(), "configured", !command.empty());
    json::set(out.get(), "command", command);
    // Default: show the control exactly when it can do something. An administrator may force
    // either answer, including showing it on a door that has no action yet.
    const bool show = cJSON_IsBool(configured_visibility) ? cJSON_IsTrue(configured_visibility)
                                                          : !command.empty();
    json::setBool(out.get(), "show_button", show);
    json::set(out.get(), "source", cJSON_IsBool(configured_visibility) ? "admin" : "default");
    return out;
  }

  // Trigger the configured unlock action for one door. Returns false when nothing is configured,
  // so the caller can explain instead of reporting a success that did nothing.
  bool openDoorOnLoop(const std::string& door_arg) {
    const std::string door = door_arg.empty() ? opts.door : door_arg;
    if (door.empty() || !doorExists(door)) return false;
    const std::string command = unlockCommandFor(door);
    if (command.empty()) return false;
    auto payload = json::obj();
    json::set(payload.get(), "type", "ha_command");
    json::set(payload.get(), "command", command);
    json::set(payload.get(), "door", door);
    json::set(payload.get(), "via", "api");
    const EventRecord recorded =
        events->append("dtmf_action", door, node_id, json::dump(payload.get()));
    return recorded.seq != 0;
  }

  // Drop announcements whose expiry has passed. Any node may prune; the tombstone replicates and
  // a repeated prune is a no-op.
  void pruneDoorNotices() {
    const int64_t now = hlc->correctedWallMs();
    std::vector<LwwMutation> expired;
    const cJSON* doors = json::get(cfg.get(), "doors");
    const cJSON* door = nullptr;
    cJSON_ArrayForEach(door, doors) {
      if (!door->string) continue;
      const cJSON* notice = json::get(door, "notice");
      if (!cJSON_IsObject(notice)) continue;
      const int64_t expires = json::getInt(notice, "expires_ms", 0);
      if (expires > 0 && now >= expires)
        expired.push_back({std::string("doors.") + door->string + ".notice", "", true});
    }
    const cJSON* global = json::get(json::get(cfg.get(), "notice"), "global");
    if (cJSON_IsObject(global)) {
      const int64_t expires = json::getInt(global, "expires_ms", 0);
      if (expires > 0 && now >= expires) expired.push_back({"notice.global", "", true});
    }
    if (expired.empty()) return;
    config->mutate(expired);
  }

  // ---------- volumes ----------
  // Device override wins over the cluster default; emergency.alarm_volume remains the legacy
  // source for the SOS level so an existing installation keeps its configured alarm loudness.
  static void readAudioLevels(const cJSON* container, AudioSnapshot::Levels* out) {
    auto one = [&](const char* name, AudioSnapshot::Level* slot) {
      const cJSON* value = json::get(container, name);
      if (!cJSON_IsNumber(value)) return;
      const int64_t whole = static_cast<int64_t>(value->valuedouble);
      if (whole < 0 || whole > 100) return;
      slot->present = true;
      slot->value = whole;
    };
    one("call", &out->call);
    one("sos", &out->sos);
    one("idle", &out->idle);
  }

  std::shared_ptr<const AudioSnapshot> buildAudioSnapshot() {
    auto snap = std::make_shared<AudioSnapshot>();
    snap->self_id = node_id;
    readAudioLevels(cfgAt("audio.volume"), &snap->cluster);
    snap->alarm_volume = json::getInt(json::get(cfg.get(), "emergency"), "alarm_volume", 100);
    const cJSON* devices = json::get(cfg.get(), "devices");
    const cJSON* device = nullptr;
    cJSON_ArrayForEach(device, devices) {
      if (!device->string) continue;
      AudioSnapshot::Levels levels;
      readAudioLevels(json::get(json::get(json::get(device, "local"), "audio"), "volume"),
                      &levels);
      if (levels.call.present || levels.sos.present || levels.idle.present)
        snap->devices[device->string] = levels;
    }
    return snap;
  }

  void publishAudioSnapshot() {
    std::atomic_store(&audio_snap, std::shared_ptr<const AudioSnapshot>(buildAudioSnapshot()));
  }

  // Pure: device override, then cluster default, then the built-in fallback.
  static std::string resolveAudioJson(const AudioSnapshot& snap, const std::string& device_arg) {
    const std::string id = device_arg.empty() ? snap.self_id : device_arg;
    const AudioSnapshot::Levels* device = nullptr;
    auto found = snap.devices.find(id);
    if (found != snap.devices.end()) device = &found->second;
    const int64_t alarm =
        (snap.alarm_volume < 0 || snap.alarm_volume > 100) ? 100 : snap.alarm_volume;
    struct Field {
      const char* name;
      AudioSnapshot::Level AudioSnapshot::Levels::*member;
      int64_t fallback;
    };
    const Field fields[] = {{"call", &AudioSnapshot::Levels::call, 80},
                            {"sos", &AudioSnapshot::Levels::sos, alarm},
                            {"idle", &AudioSnapshot::Levels::idle, 60}};
    auto out = json::obj();
    json::set(out.get(), "device", id);
    cJSON* sources = json::addObj(out.get(), "sources");
    bool any_device = false;
    bool any_cluster = false;
    for (const auto& field : fields) {
      int64_t value = field.fallback;
      const char* source = "default";
      if (device && (device->*(field.member)).present) {
        value = (device->*(field.member)).value;
        source = "device";
        any_device = true;
      } else if ((snap.cluster.*(field.member)).present) {
        value = (snap.cluster.*(field.member)).value;
        source = "cluster";
        any_cluster = true;
      }
      json::set(out.get(), field.name, value);
      json::set(sources, field.name, source);
    }
    json::set(out.get(), "source",
              any_device ? "device" : (any_cluster ? "cluster" : "default"));
    return json::dump(out.get());
  }

  // ---------- one-minute housekeeping ----------
  void minuteTick() {
    pollPowerState();
    pruneDoorNotices();
    applyTimeOffset();
    refreshDerivedTzOffset();
  }

  // integrations.tz_offset_min stays the compatibility surface for shells and the Telegram
  // bridge; when a zone is configured it is a derived value that follows daylight saving.
  void refreshDerivedTzOffset() {
    const std::string zone = configuredTimeZone();
    if (zone.empty()) return;
    int offset = 0;
    if (!tz::offsetMinAt(zone, hlc->correctedWallMs(), &offset)) return;
    if (legacyTzOffsetMin() == offset) return;
    config->mutate({{"integrations.tz_offset_min", std::to_string(offset), false}});
  }

  void scheduleSnapshotRefresh() {
    std::lock_guard<std::mutex> lk(snap_mu);
    if (snap_scheduled) return;
    snap_scheduled = true;
    if (!loop->post([this] { refreshSnapshots(); })) snap_scheduled = false;
  }





  void pushVideoTrack(const uint8_t* p, size_t n, bool key, int64_t ts) {
    bool was = video_track.active();
    video_track.push(p, n, key, ts);
    if (!was && video_track.active()) scheduleSnapshotRefresh();
  }

  void refreshSnapshots() {
    if (!started) {
      std::lock_guard<std::mutex> lk(snap_mu);
      snap_scheduled = false;
      return;
    }
    std::string status = statusJsonOnLoop();
    std::string config_json = config->materializeJson();
    std::string pairing = pairingJsonOnLoop();
    // Published separately: these two are read without taking snap_mu, so a caller polling the
    // clock never queues behind a status string copy either.
    publishTimeSnapshot();
    publishAudioSnapshot();
    std::lock_guard<std::mutex> lk(snap_mu);
    status_snap = std::move(status);
    config_snap = std::move(config_json);
    pairing_snap = std::move(pairing);
    snap_scheduled = false;
  }

  void rebuildCfg() {
    cfg = json::parse(config->materializeJson());
    if (!cfg) cfg = json::obj();
    playback_invalid_logged.clear();
    rules.setConfig(json::dump(cfg.get()));
  }


  cJSON* cfgAt(const std::string& dotpath) {
    cJSON* cur = cfg.get();
    size_t pos = 0;
    while (cur && pos <= dotpath.size()) {
      size_t dot = dotpath.find('.', pos);
      std::string part = dotpath.substr(pos, dot == std::string::npos ? std::string::npos : dot - pos);
      cur = json::get(cur, part.c_str());
      if (dot == std::string::npos) return cur;
      pos = dot + 1;
    }
    return cur;
  }

  struct PlaybackStrategy {
    std::string id;
    bool enabled = true;
    int64_t startup_timeout_ms = 5000;
    int64_t stall_timeout_ms = 3000;
  };

  using PlaybackProfile = std::vector<PlaybackStrategy>;

  static bool playbackStrategyIdOk(const std::string& id) {
    return id == "h264_low_latency" || id == "h264_hls" || id == "mjpeg";
  }

  bool parsePlaybackProfile(cJSON* profile, PlaybackProfile* out, const std::string& source) {
    if (!cJSON_IsObject(profile)) return false;
    cJSON* strategies = json::get(profile, "strategies");
    if (!cJSON_IsArray(strategies) || cJSON_GetArraySize(strategies) < 1 ||
        cJSON_GetArraySize(strategies) > 3) return false;
    PlaybackProfile parsed;
    std::set<std::string> ids;
    bool any_enabled = false;
    cJSON* it = nullptr;
    cJSON_ArrayForEach(it, strategies) {
      if (!cJSON_IsObject(it)) return false;
      std::string id = json::getString(it, "id");
      cJSON* enabled = json::get(it, "enabled");
      cJSON* startup = json::get(it, "startup_timeout_ms");
      cJSON* stall = json::get(it, "stall_timeout_ms");
      if (!playbackStrategyIdOk(id) || ids.count(id) || !cJSON_IsBool(enabled) ||
          !cJSON_IsNumber(startup) || !cJSON_IsNumber(stall)) return false;
      PlaybackStrategy s;
      s.id = id;
      s.enabled = cJSON_IsTrue(enabled);
      s.startup_timeout_ms = static_cast<int64_t>(startup->valuedouble);
      s.stall_timeout_ms = static_cast<int64_t>(stall->valuedouble);
      if (s.startup_timeout_ms < 100 || s.startup_timeout_ms > 60000 ||
          s.stall_timeout_ms < 1000 || s.stall_timeout_ms > 60000) return false;
      parsed.push_back(s);
      ids.insert(id);
      any_enabled = any_enabled || s.enabled;
    }
    if (!any_enabled) return false;
    *out = std::move(parsed);
    (void)source;
    return true;
  }

  void warnInvalidPlayback(const std::string& source) {
    if (playback_invalid_logged.insert(source).second)
      DB_LOGW(kTag, "invalid video playback profile ignored: " + source);
  }

  static PlaybackProfile defaultPlaybackProfile() {
    // A newly attached fMP4 client may have to wait for the next IDR.  The
    // encoder's nominal GOP is one second, but device codecs may defer a
    // requested IDR for several seconds. A short deadline races a healthy
    // decoder and incorrectly falls back to MJPEG on slower clients (notably
    // iPad 1). This is only a failure deadline; the first decoded frame is
    // still displayed immediately.
    return {{"h264_low_latency", true, 5000, 3000},
            {"h264_hls", false, 5000, 5000},
            {"mjpeg", true, 5000, 3000}};
  }

  PlaybackProfile legacyPlaybackProfile(const std::string& viewer) {
    cJSON* video = cfgAt("devices." + viewer + ".local.video");
    std::string legacy = json::getString(video, "playback");
    if (legacy == "mjpeg") return {{"mjpeg", true, 5000, 3000}};
    if (legacy == "hls")
      return {{"h264_hls", true, 5000, 5000}, {"mjpeg", true, 5000, 3000}};
    if (legacy == "low_latency")
      return {{"h264_low_latency", true, 5000, 3000}, {"mjpeg", true, 5000, 3000}};
    return {};
  }

  PlaybackProfile resolvePlaybackProfile(const std::string& viewer,
                                          const std::string& source,
                                          std::string* resolved_from = nullptr) {
    PlaybackProfile profile;
    // Apply pair-specific overrides only when the Web page is hosted by an indoor panel.
    cJSON* viewer_dev = cfgAt("devices." + viewer);
    bool viewer_is_indoor = json::getString(viewer_dev, "role") == "indoor_panel";
    if (viewer_is_indoor && !source.empty()) {
      std::string path = "video_playback.pairs." + viewer + "." + source;
      cJSON* pair = cfgAt(path);
      if (pair) {
        if (parsePlaybackProfile(pair, &profile, path)) {
          if (resolved_from) *resolved_from = "pair";
          return profile;
        }
        warnInvalidPlayback(path);
      }
    }
    cJSON* global = cfgAt("video_playback.global");
    if (global) {
      if (parsePlaybackProfile(global, &profile, "video_playback.global")) {
        if (resolved_from) *resolved_from = "global";
        return profile;
      }
      warnInvalidPlayback("video_playback.global");
    }
    profile = legacyPlaybackProfile(viewer);
    if (!profile.empty()) {
      if (resolved_from) *resolved_from = "legacy";
      return profile;
    }
    if (resolved_from) *resolved_from = "default";
    return defaultPlaybackProfile();
  }

  json::Doc playbackProfileDoc(const std::string& viewer, const std::string& source) {
    std::string resolved_from;
    PlaybackProfile profile = resolvePlaybackProfile(viewer, source, &resolved_from);
    auto out = json::obj();
    json::set(out.get(), "resolved_from", resolved_from);
    cJSON* strategies = json::addArr(out.get(), "strategies");
    for (const auto& s : profile) {
      cJSON* e = json::pushObj(strategies);
      json::set(e, "id", s.id);
      json::setBool(e, "enabled", s.enabled);
      json::set(e, "startup_timeout_ms", s.startup_timeout_ms);
      json::set(e, "stall_timeout_ms", s.stall_timeout_ms);
    }
    return out;
  }


  struct CamCfg {
    int fps = 8;
    int quality = 60;
    int w = 640, h = 480;
    std::string hint;

    std::string codec = "auto";  // auto | mjpeg | h264
    int h264_w = 640, h264_h = 360;
    int h264_fps = 30;
    int h264_kbps = 700;
    bool h264Enabled() const { return codec != "mjpeg"; }
  };
  static void parseRes(const std::string& res, int* w, int* h) {
    size_t x = res.find('x');
    if (x == std::string::npos) return;
    int pw = std::atoi(res.c_str());
    int ph = std::atoi(res.c_str() + x + 1);
    if (pw > 0 && ph > 0) {
      *w = pw;
      *h = ph;
    }
  }
  CamCfg cameraCfg() {
    CamCfg c;
    cJSON* cam = cfgAt("devices." + node_id + ".local.camera");
    if (cam) {
      c.fps = static_cast<int>(json::getInt(cam, "mjpeg_fps", 8));
      c.quality = static_cast<int>(json::getInt(cam, "mjpeg_quality", 60));
      c.hint = json::getString(cam, "device_hint");
      parseRes(json::getString(cam, "resolution", "640x480"), &c.w, &c.h);
      c.codec = json::getString(cam, "codec", "auto");
      if (c.codec != "mjpeg" && c.codec != "h264") c.codec = "auto";
      parseRes(json::getString(cam, "h264_resolution", "640x360"), &c.h264_w, &c.h264_h);
      c.h264_fps = static_cast<int>(json::getInt(cam, "h264_fps", 30));
      c.h264_kbps = static_cast<int>(json::getInt(cam, "h264_bitrate_kbps", 700));
    }
    if (c.fps <= 0) c.fps = 8;
    if (c.h264_fps <= 0) c.h264_fps = 30;
    if (c.h264_kbps <= 0) c.h264_kbps = 700;
    return c;
  }

  static int normalizeRotation(int degrees) {
    int d = degrees % 360;
    if (d < 0) d += 360;
    return ((d + 45) / 90 * 90) % 360;
  }

  // Auto or absent follows the sensor; numeric cardinal values are administrator-fixed.
  void applyVideoRotation() {
    int rotation = sensor_video_rotation.load();
    cJSON* video = cfgAt("devices." + node_id + ".local.video");
    cJSON* forced = json::get(video, "rotation");
    if (cJSON_IsNumber(forced)) {
      rotation = normalizeRotation(forced->valueint);
    } else if (cJSON_IsString(forced) && forced->valuestring &&
               std::strcmp(forced->valuestring, "auto") != 0) {
      char* end = nullptr;
      long v = std::strtol(forced->valuestring, &end, 10);
      if (end && *end == '\0') rotation = normalizeRotation(static_cast<int>(v));
    }
    effective_video_rotation.store(rotation);
  }


  void applyCameraSettings() {
    CamCfg c = cameraCfg();
    frame_bus.setJpegParams(c.quality, c.w);
    if (httpd)
      httpd->setJpegProvider([this](int64_t* ts) { return frame_bus.latestJpeg(ts); }, c.fps);



    video_track.setEnabled(c.h264Enabled());
  }


  void applyMotionSettings() {
    cJSON* m = cfgAt("devices." + node_id + ".local.motion");
    MotionConfig mc;
    mc.enabled = json::getBool(m, "enabled", true);
    mc.sensitivity = static_cast<int>(json::getInt(m, "sensitivity", 40));
    mc.min_interval_s = static_cast<int>(json::getInt(m, "min_interval_s", 30));
    std::lock_guard<std::mutex> lk(motion_mu);
    motion.setConfig(mc);
  }





  std::string assetFilePath(const std::string& hash) { return assets_dir + "/" + hash; }

  bool assetCached(const std::string& hash) {
    return isSha256HexStr(hash) && fileExists(assetFilePath(hash));
  }


  //   display.theme.bg_image / devices.*.local.theme.bg_image /

  //   "asset:*" / emergency.alarm_sound "asset:*"
  std::set<std::string> referencedAssets() {
    std::set<std::string> out;
    auto addHash = [&out](const std::string& h) {
      if (isSha256HexStr(h)) out.insert(h);
    };
    addHash(json::getString(cfgAt("display.theme"), "bg_image"));
    cJSON* devices = json::get(cfg.get(), "devices");
    cJSON* dev = nullptr;
    cJSON_ArrayForEach(dev, devices) {
      addHash(json::getString(json::get(json::get(dev, "local"), "theme"), "bg_image"));
    }
    cJSON* qrs = json::get(cfg.get(), "quick_replies");
    cJSON* qr = nullptr;
    cJSON_ArrayForEach(qr, qrs) {
      cJSON* audio = json::get(qr, "audio");
      cJSON* a = nullptr;
      cJSON_ArrayForEach(a, audio) {
        if (cJSON_IsString(a)) addHash(a->valuestring);
      }
    }
    cJSON* ui = json::get(cfg.get(), "ui");
    addHash(assetRefHash(json::getString(ui, "ringtone")));
    addHash(assetRefHash(json::getString(ui, "launch_sound")));
    addHash(assetRefHash(json::getString(ui, "call_sound")));
    addHash(assetRefHash(json::getString(ui, "button_sound")));
    addHash(assetRefHash(json::getString(ui, "update_sound")));
    cJSON* rules_obj = json::get(cfg.get(), "trigger_rules");
    cJSON* rule = nullptr;
    cJSON_ArrayForEach(rule, rules_obj) {
      cJSON* action = nullptr;
      cJSON_ArrayForEach(action, json::get(rule, "actions")) {
        addHash(assetRefHash(json::getString(action, "sound")));
      }
    }
    addHash(assetRefHash(json::getString(json::get(cfg.get(), "emergency"), "alarm_sound")));
    return out;
  }


  void schedulePrefetch() {
    if (!started) return;
    if (asset_prefetch_timer) loop->cancel(asset_prefetch_timer);
    asset_prefetch_timer = loop->postDelayed(200, [this] {
      asset_prefetch_timer = 0;
      prefetchAssets();
    });
  }


  void prefetchAssets() {
    if (!mesh) return;
    std::set<std::string> refs = referencedAssets();

    std::set<std::string> keep = refs;
    cJSON* ledger = json::get(cfg.get(), "assets");
    cJSON* it = nullptr;
    cJSON_ArrayForEach(it, ledger) {
      if (it->string && isSha256HexStr(it->string)) keep.insert(it->string);
    }
    const int64_t now_mono = clock->monoMs();
    for (const std::string& name : listDir(assets_dir)) {
      if (!isSha256HexStr(name)) continue;
      if (keep.count(name)) {
        asset_unref_since.erase(name);
        continue;
      }
      auto u = asset_unref_since.find(name);
      if (u == asset_unref_since.end()) {
        asset_unref_since[name] = now_mono;
      } else if (now_mono - u->second >= kAssetGcGraceMs) {
        DB_LOGI(kTag, "asset GC: " + name.substr(0, 12) + "…");
        removeFile(assetFilePath(name));
        asset_unref_since.erase(u);
      }
    }

    for (const std::string& hash : refs) {
      if (assetCached(hash) || asset_fetching.count(hash)) continue;
      asset_fetching.insert(hash);
      std::weak_ptr<char> w = alive;
      mesh->fetchBlob(hash, [this, w, hash](Bytes data) {
        if (w.expired()) return;
        asset_fetching.erase(hash);
        if (data.empty()) return;
        if (sha256Hex(data) != hash) {
          DB_LOGW(kTag, "asset verification failed (hash mismatch): " +
                           hash.substr(0, 12) + "…");
          return;
        }
        if (!writeFileBytes(assetFilePath(hash), data)) {
          DB_LOGW(kTag, "failed to save asset: " + assetFilePath(hash));
          return;
        }
        DB_LOGI(kTag, "asset cached: " + hash.substr(0, 12) + "… (" +
                          std::to_string(data.size()) + "B)");
        auto o = json::obj();
        json::set(o.get(), "t", "asset_ready");
        json::set(o.get(), "hash", hash);
        uiNotify(json::dump(o.get()));

        evalDisplay();
      });
    }
  }


  std::string addAssetOnLoop(const Bytes& data, const std::string& type,
                             const std::string& label) {
    if (data.empty() || data.size() > kAssetMaxBytes || !assetTypeAllowed(type)) return "";
    const std::string hash = sha256Hex(data);
    const bool already_cached = fileExists(assetFilePath(hash));
    if (!already_cached && !writeFileBytes(assetFilePath(hash), data)) {
      DB_LOGE(kTag, "failed to save asset: " + assetFilePath(hash));
      return "";
    }
    auto o = json::obj();
    json::set(o.get(), "size", static_cast<int64_t>(data.size()));
    json::set(o.get(), "type", type);
    json::set(o.get(), "origin", node_id);
    if (!label.empty()) json::set(o.get(), "label", label);
    config->set("assets." + hash, json::dump(o.get()));
    if (!config->lastMutationCommitted()) {
      if (!already_cached) removeFile(assetFilePath(hash));
      return "";
    }
    return hash;
  }



  void notifyChime(const std::string& sound, const std::string& door) {
    auto o = json::obj();
    json::set(o.get(), "schema_version", static_cast<int64_t>(2));
    json::set(o.get(), "t", "chime");
    json::set(o.get(), "sound", sound);
    if (!door.empty()) json::set(o.get(), "door", door);
    auto call = active_calls.find(door);
    if (call != active_calls.end()) {
      json::set(o.get(), "call_id", call->second.call_id);
      json::set(o.get(), "stage_revision", static_cast<int64_t>(call->second.stage_revision));
      json::set(o.get(), "expires_at_ms", call->second.expires_wall_ms);
      if (!call->second.purpose.empty()) json::set(o.get(), "purpose", call->second.purpose);
      const std::string visitor_lang = visitorLangFor(door);
      if (!visitor_lang.empty()) json::set(o.get(), "visitor_lang", visitor_lang);
    }
    const std::string hash = assetRefHash(sound);
    if (!hash.empty() && assetCached(hash)) json::set(o.get(), "audio_path", assetFilePath(hash));
    uiNotify(json::dump(o.get()));
  }





  std::string visitorLangFor(const std::string& door) {
    auto it = visitor_lang_by_door.find(door);
    return it == visitor_lang_by_door.end() ? "ja" : it->second;
  }

  int visitorRevertS() {
    return static_cast<int>(json::getInt(json::get(cfg.get(), "ui"), "visitor_lang_revert_s", 60));
  }

  void doSetVisitorLang(const std::string& door_arg, const std::string& lang) {
    std::string door = door_arg;
    if (door.empty()) door = opts.door.empty() ? last_press_door : opts.door;
    if (door.empty() || lang.empty()) {
      DB_LOGW(kTag, "setVisitorLang requires both door and language");
      return;
    }
    if (visitorLangFor(door) == lang) return;
    auto p = json::obj();
    json::set(p.get(), "lang", lang);
    events->append("visitor_lang", door, node_id, json::dump(p.get()));
  }

  void cancelVisitorRevert(const std::string& door) {
    auto t = visitor_lang_revert_timer.find(door);
    if (t == visitor_lang_revert_timer.end()) return;
    loop->cancel(t->second);
    visitor_lang_revert_timer.erase(t);
  }


  void armVisitorRevert(const std::string& door) {
    cancelVisitorRevert(door);
    const int s = visitorRevertS();
    if (s <= 0) return;
    visitor_lang_revert_timer[door] =
        loop->postDelayed(static_cast<int64_t>(s) * 1000, [this, door] {
          visitor_lang_revert_timer.erase(door);
          if (visitor_lang_by_door.count(door)) doSetVisitorLang(door, "ja");
        });
  }


  void applyVisitorLangEvent(const EventRecord& ev, bool is_local) {
    auto p = json::parse(ev.payload_json.empty() ? "{}" : ev.payload_json);
    const std::string lang = p ? json::getString(p.get(), "lang") : "";
    if (ev.door.empty() || lang.empty()) return;
    if (lang == "ja") {
      visitor_lang_by_door.erase(ev.door);
      cancelVisitorRevert(ev.door);
    } else {
      visitor_lang_by_door[ev.door] = lang;
      cancelVisitorRevert(ev.door);
      if (is_local && ev.origin == node_id) armVisitorRevert(ev.door);
    }
    auto o = json::obj();
    json::set(o.get(), "t", "visitor_lang");
    json::set(o.get(), "door", ev.door);
    json::set(o.get(), "lang", lang);
    uiNotify(json::dump(o.get()));
  }







  struct DisplayState {
    int brightness = 70;
    bool night = false;
    bool red_tint = false;
    int screensaver_after_s = 120;
    int pixel_shift_s = 300;
    std::string bg_color = "#101418";
    std::string bg_image;
    // Light/dark appearance. configured is what an administrator chose; effective is what core
    // resolves from the schedule. follow_system is true for auto_system, where the shell uses
    // the operating system's own setting and falls back to effective when it has none (iOS 5
    // and Android before 10 have no system dark mode at all).
    std::string appearance_configured = "auto_system";
    std::string appearance_effective = "light";
    bool appearance_follow_system = true;
    std::string dark_from = "19:00";
    std::string light_from = "06:30";
  };

  // The dark window runs from dark_from to light_from in the configured time zone, so a
  // cluster in Tokyo and a shell that has just booted agree without either consulting the OS.
  std::string scheduledAppearance(const std::string& dark_from, const std::string& light_from) {
    const int dark = parseHhmm(dark_from);
    const int light = parseHhmm(light_from);
    if (dark < 0 || light < 0 || dark == light) return "light";
    const int64_t local =
        hlc->correctedWallMs() + static_cast<int64_t>(tzOffsetMin()) * 60'000LL;
    const int64_t day = floorDiv(local, 86'400'000LL);
    const int minute = static_cast<int>((local - day * 86'400'000LL) / 60'000LL);
    const bool is_dark = dark < light ? (minute >= dark && minute < light)
                                      : (minute >= dark || minute < light);
    return is_dark ? "dark" : "light";
  }

  // The colour the theme actually renders behind text: the average of the background image when
  // one is cached and decodable, otherwise the theme colour.
  struct ThemeAuto {
    std::string background = "#101418";
    // "image" when the background image was sampled, "color" only when no image is configured,
    // and "image_unsampled" when one is configured but core could not sample it. The last case
    // must never be reported as "color": a shell would then paint ink chosen for the flat theme
    // colour over a photograph that may be nothing like it.
    std::string source = "color";
    std::string reason;  // set only for image_unsampled
    std::string ink = "light";
    std::string call_button = "#7F5E3D";
    std::string call_button_ink = "light";
  };
  ThemeAuto theme_auto;
  std::string theme_auto_input;

  std::string themeBgColorOnLoop() {
    const cJSON* base = json::get(cfg.get(), "display");
    const cJSON* theme_base = json::get(base, "theme");
    const cJSON* theme_ovr = cfgAt("devices." + node_id + ".local.theme");
    std::string value = json::getString(theme_ovr, "bg_color");
    if (value.empty()) value = json::getString(theme_base, "bg_color");
    return value.empty() ? std::string("#101418") : value;
  }

  std::string themeBgImageOnLoop() {
    const cJSON* base = json::get(cfg.get(), "display");
    const cJSON* theme_base = json::get(base, "theme");
    const cJSON* theme_ovr = cfgAt("devices." + node_id + ".local.theme");
    const cJSON* override_image = json::get(theme_ovr, "bg_image");
    // Null is an explicit device-level "no image" choice. Only an absent leaf inherits the
    // cluster image; treating null as an empty string and then falling back made the Web choice
    // appear to save while the old background remained effective.
    std::string hash = override_image ? json::getString(theme_ovr, "bg_image")
                                      : json::getString(theme_base, "bg_image");
    return isSha256HexStr(hash) ? hash : "";
  }

  // Recomputed only when the effective background changes; decoding an image on every status
  // poll would be pointless work on the oldest hardware in the fleet.
  const ThemeAuto& themeAutoState() {
    const std::string bg_color = themeBgColorOnLoop();
    const std::string bg_image = themeBgImageOnLoop();
    const std::string input = bg_color + "|" + bg_image;
    if (input == theme_auto_input) return theme_auto;
    theme_auto_input = input;
    ThemeAuto next;
    color::Rgb background;
    bool have_background = false;
    if (!bg_image.empty()) {
      // An image is configured, so the answer is about that image whether or not it sampled.
      const color::SampleStatus status =
          assetCached(bg_image) ? color::averageImageColor(assetFilePath(bg_image), &background)
                                : color::SampleStatus::kMissing;
      if (status == color::SampleStatus::kOk) {
        next.source = "image";
        have_background = true;
      } else {
        next.source = "image_unsampled";
        next.reason = color::sampleStatusName(status);
        DB_LOGW(kTag, "background image " + bg_image.substr(0, 8) + " not sampled (" +
                          next.reason + "); shells must sample it locally");
      }
    }
    if (!have_background && color::parseHex(bg_color, &background)) have_background = true;
    if (!have_background) color::parseHex("#101418", &background);
    next.background = color::formatHex(background);
    next.ink = color::autoInk(background);
    const color::Rgb white{255, 255, 255};
    const color::Rgb button = color::autoAccent(background, white);
    next.call_button = color::formatHex(button);
    next.call_button_ink = color::accentInk(button);
    theme_auto = next;
    return theme_auto;
  }

  std::string effectiveThemeBackground() { return themeAutoState().background; }

  DisplayState displayState() {
    cJSON* base = json::get(cfg.get(), "display");
    cJSON* ovr = cfgAt("devices." + node_id + ".local.display");
    auto num = [&](const char* key, int64_t def) {
      if (ovr && json::get(ovr, key)) return json::getInt(ovr, key, def);
      return json::getInt(base, key, def);
    };
    DisplayState d;
    d.brightness = static_cast<int>(num("brightness", 70));
    d.screensaver_after_s = static_cast<int>(num("screensaver_after_s", 120));
    d.pixel_shift_s = static_cast<int>(num("pixel_shift_s", 300));
    {
      cJSON* tbase = json::get(base, "theme");
      cJSON* tovr = cfgAt("devices." + node_id + ".local.theme");
      auto str = [&](const char* key) {
        if (tovr && json::get(tovr, key)) return json::getString(tovr, key);
        return json::getString(tbase, key);
      };
      const std::string c = str("bg_color");
      if (!c.empty()) d.bg_color = c;
      d.bg_image = str("bg_image");
      if (!isSha256HexStr(d.bg_image)) d.bg_image.clear();
    }
    {
      // A per-device appearance wins over the cluster default, exactly like brightness.
      const cJSON* configured = ovr ? json::get(ovr, "appearance") : nullptr;
      if (!cJSON_IsString(configured)) configured = json::get(base, "appearance");
      if (cJSON_IsString(configured)) d.appearance_configured = configured->valuestring;
      const cJSON* schedule = ovr ? json::get(ovr, "appearance_schedule") : nullptr;
      if (!cJSON_IsObject(schedule)) schedule = json::get(base, "appearance_schedule");
      d.dark_from = json::getString(schedule, "dark_from", d.dark_from);
      d.light_from = json::getString(schedule, "light_from", d.light_from);
      d.appearance_follow_system = d.appearance_configured == "auto_system";
      if (d.appearance_configured == "light" || d.appearance_configured == "dark") {
        d.appearance_effective = d.appearance_configured;
        d.appearance_follow_system = false;
      } else {
        d.appearance_effective = scheduledAppearance(d.dark_from, d.light_from);
      }
    }
    cJSON* night = ovr ? json::get(ovr, "night") : nullptr;
    if (!night) night = json::get(base, "night");
    if (night && json::getBool(night, "enabled", true)) {
      const int from = parseHhmm(json::getString(night, "from", "22:00"));
      const int to = parseHhmm(json::getString(night, "to", "06:00"));
      if (from >= 0 && to >= 0 && from != to) {
        const int64_t local =
            hlc->correctedWallMs() + static_cast<int64_t>(tzOffsetMin()) * 60'000LL;
        const int64_t day = floorDiv(local, 86'400'000LL);
        const int minute = static_cast<int>((local - day * 86'400'000LL) / 60'000LL);
        d.night = (from < to) ? (from <= minute && minute < to)
                              : (minute >= from || minute < to);
      }
      if (d.night) {
        d.brightness = static_cast<int>(json::getInt(night, "brightness", 15));
        d.red_tint = json::getBool(night, "red_tint", true);
      }
    }
    return d;
  }




  json::Doc displayDoc(const DisplayState& d) {
    auto o = json::obj();
    json::set(o.get(), "brightness", static_cast<int64_t>(d.brightness));
    json::setBool(o.get(), "night", d.night);
    json::setBool(o.get(), "red_tint", d.red_tint);
    json::set(o.get(), "screensaver_after_s", static_cast<int64_t>(d.screensaver_after_s));
    json::set(o.get(), "pixel_shift_s", static_cast<int64_t>(d.pixel_shift_s));
    {
      cJSON* appearance = json::addObj(o.get(), "appearance");
      json::set(appearance, "configured", d.appearance_configured);
      json::set(appearance, "effective", d.appearance_effective);
      json::setBool(appearance, "follow_system", d.appearance_follow_system);
      cJSON* schedule = json::addObj(appearance, "schedule");
      json::set(schedule, "dark_from", d.dark_from);
      json::set(schedule, "light_from", d.light_from);
    }
    cJSON* theme = json::addObj(o.get(), "theme");
    json::set(theme, "bg_color", d.bg_color);
    if (!d.bg_image.empty()) {
      json::set(theme, "bg_image", d.bg_image);
      if (assetCached(d.bg_image)) {
        json::set(theme, "bg_image_path", assetFilePath(d.bg_image));
      } else {
        json::setItem(theme, "bg_image_path", json::Doc(cJSON_CreateNull()));
      }
    } else {
      json::setItem(theme, "bg_image", json::Doc(cJSON_CreateNull()));
      json::setItem(theme, "bg_image_path", json::Doc(cJSON_CreateNull()));
    }
    themeAutoDoc(theme);
    return o;
  }

  // The semi-transparent layer a shell composites between the background image and everything
  // drawn on top of it. It is on by default because a bright photograph makes light text
  // unreadable, but which colour, how strong, and whether it is drawn at all belong to the
  // administrator -- and to one device when a single panel sits in a brighter room than the
  // rest. Each leaf resolves on its own, so a device can darken further without restating the
  // colour; source names the strongest origin among the three.
  json::Doc backdropDoc() {
    const cJSON* cluster = json::get(json::get(json::get(cfg.get(), "display"), "theme"),
                                     "backdrop");
    const cJSON* device = json::get(cfgAt("devices." + node_id + ".local.theme"), "backdrop");
    bool from_device = false;
    bool from_admin = false;
    auto leaf = [&](const char* name) -> const cJSON* {
      const cJSON* value = json::get(device, name);
      if (value && !cJSON_IsNull(value)) {
        from_device = true;
        return value;
      }
      value = json::get(cluster, name);
      if (value && !cJSON_IsNull(value)) {
        from_admin = true;
        return value;
      }
      return nullptr;
    };
    bool enabled = true;
    if (const cJSON* value = leaf("enabled")) {
      if (cJSON_IsBool(value)) enabled = cJSON_IsTrue(value);
    }
    std::string color = "#000000";
    if (const cJSON* value = leaf("color")) {
      color::Rgb parsed;
      if (cJSON_IsString(value) && color::parseHex(value->valuestring, &parsed))
        color = color::formatHex(parsed);
    }
    int64_t opacity = 62;
    if (const cJSON* value = leaf("opacity")) {
      if (wholeNumberInRange(value, 0, 100)) opacity = static_cast<int64_t>(value->valuedouble);
    }
    auto out = json::obj();
    json::setBool(out.get(), "enabled", enabled);
    json::set(out.get(), "color", color);
    json::set(out.get(), "opacity", opacity);
    json::set(out.get(), "source", from_device ? "device" : (from_admin ? "admin" : "default"));
    return out;
  }

  json::Doc glassDoc() {
    const cJSON* cluster = json::get(json::get(json::get(cfg.get(), "display"), "theme"),
                                     "glass");
    const cJSON* device = json::get(cfgAt("devices." + node_id + ".local.theme"), "glass");
    const cJSON* value = json::get(device, "blur_radius");
    std::string source = "device";
    if (!value || cJSON_IsNull(value)) {
      value = json::get(cluster, "blur_radius");
      source = "admin";
    }
    int64_t radius = 32;
    if (value && !cJSON_IsNull(value) && wholeNumberInRange(value, 0, 40)) {
      radius = static_cast<int64_t>(value->valuedouble);
    } else {
      source = "default";
    }
    auto out = json::obj();
    json::set(out.get(), "blur_radius", radius);
    json::set(out.get(), "source", source);
    return out;
  }

  // Automatic contrast, published once by core so every shell in the cluster draws the same ink
  // and the same call button instead of each deriving its own from the same background.
  void themeAutoDoc(cJSON* theme) {
    const ThemeAuto& automatic = themeAutoState();
    cJSON* background = json::addObj(theme, "auto_background");
    json::set(background, "color", automatic.background);
    json::set(background, "source", automatic.source);
    // Present only when an image is configured but was not sampled, so a shell can fall back to
    // sampling it itself instead of trusting ink derived from the flat colour.
    if (!automatic.reason.empty()) json::set(background, "reason", automatic.reason);

    const cJSON* theme_base = json::get(json::get(cfg.get(), "display"), "theme");
    const cJSON* theme_ovr = cfgAt("devices." + node_id + ".local.theme");
    auto override_for = [&](const char* field) -> const cJSON* {
      const cJSON* value = json::get(theme_ovr, field);
      if (value && !cJSON_IsNull(value)) return value;
      value = json::get(theme_base, field);
      return (value && !cJSON_IsNull(value)) ? value : nullptr;
    };

    cJSON* auto_ink = json::addObj(theme, "auto_ink");
    for (const char* region : kInkRegions) json::set(auto_ink, region, automatic.ink);

    cJSON* accent = json::addObj(theme, "auto_accent");
    json::set(accent, "call_button", automatic.call_button);
    json::set(accent, "call_button_ink", automatic.call_button_ink);

    // The overrides an administrator set, and the values a shell should actually paint.
    cJSON* ink_override = json::addObj(theme, "ink_override");
    const cJSON* configured_ink = override_for("ink_override");
    const cJSON* item = nullptr;
    cJSON_ArrayForEach(item, configured_ink) {
      if (item->string && cJSON_IsString(item) && inkRegionKnown(item->string))
        json::set(ink_override, item->string, item->valuestring);
    }
    const cJSON* configured_button = override_for("call_button_bg");
    std::string effective_button = automatic.call_button;
    std::string effective_button_ink = automatic.call_button_ink;
    color::Rgb parsed;
    if (cJSON_IsString(configured_button) && color::parseHex(configured_button->valuestring,
                                                             &parsed)) {
      effective_button = color::formatHex(parsed);
      effective_button_ink = color::accentInk(parsed);
    }
    json::set(theme, "call_button_bg", effective_button);
    json::set(theme, "call_button_ink", effective_button_ink);
    json::setItem(theme, "backdrop", backdropDoc());
    json::setItem(theme, "glass", glassDoc());
  }


  void evalDisplay(bool force = false) {
    auto o = displayDoc(displayState());
    json::set(o.get(), "t", "display");
    std::string j = json::dump(o.get());
    if (!force && j == last_display_json) return;
    last_display_json = j;
    uiNotify(j);
  }

  // SOS state is the newest emergency/emergency_cancel HLC. State replication is unconditional;
  // local presentation, Web Push, and external integrations remain rule-driven.
  bool deviceAlertTargetsSelf(const cJSON* params) const {
    const cJSON* explicit_targets = json::get(params, "targets");
    const bool has_targets_object = cJSON_IsObject(explicit_targets);
    const cJSON* targets = has_targets_object ? explicit_targets : params;
    const cJSON* devices = json::get(targets, "devices");
    const cJSON* roles = json::get(targets, "roles");
    const bool has_selector = devices || roles;
    // Legacy actions with no targets object retain all-node delivery. Once an explicit targets
    // object exists, Web subscription groups alone must not implicitly address native shells.
    if (!has_selector) return !has_targets_object;
    auto matches = [](const cJSON* value, const std::string& candidate) {
      if (cJSON_IsString(value))
        return std::string(value->valuestring) == "all" || candidate == value->valuestring;
      if (!cJSON_IsArray(value)) return false;
      const cJSON* it = nullptr;
      cJSON_ArrayForEach(it, value) {
        if (cJSON_IsString(it) &&
            (std::string(it->valuestring) == "all" || candidate == it->valuestring))
          return true;
      }
      return false;
    };
    return matches(devices, node_id) || matches(roles, opts.role);
  }

  static bool alertUsesLocalChannel(const cJSON* params) {
    const cJSON* channels = json::get(params, "channels");
    if (!cJSON_IsArray(channels)) return true;
    const cJSON* it = nullptr;
    cJSON_ArrayForEach(it, channels) {
      if (!cJSON_IsString(it)) continue;
      const std::string channel = it->valuestring;
      if (channel == "in_app" || channel == "system_notification") return true;
    }
    return false;
  }

  static bool alertUsesInApp(const cJSON* params) {
    const cJSON* channels = json::get(params, "channels");
    if (!cJSON_IsArray(channels)) return true;
    const cJSON* channel = nullptr;
    cJSON_ArrayForEach(channel, channels) {
      if (cJSON_IsString(channel) && std::string(channel->valuestring) == "in_app") return true;
    }
    return false;
  }

  static bool alertUsesWebPush(const cJSON* params) {
    const cJSON* channels = json::get(params, "channels");
    if (!cJSON_IsArray(channels)) return false;
    const cJSON* channel = nullptr;
    cJSON_ArrayForEach(channel, channels) {
      if (cJSON_IsString(channel) && std::string(channel->valuestring) == "web_push") return true;
    }
    return false;
  }

  static bool webPushGroupSelected(const cJSON* params, const std::string& group) {
    const cJSON* explicit_targets = json::get(params, "targets");
    const bool has_targets_object = cJSON_IsObject(explicit_targets);
    const cJSON* targets = has_targets_object ? explicit_targets : params;
    const cJSON* groups = json::get(targets, "web_subscription_groups");
    if (!groups) groups = json::get(targets, "web_profiles");
    // A legacy action without a targets object reaches every Web subscription. Once a targets
    // object exists, Web delivery is opt-in and native-only selectors cannot leak to browsers.
    if (!groups) return !has_targets_object;
    if (cJSON_IsString(groups))
      return std::string(groups->valuestring) == "all" || group == groups->valuestring;
    if (!cJSON_IsArray(groups)) return false;
    const cJSON* item = nullptr;
    cJSON_ArrayForEach(item, groups) {
      if (cJSON_IsString(item) &&
          (std::string(item->valuestring) == "all" || group == item->valuestring))
        return true;
    }
    return false;
  }

  static const cJSON* webPushGroupSelectors(const cJSON* params) {
    const cJSON* explicit_targets = json::get(params, "targets");
    const cJSON* targets = cJSON_IsObject(explicit_targets) ? explicit_targets : params;
    const cJSON* groups = json::get(targets, "web_subscription_groups");
    return groups ? groups : json::get(targets, "web_profiles");
  }

  static bool deviceAlertTargetsWebGroup(const cJSON* params, const std::string& group) {
    const cJSON* explicit_targets = json::get(params, "targets");
    const bool has_targets_object = cJSON_IsObject(explicit_targets);
    const cJSON* targets = has_targets_object ? explicit_targets : params;
    const cJSON* groups = json::get(targets, "web_subscription_groups");
    if (!groups) groups = json::get(targets, "web_profiles");
    if (groups) return webPushGroupSelected(params, group);
    if (has_targets_object) return false;
    // Device and role selectors address native shells, not an active browser page.
    return !json::get(targets, "devices") && !json::get(targets, "roles");
  }

  json::Doc webAlertPresentation(const cJSON* params, bool active) const {
    const cJSON* configured = json::get(params, "presentation");
    const cJSON* emergency = json::get(cfg.get(), "emergency");
    auto out = json::obj();
    json::setBool(out.get(), "visual", json::getBool(configured, "visual", true));
    json::setBool(out.get(), "sticky", json::getBool(configured, "sticky", active));
    json::set(out.get(), "ttl_s", json::getInt(configured, "ttl_s", active ? 0 : 10));
    const std::string sound = active
        ? json::getString(configured, "sound",
                          json::getString(emergency, "alarm_sound", "siren1"))
        : json::getString(configured, "sound");
    if (!sound.empty()) json::set(out.get(), "sound", sound);
    json::set(out.get(), "volume",
              json::getInt(configured, "volume", json::getInt(emergency, "alarm_volume", 100)));
    const EmergencyPalette palette = safeEmergencyPalette(configured);
    json::set(out.get(), "background", palette.background);
    json::set(out.get(), "foreground", palette.foreground);
    json::set(out.get(), "accent", palette.accent);
    return out;
  }

  static std::string eventIdentity(const EventRecord& event) {
    return event.origin + ":" + std::to_string(event.seq);
  }

  // ---------- call history ----------

  // Anti-entropy hands a joining node the cluster's whole history at once. Applying those
  // records to the call log is the point; re-enacting them is not. A call event presents only
  // while its call is live right now, so a panel that has just joined imports the log silently
  // instead of ringing once for every call the house has ever taken.
  bool callEventIsLive(const EventRecord& ev) {
    if (!callLifecycleType(ev.type)) return true;
    const int64_t now = hlc->correctedWallMs();
    const std::string id = eventCallId(ev);
    if (ev.type == "press" || ev.type == "purpose_selected") {
      auto projection = store.callProjection(id);
      // Still ringing on the door station, and inside the ring window the press itself declared.
      if (!projection || projection->state != "ringing") return false;
      auto payload = json::parse(ev.payload_json.empty() ? "{}" : ev.payload_json);
      const int64_t expires =
          payload ? json::getInt(payload.get(), "expires_at_ms", 0) : 0;
      if (expires > 0) return now < expires;
      return now - ev.wall_ms <= callTtlMs();
    }
    // A terminal event matters while it closes a call this device is actually showing, and
    // otherwise only while it is recent enough for a missed-call alert to still mean anything.
    auto active = active_calls.find(ev.door);
    if (!id.empty() && active != active_calls.end() && active->second.call_id == id) return true;
    return now - ev.wall_ms <= callTtlMs();
  }

  static bool callLifecycleType(const std::string& type) {
    return type == "press" || type == "purpose_selected" || type == "call_answered" ||
           type == "call_ended" || type == "call_cancelled" || type == "reply";
  }

  // A missed call is the cancellation of a call nobody answered: the ring timeout, or a restart
  // recovery that never completed. It mirrors RuleEngine's virtual "call_missed" trigger.
  static bool missedCallEvent(const EventRecord& ev) {
    if (ev.type != "call_cancelled") return false;
    auto p = json::parse(ev.payload_json.empty() ? "{}" : ev.payload_json);
    const std::string reason = p ? json::getString(p.get(), "reason") : "";
    return reason == "timeout" || reason.rfind("recovery_", 0) == 0;
  }

  json::Doc callLogRowJson(const Store::CallLogRow& row) const {
    auto o = json::obj();
    json::set(o.get(), "id", row.id);
    json::set(o.get(), "call_id", row.call_id);
    json::set(o.get(), "ts", row.ts);
    json::set(o.get(), "door", row.door);
    json::set(o.get(), "purpose", row.purpose);
    json::set(o.get(), "visitor_lang", row.visitor_lang);
    json::set(o.get(), "outcome", row.outcome);
    json::set(o.get(), "answered_by", row.answered_by);
    json::set(o.get(), "duration_ms", row.duration_ms);
    json::set(o.get(), "snapshot", row.snapshot);
    json::set(o.get(), "hlc", row.updated_hlc);
    json::setBool(o.get(), "seen", row.seen);
    return o;
  }

  std::string callLogJson(const Store::CallLogQuery& query) {
    auto o = json::obj();
    cJSON* rows = json::addArr(o.get(), "rows");
    for (const auto& row : store.callLog(query)) json::push(rows, callLogRowJson(row));
    json::set(o.get(), "unread_missed", static_cast<int64_t>(store.unreadMissedCount()));
    json::set(o.get(), "seen_hlc", store.callLogSeenHlc());
    json::set(o.get(), "server_ts", hlc->correctedWallMs());
    return json::dump(o.get());
  }

  // Delivered after every call-lifecycle event and after the watermark moves, so an open history
  // screen and an idle badge stay live without polling.
  void notifyCallLogChanged() {
    auto o = json::obj();
    json::set(o.get(), "t", "call_log_changed");
    json::set(o.get(), "unread_missed", static_cast<int64_t>(store.unreadMissedCount()));
    uiNotify(json::dump(o.get()));
  }

  bool markCallLogSeen(const std::string& up_to_hlc) {
    if (!store.callLogMarkSeen(up_to_hlc)) return false;
    notifyCallLogChanged();
    return true;
  }

  int eventRetentionDays() const {
    const int64_t days = json::getInt(json::get(cfg.get(), "events"), "retention_days", 90);
    return static_cast<int>(std::max<int64_t>(1, std::min<int64_t>(days, 3650)));
  }

  // Retention runs against whatever replicated coverage the store has recorded. Without a
  // coverage snapshot the store still refuses to delete anything, so this tick is a no-op.
  void pruneEventsTick() {
    const int64_t cutoff =
        hlc->correctedWallMs() - static_cast<int64_t>(eventRetentionDays()) * 86'400'000LL;
    if (cutoff <= 0) return;
    store.pruneEvents(kEventRetentionPerOrigin, cutoff);
  }

  bool isCurrentEmergencyWinner(const EventRecord& event) {
    auto winner = store.latestEventOfTypes("emergency", "emergency_cancel");
    return winner && winner->origin == event.origin && winner->seq == event.seq &&
        winner->type == event.type && winner->hlc == event.hlc;
  }

  json::Doc panelDeviceAlert(const std::string& group) {
    auto source = store.latestEventOfTypes("emergency", "emergency_cancel");
    if (!source) return json::Doc(cJSON_CreateNull());
    for (const auto& action : rules.evaluate(*source, hlc->correctedWallMs(), tzOffsetMin())) {
      if (action.type != "device_alert") continue;
      auto params = json::parse(action.params_json.empty() ? "{}" : action.params_json);
      // A matching Web Push rule remains an explicit Web presentation request even when the
      // administrator disables raw active-page SOS handling. Project it into panel state so a
      // subsequent poll cannot erase the Push overlay before its own TTL or clear event.
      if (!params || (!alertUsesInApp(params.get()) && !alertUsesWebPush(params.get())) ||
          !deviceAlertTargetsWebGroup(params.get(), group))
        continue;
      auto alert = json::obj();
      json::set(alert.get(), "schema_version", static_cast<int64_t>(2));
      json::setBool(alert.get(), "active", source->type == "emergency");
      json::set(alert.get(), "event_id", eventIdentity(*source));
      json::set(alert.get(), "origin", source->origin);
      json::set(alert.get(), "seq", static_cast<int64_t>(source->seq));
      json::set(alert.get(), "event_hlc", source->hlc);
      json::set(alert.get(), "device", source->device);
      json::set(alert.get(), "wall_ms", source->wall_ms);
      if (const cJSON* channels = json::get(params.get(), "channels"))
        json::setItem(alert.get(), "channels", json::Doc(cJSON_Duplicate(channels, 1)));
      json::setItem(alert.get(), "presentation",
                    webAlertPresentation(params.get(), source->type == "emergency"));
      return alert;
    }
    return json::Doc(cJSON_CreateNull());
  }

  void recordWebPushDelivery(const EventRecord& source, int requested,
                             const std::string& result, int http_status = 0,
                             const cJSON* results = nullptr) {
    auto payload = json::obj();
    json::set(payload.get(), "schema_version", static_cast<int64_t>(1));
    json::set(payload.get(), "source_event_id", eventIdentity(source));
    json::set(payload.get(), "source_event_origin", source.origin);
    json::set(payload.get(), "source_event_seq", static_cast<int64_t>(source.seq));
    json::set(payload.get(), "source_event_hlc", source.hlc);
    json::set(payload.get(), "channel", "web_push");
    json::set(payload.get(), "requested", static_cast<int64_t>(requested));
    json::set(payload.get(), "result", result);
    if (http_status) json::set(payload.get(), "http_status", static_cast<int64_t>(http_status));
    if (cJSON_IsArray(results)) {
      cJSON* sanitized = json::addArr(payload.get(), "subscriptions");
      const cJSON* item = nullptr;
      cJSON_ArrayForEach(item, results) {
        const std::string endpoint = json::getString(item, "endpoint");
        if (endpoint.empty()) continue;
        cJSON* out = json::pushObj(sanitized);
        json::set(out, "subscription_id", webPushSubscriptionKey(endpoint));
        json::set(out, "status", json::getString(item, "status", "unknown"));
        if (json::get(item, "http_status"))
          json::set(out, "http_status", json::getInt(item, "http_status"));
      }
    }
    events->append("delivery_result", source.door, node_id, json::dump(payload.get()));
  }

  void deliverWebPush(const EventRecord& ev, const cJSON* params) {
    if (!alertUsesWebPush(params) || !mesh || !mesh->isLeader("web_push")) return;
    auto all = webPushSubscriptions();
    auto recipients = json::arr();
    const cJSON* record = nullptr;
    cJSON_ArrayForEach(record, all.get()) {
      if (!webPushGroupSelected(params, json::getString(record, "group", "all"))) continue;
      json::push(recipients.get(), json::Doc(cJSON_Duplicate(record, 1)));
    }
    const int count = cJSON_GetArraySize(recipients.get());
    if (count == 0) {
      recordWebPushDelivery(ev, 0, "no_recipients");
      return;
    }
    cJSON* push_cfg = cfgAt("integrations.web_push");
    const std::string sender_url = json::getString(push_cfg, "sender_url");
    const std::string private_key =
        secretValue(json::getString(push_cfg, "vapid_private_key_ref"));
    const std::string sender_ref = json::getString(push_cfg, "sender_secret_ref");
    const std::string sender_token = secretValue(sender_ref);
    if (!webPushConfigSyntaxValid(push_cfg) || private_key.empty() ||
        (!sender_ref.empty() && sender_token.empty())) {
      recordWebPushDelivery(ev, count, "backend_unavailable");
      return;
    }
    auto request = json::obj();
    json::set(request.get(), "schema_version", static_cast<int64_t>(1));
    cJSON* vapid = json::addObj(request.get(), "vapid");
    json::set(vapid, "public_key", json::getString(push_cfg, "vapid_public_key"));
    json::set(vapid, "private_key", private_key);
    json::set(vapid, "subject", json::getString(push_cfg, "vapid_subject"));
    json::setItem(request.get(), "subscriptions", std::move(recipients));
    cJSON* payload = json::addObj(request.get(), "payload");
    const bool missed = missedCallEvent(ev);
    const bool active = !missed && ev.type == "emergency";
    std::string push_lang =
        json::getString(cfgAt("devices." + node_id + ".local"), "ui_lang", "ja");
    if (push_lang != "ja" && push_lang != "en" && push_lang != "zh") push_lang = "ja";
    if (missed) {
      const std::string unread = std::to_string(store.unreadMissedCount());
      json::set(payload, "kind", "call_missed");
      json::set(payload, "title", textOnLoop("history.outcome_missed", push_lang, {}));
      json::set(payload, "body",
                textOnLoop("history.unread_banner", push_lang, {{"n", unread}}));
      json::set(payload, "tag", "doorbell-call-missed");
      json::set(payload, "unread_missed", static_cast<int64_t>(store.unreadMissedCount()));
    } else {
      json::set(payload, "kind", active ? "emergency" : "emergency_cancel");
      json::set(payload, "title", textOnLoop(active ? "emergency.title" : "emergency.notify_off",
                                              push_lang, {}));
      json::set(payload, "body",
                textOnLoop(active ? "emergency.active_detail" : "emergency.notify_off",
                           push_lang, {}));
      json::set(payload, "tag", "doorbell-emergency");
    }
    json::set(payload, "url", "/panel/monitor");
    json::setBool(payload, "active", active);
    json::set(payload, "event_id", eventIdentity(ev));
    json::set(payload, "origin", ev.origin);
    json::set(payload, "seq", static_cast<int64_t>(ev.seq));
    json::set(payload, "event_hlc", ev.hlc);
    json::set(payload, "device", ev.device);
    json::set(payload, "wall_ms", ev.wall_ms);
    if (const cJSON* groups = webPushGroupSelectors(params))
      json::setItem(payload, "web_subscription_groups",
                    json::Doc(cJSON_Duplicate(groups, 1)));
    json::setItem(payload, "presentation", webAlertPresentation(params, active));
    auto header_doc = json::obj();
    json::set(header_doc.get(), "Content-Type", "application/json");
    if (!sender_token.empty())
      json::set(header_doc.get(), "Authorization", "Bearer " + sender_token);
    const std::string headers = json::dump(header_doc.get());
    const Bytes body = toBytes(json::dump(request.get()));
    const std::string source_origin = ev.origin;
    const uint64_t source_seq = ev.seq;
    const std::string source_hlc = ev.hlc;
    const std::string source_door = ev.door;
    const std::string source_device = ev.device;
    httpsCall("POST", sender_url, headers, body,
              [this, source_origin, source_seq, source_hlc, source_door, source_device, count](
                  int status, const std::string& response) {
      EventRecord source;
      source.origin = source_origin;
      source.seq = source_seq;
      source.hlc = source_hlc;
      source.door = source_door;
      source.device = source_device;
      auto response_json = json::parse(response);
      recordWebPushDelivery(source, count,
                            status >= 200 && status < 300 ? "accepted" : "failed", status,
                            response_json ? json::get(response_json.get(), "results") : nullptr);
    });
  }

  // In-app / system-notification delivery for a missed call. The alert carries the badge count so
  // a shell can render the idle-screen badge without querying the history first.
  void missedCallNotifyUi(const EventRecord& ev, const cJSON* params) {
    if (!deviceAlertTargetsSelf(params) || !alertUsesLocalChannel(params)) return;
    auto payload = json::parse(ev.payload_json.empty() ? "{}" : ev.payload_json);
    auto o = json::obj();
    json::set(o.get(), "schema_version", static_cast<int64_t>(2));
    json::set(o.get(), "t", "device_alert");
    json::set(o.get(), "kind", "call_missed");
    json::set(o.get(), "event_id", eventIdentity(ev));
    json::set(o.get(), "origin", ev.origin);
    json::set(o.get(), "seq", static_cast<int64_t>(ev.seq));
    json::set(o.get(), "event_hlc", ev.hlc);
    json::set(o.get(), "door", ev.door);
    json::set(o.get(), "wall_ms", ev.wall_ms);
    if (payload) {
      const std::string call_id = json::getString(payload.get(), "call_id");
      const std::string reason = json::getString(payload.get(), "reason");
      if (!call_id.empty()) json::set(o.get(), "call_id", call_id);
      if (!reason.empty()) json::set(o.get(), "reason", reason);
    }
    json::set(o.get(), "unread_missed", static_cast<int64_t>(store.unreadMissedCount()));
    const cJSON* presentation = json::get(params, "presentation");
    json::setBool(o.get(), "visual", json::getBool(presentation, "visual", true));
    json::setBool(o.get(), "sticky", json::getBool(presentation, "sticky", false));
    json::set(o.get(), "ttl_s", json::getInt(presentation, "ttl_s", 30));
    const std::string sound = json::getString(presentation, "sound");
    if (!sound.empty()) {
      json::set(o.get(), "sound", sound);
      const std::string hash = assetRefHash(sound);
      if (!hash.empty() && assetCached(hash))
        json::set(o.get(), "audio_path", assetFilePath(hash));
    }
    if (cJSON* channels = json::get(params, "channels"))
      json::setItem(o.get(), "channels", json::Doc(cJSON_Duplicate(channels, 1)));
    const bool dispatched = uiNotify(json::dump(o.get()));
    auto delivery = json::obj();
    json::set(delivery.get(), "schema_version", static_cast<int64_t>(1));
    json::set(delivery.get(), "source_event_id", eventIdentity(ev));
    json::set(delivery.get(), "source_event_origin", ev.origin);
    json::set(delivery.get(), "source_event_seq", static_cast<int64_t>(ev.seq));
    json::set(delivery.get(), "source_event_hlc", ev.hlc);
    json::set(delivery.get(), "channel", "local_shell");
    json::set(delivery.get(), "kind", "call_missed");
    json::set(delivery.get(), "device_id", node_id);
    json::set(delivery.get(), "role", opts.role);
    json::set(delivery.get(), "result", dispatched ? "dispatched" : "shell_unavailable");
    if (cJSON* channels = json::get(params, "channels"))
      json::setItem(delivery.get(), "requested_channels",
                    json::Doc(cJSON_Duplicate(channels, 1)));
    events->append("delivery_result", ev.door, node_id, json::dump(delivery.get()));
  }

  void emergencyNotifyUi(const EventRecord& ev, const cJSON* params) {
    if (!deviceAlertTargetsSelf(params) || !alertUsesLocalChannel(params)) return;
    const bool active = ev.type == "emergency";
    auto o = json::obj();
    json::set(o.get(), "schema_version", static_cast<int64_t>(2));
    json::set(o.get(), "t", "emergency");
    json::setBool(o.get(), "active", active);
    json::set(o.get(), "event_id", eventIdentity(ev));
    json::set(o.get(), "origin", ev.origin);
    json::set(o.get(), "seq", static_cast<int64_t>(ev.seq));
    json::set(o.get(), "event_hlc", ev.hlc);
    auto payload = json::parse(ev.payload_json.empty() ? "{}" : ev.payload_json);
    if (payload) json::set(o.get(), "source", json::getString(payload.get(), "source", ev.device));
    cJSON* em = json::get(cfg.get(), "emergency");
    const cJSON* presentation = json::get(params, "presentation");
    const std::string sound = active
        ? json::getString(presentation, "sound", json::getString(em, "alarm_sound", "siren1"))
        : json::getString(presentation, "sound");
    json::setBool(o.get(), "visual", json::getBool(presentation, "visual", true));
    json::setBool(o.get(), "sticky", json::getBool(presentation, "sticky", active));
    json::set(o.get(), "ttl_s", json::getInt(presentation, "ttl_s", active ? 0 : 10));
    if (!sound.empty()) json::set(o.get(), "alarm_sound", sound);
    json::set(o.get(), "alarm_volume",
              json::getInt(presentation, "volume", json::getInt(em, "alarm_volume", 100)));
    const EmergencyPalette palette = safeEmergencyPalette(presentation);
    json::set(o.get(), "background", palette.background);
    json::set(o.get(), "foreground", palette.foreground);
    json::set(o.get(), "accent", palette.accent);
    if (cJSON* channels = json::get(params, "channels"))
      json::setItem(o.get(), "channels", json::Doc(cJSON_Duplicate(channels, 1)));
    const std::string hash = assetRefHash(sound);
    if (!hash.empty() && assetCached(hash))
      json::set(o.get(), "audio_path", assetFilePath(hash));
    const bool dispatched = uiNotify(json::dump(o.get()));
    auto delivery = json::obj();
    json::set(delivery.get(), "schema_version", static_cast<int64_t>(1));
    json::set(delivery.get(), "source_event_id", eventIdentity(ev));
    json::set(delivery.get(), "source_event_origin", ev.origin);
    json::set(delivery.get(), "source_event_seq", static_cast<int64_t>(ev.seq));
    json::set(delivery.get(), "source_event_hlc", ev.hlc);
    json::set(delivery.get(), "channel", "local_shell");
    json::set(delivery.get(), "device_id", node_id);
    json::set(delivery.get(), "role", opts.role);
    json::set(delivery.get(), "result", dispatched ? "dispatched" : "shell_unavailable");
    if (cJSON* channels = json::get(params, "channels"))
      json::setItem(delivery.get(), "requested_channels",
                    json::Doc(cJSON_Duplicate(channels, 1)));
    events->append("delivery_result", ev.door, node_id, json::dump(delivery.get()));
  }

  void restoreEmergencyPresentation() {
    auto ev = store.latestEventOfTypes("emergency", "emergency_cancel");
    if (!ev) {
      auto state = json::obj();
      json::set(state.get(), "schema_version", static_cast<int64_t>(2));
      json::set(state.get(), "t", "emergency");
      json::setBool(state.get(), "active", false);
      json::setBool(state.get(), "state_only", true);
      uiNotify(json::dump(state.get()));
      return;
    }
    for (const auto& action : rules.evaluate(*ev, hlc->correctedWallMs(), tzOffsetMin())) {
      if (action.type != "device_alert") continue;
      auto params = json::parse(action.params_json.empty() ? "{}" : action.params_json);
      if (params) emergencyNotifyUi(*ev, params.get());
    }
  }




  void restoreEmergency() {
    auto ev = store.latestEventOfTypes("emergency", "emergency_cancel");
    if (!ev) return;
    hlc->observe(ev->hlc);
    emergency_hlc = ev->hlc;
    emergency_active = (ev->type == "emergency");
  }

  // Emergency state is always replicated. Presentation and external delivery are rule actions.
  bool applyEmergencyEvent(const EventRecord& ev) {
    if (ev.hlc <= emergency_hlc) return false;  // Ignore stale or clock-regressed events.
    emergency_hlc = ev.hlc;
    const bool now = (ev.type == "emergency");
    if (now == emergency_active) return false;
    emergency_active = now;
    return true;
  }

  bool doEmergency(bool active, const std::string& via) {
    auto p = json::obj();
    json::set(p.get(), "schema_version", static_cast<int64_t>(2));
    json::set(p.get(), "source", node_id);
    json::set(p.get(), "via", via);
    return events->append(active ? "emergency" : "emergency_cancel", "", node_id,
                          json::dump(p.get())).seq != 0;
  }

  std::string referencedSecret(cJSON* object, const char* ref_key) {
    return secretValue(json::getString(object, ref_key));
  }

  // ---------- SIP ----------
  SipSettings sipSettings() {
    SipSettings s;
    cJSON* sip = json::get(cfg.get(), "sip");
    s.server = json::getString(sip, "server");
    s.port = static_cast<int>(json::getInt(sip, "port", 5060));
    s.transport = json::getString(sip, "transport", "udp");
    cJSON* acct = cfgAt("sip.accounts." + node_id);
    s.user = json::getString(acct, "user");
    s.password = referencedSecret(acct, "pass_ref");
    sip_credential_source = s.password.empty() ? "none" : "secure_store";
    if (s.user.empty()) s.user = opts.sip_user;
    if (s.password.empty() && !opts.sip_pass.empty()) {
      s.password = opts.sip_pass;
      sip_credential_source = "boot";
    }
    s.display_name = opts.name;
    s.null_audio = opts.sip_null_audio;



    // Default by role, which is what the schema has always documented: a door station answers
    // immediately, an indoor panel rings and waits for a person. The setting used to default to
    // answering on every role, so an unconfigured indoor panel picked up the call by itself and
    // the history recorded it as answered by a device nobody had touched.
    s.auto_answer = opts.role == "door_station";
    std::string am = json::getString(acct, "answer_mode");
    if (am == "ring") s.auto_answer = false;
    else if (am == "auto") s.auto_answer = true;

    s.direct_port = static_cast<int>(json::getInt(sip, "direct_port", s.direct_port));

    cJSON* aec = cfgAt("devices." + node_id + ".local.aec");
    int tail = aec ? static_cast<int>(json::getInt(aec, "tail_ms", 0)) : 0;
    if (tail > 0) s.ec_tail_ms = tail;
    return s;
  }


  void scheduleSipReapply() {
    if (!sipctl) return;
    if (sip_reapply_timer) loop->cancel(sip_reapply_timer);
    sip_reapply_timer = loop->postDelayed(300, [this] {
      sip_reapply_timer = 0;
      if (sipctl) sipctl->updateSettings(sipSettings());
    });
  }




  void updateSipAllowedSources() {
    if (!sipctl || !mesh) return;
    std::vector<std::string> ips;
    ips.push_back("127.0.0.1");
    for (const auto& p : mesh->peers()) {
      if (p.status == "dead") continue;
      for (const auto& a : p.addrs) ips.push_back(hostOf(a));
    }
    sipctl->setAllowedSources(ips);
  }






  void resolveCallPeer(const std::string& remote, std::string* node, std::string* stream) {
    node->clear();
    stream->clear();
    std::string user, host;
    if (!parseSipRemote(remote, &user, &host) || !mesh) return;
    const std::string server = json::getString(json::get(cfg.get(), "sip"), "server");
    if (!user.empty() && !server.empty() && host == server) {

      cJSON* accounts = cfgAt("sip.accounts");
      cJSON* it = nullptr;
      cJSON_ArrayForEach(it, accounts) {
        if (it->string && json::getString(it, "user") == user) {
          *node = it->string;
          break;
        }
      }
    } else {

      for (const auto& p : mesh->peers()) {
        if (p.id == node_id) continue;
        for (const auto& a : p.addrs) {
          if (hostOf(a) == host) {
            *node = p.id;
            break;
          }
        }
        if (!node->empty()) break;
      }
    }
    if (node->empty() || *node == node_id) {
      node->clear();
      return;
    }
    for (const auto& p : mesh->peers()) {
      if (p.id == *node && p.status != "dead" && !p.addrs.empty()) {
        *stream = "http://" + hostOf(p.addrs[0]) + ":47180/stream.mjpeg";
        return;
      }
    }
  }




  void reevalBridge() {
    if (!bridge) return;
    cJSON* mqtt = cfgAt("integrations.mqtt");
    const std::string host = json::getString(mqtt, "host");
    const bool active = !host.empty() && mesh && mesh->isLeader("mqtt_bridge");
    auto effective = json::Doc(cJSON_Duplicate(cfg.get(), 1));
    cJSON* effective_mqtt = json::get(json::get(effective.get(), "integrations"), "mqtt");
    const std::string password = referencedSecret(mqtt, "pass_ref");
    if (effective_mqtt && !password.empty()) json::set(effective_mqtt, "pass", password);
    bridge->configure(json::dump(effective.get()), node_id, active);
  }

  void scheduleBridgeReapply() {
    if (!bridge && !tg) return;
    if (bridge_reapply_timer) loop->cancel(bridge_reapply_timer);
    bridge_reapply_timer = loop->postDelayed(300, [this] {
      bridge_reapply_timer = 0;
      reevalBridge();
      reevalTelegram();
    });
  }

  std::string telegramToken() {
    return referencedSecret(cfgAt("integrations.telegram"), "bot_token_ref");
  }


  void reevalTelegram() {
    if (!tg) return;
    const std::string token = telegramToken();
    const bool active = !token.empty() && mesh && mesh->isLeader("telegram");
    auto effective = json::Doc(cJSON_Duplicate(cfg.get(), 1));
    cJSON* effective_tg = json::get(json::get(effective.get(), "integrations"), "telegram");
    if (effective_tg && !token.empty()) json::set(effective_tg, "bot_token", token);
    tg->configure(json::dump(effective.get()), node_id, active);


    if (active && !tg_was_active) rescanPendingTelegram();
    tg_was_active = active;
  }

  void rescanPendingTelegram() {
    const int64_t cutoff = hlc->correctedWallMs() - 15 * 60 * 1000;
    for (const auto& ev : store.recentEvents(50)) {
      if (ev.type != "press" || ev.wall_ms < cutoff) continue;
      auto n = json::parse(ev.notify_json.empty() ? "{}" : ev.notify_json);
      if (n && !json::getString(n.get(), "notified_at").empty()) continue;
      if (n && json::get(n.get(), "replied")) continue;
      for (const auto& a : rules.evaluate(ev, hlc->correctedWallMs(), tzOffsetMin())) {
        if (a.type == "telegram") tg->onAction(ev, a.params_json);
      }
    }
  }



  void httpsCall(const std::string& method, const std::string& url, const std::string& headers,
                 const Bytes& body, std::function<void(int, std::string)> done) {
    HttpsFn fn;
    {
      std::lock_guard<std::mutex> lk(cb_mu);
      fn = https_fn;
    }
    if (!fn) {
      loop->post([done] { done(-1, ""); });
      return;
    }
    std::weak_ptr<char> w = alive;
    Runloop* lp = loop;
    fn(method, url, headers, body, [w, lp, done](int status, std::string resp) {


      if (w.expired()) return;
      lp->post([w, done, status, resp] {
        if (!w.expired()) done(status, resp);
      });
    });
  }

  void onSipReg(SipRegState st, const std::string& reason) {
    sip_reg = st;
    auto o = json::obj();
    json::set(o.get(), "t", "sip");
    json::setBool(o.get(), "registered", st == SipRegState::Registered);
    json::set(o.get(), "state", sipRegName(st));
    if (!reason.empty()) json::set(o.get(), "reason", reason);
    uiNotify(json::dump(o.get()));
  }

  void onSipCall(SipCallState st, const std::string& remote) {
    const SipCallState previous = sip_call;
    sip_call = st;

    const char* s = nullptr;
    switch (st) {
      case SipCallState::Calling: s = "calling"; break;
      case SipCallState::InCall: s = "in_call"; break;
      case SipCallState::Idle: s = "idle"; break;
      case SipCallState::Ended: break;
    }
    if (st == SipCallState::Idle) {
      dtmf_buf.clear();
      if (dtmf_timer) {
        loop->cancel(dtmf_timer);
        dtmf_timer = 0;
      }

      sip_peer_node.clear();
      sip_peer_stream.clear();
      peer_frame.clear();
      peer_frame_mono = 0;
    }
    if (st == SipCallState::InCall) {
      resolveCallPeer(remote, &sip_peer_node, &sip_peer_stream);
      if (!sip_call_id.empty()) {
        for (auto& entry : active_calls) {
          ActiveCall& call = entry.second;
          if (call.call_id != sip_call_id) continue;
          // Only a dialog someone is actually talking on may answer a call. An outbound
          // listen-in dialog occupies the same primary slot as a real call, so without this a
          // panel opening monitor sessions marked the ringing call answered by itself -- and a
          // burst of them wrote that into the history for a call nobody had picked up.
          const std::string dialog_mode = sipctl ? sipctl->callMode() : std::string();
          if (call.state == "ringing" && SipCtl::dialogCanAnswer(dialog_mode)) {
            call.local_sip_established = true;
            if (call.timeout_timer) loop->cancel(call.timeout_timer);
            call.timeout_timer = 0;
            door_calling_until.erase(call.door);
            doReportCallAnswered(call.door, call.call_id, call.stage_revision, node_id,
                                 /*retry_on_persistence_failure=*/true);
          } else if (call.state == "ringing") {
            DB_LOGI(kTag, "listen-in dialog established while " + call.call_id +
                              " rings; the call stays ringing");
          }
          break;
        }
      }
    }
    if (st == SipCallState::Idle &&
        (previous == SipCallState::InCall || previous == SipCallState::Ended) &&
        !sip_call_id.empty()) {
      auto pending = pending_lifecycles.find(sip_call_id);
      if (pending != pending_lifecycles.end() && pending->second.owner == node_id) {
        pending->second.end_pending = true;
        pending->second.end_reason = "hangup";
        if (pending->second.retry_timer) loop->cancel(pending->second.retry_timer);
        pending->second.retry_timer = 0;
        flushPendingLifecycle(sip_call_id);
      } else {
        for (auto& entry : active_calls) {
          ActiveCall& call = entry.second;
          // The durable dialog owner, not a losing local SIP leg, owns the terminal event.
          if (call.call_id != sip_call_id) continue;
          if (call.state == "in_call" && call.dialog_owner == node_id) {
            doReportCallEnded(call.door, call.call_id, call.stage_revision, "hangup", node_id,
                              /*retry_on_persistence_failure=*/true);
          } else if (call.state == "ringing" && call.local_sip_established) {
            queuePendingAnswer(call, node_id);
            queuePendingEnd(call, node_id, "hangup");
            pending = pending_lifecycles.find(call.call_id);
            if (pending != pending_lifecycles.end()) {
              if (pending->second.retry_timer) loop->cancel(pending->second.retry_timer);
              pending->second.retry_timer = 0;
              flushPendingLifecycle(call.call_id);
            }
          }
          break;
        }
      }
    }
    if (!s) return;
    auto o = json::obj();
    json::set(o.get(), "t", "state");
    json::set(o.get(), "state", s);
    if (!remote.empty()) json::set(o.get(), "remote", remote);
    if (st == SipCallState::InCall && !sip_peer_node.empty()) {
      json::set(o.get(), "peer_node", sip_peer_node);
      if (!sip_peer_stream.empty()) json::set(o.get(), "peer_stream", sip_peer_stream);
    }
    uiNotify(json::dump(o.get()));
  }



  void onSipDtmf(char digit) {
    if (dtmf_timer) loop->cancel(dtmf_timer);
    dtmf_timer = loop->postDelayed(3000, [this] {
      dtmf_timer = 0;
      dtmf_buf.clear();
    });
    dtmf_buf.push_back(digit);
    cJSON* acts = cfgAt("sip.dtmf_actions");
    if (!acts) return;
    cJSON* hit = json::get(acts, dtmf_buf.c_str());
    if (hit) {
      execDtmfAction(dtmf_buf, hit);
      dtmf_buf.clear();
      return;
    }

    bool prefix = false;
    cJSON* it = nullptr;
    cJSON_ArrayForEach(it, acts) {
      if (it->string && std::strncmp(it->string, dtmf_buf.c_str(), dtmf_buf.size()) == 0)
        prefix = true;
    }
    if (!prefix) {
      dtmf_buf.assign(1, digit);
      cJSON_ArrayForEach(it, acts) {
        if (it->string && std::strncmp(it->string, dtmf_buf.c_str(), 1) == 0) return;
      }
      dtmf_buf.clear();
    }
  }

  void execDtmfAction(const std::string& code, cJSON* action) {
    std::string type = json::getString(action, "type");
    DB_LOGI(kTag, "DTMF feature code " + code + " -> " + type);
    if (type == "hangup") {
      if (sipctl) sipctl->hangup();
    } else if (type == "ha_command") {

      auto p = json::parse(json::dump(action));
      json::set(p.get(), "code", code);
      DB_LOGI(kTag, "HA command queued for the MQTT bridge: " + json::dump(p.get()));
      std::string door = opts.door.empty() ? last_press_door : opts.door;
      events->append("dtmf_action", door, node_id, json::dump(p.get()));
    } else {
      DB_LOGW(kTag, "unknown DTMF action: " + type);
    }
  }

  static const char* sipRegName(SipRegState s) {
    switch (s) {
      case SipRegState::Idle: return "idle";
      case SipRegState::Registering: return "registering";
      case SipRegState::Registered: return "registered";
      case SipRegState::Failed: return "failed";
    }
    return "?";
  }
  static const char* sipCallName(SipCallState s) {
    switch (s) {
      case SipCallState::Idle: return "idle";
      case SipCallState::Calling: return "calling";
      case SipCallState::InCall: return "in_call";
      case SipCallState::Ended: return "ended";
    }
    return "?";
  }

  std::string labelIn(const cJSON* label_obj, const std::string& lang) {
    if (!label_obj) return "";
    std::string v = json::getString(label_obj, lang.c_str());
    if (v.empty()) v = json::getString(label_obj, "ja");
    if (v.empty() && cJSON_IsString(label_obj->child)) v = label_obj->child->valuestring;
    return v;
  }

  // Resolve text on the runloop for Node::text.
  // Lookup order is the requested language, Japanese override, built-in text, then the key.
  // Override names such as "event.press" are literal object keys, not nested config paths.
  std::string textOnLoop(const std::string& key, const std::string& lang_arg,
                         const std::vector<std::pair<std::string, std::string>>& args) {
    const std::string lang = lang_arg.empty() ? "ja" : lang_arg;
    std::string out;
    cJSON* ov = json::get(cfg.get(), "i18n_overrides");
    if (ov) {
      out = json::getString(json::get(ov, lang.c_str()), key.c_str());
      if (out.empty() && lang != "ja") out = json::getString(json::get(ov, "ja"), key.c_str());
    }
    if (out.empty()) {
      const char* b = builtinText(key, lang);
      if (b) out = b;
    }
    if (out.empty()) out = key;  // Keep missing translations visible to operators.
    substArgs(out, args);
    return out;
  }

  // ---------- Startup ----------
  std::string computeEffectiveCaps() {
    auto measured = json::parse(measured_caps_json);
    if (!measured || !cJSON_IsObject(measured.get())) measured = json::obj();
    const bool measured_tls = json::getBool(measured.get(), "tls12", false);
    std::string mqtt_source = cJSON_IsBool(json::get(measured.get(), "mqtt_reachable"))
        ? "shell" : "unmeasured";
    if (!mqtt_probe_host.empty() && mqtt_probe_known) {
      json::setBool(measured.get(), "mqtt_reachable", mqtt_probe_reachable);
      mqtt_source = "configured_endpoint_probe";
    }
    // A platform that reports power state is measuring mains presence directly; that measurement
    // replaces the create-time guess before administrator overrides are applied.
    if (power.known) json::setBool(measured.get(), "mains_power", power.mains);
    const cJSON* device = cfgAt("devices." + node_id);
    const cJSON* override_caps = json::get(device, "caps_override");
    if (!cJSON_IsObject(override_caps))
      override_caps = json::get(json::get(device, "local"), "caps_override");
    const std::set<std::string> operational_overrides = {
        "wan", "mains_power", "mqtt_reachable", "wall_clock_sane"};
    const cJSON* field = nullptr;
    cJSON_ArrayForEach(field, override_caps) {
      if (!field->string) continue;
      const std::string key = field->string;
      if (operational_overrides.count(key)) {
        if (cJSON_IsBool(field)) {
          json::setBool(measured.get(), key.c_str(), cJSON_IsTrue(field));
          if (key == "mqtt_reachable") mqtt_source = "administrator_override";
        }
        continue;
      }
      cJSON* hardware_limit = json::get(measured.get(), key.c_str());
      if (cJSON_IsBool(hardware_limit) && cJSON_IsBool(field)) {
        // An override may disable a measured hardware feature, but cannot invent one.
        json::setBool(measured.get(), key.c_str(), cJSON_IsTrue(hardware_limit) && cJSON_IsTrue(field));
      } else if (cJSON_IsNumber(hardware_limit) && cJSON_IsNumber(field)) {
        json::set(measured.get(), key.c_str(),
                  std::min(hardware_limit->valuedouble, field->valuedouble));
      }
    }
    // No administrator override can claim TLS when the platform has no HTTPS transport.
    if (!opts.has_https || !measured_tls) json::setBool(measured.get(), "tls12", false);
    cJSON* mqtt = cfgAt("integrations.mqtt");
    const std::string mqtt_host = json::getString(mqtt, "host");
    const std::string mqtt_ref = json::getString(mqtt, "pass_ref");
    json::setBool(measured.get(), "mqtt_ready",
                  !mqtt_host.empty() && (mqtt_ref.empty() || !referencedSecret(mqtt, "pass_ref").empty()));
    json::setBool(measured.get(), "telegram_ready", !telegramToken().empty());
    cJSON* web_push = cfgAt("integrations.web_push");
    const std::string push_sender_ref = json::getString(web_push, "sender_secret_ref");
    const bool push_sender_secret_ready =
        push_sender_ref.empty() ||
        (secretRefValid(push_sender_ref) &&
         !referencedSecret(web_push, "sender_secret_ref").empty());
    json::setBool(measured.get(), "web_push_ready",
                  webPushConfigSyntaxValid(web_push) &&
                  !referencedSecret(web_push, "vapid_private_key_ref").empty() &&
                  push_sender_secret_ready);
    json::set(measured.get(), "mqtt_reachability_source", mqtt_source);
    json::setItem(measured.get(), "features", effectiveFeaturesDoc());
    return json::dump(measured.get());
  }

  bool uiManifestSupports(const std::string& element = "") const {
    auto manifest = json::parse(ui_manifest_json);
    const cJSON* elements = manifest ? json::get(manifest.get(), "elements") : nullptr;
    if (!cJSON_IsObject(elements) || !elements->child) return false;
    return element.empty() || cJSON_IsObject(json::get(elements, element.c_str()));
  }

  std::string webUiManifestJson() const {
    auto web = json::parse(baseWebUiManifestJson());
    if (!web || !cJSON_IsObject(web.get())) return "{}";
    auto web_only = json::parse(webOnlyUiElementsJson());
    cJSON* web_elements = json::get(web.get(), "elements");
    if (web_only && cJSON_IsObject(web_only.get()) && cJSON_IsObject(web_elements)) {
      const cJSON* item = nullptr;
      cJSON_ArrayForEach(item, web_only.get()) {
        if (!item->string || json::get(web_elements, item->string)) continue;
        cJSON_AddItemToObject(web_elements, item->string, cJSON_Duplicate(item, 1));
      }
    }

    std::string manifest_error;
    if (!uiManifestValid(ui_manifest_json, &manifest_error)) return json::dump(web.get());
    auto native = json::parse(ui_manifest_json);
    const cJSON* native_elements = native ? json::get(native.get(), "elements") : nullptr;
    if (!cJSON_IsObject(native_elements) || !cJSON_IsObject(web_elements))
      return json::dump(web.get());

    cJSON* web_element = nullptr;
    cJSON_ArrayForEach(web_element, web_elements) {
      if (!web_element->string) continue;
      const cJSON* native_element = json::get(native_elements, web_element->string);
      if (!cJSON_IsObject(native_element)) continue;
      const cJSON* native_properties = json::get(native_element, "properties");
      const cJSON* native_defaults = json::get(native_element, "defaults");
      const cJSON* web_properties = json::get(web_element, "properties");
      const cJSON* web_defaults = json::get(web_element, "defaults");
      auto properties = json::arr();
      auto defaults = json::obj();
      const cJSON* property = nullptr;
      cJSON_ArrayForEach(property, web_properties) {
        if (!cJSON_IsString(property) || !property->valuestring) continue;
        bool supported = false;
        const cJSON* native_property = nullptr;
        cJSON_ArrayForEach(native_property, native_properties) {
          if (cJSON_IsString(native_property) && native_property->valuestring &&
              std::string(native_property->valuestring) == property->valuestring) {
            supported = true;
            break;
          }
        }
        if (!supported) continue;
        json::push(properties.get(), json::Doc(cJSON_CreateString(property->valuestring)));
        const cJSON* value = json::get(native_defaults, property->valuestring);
        if (!value) value = json::get(web_defaults, property->valuestring);
        if (value)
          json::setItem(defaults.get(), property->valuestring,
                        json::Doc(cJSON_Duplicate(value, 1)));
      }
      if (cJSON_GetArraySize(properties.get()) == 0) continue;
      json::setItem(web_element, "properties", std::move(properties));
      json::setItem(web_element, "defaults", std::move(defaults));
      if (json::getBool(native_element, "safety_critical"))
        json::setBool(web_element, "safety_critical", true);
    }
    return json::dump(web.get());
  }

  bool webUiManifestSupports(const std::string& element) const {
    auto manifest = json::parse(webUiManifestJson());
    const cJSON* elements = manifest ? json::get(manifest.get(), "elements") : nullptr;
    return cJSON_IsObject(json::get(elements, element.c_str()));
  }

  static std::string peerContractCacheKey(const std::string& id) {
    return "peer_ui_contract." + id;
  }

  json::Doc cachedPeerContract(const std::string& id) {
    auto raw = store.metaGet(peerContractCacheKey(id));
    if (!raw || raw->size() > 128 * 1024) return {};
    auto contract = json::parse(*raw);
    if (!contract || json::getInt(contract.get(), "schema_version") != 1 ||
        json::getString(contract.get(), "node_id") != id)
      return {};
    const cJSON* manifest = json::get(contract.get(), "ui_manifest");
    const cJSON* caps = json::get(contract.get(), "caps");
    const cJSON* features = json::get(caps, "features");
    std::string manifest_error;
    if (!cJSON_IsObject(manifest) || !cJSON_IsObject(features) ||
        !json::getBool(features, "ui_manifest_v1") ||
        !uiManifestValid(json::dump(manifest), &manifest_error))
      return {};
    const cJSON* runtime = json::get(contract.get(), "runtime");
    if (runtime) {
      std::string projected;
      auto raw_runtime = json::dump(runtime);
      auto clean_runtime = projectMeshRuntimeJson(raw_runtime, &projected)
          ? json::parse(projected) : json::obj();
      json::setItem(contract.get(), "runtime",
                    clean_runtime ? std::move(clean_runtime) : json::obj());
    }
    return contract;
  }

  std::string cachedPeerUiManifest(const std::string& id) {
    auto contract = cachedPeerContract(id);
    const cJSON* manifest = contract ? json::get(contract.get(), "ui_manifest") : nullptr;
    return cJSON_IsObject(manifest) ? json::dump(manifest) : "";
  }

  // Exactly the fields a shell renders in a peer list. Addresses are sorted so the order a peer
  // happens to advertise them in is not mistaken for a change.
  std::string peersDigest() {
    if (!mesh) return std::string();
    std::string composed;
    auto field = [&composed](const std::string& value) {
      composed += std::to_string(value.size());
      composed += ':';
      composed += value;
    };
    for (const auto& peer : mesh->peers()) {
      field(peer.id);
      field(peer.status);
      field(peer.connected ? "1" : "0");
      field(peer.role);
      field(peer.door);
      field(peer.sw_version);
      field(peer.caps_json);
      field(peer.ui_manifest_json);
      field(json::getString(cfgAt("devices." + peer.id), "name"));
      std::vector<std::string> addrs = peer.addrs;
      std::sort(addrs.begin(), addrs.end());
      for (const auto& addr : addrs) field(addr);
      composed += ';';
    }
    return sha256Hex(reinterpret_cast<const uint8_t*>(composed.data()), composed.size());
  }

  void notifyPeersChanged() {
    const std::string digest = peersDigest();
    // Nothing a shell would draw differently. This also absorbs a flap that has already
    // reverted by the time the coalescing timer fires.
    if (peers_ever_emitted && digest == emitted_peers_digest) return;
    const int64_t at = clock->monoMs();
    if (peers_ever_emitted && at - peers_emitted_mono < kPeersEventMinGapMs) {
      if (!peers_emit_timer) {
        const int64_t wait = kPeersEventMinGapMs - (at - peers_emitted_mono);
        peers_emit_timer = loop->postDelayed(wait, [this] {
          peers_emit_timer = 0;
          notifyPeersChanged();
        });
      }
      return;
    }
    emitted_peers_digest = digest;
    peers_ever_emitted = true;
    peers_emitted_mono = at;
    uiNotify("{\"t\":\"peers_changed\"}");
  }

  void cachePeerContracts() {
    if (!mesh) return;
    for (const auto& peer : mesh->peers()) {
      if (peer.id.empty() || peer.id == node_id || peer.id.size() > 128) continue;
      std::string manifest_error;
      if (peer.ui_manifest_json.size() > 64 * 1024 ||
          !uiManifestValid(peer.ui_manifest_json, &manifest_error))
        continue;
      auto manifest = json::parse(peer.ui_manifest_json);
      auto caps = json::parse(peer.caps_json);
      const cJSON* features = caps ? json::get(caps.get(), "features") : nullptr;
      if (!manifest || !cJSON_IsObject(manifest.get()) || !cJSON_IsObject(features) ||
          !json::getBool(features, "ui_manifest_v1"))
        continue;
      auto contract = json::obj();
      json::set(contract.get(), "schema_version", static_cast<int64_t>(1));
      json::set(contract.get(), "node_id", peer.id);
      json::set(contract.get(), "role", peer.role);
      if (!peer.door.empty()) json::set(contract.get(), "door", peer.door);
      json::set(contract.get(), "sw", peer.sw_version);
      json::setItem(contract.get(), "caps",
                    caps && cJSON_IsObject(caps.get()) ? std::move(caps) : json::obj());
      json::setItem(contract.get(), "ui_manifest", std::move(manifest));
      std::string projected_runtime;
      auto runtime = projectMeshRuntimeJson(peer.runtime_json, &projected_runtime)
          ? json::parse(projected_runtime) : json::obj();
      json::setItem(contract.get(), "runtime",
                    runtime ? std::move(runtime) : json::obj());
      // updated_wall_ms is added last and excluded from the comparison: stamping it into every
      // rebuild made the row differ from itself, so a quiet cluster wrote to the database once
      // per peer per peers_changed. It now means "when this contract last changed".
      const std::string body = json::dump(contract.get());
      const std::string digest = sha256Hex(reinterpret_cast<const uint8_t*>(body.data()),
                                           body.size());
      auto remembered = cached_contract_digests.find(peer.id);
      if (remembered != cached_contract_digests.end() && remembered->second == digest) continue;
      std::string stored_body;
      auto previous = store.metaGet(peerContractCacheKey(peer.id));
      if (previous) {
        auto parsed = json::parse(*previous);
        if (parsed) {
          cJSON_DeleteItemFromObject(parsed.get(), "updated_wall_ms");
          stored_body = json::dump(parsed.get());
        }
      }
      if (stored_body != body) {
        json::set(contract.get(), "updated_wall_ms", hlc->correctedWallMs());
        store.metaSet(peerContractCacheKey(peer.id), json::dump(contract.get()));
      }
      cached_contract_digests[peer.id] = digest;
    }
  }

  bool measuredFeature(const std::string& feature) const {
    auto measured = json::parse(measured_caps_json);
    if (!measured || !cJSON_IsObject(measured.get())) return false;
    const cJSON* features = json::get(measured.get(), "features");
    return cJSON_IsObject(features) && json::getBool(features, feature.c_str());
  }

  json::Doc effectiveFeaturesDoc() const {
    auto features = json::obj();
    for (const char* feature : {"emergency_rules_v1", "config_batch_v1",
                                "sip_dtmf_v1", "media_sources_v1",
                                "web_push_subscriptions_v1"})
      json::setBool(features.get(), feature, true);
    for (const char* feature : {"platform_v2", "call_flow_v2", "call_cancel_v2",
                                "call_lifecycle_v2", "device_alert_v1", "runtime_recovery_v1",
                                "helper_policy_v1"})
      json::setBool(features.get(), feature, measuredFeature(feature));
    json::setBool(features.get(), "ui_manifest_v1",
                  measuredFeature("ui_manifest_v1") && uiManifestSupports());
    return features;
  }

  bool selfFeature(const std::string& feature) const {
    auto caps = json::parse(effective_caps_json);
    return caps && json::getBool(json::get(caps.get(), "features"), feature.c_str());
  }

  static bool advertisedFeature(const std::string& caps_json, const std::string& feature) {
    auto caps = json::parse(caps_json);
    if (!caps) return false;
    const cJSON* features = json::get(caps.get(), "features");
    return cJSON_IsObject(features) && json::getBool(features, feature.c_str());
  }

  std::string relevantDoorStation(const std::string& door) const {
    std::string station;
    auto active = active_calls.find(door);
    if (active != active_calls.end()) station = active->second.origin;
    if (station.empty()) {
      const cJSON* devices = json::get(cfg.get(), "devices");
      const cJSON* device = nullptr;
      cJSON_ArrayForEach(device, devices) {
        if (device->string && json::getString(device, "role") == "door_station" &&
            json::getString(device, "door") == door) {
          if (station.empty() || std::string(device->string) < station)
            station = device->string;
        }
      }
    }
    if (station.empty() && opts.role == "door_station" && opts.door == door) station = node_id;
    return station;
  }

  bool doorFeature(const std::string& door, const std::string& feature) const {
    const std::string station = relevantDoorStation(door);
    if (station == node_id) return selfFeature(feature);
    if (!mesh) return false;
    for (const auto& peer : mesh->peers())
      if (peer.id == station) return advertisedFeature(peer.caps_json, feature);
    return false;
  }

  bool doorManifestSupports(const std::string& door, const std::string& element) const {
    const std::string station = relevantDoorStation(door);
    if (station == node_id) return uiManifestSupports(element);
    if (!mesh) return false;
    for (const auto& peer : mesh->peers()) {
      if (peer.id != station) continue;
      auto manifest = json::parse(peer.ui_manifest_json);
      const cJSON* elements = manifest ? json::get(manifest.get(), "elements") : nullptr;
      return cJSON_IsObject(json::get(elements, element.c_str()));
    }
    return false;
  }

  std::string effectiveCallFlow(const std::string& door) const {
    const std::string configured =
        json::getString(json::get(cfg.get(), "ui"), "call_flow", "purpose_first");
    if (configured != "ring_then_purpose") return "purpose_first";
    if (!doorFeature(door, "call_flow_v2") || !doorFeature(door, "call_cancel_v2") ||
        !doorFeature(door, "ui_manifest_v1") ||
        !doorManifestSupports(door, "purpose.button") ||
        !doorManifestSupports(door, "cancel.call"))
      return "purpose_first";
    return configured;
  }

  bool configWriteValidEffective(const std::string& key, const cJSON* value,
                                 std::string* error,
                                 std::vector<ConfigWarning>* warnings = nullptr) {
    if (!configWriteValid(key, value, error, warnings)) return false;
    themeContrastWarnings(key, value, warnings);
    const std::string marker = ".local.ui.elements.";
    const size_t marker_pos = key.find(marker);
    if (marker_pos == std::string::npos || !cJSON_IsObject(value)) return true;

    auto resolved = json::obj();
    auto overlay = [&resolved](const cJSON* source) {
      if (!cJSON_IsObject(source)) return;
      for (const char* property : {"scale", "font_scale", "foreground", "background",
                                   "accent", "border", "radius"}) {
        const cJSON* item = json::get(source, property);
        if (item)
          json::setItem(resolved.get(), property, json::Doc(cJSON_Duplicate(item, 1)));
      }
    };

    const std::string element = key.substr(marker_pos + marker.size());
    const std::string device_prefix = "devices.";
    if (key.rfind(device_prefix, 0) != 0 || marker_pos <= device_prefix.size()) {
      *error = "semantic UI override is missing a target device";
      return false;
    }
    const std::string target_id =
        key.substr(device_prefix.size(), marker_pos - device_prefix.size());
    std::string target_manifest_json;
    if (target_id == node_id) {
      std::string native_error;
      if (uiManifestValid(ui_manifest_json, &native_error) && uiManifestSupports(element))
        target_manifest_json = ui_manifest_json;
      else if (webUiManifestSupports(element))
        target_manifest_json = webUiManifestJson();
    } else if (mesh) {
      for (const auto& peer : mesh->peers()) {
        if (peer.id != target_id) continue;
        if (advertisedFeature(peer.caps_json, "ui_manifest_v1"))
          target_manifest_json = peer.ui_manifest_json;
        break;
      }
    }
    if (target_manifest_json.empty()) target_manifest_json = cachedPeerUiManifest(target_id);
    std::string manifest_error;
    if (target_manifest_json.empty() ||
        !uiManifestValid(target_manifest_json, &manifest_error)) {
      *error = "target device has no valid ui_manifest";
      return false;
    }
    auto manifest = json::parse(target_manifest_json);
    const cJSON* manifest_element = manifest
        ? json::get(json::get(manifest.get(), "elements"), element.c_str()) : nullptr;
    if (!cJSON_IsObject(manifest_element)) {
      *error = "target ui_manifest does not advertise semantic element " + element;
      return false;
    }
    const cJSON* properties = json::get(manifest_element, "properties");
    const cJSON* proposed = nullptr;
    cJSON_ArrayForEach(proposed, value) {
      bool declared = false;
      const cJSON* property = nullptr;
      cJSON_ArrayForEach(property, properties) {
        if (cJSON_IsString(property) && proposed->string && property->valuestring &&
            std::string(property->valuestring) == proposed->string) {
          declared = true;
          break;
        }
      }
      if (!declared) {
        *error = "target ui_manifest does not support property " +
                 std::string(proposed->string ? proposed->string : "");
        return false;
      }
    }
    const cJSON* defaults = json::get(manifest_element, "defaults");
    if (!defaults) defaults = json::get(manifest_element, "default");
    overlay(defaults);
    overlay(cfgAt(key));
    overlay(value);
    return uiStyleViewportValid(key, resolved.get(), json::get(manifest.get(), "viewport"),
                                error, warnings);
  }

  // Readability of the theme colours an administrator sets by hand, measured against the
  // effective background of the node being configured. Reported, never enforced.
  // The darkening layer is what keeps text legible over a photograph. Turning it off, or down
  // to almost nothing, is a legitimate choice on a dark image and a mistake on a bright one --
  // core cannot tell which, so it reports rather than refuses.
  void backdropWarnings(const std::string& key, const cJSON* value,
                        std::vector<ConfigWarning>* warnings) {
    if (!warnings) return;
    if (key.find("theme") == std::string::npos) return;
    // Only meaningful while a background image is configured: over a flat colour the ink is
    // already measured against the colour itself.
    if (themeBgImageOnLoop().empty()) return;
    const cJSON* backdrop = value;
    if (key.find("theme.backdrop") == std::string::npos) {
      backdrop = json::get(value, "backdrop");
      if (!backdrop) return;
    }
    bool weak = false;
    std::string property;
    if (key.size() >= 8 && key.compare(key.size() - 8, 8, ".enabled") == 0) {
      weak = cJSON_IsFalse(backdrop);
      property = "enabled";
    } else if (key.size() >= 8 && key.compare(key.size() - 8, 8, ".opacity") == 0) {
      weak = wholeNumberInRange(backdrop, 0, 19);
      property = "opacity";
    } else if (cJSON_IsObject(backdrop)) {
      const cJSON* enabled = json::get(backdrop, "enabled");
      const cJSON* opacity = json::get(backdrop, "opacity");
      if (cJSON_IsFalse(enabled)) {
        weak = true;
        property = "enabled";
      } else if (wholeNumberInRange(opacity, 0, 19)) {
        weak = true;
        property = "opacity";
      }
    }
    if (!weak) return;
    ConfigWarning warning;
    warning.key = key;
    warning.property = property;
    warning.message_key = "theme.backdrop_weak";
    warnings->push_back(std::move(warning));
  }

  void themeContrastWarnings(const std::string& key, const cJSON* value,
                             std::vector<ConfigWarning>* warnings) {
    if (!warnings) return;
    const bool is_theme_container =
        key == "display.theme" ||
        (key.rfind("devices.", 0) == 0 && key.size() >= 6 &&
         key.compare(key.size() - 6, 6, ".theme") == 0);
    backdropWarnings(key, value, warnings);
    if (!is_theme_container && key.find("theme.call_button_bg") == std::string::npos &&
        key.find("theme.ink_override") == std::string::npos)
      return;
    color::Rgb background;
    if (!color::parseHex(effectiveThemeBackground(), &background)) return;
    auto measure = [&](const cJSON* item, const std::string& warning_key,
                       const std::string& property, double floor_ratio) {
      color::Rgb candidate;
      if (!cJSON_IsString(item) || !color::parseHex(item->valuestring, &candidate)) return;
      const double ratio = color::contrastRatio(candidate, background);
      if (ratio < floor_ratio) addContrastWarning(warnings, warning_key, property, ratio);
    };
    if (is_theme_container) {
      // The Theme tab writes the whole object in one operation, so the colours are inspected
      // where they actually sit rather than only when written as individual leaves. A
      // background supplied by this same write is what the colours are measured against.
      const cJSON* written_background = json::get(value, "bg_color");
      if (cJSON_IsString(written_background))
        color::parseHex(written_background->valuestring, &background);
      measure(json::get(value, "call_button_bg"), key + ".call_button_bg", "call_button_bg",
              3.0);
      const cJSON* ink = json::get(value, "ink_override");
      const cJSON* region = nullptr;
      cJSON_ArrayForEach(region, ink) {
        if (region->string)
          measure(region, key + ".ink_override." + region->string, region->string, 4.5);
      }
      return;
    }
    if (key.find("theme.call_button_bg") != std::string::npos) {
      // A call button is a large UI component: WCAG 2.1 AA asks 3:1 against its surroundings.
      measure(value, key, "call_button_bg", 3.0);
      return;
    }
    const std::string marker = "theme.ink_override";
    const size_t pos = key.find(marker);
    const std::string tail = key.substr(pos + marker.size());
    if (tail.empty()) {
      const cJSON* item = nullptr;
      cJSON_ArrayForEach(item, value) {
        if (item->string) measure(item, key + "." + item->string, item->string, 4.5);
      }
      return;
    }
    if (tail[0] == '.') measure(value, key, tail.substr(1), 4.5);
  }

  void applyEffectiveCaps() {
    const std::string next = computeEffectiveCaps();
    if (next == effective_caps_json) return;
    effective_caps_json = next;
    if (mesh) mesh->setCaps(effective_caps_json);
    scheduleSnapshotRefresh();
  }

  std::string capabilitiesJsonOnLoop() const {
    auto root = json::obj();
    json::set(root.get(), "schema_version", static_cast<int64_t>(2));
    json::setItem(root.get(), "features", effectiveFeaturesDoc());
    auto caps = json::parse(effective_caps_json);
    json::setItem(root.get(), "caps", caps ? std::move(caps) : json::obj());
    json::setItem(root.get(), "runtime", runtimeStatusDoc());
    auto manifest = json::parse(ui_manifest_json);
    json::setItem(root.get(), "ui_manifest", manifest ? std::move(manifest) : json::obj());
    cJSON* web_ui = json::addObj(root.get(), "web_ui");
    json::set(web_ui, "device_id", node_id);
    auto web_manifest = json::parse(webUiManifestJson());
    json::setItem(web_ui, "manifest",
                  web_manifest ? std::move(web_manifest) : json::obj());
    return json::dump(root.get());
  }

  json::Doc runtimeStatusDoc() const {
    auto runtime = json::parse(runtime_status_json);
    if (!runtime || !cJSON_IsObject(runtime.get())) runtime = json::obj();
    auto web_report = json::parse(web_ui_style_report_json);
    if (web_report && cJSON_IsObject(web_report.get()) && web_report.get()->child)
      json::setItem(runtime.get(), "web_ui_style", std::move(web_report));
    if (!secret_migration_warnings.empty()) {
      cJSON* migration = json::addObj(runtime.get(), "core_secret_migration");
      json::setBool(migration, "ok", false);
      json::setBool(migration, "fail_closed", true);
      cJSON* warnings = json::addArr(migration, "warnings");
      for (const auto& warning : secret_migration_warnings)
        json::push(warnings, json::Doc(cJSON_CreateString(warning.c_str())));
    }
    cJSON_DeleteItemFromObjectCaseSensitive(runtime.get(), "config_store");
    if (config_persistence_failed) {
      cJSON* persistence = json::addObj(runtime.get(), "config_store");
      json::setBool(persistence, "ok", false);
      json::setBool(persistence, "fail_closed", true);
      json::set(persistence, "failures", static_cast<int64_t>(config_persistence_failures));
      json::set(persistence, "active_state", "last_known_good");
    }
    return runtime;
  }

  bool onConfigChanges(const std::vector<LwwEntry>& entries, bool is_local, bool batch) {
    if (entries.empty() || suppress_config_callbacks) return true;
    std::vector<LwwEntry> effective_entries = entries;
    std::vector<LwwEntry> rejected_entries;
    std::vector<LwwEntry> tombstones_to_push;
    if (!is_local) {
      for (const auto& entry : entries) {
        if (entry.deleted) continue;
        auto value = json::parse(entry.value_json);
        std::string error;
        // Remote ingress can enforce context-free schema and safety rules, but must not depend on
        // this receiver having already discovered the target's ui_manifest. The originating Admin
        // performs manifest-dependent validation; the target shell still applies LKG fail-closed.
        if (!value || !configWriteValid(entry.key, value.get(), &error)) {
          DB_LOGW(kTag, "rejected unsafe remote config key " + entry.key + " (" +
                            (error.empty() ? "invalid JSON" : error) + ")");
          rejected_entries.push_back(entry);
        }
      }
      if (!rejected_entries.empty()) {
        std::vector<LwwMutation> tombstone_mutations;
        tombstone_mutations.reserve(rejected_entries.size());
        for (const auto& entry : rejected_entries)
          tombstone_mutations.push_back({entry.key, "", true});

        // The remote winners are already in the CRDT map. Replace every unsafe winner before a
        // rebuild can expose it, while suppressing the nested observer callback. Persist the safe
        // remote winners and locally-authored tombstones together as one visible transition.
        suppress_config_callbacks = true;
        tombstones_to_push = config->mutate(tombstone_mutations);
        suppress_config_callbacks = false;

        effective_entries.clear();
        effective_entries.reserve(entries.size() + tombstones_to_push.size());
        for (const auto& entry : entries) {
          const bool rejected = std::any_of(
              rejected_entries.begin(), rejected_entries.end(),
              [&entry](const LwwEntry& candidate) { return candidate.key == entry.key; });
          if (!rejected) effective_entries.push_back(entry);
        }
        effective_entries.insert(effective_entries.end(), tombstones_to_push.begin(),
                                 tombstones_to_push.end());
        batch = batch || effective_entries.size() > 1;
      }
    }
    if (effective_entries.empty()) return true;
    const bool persisted = (batch || effective_entries.size() > 1)
        ? store.configPutBatch(effective_entries)
        : store.configPut(effective_entries.front());
    if (!persisted) {
      const bool first_failure = !config_persistence_failed;
      config_persistence_failed = true;
      ++config_persistence_failures;
      if (first_failure)
        DB_LOGE(kTag, "config persistence failed; retaining the last-known-good state");
      if (started) scheduleSnapshotRefresh();
      return false;
    }
    if (config_persistence_failed) {
      config_persistence_failed = false;
      if (started) scheduleSnapshotRefresh();
    }
    // A replicated write can carry values this node already has: anti-entropy re-sends the
    // whole frontier when a peer reconnects, and each entry is a legitimate CRDT update even
    // when the value is byte-identical. Persist and replicate it as always, but do not wake
    // every shell for a change nobody can see.
    std::map<std::string, std::string> values_before;
    if (!is_local) {
      for (const auto& e : effective_entries) {
        const cJSON* value = cfgAt(e.key);
        values_before[e.key] = value ? json::dump(value) : std::string();
      }
    }
    rebuildCfg();
    bool values_changed = is_local;
    if (!is_local) {
      for (const auto& e : effective_entries) {
        const cJSON* value = cfgAt(e.key);
        const std::string after = value ? json::dump(value) : std::string();
        if (after != values_before[e.key]) {
          values_changed = true;
          break;
        }
      }
    }
    if (is_local && mesh) mesh->pushConfigDelta(entries);
    if (!is_local && mesh && !tombstones_to_push.empty())
      mesh->pushConfigDelta(tombstones_to_push);

    bool self_device_changed = false;
    bool sip_changed = false;
    bool integrations_changed = false;
    bool panel_credential_changed = false;
    bool time_changed = false;
    std::set<std::string> notice_doors;
    for (const auto& e : effective_entries) {
      if (e.key == "time" || e.key.compare(0, 5, "time.") == 0) time_changed = true;
      const std::string notice_suffix = ".notice";
      if (e.key.compare(0, 6, "doors.") == 0 && e.key.size() > notice_suffix.size() &&
          e.key.compare(e.key.size() - notice_suffix.size(), notice_suffix.size(),
                        notice_suffix) == 0) {
        notice_doors.insert(
            e.key.substr(6, e.key.size() - 6 - notice_suffix.size()));
      }
      // The cluster-wide announcement changes what every door shows, so it is reported as the
      // wildcard target rather than as one door.
      if (e.key == "notice" || e.key == "notice.global") notice_doors.insert("*");
    }
    for (const auto& e : effective_entries) {
      const bool self_device = e.key.compare(0, 8, "devices.") == 0 &&
          e.key.find(node_id) != std::string::npos;
      self_device_changed = self_device_changed || self_device;
      sip_changed = sip_changed || e.key.compare(0, 4, "sip.") == 0 || self_device;
      integrations_changed = integrations_changed || e.key == "integrations" ||
          e.key.compare(0, 13, "integrations.") == 0;
      panel_credential_changed = panel_credential_changed || e.key == "panel" ||
          e.key == "panel.token_refs" || e.key == "panel.token_generation";
    }
    if (panel_credential_changed) invalidatePanelSessions();
    if (self_device_changed) {
      if (httpd) applyCameraSettings();
      applyMotionSettings();
      applyVideoRotation();
      applyEffectiveCaps();
    }
    if (sip_changed) scheduleSipReapply();
    if (integrations_changed) applyEffectiveCaps();
    if (started && integrations_changed) netRefreshSnapshot();
    if (time_changed && started) {
      // A zone change is what drives every clock in the fleet, so the compatibility offset is
      // rewritten immediately rather than waiting for the next housekeeping tick.
      refreshDerivedTzOffset();
      reapplyTimeSchedule();
      applyTimeOffset();
    }
    for (const auto& door : notice_doors) {
      const cJSON* current =
          isGlobalNoticeTarget(door)
              ? json::get(json::get(cfg.get(), "notice"), "global")
              : json::get(json::get(json::get(cfg.get(), "doors"), door.c_str()), "notice");
      // Anti-entropy replays a notice write whenever a peer syncs, and an administrator saving
      // the same text again is a write too. Neither is news: report the announcement only when
      // it actually differs from the one this node last reported for that door.
      const std::string signature = current ? json::dump(current) : std::string();
      auto reported = emitted_notice_digests.find(door);
      if (reported != emitted_notice_digests.end() && reported->second == signature) continue;
      emitted_notice_digests[door] = signature;
      auto notice_event = json::obj();
      json::set(notice_event.get(), "t", "notice_changed");
      json::set(notice_event.get(), "door", door);
      json::setBool(notice_event.get(), "active", cJSON_IsObject(current));
      uiNotify(json::dump(notice_event.get()));
    }
    scheduleBridgeReapply();
    if (started) evalDisplay();
    schedulePrefetch();
    if (values_changed) {
      auto event = json::obj();
      json::set(event.get(), "t", "config_changed");
      json::set(event.get(), "count", static_cast<int64_t>(effective_entries.size()));
      json::setBool(event.get(), "atomic", batch);
      uiNotify(json::dump(event.get()));
    }
    return true;
  }

  bool init() {
    // Store
    std::string db_path = opts.data_dir;
    if (db_path != ":memory:") {
      makeDir(opts.data_dir);
      db_path = opts.data_dir + "/doorbell.db";
    }
    if (!store.open(db_path)) {
      DB_LOGE(kTag, "store open failed: " + db_path);
      return false;
    }

    auto id = store.metaGet("node_id");
    if (!id) {
      node_id = genNodeId();
      if (!store.metaSet("node_id", node_id)) {
        DB_LOGE(kTag, "node identity could not be persisted");
        return false;
      }
    } else {
      node_id = *id;
    }
    auto ep = store.metaGet("epoch");
    epoch = ep ? std::stoull(*ep) + 1 : 1;
    if (!store.metaSet("epoch", std::to_string(epoch))) {
      DB_LOGE(kTag, "node epoch could not be persisted");
      return false;
    }


    assets_dir = (opts.data_dir == ":memory:")
                     ? tempDir() + "/doorbell-assets-" + node_id
                     : opts.data_dir + "/assets";
    makeDir(assets_dir);

    hlc.reset(new HlcClock(*clock, node_id.substr(0, 8)));
    config.reset(new LwwMap(node_id, *hlc));
    config->load(store.configLoadAll());
    events.reset(new EventLog(node_id, *hlc, store));
    events->loadHeads();

    config->onCommit([this](const std::vector<LwwEntry>& entries, bool is_local, bool batch) {
      return onConfigChanges(entries, is_local, batch);
    });
    events->onEvent([this](const EventRecord& ev, bool is_local) { onEvent(ev, is_local); });


    if (!transport) transport.reset(new TcpTransport(*loop));


    if (!discovery && opts.enable_beacon) discovery.reset(new UdpBeacon(*loop, opts.psk));

    // Pairing identity survives restarts: the founder badge lives in store metadata and the PSK
    // provenance comes from how the shell supplied the key in boot.json.
    {
      auto founder = store.metaGet("pairing.is_founder");
      pairing_is_founder = founder && *founder == "1";
      const bool has_psk = std::any_of(opts.psk.begin(), opts.psk.end(),
                                       [](uint8_t byte) { return byte != 0; });
      // "none" は「鍵がない」という意味なので、鍵を持っているのにそう名乗ることはできない。
      // 出所を申告しないホスト（doorbell_host や組み込み利用）は平文鍵として扱う。
      const bool declared = opts.psk_source == "secure_store" || opts.psk_source == "boot_plaintext";
      pairing_psk_source = !has_psk ? "none" : (declared ? opts.psk_source : "boot_plaintext");
      pairing_psk_ref = pairing_psk_source == "secure_store" ? opts.psk_ref : "";
      if (!has_psk) pairing_is_founder = false;
    }

    // Mesh
    MeshSettings ms = opts.use_mesh_timing_template ? opts.mesh_timing_template : MeshSettings{};
    ms.node_id = node_id;
    ms.epoch = epoch;
    ms.listen_addr = opts.listen_addr;

    ms.advertise_addr = opts.advertise_addr;
    if (ms.advertise_addr.empty()) {
      std::string ip = db::net::primaryIPv4();
      auto colon = opts.listen_addr.rfind(':');
      std::string port = colon != std::string::npos ? opts.listen_addr.substr(colon + 1) : "47172";
      ms.advertise_addr = ip.empty() ? opts.listen_addr : (ip + ":" + port);
    }
    ms.advertise_addrs = {ms.advertise_addr};
    // Gossip every interface on real networks so panels can choose a reachable management URL.
    // In-memory tests disable beacons and retain their symbolic addresses.
    if (opts.enable_beacon) {
      auto colon = opts.listen_addr.rfind(':');
      std::string port = colon != std::string::npos ? opts.listen_addr.substr(colon + 1) : "47172";
      for (const auto& ip : db::net::localAddresses(true)) {
        std::string addr = ip.find(':') == std::string::npos
            ? ip + ":" + port : "[" + ip + "]:" + port;
        if (std::find(ms.advertise_addrs.begin(), ms.advertise_addrs.end(), addr) ==
            ms.advertise_addrs.end()) ms.advertise_addrs.push_back(addr);
      }
    }
    {
      auto v4 = db::net::localAddresses(false);
      auto all = db::net::localAddresses(true);
      DB_LOGI(kTag, "addr-detect: local v4=" + std::to_string(v4.size()) +
                        " all=" + std::to_string(all.size()) +
                        " route=" + db::net::primaryIPv4ViaRoute() +
                        " advertise=" + ms.advertise_addr);
    }
    ms.seed_peers = opts.seed_peers;
    ms.psk = opts.psk;
    ms.role = opts.role;
    ms.door = opts.role == "door_station" ? opts.door : "";
    ms.sw_version = opts.sw_version;
    ms.model = opts.model.empty() ? "unknown" : opts.model;
    ms.platform = opts.platform.empty() ? "unknown" : opts.platform;
    effective_caps_json = computeEffectiveCaps();
    ms.caps_json = effective_caps_json;
    ms.ui_manifest_json = ui_manifest_json;
    ms.runtime_json = meshRuntimeJson();
    Mesh::Callbacks cbs;
    cbs.on_peers_changed = [this] {
      cachePeerContracts();
      updateSipAllowedSources();
      schedulePrefetch();
      rearmCallTimeouts();
      rearmCallRecoveryTakeovers();
      notifyPeersChanged();
    };
    cbs.on_leader_changed = [this](const std::string& duty, const std::string& leader) {

      if (duty == "mqtt_bridge") reevalBridge();
      if (duty == "telegram") reevalTelegram();
      auto o = json::obj();
      json::set(o.get(), "t", "leader");
      json::set(o.get(), "duty", duty);
      json::set(o.get(), "id", leader);
      uiNotify(json::dump(o.get()));
    };
    cbs.on_peer_alive_changed = [this](const std::string& id, bool alive) {
      updateSipAllowedSources();
      rearmCallTimeouts();
      rearmCallRecoveryTakeovers();
      onPeerAlive(id, alive);
    };
    cbs.on_command = [this](const std::string& from, const std::string& cmd) {
      onCommand(from, cmd);
    };
    cbs.on_pending_changed = [this] { uiNotify("{\"t\":\"pending_changed\"}"); };

    cbs.on_paired = [this] { onBecamePaired(); };
    cbs.on_invite_result = [this](const std::string& id, bool ok, const std::string& err) {
      auto o = json::obj();
      json::set(o.get(), "t", "invite_result");
      json::set(o.get(), "id", id);
      json::setBool(o.get(), "ok", ok);
      json::set(o.get(), "err", err);
      uiNotify(json::dump(o.get()));
    };
    cbs.on_device_joined = [this](const std::string& id, const std::string& name,
                                  const std::string& role) {
      auto o = json::obj();
      json::set(o.get(), "t", "device_joined");
      json::set(o.get(), "id", id);
      json::set(o.get(), "name", name);
      json::set(o.get(), "role", role);
      uiNotify(json::dump(o.get()));
    };
    cbs.on_pairing_mode_changed = [this](bool active, int64_t left_s, int added) {
      auto o = json::obj();
      json::set(o.get(), "t", "pairing_mode_changed");
      json::setBool(o.get(), "active", active);
      json::set(o.get(), "left_s", left_s);
      json::set(o.get(), "auto_added_count", static_cast<int64_t>(added));
      uiNotify(json::dump(o.get()));
    };
    cbs.on_join_token_changed = [this](bool active, int64_t expires_s, int attempts_left) {
      auto o = json::obj();
      json::set(o.get(), "t", "join_token_changed");
      json::setBool(o.get(), "active", active);
      json::set(o.get(), "expires_s", expires_s);
      json::set(o.get(), "attempts_left", static_cast<int64_t>(attempts_left));
      uiNotify(json::dump(o.get()));
    };
    cbs.on_invite_rejected = [this](const std::string& reason) {
      auto o = json::obj();
      json::set(o.get(), "t", "invite_rejected");
      json::set(o.get(), "reason", reason);
      uiNotify(json::dump(o.get()));
    };
    cbs.on_unpaired = [this] { pairing_joining = false; };
    mesh.reset(new Mesh(*loop, *clock, *hlc, *transport, discovery.get(), store, *config,
                        *events, ms, cbs));

    mesh->setSnapshotProvider([this] { return frame_bus.latestJpeg(); });

    mesh->setBlobProvider([this](const std::string& hash) {
      Bytes b;
      if (isSha256HexStr(hash)) readFileBytes(assetFilePath(hash), b);
      return b;
    });

    rebuildCfg();
    // Seal legacy Push endpoint/key material before the generic secret migration sees nested
    // Web Push auth fields. Sealed records remain replicated for leader failover but are never
    // exported in plaintext.
    if (!migrateLegacyWebPushSubscriptions() || !migrateLegacyRuntimeCredentials()) {
      DB_LOGE(kTag, "configuration credential migration failed closed");
      return false;
    }


    {
      HaBridge::Hooks hooks;
      hooks.on_reply = [this](const std::string& rid, const std::string& text,
                              const std::string& door, const std::string& call_id,
                              int revision) {
        return quickReply(rid, text, door, "mqtt", call_id, revision);
      };
      hooks.node_alive = [this] {
        std::vector<std::pair<std::string, bool>> v;
        if (mesh)
          for (const auto& p : mesh->peers()) v.push_back({p.id, p.status != "dead"});
        return v;
      };
      hooks.emergency_active = [this] { return emergency_active; };
      hooks.visitor_langs = [this] {
        return std::vector<std::pair<std::string, std::string>>(visitor_lang_by_door.begin(),
                                                                visitor_lang_by_door.end());
      };
      bridge.reset(new HaBridge(*loop, std::move(hooks)));
    }


    {
      TelegramBridge::Hooks th;
      th.https = [this](const std::string& m, const std::string& u, const std::string& h,
                        Bytes body, std::function<void(int, std::string)> done) {
        httpsCall(m, u, h, body, std::move(done));
      };
      th.on_reply = [this](const std::string& rid, const std::string& text,
                           const std::string& door, const std::string& call_id) {
        auto active = active_calls.find(door);
        if (active == active_calls.end() || active->second.call_id != call_id) return false;
        return quickReply(rid, text, door, "telegram", call_id,
                          active->second.stage_revision);
      };
      th.get_event = [this](const std::string& o, uint64_t s) { return store.eventGet(o, s); };
      th.merge_notify = [this](const std::string& o, uint64_t s, const std::string& nj) {
        if (!events->mergeNotify(o, s, nj)) return;


        auto ev = store.eventGet(o, s);
        if (ev && mesh) mesh->broadcastEvent(*ev);
      };
      th.hlc_tick = [this] { return hlc->tick(); };
      th.fetch_snapshot = [this](const std::string& nid, std::function<void(Bytes)> cb) {
        if (mesh) {
          mesh->fetchSnapshot(nid, std::move(cb));
        } else {
          loop->post([cb] { cb(Bytes()); });
        }
      };
      th.text = [this](const std::string& key, const std::string& lang,
                       const std::vector<std::pair<std::string, std::string>>& args) {
        return textOnLoop(key, lang, args);
      };
      tg.reset(new TelegramBridge(*loop, store, std::move(th)));
    }

    if (!seedConfig()) {
      DB_LOGE(kTag, "startup configuration could not be persisted; refusing startup");
      return false;
    }
    mesh->start();
    reevalBridge();
    reevalTelegram();


    {
      SipCtl::Callbacks scb;
      scb.on_reg_state = [this](SipRegState st, const std::string& reason) {
        onSipReg(st, reason);
      };
      scb.on_call_state = [this](SipCallState st, const std::string& remote) {
        onSipCall(st, remote);
      };
      scb.on_dtmf = [this](char d) { onSipDtmf(d); };
      sipctl.reset(new SipCtl(*loop, std::move(scb)));
      sipctl->start(sipSettings());
      updateSipAllowedSources();
    }

    if (opts.http_port > 0) {
      httpd.reset(new Httpd(*loop));
      registerHttp();
      if (!httpd->start(opts.http_port)) {
        DB_LOGE(kTag, "httpd start failed on port " + std::to_string(opts.http_port));
        return false;
      }
      applyCameraSettings();
      applyVideoRotation();
      httpd->setVideoRotationProvider([this] { return effective_video_rotation.load(); });
    }

    motion.onMotion([this](int64_t /*ts_ms*/, double changed_pct) {
      loop->post([this, changed_pct] {
        if (!started || opts.role != "door_station" || opts.door.empty()) return;
        auto p = json::obj();
        json::set(p.get(), "changed_pct", changed_pct);
        events->append("motion", opts.door, node_id, json::dump(p.get()));
      });
    });
    applyMotionSettings();
    applyVideoRotation();  // Status exposes the effective rotation even without HTTP.
#ifdef _WIN32

    if (opts.role == "door_station") {
      CamCfg c = cameraCfg();


      encoder.reset(new EncoderWin([this](const uint8_t* p, size_t n, bool key, int64_t ts) {
        pushVideoTrack(p, n, key, ts);
      }));
      camera.reset(new CameraWin([this](RawFrame&& f) {
        {
          std::lock_guard<std::mutex> lk(motion_mu);
          motion.feed(f);
        }
        // Scan mode must see core-owned frames too; submit() only copies while scanning.
        qr_scanner.submit(f);
        if (encoder) encoder->feed(f);
        frame_bus.push(std::move(f));
      }));


      int tw = c.h264Enabled() ? c.h264_w : c.w;
      int th = c.h264Enabled() ? c.h264_h : c.h;
      camera->start(c.hint, tw, th);

      encoder_timer = loop->postEvery(5'000, [this] {
        if (!encoder) return;
        bool want = video_track.enabled() && video_track.subscriberCount() > 0;
        if (want && !encoder->running()) {
          CamCfg cc = cameraCfg();
          EncoderWin::Params p;
          p.fps = cc.h264_fps;
          p.bitrate_kbps = cc.h264_kbps;
          encoder->start(p);
        } else if (!want && encoder->running()) {
          encoder->stop();
        }
      });
    }
#endif

    display_timer = loop->postEvery(30'000, [this] { evalDisplay(); });
    // Battery polling, announcement expiry, daylight-saving drift, and time-source freshness all
    // share one slow tick; none of them needs finer resolution than a minute.
    minute_timer = loop->postEvery(60'000, [this] { minuteTick(); });
    // Retention is a slow background sweep; six hours is frequent enough for a daily policy and
    // cheap enough for the oldest hardware in the fleet.
    event_retention_timer = loop->postEvery(6 * 3600'000, [this] { pruneEventsTick(); });

    started = true;
    reapplyTimeSchedule();
    pollPowerState();
    pruneDoorNotices();
    refreshDerivedTzOffset();
    startNetMonitor();
    restoreActiveCalls(/*notify=*/false);
    restoreTerminalCalls();
    events->replayRecovered();
    restoreEmergency();
    notifyPendingRecoveries();
    snapshot_timer = loop->postEvery(2'000, [this] { refreshSnapshots(); });
    refreshSnapshots();
    evalDisplay(/*force=*/true);
    restoreEmergencyPresentation();
    prefetchAssets();
    pruneEventsTick();
    DB_LOGI(kTag, "node " + node_id.substr(0, 8) + " (" + opts.name + ") started");
    return true;
  }


  bool seedConfig() {
    if (opts.seed_default_config && !config->get("schema_version")) {
      std::vector<LwwMutation> defaults = {
          {"schema_version", "1", false},
          {"reply.display_ttl_s", "30", false},
          {"integrations.tz_offset_min", "540", false},
          // A fresh installation gets the IANA zone as the source of truth; the fixed offset
          // above stays in step as a derived compatibility value.
          {"time.zone", "\"Asia/Tokyo\"", false},
          {"time.ntp.enabled", "false", false},
          {"time.ntp.servers", "[\"ntp.nict.jp\",\"time.google.com\"]", false},
          {"time.ntp.interval_s", "86400", false},
          {"audio.volume.call", "80", false},
          {"audio.volume.sos", "100", false},
          {"audio.volume.idle", "60", false},
          {"emergency.trigger.mode", "\"slide\"", false},
          {"emergency.trigger.countdown_s", "3", false}};
      auto qr = [&](const char* id, const char* ja, const char* en, const char* zh, int order) {
        auto o = json::obj();
        cJSON* label = json::addObj(o.get(), "label");
        json::set(label, "ja", ja);
        json::set(label, "en", en);
        json::set(label, "zh", zh);
        json::setBool(o.get(), "speak", true);
        json::set(o.get(), "order", static_cast<int64_t>(order));
        defaults.push_back(
            {std::string("quick_replies.") + id, json::dump(o.get()), false});
      };
      qr("qr_away", "ただいま留守にしています", "We are away right now", "现在不在家", 1);
      qr("qr_no", "結構です", "Not interested", "不需要，谢谢", 2);
      qr("qr_wrong", "お間違いのようです", "Wrong address", "您可能找错地方了", 3);
      qr("qr_wait", "少々お待ちください", "One moment please", "请稍等", 4);

      defaults.insert(defaults.end(), {
          {"ui.languages", "[\"ja\",\"en\",\"zh\"]", false},
          {"ui.visitor_lang_revert_s", "60", false},
          {"ui.launch_sound", "\"title_display\"", false},
          {"ui.call_sound", "\"outdoor_call_alert\"", false},
          {"ui.call_sound_loop", "false", false},
          {"ui.button_sound", "\"button_click\"", false},
          {"ui.update_sound", "\"indoor_update\"", false},
          {"ui.ringtone", "\"school_chime\"", false},
          {"ui.call_flow", "\"purpose_first\"", false},
          {"ui.call_ttl_s", "60", false}});

      auto vp = [&](const char* id, const char* ja, const char* en, const char* zh,
                    const char* icon, int order) {
        auto o = json::obj();
        cJSON* label = json::addObj(o.get(), "label");
        json::set(label, "ja", ja);
        json::set(label, "en", en);
        json::set(label, "zh", zh);
        json::set(o.get(), "icon", icon);
        json::set(o.get(), "order", static_cast<int64_t>(order));
        defaults.push_back(
            {std::string("visit_purposes.") + id, json::dump(o.get()), false});
      };
      vp("p_visit", "訪問", "Visit", "访客", "🏠", 1);
      vp("p_delivery", "宅配便", "Delivery", "快递", "📦", 2);
      vp("p_mail", "郵便", "Mail", "邮件", "✉️", 3);
      vp("p_sales", "営業・集金", "Sales", "推销/收费", "💼", 4);
      vp("p_work", "検針・工事", "Utility", "检修/施工", "🔧", 5);
      vp("p_other", "その他", "Other", "其他", "❓", 6);
      config->mutate(defaults);
      if (!config->lastMutationCommitted()) return false;
    }
    // One-release migration: move legacy bearer values out of the replicated/exported CRDT.
    // New installations issue panel credentials explicitly from the authenticated Admin UI.
    if (!migrateRawPanelCredentials()) return false;
    // Seed the safety-friendly default once. A tombstone made by an administrator remains deleted
    // because the local meta marker prevents this migration from recreating the rule on restart.
    if (!store.metaGet("seed_sos_rules_v1")) {
      bool has_emergency_rule = false;
      cJSON* existing_rules = json::get(cfg.get(), "trigger_rules");
      cJSON* rule = nullptr;
      cJSON_ArrayForEach(rule, existing_rules) {
        const std::string t = json::getString(json::get(rule, "when"), "type");
        if (t == "emergency" || t == "emergency_cancel" || t == "emergency_on" ||
            t == "emergency_off")
          has_emergency_rule = true;
      }
      if (!has_emergency_rule) {
        const char* targets =
            "{\"roles\":\"all\",\"web_profiles\":\"all\"}";
        const std::string on = std::string("{\"enabled\":true,\"when\":{\"type\":") +
            "\"emergency_on\"},\"actions\":[{\"type\":\"device_alert\",\"targets\":" +
            targets +
            ",\"channels\":[\"in_app\",\"system_notification\",\"web_push\"],"
            "\"never_suppress\":true,\"presentation\":{\"visual\":true,"
            "\"sticky\":true,\"ttl_s\":0}},{\"type\":\"telegram\","
            "\"never_suppress\":true,\"households\":\"all\"}]}";
        const std::string off = std::string("{\"enabled\":true,\"when\":{\"type\":") +
            "\"emergency_off\"},\"actions\":[{\"type\":\"device_alert\",\"targets\":" +
            targets +
            ",\"channels\":[\"in_app\",\"system_notification\",\"web_push\"],"
            "\"never_suppress\":true,\"presentation\":{\"visual\":true,"
            "\"sticky\":false,\"ttl_s\":10}},{\"type\":\"telegram\","
            "\"never_suppress\":true,\"households\":\"all\"}]}";
        config->mutate({{"trigger_rules.r_sos_default_on", on, false},
                        {"trigger_rules.r_sos_default_off", off, false}});
        if (!config->lastMutationCommitted()) return false;
      }
      if (!store.metaSet("seed_sos_rules_v1", "1")) return false;
    }
    // The announcement presets are ordinary configuration an administrator edits or deletes; the
    // meta marker keeps a deletion deleted instead of reseeding it on every restart.
    if (!store.metaGet("seed_notice_presets_v1")) {
      if (!json::get(json::get(cfg.get(), "notice"), "presets")) {
        auto presets = json::arr();
        auto add = [&presets](const char* id, const char* text) {
          cJSON* entry = json::pushObj(presets.get());
          json::set(entry, "id", id);
          json::set(entry, "text", text);
        };
        add("np_absent", "不在です。荷物は玄関前へお願いします");
        add("np_back_door", "裏口へお回りください");
        add("np_construction", "工事中です。足元にご注意ください");
        config->mutate({{"notice.presets", json::dump(presets.get()), false}});
        if (!config->lastMutationCommitted()) return false;
      }
      if (!store.metaSet("seed_notice_presets_v1", "1")) return false;
    }

    // A missed call is worth a notification on the indoor surfaces only; a door station must not
    // alert the visitor. The rule is an ordinary trigger_rules entry, so the Admin rules tab can
    // disable or retarget it, and the meta marker keeps a deletion deleted across restarts.
    if (!store.metaGet("seed_missed_call_rule_v1")) {
      bool has_missed_rule = false;
      cJSON* existing_rules = json::get(cfg.get(), "trigger_rules");
      cJSON* rule = nullptr;
      cJSON_ArrayForEach(rule, existing_rules) {
        const std::string t = json::getString(json::get(rule, "when"), "type");
        if (t == "call_missed" || t == "missed_call") has_missed_rule = true;
      }
      if (!has_missed_rule) {
        const std::string missed =
            "{\"enabled\":true,\"when\":{\"type\":\"call_missed\"},"
            "\"actions\":[{\"type\":\"device_alert\",\"targets\":{\"roles\":"
            "[\"indoor_panel\"],\"web_profiles\":\"all\"},"
            "\"channels\":[\"in_app\",\"system_notification\",\"web_push\"],"
            "\"presentation\":{\"visual\":true,\"sticky\":false,\"ttl_s\":30}}]}";
        config->mutate({{"trigger_rules.r_missed_call_default", missed, false}});
        if (!config->lastMutationCommitted()) return false;
      }
      if (!store.metaSet("seed_missed_call_rule_v1", "1")) return false;
    }

    // The boot identity is the operational source of truth used by the shell and mesh. Keep the
    // replicated self record aligned at leaf granularity: older Admin versions wrote both a
    // devices.<id> object and later .name/.role/.door leaves, so replacing only the parent object
    // cannot override a stale empty door leaf. Leaf writes also preserve unknown local settings.
    const std::string key = "devices." + node_id;
    const cJSON* current = cfgAt(key);
    std::vector<LwwMutation> identity;
    auto add_identity = [&](const char* field, const std::string& value) {
      if (json::getString(current, field) == value) return;
      auto encoded = json::Doc(cJSON_CreateString(value.c_str()));
      identity.push_back({key + "." + field, json::dump(encoded.get()), false});
    };
    add_identity("name", opts.name);
    add_identity("role", opts.role);
    // An indoor panel deliberately has no assigned door; persisting the empty leaf clears any
    // stale door-station assignment when an administrator changes the first-run role.
    add_identity("door", opts.role == "door_station" ? opts.door : "");
    if (!identity.empty()) {
      config->mutate(identity);
      if (!config->lastMutationCommitted()) return false;
    }
    return reclaimSeededDoorEntries() && ensureOwnDoorEntry();
  }

  // An entry is still exactly what this node seeded: nothing but the label it wrote, and that
  // label unchanged. Anything else -- a building, a notice, an unlock setting, a rename -- is an
  // administrator's work, and a door an administrator has adopted outlives the device that
  // happened to create it.
  bool seededDoorIsPristine(const cJSON* entry) const {
    if (!cJSON_IsObject(entry)) return false;
    const cJSON* field = nullptr;
    cJSON_ArrayForEach(field, entry) {
      const std::string name = field->string ? field->string : "";
      if (name != "label" && name != "seeded_by" && name != "seeded_label") return false;
    }
    const std::string seeded_label = json::getString(entry, "seeded_label");
    const cJSON* label = json::get(entry, "label");
    if (!cJSON_IsObject(label)) return seeded_label.empty();
    const cJSON* text = nullptr;
    cJSON_ArrayForEach(text, label) {
      if (!cJSON_IsString(text) || seeded_label != text->valuestring) return false;
    }
    return true;
  }

  // A door station that changes role, or moves to a different door, leaves behind the entry it
  // created for the door it no longer serves. Left alone it becomes a ghost tile on every
  // dashboard: a door with a name, permanently offline, that nobody serves.
  bool reclaimSeededDoorEntries() {
    if (!mesh || !mesh->isPaired()) return true;
    const std::string still_serving =
        opts.role == "door_station" ? opts.door : std::string();
    std::vector<LwwMutation> stale;
    const cJSON* doors = json::get(cfg.get(), "doors");
    const cJSON* door = nullptr;
    cJSON_ArrayForEach(door, doors) {
      if (!door->string) continue;
      const std::string id = door->string;
      if (json::getString(door, "seeded_by") != node_id) continue;
      if (id == still_serving) continue;
      if (!seededDoorIsPristine(door)) {
        DB_LOGI(kTag, "keeping door " + id + ": an administrator has edited it");
        continue;
      }
      stale.push_back({"doors." + id, "", true});
    }
    if (stale.empty()) return true;
    config->mutate(stale);
    if (!config->lastMutationCommitted()) return false;
    for (const auto& mutation : stale)
      DB_LOGI(kTag, "removed " + mutation.key + ": this node no longer serves that door");
    return true;
  }

  // A cluster founded by a door station used to end up with devices.<id>.door pointing at a door
  // that had no doors.<id> entry at all. Everything keyed by door -- announcements, unlock
  // visibility, tiles -- then had nothing to target, and only the cluster-wide notice worked.
  //
  // The entry is created only when it is absent, so an administrator's labels are never
  // overwritten; renaming or reassigning the door afterwards is the Admin doors tab's job.
  bool ensureOwnDoorEntry() {
    if (opts.role != "door_station" || opts.door.empty()) return true;
    // Only a paired node writes cluster configuration: an unpaired device would seed a door into
    // a cluster it is about to join and then win the merge with a name nobody chose.
    if (!mesh || !mesh->isPaired()) return true;
    const std::string key = "doors." + opts.door;
    if (cfgAt(key)) return true;
    auto entry = json::obj();
    cJSON* label = json::addObj(entry.get(), "label");
    // The device name is the only thing the operator has actually chosen at first run; the door
    // id is a generated fallback and reads like one.
    const std::string name = opts.name.empty() ? opts.door : opts.name;
    for (const char* lang : {"ja", "en", "zh"}) json::set(label, lang, name);
    // Provenance, so this node can take back exactly what it created and nothing else. Both
    // fields are needed: seeded_by says who may reclaim it, and seeded_label says what was
    // written, so a rename by an administrator is recognisable as an edit.
    json::set(entry.get(), "seeded_by", node_id);
    json::set(entry.get(), "seeded_label", name);
    config->mutate({{key, json::dump(entry.get()), false}});
    if (!config->lastMutationCommitted()) return false;
    DB_LOGI(kTag, "created the missing door entry " + key + " for this door station");
    return true;
  }

  // Seconds the incoming-call page counts down before an indoor panel returns to its home page.
  // A per-device override wins, exactly like volume and appearance.
  int callReturnSeconds() {
    const cJSON* device = cfgAt("devices." + node_id + ".local.call");
    const cJSON* seconds = json::get(device, "return_s");
    if (!cJSON_IsNumber(seconds))
      seconds = json::get(json::get(json::get(cfg.get(), "call"), "indoor"), "return_s");
    int64_t value = cJSON_IsNumber(seconds) ? static_cast<int64_t>(seconds->valuedouble) : 60;
    if (value < 5) value = 5;
    if (value > 600) value = 600;
    return static_cast<int>(value);
  }

  int64_t callTtlMs() const {
    int64_t seconds = json::getInt(json::get(cfg.get(), "ui"), "call_ttl_s", 60);
    seconds = std::max<int64_t>(10, std::min<int64_t>(seconds, 300));
    return seconds * 1000;
  }

  static std::string eventCallId(const EventRecord& ev) {
    auto p = json::parse(ev.payload_json.empty() ? "{}" : ev.payload_json);
    std::string id = p ? json::getString(p.get(), "call_id") : "";
    if (id.empty() && ev.type == "press")
      id = ev.origin + ":" + std::to_string(ev.seq);  // deterministic legacy-event identity
    return id;
  }

  static bool validDialogId(const std::string& id) {
    if (id.size() != 32) return false;
    return std::all_of(id.begin(), id.end(), [](unsigned char c) {
      return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
    });
  }

  std::string webDialogOwner(const std::string& dialog_id) const {
    if (!validDialogId(dialog_id)) return "";
    const std::string material = node_id + ":" + dialog_id;
    return node_id + ":web:" +
        sha256Hex(reinterpret_cast<const uint8_t*>(material.data()), material.size()).substr(0, 24);
  }

  bool localWebDialogOwner(const std::string& owner) const {
    return owner.rfind(node_id + ":web:", 0) == 0;
  }

  static std::string dialogOwnerNode(const std::string& owner) {
    const size_t marker = owner.find(":web:");
    return marker == std::string::npos ? owner : owner.substr(0, marker);
  }

  static int64_t callWriteRetryDelay(unsigned step) {
    static constexpr int64_t delays_ms[] = {2'000, 5'000, 10'000, 30'000, 60'000};
    return delays_ms[std::min<unsigned>(step, 4)];
  }

  void finishPendingLifecycle(const std::string& call_id) {
    auto pending = pending_lifecycles.find(call_id);
    if (pending == pending_lifecycles.end()) return;
    if (pending->second.retry_timer) loop->cancel(pending->second.retry_timer);
    pending_lifecycles.erase(pending);
  }

  void abandonPendingLifecycle(const std::string& call_id) {
    std::string door;
    auto pending = pending_lifecycles.find(call_id);
    if (pending != pending_lifecycles.end()) door = pending->second.door;
    finishPendingLifecycle(call_id);

    auto active = active_calls.find(door);
    if (active == active_calls.end() || active->second.call_id != call_id) return;
    active->second.local_sip_established = false;
    if (sip_call_id == call_id) {
      if (sipctl) sipctl->hangupOwned(call_id);
      sip_call_id.clear();
    }
    if (active->second.state == "ringing") scheduleCallTimeout(active->second);
  }

  bool pendingLifecycleIdentityValid(const PendingLifecycle& pending) const {
    auto active = active_calls.find(pending.door);
    if (active == active_calls.end() || active->second.call_id != pending.call_id ||
        active->second.stage_revision != pending.stage_revision)
      return false;
    if (active->second.state == "ringing") return pending.answer_pending;
    return active->second.state == "in_call" &&
           active->second.dialog_owner == pending.owner;
  }

  bool reservePendingLifecycle(const std::string& call_id) {
    if (pending_lifecycles.count(call_id)) return true;
    for (auto it = pending_lifecycles.begin(); it != pending_lifecycles.end();) {
      if (pendingLifecycleIdentityValid(it->second)) {
        ++it;
        continue;
      }
      if (it->second.retry_timer) loop->cancel(it->second.retry_timer);
      it = pending_lifecycles.erase(it);
    }
    if (pending_lifecycles.size() >= kMaxPendingLifecycles) {
      DB_LOGE(kTag, "call lifecycle retry queue is full");
      return false;
    }
    PendingLifecycle pending;
    pending.call_id = call_id;
    pending.order = ++pending_lifecycle_order;
    pending_lifecycles.emplace(call_id, std::move(pending));
    return true;
  }

  void schedulePendingLifecycleRetry(const std::string& call_id) {
    auto pending = pending_lifecycles.find(call_id);
    if (pending == pending_lifecycles.end() || pending->second.retry_timer) return;
    const int64_t delay = callWriteRetryDelay(pending->second.retry_step);
    if (pending->second.retry_step < 4) ++pending->second.retry_step;
    pending->second.retry_timer = loop->postDelayed(delay, [this, call_id] {
      auto current = pending_lifecycles.find(call_id);
      if (current == pending_lifecycles.end()) return;
      current->second.retry_timer = 0;
      flushPendingLifecycle(call_id);
    });
  }

  void queuePendingAnswer(const ActiveCall& call, const std::string& owner) {
    if (!reservePendingLifecycle(call.call_id)) return;
    PendingLifecycle& pending = pending_lifecycles[call.call_id];
    pending.call_id = call.call_id;
    pending.door = call.door;
    pending.owner = owner;
    pending.stage_revision = call.stage_revision;
    pending.answer_pending = true;
    auto active = active_calls.find(call.door);
    if (active != active_calls.end() && active->second.call_id == call.call_id) {
      active->second.local_sip_established = true;
      if (active->second.timeout_timer) loop->cancel(active->second.timeout_timer);
      active->second.timeout_timer = 0;
      door_calling_until.erase(call.door);
    }
    schedulePendingLifecycleRetry(call.call_id);
  }

  void queuePendingEnd(const ActiveCall& call, const std::string& owner,
                       const std::string& reason) {
    if (!reservePendingLifecycle(call.call_id)) return;
    PendingLifecycle& pending = pending_lifecycles[call.call_id];
    pending.call_id = call.call_id;
    pending.door = call.door;
    pending.owner = owner;
    pending.stage_revision = call.stage_revision;
    pending.end_pending = true;
    pending.end_reason = reason.empty() ? "sip_ended" : reason.substr(0, 64);
    schedulePendingLifecycleRetry(call.call_id);
  }

  bool callRecoveryTakeoverAuthority(const ActiveCall& call) const {
    if (!mesh || call.state != "in_call" || call.dialog_owner.empty()) return false;
    const std::string owner_node = dialogOwnerNode(call.dialog_owner);
    if (owner_node.empty() || owner_node == node_id) return false;

    bool owner_known_dead = false;
    std::string authority = node_id;
    for (const auto& peer : mesh->peers()) {
      if (peer.id.empty()) continue;
      if (peer.id == owner_node) owner_known_dead = peer.status == "dead";
      if (peer.status != "dead" && peer.id < authority) authority = peer.id;
    }
    return owner_known_dead && authority == node_id;
  }

  void clearRecoveryLease(ActiveCall& call) {
    if (call.recovery_timer) loop->cancel(call.recovery_timer);
    call.recovery_timer = 0;
    call.recovery_deadline_mono = 0;
    call.recovery_notified = false;
    call.recovery_retry_step = 0;
    call.recovery_reason.clear();
    call.recovery_kind = RecoveryLeaseKind::None;
  }

  void armRecoveryCancellation(ActiveCall& call, RecoveryLeaseKind kind,
                               const std::string& reason, int64_t delay,
                               bool reset_retry) {
    if (call.recovery_timer) loop->cancel(call.recovery_timer);
    if (reset_retry) call.recovery_retry_step = 0;
    call.recovery_kind = kind;
    call.recovery_reason = reason;
    call.recovery_deadline_mono = clock->monoMs() + delay;
    const std::string door = call.door;
    const std::string call_id = call.call_id;
    const std::string dialog_owner = call.dialog_owner;
    call.recovery_timer = loop->postDelayed(delay, [this, door, call_id, dialog_owner, kind] {
      auto active = active_calls.find(door);
      if (active == active_calls.end() || active->second.call_id != call_id ||
          active->second.dialog_owner != dialog_owner || active->second.recovery_kind != kind)
        return;
      if (kind == RecoveryLeaseKind::DeadOwnerTakeover &&
          !callRecoveryTakeoverAuthority(active->second)) {
        clearRecoveryLease(active->second);
        return;
      }
      active->second.recovery_timer = 0;
      active->second.recovery_deadline_mono = 0;
      const std::string retry_reason = active->second.recovery_reason;
      if (doCancelCall(door, call_id, retry_reason)) return;

      const int64_t retry_delay = callWriteRetryDelay(active->second.recovery_retry_step);
      if (active->second.recovery_retry_step < 4)
        ++active->second.recovery_retry_step;
      armRecoveryCancellation(active->second, kind, retry_reason, retry_delay,
                              /*reset_retry=*/false);
    });
  }

  void rearmCallRecoveryTakeovers() {
    for (auto& entry : active_calls) {
      ActiveCall& call = entry.second;
      const bool should_take_over = callRecoveryTakeoverAuthority(call);
      if (call.recovery_kind == RecoveryLeaseKind::DeadOwnerTakeover &&
          !should_take_over) {
        clearRecoveryLease(call);
        continue;
      }
      if (!should_take_over || call.recovery_timer != 0) continue;
      armRecoveryCancellation(call, RecoveryLeaseKind::DeadOwnerTakeover,
                              "recovery_timeout", 10'000, /*reset_retry=*/true);
    }
  }

  void cancelWebDialogLease(const std::string& call_id) {
    auto timer = web_dialog_timers.find(call_id);
    if (timer == web_dialog_timers.end()) return;
    if (timer->second.timer) loop->cancel(timer->second.timer);
    web_dialog_timers.erase(timer);
  }

  void armWebDialogLeaseTimer(const std::string& door, const std::string& call_id,
                              const std::string& owner, int64_t delay,
                              bool reset_retry) {
    WebDialogLease& lease = web_dialog_timers[call_id];
    if (lease.timer) loop->cancel(lease.timer);
    lease.door = door;
    lease.owner = owner;
    if (reset_retry) lease.retry_step = 0;
    lease.timer = loop->postDelayed(delay, [this, door, call_id, owner] {
      auto lease_it = web_dialog_timers.find(call_id);
      if (lease_it == web_dialog_timers.end() || lease_it->second.door != door ||
          lease_it->second.owner != owner)
        return;
      lease_it->second.timer = 0;
      auto active = active_calls.find(door);
      if (active == active_calls.end() || active->second.call_id != call_id ||
          active->second.dialog_owner != owner || active->second.state != "in_call") {
        web_dialog_timers.erase(lease_it);
        return;
      }
      if (doCancelCall(door, call_id, "recovery_timeout")) {
        cancelWebDialogLease(call_id);
        return;
      }
      lease_it = web_dialog_timers.find(call_id);
      if (lease_it == web_dialog_timers.end()) return;
      const int64_t retry_delay = callWriteRetryDelay(lease_it->second.retry_step);
      if (lease_it->second.retry_step < 4) ++lease_it->second.retry_step;
      armWebDialogLeaseTimer(door, call_id, owner, retry_delay, /*reset_retry=*/false);
    });
  }

  void armWebDialogLease(const std::string& door, const std::string& call_id,
                         const std::string& owner) {
    cancelWebDialogLease(call_id);
    armWebDialogLeaseTimer(door, call_id, owner, 10'000, /*reset_retry=*/true);
  }

  void rememberCancelled(const std::string& call_id) {
    if (call_id.empty() || !cancelled_call_ids.insert(call_id).second) return;
    cancelled_call_order.push_back(call_id);
    while (cancelled_call_order.size() > 256) {
      cancelled_call_ids.erase(cancelled_call_order.front());
      cancelled_call_order.pop_front();
    }
  }

  void pruneTerminalCalls() {
    const int64_t now_mono = clock->monoMs();
    for (auto it = terminal_calls.begin(); it != terminal_calls.end();) {
      if (it->second.visible_until_mono <= now_mono)
        it = terminal_calls.erase(it);
      else
        ++it;
    }
    while (terminal_calls.size() > kMaxPanelTerminalCalls) {
      auto oldest = std::min_element(
          terminal_calls.begin(), terminal_calls.end(), [](const auto& a, const auto& b) {
            return a.second.order < b.second.order;
          });
      if (oldest == terminal_calls.end()) break;
      terminal_calls.erase(oldest);
    }
  }

  void rememberTerminalCall(const EventRecord& ev) {
    if (ev.type != "call_cancelled" && ev.type != "call_ended" && ev.type != "reply") return;
    const std::string call_id = eventCallId(ev);
    if (call_id.empty() || ev.door.empty()) return;
    auto projection = store.callProjection(call_id);
    const std::string projected_state = ev.type == "call_cancelled" ? "cancelled" : "ended";
    if (!projection || projection->door != ev.door || projection->state != projected_state ||
        projection->updated_hlc != ev.hlc)
      return;

    int64_t terminal_wall_ms = ev.wall_ms;
    if (terminal_wall_ms <= 0)
      HlcClock::parse(ev.hlc, &terminal_wall_ms, nullptr, nullptr);
    if (terminal_wall_ms <= 0) terminal_wall_ms = clock->wallMs();
    const int64_t age_ms = std::max<int64_t>(0, clock->wallMs() - terminal_wall_ms);
    if (age_ms >= kPanelTerminalCallTtlMs) return;

    TerminalCall terminal;
    terminal.call_id = projection->call_id;
    terminal.door = projection->door;
    terminal.purpose = projection->purpose;
    terminal.reason = projection->terminal_reason;
    terminal.state = ev.type == "call_ended" || ev.type == "reply"
        ? "ended"
        : (terminal.reason == "timeout" ? "expired" : "cancelled");
    terminal.dialog_owner = projection->dialog_owner;
    terminal.stage_revision = projection->stage_revision;
    terminal.expires_wall_ms = projection->expires_wall_ms;
    terminal.terminal_wall_ms = terminal_wall_ms;
    terminal.visible_until_mono =
        clock->monoMs() + (kPanelTerminalCallTtlMs - age_ms);
    terminal.order = ++terminal_call_order;
    terminal_calls[terminal.door] = std::move(terminal);
    pruneTerminalCalls();
  }

  void restoreTerminalCalls() {
    terminal_calls.clear();
    for (const auto& ev : store.recentEvents(kMaxPanelTerminalCalls)) {
      if (ev.type != "call_cancelled" && ev.type != "call_ended" && ev.type != "reply")
        continue;
      if (active_calls.count(ev.door) || terminal_calls.count(ev.door)) continue;
      rememberTerminalCall(ev);
    }
  }

  void clearActiveCall(const std::string& door, const std::string& call_id = "") {
    auto it = active_calls.find(door);
    if (it == active_calls.end() || (!call_id.empty() && it->second.call_id != call_id)) return;
    if (it->second.timeout_timer) loop->cancel(it->second.timeout_timer);
    if (it->second.recovery_timer) loop->cancel(it->second.recovery_timer);
    finishPendingLifecycle(it->second.call_id);
    cancelWebDialogLease(it->second.call_id);
    if (sip_call_id == it->second.call_id) sip_call_id.clear();
    active_calls.erase(it);
    door_calling_until.erase(door);
  }

  void armCallTimeout(ActiveCall& call, int64_t delay, bool reset_retry) {
    if (call.timeout_timer) loop->cancel(call.timeout_timer);
    if (reset_retry) call.timeout_retry_step = 0;
    const std::string door = call.door;
    const std::string id = call.call_id;
    const int revision = call.stage_revision;
    call.timeout_timer = loop->postDelayed(delay, [this, door, id, revision] {
      auto active = active_calls.find(door);
      if (active == active_calls.end() || active->second.call_id != id ||
          active->second.stage_revision != revision)
        return;
      active->second.timeout_timer = 0;
      if (active->second.state != "ringing" || active->second.local_sip_established ||
          !isCallTimeoutAuthority(active->second))
        return;
      if (doCancelCall(door, id, "timeout")) return;
      const int64_t retry_delay = callWriteRetryDelay(active->second.timeout_retry_step);
      if (active->second.timeout_retry_step < 4) ++active->second.timeout_retry_step;
      armCallTimeout(active->second, retry_delay, /*reset_retry=*/false);
    });
  }

  void scheduleCallTimeout(ActiveCall& call) {
    if (call.timeout_timer) loop->cancel(call.timeout_timer);
    call.timeout_timer = 0;
    if (!isCallTimeoutAuthority(call) || call.state == "in_call" ||
        call.local_sip_established)
      return;
    armCallTimeout(call, std::max<int64_t>(0, call.expires_wall_ms - hlc->correctedWallMs()),
                   /*reset_retry=*/true);
  }

  bool isCallTimeoutAuthority(const ActiveCall& call) const {
    if (call.origin == node_id) return true;
    if (opts.role != "door_station" || opts.door != call.door) return false;

    bool origin_alive = false;
    if (mesh) {
      for (const auto& peer : mesh->peers()) {
        if (peer.id == call.origin && peer.status != "dead") {
          origin_alive = true;
          break;
        }
      }
    }
    if (origin_alive) return false;

    std::string authority = node_id;
    const cJSON* devices = json::get(cfg.get(), "devices");
    const cJSON* device = nullptr;
    cJSON_ArrayForEach(device, devices) {
      if (!device->string || json::getString(device, "role") != "door_station" ||
          json::getString(device, "door") != call.door)
        continue;
      bool alive = std::string(device->string) == node_id;
      if (!alive && mesh) {
        for (const auto& peer : mesh->peers()) {
          if (peer.id == device->string && peer.status != "dead") {
            alive = true;
            break;
          }
        }
      }
      if (alive && std::string(device->string) < authority) authority = device->string;
    }
    return authority == node_id;
  }

  void rearmCallTimeouts() {
    for (auto& entry : active_calls) scheduleCallTimeout(entry.second);
  }

  void syncLiveCallProjection(const Store::CallProjection& projection) {
    auto current = active_calls.find(projection.door);
    const bool dialog_changed = current == active_calls.end() ||
        current->second.state != "in_call" ||
        current->second.dialog_owner != projection.dialog_owner;
    if (current != active_calls.end()) {
      if (current->second.timeout_timer) loop->cancel(current->second.timeout_timer);
      current->second.timeout_timer = 0;
      if (projection.state != "in_call" || dialog_changed) {
        clearRecoveryLease(current->second);
        cancelWebDialogLease(current->second.call_id);
      }
    }

    const bool local_sip_is_winner =
        projection.state == "in_call" && projection.dialog_owner == node_id;
    if (sip_call_id == projection.call_id && !local_sip_is_winner) {
      if (sipctl) sipctl->hangupOwned(projection.call_id);
      sip_call_id.clear();
    }

    ActiveCall next;
    if (current != active_calls.end()) next = current->second;
    next.call_id = projection.call_id;
    next.door = projection.door;
    next.origin = projection.origin;
    next.dialog_owner = projection.dialog_owner;
    next.purpose = projection.purpose;
    next.state = projection.state;
    next.stage_revision = projection.stage_revision;
    next.expires_wall_ms = projection.expires_wall_ms;
    next.local_sip_established = local_sip_is_winner;
    active_calls[projection.door] = next;

    auto pending = pending_lifecycles.find(projection.call_id);
    if (pending != pending_lifecycles.end() &&
        !pendingLifecycleIdentityValid(pending->second))
      finishPendingLifecycle(projection.call_id);

    if (projection.state == "ringing") {
      const int64_t remaining =
          std::max<int64_t>(0, projection.expires_wall_ms - hlc->correctedWallMs());
      door_calling_until[projection.door] = clock->monoMs() + remaining;
      scheduleCallTimeout(active_calls[projection.door]);
    } else {
      door_calling_until.erase(projection.door);
    }
    rearmCallRecoveryTakeovers();
  }

  void applyCallEvent(const EventRecord& ev) {
    auto p = json::parse(ev.payload_json.empty() ? "{}" : ev.payload_json);
    if (ev.type == "press") {
      const std::string call_id = eventCallId(ev);
      auto restored = active_calls.find(ev.door);
      // A callback can be replayed after its side effects completed but before its dispatch ack.
      // Preserve the recovery lease reconstructed from the durable projection for the same call.
      if (restored != active_calls.end() && restored->second.call_id == call_id) return;
      ActiveCall call;
      call.call_id = call_id;
      call.door = ev.door;
      call.origin = ev.origin;
      call.purpose = p ? json::getString(p.get(), "purpose") : "";
      call.stage_revision = static_cast<int>(p ? json::getInt(p.get(), "stage_revision", 0) : 0);
      call.expires_wall_ms = p ? json::getInt(p.get(), "expires_at_ms", ev.wall_ms + callTtlMs())
                               : ev.wall_ms + callTtlMs();
      clearActiveCall(ev.door);
      terminal_calls.erase(ev.door);
      active_calls[ev.door] = call;
      const int64_t remaining = std::max<int64_t>(0, call.expires_wall_ms - hlc->correctedWallMs());
      door_calling_until[ev.door] = clock->monoMs() + remaining;
      scheduleCallTimeout(active_calls[ev.door]);
      return;
    }
    if (ev.type == "purpose_selected") {
      const std::string id = p ? json::getString(p.get(), "call_id") : "";
      auto projection = store.callProjection(id);
      if (!projection || projection->door != ev.door || projection->state != "ringing" ||
          projection->updated_hlc != ev.hlc)
        return;
      syncLiveCallProjection(*projection);
      return;
    }
    if (ev.type == "call_answered") {
      const std::string id = p ? json::getString(p.get(), "call_id") : "";
      auto projection = store.callProjection(id);
      if (!projection || projection->door != ev.door || projection->state != "in_call" ||
          projection->answered_hlc != ev.hlc)
        return;
      syncLiveCallProjection(*projection);
      return;
    }
    if (ev.type == "call_ended") {
      const std::string id = p ? json::getString(p.get(), "call_id") : "";
      auto it = active_calls.find(ev.door);
      if (!id.empty() && it != active_calls.end() && it->second.call_id == id) {
        const int revision = static_cast<int>(
            p ? json::getInt(p.get(), "stage_revision", -1) : -1);
        if (revision != it->second.stage_revision) return;
        if (sipctl && sip_call_id == id) sipctl->hangupOwned(id);
        clearActiveCall(ev.door, id);
      }
      rememberTerminalCall(ev);
      if (opts.role == "door_station" && (opts.door.empty() || opts.door == ev.door))
        presentReply(p.get(), ev.door, eventIdentity(ev));
      return;
    }
    if (ev.type == "call_cancelled") {
      const std::string id = p ? json::getString(p.get(), "call_id") : "";
      if (!id.empty()) rememberCancelled(id);
      auto it = active_calls.find(ev.door);
      if (it != active_calls.end() && (id.empty() || it->second.call_id == id)) {
        if (sipctl && sip_call_id == it->second.call_id)
          sipctl->hangupOwned(it->second.call_id);
        clearActiveCall(ev.door, id);
      }
      rememberTerminalCall(ev);
    }
  }

  void restoreActiveCalls(bool notify = true) {
    for (const auto& projection : store.activeCallProjections()) {
      ActiveCall call;
      call.call_id = projection.call_id;
      call.door = projection.door;
      call.origin = projection.origin;
      call.dialog_owner = projection.dialog_owner;
      call.purpose = projection.purpose;
      call.state = projection.state;
      call.stage_revision = projection.stage_revision;
      call.expires_wall_ms = projection.expires_wall_ms;
      active_calls[call.door] = call;
      if (call.state == "ringing") {
        door_calling_until[call.door] =
            clock->monoMs() +
            std::max<int64_t>(0, call.expires_wall_ms - hlc->correctedWallMs());
        scheduleCallTimeout(active_calls[call.door]);
      }
      const bool owns_recovery = call.state == "in_call"
          ? (call.dialog_owner == node_id || localWebDialogOwner(call.dialog_owner))
          : call.origin == node_id;
      if (owns_recovery) {
        armRecoveryCancellation(active_calls[call.door], RecoveryLeaseKind::LocalProcess,
                                "recovery_timeout", 10'000, /*reset_retry=*/true);
      }
    }
    rearmCallRecoveryTakeovers();
    if (notify) notifyPendingRecoveries();
  }

  void notifyPendingRecoveries() {
    if (!selfFeature("runtime_recovery_v1")) return;
    for (auto& entry : active_calls) {
      ActiveCall& call = entry.second;
      if (!call.recovery_timer || call.recovery_notified ||
          call.recovery_kind != RecoveryLeaseKind::LocalProcess)
        continue;
      auto event = json::obj();
      json::set(event.get(), "t", "call_recovery_required");
      json::set(event.get(), "call_id", call.call_id);
      json::set(event.get(), "door", call.door);
      json::set(event.get(), "origin", call.origin);
      if (!call.dialog_owner.empty())
        json::set(event.get(), "dialog_owner", call.dialog_owner);
      json::set(event.get(), "state", call.state);
      json::set(event.get(), "stage_revision", static_cast<int64_t>(call.stage_revision));
      json::set(event.get(), "expires_at_ms", call.expires_wall_ms);
      json::set(event.get(), "deadline_ms",
                std::max<int64_t>(0, call.recovery_deadline_mono - clock->monoMs()));
      call.recovery_notified = true;
      uiNotify(json::dump(event.get()));
    }
  }

  bool resolveCallRecovery(const std::string& call_id, bool restored) {
    for (auto& kv : active_calls) {
      auto& call = kv.second;
      if (call.call_id != call_id || call.recovery_timer == 0 ||
          call.recovery_kind != RecoveryLeaseKind::LocalProcess)
        continue;
      if (restored) {
        clearRecoveryLease(call);
        return true;
      }
      if (call.recovery_timer) loop->cancel(call.recovery_timer);
      call.recovery_timer = 0;
      call.recovery_deadline_mono = 0;
      call.recovery_reason = "recovery_failed";
      if (doCancelCall(call.door, call.call_id, call.recovery_reason)) return true;
      const int64_t retry_delay = callWriteRetryDelay(call.recovery_retry_step);
      if (call.recovery_retry_step < 4) ++call.recovery_retry_step;
      armRecoveryCancellation(call, RecoveryLeaseKind::LocalProcess, call.recovery_reason,
                              retry_delay, /*reset_retry=*/false);
      return true;
    }
    return false;
  }


  void onEvent(const EventRecord& ev, bool is_local) {
    bool emergency_transition = true;
    bool emergency_winner = true;
    if (is_local && mesh) mesh->broadcastEvent(ev);
    if (ev.type == "press") {
      const std::string id = eventCallId(ev);
      auto projection = store.callProjection(id);
      if (!projection || projection->state != "ringing") return;
    }
    if (ev.type == "purpose_selected") {
      auto payload = json::parse(ev.payload_json.empty() ? "{}" : ev.payload_json);
      const std::string id = payload ? json::getString(payload.get(), "call_id") : "";
      const int revision = static_cast<int>(
          payload ? json::getInt(payload.get(), "stage_revision", -1) : -1);
      auto projection = store.callProjection(id);
      if (id.empty() || !projection || projection->door != ev.door ||
          projection->state != "ringing" || projection->stage_revision != revision ||
          projection->updated_hlc != ev.hlc)
        return;
    }
    if (ev.type == "call_cancelled") {
      const std::string id = eventCallId(ev);
      auto projection = store.callProjection(id);
      if (!projection || projection->state != "cancelled" ||
          projection->updated_hlc != ev.hlc)
        return;
    }
    if (ev.type == "call_answered" || ev.type == "call_ended") {
      const std::string id = eventCallId(ev);
      auto projection = store.callProjection(id);
      const std::string expected = ev.type == "call_answered" ? "in_call" : "ended";
      if (!projection || projection->state != expected ||
          (ev.type == "call_answered" && projection->answered_hlc != ev.hlc) ||
          (ev.type == "call_ended" && projection->updated_hlc != ev.hlc))
        return;
    }
    if (ev.type == "reply") {
      auto payload = json::parse(ev.payload_json.empty() ? "{}" : ev.payload_json);
      const std::string id = payload ? json::getString(payload.get(), "call_id") : "";
      if (!id.empty()) {
        const int revision = static_cast<int>(
            payload ? json::getInt(payload.get(), "stage_revision", -1) : -1);
        auto projection = store.callProjection(id);
        if (!projection || projection->door != ev.door || projection->state != "ended" ||
            projection->terminal_reason != "reply" ||
            projection->stage_revision != revision || projection->updated_hlc != ev.hlc)
          return;
      }
    }
    if (ev.type == "press" || ev.type == "purpose_selected" ||
        ev.type == "call_answered" || ev.type == "call_ended" ||
        ev.type == "call_cancelled")
      applyCallEvent(ev);
    // The projection above is the call log and is always applied. Everything below this line is
    // presentation, and replicated history must not re-enact any of it.
    const bool live = callEventIsLive(ev);
    if (!live) {
      if (callLifecycleType(ev.type)) notifyCallLogChanged();
      return;
    }
    if (ev.type == "press") {
      last_press_door = ev.door;
      last_press_by_door[ev.door] = {ev.origin, ev.seq};

      if (visitor_lang_revert_timer.count(ev.door)) armVisitorRevert(ev.door);
    } else if (ev.type == "reply") {
      auto p = json::parse(ev.payload_json);
      if (p) {
        last_reply_text = json::getString(p.get(), "text");
        last_reply_ts = hlc->correctedWallMs();
      }
      const std::string id = p ? json::getString(p.get(), "call_id") : "";
      auto active = active_calls.find(ev.door);
      if (!id.empty() && active != active_calls.end() && active->second.call_id == id &&
          active->second.state == "ringing") {
        auto projection = store.callProjection(id);
        if (projection && projection->state == "ended" &&
            projection->terminal_reason == "reply" && projection->updated_hlc == ev.hlc)
          clearActiveCall(ev.door, id);
      }
      rememberTerminalCall(ev);
    } else if (ev.type == "emergency" || ev.type == "emergency_cancel") {
      emergency_winner = isCurrentEmergencyWinner(ev);
      emergency_transition = emergency_winner && applyEmergencyEvent(ev);
    } else if (ev.type == "visitor_lang") {

      applyVisitorLangEvent(ev, is_local);
    }
    {
      auto o = json::obj();
      json::set(o.get(), "schema_version", static_cast<int64_t>(2));
      json::set(o.get(), "t", "event");
      json::set(o.get(), "type", ev.type);
      json::set(o.get(), "event_id", eventIdentity(ev));
      json::set(o.get(), "origin", ev.origin);
      json::set(o.get(), "seq", static_cast<int64_t>(ev.seq));
      json::set(o.get(), "door", ev.door);
      json::set(o.get(), "device", ev.device);
      if (ev.type == "press" || ev.type == "purpose_selected" ||
          ev.type == "call_answered" || ev.type == "call_ended" ||
          ev.type == "call_cancelled" || ev.type == "reply") {
        auto p = json::parse(ev.payload_json.empty() ? "{}" : ev.payload_json);
        if (p) {
          const std::string call_id = json::getString(p.get(), "call_id");
          const std::string purpose = json::getString(p.get(), "purpose");
          const std::string vlang = json::getString(p.get(), "visitor_lang");
          if (!call_id.empty()) json::set(o.get(), "call_id", call_id);
          if (json::get(p.get(), "stage_revision"))
            json::set(o.get(), "stage_revision", json::getInt(p.get(), "stage_revision"));
          if (json::get(p.get(), "expires_at_ms"))
            json::set(o.get(), "expires_at_ms", json::getInt(p.get(), "expires_at_ms"));
          if (ev.type == "call_answered") {
            auto active = active_calls.find(ev.door);
            if (active != active_calls.end() && active->second.call_id == call_id &&
                !active->second.dialog_owner.empty())
              json::set(o.get(), "dialog_owner", active->second.dialog_owner);
          }
          const std::string reason = json::getString(p.get(), "reason");
          const std::string text = json::getString(p.get(), "text");
          if (!purpose.empty()) json::set(o.get(), "purpose", purpose);
          if (!vlang.empty()) json::set(o.get(), "visitor_lang", vlang);
          if (!reason.empty()) json::set(o.get(), "reason", reason);
          if (!text.empty()) json::set(o.get(), "text", text);
        }
      }
      uiNotify(json::dump(o.get()));
    }
    // The history projection is already committed at this point, so the badge count delivered
    // here is the one a client would read back from /api/call-log.
    if (callLifecycleType(ev.type)) notifyCallLogChanged();
    auto actions = rules.evaluate(ev, hlc->correctedWallMs(), tzOffsetMin());
    bool chime_notified = false;
    bool chime_action_seen = false;
    for (const auto& a : actions) {
      if ((ev.type == "emergency" || ev.type == "emergency_cancel") &&
          (!emergency_winner || !emergency_transition))
        continue;
      auto p = json::parse(a.params_json.empty() ? "{}" : a.params_json);
      if (a.type == "chime") {
        chime_action_seen = true;

        bool mine = false;
        cJSON* devs = json::get(p.get(), "devices");
        if (!devs) {
          mine = (opts.role == "indoor_panel");
        } else if (cJSON_IsString(devs)) {
          mine = std::string(devs->valuestring) == "all";
        } else if (cJSON_IsArray(devs)) {
          if (cJSON_GetArraySize(devs) == 0) mine = (opts.role == "indoor_panel");
          cJSON* it = nullptr;
          cJSON_ArrayForEach(it, devs) {
            if (cJSON_IsString(it) && node_id == it->valuestring) mine = true;
          }
        }
        if (mine) {
          notifyChime(json::getString(p.get(), "sound", "ding1"), ev.door);
          chime_notified = true;
        }
      } else if (a.type == "auto_reply") {


        if (opts.role == "door_station" && !ev.door.empty() && ev.door == opts.door) {
          const std::string rid = json::getString(p.get(), "reply_id");
          if (!rid.empty()) {
            DB_LOGI(kTag, "auto_reply -> " + rid);
            auto call_payload = json::parse(ev.payload_json.empty() ? "{}" : ev.payload_json);
            quickReply(rid, "", ev.door, "auto", eventCallId(ev),
                       static_cast<int>(call_payload
                                            ? json::getInt(call_payload.get(), "stage_revision", 0)
                                            : 0));
          }
        }
      } else if (a.type == "device_alert") {
        if (ev.type == "emergency" || ev.type == "emergency_cancel") {
          if (selfFeature("device_alert_v1")) emergencyNotifyUi(ev, p.get());
          deliverWebPush(ev, p.get());
        } else if (missedCallEvent(ev)) {
          if (selfFeature("device_alert_v1")) missedCallNotifyUi(ev, p.get());
          deliverWebPush(ev, p.get());
        }
      } else if (a.type == "sip_call") {

        if (is_local && ev.origin == node_id &&
            (ev.type == "press" || ev.type == "purpose_selected")) {
          std::string ext = json::getString(p.get(), "target_extension", "600");
          if (sipctl && sipctl->regState() == SipRegState::Registered) {
            DB_LOGI(kTag, "sip_call -> " + ext);
            const std::string owner = eventCallId(ev);
            if (sipctl->callOwned(owner, ext)) sip_call_id = owner;
          } else {

            DB_LOGW(kTag, "sip_call -> " + ext +
                             " skipped because SIP is not registered; degrading");
            auto o = json::obj();
            json::set(o.get(), "t", "state");
            json::set(o.get(), "state", "degraded");
            json::set(o.get(), "target", ext);
            uiNotify(json::dump(o.get()));
          }
        }
      } else if (a.type == "telegram") {

        if (tg && mesh && mesh->isLeader("telegram")) tg->onAction(ev, a.params_json);
      } else if (a.type == "ha_event") {

      }
    }


    if ((ev.type == "press" || ev.type == "purpose_selected") &&
        opts.role == "indoor_panel" && !chime_action_seen &&
        !chime_notified) {
      notifyChime(json::getString(json::get(cfg.get(), "ui"), "ringtone", "ding1"), ev.door);
    }

    if (bridge && mesh && mesh->isLeader("mqtt_bridge")) bridge->onEvent(ev);


    if (tg) tg->onEvent(ev);
  }


  void onPeerAlive(const std::string& id, bool alive) {
    auto peers = mesh->peers();
    std::string max_alive;
    for (const auto& p : peers)
      if (p.status == "alive" && p.id > max_alive) max_alive = p.id;
    if (max_alive != node_id) return;
    events->append(alive ? "online" : "offline", "", id, "{}");
  }

  bool rememberPresentedReply(const std::string& event_id) {
    if (event_id.empty()) return true;
    if (!presented_reply_event_ids.insert(event_id).second) return false;
    presented_reply_event_order.push_back(event_id);
    while (presented_reply_event_order.size() > 256) {
      presented_reply_event_ids.erase(presented_reply_event_order.front());
      presented_reply_event_order.pop_front();
    }
    return true;
  }

  void presentReply(const cJSON* payload, const std::string& door,
                    const std::string& event_id) {
    if (!payload || !rememberPresentedReply(event_id)) return;
    const std::string text = json::getString(payload, "text");
    if (text.empty()) return;
    const std::string lang = json::getString(payload, "lang", "ja");
    const std::string audio = json::getString(payload, "audio");
    const bool audio_ok = !audio.empty() && assetCached(audio);
    auto o = json::obj();
    json::set(o.get(), "t", "reply");
    json::set(o.get(), "text", text);
    json::set(o.get(), "ttl_s", json::getInt(payload, "ttl_s", 30));
    json::set(o.get(), "lang", lang);
    if (!door.empty()) json::set(o.get(), "door", door);
    if (audio_ok) {
      json::set(o.get(), "audio", audio);
      json::set(o.get(), "audio_path", assetFilePath(audio));
    }
    uiNotify(json::dump(o.get()));
    if (!audio_ok && json::getBool(payload, "speak", true)) tts(text, lang);
  }

  void onCommand(const std::string& from, const std::string& cmd_json) {
    auto c = json::parse(cmd_json);
    if (!c) return;
    std::string cmd = json::getString(c.get(), "cmd");
    if (cmd == "pairing_revoked") {
      if (json::getString(c.get(), "target") != node_id) return;
      const auto peers = mesh ? mesh->peers() : std::vector<PeerInfo>{};
      const auto sender = std::find_if(peers.begin(), peers.end(), [&](const PeerInfo& peer) {
        return peer.id == from && peer.role == "indoor_panel";
      });
      if (sender == peers.end()) {
        DB_LOGW(kTag, "ignored pairing reset from unauthorized peer");
        return;
      }
      auto notice = json::obj();
      json::set(notice.get(), "t", "pairing_revoked");
      json::set(notice.get(), "by", from);
      uiNotify(json::dump(notice.get()));
      // The shell shows "removed from the Cluster" on the revoked state; the key is dropped
      // immediately so a revoked device cannot keep talking to the cluster.
      pairing_revoked = true;
      emitPairingState();
      unpairOnLoop();
      return;
    }
    if (cmd == "chime") {
      notifyChime(json::getString(c.get(), "sound", "ding1"), json::getString(c.get(), "door"));
    } else if (cmd == "show_reply") {
      presentReply(c.get(), json::getString(c.get(), "door"),
                   json::getString(c.get(), "event_id"));
    } else {
      DB_LOGW(kTag, "unknown command from " + from.substr(0, 8) + ": " + cmd);
    }
  }


  bool quickReply(const std::string& reply_id, const std::string& free_text,
                  const std::string& door_arg, const std::string& via,
                  const std::string& expected_call_id = "", int expected_revision = -1) {
    std::string door = door_arg.empty() ? last_press_door : door_arg;
    auto active = active_calls.find(door);
    const bool scoped = !expected_call_id.empty();
    if (active != active_calls.end()) {
      if (!scoped || active->second.call_id != expected_call_id ||
          active->second.stage_revision != expected_revision ||
          active->second.state != "ringing") {
        DB_LOGW(kTag, "quick reply rejected because the call identity is stale on door " + door);
        return false;
      }
      auto projection = store.callProjection(expected_call_id);
      if (!projection || projection->door != door || projection->state != "ringing" ||
          projection->stage_revision != expected_revision) {
        DB_LOGW(kTag, "quick reply rejected because the durable call is no longer ringing");
        return false;
      }
    } else if (scoped) {
      DB_LOGW(kTag, "quick reply rejected because the call is no longer active");
      return false;
    }

    const std::string lang = visitorLangFor(door);
    std::string text = free_text;
    bool speak = true;
    std::string audio;
    if (text.empty() && !reply_id.empty()) {
      cJSON* q = cfgAt("quick_replies." + reply_id);
      if (q) {
        text = labelIn(json::get(q, "label"), lang);
        speak = json::getBool(q, "speak", true);
        if (cJSON* au = json::get(q, "audio")) {
          audio = json::getString(au, lang.c_str());
          if (audio.empty()) audio = json::getString(au, "ja");
          if (!isSha256HexStr(audio)) audio.clear();
        }
      }
    }
    if (text.empty()) {
      DB_LOGW(kTag, "quickReply has no body (reply_id=" + reply_id + ")");
      return false;
    }
    int64_t ttl = 30;
    if (cJSON* r = cfgAt("reply.display_ttl_s")) ttl = static_cast<int64_t>(cJSON_IsNumber(r) ? r->valuedouble : 30);


    auto pl = json::obj();
    json::set(pl.get(), "schema_version", static_cast<int64_t>(2));
    json::set(pl.get(), "reply_id", reply_id);
    json::set(pl.get(), "text", text);
    json::set(pl.get(), "via", via);
    json::set(pl.get(), "lang", lang);
    json::setBool(pl.get(), "speak", speak);
    json::set(pl.get(), "ttl_s", ttl);
    if (!audio.empty()) json::set(pl.get(), "audio", audio);
    if (scoped) {
      json::set(pl.get(), "call_id", expected_call_id);
      json::set(pl.get(), "stage_revision", static_cast<int64_t>(expected_revision));
      json::set(pl.get(), "call_origin", active->second.origin);
    }
    const EventRecord replied = events->append("reply", door, node_id, json::dump(pl.get()));
    if (replied.seq == 0) return false;
    if (scoped) {
      auto projection = store.callProjection(expected_call_id);
      if (!projection || projection->door != door || projection->state != "ended" ||
          projection->terminal_reason != "reply" ||
          projection->stage_revision != expected_revision ||
          projection->updated_hlc != replied.hlc) {
        DB_LOGW(kTag, "quick reply lost call arbitration and was not displayed");
        return false;
      }
    }

    auto c = json::obj();
    json::set(c.get(), "cmd", "show_reply");
    json::set(c.get(), "text", text);
    json::setBool(c.get(), "speak", speak);
    json::set(c.get(), "ttl_s", ttl);
    json::set(c.get(), "lang", lang);
    json::set(c.get(), "door", door);
    json::set(c.get(), "event_id", eventIdentity(replied));
    if (!audio.empty()) json::set(c.get(), "audio", audio);
    std::string cmd = json::dump(c.get());

    cJSON* devices = json::get(cfg.get(), "devices");
    int sent = 0;
    cJSON* it = nullptr;
    cJSON_ArrayForEach(it, devices) {
      if (json::getString(it, "role") != "door_station") continue;
      if (!door.empty() && json::getString(it, "door") != door) continue;
      std::string target = it->string ? it->string : "";
      if (target.empty()) continue;
      if (target == node_id) {
        onCommand(node_id, cmd);
      } else {
        mesh->sendCommand(target, cmd);
      }
      sent++;
    }
    if (sent == 0 && opts.role == "door_station") onCommand(node_id, cmd);

    auto lp = last_press_by_door.find(door);
    if (lp != last_press_by_door.end()) {
      auto press = store.eventGet(lp->second.first, lp->second.second);
      if (press && (!scoped || eventCallId(*press) == expected_call_id)) {
        auto n = json::obj();
        json::set(n.get(), "hlc", hlc->tick());
        cJSON* rep = json::addObj(n.get(), "replied");
        json::set(rep, "reply_id", reply_id);
        json::set(rep, "by", via);
        events->mergeNotify(lp->second.first, lp->second.second, json::dump(n.get()));
      }
    }
    return true;
  }


  std::string doorStation(const std::string& door_id) {
    cJSON* devices = json::get(cfg.get(), "devices");
    cJSON* dev = nullptr;
    cJSON_ArrayForEach(dev, devices) {
      if (dev->string && json::getString(dev, "role") == "door_station" &&
          json::getString(dev, "door") == door_id) {
        return dev->string;
      }
    }
    return "";
  }

  // Return a peer node's HTTP origin; never proxy back to the local node.

  std::string nodeOrigin(const std::string& nid) {
    if (nid == node_id || !mesh) return "";
    for (const auto& p : mesh->peers()) {
      if (p.id == nid && !p.addrs.empty())
        return "http://" + hostOf(p.addrs[0]) + ":47180";
    }
    return "";
  }




  void netRefreshSnapshot() {
    std::string leader_host;
    if (mesh) {
      std::string lid = mesh->leaderFor("telegram");
      if (lid.empty()) lid = mesh->leaderFor("mqtt_bridge");
      if (!lid.empty() && lid != node_id) {
        for (const auto& p : mesh->peers())
          if (p.id == lid && !p.addrs.empty()) { leader_host = hostOf(p.addrs[0]); break; }
      }
    }
    std::vector<std::pair<std::string, std::string>> custom;
    cJSON* arr = cfgAt("debug.ping_targets");
    if (arr && cJSON_IsArray(arr)) {
      cJSON* it = nullptr;
      cJSON_ArrayForEach(it, arr) {
        std::string host, label;
        int port = 80;
        if (cJSON_IsString(it)) { host = it->valuestring; label = host; }
        else if (cJSON_IsObject(it)) {
          host = json::getString(it, "host");
          label = json::getString(it, "label", host);
          cJSON* pj = json::get(it, "port");
          if (pj && cJSON_IsNumber(pj)) port = pj->valueint;
        }
        if (!host.empty()) custom.push_back({label, host + ":" + std::to_string(port)});
      }
    }
    net_leader_addr = leader_host;
    net_custom = std::move(custom);
    cJSON* mqtt = cfgAt("integrations.mqtt");
    const std::string configured_mqtt_host = json::getString(mqtt, "host");
    const std::string next_mqtt_host = safeProbeHost(configured_mqtt_host)
        ? configured_mqtt_host : "";
    int next_mqtt_port = static_cast<int>(json::getInt(mqtt, "port", 1883));
    if (next_mqtt_port < 1 || next_mqtt_port > 65535) next_mqtt_port = 1883;
    if (next_mqtt_host != mqtt_probe_host || next_mqtt_port != mqtt_probe_port) {
      mqtt_probe_host = next_mqtt_host;
      mqtt_probe_port = next_mqtt_port;
      mqtt_probe_known = false;
      mqtt_probe_reachable = false;
      applyEffectiveCaps();
    }

    if (device_info_fn) {
      std::string di = device_info_fn();
      if (!di.empty()) device_info_json = di;
    }
  }


  std::vector<std::pair<std::string, std::pair<std::string, int>>> netTargets() {
    std::vector<std::pair<std::string, std::pair<std::string, int>>> targets;
    if (!mqtt_probe_host.empty())
      targets.push_back({"mqtt", {mqtt_probe_host, mqtt_probe_port}});
    std::string gw;
    if (!device_info_json.empty()) {
      json::Doc d = json::parse(device_info_json);
      if (d) gw = json::getString(d.get(), "gateway");
    }
    if (!gw.empty()) targets.push_back({"gateway", {gw, 80}});
    if (!net_leader_addr.empty()) targets.push_back({"leader", {net_leader_addr, 47172}});
    for (auto& c : net_custom) {
      std::string hp = c.second;
      auto cpos = hp.rfind(':');
      std::string h = cpos == std::string::npos ? hp : hp.substr(0, cpos);
      int pt = cpos == std::string::npos ? 80 : std::atoi(hp.substr(cpos + 1).c_str());
      targets.push_back({c.first, {h, pt}});
    }
    return targets;
  }



  void netProbeTick() {
    auto targets = netTargets();
    if (targets.empty()) return;
    auto& t = targets[net_tick % targets.size()];
    net_tick++;
    int rtt = -1;
    bool ok = t.first == "mqtt"
        ? net::tcpEndpointProbe(t.second.first, t.second.second, 800, &rtt)
        : net::tcpProbe(t.second.first, t.second.second, 800, &rtt);
    Store::NetProbe pr;
    pr.ts_ms = clock->wallMs();
    pr.target = t.first;
    pr.host = t.second.first + ":" + std::to_string(t.second.second);
    pr.ok = ok;
    pr.rtt_ms = rtt;
    store.netProbePut(pr);
    if (t.first == "mqtt" &&
        (!mqtt_probe_known || mqtt_probe_reachable != ok)) {
      mqtt_probe_known = true;
      mqtt_probe_reachable = ok;
      applyEffectiveCaps();
    }
    if ((net_tick % 20) == 0) store.netProbePrune(clock->wallMs() - 7LL * 24 * 3600 * 1000);
  }

  void startNetMonitor() {
    netRefreshSnapshot();
    net_refresh_timer = loop->postEvery(20'000, [this] { netRefreshSnapshot(); });
    net_probe_timer = loop->postEvery(6'000, [this] { netProbeTick(); });
  }

  void stopNetMonitor() {
    if (net_refresh_timer) { loop->cancel(net_refresh_timer); net_refresh_timer = 0; }
    if (net_probe_timer) { loop->cancel(net_probe_timer); net_probe_timer = 0; }
  }




  // The single state every shell renders. Shells must never infer it from paired/persistence_ready.
  std::string pairingStateOnLoop() const {
    if (pairing_revoked) return "revoked";
    if (!mesh || !mesh->isPaired()) return pairing_joining ? "joining" : "unpaired";
    if (!pairing_persistence_ready) return "persist_error";
    return "ready";
  }

  std::string pairingJsonOnLoop() {
    auto o = json::obj();
    if (!mesh) return json::dump(o.get());
    json::set(o.get(), "state", pairingStateOnLoop());
    json::setBool(o.get(), "paired", mesh->isPaired());
    json::setBool(o.get(), "persistence_ready", pairing_persistence_ready);
    json::setBool(o.get(), "is_founder", pairing_is_founder);
    json::set(o.get(), "psk_source", pairing_psk_source);
    if (pairing_psk_ref.empty()) {
      json::setItem(o.get(), "psk_ref", json::Doc(cJSON_CreateNull()));
    } else {
      json::set(o.get(), "psk_ref", pairing_psk_ref);
    }
    json::set(o.get(), "role", opts.role);

    json::Doc self = json::parse(mesh->pairingSelfJson());
    if (self) {

      const std::string qr = "doorbell-pair:" + json::getString(self.get(), "addr") + "|" +
                             json::getString(self.get(), "id") + "|" +
                             json::getString(self.get(), "pk");
      json::set(o.get(), "pair_qr", qr);
      json::setItem(o.get(), "self", std::move(self));
    }

    {
      cJSON* home = json::addObj(o.get(), "home");
      int64_t members = 0, connected = 0;
      for (const auto& p : mesh->peers()) {
        members++;
        if (p.id == node_id || p.connected) connected++;
      }
      json::set(home, "member_count", members);
      json::set(home, "connected_count", connected);
    }

    json::Doc token = json::parse(mesh->tokenJson());
    if (token) {
      // The PIN card renders its QR from this field, beside the printed host and PIN that a
      // plain camera app can still read.
      if (json::getBool(token.get(), "active")) {
        const std::string pin = json::getString(token.get(), "pin");
        const std::string host = json::getString(token.get(), "host");
        if (!pin.empty() && !host.empty())
          json::set(token.get(), "uri",
                    pairUriFor(host, pin, json::getInt(token.get(), "expires_s", 0)));
      }
      json::setItem(o.get(), "token", std::move(token));
    }

    json::Doc pend = json::parse(mesh->pendingJson());
    if (pend) json::setItem(o.get(), "pending", std::move(pend));
    return json::dump(o.get());
  }


  // Start pairing mode and mint a PIN in one step: {ok,host,pin,expires_s}.
  // Mint or refresh the join PIN and nothing else. Pairing mode stays closed, so a device that
  // is already announcing itself is not auto-invited by the act of showing a PIN.
  std::string mintJoinTokenJsonOnLoop(int seconds) {
    auto result = json::obj();
    if (!mesh || !mesh->isPaired()) {
      json::setBool(result.get(), "ok", false);
      json::set(result.get(), "err", "host_unpaired");
      return json::dump(result.get());
    }
    const int64_t ttl_ms = seconds > 0 ? static_cast<int64_t>(seconds) * 1000 : 0;
    const auto token = mesh->createJoinToken(ttl_ms);
    json::Doc self = json::parse(mesh->pairingSelfJson());
    const std::string host = self ? json::getString(self.get(), "addr") : "";
    if (token.pin.empty() || host.empty()) {
      json::setBool(result.get(), "ok", false);
      json::set(result.get(), "err", "pairing_unavailable");
    } else {
      const int64_t expires_s =
          std::max<int64_t>(0, (token.expires_mono - clock->monoMs()) / 1000);
      json::setBool(result.get(), "ok", true);
      json::set(result.get(), "host", host);
      json::set(result.get(), "pin", token.pin);
      json::set(result.get(), "expires_s", expires_s);
      // Shells render the QR from this and never assemble it themselves, so one definition of
      // the format serves every platform.
      json::set(result.get(), "uri", pairUriFor(host, token.pin, expires_s));
    }
    return json::dump(result.get());
  }

  // doorbell://pair?... for the current PIN. The expiry is absolute so a scanned code can be
  // rejected without the scanner having to know when it was produced.
  std::string pairUriFor(const std::string& host, const std::string& pin,
                         int64_t expires_s) const {
    const int64_t exp = expires_s > 0 ? hlc->correctedWallMs() / 1000 + expires_s : 0;
    return pair_uri::build(host, pin,
                           exp, json::getString(json::get(cfg.get(), "cluster"), "name"));
  }

  // The explicit "add several devices" window: open pairing mode, then mint a PIN so the same
  // card can show both. Only the bulk-add button reaches this.
  std::string startPairingJsonOnLoop(int seconds) {
    const int bounded_seconds = std::max(1, std::min(seconds, 3600));
    if (!mesh || !mesh->isPaired()) {
      auto result = json::obj();
      json::setBool(result.get(), "ok", false);
      json::set(result.get(), "err", "host_unpaired");
      return json::dump(result.get());
    }
    mesh->setPairingMode(static_cast<int64_t>(bounded_seconds) * 1000);
    return mintJoinTokenJsonOnLoop(0);
  }


  // "doorbell-pair:<addr>|<id>|<pk>" from a scanned or pasted QR code.
  bool inviteFromQrOnLoop(const std::string& text) {
    if (!mesh || !mesh->isPaired()) return false;
    static const std::string kPrefix = "doorbell-pair:";
    if (text.rfind(kPrefix, 0) != 0) return false;
    const std::string body = text.substr(kPrefix.size());
    const auto p1 = body.find('|');
    const auto p2 = body.rfind('|');
    if (p1 == std::string::npos || p2 == std::string::npos || p2 <= p1) return false;
    const std::string addr = body.substr(0, p1);
    const std::string pk = body.substr(p2 + 1);
    if (addr.empty() || pk.size() != 64) return false;
    mesh->inviteDeviceDirect(addr, pk);
    return true;
  }


  void emitQrScanState(bool active) {
    auto o = json::obj();
    json::set(o.get(), "t", "qr_scan_state");
    json::setBool(o.get(), "active", active);
    uiNotify(json::dump(o.get()));
  }


  // A decoded payload arrives here on Runloop. A pairing payload is invited immediately so the
  // shell only has to render the invite_result / device_joined events it already handles.
  void onQrTextOnLoop(const std::string& text) {
    auto o = json::obj();
    json::set(o.get(), "t", "qr_scanned");
    json::set(o.get(), "text", text);
    const bool invited = inviteFromQrOnLoop(text);
    json::setBool(o.get(), "invited", invited);
    uiNotify(json::dump(o.get()));
  }


  void startQrScanOnLoop() {
    if (qr_scan_timer) {
      loop->cancel(qr_scan_timer);
      qr_scan_timer = 0;
    }
    const bool was_active = qr_scanner.active();
    if (!was_active) {
      std::weak_ptr<char> w = alive;
      qr_scanner.start([this, w](const std::string& text) {
        // The decode runs on the scanner thread; node state is only touched on Runloop.
        loop->post([this, w, text] {
          if (w.expired()) return;
          onQrTextOnLoop(text);
        });
      });
    }
    // Scanning holds the camera and the decoder; it always stops on its own.
    std::weak_ptr<char> w = alive;
    qr_scan_timer = loop->postDelayed(kQrScanTtlMs, [this, w] {
      if (w.expired()) return;
      qr_scan_timer = 0;
      stopQrScanOnLoop();
    });
    if (!was_active) emitQrScanState(true);
  }


  void stopQrScanOnLoop() {
    if (qr_scan_timer) {
      loop->cancel(qr_scan_timer);
      qr_scan_timer = 0;
    }
    if (!qr_scanner.active()) return;
    qr_scanner.stop();
    emitQrScanState(false);
  }


  void emitPairingState() {
    auto o = json::obj();
    json::set(o.get(), "t", "pairing_state");
    json::set(o.get(), "state", pairingStateOnLoop());
    json::setBool(o.get(), "is_founder", pairing_is_founder);
    json::set(o.get(), "psk_source", pairing_psk_source);
    uiNotify(json::dump(o.get()));
  }


  // Persist the cluster PSK into platform secure storage. Returns false when the platform has no
  // writable store or the write failed; the caller decides which event to emit.
  bool storePairingSecret() {
    if (!mesh) return false;
    const auto& s = mesh->settings();
    const std::string secret_ref = "secret:mesh.psk";
    if (!putSecret(secret_ref, hexEncode(s.psk.data(), s.psk.size()))) return false;
    pairing_persistence_ready = true;
    pairing_psk_source = "secure_store";
    pairing_psk_ref = secret_ref;
    return true;
  }


  void emitPairedEvent() {
    if (!mesh) return;
    const auto& s = mesh->settings();
    auto o = json::obj();
    json::set(o.get(), "t", "paired");
    json::set(o.get(), "psk_ref", pairing_psk_ref);
    json::set(o.get(), "psk_id", s.psk_id);
    cJSON* seeds = json::addArr(o.get(), "seeds");
    for (const auto& a : s.seed_peers)
      json::push(seeds, json::Doc(cJSON_CreateString(a.c_str())));
    DB_LOGI(kTag, "paired: mesh PSK stored securely; requesting boot reference persistence (seeds=" +
                      std::to_string(s.seed_peers.size()) + ")");
    uiNotify(json::dump(o.get()));
  }


  void emitPersistenceError() {
    auto failure = json::obj();
    json::set(failure.get(), "t", "pairing_persistence_error");
    json::set(failure.get(), "reason", "secure_store_failed");
    DB_LOGE(kTag, "paired: secure storage failed; refusing to expose the mesh PSK");
    uiNotify(json::dump(failure.get()));
  }

  void emitJoinResult(bool ok, const std::string& err) {
    auto o = json::obj();
    json::set(o.get(), "t", "join_result");
    json::setBool(o.get(), "ok", ok);
    json::set(o.get(), "err", err);
    uiNotify(json::dump(o.get()));
  }

  // Store a newly paired PSK before telling the shell to persist its opaque reference.
  void onBecamePaired() {
    if (!mesh) return;
    pairing_joining = false;
    pairing_revoked = false;
    pairing_is_founder = mesh->isFounder();
    store.metaSet("pairing.is_founder", pairing_is_founder ? "1" : "0");
    const bool stored = storePairingSecret();
    // C5: 鍵の保存に失敗した参加を ok:true と報告してはいけない。join_result は
    // 保存の成否が確定してから、paired / pairing_state より前に必ず出す。
    if (pairing_join_awaiting_persist) {
      pairing_join_awaiting_persist = false;
      emitJoinResult(stored, stored ? "" : "persist_failed");
    }
    if (!stored) {
      pairing_persistence_ready = false;
      emitPersistenceError();
      emitPairingState();
      return;
    }
    // Founding or joining is the other moment this node becomes able to write cluster
    // configuration, so the door entry is ensured here as well as at startup.
    if (!reclaimSeededDoorEntries() || !ensureOwnDoorEntry())
      DB_LOGW(kTag, "could not reconcile the door entry for this device");
    emitPairedEvent();
    emitPairingState();
  }


  // C7: the shell may retry after a persist_error without re-running the whole join.
  bool retryPairingPersistence() {
    if (!mesh || !mesh->isPaired()) {
      emitPairingState();
      return false;
    }
    if (pairing_persistence_ready) {
      emitPairingState();
      return true;
    }
    if (!storePairingSecret()) {
      emitPersistenceError();
      emitPairingState();
      return false;
    }
    emitPairedEvent();
    emitPairingState();
    return true;
  }


  // C9: leave the cluster and forget the secret. Used by "clear pairing" and by revocation.
  // Everything about the cluster this device is leaving. Kept deliberately: the event log, and
  // with it the call history, which is this device's own record of who rang its own doorbell
  // (attribution may name a device that no longer exists); the local administrator digest, so a
  // device does not sit unauthenticated between unpair and first-run setup; and node_id, which
  // is this device's identity rather than the cluster's.
  void forgetClusterStateOnLoop() {
    // Hard-delete the rows instead of tombstoning them. A tombstone replicates, so re-pairing to
    // the same cluster would push deletions for every device this replica had forgotten.
    if (!store.configDeleteAll())
      DB_LOGW(kTag, "leaving a cluster: replicated configuration could not be cleared");
    config->resetReplica();
    // Cached peer contracts are the gossip cache: they are what made an offline device from a
    // previous cluster still resolve to a name, role, and manifest.
    const size_t contracts = store.metaDeletePrefix("peer_ui_contract.");
    // The in-memory guards belong to the old cluster as well: a node id reused by the next
    // cluster must not inherit "already cached" or "already announced" from this one.
    cached_contract_digests.clear();
    emitted_notice_digests.clear();
    emitted_peers_digest.clear();
    peers_ever_emitted = false;
    // The one-shot seed markers belong to the old cluster too; the next cluster seeds its own
    // defaults, and an administrator's later deletion of a seeded rule is remembered again then.
    for (const char* marker :
         {"seed_sos_rules_v1", "seed_missed_call_rule_v1", "seed_notice_presets_v1"})
      store.metaDeletePrefix(marker);
    rebuildCfg();
    DB_LOGI(kTag, "left the cluster: configuration replica and " + std::to_string(contracts) +
                      " cached peer contract(s) dropped");
    // Re-seed straight away so the device is immediately usable as an unpaired first-run node
    // with its own identity, rather than only after the next restart.
    if (!seedConfig())
      DB_LOGW(kTag, "first-run configuration could not be re-seeded after leaving the cluster");
    applyEffectiveCaps();
    scheduleSnapshotRefresh();
  }

  void unpairOnLoop() {
    if (mesh) mesh->unpair();
    forgetClusterStateOnLoop();
    Node::SecureDeleteFn del;
    {
      std::lock_guard<std::mutex> lk(cb_mu);
      del = secure_delete_fn;
    }
    // Deletion is optional: a platform without it keeps an orphaned entry that no boot.json
    // reference points at any more.
    if (del) del("mesh.psk");
    pairing_persistence_ready = false;
    pairing_is_founder = false;
    pairing_joining = false;
    pairing_revoked = false;
    pairing_join_awaiting_persist = false;
    pairing_psk_source = "none";
    pairing_psk_ref.clear();
    store.metaSet("pairing.is_founder", "0");
    emitPairingState();
  }

  std::string debugJsonOnLoop() {
    auto o = json::obj();
    json::set(o.get(), "node", node_id);
    json::set(o.get(), "version", opts.sw_version);
    json::set(o.get(), "role", opts.role);
    cJSON* addrs = json::addArr(o.get(), "addresses");
    for (const auto& a : db::net::localAddresses(true))
      json::push(addrs, json::Doc(cJSON_CreateString(a.c_str())));
    {
      json::Doc d = device_info_json.empty() ? json::Doc(nullptr) : json::parse(device_info_json);
      if (d) json::setItem(o.get(), "device", std::move(d));
    }
    {
      cJSON* trig = json::addObj(o.get(), "triggers");
      int64_t total = 0;
      auto pc = store.metaGet("stat_press_total");
      if (pc) { try { total = std::stoll(*pc); } catch (...) { total = 0; } }
      json::set(trig, "total_press", total);
      auto last = store.latestEventOfTypes("press", "press");
      if (last) {
        cJSON* l = json::addObj(trig, "last");
        json::set(l, "door", last->door);
        json::set(l, "device", last->device);
        json::set(l, "wall_ms", last->wall_ms);
        json::set(l, "payload", last->payload_json);
      }
    }
    {
      int64_t since = clock->wallMs() - 24LL * 3600 * 1000;
      cJSON* probes = json::addArr(o.get(), "net_probes");
      for (const auto& p : store.netProbesSince(since, 5000)) {
        cJSON* e = json::pushObj(probes);
        json::set(e, "ts", p.ts_ms);
        json::set(e, "target", p.target);
        json::set(e, "host", p.host);
        json::setBool(e, "ok", p.ok);
        json::set(e, "rtt", static_cast<int64_t>(p.rtt_ms));
      }
    }
    return json::dump(o.get());
  }

  // ---------- status ----------
  std::string statusJsonOnLoop() {
    auto o = json::obj();
    cJSON* self = json::addObj(o.get(), "node");
    json::set(self, "id", node_id);
    json::set(self, "name", opts.name);
    json::set(self, "role", opts.role);
    json::set(self, "door", opts.door);
    json::set(self, "version", opts.sw_version);
    auto caps = json::parse(effective_caps_json);
    json::setItem(self, "caps", caps ? std::move(caps) : json::obj());
    if (power.known) json::setItem(self, "power", powerDoc());

    {
      cJSON* la = json::addArr(self, "local_addrs");
      for (const auto& a : db::net::localAddresses(true))
        json::push(la, json::Doc(cJSON_CreateString(a.c_str())));
    }
    // status.self is an alias of status.node so a shell can read the documented self path
    // without needing to know which of the two names predates the other.
    json::setItem(o.get(), "self", json::Doc(cJSON_Duplicate(self, 1)));
    json::setItem(o.get(), "time", timeStatusDoc());
    cJSON* sip = json::addObj(o.get(), "sip");
    json::set(sip, "backend", sipBackendName());
    json::setBool(sip, "available", sipBackendAvailable());
    json::setBool(sip, "registered", sip_reg == SipRegState::Registered);
    json::set(sip, "state", sipRegName(sip_reg));
    json::set(sip, "call", sipCallName(sip_call));
    json::set(sip, "credential_source", sip_credential_source);
    // Whether this node picks up by itself. An indoor panel defaults to ringing so that
    // "answered" in the call history always means a person answered.
    json::setBool(sip, "auto_answer", sipSettings().auto_answer);
    json::set(sip, "answer_mode", sipSettings().auto_answer ? "auto" : "ring");
    if (!sip_peer_node.empty()) json::set(sip, "peer_node", sip_peer_node);
    if (!sip_peer_stream.empty()) json::set(sip, "peer_stream", sip_peer_stream);
    if (sipctl) {
      int64_t tx = 0, rx = 0;
      sipctl->rtpStats(&tx, &rx);
      json::set(sip, "rtp_tx", tx);
      json::set(sip, "rtp_rx", rx);
    }
    {
      // What the talk controls render: the call state plus the microphone toggle. It is
      // reported even without a SIP backend, because the shell's toggle still has a position.
      cJSON* call = json::addObj(o.get(), "call");
      json::set(call, "state", sipCallName(sip_call));
      json::set(call, "return_s", static_cast<int64_t>(callReturnSeconds()));
      // "" two-way, "answer" an explicit takeover, "monitor" one-way listen-in. Only the first
      // two may ever answer a call.
      json::set(call, "dialog_mode", sipctl ? sipctl->callMode() : std::string());
      json::setBool(call, "mic_muted", sipctl ? sipctl->micMuted() : mic_muted_without_sip);
    }
    cJSON* leaders = json::addObj(o.get(), "leaders");
    if (mesh) {
      json::set(leaders, "telegram", mesh->leaderFor("telegram"));
      json::set(leaders, "mqtt_bridge", mesh->leaderFor("mqtt_bridge"));
      json::set(leaders, "web_push", mesh->leaderFor("web_push"));
    }
    cJSON* br = json::addObj(o.get(), "bridge");
    json::set(br, "mqtt", bridge ? bridge->mqttStatus() : "inactive");

    json::set(br, "telegram", tg ? tg->status() : "inactive");
    {
      auto subscriptions = webPushSubscriptions();
      cJSON* push = json::addObj(o.get(), "web_push");
      cJSON* config = cfgAt("integrations.web_push");
      const std::string sender_ref = json::getString(config, "sender_secret_ref");
      const bool sender_configured = webPushConfigSyntaxValid(config);
      const bool local_secret_ready =
          sender_configured && !referencedSecret(config, "vapid_private_key_ref").empty() &&
          (sender_ref.empty() || !referencedSecret(config, "sender_secret_ref").empty());
      const std::string leader = mesh ? mesh->leaderFor("web_push") : "";
      json::set(push, "subscriptions",
                static_cast<int64_t>(cJSON_GetArraySize(subscriptions.get())));
      json::setBool(push, "configured", sender_configured);
      json::setBool(push, "local_secret_ready", local_secret_ready);
      json::setBool(push, "delivery_backend", sender_configured && !leader.empty());
      json::set(push, "leader", leader);
      if (!sender_configured) json::set(push, "warning_code", "sender_config_invalid");
      else if (leader.empty()) json::set(push, "warning_code", "no_ready_leader");
    }

    json::setItem(o.get(), "display", displayDoc(displayState()));
    cJSON* em = json::addObj(o.get(), "emergency");
    json::setBool(em, "active", emergency_active);
    json::set(em, "hlc", emergency_hlc);
    {
      // Clearing a running alarm must never depend on a password the cluster does not have.
      // Core resolves the two facts together so no shell can gate on a credential that was
      // never set: a household that has not chosen a password can always silence its own SOS.
      const bool configured = json::getBool(json::get(cfg.get(), "emergency"),
                                            "cancel_requires_pin", true);
      const bool have_password = adminCredentialOnLoop().present;
      json::setBool(em, "cancel_requires_password", configured && have_password);
      json::setBool(em, "admin_password_set", have_password);
    }
    json::setItem(o.get(), "runtime", runtimeStatusDoc());
    auto manifest = json::parse(ui_manifest_json);
    json::setItem(o.get(), "ui_manifest", manifest ? std::move(manifest) : json::obj());
    cJSON* web_ui = json::addObj(o.get(), "web_ui");
    json::set(web_ui, "device_id", node_id);
    auto web_manifest = json::parse(webUiManifestJson());
    json::setItem(web_ui, "manifest",
                  web_manifest ? std::move(web_manifest) : json::obj());
    json::setItem(o.get(), "features", effectiveFeaturesDoc());
    cJSON* calls = json::addArr(o.get(), "active_calls");
    for (const auto& kv : active_calls) {
      const ActiveCall& call = kv.second;
      cJSON* item = json::pushObj(calls);
      json::set(item, "call_id", call.call_id);
      json::set(item, "door", call.door);
      json::set(item, "origin", call.origin);
      if (!call.dialog_owner.empty()) json::set(item, "dialog_owner", call.dialog_owner);
      json::set(item, "stage_revision", static_cast<int64_t>(call.stage_revision));
      json::set(item, "state", call.state);
      json::set(item, "call_flow", effectiveCallFlow(call.door));
      json::set(item, "expires_at_ms", call.expires_wall_ms);
      if (!call.purpose.empty()) json::set(item, "purpose", call.purpose);
    }


    {
      CamCfg cc = cameraCfg();
      cJSON* v = json::addObj(o.get(), "video");
      json::set(v, "codec", cc.codec);
      json::setBool(v, "active", video_track.active());
      json::set(v, "subscribers", static_cast<int64_t>(video_track.subscriberCount()));
      json::set(v, "rotation", static_cast<int64_t>(effective_video_rotation.load()));
      std::string cs = video_track.codecString();
      if (!cs.empty()) json::set(v, "codec_str", cs);
      // Publish-side counters for the incoming-screen debug line. Latency, jitter and displayed
      // frames are measured by each receiver's own player and are reported through its runtime
      // status; core only knows what this node produced and handed out.
      const VideoTrack::Stats stats = video_track.stats();
      cJSON* publish = json::addObj(v, "publish");
      json::set(publish, "frames", static_cast<int64_t>(stats.frames));
      json::set(publish, "keyframes", static_cast<int64_t>(stats.keyframes));
      json::set(publish, "fragments", static_cast<int64_t>(stats.fragments));
      json::set(publish, "dropped_forward", static_cast<int64_t>(stats.dropped_forward));
      json::set(publish, "frame_interval_ms",
                static_cast<int64_t>(stats.frame_interval_ms));
      json::set(publish, "fps_x10",
                stats.frame_interval_ms > 0
                    ? static_cast<int64_t>(10000 / stats.frame_interval_ms)
                    : static_cast<int64_t>(0));
    }

    {
      int64_t total = 0, cached = 0;
      cJSON* ledger = json::get(cfg.get(), "assets");
      cJSON* a = nullptr;
      cJSON_ArrayForEach(a, ledger) {
        if (!a->string) continue;
        total++;
        if (assetCached(a->string)) cached++;
      }
      cJSON* as = json::addObj(o.get(), "assets");
      json::set(as, "cached", cached);
      json::set(as, "total", total);
    }

    {
      cJSON* doors = json::addObj(o.get(), "doors");
      // The node id of the alive door station serving this door, or empty. Shells need the
      // difference between "the station is offline" and "no station serves this door at all".
      //
      // served_by and the peers array read the same map, built once here. They used to derive
      // liveness separately -- served_by from mesh->peers() only, the peers array from that plus
      // a configured-devices fallback -- so a device that had left and returned under a new node
      // id could be named as serving a door by one view while the other listed it as offline.
      // One map cannot disagree with itself.
      auto& liveness = status_peer_status;
      liveness.clear();
      if (mesh) {
        for (const auto& peer : mesh->peers()) liveness[peer.id] = peer.status;
      }
      liveness[node_id] = "alive";
      {
        // A configured device the mesh has never seen is offline, and stays out of served_by.
        const cJSON* known = json::get(cfg.get(), "devices");
        const cJSON* device = nullptr;
        cJSON_ArrayForEach(device, known) {
          if (device->string && !liveness.count(device->string))
            liveness[device->string] = "offline";
        }
      }
      auto peer_alive = [&](const std::string& id) {
        auto it = liveness.find(id);
        return it != liveness.end() && it->second == "alive";
      };
      auto serving_station = [&](const std::string& door_id) {
        if (door_id.empty()) return std::string();
        if (opts.role == "door_station" && opts.door == door_id && peer_alive(node_id))
          return node_id;
        for (const auto& entry : liveness) {
          if (entry.first == node_id || entry.second != "alive") continue;
          const cJSON* device = cfgAt("devices." + entry.first);
          std::string role;
          std::string peer_door;
          if (mesh) {
            for (const auto& peer : mesh->peers()) {
              if (peer.id != entry.first) continue;
              role = peer.role;
              peer_door = peer.door;
              break;
            }
          }
          // A connected peer owns its operational identity. Replicated identity is only the
          // fallback for older peers that do not advertise these fields yet; otherwise a stale
          // role edit can hide a healthy station even while its signed heartbeat says it serves
          // this door.
          if (role.empty()) role = json::getString(device, "role");
          if (peer_door.empty()) peer_door = json::getString(device, "door");
          if (role != "door_station" || peer_door != door_id) continue;
          return entry.first;
        }
        return std::string();
      };
      auto add_door = [&](const std::string& id, const cJSON* configured,
                          const std::string& fallback_label) {
        if (id.empty() || json::get(doors, id.c_str())) return;
        cJSON* entry = json::addObj(doors, id.c_str());
        const std::string station = serving_station(id);
        if (station.empty()) json::setItem(entry, "served_by", json::Doc(cJSON_CreateNull()));
        else json::set(entry, "served_by", station);
        const std::string label = labelIn(json::get(configured, "label"), "ja");
        json::set(entry, "label", label.empty() ? fallback_label : label);
        // configured:false means the door is live on the mesh but has no doors.<id> entry yet.
        // Shells still render the tile and can still address it; the Admin doors tab is where
        // it gets a name.
        json::setBool(entry, "configured", configured != nullptr);
        auto notice = effectiveDoorNoticeDoc(id);
        if (notice) json::setItem(entry, "notice", std::move(notice));
        else json::setItem(entry, "notice", json::Doc(cJSON_CreateNull()));
        json::setItem(entry, "unlock", doorUnlockDoc(id));
      };
      const cJSON* configured_doors = json::get(cfg.get(), "doors");
      const cJSON* door = nullptr;
      cJSON_ArrayForEach(door, configured_doors) {
        if (door->string) add_door(door->string, door, door->string);
      }
      // A door referenced by a live door station but missing from configuration would otherwise
      // be invisible here, and every door-keyed surface would have nothing to target. Degrade
      // to an unconfigured entry instead of dropping the door.
      auto add_station = [&](const std::string& id, const std::string& door_id,
                             const std::string& advertised_name) {
        if (door_id.empty()) return;
        const cJSON* device = cfgAt("devices." + id);
        std::string name = json::getString(device, "name", advertised_name);
        add_door(door_id, cfgAt("doors." + door_id), name.empty() ? door_id : name);
      };
      if (opts.role == "door_station") add_station(node_id, opts.door, opts.name);
      if (mesh) {
        for (const auto& peer : mesh->peers()) {
          if (!peer_alive(peer.id)) continue;
          const cJSON* device = cfgAt("devices." + peer.id);
          std::string role = peer.role;
          if (role.empty()) role = json::getString(device, "role");
          if (role != "door_station") continue;
          std::string door_id = peer.door;
          if (door_id.empty()) door_id = json::getString(device, "door");
          add_station(peer.id, door_id, peer.id.substr(0, 8));
        }
      }
      cJSON* notice_config = json::addObj(o.get(), "notice");
      const cJSON* global = json::get(json::get(cfg.get(), "notice"), "global");
      json::setBool(notice_config, "global_active", cJSON_IsObject(global));
    }

    {
      cJSON* vl = json::addObj(o.get(), "visitor_lang");
      for (const auto& kv : visitor_lang_by_door) json::set(vl, kv.first.c_str(), kv.second);
    }
    cJSON* arr = json::addArr(o.get(), "peers");
    std::set<std::string> visible_peers;
    if (mesh) {
      for (const auto& p : mesh->peers()) {
        visible_peers.insert(p.id);
        cJSON* e = json::pushObj(arr);
        json::set(e, "id", p.id);
        // The same map served_by consulted, so the two views cannot disagree about a node.
        json::set(e, "status", status_peer_status.count(p.id) ? status_peer_status[p.id]
                                                              : p.status);
        json::set(e, "role", p.role);
        json::set(e, "sw", p.sw_version);
        json::setBool(e, "self", p.id == node_id);
        auto peer_caps = json::parse(p.caps_json);
        json::setItem(e, "caps", peer_caps ? std::move(peer_caps) : json::obj());
        auto advertised = json::parse(p.caps_json);
        const cJSON* advertised_features = advertised
            ? json::get(advertised.get(), "features") : nullptr;
        json::setItem(e, "features",
                      cJSON_IsObject(advertised_features)
                          ? json::Doc(cJSON_Duplicate(advertised_features, 1)) : json::obj());
        auto peer_manifest = json::parse(p.ui_manifest_json);
        json::setItem(e, "ui_manifest", peer_manifest ? std::move(peer_manifest) : json::obj());
        // Re-project at the HTTP boundary so a future mesh decoder cannot expose unrelated
        // platform diagnostics through the administrator status response.
        std::string projected_runtime;
        auto peer_runtime = projectMeshRuntimeJson(p.runtime_json, &projected_runtime)
            ? json::parse(projected_runtime) : json::obj();
        if (p.id == node_id) {
          if (power.known) json::setItem(e, "power", powerDoc());
        } else if (peer_runtime) {
          const cJSON* peer_power = json::get(peer_runtime.get(), "power");
          if (cJSON_IsObject(peer_power))
            json::setItem(e, "power", json::Doc(cJSON_Duplicate(peer_power, 1)));
        }
        json::setItem(e, "runtime",
                      peer_runtime ? std::move(peer_runtime) : json::obj());
        cJSON* addrs = json::addArr(e, "addrs");
        std::vector<std::string> display_addrs = p.addrs;
        std::sort(display_addrs.begin(), display_addrs.end());
        for (const auto& a : display_addrs)
          json::push(addrs, json::Doc(cJSON_CreateString(a.c_str())));
        // Enrich display name and door from config. During commissioning, a mesh-advertised
        // door station can expose streams before its devices.* entry has replicated.
        cJSON* dev = cfgAt("devices." + p.id);
        std::string peer_name = p.id.substr(0, 8);
        std::string peer_role = p.role;
        std::string peer_door = p.door;
        std::string codec = "auto";
        if (dev) {
          peer_name = json::getString(dev, "name", peer_name);
          std::string configured_role = json::getString(dev, "role");
          if (peer_role.empty()) peer_role = configured_role;
          if (peer_door.empty()) peer_door = json::getString(dev, "door");
          cJSON* cam = json::get(json::get(dev, "local"), "camera");
          codec = json::getString(cam, "codec", "auto");
        }
        json::set(e, "role", peer_role);
        if (!peer_door.empty()) {
          json::set(e, "door", peer_door);
          cJSON* d = cfgAt("doors." + peer_door);
          if (d) json::set(e, "door_label", labelIn(json::get(d, "label"), "ja"));
        }
        json::set(e, "name", peer_name);
        const std::string peer_http_host = preferredPeerHost(p.addrs);
        if (peer_role == "door_station" && !peer_http_host.empty()) {
          const std::string origin = "http://" + peer_http_host + ":47180";
          json::set(e, "stream", origin + "/stream.mjpeg");
          json::set(e, "video_meta", origin + "/video-meta");
          // Treat an unregistered peer as auto-capable; clients fall back to MJPEG on 503.
          if (codec != "mjpeg") json::set(e, "stream_mp4", origin + "/stream.mp4");
          json::setItem(e, "playback_profile", playbackProfileDoc(node_id, p.id));
        }
      }
    }
    const cJSON* configured_devices = json::get(cfg.get(), "devices");
    const cJSON* configured_device = nullptr;
    cJSON_ArrayForEach(configured_device, configured_devices) {
      if (!configured_device->string) continue;
      const std::string id = configured_device->string;
      if (id == node_id || visible_peers.count(id)) continue;
      cJSON* e = json::pushObj(arr);
      json::set(e, "id", id);
      json::set(e, "status", status_peer_status.count(id) ? status_peer_status[id]
                                                          : std::string("offline"));
      json::set(e, "role", json::getString(configured_device, "role"));
      json::set(e, "name", json::getString(configured_device, "name", id.substr(0, 8)));
      json::setBool(e, "self", false);
      json::addArr(e, "addrs");
      const std::string door = json::getString(configured_device, "door");
      if (!door.empty()) json::set(e, "door", door);
      auto cached = cachedPeerContract(id);
      const cJSON* cached_caps = cached ? json::get(cached.get(), "caps") : nullptr;
      const cJSON* cached_manifest = cached ? json::get(cached.get(), "ui_manifest") : nullptr;
      const cJSON* cached_runtime = cached ? json::get(cached.get(), "runtime") : nullptr;
      json::setBool(e, "cached_contract", static_cast<bool>(cached));
      json::setItem(e, "caps", cJSON_IsObject(cached_caps)
          ? json::Doc(cJSON_Duplicate(cached_caps, 1)) : json::obj());
      const cJSON* cached_features = cJSON_IsObject(cached_caps)
          ? json::get(cached_caps, "features") : nullptr;
      json::setItem(e, "features", cJSON_IsObject(cached_features)
          ? json::Doc(cJSON_Duplicate(cached_features, 1)) : json::obj());
      json::setItem(e, "ui_manifest", cJSON_IsObject(cached_manifest)
          ? json::Doc(cJSON_Duplicate(cached_manifest, 1)) : json::obj());
      json::setItem(e, "runtime", cJSON_IsObject(cached_runtime)
          ? json::Doc(cJSON_Duplicate(cached_runtime, 1)) : json::obj());
      if (cached) json::set(e, "contract_updated_wall_ms",
                            json::getInt(cached.get(), "updated_wall_ms"));
    }
    return json::dump(o.get());
  }

  // ---------- HTTP ----------
  // Readability findings ride along with a successful write so the admin can show them inline.
  static void attachWarnings(cJSON* out, const std::vector<ConfigWarning>& warnings) {
    if (warnings.empty()) return;
    cJSON* list = json::addArr(out, "warnings");
    for (const auto& warning : warnings) {
      cJSON* item = json::pushObj(list);
      json::set(item, "key", warning.key);
      json::set(item, "property", warning.property);
      json::set(item, "contrast", warning.contrast);
      json::set(item, "message_key", warning.message_key);
    }
  }

  // ---------- administrator password ----------
  // One password for the whole cluster: the same secret opens the web admin and the device-side
  // settings screen. It is stored as a salted digest in replicated configuration, so an offline
  // device verifies against the copy it already holds instead of asking the leader.
  struct AdminCredential {
    std::string salt;
    std::string hash;
    bool present = false;
    bool from_local_meta = false;
  };

  AdminCredential adminCredentialOnLoop() {
    AdminCredential out;
    const cJSON* record = json::get(json::get(cfg.get(), "admin"), "password_hash");
    out.salt = json::getString(record, "salt");
    out.hash = json::getString(record, "hash");
    if (!out.salt.empty() && !out.hash.empty()) {
      out.present = true;
      return out;
    }
    // Before the cluster-wide password existed, each node kept its own digest in local meta.
    // It stays authoritative until the first successful verification migrates it.
    auto salt = store.metaGet("admin_pw_salt");
    auto hash = store.metaGet("admin_pw_hash");
    if (salt && hash && !salt->empty() && !hash->empty()) {
      out.salt = *salt;
      out.hash = *hash;
      out.present = true;
      out.from_local_meta = true;
    }
    return out;
  }

  AdminCredential adminCredential() {
    AdminCredential out;
    loop->callSync([&] { out = adminCredentialOnLoop(); });
    return out;
  }

  // Replicate the digest and keep the local meta copy in step, so a downgrade to an older build
  // still finds a working password on this node.
  bool storeAdminCredentialOnLoop(const std::string& password) {
    const std::string salt = genTokenHex(16);
    const std::string hash = hashPassword(password, salt);
    // The local durable write comes first: a session must never be issued for a password that
    // did not survive, and a half-written credential must not leave the cluster holding a digest
    // this node cannot reproduce.
    if (!store.metaSetBatch({{"admin_pw_salt", salt}, {"admin_pw_hash", hash}})) return false;
    auto record = json::obj();
    json::set(record.get(), "salt", salt);
    json::set(record.get(), "hash", hash);
    json::set(record.get(), "algo", "blake2b-256");
    json::set(record.get(), "updated_ms", hlc->correctedWallMs());
    config->mutate({{"admin.password_hash", json::dump(record.get()), false}});
    if (!config->lastMutationCommitted()) {
      // The password works on this node; the cluster copy is retried on the next verification.
      DB_LOGW(kTag, "administrator password stored locally but not replicated");
      return false;
    }
    return true;
  }

  // 1 accepted, 0 wrong, -1 locked out, -2 no cluster password set yet.
  int verifyAdminPassword(const std::string& password) {
    const AdminCredential credential = adminCredential();
    std::lock_guard<std::mutex> lk(admin_credential_mu);
    const int64_t now = clock->monoMs();
    if (admin_lockout_until_mono > now) return -1;
    if (!credential.present) return -2;
    if (password.empty()) return 0;
    if (!constantTimeEquals(hashPassword(password, credential.salt), credential.hash)) {
      if (++admin_auth_failures >= kAdminAuthMaxFailures) {
        admin_auth_failures = 0;
        admin_lockout_until_mono = now + kAdminLockoutMs;
        DB_LOGW(kTag, "administrator password locked out for ten minutes after repeated failures");
      }
      return 0;
    }
    admin_auth_failures = 0;
    admin_lockout_until_mono = 0;
    if (credential.from_local_meta) {  // first correct entry after the upgrade
      // First correct entry after the upgrade: publish the digest so every device shares it.
      const std::string accepted = password;
      loop->callSync([&] { storeAdminCredentialOnLoop(accepted); });
      DB_LOGI(kTag, "migrated the local administrator digest to replicated configuration");
    }
    return 1;
  }

  // 0 changed, -1 bad arguments, -2 current password wrong, -3 locked out, -4 not persisted.
  int setAdminPassword(const std::string& current, const std::string& next) {
    if (next.size() < 4 || next.size() > 128) return -1;
    const AdminCredential credential = adminCredential();
    if (credential.present) {
      // An empty current password is accepted only while the cluster has none.
      const int verified = verifyAdminPassword(current);
      if (verified == -1) return -3;
      if (verified <= 0) return -2;
    }
    bool ok = false;
    loop->callSync([&] { ok = storeAdminCredentialOnLoop(next); });
    if (!ok) return -4;
    {
      std::lock_guard<std::mutex> lk(admin_credential_mu);
      admin_auth_failures = 0;
      admin_lockout_until_mono = 0;
    }
    // A password change invalidates every session established with the old one.
    std::lock_guard<std::mutex> lk(sess_mu);
    sessions.clear();
    return 0;
  }

  // ---------- configuration writes ----------
  // One implementation for the HTTP endpoints and the C ABI, so a native shell that writes
  // through the ABI gets byte-for-byte the same validation, result shape, and advisory warnings
  // as the Admin page. status_out receives the HTTP status the same request would have produced.
  // The warnings from the most recent single-key write, so db_core_set_config_json can stay an
  // int and a shell can still surface the readability finding.
  std::mutex last_warnings_mu;
  std::string last_write_warnings_json = "[]";

  void rememberWarnings(const std::vector<ConfigWarning>& warnings) {
    auto out = json::obj();
    attachWarnings(out.get(), warnings);
    const cJSON* list = json::get(out.get(), "warnings");
    std::string encoded = list ? json::dump(list) : "[]";
    std::lock_guard<std::mutex> lk(last_warnings_mu);
    last_write_warnings_json = std::move(encoded);
  }

  std::string setConfigJsonOnLoop(const std::string& key, const std::string& value_json,
                                  int* status_out) {
    auto fail = [&](const char* error, int status) {
      if (status_out) *status_out = status;
      auto out = json::obj();
      json::setBool(out.get(), "ok", false);
      json::set(out.get(), "err", error);
      return json::dump(out.get());
    };
    if (key.empty() || key.size() > 512 || key.front() == '.' || key.back() == '.' ||
        key.find("..") != std::string::npos)
      return fail("no key", 400);
    auto parsed = json::parse(value_json);
    if (!parsed) parsed = json::Doc(cJSON_CreateString(value_json.c_str()));
    std::string error;
    std::vector<ConfigWarning> warnings;
    if (!configWriteValidEffective(key, parsed.get(), &error, &warnings))
      return fail(error.c_str(), 400);
    if (!setKey(key, value_json)) return fail("config_persistence_failed", 500);
    if (status_out) *status_out = 200;
    rememberWarnings(warnings);
    auto out = json::obj();
    json::setBool(out.get(), "ok", true);
    attachWarnings(out.get(), warnings);
    return json::dump(out.get());
  }

  // ops_json is either the array of operations or the {"ops":[...]} envelope the HTTP endpoint
  // takes, so the same document works for both callers.
  std::string configBatchJsonOnLoop(const std::string& ops_json, int* status_out) {
    auto fail = [&](const char* error, int status) {
      if (status_out) *status_out = status;
      auto out = json::obj();
      json::setBool(out.get(), "ok", false);
      json::set(out.get(), "err", error);
      return json::dump(out.get());
    };
    auto body = json::parse(ops_json);
    const cJSON* ops = nullptr;
    if (body && cJSON_IsArray(body.get())) ops = body.get();
    else if (body) ops = json::get(body.get(), "ops");
    if (!cJSON_IsArray(ops) || cJSON_GetArraySize(ops) == 0) return fail("no ops", 400);
    if (cJSON_GetArraySize(ops) > 256) return fail("too many ops", 413);
    std::vector<LwwMutation> mutations;
    std::vector<ConfigWarning> warnings;
    std::set<std::string> keys;
    const cJSON* op = nullptr;
    cJSON_ArrayForEach(op, ops) {
      if (!cJSON_IsObject(op)) return fail("bad op", 400);
      const std::string kind = json::getString(op, "op");
      const std::string key = json::getString(op, "key");
      if ((kind != "set" && kind != "delete") || key.empty() || key.size() > 512 ||
          key.front() == '.' || key.back() == '.' || key.find("..") != std::string::npos)
        return fail("bad op or key", 400);
      if (!keys.insert(key).second) return fail("duplicate key", 400);
      LwwMutation mutation;
      mutation.key = key;
      mutation.deleted = kind == "delete";
      if (!mutation.deleted) {
        const cJSON* value = json::get(op, "value");
        if (!value) return fail("set without value", 400);
        std::string error;
        if (!configWriteValidEffective(key, value, &error, &warnings))
          return fail(error.c_str(), 400);
        mutation.value_json = json::dump(value);
      }
      mutations.push_back(std::move(mutation));
    }
    const auto changed = config->mutate(mutations);
    if (!config->lastMutationCommitted()) return fail("config_persistence_failed", 500);
    if (status_out) *status_out = 200;
    auto result = json::obj();
    json::setBool(result.get(), "ok", true);
    json::set(result.get(), "n", static_cast<int64_t>(changed.size()));
    if (!changed.empty()) {
      json::set(result.get(), "revision", changed.back().hlc);
      json::set(result.get(), "hlc", changed.back().hlc);  // one-release compatibility alias
    }
    attachWarnings(result.get(), warnings);
    return json::dump(result.get());
  }

  std::string deleteConfigKeyJsonOnLoop(const std::string& key, int* status_out) {
    auto fail = [&](const char* error, int status) {
      if (status_out) *status_out = status;
      auto out = json::obj();
      json::setBool(out.get(), "ok", false);
      json::set(out.get(), "err", error);
      return json::dump(out.get());
    };
    if (key.empty()) return fail("no key", 400);
    config->remove(key);
    if (!config->lastMutationCommitted()) return fail("config_persistence_failed", 500);
    if (status_out) *status_out = 200;
    return "{\"ok\":true}";
  }

  // Extract "<id>" from "/api/doors/<id><suffix>". Returns an empty string for any other shape,
  // so the prefix route cannot be used to reach an unrelated door resource.
  static std::string doorPathDoor(const std::string& uri, const std::string& suffix) {
    const std::string prefix = "/api/doors/";
    const std::string path = uri.substr(0, uri.find('?'));
    if (path.rfind(prefix, 0) != 0) return "";
    if (path.size() <= prefix.size() + suffix.size()) return "";
    if (path.compare(path.size() - suffix.size(), suffix.size(), suffix) != 0) return "";
    const std::string door = path.substr(prefix.size(), path.size() - prefix.size() -
                                                            suffix.size());
    if (door.empty() || door.size() > 64) return "";
    for (char c : door) {
      const bool allowed = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                           (c >= '0' && c <= '9') || c == '_' || c == '-';
      if (!allowed) return "";
    }
    return door;
  }

  static std::string doorNoticePathDoor(const std::string& uri) {
    return doorPathDoor(uri, "/notice");
  }

  bool checkSession(const HttpReq& req) {
    std::string tok = req.cookie("dbsess");
    if (tok.empty()) return false;
    std::lock_guard<std::mutex> lk(sess_mu);
    return sessions.count(tok) > 0;
  }

  void registerHttp() {
    size_t n = 0;
    const WebAsset* assets = webuiAssets(&n);
    for (size_t i = 0; i < n; i++)
      httpd->setStatic(assets[i].path, assets[i].content_type,
                       Bytes(assets[i].data, assets[i].data + assets[i].len));


    // Panel APIs use an HttpOnly panel session established from a fragment-delivered credential.


    httpd->setAuth([this](const HttpReq& r) {
      const bool public_asset_get =
          r.method == "GET" && r.uri.size() == 7 + 64 && r.uri.compare(0, 7, "/asset/") == 0 &&
          isSha256HexStr(r.uri.substr(7));
      return r.uri == "/" || public_asset_get || checkSession(r);
    },
                   {"/api/login", "/locale/", "/panel/", "/admin/", "/stream.mjpeg",
                    "/stream.mp4", "/stream-proxy.mp4", "/video-meta", "/snapshot.jpg",
                    "/api/panel/", "/snapshot-proxy", "/call-frame", "/peer-frame.jpg",
                    // The call history is readable by a panel credential and by an admin
                    // session; both handlers below re-check the caller explicitly.
                    "/api/call-log",
                    // Announcements and the unlock trigger accept an indoor panel credential
                    // as well as an admin session. The handlers re-check the caller explicitly.
                    "/api/doors/", "/api/notice"});

    // /stream.mp4 follows the same LAN-public policy as /stream.mjpeg.

    httpd->setMp4Provider([this]() -> Httpd::Mp4Pull {
      if (!video_track.enabled()) return nullptr;  // codec=mjpeg → 503
      auto reader = video_track.subscribe();
      return [reader](bool* ended) { return reader->pull(500, ended); };
    });

    httpd->setMp4ProxyProvider([this](const HttpReq& req, int* status) -> Httpd::Mp4Pull {
      std::string upstream_host;
      bool local = false;
      int resolved_status = 503;
      loop->callSync([&] {
        if (!panelTokenOk(req) && !checkSession(req)) {
          resolved_status = 403;
          return;
        }
        const std::string door = req.param("door");
        if (door.empty()) {
          resolved_status = 400;
          return;
        }
        std::string target;
        if (opts.role == "door_station" && opts.door == door) target = node_id;
        cJSON* devices = json::get(cfg.get(), "devices");
        cJSON* device = nullptr;
        cJSON_ArrayForEach(device, devices) {
          if (!device->string) continue;
          if (json::getString(device, "role") == "door_station" &&
              json::getString(device, "door") == door) {
            target = device->string;
            break;
          }
        }
        if (target.empty()) {
          resolved_status = 404;
          return;
        }
        if (target == node_id) {
          local = true;
          resolved_status = 200;
          return;
        }
        if (mesh) {
          for (const auto& peer : mesh->peers()) {
            if (peer.id == target && peer.status == "alive" && !peer.addrs.empty()) {
              upstream_host = hostOf(peer.addrs.front());
              resolved_status = 200;
              return;
            }
          }
        }
      });
      if (status) *status = resolved_status;
      if (resolved_status != 200) return nullptr;
      if (local) {
        if (!video_track.enabled()) {
          if (status) *status = 503;
          return nullptr;
        }
        auto reader = video_track.subscribe();
        return [reader](bool* ended) { return reader->pull(500, ended); };
      }
      if (upstream_host.empty()) return nullptr;
      auto stream = std::make_shared<RemoteMp4Stream>(upstream_host);
      return [stream](bool* ended) { return stream->pull(ended); };
    });

    httpd->route("GET", "/", [](const HttpReq&) {
      HttpResp r;
      r.status = 302;
      r.headers["Location"] = "/admin/";
      r.body = "";
      return r;
    });

    // Lightweight orientation metadata for panels currently playing H.264.
    httpd->route("GET", "/video-meta", [this](const HttpReq&) {
      HttpResp r = HttpResp::json("{\"rotation\":" +
                                  std::to_string(effective_video_rotation.load()) + "}");
      r.headers["Cache-Control"] = "no-store";
      r.headers["Access-Control-Allow-Origin"] = "*";
      return r;
    });

    httpd->route("POST", "/api/login", [this](const HttpReq& req) {
      auto b = json::parse(req.body);
      std::string pw = b ? json::getString(b.get(), "password") : "";
      if (pw.empty()) return HttpResp::json("{\"ok\":false}", 401);
      // Same credential, same lockout counter as the device-side settings screen.
      const int verified = verifyAdminPassword(pw);
      if (verified == -1)
        return HttpResp::json("{\"ok\":false,\"err\":\"locked\"}", 429);
      if (verified == -2) {
        // Trust on first use: the first password offered on any surface becomes the cluster's.
        bool stored = false;
        loop->callSync([&] { stored = storeAdminCredentialOnLoop(pw); });
        if (!stored)
          return HttpResp::json(
              "{\"ok\":false,\"err\":\"credential_persistence_failed\"}", 500);
        DB_LOGI(kTag, "initialized the cluster administrator password");
      } else if (verified <= 0) {
        return HttpResp::json("{\"ok\":false}", 401);
      }
      std::string tok = genTokenHex(16);
      {
        std::lock_guard<std::mutex> lk(sess_mu);
        sessions.insert(tok);
        if (sessions.size() > 64) sessions.erase(sessions.begin());
      }
      HttpResp r = HttpResp::json("{\"ok\":true}");
      r.headers["Set-Cookie"] = "dbsess=" + tok + "; Path=/; HttpOnly; SameSite=Strict";
      return r;
    });

    httpd->route("GET", "/api/status",
                 [this](const HttpReq&) { return HttpResp::json(statusJsonOnLoop()); });

    httpd->route("GET", "/api/debug",
                 [this](const HttpReq&) { return HttpResp::json(debugJsonOnLoop()); });

    httpd->route("GET", "/api/events", [this](const HttpReq& req) {
      size_t limit = 50;
      try {
        std::string l = req.param("limit");
        if (!l.empty()) limit = std::stoul(l);
      } catch (...) {
      }
      limit = std::max<size_t>(1, std::min<size_t>(limit, 1000));
      int64_t since_ms = 0;
      try {
        const std::string raw = req.param("since_ms");
        if (!raw.empty()) since_ms = std::stoll(raw);
      } catch (...) {
      }
      const std::string type_filter = req.param("type");
      const std::string door_filter = req.param("door");
      auto o = json::obj();
      cJSON* arr = json::addArr(o.get(), "events");
      // recentEvents is newest first. Filtering after the fetch keeps one query shape while
      // since_ms lets a caller poll for what it has not seen yet.
      size_t emitted = 0;
      for (const auto& ev : store.recentEvents(
               since_ms > 0 || !type_filter.empty() || !door_filter.empty()
                   ? std::max<size_t>(limit, 1000)
                   : limit)) {
        if (emitted >= limit) break;
        if (since_ms > 0 && ev.wall_ms < since_ms) continue;
        if (!type_filter.empty() && ev.type != type_filter) continue;
        if (!door_filter.empty() && ev.door != door_filter) continue;
        cJSON* e = json::pushObj(arr);
        json::set(e, "type", ev.type);
        json::set(e, "door", ev.door);
        json::set(e, "device", ev.device);
        json::set(e, "wall_ms", ev.wall_ms);
        json::set(e, "origin", ev.origin);
        json::set(e, "seq", static_cast<int64_t>(ev.seq));
        json::set(e, "hlc", ev.hlc);
        json::set(e, "payload", ev.payload_json);
        emitted++;
      }
      json::set(o.get(), "server_ts", hlc->correctedWallMs());
      return HttpResp::json(json::dump(o.get()));
    });

    // Call history. The panel token and the admin session are both accepted so the Web panel and
    // the Admin UI read one shared projection.
    httpd->route("GET", "/api/call-log", [this](const HttpReq& req) {
      if (!panelTokenOk(req) && !checkSession(req))
        return HttpResp::json("{\"ok\":false,\"err\":\"bad token\"}", 403);
      Store::CallLogQuery query;
      query.limit = kCallLogDefaultLimit;
      try {
        const std::string raw = req.param("limit");
        if (!raw.empty()) query.limit = std::stoul(raw);
      } catch (...) {
      }
      query.limit = std::max<size_t>(1, std::min<size_t>(query.limit, kCallLogMaxLimit));
      try {
        const std::string raw = req.param("since_ms");
        if (!raw.empty()) query.since_ms = std::stoll(raw);
      } catch (...) {
      }
      try {
        const std::string raw = req.param("before_ms");
        if (!raw.empty()) query.before_ms = std::stoll(raw);
      } catch (...) {
      }
      query.door = req.param("door");
      query.outcome = req.param("outcome");
      return HttpResp::json(callLogJson(query));
    });

    httpd->route("POST", "/api/call-log/seen", [this](const HttpReq& req) {
      if (!panelTokenOk(req) && !checkSession(req))
        return HttpResp::json("{\"ok\":false,\"err\":\"bad token\"}", 403);
      auto body = json::parse(req.body.empty() ? "{}" : req.body);
      const std::string up_to = body ? json::getString(body.get(), "up_to_hlc")
                                     : req.param("up_to_hlc");
      if (!markCallLogSeen(up_to))
        return HttpResp::json("{\"ok\":false,\"err\":\"persist_failed\"}", 500);
      auto o = json::obj();
      json::setBool(o.get(), "ok", true);
      json::set(o.get(), "unread_missed", static_cast<int64_t>(store.unreadMissedCount()));
      json::set(o.get(), "seen_hlc", store.callLogSeenHlc());
      return HttpResp::json(json::dump(o.get()));
    });

    httpd->route("GET", "/api/config", [this](const HttpReq&) {
      return HttpResp::json(config->materializeJson());
    });

    httpd->route("POST", "/api/secrets", [this](const HttpReq& req) {
      if (!secureStoreAvailable(true))
        return HttpResp::json("{\"ok\":false,\"err\":\"secure_store_unavailable\"}", 501);
      auto body = json::parse(req.body);
      const std::string ref = body ? json::getString(body.get(), "secret_ref") : "";
      const std::string value = body ? json::getString(body.get(), "value") : "";
      if (!secretRefValid(ref) || value.empty())
        return HttpResp::json("{\"ok\":false,\"err\":\"bad secret_ref or value\"}", 400);
      if (!putSecret(ref, value))
        return HttpResp::json("{\"ok\":false,\"err\":\"secure_store_failed\"}", 500);
      const auto active_panel_refs = panelSecretRefs();
      if (std::find(active_panel_refs.begin(), active_panel_refs.end(), ref) !=
          active_panel_refs.end())
        invalidatePanelSessions();
      applyEffectiveCaps();
      scheduleBridgeReapply();
      scheduleSipReapply();
      return HttpResp::json("{\"ok\":true}");
    });

    httpd->route("POST", "/api/panel/session", [this](const HttpReq& req) {
      auto body = json::parse(req.body);
      const std::string credential = body ? json::getString(body.get(), "credential") : "";
      if (!panelCredentialOk(credential))
        return HttpResp::json("{\"ok\":false,\"err\":\"bad credential\"}", 403);
      const std::string session = genTokenHex(16);
      {
        std::lock_guard<std::mutex> lk(sess_mu);
        panel_sessions[session] = panelCredentialBinding();
        if (panel_sessions.size() > 128) panel_sessions.erase(panel_sessions.begin());
      }
      HttpResp response = HttpResp::json("{\"ok\":true}");
      response.headers["Cache-Control"] = "no-store";
      response.headers["Set-Cookie"] =
          "dbpanel=" + session + "; Path=/; HttpOnly; SameSite=Strict";
      return response;
    });

    httpd->route("DELETE", "/api/secrets", [this](const HttpReq& req) {
      if (!secureStoreAvailable(true))
        return HttpResp::json("{\"ok\":false,\"err\":\"secure_store_unavailable\"}", 501);
      auto body = json::parse(req.body);
      const std::string ref = body ? json::getString(body.get(), "secret_ref") : "";
      if (!secretRefValid(ref))
        return HttpResp::json("{\"ok\":false,\"err\":\"bad secret_ref\"}", 400);
      auto config_snapshot = json::parse(config->materializeJson());
      if (config_snapshot && jsonContainsExactString(config_snapshot.get(), ref))
        return HttpResp::json("{\"ok\":false,\"err\":\"secret_ref_in_use\"}", 409);
      if (!putSecret(ref, ""))
        return HttpResp::json("{\"ok\":false,\"err\":\"secure_store_failed\"}", 500);
      applyEffectiveCaps();
      scheduleBridgeReapply();
      return HttpResp::json("{\"ok\":true}");
    });

    httpd->route("POST", "/api/config", [this](const HttpReq& req) {
      auto b = json::parse(req.body);
      if (!b) return HttpResp::json("{\"ok\":false,\"err\":\"bad json\"}", 400);
      const std::string key = json::getString(b.get(), "key");
      const std::string value = json::getString(b.get(), "value");
      int status = 200;
      const std::string result = setConfigJsonOnLoop(key, value, &status);
      return HttpResp::json(result, status);
    });

    httpd->route("POST", "/api/config/batch", [this](const HttpReq& req) {
      int status = 200;
      const std::string result = configBatchJsonOnLoop(req.body, &status);
      return HttpResp::json(result, status);
    });

    httpd->route("POST", "/api/config/delete", [this](const HttpReq& req) {
      auto b = json::parse(req.body);
      const std::string key = b ? json::getString(b.get(), "key") : "";
      int status = 200;
      const std::string result = deleteConfigKeyJsonOnLoop(key, &status);
      return HttpResp::json(result, status);
    });

    httpd->route("POST", "/api/config/import", [this](const HttpReq& req) {
      auto b = json::parse(req.body);
      cJSON* entries = b ? json::get(b.get(), "entries") : nullptr;
      if (!entries || !cJSON_IsArray(entries))
        return HttpResp::json("{\"ok\":false,\"err\":\"no entries\"}", 400);
      std::vector<LwwMutation> mutations;
      std::set<std::string> keys;
      cJSON* it = nullptr;
      cJSON_ArrayForEach(it, entries) {
        if (!cJSON_IsObject(it))
          return HttpResp::json("{\"ok\":false,\"err\":\"bad entry\"}", 400);
        std::string key = json::getString(it, "key");
        cJSON* v = json::get(it, "value");
        if (key.empty() || !v || key.size() > 512 || key.front() == '.' || key.back() == '.' ||
            key.find("..") != std::string::npos)
          return HttpResp::json("{\"ok\":false,\"err\":\"bad key or value\"}", 400);
        if (!keys.insert(key).second)
          return HttpResp::json("{\"ok\":false,\"err\":\"duplicate key\"}", 400);
        std::string style_error;
        if (!configWriteValidEffective(key, v, &style_error)) {
          auto out = json::obj();
          json::setBool(out.get(), "ok", false);
          json::set(out.get(), "err", style_error);
          return HttpResp::json(json::dump(out.get()), 400);
        }
        mutations.push_back({key, json::dump(v), false});
      }
      const auto changed = config->mutate(mutations);
      if (!config->lastMutationCommitted())
        return HttpResp::json(
            "{\"ok\":false,\"err\":\"config_persistence_failed\"}", 500);
      auto o = json::obj();
      json::setBool(o.get(), "ok", true);
      json::set(o.get(), "n", static_cast<int64_t>(changed.size()));
      return HttpResp::json(json::dump(o.get()));
    });


    // Showing a PIN is not the same decision as opening the bulk-add window, so this route mints
    // only. Use POST /api/pairing/start for the bulk-add window.
    httpd->route("POST", "/api/join-token", [this](const HttpReq& req) {
      if (!mesh) return HttpResp::json("{\"ok\":false,\"err\":\"no mesh\"}", 503);
      auto body = json::parse(req.body);
      const int seconds =
          body ? static_cast<int>(json::getInt(body.get(), "seconds", 0)) : 0;
      const std::string result = mintJoinTokenJsonOnLoop(seconds);
      auto parsed = json::parse(result);
      const bool ok = parsed && json::getBool(parsed.get(), "ok");
      return HttpResp::json(result, ok ? 200 : 409);
    });


    httpd->route("POST", "/api/pairing/found", [this](const HttpReq&) {
      if (!mesh) return HttpResp::json("{\"ok\":false,\"err\":\"no_mesh\"}", 503);
      bool ok = mesh->foundCluster();
      auto o = json::obj();
      json::setBool(o.get(), "ok", ok);
      if (!ok) json::set(o.get(), "err", "already_paired");
      return HttpResp::json(json::dump(o.get()));
    });



    httpd->route("GET", "/api/pairing",
                 [this](const HttpReq&) { return HttpResp::json(pairingJsonOnLoop()); });

    httpd->route("POST", "/api/pairing/mode", [this](const HttpReq& req) {
      if (!mesh) return HttpResp::json("{\"ok\":false,\"err\":\"no_mesh\"}", 503);
      // An unpaired node has no cluster to add anyone to; saying "ok" here strands the user.
      if (!mesh->isPaired())
        return HttpResp::json("{\"ok\":false,\"err\":\"host_unpaired\"}", 409);
      auto b = json::parse(req.body);
      int64_t sec = b ? json::getInt(b.get(), "seconds", 600) : 600;
      if (sec < 0) sec = 0;
      if (sec > 3600) sec = 3600;
      mesh->setPairingMode(sec * 1000);
      auto o = json::obj();
      json::setBool(o.get(), "ok", true);
      json::set(o.get(), "seconds", sec);
      return HttpResp::json(json::dump(o.get()));
    });


    // C10: the panel-facing pairing surface. Older routes above stay for existing shells.
    httpd->route("POST", "/api/pairing/start", [this](const HttpReq& req) {
      auto b = json::parse(req.body);
      int seconds = b ? static_cast<int>(json::getInt(b.get(), "seconds", 600)) : 600;
      const std::string result = startPairingJsonOnLoop(seconds);
      auto parsed = json::parse(result);
      const bool ok = parsed && json::getBool(parsed.get(), "ok");
      return HttpResp::json(result, ok ? 200 : 409);
    });

    httpd->route("POST", "/api/pairing/stop", [this](const HttpReq&) {
      if (!mesh) return HttpResp::json("{\"ok\":false,\"err\":\"no_mesh\"}", 503);
      mesh->setPairingMode(0);
      return HttpResp::json("{\"ok\":true}");
    });

    httpd->route("POST", "/api/pairing/deny", [this](const HttpReq& req) {
      if (!mesh) return HttpResp::json("{\"ok\":false,\"err\":\"no_mesh\"}", 503);
      auto b = json::parse(req.body);
      const std::string id = b ? json::getString(b.get(), "id") : "";
      if (id.empty()) return HttpResp::json("{\"ok\":false,\"err\":\"no_id\"}", 400);
      mesh->denyDevice(id);
      return HttpResp::json("{\"ok\":true}");
    });

    httpd->route("POST", "/api/pairing/retry-persist", [this](const HttpReq&) {
      const bool ok = retryPairingPersistence();
      auto o = json::obj();
      json::setBool(o.get(), "ok", ok);
      if (!ok) json::set(o.get(), "err", "persist_failed");
      return HttpResp::json(json::dump(o.get()), ok ? 200 : 500);
    });

    httpd->route("POST", "/api/pairing/unpair", [this](const HttpReq&) {
      if (!mesh) return HttpResp::json("{\"ok\":false,\"err\":\"no_mesh\"}", 503);
      unpairOnLoop();
      return HttpResp::json("{\"ok\":true}");
    });

    // Web paste fallback for QR scanning in a non-secure browsing context.
    httpd->route("POST", "/api/pairing/scan", [this](const HttpReq& req) {
      if (!mesh) return HttpResp::json("{\"ok\":false,\"err\":\"no_mesh\"}", 503);
      if (!mesh->isPaired())
        return HttpResp::json("{\"ok\":false,\"err\":\"host_unpaired\"}", 409);
      auto b = json::parse(req.body);
      const std::string text = b ? json::getString(b.get(), "text") : "";
      if (!inviteFromQrOnLoop(text))
        return HttpResp::json("{\"ok\":false,\"err\":\"bad_qr\"}", 400);
      return HttpResp::json("{\"ok\":true}");
    });

    httpd->route("POST", "/api/pairing/invite", [this](const HttpReq& req) {
      if (!mesh) return HttpResp::json("{\"ok\":false,\"err\":\"no_mesh\"}", 503);
      auto b = json::parse(req.body);
      std::string id = b ? json::getString(b.get(), "id") : "";
      if (id.empty()) return HttpResp::json("{\"ok\":false,\"err\":\"no_id\"}", 400);
      mesh->inviteDevice(id);
      return HttpResp::json("{\"ok\":true}");
    });

    httpd->route("POST", "/api/pairing/invite-direct", [this](const HttpReq& req) {
      if (!mesh) return HttpResp::json("{\"ok\":false,\"err\":\"no_mesh\"}", 503);
      auto b = json::parse(req.body);
      std::string addr = b ? json::getString(b.get(), "addr") : "";
      std::string id = b ? json::getString(b.get(), "id") : "";
      std::string pk = b ? json::getString(b.get(), "pk") : "";
      std::string qr = b ? json::getString(b.get(), "qr") : "";
      if (!qr.empty()) {
        const std::string kPrefix = "doorbell-pair:";
        if (qr.rfind(kPrefix, 0) == 0) qr = qr.substr(kPrefix.size());
        auto p1 = qr.find('|'), p2 = qr.rfind('|');
        if (p1 != std::string::npos && p2 != std::string::npos && p2 > p1) {
          addr = qr.substr(0, p1);
          id = qr.substr(p1 + 1, p2 - p1 - 1);
          pk = qr.substr(p2 + 1);
        }
      }
      if (addr.empty() || pk.size() != 64)
        return HttpResp::json("{\"ok\":false,\"err\":\"bad_qr\"}", 400);
      mesh->inviteDeviceDirect(addr, pk);
      return HttpResp::json("{\"ok\":true}");
    });

    httpd->route("POST", "/api/pairing/join", [this](const HttpReq& req) {
      if (!mesh) return HttpResp::json("{\"ok\":false,\"err\":\"no_mesh\"}", 503);
      if (mesh->isPaired()) return HttpResp::json("{\"ok\":false,\"err\":\"already_paired\"}", 409);
      auto b = json::parse(req.body);
      std::string host = b ? json::getString(b.get(), "host") : "";
      std::string pin = b ? json::getString(b.get(), "pin") : "";
      if (host.empty() || pin.empty())
        return HttpResp::json("{\"ok\":false,\"err\":\"need host+pin\"}", 400);

      mesh->joinCluster(host, pin, [this](bool ok, const std::string& err) {
        auto o = json::obj();
        json::set(o.get(), "t", "join_result");
        json::setBool(o.get(), "ok", ok);
        json::set(o.get(), "err", err);
        uiNotify(json::dump(o.get()));
      });
      return HttpResp::json("{\"ok\":true,\"pending\":true}");
    });



    httpd->route("POST", "/api/test/telegram", [this](const HttpReq& req) {
      auto b = json::parse(req.body);
      std::string chat = b ? json::getString(b.get(), "chat_id") : "";
      if (telegramToken().empty())
        return HttpResp::json("{\"ok\":false,\"err\":\"no_token\"}");
      if (!tg || !mesh || !mesh->isLeader("telegram"))
        return HttpResp::json("{\"ok\":false,\"err\":\"not_leader\"}");
      if (chat.empty()) {

        bool any = false;
        cJSON* hs = json::get(cfg.get(), "households");
        cJSON* h = nullptr;
        cJSON_ArrayForEach(h, hs) {
          cJSON* ids = json::get(h, "telegram_chat_ids");
          if (ids && cJSON_GetArraySize(ids) > 0) any = true;
        }
        if (!any) return HttpResp::json("{\"ok\":false,\"err\":\"no_chat\"}");
      }
      tg->sendTestMessage(chat);
      return HttpResp::json("{\"ok\":true}");
    });

    // Rotate a panel bearer in secure storage. Only its opaque reference is replicated/exported.
    httpd->route("POST", "/api/panel-token/rotate", [this](const HttpReq&) {
      std::string tok, ref;
      if (!issuePanelCredential(&tok, &ref))
        return HttpResp::json("{\"ok\":false,\"err\":\"secure_store_unavailable\"}", 501);
      const auto old_refs = panelSecretRefs();
      std::vector<LwwMutation> mutations = {
          {"panel.token_refs", "[\"" + ref + "\"]", false},
          {"panel.token_generation", "\"" + genTokenHex(16) + "\"", false}};
      if (config->get("panel.tokens"))
        mutations.push_back({"panel.tokens", "", true});
      config->mutate(mutations);
      if (!config->lastMutationCommitted()) {
        putSecret(ref, "");
        return HttpResp::json(
            "{\"ok\":false,\"err\":\"config_persistence_failed\"}", 500);
      }
      invalidatePanelSessions();
      for (const auto& old_ref : old_refs) putSecret(old_ref, "");
      auto o = json::obj();
      json::setBool(o.get(), "ok", true);
      json::set(o.get(), "token", tok);
      HttpResp response = HttpResp::json(json::dump(o.get()));
      response.headers["Cache-Control"] = "no-store";
      return response;
    });

    // Provision the current fleet reference on this node without mutating replicated config.
    httpd->route("POST", "/api/panel-token/provision", [this](const HttpReq& req) {
      if (!secureStoreReadWrite())
        return HttpResp::json("{\"ok\":false,\"err\":\"secure_store_unavailable\"}", 501);
      auto body = json::parse(req.body);
      const std::string ref = body ? json::getString(body.get(), "secret_ref") : "";
      const std::string token = body ? json::getString(body.get(), "token") : "";
      if (!secretRefValid(ref) || token.empty() || token.size() > 4096)
        return HttpResp::json("{\"ok\":false,\"err\":\"bad secret_ref or token\"}", 400);
      const auto refs = panelSecretRefs();
      if (std::find(refs.begin(), refs.end(), ref) == refs.end())
        return HttpResp::json("{\"ok\":false,\"err\":\"panel_ref_not_active\"}", 409);
      if (!putSecret(ref, token))
        return HttpResp::json("{\"ok\":false,\"err\":\"secure_store_failed\"}", 500);
      invalidatePanelSessions();
      HttpResp response = HttpResp::json("{\"ok\":true}");
      response.headers["Cache-Control"] = "no-store";
      return response;
    });

    httpd->route("POST", "/api/press", [this](const HttpReq& req) {
      auto b = json::parse(req.body);
      std::string door = b ? json::getString(b.get(), "door") : "";
      std::string purpose = b ? json::getString(b.get(), "purpose") : "";
      if (!purpose.empty() && !purposeSelectable(purpose))
        return HttpResp::json("{\"ok\":false,\"err\":\"unknown purpose\"}", 400);
      const std::string call_id = doPress(door, purpose);
      if (call_id.empty())
        return HttpResp::json(
            "{\"ok\":false,\"err\":\"event_persistence_failed\"}", 500);
      auto o = json::obj();
      json::setBool(o.get(), "ok", true);
      json::set(o.get(), "call_id", call_id);
      const std::string effective_door = door.empty() ? opts.door : door;
      auto active = active_calls.find(effective_door);
      if (active != active_calls.end() && active->second.call_id == call_id) {
        json::set(o.get(), "call_state", active->second.state);
        json::set(o.get(), "stage_revision",
                  static_cast<int64_t>(active->second.stage_revision));
        json::set(o.get(), "expires_at_ms", active->second.expires_wall_ms);
      }
      return HttpResp::json(json::dump(o.get()));
    });

    httpd->route("POST", "/api/call/purpose", [this](const HttpReq& req) {
      auto b = json::parse(req.body);
      if (!b) return HttpResp::json("{\"ok\":false,\"err\":\"bad json\"}", 400);
      const std::string door = json::getString(b.get(), "door");
      const std::string call_id = json::getString(b.get(), "call_id");
      const std::string purpose = json::getString(b.get(), "purpose");
      if (!doSelectPurpose(door, call_id, purpose))
        return HttpResp::json("{\"ok\":false,\"err\":\"stale call\"}", 409);
      return HttpResp::json("{\"ok\":true}");
    });

    httpd->route("POST", "/api/call/cancel", [this](const HttpReq& req) {
      auto b = json::parse(req.body);
      if (!b) return HttpResp::json("{\"ok\":false,\"err\":\"bad json\"}", 400);
      if (!doCancelCall(json::getString(b.get(), "door"), json::getString(b.get(), "call_id"),
                        json::getString(b.get(), "reason", "visitor")))
        return HttpResp::json("{\"ok\":false,\"err\":\"stale call\"}", 409);
      return HttpResp::json("{\"ok\":true}");
    });



    httpd->route("POST", "/api/assets", [this](const HttpReq& req) {
      const std::string type = req.param("type");
      if (!assetTypeAllowed(type))
        return HttpResp::json("{\"ok\":false,\"err\":\"bad type\"}", 415);
      if (req.body.empty()) return HttpResp::json("{\"ok\":false,\"err\":\"empty body\"}", 400);
      if (req.body.size() > kAssetMaxBytes)
        return HttpResp::json("{\"ok\":false,\"err\":\"too large\"}", 413);
      Bytes data(req.body.begin(), req.body.end());
      const std::string hash = addAssetOnLoop(data, type, req.param("label"));
      if (hash.empty()) return HttpResp::json("{\"ok\":false,\"err\":\"store failed\"}", 500);
      auto o = json::obj();
      json::setBool(o.get(), "ok", true);
      json::set(o.get(), "hash", hash);
      return HttpResp::json(json::dump(o.get()));
    });

    httpd->route("GET", "/asset/*", [this](const HttpReq& req) {
      const std::string hash = req.uri.substr(7);
      if (!isSha256HexStr(hash))
        return HttpResp::json("{\"ok\":false,\"err\":\"bad hash\"}", 400);
      Bytes data;
      if (!readFileBytes(assetFilePath(hash), data))
        return HttpResp::json("{\"ok\":false,\"err\":\"not cached\"}", 404);
      HttpResp r;
      r.content_type = json::getString(cfgAt("assets." + hash), "type",
                                       "application/octet-stream");
      r.body.assign(data.begin(), data.end());
      r.headers["Cache-Control"] = "max-age=31536000, immutable";
      return r;
    });





    httpd->route("DELETE", "/api/assets/*", [this](const HttpReq& req) {
      const std::string hash = req.uri.substr(std::string("/api/assets/").size());
      if (!isSha256HexStr(hash))
        return HttpResp::json("{\"ok\":false,\"err\":\"bad hash\"}", 400);
      config->remove("assets." + hash);
      if (!config->lastMutationCommitted())
        return HttpResp::json(
            "{\"ok\":false,\"err\":\"config_persistence_failed\"}", 500);
      removeFile(assetFilePath(hash));
      asset_unref_since.erase(hash);
      return HttpResp::json("{\"ok\":true}");
    });


    httpd->route("POST", "/api/visitor-lang", [this](const HttpReq& req) {
      auto b = json::parse(req.body);
      std::string lang = b ? json::getString(b.get(), "lang") : "";
      if (lang.empty()) return HttpResp::json("{\"ok\":false,\"err\":\"no lang\"}", 400);
      doSetVisitorLang(b ? json::getString(b.get(), "door") : "", lang);
      return HttpResp::json("{\"ok\":true}");
    });

    httpd->route("POST", "/api/reply", [this](const HttpReq& req) {
      auto b = json::parse(req.body);
      if (!b) return HttpResp::json("{\"ok\":false}", 400);
      const std::string call_id = json::getString(b.get(), "call_id");
      const int revision = static_cast<int>(json::getInt(b.get(), "stage_revision", -1));
      if (!quickReply(json::getString(b.get(), "reply_id"), json::getString(b.get(), "text"),
                      json::getString(b.get(), "door"), "web", call_id, revision))
        return HttpResp::json("{\"ok\":false,\"err\":\"stale call\"}", 409);
      return HttpResp::json("{\"ok\":true}");
    });


    httpd->route("POST", "/api/emergency", [this](const HttpReq& req) {
      auto b = json::parse(req.body);
      if (!b || !json::get(b.get(), "active"))
        return HttpResp::json("{\"ok\":false,\"err\":\"no active\"}", 400);
      if (!doEmergency(json::getBool(b.get(), "active"), "admin"))
        return HttpResp::json(
            "{\"ok\":false,\"err\":\"event_persistence_failed\"}", 500);
      return HttpResp::json("{\"ok\":true}");
    });

    // One immediate SNTP round for the "sync now" button. The exchange is asynchronous; the
    // caller re-reads /api/status to see the result.
    httpd->route("POST", "/api/time/sync", [this](const HttpReq&) {
      if (!ntpEnabled())
        return HttpResp::json("{\"ok\":false,\"err\":\"ntp_disabled\"}", 409);
      if (!startTimeSync())
        return HttpResp::json("{\"ok\":false,\"err\":\"not_started\"}", 409);
      return HttpResp::json("{\"ok\":true,\"started\":true}");
    });

    // Announcements. An indoor panel posts with its panel credential; the Admin doors tab posts
    // with the administrator session.
    httpd->route("POST", "/api/doors/*", [this](const HttpReq& req) {
      // The existing unlock capability: trigger the configured unlock action for this door. It
      // publishes the same ha_command the SIP feature code does, so an installation that already
      // wired a relay to <base>/cmd/unlock needs no new configuration.
      const std::string unlock_door = doorPathDoor(req.uri, "/open");
      if (!unlock_door.empty()) {
        if (!checkSession(req) && !panelTokenOk(req))
          return HttpResp::json("{\"ok\":false,\"err\":\"forbidden\"}", 403);
        if (!doorExists(unlock_door))
          return HttpResp::json("{\"ok\":false,\"err\":\"unknown_door\"}", 404);
        if (!openDoorOnLoop(unlock_door))
          return HttpResp::json(
              "{\"ok\":false,\"err\":\"unlock_not_configured\"}", 409);
        return HttpResp::json("{\"ok\":true}");
      }
      const std::string door = doorNoticePathDoor(req.uri);
      if (door.empty()) return HttpResp::json("{\"ok\":false,\"err\":\"not_found\"}", 404);
      if (!checkSession(req) && !panelTokenOk(req))
        return HttpResp::json("{\"ok\":false,\"err\":\"forbidden\"}", 403);
      auto body = json::parse(req.body);
      if (!body) return HttpResp::json("{\"ok\":false,\"err\":\"bad_body\"}", 400);
      const std::string text = json::getString(body.get(), "text");
      int64_t expires = json::getInt(body.get(), "expires_ms", 0);
      const int64_t ttl_s = json::getInt(body.get(), "ttl_s", 0);
      if (expires <= 0 && ttl_s > 0) expires = hlc->correctedWallMs() + ttl_s * 1000LL;
      if (!setDoorNoticeOnLoop(door, text, expires))
        return HttpResp::json("{\"ok\":false,\"err\":\"rejected\"}", 400);
      return HttpResp::json("{\"ok\":true}");
    });

    // The cluster-wide announcement. A door-specific one overrides it, so this is the
    // "everywhere" target of the announcement dialog rather than a bulk per-door write.
    httpd->route("POST", "/api/notice", [this](const HttpReq& req) {
      if (!checkSession(req) && !panelTokenOk(req))
        return HttpResp::json("{\"ok\":false,\"err\":\"forbidden\"}", 403);
      auto body = json::parse(req.body);
      if (!body) return HttpResp::json("{\"ok\":false,\"err\":\"bad_body\"}", 400);
      const std::string text = json::getString(body.get(), "text");
      int64_t expires = json::getInt(body.get(), "expires_ms", 0);
      const int64_t ttl_s = json::getInt(body.get(), "ttl_s", 0);
      if (expires <= 0 && ttl_s > 0) expires = hlc->correctedWallMs() + ttl_s * 1000LL;
      if (!setDoorNoticeOnLoop("*", text, expires))
        return HttpResp::json("{\"ok\":false,\"err\":\"rejected\"}", 400);
      return HttpResp::json("{\"ok\":true}");
    });

    httpd->route("DELETE", "/api/notice", [this](const HttpReq& req) {
      if (!checkSession(req) && !panelTokenOk(req))
        return HttpResp::json("{\"ok\":false,\"err\":\"forbidden\"}", 403);
      if (!clearDoorNoticeOnLoop("*"))
        return HttpResp::json("{\"ok\":false,\"err\":\"rejected\"}", 400);
      return HttpResp::json("{\"ok\":true}");
    });

    httpd->route("DELETE", "/api/doors/*", [this](const HttpReq& req) {
      const std::string door = doorNoticePathDoor(req.uri);
      if (door.empty()) return HttpResp::json("{\"ok\":false,\"err\":\"not_found\"}", 404);
      if (!checkSession(req) && !panelTokenOk(req))
        return HttpResp::json("{\"ok\":false,\"err\":\"forbidden\"}", 403);
      if (!clearDoorNoticeOnLoop(door))
        return HttpResp::json("{\"ok\":false,\"err\":\"rejected\"}", 400);
      return HttpResp::json("{\"ok\":true}");
    });

    httpd->route("GET", "/api/logs", [](const HttpReq&) {
      auto o = json::obj();
      cJSON* arr = json::addArr(o.get(), "logs");
      for (const auto& l : recentLogs(200))
        json::push(arr, json::Doc(cJSON_CreateString(l.c_str())));
      return HttpResp::json(json::dump(o.get()));
    });

    // ---------- Panel API (panel token authentication) ----------
    httpd->route("GET", "/api/panel/push-vapid-public-key", [this](const HttpReq& req) {
      if (!panelTokenOk(req)) return HttpResp::json("{\"ok\":false,\"err\":\"bad token\"}", 403);
      const std::string key =
          json::getString(cfgAt("integrations.web_push"), "vapid_public_key");
      if (!vapidPublicKeyValid(key))
        return HttpResp::json("{\"ok\":false,\"err\":\"web_push_not_configured\"}", 501);
      auto out = json::obj();
      json::setBool(out.get(), "ok", true);
      json::set(out.get(), "public_key", key);
      return HttpResp::json(json::dump(out.get()));
    });

    httpd->route("POST", "/api/panel/push-subscription", [this](const HttpReq& req) {
      if (!panelTokenOk(req)) return HttpResp::json("{\"ok\":false,\"err\":\"bad token\"}", 403);
      auto body = json::parse(req.body);
      cJSON* subscription = body ? json::get(body.get(), "subscription") : nullptr;
      auto normalized = normalizedWebPushSubscription(subscription);
      if (!normalized)
        return HttpResp::json("{\"ok\":false,\"err\":\"bad subscription\"}", 400);
      const std::string endpoint = json::getString(normalized.get(), "endpoint");
      std::string page = body ? json::getString(body.get(), "page") : "";
      if (page.rfind("/panel/", 0) != 0) page = "/panel/monitor";
      std::string group = body ? json::getString(body.get(), "group", "all") : "all";
      if (!webGroupNameValid(group)) group = "all";
      auto current = webPushSubscriptions();
      bool replaced = false;
      cJSON* item = nullptr;
      cJSON_ArrayForEach(item, current.get()) {
        cJSON* old_subscription = json::get(item, "subscription");
        if (json::getString(old_subscription, "endpoint") == endpoint) replaced = true;
      }
      if (!replaced && cJSON_GetArraySize(current.get()) >= 256)
        return HttpResp::json("{\"ok\":false,\"err\":\"subscription limit\"}", 409);
      auto record = sealWebPushRecord(normalized.get(), page, group, hlc->correctedWallMs());
      if (!record)
        return HttpResp::json("{\"ok\":false,\"err\":\"mesh_secret_unavailable\"}", 503);
      config->set("web_push.subscriptions." + webPushSubscriptionKey(endpoint),
                  json::dump(record.get()));
      if (!config->lastMutationCommitted())
        return HttpResp::json(
            "{\"ok\":false,\"err\":\"config_persistence_failed\"}", 500);
      auto out = json::obj();
      json::setBool(out.get(), "ok", true);
      json::set(out.get(), "subscriptions",
                static_cast<int64_t>(cJSON_GetArraySize(current.get()) + (replaced ? 0 : 1)));
      return HttpResp::json(json::dump(out.get()));
    });

    httpd->route("DELETE", "/api/panel/push-subscription", [this](const HttpReq& req) {
      if (!panelTokenOk(req)) return HttpResp::json("{\"ok\":false,\"err\":\"bad token\"}", 403);
      auto body = json::parse(req.body);
      const std::string endpoint = body ? json::getString(body.get(), "endpoint") : "";
      if (endpoint.empty())
        return HttpResp::json("{\"ok\":false,\"err\":\"no endpoint\"}", 400);
      config->remove("web_push.subscriptions." + webPushSubscriptionKey(endpoint));
      if (!config->lastMutationCommitted())
        return HttpResp::json(
            "{\"ok\":false,\"err\":\"config_persistence_failed\"}", 500);
      return HttpResp::json("{\"ok\":true}");
    });

    httpd->route("GET", "/api/panel/state", [this](const HttpReq& req) {
      if (!panelTokenOk(req)) return HttpResp::json("{\"ok\":false,\"err\":\"bad token\"}", 403);
      auto o = json::obj();
      cJSON* doors = json::addArr(o.get(), "doors");
      int64_t now_mono = clock->monoMs();
      pruneTerminalCalls();
      cJSON* dcfg = json::get(cfg.get(), "doors");
      cJSON* it = nullptr;
      cJSON_ArrayForEach(it, dcfg) {
        if (!it->string) continue;
        cJSON* e = json::pushObj(doors);
        json::set(e, "id", it->string);
        std::string label = labelIn(json::get(it, "label"), "ja");
        json::set(e, "label", label.empty() ? std::string(it->string) : label);
        auto c = door_calling_until.find(it->string);
        json::setBool(e, "calling", c != door_calling_until.end() && c->second > now_mono);
        auto active = active_calls.find(it->string);
        const std::string flow = effectiveCallFlow(it->string);
        json::set(e, "call_flow", flow);
        if (active != active_calls.end()) {
          json::set(e, "call_id", active->second.call_id);
          json::set(e, "call_state",
                    active->second.state == "in_call"
                        ? "in_call"
                        : (flow == "ring_then_purpose" &&
                                   active->second.stage_revision == 0 &&
                                   active->second.purpose.empty()
                               ? "purpose_pending"
                               : "ringing"));
          json::set(e, "stage_revision", static_cast<int64_t>(active->second.stage_revision));
          if (!active->second.dialog_owner.empty())
            json::set(e, "dialog_owner", active->second.dialog_owner);
          json::set(e, "expires_at_ms", active->second.expires_wall_ms);
          json::setBool(e, "recovery_required",
                        active->second.recovery_timer != 0 &&
                        active->second.recovery_kind == RecoveryLeaseKind::LocalProcess);
          if (!active->second.purpose.empty()) json::set(e, "purpose", active->second.purpose);
        } else {
          auto terminal = terminal_calls.find(it->string);
          if (terminal != terminal_calls.end()) {
            json::set(e, "call_id", terminal->second.call_id);
            json::set(e, "call_state", terminal->second.state);
            json::set(e, "stage_revision",
                      static_cast<int64_t>(terminal->second.stage_revision));
            json::set(e, "terminal_at_ms", terminal->second.terminal_wall_ms);
            json::setBool(e, "recovery_required", false);
            if (terminal->second.expires_wall_ms > 0)
              json::set(e, "expires_at_ms", terminal->second.expires_wall_ms);
            if (!terminal->second.reason.empty())
              json::set(e, "terminal_reason", terminal->second.reason);
            if (!terminal->second.dialog_owner.empty())
              json::set(e, "dialog_owner", terminal->second.dialog_owner);
            if (!terminal->second.purpose.empty())
              json::set(e, "purpose", terminal->second.purpose);
          }
        }

        auto vl = visitor_lang_by_door.find(it->string);
        if (vl != visitor_lang_by_door.end()) json::set(e, "visitor_lang", vl->second);



        std::string station = doorStation(it->string);
        if (!station.empty()) {
          json::set(e, "source_node_id", station);
          json::setItem(e, "playback_profile", playbackProfileDoc(node_id, station));
          std::string origin = station == node_id ? "" : nodeOrigin(station);
          if (station == node_id || !origin.empty())
            json::set(e, "stream_mjpeg", origin + "/stream.mjpeg");
          cJSON* cam = json::get(json::get(cfgAt("devices." + station), "local"), "camera");
          if (json::getString(cam, "codec", "auto") != "mjpeg") {
            if (station == node_id) {
              json::set(e, "stream_mp4", "/stream.mp4");
            } else {
              if (!origin.empty()) json::set(e, "stream_mp4", origin + "/stream.mp4");
            }
          }
        }
      }
      cJSON* quick_replies = json::addArr(o.get(), "quick_replies");
      std::vector<const cJSON*> reply_items;
      const cJSON* reply_cfg = json::get(cfg.get(), "quick_replies");
      const cJSON* reply_item = nullptr;
      cJSON_ArrayForEach(reply_item, reply_cfg) {
        if (reply_item->string && cJSON_IsObject(reply_item) && reply_items.size() < 64)
          reply_items.push_back(reply_item);
      }
      std::sort(reply_items.begin(), reply_items.end(), [](const cJSON* a, const cJSON* b) {
        const int64_t ao = json::getInt(a, "order", 0);
        const int64_t bo = json::getInt(b, "order", 0);
        if (ao != bo) return ao < bo;
        return std::string(a->string ? a->string : "") <
               std::string(b->string ? b->string : "");
      });
      for (const cJSON* configured_reply : reply_items) {
        cJSON* label = json::get(configured_reply, "label");
        if (!cJSON_IsObject(label)) continue;
        cJSON* exposed_reply = json::pushObj(quick_replies);
        json::set(exposed_reply, "id", configured_reply->string);
        json::set(exposed_reply, "label", labelIn(label, "ja"));
        json::setItem(exposed_reply, "labels", json::Doc(cJSON_Duplicate(label, 1)));
      }
      json::set(o.get(), "call_flow", effectiveCallFlow(opts.door));
      cJSON* emergency = json::addObj(o.get(), "emergency");
      json::setBool(emergency, "active", emergency_active);
      json::set(emergency, "hlc", emergency_hlc);
      json::setBool(emergency, "web_active_page_alerts",
                    json::getBool(json::get(cfg.get(), "emergency"),
                                  "web_active_page_alerts", true));
      std::string web_group = req.param("group");
      if (!webGroupNameValid(web_group)) web_group = "all";
      json::setItem(o.get(), "device_alert", panelDeviceAlert(web_group));
      cJSON* evs = json::addArr(o.get(), "events");
      for (const auto& ev : store.recentEvents(10)) {
        cJSON* e = json::pushObj(evs);
        json::set(e, "type", ev.type);
        json::set(e, "door", ev.door);
        json::set(e, "device", ev.device);
        json::set(e, "wall_ms", ev.wall_ms);
        if (ev.type == "press" && !ev.payload_json.empty()) {
          auto p = json::parse(ev.payload_json);
          const std::string purpose = p ? json::getString(p.get(), "purpose") : "";
          const std::string vlang = p ? json::getString(p.get(), "visitor_lang") : "";
          if (!purpose.empty()) json::set(e, "purpose", purpose);
          if (!vlang.empty()) json::set(e, "visitor_lang", vlang);
        }
      }
      if (last_reply_ts > 0) {
        cJSON* r = json::addObj(o.get(), "reply");
        json::set(r, "text", last_reply_text);
        json::set(r, "ts", last_reply_ts);
      } else {
        json::setItem(o.get(), "reply", json::Doc(cJSON_CreateNull()));
      }
      // Web panels use the same sound settings as native shells. asset:* resolves via /asset/<hash>

      {
        cJSON* sounds = json::addObj(o.get(), "sounds");
        cJSON* ui = json::get(cfg.get(), "ui");
        json::set(sounds, "launch", json::getString(ui, "launch_sound", "title_display"));
        json::set(sounds, "call", json::getString(ui, "call_sound", "outdoor_call_alert"));
        json::setBool(sounds, "call_loop", json::getBool(ui, "call_sound_loop", false));
        json::set(sounds, "button", json::getString(ui, "button_sound", "button_click"));
        json::set(sounds, "update", json::getString(ui, "update_sound", "indoor_update"));
        json::set(sounds, "ringtone", json::getString(ui, "ringtone", "school_chime"));
      }


      {
        struct P {
          int64_t order;
          std::string id;
          const cJSON* obj;
        };
        std::vector<P> ps;
        cJSON* vps = json::get(cfg.get(), "visit_purposes");
        cJSON* vp = nullptr;
        cJSON_ArrayForEach(vp, vps) {
          // A disabled purpose stays in configuration but is never offered to a visitor.
          if (vp->string && json::getBool(vp, "enabled", true))
            ps.push_back({json::getInt(vp, "order", 1000), vp->string, vp});
        }
        std::sort(ps.begin(), ps.end(), [](const P& a, const P& b) {
          return std::tie(a.order, a.id) < std::tie(b.order, b.id);
        });
        cJSON* arr = json::addArr(o.get(), "purposes");
        for (const P& p : ps) {
          cJSON* e = json::pushObj(arr);
          json::set(e, "id", p.id);
          json::set(e, "icon", json::getString(p.obj, "icon"));
          json::set(e, "order", p.order);
          if (cJSON* label = json::get(p.obj, "label"))
            json::setItem(e, "label", json::Doc(cJSON_Duplicate(label, 1)));
        }
      }

      {
        cJSON* arr = json::addArr(o.get(), "languages");
        cJSON* langs = cfgAt("ui.languages");
        if (cJSON_IsArray(langs)) {
          cJSON* l = nullptr;
          cJSON_ArrayForEach(l, langs) {
            if (cJSON_IsString(l)) json::push(arr, json::Doc(cJSON_CreateString(l->valuestring)));
          }
        }
        if (cJSON_GetArraySize(arr) == 0)
          json::push(arr, json::Doc(cJSON_CreateString("ja")));
      }
      {
        cJSON* web_ui = json::addObj(o.get(), "web_ui");
        json::set(web_ui, "device_id", node_id);
        auto manifest = json::parse(webUiManifestJson());
        json::setItem(web_ui, "manifest",
                      manifest && cJSON_IsObject(manifest.get()) ? std::move(manifest)
                                                                : json::obj());
        cJSON* elements = cfgAt("devices." + node_id + ".local.ui.elements");
        json::setItem(web_ui, "elements",
                      cJSON_IsObject(elements)
                          ? json::Doc(cJSON_Duplicate(elements, 1)) : json::obj());
      }
      json::set(o.get(), "server_ts", hlc->correctedWallMs());
      return HttpResp::json(json::dump(o.get()));
    });


    httpd->route("POST", "/api/panel/ui-report", [this](const HttpReq& req) {
      if (!panelTokenOk(req)) return HttpResp::json("{\"ok\":false,\"err\":\"bad token\"}", 403);
      if (req.body.size() > 16 * 1024)
        return HttpResp::json("{\"ok\":false,\"err\":\"report too large\"}", 413);
      auto body = json::parse(req.body);
      const std::string page = body ? json::getString(body.get(), "page") : "";
      const cJSON* applied = body ? json::get(body.get(), "applied") : nullptr;
      const cJSON* rejected = body ? json::get(body.get(), "rejected") : nullptr;
      const cJSON* lkg_used = body ? json::get(body.get(), "lkg_used") : nullptr;
      const cJSON* lkg_persisted = body ? json::get(body.get(), "lkg_persisted") : nullptr;
      const cJSON* elements = body ? json::get(body.get(), "elements") : nullptr;
      const std::string error = body ? json::getString(body.get(), "last_error") : "";
      if (!body || !cJSON_IsObject(body.get()) ||
          json::getInt(body.get(), "schema_version") != 1 ||
          (page != "door" && page != "monitor" && page != "call") ||
          !cJSON_IsBool(applied) || !cJSON_IsBool(rejected) ||
          !cJSON_IsBool(lkg_used) || !cJSON_IsBool(lkg_persisted) ||
          !cJSON_IsArray(elements) || cJSON_GetArraySize(elements) > 64 ||
          error.size() > 256)
        return HttpResp::json("{\"ok\":false,\"err\":\"invalid UI report\"}", 400);
      auto report = json::obj();
      json::set(report.get(), "schema_version", static_cast<int64_t>(1));
      json::set(report.get(), "client", "web");
      json::set(report.get(), "device_id", node_id);
      json::set(report.get(), "page", page);
      json::setBool(report.get(), "applied", cJSON_IsTrue(applied));
      json::setBool(report.get(), "rejected", cJSON_IsTrue(rejected));
      json::setBool(report.get(), "lkg_used", cJSON_IsTrue(lkg_used));
      json::setBool(report.get(), "lkg_persisted", cJSON_IsTrue(lkg_persisted));
      if (!error.empty()) json::set(report.get(), "last_error", error);
      cJSON* reported_elements = json::addArr(report.get(), "elements");
      const cJSON* element = nullptr;
      cJSON_ArrayForEach(element, elements) {
        const std::string id = cJSON_IsString(element) && element->valuestring
            ? element->valuestring : "";
        if (id.empty() || id.size() > 128)
          return HttpResp::json("{\"ok\":false,\"err\":\"invalid semantic element\"}", 400);
        for (char ch : id) {
          if (!(std::isalnum(static_cast<unsigned char>(ch)) || ch == '.' || ch == '_' ||
                ch == '-'))
            return HttpResp::json("{\"ok\":false,\"err\":\"invalid semantic element\"}", 400);
        }
        json::push(reported_elements, json::Doc(cJSON_CreateString(id.c_str())));
      }
      json::set(report.get(), "updated_at_ms", hlc->correctedWallMs());
      web_ui_style_report_json = json::dump(report.get());
      scheduleSnapshotRefresh();
      return HttpResp::json("{\"ok\":true}");
    });



    httpd->route("GET", "/api/panel/i18n", [this](const HttpReq& req) {
      if (!panelTokenOk(req)) return HttpResp::json("{\"ok\":false,\"err\":\"bad token\"}", 403);
      auto o = json::obj();
      json::setBool(o.get(), "ok", true);
      cJSON* arr = json::addArr(o.get(), "languages");
      cJSON* langs = cfgAt("ui.languages");
      if (cJSON_IsArray(langs)) {
        cJSON* l = nullptr;
        cJSON_ArrayForEach(l, langs) {
          if (cJSON_IsString(l)) json::push(arr, json::Doc(cJSON_CreateString(l->valuestring)));
        }
      }
      if (cJSON_GetArraySize(arr) == 0) json::push(arr, json::Doc(cJSON_CreateString("ja")));
      cJSON* ov = json::get(cfg.get(), "i18n_overrides");
      if (ov) {
        json::setItem(o.get(), "overrides", json::Doc(cJSON_Duplicate(ov, 1)));
      } else {
        json::addObj(o.get(), "overrides");
      }
      return HttpResp::json(json::dump(o.get()));
    });

    httpd->route("POST", "/api/panel/press", [this](const HttpReq& req) {
      if (!panelTokenOk(req)) return HttpResp::json("{\"ok\":false,\"err\":\"bad token\"}", 403);
      std::string door = req.param("door");
      if (door.empty() || !cfgAt("doors." + door))
        return HttpResp::json("{\"ok\":false,\"err\":\"unknown door\"}", 400);
      std::string purpose = req.param("purpose");
      if (!purpose.empty() && !purposeSelectable(purpose))
        return HttpResp::json("{\"ok\":false,\"err\":\"unknown purpose\"}", 400);
      const std::string call_id = doPress(door, purpose);
      if (call_id.empty())
        return HttpResp::json(
            "{\"ok\":false,\"err\":\"event_persistence_failed\"}", 500);
      auto o = json::obj();
      json::setBool(o.get(), "ok", true);
      json::set(o.get(), "call_id", call_id);
      auto active = active_calls.find(door);
      if (active != active_calls.end() && active->second.call_id == call_id) {
        json::set(o.get(), "call_state", active->second.state);
        json::set(o.get(), "stage_revision",
                  static_cast<int64_t>(active->second.stage_revision));
        json::set(o.get(), "expires_at_ms", active->second.expires_wall_ms);
      }
      return HttpResp::json(json::dump(o.get()));
    });

    httpd->route("POST", "/api/panel/purpose", [this](const HttpReq& req) {
      if (!panelTokenOk(req)) return HttpResp::json("{\"ok\":false,\"err\":\"bad token\"}", 403);
      const std::string door = req.param("door");
      if (effectiveCallFlow(door.empty() ? opts.door : door) != "ring_then_purpose")
        return HttpResp::json("{\"ok\":false,\"err\":\"call flow unsupported\"}", 409);
      const std::string call_id = req.param("call_id");
      if (!doSelectPurpose(door, call_id, req.param("purpose")))
        return HttpResp::json("{\"ok\":false,\"err\":\"stale call\"}", 409);
      auto out = json::obj();
      json::setBool(out.get(), "ok", true);
      json::set(out.get(), "call_id", call_id);
      auto active = active_calls.find(door.empty() ? opts.door : door);
      if (active != active_calls.end())
        json::set(out.get(), "stage_revision",
                  static_cast<int64_t>(active->second.stage_revision));
      return HttpResp::json(json::dump(out.get()));
    });

    httpd->route("POST", "/api/panel/reply", [this](const HttpReq& req) {
      if (!panelTokenOk(req)) return HttpResp::json("{\"ok\":false,\"err\":\"bad token\"}", 403);
      const std::string door = req.param("door").empty() ? opts.door : req.param("door");
      const std::string reply_id = req.param("reply_id");
      if (door.empty() || !cfgAt("doors." + door))
        return HttpResp::json("{\"ok\":false,\"err\":\"unknown door\"}", 400);
      cJSON* configured_reply = cfgAt("quick_replies." + reply_id);
      if (reply_id.empty() || !cJSON_IsObject(configured_reply) ||
          !cJSON_IsObject(json::get(configured_reply, "label")))
        return HttpResp::json("{\"ok\":false,\"err\":\"unknown reply\"}", 400);
      const std::string revision_text = req.param("stage_revision");
      int revision = -1;
      try {
        size_t consumed = 0;
        revision = std::stoi(revision_text, &consumed);
        if (consumed != revision_text.size()) revision = -1;
      } catch (...) {
        revision = -1;
      }
      if (revision < 0)
        return HttpResp::json("{\"ok\":false,\"err\":\"invalid stage revision\"}", 400);
      auto active = active_calls.find(door);
      if (active == active_calls.end() || active->second.call_id != req.param("call_id") ||
          active->second.stage_revision != revision || active->second.state == "in_call")
        return HttpResp::json("{\"ok\":false,\"err\":\"stale call\"}", 409);
      if (!quickReply(reply_id, "", door, "web_panel", req.param("call_id"), revision))
        return HttpResp::json("{\"ok\":false,\"err\":\"stale call\"}", 409);
      auto out = json::obj();
      json::setBool(out.get(), "ok", true);
      json::set(out.get(), "call_id", req.param("call_id"));
      return HttpResp::json(json::dump(out.get()));
    });

    httpd->route("POST", "/api/panel/cancel", [this](const HttpReq& req) {
      if (!panelTokenOk(req)) return HttpResp::json("{\"ok\":false,\"err\":\"bad token\"}", 403);
      const std::string door = req.param("door").empty() ? opts.door : req.param("door");
      if (!doorFeature(door, "call_cancel_v2") ||
          !doorManifestSupports(door, "cancel.call"))
        return HttpResp::json("{\"ok\":false,\"err\":\"cancel unsupported\"}", 409);
      if (!doCancelCall(req.param("door"), req.param("call_id"), "visitor"))
        return HttpResp::json("{\"ok\":false,\"err\":\"stale call\"}", 409);
      return HttpResp::json("{\"ok\":true}");
    });

    httpd->route("POST", "/api/panel/call-lifecycle", [this](const HttpReq& req) {
      if (!panelTokenOk(req)) return HttpResp::json("{\"ok\":false,\"err\":\"bad token\"}", 403);
      const std::string door = req.param("door").empty() ? opts.door : req.param("door");
      const std::string owner = webDialogOwner(req.param("dialog_id"));
      if (owner.empty())
        return HttpResp::json("{\"ok\":false,\"err\":\"invalid dialog identity\"}", 400);
      const std::string revision_text = req.param("stage_revision");
      int revision = -1;
      try {
        size_t consumed = 0;
        revision = std::stoi(revision_text, &consumed);
        if (consumed != revision_text.size()) revision = -1;
      } catch (...) {
        revision = -1;
      }
      if (revision < 0)
        return HttpResp::json("{\"ok\":false,\"err\":\"invalid stage revision\"}", 400);
      const std::string state = req.param("state");
      bool ok = false;
      if (state == "answered") {
        ok = doReportCallAnswered(door, req.param("call_id"), revision, owner);
        if (ok) armWebDialogLease(door, req.param("call_id"), owner);
      } else if (state == "ended") {
        ok = doReportCallEnded(door, req.param("call_id"), revision,
                               req.param("reason").empty() ? "sip_ended" : req.param("reason"),
                               owner);
      } else if (state == "heartbeat") {
        auto active = active_calls.find(door);
        ok = active != active_calls.end() && active->second.call_id == req.param("call_id") &&
             active->second.stage_revision == revision && active->second.state == "in_call" &&
             active->second.dialog_owner == owner;
        if (ok) armWebDialogLease(door, req.param("call_id"), owner);
      } else {
        return HttpResp::json("{\"ok\":false,\"err\":\"invalid lifecycle state\"}", 400);
      }
      if (!ok) return HttpResp::json("{\"ok\":false,\"err\":\"stale call\"}", 409);
      auto response = json::obj();
      json::setBool(response.get(), "ok", true);
      json::set(response.get(), "dialog_owner", owner);
      return HttpResp::json(json::dump(response.get()));
    });

    httpd->route("POST", "/api/panel/hangup", [this](const HttpReq& req) {
      if (!panelTokenOk(req)) return HttpResp::json("{\"ok\":false,\"err\":\"bad token\"}", 403);
      const std::string door = req.param("door").empty() ? opts.door : req.param("door");
      if (!doorManifestSupports(door, "call.end"))
        return HttpResp::json("{\"ok\":false,\"err\":\"hangup unsupported\"}", 409);
      if (!doEndCall(door, req.param("call_id"), "visitor_hangup"))
        return HttpResp::json("{\"ok\":false,\"err\":\"call is not in progress\"}", 409);
      return HttpResp::json("{\"ok\":true}");
    });

    httpd->route("POST", "/api/panel/recovery", [this](const HttpReq& req) {
      if (!panelTokenOk(req)) return HttpResp::json("{\"ok\":false,\"err\":\"bad token\"}", 403);
      const std::string call_id = req.param("call_id");
      const std::string door = req.param("door");
      auto active = active_calls.find(door.empty() ? opts.door : door);
      if (call_id.empty() || active == active_calls.end() ||
          active->second.call_id != call_id || active->second.recovery_timer == 0 ||
          active->second.recovery_kind != RecoveryLeaseKind::LocalProcess)
        return HttpResp::json("{\"ok\":false,\"err\":\"no recovery pending\"}", 409);
      const std::string restored = req.param("restored");
      const bool did_restore = restored == "1" || restored == "true";
      if (active->second.state == "in_call" && did_restore) {
        if (!localWebDialogOwner(active->second.dialog_owner))
          return HttpResp::json(
              "{\"ok\":false,\"err\":\"native dialog recovery requires platform ABI\"}",
              409);
        const std::string owner = webDialogOwner(req.param("dialog_id"));
        if (owner.empty() || owner != active->second.dialog_owner)
          return HttpResp::json("{\"ok\":false,\"err\":\"wrong dialog owner\"}", 409);
      }
      if (!resolveCallRecovery(call_id, did_restore))
        return HttpResp::json("{\"ok\":false,\"err\":\"no recovery pending\"}", 409);
      if (did_restore && active->second.state == "in_call" &&
          localWebDialogOwner(active->second.dialog_owner))
        armWebDialogLease(active->second.door, call_id, active->second.dialog_owner);
      return HttpResp::json("{\"ok\":true}");
    });


    httpd->route("POST", "/api/panel/visitor-lang", [this](const HttpReq& req) {
      if (!panelTokenOk(req)) return HttpResp::json("{\"ok\":false,\"err\":\"bad token\"}", 403);
      const std::string lang = req.param("lang");
      if (lang.empty()) return HttpResp::json("{\"ok\":false,\"err\":\"no lang\"}", 400);
      const std::string door = req.param("door");
      if (!door.empty() && !cfgAt("doors." + door))
        return HttpResp::json("{\"ok\":false,\"err\":\"unknown door\"}", 400);
      doSetVisitorLang(door, lang);
      return HttpResp::json("{\"ok\":true}");
    });



    httpd->route("POST", "/api/panel/emergency", [this](const HttpReq& req) {
      if (!panelTokenOk(req)) return HttpResp::json("{\"ok\":false,\"err\":\"bad token\"}", 403);
      const std::string act = req.param("active");
      if (act == "0" || act == "false")
        return HttpResp::json("{\"ok\":false,\"err\":\"cancel not allowed\"}", 403);
      if (!doEmergency(true, "web"))
        return HttpResp::json(
            "{\"ok\":false,\"err\":\"event_persistence_failed\"}", 500);
      return HttpResp::json("{\"ok\":true}");
    });

    httpd->route("GET", "/snapshot-proxy", [this](const HttpReq& req) {
      if (!panelTokenOk(req)) return HttpResp::json("{\"ok\":false,\"err\":\"bad token\"}", 403);
      std::string door = req.param("door");

      std::string target;
      cJSON* devices = json::get(cfg.get(), "devices");
      cJSON* it = nullptr;
      cJSON_ArrayForEach(it, devices) {
        if (!it->string) continue;
        if (json::getString(it, "role") == "door_station" && json::getString(it, "door") == door) {
          target = it->string;
          break;
        }
      }
      if (target.empty()) return HttpResp::json("{\"ok\":false,\"err\":\"no station\"}", 404);
      if (target == node_id) {
        Bytes jpg = frame_bus.latestJpeg();
        if (jpg.empty()) return HttpResp::json("{\"ok\":false,\"err\":\"no frame\"}", 503);
        HttpResp r;
        r.content_type = "image/jpeg";
        r.body.assign(jpg.begin(), jpg.end());
        r.headers["Cache-Control"] = "no-store";
        return r;
      }

      if (mesh) {
        for (const auto& p : mesh->peers()) {
          if (p.id == target && !p.addrs.empty()) {
            HttpResp r;
            r.status = 302;
            r.headers["Location"] = "http://" + hostOf(p.addrs[0]) + ":47180/snapshot.jpg";
            r.headers["Cache-Control"] = "no-store";
            return r;
          }
        }
      }
      return HttpResp::json("{\"ok\":false,\"err\":\"station offline\"}", 503);
    });





    httpd->route("GET", "/api/panel/call-info", [this](const HttpReq& req) {
      if (!panelTokenOk(req)) return HttpResp::json("{\"ok\":false,\"err\":\"bad token\"}", 403);
      auto o = json::obj();
      json::setBool(o.get(), "ok", true);
      cJSON* w = json::addObj(o.get(), "webrtc");
      cJSON* wc = cfgAt("integrations.webrtc");
      json::set(w, "ws_url", json::getString(wc, "ws_url"));
      json::set(w, "sip_user", json::getString(wc, "sip_user"));
      json::set(w, "sip_pass", referencedSecret(wc, "sip_pass_ref"));
      json::set(w, "server", json::getString(json::get(cfg.get(), "sip"), "server"));
      cJSON* doors = json::addObj(o.get(), "doors");
      cJSON* dcfg = json::get(cfg.get(), "doors");
      cJSON* it = nullptr;
      cJSON_ArrayForEach(it, dcfg) {
        if (!it->string) continue;
        cJSON* e = json::addObj(doors, it->string);

        std::string station;
        cJSON* devices = json::get(cfg.get(), "devices");
        cJSON* dev = nullptr;
        cJSON_ArrayForEach(dev, devices) {
          if (dev->string && json::getString(dev, "role") == "door_station" &&
              json::getString(dev, "door") == it->string) {
            station = dev->string;
            break;
          }
        }
        if (station.empty()) continue;
        json::set(e, "source_node_id", station);
        json::setItem(e, "playback_profile", playbackProfileDoc(node_id, station));
        json::set(e, "extension", json::getString(cfgAt("sip.accounts." + station), "user"));
        if (station == node_id) {
          json::set(e, "station", "");
          json::set(e, "stream_mjpeg", "/stream.mjpeg");
          if (json::getString(json::get(json::get(cfgAt("devices." + station), "local"),
                                             "camera"), "codec", "auto") != "mjpeg")
            json::set(e, "stream_mp4", "/stream.mp4");
          json::setBool(e, "online", true);
        } else if (mesh) {
          for (const auto& p : mesh->peers()) {
            if (p.id == station && !p.addrs.empty()) {
              const std::string origin = "http://" + hostOf(p.addrs[0]) + ":47180";
              json::set(e, "station", origin);
              json::set(e, "stream_mjpeg", origin + "/stream.mjpeg");
              if (json::getString(json::get(json::get(cfgAt("devices." + station), "local"),
                                                   "camera"), "codec", "auto") != "mjpeg")
                json::set(e, "stream_mp4", origin + "/stream.mp4");
              json::setBool(e, "online", p.status != "dead");
            }
          }
        }
      }
      return HttpResp::json(json::dump(o.get()));
    });




    httpd->route("POST", "/call-frame", [this](const HttpReq& req) {
      auto cors = [](HttpResp r) {
        r.headers["Access-Control-Allow-Origin"] = "*";
        return r;
      };
      if (!panelTokenOk(req))
        return cors(HttpResp::json("{\"ok\":false,\"err\":\"bad token\"}", 403));
      const std::string door = req.param("door");
      if (opts.role != "door_station" || (!door.empty() && door != opts.door))
        return cors(HttpResp::json("{\"ok\":false,\"err\":\"not this station\"}", 404));
      if (sip_call != SipCallState::InCall)
        return cors(HttpResp::json("{\"ok\":false,\"err\":\"not in call\"}", 409));

      if (req.body.size() < 4 || static_cast<uint8_t>(req.body[0]) != 0xFF ||
          static_cast<uint8_t>(req.body[1]) != 0xD8)
        return cors(HttpResp::json("{\"ok\":false,\"err\":\"not jpeg\"}", 400));
      peer_frame.assign(req.body.begin(), req.body.end());
      peer_frame_mono = clock->monoMs();
      return cors(HttpResp::json("{\"ok\":true}"));
    });
    httpd->route("OPTIONS", "/call-frame", [](const HttpReq&) {
      HttpResp r;
      r.status = 204;
      r.body = "";
      r.headers["Access-Control-Allow-Origin"] = "*";
      r.headers["Access-Control-Allow-Methods"] = "POST, OPTIONS";
      r.headers["Access-Control-Allow-Headers"] = "Authorization, Content-Type";
      r.headers["Access-Control-Max-Age"] = "600";
      return r;
    });



    httpd->route("GET", "/peer-frame.jpg", [this](const HttpReq&) {
      if (peer_frame.empty() || clock->monoMs() - peer_frame_mono > 3000)
        return HttpResp::json("{\"ok\":false,\"err\":\"no frame\"}", 404);
      HttpResp r;
      r.content_type = "image/jpeg";
      r.body.assign(peer_frame.begin(), peer_frame.end());
      r.headers["Cache-Control"] = "no-store";
      return r;
    });
  }

  // Panel bearer values never appear in URLs. APIs accept only the revocable HttpOnly session.
  bool panelTokenOk(const HttpReq& req) {
    const std::string session = req.cookie("dbpanel");
    if (!session.empty()) {
      const PanelCredentialBinding current = panelCredentialBinding();
      std::lock_guard<std::mutex> lk(sess_mu);
      auto existing = panel_sessions.find(session);
      if (existing != panel_sessions.end()) {
        if (samePanelCredentialBinding(existing->second, current)) return true;
        panel_sessions.erase(existing);
      }
    }
    const auto auth = req.headers.find("authorization");
    const std::string prefix = "Bearer ";
    return auth != req.headers.end() && auth->second.rfind(prefix, 0) == 0 &&
           panelCredentialOk(auth->second.substr(prefix.size()));
  }

  bool setKey(const std::string& key, const std::string& value) {
    auto v = json::parse(value);
    if (v) {
      config->set(key, value);
    } else {
      auto s = json::Doc(cJSON_CreateString(value.c_str()));
      config->set(key, json::dump(s.get()));
    }
    return config->lastMutationCommitted();
  }

  std::string doPress(const std::string& door_arg, const std::string& purpose_arg) {
    std::string door = door_arg.empty() ? opts.door : door_arg;
    // A door station showing a purpose an administrator has since switched off is stale. Ring
    // anyway, without the purpose: refusing the call outright would punish the visitor for it.
    const std::string purpose =
        (!purpose_arg.empty() && purposeSelectable(purpose_arg)) ? purpose_arg : std::string();
    auto existing = active_calls.find(door);
    if (existing != active_calls.end() && existing->second.state == "in_call")
      return existing->second.call_id;
    if (existing != active_calls.end() &&
        existing->second.expires_wall_ms > hlc->correctedWallMs())
      return existing->second.call_id;  // retry of a press while its call is still active
    if (existing != active_calls.end() &&
        !doCancelCall(door, existing->second.call_id, "timeout"))
      return "";
    const std::string call_id = genTokenHex(16);
    auto p = json::obj();
    json::set(p.get(), "schema_version", static_cast<int64_t>(2));
    json::set(p.get(), "call_id", call_id);
    json::set(p.get(), "stage_revision", static_cast<int64_t>(0));
    json::set(p.get(), "expires_at_ms", hlc->correctedWallMs() + callTtlMs());
    if (!purpose.empty()) json::set(p.get(), "purpose", purpose);
    const std::string vlang = visitorLangFor(door);
    if (vlang != "ja") json::set(p.get(), "visitor_lang", vlang);
    const EventRecord pressed = events->append("press", door, node_id, json::dump(p.get()));
    return pressed.seq == 0 ? "" : call_id;
  }

  bool doSelectPurpose(const std::string& door_arg, const std::string& call_id,
                       const std::string& purpose) {
    if (purpose.empty() || !purposeSelectable(purpose)) return false;
    const std::string door = door_arg.empty() ? opts.door : door_arg;
    auto it = active_calls.find(door);
    if (it == active_calls.end() || it->second.call_id != call_id ||
        it->second.state != "ringing" || cancelled_call_ids.count(call_id))
      return false;
    if (it->second.purpose == purpose && it->second.stage_revision > 0) return true;
    auto p = json::obj();
    json::set(p.get(), "schema_version", static_cast<int64_t>(2));
    json::set(p.get(), "call_id", call_id);
    const int revision = it->second.stage_revision + 1;
    json::set(p.get(), "stage_revision", static_cast<int64_t>(revision));
    json::set(p.get(), "expires_at_ms", it->second.expires_wall_ms);
    json::set(p.get(), "purpose", purpose);
    const std::string vlang = visitorLangFor(door);
    if (vlang != "ja") json::set(p.get(), "visitor_lang", vlang);
    const EventRecord selected =
        events->append("purpose_selected", door, node_id, json::dump(p.get()));
    auto projection = store.callProjection(call_id);
    return projection && projection->door == door && projection->state == "ringing" &&
           projection->stage_revision == revision && projection->purpose == purpose &&
           projection->updated_hlc == selected.hlc;
  }

  bool doCancelCall(const std::string& door_arg, const std::string& call_id,
                    const std::string& reason) {
    const std::string door = door_arg.empty() ? opts.door : door_arg;
    if (call_id.empty()) return false;
    if (cancelled_call_ids.count(call_id)) return true;
    auto it = active_calls.find(door);
    if (it == active_calls.end() || it->second.call_id != call_id) {
      auto projection = store.callProjection(call_id);
      return projection && projection->door == door && projection->state == "cancelled";
    }
    if (it->second.state == "in_call" && reason != "recovery_failed" &&
        reason != "recovery_timeout")
      return false;
    auto p = json::obj();
    json::set(p.get(), "schema_version", static_cast<int64_t>(2));
    json::set(p.get(), "call_id", call_id);
    json::set(p.get(), "stage_revision", static_cast<int64_t>(it->second.stage_revision));
    json::set(p.get(), "reason", reason);
    const EventRecord cancelled =
        events->append("call_cancelled", door, node_id, json::dump(p.get()));
    if (cancelled.seq == 0) return false;
    auto projection = store.callProjection(call_id);
    return projection && projection->door == door && projection->state == "cancelled" &&
           projection->updated_hlc == cancelled.hlc;
  }

  bool doEndCall(const std::string& door_arg, const std::string& call_id,
                 const std::string& reason) {
    const std::string door = door_arg.empty() ? opts.door : door_arg;
    if (call_id.empty()) return false;
    auto it = active_calls.find(door);
    if (it == active_calls.end() || it->second.call_id != call_id ||
        it->second.state != "in_call" || it->second.dialog_owner.empty())
      return false;
    auto p = json::obj();
    json::set(p.get(), "schema_version", static_cast<int64_t>(2));
    json::set(p.get(), "call_id", call_id);
    json::set(p.get(), "stage_revision", static_cast<int64_t>(it->second.stage_revision));
    json::set(p.get(), "reason", reason);
    json::set(p.get(), "requested_by", node_id);
    // The accepted dialog owner remains the lifecycle authority. A visitor-side End action is
    // represented as an owner-scoped terminal event so a losing SIP leg can never resolve it.
    const EventRecord ended =
        events->append("call_ended", door, it->second.dialog_owner, json::dump(p.get()));
    if (ended.seq == 0) return false;
    auto projection = store.callProjection(call_id);
    return projection && projection->door == door && projection->state == "ended" &&
           projection->updated_hlc == ended.hlc;
  }

  bool doReportCallAnswered(const std::string& door_arg, const std::string& call_id,
                            int stage_revision, const std::string& reporter = "",
                            bool retry_on_persistence_failure = false) {
    const std::string door = door_arg.empty() ? opts.door : door_arg;
    const std::string owner = reporter.empty() ? node_id : reporter;
    if (call_id.empty() || stage_revision < 0) return false;
    auto it = active_calls.find(door);
    if (it == active_calls.end() || it->second.call_id != call_id ||
        it->second.stage_revision != stage_revision)
      return false;
    if (it->second.state == "in_call") return it->second.dialog_owner == owner;
    if (it->second.state != "ringing") return false;
    auto p = json::obj();
    json::set(p.get(), "schema_version", static_cast<int64_t>(2));
    json::set(p.get(), "call_id", call_id);
    json::set(p.get(), "call_origin", it->second.origin);
    json::set(p.get(), "stage_revision", static_cast<int64_t>(stage_revision));
    json::set(p.get(), "expires_at_ms", it->second.expires_wall_ms);
    if (!it->second.purpose.empty()) json::set(p.get(), "purpose", it->second.purpose);
    if (events->append("call_answered", door, owner, json::dump(p.get())).seq == 0) {
      if (retry_on_persistence_failure) queuePendingAnswer(it->second, owner);
      return false;
    }
    auto accepted = active_calls.find(door);
    return accepted != active_calls.end() && accepted->second.call_id == call_id &&
           accepted->second.stage_revision == stage_revision &&
           accepted->second.state == "in_call" && accepted->second.dialog_owner == owner;
  }

  bool doReportCallEnded(const std::string& door_arg, const std::string& call_id,
                         int stage_revision, const std::string& reason,
                         const std::string& reporter = "",
                         bool retry_on_persistence_failure = false) {
    const std::string door = door_arg.empty() ? opts.door : door_arg;
    const std::string owner = reporter.empty() ? node_id : reporter;
    if (call_id.empty() || stage_revision < 0) return false;
    auto it = active_calls.find(door);
    if (it == active_calls.end()) {
      auto projection = store.callProjection(call_id);
      return projection && projection->door == door &&
             projection->stage_revision == stage_revision && projection->state == "ended" &&
             projection->dialog_owner == owner;
    }
    if (it->second.call_id != call_id || it->second.stage_revision != stage_revision ||
        it->second.state != "in_call" || it->second.dialog_owner != owner)
      return false;
    auto p = json::obj();
    json::set(p.get(), "schema_version", static_cast<int64_t>(2));
    json::set(p.get(), "call_id", call_id);
    json::set(p.get(), "stage_revision", static_cast<int64_t>(stage_revision));
    json::set(p.get(), "reason", reason.empty() ? "sip_ended" : reason.substr(0, 64));
    const EventRecord ended = events->append("call_ended", door, owner, json::dump(p.get()));
    if (ended.seq == 0) {
      if (retry_on_persistence_failure) queuePendingEnd(it->second, owner, reason);
      return false;
    }
    auto projection = store.callProjection(call_id);
    return projection && projection->door == door && projection->state == "ended" &&
           projection->stage_revision == stage_revision &&
           projection->dialog_owner == owner && projection->updated_hlc == ended.hlc;
  }

  void flushPendingLifecycle(const std::string& call_id) {
    auto pending_it = pending_lifecycles.find(call_id);
    if (pending_it == pending_lifecycles.end()) return;
    if (!pendingLifecycleIdentityValid(pending_it->second)) {
      abandonPendingLifecycle(call_id);
      return;
    }

    PendingLifecycle pending = pending_it->second;
    auto active = active_calls.find(pending.door);
    if (pending.answer_pending) {
      if (active->second.state == "ringing") {
        if (!doReportCallAnswered(pending.door, call_id, pending.stage_revision,
                                  pending.owner, /*retry_on_persistence_failure=*/false)) {
          active = active_calls.find(pending.door);
          if (active != active_calls.end() && active->second.call_id == call_id &&
              active->second.stage_revision == pending.stage_revision &&
              active->second.state == "ringing") {
            schedulePendingLifecycleRetry(call_id);
            return;
          }
          abandonPendingLifecycle(call_id);
          return;
        }
      } else if (active->second.dialog_owner != pending.owner) {
        abandonPendingLifecycle(call_id);
        return;
      }
      pending_it = pending_lifecycles.find(call_id);
      if (pending_it == pending_lifecycles.end()) return;
      pending_it->second.answer_pending = false;
      pending_it->second.retry_step = 0;
    }

    pending_it = pending_lifecycles.find(call_id);
    if (pending_it == pending_lifecycles.end()) return;
    if (!pending_it->second.end_pending) {
      finishPendingLifecycle(call_id);
      return;
    }
    pending = pending_it->second;
    active = active_calls.find(pending.door);
    if (active == active_calls.end() || active->second.call_id != call_id ||
        active->second.stage_revision != pending.stage_revision ||
        active->second.state != "in_call" || active->second.dialog_owner != pending.owner) {
      abandonPendingLifecycle(call_id);
      return;
    }
    if (!doReportCallEnded(pending.door, call_id, pending.stage_revision,
                           pending.end_reason, pending.owner,
                           /*retry_on_persistence_failure=*/false)) {
      active = active_calls.find(pending.door);
      if (active != active_calls.end() && active->second.call_id == call_id &&
          active->second.stage_revision == pending.stage_revision &&
          active->second.state == "in_call" && active->second.dialog_owner == pending.owner) {
        schedulePendingLifecycleRetry(call_id);
        return;
      }
      abandonPendingLifecycle(call_id);
      return;
    }
    finishPendingLifecycle(call_id);
  }
};



Node::Node(NodeOptions opts, NodeDeps deps) : impl_(new Impl) {
  impl_->opts = std::move(opts);
  impl_->pairing_persistence_ready = std::any_of(
      impl_->opts.psk.begin(), impl_->opts.psk.end(), [](uint8_t byte) { return byte != 0; });
  impl_->measured_caps_json = impl_->opts.caps_json;
  impl_->ui_manifest_json = "{}";
  if (deps.clock) {
    impl_->clock = deps.clock;
  } else {
    impl_->owned_clock.reset(new RealClock);
    impl_->clock = impl_->owned_clock.get();
  }
  if (deps.loop) {
    impl_->loop = deps.loop;
    impl_->external_loop = true;
  } else {
    impl_->owned_loop.reset(new Runloop(*impl_->clock));
    impl_->loop = impl_->owned_loop.get();
  }
  impl_->transport = std::move(deps.transport);
  impl_->discovery = std::move(deps.discovery);
}

Node::~Node() { stop(); }

bool Node::start() {
  if (impl_->started) return true;
  if (!impl_->external_loop) impl_->loop->start();
  bool ok = false;
  impl_->loop->callSync([&] { ok = impl_->init(); });
  if (ok) node_id_ = impl_->node_id;
  return ok;
}

void Node::stop() {
  if (!impl_ || !impl_->started) return;
  impl_->started = false;
  // The SNTP worker holds a raw pointer to Impl, so it is stopped before anything else is torn
  // down. It observes the abort flag between exchanges and each exchange is bounded.
  impl_->stopTimeSync();
#ifdef _WIN32

  if (impl_->camera) impl_->camera->stop();
  if (impl_->encoder) impl_->encoder->stop();
#endif


  impl_->video_track.stop();

  impl_->loop->callSync([&] {
    impl_->stopQrScanOnLoop();
    impl_->stopNetMonitor();
    if (impl_->sip_reapply_timer) {
      impl_->loop->cancel(impl_->sip_reapply_timer);
      impl_->sip_reapply_timer = 0;
    }
    if (impl_->dtmf_timer) {
      impl_->loop->cancel(impl_->dtmf_timer);
      impl_->dtmf_timer = 0;
    }
    if (impl_->bridge_reapply_timer) {
      impl_->loop->cancel(impl_->bridge_reapply_timer);
      impl_->bridge_reapply_timer = 0;
    }
    if (impl_->display_timer) {
      impl_->loop->cancel(impl_->display_timer);
      impl_->display_timer = 0;
    }
    if (impl_->event_retention_timer) {
      impl_->loop->cancel(impl_->event_retention_timer);
      impl_->event_retention_timer = 0;
    }
    if (impl_->minute_timer) {
      impl_->loop->cancel(impl_->minute_timer);
      impl_->minute_timer = 0;
    }
    impl_->cancelTimeSyncTimer();
    impl_->time_sync_armed = false;
    impl_->time_sync_backoff_s = 0;
    if (impl_->peers_emit_timer) {
      impl_->loop->cancel(impl_->peers_emit_timer);
      impl_->peers_emit_timer = 0;
    }
    if (impl_->snapshot_timer) {
      impl_->loop->cancel(impl_->snapshot_timer);
      impl_->snapshot_timer = 0;
    }
    if (impl_->asset_prefetch_timer) {
      impl_->loop->cancel(impl_->asset_prefetch_timer);
      impl_->asset_prefetch_timer = 0;
    }
#ifdef _WIN32
    if (impl_->encoder_timer) {
      impl_->loop->cancel(impl_->encoder_timer);
      impl_->encoder_timer = 0;
    }
#endif
    for (auto& kv : impl_->visitor_lang_revert_timer) impl_->loop->cancel(kv.second);
    impl_->visitor_lang_revert_timer.clear();
    for (auto& entry : impl_->active_calls) {
      if (entry.second.timeout_timer) impl_->loop->cancel(entry.second.timeout_timer);
      if (entry.second.recovery_timer) impl_->loop->cancel(entry.second.recovery_timer);
      entry.second.timeout_timer = 0;
      entry.second.recovery_timer = 0;
    }
    for (const auto& entry : impl_->web_dialog_timers)
      if (entry.second.timer) impl_->loop->cancel(entry.second.timer);
    impl_->web_dialog_timers.clear();
    for (const auto& entry : impl_->pending_lifecycles)
      if (entry.second.retry_timer) impl_->loop->cancel(entry.second.retry_timer);
    impl_->pending_lifecycles.clear();
    if (impl_->tg) impl_->tg->stop();
    if (impl_->bridge) impl_->bridge->stop();  // availability=offline (retain) → DISCONNECT
    if (impl_->sipctl) impl_->sipctl->stop();
  });

  if (impl_->httpd) impl_->httpd->stop();
  impl_->loop->callSync([&] {
    if (impl_->mesh) impl_->mesh->stop();
    if (impl_->discovery) impl_->discovery->stop();
  });
  if (!impl_->external_loop) impl_->loop->stop();
}

void Node::setUiEventCb(UiEventCb cb) {
  std::lock_guard<std::mutex> lk(impl_->cb_mu);
  impl_->ui_cb = std::move(cb);
}

void Node::setTtsCb(TtsCb cb) {
  std::lock_guard<std::mutex> lk(impl_->cb_mu);
  impl_->tts_cb = std::move(cb);
}

void Node::setHttpsFn(HttpsFn fn) {
  std::lock_guard<std::mutex> lk(impl_->cb_mu);
  impl_->https_fn = std::move(fn);
}

void Node::setDeviceInfoFn(DeviceInfoFn fn) {

  impl_->device_info_fn = std::move(fn);
}

void Node::setSecureStore(SecureGetFn get, SecurePutFn put) {
  std::lock_guard<std::mutex> lk(impl_->cb_mu);
  impl_->secure_get_fn = std::move(get);
  impl_->secure_put_fn = std::move(put);
}

void Node::setSecureDelete(SecureDeleteFn del) {
  std::lock_guard<std::mutex> lk(impl_->cb_mu);
  impl_->secure_delete_fn = std::move(del);
}

void Node::setPowerStateFn(PowerStateFn fn) {
  {
    std::lock_guard<std::mutex> lk(impl_->cb_mu);
    impl_->power_state_fn = std::move(fn);
  }
  impl_->loop->post([this] { impl_->pollPowerState(); });
}

void Node::setRuntimeCapabilities(const std::string& capabilities_json) {
  auto parsed = json::parse(capabilities_json);
  if (!parsed || !cJSON_IsObject(parsed.get()) || capabilities_json.size() > 64 * 1024) return;
  impl_->loop->post([this, capabilities_json] {
    impl_->measured_caps_json = capabilities_json;
    impl_->applyEffectiveCaps();
    impl_->notifyPendingRecoveries();
  });
}

void Node::setRuntimeStatus(const std::string& runtime_json) {
  auto parsed = json::parse(runtime_json);
  if (!parsed || !cJSON_IsObject(parsed.get()) || runtime_json.size() > 64 * 1024) return;
  impl_->loop->post([this, runtime_json] {
    impl_->runtime_status_json = runtime_json;
    impl_->publishMeshRuntime();
    impl_->scheduleSnapshotRefresh();
  });
}

void Node::setUiManifest(const std::string& manifest_json) {
  auto parsed = json::parse(manifest_json);
  if (!parsed || !cJSON_IsObject(parsed.get()) || manifest_json.size() > 128 * 1024) return;
  std::string error;
  if (parsed->child && !uiManifestValid(manifest_json, &error)) {
    DB_LOGE(kTag, "rejected ui_manifest: " + error);
    return;
  }
  impl_->loop->post([this, manifest_json] {
    impl_->ui_manifest_json = manifest_json;
    impl_->applyEffectiveCaps();
    if (impl_->mesh) impl_->mesh->setUiManifest(manifest_json);
    impl_->scheduleSnapshotRefresh();
  });
}

std::string Node::capabilitiesJson() {
  std::string out;
  impl_->loop->callSync([&] { out = impl_->capabilitiesJsonOnLoop(); });
  return out;
}

void Node::press(const std::string& door_id, const std::string& purpose) {
  (void)pressV2(door_id, purpose);
}

void Node::selectPurpose(const std::string& door_id, const std::string& purpose) {
  std::string d = door_id;
  std::string p = purpose;
  impl_->loop->post([this, d, p] {
    const std::string door = d.empty() ? impl_->opts.door : d;
    auto it = impl_->active_calls.find(door);
    if (it != impl_->active_calls.end()) impl_->doSelectPurpose(door, it->second.call_id, p);
  });
}

void Node::cancelCall(const std::string& door_id) {
  std::string d = door_id;
  impl_->loop->post([this, d] {
    const std::string door = d.empty() ? impl_->opts.door : d;
    auto it = impl_->active_calls.find(door);
    if (it != impl_->active_calls.end()) impl_->doCancelCall(door, it->second.call_id, "visitor");
  });
}

std::string Node::pressV2(const std::string& door_id, const std::string& purpose) {
  std::string id;
  impl_->loop->callSync([&] { id = impl_->doPress(door_id, purpose); });
  return id;
}

bool Node::selectPurposeV2(const std::string& door_id, const std::string& call_id,
                           const std::string& purpose) {
  bool ok = false;
  impl_->loop->callSync([&] { ok = impl_->doSelectPurpose(door_id, call_id, purpose); });
  return ok;
}

bool Node::cancelCallV2(const std::string& door_id, const std::string& call_id,
                        const std::string& reason) {
  bool ok = false;
  impl_->loop->callSync([&] { ok = impl_->doCancelCall(door_id, call_id, reason); });
  return ok;
}

bool Node::reportCallAnsweredV2(const std::string& door_id, const std::string& call_id,
                                int stage_revision) {
  bool ok = false;
  impl_->loop->callSync([&] {
    ok = impl_->doReportCallAnswered(door_id, call_id, stage_revision, "",
                                     /*retry_on_persistence_failure=*/true);
  });
  return ok;
}

bool Node::reportCallEndedV2(const std::string& door_id, const std::string& call_id,
                             int stage_revision, const std::string& reason) {
  bool ok = false;
  impl_->loop->callSync([&] {
    ok = impl_->doReportCallEnded(door_id, call_id, stage_revision, reason, "",
                                  /*retry_on_persistence_failure=*/true);
  });
  return ok;
}

void Node::reportCallRecovery(const std::string& call_id, bool restored) {
  impl_->loop->post([this, call_id, restored] {
    impl_->resolveCallRecovery(call_id, restored);
  });
}

void Node::setVisitorLang(const std::string& door_id, const std::string& lang) {
  std::string d = door_id;
  std::string l = lang;
  impl_->loop->post([this, d, l] { impl_->doSetVisitorLang(d, l); });
}

std::string Node::addAsset(const Bytes& data, const std::string& type,
                           const std::string& label) {
  std::string hash;
  impl_->loop->callSync([&] { hash = impl_->addAssetOnLoop(data, type, label); });
  return hash;
}

std::string Node::text(const std::string& key, const std::string& lang,
                       const TextArgs& args) const {
  std::string out;
  impl_->loop->callSync([&] { out = impl_->textOnLoop(key, lang, args); });
  return out;
}

std::string Node::assetPath(const std::string& hash) {
  std::string path;
  impl_->loop->callSync([&] {
    if (impl_->assetCached(hash)) path = impl_->assetFilePath(hash);
  });
  return path;
}

void Node::pushCameraFrame(const uint8_t* data, int format, int width, int height, int stride,
                           int64_t ts_ms) {
  if (!data || width <= 0 || height <= 0) return;
  size_t n = rawFrameBytes(format, width, height, stride);
  if (n == 0) return;
  RawFrame f;
  f.format = format;
  f.w = width;
  f.h = height;
  f.stride = stride;
  f.ts_ms = ts_ms;
  f.data.assign(data, data + n);
  {
    std::lock_guard<std::mutex> lk(impl_->motion_mu);
    impl_->motion.feed(f);
  }
  // Scan mode reuses this pipeline; submit() only copies a frame and returns.
  impl_->qr_scanner.submit(f);
  impl_->frame_bus.push(std::move(f));
}

void Node::startQrScan() {
  impl_->loop->callSync([&] { impl_->startQrScanOnLoop(); });
}

void Node::stopQrScan() {
  impl_->loop->callSync([&] { impl_->stopQrScanOnLoop(); });
}

void Node::pushEncodedFrame(const uint8_t* annexb, size_t len, bool key, int64_t ts_ms) {

  impl_->pushVideoTrack(annexb, len, key, ts_ms);
}

bool Node::videoEncoderWanted() {
  return impl_->video_track.enabled() && impl_->video_track.subscriberCount() > 0;
}

void Node::setVideoSensorRotation(int degrees) {
  const int rotation = Impl::normalizeRotation(degrees);
  if (impl_->sensor_video_rotation.exchange(rotation) == rotation) return;
  impl_->loop->post([this] {
    impl_->applyVideoRotation();
    impl_->scheduleSnapshotRefresh();
  });
}

void Node::sendQuickReply(const std::string& reply_id, const std::string& free_text,
                          const std::string& door_id, const std::string& via) {
  std::string rid = reply_id;
  std::string txt = free_text;
  std::string d = door_id;
  std::string v = via;
  impl_->loop->post([this, rid, txt, d, v] { impl_->quickReply(rid, txt, d, v); });
}

bool Node::sendQuickReplyV2(const std::string& reply_id, const std::string& free_text,
                            const std::string& door_id, const std::string& call_id,
                            int stage_revision) {
  bool ok = false;
  impl_->loop->callSync([&] {
    ok = impl_->quickReply(reply_id, free_text, door_id, "app", call_id, stage_revision);
  });
  return ok;
}

void Node::setEmergency(bool active, const std::string& via) {
  (void)setEmergencyV2(active, via);
}

bool Node::setEmergencyV2(bool active, const std::string& via) {
  bool ok = false;
  impl_->loop->callSync([&] { ok = impl_->doEmergency(active, via); });
  return ok;
}

std::string Node::statusJson() {
  std::lock_guard<std::mutex> lk(impl_->snap_mu);
  if (impl_->status_snap.empty()) return "{}";
  return impl_->status_snap;
}

std::string Node::callLogJson(int64_t since_ms, int limit) {
  return callLogJson(since_ms, 0, limit);
}

std::string Node::callLogJson(int64_t since_ms, int64_t before_ms, int limit) {
  Store::CallLogQuery query;
  query.since_ms = since_ms > 0 ? since_ms : 0;
  query.before_ms = before_ms > 0 ? before_ms : 0;
  query.limit = limit > 0 ? static_cast<size_t>(limit) : kCallLogDefaultLimit;
  query.limit = std::min<size_t>(query.limit, kCallLogMaxLimit);
  std::string out;
  // A core that was created but never started has no store to read; report an empty history
  // rather than touching uninitialized composition state.
  if (!impl_->loop->callSync([&] {
        if (impl_->started) out = impl_->callLogJson(query);
      }) ||
      out.empty())
    out = R"({"rows":[],"unread_missed":0,"seen_hlc":"","server_ts":0})";
  return out;
}

bool Node::markCallLogSeen(const std::string& up_to_hlc) {
  bool ok = false;
  if (!impl_->loop->callSync([&] {
        if (impl_->started) ok = impl_->markCallLogSeen(up_to_hlc);
      }))
    return false;
  return ok;
}

std::string Node::debugJson() {
  std::string out;
  impl_->loop->callSync([&] { out = impl_->debugJsonOnLoop(); });
  return out;
}

std::string Node::configJson() {
  std::lock_guard<std::mutex> lk(impl_->snap_mu);
  if (impl_->config_snap.empty()) return "{}";
  return impl_->config_snap;
}

std::string Node::localTimeJson(int64_t wall_ms) {
  // Served from the published record: never enters the run loop, safe from any thread. Only the
  // instant is read live, so a one-second clock still advances once a second while the loop is
  // busy synchronizing time or building a status document.
  auto snap = std::atomic_load(&impl_->time_snap);
  return Impl::renderLocalTime(*snap, wall_ms, impl_->clock->wallMs());
}

std::string Node::audioJson(const std::string& device_id) {
  auto snap = std::atomic_load(&impl_->audio_snap);
  return Impl::resolveAudioJson(*snap, device_id);
}

bool Node::syncTimeNow() {
  bool started = false;
  impl_->loop->callSync([&] { started = impl_->startTimeSync(); });
  return started;
}

bool Node::setDoorNotice(const std::string& door, const std::string& text, int64_t expires_ms) {
  bool ok = false;
  impl_->loop->callSync([&] { ok = impl_->setDoorNoticeOnLoop(door, text, expires_ms); });
  return ok;
}

bool Node::clearDoorNotice(const std::string& door) {
  bool ok = false;
  impl_->loop->callSync([&] { ok = impl_->clearDoorNoticeOnLoop(door); });
  return ok;
}

bool Node::openDoor(const std::string& door) {
  bool ok = false;
  impl_->loop->callSync([&] { ok = impl_->openDoorOnLoop(door); });
  return ok;
}

std::string Node::lastWriteWarningsJson() {
  std::lock_guard<std::mutex> lk(impl_->last_warnings_mu);
  return impl_->last_write_warnings_json;
}

std::string Node::setConfigJson(const std::string& key, const std::string& value_json) {
  std::string out;
  if (!impl_->loop->callSync(
          [&] { out = impl_->setConfigJsonOnLoop(key, value_json, nullptr); }))
    return R"({"ok":false,"err":"not_started"})";
  return out;
}

std::string Node::configBatchJson(const std::string& ops_json) {
  std::string out;
  if (!impl_->loop->callSync([&] { out = impl_->configBatchJsonOnLoop(ops_json, nullptr); }))
    return R"({"ok":false,"err":"not_started"})";
  return out;
}

std::string Node::deleteConfigKeyJson(const std::string& key) {
  std::string out;
  if (!impl_->loop->callSync([&] { out = impl_->deleteConfigKeyJsonOnLoop(key, nullptr); }))
    return R"({"ok":false,"err":"not_started"})";
  return out;
}

void Node::setConfigKey(const std::string& key, const std::string& value_json) {
  auto parsed = json::parse(value_json);
  if (!parsed) parsed = json::Doc(cJSON_CreateString(value_json.c_str()));
  impl_->loop->callSync([&] {
    std::string error;
    if (!impl_->configWriteValidEffective(key, parsed.get(), &error)) {
      DB_LOGE(kTag, "refused unsafe programmatic config write: " + key + " (" + error + ")");
      return;
    }
    if (!impl_->setKey(key, value_json))
      DB_LOGE(kTag, "programmatic config write was not persisted: " + key);
  });
}

std::string Node::pairingJson() {
  // C2: the snapshot must be live. Countdowns tick over db_core_pairing_json, so a cached copy
  // would freeze the PIN timer and the pending list on every shell that polls it.
  std::string fresh;
  if (impl_->loop->callSync([&] { fresh = impl_->pairingJsonOnLoop(); }) && !fresh.empty()) {
    std::lock_guard<std::mutex> lk(impl_->snap_mu);
    impl_->pairing_snap = fresh;
    return fresh;
  }
  std::lock_guard<std::mutex> lk(impl_->snap_mu);
  if (impl_->pairing_snap.empty()) return "{}";
  return impl_->pairing_snap;
}

bool Node::foundCluster() {
  bool ok = false;
  impl_->loop->callSync([&] {
    if (impl_->mesh) ok = impl_->mesh->foundCluster();
  });
  return ok;
}

void Node::joinCluster(const std::string& host, const std::string& pin) {
  std::string h = host;
  std::string p = pin;
  impl_->loop->post([this, h, p] {
    if (!impl_->mesh) return;
    auto done = [this](bool ok, const std::string& err) {
      impl_->pairing_joining = false;
      if (ok) {
        // Mesh calls onBecamePaired on the next statement; it emits join_result once the
        // secure-store outcome is known, so a failed write is never reported as a success.
        impl_->pairing_join_awaiting_persist = true;
        return;
      }
      impl_->emitJoinResult(false, err);
      // A failed join leaves the node unpaired, so the state has to be republished.
      impl_->emitPairingState();
    };
    // Never fail silently: an already-paired node reports why it refused.
    if (impl_->mesh->isPaired()) {
      done(false, "already_paired");
      return;
    }
    impl_->pairing_joining = true;
    impl_->emitPairingState();
    impl_->mesh->joinCluster(h, p, done);
  });
}

void Node::setPairingMode(int seconds) {
  int s = seconds;
  impl_->loop->post([this, s] {
    // An unpaired node has no cluster key to hand out, so pairing mode would do nothing.
    if (!impl_->mesh || (!impl_->mesh->isPaired() && s > 0)) return;
    impl_->mesh->setPairingMode(static_cast<int64_t>(s) * 1000);
  });
}

void Node::denyDevice(const std::string& id) {
  std::string did = id;
  impl_->loop->post([this, did] {
    if (impl_->mesh) impl_->mesh->denyDevice(did);
  });
}

bool Node::retryPairingPersistence() {
  bool ok = false;
  impl_->loop->callSync([&] { ok = impl_->retryPairingPersistence(); });
  return ok;
}

void Node::unpair() {
  impl_->loop->callSync([&] { impl_->unpairOnLoop(); });
}

bool Node::inviteFromQrText(const std::string& text) {
  bool ok = false;
  std::string t = text;
  impl_->loop->callSync([&] { ok = impl_->inviteFromQrOnLoop(t); });
  return ok;
}

void Node::removeDevice(const std::string& target) {
  impl_->loop->post([this, target] {
    if (!impl_->mesh || impl_->opts.role != "indoor_panel" || target.empty() ||
        target == node_id_)
      return;
    const auto peers = impl_->mesh->peers();
    const auto it = std::find_if(peers.begin(), peers.end(), [&](const PeerInfo& peer) {
      return peer.id == target && peer.connected;
    });
    if (it == peers.end()) return;
    auto command = json::obj();
    json::set(command.get(), "cmd", "pairing_revoked");
    json::set(command.get(), "target", target);
    impl_->mesh->sendCommand(target, json::dump(command.get()));
  });
}

std::string Node::startPairingJson(int seconds) {
  std::string out;
  impl_->loop->callSync([&] { out = impl_->startPairingJsonOnLoop(seconds); });
  return out;
}

std::string Node::parsePairUriJson(const std::string& uri) {
  // Corrected cluster time when the node has a clock, the platform clock otherwise: a shell may
  // scan a code before core has started. The shared clock carries the time-service correction in
  // an atomic, so this needs no trip through the run loop.
  int64_t now_unix_s =
      impl_->clock ? impl_->clock->wallMs() / 1000
                   : std::chrono::duration_cast<std::chrono::seconds>(
                         std::chrono::system_clock::now().time_since_epoch())
                         .count();
  const pair_uri::Parsed parsed = pair_uri::parse(uri, now_unix_s);
  auto out = json::obj();
  json::setBool(out.get(), "ok", parsed.ok);
  if (!parsed.ok) {
    json::set(out.get(), "err", parsed.err);
    return json::dump(out.get());
  }
  json::set(out.get(), "host", parsed.host);
  json::set(out.get(), "pin", parsed.pin);
  json::set(out.get(), "exp", parsed.exp);
  json::set(out.get(), "cluster", parsed.cluster);
  return json::dump(out.get());
}

std::string Node::mintJoinTokenJson(int seconds) {
  std::string out;
  impl_->loop->callSync([&] { out = impl_->mintJoinTokenJsonOnLoop(seconds); });
  return out;
}

void Node::inviteDevice(const std::string& id) {
  std::string did = id;
  impl_->loop->post([this, did] {
    if (impl_->mesh) impl_->mesh->inviteDevice(did);
  });
}

void Node::inviteDeviceDirect(const std::string& addr, const std::string& id,
                              const std::string& pk) {
  (void)id;
  std::string a = addr;
  std::string p = pk;
  impl_->loop->post([this, a, p] {
    if (impl_->mesh) impl_->mesh->inviteDeviceDirect(a, p);
  });
}

Runloop& Node::loop() { return *impl_->loop; }



void Node::sipCall(const std::string& target, const std::string& mode) {
  impl_->loop->callSync([&] {
    if (impl_->sipctl) impl_->sipctl->call(target, mode);
  });
}

void Node::sipHangup() {
  impl_->loop->callSync([&] {
    if (impl_->sipctl) impl_->sipctl->hangup();
  });
}

void Node::setSipMicMuted(bool muted) {
  impl_->loop->callSync([&] {
    impl_->mic_muted_without_sip = muted;
    if (impl_->sipctl) impl_->sipctl->setMicMuted(muted);
    // Rebuild the published snapshot before returning: a toggle that reads its own state back
    // immediately must not see the previous position.
    if (impl_->started && impl_->loop->onLoopThread()) impl_->refreshSnapshots();
    else impl_->scheduleSnapshotRefresh();
  });
}

bool Node::sipMicMuted() {
  bool muted = false;
  impl_->loop->callSync([&] {
    muted = impl_->sipctl ? impl_->sipctl->micMuted() : impl_->mic_muted_without_sip;
  });
  return muted;
}

int Node::verifyAdminPassword(const std::string& password) {
  return impl_->verifyAdminPassword(password);
}

int Node::setAdminPassword(const std::string& current, const std::string& next) {
  return impl_->setAdminPassword(current, next);
}

bool Node::sipSendDtmf(const std::string& digits) {
  bool ok = false;
  impl_->loop->callSync([&] {
    if (impl_->sipctl) ok = impl_->sipctl->sendDtmf(digits);
  });
  return ok;
}

}  // namespace db
