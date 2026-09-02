#import <UIKit/UIKit.h>

@class DBRouter, DBUiPalette;

// Announcement dialog (spec §4.3). The same control is opened from the
// dashboard's 「お知らせ（全体）」 button, from a door tile's chip, and from the
// monitor/incoming screen's 「この門口機にお知らせ」 entry.
@interface DBNoticeDialog : UIView

- (id)initWithRouter:(DBRouter *)router;

// doorIds/doorLabels come from the caller's configuration snapshot so the
// dialog never reads Core on the main thread. preselectedDoor of nil or an
// empty string preselects the 全体 target.
- (void)presentInView:(UIView *)parent
               config:(NSDictionary *)config
              doorIds:(NSArray *)doorIds
           doorLabels:(NSDictionary *)doorLabels
      preselectedDoor:(NSString *)preselectedDoor
              palette:(DBUiPalette *)palette
           onFinished:(void (^)(BOOL changed))onFinished;

- (void)dismiss;

@end
