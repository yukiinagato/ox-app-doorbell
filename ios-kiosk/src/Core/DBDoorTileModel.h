#import <Foundation/Foundation.h>

@class DBBootConfig;

// One dashboard door tile, resolved from status.doors rather than from the raw
// peer list. Core publishes doors.<id>.served_by as the node id of the alive
// door station serving that door, which is the only thing that separates
// "nobody serves this door" from "the station that serves it is down". A still
// that has not arrived yet is not evidence of either.
@interface DBDoorTileInfo : NSObject

@property(nonatomic, readonly, copy) NSString *doorId;
@property(nonatomic, readonly, copy) NSString *label;      // Core's label, may be empty.
@property(nonatomic, readonly, copy) NSString *servedBy;   // Node id, empty when none.
@property(nonatomic, readonly, strong) NSDictionary *peer; // Serving peer, nil when offline.
@property(nonatomic, readonly) BOOL configured;            // doors.<id> exists in config.
@property(nonatomic, readonly) BOOL online;                // served_by names an alive peer.
@property(nonatomic, readonly, copy) NSString *snapshotURL;  // Empty unless online.
@property(nonatomic, readonly, copy) NSString *streamURL;    // Empty unless online.

@end

@interface DBDoorTileModel : NSObject

// Configuration order (doors.<id>.order, then the door id) so the dashboard
// keeps a stable tile order across status refreshes.
+ (NSArray *)tilesFromStatus:(NSDictionary *)status
                      config:(NSDictionary *)config
                        boot:(DBBootConfig *)boot;

// The peer entry for a node id, only when the mesh reports it alive.
+ (NSDictionary *)alivePeer:(NSDictionary *)status nodeId:(NSString *)nodeId;

@end
