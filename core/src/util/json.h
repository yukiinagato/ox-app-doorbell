

#pragma once

#include <cstdint>
#include <memory>
#include <string>

#include "cJSON.h"

namespace db {
namespace json {

struct Deleter {
  void operator()(cJSON* j) const {
    if (j) cJSON_Delete(j);
  }
};
using Doc = std::unique_ptr<cJSON, Deleter>;

Doc parse(const std::string& text);
Doc obj();
Doc arr();
std::string dump(const cJSON* j, bool pretty = false);


std::string getString(const cJSON* o, const char* key, const std::string& def = "");
int64_t getInt(const cJSON* o, const char* key, int64_t def = 0);
double getNum(const cJSON* o, const char* key, double def = 0.0);
bool getBool(const cJSON* o, const char* key, bool def = false);
cJSON* get(const cJSON* o, const char* key);


void set(cJSON* o, const char* key, const std::string& v);
void set(cJSON* o, const char* key, const char* v);
void set(cJSON* o, const char* key, int64_t v);
void set(cJSON* o, const char* key, double v);
void setBool(cJSON* o, const char* key, bool v);
void setItem(cJSON* o, const char* key, Doc item);
cJSON* addObj(cJSON* o, const char* key);
cJSON* addArr(cJSON* o, const char* key);
void push(cJSON* array, Doc item);
cJSON* pushObj(cJSON* array);



}  // namespace json
}  // namespace db
