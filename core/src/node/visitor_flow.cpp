#include "node/visitor_flow.h"

#include <algorithm>
#include <cmath>
#include <map>
#include <set>
#include <tuple>

namespace db {
namespace visitor_flow {
namespace {

const char* const kBuiltinLanguages[] = {"ja", "en", "zh"};

bool fail(std::string* error, const std::string& code, const std::string& where = "") {
  *error = "visitor_flow." + code + (where.empty() ? "" : ": " + where);
  return false;
}

bool idValid(const std::string& id) {
  if (id.empty() || id.size() > 32 || id.rfind("__", 0) == 0) return false;
  for (unsigned char c : id)
    if (!(std::isalnum(c) || c == '_' || c == '-')) return false;
  return true;
}

// Purpose and media-source keys are written by other editors; only their shape is checked here.
bool referenceValid(const cJSON* value, size_t max_size) {
  if (!cJSON_IsString(value) || !value->valuestring) return false;
  const std::string text = value->valuestring;
  return !text.empty() && text.size() <= max_size &&
         text.find_first_of(". /\\") == std::string::npos;
}

bool sha256Valid(const std::string& text) {
  if (text.size() != 64) return false;
  for (char c : text)
    if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
  return true;
}

size_t codePoints(const std::string& text) {
  size_t count = 0;
  for (unsigned char c : text)
    if ((c & 0xC0) != 0x80) count++;
  return count;
}

bool wholeNumber(const cJSON* value, int64_t low, int64_t high) {
  if (!cJSON_IsNumber(value)) return false;
  const double number = value->valuedouble;
  return std::floor(number) == number && number >= static_cast<double>(low) &&
         number <= static_cast<double>(high);
}

bool hasOnly(const cJSON* object, const std::set<std::string>& allowed) {
  const cJSON* field = nullptr;
  cJSON_ArrayForEach(field, object) {
    if (!field->string || !allowed.count(field->string)) return false;
  }
  return true;
}

// A blank line starts a paragraph; a single newline is only a line break.
size_t paragraphs(const std::string& text) {
  size_t count = 0;
  bool in_paragraph = false;
  size_t line_start = 0;
  while (line_start <= text.size()) {
    size_t line_end = text.find('\n', line_start);
    if (line_end == std::string::npos) line_end = text.size();
    const bool blank =
        text.find_first_not_of(" \t\r", line_start) >= line_end;
    if (blank) {
      in_paragraph = false;
    } else if (!in_paragraph) {
      in_paragraph = true;
      count++;
    }
    line_start = line_end + 1;
  }
  return count;
}

// {lang: text}. Plain text only: no control characters other than the newline a body may use.
bool textMapValid(const cJSON* value, size_t max_chars, size_t max_paragraphs, bool required) {
  if (!cJSON_IsObject(value)) return false;
  int entries = 0;
  bool any_text = false;
  const cJSON* item = nullptr;
  cJSON_ArrayForEach(item, value) {
    if (++entries > 8 || !item->string || !cJSON_IsString(item) || !item->valuestring) return false;
    const std::string lang = item->string;
    if (lang.size() < 2 || lang.size() > 8) return false;
    for (unsigned char c : lang)
      if (!(std::isalpha(c) || c == '-')) return false;
    const std::string text = item->valuestring;
    if (codePoints(text) > max_chars) return false;
    for (unsigned char c : text)
      if (c < 0x20 && !(c == '\n' && max_paragraphs > 0)) return false;
    if (max_paragraphs > 0 && paragraphs(text) > max_paragraphs) return false;
    if (!text.empty()) any_text = true;
  }
  return any_text || !required;
}

bool imagesValid(const cJSON* images) {
  if (!cJSON_IsArray(images) || cJSON_GetArraySize(images) > kMaxImages) return false;
  const cJSON* image = nullptr;
  cJSON_ArrayForEach(image, images) {
    if (!cJSON_IsObject(image) || !hasOnly(image, {"asset", "alt", "place"})) return false;
    if (!sha256Valid(json::getString(image, "asset"))) return false;
    const cJSON* alt = json::get(image, "alt");
    if (alt && !textMapValid(alt, 120, 0, false)) return false;
    const cJSON* place = json::get(image, "place");
    if (place && json::getString(image, "place") != "above" &&
        json::getString(image, "place") != "below")
      return false;
  }
  return true;
}

bool optionalTargetValid(const cJSON* step, const char* field) {
  const cJSON* target = json::get(step, field);
  return !target || (cJSON_IsString(target) && idValid(target->valuestring));
}

bool stepShapeValid(const std::string& id, const cJSON* step, std::string* error) {
  if (!idValid(id)) return fail(error, "bad_step_id", id);
  if (!cJSON_IsObject(step)) return fail(error, "bad_step", id);
  const std::string kind = json::getString(step, "kind");
  const cJSON* title = json::get(step, "title");
  const cJSON* body = json::get(step, "body");
  const cJSON* images = json::get(step, "images");
  const cJSON* purpose = json::get(step, "purpose");
  if (kind == "page" || kind == "end") {
    if (title && !textMapValid(title, 60, 0, false)) return fail(error, "bad_text", id + ".title");
    if (body && !textMapValid(body, 600, 8, false)) return fail(error, "bad_text", id + ".body");
    if (images && !imagesValid(images)) return fail(error, "bad_images", id);
  }
  if (kind == "page") {
    if (!hasOnly(step, {"kind", "title", "body", "images", "options"}))
      return fail(error, "unknown_field", id);
    const cJSON* options = json::get(step, "options");
    if (!cJSON_IsArray(options) || cJSON_GetArraySize(options) < 1)
      return fail(error, "no_options", id);
    if (cJSON_GetArraySize(options) > kMaxOptions) return fail(error, "too_many_options", id);
    std::set<std::string> seen;
    int primaries = 0;
    const cJSON* option = nullptr;
    cJSON_ArrayForEach(option, options) {
      const std::string option_id = json::getString(option, "id");
      const std::string where = id + "." + option_id;
      if (!cJSON_IsObject(option) || !idValid(option_id) || !seen.insert(option_id).second)
        return fail(error, "bad_option_id", where);
      // The closed field list is what keeps an option from ever opening settings, Admin, a URL
      // or free-text entry: there is no member that could carry one.
      if (!hasOnly(option, {"id", "label", "purpose", "icon", "style", "enabled", "to"}))
        return fail(error, "unknown_field", where);
      const cJSON* label = json::get(option, "label");
      const cJSON* option_purpose = json::get(option, "purpose");
      if (!label && !option_purpose) return fail(error, "option_needs_label", where);
      if (label && !textMapValid(label, 40, 0, !option_purpose))
        return fail(error, "bad_text", where + ".label");
      if (option_purpose && !referenceValid(option_purpose, 64))
        return fail(error, "bad_purpose", where);
      const cJSON* icon = json::get(option, "icon");
      if (icon && (!cJSON_IsString(icon) || std::string(icon->valuestring).size() > 32))
        return fail(error, "bad_icon", where);
      const cJSON* style = json::get(option, "style");
      const std::string style_name = json::getString(option, "style");
      if (style && style_name != "primary" && style_name != "normal")
        return fail(error, "bad_style", where);
      if (style_name == "primary" && ++primaries > 1) return fail(error, "multiple_primary", id);
      const cJSON* enabled = json::get(option, "enabled");
      if (enabled && !cJSON_IsBool(enabled)) return fail(error, "bad_enabled", where);
      if (!idValid(json::getString(option, "to"))) return fail(error, "bad_target", where);
    }
    return true;
  }
  if (kind == "call") {
    if (!hasOnly(step, {"kind", "purpose", "on_unanswered"}))
      return fail(error, "unknown_field", id);
    if (purpose && !referenceValid(purpose, 64)) return fail(error, "bad_purpose", id);
    if (!optionalTargetValid(step, "on_unanswered")) return fail(error, "bad_target", id);
    return true;
  }
  if (kind == "notify") {
    if (!hasOnly(step, {"kind", "message", "purpose", "to", "snapshot"}))
      return fail(error, "unknown_field", id);
    const cJSON* message = json::get(step, "message");
    if (!message || !textMapValid(message, 200, 0, true))
      return fail(error, "bad_text", id + ".message");
    if (purpose && !referenceValid(purpose, 64)) return fail(error, "bad_purpose", id);
    if (!idValid(json::getString(step, "to"))) return fail(error, "bad_target", id);
    const cJSON* snapshot = json::get(step, "snapshot");
    if (snapshot) {
      if (!cJSON_IsObject(snapshot) || !hasOnly(snapshot, {"source", "id"}))
        return fail(error, "bad_snapshot", id);
      const std::string source = json::getString(snapshot, "source");
      const cJSON* camera = json::get(snapshot, "id");
      const bool external = source == "media_source" && referenceValid(camera, 128);
      const bool door = source == "door_station" && !camera;
      if (!external && !door) return fail(error, "bad_snapshot", id);
    }
    return true;
  }
  if (kind == "end") {
    if (!hasOnly(step, {"kind", "title", "body", "images", "return_s"}))
      return fail(error, "unknown_field", id);
    const cJSON* return_s = json::get(step, "return_s");
    if (return_s && !wholeNumber(return_s, 3, 60)) return fail(error, "bad_return_s", id);
    return true;
  }
  return fail(error, "unknown_kind", id);
}

bool doorFlowValid(const cJSON* door_flow, std::string* error) {
  if (!door_flow || cJSON_IsNull(door_flow)) return true;
  if (!cJSON_IsObject(door_flow) || !hasOnly(door_flow, {"start"}))
    return fail(error, "bad_door_flow");
  const cJSON* start = json::get(door_flow, "start");
  if (start && (!cJSON_IsString(start) || !idValid(start->valuestring)))
    return fail(error, "bad_target", "start");
  return true;
}

const cJSON* purposeEntry(const cJSON* config, const std::string& id) {
  return id.empty() ? nullptr : json::get(json::get(config, "visit_purposes"), id.c_str());
}

bool purposeSelectable(const cJSON* config, const std::string& id) {
  const cJSON* entry = purposeEntry(config, id);
  return cJSON_IsObject(entry) && json::getBool(entry, "enabled", true);
}

bool imageAssetKnown(const cJSON* config, const std::string& sha256) {
  const cJSON* entry = json::get(json::get(config, "assets"), sha256.c_str());
  return cJSON_IsObject(entry) && json::getString(entry, "type").rfind("image/", 0) == 0;
}

bool cameraHasSnapshot(const cJSON* config, const std::string& id) {
  const cJSON* source = json::get(json::get(config, "media_sources"), id.c_str());
  const cJSON* stream = json::get(json::get(source, "streams"), "snapshot");
  return !json::getString(stream, "url").empty();
}

std::vector<std::string> languages(const cJSON* config) {
  std::vector<std::string> out;
  const cJSON* item = nullptr;
  cJSON_ArrayForEach(item, json::get(json::get(config, "ui"), "languages")) {
    if (cJSON_IsString(item) && item->valuestring && *item->valuestring &&
        std::find(out.begin(), out.end(), item->valuestring) == out.end())
      out.push_back(item->valuestring);
  }
  if (out.empty()) out.push_back("ja");
  return out;
}

// One entry per offered language: the language itself, then Japanese, then any text present,
// then fallback. Null when nothing at all can be shown.
json::Doc completeText(const cJSON* map, const std::vector<std::string>& langs,
                       const std::string& fallback) {
  std::string japanese = json::getString(map, "ja");
  std::string any;
  const cJSON* item = nullptr;
  cJSON_ArrayForEach(item, map) {
    if (any.empty() && cJSON_IsString(item) && item->valuestring) any = item->valuestring;
  }
  const std::string last = !japanese.empty() ? japanese : !any.empty() ? any : fallback;
  if (last.empty()) return nullptr;
  auto out = json::obj();
  for (const auto& lang : langs) {
    const std::string own = json::getString(map, lang.c_str());
    json::set(out.get(), lang.c_str(), own.empty() ? last : own);
  }
  return out;
}

json::Doc builtinLabels(const TextFn& text, const std::string& key) {
  auto out = json::obj();
  for (const char* lang : kBuiltinLanguages)
    json::set(out.get(), lang, text ? text(key, lang) : key);
  return out;
}

struct Purpose {
  int64_t order;
  std::string id;
  const cJSON* entry;
};

std::vector<Purpose> enabledPurposes(const cJSON* config) {
  std::vector<Purpose> out;
  const cJSON* entry = nullptr;
  cJSON_ArrayForEach(entry, json::get(config, "visit_purposes")) {
    if (entry->string && cJSON_IsObject(entry) && json::getBool(entry, "enabled", true))
      out.push_back({json::getInt(entry, "order", 1000), entry->string, entry});
  }
  std::sort(out.begin(), out.end(), [](const Purpose& a, const Purpose& b) {
    return std::tie(a.order, a.id) < std::tie(b.order, b.id);
  });
  return out;
}

// The purpose whose visitors may leave something at the door: the seeded delivery purpose, or
// any purpose an administrator gave the parcel icon.
std::string deliveryPurpose(const std::vector<Purpose>& purposes) {
  for (const auto& purpose : purposes)
    if (purpose.id == "p_delivery") return purpose.id;
  for (const auto& purpose : purposes)
    if (json::getString(purpose.entry, "icon") == "\xF0\x9F\x93\xA6") return purpose.id;
  return "";
}

cJSON* addStep(cJSON* steps, const std::string& id, const char* kind) {
  cJSON* step = json::addObj(steps, id.c_str());
  json::set(step, "kind", kind);
  return step;
}

cJSON* addOption(cJSON* options, const std::string& id, const std::string& to) {
  cJSON* option = json::pushObj(options);
  json::set(option, "id", id);
  json::set(option, "to", to);
  return option;
}

void addDeliveryBranch(cJSON* steps, const TextFn& text, const std::string& call_step,
                       const std::string& purpose) {
  cJSON* parcel = addStep(steps, "s_parcel", "page");
  json::setItem(parcel, "title", builtinLabels(text, "core.flow.parcel_title"));
  json::setItem(parcel, "body", builtinLabels(text, "core.flow.parcel_body"));
  cJSON* parcel_options = json::addArr(parcel, "options");
  cJSON* leave = addOption(parcel_options, "o_leave", "s_where");
  json::set(leave, "icon", "\xF0\x9F\x93\xA6");
  json::setItem(leave, "label", builtinLabels(text, "core.flow.parcel_leave"));
  json::set(leave, "style", "primary");
  cJSON* hand = addOption(parcel_options, "o_hand", call_step);
  json::set(hand, "icon", "\xE2\x9C\x8D\xEF\xB8\x8F");
  json::setItem(hand, "label", builtinLabels(text, "core.flow.parcel_hand"));

  cJSON* where = addStep(steps, "s_where", "page");
  json::setItem(where, "title", builtinLabels(text, "core.flow.where_title"));
  json::setItem(where, "body", builtinLabels(text, "core.flow.where_body"));
  cJSON* done = addOption(json::addArr(where, "options"), "o_done", "n_left");
  json::setItem(done, "label", builtinLabels(text, "core.flow.where_done"));
  json::set(done, "style", "primary");

  cJSON* left = addStep(steps, "n_left", "notify");
  json::setItem(left, "message", builtinLabels(text, "core.flow.left_message"));
  if (!purpose.empty()) json::set(left, "purpose", purpose);
  json::set(left, "to", "e_thanks");

  cJSON* thanks = addStep(steps, "e_thanks", "end");
  json::setItem(thanks, "title", builtinLabels(text, "core.flow.thanks_title"));
  json::setItem(thanks, "body", builtinLabels(text, "core.flow.thanks_body"));
  json::set(thanks, "return_s", static_cast<int64_t>(kDefaultReturnS));
}

// The explicit flow, or the built-in one while no step has ever been written. Null with a
// reason when no flow applies to this installation.
json::Doc effectiveRaw(const cJSON* config, const TextFn& text, std::string* source,
                       std::string* reason) {
  const cJSON* flow = json::get(config, "visitor_flow");
  const cJSON* enabled = json::get(flow, "enabled");
  if (cJSON_IsFalse(enabled)) {
    *reason = "disabled";
    return nullptr;
  }
  const cJSON* steps = json::get(flow, "steps");
  if (cJSON_IsObject(steps) && steps->child) {
    *source = "config";
    return json::Doc(cJSON_Duplicate(flow, 1));
  }
  // ring_then_purpose is a deliberate administrator choice that predates the wizard; it stays in
  // force until the administrator turns the wizard on or writes a step.
  if (!cJSON_IsTrue(enabled) &&
      json::getString(json::get(config, "ui"), "call_flow", "purpose_first") ==
          "ring_then_purpose") {
    *reason = "legacy_call_flow";
    return nullptr;
  }
  *source = "default";
  auto raw = templateFlow(config, text, "default");
  for (const char* leaf : {"idle_s", "require_call"}) {
    const cJSON* value = json::get(flow, leaf);
    if (value) json::setItem(raw.get(), leaf, json::Doc(cJSON_Duplicate(value, 1)));
  }
  return raw;
}

std::string kindOf(const cJSON* steps, const std::string& id) {
  return json::getString(json::get(steps, id.c_str()), "kind");
}

// Every step reachable from entry by option targets, notify targets and unanswered branches.
bool reachesCall(const cJSON* steps, const std::string& entry) {
  std::set<std::string> seen;
  std::vector<std::string> queue = {entry};
  while (!queue.empty()) {
    const std::string id = queue.back();
    queue.pop_back();
    if (id.empty() || !seen.insert(id).second) continue;
    const cJSON* step = json::get(steps, id.c_str());
    const std::string kind = json::getString(step, "kind");
    if (kind == "call") return true;
    if (kind == "notify") queue.push_back(json::getString(step, "to"));
    const cJSON* option = nullptr;
    cJSON_ArrayForEach(option, json::get(step, "options")) {
      if (json::getBool(option, "enabled", true)) queue.push_back(json::getString(option, "to"));
    }
  }
  return false;
}

// Longest chain of pages starting at id, or -1 when the chain loops.
int pageDepth(const cJSON* steps, const std::string& id, std::map<std::string, int>* memo,
              std::set<std::string>* visiting) {
  if (kindOf(steps, id) != "page") return 0;
  auto known = memo->find(id);
  if (known != memo->end()) return known->second;
  if (!visiting->insert(id).second) return -1;
  int deepest = 0;
  const cJSON* option = nullptr;
  cJSON_ArrayForEach(option, json::get(json::get(steps, id.c_str()), "options")) {
    const int below = pageDepth(steps, json::getString(option, "to"), memo, visiting);
    if (below < 0) return -1;
    deepest = std::max(deepest, below);
  }
  visiting->erase(id);
  (*memo)[id] = deepest + 1;
  return deepest + 1;
}

std::vector<std::pair<std::string, std::string>> doorStarts(const cJSON* config) {
  std::vector<std::pair<std::string, std::string>> out;
  const cJSON* door = nullptr;
  cJSON_ArrayForEach(door, json::get(config, "doors")) {
    const std::string start = json::getString(json::get(door, "visitor_flow"), "start");
    if (door->string && !start.empty()) out.emplace_back(door->string, start);
  }
  return out;
}

json::Doc resolvedImages(const cJSON* config, const cJSON* images,
                         const std::vector<std::string>& langs, const ResolveEnv& env,
                         const std::string& step, cJSON* issues) {
  auto out = json::arr();
  const cJSON* image = nullptr;
  cJSON_ArrayForEach(image, images) {
    if (cJSON_GetArraySize(out.get()) >= kMaxImages) break;
    const std::string asset = json::getString(image, "asset");
    if (!sha256Valid(asset) || !imageAssetKnown(config, asset)) {
      cJSON* issue = json::pushObj(issues);
      json::set(issue, "step", step);
      json::set(issue, "code", "missing_asset");
      continue;
    }
    cJSON* resolved = json::pushObj(out.get());
    json::set(resolved, "asset", asset);
    json::set(resolved, "url", "/asset/" + asset);
    const std::string path = env.asset_path ? env.asset_path(asset) : std::string();
    if (path.empty()) json::setItem(resolved, "path", json::Doc(cJSON_CreateNull()));
    else json::set(resolved, "path", path);
    if (auto alt = completeText(json::get(image, "alt"), langs, ""))
      json::setItem(resolved, "alt", std::move(alt));
    json::set(resolved, "place",
              json::getString(image, "place") == "below" ? "below" : "above");
  }
  return out;
}

void addIssue(cJSON* issues, const std::string& step, const char* code) {
  cJSON* issue = json::pushObj(issues);
  json::set(issue, "step", step);
  json::set(issue, "code", code);
}

void ensureDirectCall(cJSON* steps) {
  if (!json::get(steps, kDirectCallStep)) addStep(steps, kDirectCallStep, "call");
}

cJSON* appendDirectCallOption(cJSON* page, const TextFn& text,
                              const std::vector<std::string>& langs, bool primary) {
  cJSON* options = json::get(page, "options");
  if (!options) options = json::addArr(page, "options");
  cJSON* option = json::pushObj(options);
  json::set(option, "id", kDirectCallOption);
  json::set(option, "semantic_id", primary ? "call.primary" : "purpose.button");
  auto labels = builtinLabels(text, "core.flow.call");
  json::setItem(option, "label", completeText(labels.get(), langs, "Call"));
  json::set(option, "icon", "");
  json::set(option, "style", primary ? "primary" : "normal");
  json::set(option, "to", kDirectCallStep);
  return option;
}

bool pageHasPrimary(const cJSON* page) {
  const cJSON* option = nullptr;
  cJSON_ArrayForEach(option, json::get(page, "options")) {
    if (json::getString(option, "style") == "primary") return true;
  }
  return false;
}

// Retargets the option that closes a page loop to a direct call, so a merge of two concurrent
// edits can never trap a visitor between pages.
void breakCycles(cJSON* steps, const std::string& id, std::set<std::string>* done,
                 std::vector<std::string>* path, cJSON* issues) {
  if (done->count(id) || kindOf(steps, id) != "page") return;
  path->push_back(id);
  cJSON* option = nullptr;
  cJSON_ArrayForEach(option, json::get(json::get(steps, id.c_str()), "options")) {
    const std::string to = json::getString(option, "to");
    if (std::find(path->begin(), path->end(), to) != path->end()) {
      json::set(option, "to", kDirectCallStep);
      ensureDirectCall(steps);
      addIssue(issues, id, "cycle");
      continue;
    }
    breakCycles(steps, to, done, path, issues);
  }
  path->pop_back();
  done->insert(id);
}

}  // namespace

json::Doc disabledDocument(const std::string& door, const std::string& reason) {
  auto out = json::obj();
  json::set(out.get(), "schema_version", static_cast<int64_t>(1));
  json::setBool(out.get(), "enabled", false);
  json::set(out.get(), "door", door);
  json::set(out.get(), "reason", reason);
  return out;
}

bool touchesFlow(const std::string& key, const cJSON* value) {
  if (key == "visitor_flow" || key.rfind("visitor_flow.", 0) == 0) return true;
  // Removing a door's entry point cannot break a flow, and an unrelated door edit must not be
  // refused because of one: only a write that sets an entry point counts.
  if (!value) return false;
  if (key == "doors") {
    const cJSON* door = nullptr;
    cJSON_ArrayForEach(door, value) {
      if (json::get(door, "visitor_flow")) return true;
    }
    return false;
  }
  if (key.rfind("doors.", 0) != 0) return false;
  if (key.find(".visitor_flow") != std::string::npos) return true;
  return key.find('.', 6) == std::string::npos && json::get(value, "visitor_flow") != nullptr;
}

bool writeKeyValid(const std::string& key, const cJSON* value, std::string* error) {
  if (key.rfind("doors.", 0) == 0) {
    const std::string rest = key.substr(6);
    const size_t dot = rest.find('.');
    if (dot == std::string::npos)
      return !cJSON_IsObject(value) || doorFlowValid(json::get(value, "visitor_flow"), error);
    const std::string member = rest.substr(dot + 1);
    if (member == "visitor_flow") return doorFlowValid(value, error);
    if (member == "visitor_flow.start") {
      if (cJSON_IsString(value) && idValid(value->valuestring)) return true;
      return fail(error, "bad_target", "start");
    }
    if (member.rfind("visitor_flow.", 0) == 0) return fail(error, "unknown_key", key);
    return true;
  }
  if (key != "visitor_flow" && key.rfind("visitor_flow.", 0) != 0) return true;
  if (key == "visitor_flow" || key == "visitor_flow.steps")
    return fail(error, "container_write", key);
  if (key == "visitor_flow.enabled" || key == "visitor_flow.require_call") {
    if (cJSON_IsBool(value)) return true;
    return fail(error, "bad_boolean", key);
  }
  if (key == "visitor_flow.start") {
    if (cJSON_IsString(value) && idValid(value->valuestring)) return true;
    return fail(error, "bad_target", "start");
  }
  if (key == "visitor_flow.idle_s") {
    if (wholeNumber(value, 15, 300)) return true;
    return fail(error, "bad_idle_s");
  }
  const std::string prefix = "visitor_flow.steps.";
  if (key.rfind(prefix, 0) != 0) return fail(error, "unknown_key", key);
  const std::string id = key.substr(prefix.size());
  // Nothing below a step is ever its own entry: a leaf there would mask one member of the step
  // object regardless of age and leave a half-merged step.
  if (id.find('.') != std::string::npos) return fail(error, "step_leaf_write", key);
  return stepShapeValid(id, value, error);
}

bool candidateValid(const cJSON* config, const TextFn& text, std::string* error,
                    std::vector<Warning>* warnings) {
  std::string source, reason;
  auto raw = effectiveRaw(config, text, &source, &reason);
  if (!raw) return true;
  const cJSON* steps = json::get(raw.get(), "steps");
  if (cJSON_GetArraySize(steps) > kMaxSteps) return fail(error, "too_many_steps");
  const cJSON* step = nullptr;
  cJSON_ArrayForEach(step, steps) {
    const std::string id = step->string ? step->string : "";
    // The built-in flow is correct by construction and follows the purposes as they are.
    if (source == "default") break;
    if (!stepShapeValid(id, step, error)) return false;
    const std::string kind = json::getString(step, "kind");
    const std::string purpose = json::getString(step, "purpose");
    if (!purpose.empty() && !purposeEntry(config, purpose))
      return fail(error, "unknown_purpose", id);
    const cJSON* image = nullptr;
    cJSON_ArrayForEach(image, json::get(step, "images")) {
      if (!imageAssetKnown(config, json::getString(image, "asset")))
        return fail(error, "unknown_asset", id);
    }
    const cJSON* option = nullptr;
    cJSON_ArrayForEach(option, json::get(step, "options")) {
      const std::string where = id + "." + json::getString(option, "id");
      if (!json::get(steps, json::getString(option, "to").c_str()))
        return fail(error, "unknown_target", where);
      const std::string option_purpose = json::getString(option, "purpose");
      if (!option_purpose.empty() && !purposeEntry(config, option_purpose))
        return fail(error, "unknown_purpose", where);
    }
    if (kind == "call") {
      const std::string unanswered = json::getString(step, "on_unanswered");
      if (!unanswered.empty() && !json::get(steps, unanswered.c_str()))
        return fail(error, "unknown_target", id);
      if (!unanswered.empty() && kindOf(steps, unanswered) != "page")
        return fail(error, "bad_target_kind", id);
    } else if (kind == "notify") {
      const std::string to = json::getString(step, "to");
      if (!json::get(steps, to.c_str())) return fail(error, "unknown_target", id);
      if (kindOf(steps, to) != "end") return fail(error, "bad_target_kind", id);
      const cJSON* snapshot = json::get(step, "snapshot");
      if (json::getString(snapshot, "source") == "media_source" &&
          !cameraHasSnapshot(config, json::getString(snapshot, "id")))
        return fail(error, "unknown_camera", id);
    }
  }

  std::vector<std::pair<std::string, std::string>> entries;
  const std::string start = json::getString(raw.get(), "start");
  if (start.empty()) return fail(error, "missing_start");
  entries.emplace_back("start", start);
  for (const auto& door : doorStarts(config)) entries.emplace_back(door.first, door.second);
  for (const auto& entry : entries) {
    if (!json::get(steps, entry.second.c_str())) return fail(error, "unknown_target", entry.first);
    if (kindOf(steps, entry.second) != "page") return fail(error, "bad_target_kind", entry.first);
  }

  std::map<std::string, int> depths;
  cJSON_ArrayForEach(step, steps) {
    std::set<std::string> visiting;
    const int depth = pageDepth(steps, step->string, &depths, &visiting);
    if (depth < 0) return fail(error, "cycle", step->string);
    if (depth > kMaxPageDepth) return fail(error, "too_deep", step->string);
  }

  const bool require_call = json::getBool(raw.get(), "require_call", true);
  for (const auto& entry : entries) {
    if (reachesCall(steps, entry.second)) continue;
    if (require_call) return fail(error, "no_reachable_call", entry.first);
    if (warnings) warnings->push_back({"visitor_flow.require_call", "visitor_flow.no_call"});
    break;
  }
  if (warnings) {
    cJSON_ArrayForEach(step, steps) {
      if (json::getString(step, "kind") != "page") continue;
      const bool has_content = json::get(step, "body") ||
                               cJSON_GetArraySize(json::get(step, "images")) > 0;
      if (has_content && cJSON_GetArraySize(json::get(step, "options")) > 4)
        warnings->push_back({std::string("visitor_flow.steps.") + step->string,
                             "visitor_flow.crowded_page"});
    }
  }
  return true;
}

json::Doc templateFlow(const cJSON* config, const TextFn& text, const std::string& name) {
  if (name != "default" && name != "purposes" && name != "delivery") return nullptr;
  auto raw = json::obj();
  json::setBool(raw.get(), "enabled", true);
  json::set(raw.get(), "start", "s_home");
  json::set(raw.get(), "idle_s", static_cast<int64_t>(kDefaultIdleS));
  json::setBool(raw.get(), "require_call", true);
  cJSON* steps = json::addObj(raw.get(), "steps");

  const auto purposes = enabledPurposes(config);
  const std::string delivery = name == "purposes" ? std::string() : deliveryPurpose(purposes);
  cJSON* home = addStep(steps, "s_home", "page");
  json::setItem(home, "title", builtinLabels(text, "core.flow.home_title"));
  cJSON* options = json::addArr(home, "options");
  cJSON* call = addOption(options, "o_call", "c_any");
  json::setItem(call, "label", builtinLabels(text, "core.flow.call"));
  json::set(call, "style", "primary");
  addStep(steps, "c_any", "call");

  std::string delivery_call;
  int index = 0;
  for (const auto& purpose : purposes) {
    // Room is kept for the Call option, and for a delivery option the template may add itself.
    if (cJSON_GetArraySize(options) >= kMaxOptions - (name == "delivery" && delivery.empty()))
      break;
    ++index;
    if (purpose.id.size() > 64 || purpose.id.find_first_of(" /\\") != std::string::npos) continue;
    // Purpose keys are free-form; a key that is not a legal step id gets a positional one.
    const std::string suffix = idValid(purpose.id) && purpose.id.size() <= 28
        ? purpose.id : "p" + std::to_string(index);
    const std::string call_step = "c_" + suffix;
    cJSON* target = addStep(steps, call_step, "call");
    json::set(target, "purpose", purpose.id);
    const bool is_delivery = purpose.id == delivery;
    if (is_delivery) {
      json::set(target, "on_unanswered", "s_parcel");
      delivery_call = call_step;
    }
    cJSON* option = addOption(options, "o_" + suffix, is_delivery ? "s_parcel" : call_step);
    json::set(option, "purpose", purpose.id);
  }
  if (name == "delivery" && delivery.empty()) {
    delivery_call = "c_delivery";
    cJSON* target = addStep(steps, delivery_call, "call");
    json::set(target, "on_unanswered", "s_parcel");
    cJSON* option = addOption(options, "o_delivery", "s_parcel");
    json::set(option, "icon", "\xF0\x9F\x93\xA6");
    json::setItem(option, "label", builtinLabels(text, "core.seed.purpose.p_delivery"));
  }
  if (!delivery_call.empty()) addDeliveryBranch(steps, text, delivery_call, delivery);
  return raw;
}

json::Doc resolve(const cJSON* config, const std::string& door, const ResolveEnv& env,
                  bool with_private) {
  std::string source, reason;
  auto raw = effectiveRaw(config, env.text, &source, &reason);
  if (!raw) return disabledDocument(door, reason);
  const auto langs = languages(config);
  const cJSON* raw_steps = json::get(raw.get(), "steps");

  auto out = json::obj();
  json::set(out.get(), "schema_version", static_cast<int64_t>(1));
  json::setBool(out.get(), "enabled", true);
  json::set(out.get(), "door", door);
  auto issues = json::arr();

  // First pass: which written steps survive, and as what kind. A kind this core does not know
  // (written by a newer one) and a step that cannot be shown both become a direct call.
  std::vector<std::string> ids;
  const cJSON* raw_step = nullptr;
  cJSON_ArrayForEach(raw_step, raw_steps) {
    if (raw_step->string && idValid(raw_step->string) && cJSON_IsObject(raw_step) &&
        static_cast<int>(ids.size()) < kMaxSteps)
      ids.push_back(raw_step->string);
  }
  std::sort(ids.begin(), ids.end());
  std::map<std::string, std::string> kinds;
  for (const auto& id : ids) {
    const cJSON* step = json::get(raw_steps, id.c_str());
    std::string kind = json::getString(step, "kind");
    if (kind != "page" && kind != "call" && kind != "notify" && kind != "end") {
      addIssue(issues.get(), id, "unknown_kind");
      kind = "call";
    } else if (kind == "notify" &&
               !completeText(json::get(step, "message"), langs, "")) {
      addIssue(issues.get(), id, "empty_message");
      kind = "call";
    }
    kinds[id] = kind;
  }

  auto steps = json::obj();
  bool needs_default_end = false;
  for (const auto& id : ids) {
    const cJSON* step = json::get(raw_steps, id.c_str());
    const std::string kind = kinds[id];
    const bool rewritten = kind != json::getString(step, "kind");
    cJSON* resolved = addStep(steps.get(), id, kind.c_str());
    if (kind == "page" || kind == "end") {
      if (auto title = completeText(json::get(step, "title"), langs, ""))
        json::setItem(resolved, "title", std::move(title));
      if (auto body = completeText(json::get(step, "body"), langs, ""))
        json::setItem(resolved, "body", std::move(body));
      json::setItem(resolved, "images",
                    resolvedImages(config, json::get(step, "images"), langs, env, id,
                                   issues.get()));
    }
    if (kind == "end") {
      const cJSON* return_s = json::get(step, "return_s");
      json::set(resolved, "return_s",
                wholeNumber(return_s, 3, 60) ? static_cast<int64_t>(return_s->valuedouble)
                                             : static_cast<int64_t>(kDefaultReturnS));
    } else if (kind == "call") {
      const std::string purpose = rewritten ? "" : json::getString(step, "purpose");
      if (purposeSelectable(config, purpose)) json::set(resolved, "purpose", purpose);
      else if (!purpose.empty()) addIssue(issues.get(), id, "purpose_unavailable");
      const std::string unanswered = rewritten ? "" : json::getString(step, "on_unanswered");
      if (!unanswered.empty()) {
        auto target = kinds.find(unanswered);
        if (target != kinds.end() && target->second == "page")
          json::set(resolved, "on_unanswered", unanswered);
        else
          addIssue(issues.get(), id, "dangling_target");
      }
    } else if (kind == "notify") {
      const std::string purpose = json::getString(step, "purpose");
      if (purposeSelectable(config, purpose)) json::set(resolved, "purpose", purpose);
      const std::string to = json::getString(step, "to");
      auto target = kinds.find(to);
      if (target != kinds.end() && target->second == "end") {
        json::set(resolved, "to", to);
      } else {
        json::set(resolved, "to", kDefaultEndStep);
        needs_default_end = true;
        addIssue(issues.get(), id, "dangling_target");
      }
      if (with_private) {
        json::setItem(resolved, "message", completeText(json::get(step, "message"), langs, ""));
        const cJSON* snapshot = json::get(step, "snapshot");
        const std::string snapshot_source = json::getString(snapshot, "source");
        const std::string camera = json::getString(snapshot, "id");
        if (snapshot_source == "door_station" ||
            (snapshot_source == "media_source" && cameraHasSnapshot(config, camera)))
          json::setItem(resolved, "snapshot", json::Doc(cJSON_Duplicate(snapshot, 1)));
      }
    } else {
      cJSON* options = json::addArr(resolved, "options");
      std::set<std::string> seen;
      bool primary_used = false;
      const cJSON* option = nullptr;
      cJSON_ArrayForEach(option, json::get(step, "options")) {
        const std::string option_id = json::getString(option, "id");
        if (!cJSON_IsObject(option) || !idValid(option_id) || seen.count(option_id)) {
          addIssue(issues.get(), id, "bad_option");
          continue;
        }
        if (!json::getBool(option, "enabled", true)) continue;
        if (cJSON_GetArraySize(options) >= kMaxOptions) {
          addIssue(issues.get(), id, "too_many_options");
          break;
        }
        const std::string purpose = json::getString(option, "purpose");
        if (!purpose.empty() && !purposeSelectable(config, purpose)) continue;
        std::string to = json::getString(option, "to");
        auto target = kinds.find(to);
        if (target == kinds.end()) {
          addIssue(issues.get(), id, "dangling_target");
          to = kDirectCallStep;
          ensureDirectCall(steps.get());
        } else if (target->second == "call") {
          // An option that would ring for a purpose the administrator switched off is hidden
          // with it, rather than ringing without saying why.
          const cJSON* call_step = json::get(raw_steps, to.c_str());
          const std::string call_purpose = json::getString(call_step, "purpose");
          if (json::getString(call_step, "kind") == "call" && !call_purpose.empty() &&
              !purposeSelectable(config, call_purpose))
            continue;
        }
        seen.insert(option_id);
        const cJSON* purpose_entry = purposeEntry(config, purpose);
        const bool primary = json::getString(option, "style") == "primary" && !primary_used;
        if (json::getString(option, "style") == "primary" && primary_used)
          addIssue(issues.get(), id, "multiple_primary");
        primary_used = primary_used || primary;
        cJSON* visible = json::pushObj(options);
        json::set(visible, "id", option_id);
        json::set(visible, "semantic_id", primary ? "call.primary" : "purpose.button");
        const cJSON* own_label = json::get(option, "label");
        const bool has_own_label = cJSON_IsObject(own_label) && own_label->child;
        json::setItem(visible, "label",
                      completeText(has_own_label ? own_label : json::get(purpose_entry, "label"),
                                   langs, option_id));
        const cJSON* own_icon = json::get(option, "icon");
        json::set(visible, "icon",
                  cJSON_IsString(own_icon) ? std::string(own_icon->valuestring)
                                           : json::getString(purpose_entry, "icon"));
        json::set(visible, "style", primary ? "primary" : "normal");
        json::set(visible, "to", to);
        if (!purpose.empty()) json::set(visible, "purpose", purpose);
      }
    }
  }
  if (needs_default_end) {
    cJSON* end = addStep(steps.get(), kDefaultEndStep, "end");
    auto title = builtinLabels(env.text, "core.flow.thanks_title");
    json::setItem(end, "title", completeText(title.get(), langs, ""));
    json::addArr(end, "images");
    json::set(end, "return_s", static_cast<int64_t>(kDefaultReturnS));
  }

  // A page left with nothing to press still has to let the visitor ring.
  for (const auto& id : ids) {
    cJSON* page = json::get(steps.get(), id.c_str());
    if (kinds[id] != "page" || cJSON_GetArraySize(json::get(page, "options")) > 0) continue;
    addIssue(issues.get(), id, "no_options");
    ensureDirectCall(steps.get());
    appendDirectCallOption(page, env.text, langs, true);
  }

  auto entry_page = [&](const std::string& id) {
    auto found = kinds.find(id);
    return found != kinds.end() && found->second == "page";
  };
  std::string start = json::getString(
      json::get(json::get(json::get(config, "doors"), door.c_str()), "visitor_flow"), "start");
  if (!start.empty() && !entry_page(start)) {
    addIssue(issues.get(), start, "dangling_door_start");
    start.clear();
  }
  if (start.empty()) start = json::getString(raw.get(), "start");
  if (!entry_page(start)) {
    // Nothing usable to start from: one page with the Call button, exactly what a door without
    // a wizard shows.
    addIssue(issues.get(), start, "missing_start");
    source = "fallback";
    steps = json::obj();
    start = "__home";
    cJSON* home = addStep(steps.get(), start, "page");
    json::addArr(home, "images");
    ensureDirectCall(steps.get());
    appendDirectCallOption(home, env.text, langs, true);
  } else {
    std::set<std::string> done;
    std::vector<std::string> path;
    breakCycles(steps.get(), start, &done, &path, issues.get());
    for (const auto& id : ids) breakCycles(steps.get(), id, &done, &path, issues.get());
  }

  const bool require_call = json::getBool(raw.get(), "require_call", true);
  if (require_call && !reachesCall(steps.get(), start)) {
    addIssue(issues.get(), start, "no_reachable_call");
    cJSON* page = json::get(steps.get(), start.c_str());
    ensureDirectCall(steps.get());
    appendDirectCallOption(page, env.text, langs, !pageHasPrimary(page));
  }

  json::set(out.get(), "source", source);
  json::set(out.get(), "start", start);
  const cJSON* idle = json::get(raw.get(), "idle_s");
  json::set(out.get(), "idle_s",
            wholeNumber(idle, 15, 300) ? static_cast<int64_t>(idle->valuedouble)
                                       : static_cast<int64_t>(kDefaultIdleS));
  json::setBool(out.get(), "require_call", require_call);
  json::setItem(out.get(), "steps", std::move(steps));
  json::setItem(out.get(), "issues", std::move(issues));
  return out;
}

}  // namespace visitor_flow
}  // namespace db
