





#include "mesh/mesh.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <initializer_list>
#include <set>
#include <tuple>

#include "mesh/secure_channel.h"
#include "monocypher.h"
#include "store/store.h"
#include "util/common.h"
#include "util/ids.h"
#include "util/json.h"
#include "util/log.h"

namespace db {

namespace {

constexpr int64_t kJoinTokenTtlMs = 10 * 60 * 1000;
constexpr size_t kSyncEventLimit = 200;
constexpr int kEventTtl = 2;
constexpr int64_t kSnapTimeoutMs = 5000;
constexpr size_t kSnapMaxBytes = 300 * 1024;
constexpr int64_t kBlobTimeoutMs = 10000;
constexpr size_t kBlobMaxBytes = 3 * 1024 * 1024;
constexpr size_t kBlobChunkBytes = 256 * 1024;
constexpr size_t kRuntimeInputMaxBytes = 64 * 1024;
constexpr size_t kRuntimeProjectionMaxBytes = 16 * 1024;
constexpr size_t kUiStyleMaxElements = 64;
constexpr size_t kUiStyleTextMaxBytes = 512;
constexpr size_t kConfigKeyMaxBytes = 512;
constexpr size_t kNodeIdHexChars = 32;
constexpr size_t kHlcChars = 26;
constexpr size_t kEventTypeMaxBytes = 64;
constexpr size_t kEventEndpointMaxBytes = 256;
constexpr size_t kEventJsonMaxBytes = 64 * 1024;
constexpr double kInt64LimitExclusive = 9223372036854775808.0;


[[maybe_unused]] constexpr const char* kMsgVersionAnnounce = "VERSION_ANNOUNCE";
const char* const kDuties[] = {"telegram", "mqtt_bridge", "web_push"};

bool boundedString(const cJSON* value, size_t max_bytes) {
  return cJSON_IsString(value) && value->valuestring &&
         std::strlen(value->valuestring) <= max_bytes;
}

bool semanticIdValid(const char* value) {
  if (!value || value[0] == '\0' || std::strlen(value) > 96) return false;
  for (const unsigned char ch : std::string(value)) {
    if (!((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
          (ch >= '0' && ch <= '9') || ch == '.' || ch == '_' || ch == '-'))
      return false;
  }
  return true;
}

bool semanticIdValid(const cJSON* value) {
  return cJSON_IsString(value) && semanticIdValid(value->valuestring);
}

void copyStringIfBounded(cJSON* target, const cJSON* source, const char* key,
                         size_t max_bytes) {
  const cJSON* value = json::get(source, key);
  if (boundedString(value, max_bytes)) json::set(target, key, value->valuestring);
}

void copyBoolIfPresent(cJSON* target, const cJSON* source, const char* key) {
  const cJSON* value = json::get(source, key);
  if (cJSON_IsBool(value)) json::setBool(target, key, cJSON_IsTrue(value));
}

bool runtimeToken(const cJSON* value, size_t max_bytes = 128) {
  if (!boundedString(value, max_bytes)) return false;
  for (const unsigned char ch : std::string(value->valuestring)) {
    if (!((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
          (ch >= '0' && ch <= '9') || ch == '_' || ch == '-' || ch == '.' || ch == ':'))
      return false;
  }
  return true;
}

void copyTokenIfPresent(cJSON* target, const cJSON* source, const char* key,
                        size_t max_bytes = 128) {
  const cJSON* value = json::get(source, key);
  if (runtimeToken(value, max_bytes)) json::set(target, key, value->valuestring);
}

void copyNumberIfPresent(cJSON* target, const cJSON* source, const char* key,
                         double maximum = 9.0e15) {
  const cJSON* value = json::get(source, key);
  if (cJSON_IsNumber(value) && std::isfinite(value->valuedouble) && value->valuedouble >= 0 &&
      value->valuedouble <= maximum)
    json::set(target, key, json::getInt(source, key));
}

bool inKeys(const std::string& key, std::initializer_list<const char*> keys) {
  for (const char* allowed : keys)
    if (key == allowed) return true;
  return false;
}

json::Doc runtimeHealthObject(const cJSON* source, int depth = 0) {
  if (!cJSON_IsObject(source) || depth > 3) return {};
  auto out = json::obj();
  const cJSON* item = nullptr;
  size_t count = 0;
  cJSON_ArrayForEach(item, source) {
    if (++count > 64 || !item->string) break;
    const std::string key = item->string;
    if (cJSON_IsNumber(item) && inKeys(key, {"schema_version", "generation", "heartbeat_ms", "updated_at_ms",
                     "crash_count_5m", "crashes_in_window", "window_ms", "restart_attempt",
                     "next_backoff_ms", "native_kiosk_consecutive_failures",
                     "native_kiosk_failure_count", "native_kiosk_failure_threshold",
                     "memory_warnings", "ttl_s", "decoded_frames", "displayed_frames",
                     "dropped_frames", "latency_ms", "jitter_ms", "fps_x10"})) {
      copyNumberIfPresent(out.get(), source, item->string);
    } else if (cJSON_IsBool(item) && inKeys(key, {"safe_mode", "local_safe_mode", "helper_safe_mode",
                            "helper_available", "helper_installed", "helper_enabled",
                            "helper_running", "helper_reachable", "helper_supervising",
                            "mode_acknowledged", "config_valid", "valid", "enabled",
                            "native_kiosk_available", "native_kiosk_api_available",
                            "native_kiosk_healthy", "sip_available", "active", "restored",
                            "state_persisted", "requested", "applied", "rejected",
                            "unsupported", "visual_applied", "sound_applied",
                            "sticky_applied"})) {
      copyBoolIfPresent(out.get(), source, item->string);
    } else if (cJSON_IsObject(item) &&
               inKeys(key, {"configured", "effective", "measured", "helper_status", "media"})) {
      auto nested = runtimeHealthObject(item, depth + 1);
      if (nested) json::setItem(out.get(), item->string, std::move(nested));
    } else if (cJSON_IsString(item) && inKeys(key, {"last_exit_reason", "codec_health", "helper_mode",
                            "helper_effective", "effective_mode", "native_kiosk",
                            "active_call_recovery", "configured", "effective", "requested_mode",
                            "mode", "source", "state", "status", "reason", "last_event",
                            "platform", "role", "process_arch", "sip_backend", "h264_playback",
                            "mjpeg_playback", "audio_calling", "sip_audio", "media", "core",
                            "ringer", "sos", "controls", "custom_visuals",
                            "native_kiosk_health", "helper_version", "transport", "profile",
                            "codec", "resolution", "compositor", "permission", "result",
                            "limitation"})) {
      copyTokenIfPresent(out.get(), source, item->string);
    }
  }
  return out;
}

json::Doc componentsProjection(const cJSON* source) {
  if (!cJSON_IsObject(source)) return {};
  auto out = json::obj();
  const cJSON* item = nullptr;
  size_t count = 0;
  cJSON_ArrayForEach(item, source) {
    if (count >= 32) break;
    if (!semanticIdValid(item->string) || !runtimeToken(item, 64)) continue;
    json::set(out.get(), item->string, item->valuestring);
    count++;
  }
  return out;
}

json::Doc deviceAlertProjection(const cJSON* source) {
  if (!cJSON_IsObject(source)) return {};
  auto out = runtimeHealthObject(source);
  if (!out) return {};
  copyTokenIfPresent(out.get(), source, "event_hlc", 128);
  const cJSON* channels = json::get(source, "channels");
  if (cJSON_IsArray(channels)) {
    auto clean = json::arr();
    const cJSON* item = nullptr;
    size_t count = 0;
    cJSON_ArrayForEach(item, channels) {
      if (count >= 8) break;
      if (!runtimeToken(item, 32)) continue;
      json::push(clean.get(), json::Doc(cJSON_CreateString(item->valuestring)));
      count++;
    }
    json::setItem(out.get(), "channels", std::move(clean));
  }
  const cJSON* results = json::get(source, "channel_results");
  if (cJSON_IsArray(results)) {
    auto clean = json::arr();
    const cJSON* item = nullptr;
    size_t count = 0;
    cJSON_ArrayForEach(item, results) {
      if (count >= 8) break;
      auto result = runtimeHealthObject(item);
      if (!result) continue;
      copyTokenIfPresent(result.get(), item, "channel", 32);
      json::push(clean.get(), std::move(result));
      count++;
    }
    json::setItem(out.get(), "channel_results", std::move(clean));
  }
  return out;
}

json::Doc semanticIdArray(const cJSON* source) {
  auto out = json::arr();
  if (!cJSON_IsArray(source)) return out;
  const cJSON* item = nullptr;
  size_t count = 0;
  cJSON_ArrayForEach(item, source) {
    if (count >= kUiStyleMaxElements) break;
    if (!semanticIdValid(item)) continue;
    json::push(out.get(), json::Doc(cJSON_CreateString(item->valuestring)));
    count++;
  }
  return out;
}

json::Doc uiStyleOutcome(const cJSON* source) {
  if (!cJSON_IsObject(source)) return {};
  auto out = json::obj();
  copyStringIfBounded(out.get(), source, "source", 64);
  copyStringIfBounded(out.get(), source, "result", 64);
  copyStringIfBounded(out.get(), source, "error", kUiStyleTextMaxBytes);
  copyStringIfBounded(out.get(), source, "validation_error", kUiStyleTextMaxBytes);
  copyStringIfBounded(out.get(), source, "persistence_error", kUiStyleTextMaxBytes);
  copyBoolIfPresent(out.get(), source, "applied");
  copyBoolIfPresent(out.get(), source, "rejected");
  copyBoolIfPresent(out.get(), source, "lkg_persisted");
  copyBoolIfPresent(out.get(), source, "validation_valid");
  copyBoolIfPresent(out.get(), source, "last_known_good_persisted");
  return out;
}

json::Doc uiStyleProjection(const cJSON* source) {
  if (!cJSON_IsObject(source)) return {};
  const cJSON* schema = json::get(source, "schema_version");
  if (!cJSON_IsNumber(schema) || schema->valuedouble != 1.0) return {};
  auto out = json::obj();
  json::set(out.get(), "schema_version", int64_t{1});
  copyStringIfBounded(out.get(), source, "node_id", 128);
  copyStringIfBounded(out.get(), source, "last_error", kUiStyleTextMaxBytes);
  const cJSON* updated = json::get(source, "updated_at_ms");
  if (cJSON_IsNumber(updated) && updated->valuedouble >= 0 &&
      updated->valuedouble <= 9'000'000'000'000'000.0)
    json::set(out.get(), "updated_at_ms", json::getInt(source, "updated_at_ms"));
  const cJSON* minimum_touch = json::get(source, "minimum_touch_dp");
  if (cJSON_IsNumber(minimum_touch) && minimum_touch->valuedouble >= 0 &&
      minimum_touch->valuedouble <= 4096)
    json::set(out.get(), "minimum_touch_dp", json::getInt(source, "minimum_touch_dp"));

  for (const char* key : {"applied"}) {
    const cJSON* value = json::get(source, key);
    if (cJSON_IsArray(value)) json::setItem(out.get(), key, semanticIdArray(value));
  }

  const cJSON* rejected = json::get(source, "rejected");
  if (cJSON_IsArray(rejected)) {
    auto clean = json::arr();
    const cJSON* item = nullptr;
    size_t count = 0;
    cJSON_ArrayForEach(item, rejected) {
      if (count >= kUiStyleMaxElements) break;
      const cJSON* semantic_id = json::get(item, "semantic_id");
      if (!cJSON_IsObject(item) || !semanticIdValid(semantic_id)) continue;
      cJSON* entry = json::pushObj(clean.get());
      json::set(entry, "semantic_id", semantic_id->valuestring);
      copyStringIfBounded(entry, item, "reason", kUiStyleTextMaxBytes);
      count++;
    }
    json::setItem(out.get(), "rejected", std::move(clean));
  }

  const cJSON* last_known_good = json::get(source, "last_known_good");
  if (cJSON_IsObject(last_known_good)) {
    cJSON* clean = json::addObj(out.get(), "last_known_good");
    for (const char* key : {"used", "persisted"}) {
      const cJSON* value = json::get(last_known_good, key);
      if (cJSON_IsArray(value)) json::setItem(clean, key, semanticIdArray(value));
    }
  }

  const cJSON* elements = json::get(source, "elements");
  if (cJSON_IsObject(elements)) {
    cJSON* clean = json::addObj(out.get(), "elements");
    const cJSON* item = nullptr;
    size_t count = 0;
    cJSON_ArrayForEach(item, elements) {
      if (count >= kUiStyleMaxElements) break;
      if (!semanticIdValid(item->string)) continue;
      auto outcome = uiStyleOutcome(item);
      if (!outcome) continue;
      cJSON_AddItemToObject(clean, item->string, outcome.release());
      count++;
    }
  }
  return out;
}



json::Doc entryToJson(const LwwEntry& e) {
  auto o = json::obj();
  json::set(o.get(), "k", e.key);
  json::set(o.get(), "v", e.value_json);
  json::setBool(o.get(), "d", e.deleted);
  json::set(o.get(), "h", e.hlc);
  json::set(o.get(), "a", e.author);
  json::set(o.get(), "s", static_cast<int64_t>(e.seq));
  return o;
}

bool isAsciiHex(char value) {
  return (value >= '0' && value <= '9') || (value >= 'a' && value <= 'f') ||
         (value >= 'A' && value <= 'F');
}

bool sameAsciiHex(char lhs, char rhs) {
  if (lhs >= 'A' && lhs <= 'F') lhs = static_cast<char>(lhs - 'A' + 'a');
  if (rhs >= 'A' && rhs <= 'F') rhs = static_cast<char>(rhs - 'A' + 'a');
  return lhs == rhs;
}

bool nodeIdValid(const char* value) {
  if (!value || std::strlen(value) != kNodeIdHexChars) return false;
  for (size_t i = 0; i < kNodeIdHexChars; ++i)
    if (!isAsciiHex(value[i])) return false;
  return true;
}

bool configKeyValid(const char* value) {
  if (!value) return false;
  const size_t size = std::strlen(value);
  if (size == 0 || size > kConfigKeyMaxBytes || value[0] == '.' || value[size - 1] == '.')
    return false;
  for (size_t i = 0; i < size; ++i) {
    const unsigned char ch = static_cast<unsigned char>(value[i]);
    if (ch < 0x20 || ch == 0x7f || (ch == '.' && i + 1 < size && value[i + 1] == '.'))
      return false;
  }
  return true;
}

bool hlcValidForAuthor(const char* value, const char* author) {
  if (!value || !nodeIdValid(author) || std::strlen(value) != kHlcChars || value[12] != '-' ||
      value[17] != '-')
    return false;
  for (size_t i = 0; i < 12; ++i)
    if (!isAsciiHex(value[i])) return false;
  for (size_t i = 13; i < 17; ++i)
    if (!isAsciiHex(value[i])) return false;
  for (size_t i = 18; i < kHlcChars; ++i) {
    if (!isAsciiHex(value[i]) || !sameAsciiHex(value[i], author[i - 18])) return false;
  }
  return true;
}

bool wireSequence(const cJSON* value, bool allow_zero, uint64_t* out) {
  // cJSON stores numbers as doubles. Values rounded to 2^63 are ambiguous, so the signed limit
  // is exclusive and such boundary encodings fail closed instead of overflowing a cast.
  if (!out || !cJSON_IsNumber(value) || !std::isfinite(value->valuedouble) ||
      value->valuedouble < 0 || value->valuedouble >= kInt64LimitExclusive ||
      std::trunc(value->valuedouble) != value->valuedouble)
    return false;
  const uint64_t decoded = static_cast<uint64_t>(value->valuedouble);
  if (!allow_zero && decoded == 0) return false;
  *out = decoded;
  return true;
}

bool wireSignedInteger(const cJSON* value, int64_t* out) {
  // Both boundaries are rejected because adjacent out-of-range JSON integers round to the same
  // cJSON double. Normal wire values are far inside this interval.
  if (!out || !cJSON_IsNumber(value) || !std::isfinite(value->valuedouble) ||
      value->valuedouble <= -kInt64LimitExclusive ||
      value->valuedouble >= kInt64LimitExclusive ||
      std::trunc(value->valuedouble) != value->valuedouble)
    return false;
  *out = static_cast<int64_t>(value->valuedouble);
  return true;
}

bool entryFromJson(const cJSON* o, LwwEntry* out) {
  if (!out || !cJSON_IsObject(o)) return false;
  const cJSON* key = json::get(o, "k");
  const cJSON* value = json::get(o, "v");
  const cJSON* deleted = json::get(o, "d");
  const cJSON* hlc = json::get(o, "h");
  const cJSON* author = json::get(o, "a");
  uint64_t seq = 0;
  if (!cJSON_IsString(key) || !configKeyValid(key->valuestring) || !cJSON_IsString(value) ||
      !value->valuestring || !cJSON_IsBool(deleted) || !cJSON_IsString(hlc) ||
      !cJSON_IsString(author) ||
      !hlcValidForAuthor(hlc->valuestring, author->valuestring) ||
      !wireSequence(json::get(o, "s"), false, &seq))
    return false;

  LwwEntry entry;
  entry.key = key->valuestring;
  entry.value_json = value->valuestring;
  entry.deleted = cJSON_IsTrue(deleted);
  entry.hlc = hlc->valuestring;
  entry.author = author->valuestring;
  entry.seq = seq;
  *out = std::move(entry);
  return true;
}

json::Doc eventToJson(const EventRecord& e) {
  auto o = json::obj();
  json::set(o.get(), "origin", e.origin);
  json::set(o.get(), "seq", static_cast<int64_t>(e.seq));
  json::set(o.get(), "type", e.type);
  json::set(o.get(), "door", e.door);
  json::set(o.get(), "device", e.device);
  json::set(o.get(), "hlc", e.hlc);
  json::set(o.get(), "wall", e.wall_ms);
  json::set(o.get(), "payload", e.payload_json.empty() ? "{}" : e.payload_json);
  json::set(o.get(), "notify", e.notify_json.empty() ? "{}" : e.notify_json);
  return o;
}

bool eventEndpointValid(const cJSON* value) {
  if (!boundedString(value, kEventEndpointMaxBytes)) return false;
  for (const unsigned char ch : std::string(value->valuestring)) {
    if (ch < 0x20 || ch == 0x7f) return false;
  }
  return true;
}

bool eventJsonObject(const cJSON* value, std::string* normalized) {
  if (!normalized || !boundedString(value, kEventJsonMaxBytes)) return false;
  if (value->valuestring[0] == '\0') {
    *normalized = "{}";
    return true;
  }
  json::Doc parsed(cJSON_ParseWithOpts(value->valuestring, nullptr, /*require_null_terminated=*/1));
  if (!parsed || !cJSON_IsObject(parsed.get())) return false;
  *normalized = value->valuestring;
  return true;
}

bool eventFromJson(const cJSON* o, EventRecord* out) {
  if (!out || !cJSON_IsObject(o)) return false;
  const cJSON* origin = json::get(o, "origin");
  const cJSON* type = json::get(o, "type");
  const cJSON* door = json::get(o, "door");
  const cJSON* device = json::get(o, "device");
  const cJSON* event_hlc = json::get(o, "hlc");
  const cJSON* payload = json::get(o, "payload");
  const cJSON* notify = json::get(o, "notify");
  uint64_t seq = 0;
  int64_t wall_ms = 0;
  std::string payload_json;
  std::string notify_json;
  if (!cJSON_IsString(origin) || !nodeIdValid(origin->valuestring) ||
      !wireSequence(json::get(o, "seq"), false, &seq) || !runtimeToken(type, kEventTypeMaxBytes) ||
      type->valuestring[0] == '\0' || !eventEndpointValid(door) || !eventEndpointValid(device) ||
      !cJSON_IsString(event_hlc) ||
      !hlcValidForAuthor(event_hlc->valuestring, origin->valuestring) ||
      !wireSignedInteger(json::get(o, "wall"), &wall_ms) ||
      !eventJsonObject(payload, &payload_json) || !eventJsonObject(notify, &notify_json))
    return false;

  EventRecord event;
  event.origin = origin->valuestring;
  event.seq = seq;
  event.type = type->valuestring;
  event.door = door->valuestring;
  event.device = device->valuestring;
  event.hlc = event_hlc->valuestring;
  event.wall_ms = wall_ms;
  event.payload_json = std::move(payload_json);
  event.notify_json = std::move(notify_json);
  *out = std::move(event);
  return true;
}

bool eventsFromJson(const cJSON* array, std::vector<EventRecord>* out) {
  if (!out || !cJSON_IsArray(array) ||
      static_cast<size_t>(cJSON_GetArraySize(array)) > kSyncEventLimit)
    return false;
  std::vector<EventRecord> decoded;
  std::set<std::pair<std::string, uint64_t>> identities;
  const cJSON* item = nullptr;
  cJSON_ArrayForEach(item, array) {
    EventRecord event;
    if (!eventFromJson(item, &event) ||
        !identities.emplace(event.origin, event.seq).second)
      return false;
    decoded.push_back(std::move(event));
  }
  *out = std::move(decoded);
  return true;
}

struct WireHeartbeat {
  std::string id;
  uint64_t epoch = 0;
  uint64_t sequence = 0;
  std::string hlc;
  std::string door;
  bool has_door = false;
};

bool heartbeatFromJson(const cJSON* object, bool allow_empty_hlc, WireHeartbeat* out) {
  if (!out || !cJSON_IsObject(object)) return false;
  const cJSON* id = json::get(object, "id");
  const cJSON* heartbeat_hlc = json::get(object, "hlc");
  const cJSON* door = json::get(object, "door");
  WireHeartbeat decoded;
  if (!cJSON_IsString(id) || !nodeIdValid(id->valuestring) ||
      !wireSequence(json::get(object, "epoch"), true, &decoded.epoch) ||
      !wireSequence(json::get(object, "hb"), true, &decoded.sequence) ||
      !cJSON_IsString(heartbeat_hlc) || !heartbeat_hlc->valuestring ||
      (heartbeat_hlc->valuestring[0] == '\0'
           ? !allow_empty_hlc
           : !hlcValidForAuthor(heartbeat_hlc->valuestring, id->valuestring)) ||
      (door && !eventEndpointValid(door)))
    return false;
  decoded.id = id->valuestring;
  decoded.hlc = heartbeat_hlc->valuestring;
  if (door) {
    decoded.door = door->valuestring;
    decoded.has_door = true;
  }
  *out = std::move(decoded);
  return true;
}

bool dutyValid(const std::string& duty) {
  for (const char* known : kDuties)
    if (duty == known) return true;
  return false;
}

void mapToJson(cJSON* obj, const std::map<std::string, uint64_t>& m) {
  for (const auto& kv : m) json::set(obj, kv.first.c_str(), static_cast<int64_t>(kv.second));
}

bool mapFromJson(const cJSON* obj, std::map<std::string, uint64_t>* out) {
  if (!out || !cJSON_IsObject(obj)) return false;
  std::map<std::string, uint64_t> decoded;
  const cJSON* it = nullptr;
  cJSON_ArrayForEach(it, obj) {
    uint64_t seq = 0;
    if (!nodeIdValid(it->string) || !wireSequence(it, true, &seq) ||
        !decoded.emplace(it->string, seq).second)
      return false;
  }
  *out = std::move(decoded);
  return true;
}

struct ConfigWirePayload {
  std::vector<LwwEntry> entries;
  VersionVector complete_frontier;
  bool has_complete_frontier = false;
};

bool configPayloadFromJson(const cJSON* payload, ConfigWirePayload* out) {
  if (!out || !cJSON_IsObject(payload)) return false;
  const cJSON* cfg = json::get(payload, "cfg");
  if (!cJSON_IsArray(cfg)) return false;

  ConfigWirePayload decoded;
  const cJSON* item = nullptr;
  cJSON_ArrayForEach(item, cfg) {
    LwwEntry entry;
    if (!entryFromJson(item, &entry)) return false;
    decoded.entries.push_back(std::move(entry));
  }

  const cJSON* complete_frontier = json::get(payload, "cfg_complete_vv");
  if (complete_frontier) {
    if (!mapFromJson(complete_frontier, &decoded.complete_frontier)) return false;
    decoded.has_complete_frontier = true;
  }
  *out = std::move(decoded);
  return true;
}



// K = BLAKE2b-256(pin || salt)
std::array<uint8_t, 32> joinKey(const std::string& pin, const Bytes& salt) {
  crypto_blake2b_ctx ctx;
  crypto_blake2b_init(&ctx, 32);
  crypto_blake2b_update(&ctx, reinterpret_cast<const uint8_t*>(pin.data()), pin.size());
  crypto_blake2b_update(&ctx, salt.data(), salt.size());
  std::array<uint8_t, 32> k{};
  crypto_blake2b_final(&ctx, k.data());
  return k;
}

// HMAC(K, challenge || joiner_id)
std::array<uint8_t, 32> joinProof(const std::array<uint8_t, 32>& k, const Bytes& challenge,
                                  const std::string& joiner_id) {
  crypto_blake2b_ctx ctx;
  crypto_blake2b_keyed_init(&ctx, 32, k.data(), k.size());
  crypto_blake2b_update(&ctx, challenge.data(), challenge.size());
  crypto_blake2b_update(&ctx, reinterpret_cast<const uint8_t*>(joiner_id.data()),
                        joiner_id.size());
  std::array<uint8_t, 32> mac{};
  crypto_blake2b_final(&ctx, mac.data());
  return mac;
}

// Core-owned power section: exactly three scalars, clamped, so peers[].power can never become a
// channel for arbitrary platform data.
json::Doc powerProjection(const cJSON* section) {
  if (!cJSON_IsObject(section)) return {};
  const cJSON* battery = json::get(section, "battery_pct");
  if (!cJSON_IsNumber(battery)) return {};
  int64_t pct = static_cast<int64_t>(battery->valuedouble);
  if (pct < -1) pct = -1;
  if (pct > 100) pct = 100;
  auto out = json::obj();
  json::set(out.get(), "battery_pct", pct);
  json::setBool(out.get(), "charging", json::getBool(section, "charging", false));
  json::setBool(out.get(), "mains", json::getBool(section, "mains", false));
  return out;
}

void sendJoinFrame(const ConnPtr& conn, const cJSON* msg) {
  std::string s = json::dump(msg);
  Bytes f;
  f.reserve(1 + s.size());
  f.push_back(kFrameJoin);
  f.insert(f.end(), s.begin(), s.end());
  conn->send(f);
}

}  // namespace

bool projectMeshRuntimeJson(const std::string& runtime_json, std::string* projected_json) {
  if (!projected_json || runtime_json.size() > kRuntimeInputMaxBytes) return false;
  auto source = json::parse(runtime_json);
  if (!source || !cJSON_IsObject(source.get())) return false;
  auto projected = runtimeHealthObject(source.get());
  if (!projected) projected = json::obj();
  const cJSON* components = json::get(source.get(), "components");
  if (components) {
    auto clean = componentsProjection(components);
    if (clean) json::setItem(projected.get(), "components", std::move(clean));
  }
  for (const char* key : {"process_recovery", "recovery_helper", "kiosk", "recovery",
                          "windows", "ios_compat", "safe_mode", "runtime", "camera",
                          "avc_encode", "avc_decode", "avc_commissioning", "media_source",
                          "media_playback", "sip"}) {
    const cJSON* section = json::get(source.get(), key);
    if (!cJSON_IsObject(section)) continue;
    auto clean = runtimeHealthObject(section);
    if (clean) json::setItem(projected.get(), key, std::move(clean));
  }
  for (const char* key : {"device_alert", "emergency_presentation"}) {
    const cJSON* section = json::get(source.get(), key);
    if (!cJSON_IsObject(section)) continue;
    auto clean = deviceAlertProjection(section);
    if (clean) json::setItem(projected.get(), key, std::move(clean));
  }
  auto power = powerProjection(json::get(source.get(), "power"));
  if (power) json::setItem(projected.get(), "power", std::move(power));
  const cJSON* ui_style = json::get(source.get(), "ui_style");
  if (ui_style) {
    auto clean = uiStyleProjection(ui_style);
    if (!clean) return false;
    json::setItem(projected.get(), "ui_style", std::move(clean));
  }
  const std::string encoded = json::dump(projected.get());
  if (encoded.size() > kRuntimeProjectionMaxBytes) return false;
  *projected_json = encoded;
  return true;
}

// ============================================================================

struct Mesh::Impl {
  Runloop& loop;
  IClock& clock;
  HlcClock& hlc;
  ITransport& tp;
  IDiscovery* disc;
  Store& store;
  LwwMap& config;
  EventLog& events;
  MeshSettings& st;
  Callbacks cbs;
  bool running = false;


  struct Peer {
    PeerInfo info;
    int64_t last_adv_mono = 0;
  };
  std::map<std::string, Peer> peers;


  std::map<std::string, std::shared_ptr<SecureChannel>> chans;
  std::vector<std::shared_ptr<SecureChannel>> pending;
  std::set<std::string> dialing;
  std::set<std::string> known_addrs;
  std::map<std::string, std::string> addr_owner;


  struct DutyState {
    std::string leader;
    int64_t last_claim_mono = -(int64_t{1} << 60);
    uint64_t term = 0;
  };
  std::map<std::string, DutyState> duties;


  struct Token {
    std::string pin;
    int64_t expires_mono = 0;
    int fails = 0;
    bool active = false;
    // A joiner that arrives just after the deadline is told the code expired rather than that no
    // code exists, but only once: a later attempt is simply a request without a code.
    bool expired_unreported = false;
  } token;


  struct Inbound {
    ConnPtr conn;
    Bytes challenge, salt;
    bool challenged = false;
  };
  std::vector<std::shared_ptr<Inbound>> inbound;


  struct JoinRun {
    ConnPtr conn;
    std::string pin;
    std::array<uint8_t, 32> k{};
    bool key_ready = false;
    std::function<void(bool, const std::string&)> done;
    uint64_t timeout_id = 0;
    bool finished = false;
  };
  std::shared_ptr<JoinRun> join;


  std::array<uint8_t, 32> pair_sk_{};
  std::array<uint8_t, 32> pair_pk_{};
  bool pair_keys_ready_ = false;
  struct Pending {
    std::string id, addr, name, role, pk;
    std::string model, platform, sw;
    int64_t last_seen = 0;
    // none | sent | acked | joined | failed
    std::string invite_state = "none";
    int attempts = 0;
    std::string last_error;
  };
  std::map<std::string, Pending> pending_;
  std::map<std::string, int64_t> denied_;  // node id → mono deadline for ignoring announcements
  int64_t pairing_mode_until_ = 0;
  int auto_added_count_ = 0;
  bool is_founder_ = false;
  static constexpr int64_t kPendingTtlMs = 30000;
  static constexpr int64_t kDenyTtlMs = 10 * 60 * 1000;
  static constexpr int64_t kInviteAckMs = 2000;
  static constexpr int kInviteAttempts = 3;


  // One outstanding invitation. A manual invitation retries until the invitee acknowledges the
  // join frame; an automatic one is sent once so pairing mode cannot flood a device.
  struct InviteRun {
    std::string key;  // pending id, or "addr:<addr>" for a direct (QR) invitation
    std::string id;   // pending id; empty until a direct invitation is acknowledged
    std::string addr, pk;
    int attempts = 0;
    bool manual = false;
    bool finished = false;
    uint64_t timer = 0;
  };
  std::map<std::string, std::shared_ptr<InviteRun>> invites_;


  std::function<Bytes()> snap_provider;
  struct SnapWait {
    std::function<void(Bytes)> cb;
    uint64_t timeout_id = 0;
  };
  std::map<uint64_t, SnapWait> snap_waits;
  uint64_t snap_rid = 0;


  std::function<Bytes(const std::string&)> blob_provider;
  struct BlobWait {
    std::string hash;
    std::vector<std::string> remaining;
    std::map<uint64_t, Bytes> chunks;
    uint64_t total_chunks = 0;
    size_t total_bytes = 0;
    std::function<void(Bytes)> cb;
    uint64_t timeout_id = 0;
  };
  std::map<uint64_t, BlobWait> blob_waits;
  uint64_t blob_rid = 0;

  std::vector<uint64_t> timers;
  uint64_t sync_rr = 0;

  std::shared_ptr<char> alive = std::make_shared<char>(0);


  void postGuarded(std::function<void()> fn) {
    std::weak_ptr<char> w = alive;
    loop.post([w, fn] {
      if (!w.expired()) fn();
    });
  }

  Impl(Runloop& l, IClock& c, HlcClock& h, ITransport& t, IDiscovery* d, Store& s, LwwMap& cfg,
       EventLog& ev, MeshSettings& settings, Callbacks callbacks)
      : loop(l), clock(c), hlc(h), tp(t), disc(d), store(s), config(cfg), events(ev),
        st(settings), cbs(std::move(callbacks)) {}

  int64_t now() { return clock.monoMs(); }
  int64_t hsTimeoutMs() const { return st.reconnect_ms; }



  void start() {
    if (running) return;
    running = true;

    Peer& self = peers[st.node_id];
    self.info.id = st.node_id;
    self.info.addrs = st.advertise_addrs;
    if (self.info.addrs.empty()) self.info.addrs.push_back(st.advertise_addr);
    if (!st.advertise_addr.empty() && self.info.addrs.front() != st.advertise_addr) {
      self.info.addrs.erase(std::remove(self.info.addrs.begin(), self.info.addrs.end(),
                                        st.advertise_addr), self.info.addrs.end());
      self.info.addrs.insert(self.info.addrs.begin(), st.advertise_addr);
    }
    self.info.epoch = st.epoch;
    self.info.hb_seq = 0;
    self.info.hb_hlc = hlc.tick();
    self.info.status = "alive";
    self.info.caps_json = st.caps_json;
    self.info.ui_manifest_json = st.ui_manifest_json;
    self.info.runtime_json = st.runtime_json;
    self.info.role = st.role;
    self.info.door = st.door;
    self.info.sw_version = st.sw_version;
    self.last_adv_mono = now();

    for (const auto& a : st.seed_peers) {
      if (!isSelfAddr(a)) known_addrs.insert(a);
    }

    tp.listen(st.listen_addr, [this](ConnPtr c) { onAccept(std::move(c)); });
    if (disc) {
      disc->start([this](const DiscoveredPeer& p) { onDiscovered(p); });


      std::weak_ptr<char> w = alive;
      disc->setPsk(st.psk);
      if (isPaired()) {

        disc->setPairFound([this, w](const PairBeacon& pb) {
          if (!w.expired() && running) onPairFound(pb);
        });
      } else {

        startPairAnnounce();
      }
      disc->announce(st.node_id, st.advertise_addr);
    }

    timers.push_back(loop.postEvery(st.heartbeat_ms, [this] { heartbeatTick(); }));
    timers.push_back(loop.postEvery(st.gossip_ms, [this] { gossipAll(); }));
    timers.push_back(loop.postEvery(st.sync_ms, [this] { syncTick(); }));
    timers.push_back(loop.postEvery(std::max<int64_t>(1, st.claim_ttl_ms / 3),
                                    [this] { leaderTick(); }));
    timers.push_back(loop.postEvery(st.reconnect_ms, [this] { maintain(); }));
    // Pairing countdowns tick once a second so token expiry, pairing-mode expiry, and pending
    // expiry reach the shell as events instead of only on the next poll.
    timers.push_back(loop.postEvery(1000, [this] { pairingTick(); }));
    postGuarded([this] {
      if (running) maintain();
    });
  }

  void stop() {
    if (!running) return;
    running = false;
    for (uint64_t id : timers) loop.cancel(id);
    timers.clear();

    for (auto& kv : chans) {
      kv.second->setCallbacks({});
      kv.second->close();
    }
    chans.clear();
    for (auto& ch : pending) {
      ch->setCallbacks({});
      ch->close();
    }
    pending.clear();
    for (auto& ib : inbound) {
      ib->conn->setCallbacks([](const Bytes&) {}, [] {});
      ib->conn->close();
    }
    inbound.clear();
    for (auto& kv : invites_) {
      if (kv.second->timer) loop.cancel(kv.second->timer);
      kv.second->finished = true;
    }
    invites_.clear();

    for (auto& kv : snap_waits) {
      loop.cancel(kv.second.timeout_id);
      if (kv.second.cb) kv.second.cb(Bytes());
    }
    snap_waits.clear();
    for (auto& kv : blob_waits) {
      loop.cancel(kv.second.timeout_id);
      if (kv.second.cb) kv.second.cb(Bytes());
    }
    blob_waits.clear();
    if (join) abortJoin("stopped");
    tp.stopListening();
    if (disc) disc->stop();
  }

  bool isSelfAddr(const std::string& a) const {
    return a == st.advertise_addr || a == st.listen_addr;
  }



  void onAccept(ConnPtr conn) {
    if (!running) {
      conn->close();
      return;
    }
    auto ib = std::make_shared<Inbound>();
    ib->conn = std::move(conn);
    inbound.push_back(ib);
    std::weak_ptr<Inbound> wib = ib;
    ib->conn->setCallbacks(
        [this, wib](const Bytes& f) {
          if (auto p = wib.lock()) onInboundFrame(p, f);
        },
        [this, wib] {
          if (auto p = wib.lock()) dropInbound(p);
        });

    std::weak_ptr<char> wa = alive;
    loop.postDelayed(hsTimeoutMs() * 4, [this, wa, wib] {
      if (wa.expired()) return;
      if (auto p = wib.lock()) {
        p->conn->close();
        dropInbound(p);
      }
    });
  }

  void dropInbound(const std::shared_ptr<Inbound>& ib) {
    inbound.erase(std::remove(inbound.begin(), inbound.end(), ib), inbound.end());
  }


  void onInboundFrame(const std::shared_ptr<Inbound>& ib, const Bytes& f) {
    if (f.empty()) return;
    if (f[0] == kFrameJoin) {
      handleJoinHostFrame(ib, f);
      return;
    }

    dropInbound(ib);
    auto ch = makeChannel(ib->conn, /*initiator=*/false);
    ch->start();
    ch->handleRawFrame(f);
  }



  std::shared_ptr<SecureChannel> makeChannel(ConnPtr conn, bool initiator) {
    auto ch = std::make_shared<SecureChannel>(loop, std::move(conn), initiator, st.psk,
                                              st.node_id, hsTimeoutMs());
    pending.push_back(ch);
    std::weak_ptr<SecureChannel> wch = ch;
    SecureChannel::Callbacks c;
    c.on_established = [this, wch] {
      if (auto p = wch.lock()) onChanEstablished(p);
    };
    c.on_message = [this, wch](const std::string& msg) {
      if (auto p = wch.lock()) handleMessage(p, msg);
    };
    c.on_close = [this, wch] {
      if (auto p = wch.lock()) onChanClosed(p);
    };
    ch->setCallbacks(std::move(c));
    return ch;
  }

  void detachAndClose(const std::shared_ptr<SecureChannel>& ch) {
    ch->setCallbacks({});
    ch->close();
    pending.erase(std::remove(pending.begin(), pending.end(), ch), pending.end());
  }

  void onChanEstablished(const std::shared_ptr<SecureChannel>& ch) {
    pending.erase(std::remove(pending.begin(), pending.end(), ch), pending.end());
    const std::string pid = ch->peerId();
    if (pid.empty() || pid == st.node_id) {
      detachAndClose(ch);
      return;
    }
    auto it = chans.find(pid);
    if (it != chans.end() && it->second != ch) {

      auto initiatorId = [&](const std::shared_ptr<SecureChannel>& c) {
        return c->isInitiator() ? st.node_id : pid;
      };
      if (initiatorId(ch) < initiatorId(it->second)) {
        detachAndClose(it->second);
        it->second = ch;
      } else {
        detachAndClose(ch);
        return;
      }
    } else {
      chans[pid] = ch;
    }
    Peer& p = peers[pid];
    if (p.info.id.empty()) {
      p.info.id = pid;
      p.info.status = "alive";
      p.last_adv_mono = now();
    }
    p.info.connected = true;
    if (ch->isInitiator()) rememberAddr(ch->remoteAddr(), pid);

    sendPeersTo(*ch);
    sendSyncReq(*ch);
    if (cbs.on_peers_changed) cbs.on_peers_changed();
    onPendingDeviceJoined(pid);
  }


  // A pending device that completes its secure handshake has really joined; that is the only
  // positive confirmation the inviting shell can show.
  void onPendingDeviceJoined(const std::string& pid) {
    auto it = pending_.find(pid);
    if (it == pending_.end()) return;
    const std::string name = it->second.name;
    const std::string role = it->second.role;
    auto run = invites_.find(pid);
    if (run != invites_.end()) finishInvite(run->second, true, "");
    pending_.erase(pid);
    if (now() < pairing_mode_until_) auto_added_count_++;
    if (cbs.on_device_joined) cbs.on_device_joined(pid, name, role);
    if (cbs.on_pending_changed) cbs.on_pending_changed();
  }

  void onChanClosed(const std::shared_ptr<SecureChannel>& ch) {
    pending.erase(std::remove(pending.begin(), pending.end(), ch), pending.end());
    const std::string pid = ch->peerId();
    auto it = chans.find(pid);
    if (it != chans.end() && it->second == ch) {
      chans.erase(it);
      auto p = peers.find(pid);
      if (p != peers.end()) p->second.info.connected = false;
      if (cbs.on_peers_changed) cbs.on_peers_changed();
    }
  }

  void rememberAddr(const std::string& addr, const std::string& owner) {
    if (addr.empty() || isSelfAddr(addr)) return;
    known_addrs.insert(addr);
    if (!owner.empty()) addr_owner[addr] = owner;
  }

  void onDiscovered(const DiscoveredPeer& p) {
    if (!running || p.node_id == st.node_id) return;
    rememberAddr(p.addr, p.node_id);
    Peer& peer = peers[p.node_id];
    if (peer.info.id.empty()) {
      peer.info.id = p.node_id;
      peer.info.status = "alive";
      peer.info.addrs = {p.addr};
      peer.last_adv_mono = now();
      if (cbs.on_peers_changed) cbs.on_peers_changed();
      postGuarded([this] {
        if (running) maintain();
      });
    }
  }



  bool dialInProgress(const std::string& addr) const {
    if (dialing.count(addr)) return true;
    for (const auto& ch : pending) {
      if (ch->isInitiator() && ch->remoteAddr() == addr) return true;
    }
    return false;
  }

  void maintain() {
    if (!running) return;
    const int budget = st.max_neighbors - static_cast<int>(chans.size());
    if (budget <= 0) return;

    std::vector<std::tuple<int, std::string, std::string>> cand;
    std::set<std::string> leader_ids;
    for (const auto& d : duties) {
      if (!d.second.leader.empty()) leader_ids.insert(d.second.leader);
    }
    auto isSeedAddr = [this](const std::string& a) {
      return std::find(st.seed_peers.begin(), st.seed_peers.end(), a) != st.seed_peers.end();
    };
    std::set<std::string> covered_addrs;
    for (const auto& kv : peers) {
      const Peer& p = kv.second;
      if (p.info.id == st.node_id || p.info.connected || p.info.status == "dead") continue;
      std::string addr;
      bool seed = false;
      for (const auto& a : p.info.addrs) {
        if (a.empty() || isSelfAddr(a)) continue;
        if (addr.empty()) addr = a;
        if (isSeedAddr(a)) {
          addr = a;
          seed = true;
        }
        covered_addrs.insert(a);
      }
      if (addr.empty() || dialInProgress(addr)) continue;
      const int pri = seed ? 0 : (leader_ids.count(p.info.id) ? 1 : 2);
      cand.emplace_back(pri, p.info.id, addr);
    }
    for (const auto& a : known_addrs) {
      if (covered_addrs.count(a) || dialInProgress(a)) continue;
      auto own = addr_owner.find(a);
      if (own != addr_owner.end() && (chans.count(own->second) || own->second == st.node_id)) {
        continue;
      }
      cand.emplace_back(3, a, a);
    }
    std::sort(cand.begin(), cand.end());
    int n = budget;
    for (const auto& c : cand) {
      if (n-- <= 0) break;
      dial(std::get<2>(c));
    }
  }

  void dial(const std::string& addr) {
    dialing.insert(addr);
    std::weak_ptr<char> w = alive;
    tp.connect(addr, [this, w, addr](ConnPtr conn) {
      if (w.expired()) {
        if (conn) conn->close();
        return;
      }
      dialing.erase(addr);
      if (!conn) return;
      if (!running) {
        conn->close();
        return;
      }
      makeChannel(std::move(conn), /*initiator=*/true)->start();
    });
  }



  void heartbeatTick() {
    Peer& self = peers[st.node_id];
    self.info.hb_seq++;
    self.info.hb_hlc = hlc.tick();
    self.last_adv_mono = now();
    auto ping = json::obj();
    json::set(ping.get(), "t", "PING");
    fillHb(ping.get());
    broadcast(json::dump(ping.get()));
    checkLiveness();
  }

  void fillHb(cJSON* o) {
    const Peer& self = peers[st.node_id];
    json::set(o, "id", st.node_id);
    json::set(o, "epoch", static_cast<int64_t>(st.epoch));
    json::set(o, "hb", static_cast<int64_t>(self.info.hb_seq));
    json::set(o, "hlc", self.info.hb_hlc);
  }

  void checkLiveness() {
    const int64_t t = now();
    bool changed = false;
    bool leader_dirty = false;
    for (auto& kv : peers) {
      Peer& p = kv.second;
      if (p.info.id == st.node_id) continue;
      const int64_t idle = t - p.last_adv_mono;
      std::string ns = idle >= st.dead_ms ? "dead" : (idle >= st.suspect_ms ? "suspect" : "alive");
      if (ns == p.info.status) continue;
      const bool was_dead = p.info.status == "dead";
      p.info.status = ns;
      changed = true;
      if (ns == "dead") {
        leader_dirty = true;
        if (cbs.on_peer_alive_changed) cbs.on_peer_alive_changed(p.info.id, false);
      } else if (was_dead) {
        leader_dirty = true;
        if (cbs.on_peer_alive_changed) cbs.on_peer_alive_changed(p.info.id, true);
      }
    }
    if (changed && cbs.on_peers_changed) cbs.on_peers_changed();
    if (leader_dirty) leaderTick();
  }


  bool observeHb(const std::string& id, uint64_t epoch, uint64_t hb, const std::string& hb_hlc) {
    if (id.empty() || id == st.node_id) return false;
    if (!hb_hlc.empty()) hlc.observe(hb_hlc);
    Peer& p = peers[id];
    const bool fresh = p.info.id.empty();
    if (fresh) {
      p.info.id = id;
      p.info.status = "alive";
    }
    if (!fresh && std::tie(epoch, hb) <= std::tie(p.info.epoch, p.info.hb_seq)) return false;
    p.info.epoch = epoch;
    p.info.hb_seq = hb;
    p.info.hb_hlc = hb_hlc;
    p.last_adv_mono = now();
    if (p.info.status == "dead") {
      p.info.status = "alive";
      if (cbs.on_peer_alive_changed) cbs.on_peer_alive_changed(id, true);
      if (cbs.on_peers_changed) cbs.on_peers_changed();
      leaderTick();
    } else if (p.info.status == "suspect") {
      p.info.status = "alive";
      if (cbs.on_peers_changed) cbs.on_peers_changed();
    } else if (fresh && cbs.on_peers_changed) {
      cbs.on_peers_changed();
    }
    return true;
  }

  // ------------------------------------------------------------------ PEERS gossip

  void sendPeersTo(SecureChannel& ch) {
    auto o = json::obj();
    json::set(o.get(), "t", "PEERS");
    cJSON* arr = json::addArr(o.get(), "peers");
    for (const auto& kv : peers) {
      const PeerInfo& p = kv.second.info;
      cJSON* e = json::pushObj(arr);
      json::set(e, "id", p.id);
      cJSON* addrs = json::addArr(e, "addrs");
      for (const auto& a : p.addrs) json::push(addrs, json::Doc(cJSON_CreateString(a.c_str())));
      json::set(e, "epoch", static_cast<int64_t>(p.epoch));
      json::set(e, "hb", static_cast<int64_t>(p.hb_seq));
      json::set(e, "hlc", p.hb_hlc);
      json::set(e, "status", p.status);
      json::set(e, "caps", p.caps_json);
      json::set(e, "role", p.role);
      json::set(e, "door", p.door);
      json::set(e, "sw", p.sw_version);
      json::set(e, "ui_manifest", p.ui_manifest_json);
      json::set(e, "runtime", p.runtime_json);
    }
    ch.sendMessage(json::dump(o.get()));
  }

  void gossipAll() {
    for (auto& kv : chans) sendPeersTo(*kv.second);
  }

  void handlePeers(const cJSON* doc, const std::string& sender) {
    const cJSON* arr = json::get(doc, "peers");
    if (!cJSON_IsArray(arr)) return;
    std::vector<WireHeartbeat> heartbeats;
    std::set<std::string> ids;
    const cJSON* e = nullptr;
    cJSON_ArrayForEach(e, arr) {
      WireHeartbeat heartbeat;
      if (!heartbeatFromJson(e, /*allow_empty_hlc=*/true, &heartbeat) ||
          !ids.insert(heartbeat.id).second)
        return;
      heartbeats.push_back(std::move(heartbeat));
    }

    bool leader_dirty = false;
    bool new_node = false;
    bool peer_details_changed = false;
    size_t heartbeat_index = 0;
    cJSON_ArrayForEach(e, arr) {
      const WireHeartbeat& heartbeat = heartbeats[heartbeat_index++];
      const std::string& id = heartbeat.id;
      if (id.empty() || id == st.node_id) continue;
      const bool fresh = peers.find(id) == peers.end();
      const bool advanced =
          observeHb(id, heartbeat.epoch, heartbeat.sequence, heartbeat.hlc);
      Peer& p = peers[id];
      const auto reported_version = std::make_pair(heartbeat.epoch, heartbeat.sequence);
      const auto current_version = std::make_pair(p.info.epoch, p.info.hb_seq);
      // A directly connected node may revise its own runtime details at the current heartbeat.
      // Relayed records still require a newer heartbeat so one peer cannot rewrite another.
      const bool current_self_report = id == sender && reported_version == current_version;
      if (fresh || advanced || current_self_report) {
        const auto old_addrs = p.info.addrs;
        const std::string old_caps = p.info.caps_json;
        const std::string old_role = p.info.role;
        const std::string old_door = p.info.door;
        const std::string old_sw = p.info.sw_version;
        const std::string old_manifest = p.info.ui_manifest_json;
        const std::string old_runtime = p.info.runtime_json;
        std::vector<std::string> addrs;
        const cJSON* a = nullptr;
        cJSON_ArrayForEach(a, json::get(e, "addrs")) {
          if (cJSON_IsString(a)) addrs.push_back(a->valuestring);
        }
        if (!addrs.empty()) p.info.addrs = addrs;
        for (const auto& ad : p.info.addrs) rememberAddr(ad, id);
        const std::string caps = json::getString(e, "caps");
        if (!caps.empty() && caps != p.info.caps_json) {
          p.info.caps_json = caps;
          leader_dirty = true;
        }
        p.info.role = json::getString(e, "role", p.info.role);
        if (heartbeat.has_door) p.info.door = heartbeat.door;
        p.info.sw_version = json::getString(e, "sw", p.info.sw_version);
        p.info.ui_manifest_json = json::getString(e, "ui_manifest", p.info.ui_manifest_json);
        const cJSON* runtime = json::get(e, "runtime");
        if (cJSON_IsString(runtime) && runtime->valuestring) {
          std::string projected;
          if (projectMeshRuntimeJson(runtime->valuestring, &projected))
            p.info.runtime_json = std::move(projected);
        }
        if (p.info.addrs != old_addrs || p.info.caps_json != old_caps ||
            p.info.role != old_role || p.info.door != old_door ||
            p.info.sw_version != old_sw ||
            p.info.ui_manifest_json != old_manifest || p.info.runtime_json != old_runtime)
          peer_details_changed = true;
      }
      if (fresh) new_node = true;
    }
    // UDP discovery initially provides only identity/address. The following PEERS message
    // supplies role, capabilities, and all interfaces, which still requires a UI refresh.
    if (peer_details_changed && cbs.on_peers_changed) cbs.on_peers_changed();
    if (leader_dirty) leaderTick();
    if (new_node) {
      postGuarded([this] {
        if (running) maintain();
      });
    }
  }



  static bool capsEligible(const cJSON* caps, const std::string& duty) {
    if (duty == "telegram" || duty == "web_push") {
      const char* ready = duty == "telegram" ? "telegram_ready" : "web_push_ready";
      return json::getBool(caps, "tls12") && json::getBool(caps, "wan") &&
             json::getBool(caps, "mains_power") && json::getBool(caps, "wall_clock_sane") &&
             json::getBool(caps, ready);
    }
    if (duty == "mqtt_bridge") {
      return json::getBool(caps, "mqtt_reachable") && json::getBool(caps, "mains_power") &&
             json::getBool(caps, "mqtt_ready");
    }
    return false;
  }

  int64_t rankOf(const std::string& id) const {
    auto it = peers.find(id);
    if (it == peers.end()) return 0;
    json::Doc caps = json::parse(it->second.info.caps_json);
    return caps ? json::getInt(caps.get(), "cpu_score") : 0;
  }

  bool notDead(const std::string& id) const {
    if (id == st.node_id) return true;
    auto it = peers.find(id);
    return it != peers.end() && it->second.info.status != "dead";
  }


  std::string computeLeader(const std::string& duty) const {
    std::string best;
    int64_t best_rank = 0;
    for (const auto& kv : peers) {
      const Peer& p = kv.second;
      if (p.info.id != st.node_id && p.info.status == "dead") continue;
      json::Doc caps = json::parse(p.info.caps_json);
      if (!caps || !capsEligible(caps.get(), duty)) continue;
      const int64_t r = json::getInt(caps.get(), "cpu_score");
      if (best.empty() || std::tie(r, p.info.id) > std::tie(best_rank, best)) {
        best = p.info.id;
        best_rank = r;
      }
    }
    return best;
  }

  void setLeader(const std::string& duty, const std::string& id) {
    DutyState& d = duties[duty];
    if (d.leader == id) return;
    d.leader = id;
    if (cbs.on_leader_changed) cbs.on_leader_changed(duty, id);
  }

  void leaderTick() {
    for (const char* duty : kDuties) {
      DutyState& d = duties[duty];
      const std::string w = computeLeader(duty);
      if (w == st.node_id && !w.empty()) {

        if (d.leader != w) d.term++;
        setLeader(duty, w);
        d.last_claim_mono = now();
        broadcastClaim(duty);
      } else {
        const bool lease_ok = !d.leader.empty() && notDead(d.leader) &&
                              (now() - d.last_claim_mono) < st.claim_ttl_ms;
        if (!lease_ok) setLeader(duty, w);
      }
    }
  }

  void broadcastClaim(const std::string& duty) {
    const DutyState& d = duties[duty];
    auto o = json::obj();
    json::set(o.get(), "t", "CLAIM");
    json::set(o.get(), "duty", duty);
    json::set(o.get(), "leader", st.node_id);
    json::set(o.get(), "term", static_cast<int64_t>(d.term));
    json::set(o.get(), "rank", rankOf(st.node_id));
    broadcast(json::dump(o.get()));
  }

  void handleClaim(const cJSON* doc) {
    const std::string duty = json::getString(doc, "duty");
    const std::string leader = json::getString(doc, "leader");
    int64_t rank = 0;
    uint64_t term = 0;
    if (!dutyValid(duty) || !nodeIdValid(leader.c_str()) ||
        !wireSignedInteger(json::get(doc, "rank"), &rank) ||
        !wireSequence(json::get(doc, "term"), true, &term))
      return;
    DutyState& d = duties[duty];
    if (leader == d.leader) {
      d.last_claim_mono = now();
      d.term = std::max(d.term, term);
      return;
    }
    if (!notDead(leader)) return;
    const bool lease_expired = d.leader.empty() || !notDead(d.leader) ||
                               (now() - d.last_claim_mono) >= st.claim_ttl_ms;

    if (lease_expired ||
        std::make_tuple(rank, leader) > std::make_tuple(rankOf(d.leader), d.leader)) {
      setLeader(duty, leader);
      d.term = std::max(d.term, term);
      d.last_claim_mono = now();
    }
  }



  void syncTick() {
    if (chans.empty()) return;
    std::vector<std::string> ids;
    ids.reserve(chans.size());
    for (const auto& kv : chans) ids.push_back(kv.first);

    const std::string& pick = ids[sync_rr++ % ids.size()];
    sendSyncReq(*chans[pick]);
  }

  void sendSyncReq(SecureChannel& ch) {
    auto o = json::obj();
    json::set(o.get(), "t", "SYNC_REQ");
    mapToJson(json::addObj(o.get(), "vv"), config.versionVector());
    mapToJson(json::addObj(o.get(), "heads"), events.heads());
    ch.sendMessage(json::dump(o.get()));
  }


  json::Doc buildSyncResp(const cJSON* remote, bool fin) {
    VersionVector rvv;
    std::map<std::string, uint64_t> rheads;
    if (!remote || !mapFromJson(json::get(remote, "vv"), &rvv) ||
        !mapFromJson(json::get(remote, "heads"), &rheads))
      return {};

    auto o = json::obj();
    json::set(o.get(), "t", "SYNC_RESP");
    json::setBool(o.get(), "fin", fin);
    // Config deltas are intentionally unbounded. This explicit frontier lets a receiver
    // acknowledge overwritten same-key sequences without granting that privilege to live pushes.
    mapToJson(json::addObj(o.get(), "cfg_complete_vv"), config.versionVector());
    if (!fin) {
      mapToJson(json::addObj(o.get(), "vv"), config.versionVector());
      mapToJson(json::addObj(o.get(), "heads"), events.heads());
    }
    cJSON* cfg = json::addArr(o.get(), "cfg");
    for (const auto& e : config.deltaSince(rvv)) json::push(cfg, entryToJson(e));
    cJSON* ev = json::addArr(o.get(), "ev");
    for (const auto& r : events.deltaSince(rheads, kSyncEventLimit)) {
      json::push(ev, eventToJson(r));
    }
    return o;
  }

  bool applySyncPayload(const cJSON* doc) {
    ConfigWirePayload config_payload;
    if (!configPayloadFromJson(doc, &config_payload)) return false;

    VersionVector unused;
    const cJSON* remote_vv = json::get(doc, "vv");
    const cJSON* remote_heads = json::get(doc, "heads");
    const cJSON* fin_value = json::get(doc, "fin");
    const bool fin = fin_value ? cJSON_IsTrue(fin_value) : true;
    if (fin_value && !cJSON_IsBool(fin_value)) return false;
    if ((remote_vv && !mapFromJson(remote_vv, &unused)) ||
        (remote_heads && !mapFromJson(remote_heads, &unused)) ||
        (!fin && (!remote_vv || !remote_heads)))
      return false;

    std::vector<EventRecord> event_payload;
    if (!eventsFromJson(json::get(doc, "ev"), &event_payload)) return false;

    if (config_payload.has_complete_frontier) {
      config.applyRemoteSnapshot(config_payload.entries, config_payload.complete_frontier);
    } else {
      config.applyRemoteBatch(config_payload.entries);
    }
    if (!config.lastMutationCommitted()) return false;

    for (const EventRecord& rec : event_payload) {
      std::vector<EventRecord> applied;
      const bool inserted = events.applyRemote(rec, &applied);
      if (cbs.on_event)
        for (const auto& record : applied) cbs.on_event(record);
      if (!inserted && !rec.notify_json.empty()) {
        events.mergeNotify(rec.origin, rec.seq, rec.notify_json);
      }
    }
    return true;
  }

  void handleSyncReq(SecureChannel& ch, const cJSON* doc) {
    auto resp = buildSyncResp(doc, /*fin=*/false);
    if (!resp) {
      DB_LOGW("mesh", "rejected malformed sync request from " + ch.peerId());
      return;
    }
    ch.sendMessage(json::dump(resp.get()));
  }

  void handleSyncResp(SecureChannel& ch, const cJSON* doc) {
    if (!applySyncPayload(doc)) {
      DB_LOGW("mesh", "rejected malformed sync response from " + ch.peerId());
      return;
    }
    if (!json::getBool(doc, "fin", true) && json::get(doc, "vv")) {
      auto resp = buildSyncResp(doc, /*fin=*/true);
      if (resp) ch.sendMessage(json::dump(resp.get()));
    }
  }

  // ------------------------------------------------------------------ EVENT / CMD

  void broadcastEvent(const EventRecord& ev) {
    auto o = json::obj();
    json::set(o.get(), "t", "EVENT");
    json::set(o.get(), "ttl", int64_t{kEventTtl});
    json::setItem(o.get(), "ev", eventToJson(ev));
    broadcast(json::dump(o.get()));
  }

  void handleEvent(SecureChannel& src, const cJSON* doc) {
    const cJSON* eo = json::get(doc, "ev");
    EventRecord rec;
    int64_t ttl = 1;
    const cJSON* wire_ttl = json::get(doc, "ttl");
    if (!eventFromJson(eo, &rec) ||
        (wire_ttl && (!wireSignedInteger(wire_ttl, &ttl) || ttl < 1 || ttl > kEventTtl))) {
      DB_LOGW("mesh", "rejected malformed event from " + src.peerId());
      return;
    }
    std::vector<EventRecord> applied;
    const bool inserted = events.applyRemote(rec, &applied);
    if (cbs.on_event)
      for (const auto& record : applied) cbs.on_event(record);
    if (!inserted) {
      if (!rec.notify_json.empty()) events.mergeNotify(rec.origin, rec.seq, rec.notify_json);
      return;
    }
    if (ttl > 1) {
      auto o = json::obj();
      json::set(o.get(), "t", "EVENT");
      json::set(o.get(), "ttl", ttl - 1);
      json::setItem(o.get(), "ev", eventToJson(rec));
      const std::string msg = json::dump(o.get());
      for (auto& kv : chans) {
        if (kv.second.get() != &src) kv.second->sendMessage(msg);
      }
    }
  }

  void pushConfigDelta(const std::vector<LwwEntry>& entries) {
    if (entries.empty() || chans.empty()) return;
    auto o = json::obj();
    json::set(o.get(), "t", "SYNC_RESP");
    json::setBool(o.get(), "fin", true);
    cJSON* cfg = json::addArr(o.get(), "cfg");
    for (const auto& e : entries) json::push(cfg, entryToJson(e));
    json::addArr(o.get(), "ev");
    broadcast(json::dump(o.get()));
  }

  json::Doc makeCmdMsg(const std::string& cmd_json) {
    auto o = json::obj();
    json::set(o.get(), "t", "CMD");
    json::set(o.get(), "from", st.node_id);
    json::set(o.get(), "cmd", cmd_json);
    return o;
  }

  void sendCommand(const std::string& node_id, const std::string& cmd_json) {
    auto it = chans.find(node_id);
    if (it == chans.end()) {
      DB_LOGW("mesh", "sendCommand: no direct channel to " + node_id);
      return;
    }
    auto o = makeCmdMsg(cmd_json);
    it->second->sendMessage(json::dump(o.get()));
  }

  void broadcastCommand(const std::string& cmd_json) {
    auto o = makeCmdMsg(cmd_json);
    broadcast(json::dump(o.get()));
  }

  void broadcast(const std::string& msg) {
    for (auto& kv : chans) kv.second->sendMessage(msg);
  }



  void fetchSnapshot(const std::string& node_id, std::function<void(Bytes)> cb) {
    if (node_id == st.node_id) {
      Bytes jpeg = snap_provider ? snap_provider() : Bytes();
      if (jpeg.size() > kSnapMaxBytes) jpeg.clear();
      loop.post([cb, jpeg] { cb(jpeg); });
      return;
    }
    auto it = chans.find(node_id);
    if (it == chans.end()) {
      DB_LOGW("mesh", "fetchSnapshot: no direct channel to " + node_id.substr(0, 8));
      loop.post([cb] { cb(Bytes()); });
      return;
    }
    const uint64_t rid = ++snap_rid;
    SnapWait& w = snap_waits[rid];
    w.cb = std::move(cb);
    std::weak_ptr<char> wa = alive;
    w.timeout_id = loop.postDelayed(kSnapTimeoutMs, [this, wa, rid] {
      if (wa.expired()) return;
      auto sit = snap_waits.find(rid);
      if (sit == snap_waits.end()) return;
      auto done = std::move(sit->second.cb);
      snap_waits.erase(sit);
      if (done) done(Bytes());
    });
    auto o = json::obj();
    json::set(o.get(), "t", "SNAP_REQ");
    json::set(o.get(), "rid", static_cast<int64_t>(rid));
    it->second->sendMessage(json::dump(o.get()));
  }

  void handleSnapReq(SecureChannel& ch, const cJSON* doc) {
    const int64_t rid = json::getInt(doc, "rid");
    Bytes jpeg = snap_provider ? snap_provider() : Bytes();
    if (jpeg.size() > kSnapMaxBytes) jpeg.clear();
    auto o = json::obj();
    json::set(o.get(), "t", "SNAP_RESP");
    json::set(o.get(), "rid", rid);
    json::set(o.get(), "jpeg", base64Encode(jpeg));
    ch.sendMessage(json::dump(o.get()));
  }

  void handleSnapResp(const cJSON* doc) {
    const uint64_t rid = static_cast<uint64_t>(json::getInt(doc, "rid"));
    auto it = snap_waits.find(rid);
    if (it == snap_waits.end()) return;
    loop.cancel(it->second.timeout_id);
    auto done = std::move(it->second.cb);
    snap_waits.erase(it);
    Bytes jpeg;
    base64Decode(json::getString(doc, "jpeg"), jpeg);
    if (done) done(std::move(jpeg));
  }





  void fetchBlob(const std::string& hash, std::function<void(Bytes)> cb) {
    if (hash.empty()) {
      loop.post([cb] { cb(Bytes()); });
      return;
    }

    if (blob_provider) {
      Bytes local = blob_provider(hash);
      if (!local.empty() && local.size() <= kBlobMaxBytes) {
        loop.post([cb, local] { cb(local); });
        return;
      }
    }
    std::vector<std::string> candidates;
    for (const auto& kv : chans) candidates.push_back(kv.first);
    tryNextBlobPeer(hash, std::move(candidates), std::move(cb));
  }

  void tryNextBlobPeer(const std::string& hash, std::vector<std::string> remaining,
                       std::function<void(Bytes)> cb) {

    std::shared_ptr<SecureChannel> ch;
    while (!remaining.empty() && !ch) {
      auto it = chans.find(remaining.front());
      remaining.erase(remaining.begin());
      if (it != chans.end()) ch = it->second;
    }
    if (!ch) {
      DB_LOGW("mesh", "fetchBlob: no peer has " + hash.substr(0, 12));
      loop.post([cb] { cb(Bytes()); });
      return;
    }
    const uint64_t rid = ++blob_rid;
    BlobWait& w = blob_waits[rid];
    w.hash = hash;
    w.remaining = std::move(remaining);
    w.cb = std::move(cb);
    std::weak_ptr<char> wa = alive;
    w.timeout_id = loop.postDelayed(kBlobTimeoutMs, [this, wa, rid] {
      if (wa.expired()) return;
      failBlobAttempt(rid, /*cancel_timer=*/false);
    });
    auto o = json::obj();
    json::set(o.get(), "t", "BLOB_REQ");
    json::set(o.get(), "rid", static_cast<int64_t>(rid));
    json::set(o.get(), "hash", hash);
    ch->sendMessage(json::dump(o.get()));
  }


  void failBlobAttempt(uint64_t rid, bool cancel_timer) {
    auto it = blob_waits.find(rid);
    if (it == blob_waits.end()) return;
    if (cancel_timer) loop.cancel(it->second.timeout_id);
    auto hash = std::move(it->second.hash);
    auto remaining = std::move(it->second.remaining);
    auto cb = std::move(it->second.cb);
    blob_waits.erase(it);
    tryNextBlobPeer(hash, std::move(remaining), std::move(cb));
  }

  void handleBlobReq(SecureChannel& ch, const cJSON* doc) {
    const int64_t rid = json::getInt(doc, "rid");
    const std::string hash = json::getString(doc, "hash");
    Bytes data = blob_provider ? blob_provider(hash) : Bytes();
    if (data.empty() || data.size() > kBlobMaxBytes) {
      auto o = json::obj();
      json::set(o.get(), "t", "BLOB_RESP");
      json::set(o.get(), "rid", rid);
      json::set(o.get(), "hash", hash);
      json::setBool(o.get(), "found", false);
      ch.sendMessage(json::dump(o.get()));
      return;
    }
    const uint64_t n = (data.size() + kBlobChunkBytes - 1) / kBlobChunkBytes;
    for (uint64_t i = 0; i < n; i++) {
      const size_t off = static_cast<size_t>(i) * kBlobChunkBytes;
      const size_t len = std::min(kBlobChunkBytes, data.size() - off);
      auto o = json::obj();
      json::set(o.get(), "t", "BLOB_RESP");
      json::set(o.get(), "rid", rid);
      json::set(o.get(), "hash", hash);
      json::setBool(o.get(), "found", true);
      json::set(o.get(), "seq", static_cast<int64_t>(i));
      json::set(o.get(), "n", static_cast<int64_t>(n));
      json::set(o.get(), "data", base64Encode(data.data() + off, len));
      ch.sendMessage(json::dump(o.get()));
    }
  }

  void handleBlobResp(const cJSON* doc) {
    const uint64_t rid = static_cast<uint64_t>(json::getInt(doc, "rid"));
    auto it = blob_waits.find(rid);
    if (it == blob_waits.end()) return;
    BlobWait& w = it->second;
    if (json::getString(doc, "hash") != w.hash) return;
    if (!json::getBool(doc, "found", false)) {
      failBlobAttempt(rid, /*cancel_timer=*/true);
      return;
    }
    const uint64_t seq = static_cast<uint64_t>(json::getInt(doc, "seq"));
    const uint64_t n = static_cast<uint64_t>(json::getInt(doc, "n"));
    Bytes chunk;
    if (n == 0 || seq >= n || !base64Decode(json::getString(doc, "data"), chunk) ||
        (w.total_chunks != 0 && w.total_chunks != n)) {
      failBlobAttempt(rid, /*cancel_timer=*/true);
      return;
    }
    w.total_chunks = n;
    if (!w.chunks.count(seq)) w.total_bytes += chunk.size();
    if (w.total_bytes > kBlobMaxBytes) {
      failBlobAttempt(rid, /*cancel_timer=*/true);
      return;
    }
    w.chunks[seq] = std::move(chunk);
    if (w.chunks.size() < w.total_chunks) return;
    Bytes data;
    data.reserve(w.total_bytes);
    for (auto& c : w.chunks) data.insert(data.end(), c.second.begin(), c.second.end());
    loop.cancel(w.timeout_id);
    auto done = std::move(w.cb);
    blob_waits.erase(it);
    if (done) done(std::move(data));
  }



  void handleMessage(const std::shared_ptr<SecureChannel>& ch, const std::string& msg) {
    if (!running) return;
    json::Doc doc = json::parse(msg);
    if (!doc) {
      DB_LOGW("mesh", "bad message from " + ch->peerId());
      return;
    }
    const std::string t = json::getString(doc.get(), "t");
    if (t == "PEERS") {
      handlePeers(doc.get(), ch->peerId());
    } else if (t == "PING" || t == "PONG") {
      WireHeartbeat heartbeat;
      if (!heartbeatFromJson(doc.get(), /*allow_empty_hlc=*/false, &heartbeat)) return;
      observeHb(heartbeat.id, heartbeat.epoch, heartbeat.sequence, heartbeat.hlc);
      if (t == "PING") {
        auto o = json::obj();
        json::set(o.get(), "t", "PONG");
        fillHb(o.get());
        ch->sendMessage(json::dump(o.get()));
      }
    } else if (t == "SYNC_REQ") {
      handleSyncReq(*ch, doc.get());
    } else if (t == "SYNC_RESP") {
      handleSyncResp(*ch, doc.get());
    } else if (t == "CLAIM") {
      handleClaim(doc.get());
    } else if (t == "EVENT") {
      handleEvent(*ch, doc.get());
    } else if (t == "SNAP_REQ") {
      handleSnapReq(*ch, doc.get());
    } else if (t == "SNAP_RESP") {
      handleSnapResp(doc.get());
    } else if (t == "BLOB_REQ") {
      handleBlobReq(*ch, doc.get());
    } else if (t == "BLOB_RESP") {
      handleBlobResp(doc.get());
    } else if (t == "CMD") {
      if (cbs.on_command) {
        cbs.on_command(ch->peerId(), json::getString(doc.get(), "cmd"));
      }
    }
  }



  void sendJoinErr(const ConnPtr& conn, const std::string& err) {
    auto o = json::obj();
    json::set(o.get(), "t", "JOIN_ERR");
    json::set(o.get(), "err", err);
    sendJoinFrame(conn, o.get());
  }

  void handleJoinHostFrame(const std::shared_ptr<Inbound>& ib, const Bytes& f) {
    json::Doc doc = json::parse(std::string(f.begin() + 1, f.end()));
    if (!doc) return;
    const std::string t = json::getString(doc.get(), "t");
    if (t == "JOIN_REQ1") {
      if (!isPaired()) {
        sendJoinErr(ib->conn, "host_unpaired");
        return;
      }
      if (expireToken()) notifyToken();
      if (!token.active) {
        const bool just_expired = token.expired_unreported;
        token.expired_unreported = false;
        sendJoinErr(ib->conn, just_expired ? "expired" : "no_token");
        return;
      }
      ib->challenge = randomBytes(32);
      ib->salt = randomBytes(16);
      ib->challenged = true;
      auto o = json::obj();
      json::set(o.get(), "t", "JOIN_CHALLENGE");
      json::set(o.get(), "challenge", hexEncode(ib->challenge));
      json::set(o.get(), "salt", hexEncode(ib->salt));
      sendJoinFrame(ib->conn, o.get());
    } else if (t == "JOIN_PROOF") {
      if (!ib->challenged || !token.active || now() >= token.expires_mono) {
        sendJoinErr(ib->conn, "no_token");
        return;
      }
      const std::string joiner_id = json::getString(doc.get(), "id");
      Bytes mac;
      if (!hexDecode(json::getString(doc.get(), "hmac"), mac) || mac.size() != 32) {
        sendJoinErr(ib->conn, "bad_pin");
        return;
      }
      const auto k = joinKey(token.pin, ib->salt);
      const auto expect = joinProof(k, ib->challenge, joiner_id);
      if (crypto_verify32(mac.data(), expect.data()) != 0) {
        if (++token.fails >= kInviteAttempts) token.active = false;
        notifyToken();
        sendJoinErr(ib->conn, "bad_pin");
        return;
      }

      const std::string plain = buildJoinPayloadJson();
      Bytes nonce = randomBytes(24);
      Bytes out(16 + plain.size());  // mac(16) || cipher
      crypto_aead_lock(out.data() + 16, out.data(), k.data(), nonce.data(), nullptr, 0,
                       reinterpret_cast<const uint8_t*>(plain.data()), plain.size());
      auto o = json::obj();
      json::set(o.get(), "t", "JOIN_OK");
      json::set(o.get(), "n", hexEncode(nonce));
      json::set(o.get(), "c", hexEncode(out));
      sendJoinFrame(ib->conn, o.get());
      token.active = false;
      notifyToken();
    } else if (t == "INVITE") {


      // Every refusal is reported: a silent return leaves the inviting shell waiting forever.
      if (isPaired()) {
        rejectInvite(ib->conn, "already_paired");
        return;
      }
      if (!pair_keys_ready_) {
        rejectInvite(ib->conn, "no_pair_key");
        return;
      }
      Bytes epk, nonce, enc;
      if (!hexDecode(json::getString(doc.get(), "epk"), epk) || epk.size() != 32 ||
          !hexDecode(json::getString(doc.get(), "n"), nonce) || nonce.size() != 24 ||
          !hexDecode(json::getString(doc.get(), "c"), enc) || enc.size() < 16) {
        rejectInvite(ib->conn, "bad_payload");
        return;
      }
      std::array<uint8_t, 32> shared{}, key{};
      crypto_x25519(shared.data(), pair_sk_.data(), epk.data());
      crypto_blake2b(key.data(), 32, shared.data(), shared.size());
      Bytes plain(enc.size() - 16);
      if (crypto_aead_unlock(plain.data(), enc.data(), key.data(), nonce.data(), nullptr, 0,
                             enc.data() + 16, plain.size()) != 0) {
        rejectInvite(ib->conn, "decrypt_failed");
        return;
      }
      json::Doc payload = json::parse(std::string(plain.begin(), plain.end()));
      std::string err = "bad_payload";
      if (!payload || !applyJoinPayload(payload.get(), &err)) {
        rejectInvite(ib->conn, err);
        return;
      }
      // The acknowledgement precedes onBecamePaired so the inviter learns the outcome even if
      // rekeying immediately drops this unencrypted join connection.
      auto ack = json::obj();
      json::set(ack.get(), "t", "INVITE_ACK");
      json::set(ack.get(), "id", st.node_id);
      json::set(ack.get(), "name", pairName());
      json::set(ack.get(), "role", st.role);
      sendJoinFrame(ib->conn, ack.get());
      onBecamePaired();
    }
  }


  void rejectInvite(const ConnPtr& conn, const std::string& reason) {
    auto o = json::obj();
    json::set(o.get(), "t", "INVITE_NAK");
    json::set(o.get(), "err", reason);
    sendJoinFrame(conn, o.get());
    if (cbs.on_invite_rejected) cbs.on_invite_rejected(reason);
  }


  std::string buildJoinPayloadJson() {
    auto payload = json::obj();
    json::set(payload.get(), "psk", hexEncode(st.psk.data(), st.psk.size()));
    json::set(payload.get(), "psk_id", st.psk_id);
    cJSON* seeds = json::addArr(payload.get(), "seeds");
    std::set<std::string> seen;
    auto addSeed = [&](const std::string& a) {
      if (!a.empty() && seen.insert(a).second) {
        json::push(seeds, json::Doc(cJSON_CreateString(a.c_str())));
      }
    };
    addSeed(st.advertise_addr);
    for (const auto& a : st.seed_peers) addSeed(a);
    cJSON* cfg = json::addArr(payload.get(), "cfg");
    for (const auto& e : config.all()) json::push(cfg, entryToJson(e));
    mapToJson(json::addObj(payload.get(), "cfg_complete_vv"), config.versionVector());
    return json::dump(payload.get());
  }


  // err distinguishes a malformed or unusable wire payload ("bad_payload", "host_zero_psk") from
  // a local durability failure ("local_persist_failed"), which the shell must report differently.
  bool applyJoinPayload(const cJSON* payload, std::string* err) {
    auto fail = [err](const char* code) {
      if (err) *err = code;
      return false;
    };
    Bytes psk;
    if (!hexDecode(json::getString(payload, "psk"), psk) || psk.size() != 32) {
      return fail("bad_payload");
    }
    if (std::all_of(psk.begin(), psk.end(), [](uint8_t b) { return b == 0; })) {
      // An all-zero key would leave both sides "paired" with no authentication at all.
      return fail("host_zero_psk");
    }
    ConfigWirePayload config_payload;
    if (!configPayloadFromJson(payload, &config_payload)) return fail("bad_payload");

    // Adopt the cluster key before committing config so a crash between the two cannot leave the
    // node holding cluster configuration it has no key for. LwwMap restores its pre-mutation
    // state when a commit fails, so only the key needs an explicit rollback here.
    const std::array<uint8_t, 32> previous_psk = st.psk;
    const std::string previous_psk_id = st.psk_id;
    std::copy(psk.begin(), psk.end(), st.psk.begin());
    st.psk_id = json::getString(payload, "psk_id", st.psk_id);

    if (config_payload.has_complete_frontier) {
      config.applyRemoteSnapshot(config_payload.entries, config_payload.complete_frontier);
    } else {
      config.applyRemoteBatch(config_payload.entries);
    }
    if (!config.lastMutationCommitted()) {
      st.psk = previous_psk;
      st.psk_id = previous_psk_id;
      return fail("local_persist_failed");
    }

    const cJSON* a = nullptr;
    cJSON_ArrayForEach(a, json::get(payload, "seeds")) {
      if (!cJSON_IsString(a)) continue;
      const std::string addr = a->valuestring;
      if (isSelfAddr(addr)) continue;
      if (std::find(st.seed_peers.begin(), st.seed_peers.end(), addr) == st.seed_peers.end()) {
        st.seed_peers.push_back(addr);
      }
      rememberAddr(addr, "");
    }
    return true;
  }




  // inline_done delivers the result before the caller's next statement. The successful JOIN_OK
  // path needs it so join_result reaches the shell ahead of paired/pairing_state.
  void finishJoin(std::shared_ptr<JoinRun> j, bool ok, const std::string& err,
                  bool inline_done = false) {
    if (j->finished) return;
    j->finished = true;
    if (j->timeout_id) {
      loop.cancel(j->timeout_id);
      j->timeout_id = 0;
    }
    if (j->conn) {
      j->conn->setCallbacks([](const Bytes&) {}, [] {});
      j->conn->close();
    }
    if (join == j) join.reset();
    auto done = j->done;
    if (inline_done) {
      if (done) done(ok, err);
    } else {
      loop.post([done, ok, err] {
        if (done) done(ok, err);
      });
    }
    if (ok) {
      postGuarded([this] {
        if (running) maintain();
      });
    }
  }

  void abortJoin(const std::string& err) {
    if (join) finishJoin(join, false, err);
  }



  bool isPaired() const {
    for (uint8_t b : st.psk)
      if (b) return true;
    return false;
  }

  void ensurePairKeys() {
    if (pair_keys_ready_) return;
    Bytes sk = randomBytes(32);
    std::copy(sk.begin(), sk.end(), pair_sk_.begin());
    crypto_x25519_public_key(pair_pk_.data(), pair_sk_.data());
    pair_keys_ready_ = true;
  }

  std::string pairName() const {

    return st.role + " · " + (st.node_id.size() > 6 ? st.node_id.substr(0, 6) : st.node_id);
  }


  std::string pairingSelfJson() {
    ensurePairKeys();
    auto o = json::obj();
    json::setBool(o.get(), "paired", isPaired());
    json::set(o.get(), "id", st.node_id);
    json::set(o.get(), "addr", st.advertise_addr);
    json::set(o.get(), "name", pairName());
    json::set(o.get(), "role", st.role);
    json::set(o.get(), "pk", hexEncode(pair_pk_.data(), pair_pk_.size()));
    json::set(o.get(), "model", st.model);
    json::set(o.get(), "platform", st.platform);
    json::set(o.get(), "sw", st.sw_version);
    return json::dump(o.get());
  }


  std::string pendingJson() {
    expirePending();
    const int64_t t = now();
    auto o = json::obj();
    json::setBool(o.get(), "pairing_mode", t < pairing_mode_until_);
    json::set(o.get(), "pairing_mode_left_s",
              t < pairing_mode_until_ ? (pairing_mode_until_ - t) / 1000 : int64_t{0});
    json::set(o.get(), "auto_added_count", static_cast<int64_t>(auto_added_count_));
    cJSON* arr = json::addArr(o.get(), "devices");
    for (const auto& kv : pending_) {
      auto d = json::obj();
      json::set(d.get(), "id", kv.second.id);
      json::set(d.get(), "addr", kv.second.addr);
      json::set(d.get(), "name", kv.second.name);
      json::set(d.get(), "role", kv.second.role);
      json::set(d.get(), "model", kv.second.model);
      json::set(d.get(), "platform", kv.second.platform);
      json::set(d.get(), "sw", kv.second.sw);
      json::set(d.get(), "age_s", (t - kv.second.last_seen) / 1000);
      json::set(d.get(), "invite_state", kv.second.invite_state);
      json::set(d.get(), "attempts", static_cast<int64_t>(kv.second.attempts));
      json::set(d.get(), "last_error", kv.second.last_error);
      json::push(arr, std::move(d));
    }
    return json::dump(o.get());
  }


  std::string tokenJson() {
    expireToken();
    const bool active = token.active;
    auto o = json::obj();
    json::setBool(o.get(), "active", active);
    json::set(o.get(), "expires_s",
              active ? std::max<int64_t>(0, (token.expires_mono - now() + 999) / 1000)
                     : int64_t{0});
    json::set(o.get(), "attempts_left",
              active ? static_cast<int64_t>(kInviteAttempts - token.fails) : int64_t{0});
    json::set(o.get(), "host", st.advertise_addr);
    // The PIN is readable only while the token is live so a reopened panel can redraw the card.
    if (active) json::set(o.get(), "pin", token.pin);
    return json::dump(o.get());
  }


  bool expirePending() {
    const int64_t t = now();
    bool changed = false;
    for (auto it = pending_.begin(); it != pending_.end();) {
      if (t - it->second.last_seen > kPendingTtlMs) {
        it = pending_.erase(it);
        changed = true;
      } else {
        ++it;
      }
    }
    for (auto it = denied_.begin(); it != denied_.end();) {
      it = t >= it->second ? denied_.erase(it) : std::next(it);
    }
    return changed;
  }


  bool expireToken() {
    if (!token.active || now() < token.expires_mono) return false;
    token.active = false;
    token.expired_unreported = true;
    return true;
  }


  void notifyToken() {
    if (!cbs.on_join_token_changed) return;
    cbs.on_join_token_changed(
        token.active, token.active ? std::max<int64_t>(0, (token.expires_mono - now() + 999) / 1000)
                                   : 0,
        token.active ? kInviteAttempts - token.fails : 0);
  }


  void notifyPairingMode() {
    if (!cbs.on_pairing_mode_changed) return;
    const int64_t t = now();
    const bool active = t < pairing_mode_until_;
    cbs.on_pairing_mode_changed(active, active ? (pairing_mode_until_ - t) / 1000 : 0,
                                auto_added_count_);
  }


  void pairingTick() {
    if (!running) return;
    if (expirePending() && cbs.on_pending_changed) cbs.on_pending_changed();
    if (expireToken()) notifyToken();
    if (pairing_mode_until_ != 0 && now() >= pairing_mode_until_) {
      pairing_mode_until_ = 0;
      notifyPairingMode();
    }
  }

  void onPairFound(const PairBeacon& pb) {
    if (!isPaired()) return;
    if (pb.id == st.node_id) return;
    if (pb.pk.size() != 64) return;
    auto pit = peers.find(pb.id);
    if (pit != peers.end() && pit->second.info.connected) return;
    auto denial = denied_.find(pb.id);
    if (denial != denied_.end()) {
      if (now() < denial->second) return;
      denied_.erase(denial);
    }
    auto it = pending_.find(pb.id);
    const bool isNew = it == pending_.end();
    Pending& p = pending_[pb.id];
    const bool changed = isNew || p.addr != pb.addr || p.name != pb.name || p.role != pb.role ||
                         p.model != pb.model || p.platform != pb.platform || p.sw != pb.sw;
    p.id = pb.id;
    p.addr = pb.addr;
    p.name = pb.name;
    p.role = pb.role;
    p.pk = pb.pk;
    p.model = pb.model;
    p.platform = pb.platform;
    p.sw = pb.sw;
    p.last_seen = now();
    if (now() < pairing_mode_until_) {
      inviteDevice(pb.id, /*manual=*/false);
    }
    if (changed && cbs.on_pending_changed) cbs.on_pending_changed();
  }



  bool foundCluster() {
    if (isPaired()) return false;
    Bytes psk = randomBytes(32);
    std::copy(psk.begin(), psk.end(), st.psk.begin());
    if (st.psk_id.empty()) st.psk_id = "k1";
    is_founder_ = true;
    onBecamePaired();
    return true;
  }


  void setPairingMode(int64_t ttl_ms) {
    if (ttl_ms <= 0) {
      pairing_mode_until_ = 0;
      notifyPairingMode();
      return;
    }
    pairing_mode_until_ = now() + ttl_ms;
    auto_added_count_ = 0;
    std::vector<std::string> ids;
    for (const auto& kv : pending_) ids.push_back(kv.first);
    for (const auto& id : ids) inviteDevice(id, /*manual=*/false);
    notifyPairingMode();
  }


  void inviteDevice(const std::string& id, bool manual) {
    auto it = pending_.find(id);
    if (it == pending_.end()) {
      if (manual && cbs.on_invite_result) cbs.on_invite_result(id, false, "unknown_device");
      return;
    }
    if (!isPaired()) {
      if (manual && cbs.on_invite_result) cbs.on_invite_result(id, false, "host_unpaired");
      return;
    }
    auto run = invites_.find(id);
    if (run != invites_.end()) {
      // An automatic re-announcement must not restart an invitation that is already in flight.
      if (!manual) return;
      finishInvite(run->second, false, "superseded");
    }
    startInvite(id, it->second.addr, it->second.pk, manual);
  }


  void inviteDeviceDirect(const std::string& addr, const std::string& pk) {
    if (!isPaired()) {
      if (cbs.on_invite_result) cbs.on_invite_result(addr, false, "host_unpaired");
      return;
    }
    const std::string key = "addr:" + addr;
    auto run = invites_.find(key);
    if (run != invites_.end()) finishInvite(run->second, false, "superseded");
    startInvite("", addr, pk, /*manual=*/true);
  }


  void denyDevice(const std::string& id) {
    auto run = invites_.find(id);
    if (run != invites_.end()) finishInvite(run->second, false, "denied");
    denied_[id] = now() + kDenyTtlMs;
    if (pending_.erase(id) > 0 && cbs.on_pending_changed) cbs.on_pending_changed();
  }


  void startInvite(const std::string& id, const std::string& addr, const std::string& pk,
                   bool manual) {
    if (addr.empty()) {
      if (manual && cbs.on_invite_result) cbs.on_invite_result(id, false, "no_addr");
      return;
    }
    Bytes decoded;
    if (!hexDecode(pk, decoded) || decoded.size() != 32) {
      if (manual && cbs.on_invite_result) cbs.on_invite_result(id.empty() ? addr : id, false,
                                                               "bad_pk");
      return;
    }
    auto run = std::make_shared<InviteRun>();
    run->key = id.empty() ? ("addr:" + addr) : id;
    run->id = id;
    run->addr = addr;
    run->pk = pk;
    run->manual = manual;
    invites_[run->key] = run;
    sendInviteAttempt(run);
  }


  void sendInviteAttempt(const std::shared_ptr<InviteRun>& run) {
    run->attempts++;
    auto it = pending_.find(run->id);
    if (it != pending_.end()) {
      it->second.invite_state = "sent";
      it->second.attempts = run->attempts;
      it->second.last_error.clear();
      if (cbs.on_pending_changed) cbs.on_pending_changed();
    }
    sendInvite(run->addr, run->pk, run);
    std::weak_ptr<char> w = alive;
    run->timer = loop.postDelayed(kInviteAckMs, [this, w, run] {
      if (w.expired()) return;
      run->timer = 0;
      if (run->finished) return;
      if (run->manual && run->attempts < kInviteAttempts) {
        sendInviteAttempt(run);
        return;
      }
      finishInvite(run, false, "no_ack");
    });
  }


  void finishInvite(const std::shared_ptr<InviteRun>& run, bool ok, const std::string& err) {
    if (run->finished) return;
    run->finished = true;
    if (run->timer) {
      loop.cancel(run->timer);
      run->timer = 0;
    }
    auto held = invites_.find(run->key);
    if (held != invites_.end() && held->second == run) invites_.erase(held);
    auto it = pending_.find(run->id);
    if (it != pending_.end()) {
      it->second.invite_state = ok ? "acked" : "failed";
      it->second.attempts = run->attempts;
      it->second.last_error = ok ? "" : err;
      if (cbs.on_pending_changed) cbs.on_pending_changed();
    }
    if (err == "superseded") return;
    if (run->manual && cbs.on_invite_result) {
      cbs.on_invite_result(run->id.empty() ? run->addr : run->id, ok, err);
    }
  }


  void onInviteAck(const std::shared_ptr<InviteRun>& run, const cJSON* doc) {
    const std::string t = json::getString(doc, "t");
    if (t == "INVITE_NAK") {
      finishInvite(run, false, json::getString(doc, "err", "rejected"));
      return;
    }
    if (t != "INVITE_ACK") return;
    const std::string id = json::getString(doc, "id");
    if (run->id.empty() && !id.empty()) run->id = id;
    finishInvite(run, true, "");
  }

  void sendInvite(const std::string& addr, const std::string& pk_hex,
                  std::shared_ptr<InviteRun> run = nullptr) {
    if (!isPaired() || addr.empty()) return;
    Bytes pk;
    if (!hexDecode(pk_hex, pk) || pk.size() != 32) return;

    Bytes esk = randomBytes(32);
    std::array<uint8_t, 32> epk{}, shared{}, key{};
    crypto_x25519_public_key(epk.data(), esk.data());
    crypto_x25519(shared.data(), esk.data(), pk.data());
    crypto_blake2b(key.data(), 32, shared.data(), shared.size());
    const std::string plain = buildJoinPayloadJson();
    Bytes nonce = randomBytes(24);
    Bytes out(16 + plain.size());  // mac(16) || cipher
    crypto_aead_lock(out.data() + 16, out.data(), key.data(), nonce.data(), nullptr, 0,
                     reinterpret_cast<const uint8_t*>(plain.data()), plain.size());
    auto o = json::obj();
    json::set(o.get(), "t", "INVITE");
    json::set(o.get(), "epk", hexEncode(epk.data(), epk.size()));
    json::set(o.get(), "n", hexEncode(nonce));
    json::set(o.get(), "c", hexEncode(out));
    const std::string s = json::dump(o.get());
    Bytes frame;
    frame.reserve(1 + s.size());
    frame.push_back(kFrameJoin);
    frame.insert(frame.end(), s.begin(), s.end());
    std::weak_ptr<char> w = alive;
    tp.connect(addr, [this, w, frame, run](ConnPtr conn) {
      // A device that is rebooting refuses the connection; the retry timer tries again and only
      // gives up as "no_ack" after the last attempt.
      if (w.expired() || !conn) {
        if (conn) conn->close();
        return;
      }
      if (run) {
        std::weak_ptr<char> wr = alive;
        conn->setCallbacks(
            [this, wr, run](const Bytes& f) {
              if (wr.expired() || f.empty() || f[0] != kFrameJoin) return;
              json::Doc doc = json::parse(std::string(f.begin() + 1, f.end()));
              if (doc) onInviteAck(run, doc.get());
            },
            [] {});
      } else {
        conn->setCallbacks([](const Bytes&) {}, [] {});
      }
      conn->send(frame);

      std::weak_ptr<char> w2 = alive;
      loop.postDelayed(1500, [w2, conn] {
        if (!w2.expired()) conn->close();
      });
    });
  }


  void startPairAnnounce() {
    if (!disc) return;
    ensurePairKeys();
    PairAnnounce a;
    a.on = true;
    a.name = pairName();
    a.role = st.role;
    a.pk = hexEncode(pair_pk_.data(), pair_pk_.size());
    a.model = st.model;
    a.platform = st.platform;
    a.sw = st.sw_version;
    disc->setPairAnnounce(a);
  }


  void onBecamePaired() {
    if (disc) {
      disc->setPairAnnounce(PairAnnounce{});
      // HELLO packets must be authenticated with the key this node just adopted; without the
      // rekey, discovery stays broken until the process restarts.
      disc->setPsk(st.psk);
      std::weak_ptr<char> w = alive;
      disc->setPairFound([this, w](const PairBeacon& pb) {
        if (!w.expired() && running) onPairFound(pb);
      });
    }
    pending_.clear();
    for (auto& kv : invites_) {
      if (kv.second->timer) loop.cancel(kv.second->timer);
      kv.second->finished = true;
    }
    invites_.clear();
    pairing_mode_until_ = 0;
    auto_added_count_ = 0;
    postGuarded([this] {
      if (running) maintain();
    });
    if (cbs.on_paired) cbs.on_paired();
  }


  // Leave the cluster. The key is zeroed, every authenticated connection is dropped, and the node
  // announces itself for pairing again so it can be added to another cluster without a restart.
  void unpair() {
    token = Token{};
    for (auto& kv : invites_) {
      if (kv.second->timer) loop.cancel(kv.second->timer);
      kv.second->finished = true;
    }
    invites_.clear();
    pending_.clear();
    denied_.clear();
    pairing_mode_until_ = 0;
    auto_added_count_ = 0;
    is_founder_ = false;
    notifyToken();
    st.psk.fill(0);
    st.seed_peers.clear();
    if (join) abortJoin("unpaired");

    for (auto& kv : chans) {
      kv.second->setCallbacks({});
      kv.second->close();
    }
    chans.clear();
    for (auto& ch : pending) {
      ch->setCallbacks({});
      ch->close();
    }
    pending.clear();
    for (auto& ib : inbound) {
      ib->conn->setCallbacks([](const Bytes&) {}, [] {});
      ib->conn->close();
    }
    inbound.clear();
    for (auto it = peers.begin(); it != peers.end();) {
      it = it->first == st.node_id ? std::next(it) : peers.erase(it);
    }
    known_addrs.clear();
    addr_owner.clear();
    dialing.clear();

    if (disc) {
      disc->setPsk(st.psk);
      disc->setPairFound(nullptr);
      startPairAnnounce();
    }
    if (cbs.on_peers_changed) cbs.on_peers_changed();
    if (cbs.on_pending_changed) cbs.on_pending_changed();
    if (cbs.on_unpaired) cbs.on_unpaired();
  }

  void joinCluster(const std::string& host_addr, const std::string& pin,
                   std::function<void(bool, const std::string&)> done) {
    if (isPaired()) {
      loop.post([done] { done(false, "already_paired"); });
      return;
    }
    if (join) {
      loop.post([done] { done(false, "join_in_progress"); });
      return;
    }
    auto j = std::make_shared<JoinRun>();
    j->pin = pin;
    j->done = std::move(done);
    join = j;
    std::weak_ptr<char> wt = alive;
    j->timeout_id = loop.postDelayed(st.claim_ttl_ms, [this, wt, j] {
      if (wt.expired()) return;
      j->timeout_id = 0;
      finishJoin(j, false, "timeout");
    });
    std::weak_ptr<char> w = alive;
    tp.connect(host_addr, [this, w, j, host_addr](ConnPtr conn) {
      if (w.expired()) {
        if (conn) conn->close();
        return;
      }
      if (j->finished) {
        if (conn) conn->close();
        return;
      }
      if (!conn) {
        finishJoin(j, false, "connect_failed");
        return;
      }
      j->conn = conn;
      rememberAddr(host_addr, "");
      conn->setCallbacks(
          [this, w, j](const Bytes& f) {
            if (!w.expired()) handleJoinClientFrame(j, f);
          },
          [this, w, j] {
            if (!w.expired()) finishJoin(j, false, "closed");
          });
      auto o = json::obj();
      json::set(o.get(), "t", "JOIN_REQ1");
      json::set(o.get(), "id", st.node_id);
      sendJoinFrame(conn, o.get());
    });
  }

  void handleJoinClientFrame(std::shared_ptr<JoinRun> j, const Bytes& f) {
    if (j->finished || f.empty() || f[0] != kFrameJoin) return;
    json::Doc doc = json::parse(std::string(f.begin() + 1, f.end()));
    if (!doc) return;
    const std::string t = json::getString(doc.get(), "t");
    if (t == "JOIN_CHALLENGE") {
      Bytes challenge, salt;
      if (!hexDecode(json::getString(doc.get(), "challenge"), challenge) ||
          !hexDecode(json::getString(doc.get(), "salt"), salt)) {
        finishJoin(j, false, "bad_challenge");
        return;
      }
      j->k = joinKey(j->pin, salt);
      j->key_ready = true;
      const auto proof = joinProof(j->k, challenge, st.node_id);
      auto o = json::obj();
      json::set(o.get(), "t", "JOIN_PROOF");
      json::set(o.get(), "id", st.node_id);
      json::set(o.get(), "hmac", hexEncode(proof.data(), proof.size()));
      sendJoinFrame(j->conn, o.get());
    } else if (t == "JOIN_OK") {
      // An invitation may have paired this node while the code join was in flight. Applying a
      // second cluster key here would emit a duplicate paired event and drop the live one.
      if (isPaired()) {
        finishJoin(j, false, "already_paired");
        return;
      }
      Bytes nonce, enc;
      if (!j->key_ready || !hexDecode(json::getString(doc.get(), "n"), nonce) ||
          !hexDecode(json::getString(doc.get(), "c"), enc) || nonce.size() != 24 ||
          enc.size() < 16) {
        finishJoin(j, false, "bad_payload");
        return;
      }
      Bytes plain(enc.size() - 16);
      if (crypto_aead_unlock(plain.data(), enc.data(), j->k.data(), nonce.data(), nullptr, 0,
                             enc.data() + 16, plain.size()) != 0) {
        finishJoin(j, false, "decrypt_failed");
        return;
      }
      json::Doc payload = json::parse(std::string(plain.begin(), plain.end()));
      if (!payload) {
        finishJoin(j, false, "bad_payload");
        return;
      }
      std::string err = "bad_payload";
      if (!applyJoinPayload(payload.get(), &err)) {
        finishJoin(j, false, err);
        return;
      }
      finishJoin(j, true, "", /*inline_done=*/true);
      onBecamePaired();
    } else if (t == "JOIN_ERR") {
      finishJoin(j, false, json::getString(doc.get(), "err", "error"));
    }
  }
};



Mesh::Mesh(Runloop& loop, IClock& clock, HlcClock& hlc, ITransport& transport,
           IDiscovery* discovery, Store& store, LwwMap& config, EventLog& events,
           MeshSettings settings, Callbacks cbs)
    : settings_(std::move(settings)),
      impl_(new Impl(loop, clock, hlc, transport, discovery, store, config, events, settings_,
                     std::move(cbs))) {
  std::string projected;
  settings_.runtime_json = projectMeshRuntimeJson(settings_.runtime_json, &projected)
      ? std::move(projected) : "{}";
}

Mesh::~Mesh() { impl_->stop(); }

void Mesh::start() { impl_->start(); }
void Mesh::stop() { impl_->stop(); }

std::vector<PeerInfo> Mesh::peers() const {
  std::vector<PeerInfo> out;
  out.reserve(impl_->peers.size());
  for (const auto& kv : impl_->peers) out.push_back(kv.second.info);
  return out;
}

std::string Mesh::leaderFor(const std::string& duty) const {
  auto it = impl_->duties.find(duty);
  return it == impl_->duties.end() ? "" : it->second.leader;
}

bool Mesh::isLeader(const std::string& duty) const { return leaderFor(duty) == settings_.node_id; }

void Mesh::setCaps(const std::string& caps_json) {
  settings_.caps_json = caps_json;
  auto it = impl_->peers.find(settings_.node_id);
  if (it != impl_->peers.end()) it->second.info.caps_json = caps_json;
  if (impl_->running) {
    impl_->gossipAll();
    impl_->leaderTick();
  }
}

void Mesh::setUiManifest(const std::string& manifest_json) {
  settings_.ui_manifest_json = manifest_json;
  auto it = impl_->peers.find(settings_.node_id);
  if (it != impl_->peers.end()) it->second.info.ui_manifest_json = manifest_json;
  if (impl_->running) impl_->gossipAll();
}

void Mesh::setRuntime(const std::string& runtime_json) {
  std::string projected;
  if (!projectMeshRuntimeJson(runtime_json, &projected)) return;
  settings_.runtime_json = projected;
  auto it = impl_->peers.find(settings_.node_id);
  if (it != impl_->peers.end()) it->second.info.runtime_json = std::move(projected);
  if (impl_->running) impl_->gossipAll();
}

void Mesh::broadcastEvent(const EventRecord& ev) { impl_->broadcastEvent(ev); }

void Mesh::pushConfigDelta(const std::vector<LwwEntry>& entries) {
  impl_->pushConfigDelta(entries);
}

void Mesh::sendCommand(const std::string& node_id, const std::string& cmd_json) {
  impl_->sendCommand(node_id, cmd_json);
}

void Mesh::broadcastCommand(const std::string& cmd_json) { impl_->broadcastCommand(cmd_json); }

void Mesh::setSnapshotProvider(std::function<Bytes()> provider) {
  impl_->snap_provider = std::move(provider);
}

void Mesh::fetchSnapshot(const std::string& node_id, std::function<void(Bytes)> cb) {
  impl_->fetchSnapshot(node_id, std::move(cb));
}

void Mesh::setBlobProvider(std::function<Bytes(const std::string&)> provider) {
  impl_->blob_provider = std::move(provider);
}

void Mesh::fetchBlob(const std::string& hash, std::function<void(Bytes)> cb) {
  impl_->fetchBlob(hash, std::move(cb));
}

Mesh::JoinToken Mesh::createJoinToken(int64_t ttl_ms) {
  if (!impl_->isPaired()) return JoinToken{};
  int64_t lifetime = ttl_ms > 0 ? ttl_ms : kJoinTokenTtlMs;
  lifetime = std::max<int64_t>(30'000, std::min<int64_t>(lifetime, kJoinTokenTtlMs));
  impl_->token.pin = genPin6();
  impl_->token.expires_mono = impl_->now() + lifetime;
  impl_->token.fails = 0;
  impl_->token.active = true;
  impl_->token.expired_unreported = false;
  impl_->notifyToken();
  JoinToken t;
  t.pin = impl_->token.pin;
  t.expires_mono = impl_->token.expires_mono;
  return t;
}

bool Mesh::isPaired() const { return impl_->isPaired(); }
bool Mesh::foundCluster() { return impl_->foundCluster(); }
bool Mesh::isFounder() const { return impl_->is_founder_; }
std::string Mesh::pairingSelfJson() { return impl_->pairingSelfJson(); }
std::string Mesh::pendingJson() { return impl_->pendingJson(); }
std::string Mesh::tokenJson() { return impl_->tokenJson(); }
void Mesh::inviteDevice(const std::string& id) { impl_->inviteDevice(id, /*manual=*/true); }
void Mesh::inviteDeviceDirect(const std::string& addr, const std::string& pk) {
  impl_->inviteDeviceDirect(addr, pk);
}
void Mesh::denyDevice(const std::string& id) { impl_->denyDevice(id); }
void Mesh::setPairingMode(int64_t ttl_ms) { impl_->setPairingMode(ttl_ms); }
void Mesh::unpair() { impl_->unpair(); }

void Mesh::joinCluster(const std::string& host_addr, const std::string& pin,
                       std::function<void(bool, const std::string&)> done) {
  impl_->joinCluster(host_addr, pin, std::move(done));
}

}  // namespace db
