#import <Foundation/Foundation.h>

#import "DBBootConfig.h"
#import "DBDoorTileModel.h"
#import "DBMediaSource.h"

static void require(BOOL condition, NSString *message) {
  if (!condition) {
    NSLog(@"FAIL: %@", message);
    exit(1);
  }
}

// The indoor panel that reported the bug: role indoor_panel, no local camera.
static DBBootConfig *panelBoot(void) {
  DBBootConfig *boot = [[DBBootConfig alloc] init];
  boot.role = @"indoor_panel";
  boot.uiLang = @"ja";
  return boot;
}

// The exact peer shape /api/status publishes for the mini3 door station.
static NSDictionary *aliveStation(NSString *status) {
  return @{
    @"id" : @"c0ffee1122334455",
    @"name" : @"doorbell-ios",
    @"status" : status,
    @"role" : @"door_station",
    @"self" : @NO,
    @"door" : @"door-mini3",
    @"stream" : @"http://10.10.38.79:47180/stream.mjpeg",
    @"stream_mp4" : @"http://10.10.38.79:47180/stream.mp4",
    @"addrs" : @[ @"10.10.38.79:47172" ],
  };
}

static NSDictionary *panelSelf(void) {
  return @{
    @"id" : @"aabbccdd00112233",
    @"name" : @"panel",
    @"status" : @"alive",
    @"role" : @"indoor_panel",
    @"self" : @YES,
    @"addrs" : @[ @"10.10.38.147:47172" ],
  };
}

static NSDictionary *config(void) {
  return @{
    @"doors" : @{
      @"door-mini3" : @{@"order" : @1, @"label" : @{@"ja" : @"玄関"}},
    },
    @"devices" : @{
      @"c0ffee1122334455" : @{@"role" : @"door_station", @"door" : @"door-mini3",
                              @"name" : @"doorbell-ios"},
    },
  };
}

static DBDoorTileInfo *onlyTile(NSArray *tiles) {
  require([tiles count] == 1, @"exactly one door tile");
  return [tiles objectAtIndex:0];
}

