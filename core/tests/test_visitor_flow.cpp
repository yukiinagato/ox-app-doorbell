// Visitor flow: the pure resolver and validator against the shared contract fixture.
#include <fstream>
#include <set>
#include <sstream>
#include <string>
#include <vector>

#include "doctest.h"
#include "node/node.h"
#include "node/visitor_flow.h"
#include "util/json.h"

using namespace db;

namespace {

// tools/conformance/fixtures/visitor-flow-v1.json, located from this source file so the test
// runs from any build directory.
std::string fixturePath() {
  std::string here = __FILE__;
  const size_t tests = here.rfind("/core/tests/");
  REQUIRE(tests != std::string::npos);
  return here.substr(0, tests) + "/tools/conformance/fixtures/visitor-flow-v1.json";
}

json::Doc loadFixture() {
  std::ifstream file(fixturePath());
  std::stringstream text;
  text << file.rdbuf();
  auto suite = json::parse(text.str());
  REQUIRE(suite);
  REQUIRE(json::getInt(suite.get(), "schema_version") == 1);
  return suite;
}

visitor_flow::TextFn catalog() {
  return [](const std::string& key, const std::string& lang) {
    return Node::builtinCatalogText(key, lang);
  };
}

visitor_flow::ResolveEnv fixtureEnv(const cJSON* resolve_case) {
  std::set<std::string> cached;
  const cJSON* hash = nullptr;
  cJSON_ArrayForEach(hash, json::get(resolve_case, "assets_cached")) cached.insert(hash->valuestring);
  visitor_flow::ResolveEnv env;
  env.text = catalog();
  env.asset_path = [cached](const std::string& sha256) {
    return cached.count(sha256) ? "/assets/" + sha256 : std::string();
  };
  return env;
}

const cJSON* fixtureCase(const cJSON* suite, const std::string& name) {
  const cJSON* item = nullptr;
  cJSON_ArrayForEach(item, json::get(suite, "resolve")) {
    if (json::getString(item, "name") == name) return item;
  }
  return nullptr;
}

std::string validate(const cJSON* config, std::string* detail = nullptr) {
  std::string error;
  std::vector<visitor_flow::Warning> warnings;
  return visitor_flow::candidateValid(config, catalog(), &error, &warnings, detail) ? "ok" : error;
}

std::string writeKey(const std::string& key, const std::string& value_json) {
  auto value = json::parse(value_json);
  REQUIRE(value);
  std::string error;
  return visitor_flow::writeKeyValid(key, value.get(), &error) ? "ok" : error;
}

}  // namespace

TEST_CASE("visitor flow: every resolve case of the contract fixture matches core") {
  auto suite = loadFixture();
  int checked = 0;
  const cJSON* item = nullptr;
  cJSON_ArrayForEach(item, json::get(suite.get(), "resolve")) {
    const std::string name = json::getString(item, "name");
    CAPTURE(name);
    auto resolved = visitor_flow::resolve(json::get(item, "config"), json::getString(item, "door"),
                                          fixtureEnv(item));
    REQUIRE(resolved);
    const bool same = cJSON_Compare(resolved.get(), json::get(item, "expect"), 1) != 0;
    if (!same) MESSAGE("resolved: " << json::dump(resolved.get()));
    CHECK(same);
    CHECK(validate(json::get(item, "config")) == json::getString(item, "write"));
    ++checked;
  }
  CHECK(checked >= 15);
}

TEST_CASE("visitor flow: a resolved document keeps resident-facing data inside core") {
  auto suite = loadFixture();
  const cJSON* item = fixtureCase(suite.get(), "explicit-flow");
  REQUIRE(item);
  auto shown = visitor_flow::resolve(json::get(item, "config"), "d_front", fixtureEnv(item));
  const cJSON* notify = json::get(json::get(shown.get(), "steps"), "n_left");
  REQUIRE(notify);
  CHECK(json::get(notify, "message") == nullptr);
  CHECK(json::get(notify, "snapshot") == nullptr);
  CHECK(json::dump(shown.get()).find("secret:") == std::string::npos);
  CHECK(json::dump(shown.get()).find("192.0.2.20") == std::string::npos);

  auto internal = visitor_flow::resolve(json::get(item, "config"), "d_front", fixtureEnv(item), true);
  notify = json::get(json::get(internal.get(), "steps"), "n_left");
  CHECK(json::getString(json::get(notify, "message"), "en") == "A parcel was left at the door");
  CHECK(json::getString(json::get(notify, "snapshot"), "id") == "porch_camera");
  // Even inside core the step names the camera; it never carries its address or credential.
  CHECK(json::dump(internal.get()).find("192.0.2.20") == std::string::npos);
}

