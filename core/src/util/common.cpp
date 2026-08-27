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

static const char* kB64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

std::string base64Encode(const uint8_t* data, size_t len) {
  std::string out;
  out.reserve(((len + 2) / 3) * 4);
  size_t i = 0;
  for (; i + 3 <= len; i += 3) {
    uint32_t v = (data[i] << 16) | (data[i + 1] << 8) | data[i + 2];
    out.push_back(kB64[(v >> 18) & 0x3f]);
    out.push_back(kB64[(v >> 12) & 0x3f]);
    out.push_back(kB64[(v >> 6) & 0x3f]);
    out.push_back(kB64[v & 0x3f]);
  }
  const size_t rest = len - i;
  if (rest == 1) {
    uint32_t v = data[i] << 16;
    out.push_back(kB64[(v >> 18) & 0x3f]);
    out.push_back(kB64[(v >> 12) & 0x3f]);
    out.push_back('=');
    out.push_back('=');
  } else if (rest == 2) {
    uint32_t v = (data[i] << 16) | (data[i + 1] << 8);
    out.push_back(kB64[(v >> 18) & 0x3f]);
    out.push_back(kB64[(v >> 12) & 0x3f]);
    out.push_back(kB64[(v >> 6) & 0x3f]);
    out.push_back('=');
  }
  return out;
}

static int b64Val(char c) {
  if (c >= 'A' && c <= 'Z') return c - 'A';
  if (c >= 'a' && c <= 'z') return c - 'a' + 26;
  if (c >= '0' && c <= '9') return c - '0' + 52;
  if (c == '+') return 62;
  if (c == '/') return 63;
  return -1;
}

bool base64Decode(const std::string& b64, Bytes& out) {
  if (b64.size() % 4 != 0) return false;
  Bytes tmp;
  tmp.reserve(b64.size() / 4 * 3);
  for (size_t i = 0; i < b64.size(); i += 4) {
    int pad = 0;
    uint32_t v = 0;
    for (int k = 0; k < 4; k++) {
      const char c = b64[i + k];
      if (c == '=') {  // '=' は末尾ブロックの後ろ 2 文字のみ許可
        if (i + 4 != b64.size() || k < 2) return false;
        pad++;
        v <<= 6;
        continue;
      }
      if (pad > 0) return false;  // '=' の後に通常文字は不可
      const int d = b64Val(c);
      if (d < 0) return false;
      v = (v << 6) | static_cast<uint32_t>(d);
    }
    tmp.push_back(static_cast<uint8_t>((v >> 16) & 0xff));
    if (pad < 2) tmp.push_back(static_cast<uint8_t>((v >> 8) & 0xff));
    if (pad < 1) tmp.push_back(static_cast<uint8_t>(v & 0xff));
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
