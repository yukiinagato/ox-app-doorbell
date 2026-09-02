


#include "events/events.h"

#include <algorithm>
#include <cstdio>
#include <utility>

#include "util/json.h"
#include "util/log.h"

namespace db {
namespace {

constexpr const char* kTag = "rules";
constexpr int64_t kDayMs = 86400000LL;


int64_t floorDiv(int64_t a, int64_t b) {
  int64_t q = a / b;
  if ((a % b) != 0 && ((a < 0) != (b < 0))) --q;
  return q;
}


int parseHhmm(const std::string& s) {
  int h = 0, m = 0;
  char tail = 0;
  if (std::sscanf(s.c_str(), "%d:%d%c", &h, &m, &tail) != 2) return -1;
  if (h < 0 || h > 24 || m < 0 || m > 59) return -1;
  return h * 60 + m;
}


int weekdayOfDay(int64_t day) {
  return static_cast<int>(((day + 4) % 7 + 7) % 7);
}

const char* const kDayNames[7] = {"sun", "mon", "tue", "wed", "thu", "fri", "sat"};


bool listContains(const cJSON* array, const std::string& v) {
  const cJSON* it = nullptr;
  cJSON_ArrayForEach(it, array) {
    if (cJSON_IsString(it) && v == it->valuestring) return true;
  }
  return false;
}


bool daysContain(const cJSON* days, int wd) {
  if (!cJSON_IsArray(days)) return true;
  return listContains(days, kDayNames[wd]);
}




bool windowMatch(const cJSON* win, int64_t day, int minute) {
  const int from = parseHhmm(json::getString(win, "from"));
  const int to = parseHhmm(json::getString(win, "to"));
  if (from < 0 || to < 0) return false;
  const cJSON* days = json::get(win, "days");
  if (from < to) return daysContain(days, weekdayOfDay(day)) && from <= minute && minute < to;
  if (from == to) return false;
  if (minute >= from) return daysContain(days, weekdayOfDay(day));
  if (minute < to) return daysContain(days, weekdayOfDay(day - 1));
  return false;
}


bool anyWindowMatch(const cJSON* windows, int64_t day, int minute) {
  if (!cJSON_IsArray(windows)) return false;
  const cJSON* it = nullptr;
  cJSON_ArrayForEach(it, windows) {
    if (cJSON_IsObject(it) && windowMatch(it, day, minute)) return true;
  }
  return false;
}


bool scheduleMatch(const cJSON* sched, int64_t day, int minute) {
  if (!sched) return true;
  if (json::getBool(sched, "always", false)) return true;
  const cJSON* windows = json::get(sched, "windows");
  if (!windows) return true;
  return anyWindowMatch(windows, day, minute);
}



std::string canonicalType(const std::string& t) {
  if (t == "button") return "press";
  if (t == "purpose_selected") return "press";
  if (t == "device_offline") return "offline";
  if (t == "device_online") return "online";
  if (t == "emergency_on") return "emergency";
  if (t == "emergency_off") return "emergency_cancel";
  // "call_missed" is a virtual trigger: nobody emits it. A call_cancelled event whose reason is a
  // ring timeout or a failed restart recovery also matches it, so a rule can notify on a missed
  // call without changing the replicated event vocabulary.
  if (t == "missed_call") return "call_missed";
  return t;
}


// A missed call is a cancellation that ended a call nobody answered.
bool isMissedCall(const EventRecord& ev, const std::string& reason) {
  if (ev.type != "call_cancelled") return false;
  return reason == "timeout" || reason.rfind("recovery_", 0) == 0;
}





bool whenMatch(const cJSON* when, const EventRecord& ev, const std::string& purpose,
               const std::string& reason) {
  if (!cJSON_IsObject(when)) return false;
  const std::string wanted = canonicalType(json::getString(when, "type"));
  // The event keeps its own canonical type so existing call_cancelled rules stay unchanged; a
  // missed cancellation additionally answers to call_missed.
  if (wanted != canonicalType(ev.type) &&
      !(wanted == "call_missed" && isMissedCall(ev, reason)))
    return false;
  const cJSON* doors = json::get(when, "doors");
  if (cJSON_IsArray(doors) && !listContains(doors, ev.door)) return false;
  const cJSON* devices = json::get(when, "devices");
  if (devices) {
    if (cJSON_IsString(devices)) {
      if (std::string("all") != devices->valuestring) return false;
    } else if (cJSON_IsArray(devices)) {
      if (!listContains(devices, ev.device)) return false;
    }
  }
  const cJSON* purposes = json::get(when, "purposes");
  if (cJSON_IsArray(purposes) && !listContains(purposes, purpose)) return false;
  return true;
}


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
    DB_LOGW(kTag, "cannot parse config JSON; treating it as empty config");
  }
}

std::vector<Action> RuleEngine::evaluate(const EventRecord& ev, int64_t corrected_wall_ms,
                                         int tz_offset_min) const {
  std::vector<Action> out;
  if (!config_) return out;


  const int64_t local_ms = corrected_wall_ms + static_cast<int64_t>(tz_offset_min) * 60000LL;
  const int64_t day = floorDiv(local_ms, kDayMs);
  const int minute = static_cast<int>((local_ms - day * kDayMs) / 60000LL);


  QuietState quiet;
  const cJSON* qdef = json::get(json::get(config_.get(), "quiet_hours"), "default");
  if (cJSON_IsObject(qdef)) {
    quiet.suppress = json::get(qdef, "suppress");
    quiet.never_suppress = json::get(qdef, "never_suppress");
    quiet.active = anyWindowMatch(json::get(qdef, "windows"), day, minute);
  }

  const cJSON* rules = json::get(config_.get(), "trigger_rules");
  if (!cJSON_IsObject(rules)) return out;


  std::string purpose;
  std::string reason;
  if (!ev.payload_json.empty()) {
    json::Doc payload = json::parse(ev.payload_json);
    if (payload) {
      purpose = json::getString(payload.get(), "purpose");
      reason = json::getString(payload.get(), "reason");
    }
  }


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
    if (!json::getBool(rule, "enabled", true)) continue;
    if (!whenMatch(json::get(rule, "when"), ev, purpose, reason)) continue;
    if (!scheduleMatch(json::get(rule, "schedule"), day, minute)) continue;

    const cJSON* action = nullptr;
    cJSON_ArrayForEach(action, json::get(rule, "actions")) {
      if (!cJSON_IsObject(action)) continue;
      const std::string type = json::getString(action, "type");
      if (type.empty()) continue;
      if (quiet.shouldDrop(type) && !json::getBool(action, "never_suppress")) continue;

      json::Doc params(cJSON_Duplicate(action, 1));
      if (!params) continue;
      cJSON_DeleteItemFromObjectCaseSensitive(params.get(), "type");
      out.push_back(Action{type, json::dump(params.get())});
    }
  }
  return out;
}

}  // namespace db
