#import "DBScreen.h"

@class DBRouter;

// Native settings, always protected by the admin password.
@interface DBSettingsScreen : DBScreen

- (id)initWithRouter:(DBRouter *)router;
- (void)reload;

// Opens one category by position; the debug start screen "settings:N" uses it.
- (void)selectCategory:(NSInteger)index;
// Debug builds only: times page open, category switches and writes into Documents/settingsperf.txt.
- (void)debugPerfProbe;

@end