TEST_CASE("visitor flow: written keys are leaves or one whole step") {
  CHECK(writeKey("visitor_flow.enabled", "true") == "ok");
  CHECK(writeKey("visitor_flow.enabled", "\"yes\"") == "visitor_flow.bad_boolean: visitor_flow.enabled");
  CHECK(writeKey("visitor_flow.require_call", "false") == "ok");
  CHECK(writeKey("visitor_flow.start", "\"s_home\"") == "ok");
  CHECK(writeKey("visitor_flow.start", "\"__call\"") == "visitor_flow.bad_start: start");
  CHECK(writeKey("visitor_flow.idle_s", "45") == "ok");
  CHECK(writeKey("visitor_flow.idle_s", "14") == "visitor_flow.bad_idle_s");
  CHECK(writeKey("visitor_flow.idle_s", "301") == "visitor_flow.bad_idle_s");
  CHECK(writeKey("visitor_flow.idle_s", "45.5") == "visitor_flow.bad_idle_s");
  CHECK(writeKey("visitor_flow", "{}") == "visitor_flow.container_write: visitor_flow");
  CHECK(writeKey("visitor_flow.steps", "{}") == "visitor_flow.container_write: visitor_flow.steps");
  CHECK(writeKey("visitor_flow.theme", "1") == "visitor_flow.unknown_key: visitor_flow.theme");
  CHECK(writeKey("visitor_flow.steps.c_any", R"({"kind":"call"})") == "ok");
  CHECK(writeKey("visitor_flow.steps.c_any", R"({"kind":"call","order":0})") == "ok");
  CHECK(writeKey("visitor_flow.steps.c_any", R"({"kind":"call","order":9999})") == "ok");
  for (const char* bad : {"-1", "10000", "1.5", "\"2\"", "null", "true"})
    CHECK(writeKey("visitor_flow.steps.c_any", std::string(R"({"kind":"call","order":)") + bad + "}") ==
          "visitor_flow.bad_order: c_any");
  CHECK(writeKey("visitor_flow.steps.e_x", R"({"kind":"end","order":3})") == "ok");
  CHECK(writeKey("visitor_flow.steps.n_x",
                 R"({"kind":"notify","message":{"ja":"m"},"to":"e_x","order":3})") == "ok");
  // A leaf below a step would mask one member of the step object regardless of age.
  CHECK(writeKey("visitor_flow.steps.c_any.purpose", "\"p_visit\"") ==
        "visitor_flow.step_leaf_write: visitor_flow.steps.c_any.purpose");
  CHECK(writeKey("visitor_flow.steps.bad id", R"({"kind":"call"})") ==
        "visitor_flow.bad_step_id: bad id");
  CHECK(writeKey("visitor_flow.steps.__call", R"({"kind":"call"})") ==
        "visitor_flow.bad_step_id: __call");
  CHECK(writeKey("doors.d_back.visitor_flow.start", "\"s_back\"") == "ok");
  CHECK(writeKey("doors.d_back.visitor_flow.start", "7") == "visitor_flow.bad_start: start");
  CHECK(writeKey("doors.d_back.visitor_flow", R"({"start":"s_back"})") == "ok");
  CHECK(writeKey("doors.d_back.visitor_flow", R"({"start":"s_back","steps":{}})") ==
        "visitor_flow.bad_door_flow");
  CHECK(writeKey("doors.d_back", R"({"label":{"ja":"x"},"visitor_flow":{"start":"s_back"}})") == "ok");
  CHECK(writeKey("doors.d_back.label", R"({"ja":"x"})") == "ok");
  CHECK(writeKey("ui.call_flow", "\"purpose_first\"") == "ok");
}