int main(void) {
  @autoreleasepool {
    DBBootConfig *boot = panelBoot();

    // --- Origin resolution: the still follows the peer's advertised base. ---
    require([[DBMediaSource originForPeer:aliveStation(@"alive")]
                isEqualToString:@"http://10.10.38.79:47180"],
            @"the peer origin comes from its advertised stream URL");
    require([[DBMediaSource originForPeer:@{@"addrs" : @[ @"10.10.38.80:47172" ]}]
                isEqualToString:@"http://10.10.38.80:47180"],
            @"a peer with no stream URL falls back to its mesh address host");
    require([[DBMediaSource originForPeer:
                 @{@"stream" : @"http://user:pw@10.10.38.79:47180/stream.mjpeg"}] length] == 0,
            @"a credentialed stream URL never becomes an origin");
    require([[DBMediaSource originForPeer:@{}] length] == 0,
            @"a peer with neither stream nor address has no origin");

    // --- State 1: served_by names an alive station -> online, with a still. ---
    NSDictionary *online = @{
      @"peers" : @[ panelSelf(), aliveStation(@"alive") ],
      @"doors" : @{
        @"door-mini3" : @{@"served_by" : @"c0ffee1122334455", @"label" : @"玄関",
                          @"configured" : @YES, @"notice" : [NSNull null]},
      },
    };
    DBDoorTileInfo *tile = onlyTile([DBDoorTileModel tilesFromStatus:online
                                                              config:config() boot:boot]);
    require([tile.doorId isEqualToString:@"door-mini3"], @"tile is keyed by the door");
    require(tile.online, @"served_by naming an alive station is online");
    require(tile.configured, @"the configured flag is carried through");
    require([tile.servedBy isEqualToString:@"c0ffee1122334455"], @"tile keeps the station id");
    require(tile.peer != nil, @"an online tile carries the serving peer for the monitor tap");
    require([tile.snapshotURL isEqualToString:@"http://10.10.38.79:47180/snapshot.jpg"],
            @"the still is fetched from the serving peer's stream base");
    require([tile.streamURL isEqualToString:@"http://10.10.38.79:47180/stream.mjpeg"],
            @"the tile exposes the peer's advertised MJPEG stream");

    // A station whose HTTP origin is not the mesh address must still resolve:
    // this is the shape that made the fixed 47180-on-addrs[0] guess wrong.
    NSMutableDictionary *moved = [aliveStation(@"alive") mutableCopy];
    [moved setObject:@"http://10.10.38.79:8080/stream.mjpeg" forKey:@"stream"];
    [moved setObject:@[ @"192.168.9.9:47172", @"10.10.38.79:47172" ] forKey:@"addrs"];
    NSDictionary *movedStatus = @{
      @"peers" : @[ panelSelf(), moved ],
      @"doors" : @{
        @"door-mini3" : @{@"served_by" : @"c0ffee1122334455", @"configured" : @YES},
      },
    };
    tile = onlyTile([DBDoorTileModel tilesFromStatus:movedStatus config:config() boot:boot]);
    require([tile.snapshotURL isEqualToString:@"http://10.10.38.79:8080/snapshot.jpg"],
            @"the still follows the advertised origin, not addrs[0] on a fixed port");

    // --- State 2: configured, but no alive station -> offline. ---
    NSDictionary *offline = @{
      @"peers" : @[ panelSelf() ],
      @"doors" : @{
        @"door-mini3" : @{@"served_by" : [NSNull null], @"label" : @"玄関",
                          @"configured" : @YES},
      },
    };
    tile = onlyTile([DBDoorTileModel tilesFromStatus:offline config:config() boot:boot]);
    require([tile.doorId isEqualToString:@"door-mini3"], @"a door with no station still tiles");
    require(!tile.online, @"served_by null is offline");
    require(tile.configured, @"the door is still configured while its station is down");
    require(tile.peer == nil && [tile.snapshotURL length] == 0,
            @"an offline tile fetches no still");

    // The station is listed but not alive: still offline, never online because
    // a stale served_by happens to name it.
    NSDictionary *stale = @{
      @"peers" : @[ panelSelf(), aliveStation(@"offline") ],
      @"doors" : @{
        @"door-mini3" : @{@"served_by" : @"c0ffee1122334455", @"configured" : @YES},
      },
    };
    tile = onlyTile([DBDoorTileModel tilesFromStatus:stale config:config() boot:boot]);
    require(!tile.online && [tile.snapshotURL length] == 0,
            @"served_by naming a peer that is not alive is offline");
    NSDictionary *dead = @{
      @"peers" : @[ panelSelf(), aliveStation(@"dead") ],
      @"doors" : @{
        @"door-mini3" : @{@"served_by" : @"c0ffee1122334455", @"configured" : @YES},
      },
    };
    require(!onlyTile([DBDoorTileModel tilesFromStatus:dead config:config() boot:boot]).online,
            @"a dead station is offline");

    // --- State 3: no door station anywhere -> no tiles at all. ---
    NSDictionary *noStation = @{ @"peers" : @[ panelSelf() ], @"doors" : @{} };
    require([[DBDoorTileModel tilesFromStatus:noStation config:@{} boot:boot] count] == 0,
            @"a cluster with no doors renders no tiles");
    require([[DBDoorTileModel tilesFromStatus:@{} config:@{} boot:boot] count] == 0,
            @"an empty status renders no tiles");

    // An unconfigured door that a live station advertises is still online: the
    // Admin doors tab is where it gets a name, not a precondition for video.
    NSDictionary *unconfigured = @{
      @"peers" : @[ panelSelf(), aliveStation(@"alive") ],
      @"doors" : @{
        @"door-mini3" : @{@"served_by" : @"c0ffee1122334455", @"label" : @"doorbell-ios",
                          @"configured" : @NO},
      },
    };
    tile = onlyTile([DBDoorTileModel tilesFromStatus:unconfigured config:@{} boot:boot]);
    require(tile.online && !tile.configured, @"an unconfigured live door is online");
    require([tile.label isEqualToString:@"doorbell-ios"], @"core's fallback label survives");

    // A core too old to publish status.doors keeps the dashboard populated.
    NSDictionary *legacy = @{ @"peers" : @[ panelSelf(), aliveStation(@"alive") ] };
    tile = onlyTile([DBDoorTileModel tilesFromStatus:legacy config:config() boot:boot]);
    require(tile.online &&
            [tile.snapshotURL isEqualToString:@"http://10.10.38.79:47180/snapshot.jpg"],
            @"a status without a doors map falls back to the peer list");

    // Ordering is configuration order, then the door id, so tiles do not swap
    // places between status polls.
    NSDictionary *two = @{
      @"peers" : @[ panelSelf(), aliveStation(@"alive") ],
      @"doors" : @{
        @"door-mini3" : @{@"served_by" : @"c0ffee1122334455", @"configured" : @YES},
        @"door-back" : @{@"served_by" : [NSNull null], @"configured" : @YES},
      },
    };
    NSArray *tiles = [DBDoorTileModel tilesFromStatus:two config:config() boot:boot];
    require([tiles count] == 2, @"both doors render");
    require([[[tiles objectAtIndex:0] doorId] isEqualToString:@"door-mini3"] &&
            [[[tiles objectAtIndex:1] doorId] isEqualToString:@"door-back"],
            @"doors.<id>.order wins over the door id");

    // --- caps.camera: a station with nothing to show gets no tile. ---
    require([DBDoorTileModel peerHasCamera:aliveStation(@"alive")],
            @"a peer with no caps at all is assumed to have a camera");
    NSMutableDictionary *withCamera = [aliveStation(@"alive") mutableCopy];
    [withCamera setObject:@{@"camera" : @YES} forKey:@"caps"];
    NSMutableDictionary *noCamera = [aliveStation(@"alive") mutableCopy];
    [noCamera setObject:@{@"camera" : @NO} forKey:@"caps"];
    NSMutableDictionary *legacyNoCamera = [aliveStation(@"alive") mutableCopy];
    // The iOS 5 shell published camera_capture before the cluster-wide key existed.
    [legacyNoCamera setObject:@{@"camera_capture" : @NO} forKey:@"caps"];
    require([DBDoorTileModel peerHasCamera:withCamera], @"caps.camera true has a camera");
    require(![DBDoorTileModel peerHasCamera:noCamera], @"caps.camera false has none");
    require(![DBDoorTileModel peerHasCamera:legacyNoCamera],
            @"caps.camera_capture false has none");

    NSDictionary *doorsEntry = @{
      @"door-mini3" : @{@"served_by" : @"c0ffee1122334455", @"configured" : @YES},
    };
    NSDictionary *cameraTrue = @{ @"peers" : @[ panelSelf(), withCamera ], @"doors" : doorsEntry };
    require([[DBDoorTileModel tilesFromStatus:cameraTrue config:config() boot:boot] count] == 1,
            @"a station that reports a camera keeps its tile");
    NSDictionary *cameraFalse = @{ @"peers" : @[ panelSelf(), noCamera ], @"doors" : doorsEntry };
    require([[DBDoorTileModel tilesFromStatus:cameraFalse config:config() boot:boot] count] == 0,
            @"a station that reports no camera renders no tile");
    NSDictionary *cameraAbsent = @{
      @"peers" : @[ panelSelf(), aliveStation(@"alive") ], @"doors" : doorsEntry,
    };
    require([[DBDoorTileModel tilesFromStatus:cameraAbsent config:config() boot:boot] count] == 1,
            @"a station that reports no camera capability at all keeps its tile");

    // The suppression follows the device, not its current state: an iPad 1 door
    // station that is merely down still has nothing worth a tile.
    NSMutableDictionary *downNoCamera = [noCamera mutableCopy];
    [downNoCamera setObject:@"dead" forKey:@"status"];
    NSDictionary *downStatus = @{
      @"peers" : @[ panelSelf(), downNoCamera ],
      @"doors" : @{@"door-mini3" : @{@"served_by" : [NSNull null], @"configured" : @YES}},
    };
    require([[DBDoorTileModel tilesFromStatus:downStatus config:config() boot:boot] count] == 0,
            @"a camera-less station gets no tile even while it is offline");

    puts("PASS: DBDoorTileModel online/offline/no-station states");
  }
  return 0;
}
