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
// Nine callbacks since secure_delete was appended. Fields are only ever appended, and the shell
// always reports sizeof(db_platform_v2) as struct_size.
static_assert(sizeof(db_platform_v2) == 2 * sizeof(std::uint32_t) + 9 * sizeof(void*),
              "db_platform_v2 size changed");
static_assert(offsetof(db_platform_v2, secure_delete) ==
                  2 * sizeof(std::uint32_t) + 8 * sizeof(void*),
              "secure_delete must stay the last field");

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
      "db_core_qr_scan_start",  "db_core_qr_scan_stop",       "db_core_on_camera_frame"};
  for (const char* name : kPairingExports) {
    if (!GetProcAddress(module, name)) {
      std::cerr << "required pairing export is missing: " << name << "\n";
      return 5;
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
