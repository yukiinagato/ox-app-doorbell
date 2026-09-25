#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <utility>
#include <vector>

namespace db {
namespace media_relay {

// All state in this header is owned by the Core runloop, not HTTP worker threads.
constexpr size_t kFrameBytes = 1024U * 1024U;
constexpr size_t kBase64Bytes = ((kFrameBytes + 2U) / 3U) * 4U;
constexpr size_t kWireBytes = kBase64Bytes + 4096U;
constexpr size_t kPublishers = 8;
constexpr size_t kRpcCapacity = 4;
constexpr size_t kQueuePublishers = 4;
constexpr int64_t kHttpMs = 3000;
constexpr int64_t kRpcMs = 2500;
constexpr int64_t kGrantMs = 10000;
constexpr int64_t kSweepMs = 50;

inline bool hexId(const std::string& value, size_t size = 32) {
  return value.size() == size && value.find_first_not_of("0123456789abcdef") == std::string::npos;
}

inline bool decimal(const std::string& text, uint64_t maximum, uint64_t* result,
                    bool allow_zero = false) {
  if (!result || text.empty() || text.size() > 19 || (text.size() > 1 && text[0] == '0')) return false;
  uint64_t value = 0;
  for (const char c : text) {
    if (c < '0' || c > '9') return false;
    const auto digit = static_cast<uint64_t>(c - '0');
    if (digit > maximum || value > (maximum - digit) / 10) return false;
    value = value * 10 + digit;
  }
  if (!allow_zero && value == 0) return false;
  *result = value;
  return true;
}

inline bool identifier(const std::string& value, size_t maximum = 192) {
  if (value.empty() || value.size() > maximum) return false;
  for (unsigned char c : value) if (c <= 0x20 || c == 0x7f) return false;
  return true;
}

inline bool contentType(const std::string& value, const std::string& expected) {
  if (value.size() > 256 || value.find_first_of("\r\n") != std::string::npos) return false;
  std::string type = value.substr(0, value.find(';'));
  const auto first = type.find_first_not_of(" \t"), last = type.find_last_not_of(" \t");
  if (first == std::string::npos) return false;
  type = type.substr(first, last - first + 1);
  for (char& c : type) if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
  return type == expected;
}

inline int hexDigit(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

inline bool urlDecode(const std::string& input, std::string* output) {
  output->clear();
  for (size_t i = 0; i < input.size(); ++i) {
    unsigned char c = static_cast<unsigned char>(input[i]);
    if (c == '%') {
      if (i + 2 >= input.size()) return false;
      const int hi = hexDigit(input[i + 1]), lo = hexDigit(input[i + 2]);
      if (hi < 0 || lo < 0) return false;
      c = static_cast<unsigned char>((hi << 4) | lo);
      i += 2;
    } else if (c == '+') c = ' ';
    if (c < 0x20 || c == 0x7f) return false;
    output->push_back(static_cast<char>(c));
  }
  return true;
}

// Only a fixed identity tuple can cross this API; there is no URL/host/port/path parameter.
inline bool query(const std::string& text, bool frame, std::map<std::string, std::string>* output) {
  output->clear();
  if (text.empty() || text.size() > 2048) return false;
  const std::set<std::string> allowed = frame
      ? std::set<std::string>{"door", "call_id", "stage_revision", "media_generation", "frame_sequence"}
      : std::set<std::string>{"door", "call_id", "stage_revision"};
  size_t begin = 0;
  while (begin < text.size()) {
    const size_t amp = text.find('&', begin);
    const size_t end = amp == std::string::npos ? text.size() : amp;
    const size_t eq = text.find('=', begin);
    if (eq == std::string::npos || eq >= end) return false;
    std::string key, value;
    if (!urlDecode(text.substr(begin, eq - begin), &key) ||
        !urlDecode(text.substr(eq + 1, end - eq - 1), &value) ||
        allowed.count(key) == 0 || value.empty() || !output->emplace(key, value).second) return false;
    if (end == text.size()) break;
    begin = end + 1;
    if (begin == text.size()) return false;
  }
  return output->size() == allowed.size();
}

inline bool canonicalBase64(const std::string& input, size_t* decoded_size) {
  if (!decoded_size || input.empty() || input.size() > kBase64Bytes || input.size() % 4) return false;
  auto value = [](char c) -> int {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
  };
  size_t padding = input.back() == '=' ? 1 : 0;
  if (padding && input[input.size() - 2] == '=') ++padding;
  for (size_t i = 0; i < input.size() - padding; ++i) if (value(input[i]) < 0) return false;
  if (padding == 2 && (value(input[input.size() - 3]) & 15)) return false;
  if (padding == 1 && (value(input[input.size() - 2]) & 3)) return false;
  *decoded_size = input.size() / 4 * 3 - padding;
  return *decoded_size <= kFrameBytes;
}

// Preflight is allocation-free. Baseline sequential JPEG only: one scan and bounded metadata.
// The production adapter additionally performs a bounded stb decode before accepting the slot.
// Rejecting progressive/multiscan images bounds codec work on legacy devices.
inline bool jpegEnvelope(const std::string& bytes) {
  if (bytes.size() < 16 || bytes.size() > kFrameBytes) return false;
  const auto u = [&](size_t at) { return static_cast<unsigned char>(bytes[at]); };
  if (u(0) != 0xff || u(1) != 0xd8 || u(bytes.size() - 2) != 0xff || u(bytes.size() - 1) != 0xd9)
    return false;
  size_t pos = 2, segments = 0;
  bool sof = false, scan = false, quantization = false, huffman = false;
  while (pos < bytes.size()) {
    if (u(pos++) != 0xff) return false;
    while (pos < bytes.size() && u(pos) == 0xff) ++pos;
    if (pos == bytes.size()) return false;
    const unsigned marker = u(pos++);
    if (++segments > 128 || marker == 0 || marker == 0xd8) return false;
    if (marker == 0xd9) return scan && sof && quantization && huffman && pos == bytes.size();
    if (marker >= 0xd0 && marker <= 0xd7) return false;
    if (pos + 2 > bytes.size()) return false;
    const size_t length = (u(pos) << 8) | u(pos + 1);
    if (length < 2 || length > bytes.size() - pos) return false;
    if (marker >= 0xc0 && marker <= 0xcf && marker != 0xc4 && marker != 0xc8 && marker != 0xcc) {
      if (marker != 0xc0 || sof || length < 11 || u(pos + 2) != 8) return false;
      const unsigned height = (u(pos + 3) << 8) | u(pos + 4);
      const unsigned width = (u(pos + 5) << 8) | u(pos + 6);
      const unsigned components = u(pos + 7);
      if (height == 0 || width == 0 || height > 1024 || width > 1024 ||
          height * width > 307200 || (components != 1 && components != 3) ||
          length != 8 + components * 3) return false;
      sof = true;
    }
    if (marker == 0xdb) quantization = true;
    if (marker == 0xc4) huffman = true;
    pos += length;
    if (marker != 0xda) continue;
    if (!sof || scan || !quantization || !huffman) return false;
    scan = true;
    // Only escaped FF, restart markers and the final EOI may follow this scan header.
    while (pos + 1 < bytes.size()) {
      if (u(pos++) != 0xff) continue;
      const unsigned next = u(pos);
      if (next == 0 || (next >= 0xd0 && next <= 0xd7)) { ++pos; continue; }
      --pos;
      break;
    }
  }
  return false;
}

struct Bucket {
  int64_t updated = 0;
  int64_t milli_tokens = 2000;
  bool initialized = false;
  bool take(int64_t now, int per_second = 10, int burst = 2) {
    if (!initialized) { updated = now; milli_tokens = static_cast<int64_t>(burst) * 1000; initialized = true; }
    const int64_t elapsed = now > updated ? std::min<int64_t>(now - updated, 10000) : 0;
    milli_tokens = std::min<int64_t>(static_cast<int64_t>(burst) * 1000, milli_tokens + elapsed * per_second);
    updated = std::max(updated, now);
    if (milli_tokens < 1000) return false;
    milli_tokens -= 1000;
    return true;
  }
};

// Callbacks belong to the adapter. Removing work returns ownership before a callback can reenter.
template<class Work>
class LatestQueue {
 public:
  using Item = std::shared_ptr<Work>;
  struct Slot { Item active, pending; };
  enum class Admission { Start, Pending, Replaced, Full };
  Admission offer(const std::string& publisher, const Item& item, Item* replaced) {
    replaced->reset();
    auto found = slots_.find(publisher);
    if (found == slots_.end()) {
      if (slots_.size() >= kQueuePublishers) return Admission::Full;
      slots_.emplace(publisher, Slot{item, {}});
      return Admission::Start;
    }
    *replaced = std::move(found->second.pending);
    found->second.pending = item;
    return *replaced ? Admission::Replaced : Admission::Pending;
  }
  Item finish(const std::string& publisher, const Item& expected) {
    auto found = slots_.find(publisher);
    if (found == slots_.end() || found->second.active != expected) return {};
    Item next = std::move(found->second.pending);
    if (next) found->second.active = next;
    else slots_.erase(found);
    return next;
  }
  std::vector<Item> remove(const std::string& publisher) {
    std::vector<Item> result;
    auto found = slots_.find(publisher);
    if (found == slots_.end()) return result;
    if (found->second.active) result.push_back(std::move(found->second.active));
    if (found->second.pending) result.push_back(std::move(found->second.pending));
    slots_.erase(found);
    return result;
  }
  std::vector<Item> clear() {
    std::vector<Item> result;
    while (!slots_.empty()) {
      auto items = remove(slots_.begin()->first);
      result.insert(result.end(), items.begin(), items.end());
    }
    return result;
  }
  const std::map<std::string, Slot>& slots() const { return slots_; }
  size_t size() const { return slots_.size(); }
 private:
  std::map<std::string, Slot> slots_;
};

}  // namespace media_relay
}  // namespace db
