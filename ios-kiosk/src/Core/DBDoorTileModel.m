#import "DBDoorTileModel.h"

#import "DBMediaSource.h"

@interface DBDoorTileInfo ()
@property(nonatomic, readwrite, copy) NSString *doorId;
@property(nonatomic, readwrite, copy) NSString *label;
@property(nonatomic, readwrite, copy) NSString *servedBy;
@property(nonatomic, readwrite, strong) NSDictionary *peer;
@property(nonatomic, readwrite) BOOL configured;
@property(nonatomic, readwrite) BOOL online;
@property(nonatomic, readwrite, copy) NSString *snapshotURL;
@property(nonatomic, readwrite, copy) NSString *streamURL;
@end

@implementation DBDoorTileInfo

- (id)init {
  self = [super init];
  if (self) {
    _doorId = @"";
    _label = @"";
    _servedBy = @"";
    _snapshotURL = @"";
    _streamURL = @"";
  }
  return self;
}

@end

@implementation DBDoorTileModel

+ (NSDictionary *)dictionary:(NSDictionary *)root key:(NSString *)key {
  if (![root isKindOfClass:[NSDictionary class]]) return nil;
  id value = [root objectForKey:key];
  return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

+ (NSString *)string:(NSDictionary *)root key:(NSString *)key {
  if (![root isKindOfClass:[NSDictionary class]]) return @"";
  id value = [root objectForKey:key];
  return [value isKindOfClass:[NSString class]] ? value : @"";
}

+ (BOOL)flag:(NSDictionary *)root key:(NSString *)key def:(BOOL)def {
  if (![root isKindOfClass:[NSDictionary class]]) return def;
  id value = [root objectForKey:key];
  return [value isKindOfClass:[NSNumber class]] ? [(NSNumber *)value boolValue] : def;
}

+ (NSString *)peerID:(NSDictionary *)peer {
  NSString *identifier = [self string:peer key:@"id"];
  return [identifier length] > 0 ? identifier : [self string:peer key:@"node_id"];
}

+ (NSDictionary *)alivePeer:(NSDictionary *)status nodeId:(NSString *)nodeId {
  if ([nodeId length] == 0) return nil;
  id peers = [status objectForKey:@"peers"];
  if (![peers isKindOfClass:[NSArray class]]) return nil;
  for (id candidate in (NSArray *)peers) {
    if (![candidate isKindOfClass:[NSDictionary class]]) continue;
    if (![[self peerID:candidate] isEqualToString:nodeId]) continue;
    // "alive" is the only status that means the station can answer an HTTP
    // request right now; "offline", "dead" and a missing status are all down.
    return [[self string:candidate key:@"status"] isEqualToString:@"alive"] ? candidate : nil;
  }
  return nil;
}

+ (BOOL)peerHasCamera:(NSDictionary *)peer {
  NSDictionary *caps = [self dictionary:peer key:@"caps"];
  // "camera" is the cluster-wide key; "camera_capture" is what the iOS 5 shell
  // published before it existed. Either one saying no is a no.
  for (NSString *key in @[ @"camera", @"camera_capture" ]) {
    id value = [caps objectForKey:key];
    if ([value isKindOfClass:[NSNumber class]] && ![(NSNumber *)value boolValue]) return NO;
  }
  return YES;
}

// The station bound to a door, alive or not, so a tile can be suppressed for a
// camera-less device even while that device is down.
+ (NSDictionary *)stationForDoor:(NSDictionary *)status config:(NSDictionary *)config
                            door:(NSString *)doorId servedBy:(NSString *)servedBy {
  id peers = [status objectForKey:@"peers"];
  if (![peers isKindOfClass:[NSArray class]]) return nil;
  NSDictionary *fallback = nil;
  NSDictionary *devices = [self dictionary:config key:@"devices"];
  for (id candidate in (NSArray *)peers) {
    if (![candidate isKindOfClass:[NSDictionary class]]) continue;
    NSString *identifier = [self peerID:candidate];
    if ([servedBy length] > 0 && [identifier isEqualToString:servedBy]) return candidate;
    NSDictionary *device = [self dictionary:devices key:identifier];
    NSString *role = [self string:device key:@"role"];
    if ([role length] == 0) role = [self string:candidate key:@"role"];
    if (![role isEqualToString:@"door_station"]) continue;
    NSString *door = [self string:device key:@"door"];
    if ([door length] == 0) door = [self string:candidate key:@"door"];
    if (![door isEqualToString:doorId]) continue;
    if (fallback == nil) fallback = candidate;
  }
  return fallback;
}

+ (NSInteger)orderOf:(NSString *)doorId doors:(NSDictionary *)doors {
  NSDictionary *entry = [self dictionary:doors key:doorId];
  id order = [entry objectForKey:@"order"];
  return [order isKindOfClass:[NSNumber class]] ? [(NSNumber *)order integerValue] : 999;
}

// A core too old to publish status.doors still advertises door stations in the
// peer list; synthesise the same shape so the dashboard does not go blank
// against it.
+ (NSDictionary *)doorsFromPeers:(NSDictionary *)status config:(NSDictionary *)config {
  NSMutableDictionary *doors = [NSMutableDictionary dictionary];
  id peers = [status objectForKey:@"peers"];
  if (![peers isKindOfClass:[NSArray class]]) return doors;
  NSDictionary *configured = [self dictionary:config key:@"doors"];
  for (id candidate in (NSArray *)peers) {
    if (![candidate isKindOfClass:[NSDictionary class]]) continue;
    if (![[self string:candidate key:@"role"] isEqualToString:@"door_station"]) continue;
    NSString *door = [self string:candidate key:@"door"];
    if ([door length] == 0 || [doors objectForKey:door] != nil) continue;
    BOOL alive = [[self string:candidate key:@"status"] isEqualToString:@"alive"];
    [doors setObject:@{
      @"served_by" : alive ? [self peerID:candidate] : [NSNull null],
      @"label" : [self string:candidate key:@"door_label"],
      @"configured" : [NSNumber numberWithBool:
          ([self dictionary:configured key:door] != nil)],
    } forKey:door];
  }
  return doors;
}

+ (NSArray *)tilesFromStatus:(NSDictionary *)status
                      config:(NSDictionary *)config
                        boot:(DBBootConfig *)boot {
  NSDictionary *doors = [self dictionary:status key:@"doors"];
  if ([doors count] == 0) doors = [self doorsFromPeers:status config:config];
  if ([doors count] == 0) return @[];

  NSDictionary *configuredDoors = [self dictionary:config key:@"doors"];
  NSArray *ids = [[doors allKeys] sortedArrayUsingComparator:
      ^NSComparisonResult(NSString *a, NSString *b) {
        NSInteger orderA = [self orderOf:a doors:configuredDoors];
        NSInteger orderB = [self orderOf:b doors:configuredDoors];
        if (orderA != orderB) return orderA < orderB ? NSOrderedAscending : NSOrderedDescending;
        return [a compare:b];
      }];

  NSMutableArray *out = [NSMutableArray array];
  for (NSString *doorId in ids) {
    if (![doorId isKindOfClass:[NSString class]] || [doorId length] == 0) continue;
    NSDictionary *entry = [self dictionary:doors key:doorId];
    DBDoorTileInfo *tile = [[DBDoorTileInfo alloc] init];
    tile.doorId = doorId;
    tile.label = [self string:entry key:@"label"];
    // configured defaults to true so the fallback shape above and any core that
    // omits the flag still render a named door.
    tile.configured = [self flag:entry key:@"configured" def:YES];
    tile.servedBy = [self string:entry key:@"served_by"];
    // A station with no camera has nothing to watch. The door is still reachable
    // from the door list and still carries notices; only the still tile goes.
    NSDictionary *station = [self stationForDoor:status config:config door:doorId
                                        servedBy:tile.servedBy];
    if (station != nil && ![self peerHasCamera:station]) continue;
    NSDictionary *peer = [self alivePeer:status nodeId:tile.servedBy];
    tile.online = (peer != nil);
    if (!tile.online) {
      tile.servedBy = @"";
      [out addObject:tile];
      continue;
    }
    tile.peer = peer;
    DBMediaSource *source = [DBMediaSource sourceForPeer:peer config:config boot:boot
                                                    door:doorId deviceID:tile.servedBy];
    tile.snapshotURL = source.snapshotURL ?: @"";
    tile.streamURL = source.mjpegURL ?: @"";
    [out addObject:tile];
  }
  return out;
}

@end
