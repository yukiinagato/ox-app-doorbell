#import <Foundation/Foundation.h>

#define DB_IOS_COMPAT_PROFILE_TESTING 1
#define DB_IOS_COMPAT_OS_FLOOR 90000
#import "DBCompatibilityProfile.h"

static void require(BOOL condition, NSString *message) {
  if (!condition) {
    NSLog(@"FAIL: %@", message);
    exit(1);
  }
}

int main(void) {
  @autoreleasepool {
    require(DBCompatibilityLayoutForWidth(320.0) == DBCompatibilityLayoutCompact,
            @"320-point iPhone layout must be compact");
    require(DBCompatibilityLayoutForWidth(499.0) == DBCompatibilityLayoutCompact,
            @"the last sub-breakpoint width must be compact");
    require(DBCompatibilityLayoutForWidth(500.0) == DBCompatibilityLayoutRegular,
            @"the breakpoint itself must use the regular layout");
    require(DBCompatibilityLayoutForWidth(768.0) == DBCompatibilityLayoutRegular,
            @"classic iPad layout must be regular");
    puts("PASS: iOS compatibility layout profile");
  }
  return 0;
}
