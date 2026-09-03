#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>

#include "doctest.h"
#include "doorbell/doorbell.h"

TEST_CASE("capi: legacy platform layout remains six pointers") {
  CHECK(sizeof(db_platform) == 6 * sizeof(void*));
  CHECK(offsetof(db_platform, tts_speak) == 5 * sizeof(void*));
}

TEST_CASE("capi: v2 platform rejects truncated and unknown layouts") {
  db_platform_v2 platform{};
  platform.struct_size = sizeof(platform) - 1;
  platform.version = DB_PLATFORM_V2_VERSION;
  CHECK(db_core_create_v2(&platform, ":memory:", "{\"http_port\":0}") == nullptr);

  platform.struct_size = sizeof(platform);
  platform.version = DB_PLATFORM_V2_VERSION + 1;
  CHECK(db_core_create_v2(&platform, ":memory:", "{\"http_port\":0}") == nullptr);
}

TEST_CASE("capi: a v2 shell built before secure_delete still starts") {
  // secure_delete は末尾に追加しただけなので、追加前のサイズを名乗る既存シェルは
  // 再ビルドせずにそのまま動く。追加後のフィールドは NULL 扱いになる。
  const size_t base_size = offsetof(db_platform_v2, secure_delete);
  CHECK(base_size < sizeof(db_platform_v2));
  db_platform_v2 platform{};
  platform.struct_size = static_cast<uint32_t>(base_size);
  platform.version = DB_PLATFORM_V2_VERSION;
  db_core* core = db_core_create_v2(&platform, ":memory:", "{\"http_port\":0}");
  REQUIRE(core != nullptr);
  db_core_destroy(core);

  // 未公開の中間サイズは受け付けない。
  platform.struct_size = static_cast<uint32_t>(base_size + 1);
  CHECK(db_core_create_v2(&platform, ":memory:", "{\"http_port\":0}") == nullptr);
}

TEST_CASE("capi: a v2 shell built before power_state still starts") {
  // power_state was appended after secure_delete, so both earlier published sizes remain valid
  // and a shell that declares one of them keeps working with the newer field left NULL.
  const size_t before_secure_delete = offsetof(db_platform_v2, secure_delete);
  const size_t before_power_state = offsetof(db_platform_v2, power_state);
  CHECK(before_secure_delete < before_power_state);
  CHECK(before_power_state < sizeof(db_platform_v2));

  for (size_t size : {before_secure_delete, before_power_state, sizeof(db_platform_v2)}) {
    db_platform_v2 platform{};
    platform.struct_size = static_cast<uint32_t>(size);
    platform.version = DB_PLATFORM_V2_VERSION;
    db_core* core = db_core_create_v2(&platform, ":memory:", "{\"http_port\":0}");
    CAPTURE(size);
    REQUIRE(core != nullptr);
    db_core_destroy(core);
  }

  // Unpublished intermediate sizes stay rejected.
  db_platform_v2 platform{};
  platform.version = DB_PLATFORM_V2_VERSION;
  platform.struct_size = static_cast<uint32_t>(before_power_state + 1);
  CHECK(db_core_create_v2(&platform, ":memory:", "{\"http_port\":0}") == nullptr);
  platform.struct_size = static_cast<uint32_t>(before_power_state - 1);
  CHECK(db_core_create_v2(&platform, ":memory:", "{\"http_port\":0}") == nullptr);
}

