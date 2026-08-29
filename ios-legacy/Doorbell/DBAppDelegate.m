#import "DBAppDelegate.h"
#import "DBCoreBridge.h"
#import "DBBootConfig.h"
#import "DBConfigUtil.h"
#import "DBMainViewController.h"
#import "DBIncomingViewController.h"
#import <unistd.h>
#import <stdlib.h>

// ---- UI ウォッチドッグ (kiosk 自愈) ----
// kiosk では「プロセスが生きているが UI が固まった」状態はクラッシュと同義。
// メインスレッドの応答を監視し、無応答が続いたら SpringBoard への再起動要求 (uiopen) を
// 残したうえで自プロセスを終了する。復旧記録は doorbell-hangs.log に残す (crash log は
// ハングでは出ないため)。
static volatile int gWdPong = 0;
static int gWdFail = 0;

static void WDAppendLog(NSString *line) {
  NSString *path = @"/var/mobile/Documents/doorbell-hangs.log";
  NSFileManager *fm = [NSFileManager defaultManager];
  NSDictionary *attrs = [fm attributesOfItemAtPath:path error:NULL];
  if ([attrs fileSize] > 256 * 1024) [fm removeItemAtPath:path error:NULL];  // 簡易ローテート
  NSString *out = [NSString stringWithFormat:@"%@ %@\n",
                   [[NSDate date] description], line];
  FILE *f = fopen([path UTF8String], "a");
  if (f) { fprintf(f, "%s", [out UTF8String]); fclose(f); }
}

@implementation DBActivityWindow
@synthesize onActivity = _onActivity;
- (void)sendEvent:(UIEvent *)event {
  if (event.type == UIEventTypeTouches && _onActivity) _onActivity();
  [super sendEvent:event];
}
- (void)dealloc {
  [_onActivity release];
  [super dealloc];
}
@end

@implementation DBAppDelegate {
  DBCoreBridge *_core;
  DBBootConfig *_boot;
  DBMainViewController *_main;
}
@synthesize window = _window;

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  _boot = [[DBBootConfig load] retain];
  _core = [[DBCoreBridge alloc] init];

  // 失敗しても UI は起動する (オフライン表示)。
  [_core startWithDataDir:[DBBootConfig dataDir] bootJson:_boot.rawJson];

  DBAppDelegate *__unsafe_unretained weakSelf = self;
  [_core addHandler:@"app" handler:^(NSDictionary *ev) { [weakSelf onUiEvent:ev]; }];

  DBActivityWindow *win = [[DBActivityWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
  _main = [[DBMainViewController alloc] initWithCore:_core boot:_boot];
  DBMainViewController *__unsafe_unretained weakMain = _main;
  win.onActivity = ^{ [weakMain onActivity]; };
  win.rootViewController = _main;
  [win makeKeyAndVisible];
  self.window = win;
  [win release];

  application.idleTimerDisabled = YES;  // keep-awake (kiosk)

  // UI ウォッチドッグ起動 (メイン runloop が回り始めた後で良い)
  [NSThread detachNewThreadSelector:@selector(wdThreadMain) toTarget:self withObject:nil];
  return YES;
}

#pragma mark - UI ウォッチドッグ

// メインスレッドから呼ばれる (runloop が回っている = 生きている証拠)
- (void)wdPong {
  gWdPong = 1;
}

- (void)wdThreadMain {
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  [NSThread sleepForTimeInterval:5.0];  // 起動直後の猶予
  while (YES) {
    [pool release];
    pool = [[NSAutoreleasePool alloc] init];

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
      WDAppendLog([NSString stringWithFormat:@"UI hang detected (consecutive %d)", gWdFail]);
      NSLog(@"[doorbell] WATCHDOG: main thread no response (consecutive %d)", gWdFail);
    } else {
      gWdFail = 0;
    }
    if (gWdFail >= 3) {  // ~15 秒以上無応答
      WDAppendLog(@"UI hung >15s — restarting app");
      NSLog(@"[doorbell] WATCHDOG: UI hung — restarting app");
      // 1) 自プロセスが消えた 1 秒後に SpringBoard へ再起動要求を出す子プロセスを残す
      //    (既に生きているプロセスへの open は前面化されるだけで再起動にならないため)
      system("( sleep 1; /usr/bin/uiopen doorbell:// ) >/dev/null 2>&1 &");
      [NSThread sleepForTimeInterval:0.3];
      // 2) 自殺。固まったメインスレッドを抱えたまま exit() の後始末をしないよう _exit。
      _exit(0);
    }
  }
}

- (void)applicationWillTerminate:(UIApplication *)application {
  [_core stop];
}

- (void)onUiEvent:(NSDictionary *)ev {
  NSString *t = [DBConfigUtil evStr:ev key:@"t"];
  // 来客 (press イベントの複製) → 来鈴画面。門口機自身 (door_station) は出さない。
  if ([t isEqualToString:@"event"] &&
      [[DBConfigUtil evStr:ev key:@"type"] isEqualToString:@"press"] &&
      ![_boot.role isEqualToString:@"door_station"]) {
    [self presentIncomingDoor:[DBConfigUtil evStr:ev key:@"door"]
                      purpose:[DBConfigUtil evStr:ev key:@"purpose"]
                  visitorLang:[DBConfigUtil evStr:ev key:@"visitor_lang"]];
  } else if ([t isEqualToString:@"paired"]) {
    [self onPaired:ev];
  }
}

// 配対成功 (INVITE 受理 / PIN 参加)。boot.json に PSK/seeds を永続化する。
// 現行プロセスは取得済み PSK で seed 直結・gossip 済み (再起動不要)。次回起動で beacon も再鍵。
- (void)onPaired:(NSDictionary *)ev {
  NSString *pskHex = [DBConfigUtil evStr:ev key:@"psk_hex"];
  id sids = [ev objectForKey:@"seeds"];
  NSArray *seeds = [sids isKindOfClass:[NSArray class]] ? sids : nil;
  NSString *js = [DBBootConfig persistPsk:pskHex seeds:seeds];
  if ([js length] > 0) {
    _boot.rawJson = js;  // 次回 load 用にメモリ側も更新
    NSLog(@"[doorbell] paired: boot.json に PSK/seeds を保存しました");
  }
  // フィードバックは配対引導ページが自動で閉じることで伝わる。ここで UIAlertView を出すと
  // 同一イベント配送中に引導 VC の dismiss と重なり over-release で落ちる (iOS5) ため出さない。
}

- (void)presentIncomingDoor:(NSString *)door purpose:(NSString *)purpose
                visitorLang:(NSString *)visitorLang {
  UIViewController *root = self.window.rootViewController;
  if (root == nil) return;
  UIViewController *presented = root.presentedViewController;
  if ([presented isKindOfClass:[DBIncomingViewController class]]) {
    [(DBIncomingViewController *)presented refreshPurpose:purpose visitorLang:visitorLang];
    return;
  }
  if (presented != nil) return;  // PIN 等の表示中は奪わない
  DBIncomingViewController *vc =
      [[[DBIncomingViewController alloc] initWithCore:_core boot:_boot door:door
                                             purpose:purpose visitorLang:visitorLang] autorelease];
  [root presentViewController:vc animated:YES completion:nil];
}

- (void)dealloc {
  [_core release];
  [_boot release];
  [_main release];
  [_window release];
  [super dealloc];
}

@end
