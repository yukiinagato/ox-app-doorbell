#include "util/common.h"

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <bcrypt.h>
#include <direct.h>
#else
#include <dirent.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
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
      if (c == '=') {
        if (i + 4 != b64.size() || k < 2) return false;
        pad++;
        v <<= 6;
        continue;
      }
      if (pad > 0) return false;
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

// ---------------- SHA-256 (FIPS 180-4) ----------------



namespace {

struct Sha256Ctx {
  uint32_t h[8];
  uint64_t total = 0;
  uint8_t buf[64];
  size_t buf_len = 0;
};

constexpr uint32_t kSha256K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
    0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
    0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
    0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
    0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
    0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
    0xc67178f2};

inline uint32_t rotr(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }

void sha256Init(Sha256Ctx& c) {
  static constexpr uint32_t h0[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                                     0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
  std::memcpy(c.h, h0, sizeof(h0));
  c.total = 0;
  c.buf_len = 0;
}

void sha256Block(Sha256Ctx& c, const uint8_t* p) {
  uint32_t w[64];
  for (int i = 0; i < 16; i++) {
    w[i] = (uint32_t(p[i * 4]) << 24) | (uint32_t(p[i * 4 + 1]) << 16) |
           (uint32_t(p[i * 4 + 2]) << 8) | uint32_t(p[i * 4 + 3]);
  }
  for (int i = 16; i < 64; i++) {
    const uint32_t s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
    const uint32_t s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
    w[i] = w[i - 16] + s0 + w[i - 7] + s1;
  }
  uint32_t a = c.h[0], b = c.h[1], cc = c.h[2], d = c.h[3];
  uint32_t e = c.h[4], f = c.h[5], g = c.h[6], h = c.h[7];
  for (int i = 0; i < 64; i++) {
    const uint32_t s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
    const uint32_t ch = (e & f) ^ (~e & g);
    const uint32_t t1 = h + s1 + ch + kSha256K[i] + w[i];
    const uint32_t s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
    const uint32_t maj = (a & b) ^ (a & cc) ^ (b & cc);
    const uint32_t t2 = s0 + maj;
    h = g; g = f; f = e; e = d + t1;
    d = cc; cc = b; b = a; a = t1 + t2;
  }
  c.h[0] += a; c.h[1] += b; c.h[2] += cc; c.h[3] += d;
  c.h[4] += e; c.h[5] += f; c.h[6] += g; c.h[7] += h;
}

void sha256Update(Sha256Ctx& c, const uint8_t* data, size_t len) {
  c.total += len;
  while (len > 0) {
    if (c.buf_len == 0 && len >= 64) {
      sha256Block(c, data);
      data += 64;
      len -= 64;
      continue;
    }
    const size_t take = std::min<size_t>(64 - c.buf_len, len);
    std::memcpy(c.buf + c.buf_len, data, take);
    c.buf_len += take;
    data += take;
    len -= take;
    if (c.buf_len == 64) {
      sha256Block(c, c.buf);
      c.buf_len = 0;
    }
  }
}

void sha256Final(Sha256Ctx& c, uint8_t out[32]) {
  const uint64_t bits = c.total * 8;
  const uint8_t one = 0x80;
  sha256Update(c, &one, 1);
  const uint8_t zero = 0x00;
  while (c.buf_len != 56) sha256Update(c, &zero, 1);
  uint8_t len_be[8];
  for (int i = 0; i < 8; i++) len_be[i] = static_cast<uint8_t>(bits >> (56 - 8 * i));
  sha256Update(c, len_be, 8);
  for (int i = 0; i < 8; i++) {
    out[i * 4] = static_cast<uint8_t>(c.h[i] >> 24);
    out[i * 4 + 1] = static_cast<uint8_t>(c.h[i] >> 16);
    out[i * 4 + 2] = static_cast<uint8_t>(c.h[i] >> 8);
    out[i * 4 + 3] = static_cast<uint8_t>(c.h[i]);
  }
}

}  // namespace

Bytes sha256(const uint8_t* data, size_t len) {
  Sha256Ctx c;
  sha256Init(c);
  if (len > 0) sha256Update(c, data, len);
  Bytes out(32);
  sha256Final(c, out.data());
  return out;
}

std::string sha256Hex(const uint8_t* data, size_t len) { return hexEncode(sha256(data, len)); }

Bytes randomBytes(size_t n) {
  Bytes out(n);
  if (n == 0) return out;
#if defined(_WIN32)

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

bool readFileBytes(const std::string& path, Bytes& out) {
  FILE* f = std::fopen(path.c_str(), "rb");
  if (!f) return false;
  Bytes tmp;
  char buf[8192];
  size_t n;
  while ((n = std::fread(buf, 1, sizeof(buf), f)) > 0) {
    tmp.insert(tmp.end(), buf, buf + n);
  }
  const bool ok = std::ferror(f) == 0;
  std::fclose(f);
  if (!ok) return false;
  out = std::move(tmp);
  return true;
}

bool writeFileBytes(const std::string& path, const Bytes& data) {

  const std::string tmp = path + ".tmp";
  FILE* f = std::fopen(tmp.c_str(), "wb");
  if (!f) return false;
  const bool wrote =
      data.empty() || std::fwrite(data.data(), 1, data.size(), f) == data.size();
  const bool closed = std::fclose(f) == 0;
  if (!wrote || !closed) {
    std::remove(tmp.c_str());
    return false;
  }
#if defined(_WIN32)
  ::MoveFileExA(tmp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING);
  return fileExists(path);
#else
  if (std::rename(tmp.c_str(), path.c_str()) != 0) {
    std::remove(tmp.c_str());
    return false;
  }
  return true;
#endif
}

bool removeFile(const std::string& path) { return std::remove(path.c_str()) == 0; }

bool fileExists(const std::string& path) {
#if defined(_WIN32)
  const DWORD a = ::GetFileAttributesA(path.c_str());
  return a != INVALID_FILE_ATTRIBUTES && !(a & FILE_ATTRIBUTE_DIRECTORY);
#else
  struct stat st{};
  return ::stat(path.c_str(), &st) == 0 && S_ISREG(st.st_mode);
#endif
}

std::vector<std::string> listDir(const std::string& path) {
  std::vector<std::string> out;
#if defined(_WIN32)
  WIN32_FIND_DATAA fd{};
  HANDLE h = ::FindFirstFileA((path + "\\*").c_str(), &fd);
  if (h == INVALID_HANDLE_VALUE) return out;
  do {
    const std::string name = fd.cFileName;
    if (name != "." && name != "..") out.push_back(name);
  } while (::FindNextFileA(h, &fd));
  ::FindClose(h);
#else
  DIR* d = ::opendir(path.c_str());
  if (!d) return out;
  while (dirent* e = ::readdir(d)) {
    const std::string name = e->d_name;
    if (name != "." && name != "..") out.push_back(name);
  }
  ::closedir(d);
#endif
  return out;
}

std::string tempDir() {
#if defined(_WIN32)
  char buf[MAX_PATH + 1] = {0};
  DWORD n = ::GetTempPathA(sizeof(buf), buf);
  std::string p = n > 0 ? std::string(buf, n) : std::string(".");
  while (!p.empty() && (p.back() == '\\' || p.back() == '/')) p.pop_back();
  return p;
#else
  const char* t = std::getenv("TMPDIR");
  std::string p = t && *t ? t : "/tmp";
  while (p.size() > 1 && p.back() == '/') p.pop_back();
  return p;
#endif
}

}  // namespace db
