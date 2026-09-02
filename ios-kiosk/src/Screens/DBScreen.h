#import <UIKit/UIKit.h>

@class DBRouter;

// UIView-based screen foundation for iOS 5. Auto Layout is unavailable, so subclasses implement
// layoutSubviews and Router performs transitions without UIViewController presentation.
@interface DBScreen : UIView {
@protected
  __weak DBRouter *_router;
}

@property(nonatomic, weak) DBRouter *router;

- (NSString *)screenName;
- (void)onScreenWillAppear;
- (void)onScreenWillDisappear;


// Required workaround for devices whose legacy UILabel default background renders opaque white.
- (void)clearLabelBackgrounds:(UIView *)v;

@end
