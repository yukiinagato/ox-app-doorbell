// 来客全屏 (indoor_panel が press で表示。ios/Doorbell/IncomingViewController.swift の MRC 移植)。
//   - 門口ライブ映像: peers[].stream (MJPEG) を DBMjpegClient で自前デコード
//   - 監聴/応答: ミニ SIP で門口機の待受 (sip.direct_port 既定 47190) へ直接呼
//       ・「聞く」= X-Doorbell-Mode: monitor (門口マイク一方向)
//       ・「応答」= monitor を切って 400ms 後に answer 直呼 (双方向)
//   - 開錠: 通話中に DTMF "*1" 送出 (ms_send_dtmf)
//   - クイック返信: config quick_replies を訪客言語ラベルで db_core_quick_reply
//   - 用件 / 訪客言語バッジ: press payload 由来
//   - 30 秒無操作 or reply で自動クローズ
#import <UIKit/UIKit.h>

@class DBCoreBridge, DBBootConfig;

@interface DBIncomingViewController : UIViewController

- (id)initWithCore:(DBCoreBridge *)core
              boot:(DBBootConfig *)boot
              door:(NSString *)door
           purpose:(NSString *)purpose
       visitorLang:(NSString *)visitorLang;

// 同じ画面が出ている間の再チャイム。
- (void)refreshPurpose:(NSString *)purpose visitorLang:(NSString *)visitorLang;

@end
