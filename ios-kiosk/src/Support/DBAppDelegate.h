#import <UIKit/UIKit.h>

@interface DBAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;

// UI 診断ダンプ (Documents/ui-dump.png + ui-dump.txt)。黒画面/画面異常の調査用。
- (void)diagDump;
@end
