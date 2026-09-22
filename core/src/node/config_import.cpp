#include "node/config_import.h"
#include <cmath>

namespace db {
bool configImportFields(const cJSON* value, const std::set<std::string>& allowed) {
  if (!cJSON_IsObject(value)) return false;
  std::set<std::string> seen; const cJSON* child = nullptr;
  cJSON_ArrayForEach(child, value)
    if (!child->string || !allowed.count(child->string) || !seen.insert(child->string).second)
      return false;
  return true;
}
bool configImportHex(const std::string& text, size_t size) {
  return text.size() == size && text.find_first_not_of("0123456789abcdef") == std::string::npos;
}
json::Doc configImportParse(const std::string& text) {
  if (text.size() > kConfigImportBytes || text.find('\0') != std::string::npos) return {};
  unsigned depth = 0; bool quoted = false, escaped = false;
  for (size_t i = 0; i < text.size(); ++i) {
    const char ch = text[i];
    if (quoted) {
      if (escaped) {
        if (ch == 'u' && text.compare(i + 1, 4, "0000") == 0) return {};
        escaped = false;
      }
      else if (ch == '\\') escaped = true;
      else if (ch == '"') quoted = false;
    } else if (ch == '"') quoted = true;
    else if (ch == '{' || ch == '[') { if (++depth > 20) return {}; }
    else if (ch == '}' || ch == ']') { if (depth == 0) return {}; --depth; }
  }
  return json::Doc(cJSON_ParseWithOpts(text.c_str(), nullptr, 1));
}
bool configImportTreeValid(const cJSON* value, unsigned depth, size_t* nodes) {
  if (!value || depth > 16 || ++*nodes > 65536) return false;
  if (cJSON_IsNumber(value) && !std::isfinite(value->valuedouble)) return false;
  std::set<std::string> names; const cJSON* child = nullptr;
  cJSON_ArrayForEach(child, value) {
    if (cJSON_IsObject(value)) {
      const std::string name = child->string ? child->string : "";
      if (name.empty() || name.size() > 512 || !names.insert(name).second) return false;
      for (unsigned char ch : name) if (ch < 0x20 || ch == 0x7f) return false;
    }
    if (!configImportTreeValid(child, depth + 1, nodes)) return false;
  }
  return true;
}
const cJSON* configImportAt(const cJSON* value, const std::string& path) {
  size_t begin = 0;
  while (value && begin < path.size()) {
    const auto end = path.find('.', begin);
    value = cJSON_IsObject(value) ? json::get(value, path.substr(begin, end - begin).c_str()) : nullptr;
    if (end == std::string::npos) break;
    begin = end + 1;
  }
  return value;
}
void configImportLeaves(const cJSON* value, const std::string& path,
                        std::map<std::string, std::string>* leaves) {
  if (cJSON_IsObject(value) && value->child) {
    const cJSON* child = nullptr;
    cJSON_ArrayForEach(child, value) {
      std::string name;
      for (char ch : std::string(child->string)) {
        if (ch == '~') name += "~0";
        else if (ch == '/') name += "~1";
        else name += ch;
      }
      configImportLeaves(child, path + "/" + name, leaves);
    }
  } else {
    // Arrays have no stable field identity and are one replacement, including empty arrays.
    (*leaves)[path] = json::dump(value);
  }
}
}  // namespace db
