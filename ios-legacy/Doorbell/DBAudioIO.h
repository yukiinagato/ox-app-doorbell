// RemoteIO ↔ ミニ SIP の音声配線 (計画 §6)。8kHz 単声道 int16。
//  - RemoteIO 出力 render callback → rxRing から取り出して門口の声を再生
//  - RemoteIO 入力 (外麦有時のみ) → txRing へ。iPad1 無マイク時は入力を張らず tx は 0 (無音)
// ミニ SIP の on_rx_audio / pull_tx_audio コールバック (poll スレッド) がこの 2 本の
// SPSC リングを叩く。AudioSession は C API で PlayAndRecord + スピーカ出力に設定。
#import <Foundation/Foundation.h>

@interface DBAudioIO : NSObject

@property(nonatomic, assign) BOOL micEnabled;  // 外部マイク (無ければ入力を張らない)

- (BOOL)start;
- (void)stop;

// ミニ SIP コールバックから呼ぶ (poll スレッド)。
- (void)enqueueRx:(const short *)pcm count:(int)n;  // 門口→スピーカ
- (int)dequeueTx:(short *)pcm max:(int)n;           // マイク→門口 (無音なら 0)

@end
