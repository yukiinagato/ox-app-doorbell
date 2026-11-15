#import <Foundation/Foundation.h>

// Coalescing by generation: starting new work supersedes all earlier pending work, whose
// completion then finds its token stale and does nothing. Main thread only.
NSUInteger DBLatestWinsBegin(NSUInteger *generation);
BOOL DBLatestWinsIsCurrent(NSUInteger generation, NSUInteger token);

// Echo suppression: a refresh that would show a value older than a write still in flight waits
// until the last write has completed.
void DBPendingWriteBegin(NSInteger *inFlight);
void DBPendingWriteEnd(NSInteger *inFlight);
BOOL DBPendingWritesIdle(NSInteger inFlight);
