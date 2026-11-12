#include "call/conversation.h"
#include <algorithm>

namespace db {
namespace {
bool identifier(const std::string& value) {
  return !value.empty() && value.size() <= 128 &&
      value.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-") == std::string::npos;
}
}

std::string Conversation::apply(const std::string& actor, const std::string& action,
                                int64_t expected_version, const std::string& new_leg) {
  if (!identifier(actor)) return "invalid_actor";
  if (expected_version != version) return "conflict";
  auto member = participants.find(actor);
  if (action == "answer" || action == "join" || action == "takeover" || action == "respond") {
    if (action != "takeover" && member != participants.end() && member->second.state != "waiting") return "already_participating";
    if (action == "answer" && !owner.empty() && owner != actor) return "busy";
    if (action == "join" && (owner.empty() || std::none_of(participants.begin(), participants.end(),
        [](const auto& p) { return p.second.established; }))) return "not_connected";
    if (action != "takeover" && member == participants.end() && participants.size() >= kMaxParticipants)
      return "capacity";
    if (action != "respond" && !identifier(new_leg)) return "invalid_leg";
    if (action == "takeover") participants.clear();
    participants[actor] = Participant{action == "respond" ? "waiting" : "dialing",
                                     action == "respond" ? "" : new_leg, false};
    if (action == "answer" || action == "takeover") owner = actor;
  } else if (action == "leave") {
    if (member == participants.end()) return "not_participating";
    participants.erase(member);
    if (owner == actor) {
      owner.clear();
      for (const auto& p : participants)
        if (p.second.state != "waiting") { owner = p.first; break; }
    }
  } else if (action == "hold") {
    if (member == participants.end() || !member->second.established || member->second.state != "connected")
      return "not_connected";
    member->second.state = "held";
  } else if (action == "resume") {
    if (member == participants.end() || (member->second.state != "held" && member->second.state != "connected")) return "not_held";
    if (member->second.state == "connected") member->second.established = false;
    if (!member->second.established && !identifier(new_leg)) return "invalid_leg";
    member->second.state = member->second.established ? "connected" : "dialing";
    if (!member->second.established) {
      member->second.leg = new_leg;
    }
  } else return "unsupported_action";
  ++version;
  return "";
}

bool Conversation::media(const std::string& actor, const std::string& leg, bool connected) {
  auto member = participants.find(actor);
  if (member == participants.end() || leg.empty() || member->second.leg != leg) return false;
  if (connected) {
    if (member->second.established || member->second.state != "dialing") return false;
    member->second.established = true;
    member->second.state = "connected";
  } else {
    if (!apply(actor, "leave", version, "").empty()) return false;
    return true;
  }
  ++version;
  return true;
}

std::string Conversation::phase() const {
  bool dialing = false, held = false;
  for (const auto& p : participants) {
    if (p.second.state == "connected") return "connected";
    dialing = dialing || p.second.state == "dialing";
    held = held || p.second.state == "held";
  }
  return dialing ? "dialing" : held ? "held" : "waiting";
}

json::Doc Conversation::document() const {
  auto out = json::obj();
  json::set(out.get(), "schema_version", int64_t{1});
  json::set(out.get(), "door", door);
  json::set(out.get(), "call_id", call_id);
  json::set(out.get(), "authority", authority);
  json::set(out.get(), "owner", owner);
  json::set(out.get(), "stage_revision", int64_t{stage_revision});
  json::set(out.get(), "version", version);
  json::set(out.get(), "phase", phase());
  auto* members = json::addArr(out.get(), "participants");
  for (const auto& p : participants) {
    auto* item = json::pushObj(members);
    json::set(item, "device", p.first);
    json::set(item, "state", p.second.state);
    json::set(item, "leg", p.second.leg);
    json::setBool(item, "established", p.second.established);
  }
  return out;
}

bool Conversation::parse(const cJSON* value, Conversation* out) {
  if (!out || !cJSON_IsObject(value) || json::getInt(value, "schema_version", 0) != 1) return false;
  Conversation next;
  next.door = json::getString(value, "door");
  next.call_id = json::getString(value, "call_id");
  next.authority = json::getString(value, "authority");
  next.owner = json::getString(value, "owner");
  const auto revision = json::getInt(value, "stage_revision", -1);
  next.version = json::getInt(value, "version", -1);
  if (!identifier(next.door) || !identifier(next.call_id) || !identifier(next.authority) ||
      revision < 0 || revision > 1000000 || next.version < 1) return false;
  next.stage_revision = static_cast<int>(revision);
  const cJSON* members = json::get(value, "participants");
  if (!cJSON_IsArray(members) || cJSON_GetArraySize(members) > static_cast<int>(kMaxParticipants)) return false;
  const cJSON* item = nullptr;
  cJSON_ArrayForEach(item, members) {
    const auto peer = json::getString(item, "device");
    Participant p{json::getString(item, "state"), json::getString(item, "leg"),
                  json::getBool(item, "established")};
    if (!identifier(peer) || (p.state != "waiting" && p.state != "dialing" &&
        p.state != "connected" && p.state != "held") ||
        (p.state != "waiting" && !identifier(p.leg)) ||
        (p.state == "connected" && !p.established) ||
        !next.participants.emplace(peer, p).second) return false;
  }
  if (!next.owner.empty() && !next.participants.count(next.owner)) return false;
  *out = std::move(next);
  return true;
}
}  // namespace db