TEST_CASE("capi: the power SPI feeds status and the settings entry points fail closed") {
  struct Context {
    int reads = 0;
    int releases = 0;
  } context;
  db_platform_v2 platform{};
  platform.struct_size = sizeof(platform);
  platform.version = DB_PLATFORM_V2_VERSION;
  platform.user = &context;
  platform.power_state = [](void* user, char** value) -> int {
    auto* context = static_cast<Context*>(user);
    ++context->reads;
    const char json[] = "{\"battery_pct\":64,\"charging\":true,\"mains\":true}";
    *value = static_cast<char*>(std::malloc(sizeof(json)));
    if (!*value) return -1;
    std::memcpy(*value, json, sizeof(json));
    return 0;
  };
  platform.release_buffer = [](void* user, void* value) {
    ++static_cast<Context*>(user)->releases;
    std::free(value);
  };

  // Every additive entry point tolerates a null handle.
  CHECK(db_core_local_time_json(nullptr, 0) == nullptr);
  CHECK(db_core_audio_json(nullptr, nullptr) == nullptr);
  CHECK(db_core_time_sync_now(nullptr) == 0);
  CHECK(db_core_set_door_notice(nullptr, "d_front", "hi", 0) < 0);
  CHECK(db_core_clear_door_notice(nullptr, "d_front") < 0);

  db_core* core = db_core_create_v2(
      &platform, ":memory:",
      "{\"name\":\"power-capi\",\"role\":\"indoor_panel\",\"listen_port\":0,\"http_port\":0}");
  REQUIRE(core != nullptr);
  REQUIRE(db_core_start(core) == 0);

  char* status = db_core_status_json(core);
  REQUIRE(status != nullptr);
  const std::string status_json = status;
  db_free(status);
  CHECK(status_json.find("\"battery_pct\":64") != std::string::npos);
  CHECK(status_json.find("\"charging\":true") != std::string::npos);

  char* local = db_core_local_time_json(core, 1'772'000'000'000LL);
  REQUIRE(local != nullptr);
  const std::string local_json = local;
  db_free(local);
  CHECK(local_json.find("\"tz\":\"Asia/Tokyo\"") != std::string::npos);
  CHECK(local_json.find("\"offset_min\":540") != std::string::npos);

  char* audio = db_core_audio_json(core, nullptr);
  REQUIRE(audio != nullptr);
  const std::string audio_json = audio;
  db_free(audio);
  CHECK(audio_json.find("\"call\":80") != std::string::npos);
  CHECK(audio_json.find("\"sos\":100") != std::string::npos);
  CHECK(audio_json.find("\"idle\":60") != std::string::npos);

  // NTP is off by default, so an explicit sync request reports that it did not start.
  CHECK(db_core_time_sync_now(core) == 0);
  // Announcements need a configured door; arguments are checked before any state is touched.
  CHECK(db_core_set_door_notice(core, "", "hi", 0) < 0);
  CHECK(db_core_set_door_notice(core, "d_missing", "hi", 0) < 0);

  db_core_stop(core);
  db_core_destroy(core);
  CHECK(context.reads >= 1);
  CHECK(context.releases == context.reads);
}

TEST_CASE("capi: legacy and v2 constructors accept their declared layouts") {
  db_platform legacy{};
  db_core* old_core = db_core_create(&legacy, ":memory:", "{\"http_port\":0}");
  REQUIRE(old_core != nullptr);
  db_core_destroy(old_core);

  db_platform_v2 platform{};
  platform.struct_size = sizeof(platform);
  platform.version = DB_PLATFORM_V2_VERSION;
  db_core* new_core = db_core_create_v2(&platform, ":memory:", "{\"http_port\":0}");
  REQUIRE(new_core != nullptr);
  db_core_destroy(new_core);
}

TEST_CASE("capi: call-history entry points fail closed on a null core") {
  // Both are additive exports; existing shells keep working and a null handle never traps.
  CHECK(db_core_call_log_json(nullptr, 0, 10) == nullptr);
  CHECK(db_core_call_log_mark_seen(nullptr, "") < 0);
  CHECK(db_core_call_log_mark_seen(nullptr, nullptr) < 0);

  db_platform_v2 platform{};
  platform.struct_size = sizeof(platform);
  platform.version = DB_PLATFORM_V2_VERSION;
  db_core* core = db_core_create_v2(&platform, ":memory:", "{\"http_port\":0}");
  REQUIRE(core != nullptr);
  // A core that was created but never started reports an empty history and refuses to move the
  // watermark instead of reaching into uninitialized state.
  char* history = db_core_call_log_json(core, 0, 10);
  REQUIRE(history != nullptr);
  const std::string json = history;
  db_free(history);
  CHECK(json.find("\"rows\":[]") != std::string::npos);
  CHECK(json.find("\"unread_missed\":0") != std::string::npos);
  CHECK(db_core_call_log_mark_seen(core, nullptr) < 0);
  db_core_destroy(core);
}

