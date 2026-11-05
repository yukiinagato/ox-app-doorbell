// Administrator password digests. New digests are Argon2id; legacy BLAKE2b-256 digests verify
// once and are replaced after the next successful login. Hashing is deliberately slow and
// memory-hard, so it runs off the state loop and one computation at a time per process.
#pragma once

#include <cstdint>
#include <string>

namespace db {
namespace admin_password {

constexpr size_t kMinLength = 8;
constexpr size_t kMaxLength = 128;

struct Record {
  std::string algo;  // "argon2id" or "blake2b-256" (also the pre-algo legacy records)
  std::string salt;  // hex
  std::string hash;  // hex
  uint32_t m_kib = 8192;
  uint32_t t = 3;
  uint32_t p = 1;
};

// A fresh Argon2id record with a random 16-byte salt.
Record create(const std::string& password);
// Constant-time comparison against the record's algorithm.
bool verify(const Record& record, const std::string& password);
// True for any record that is not Argon2id at the current parameters.
bool needsUpgrade(const Record& record);
// Argon2id digest as hex; empty on invalid parameters or allocation failure.
std::string argon2idHex(const std::string& password, const std::string& salt_hex,
                        uint32_t m_kib, uint32_t t, uint32_t p);
std::string legacyBlake2bHex(const std::string& password, const std::string& salt_hex);

}  // namespace admin_password
}  // namespace db
