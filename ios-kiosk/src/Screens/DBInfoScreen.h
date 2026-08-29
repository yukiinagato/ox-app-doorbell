#import "DBScreen.h"

// 本機情報 / Debug 画面。debug JSON、ネットワーク、監視ポート、触発統計、
// 管理後台 URL の QR (IPv4/IPv6 切替・複数アドレスの循環)。
@interface DBInfoScreen : DBScreen

- (id)initWithRouter:(DBRouter *)router;
- (void)reload;

@end
