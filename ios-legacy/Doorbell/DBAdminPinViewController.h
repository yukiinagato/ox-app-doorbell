// 隠し管理入口 / SOS 解除の PIN ダイアログ (簡略。ios/Doorbell/AdminPinViewController.swift 準拠)。
// 描画テンキーのみ (実体キーボード無しの監視端前提)。5 回失敗で 10 分ロック (プロセス内)。
// 照合先: <data_dir>/exit_pin.txt の SHA-256 hex (無ければ既定 PIN "000000")。
#import <UIKit/UIKit.h>

@class DBTexts;

typedef void (^DBAdminUnlockHandler)(void);

@interface DBAdminPinViewController : UIViewController

@property(nonatomic, copy) DBAdminUnlockHandler onUnlocked;

- (id)initWithTexts:(DBTexts *)texts;

@end