TEST_CASE("visitor flow: step shape matrix") {
  const std::string key = "visitor_flow.steps.s_x";
  auto page = [&](const std::string& options, const std::string& extra = "") {
    return writeKey(key, R"({"kind":"page")" + extra + R"(,"options":)" + options + "}");
  };
  const std::string option = R"({"id":"o_a","label":{"ja":"A"},"to":"c_any"})";
  CHECK(page("[" + option + "]") == "ok");
  CHECK(page("[]") == "visitor_flow.no_options: s_x");
  CHECK(page(R"([{"id":"o_a","to":"c_any"}])") == "visitor_flow.option_needs_label: s_x.o_a");
  CHECK(page(R"([{"id":"o_a","purpose":"p_visit","to":"c_any"}])") == "ok");
  CHECK(page(R"([{"id":"o_a","label":{"ja":""},"to":"c_any"}])") ==
        "visitor_flow.text_required: s_x.o_a.label");
  CHECK(page("[" + option + "," + option + "]") == "visitor_flow.bad_option_id: s_x.o_a");
  CHECK(page(R"([{"id":"o_a","label":{"ja":"A"}}])") == "visitor_flow.missing_target: s_x.o_a");
  CHECK(page(R"([{"id":"o_a","label":{"ja":"A"},"to":"c_any","style":"huge"}])") ==
        "visitor_flow.bad_style: s_x.o_a");
  CHECK(page(R"([{"id":"o_a","label":{"ja":"A"},"to":"c_any","style":"primary"},)"
             R"({"id":"o_b","label":{"ja":"B"},"to":"c_any","style":"primary"}])") ==
        "visitor_flow.multiple_primary: s_x");
  // No option member can carry a URL, a settings route or free-text entry.
  for (const char* forbidden : {"url", "href", "action", "open", "input", "settings"}) {
    CHECK(page(R"([{"id":"o_a","label":{"ja":"A"},"to":"c_any",")" + std::string(forbidden) +
               R"(":"https://example.com"}])") == "visitor_flow.unknown_field: s_x.o_a");
  }
  std::string many = "[";
  for (int i = 0; i < 13; ++i)
    many += std::string(i ? "," : "") + R"({"id":"o_)" + std::to_string(i) +
            R"(","label":{"ja":"A"},"to":"c_any"})";
  CHECK(page(many + "]") == "visitor_flow.too_many_options: s_x");

  const std::string title61(61, 'a');
  CHECK(page("[" + option + "]", R"(,"title":{"ja":")" + title61 + "\"}") ==
        "visitor_flow.text_too_long: s_x.title.ja");
  // Limits count characters, not bytes: sixty Japanese characters are a legal title.
  std::string japanese;
  for (int i = 0; i < 60; ++i) japanese += "\xE3\x81\x82";
  CHECK(page("[" + option + "]", R"(,"title":{"ja":")" + japanese + "\"}") == "ok");
  CHECK(page("[" + option + "]", R"(,"body":{"ja":"one\n\ntwo\nstill two"})") == "ok");
  CHECK(page("[" + option + "]",
             R"(,"body":{"ja":"1\n\n2\n\n3\n\n4\n\n5\n\n6\n\n7\n\n8\n\n9"})") ==
        "visitor_flow.too_many_paragraphs: s_x.body.ja");
  CHECK(page("[" + option + "]", R"(,"title":{"ja":"two\nlines"})") ==
        "visitor_flow.bad_character: s_x.title.ja");
  CHECK(page("[" + option + "]", R"(,"markup":"<b>")") == "visitor_flow.unknown_field: s_x");
  const std::string sha(64, 'a');
  CHECK(page("[" + option + "]", R"(,"images":[{"asset":")" + sha + R"(","place":"below"}])") == "ok");
  CHECK(page("[" + option + "]", R"(,"images":[{"asset":"nope"}])") == "visitor_flow.bad_asset: s_x.images[0]");
  CHECK(page("[" + option + "]", R"(,"images":[{"asset":")" + sha + R"("},{"asset":")" + sha +
                                     R"("},{"asset":")" + sha + R"("}])") ==
        "visitor_flow.too_many_images: s_x");

  CHECK(writeKey(key, R"({"kind":"call","purpose":"p_visit","on_unanswered":"s_home"})") == "ok");
  CHECK(writeKey(key, R"({"kind":"call","to":"s_home"})") == "visitor_flow.unknown_field: s_x");
  CHECK(writeKey(key, R"({"kind":"notify","message":{"ja":"m"},"to":"e_x"})") == "ok");
  CHECK(writeKey(key, R"({"kind":"notify","to":"e_x"})") == "visitor_flow.text_required: s_x.message");
  CHECK(writeKey(key, R"({"kind":"notify","message":{"ja":"m"}})") == "visitor_flow.missing_target: s_x");
  CHECK(writeKey(key, R"({"kind":"notify","message":{"ja":"m"},"to":"e_x",)"
                      R"("snapshot":{"source":"media_source","id":"porch_camera"}})") == "ok");
  CHECK(writeKey(key, R"({"kind":"notify","message":{"ja":"m"},"to":"e_x",)"
                      R"("snapshot":{"source":"door_station"}})") == "ok");
  // A snapshot names a configured camera; it can never carry an address or a credential.
  CHECK(writeKey(key, R"({"kind":"notify","message":{"ja":"m"},"to":"e_x",)"
                      R"("snapshot":{"source":"media_source","id":"porch_camera",)"
                      R"("url":"http://user:pw@192.0.2.20/s.jpg"}})") ==
        "visitor_flow.bad_snapshot: s_x");
  CHECK(writeKey(key, R"({"kind":"notify","message":{"ja":"m"},"to":"e_x",)"
                      R"("snapshot":{"source":"url","id":"x"}})") == "visitor_flow.bad_snapshot_source: s_x");
  CHECK(writeKey(key, R"({"kind":"end","title":{"ja":"t"},"return_s":8})") == "ok");
  CHECK(writeKey(key, R"({"kind":"end","return_s":2})") == "visitor_flow.bad_return_s: s_x");
  CHECK(writeKey(key, R"({"kind":"end","return_s":61})") == "visitor_flow.bad_return_s: s_x");
  CHECK(writeKey(key, R"({"kind":"survey"})") == "visitor_flow.unknown_kind: s_x");
  CHECK(writeKey(key, "[]") == "visitor_flow.bad_step: s_x");
}

