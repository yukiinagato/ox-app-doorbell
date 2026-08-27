// トリガールールエンジン (events.h RuleEngine の実装)。
// 設定 JSON の trigger_rules / quiet_hours を評価し、実行すべきアクション一覧を返す。
// setConfig でパース済みツリーを保持し、evaluate 毎の再パースはしない。
#include "events/events.h"

#include <algorithm>
#include <cstdio>
#include <utility>

#include "util/json.h"
#include "util/log.h"

namespace db {
namespace {

constexpr const char* kTag = "rules";
constexpr int64_t kDayMs = 86400000LL;  // 1 日 (ms)

// 負値でも床方向へ丸める除算 (epoch 前の時刻でも曜日計算が壊れないように)
int64_t floorDiv(int64_t a, int64_t b) {
  int64_t q = a / b;
  if ((a % b) != 0 && ((a < 0) != (b < 0))) --q;
  return q;
}

// "HH:MM" → 通算分。不正な書式は -1。
int parseHhmm(const std::string& s) {
  int h = 0, m = 0;
  char tail = 0;
  if (std::sscanf(s.c_str(), "%d:%d%c", &h, &m, &tail) != 2) return -1;
  if (h < 0 || h > 24 || m < 0 || m > 59) return -1;
  return h * 60 + m;
}

// epoch 日数 → 曜日 (0=sun..6=sat)。1970-01-01 (day 0) は木曜。
int weekdayOfDay(int64_t day) {
  return static_cast<int>(((day + 4) % 7 + 7) % 7);
}

const char* const kDayNames[7] = {"sun", "mon", "tue", "wed", "thu", "fri", "sat"};

// 文字列配列 array に v が含まれるか
bool listContains(const cJSON* array, const std::string& v) {
  const cJSON* it = nullptr;
  cJSON_ArrayForEach(it, array) {
    if (cJSON_IsString(it) && v == it->valuestring) return true;
  }
  return false;
}

// days 配列に曜日 wd が含まれるか。days 省略 (配列でない) = 毎日。
bool daysContain(const cJSON* days, int wd) {
  if (!cJSON_IsArray(days)) return true;
  return listContains(days, kDayNames[wd]);
}

// 1 窓の判定。day/minute は現地の epoch 日数と分。境界は from <= t < to。
// from > to は日跨ぎ窓: 翌朝側は「窓が始まった日の days」に属するので、
// 当日 days に対し from-24:00、前日 days に対し 00:00-to として判定する。
bool windowMatch(const cJSON* win, int64_t day, int minute) {
  const int from = parseHhmm(json::getString(win, "from"));
  const int to = parseHhmm(json::getString(win, "to"));
  if (from < 0 || to < 0) return false;
  const cJSON* days = json::get(win, "days");
  if (from < to) return daysContain(days, weekdayOfDay(day)) && from <= minute && minute < to;
  if (from == to) return false;  // 空窓
  if (minute >= from) return daysContain(days, weekdayOfDay(day));      // 当日夜側
  if (minute < to) return daysContain(days, weekdayOfDay(day - 1));     // 前日起点の翌朝側
  return false;
}

// windows 配列のいずれかに現地時刻が入っているか
bool anyWindowMatch(const cJSON* windows, int64_t day, int minute) {
  if (!cJSON_IsArray(windows)) return false;
  const cJSON* it = nullptr;
  cJSON_ArrayForEach(it, windows) {
    if (cJSON_IsObject(it) && windowMatch(it, day, minute)) return true;
  }
  return false;
}

// schedule 判定。省略 or always → 常時。windows があれば窓判定。
bool scheduleMatch(const cJSON* sched, int64_t day, int minute) {
  if (!sched) return true;
  if (json::getBool(sched, "always", false)) return true;
  const cJSON* windows = json::get(sched, "windows");
  if (!windows) return true;  // always も windows も無い → 常時扱い
  return anyWindowMatch(windows, day, minute);
}

// 設定側 when.type の語彙 (計画書: button/device_offline) を
// EventRecord.type の語彙 (events.h: press/offline/online) へ正規化して比較する。
std::string canonicalType(const std::string& t) {
  if (t == "button") return "press";
  if (t == "device_offline") return "offline";
  if (t == "device_online") return "online";
  return t;
}

// when 節のマッチ判定。doors 省略 = 全ドア。devices は "all" か配列。
// イベント側は ev.door / ev.device を見る (offline/online は device ベース)。
bool whenMatch(const cJSON* when, const EventRecord& ev) {
  if (!cJSON_IsObject(when)) return false;
  if (canonicalType(json::getString(when, "type")) != canonicalType(ev.type)) return false;
  const cJSON* doors = json::get(when, "doors");
  if (cJSON_IsArray(doors) && !listContains(doors, ev.door)) return false;
  const cJSON* devices = json::get(when, "devices");
  if (devices) {
    if (cJSON_IsString(devices)) {
      if (std::string("all") != devices->valuestring) return false;  // 未知の文字列は非マッチ
    } else if (cJSON_IsArray(devices)) {
      if (!listContains(devices, ev.device)) return false;
    }
  }
  return true;
}

// quiet_hours の適用状態。窓内なら suppress にある型を落とす (never_suppress は常に残す)。
struct QuietState {
  bool active = false;
  const cJSON* suppress = nullptr;
  const cJSON* never_suppress = nullptr;

