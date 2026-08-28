// -----------------------------------------------------------------------------
// Shim for <System/pthread_machdep.h>
//
// The extracted iOS 7.1 SDK does not ship Apple's private
// <System/pthread_machdep.h>. armv7-apple-ios uses SjLj C++ exceptions
// (__gxx_personality_sj0), and libunwind's Unwind-sjlj.c keeps the per-thread
// "function context" stack in a fast, fixed-index pthread TSD slot exposed by
// that header (_pthread_{get,set}specific_direct + __PTK_LIBC_DYLD_Unwind_SjLj_Key).
//
// We don't have those reserved direct slots, so we back the single key this
// translation unit ever touches with a normal, lazily-created pthread_key_t.
// This is fully self-consistent: the compiler emits calls to *our* statically
// linked _Unwind_SjLj_Register / _Unwind_SjLj_Unregister, which read/write the
// stack exclusively through these accessors. Nothing else shares the slot.
// -----------------------------------------------------------------------------
#ifndef _DB_SHIM_SYSTEM_PTHREAD_MACHDEP_H
#define _DB_SHIM_SYSTEM_PTHREAD_MACHDEP_H

#include <pthread.h>

// The real header defines this as a reserved fast-TSD slot index. Unwind-sjlj.c
// only uses it as an opaque handle passed straight back to the accessors below,
// so the concrete value is irrelevant here.
#ifndef __PTK_LIBC_DYLD_Unwind_SjLj_Key
#define __PTK_LIBC_DYLD_Unwind_SjLj_Key 0
#endif

static pthread_key_t   __db_sjlj_tsd_key;
static pthread_once_t  __db_sjlj_tsd_once = PTHREAD_ONCE_INIT;

static void __db_sjlj_tsd_make(void) {
  (void)pthread_key_create(&__db_sjlj_tsd_key, (void (*)(void *))0);
}

static __inline__ pthread_key_t __db_sjlj_tsd(void) {
  (void)pthread_once(&__db_sjlj_tsd_once, __db_sjlj_tsd_make);
  return __db_sjlj_tsd_key;
}

__attribute__((__unused__))
static __inline__ void *_pthread_getspecific_direct(unsigned long __slot) {
  (void)__slot;
  return pthread_getspecific(__db_sjlj_tsd());
}

__attribute__((__unused__))
static __inline__ int _pthread_setspecific_direct(unsigned long __slot,
                                                  void *__value) {
  (void)__slot;
  return pthread_setspecific(__db_sjlj_tsd(), __value);
}

#endif // _DB_SHIM_SYSTEM_PTHREAD_MACHDEP_H
