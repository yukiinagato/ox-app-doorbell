#include "util/common.h"

#include <cerrno>
#include <cstdio>
#include <stdexcept>

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <bcrypt.h>
#include <direct.h>
#else
#include <sys/stat.h>
#include <sys/types.h>
#endif

namespace db {

static const char* kHex = "0123456789abcdef";

std::string hexEncode(const uint8_t* data, size_t len) {
  std::string out;
  out.reserve(len * 2);
  for (size_t i = 0; i < len; i++) {
    out.push_back(kHex[data[i] >> 4]);
    out.push_back(kHex[data[i] & 0xf]);
  }
  return out;
}

static int hexVal(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

bool hexDecode(const std::string& hex, Bytes& out) {
  if (hex.size() % 2 != 0) return false;
  Bytes tmp;
  tmp.reserve(hex.size() / 2);
  for (size_t i = 0; i < hex.size(); i += 2) {
    int hi = hexVal(hex[i]), lo = hexVal(hex[i + 1]);
    if (hi < 0 || lo < 0) return false;
    tmp.push_back(static_cast<uint8_t>((hi << 4) | lo));
  }
  out = std::move(tmp);
  return true;
}

Bytes randomBytes(size_t n) {
  Bytes out(n);
  if (n == 0) return out;
#if defined(_WIN32)
  // CNG のシステム既定 RNG (Win7 SP1+)。暗号用途可。
  NTSTATUS st = BCryptGenRandom(nullptr, out.data(), static_cast<ULONG>(n),
                                BCRYPT_USE_SYSTEM_PREFERRED_RNG);
  if (!BCRYPT_SUCCESS(st)) throw std::runtime_error("randomBytes: BCryptGenRandom failed");
#else
  FILE* f = std::fopen("/dev/urandom", "rb");
  if (!f || std::fread(out.data(), 1, n, f) != n) {
    if (f) std::fclose(f);
    throw std::runtime_error("randomBytes: /dev/urandom unavailable");
  }
  std::fclose(f);
#endif
  return out;
}

bool makeDir(const std::string& path) {
#if defined(_WIN32)
  return ::_mkdir(path.c_str()) == 0 || errno == EEXIST;
#else
  return ::mkdir(path.c_str(), 0755) == 0 || errno == EEXIST;
#endif
}

}  // namespace db
