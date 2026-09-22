#include "node/config_edit_journal.h"

#include <algorithm>
#include <cctype>
#include <map>
#include <set>

#include "util/common.h"

namespace db {
namespace {
constexpr char kRoot[] = "_config_changes";
constexpr char kPrefix[] = "_config_changes.";
constexpr size_t kRecordBytes = 64 * 1024;
struct Edit {
  std::string id, entity, encoded;
  std::set<std::string> parents;
};
using Edits = std::map<std::string, Edit>;
bool hex(const std::string& value, size_t length) {
  return value.size() == length && value.find_first_not_of("0123456789abcdef") == std::string::npos;
}
bool fields(const cJSON* object, const std::set<std::string>& allowed) {
  if (!cJSON_IsObject(object)) return false;
  std::set<std::string> seen; const cJSON* field = nullptr;
  cJSON_ArrayForEach(field, object)
    if (!field->string || !allowed.count(field->string) || !seen.insert(field->string).second) return false;
  return true;
}
bool keyValid(const std::string& key) {
  if (key.empty() || key.size() > 512 || key.front() == '.' || key.back() == '.' ||
      key.find("..") != std::string::npos || configEditReserved(key)) return false;
  for (unsigned char ch : key) if (ch < 0x20 || ch == 0x7f) return false;
  return true;
}
bool versionValid(const cJSON* version, const std::string& key) {
  if (!fields(version, {"key", "hlc", "author", "seq", "deleted"})) return false;
  const auto parent = json::getString(version, "key");
  const auto author = json::getString(version, "author");
  const auto hlc = json::getString(version, "hlc");
  const auto seq = json::getString(version, "seq");
  return keyValid(parent) && (parent == key || key.rfind(parent + ".", 0) == 0) &&
      hex(author, 32) && hlc.size() == 26 && hlc[12] == '-' && hlc[17] == '-' &&
      hex(hlc.substr(0, 12), 12) && hex(hlc.substr(13, 4), 4) &&
      hlc.substr(18) == author.substr(0, 8) &&
      !seq.empty() && seq.front() != '0' && seq.find_first_not_of("0123456789") == std::string::npos &&
      (seq.size() < 20 || (seq.size() == 20 && seq <= "18446744073709551615")) &&
      cJSON_IsBool(json::get(version, "deleted"));
}
const cJSON* at(const cJSON* root, const std::string& path) {
  size_t begin = 0;
  while (root && begin < path.size()) {
    const size_t end = path.find('.', begin);
    root = json::get(root, path.substr(begin, end - begin).c_str());
    if (end == std::string::npos) break;
    begin = end + 1;
  }
  return root;
}
bool sensitive(std::string name) {
  std::transform(name.begin(), name.end(), name.begin(), [](unsigned char c) { return std::tolower(c); });
  name.erase(std::remove_if(name.begin(), name.end(), [](char c) { return c == '_' || c == '-'; }), name.end());
  for (const char* part : {"password", "passwd", "passphrase", "secret", "token", "credential",
                           "privatekey", "authorization", "apikey"})
    if (name.find(part) != std::string::npos) return true;
  size_t begin = 0;
  const std::set<std::string> names = {"auth", "basicauth", "bearer", "digestauth", "pass", "pin",
                                     "proxyauth", "psk", "pskhex", "sippass", "key"};
  while (begin < name.size()) {
    const auto end = name.find('.', begin);
    if (names.count(name.substr(begin, end - begin))) return true;
    if (end == std::string::npos) break;
    begin = end + 1;
  }
  return false;
}
bool secretReference(const std::string& ref) {
  if (ref.rfind("secret:", 0) != 0 || ref.size() <= 7 || ref.size() > 135) return false;
  for (size_t i = 7; i < ref.size(); ++i) {
    const unsigned char ch = static_cast<unsigned char>(ref[i]);
    if (!((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
          (ch >= '0' && ch <= '9') || ch == '.' || ch == '_' || ch == '-')) return false;
  }
  return true;
}
json::Doc scrub(const cJSON* value, const std::string& name, bool* redacted) {
  if (!value) return json::Doc(cJSON_CreateNull());
  if (cJSON_IsString(value) && value->valuestring &&
      secretReference(value->valuestring))
    return json::Doc(cJSON_Duplicate(value, 1));
  if (cJSON_IsObject(value) && json::getBool(value, "requires_reentry") &&
      cJSON_GetArraySize(value) == 1) {
    *redacted = true; return json::Doc(cJSON_Duplicate(value, 1));
  }
  if (cJSON_IsObject(value)) {
    auto result = json::obj(); const cJSON* child = nullptr;
    cJSON_ArrayForEach(child, value) if (child->string)
      json::setItem(result.get(), child->string, scrub(child, name + "." + child->string, redacted));
    return result;
  }
  if (cJSON_IsArray(value)) {
    auto result = json::arr(); const cJSON* child = nullptr;
    cJSON_ArrayForEach(child, value) json::push(result.get(), scrub(child, name, redacted));
    return result;
  }
  if (sensitive(name)) {
    *redacted = true;
    auto marker = json::obj(); json::setBool(marker.get(), "requires_reentry", true); return marker;
  }
  if (cJSON_IsString(value) && value->valuestring) {
    const std::string text = value->valuestring;
    const auto scheme = text.find("://");
    if (text.rfind("secret:", 0) == 0 ||
        (scheme != std::string::npos && text.find_first_of("@?#%", scheme + 3) != std::string::npos)) {
      *redacted = true;
      auto marker = json::obj(); json::setBool(marker.get(), "requires_reentry", true); return marker;
    }
  }
  return json::Doc(cJSON_Duplicate(value, 1));
}
Edits edits(const std::vector<LwwEntry>& records) {
  Edits result;
  for (const auto& entry : records) if (entry.key.rfind(kPrefix, 0) == 0 && !entry.deleted) {
    auto doc = json::parse(entry.value_json);
    Edit e; e.id = json::getString(doc.get(), "change_id");
    e.entity = json::getString(doc.get(), "entity"); e.encoded = entry.value_json;
    const cJSON* parent = nullptr;
    cJSON_ArrayForEach(parent, json::get(doc.get(), "parents"))
      if (cJSON_IsString(parent) && parent->valuestring) e.parents.insert(parent->valuestring);
    if (!e.id.empty()) result[e.id] = std::move(e);
  }
  return result;
}
std::map<std::string, std::set<std::string>> heads(const Edits& all) {
  std::map<std::string, std::set<std::string>> result;
  for (const auto& pair : all) result[pair.second.entity].insert(pair.first);
  for (const auto& pair : all) for (const auto& parent : pair.second.parents)
    result[pair.second.entity].erase(parent);
  return result;
}
json::Doc strings(const std::set<std::string>& values) {
  auto result = json::arr();
  for (const auto& value : values) json::push(result.get(), json::Doc(cJSON_CreateString(value.c_str())));
  return result;
}
bool withinBudget(const Edits& all, bool remote) {
  const size_t multiplier = remote ? 2 : 1;
  if (all.size() > 512 * multiplier) return false;
  size_t bytes = 0; std::map<std::string, size_t> count;
  for (const auto& pair : all) {
    bytes += pair.second.encoded.size();
    if (++count[pair.second.entity] > 64 * multiplier || bytes > 512 * 1024 * multiplier) return false;
  }
  return true;
}
}

bool configEditReserved(const std::string& key) {
  return key == kRoot || key.rfind(kPrefix, 0) == 0;
}
std::string configEditEntity(const std::string& key) {
  const auto dot = key.find('.');
  if (key.rfind("devices.", 0) == 0) return key.substr(0, key.find('.', dot + 1));
  return key.substr(0, dot);
}
bool configEditCandidateComplete(const cJSON* value) {
  if (cJSON_IsObject(value) && json::getBool(value, "requires_reentry")) return false;
  if (cJSON_IsObject(value) || cJSON_IsArray(value)) {
    const cJSON* child = nullptr;
    cJSON_ArrayForEach(child, value) if (!configEditCandidateComplete(child)) return false;
  }
  return true;
}
bool configEditRecordsValid(const std::vector<LwwEntry>& records, std::string* error) {
  if (error) *error = "invalid_config_history";
  std::set<std::string> ids;
  for (const auto& entry : records) {
    if (!configEditReserved(entry.key)) continue;
    if (entry.deleted || entry.value_json.size() > kRecordBytes) return false;
    auto doc = json::parse(entry.value_json);
    const auto id = json::getString(doc.get(), "change_id");
    const auto entity = json::getString(doc.get(), "entity");
    const auto* parent_list = json::get(doc.get(), "parents");
    if (!fields(doc.get(), {"schema_version", "change_id", "author_node", "entity", "parents",
                           "base_entity_version", "ops", "candidate_exists", "candidate", "requires_reentry"}) ||
        !cJSON_IsNumber(json::get(doc.get(), "schema_version")) ||
        json::get(doc.get(), "schema_version")->valuedouble != 1 || !hex(entry.author, 32) ||
        !keyValid(entity) || entity == "devices" || !hex(id, 32) || !ids.insert(id).second || entity.empty() || entity.size() > 512 ||
        configEditReserved(entity) || configEditEntity(entity) != entity ||
        entry.author != json::getString(doc.get(), "author_node") ||
        !hex(json::getString(doc.get(), "base_entity_version"), 64) ||
        entry.key != std::string(kPrefix) + id + "." + sha256Hex(toBytes(entry.value_json)) ||
        !cJSON_IsArray(parent_list) || cJSON_GetArraySize(parent_list) > 128 ||
        !cJSON_IsArray(json::get(doc.get(), "ops")) ||
        cJSON_GetArraySize(json::get(doc.get(), "ops")) < 1 ||
        cJSON_GetArraySize(json::get(doc.get(), "ops")) > 256 ||
        !cJSON_IsBool(json::get(doc.get(), "candidate_exists")) ||
        !cJSON_IsBool(json::get(doc.get(), "requires_reentry"))) return false;
    bool redacted = false;
    const auto* candidate = json::get(doc.get(), "candidate");
    if (!candidate || (!json::getBool(doc.get(), "candidate_exists") && !cJSON_IsNull(candidate))) return false;
    auto safe_candidate = scrub(candidate, entity, &redacted);
    if (json::dump(safe_candidate.get()) != json::dump(candidate)) return false;
    const cJSON* operation = nullptr; std::set<std::string> operation_keys;
    cJSON_ArrayForEach(operation, json::get(doc.get(), "ops")) {
      const auto key = json::getString(operation, "key");
      const auto kind = json::getString(operation, "op");
      if (!fields(operation, {"op", "key", "value", "base_versions"}) || !keyValid(key) ||
          !operation_keys.insert(key).second || configEditEntity(key) != entity ||
          (kind != "set" && kind != "delete") || (kind == "delete" && json::get(operation, "value"))) return false;
      const auto* versions = json::get(operation, "base_versions");
      if (!cJSON_IsArray(versions) || cJSON_GetArraySize(versions) > 2) return false;
      const cJSON* version = nullptr; std::set<std::string> parent_keys;
      cJSON_ArrayForEach(version, versions)
        if (!versionValid(version, key) || !parent_keys.insert(json::getString(version, "key")).second) return false;
      if (kind == "set") {
        const auto* value = json::get(operation, "value");
        if (!value) return false;
        auto safe_value = scrub(value, key, &redacted);
        if (json::dump(safe_value.get()) != json::dump(value)) return false;
      }
    }
    if (redacted && !json::getBool(doc.get(), "requires_reentry")) return false;
    std::set<std::string> parents; const cJSON* parent = nullptr;
    cJSON_ArrayForEach(parent, parent_list) {
      const std::string p = cJSON_IsString(parent) && parent->valuestring ? parent->valuestring : "";
      if (!hex(p, 32) || p == id || !parents.insert(p).second) return false;
    }
  }
  auto all = edits(records);
  if (!withinBudget(all, true)) {
    if (error) *error = "config_history_capacity_exceeded";
    return false;
  }
  std::map<std::string, size_t> indegree;
  std::map<std::string, std::vector<std::string>> children;
  for (const auto& pair : all) {
    indegree[pair.first] = 0;
    for (const auto& p : pair.second.parents) if (all.count(p)) {
      if (all.at(p).entity != pair.second.entity) return false;
      ++indegree[pair.first]; children[p].push_back(pair.first);
    }
  }
  std::vector<std::string> ready;
  for (const auto& pair : indegree) if (pair.second == 0) ready.push_back(pair.first);
  for (size_t i = 0; i < ready.size(); ++i)
    for (const auto& child : children[ready[i]]) if (--indegree[child] == 0) ready.push_back(child);
  if (ready.size() != all.size()) return false;
  if (error) error->clear();
  return true;
}
json::Doc configEditSummary(const std::vector<LwwEntry>& records) {
  const auto all = edits(records);
  auto result = json::obj();
  json::set(result.get(), "records", static_cast<int64_t>(all.size()));
  json::set(result.get(), "local_record_limit", int64_t{512});
  json::set(result.get(), "entity_record_limit", int64_t{64});
  size_t bytes = 0; std::map<std::string, size_t> counts;
  for (const auto& pair : all) { bytes += pair.second.encoded.size(); ++counts[pair.second.entity]; }
  json::setBool(result.get(), "capacity_available", all.size() < 512 && bytes < 512 * 1024);
  auto* blocked = json::addArr(result.get(), "blocked_entities");
  for (const auto& pair : counts) if (pair.second >= 64)
    json::push(blocked, json::Doc(cJSON_CreateString(pair.first.c_str())));
  return result;
}
json::Doc configEditConflicts(const std::vector<LwwEntry>& records, const cJSON* current) {
  const auto all = edits(records); auto result = json::arr();
  for (const auto& group : heads(all)) {
    if (group.second.size() < 2) continue;
    auto* conflict = json::pushObj(result.get());
    json::set(conflict, "entity", group.first); json::set(conflict, "state", "unresolved");
    json::setItem(conflict, "heads", strings(group.second));
    bool redacted = false;
    json::setBool(conflict, "effective_exists", at(current, group.first) != nullptr);
    json::setItem(conflict, "effective", scrub(at(current, group.first), group.first, &redacted));
    json::setBool(conflict, "effective_requires_reentry", redacted);
    auto* candidates = json::addArr(conflict, "candidates");
    // Preserve the entire branch, not only its last changed field.
    for (const auto& pair : all) if (pair.second.entity == group.first) {
      auto record = json::parse(pair.second.encoded);
      json::setBool(record.get(), "is_head", group.second.count(pair.first) != 0);
      json::push(candidates, std::move(record));
    }
  }
  return result;
}
json::Doc configEditSafeValue(const cJSON* value, const std::string& path) {
  bool redacted = false;
  return scrub(value, path, &redacted);
}
std::string appendConfigEdits(const std::vector<LwwEntry>& records,
                             const std::vector<LwwMutation>& changes,
                             const cJSON* candidate, const std::string& author,
                             const cJSON* resolves, std::vector<LwwMutation>* output) {
  auto all = edits(records); const auto frontier = heads(all);
  std::map<std::string, std::vector<LwwMutation>> groups;
  for (const auto& change : changes) {
    if (configEditReserved(change.key)) return "reserved_config_key";
    groups[configEditEntity(change.key)].push_back(change);
  }
  if (resolves) {
    if (!cJSON_IsObject(resolves)) return "invalid_resolution";
    const cJSON* value = nullptr; std::set<std::string> unique;
    cJSON_ArrayForEach(value, resolves)
      if (!value->string || !groups.count(value->string) || !unique.insert(value->string).second)
        return "invalid_resolution";
  }
  for (const auto& group : groups) {
    const auto found = frontier.find(group.first);
    const std::set<std::string> parents = found == frontier.end() ? std::set<std::string>{} : found->second;
    const auto* resolution = resolves ? json::get(resolves, group.first.c_str()) : nullptr;
    if (parents.size() > 1 || resolution) {
      if (!cJSON_IsArray(resolution)) return "unresolved_config_conflict";
      std::set<std::string> supplied; const cJSON* item = nullptr;
      cJSON_ArrayForEach(item, resolution) {
        if (!cJSON_IsString(item) || !item->valuestring || !supplied.insert(item->valuestring).second)
          return "invalid_resolution";
      }
      if (supplied != parents || parents.size() < 2) return "stale_config_resolution";
    }
    if (group.second.size() > 256) return "config_history_capacity_exceeded";
    auto record = json::obj(); const auto id = hexEncode(randomBytes(16));
    json::set(record.get(), "schema_version", int64_t{1});
    json::set(record.get(), "change_id", id); json::set(record.get(), "author_node", author);
    json::set(record.get(), "entity", group.first); json::setItem(record.get(), "parents", strings(parents));
    auto versions = json::arr();
    for (const auto& entry : records) if (configEditEntity(entry.key) == group.first) {
      auto* version = json::pushObj(versions.get()); json::set(version, "key", entry.key);
      json::set(version, "hlc", entry.hlc); json::set(version, "author", entry.author);
      json::set(version, "seq", std::to_string(entry.seq)); json::setBool(version, "deleted", entry.deleted);
    }
    json::set(record.get(), "base_entity_version", sha256Hex(toBytes(json::dump(versions.get()))));
    bool redacted = false;
    auto* ops = json::addArr(record.get(), "ops");
    for (const auto& change : group.second) {
      auto* op = json::pushObj(ops); json::set(op, "key", change.key);
      json::set(op, "op", change.deleted ? "delete" : "set");
      auto* base_versions = json::addArr(op, "base_versions");
      const LwwEntry* exact = nullptr; const LwwEntry* ancestor = nullptr;
      for (const auto& previous : records) {
        if (previous.key == change.key) exact = &previous;
        else if (change.key.rfind(previous.key + ".", 0) == 0 &&
                 (!ancestor || previous.key.size() > ancestor->key.size())) ancestor = &previous;
      }
      for (const auto* previous : {ancestor, exact}) if (previous) {
        auto* version = json::pushObj(base_versions);
        json::set(version, "hlc", previous->hlc); json::set(version, "author", previous->author);
        json::set(version, "seq", std::to_string(previous->seq));
        json::set(version, "key", previous->key); json::setBool(version, "deleted", previous->deleted);
      }
      if (!change.deleted) {
        auto value = json::parse(change.value_json);
        json::setItem(op, "value", scrub(value.get(), change.key, &redacted));
      }
    }
    const auto* value = at(candidate, group.first);
    json::setBool(record.get(), "candidate_exists", value != nullptr);
    json::setItem(record.get(), "candidate", scrub(value, group.first, &redacted));
    json::setBool(record.get(), "requires_reentry", redacted);
    auto encoded = json::dump(record.get());
    if (encoded.size() > kRecordBytes) return "config_history_capacity_exceeded";
    all.emplace(id, Edit{id, group.first, encoded, parents});
    if (!withinBudget(all, false)) return "config_history_capacity_exceeded";
    output->push_back({std::string(kPrefix) + id + "." + sha256Hex(toBytes(encoded)), encoded, false});
  }
  return "";
}
}  // namespace db
