#pragma once

#include "crdt/lww_map.h"
#include "util/json.h"
#include <map>
#include <set>

namespace db {
struct ConfigImportStage {
  std::string token, digest, principal, session, boot, revision, candidate;
  int64_t issued_mono = 0;
};

constexpr size_t kConfigImportBytes = 4 * 1024 * 1024;
constexpr size_t kConfigImportLeaves = 4096;
constexpr int64_t kConfigImportTtlMs = 10 * 60 * 1000;

bool configImportFields(const cJSON* value, const std::set<std::string>& allowed);
bool configImportHex(const std::string& text, size_t size);
json::Doc configImportParse(const std::string& text);
bool configImportTreeValid(const cJSON* value, unsigned depth, size_t* nodes);
const cJSON* configImportAt(const cJSON* value, const std::string& path);
void configImportLeaves(const cJSON* value, const std::string& path,
                        std::map<std::string, std::string>* leaves);
}  // namespace db
