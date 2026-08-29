#import "DBScreen.h"

// 未配対機の配対引導画面。自機 QR 表示 + 管理後台での承認待ち、
// または PIN での能動参加、または親機化 (2 段確認 — UIAlertView 不使用)。
// 2 秒毎に paired を確認し、配対済みになったら自動で閉じる。
@interface DBPairingScreen : DBScreen

- (id)initWithRouter:(DBRouter *)router;
- (void)startPolling;
- (void)stopPolling;
- (void)reload;
- (void)handleJoinResult:(NSDictionary *)ev;

@end
