// Monotonic milliseconds for mbedTLS on Apple targets, including iOS 5.1, whose SDK lacks
// clock_gettime(). Selected by MBEDTLS_PLATFORM_MS_TIME_ALT in mbedtls_user_config.h.
#if defined(__APPLE__)
#include <mach/mach_time.h>

#include "mbedtls/platform_time.h"

mbedtls_ms_time_t mbedtls_ms_time(void) {
  static mach_timebase_info_data_t timebase;
  if (timebase.denom == 0) mach_timebase_info(&timebase);
  const uint64_t ticks = mach_absolute_time();
  const uint64_t ns = ticks / timebase.denom * timebase.numer +
                      ticks % timebase.denom * timebase.numer / timebase.denom;
  return (mbedtls_ms_time_t)(ns / 1000000u);
}
#endif
