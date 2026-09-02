#include <windows.h>

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <iostream>

#include <doorbell/doorbell.h>

static_assert(DB_PLATFORM_V2_VERSION == 2u, "unexpected platform ABI version");
static_assert(offsetof(db_platform_v2, struct_size) == 0, "struct_size must be first");
static_assert(offsetof(db_platform_v2, version) == sizeof(std::uint32_t),
              "version offset changed");
static_assert(offsetof(db_platform_v2, user) == 2 * sizeof(std::uint32_t),
              "pointer alignment/layout changed");
// Ten callbacks since power_state was appended after secure_delete. Fields are only ever
// appended, and the shell always reports sizeof(db_platform_v2) as struct_size.
static_assert(sizeof(db_platform_v2) == 2 * sizeof(std::uint32_t) + 10 * sizeof(void*),
              "db_platform_v2 size changed");
static_assert(offsetof(db_platform_v2, secure_delete) ==
                  2 * sizeof(std::uint32_t) + 8 * sizeof(void*),
              "secure_delete offset changed");
static_assert(offsetof(db_platform_v2, power_state) ==
                  2 * sizeof(std::uint32_t) + 9 * sizeof(void*),
              "power_state must stay the last field");

int main(int argc, char** argv) {
  const bool allow_stub = argc == 2 && std::strcmp(argv[1], "--allow-stub") == 0;
  const char* backend = db_core_sip_backend();
  if (!backend) {
    std::cerr << "db_core_sip_backend returned null\n";
    return 2;
  }
  HMODULE module = GetModuleHandleW(L"doorbell.dll");
  if (!module || !GetProcAddress(module, "db_core_create_v2") ||
      !GetProcAddress(module, "db_core_sip_backend") ||
      !GetProcAddress(module, "db_core_press_v2") ||
      !GetProcAddress(module, "db_core_cancel_call_v2")) {
    std::cerr << "required v2 exports are missing\n";
    return 3;
  }
  // Pairing and QR entry points the WPF shell binds through P/Invoke.
  static const char* kPairingExports[] = {
      "db_core_pairing_json",   "db_core_start_pairing_json", "db_core_invite_device",
      "db_core_invite_direct",  "db_core_deny_device",        "db_core_unpair",
      "db_core_retry_pairing_persistence", "db_core_qr_encode", "db_core_qr_decode",
      "db_core_qr_scan_start",  "db_core_qr_scan_stop",       "db_core_on_camera_frame",
      // Landed with the batch-2 core delta: a PIN never opens the bulk-add window (spec 5.4).
      "db_core_mint_join_token_json"};
  for (const char* name : kPairingExports) {
    if (!GetProcAddress(module, name)) {
      std::cerr << "required pairing export is missing: " << name << "\n";
      return 5;
    }
  }
  // Batch-2 shell surfaces (spec 5.1 to 5.5): the cluster clock, effective volumes,
  // announcements, call history and its before_ms paging, the one cluster-wide 管理パスワード,
  // native configuration writes with their advisory warnings, the door unlock action, and the
  // microphone toggle. The 全体 announcement needs no entry point of its own: core addresses it
  // as the door "*" through db_core_set_door_notice.
  static const char* kShellExports[] = {
      "db_core_local_time_json",         "db_core_time_sync_now",
      "db_core_audio_json",              "db_core_set_door_notice",
      "db_core_clear_door_notice",       "db_core_call_log_json",
      "db_core_call_log_json_v2",        "db_core_call_log_mark_seen",
      "db_core_emergency_v2",            "db_core_open_door",
      "db_core_admin_password_verify",   "db_core_admin_password_set",
      "db_core_set_config_json",         "db_core_last_write_warnings_json",
      "db_core_config_batch_json",       "db_core_delete_config_key",
      "db_core_sip_set_mic_muted"};
  for (const char* name : kShellExports) {
    if (!GetProcAddress(module, name)) {
      std::cerr << "required shell export is missing: " << name << "\n";
      return 6;
    }
  }
  if (!allow_stub && std::strcmp(backend, "pjsip") != 0) {
    std::cerr << "release gate: expected pjsip, got " << backend << "\n";
    return 4;
  }
  std::cout << "platform_v2_size=" << sizeof(db_platform_v2)
            << " pointer_size=" << sizeof(void*) << " sip_backend=" << backend << "\n";
  return 0;
}
