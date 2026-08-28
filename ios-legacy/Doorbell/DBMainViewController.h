// 監視端メイン画面 (待機 / 監視 / 返信バナー / 緊急)。iPad1 (indoor_panel) 版 —
// 用件ボタン/訪客言語バー/カメラ/H.264 は無し (門口機専用機能)。frame ベース手動レイアウト。
// core イベント (state/chime/reply/display/emergency/config_changed/…) で遷移する。
#import <UIKit/UIKit.h>

@class DBCoreBridge, DBBootConfig;

@interface DBMainViewController : UIViewController

- (id)initWithCore:(DBCoreBridge *)core boot:(DBBootConfig *)boot;
- (void)onActivity;  // 無操作検出リセット (ActivityWindow から)

@end
