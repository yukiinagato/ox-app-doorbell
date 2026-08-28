// 未配対 (全ゼロ PSK) 端末の配対引導画面。
//  - 自機の配対 QR を表示 (管理者が『デバイスを追加』一覧で承認 or この QR を読み取る)
//  - 手動フォールバック: seed アドレス + PIN で能動参加 ([_core joinCluster:pin:])
// core の "paired" イベント / pairingInfo ポーリングで配対完了を検知し自動 dismiss。
#import <UIKit/UIKit.h>

@class DBCoreBridge, DBBootConfig;

@interface DBPairingViewController : UIViewController
- (id)initWithCore:(DBCoreBridge *)core boot:(DBBootConfig *)boot;
@end