TEST_CASE("capi: SIP backend identity is explicit") {
  const std::string backend = db_core_sip_backend();
  CHECK((backend == "pjsip" || backend == "stub"));
}

TEST_CASE("capi: video keyframe request polling fails closed on a null core") {
  CHECK(db_core_take_video_keyframe_request(nullptr) == 0);
}

TEST_CASE("capi: quick reply v2 carries exact call scope") {
  using QuickReplyV2 = int (*)(db_core*, const char*, const char*, const char*, int);
  QuickReplyV2 quick_reply = &db_core_quick_reply_v2;
  CHECK(quick_reply(nullptr, "qr_away", "d_front", "call-id", 0) == -1);
}

TEST_CASE("capi: quick reply v2 rejects stale scope and accepts the active revision") {
  db_platform_v2 platform{};
  platform.struct_size = sizeof(platform);
  platform.version = DB_PLATFORM_V2_VERSION;
  db_core* core = db_core_create_v2(
      &platform, ":memory:",
      "{\"name\":\"capi-reply\",\"role\":\"door_station\","
      "\"door\":\"d_front\",\"listen_port\":0,\"http_port\":0}");
  REQUIRE(core != nullptr);
  REQUIRE(db_core_start(core) == 0);
  char* call_id = db_core_press_v2(core, "d_front", "");
  REQUIRE(call_id != nullptr);
  CHECK(db_core_quick_reply_v2(core, "qr_away", "d_front", "stale-call", 0) == -2);
  CHECK(db_core_quick_reply_v2(core, "qr_away", "d_front", call_id, 1) == -2);
  CHECK(db_core_quick_reply_v2(core, "qr_away", "d_front", call_id, 0) == 0);
  CHECK(db_core_quick_reply_v2(core, "qr_away", "d_front", call_id, 0) == -2);
  db_free(call_id);
  db_core_stop(core);
  db_core_destroy(core);
}

TEST_CASE("capi: shell call lifecycle requires an exact call and stage") {
  db_platform_v2 platform{};
  platform.struct_size = sizeof(platform);
  platform.version = DB_PLATFORM_V2_VERSION;
  db_core* core = db_core_create_v2(
      &platform, ":memory:",
      "{\"name\":\"capi-lifecycle\",\"role\":\"door_station\","
      "\"door\":\"d_front\",\"listen_port\":0,\"http_port\":0}");
  REQUIRE(core != nullptr);
  REQUIRE(db_core_start(core) == 0);
  CHECK(db_core_emergency_v2(core, 1) == 1);
  CHECK(db_core_emergency_v2(core, 0) == 1);
  char* call_id = db_core_press_v2(core, "d_front", "");
  REQUIRE(call_id != nullptr);
  CHECK(std::strlen(call_id) == 32);
  CHECK(db_core_report_call_answered_v2(core, "d_front", call_id, 1) == -2);
  CHECK(db_core_report_call_answered_v2(core, "d_front", call_id, 0) == 0);
  CHECK(db_core_cancel_call_v2(core, "d_front", call_id, "visitor") == -2);
  CHECK(db_core_report_call_ended_v2(core, "d_front", call_id, 0, "sip_ended") == 0);
  CHECK(db_core_report_call_ended_v2(core, "d_front", call_id, 0, "sip_ended") == 0);
  db_free(call_id);
  db_core_stop(core);
  db_core_destroy(core);
}

