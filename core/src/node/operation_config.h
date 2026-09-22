#pragma once

#include <algorithm>
#include <set>
#include <string>

#include "util/json.h"
#include "node/operation_ack.h"

namespace db {

inline bool operationIdValid(const std::string& value) {
  return value.size() == 32 && std::all_of(value.begin(), value.end(), [](char c) {
    return (c >= 'a' && c <= 'f') || (c >= '0' && c <= '9');
  });
}

inline bool operationDoorValid(const std::string& value) {
  return !value.empty() && value.size() <= 128 &&
      std::all_of(value.begin(), value.end(), [](unsigned char c) {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
               (c >= '0' && c <= '9') || c == '_' || c == '-';
      });
}

inline bool operationConfigValid(const std::string& key, const cJSON* value, std::string* error) {
  auto fail = [&] { *error = "invalid operation authority or device grant"; return false; };
  auto authority = [](const cJSON* v) {
    return cJSON_IsString(v) && operationIdValid(v->valuestring);
  };
  auto doors = [](const cJSON* v) {
    if (!cJSON_IsArray(v) || cJSON_GetArraySize(v) > 64) return false;
    std::set<std::string> unique;
    const cJSON* item = nullptr;
    cJSON_ArrayForEach(item, v) {
      if (!cJSON_IsString(item) || !operationDoorValid(item->valuestring) ||
          !unique.insert(item->valuestring).second) return false;
    }
    return true;
  };
  const bool device = key.rfind("devices.", 0) == 0;
  const bool door = key.rfind("doors.", 0) == 0;
  if (!device && !door && key != "doors" && key != "cluster" &&
      key.rfind("cluster.operations", 0) != 0) return true;
  if (key == "doors") {
    const cJSON* item = nullptr;
    cJSON_ArrayForEach(item, value) {
      if (!operationConfigValid("doors." + std::string(item->string ? item->string : ""), item, error))
        return false;
    }
    return true;
  }
  size_t position = key.find(".operations");
  if (position == std::string::npos) {
    const cJSON* embedded = json::get(value, "operations");
    return !embedded || operationConfigValid(key + ".operations", embedded, error);
  }
  const std::string root = key.substr(0, position);
  if ((device && !operationIdValid(root.substr(8))) ||
      (door && !operationDoorValid(root.substr(6)))) return fail();
  const std::string suffix = key.substr(position + 11);
  if (!suffix.empty()) {
    if (door && suffix == ".ack") return operationAckConfigValid(value, false) || fail();
    if (door && suffix.rfind(".ack.", 0) == 0)
      return operationAckConfigField(suffix.substr(5), value) || fail();
    if (device && suffix == ".doors") return doors(value) || fail();
    if (device && (suffix == ".sos_start" || suffix == ".sos_clear"))
      return cJSON_IsBool(value) || fail();
    if ((door && suffix == ".authority_node") ||
        (root == "cluster" && suffix == ".sos_authority_node")) return authority(value) || fail();
    return fail();
  }
  if (!cJSON_IsObject(value)) return fail();
  std::set<std::string> seen;
  const cJSON* item = nullptr;
  cJSON_ArrayForEach(item, value) {
    const std::string field = item->string ? item->string : "";
    if (!seen.insert(field).second ||
        !operationConfigValid(key + "." + field, item, error)) return fail();
  }
  return true;
}

}  // namespace db
