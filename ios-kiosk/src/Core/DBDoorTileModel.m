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
@property(nonatomic, readwrite, copy) NSString *videoMetaURL;
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
    _videoMetaURL = @"";
  }
  return self;
}

@end

@implementation DBDoorTileModel

+ (NSInteger)videoRotationFromMetadata:(id)metadata fallback:(NSInteger)fallback {
  if (![metadata isKindOfClass:[NSDictionary class]]) return fallback;
  id value = [metadata objectForKey:@"rotation"];
  if (![value isKindOfClass:[NSNumber class]]) return fallback;
  double degrees = [value doubleValue];
  if (!(degrees >= -360 && degrees <= 360)) return fallback;
  NSInteger whole = (NSInteger)degrees;
  if (degrees != (double)whole || whole % 90 != 0) return fallback;
  return ((whole % 360) + 360) % 360;
}

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
    if ([self isRemovedStation:identifier config:config]) continue;
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

+ (BOOL)isRemovedStation:(NSString *)identifier config:(NSDictionary *)config {
  return [self flag:[self dictionary:config key:@"removed_devices"] key:identifier def:NO];
}

// A seeded door outlives its device in replicated configuration. It is not a
// video source after revocation unless another retained station uses that door.
+ (BOOL)isOrphanedDoor:(NSString *)doorId status:(NSDictionary *)status
                config:(NSDictionary *)config {
  NSDictionary *door = [self dictionary:[self dictionary:config key:@"doors"] key:doorId];
  if (![self isRemovedStation:[self string:door key:@"seeded_by"] config:config]) return NO;
  NSDictionary *devices = [self dictionary:config key:@"devices"];
  for (NSString *identifier in devices) {
    if ([self isRemovedStation:identifier config:config]) continue;
    NSDictionary *device = [self dictionary:devices key:identifier];
    if ([[self string:device key:@"role"] isEqualToString:@"door_station"] &&
        [[self string:device key:@"door"] isEqualToString:doorId]) return NO;
  }
  id peers = [status objectForKey:@"peers"];
  if ([peers isKindOfClass:[NSArray class]]) {
    for (NSDictionary *peer in peers) {
      if ([self isRemovedStation:[self peerID:peer] config:config]) continue;
      if ([[self string:peer key:@"role"] isEqualToString:@"door_station"] &&
          [[self string:peer key:@"door"] isEqualToString:doorId]) return NO;
    }
  }
  return YES;
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
    if ([self isRemovedStation:[self peerID:candidate] config:config]) continue;
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
  if (doors == nil) doors = [self doorsFromPeers:status config:config];
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
    if ([self isOrphanedDoor:doorId status:status config:config]) continue;
    NSDictionary *entry = [self dictionary:doors key:doorId];
    DBDoorTileInfo *tile = [[DBDoorTileInfo alloc] init];
    tile.doorId = doorId;
    tile.label = [self string:entry key:@"label"];
    // configured defaults to true so the fallback shape above and any core that
    // omits the flag still render a named door.
    tile.configured = [self flag:entry key:@"configured" def:YES];
    tile.servedBy = [self string:entry key:@"served_by"];
    if ([self isRemovedStation:tile.servedBy config:config]) tile.servedBy = @"";
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
    tile.videoMetaURL = source.videoMetaURL ?: @"";
    [out addObject:tile];
  }
  return out;
}

@end
