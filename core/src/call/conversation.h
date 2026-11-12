#pragma once
#include <map>
#include <string>
#include "util/json.h"

namespace db {

// Only the door authority mutates this state. Media callbacks carry the immutable leg generation.
struct Conversation {
  struct Participant {
    std::string state;
    std::string leg;
    bool established = false;
  };
  static constexpr size_t kMaxParticipants = 8;
  std::string door, call_id, authority, owner;
  int stage_revision = 0;
  int64_t version = 0;
  std::map<std::string, Participant> participants;

  std::string apply(const std::string& actor, const std::string& action,
                    int64_t expected_version, const std::string& new_leg);
  bool media(const std::string& actor, const std::string& leg, bool connected);
  std::string phase() const;
  json::Doc document() const;
  static bool parse(const cJSON* value, Conversation* out);
};
}  // namespace db
