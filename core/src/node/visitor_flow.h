// Visitor flow: the door-station call-out wizard.
//
// Configuration holds a pool of steps (visitor_flow.steps.<id>, each written whole) plus a few
// scalar leaves. Shells never read that raw document: they render the resolved document this
// module produces, which is validated, repaired so a visitor can never be stranded, stripped of
// options a visitor must not see, and annotated with purpose labels and local asset paths.
//
// Everything here is a pure function of a materialized configuration document, so the write
// validator, the resolver, and the conformance fixtures exercise the same code.
#pragma once

#include <functional>
#include <string>
#include <vector>

#include "util/json.h"

namespace db {
namespace visitor_flow {

constexpr int kMaxSteps = 32;
constexpr int kMaxOptions = 12;
constexpr int kMaxPageDepth = 6;
constexpr int kMaxImages = 2;
constexpr int kDefaultIdleS = 45;
constexpr int kDefaultReturnS = 8;

// Step ids the resolver synthesizes while repairing a flow. The "__" prefix is refused in
// written ids, so they cannot collide with an administrator's steps.
constexpr const char* kDirectCallStep = "__call";
constexpr const char* kDirectCallOption = "__call";
constexpr const char* kDefaultEndStep = "__end";

// Built-in text for the default wizard and for synthesized controls: (catalog key, language).
using TextFn = std::function<std::string(const std::string& key, const std::string& lang)>;

struct Warning {
  std::string key;
  std::string message_key;
};

// True when a write to key (carrying value, null for a delete) can change the effective flow of
// some door, so the caller must run candidateValid on the configuration that would result.
bool touchesFlow(const std::string& key, const cJSON* value);

// Shape of one written key: leaves have the right type and range, a step is one complete
// object of a known kind, and nothing below a step is written on its own. Errors are
// "visitor_flow.<code>" optionally followed by ": <step>[.<option>]".
bool writeKeyValid(const std::string& key, const cJSON* value, std::string* error);

// Graph rules for the configuration a write would produce: targets exist and have the right
// kind, no page cycle, bounded depth, referenced purposes/assets/cameras exist, and, while
// visitor_flow.require_call is true, every entry point can reach a call.
bool candidateValid(const cJSON* config, const TextFn& text, std::string* error,
                    std::vector<Warning>* warnings);

// A configuration-shaped flow ({enabled,start,idle_s,require_call,steps}) an editor can write as
// ordinary steps. name is "default" (what core serves while visitor_flow has no steps),
// "purposes" (start page only) or "delivery" (always includes the leave-at-door branch).
// Returns null for an unknown name.
json::Doc templateFlow(const cJSON* config, const TextFn& text, const std::string& name);

struct ResolveEnv {
  TextFn text;
  // Local file path of a cached asset, or empty while it is not cached on this node.
  std::function<std::string(const std::string& sha256)> asset_path;
};

// The document a shell renders for one door. with_private additionally keeps each notify step's
// resident-facing message and snapshot source, which never leave core.
json::Doc resolve(const cJSON* config, const std::string& door, const ResolveEnv& env,
                  bool with_private = false);

// What a door without a flow receives: {schema_version, enabled:false, door, reason}.
json::Doc disabledDocument(const std::string& door, const std::string& reason);

}  // namespace visitor_flow
}  // namespace db
