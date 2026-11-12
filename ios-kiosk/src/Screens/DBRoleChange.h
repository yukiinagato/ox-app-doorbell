#import <Foundation/Foundation.h>

@class DBEditPage;
@class DBEditorView;
@class DBRouter;

// The "Change role" form of this device's settings: role, and for a door station the door it
// serves. Nothing is written until the operator confirms; applying persists boot.json and
// takes the application's identity restart, after which Core republishes devices.<self>.
// The form refuses while a call, an SOS, or pairing is in progress.
@interface DBRoleChange : NSObject

- (id)initWithRouter:(DBRouter *)router editor:(DBEditorView *)editor;

// A fresh form seeded from the running identity. config and status are the caller's
// snapshots; nodeId is this device's id in them.
- (DBEditPage *)pageWithConfig:(NSDictionary *)config status:(NSDictionary *)status
                        nodeId:(NSString *)nodeId;

@end
