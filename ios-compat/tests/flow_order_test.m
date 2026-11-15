#import <Foundation/Foundation.h>

#import "DBFlowOrder.h"
#import "DBPurposeModel.h"

// The flow editor's step order and the whole-step writes a reorder needs, plus the icon the editor
// and the door screen choose for an option.

static int failures = 0;

static void Require(BOOL condition, NSString *message) {
  if (!condition) {
    NSLog(@"FAIL: %@", message);
    failures++;
  }
}

static NSDictionary *Page(NSString *to, NSNumber *order) {
  NSMutableDictionary *step = [NSMutableDictionary dictionaryWithObjectsAndKeys:
      @"page", @"kind", @[ @{ @"id" : @"o1", @"to" : to } ], @"options", nil];
  if (order != nil) [step setObject:order forKey:@"order"];
  return step;
}

static NSDictionary *Flow(void) {
  return @{ @"start" : @"s_home", @"steps" : @{
    @"s_home" : @{ @"kind" : @"page", @"options" : @[ @{ @"id" : @"a", @"to" : @"s_two" },
                                                       @{ @"id" : @"b", @"to" : @"c_any" } ] },
    @"s_two" : Page(@"e_end", nil),
    @"c_any" : @{ @"kind" : @"call", @"on_unanswered" : @"s_lost" },
    @"e_end" : @{ @"kind" : @"end" },
    @"s_lost" : Page(@"c_any", nil),
    @"s_orphan" : Page(@"c_any", nil) } };
}

static void TestReadingOrder(void) {
  NSArray *expected = @[ @"s_home", @"s_two", @"c_any", @"e_end", @"s_lost", @"s_orphan" ];
  Require([[DBFlowOrder stepOrderForFlow:Flow()] isEqualToArray:expected],
          @"without any order the list is the reading order");
  Require([[DBFlowOrder readingOrderForFlow:Flow()] isEqualToArray:expected],
          @"reading order: start, breadth-first, then unreachable by id");
}

static void TestOrderedStepsComeFirst(void) {
  NSMutableDictionary *flow = [Flow() mutableCopy];
  NSMutableDictionary *steps = [[flow objectForKey:@"steps"] mutableCopy];
  [steps setObject:Page(@"c_any", @5) forKey:@"s_orphan"];
  [steps setObject:Page(@"e_end", @2) forKey:@"s_two"];
  [flow setObject:steps forKey:@"steps"];
  NSArray *order = [DBFlowOrder stepOrderForFlow:flow];
  Require([[order subarrayWithRange:NSMakeRange(0, 2)] isEqualToArray:
              @[ @"s_two", @"s_orphan" ]], @"steps with an order lead, ascending");
  Require([[order subarrayWithRange:NSMakeRange(2, 4)] isEqualToArray:
              @[ @"s_home", @"c_any", @"e_end", @"s_lost" ]], @"the rest keep reading order");

  // Ties keep reading order; unusable values count as no order.
  [steps setObject:Page(@"c_any", @2) forKey:@"s_orphan"];
  [steps setObject:Page(@"e_end", @2) forKey:@"s_two"];
  [steps setObject:Page(@"c_any", @(-1)) forKey:@"s_lost"];
  NSMutableDictionary *home = [[steps objectForKey:@"s_home"] mutableCopy];
  [home setObject:@1.5 forKey:@"order"];
  [steps setObject:home forKey:@"s_home"];
  NSMutableDictionary *flag = [[steps objectForKey:@"e_end"] mutableCopy];
  [flag setObject:@YES forKey:@"order"];
  [steps setObject:flag forKey:@"e_end"];
  [flow setObject:steps forKey:@"steps"];
  order = [DBFlowOrder stepOrderForFlow:flow];
  Require([[order subarrayWithRange:NSMakeRange(0, 2)] isEqualToArray:
              @[ @"s_two", @"s_orphan" ]], @"equal orders keep reading order");
  Require([[order subarrayWithRange:NSMakeRange(2, 4)] isEqualToArray:
              @[ @"s_home", @"c_any", @"e_end", @"s_lost" ]],
          @"fractional, negative and boolean orders count as none");
}

static void TestMoveWritesConsecutiveOrders(void) {
  NSDictionary *flow = Flow();
  NSArray *sequence = [DBFlowOrder stepOrderForFlow:flow];
  NSArray *moved = [DBFlowOrder sequence:sequence movingFrom:4 to:1];
  Require([moved isEqualToArray:
              @[ @"s_home", @"s_lost", @"s_two", @"c_any", @"e_end", @"s_orphan" ]],
          @"UITableView move semantics");
  NSArray *writes = [DBFlowOrder writesForSequence:moved steps:[flow objectForKey:@"steps"]];
  // Nothing had an order, so every step gets one, including the ones that did not move.
  Require([writes count] == 6, @"first reorder writes every step");
  for (NSUInteger i = 0; i < [writes count]; i++) {
    NSDictionary *write = [writes objectAtIndex:i];
    Require([[write objectForKey:@"id"] isEqual:[moved objectAtIndex:i]], @"writes follow the sequence");
    Require([[[write objectForKey:@"step"] objectForKey:@"order"] isEqual:@(i)],
            @"orders are 0, 1, 2, ...");
  }
  NSDictionary *lost = [[writes objectAtIndex:1] objectForKey:@"step"];
  Require([[lost objectForKey:@"kind"] isEqual:@"page"] && [[lost objectForKey:@"options"] count] == 1,
          @"the whole step is written, not only the order");

  // A second move rewrites only the steps whose position changed.
  NSMutableDictionary *steps = [NSMutableDictionary dictionary];
  for (NSDictionary *write in writes)
    [steps setObject:[write objectForKey:@"step"] forKey:[write objectForKey:@"id"]];
  NSMutableDictionary *next = [flow mutableCopy];
  [next setObject:steps forKey:@"steps"];
  NSArray *again = [DBFlowOrder stepOrderForFlow:next];
  Require([again isEqualToArray:moved], @"the saved orders list the new sequence");
  NSArray *swap = [DBFlowOrder sequence:again movingFrom:2 to:3];
  NSArray *second = [DBFlowOrder writesForSequence:swap steps:steps];
  Require([second count] == 2, @"a swap rewrites two steps");
  Require([[[second objectAtIndex:0] objectForKey:@"id"] isEqual:@"c_any"] &&
              [[[[second objectAtIndex:0] objectForKey:@"step"] objectForKey:@"order"] isEqual:@2],
          @"the swapped steps take each other's order");
  Require([[DBFlowOrder sequence:again movingFrom:2 to:2] isEqualToArray:again] &&
              [[DBFlowOrder sequence:again movingFrom:9 to:0] isEqualToArray:again],
          @"a no-op or out-of-range move changes nothing");
}

