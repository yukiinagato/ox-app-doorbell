
#include <string>
#include <vector>

#include "doctest.h"
#include "events/events.h"
#include "util/json.h"

using namespace db;

namespace {

constexpr int64_t kDayMs = 86400000LL;

constexpr int64_t kThu = 20692;
constexpr int64_t kFri = kThu + 1;


int64_t wallAtLocal(int64_t day, int h, int m, int tz_min) {
  return day * kDayMs + h * 3600000LL + m * 60000LL - static_cast<int64_t>(tz_min) * 60000LL;
}

EventRecord makeEv(const std::string& type, const std::string& door, const std::string& device) {
  EventRecord ev;
  ev.type = type;
  ev.door = door;
  ev.device = device;
  return ev;
}


std::string typesOf(const std::vector<Action>& as) {
  std::string s;
  for (const auto& a : as) {
    if (!s.empty()) s += ",";
    s += a.type;
  }
  return s;
}

}  // namespace

TEST_CASE("rules: when matches event type, doors, and devices") {
  RuleEngine re;
  re.setConfig(R"({
    "trigger_rules": {
      "r1_btn": { "enabled": true,
        "when": { "type": "button", "doors": ["d_front"] },
        "schedule": { "always": true },
        "actions": [ { "type": "sip_call", "target_extension": "600" } ] },
      "r2_motion": { "enabled": true,
        "when": { "type": "motion" },
        "actions": [ { "type": "ha_event" } ] },
      "r3_off_all": { "enabled": true,
        "when": { "type": "device_offline", "devices": "all" },
        "actions": [ { "type": "telegram", "households": ["h_ox"] } ] },
      "r4_off_c2d1": { "enabled": true,
        "when": { "type": "device_offline", "devices": ["c2d1"] },
        "actions": [ { "type": "chime", "devices": ["c2d1"], "sound": "ding1" } ] }
    }
  })");
  const int64_t noon = wallAtLocal(kThu, 12, 0, 0);

  struct Row {
    const char* type;
    const char* door;
    const char* device;
    const char* want;
  };
  const Row rows[] = {
      {"press", "d_front", "", "sip_call"},
      {"button", "d_front", "", "sip_call"},
      {"press", "d_back", "", ""},
      {"motion", "d_back", "", "ha_event"},
      {"motion", "d_front", "", "ha_event"},
      {"offline", "", "c2d1", "telegram,chime"},
      {"offline", "", "c9", "telegram"},
      {"online", "", "c2d1", ""},
      {"answered", "d_front", "", ""},
  };
  for (const auto& r : rows) {
    CAPTURE(r.type);
    CAPTURE(r.door);
    CAPTURE(r.device);
    CHECK(typesOf(re.evaluate(makeEv(r.type, r.door, r.device), noon, 0)) == r.want);
  }
}

TEST_CASE("rules: schedule windows support weekdays, boundaries, and midnight spans") {
  RuleEngine re;
  re.setConfig(R"({
    "trigger_rules": {
      "night": { "enabled": true,
        "when": { "type": "motion" },
        "schedule": { "windows": [ { "days": ["thu"], "from": "22:00", "to": "06:00" } ] },
        "actions": [ { "type": "ha_event" } ] },
      "office": { "enabled": true,
        "when": { "type": "button" },
        "schedule": { "windows": [ { "days": ["thu"], "from": "09:00", "to": "17:00" } ] },
        "actions": [ { "type": "sip_call" } ] }
    }
  })");
  const EventRecord mo = makeEv("motion", "d_front", "");
  const EventRecord bt = makeEv("press", "d_front", "");

  struct Row {
    const EventRecord* ev;
    int64_t day;
    int h, m;
    bool want;
  };
  const Row rows[] = {

      {&mo, kThu, 23, 30, true},
      {&mo, kFri, 5, 0, true},
      {&mo, kThu, 12, 0, false},
      {&mo, kThu, 5, 0, false},
      {&mo, kFri, 23, 30, false},
      {&mo, kThu, 22, 0, true},
      {&mo, kFri, 6, 0, false},

      {&bt, kThu, 12, 0, true},
      {&bt, kFri, 12, 0, false},
      {&bt, kThu, 9, 0, true},
      {&bt, kThu, 17, 0, false},
  };
  for (const auto& r : rows) {
    CAPTURE(r.day);
    CAPTURE(r.h);
    CAPTURE(r.m);
    CHECK(!re.evaluate(*r.ev, wallAtLocal(r.day, r.h, r.m, 0), 0).empty() == r.want);
  }
}

