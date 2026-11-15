#import "DBLatestWins.h"

NSUInteger DBLatestWinsBegin(NSUInteger *generation) {
  *generation += 1;
  return *generation;
}

BOOL DBLatestWinsIsCurrent(NSUInteger generation, NSUInteger token) {
  return generation == token;
}

void DBPendingWriteBegin(NSInteger *inFlight) { *inFlight += 1; }

void DBPendingWriteEnd(NSInteger *inFlight) {
  if (*inFlight > 0) *inFlight -= 1;
}

BOOL DBPendingWritesIdle(NSInteger inFlight) { return inFlight == 0; }