static void TestNewAndDuplicatedSteps(void) {
  NSMutableDictionary *steps = [NSMutableDictionary dictionary];
  NSArray *base = @[ @"s_home", @"c_any", @"e_end" ];
  for (NSUInteger i = 0; i < [base count]; i++)
    [steps setObject:@{ @"kind" : @"call", @"order" : @(i), @"purpose" : @"p_visit" }
              forKey:[base objectAtIndex:i]];
  [steps setObject:@{ @"kind" : @"call", @"purpose" : @"p_visit", @"order" : @1 } forKey:@"s_copy"];

  NSArray *appended = [DBFlowOrder sequence:base inserting:@"s_new" after:nil];
  [steps setObject:@{ @"kind" : @"end" } forKey:@"s_new"];
  NSArray *writes = [DBFlowOrder writesForSequence:appended steps:steps];
  Require([writes count] == 1 && [[[writes firstObject] objectForKey:@"id"] isEqual:@"s_new"] &&
              [[[[writes firstObject] objectForKey:@"step"] objectForKey:@"order"] isEqual:@3],
          @"a new step takes the next order and nothing else is rewritten");

  NSArray *duplicated = [DBFlowOrder sequence:base inserting:@"s_copy" after:@"s_home"];
  Require([duplicated isEqualToArray:@[ @"s_home", @"s_copy", @"c_any", @"e_end" ]],
          @"a copy sits right after its original");
  writes = [DBFlowOrder writesForSequence:duplicated steps:steps];
  NSMutableArray *ids = [NSMutableArray array];
  for (NSDictionary *write in writes) [ids addObject:[write objectForKey:@"id"]];
  Require([ids isEqualToArray:@[ @"c_any", @"e_end" ]],
          @"the copy already carries the right order; the steps after it move down by one");
  Require([[[[writes firstObject] objectForKey:@"step"] objectForKey:@"purpose"] isEqual:@"p_visit"],
          @"members other than order survive");
}

static void TestOptionIcons(void) {
  Require([[DBPurposeModel iconNameForOptionPurpose:@"p_delivery" icon:@"\U0001F3E0"]
              isEqualToString:@"f7:cube_box_fill"], @"a purpose beats the typed icon");
  Require([DBPurposeModel iconNameForOptionPurpose:nil icon:@""] == nil &&
              [DBPurposeModel iconNameForOptionPurpose:@"" icon:@"  "] == nil,
          @"an option without purpose or icon has none");
  struct { NSString *icon; NSString *name; } cases[] = {
    { @"\U0001F3E0", @"f7:house_fill" },
    { @"\U0001F4E6", @"f7:cube_box_fill" },
    { @"✉️", @"f7:envelope_fill" },
    { @"\U0001F4EE", @"f7:envelope_fill" },
    { @"\U0001F6CD️", @"f7:bag_fill" },
    { @"\U0001F4BC", @"f7:bag_fill" },
    { @"\U0001F527", @"f7:hammer_fill" },
    { @"\U0001F6E0️", @"f7:hammer_fill" },
    { @"…", @"f7:ellipsis_circle_fill" },
    { @"\U0001F514", @"f7:bell_fill" },
    { @"package", @"f7:cube_box_fill" },
    { @"✍️", @"f7:person_fill" },
    { @"\U0001F984", @"f7:person_fill" },
  };
  for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++)
    Require([[DBPurposeModel iconNameForOptionPurpose:nil icon:cases[i].icon]
                isEqualToString:cases[i].name],
            [NSString stringWithFormat:@"icon case %zu maps to %@", i, cases[i].name]);
  for (NSArray *choice in [DBPurposeModel optionIconChoices])
    Require([[DBPurposeModel iconNameForOptionPurpose:nil icon:[choice objectAtIndex:0]]
                isEqualToString:[choice objectAtIndex:2]],
            [NSString stringWithFormat:@"the picker's %@ maps to its own icon",
             [choice objectAtIndex:1]]);
}

int main(void) {
  @autoreleasepool {
    TestReadingOrder();
    TestOrderedStepsComeFirst();
    TestMoveWritesConsecutiveOrders();
    TestNewAndDuplicatedSteps();
    TestOptionIcons();
  }
  if (failures > 0) {
    NSLog(@"%d failure(s)", failures);
    return 1;
  }
  NSLog(@"flow_order_test: ok");
  return 0;
}
