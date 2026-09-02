#import "DBScreen.h"

@class DBRouter;

// Full-screen call history (spec §5.1 "History"): filters (all / missed / by
// door), fifty rows per page with 「さらに読み込む」, grouped by day, mark-seen on
// open. Large rows, drawn with a plain grouped UITableView.
@interface DBHistoryScreen : DBScreen

- (id)initWithRouter:(DBRouter *)router;
- (void)reload;

@end
