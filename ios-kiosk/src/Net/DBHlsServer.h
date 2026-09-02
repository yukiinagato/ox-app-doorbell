#import <Foundation/Foundation.h>

// Loopback-only HLS server for MPMoviePlayerController. The playlist exposes five recent segments
// while eighteen remain fetchable for the slow A4-era startup probe. Each instance uses an
// ephemeral port so simultaneous diagnostic and incoming-call players never share segments.
@interface DBHlsServer : NSObject

- (BOOL)start;
- (void)stop;
- (NSInteger)port;
- (NSString *)playlistUrl;     // http://127.0.0.1:<port>/live.m3u8


- (void)addSegment:(NSData *)ts durationMs:(int64_t)durationMs;
- (NSUInteger)segmentCount;

@end
