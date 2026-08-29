#import <UIKit/UIKit.h>

// 設定ツリーをドットパスで辿る ("doors.d_front.label.ja")。無ければ nil。
// イベント dict からの型安全取り出し、door peer 解決、16進色パースなど共通 helper。
@interface DBConfigUtil : NSObject

+ (id)dig:(NSDictionary *)root path:(NSString *)dotpath;
+ (NSString *)str:(NSDictionary *)root path:(NSString *)dotpath;          // 空文字は nil
+ (NSInteger)intVal:(NSDictionary *)root path:(NSString *)dotpath def:(NSInteger)def;
+ (double)doubleVal:(NSDictionary *)root path:(NSString *)dotpath def:(double)def;
+ (BOOL)boolVal:(NSDictionary *)root path:(NSString *)dotpath def:(BOOL)def;

+ (NSInteger)orderOf:(NSString *)identifier map:(NSDictionary *)map;
+ (NSArray *)sortedByOrder:(NSDictionary *)map;  // keys を order → key 名順に
+ (NSString *)labelOf:(NSDictionary *)entry lang:(NSString *)lang fallback:(NSString *)fallback;

// イベント dict 取り出し (型が違っても安全)
+ (NSString *)evStr:(NSDictionary *)ev key:(NSString *)key;
+ (BOOL)evBool:(NSDictionary *)ev key:(NSString *)key;

// status.peers から door_station の peer を探す (自分/ dead は除外)
+ (NSDictionary *)findDoorPeer:(NSDictionary *)status door:(NSString *)door;
+ (NSString *)peerHost:(NSDictionary *)peer;  // "1.2.3.4:47172" → "1.2.3.4"

+ (UIColor *)parseHexColor:(NSString *)s;  // "#101418"

@end
