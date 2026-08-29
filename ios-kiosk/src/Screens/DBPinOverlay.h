#import "DBScreen.h"

@class DBRouter;

// 管理 PIN 键盘覆盖层。UIViewController モーダルの代わりにコンテナに直接乗る
// (dismiss の CA commit コンテキスト内で present する iOS 5.1 クラッシュ構造が
//  物理的に存在しない)。SHA256 照合 + 5 失敗 10 分ロック。
// DBScreen 継承で clearLabelBackgrounds: (この個体の UILabel 白背景対策) を共用する。
@interface DBPinOverlay : DBScreen

- (id)initWithRouter:(DBRouter *)router;
- (void)presentInView:(UIView *)parent then:(void (^)(void))onUnlocked;
- (void)dismiss;

@end
