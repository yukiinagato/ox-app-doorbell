#import <Foundation/Foundation.h>

// Coalescing by generation: starting new work supersedes all earlier pending work, whose
// completion then finds its token stale and does nothing. Main thread only.
NSUInteger DBLatestWinsBegin(NSUInteger *generation);
BOOL DBLatestWinsIsCurrent(NSUInteger generation, NSUInteger token);