  bool shouldDrop(const std::string& action_type) const {
    if (!active) return false;
    if (never_suppress && listContains(never_suppress, action_type)) return false;
    return suppress && listContains(suppress, action_type);
  }
};

}  // namespace

void RuleEngine::setConfig(const std::string& config_json) {
  config_json_ = config_json;
  config_ = json::parse(config_json);
  if (!config_) {
    DB_LOGW(kTag, "設定 JSON をパースできない — 空設定として扱う");
  }
}

std::vector<Action> RuleEngine::evaluate(const EventRecord& ev, int64_t corrected_wall_ms,
                                         int tz_offset_min) const {
  std::vector<Action> out;
  if (!config_) return out;

  // 現地時刻 (epoch 日数 + 分)。判定は分単位。
  const int64_t local_ms = corrected_wall_ms + static_cast<int64_t>(tz_offset_min) * 60000LL;
  const int64_t day = floorDiv(local_ms, kDayMs);
  const int minute = static_cast<int>((local_ms - day * kDayMs) / 60000LL);

  // quiet_hours (default プロファイル) の現在状態
  QuietState quiet;
  const cJSON* qdef = json::get(json::get(config_.get(), "quiet_hours"), "default");
  if (cJSON_IsObject(qdef)) {
    quiet.suppress = json::get(qdef, "suppress");
    quiet.never_suppress = json::get(qdef, "never_suppress");
    quiet.active = anyWindowMatch(json::get(qdef, "windows"), day, minute);
  }

  const cJSON* rules = json::get(config_.get(), "trigger_rules");
  if (!cJSON_IsObject(rules)) return out;

  // ルール ID 昇順で決定的な結果順にする (JSON の出現順に依存しない)
  std::vector<std::pair<std::string, const cJSON*>> ordered;
  const cJSON* it = nullptr;
  cJSON_ArrayForEach(it, rules) {
    if (it->string) ordered.emplace_back(it->string, it);
  }
  std::sort(ordered.begin(), ordered.end(),
            [](const std::pair<std::string, const cJSON*>& a,
               const std::pair<std::string, const cJSON*>& b) { return a.first < b.first; });

  for (const auto& entry : ordered) {
    const cJSON* rule = entry.second;
    if (!cJSON_IsObject(rule)) continue;
    if (!json::getBool(rule, "enabled", true)) continue;  // 無効ルールはスキップ
    if (!whenMatch(json::get(rule, "when"), ev)) continue;
    if (!scheduleMatch(json::get(rule, "schedule"), day, minute)) continue;

    const cJSON* action = nullptr;
    cJSON_ArrayForEach(action, json::get(rule, "actions")) {
      if (!cJSON_IsObject(action)) continue;
      const std::string type = json::getString(action, "type");
      if (type.empty()) continue;
      if (quiet.shouldDrop(type)) continue;
      // type 以外のフィールドをそのまま params_json へ (type を除いたオブジェクトを dump)
      json::Doc params(cJSON_Duplicate(action, 1));
      if (!params) continue;
      cJSON_DeleteItemFromObjectCaseSensitive(params.get(), "type");
      out.push_back(Action{type, json::dump(params.get())});
    }
  }
  return out;
}

}  // namespace db
