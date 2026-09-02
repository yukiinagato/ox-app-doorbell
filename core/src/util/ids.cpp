#include "util/ids.h"

#include <cstdio>

#include "util/common.h"

namespace db {

std::string genNodeId() {
  Bytes b = randomBytes(16);
  return hexEncode(b);
}

std::string genPin6() {

  for (;;) {
    Bytes b = randomBytes(4);
    uint32_t v = (uint32_t(b[0]) << 24) | (uint32_t(b[1]) << 16) | (uint32_t(b[2]) << 8) |
                 uint32_t(b[3]);
    if (v < 4'000'000'000u) {
      char buf[8];
      std::snprintf(buf, sizeof(buf), "%06u", v % 1'000'000u);
      return std::string(buf);
    }
  }
}

std::string genTokenHex(size_t n_bytes) { return hexEncode(randomBytes(n_bytes)); }

}  // namespace db
