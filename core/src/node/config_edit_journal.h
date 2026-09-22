#pragma once

#include "crdt/lww_map.h"
#include "util/json.h"

namespace db {
// Immutable edit records use the existing authenticated config replication and atomic Store
// transaction. They never become ordinary configuration or executable events.
bool configEditReserved(const std::string& key);
std::string configEditEntity(const std::string& key);
bool configEditCandidateComplete(const cJSON* value);
json::Doc configEditSafeValue(const cJSON* value, const std::string& path);
bool configEditRecordsValid(const std::vector<LwwEntry>& records, std::string* error = nullptr);
json::Doc configEditConflicts(const std::vector<LwwEntry>& records, const cJSON* current);
json::Doc configEditSummary(const std::vector<LwwEntry>& records);
std::string appendConfigEdits(const std::vector<LwwEntry>& records,
                             const std::vector<LwwMutation>& changes,
                             const cJSON* candidate, const std::string& author,
                             const cJSON* resolves, std::vector<LwwMutation>* output);
}  // namespace db
