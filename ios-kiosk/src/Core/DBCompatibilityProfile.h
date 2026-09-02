#import <Foundation/Foundation.h>
#import <Availability.h>

#ifndef DB_IOS_COMPAT_OS_FLOOR
#define DB_IOS_COMPAT_OS_FLOOR 50100
#endif

#if DB_IOS_COMPAT_OS_FLOOR >= 90000 && !defined(DB_IOS_COMPAT_PROFILE_TESTING)
#if !defined(DB_IOS_COMPAT_CORE_PJSIP)
#error "The iOS 9 compatibility profile requires the Core/PJSIP adapter"
#endif
#if !defined(DB_IOS_COMPAT_PUBLIC_VIDEOTOOLBOX)
#error "The iOS 9 compatibility profile requires public VideoToolbox"
#endif
#if !defined(DB_IOS_COMPAT_DEVICE_FAMILY_PHONE) || \
    !defined(DB_IOS_COMPAT_DEVICE_FAMILY_IPAD)
#error "The iOS 9 compatibility profile must support both iPhone and iPad"
#endif
#if !defined(__arm__) || defined(__arm64__)
#error "The iOS 9 armv7 compatibility profile must compile as 32-bit ARM"
#endif
#if !defined(__IPHONE_OS_VERSION_MIN_REQUIRED) || \
    __IPHONE_OS_VERSION_MIN_REQUIRED != 90000
#error "The iOS 9 armv7 compatibility profile must use deployment target 9.0"
#endif
#endif

typedef enum {
  DBCompatibilityLayoutCompact = 0,
  DBCompatibilityLayoutRegular = 1
} DBCompatibilityLayoutClass;

static inline DBCompatibilityLayoutClass DBCompatibilityLayoutForWidth(CGFloat width) {
  return width < 500.0 ? DBCompatibilityLayoutCompact : DBCompatibilityLayoutRegular;
}

