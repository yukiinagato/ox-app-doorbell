#import <Foundation/Foundation.h>

#import "DBLatestWins.h"

static void require(BOOL condition, NSString *message) {
  if (!condition) {
    NSLog(@"FAIL: %@", message);
    exit(1);
  }
}

int main(void) {
  @autoreleasepool {
    NSUInteger generation = 0;
    NSUInteger ja = DBLatestWinsBegin(&generation);
    NSUInteger en = DBLatestWinsBegin(&generation);
    NSUInteger zh = DBLatestWinsBegin(&generation);
    require(!DBLatestWinsIsCurrent(generation, ja), @"the first tap is superseded");
    require(!DBLatestWinsIsCurrent(generation, en), @"the second tap is superseded");
    require(DBLatestWinsIsCurrent(generation, zh), @"only the final tap applies");
    NSUInteger later = DBLatestWinsBegin(&generation);
    require(!DBLatestWinsIsCurrent(generation, zh), @"a later tap supersedes an applied one");
    require(DBLatestWinsIsCurrent(generation, later), @"and is current itself");
    NSInteger inFlight = 0;
    DBPendingWriteBegin(&inFlight);
    DBPendingWriteBegin(&inFlight);
    require(!DBPendingWritesIdle(inFlight), @"refresh waits while writes are in flight");
    DBPendingWriteEnd(&inFlight);
    require(!DBPendingWritesIdle(inFlight), @"and until the last one completes");
    DBPendingWriteEnd(&inFlight);
    DBPendingWriteEnd(&inFlight);
    require(DBPendingWritesIdle(inFlight), @"idle once all are done, never negative");
    NSLog(@"latest_wins_test ok");
  }
  return 0;
}
