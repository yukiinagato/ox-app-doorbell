#import <UIKit/UIKit.h>
#import "../Media/DBSipSession.h"

@class DBCoreBridge, DBBootConfig, DBTexts, DBScreen, DBHomeScreen, DBIncomingScreen;

// 画面状態機 + イベント単点入口。全ての画面遷移と core イベント配送はここを通る。
//
// 設計ルール:
//  - present/dismiss/UIAlertView は存在しない。遷移は addSubview/removeFromSuperview。
//  - onCoreEvent: は必ず main スレッドで呼ばれる (DBCoreBridge が marshal 済み)。
//  - 画面は生涯 1 インスタンス (生成コストと生成時競合の排除)。
//  - SIP は同時に 1 セッション。このクラスが唯一の所有者。
@interface DBRouter : NSObject <DBMiniSipDelegate>

@property(nonatomic, readonly) UIView *containerView;
@property(nonatomic, readonly) DBCoreBridge *core;
@property(nonatomic, readonly) DBBootConfig *boot;
@property(nonatomic, readonly) DBTexts *texts;
@property(nonatomic, readonly) DBHomeScreen *home;
@property(nonatomic, readonly) DBIncomingScreen *incoming;

- (id)initWithBridge:(DBCoreBridge *)core boot:(DBBootConfig *)boot;
- (void)start;
- (NSString *)currentScreenName;

// 画面遷移 (main スレッドからのみ)
- (void)showHomeAnimated:(BOOL)animated;
- (void)showIncoming:(NSString *)door purpose:(NSString *)purpose lang:(NSString *)lang;
- (void)closeIncomingAnimated:(BOOL)animated;
- (void)showInfo;
- (void)closeInfoAnimated:(BOOL)animated;
- (void)showPairing;
- (void)closePairingAnimated:(BOOL)animated;

// PIN 覆盖层 (解锁確認後に action を実行)。
- (void)requestPinThen:(void (^)(void))action;
- (void)dismissPinOverlay;

// SIP 管理 (単一セッション)
- (void)sipStart:(NSString *)host port:(int)port mode:(NSString *)mode;
- (void)sipHangup;
- (void)sipSendDtmf:(NSString *)digits;

// core イベント入口 (main スレッド)
- (void)onCoreEvent:(NSDictionary *)ev;

@end
