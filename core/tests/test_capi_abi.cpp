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

TEST_CASE("capi: SIP backend identity is explicit") {
  const std::string backend = db_core_sip_backend();
  CHECK((backend == "pjsip" || backend == "stub"));
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
