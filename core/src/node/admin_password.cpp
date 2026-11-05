#include "node/admin_password.h"

#include <mutex>
#include <new>
#include <vector>

#include "monocypher.h"
#include "util/common.h"
#include "util/ids.h"

namespace db {
namespace admin_password {
namespace {

constexpr uint32_t kCurrentMKib = 8192;
constexpr uint32_t kCurrentT = 3;
constexpr uint32_t kCurrentP = 1;
// Upper bounds for replicated parameters, so a hostile record cannot demand gigabytes.
constexpr uint32_t kMaxMKib = 65536;
constexpr uint32_t kMaxT = 10;

std::mutex g_argon2_mu;

bool equalConstantTime(const std::string& a, const std::string& b) {
  if (a.size() != b.size() || a.empty()) return false;
  unsigned char diff = 0;
  for (size_t i = 0; i < a.size(); ++i)
    diff = static_cast<unsigned char>(diff | (static_cast<unsigned char>(a[i]) ^
                                              static_cast<unsigned char>(b[i])));
  return diff == 0;
}

}  // namespace

std::string argon2idHex(const std::string& password, const std::string& salt_hex,
                        uint32_t m_kib, uint32_t t, uint32_t p) {
  Bytes salt;
  if (!hexDecode(salt_hex, salt) || salt.size() < 8 || m_kib < 8 * p || m_kib > kMaxMKib ||
      t < 1 || t > kMaxT || p != 1)
    return "";
  std::lock_guard<std::mutex> lock(g_argon2_mu);
  std::vector<uint8_t> work;
  try {
    work.resize(static_cast<size_t>(m_kib) * 1024);
  } catch (const std::bad_alloc&) {
    return "";
  }
  crypto_argon2_config config;
  config.algorithm = CRYPTO_ARGON2_ID;
  config.nb_blocks = m_kib;
  config.nb_passes = t;
  config.nb_lanes = p;
  crypto_argon2_inputs inputs;
  inputs.pass = reinterpret_cast<const uint8_t*>(password.data());
  inputs.pass_size = static_cast<uint32_t>(password.size());
  inputs.salt = salt.data();
  inputs.salt_size = static_cast<uint32_t>(salt.size());
  uint8_t out[32];
  crypto_argon2(out, sizeof(out), work.data(), config, inputs, crypto_argon2_no_extras);
  crypto_wipe(work.data(), work.size());
  return hexEncode(out, sizeof(out));
}

std::string legacyBlake2bHex(const std::string& password, const std::string& salt_hex) {
  Bytes salt;
  hexDecode(salt_hex, salt);
  Bytes buf = salt;
  buf.insert(buf.end(), password.begin(), password.end());
  uint8_t out[32];
  crypto_blake2b(out, sizeof(out), buf.data(), buf.size());
  crypto_wipe(buf.data(), buf.size());
  return hexEncode(out, sizeof(out));
}

Record create(const std::string& password) {
  Record record;
  record.algo = "argon2id";
  record.salt = genTokenHex(16);
  record.m_kib = kCurrentMKib;
  record.t = kCurrentT;
  record.p = kCurrentP;
  record.hash = argon2idHex(password, record.salt, record.m_kib, record.t, record.p);
  return record;
}

bool verify(const Record& record, const std::string& password) {
  if (record.salt.empty() || record.hash.empty()) return false;
  const std::string digest = record.algo == "argon2id"
      ? argon2idHex(password, record.salt, record.m_kib, record.t, record.p)
      : legacyBlake2bHex(password, record.salt);
  return equalConstantTime(digest, record.hash);
}

bool needsUpgrade(const Record& record) {
  return record.algo != "argon2id" || record.m_kib != kCurrentMKib || record.t != kCurrentT ||
         record.p != kCurrentP;
}

}  // namespace admin_password
}  // namespace db
