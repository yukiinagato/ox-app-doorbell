#import <Foundation/Foundation.h>

// Documents/boot.json の読み書き。bundle id は旧版と同一 (jp.keihan.doorbell) のため
// 端末上の既存 boot.json / doorbell.db / Keychain をそのまま引き継ぐ。
@interface DBBootConfig : NSObject

@property(nonatomic, copy) NSString *rawJson;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *role;
@property(nonatomic, copy) NSString *door;
@property(nonatomic, copy) NSString *uiLang;
@property(nonatomic, assign) BOOL kiosk;
@property(nonatomic, assign) long httpPort;
@property(nonatomic, copy) NSString *doorHost;
@property(nonatomic, assign) long directPort;
@property(nonatomic, assign) BOOL micEnabled;

+ (NSString *)dataDir;  // Documents (無ければ作る)

// 未読み込み時の既定 (indoor_panel)。
+ (DBBootConfig *)load;

// 配対成功時に PSK/seeds を boot.json へ和集合保存。更新後 JSON を返す (失敗 nil)。
+ (NSString *)persistPsk:(NSString *)pskHex seeds:(NSArray *)seeds;

@end
