#import <Foundation/Foundation.h>

// UI-hang watchdog for jailbroken iOS 5 kiosks. Three failed main-thread probes trigger a logged
// process exit. A reachable external helper owns relaunch; otherwise a fixed-argv uiopen fallback
// uses the shared bounded restart backoff and never exposes a shell or TCP control surface.

@interface DBWatchdog : NSObject


- (id)initWithNameProvider:(NSString * (^)(void))nameProvider;
- (id)initWithNameProvider:(NSString * (^)(void))nameProvider
 externalSupervisorProvider:(BOOL (^)(void))externalSupervisorProvider;
- (void)start;

@end