TEST_CASE("capi: mesh PSK can be resolved through a secret reference") {
  db_platform_v2 platform{};
  platform.struct_size = sizeof(platform);
  platform.version = DB_PLATFORM_V2_VERSION;
  platform.secure_get = [](void*, const char* key, char** value) -> int {
    if (!key || std::strcmp(key, "mesh.psk") != 0 || !value) return -1;
    *value = static_cast<char*>(std::malloc(65));
    if (!*value) return -1;
    std::memset(*value, '0', 64);
    (*value)[64] = '\0';
    return 0;
  };
  platform.release_buffer = [](void*, void* value) { std::free(value); };
  db_core* core = db_core_create_v2(
      &platform, ":memory:",
      "{\"http_port\":0,\"psk_ref\":\"secret:mesh.psk\"}");
  REQUIRE(core != nullptr);
  db_core_destroy(core);
}

TEST_CASE("capi: v2 device info is sampled when the runtime monitor starts") {
  struct Context {
    int reads = 0;
    int releases = 0;
  } context;
  db_platform_v2 platform{};
  platform.struct_size = sizeof(platform);
  platform.version = DB_PLATFORM_V2_VERSION;
  platform.user = &context;
  platform.device_info = [](void* user, char** value) -> int {
    auto* context = static_cast<Context*>(user);
    ++context->reads;
    const char json[] = "{\"gateway\":\"192.0.2.1\",\"battery\":{\"level\":0.5}}";
    *value = static_cast<char*>(std::malloc(sizeof(json)));
    if (!*value) return -1;
    std::memcpy(*value, json, sizeof(json));
    return 0;
  };
  platform.release_buffer = [](void* user, void* value) {
    ++static_cast<Context*>(user)->releases;
    std::free(value);
  };
  db_core* core = db_core_create_v2(
      &platform, ":memory:",
      "{\"name\":\"device-info-test\",\"listen_port\":0,\"http_port\":0}"
  );
  REQUIRE(core != nullptr);
  REQUIRE(db_core_start(core) == 0);
  char* debug = db_core_debug_json(core);
  REQUIRE(debug != nullptr);
  CHECK(std::string(debug).find("192.0.2.1") != std::string::npos);
  db_free(debug);
  db_core_stop(core);
  db_core_destroy(core);
  CHECK(context.reads >= 1);
  CHECK(context.releases == context.reads);
}

