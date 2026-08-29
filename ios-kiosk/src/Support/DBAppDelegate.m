#import "DBAppDelegate.h"
#import "../Core/DBBootConfig.h"
#import "../Core/DBCoreBridge.h"
#import "../Media/DBH264Player.h"
#import "../Media/DBLowLatencyH264Player.h"
#import "../Net/DBMjpegClient.h"
#import "../Screens/DBRouter.h"
#import "DBWatchdog.h"

void DBH264Dbg(NSString *fmt, ...);

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

@interface DBEffectWindow : UIWindow
@property(nonatomic, copy) void (^onButtonTap)(void);
@end
@implementation DBEffectWindow
- (void)sendEvent:(UIEvent *)event {
  [super sendEvent:event];
  if (event.type != UIEventTypeTouches || !_onButtonTap) return;
  for (UITouch *touch in [event allTouches]) {
    if (touch.phase != UITouchPhaseEnded) continue;
    UIView *view = touch.view;
    while (view && ![view isKindOfClass:[UIButton class]]) view = view.superview;
    if ([view isKindOfClass:[UIButton class]] && [(UIButton *)view isEnabled]) {
      _onButtonTap();
      break;
    }
  }
}
@end

@implementation DBAppDelegate {
  DBCoreBridge *_core;
  DBBootConfig *_boot;
  DBRouter *_router;
  DBWatchdog *_watchdog;
  DBH264Player *_h264Test;  // doorbell://h264test 用 (全screen 再生テスト)
  DBLowLatencyH264Player *_vtTest;  // doorbell://vttest<ip> 用
  DBMjpegClient *_mjpegTest;
  UIImageView *_mjpegTestView;
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

  DBEffectWindow *win = [[DBEffectWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
  __weak DBRouter *effectRouter = _router;
  win.onButtonTap = ^{ [effectRouter playButtonSound]; };
  DBRootController *root = [[DBRootController alloc] initWithNibName:nil bundle:nil];
  UIView *container = _router.containerView;
  container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  root.view = container;
  win.rootViewController = root;
  [win makeKeyAndVisible];
  self.window = win;

  application.idleTimerDisabled = YES;  // keep-awake (kiosk)

  [_router start];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{ [_router playLaunchSound]; });

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
    [self h264TestStop];
    return YES;
  }
  if ([host isEqualToString:@"info"]) {
    // debug/情報画面を直接開く (実機検証用 — 物理接触 or root SSH 前提の入口)
    [_router showInfo];
    return YES;
  }
  if ([host isEqualToString:@"stress"]) {
    // core JSON 取得の連続圧 (store 二重ロック修正の実機検証用)。
    // SUSPECT buffer / SIGSEGV が出なければ修正成立。
    DBCoreBridge *c = _core;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      for (int i = 0; i < 60; i++) {
        (void)[c status];
        (void)[c debugInfo];
        (void)[c config];
        if (i % 10 == 0) NSLog(@"[doorbell] stress %d/60", i);
        [NSThread sleepForTimeInterval:0.05];
      }
      NSLog(@"[doorbell] stress done (60 rounds, no crash)");
    });
    return YES;
  }
  if ([host hasPrefix:@"h264test"]) {
    // H.264 fMP4 直播の全画面テスト。host = "h264test<ip>" 形式
    // (uiopen doorbell://h264test10.10.39.174)。IP 省略時は 127.0.0.1。
    NSString *ip = nil;
    if ([host length] > 8) ip = [host substringFromIndex:8];
    if ([ip length] == 0) ip = @"127.0.0.1";
    NSString *url = [NSString stringWithFormat:@"http://%@:47180/stream.mp4", ip];
    NSLog(@"[doorbell] h264test: %@", url);
    [_h264Test stop];
    _h264Test = nil;
    UIView *container = _router.containerView;
    __weak DBAppDelegate *wself = self;
    _h264Test = [[DBH264Player alloc] initWithURL:url container:container
                                          onState:^(DBH264PlayerState st) {
      NSLog(@"[doorbell] h264test state=%ld", (long)st);
      if (st == DBH264PlayerFailed) {
        DBAppDelegate *s = wself;
        if (s) [s h264TestStop];
      }
    }];
    [_h264Test start];
    return YES;
  }
  if ([host hasPrefix:@"vttest"]) {
    NSString *ip = [host length] > 6 ? [host substringFromIndex:6] : nil;
    if (![ip length]) ip = @"127.0.0.1";
    NSString *stream = [NSString stringWithFormat:@"http://%@:47180/stream.mp4", ip];
    [self h264TestStop];
    UIView *container = _router.containerView;
    __weak DBAppDelegate *wself = self;
    _vtTest = [[DBLowLatencyH264Player alloc] initWithURL:stream container:container
                                                  onState:^(DBLowLatencyPlayerState state) {
      DBH264Dbg(@"[vt] test state=%ld", (long)state);
      if (state == DBLowLatencyPlayerFailed) {
        DBAppDelegate *delegate = wself;
        if (delegate) [delegate h264TestStop];
      }
    }];
    [_vtTest start];
    return YES;
  }
  if ([host hasPrefix:@"mjpegtest"]) {
    NSString *ip = [host length] > 9 ? [host substringFromIndex:9] : nil;
    if (![ip length]) ip = @"127.0.0.1";
    [self h264TestStop];
    UIView *container = _router.containerView;
    _mjpegTestView = [[UIImageView alloc] initWithFrame:container.bounds];
    _mjpegTestView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _mjpegTestView.contentMode = UIViewContentModeScaleAspectFit;
    _mjpegTestView.backgroundColor = [UIColor blackColor];
    [container addSubview:_mjpegTestView];
    __weak DBAppDelegate *wself = self;
    NSString *url = [NSString stringWithFormat:@"http://%@:47180/stream.mjpeg", ip];
    _mjpegTest = [[DBMjpegClient alloc] initWithURLString:url onFrame:^(UIImage *image) {
      DBAppDelegate *delegate = wself;
      if (delegate) delegate->_mjpegTestView.image = image;
    }];
    [_mjpegTest start];
    return YES;
  }
  if ([host isEqualToString:@"h264stop"]) {
    [self h264TestStop];
    return YES;
  }
  return YES;
}

- (void)h264TestStop {
  [_h264Test stop];
  _h264Test = nil;
  [_vtTest stop];
  _vtTest = nil;
  [_mjpegTest stop];
  _mjpegTest = nil;
  [_mjpegTestView removeFromSuperview];
  _mjpegTestView = nil;
  [_router showHomeAnimated:NO];
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
