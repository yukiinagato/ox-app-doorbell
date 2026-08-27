// cJSON の薄いラッパ。所有権は Doc (unique_ptr)、参照は生ポインタ (borrowed)。
// 数値は double 経由 (53bit まで安全 — seq/時刻ms はその範囲)。
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

Doc parse(const std::string& text);  // 失敗時 nullptr
Doc obj();
Doc arr();
std::string dump(const cJSON* j, bool pretty = false);

// --- getters (borrowed; 型不一致は def) ---
std::string getString(const cJSON* o, const char* key, const std::string& def = "");
int64_t getInt(const cJSON* o, const char* key, int64_t def = 0);
double getNum(const cJSON* o, const char* key, double def = 0.0);
bool getBool(const cJSON* o, const char* key, bool def = false);
cJSON* get(const cJSON* o, const char* key);  // 無ければ nullptr

// --- setters (親 o に所有権が移る) ---
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

// 配列走査は cJSON_ArrayForEach(it, arr) をそのまま使う。

}  // namespace json
}  // namespace db
