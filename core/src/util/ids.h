// ノードID・トークン生成
#pragma once

#include <string>

namespace db {

// 32 hex 小文字 (UUIDv4 相当のランダム 128bit)。終身不変の node_id 用。
std::string genNodeId();
// 6 桁数字 PIN (配対用)
std::string genPin6();
// URL 安全な長期トークン (panel アクセス用など): n バイト乱数の hex
std::string genTokenHex(size_t n_bytes);

}  // namespace db