TEST_CASE("visitor flow: graph rules on the configuration a write would leave") {
  auto suite = loadFixture();
  const cJSON* item = fixtureCase(suite.get(), "explicit-flow");
  REQUIRE(item);
  auto with = [&](const std::function<void(cJSON*)>& change) {
    json::Doc config(cJSON_Duplicate(json::get(item, "config"), 1));
    change(config.get());
    return validate(config.get());
  };
  auto steps_of = [](cJSON* config) {
    return json::get(json::get(config, "visitor_flow"), "steps");
  };
  CHECK(with([](cJSON*) {}) == "ok");
  CHECK(with([&](cJSON* c) { cJSON_DeleteItemFromObject(steps_of(c), "e_thanks"); }) ==
        "visitor_flow.unknown_target: n_left");
  CHECK(with([&](cJSON* c) { json::set(json::get(steps_of(c), "n_left"), "to", "s_home"); }) ==
        "visitor_flow.bad_target_kind: n_left");
  CHECK(with([&](cJSON* c) {
          json::set(json::get(steps_of(c), "c_delivery"), "on_unanswered", "e_thanks");
        }) == "visitor_flow.bad_target_kind: c_delivery");
  CHECK(with([&](cJSON* c) { json::set(json::get(c, "visitor_flow"), "start", "c_any"); }) ==
        "visitor_flow.start_not_page: start");
  CHECK(with([&](cJSON* c) { cJSON_DeleteItemFromObject(json::get(c, "visitor_flow"), "start"); }) ==
        "visitor_flow.missing_start");
  CHECK(with([&](cJSON* c) { json::set(json::get(steps_of(c), "c_visit"), "purpose", "p_gone"); }) ==
        "visitor_flow.unknown_purpose: c_visit");
  // A purpose that exists but is switched off is still a legal reference: the option simply
  // disappears until it is switched back on.
  CHECK(with([&](cJSON* c) {
          json::setBool(json::get(json::get(c, "visit_purposes"), "p_visit"), "enabled", false);
        }) == "ok");
  CHECK(with([&](cJSON* c) { cJSON_DeleteItemFromObject(c, "assets"); }) ==
        "visitor_flow.unknown_asset: s_where.images[0]");
  CHECK(with([&](cJSON* c) { cJSON_DeleteItemFromObject(c, "media_sources"); }) ==
        "visitor_flow.unknown_camera: n_left");
  CHECK(with([&](cJSON* c) {
          cJSON* streams = json::get(json::get(json::get(c, "media_sources"), "porch_camera"), "streams");
          cJSON_DeleteItemFromObject(streams, "snapshot");
          json::set(json::addObj(streams, "mjpeg"), "url", "http://192.0.2.20/live.mjpeg");
        }) == "visitor_flow.unknown_camera: n_left");
  CHECK(with([&](cJSON* c) {
          cJSON* option = cJSON_GetArrayItem(json::get(json::get(steps_of(c), "s_where"), "options"), 0);
          json::set(option, "to", "s_home");
        }) == "visitor_flow.cycle: s_home");
  CHECK(with([&](cJSON* c) {
          json::set(json::addObj(json::addObj(json::get(c, "doors"), "d_back"), "visitor_flow"),
                    "start", "s_gone");
        }) == "visitor_flow.unknown_start: doors.d_back.start");
  CHECK(with([&](cJSON* c) {
          json::set(json::addObj(json::addObj(json::get(c, "doors"), "d_back"), "visitor_flow"),
                    "start", "s_where");
        }) == "visitor_flow.no_reachable_call: d_back");
  // Thirty-three steps, and a seven-page chain.
  CHECK(with([&](cJSON* c) {
          for (int i = 0; i < 25; ++i)
            json::set(json::addObj(steps_of(c), ("c_extra" + std::to_string(i)).c_str()), "kind", "call");
        }) == "visitor_flow.too_many_steps");
  CHECK(with([&](cJSON* c) {
          std::string previous = "s_where";
          for (int i = 0; i < 4; ++i) {
            const std::string id = "s_deep" + std::to_string(i);
            cJSON* page = json::addObj(steps_of(c), id.c_str());
            json::set(page, "kind", "page");
            cJSON* option = json::pushObj(json::addArr(page, "options"));
            json::set(option, "id", "o_x");
            json::set(json::addObj(option, "label"), "ja", "x");
            json::set(option, "to", "c_any");
            cJSON* link = cJSON_GetArrayItem(
                json::get(json::get(steps_of(c), previous.c_str()), "options"), 0);
            json::set(link, "to", id);
            previous = id;
          }
        }) == "visitor_flow.too_deep: s_home");

  // The switch the administrator owns: a notify-only door is refused until it is turned off,
  // and then accepted with a warning rather than silently.
  const cJSON* notify_only = fixtureCase(suite.get(), "require-call-false");
  REQUIRE(notify_only);
  json::Doc config(cJSON_Duplicate(json::get(notify_only, "config"), 1));
  std::string error;
  std::vector<visitor_flow::Warning> warnings;
  CHECK(visitor_flow::candidateValid(config.get(), catalog(), &error, &warnings));
  REQUIRE(warnings.size() == 1);
  CHECK(warnings[0].message_key == "visitor_flow.no_call");
  json::setBool(json::get(config.get(), "visitor_flow"), "require_call", true);
  CHECK(validate(config.get()) == "visitor_flow.no_reachable_call: start");
  // Switched off, the wizard is not judged at all.
  json::setBool(json::get(config.get(), "visitor_flow"), "enabled", false);
  CHECK(validate(config.get()) == "ok");
}

