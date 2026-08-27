// doorbell-core 共通基盤: 基本型・byte/hex ユーティリティ
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
// 不正な16進は false。out は成功時のみ書き換わる。
bool hexDecode(const std::string& hex, Bytes& out);

// 暗号用途可の乱数 (POSIX: /dev/urandom, Windows: BCryptGenRandom)
Bytes randomBytes(size_t n);

// ディレクトリを 1 階層作成 (既存なら成功扱い)。POSIX は mode 0755。
bool makeDir(const std::string& path);

}  // namespace db
