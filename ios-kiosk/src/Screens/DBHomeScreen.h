#import "DBScreen.h"

// 待機画面。時計/日付/状態/イベント直近 8 件、SOS 長押し、緊急覆盖層、
// 応対メッセージ横幅、夜間 (赤色) 調色、輝度、主題背景、离線覆盖層、
// 隠し管理入口 (右上 5 秒 7 タップ) と ⓘ (情報) ボタン。
@interface DBHomeScreen : DBScreen

- (id)initWithRouter:(DBRouter *)router;

// core イベント (router 経由・main スレッド)
- (void)refreshFromCore;                  // config/status/主題/SOS/display 全更新
- (void)appendEvent:(NSDictionary *)ev;   // イベント履歴行を追加
- (void)playChime:(NSDictionary *)ev;     // chime (カスタム音 → 失敗時システム音)
- (void)stopChime;                        // 門口機の取消で再生中の来鈴音を停止
- (void)showReplyBanner:(NSDictionary *)ev;
- (void)applyDisplayEvent:(NSDictionary *)ev;
- (void)showEmergencyEvent:(NSDictionary *)ev;
- (void)hideEmergencyEvent:(NSDictionary *)ev;

@end
