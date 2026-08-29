#import "DBAppDelegate.h"
#import "../Core/DBBootConfig.h"
#import "../Core/DBCoreBridge.h"
#import "../Screens/DBRouter.h"
#import "DBWatchdog.h"

// 回転を受け付けるだけの最小 root VC。画面遷移は UIViewController を使わない
// (present/dismiss モーダル機構が iOS 5.1 の主要 crash 源のため構造から排除)。
// この VC の view が DBRouter の container になり、回転時は layoutSubviews が cascade する。
@interface DBRootController : UIViewController
@end
@implementation DBRootController
- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation {
  return YES;
}
@end

@implementation DBAppDelegate {
  DBCoreBridge *_core;
  DBBootConfig *_boot;
  DBRouter *_router;
  DBWatchdog *_watchdog;
}
@synthesize window = _window;

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  _boot = [DBBootConfig load];
  _core = [[DBCoreBridge alloc] init];

  // 失敗しても UI は起動する (オフライン表示)。
  [_core startWithDataDir:[DBBootConfig dataDir] bootJson:_boot.rawJson];

  _router = [[DBRouter alloc] initWithBridge:_core boot:_boot];
  DBRouter *router = _router;  // app 生涯で生存するため strong キャプチャで安全
  [_core addHandler:@"app" handler:^(NSDictionary *ev) { [router onCoreEvent:ev]; }];

  UIWindow *win = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
  DBRootController *root = [[DBRootController alloc] initWithNibName:nil bundle:nil];
  UIView *container = _router.containerView;
  container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  root.view = container;
  win.rootViewController = root;
  [win makeKeyAndVisible];
  self.window = win;

  application.idleTimerDisabled = YES;  // keep-awake (kiosk)

  [_router start];

  // UI ウォッチドッグ (main runloop が回り始めた後で良い)
  DBRouter *r = _router;
  _watchdog = [[DBWatchdog alloc] initWithNameProvider:^NSString * { return [r currentScreenName]; }];
  [_watchdog start];
  return YES;
}

- (void)applicationWillTerminate:(UIApplication *)application {
  [_core stop];
}

@end
