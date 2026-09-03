#import "DBWatchdog.h"
#import "DBRecoveryClient.h"
#import <UIKit/UIKit.h>
#import <unistd.h>

static volatile int gWdPong = 0;
static int gWdFail = 0;
static NSString *const DBWatchdogBackoffIndexKey = @"runtime.watchdog_backoff_index";

static unsigned int DBNextRelaunchDelay(void) {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSInteger index = [defaults integerForKey:DBWatchdogBackoffIndexKey];
  if (index < 0) index = 0;
  [defaults setInteger:index + 1 forKey:DBWatchdogBackoffIndexKey];
  [defaults synchronize];
  return (unsigned int)[DBRecoveryClient restartBackoffSecondsForAttempt:(NSUInteger)index];
}

static void DBScheduleFixedRelaunch(unsigned int delaySeconds) {
  pid_t child = fork();
  if (child != 0) return;
  sleep(delaySeconds);
  const char *tool = "/usr/bin/uiopen";
  char *const args[] = {(char *)tool, (char *)"doorbell://", NULL};
  execv(tool, args);
  _exit(127);
}

static void WDAppendLog(NSString *line) {
  NSString *path = @"/var/mobile/Documents/doorbell-hangs.log";
  NSFileManager *fm = [NSFileManager defaultManager];
  NSDictionary *attrs = [fm attributesOfItemAtPath:path error:NULL];
  if ([attrs fileSize] > 256 * 1024) [fm removeItemAtPath:path error:NULL];
  NSString *out = [NSString stringWithFormat:@"%@ %@\n", [[NSDate date] description], line];
  FILE *f = fopen([path UTF8String], "a");
  if (f) {
    fprintf(f, "%s", [out UTF8String]);
    fclose(f);
  }
}

@implementation DBWatchdog {
  NSString *(^_nameProvider)(void);
  BOOL (^_externalSupervisorProvider)(void);
}

+ (void)restartForMaintenanceWithExternalSupervisor:(BOOL)externalSupervisor {
  if (!externalSupervisor) DBScheduleFixedRelaunch(1);
  [NSThread sleepForTimeInterval:0.2];
  _exit(0);
}

- (id)initWithNameProvider:(NSString * (^)(void))nameProvider {
  return [self initWithNameProvider:nameProvider externalSupervisorProvider:nil];
}

- (id)initWithNameProvider:(NSString * (^)(void))nameProvider
 externalSupervisorProvider:(BOOL (^)(void))externalSupervisorProvider {
  self = [super init];
  if (self) {
    _nameProvider = [nameProvider copy];
    _externalSupervisorProvider = [externalSupervisorProvider copy];
  }
  return self;
}

- (void)start {
  [NSThread detachNewThreadSelector:@selector(wdThreadMain) toTarget:self withObject:nil];
}


- (void)wdPong {
  gWdPong = 1;
}

- (void)wdThreadMain {
  [NSThread sleepForTimeInterval:5.0];
  while (YES) {
    @autoreleasepool {
      [NSThread sleepForTimeInterval:3.0];
      gWdPong = 0;
      [self performSelectorOnMainThread:@selector(wdPong) withObject:nil waitUntilDone:NO];
      int waited = 0;
      while (waited < 5000 && gWdPong == 0) {
        usleep(100 * 1000);
        waited += 100;
      }
      if (gWdPong == 0) {
        gWdFail++;
        WDAppendLog([NSString stringWithFormat:@"UI hang detected (consecutive %d, screen %@)",
                     gWdFail, _nameProvider ? _nameProvider() : @"?"]);
        NSLog(@"[doorbell] WATCHDOG: main thread no response (consecutive %d)", gWdFail);
      } else {
        gWdFail = 0;
      }
      if (gWdFail >= 3) {
        WDAppendLog([NSString stringWithFormat:@"UI hung >15s — restarting app (screen %@)",
                     _nameProvider ? _nameProvider() : @"?"]);
        BOOL supervised = _externalSupervisorProvider && _externalSupervisorProvider();
        if (supervised) {
          NSLog(@"[doorbell] WATCHDOG: UI hung — delegating restart to helper");
          WDAppendLog(@"external supervisor reachable; delegating relaunch");
        } else {
          // A fixed argv fallback avoids exposing a shell or accepting runtime command input.
          unsigned int delay = DBNextRelaunchDelay();
          NSLog(@"[doorbell] WATCHDOG: UI hung — restarting app after %u seconds", delay);
          DBScheduleFixedRelaunch(delay);
        }
        [NSThread sleepForTimeInterval:0.3];

        _exit(0);
      }
    }
  }
}

@end
