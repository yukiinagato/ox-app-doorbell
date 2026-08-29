// ミニ SIP (mini_sip/) の ObjC (ARC) ラッパ。門口機への直接監聴/応答呼を専用スレッドで
// 駆動する。1 セッション = 1 スレッド (ms_call → ms_poll ループ)。
//
// ライフタイム契約 (旧版 MRC で発覚した凍結バグの対策を ARC で構造化):
//  - NSThread は target をスレッド完走まで強参照で保持する → poll スレッド走行中は
//    オブジェクトが死なない (旧版の自己 retain と同じ意味が ARC で自動的に成立)。
//  - delegate は weak。画面側は消失前に delegate=nil する (状態配送の停止)。
//  - 同時に 1 セッション (管理は DBRouter が行う)。
#import <Foundation/Foundation.h>

// ms_state と同値 (0=calling / 1=in_call / 2=ended)。
typedef enum { DBMiniSipCalling = 0, DBMiniSipInCall = 1, DBMiniSipEnded = 2 } DBMiniSipState;

@protocol DBMiniSipDelegate <NSObject>
- (void)miniSipStateChanged:(DBMiniSipState)state;  // main スレッド
@end

@interface DBSipSession : NSObject

@property(nonatomic, weak) id<DBMiniSipDelegate> delegate;  // weak (ARC)

// host: 門口機 IP / port: SIP 待受 (既定 47190) / mode: "monitor"|"answer"|""
// micEnabled: 外部マイク有無 (応答用。監聴は無音送信で可)。
- (id)initWithHost:(NSString *)host port:(int)port mode:(NSString *)mode micEnabled:(BOOL)micEnabled;
- (void)start;                        // poll スレッド開始
- (void)hangup;                       // 非同期: poll スレッドが ms_hangup + ms_free する
- (void)sendDtmf:(NSString *)digits;  // "*1" 等 (開錠)

@end
