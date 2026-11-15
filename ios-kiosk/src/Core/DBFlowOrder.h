#import <Foundation/Foundation.h>

// The order in which the flow editor lists steps and the writes a reorder needs
// (docs/en/visitor-flow-contract.md, sections 4 and 8). It works on the stored `visitor_flow`
// object, imports no UI and never talks to Core. `order` never affects walking; it only decides how
// steps are listed.
@interface DBFlowOrder : NSObject

// Core's `step_order`: steps with a usable integer `order` (0..9999) first by ascending order, then
// the rest; ties and unordered steps keep reading order (the start page, then breadth-first through
// option targets, notify `to` and `on_unanswered`, then unreachable steps by id).
+ (NSArray *)stepOrderForFlow:(NSDictionary *)flow;

// The reading order alone.
+ (NSArray *)readingOrderForFlow:(NSDictionary *)flow;

// UITableView's move: the row at `from` is removed and inserted at `to`. Out-of-range input returns
// the sequence unchanged.
+ (NSArray *)sequence:(NSArray *)sequence movingFrom:(NSInteger)from to:(NSInteger)to;

// `stepID` inserted right after `afterID`, or appended when afterID is nil or not listed.
+ (NSArray *)sequence:(NSArray *)sequence inserting:(NSString *)stepID after:(NSString *)afterID;

// Consecutive `order` values 0, 1, 2, ... for the sequence. Returns only the steps that must be
// rewritten, each as @{@"id": ..., @"step": <the whole step with its new order>}, in sequence order.
// `steps` maps step id to the whole stored step and must include steps that are not stored yet.
// Every other member of a step is kept as it is.
+ (NSArray *)writesForSequence:(NSArray *)sequence steps:(NSDictionary *)steps;

@end
