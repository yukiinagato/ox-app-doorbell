#import <UIKit/UIKit.h>

@class DBRouter, DBUiPalette;

// Announcement editor, shown as a sheet inside its parent view: a navigation bar with Cancel
// and Show, and a grouped table for the target, saved messages, text, duration, and clearing.
// The dashboard, the settings page, and the incoming/monitor screen open the same control.
@interface DBNoticeDialog : UIView

- (id)initWithRouter:(DBRouter *)router;

// doorIds/doorLabels come from the caller's configuration snapshot so the dialog never reads
// Core on the main thread. A nil or empty preselectedDoor preselects the cluster-wide target.
// palette is unused: the sheet is stock UIKit and keeps the system colours.
- (void)presentInView:(UIView *)parent
               config:(NSDictionary *)config
              doorIds:(NSArray *)doorIds
           doorLabels:(NSDictionary *)doorLabels
      preselectedDoor:(NSString *)preselectedDoor
              palette:(DBUiPalette *)palette
           onFinished:(void (^)(BOOL changed))onFinished;

- (void)dismiss;

@end
