#import "DBFlowOrder.h"

static NSDictionary *DBOrderDict(id value) {
  return [value isKindOfClass:[NSDictionary class]] ? value : @{};
}

// An integer in 0..9999 that is not a boolean; anything else is "no order".
static NSNumber *DBOrderValue(NSDictionary *step) {
  id value = [step objectForKey:@"order"];
  if (![value isKindOfClass:[NSNumber class]]) return nil;
  if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return nil;
  double number = [value doubleValue];
  if (number < 0 || number > 9999 || number != floor(number)) return nil;
  return value;
}

@implementation DBFlowOrder

+ (NSArray *)readingOrderForFlow:(NSDictionary *)flow {
  NSDictionary *steps = DBOrderDict([DBOrderDict(flow) objectForKey:@"steps"]);
  NSMutableArray *order = [NSMutableArray array];
  id start = [DBOrderDict(flow) objectForKey:@"start"];
  NSMutableArray *queue = [NSMutableArray array];
  if ([start isKindOfClass:[NSString class]] && [steps objectForKey:start] != nil)
    [queue addObject:start];
  while ([queue count] > 0) {
    NSString *current = [queue objectAtIndex:0];
    [queue removeObjectAtIndex:0];
    if ([order containsObject:current]) continue;
    [order addObject:current];
    NSDictionary *step = DBOrderDict([steps objectForKey:current]);
    id options = [step objectForKey:@"options"];
    if ([options isKindOfClass:[NSArray class]])
      for (id option in (NSArray *)options) {
        id target = [DBOrderDict(option) objectForKey:@"to"];
        if ([target isKindOfClass:[NSString class]] && [steps objectForKey:target] != nil)
          [queue addObject:target];
      }
    for (NSString *member in @[ @"to", @"on_unanswered" ]) {
      id target = [step objectForKey:member];
      if ([target isKindOfClass:[NSString class]] && [steps objectForKey:target] != nil)
        [queue addObject:target];
    }
  }
  for (NSString *stepID in [[steps allKeys] sortedArrayUsingSelector:@selector(compare:)])
    if (![order containsObject:stepID]) [order addObject:stepID];
  return order;
}

+ (NSArray *)stepOrderForFlow:(NSDictionary *)flow {
  NSDictionary *steps = DBOrderDict([DBOrderDict(flow) objectForKey:@"steps"]);
  NSArray *reading = [self readingOrderForFlow:flow];
  NSMutableArray *ordered = [NSMutableArray array];
  NSMutableArray *rest = [NSMutableArray array];
  for (NSString *stepID in reading) {
    if (DBOrderValue(DBOrderDict([steps objectForKey:stepID])) != nil) [ordered addObject:stepID];
    else [rest addObject:stepID];
  }
  // Ties keep reading order, so the reading position is the tie-breaker.
  NSArray *sorted = [ordered sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
    NSNumber *left = DBOrderValue(DBOrderDict([steps objectForKey:a]));
    NSNumber *right = DBOrderValue(DBOrderDict([steps objectForKey:b]));
    NSComparisonResult result = [left compare:right];
    if (result != NSOrderedSame) return result;
    return [@([reading indexOfObject:a]) compare:@([reading indexOfObject:b])];
  }];
  return [sorted arrayByAddingObjectsFromArray:rest];
}

+ (NSArray *)sequence:(NSArray *)sequence movingFrom:(NSInteger)from to:(NSInteger)to {
  NSInteger count = (NSInteger)[sequence count];
  if (from < 0 || to < 0 || from >= count || to >= count || from == to) return sequence;
  NSMutableArray *next = [NSMutableArray arrayWithArray:sequence];
  id moved = [next objectAtIndex:(NSUInteger)from];
  [next removeObjectAtIndex:(NSUInteger)from];
  [next insertObject:moved atIndex:(NSUInteger)to];
  return next;
}

+ (NSArray *)sequence:(NSArray *)sequence inserting:(NSString *)stepID after:(NSString *)afterID {
  NSMutableArray *next = [NSMutableArray arrayWithArray:sequence];
  [next removeObject:stepID];
  NSUInteger at = afterID != nil ? [next indexOfObject:afterID] : NSNotFound;
  if (at == NSNotFound) [next addObject:stepID];
  else [next insertObject:stepID atIndex:at + 1];
  return next;
}

+ (NSArray *)writesForSequence:(NSArray *)sequence steps:(NSDictionary *)steps {
  NSMutableArray *writes = [NSMutableArray array];
  for (NSUInteger i = 0; i < [sequence count]; i++) {
    NSString *stepID = [sequence objectAtIndex:i];
    NSDictionary *step = [steps objectForKey:stepID];
    if (![step isKindOfClass:[NSDictionary class]]) continue;
    NSNumber *current = DBOrderValue(step);
    if (current != nil && [current integerValue] == (NSInteger)i) continue;
    NSMutableDictionary *copy = [step mutableCopy];
    [copy setObject:[NSNumber numberWithUnsignedInteger:i] forKey:@"order"];
    [writes addObject:@{ @"id" : stepID, @"step" : copy }];
  }
  return writes;
}

@end
