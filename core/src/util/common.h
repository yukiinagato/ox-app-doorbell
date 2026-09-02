
// Shared byte, encoding, cryptographic, and filesystem helpers.
#pragma once

#include <cstdint>
#include <cstddef>
#include <string>
#include <vector>

namespace db {

using Bytes = std::vector<uint8_t>;

inline Bytes toBytes(const std::string& s) { return Bytes(s.begin(), s.end()); }
inline std::string toString(const Bytes& b) { return std::string(b.begin(), b.end()); }

std::string hexEncode(const uint8_t* data, size_t len);
inline std::string hexEncode(const Bytes& b) { return hexEncode(b.data(), b.size()); }

// Decode functions leave out unchanged on invalid input.
bool hexDecode(const std::string& hex, Bytes& out);


std::string base64Encode(const uint8_t* data, size_t len);
inline std::string base64Encode(const Bytes& b) { return base64Encode(b.data(), b.size()); }

bool base64Decode(const std::string& b64, Bytes& out);


// Cryptographically secure randomness from BCryptGenRandom or the platform entropy source.
Bytes randomBytes(size_t n);


Bytes sha256(const uint8_t* data, size_t len);
inline Bytes sha256(const Bytes& b) { return sha256(b.data(), b.size()); }
std::string sha256Hex(const uint8_t* data, size_t len);
inline std::string sha256Hex(const Bytes& b) { return sha256Hex(b.data(), b.size()); }


bool makeDir(const std::string& path);


bool readFileBytes(const std::string& path, Bytes& out);
bool writeFileBytes(const std::string& path, const Bytes& data);  // Atomic temporary-file rename.
bool removeFile(const std::string& path);
bool fileExists(const std::string& path);

std::vector<std::string> listDir(const std::string& path);

std::string tempDir();

}  // namespace db
