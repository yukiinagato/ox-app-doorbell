#import "DBScreen.h"

@class DBRouter;

// In-container admin password prompt: a dimming view with a centred panel holding a navigation
// bar (Cancel, Log in) and a one-row grouped form. It is a subview rather than a modal view
// controller because presenting inside a dismissal transaction crashes on iOS 5. Core verifies
// the cluster password and owns its lockout; five local failures also lock entry for ten
// minutes.
@interface DBPinOverlay : DBScreen

- (id)initWithRouter:(DBRouter *)router;
- (void)presentInView:(UIView *)parent then:(void (^)(void))onUnlocked;
- (void)dismiss;

@end
