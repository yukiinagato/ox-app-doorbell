#include "sensors/mops_vida.h"

namespace db {
namespace mops_vida {
namespace {

constexpr uint8_t kMagic = 0xAA;
constexpr uint8_t kTypeUpdate = 0x50;
constexpr uint8_t kTypeVersion = 0x54;
constexpr uint8_t kUpdateBattery = 0x04;
constexpr uint8_t kUpdateSensor = 0x06;

uint32_t be16(const uint8_t* p) { return (uint32_t{p[0]} << 8) | p[1]; }

bool checksumValid(const uint8_t* data, size_t len) {
  uint32_t sum = 0;
  for (size_t i = 0; i + 1 < len; i++) sum += data[i];
  return (sum & 0xFF) == data[len - 1];
}

}  // namespace

Packet parse(const uint8_t* data, size_t len) {
  Packet out;
  if (!data || len < 3 || data[0] != kMagic || !checksumValid(data, len)) return out;
  out.kind = PacketKind::other;
  const uint8_t type = data[1];
  if (type == kTypeUpdate && len >= 4) {
    const uint8_t sub = data[2];
    if (sub == kUpdateSensor && len >= 6) {
      out.kind = PacketKind::sensor;
      out.pm25 = static_cast<int>(be16(data + 3));
    } else if (sub == kUpdateBattery && len >= 8) {
      const int capacity = data[3];
      out.kind = PacketKind::battery;
      out.battery_pct = capacity > 100 ? 100 : capacity;
      out.charging = data[6] != 0;
    }
  } else if (type == kTypeVersion && len >= 7) {
    out.kind = PacketKind::version;
    out.firmware = std::to_string(be16(data + 4)) + "." + std::to_string(be16(data + 2));
  }
  return out;
}

std::vector<uint8_t> setRtcCommand(int64_t wall_ms) {
  const int64_t seconds = wall_ms > 0 ? wall_ms / 1000 : 0;
  const uint32_t ts = seconds > 0xFFFFFFFFLL ? 0xFFFFFFFFu : static_cast<uint32_t>(seconds);
  std::vector<uint8_t> out = {kMagic, 0x09, static_cast<uint8_t>(ts >> 24),
                              static_cast<uint8_t>(ts >> 16), static_cast<uint8_t>(ts >> 8),
                              static_cast<uint8_t>(ts)};
  uint32_t sum = 0;
  for (uint8_t b : out) sum += b;
  out.push_back(static_cast<uint8_t>(sum & 0xFF));
  return out;
}

std::string toHex(const std::vector<uint8_t>& bytes) {
  static const char* digits = "0123456789abcdef";
  std::string out;
  out.reserve(bytes.size() * 2);
  for (uint8_t b : bytes) {
    out.push_back(digits[b >> 4]);
    out.push_back(digits[b & 0x0F]);
  }
  return out;
}

}  // namespace mops_vida

namespace air_quality {

const char* levelFor(int pm25) {
  if (pm25 < 0) return "unknown";
  if (pm25 <= 9) return "good";
  if (pm25 <= 35) return "moderate";
  if (pm25 <= 55) return "sensitive";
  if (pm25 <= 125) return "unhealthy";
  if (pm25 <= 225) return "very_unhealthy";
  return "hazardous";
}

}  // namespace air_quality
}  // namespace db
