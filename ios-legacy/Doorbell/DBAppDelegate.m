#import "DBAppDelegate.h"
#import "DBCoreBridge.h"
#import "DBBootConfig.h"
#import "DBConfigUtil.h"
#import "DBMainViewController.h"
#import "DBIncomingViewController.h"

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
  return YES;
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
