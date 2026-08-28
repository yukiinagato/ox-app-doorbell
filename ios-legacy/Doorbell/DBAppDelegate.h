// 起動: Documents/boot.json を読み core を生成・起動 (ios/Doorbell/AppDelegate.swift の MRC 移植)。
// core の UI イベントは DBCoreBridge が main へ marshal。press 複製で来鈴画面を被せる。
// keep-awake: idleTimerDisabled=YES。
#import <UIKit/UIKit.h>

@class DBCoreBridge, DBBootConfig;

@interface DBAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, retain) UIWindow *window;
@end

// 全タッチを無操作検出へ流す window。
@interface DBActivityWindow : UIWindow
@property(nonatomic, copy) void (^onActivity)(void);
@end