TEST_CASE("capi: native config writes match the HTTP endpoints, warnings included") {
  db_platform_v2 platform{};
  platform.struct_size = sizeof(platform);
  platform.version = DB_PLATFORM_V2_VERSION;
  db_core* core = db_core_create_v2(
      &platform, ":memory:",
      "{\"name\":\"config-abi\",\"role\":\"indoor_panel\",\"listen_port\":0,\"http_port\":0}");
  REQUIRE(core != nullptr);
  REQUIRE(db_core_start(core) == 0);

  // Null handles never trap; every one of these is an additive export.
  CHECK(db_core_set_config_json(nullptr, "a", "1") < 0);
  CHECK(db_core_config_batch_json(nullptr, "[]") == nullptr);
  CHECK(db_core_delete_config_key(nullptr, "a") < 0);
  CHECK(db_core_last_write_warnings_json(nullptr) == nullptr);
  CHECK(db_core_set_config_json(core, "", "1") < 0);
  CHECK(db_core_set_config_json(core, "audio.volume.call", nullptr) < 0);

  CHECK(db_core_set_config_json(core, "audio.volume.call", "42") == 0);
  char* config = db_core_config_json(core);
  REQUIRE(config != nullptr);
  CHECK(std::string(config).find("\"call\":42") != std::string::npos);
  db_free(config);
  // Core's validation applies exactly as it does over HTTP.
  CHECK(db_core_set_config_json(core, "audio.volume.call", "900") < 0);
  CHECK(db_core_set_config_json(core, "time.zone", "\"Mars/Olympus\"") < 0);
  CHECK(db_core_set_config_json(core, "time.zone", "\"Europe/Paris\"") == 0);

  // A colour that falls short of AA saves and reports the ratio instead of failing.
  CHECK(db_core_set_config_json(core, "display.theme.bg_color", "\"#FFFFFF\"") == 0);
  CHECK(db_core_set_config_json(core, "display.theme.call_button_bg", "\"#FEFEFE\"") == 0);
  char* warnings = db_core_last_write_warnings_json(core);
  REQUIRE(warnings != nullptr);
  const std::string warning_json = warnings;
  db_free(warnings);
  CHECK(warning_json.find("theme.low_contrast") != std::string::npos);
  CHECK(warning_json.find("call_button_bg") != std::string::npos);

  // The batch form takes the same document as POST /api/config/batch and returns its result.
  char* batch = db_core_config_batch_json(
      core,
      "{\"ops\":[{\"op\":\"set\",\"key\":\"audio.volume.sos\",\"value\":10},"
      "{\"op\":\"set\",\"key\":\"audio.volume.idle\",\"value\":20}]}");
  REQUIRE(batch != nullptr);
  const std::string batch_json = batch;
  db_free(batch);
  CHECK(batch_json.find("\"ok\":true") != std::string::npos);
  CHECK(batch_json.find("\"n\":2") != std::string::npos);
  CHECK(batch_json.find("\"revision\"") != std::string::npos);

  // A bare array is accepted too, so a shell need not wrap it.
  char* bare = db_core_config_batch_json(
      core, "[{\"op\":\"set\",\"key\":\"audio.volume.idle\",\"value\":30}]");
  REQUIRE(bare != nullptr);
  CHECK(std::string(bare).find("\"ok\":true") != std::string::npos);
  db_free(bare);

  // Nothing is written unless every operation validates.
  char* rejected = db_core_config_batch_json(
      core,
      "{\"ops\":[{\"op\":\"set\",\"key\":\"audio.volume.sos\",\"value\":11},"
      "{\"op\":\"set\",\"key\":\"audio.volume.idle\",\"value\":900}]}");
  REQUIRE(rejected != nullptr);
  CHECK(std::string(rejected).find("\"ok\":false") != std::string::npos);
  db_free(rejected);
  config = db_core_config_json(core);
  REQUIRE(config != nullptr);
  CHECK(std::string(config).find("\"sos\":10") != std::string::npos);
  db_free(config);

  CHECK(db_core_delete_config_key(core, "audio.volume.idle") == 0);
  config = db_core_config_json(core);
  REQUIRE(config != nullptr);
  CHECK(std::string(config).find("\"idle\"") == std::string::npos);
  db_free(config);

  db_core_stop(core);
  db_core_destroy(core);
}

TEST_CASE("capi: one cluster administrator password, shared lockout, SOS never blocked") {
  db_platform_v2 platform{};
  platform.struct_size = sizeof(platform);
  platform.version = DB_PLATFORM_V2_VERSION;
  db_core* core = db_core_create_v2(
      &platform, ":memory:",
      "{\"name\":\"admin-pw\",\"role\":\"indoor_panel\",\"listen_port\":0,\"http_port\":0}");
  REQUIRE(core != nullptr);
  REQUIRE(db_core_start(core) == 0);

  CHECK(db_core_admin_password_verify(nullptr, "x") == -3);
  CHECK(db_core_admin_password_verify(core, nullptr) == -3);
  // Nothing set yet: the caller is told so rather than being told "wrong".
  CHECK(db_core_admin_password_verify(core, "anything") == -2);

  auto emergency = [core]() {
    char* raw = db_core_status_json(core);
    REQUIRE(raw != nullptr);
    const std::string status = raw;
    db_free(raw);
    return status;
  };
  // With no password, clearing a running alarm must not be gated on one.
  CHECK(emergency().find("\"cancel_requires_password\":false") != std::string::npos);
  CHECK(emergency().find("\"admin_password_set\":false") != std::string::npos);

  // Trust on first use: an empty current is accepted only while the cluster has no password.
  CHECK(db_core_admin_password_set(core, "", "abc") == -1);  // too short
  CHECK(db_core_admin_password_set(core, "", "first-password") == 0);
  CHECK(db_core_admin_password_verify(core, "first-password") > 0);
  CHECK(db_core_admin_password_verify(core, "wrong") == 0);
  CHECK(db_core_admin_password_set(core, "", "second") == -2);
  CHECK(db_core_admin_password_set(core, "wrong", "second") == -2);

  // The digest is replicated, never the plaintext.
  char* config = db_core_config_json(core);
  REQUIRE(config != nullptr);
  const std::string config_json = config;
  db_free(config);
  CHECK(config_json.find("admin") != std::string::npos);
  CHECK(config_json.find("password_hash") != std::string::npos);
  CHECK(config_json.find("first-password") == std::string::npos);

  // Now that a password exists, the configured SOS policy applies.
  CHECK(emergency().find("\"admin_password_set\":true") != std::string::npos);
  CHECK(emergency().find("\"cancel_requires_password\":true") != std::string::npos);
  CHECK(db_core_set_config_json(core, "emergency.cancel_requires_pin", "false") == 0);
  CHECK(emergency().find("\"cancel_requires_password\":false") != std::string::npos);

  CHECK(db_core_admin_password_set(core, "first-password", "second-password") == 0);
  CHECK(db_core_admin_password_verify(core, "second-password") > 0);
  CHECK(db_core_admin_password_verify(core, "first-password") == 0);

  // Repeated failures pause every surface. The counter is shared across call sites, so the
  // earlier wrong guesses in this test count toward it too.
  bool locked = false;
  for (int attempt = 0; attempt < 5 && !locked; attempt++)
    locked = db_core_admin_password_verify(core, "nope") == -1;
  CHECK(locked);
  // The lockout refuses the correct password too; otherwise it would not be a lockout.
  CHECK(db_core_admin_password_verify(core, "second-password") == -1);
  CHECK(db_core_admin_password_set(core, "second-password", "third-password") == -3);

  db_core_stop(core);
  db_core_destroy(core);
}

