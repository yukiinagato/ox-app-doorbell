// boot.json — 端末ローカルの起動設定 (ios/Doorbell/BootConfig.swift の MRC 移植)。
// iPad1 監視ノードは role=indoor_panel が既定。fleet 設定は core が CRDT で持つ。
// 保存場所: <Documents>/boot.json (無ければ既定を書き出す)。
#import <Foundation/Foundation.h>

@interface DBBootConfig : NSObject

@property(nonatomic, copy) NSString *rawJson;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *role;   // "indoor_panel" (iPad1 監視端)
@property(nonatomic, copy) NSString *door;   // 監視対象 door ("" = 任意)
@property(nonatomic, copy) NSString *uiLang; // 室内側表示言語
@property(nonatomic, assign) BOOL kiosk;
@property(nonatomic, assign) NSInteger httpPort; // 自機 httpd (資産取得 /asset/<hash>)
// 門口機 direct SIP 目標: boot.json の door_host / sip.direct_port を殻が読む。
@property(nonatomic, copy) NSString *doorHost; // 直呼宛先 (空なら status_json から解決)
@property(nonatomic, assign) NSInteger directPort;
@property(nonatomic, assign) BOOL micEnabled;  // 外部マイク有無 (無ければ 0=無音送信)

+ (NSString *)dataDir;
+ (DBBootConfig *)load;

@end
