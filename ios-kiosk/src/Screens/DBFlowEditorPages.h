#import <Foundation/Foundation.h>

@class DBEditPage;
@class DBEditorView;
@class DBRouter;

// The visitor-flow editor of the kiosk settings (docs/en/visitor-flow-contract.md, section 8):
// enable, start pages, idle and require_call, the step pool, per-kind step pages, options,
// images from Assets, notify message and snapshot camera, templates, and the reset to the
// built-in wizard. Every edit is one whole step (or the leaves of the top-level keys) written as
// one batch; Core's validation errors are shown by name, and an unresolved configuration
// conflict is shown as such and never retried.
@interface DBFlowEditorPages : NSObject
- (id)initWithRouter:(DBRouter *)router editor:(DBEditorView *)editor;
- (DBEditPage *)rootPage;
- (DBEditPage *)stepPage:(NSString *)stepID;
// Debug start screens only: the editor over the built-in wizard's template, never written.
- (void)usePreviewTemplate;
// Debug start screens only: the try-it page after the given option taps.
- (DBEditPage *)previewPageAfterTaps:(NSArray *)optionIDs;
// Stops the photo picker and drops any pending upload.
- (void)close;
@end
