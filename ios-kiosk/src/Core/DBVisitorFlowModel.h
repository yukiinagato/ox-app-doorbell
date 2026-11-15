#import <Foundation/Foundation.h>

// The shell-side walker of the resolved visitor flow (docs/en/visitor-flow-contract.md, section
// 5). It holds navigation state only and imports no UI: a tap, Back, an idle timeout, a call
// ending or a replaced document go in, and the Core calls the shell must make come out. It never
// reads raw configuration and never invents text. tools/conformance/visitor_flow.py is the
// reference; ios-compat/tests/visitor_flow_model_test.m runs the shared fixture against this class.
extern NSString *const DBVisitorFlowModePage;
extern NSString *const DBVisitorFlowModeCalling;
extern NSString *const DBVisitorFlowModeEnd;
extern NSString *const DBVisitorFlowModeLegacy;
extern NSString *const DBVisitorFlowNoAnswerNotice;
extern NSString *const DBVisitorFlowCallFailedNotice;

@interface DBVisitorFlowModel : NSObject

- (id)initWithFlow:(NSDictionary *)flow lang:(NSString *)lang;

@property(nonatomic, copy) NSString *lang;
@property(nonatomic, readonly) NSDictionary *flow;
@property(nonatomic, readonly) NSString *mode;
@property(nonatomic, readonly) NSArray *stack;
@property(nonatomic, readonly) NSString *activeStep;
@property(nonatomic, readonly) NSString *notice;
@property(nonatomic, assign) BOOL reply;

// YES when the document is enabled and starts on a page; otherwise the shell shows its classic
// screen.
@property(nonatomic, readonly) BOOL active;

// The inputs the fixture's walk cases use: tap (+notify_result, press_result), back,
// idle_timeout, done, end_timeout, call_ended, reply, lang, flow_changed, and press_failed (the
// shell reports that a press it was asked to make returned no call). Returns the Core calls the
// input caused, in order: @{@"press": purpose} or @{@"notify": stepID}.
- (NSArray *)applyEvent:(NSDictionary *)event;

// What a tap on the option would ask Core for, without changing any state: @{@"action":
// @"local"} for a page or end page, @{@"action": @"press", @"purpose": p}, @{@"action":
// @"notify", @"step": id}, or nil when the option is not on screen.
- (NSDictionary *)planForTap:(NSString *)optionID;

// What is on screen, in the fixture's snapshot shape.
- (NSDictionary *)snapshot;

// The page (or end page) on screen, nil while calling or on the classic screen.
- (NSString *)currentStepID;
- (NSDictionary *)currentStep;
// The options of the page on screen as {id, semantic_id, label, icon, style, to, purpose}.
- (NSArray *)currentOptions;
- (BOOL)canGoBack;
- (NSString *)kindOfStep:(NSString *)stepID;
// Debug screens only: shows a page (with the start page beneath it) or an end page directly.
- (BOOL)jumpToStep:(NSString *)stepID;
- (NSTimeInterval)idleSeconds;
- (NSTimeInterval)returnSeconds;

// Language, then Japanese, then whatever the document carries; nil when the map is empty.
+ (NSString *)text:(id)map lang:(NSString *)lang;
- (NSString *)text:(id)map;

@end
