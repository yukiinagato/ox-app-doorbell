#import <Foundation/Foundation.h>

@class DBFmp4Demux;

// fMP4 (ftyp+moov → moof+mdat 無限ライブ) の受信+解析クライアント。
// doorbell-core /stream.mp4 専用 (timescale=1000, avc1, default-base-is-moof,
// trun flags 0x701 = data_offset|duration|size|flags)。
//
// 設計 (DBMjpegClient と同じ骨格):
//  - BSD socket 専用スレッドで同期受信 (main runloop に乗らない)
//  - ISOBMFF box を自前パース (依存ゼロ)
//  - 出力は AVCC のまま (4 バイト長前置) — 私有 VideoToolbox へ直接渡す形式
@protocol DBFmp4DemuxDelegate <NSObject>
// init segment 解析完了 (avcC から SPS/PPS 抽出)。1 回だけ来る。main 以外のスレッド。
- (void)fmp4DemuxReady:(DBFmp4Demux *)demux sps:(NSData *)sps pps:(NSData *)pps;
// sample (1 access unit, AVCC)。main 以外のスレッドで逐次。durMs は推定表示間隔。
- (void)fmp4Demux:(DBFmp4Demux *)demux sample:(NSData *)avcc key:(BOOL)key
         captureMs:(int64_t)captureMs dtsMs:(int64_t)dtsMs durMs:(int64_t)durMs;
- (void)fmp4DemuxFailed:(DBFmp4Demux *)demux;  // トランスポート/解析致命傷 (1 回)
@end

@interface DBFmp4Demux : NSObject

- (id)initWithURLString:(NSString *)url delegate:(id<DBFmp4DemuxDelegate>)delegate;
- (void)start;  // 冪等
- (void)stop;   // 冪等。socket shutdown してスレッドを起床
// client epoch ms - server epoch ms, estimated from the response header.
- (int64_t)serverToClientOffsetMs;

@end
