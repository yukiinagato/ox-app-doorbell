// Doorbell overrides on top of the stock mbedTLS 3.6 configuration (MBEDTLS_USER_CONFIG_FILE).
// TLS 1.2 only: TLS 1.3 in 3.6 routes key exchange through PSA, whose global state is not
// thread-safe without MBEDTLS_THREADING_C, while CivetWeb handshakes run on many workers.
#pragma once

#undef MBEDTLS_SSL_PROTO_TLS1_3
#undef MBEDTLS_SSL_TLS1_3_COMPATIBILITY_MODE
#undef MBEDTLS_SSL_TLS1_3_KEY_EXCHANGE_MODE_PSK_ENABLED
#undef MBEDTLS_SSL_TLS1_3_KEY_EXCHANGE_MODE_EPHEMERAL_ENABLED
#undef MBEDTLS_SSL_TLS1_3_KEY_EXCHANGE_MODE_PSK_EPHEMERAL_ENABLED

#undef MBEDTLS_SSL_PROTO_DTLS
#undef MBEDTLS_SSL_DTLS_ANTI_REPLAY
#undef MBEDTLS_SSL_DTLS_HELLO_VERIFY
#undef MBEDTLS_SSL_DTLS_CLIENT_PORT_REUSE
#undef MBEDTLS_SSL_DTLS_CONNECTION_ID
#undef MBEDTLS_SSL_COOKIE_C

#undef MBEDTLS_SSL_SESSION_TICKETS
#undef MBEDTLS_SSL_TICKET_C

// No persistent PSA keys and no filesystem key store.
#undef MBEDTLS_PSA_CRYPTO_STORAGE_C
#undef MBEDTLS_PSA_ITS_FILE_C

// GCC-only x86 inline assembly; unused and fragile on old MinGW.
#undef MBEDTLS_PADLOCK_C
#undef MBEDTLS_TIMING_C

// The iOS 5.1 SDK has no clock_gettime(); every Apple target uses mach_absolute_time() instead
// (core/src/tls/mbedtls_ms_time_apple.c).
#if defined(__APPLE__)
#define MBEDTLS_PLATFORM_MS_TIME_ALT
#endif