TEST_CASE("capi: mic mute, call-log paging, and the bundled zone list") {
  db_platform_v2 platform{};
  platform.struct_size = sizeof(platform);
  platform.version = DB_PLATFORM_V2_VERSION;
  db_core* core = db_core_create_v2(
      &platform, ":memory:",
      "{\"name\":\"round7\",\"role\":\"indoor_panel\",\"listen_port\":0,\"http_port\":0}");
  REQUIRE(core != nullptr);
  REQUIRE(db_core_start(core) == 0);

  auto status = [core]() {
    char* raw = db_core_status_json(core);
    REQUIRE(raw != nullptr);
    const std::string out = raw;
    db_free(raw);
    return out;
  };

  CHECK(db_core_sip_set_mic_muted(nullptr, 1) < 0);
  CHECK(status().find("\"mic_muted\":false") != std::string::npos);
  CHECK(db_core_sip_set_mic_muted(core, 1) == 0);
  CHECK(status().find("\"mic_muted\":true") != std::string::npos);
  CHECK(db_core_sip_set_mic_muted(core, 0) == 0);
  CHECK(status().find("\"mic_muted\":false") != std::string::npos);

  // The paging variant answers the same shape and tolerates a null handle.
  CHECK(db_core_call_log_json_v2(nullptr, 0, 0, 10) == nullptr);
  char* page = db_core_call_log_json_v2(core, 0, 0, 10);
  REQUIRE(page != nullptr);
  const std::string page_json = page;
  db_free(page);
  CHECK(page_json.find("\"rows\":[]") != std::string::npos);
  CHECK(page_json.find("\"unread_missed\":0") != std::string::npos);
  char* older = db_core_call_log_json_v2(core, 0, 1'700'000'000'000LL, 10);
  REQUIRE(older != nullptr);
  CHECK(std::string(older).find("\"rows\":[]") != std::string::npos);
  db_free(older);

  // A native picker builds its zone list from what core can actually resolve.
  const std::string zones = status();
  CHECK(zones.find("\"zones\"") != std::string::npos);
  CHECK(zones.find("\"Asia/Tokyo\"") != std::string::npos);
  CHECK(zones.find("\"Europe/Berlin\"") != std::string::npos);
  CHECK(zones.find("\"America/New_York\"") != std::string::npos);

  db_core_stop(core);
  db_core_destroy(core);
}
