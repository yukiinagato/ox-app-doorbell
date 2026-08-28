// doorbell-core C ABI の ObjC(MRC) ラッパ (ios/Doorbell/CoreBridge.swift と同役)。
// - コールバックは core 内部スレッドから届く → main スレッドへ marshal して配送。
// - db_platform:
//     log_line      → NSLog
//     tts_speak     → iOS5 に AVSpeechSynthesizer 無し (iOS7+) → 提示音 (システム音) へ回落
//     https_request → NSURLConnection sendSynchronousRequest (同期契約・専用スレッド駆動)
//     secure_get/put→ Keychain (kSecClassGenericPassword)
// - core が返す char* は db_free で解放。SPI が core へ渡す char* は malloc (core が free)。
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
- (NSDictionary *)config;

// 提示音 (reply/chime のカスタム音声再生失敗時の回落先でも使う)。
- (void)chimeFallback;

@end