TEST_CASE("visitor flow: a crowded page is a warning, not an error") {
  auto suite = loadFixture();
  json::Doc config(cJSON_Duplicate(json::get(fixtureCase(suite.get(), "explicit-flow"), "config"), 1));
  cJSON* parcel = json::get(json::get(json::get(config.get(), "visitor_flow"), "steps"), "s_parcel");
  for (const char* id : {"o_c", "o_d", "o_e"}) {
    cJSON* option = json::pushObj(json::get(parcel, "options"));
    json::set(option, "id", id);
    json::set(json::addObj(option, "label"), "ja", id);
    json::set(option, "to", "c_any");
  }
  std::string error;
  std::vector<visitor_flow::Warning> warnings;
  REQUIRE(visitor_flow::candidateValid(config.get(), catalog(), &error, &warnings));
  REQUIRE(warnings.size() == 1);
  CHECK(warnings[0].key == "visitor_flow.steps.s_parcel");
  CHECK(warnings[0].message_key == "visitor_flow.crowded_page");
}

TEST_CASE("visitor flow: templates are writable flows") {
  auto suite = loadFixture();
  const cJSON* config = json::get(fixtureCase(suite.get(), "default-with-delivery"), "config");
  for (const char* name : {"default", "purposes", "delivery"}) {
    CAPTURE(name);
    auto flow = visitor_flow::templateFlow(config, catalog(), name);
    REQUIRE(flow);
    json::Doc written(cJSON_Duplicate(config, 1));
    const cJSON* step = nullptr;
    cJSON_ArrayForEach(step, json::get(flow.get(), "steps")) {
      std::string error;
      CHECK(visitor_flow::writeKeyValid(std::string("visitor_flow.steps.") + step->string, step,
                                        &error));
      CHECK(error == "");
    }
    const cJSON* home = json::get(json::get(json::get(flow.get(), "steps"), "s_home"), "options");
    CHECK(json::get(json::get(json::get(flow.get(), "steps"), "c_any"), "kind") == nullptr);
    const cJSON* home_option = nullptr;
    cJSON_ArrayForEach(home_option, home) {
      CHECK(json::getString(home_option, "id") != "o_call");
      CHECK(json::getString(home_option, "style").empty());
    }
    json::setItem(written.get(), "visitor_flow", std::move(flow));
    CHECK(validate(written.get()) == "ok");
  }
  {
    auto flow = visitor_flow::templateFlow(config, catalog(), "delivery");
    const cJSON* steps = json::get(flow.get(), "steps");
    CHECK(json::getInt(json::get(steps, "s_home"), "order", -1) == 0);
    std::set<int> seen;
    const cJSON* step = nullptr;
    cJSON_ArrayForEach(step, steps) seen.insert(static_cast<int>(json::getInt(step, "order", -1)));
    CHECK(static_cast<int>(seen.size()) == cJSON_GetArraySize(steps));
    CHECK(*seen.begin() == 0);
    CHECK(*seen.rbegin() == cJSON_GetArraySize(steps) - 1);
  }
  const cJSON* none = json::get(fixtureCase(suite.get(), "default-no-purposes"), "config");
  for (const char* name : {"default", "purposes"}) {
    auto flow = visitor_flow::templateFlow(none, catalog(), name);
    const cJSON* home = json::get(json::get(flow.get(), "steps"), "s_home");
    CHECK(cJSON_GetArraySize(json::get(home, "options")) == 1);
    CHECK(json::getString(cJSON_GetArrayItem(json::get(home, "options"), 0), "style") == "primary");
    CHECK(json::getString(json::get(json::get(flow.get(), "steps"), "c_any"), "kind") == "call");
  }
  CHECK(visitor_flow::templateFlow(config, catalog(), "nonsense") == nullptr);
  auto plain = visitor_flow::templateFlow(config, catalog(), "purposes");
  CHECK(json::get(json::get(plain.get(), "steps"), "s_parcel") == nullptr);

  // The delivery template works on an install that has no delivery purpose at all.
  const cJSON* bare = json::get(fixtureCase(suite.get(), "default-without-delivery"), "config");
  auto delivery = visitor_flow::templateFlow(bare, catalog(), "delivery");
  const cJSON* steps = json::get(delivery.get(), "steps");
  CHECK(json::getString(json::get(steps, "c_delivery"), "on_unanswered") == "s_parcel");
  CHECK(json::get(json::get(steps, "n_left"), "purpose") == nullptr);
  CHECK(json::get(json::get(steps, "n_left"), "snapshot") == nullptr);
  CHECK(json::get(json::get(steps, "s_where"), "images") == nullptr);
}

