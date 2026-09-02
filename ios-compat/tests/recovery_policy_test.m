#import <Foundation/Foundation.h>

#import "DBRecoveryClient.h"

static void require(BOOL condition, NSString *message) {
  if (!condition) {
    NSLog(@"FAIL: %@", message);
    exit(1);
  }
}

int main(void) {
  @autoreleasepool {
    require([DBRecoveryClient isValidHelperMode:@"off"], @"off must be accepted");
    require([DBRecoveryClient isValidHelperMode:@"auto"], @"auto must be accepted");
    require([DBRecoveryClient isValidHelperMode:@"on"], @"on must be accepted");
    require(![DBRecoveryClient isValidHelperMode:@"AUTO"], @"mode is case-sensitive");
    require(![DBRecoveryClient isValidHelperMode:@"unknown"],
            @"unknown mode must be rejected");
    require([[DBRecoveryClient effectiveModeForConfiguredMode:@"auto"
                                        nativeKioskAvailable:YES
                                          nativeKioskHealthy:YES
                           consecutiveNativeKioskFailures:0] isEqualToString:@"off"],
            @"healthy native kiosk disables helper in auto mode");
    require([[DBRecoveryClient effectiveModeForConfiguredMode:@"auto"
                                        nativeKioskAvailable:YES
                                          nativeKioskHealthy:NO
                           consecutiveNativeKioskFailures:2] isEqualToString:@"off"],
            @"two unhealthy measurements keep the helper temporarily disarmed");
    require([[DBRecoveryClient effectiveModeForConfiguredMode:@"auto"
                                        nativeKioskAvailable:YES
                                          nativeKioskHealthy:NO
                           consecutiveNativeKioskFailures:3] isEqualToString:@"auto"],
            @"three unhealthy measurements enable the helper in auto mode");
    require([[DBRecoveryClient effectiveModeForConfiguredMode:@"auto"
                                        nativeKioskAvailable:NO
                                          nativeKioskHealthy:NO
                           consecutiveNativeKioskFailures:0] isEqualToString:@"auto"],
            @"unavailable native kiosk enables helper in auto mode");
    require([[DBRecoveryClient effectiveModeForConfiguredMode:@"on"
                                        nativeKioskAvailable:YES
                                          nativeKioskHealthy:YES
                           consecutiveNativeKioskFailures:0] isEqualToString:@"on"],
            @"on forces helper even when native kiosk is healthy");
    require([[DBRecoveryClient effectiveModeForConfiguredMode:@"invalid"
                                        nativeKioskAvailable:NO
                                          nativeKioskHealthy:NO
                           consecutiveNativeKioskFailures:3] isEqualToString:@"off"],
            @"invalid configuration fails closed");

    NSArray *updated = nil;
    require(![DBRecoveryClient shouldEnterSafeModeWithPreviousCleanExit:nil
        launches:@[] now:1000 updatedLaunches:&updated],
            @"first launch is not treated as a crash");
    require([updated count] == 0, @"first launch keeps an empty crash window");
    require([DBRecoveryClient shouldEnterSafeModeWithPreviousCleanExit:@NO
        launches:@[@700, @800] now:1000 updatedLaunches:&updated],
            @"three unexpected launches inside five minutes enter safe mode");
    require([updated count] == 3, @"crash-loop projection retains recent launches");
    require(![DBRecoveryClient shouldEnterSafeModeWithPreviousCleanExit:@YES
        launches:@[@100, @200, @300] now:1000 updatedLaunches:&updated],
            @"old launches and a clean exit do not enter safe mode");

    NSArray *backoff = @[@2, @5, @10, @30, @60, @60];
    for (NSUInteger i = 0; i < [backoff count]; i++) {
      require([DBRecoveryClient restartBackoffSecondsForAttempt:i] ==
                  [[backoff objectAtIndex:i] unsignedIntegerValue],
              @"restart backoff follows the canonical bounded sequence");
    }
    puts("PASS: recovery helper policy resolution");
  }
  return 0;
}
