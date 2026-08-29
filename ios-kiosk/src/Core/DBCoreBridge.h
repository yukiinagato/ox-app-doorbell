#import <Foundation/Foundation.h>

// doorbell-core C ABI の ObjC (ARC) ラッパ。
// 設計ルール (ios-legacy で固めたもの):
//  - コールバックは core 内部スレッドから届く → 必ず main へ marshal してから配送。
//    ハンドラは add/remove の衝突を避けるためコピーして回す。
//  - core が返す char* は db_free で解放。SPI が core へ渡す char* は malloc (core が free)。
//  - db_platform:
//      log_line      → NSLog
//      tts_speak     → iOS5 に AVSpeechSynthesizer 無し (iOS7+) → 提示音へ回落
//      https_request → NSURLConnection sendSynchronousRequest (同期契約・core 専用スレッド駆動)
//      secure_get/put→ Keychain (kSecClassGenericPassword)
//      device_info   → main スレッドで定期更新したキャッシュ JSON を返す (UIKit 非依存)
#import <Foundation/Foundation.h>

typedef void (^DBUiEventHandler)(NSDictionary *ev);

@interface DBCoreBridge : NSObject

@property(nonatomic, readonly) BOOL isRunning;

- (BOOL)startWithDataDir:(NSString *)dataDir bootJson:(NSString *)bootJson;
- (void)stop;

// UI イベント購読 (main スレッドで届く)。key 重複は上書き。
- (void)addHandler:(NSString *)key handler:(DBUiEventHandler)handler;
- (void)removeHandler:(NSString *)key;

// 操作 API (doorbell.h)
- (void)press:(NSString *)door;
- (void)pressPurpose:(NSString *)door purpose:(NSString *)purpose;
- (void)setVisitorLang:(NSString *)door lang:(NSString *)lang;
- (void)quickReply:(NSString *)replyId door:(NSString *)door;
- (void)emergency:(BOOL)active;

- (NSDictionary *)status;
- (NSDictionary *)debugInfo;
- (NSDictionary *)deviceInfoNow;  // gateway/wifi/battery を今取得 (main スレッド専用)
- (NSDictionary *)config;

// 配対 (発見/招待)。{paired, self, pair_qr, pending:{devices,pairing_mode}}
- (NSDictionary *)pairingInfo;
- (void)joinCluster:(NSString *)host pin:(NSString *)pin;  // 未配対機側: PIN 参加
- (BOOL)foundCluster;                                      // 未配対機側: 親機化
- (void)setPairingMode:(int)seconds;                       // 配対済み機側: 配対モード ON
- (void)inviteDevice:(NSString *)nodeId;                   // 配対済み機側: 承認

// 提示音 (カスタム音声再生失敗時の回落先)
- (void)chimeFallback;

@end
