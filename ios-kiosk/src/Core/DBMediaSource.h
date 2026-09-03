#import <Foundation/Foundation.h>

@class DBBootConfig;

// Immutable, shell-level description of a door's video source. The primary
// input is media_sources.<id> plus devices.<self>.local.camera.source_ref;
// peer metadata and the legacy boot override are read-only migration inputs.
@interface DBMediaSource : NSObject

@property(nonatomic, readonly, copy) NSString *kind;  // node | ip_camera | none
@property(nonatomic, readonly, copy) NSString *sourceRef;
@property(nonatomic, readonly, copy) NSString *deviceID;
@property(nonatomic, readonly, copy) NSString *mjpegURL;
@property(nonatomic, readonly, copy) NSString *mp4URL;
@property(nonatomic, readonly, copy) NSString *snapshotURL;
@property(nonatomic, readonly, copy) NSString *h264URL;
@property(nonatomic, readonly, copy) NSString *h264Transport;
@property(nonatomic, readonly, copy) NSString *h264Profile;
@property(nonatomic, readonly, copy) NSString *secretRef;
@property(nonatomic, readonly, copy) NSString *videoMetaURL;
@property(nonatomic, readonly) BOOL explicitlyUnavailable;
@property(nonatomic, readonly) BOOL h264SourceAvailable;
@property(nonatomic, readonly) BOOL requiresH264Ingest;
@property(nonatomic, readonly, copy) NSString *degradedReason;

- (BOOL)hasVideo;
- (BOOL)hasPreview;
- (NSString *)preferredPreviewTransport;
- (BOOL)supportsDirectJPEGPlayback;

// "http://10.0.0.9:47180" for a peer, derived from the media URLs it
// advertises and falling back to its first mesh address. Empty when the peer
// carries neither.
+ (NSString *)originForPeer:(NSDictionary *)peer;

+ (DBMediaSource *)sourceForPeer:(NSDictionary *)peer
                          config:(NSDictionary *)config
                            boot:(DBBootConfig *)boot
                            door:(NSString *)door
                        deviceID:(NSString *)deviceID;

@end
