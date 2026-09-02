#import <UIKit/UIKit.h>

// Shared typed accessors for dotted config paths, event dictionaries, peers, and colors.
@interface DBConfigUtil : NSObject

+ (id)dig:(NSDictionary *)root path:(NSString *)dotpath;
+ (NSString *)str:(NSDictionary *)root path:(NSString *)dotpath;  // Empty strings become nil.
+ (NSInteger)intVal:(NSDictionary *)root path:(NSString *)dotpath def:(NSInteger)def;
+ (long long)longLongVal:(NSDictionary *)root path:(NSString *)dotpath def:(long long)def;
+ (double)doubleVal:(NSDictionary *)root path:(NSString *)dotpath def:(double)def;
+ (BOOL)boolVal:(NSDictionary *)root path:(NSString *)dotpath def:(BOOL)def;

+ (NSInteger)orderOf:(NSString *)identifier map:(NSDictionary *)map;
+ (NSArray *)sortedByOrder:(NSDictionary *)map;  // Sorts by order, then identifier.
+ (NSString *)labelOf:(NSDictionary *)entry lang:(NSString *)lang fallback:(NSString *)fallback;

// Event accessors reject values with the wrong type.
+ (NSString *)evStr:(NSDictionary *)ev key:(NSString *)key;
+ (BOOL)evBool:(NSDictionary *)ev key:(NSString *)key;

// Peer lookup excludes the local node and dead peers.
+ (NSDictionary *)findDoorPeer:(NSDictionary *)status door:(NSString *)door;
+ (NSDictionary *)findPeer:(NSDictionary *)status nodeId:(NSString *)nodeId;
+ (NSDictionary *)findDoorPeer:(NSDictionary *)status host:(NSString *)host;
+ (NSArray *)doorPeers:(NSDictionary *)status;  // Live door stations with video.
+ (NSString *)peerHost:(NSDictionary *)peer;    // "1.2.3.4:47172" to "1.2.3.4".
+ (NSArray *)peerHosts:(NSDictionary *)peer;     // Stable, deduplicated address hosts.
+ (NSString *)urlHost:(NSString *)host;          // Adds URL brackets to IPv6 literals.

+ (UIColor *)parseHexColor:(NSString *)s;  // "#101418".
+ (NSDictionary *)emergencyPalette:(NSDictionary *)event;

@end
