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
static_assert(sizeof(db_platform_v2) == 2 * sizeof(std::uint32_t) + 8 * sizeof(void*),
              "db_platform_v2 size changed");

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
  if (!allow_stub && std::strcmp(backend, "pjsip") != 0) {
    std::cerr << "release gate: expected pjsip, got " << backend << "\n";
    return 4;
  }
  std::cout << "platform_v2_size=" << sizeof(db_platform_v2)
            << " pointer_size=" << sizeof(void*) << " sip_backend=" << backend << "\n";
  return 0;
}
