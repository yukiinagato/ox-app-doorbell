#pragma once

// MOPS·VIDA PM2.5 Watchdog (model AD520-P001) Bluetooth LE protocol. The device advertises the
// 16-bit service 0x7676 and exposes a Nordic UART Service: commands are written to RX and every
// notification on TX carries exactly one framed packet:
//
//   AA <type> [<subtype>] <payload…> <checksum = sum of all preceding bytes & 0xFF>
//
// Reference: github.com/CursedHardware/mops-vida-pm-watchdog, docs/protocol-design.md. Shells do
// only GATT plumbing and hand raw notification bytes to Core, so the framing is parsed once.

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace db {
namespace mops_vida {

constexpr const char* kKind = "mops_vida_pm25";
constexpr const char* kAdvertisedService = "7676";
constexpr const char* kUartService = "6e400001-b5a3-f393-e0a9-e50e24dcca9e";
constexpr const char* kRxCharacteristic = "6e400002-b5a3-f393-e0a9-e50e24dcca9e";
constexpr const char* kTxCharacteristic = "6e400003-b5a3-f393-e0a9-e50e24dcca9e";
constexpr const char* kAdvertisedName = "\xE6\xB5\x8B\xE9\x9C\xBE\xE5\x8D\x95\xE5\x93\x81";

enum class PacketKind { invalid, other, battery, sensor, version };

struct Packet {
  PacketKind kind = PacketKind::invalid;
  int pm25 = -1;              // sensor: micrograms per cubic metre
  int battery_pct = -1;       // battery: 0..100
  bool charging = false;      // battery
  std::string firmware;       // version: "<major>.<minor>"
};

// Validates the header and checksum before reading any field; a short or corrupt packet is
// invalid, a well-formed packet this client does not use is other.
Packet parse(const uint8_t* data, size_t len);

// Set RTC (0x09) with a big-endian Unix timestamp. Sent once after notifications are enabled so
// the device's own measurement records carry the cluster time.
std::vector<uint8_t> setRtcCommand(int64_t wall_ms);

std::string toHex(const std::vector<uint8_t>& bytes);

}  // namespace mops_vida

namespace air_quality {

// Category for a PM2.5 concentration using the US EPA 2024 24-hour breakpoints, which are the
// only widely published scale with six bands: good <=9, moderate <=35, sensitive <=55,
// unhealthy <=125, very_unhealthy <=225, hazardous above. The device reports whole units, so
// the bands are compared on integers.
const char* levelFor(int pm25);

}  // namespace air_quality
}  // namespace db
