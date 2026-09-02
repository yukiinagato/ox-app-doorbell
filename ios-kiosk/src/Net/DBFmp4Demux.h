#import <Foundation/Foundation.h>

@class DBFmp4Demux;

// Bounded streaming fMP4 reader for the iOS 5 compatibility path. It uses one network thread and
// a serial callback queue; stop drains callbacks before downstream mux/player state is released.


@protocol DBFmp4DemuxDelegate <NSObject>

- (void)fmp4DemuxReady:(DBFmp4Demux *)demux sps:(NSData *)sps pps:(NSData *)pps;

- (void)fmp4Demux:(DBFmp4Demux *)demux sample:(NSData *)avcc key:(BOOL)key
         captureMs:(int64_t)captureMs dtsMs:(int64_t)dtsMs durMs:(int64_t)durMs;
- (void)fmp4DemuxFailed:(DBFmp4Demux *)demux;
@end

@interface DBFmp4Demux : NSObject

- (id)initWithURLString:(NSString *)url delegate:(id<DBFmp4DemuxDelegate>)delegate;
- (void)start;
- (void)stop;
// client epoch ms - server epoch ms, estimated from the response header and
// compensated for half the request/response round trip.
- (int64_t)serverToClientOffsetMs;
// NO when the header was missing or implausible. Callers must then not treat
// a frame's computed age as meaningful.
- (BOOL)clockOffsetTrusted;

@end
