#import "DBScreen.h"
#import "../Media/DBSipSession.h"

// 来鈴画面。MJPEG 映像 + 応答/聞く/開錠/無視 + quick replies + 徽章。
// SIP 会話は DBRouter が唯一所有する (この画面は状態反映とボタン操作のみ)。
@interface DBIncomingScreen : DBScreen

- (id)initWithRouter:(DBRouter *)router;

// 来客情報を設定して表示準備 (main スレッド)。router.showIncoming から呼ばれる。
- (void)prepareWithDoor:(NSString *)door purpose:(NSString *)purpose lang:(NSString *)lang;

// 再来客 (同一画面表示中の purpose/lang 更新)
- (void)refreshPurpose:(NSString *)purpose lang:(NSString *)lang;

// SIP 状態 (DBRouter が画面表示中のみ転送)
- (void)sipStateChanged:(DBMiniSipState)state;

// core イベント (表示中のみ router が転送)
- (void)handleReplyEvent:(NSDictionary *)ev;
- (void)handleVisitorLangEvent:(NSDictionary *)ev;

@end
