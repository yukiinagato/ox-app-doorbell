#import <Foundation/Foundation.h>

#import "DBFleetCounts.h"

static void require(BOOL condition, NSString *message) {
  if (!condition) {
    NSLog(@"FAIL: %@", message);
    exit(1);
  }
}

static NSDictionary *peer(NSString *identifier, NSString *role, NSString *status, BOOL isSelf) {
  return @{
    @"id" : identifier, @"role" : role, @"status" : status,
    @"self" : [NSNumber numberWithBool:isSelf],
  };
}

int main(void) {
  @autoreleasepool {
    // The live cluster: this panel, the mini3 door station, the android panel.
    NSDictionary *status = @{
      @"peers" : @[
        peer(@"75cd2ca1", @"indoor_panel", @"alive", YES),
        peer(@"787e91b5", @"door_station", @"alive", NO),
        peer(@"8e98f79e", @"indoor_panel", @"alive", NO),
      ],
    };
    DBFleetCounts *counts = [DBFleetCounts countsFromStatus:status config:@{}];
    require(counts.devices == 3, @"every peer counts once, the local node included");
    require(counts.devicesOnline == 3, @"all three are alive");
    require(counts.doorStations == 1 && counts.doorStationsOnline == 1, @"one live door station");
    require(counts.panels == 2 && counts.panelsOnline == 2, @"two live indoor panels");

    // The door station drops off the mesh: the totals hold, the online counts fall.
    NSDictionary *degraded = @{
      @"peers" : @[
        peer(@"75cd2ca1", @"indoor_panel", @"alive", YES),
        peer(@"787e91b5", @"door_station", @"dead", NO),
        peer(@"8e98f79e", @"indoor_panel", @"offline", NO),
      ],
    };
    counts = [DBFleetCounts countsFromStatus:degraded config:@{}];
    require(counts.devices == 3 && counts.devicesOnline == 1, @"a dead peer is still a device");
    require(counts.doorStations == 1 && counts.doorStationsOnline == 0,
            @"a dead door station is counted but not online");
    require(counts.panels == 2 && counts.panelsOnline == 1,
            @"offline is not alive");

    // A configured role wins over the advertised one, as core resolves it: a
    // station announces itself before its devices.<id> entry has replicated.
    NSDictionary *config = @{
      @"devices" : @{ @"787e91b5" : @{@"role" : @"door_station", @"door" : @"door-mini3"} },
    };
    NSDictionary *commissioning = @{
      @"peers" : @[
        peer(@"75cd2ca1", @"indoor_panel", @"alive", YES),
        peer(@"787e91b5", @"", @"alive", NO),
      ],
    };
    counts = [DBFleetCounts countsFromStatus:commissioning config:config];
    require(counts.doorStations == 1 && counts.doorStationsOnline == 1,
            @"the configured role names an unannounced door station");
    counts = [DBFleetCounts countsFromStatus:commissioning config:@{}];
    require(counts.devices == 2 && counts.doorStations == 0 && counts.panels == 1,
            @"a peer with no role at all is a device and nothing more");

    // One node listed twice is one device.
    NSDictionary *duplicated = @{
      @"peers" : @[
        peer(@"75cd2ca1", @"indoor_panel", @"alive", YES),
        peer(@"75cd2ca1", @"indoor_panel", @"alive", NO),
      ],
    };
    counts = [DBFleetCounts countsFromStatus:duplicated config:@{}];
    require(counts.devices == 1 && counts.panels == 1, @"a duplicate peer entry counts once");

    counts = [DBFleetCounts countsFromStatus:@{} config:@{}];
    require(counts.devices == 0 && counts.doorStations == 0 && counts.panels == 0,
            @"a status with no peers counts nothing");

    puts("PASS: DBFleetCounts cluster, door-station and panel counters");
  }
  return 0;
}
