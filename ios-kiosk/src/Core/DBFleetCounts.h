#import <Foundation/Foundation.h>

// What the dashboard header reports about the cluster: how many devices there
// are, and how many of each kind are answering right now. Counted from
// status.peers, which already carries the local node with self:true, so the
// local device is included exactly once.
@interface DBFleetCounts : NSObject

@property(nonatomic, readonly) NSInteger devices;             // Distinct peers, all roles.
@property(nonatomic, readonly) NSInteger devicesOnline;
@property(nonatomic, readonly) NSInteger doorStations;
@property(nonatomic, readonly) NSInteger doorStationsOnline;
@property(nonatomic, readonly) NSInteger panels;              // Indoor panels.
@property(nonatomic, readonly) NSInteger panelsOnline;

// A configured devices.<id>.role wins over the role a peer advertises, exactly
// as core resolves it: during commissioning a device announces itself before
// its configuration entry has replicated.
+ (DBFleetCounts *)countsFromStatus:(NSDictionary *)status config:(NSDictionary *)config;

@end
