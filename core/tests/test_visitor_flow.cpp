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

std::string validate(const cJSON* config) {
  std::string error;
  std::vector<visitor_flow::Warning> warnings;
  return visitor_flow::candidateValid(config, catalog(), &error, &warnings) ? "ok" : error;
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
  CHECK(writeKey("visitor_flow.start", "\"__call\"") == "visitor_flow.bad_target: start");
  CHECK(writeKey("visitor_flow.idle_s", "45") == "ok");
  CHECK(writeKey("visitor_flow.idle_s", "14") == "visitor_flow.bad_idle_s");
  CHECK(writeKey("visitor_flow.idle_s", "301") == "visitor_flow.bad_idle_s");
  CHECK(writeKey("visitor_flow.idle_s", "45.5") == "visitor_flow.bad_idle_s");
  CHECK(writeKey("visitor_flow", "{}") == "visitor_flow.container_write: visitor_flow");
  CHECK(writeKey("visitor_flow.steps", "{}") == "visitor_flow.container_write: visitor_flow.steps");
  CHECK(writeKey("visitor_flow.theme", "1") == "visitor_flow.unknown_key: visitor_flow.theme");
  CHECK(writeKey("visitor_flow.steps.c_any", R"({"kind":"call"})") == "ok");
  // A leaf below a step would mask one member of the step object regardless of age.
  CHECK(writeKey("visitor_flow.steps.c_any.purpose", "\"p_visit\"") ==
        "visitor_flow.step_leaf_write: visitor_flow.steps.c_any.purpose");
  CHECK(writeKey("visitor_flow.steps.bad id", R"({"kind":"call"})") ==
        "visitor_flow.bad_step_id: bad id");
  CHECK(writeKey("visitor_flow.steps.__call", R"({"kind":"call"})") ==
        "visitor_flow.bad_step_id: __call");
  CHECK(writeKey("doors.d_back.visitor_flow.start", "\"s_back\"") == "ok");
  CHECK(writeKey("doors.d_back.visitor_flow.start", "7") == "visitor_flow.bad_target: start");
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
        "visitor_flow.bad_text: s_x.o_a.label");
  CHECK(page("[" + option + "," + option + "]") == "visitor_flow.bad_option_id: s_x.o_a");
  CHECK(page(R"([{"id":"o_a","label":{"ja":"A"}}])") == "visitor_flow.bad_target: s_x.o_a");
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
        "visitor_flow.bad_text: s_x.title");
  // Limits count characters, not bytes: sixty Japanese characters are a legal title.
  std::string japanese;
  for (int i = 0; i < 60; ++i) japanese += "\xE3\x81\x82";
  CHECK(page("[" + option + "]", R"(,"title":{"ja":")" + japanese + "\"}") == "ok");
  CHECK(page("[" + option + "]", R"(,"body":{"ja":"one\n\ntwo\nstill two"})") == "ok");
  CHECK(page("[" + option + "]",
             R"(,"body":{"ja":"1\n\n2\n\n3\n\n4\n\n5\n\n6\n\n7\n\n8\n\n9"})") ==
        "visitor_flow.bad_text: s_x.body");
  CHECK(page("[" + option + "]", R"(,"title":{"ja":"two\nlines"})") ==
        "visitor_flow.bad_text: s_x.title");
  CHECK(page("[" + option + "]", R"(,"markup":"<b>")") == "visitor_flow.unknown_field: s_x");
  const std::string sha(64, 'a');
  CHECK(page("[" + option + "]", R"(,"images":[{"asset":")" + sha + R"(","place":"below"}])") == "ok");
  CHECK(page("[" + option + "]", R"(,"images":[{"asset":"nope"}])") == "visitor_flow.bad_images: s_x");
  CHECK(page("[" + option + "]", R"(,"images":[{"asset":")" + sha + R"("},{"asset":")" + sha +
                                     R"("},{"asset":")" + sha + R"("}])") ==
        "visitor_flow.bad_images: s_x");

  CHECK(writeKey(key, R"({"kind":"call","purpose":"p_visit","on_unanswered":"s_home"})") == "ok");
  CHECK(writeKey(key, R"({"kind":"call","to":"s_home"})") == "visitor_flow.unknown_field: s_x");
  CHECK(writeKey(key, R"({"kind":"notify","message":{"ja":"m"},"to":"e_x"})") == "ok");
  CHECK(writeKey(key, R"({"kind":"notify","to":"e_x"})") == "visitor_flow.bad_text: s_x.message");
  CHECK(writeKey(key, R"({"kind":"notify","message":{"ja":"m"}})") == "visitor_flow.bad_target: s_x");
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
                      R"("snapshot":{"source":"url","id":"x"}})") == "visitor_flow.bad_snapshot: s_x");
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
        "visitor_flow.bad_target_kind: start");
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
        "visitor_flow.unknown_asset: s_where");
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
        }) == "visitor_flow.unknown_target: d_back");
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
    json::setItem(written.get(), "visitor_flow", std::move(flow));
    CHECK(validate(written.get()) == "ok");
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
