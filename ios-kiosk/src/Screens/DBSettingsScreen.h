#import "DBScreen.h"

@class DBRouter;

// Native settings (spec §3), reached from the indoor 管理 entry or the door
// station's hidden 7-tap corner, always behind the admin password.
// Large-row grouped UITableView; numbers are entered with the drawn keypad
// because iOS 5 has no usable IME and the system keyboard covers the field.
@interface DBSettingsScreen : DBScreen

- (id)initWithRouter:(DBRouter *)router;
- (void)reload;

@end
