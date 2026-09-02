#import "DBScreen.h"

@class DBRouter;

// In-container PIN keypad. Avoiding modal presentation prevents the iOS 5 crash caused by
// presenting inside a dismissal transaction. Verification uses SHA-256 and locks for ten minutes
// after five failed attempts.
@interface DBPinOverlay : DBScreen

- (id)initWithRouter:(DBRouter *)router;
- (void)presentInView:(UIView *)parent then:(void (^)(void))onUnlocked;
- (void)dismiss;

@end
