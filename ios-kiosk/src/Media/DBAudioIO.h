#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>

// SIP 通話音声 I/O (RemoteIO AudioUnit)。poll スレッド (生産) と render/input
// コールバック (消費/生産) をロックフリーの単一生産者・単一消費者リングで繋ぐ。
// iOS5 では AudioSession C API を使う (PlayAndRecord + スピーカ出力)。
@interface DBAudioIO : NSObject

@property(nonatomic, assign) BOOL micEnabled;  // 外部マイク (無ければ入力を張らない)

- (BOOL)start;   // 失敗 NO (呼び出し側は発呼を諦める/继续無音でも可)
- (void)stop;
- (void)enqueueRx:(const short *)pcm count:(int)n;  // SIP 受信音声 → 出力
- (int)dequeueTx:(short *)pcm max:(int)n;           // 入力 → SIP 送信 (外麦無し時は 0)

@end
