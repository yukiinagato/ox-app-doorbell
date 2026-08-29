#import <Foundation/Foundation.h>

// UI ウォッチドッグ (kiosk 自愈)。
// kiosk では「プロセスが生きているが UI が固まった」状態はクラッシュと同義。
// メインスレッドの応答を監視し、無応答 ~15s で:
//   1) /var/mobile/Documents/doorbell-hangs.log に記録 (crash log は hang を出さない)
//   2) ( sleep 1; uiopen doorbell:// ) 子プロセスを遺して自プロセスを _exit(0)
//   3) SpringBoard が ~1s 後に再起動
// 誤発火閾値: 3s 輪詢 + 5s 待機 × 3 回。main の最長合法ブロック (MJPEG 解码/音声停止)
// はこれより十分短い (MJPEG は専用スレッドへ移したため main を塞がない)。
@interface DBWatchdog : NSObject

// 現在の画面名を返す (凍結時の取证用ログに載せる)。
- (id)initWithNameProvider:(NSString * (^)(void))nameProvider;
- (void)start;

@end
