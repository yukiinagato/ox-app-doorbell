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

  // 黒画面調査: 起動 6 秒後に UI の実体 (PNG + view tree) を Documents に吐く
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{ [self diagDump]; });
  return YES;
}

- (void)applicationWillTerminate:(UIApplication *)application {
  [_core stop];
}

// URL scheme (doorbell://)。kiosk の遠隔補助入口:
//   doorbell://pin   → PIN 覆盖層を開く (遠隔から admin 操作を開始できる。実機 UI 試験にも使う)
//   doorbell://shot  → diagDump (PNG + view tree を Documents へ — DDI 無しの実機 UI 取証)
//   doorbell://home  → home 画面へ戻す
// iOS 4.2+ の delegate 簽名 (iOS 5.1 で呼ばれるもの)。
- (BOOL)application:(UIApplication *)application
            openURL:(NSURL *)url
  sourceApplication:(NSString *)source
         annotation:(id)annotation {
  (void)application; (void)source; (void)annotation;
  NSString *host = [url host] ?: @"";
  if ([host length] == 0) host = [[url path] stringByTrimmingCharactersInSet:
                                     [NSCharacterSet characterSetWithCharactersInString:@"/"]];
  NSLog(@"[doorbell] openURL: %@ → host='%@'", url, host);
  if ([host isEqualToString:@"pin"]) {
    [_router requestPinThen:nil];
    return YES;
  }
  if ([host isEqualToString:@"shot"]) {
    [self diagDump];
    return YES;
  }
  if ([host isEqualToString:@"home"]) {
    [_router showHomeAnimated:NO];
    return YES;
  }
  return YES;
}

#pragma mark - UI 診断ダンプ (kiosk 黑画面調査用 — Documents に PNG + view tree)

// 起動 6 秒後に 1 回: keyWindow を PNG 化して Documents へ。
// recursiveDescription (private, jailbreak 前提の log/調査専用) もファイルに落とす。
- (void)diagDump {
  NSMutableString *out = [NSMutableString string];
  UIApplication *app = [UIApplication sharedApplication];
  UIWindow *win = self.window ?: app.keyWindow;
  [out appendFormat:@"time=%@\n", [[NSDate date] description]];
  [out appendFormat:@"appState=%ld active=%d\n", (long)app.applicationState,
                      (int)(app.applicationState == UIApplicationStateActive)];
  [out appendFormat:@"screenBounds=%@ brightness=%.2f\n",
                      NSStringFromCGRect([UIScreen mainScreen].bounds),
                      [UIScreen mainScreen].brightness];
  [out appendFormat:@"window=%@ frame=%@ hidden=%d alpha=%.2f\n", win,
                      win ? NSStringFromCGRect(win.frame) : @"nil",
                      (int)(win.isHidden), win.alpha];
  if (win) {
    [out appendFormat:@"rootVC=%@\n", win.rootViewController];
    UIView *rv = nil;
    UIViewController *rvc = win.rootViewController;
    if (rvc) {
      // viewIfLoaded は iOS 9+ — iOS 5 では isViewLoaded でガードする
      if ([rvc respondsToSelector:@selector(isViewLoaded)] && [rvc isViewLoaded]) rv = rvc.view;
    }
    [out appendFormat:@"loadedView=%@\n", rv ?: @"(not loaded)"];
    if (rv) {
      [out appendFormat:@"rootView frame=%@ hidden=%d alpha=%.2f superview=%@ subviews=%lu\n",
                          NSStringFromCGRect(rv.frame), (int)rv.isHidden, rv.alpha,
                          rv.superview, (unsigned long)[rv.subviews count]];
    }
    SEL rec = NSSelectorFromString(@"recursiveDescription");
    if ([win respondsToSelector:rec]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
      [out appendFormat:@"--- view tree ---\n%@\n", [win performSelector:rec]];
#pragma clang diagnostic pop
    }
  }
  [out writeToFile:@"/var/mobile/Documents/ui-dump.txt"
          atomically:YES
            encoding:NSUTF8StringEncoding
               error:NULL];
  if (win) {
    CGSize sz = win.bounds.size;
    if (sz.width < 1 || sz.height < 1) sz = [UIScreen mainScreen].bounds.size;
    UIGraphicsBeginImageContextWithOptions(sz, NO, 1.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (ctx) {
      [win.layer renderInContext:ctx];
      UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
      UIGraphicsEndImageContext();
      if (img) {
        [UIImagePNGRepresentation(img) writeToFile:@"/var/mobile/Documents/ui-dump.png"
                                        atomically:YES];
      }
    } else {
      UIGraphicsEndImageContext();
    }
  }
  NSLog(@"[doorbell] diag dump done (Documents/ui-dump.png, ui-dump.txt)");
}

@end
