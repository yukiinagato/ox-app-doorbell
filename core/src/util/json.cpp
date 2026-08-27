#include "util/json.h"

namespace db {
namespace json {

Doc parse(const std::string& text) { return Doc(cJSON_Parse(text.c_str())); }
Doc obj() { return Doc(cJSON_CreateObject()); }
Doc arr() { return Doc(cJSON_CreateArray()); }

std::string dump(const cJSON* j, bool pretty) {
  if (!j) return "null";
  char* s = pretty ? cJSON_Print(j) : cJSON_PrintUnformatted(j);
  if (!s) return "null";
  std::string out(s);
  cJSON_free(s);
  return out;
}

std::string getString(const cJSON* o, const char* key, const std::string& def) {
  const cJSON* it = cJSON_GetObjectItemCaseSensitive(o, key);
  return cJSON_IsString(it) ? it->valuestring : def;
}

int64_t getInt(const cJSON* o, const char* key, int64_t def) {
  const cJSON* it = cJSON_GetObjectItemCaseSensitive(o, key);
  return cJSON_IsNumber(it) ? static_cast<int64_t>(it->valuedouble) : def;
}

double getNum(const cJSON* o, const char* key, double def) {
  const cJSON* it = cJSON_GetObjectItemCaseSensitive(o, key);
  return cJSON_IsNumber(it) ? it->valuedouble : def;
}

bool getBool(const cJSON* o, const char* key, bool def) {
  const cJSON* it = cJSON_GetObjectItemCaseSensitive(o, key);
  if (cJSON_IsBool(it)) return cJSON_IsTrue(it);
  return def;
}

cJSON* get(const cJSON* o, const char* key) {
  return cJSON_GetObjectItemCaseSensitive(const_cast<cJSON*>(o), key);
}

void set(cJSON* o, const char* key, const std::string& v) {
  cJSON_DeleteItemFromObjectCaseSensitive(o, key);
  cJSON_AddStringToObject(o, key, v.c_str());
}
void set(cJSON* o, const char* key, const char* v) {
  cJSON_DeleteItemFromObjectCaseSensitive(o, key);
  cJSON_AddStringToObject(o, key, v);
}
void set(cJSON* o, const char* key, int64_t v) {
  cJSON_DeleteItemFromObjectCaseSensitive(o, key);
  cJSON_AddNumberToObject(o, key, static_cast<double>(v));
}
void set(cJSON* o, const char* key, double v) {
  cJSON_DeleteItemFromObjectCaseSensitive(o, key);
  cJSON_AddNumberToObject(o, key, v);
}
void setBool(cJSON* o, const char* key, bool v) {
  cJSON_DeleteItemFromObjectCaseSensitive(o, key);
  cJSON_AddBoolToObject(o, key, v);
}
void setItem(cJSON* o, const char* key, Doc item) {
  cJSON_DeleteItemFromObjectCaseSensitive(o, key);
  cJSON_AddItemToObject(o, key, item.release());
}
cJSON* addObj(cJSON* o, const char* key) {
  cJSON_DeleteItemFromObjectCaseSensitive(o, key);
  return cJSON_AddObjectToObject(o, key);
}
cJSON* addArr(cJSON* o, const char* key) {
  cJSON_DeleteItemFromObjectCaseSensitive(o, key);
  return cJSON_AddArrayToObject(o, key);
}
void push(cJSON* array, Doc item) { cJSON_AddItemToArray(array, item.release()); }
cJSON* pushObj(cJSON* array) {
  cJSON* o = cJSON_CreateObject();
  cJSON_AddItemToArray(array, o);
  return o;
}

}  // namespace json
}  // namespace db
