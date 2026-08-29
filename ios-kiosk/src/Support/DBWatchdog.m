#import "DBWatchdog.h"
#import <UIKit/UIKit.h>

static volatile int gWdPong = 0;
static int gWdFail = 0;

static void WDAppendLog(NSString *line) {
  NSString *path = @"/var/mobile/Documents/doorbell-hangs.log";
  NSFileManager *fm = [NSFileManager defaultManager];
  NSDictionary *attrs = [fm attributesOfItemAtPath:path error:NULL];
  if ([attrs fileSize] > 256 * 1024) [fm removeItemAtPath:path error:NULL];  // 簡易ローテート
  NSString *out = [NSString stringWithFormat:@"%@ %@\n", [[NSDate date] description], line];
  FILE *f = fopen([path UTF8String], "a");
  if (f) {
    fprintf(f, "%s", [out UTF8String]);
    fclose(f);
  }
}

@implementation DBWatchdog {
  NSString *(^_nameProvider)(void);
}

- (id)initWithNameProvider:(NSString * (^)(void))nameProvider {
  self = [super init];
  if (self) _nameProvider = [nameProvider copy];
  return self;
}

- (void)start {
  [NSThread detachNewThreadSelector:@selector(wdThreadMain) toTarget:self withObject:nil];
}

// メインスレッドから呼ばれる (runloop が回っている = 生きている証拠)
- (void)wdPong {
  gWdPong = 1;
}

- (void)wdThreadMain {
  [NSThread sleepForTimeInterval:5.0];  // 起動直後の猶予
  while (YES) {
    @autoreleasepool {  // 一巡ごとに解放 (ループが一生抜けないため外側に置かない)
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
      if (gWdFail >= 3) {  // ~15 秒以上無応答
        WDAppendLog([NSString stringWithFormat:@"UI hung >15s — restarting app (screen %@)",
                     _nameProvider ? _nameProvider() : @"?"]);
        NSLog(@"[doorbell] WATCHDOG: UI hung — restarting app");
        // 自プロセスが消えた 1 秒後に SpringBoard へ再起動要求を出す子プロセスを残す
        // (生きているプロセスへの open は前面化されるだけで再起動にならないため)
        system("( sleep 1; /usr/bin/uiopen doorbell:// ) >/dev/null 2>&1 &");
        [NSThread sleepForTimeInterval:0.3];
        // 自殺。固まったメインスレッドを抱えたまま exit() の後始末をしないよう _exit。
        _exit(0);
      }
    }
  }
}

@end