TEST_CASE("rules: tz_offset evaluates local time") {
  RuleEngine re;
  re.setConfig(R"({
    "trigger_rules": {
      "night": { "enabled": true,
        "when": { "type": "motion" },
        "schedule": { "windows": [ { "from": "22:00", "to": "06:00" } ] },
        "actions": [ { "type": "ha_event" } ] }
    }
  })");
  const EventRecord mo = makeEv("motion", "d_front", "");
  const int jst = 540;

  const int64_t wall = wallAtLocal(kThu, 23, 30, jst);
  CHECK(re.evaluate(mo, wall, jst).size() == 1);
  CHECK(re.evaluate(mo, wall, 0).empty());

  CHECK(re.evaluate(mo, wallAtLocal(kFri, 5, 0, jst), jst).size() == 1);
}

TEST_CASE("rules: quiet_hours supports suppress and never_suppress") {
  RuleEngine re;
  re.setConfig(R"({
    "trigger_rules": {
      "r": { "enabled": true,
        "when": { "type": "button" },
        "schedule": { "always": true },
        "actions": [ { "type": "chime", "sound": "ding1" },
                     { "type": "sip_call", "target_extension": "600" },
                     { "type": "telegram", "households": ["h_ox"] } ] }
    },
    "quiet_hours": {
      "default": { "windows": [ { "from": "23:00", "to": "07:00" } ],
                   "suppress": ["chime", "telegram"],
                   "never_suppress": ["sip_call", "telegram"] }
    }
  })");
  const EventRecord bt = makeEv("press", "d_front", "");

  CHECK(typesOf(re.evaluate(bt, wallAtLocal(kThu, 23, 30, 0), 0)) == "sip_call,telegram");
  CHECK(typesOf(re.evaluate(bt, wallAtLocal(kFri, 6, 59, 0), 0)) == "sip_call,telegram");

  CHECK(typesOf(re.evaluate(bt, wallAtLocal(kThu, 12, 0, 0), 0)) == "chime,sip_call,telegram");
  CHECK(typesOf(re.evaluate(bt, wallAtLocal(kFri, 7, 0, 0), 0)) == "chime,sip_call,telegram");
}

TEST_CASE("rules: disabled rules are skipped and multiple rules are deterministic") {
  RuleEngine re;

  re.setConfig(R"({
    "trigger_rules": {
      "b_rule": { "enabled": true,
        "when": { "type": "button" },
        "actions": [ { "type": "telegram", "households": ["h_ox"] } ] },
      "a_rule": { "enabled": true,
        "when": { "type": "button" },
        "actions": [ { "type": "sip_call", "target_extension": "600" } ] },
      "c_rule": { "enabled": false,
        "when": { "type": "button" },
        "actions": [ { "type": "chime" } ] }
    }
  })");
  const auto acts = re.evaluate(makeEv("press", "d_front", ""), wallAtLocal(kThu, 12, 0, 0), 0);
  CHECK(typesOf(acts) == "sip_call,telegram");
}

