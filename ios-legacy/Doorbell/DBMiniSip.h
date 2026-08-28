// ミニ SIP (ios-legacy/mini_sip) の ObjC ラッパ。門口機への直接監聴/応答呼を専用スレッドで
// 駆動する (計画 §5/§6)。スレッドモデル: 1 セッション = 1 スレッド (ms_call → ms_poll ループ)。
//  - on_rx_audio  → DBAudioIO enqueueRx (門口の声を再生)
//  - pull_tx_audio→ DBAudioIO dequeueTx (外麦。無ければ 0=無音)
//  - on_state     → main スレッドへ marshal して delegate へ
// DTMF/切断は main スレッドから要求を積み、poll スレッドが同スレッド契約を守って実行する。
#import <Foundation/Foundation.h>

// ms_state と同値 (0=calling / 1=in_call / 2=ended)。
typedef enum { DBMiniSipCalling = 0, DBMiniSipInCall = 1, DBMiniSipEnded = 2 } DBMiniSipState;

@protocol DBMiniSipDelegate <NSObject>
- (void)miniSipStateChanged:(DBMiniSipState)state;  // main スレッド
@end

@interface DBMiniSip : NSObject

@property(nonatomic, assign) id<DBMiniSipDelegate> delegate;  // weak

// host: 門口機 IP / port: SIP 待受 (既定 47190) / mode: "monitor"|"answer"|""
// micEnabled: 外部マイク有無 (答応用。監聴は無音送信で可)。
- (id)initWithHost:(NSString *)host port:(int)port mode:(NSString *)mode micEnabled:(BOOL)micEnabled;
- (void)start;
- (void)hangup;
- (void)sendDtmf:(NSString *)digits;  // "*1" 等 (開錠)

@end
