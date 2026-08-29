#import <UIKit/UIKit.h>

@class DBRouter;

// 画面の基底。iOS 5.1 の脆弱な UIViewController モーダル機構を一切使わないため、
// 画面は単なる UIView。遷移は DBRouter が addSubview/removeFromSuperview で行い、
// レイアウトは layoutSubviews だけで表現する (Auto Layout は iOS 6+ のため不使用)。
@interface DBScreen : UIView {
@protected
  __weak DBRouter *_router;
}

@property(nonatomic, weak) DBRouter *router;

- (NSString *)screenName;  // watchdog 取证用
- (void)onScreenWillAppear;
- (void)onScreenWillDisappear;

// 全ラベル背景を透明化 (この個体は UILabel 既定背景が不透明白のため再帰で潰す)
- (void)clearLabelBackgrounds:(UIView *)v;

@end