TEST_CASE("rules: action parameters pass through without the type field") {
  RuleEngine re;
  re.setConfig(R"({
    "trigger_rules": {
      "r": { "enabled": true,
        "when": { "type": "button" },
        "actions": [ { "type": "telegram", "households": ["h_ox"], "with_snapshot": true },
                     { "type": "ha_event" } ] }
    }
  })");
  const auto acts = re.evaluate(makeEv("press", "d_front", ""), wallAtLocal(kThu, 12, 0, 0), 0);
  REQUIRE(acts.size() == 2);

  CHECK(acts[0].type == "telegram");
  auto p = json::parse(acts[0].params_json);
  REQUIRE(p);
  CHECK(json::getBool(p.get(), "with_snapshot"));
  cJSON* hh = json::get(p.get(), "households");
  REQUIRE(cJSON_IsArray(hh));
  CHECK(cJSON_GetArraySize(hh) == 1);
  CHECK(json::get(p.get(), "type") == nullptr);

  CHECK(acts[1].type == "ha_event");
  CHECK(acts[1].params_json == "{}");
}

TEST_CASE("rules: when.purposes branches by purpose and supports auto_reply") {
  RuleEngine re;

  re.setConfig(R"({
    "trigger_rules": {
      "r1_delivery": { "enabled": true,
        "when": { "type": "button", "purposes": ["p_delivery"] },
        "actions": [ { "type": "auto_reply", "reply_id": "qr_okihai" } ] },
      "r2_any": { "enabled": true,
        "when": { "type": "button" },
        "actions": [ { "type": "telegram", "households": ["h_ox"] } ] },
      "r3_multi": { "enabled": true,
        "when": { "type": "button", "purposes": ["p_sales", "p_mail"] },
        "actions": [ { "type": "chime", "sound": "ding2" } ] }
    }
  })");
  const int64_t noon = wallAtLocal(kThu, 12, 0, 0);

  auto pressWith = [](const char* payload) {
    EventRecord ev = makeEv("press", "d_front", "");
    ev.payload_json = payload;
    return ev;
  };

  struct Row {
    const char* payload;
    const char* want;
  };
  const Row rows[] = {

      {R"({"purpose":"p_delivery"})", "auto_reply,telegram"},
      {R"({"purpose":"p_sales"})", "telegram,chime"},
      {R"({"purpose":"p_mail"})", "telegram,chime"},

      {R"({"purpose":""})", "telegram"},
      {"{}", "telegram"},
      {"", "telegram"},

      {R"({"purpose":"p_unknown"})", "telegram"},

      {R"({"purpose":"p_delivery","visitor_lang":"en"})", "auto_reply,telegram"},
  };
  for (const auto& r : rows) {
    CAPTURE(r.payload);
    CHECK(typesOf(re.evaluate(pressWith(r.payload), noon, 0)) == r.want);
  }


  const auto acts = re.evaluate(pressWith(R"({"purpose":"p_delivery"})"), noon, 0);
  REQUIRE(acts.size() == 2);
  CHECK(acts[0].type == "auto_reply");
  auto p = json::parse(acts[0].params_json);
  REQUIRE(p);
  CHECK(json::getString(p.get(), "reply_id") == "qr_okihai");
  CHECK(json::get(p.get(), "type") == nullptr);


  EventRecord mo = makeEv("motion", "d_front", "");
  mo.payload_json = R"({"changed_pct":12.5})";
  CHECK(typesOf(re.evaluate(mo, noon, 0)) == "");
}

TEST_CASE("rules: malformed config JSON is treated as empty config") {
  RuleEngine re;
  const EventRecord bt = makeEv("press", "d_front", "");
  const int64_t noon = wallAtLocal(kThu, 12, 0, 0);

  re.setConfig("{oops");
  CHECK(re.evaluate(bt, noon, 0).empty());


  re.setConfig(R"({"trigger_rules":{"r":{"when":{"type":"button"},
    "actions":[{"type":"sip_call"}]}}})");
  CHECK(re.evaluate(bt, noon, 0).size() == 1);


  re.setConfig("not json at all");
  CHECK(re.evaluate(bt, noon, 0).empty());


  re.setConfig(R"({"trigger_rules": []})");
  CHECK(re.evaluate(bt, noon, 0).empty());
}
