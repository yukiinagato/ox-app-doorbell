#import "DBScreen.h"

@class DBRouter;

// Native settings, always protected by the admin password.
@interface DBSettingsScreen : DBScreen

- (id)initWithRouter:(DBRouter *)router;
- (void)reload;

@end
