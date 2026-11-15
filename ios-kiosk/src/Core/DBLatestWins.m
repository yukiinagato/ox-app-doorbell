#import "DBLatestWins.h"

NSUInteger DBLatestWinsBegin(NSUInteger *generation) {
  *generation += 1;
  return *generation;
}

BOOL DBLatestWinsIsCurrent(NSUInteger generation, NSUInteger token) {
  return generation == token;
}
