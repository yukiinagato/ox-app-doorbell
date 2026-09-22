#pragma once

#include <algorithm>
#include <set>
#include <string>

#include "util/json.h"

namespace db {

// Delegation carries this public identity only, never a browser session or credential digest.
struct PanelPrincipal {
  std::string panel_id;
  std::string credential_generation;
  std::string grant_version;
  bool legacy_shared = false;
};

inline bool panelIdentityIdValid(const std::string& value) {
  return value.size() == 32 && std::all_of(value.begin(), value.end(), [](char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
  });
}

inline bool panelGrantValid(const std::string& grant) {
  return grant == "view" || grant == "call.monitor" || grant == "call.answer" ||
      grant == "call.initiate" || grant == "sos.trigger" || grant == "door.open" ||
      grant == "media.publish" || grant == "notice.write";
}

inline bool panelIdentityFieldValid(const std::string& field, const cJSON* value) {
  if (field == "credential_generation" || field == "sip_account_id")
    return cJSON_IsString(value) && panelIdentityIdValid(value->valuestring);
  if (field == "credential_ref") {
    if (!cJSON_IsString(value) || !value->valuestring) return false;
    const std::string ref = value->valuestring;
    return ref.rfind("secret:", 0) == 0 && ref.size() > 7 && ref.size() <= 160 &&
        std::all_of(ref.begin() + 7, ref.end(), [](unsigned char c) {
          return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-';
        });
  }
  if (field == "revoked") return cJSON_IsBool(value);
  if (field != "door_scope" && field != "grants") return false;
  if (!cJSON_IsArray(value) || cJSON_GetArraySize(value) > 64) return false;
  std::set<std::string> seen;
  const cJSON* item = nullptr;
  cJSON_ArrayForEach(item, value) {
    if (!cJSON_IsString(item) || !item->valuestring) return false;
    const std::string text = item->valuestring;
    if (!seen.insert(text).second) return false;
    if (field == "grants") {
      if (!panelGrantValid(text)) return false;
    } else if (text.empty() || text.size() > 64 ||
        !std::all_of(text.begin(), text.end(), [](unsigned char c) {
          return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c == '_' || c == '-';
        })) return false;
  }
  return true;
}

inline bool panelIdentityRecordValid(const cJSON* value) {
  if (!cJSON_IsObject(value)) return false;
  std::set<std::string> seen;
  const cJSON* field = nullptr;
  cJSON_ArrayForEach(field, value) {
    const std::string key = field->string ? field->string : "";
    if (!seen.insert(key).second || !panelIdentityFieldValid(key, field)) return false;
  }
  return seen.count("credential_ref") && seen.count("credential_generation") &&
      seen.count("door_scope") && seen.count("grants") && seen.count("revoked");
}

inline bool panelIdentityConfigValid(const std::string& path, const cJSON* value,
                                     std::string* error) {
  auto fail = [&] { *error = "invalid independent panel identity"; return false; };
  if (path == "panel") {
    const auto* identities = json::get(value, "identities");
    return !identities || panelIdentityConfigValid("panel.identities", identities, error);
  }
  if (path == "panel.identities") {
    if (!cJSON_IsObject(value) || cJSON_GetArraySize(value) > 128) return fail();
    std::set<std::string> ids;
    const cJSON* item = nullptr;
    cJSON_ArrayForEach(item, value) {
      const std::string id = item->string ? item->string : "";
      if (!panelIdentityIdValid(id) || !ids.insert(id).second ||
          !panelIdentityRecordValid(item)) return fail();
    }
    return true;
  }
  const std::string prefix = "panel.identities.";
  if (path.rfind(prefix, 0) != 0) return true;
  const auto suffix = path.substr(prefix.size());
  const auto dot = suffix.find('.');
  if (!panelIdentityIdValid(suffix.substr(0, dot))) return fail();
  return (dot == std::string::npos ? panelIdentityRecordValid(value) :
      panelIdentityFieldValid(suffix.substr(dot + 1), value)) || fail();
}

}  // namespace db
