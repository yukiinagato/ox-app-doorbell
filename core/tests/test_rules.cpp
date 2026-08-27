// RuleEngine のテスト (表駆動)。
#include <string>
#include <vector>

#include "doctest.h"
#include "events/events.h"
#include "util/json.h"

using namespace db;

namespace {

constexpr int64_t kDayMs = 86400000LL;
// 2026-08-27 は木曜 (epoch 日数 20692)。曜日計算の既知日付アンカー。
constexpr int64_t kThu = 20692;
constexpr int64_t kFri = kThu + 1;

// 現地時刻 (epoch 日数 day, h:m, tz オフセット分) を指す corrected_wall_ms を作る
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

// 結果のアクション型をカンマ連結 (順序検証用)
std::string typesOf(const std::vector<Action>& as) {
  std::string s;
  for (const auto& a : as) {
    if (!s.empty()) s += ",";
    s += a.type;
  }
  return s;
}

}  // namespace

TEST_CASE("rules: when マッチ (種別/doors/devices)") {
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
    const char* want;  // 期待アクション型 (ルール ID 昇順)
  };
  const Row rows[] = {
      {"press", "d_front", "", "sip_call"},          // button ルールにマッチ (別名)
      {"button", "d_front", "", "sip_call"},         // 計画書語彙そのままでもマッチ
      {"press", "d_back", "", ""},                   // doors 限定で非マッチ
      {"motion", "d_back", "", "ha_event"},          // doors 省略 = 全ドア
      {"motion", "d_front", "", "ha_event"},
      {"offline", "", "c2d1", "telegram,chime"},     // devices all + 個別指定の両方
      {"offline", "", "c9", "telegram"},             // devices 配列で非マッチ
      {"online", "", "c2d1", ""},                    // 種別違い (offline ルールのみ)
      {"answered", "d_front", "", ""},               // ルール無し種別
  };
  for (const auto& r : rows) {
    CAPTURE(r.type);
    CAPTURE(r.door);
    CAPTURE(r.device);
    CHECK(typesOf(re.evaluate(makeEv(r.type, r.door, r.device), noon, 0)) == r.want);
  }
}

TEST_CASE("rules: スケジュール窓 (日跨ぎ・曜日・境界)") {
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
      // 日跨ぎ窓 22:00-06:00 (木曜起点)
      {&mo, kThu, 23, 30, true},   // 木 23:30 → 当日夜側
      {&mo, kFri, 5, 0, true},     // 金 05:00 → 窓は木曜起点なのでマッチ
      {&mo, kThu, 12, 0, false},   // 木 12:00 → 窓外
      {&mo, kThu, 5, 0, false},    // 木 05:00 → 前日は水曜で days 外
      {&mo, kFri, 23, 30, false},  // 金 23:30 → days 外
      {&mo, kThu, 22, 0, true},    // 境界 from <= t
      {&mo, kFri, 6, 0, false},    // 境界 t < to
      // 通常窓 09:00-17:00 (木曜のみ) — 既知日付で weekday 計算を検証
      {&bt, kThu, 12, 0, true},    // 2026-08-27 は木曜
      {&bt, kFri, 12, 0, false},   // 金曜は days 外
      {&bt, kThu, 9, 0, true},     // 境界 from <= t
      {&bt, kThu, 17, 0, false},   // 境界 t < to
  };
  for (const auto& r : rows) {
    CAPTURE(r.day);
    CAPTURE(r.h);
    CAPTURE(r.m);
    CHECK(!re.evaluate(*r.ev, wallAtLocal(r.day, r.h, r.m, 0), 0).empty() == r.want);
  }
}

TEST_CASE("rules: tz_offset (JST +540) で現地時刻判定") {
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
  // JST 23:30 = UTC 14:30 の同一時点: JST では窓内、UTC では窓外
  const int64_t wall = wallAtLocal(kThu, 23, 30, jst);
  CHECK(re.evaluate(mo, wall, jst).size() == 1);
  CHECK(re.evaluate(mo, wall, 0).empty());
  // JST 05:00 (日跨ぎの朝側) もマッチ
  CHECK(re.evaluate(mo, wallAtLocal(kFri, 5, 0, jst), jst).size() == 1);
}

TEST_CASE("rules: quiet_hours の suppress / never_suppress") {
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
  // 窓内: chime は落ちる。telegram は suppress にあるが never_suppress が勝って残る。
  CHECK(typesOf(re.evaluate(bt, wallAtLocal(kThu, 23, 30, 0), 0)) == "sip_call,telegram");
  CHECK(typesOf(re.evaluate(bt, wallAtLocal(kFri, 6, 59, 0), 0)) == "sip_call,telegram");
  // 窓外: 全部残る
  CHECK(typesOf(re.evaluate(bt, wallAtLocal(kThu, 12, 0, 0), 0)) == "chime,sip_call,telegram");
  CHECK(typesOf(re.evaluate(bt, wallAtLocal(kFri, 7, 0, 0), 0)) == "chime,sip_call,telegram");
}

TEST_CASE("rules: enabled=false / 複数ルールの決定的順序") {
  RuleEngine re;
  // JSON 上は b_rule を先に書くが、結果はルール ID 昇順 (a_rule → b_rule)
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
  CHECK(typesOf(acts) == "sip_call,telegram");  // c_rule (無効) は出ない
}

TEST_CASE("rules: actions params の passthrough (type 除去)") {
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
  CHECK(json::get(p.get(), "type") == nullptr);  // type は params から除去済み

  CHECK(acts[1].type == "ha_event");
  CHECK(acts[1].params_json == "{}");  // 追加フィールド無し
}

TEST_CASE("rules: 壊れた設定 JSON は空設定として扱う") {
  RuleEngine re;
  const EventRecord bt = makeEv("press", "d_front", "");
  const int64_t noon = wallAtLocal(kThu, 12, 0, 0);

  re.setConfig("{oops");  // パース不能
  CHECK(re.evaluate(bt, noon, 0).empty());

  // 正しい設定に差し替えると動く
  re.setConfig(R"({"trigger_rules":{"r":{"when":{"type":"button"},
    "actions":[{"type":"sip_call"}]}}})");
  CHECK(re.evaluate(bt, noon, 0).size() == 1);

  // 再び壊れた設定 → 空設定に置き換わる (古い設定を引きずらない)
  re.setConfig("not json at all");
  CHECK(re.evaluate(bt, noon, 0).empty());

  // trigger_rules がオブジェクトでない場合も安全に空
  re.setConfig(R"({"trigger_rules": []})");
  CHECK(re.evaluate(bt, noon, 0).empty());
}