TEST_CASE("visitor flow: every refusal has its own code, location and detail") {
  struct Row {
    std::string code;
    std::string key;
    std::string value;
    std::string location;
    std::string detail;
  };
  std::string many_options = R"({"kind":"page","options":[)";
  for (int i = 0; i < 13; ++i)
    many_options += std::string(i ? "," : "") + R"({"id":"o_)" + std::to_string(i) +
                    R"(","label":{"ja":"A"},"to":"c_any"})";
  many_options += "]}";
  const std::string long_title = R"({"kind":"page","title":{"ja":")" + std::string(61, 'a') +
                                 R"("},"options":[{"id":"o","label":{"ja":"A"},"to":"c_any"}]})";
  const std::string sha(64, 'a');
  const std::string option = R"({"id":"o_a","label":{"ja":"A"},"to":"c_any")";
  auto page = [&](const std::string& extra) {
    return R"({"kind":"page","options":[)" + option + "," + extra + "}]}";
  };
  auto images = [&](int count) {
    std::string out = R"({"kind":"end","images":[)";
    for (int i = 0; i < count; ++i) out += std::string(i ? "," : "") + R"({"asset":")" + sha + R"("})";
    return out + "]}";
  };
  const std::string notify = R"({"kind":"notify","message":{"ja":"m"},"to":"e_x")";
  const std::string s = "visitor_flow.steps.s_x";
  const std::vector<Row> rows = {
      {"bad_step_id", "visitor_flow.steps.bad id", R"({"kind":"call"})", "bad id", ""},
      {"bad_step", s, "[]", "s_x", ""},
      {"unknown_kind", s, R"({"kind":"survey"})", "s_x", ""},
      {"unknown_field", s, R"({"kind":"call","to":"s_home"})", "s_x", ""},
      {"no_options", s, R"({"kind":"page","options":[]})", "s_x", ""},
      {"too_many_options", s, many_options, "s_x", R"({"limit":12,"value":13})"},
      {"bad_option_id", s, R"({"kind":"page","options":[{"id":"a b","to":"c_any"}]})", "s_x.a b", ""},
      {"option_needs_label", s, R"({"kind":"page","options":[{"id":"o_a","to":"c_any"}]})", "s_x.o_a", ""},
      {"text_required", s, R"({"kind":"page","options":[{"id":"o_a","label":{"ja":""},"to":"c_any"}]})",
       "s_x.o_a.label", ""},
      {"text_required", s, R"({"kind":"notify","message":{"ja":""},"to":"e_x"})", "s_x.message", ""},
      {"text_required", s, R"({"kind":"notify","to":"e_x"})", "s_x.message", ""},
      {"text_too_long", s, long_title, "s_x.title.ja", R"({"lang":"ja","limit":60,"value":61})"},
      {"too_many_paragraphs", s, R"({"kind":"end","body":{"en":"1\n\n2\n\n3\n\n4\n\n5\n\n6\n\n7\n\n8\n\n9"}})",
       "s_x.body.en", R"({"lang":"en","limit":8,"value":9})"},
      {"bad_character", s, R"({"kind":"end","title":{"ja":"a\nb"}})", "s_x.title.ja", R"({"lang":"ja"})"},
      {"bad_text", s, R"({"kind":"end","title":{"ja":5}})", "s_x.title.ja", ""},
      {"bad_text", s, R"({"kind":"end","title":"plain"})", "s_x.title", ""},
      {"bad_language", s, R"({"kind":"end","title":{"j1":"a"}})", "s_x.title", ""},
      {"too_many_languages", s,
       R"({"kind":"end","title":{"aa":"a","ab":"a","ac":"a","ad":"a","ae":"a","af":"a","ag":"a","ah":"a","ai":"a"}})",
       "s_x.title", R"({"limit":8,"value":9})"},
      {"bad_icon", s, page(R"("icon":5)"), "s_x.o_a", ""},
      {"bad_style", s, page(R"("style":"huge")"), "s_x.o_a", ""},
      {"bad_enabled", s, page(R"("enabled":"no")"), "s_x.o_a", ""},
      {"bad_purpose", s, R"({"kind":"call","purpose":"a.b"})", "s_x", ""},
      {"missing_target", s, R"({"kind":"notify","message":{"ja":"m"}})", "s_x", ""},
      {"missing_target", s, R"({"kind":"page","options":[{"id":"o_a","label":{"ja":"A"}}]})", "s_x.o_a", ""},
      {"bad_target", s, R"({"kind":"notify","message":{"ja":"m"},"to":"__x"})", "s_x", ""},
      {"multiple_primary", s,
       R"({"kind":"page","options":[{"id":"a","label":{"ja":"A"},"to":"c","style":"primary"},)"
       R"({"id":"b","label":{"ja":"B"},"to":"c","style":"primary"}]})",
       "s_x", ""},
      {"too_many_images", s, images(3), "s_x", R"({"limit":2,"value":3})"},
      {"bad_images", s, R"({"kind":"end","images":{}})", "s_x", ""},
      {"bad_asset", s, R"({"kind":"end","images":[{"asset":"nope"}]})", "s_x.images[0]", ""},
      {"bad_placement", s, R"({"kind":"end","images":[{"asset":")" + sha + R"(","place":"left"}]})",
       "s_x.images[0]", ""},
      {"text_too_long", s,
       R"({"kind":"end","images":[{"asset":")" + sha + R"(","alt":{"ja":")" + std::string(121, 'a') + R"("}}]})",
       "s_x.images[0].alt.ja", R"({"lang":"ja","limit":120,"value":121})"},
      {"bad_order", s, R"({"kind":"call","order":-1})", "s_x", R"({"min":0,"max":9999})"},
      {"bad_return_s", s, R"({"kind":"end","return_s":2})", "s_x", R"({"min":3,"max":60})"},
      {"bad_snapshot", s, notify + R"(,"snapshot":{"source":"door_station","x":1}})", "s_x", ""},
      {"bad_snapshot_source", s, notify + R"(,"snapshot":{"source":"url"}})", "s_x", ""},
      {"bad_snapshot_camera", s, notify + R"(,"snapshot":{"source":"media_source"}})", "s_x", ""},
      {"bad_start", "visitor_flow.start", "7", "start", ""},
      {"bad_start", "doors.d_back.visitor_flow.start", "7", "start", ""},
      {"bad_door_flow", "doors.d_back.visitor_flow", R"({"x":1})", "", ""},
      {"bad_idle_s", "visitor_flow.idle_s", "14", "", R"({"min":15,"max":300})"},
      {"bad_boolean", "visitor_flow.enabled", "\"yes\"", "visitor_flow.enabled", ""},
      {"container_write", "visitor_flow.steps", "{}", "visitor_flow.steps", ""},
      {"step_leaf_write", "visitor_flow.steps.c_any.purpose", "\"p\"", "visitor_flow.steps.c_any.purpose", ""},
      {"unknown_key", "visitor_flow.theme", "1", "visitor_flow.theme", ""},
  };
  for (const Row& row : rows) {
    auto value = json::parse(row.value);
    REQUIRE(value);
    std::string error, detail;
    INFO(row.code << " " << row.key);
    CHECK_FALSE(visitor_flow::writeKeyValid(row.key, value.get(), &error, &detail));
    CHECK(error == "visitor_flow." + row.code + (row.location.empty() ? "" : ": " + row.location));
    CHECK(detail == row.detail);
  }

  auto suite = loadFixture();
  const cJSON* item = fixtureCase(suite.get(), "explicit-flow");
  REQUIRE(item);
  auto steps_of = [](cJSON* config) { return json::get(json::get(config, "visitor_flow"), "steps"); };
  auto refused = [&](const std::function<void(cJSON*)>& change, const std::string& detail) {
    json::Doc config(cJSON_Duplicate(json::get(item, "config"), 1));
    change(config.get());
    std::string reported;
    const std::string error = validate(config.get(), &reported);
    CHECK(reported == detail);
    return error;
  };
  CHECK(refused([&](cJSON* c) {
          const cJSON* image = cJSON_GetArrayItem(json::get(json::get(steps_of(c), "s_where"), "images"), 0);
          json::set(json::get(json::get(c, "assets"), json::getString(image, "asset").c_str()), "type",
                    "application/pdf");
        }, "") == "visitor_flow.asset_not_image: s_where.images[0]");
  CHECK(refused([&](cJSON* c) {
          for (int i = 0; i < 25; ++i)
            json::set(json::addObj(steps_of(c), ("c_extra" + std::to_string(i)).c_str()), "kind", "call");
        }, R"({"limit":32,"value":33})") == "visitor_flow.too_many_steps");
  CHECK(refused([&](cJSON* c) { json::set(json::get(c, "visitor_flow"), "start", "s_gone"); }, "") ==
        "visitor_flow.unknown_start: start");
  CHECK(refused([&](cJSON* c) {
          json::set(json::addObj(json::addObj(json::get(c, "doors"), "d_back"), "visitor_flow"), "start",
                    "c_any");
        }, "") == "visitor_flow.start_not_page: doors.d_back.start");
}

TEST_CASE("visitor flow: a disabled purpose is a warning, not a refusal") {
  auto suite = loadFixture();
  const cJSON* item = fixtureCase(suite.get(), "explicit-flow");
  REQUIRE(item);
  json::Doc config(cJSON_Duplicate(json::get(item, "config"), 1));
  json::setBool(json::get(json::get(config.get(), "visit_purposes"), "p_visit"), "enabled", false);
  std::string error;
  std::vector<visitor_flow::Warning> warnings;
  CHECK(visitor_flow::candidateValid(config.get(), catalog(), &error, &warnings));
  bool found = false;
  for (const auto& warning : warnings) found = found || warning.message_key == "visitor_flow.disabled_purpose";
  CHECK(found);
}
