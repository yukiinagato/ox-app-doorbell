#import <Foundation/Foundation.h>

// 127.0.0.1 のみに listen する超小物 HTTP server — MPMoviePlayer へ HLS
// (live.m3u8 + .ts セグメント) を供給する。セグメントはメモリ内で最大 5 個保持。
// player ごとに loopback の ephemeral port を使うため、診断 player と来鈴 player が
// 同時に存在してもセグメントを混ぜない。
@interface DBHlsServer : NSObject

- (BOOL)start;                 // 冪等 (既に listen 済みなら YES)
- (void)stop;                  // listen socket を閉じ、セグメントを廃棄
- (NSInteger)port;
- (NSString *)playlistUrl;     // http://127.0.0.1:<port>/live.m3u8

// セグメント追加 (durationMs 実測)。5 個を超えると最古を捨てる。任意スレッド可。
- (void)addSegment:(NSData *)ts durationMs:(int64_t)durationMs;
- (NSUInteger)segmentCount;  // 現在保持している段数

@end
