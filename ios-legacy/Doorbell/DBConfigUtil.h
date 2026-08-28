// core 設定 (config_json / status_json) の共通ヘルパ (ios/Doorbell/ConfigUtil.swift の MRC 移植)。
// 全て NSDictionary/NSArray (NSJSONSerialization の出力) 上で型ゆるめに取り出す。
#import <UIKit/UIKit.h>

@interface DBConfigUtil : NSObject

// 設定ツリーをドットパスで辿る ("doors.d_front.label.ja")。無ければ nil。
+ (id)dig:(NSDictionary *)root path:(NSString *)dotpath;
+ (NSString *)str:(NSDictionary *)root path:(NSString *)dotpath;
+ (NSInteger)intVal:(NSDictionary *)root path:(NSString *)dotpath def:(NSInteger)def;
+ (double)doubleVal:(NSDictionary *)root path:(NSString *)dotpath def:(double)def;
+ (BOOL)boolVal:(NSDictionary *)root path:(NSString *)dotpath def:(BOOL)def;

// 設定オブジェクト直下のキーを order 昇順 (同値は id 順) に並べる。
+ (NSArray *)sortedByOrder:(NSDictionary *)map;

// ラベル多言語解決 (label.<lang> → label.ja → fallback)。
+ (NSString *)labelOf:(NSDictionary *)entry lang:(NSString *)lang fallback:(NSString *)fallback;

// イベント/設定の文字列取り出し ("" = 無し) / bool 取り出し。
+ (NSString *)evStr:(NSDictionary *)ev key:(NSString *)key;
+ (BOOL)evBool:(NSDictionary *)ev key:(NSString *)key;

// statusJson peers[] からこの door 担当の door_station (自分以外・生存) を返す。
+ (NSDictionary *)findDoorPeer:(NSDictionary *)status door:(NSString *)door;
// peer の addrs[0] "host:port" → host (Asterisk 非経由の直呼宛先)。無ければ nil。
+ (NSString *)peerHost:(NSDictionary *)peer;

// "#RRGGBB" → UIColor (不正は nil)。
+ (UIColor *)parseHexColor:(NSString *)s;

@end
