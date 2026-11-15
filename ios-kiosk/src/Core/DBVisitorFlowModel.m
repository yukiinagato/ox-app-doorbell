#import "DBVisitorFlowModel.h"

NSString *const DBVisitorFlowModePage = @"page";
NSString *const DBVisitorFlowModeCalling = @"calling";
NSString *const DBVisitorFlowModeEnd = @"end";
NSString *const DBVisitorFlowModeLegacy = @"legacy";
NSString *const DBVisitorFlowNoAnswerNotice = @"calling.no_answer";
NSString *const DBVisitorFlowCallFailedNotice = @"flow.call_failed";

static const NSUInteger kMaxSteps = 34;

static NSDictionary *DBFlowDict(id value) {
  return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

static NSString *DBFlowString(id value) {
  return [value isKindOfClass:[NSString class]] ? value : nil;
}

static BOOL DBFlowTrue(id value) {
  return [value isKindOfClass:[NSNumber class]] && [value boolValue];
}

@implementation DBVisitorFlowModel {
  NSDictionary *_flow;
  NSString *_mode;
  NSMutableArray *_stack;
  NSString *_activeStep;
  NSString *_notice;
}

@synthesize flow = _flow, mode = _mode, activeStep = _activeStep, notice = _notice;

+ (NSString *)text:(id)map lang:(NSString *)lang {
  NSDictionary *labels = DBFlowDict(map);
  if (labels == nil) return nil;
  for (NSString *key in @[ lang ?: @"ja", @"ja" ]) {
    NSString *value = DBFlowString([labels objectForKey:key]);
    if ([value length] > 0) return value;
  }
  for (id value in [labels allValues])
    if ([DBFlowString(value) length] > 0) return value;
  return nil;
}

- (NSString *)text:(id)map {
  return [DBVisitorFlowModel text:map lang:_lang];
}

- (id)initWithFlow:(NSDictionary *)flow lang:(NSString *)lang {
  self = [super init];
  if (self) {
    _lang = [lang length] ? [lang copy] : @"ja";
    _stack = [[NSMutableArray alloc] init];
    [self load:flow];
    [self home];
  }
  return self;
}

- (NSArray *)stack { return [_stack copy]; }

- (void)load:(NSDictionary *)flow {
  NSDictionary *document = DBFlowDict(flow);
  NSDictionary *steps = DBFlowDict([document objectForKey:@"steps"]);
  // A document that is not an object, or carries an unbounded step table, is no flow at all.
  if ([document objectForKey:@"steps"] != nil && (steps == nil || [steps count] > kMaxSteps))
    document = nil;
  _flow = document ?: @{};
}

- (NSDictionary *)step:(id)stepID {
  NSDictionary *steps = DBFlowDict([_flow objectForKey:@"steps"]);
  NSString *key = DBFlowString(stepID);
  return key ? (DBFlowDict([steps objectForKey:key]) ?: @{}) : @{};
}

- (NSString *)kind:(id)stepID {
  return DBFlowString([[self step:stepID] objectForKey:@"kind"]) ?: @"";
}

- (NSString *)kindOfStep:(NSString *)stepID {
  return [self kind:stepID];
}

- (BOOL)jumpToStep:(NSString *)stepID {
  NSString *kind = [self kind:stepID];
  if (![self active]) return NO;
  [self home];
  if ([kind isEqualToString:@"page"]) {
    if (![stepID isEqual:[_flow objectForKey:@"start"]]) [_stack addObject:stepID];
    return YES;
  }
  if ([kind isEqualToString:@"end"]) {
    _mode = DBVisitorFlowModeEnd;
    _activeStep = stepID;
    return YES;
  }
  return NO;
}

- (BOOL)active {
  return DBFlowTrue([_flow objectForKey:@"enabled"]) &&
      [[self kind:[_flow objectForKey:@"start"]] isEqualToString:@"page"];
}

- (void)home {
  _activeStep = nil;
  [_stack removeAllObjects];
  if ([self active]) {
    _mode = DBVisitorFlowModePage;
    [_stack addObject:[_flow objectForKey:@"start"]];
  } else {
    _mode = DBVisitorFlowModeLegacy;
  }
}

#pragma mark - what is on screen

- (NSString *)currentStepID {
  if ([_mode isEqualToString:DBVisitorFlowModePage]) return [_stack lastObject];
  if ([_mode isEqualToString:DBVisitorFlowModeEnd]) return _activeStep;
  return nil;
}

- (NSDictionary *)currentStep {
  NSString *identifier = [self currentStepID];
  return identifier ? [self step:identifier] : nil;
}

- (NSArray *)currentOptions {
  if (![_mode isEqualToString:DBVisitorFlowModePage]) return @[];
  id raw = [[self currentStep] objectForKey:@"options"];
  if (![raw isKindOfClass:[NSArray class]]) return @[];
  NSMutableArray *options = [NSMutableArray array];
  for (id entry in (NSArray *)raw) {
    NSDictionary *option = DBFlowDict(entry);
    NSString *identifier = DBFlowString([option objectForKey:@"id"]);
    if ([identifier length] == 0) continue;
    NSString *style = DBFlowString([option objectForKey:@"style"]) ?: @"normal";
    NSString *semantic = DBFlowString([option objectForKey:@"semantic_id"]);
    if ([semantic length] == 0)
      semantic = [style isEqualToString:@"primary"] ? @"call.primary" : @"purpose.button";
    [options addObject:@{
      @"id" : identifier,
      @"semantic_id" : semantic,
      @"label" : [self text:[option objectForKey:@"label"]] ?: @"",
      @"icon" : DBFlowString([option objectForKey:@"icon"]) ?: @"",
      @"style" : style,
      @"to" : DBFlowString([option objectForKey:@"to"]) ?: @"",
      @"purpose" : DBFlowString([option objectForKey:@"purpose"]) ?: @"",
    }];
  }
  return options;
}

- (BOOL)canGoBack {
  return [_mode isEqualToString:DBVisitorFlowModePage] && [_stack count] > 1;
}

- (NSTimeInterval)idleSeconds {
  id value = [_flow objectForKey:@"idle_s"];
  double seconds = [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : 45;
  return MAX(15, MIN(300, seconds));
}

- (NSTimeInterval)returnSeconds {
  id value = [[self currentStep] objectForKey:@"return_s"];
  double seconds = [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : 8;
  return MAX(3, MIN(60, seconds));
}

- (NSDictionary *)snapshot {
  NSString *page = [self currentStepID];
  NSDictionary *step = page ? [self step:page] : @{};
  NSMutableArray *options = [NSMutableArray array];
  for (NSDictionary *option in [self currentOptions])
    [options addObject:@{ @"id" : [option objectForKey:@"id"],
                          @"semantic_id" : [option objectForKey:@"semantic_id"],
                          @"label" : [option objectForKey:@"label"] }];
  NSString *title = page ? [self text:[step objectForKey:@"title"]] : nil;
  return @{
    @"mode" : _mode,
    @"page" : page ?: [NSNull null],
    @"title" : title ?: [NSNull null],
    @"options" : options,
    @"back" : @([self canGoBack]),
    @"done" : @([_mode isEqualToString:DBVisitorFlowModeEnd]),
    @"notice" : _notice ?: [NSNull null],
    @"reply" : @(_reply),
  };
}

#pragma mark - input

- (NSDictionary *)chosenOption:(NSString *)optionID {
  if (![_mode isEqualToString:DBVisitorFlowModePage]) return nil;
  id raw = [[self step:[_stack lastObject]] objectForKey:@"options"];
  NSDictionary *chosen = nil;
  if ([raw isKindOfClass:[NSArray class]])
    for (id entry in (NSArray *)raw)
      if ([[DBFlowDict(entry) objectForKey:@"id"] isEqual:optionID]) chosen = entry;
  return chosen;
}

- (NSString *)purposeOf:(id)stepID {
  return DBFlowString([[self step:stepID] objectForKey:@"purpose"]) ?: @"";
}

- (NSDictionary *)planForTap:(NSString *)optionID {
  NSDictionary *chosen = [self chosenOption:optionID];
  if (chosen == nil) return nil;
  id target = [chosen objectForKey:@"to"];
  NSString *kind = [self kind:target];
  if ([kind isEqualToString:@"page"] || [kind isEqualToString:@"end"])
    return @{ @"action" : @"local" };
  if ([kind isEqualToString:@"call"])
    return @{ @"action" : @"press", @"purpose" : [self purposeOf:target] };
  if ([kind isEqualToString:@"notify"]) return @{ @"action" : @"notify", @"step" : target };
  return @{ @"action" : @"press", @"purpose" : @"" };
}

- (NSArray *)directCall:(NSString *)purpose event:(NSDictionary *)event {
  if ([[event objectForKey:@"press_result"] isEqual:@"failed"]) _notice = DBVisitorFlowCallFailedNotice;
  else _mode = DBVisitorFlowModeCalling;
  return @[ @{ @"press" : purpose ?: @"" } ];
}

- (NSArray *)tap:(NSDictionary *)event {
  NSDictionary *chosen = [self chosenOption:DBFlowString([event objectForKey:@"tap"])];
  if (chosen == nil) return @[];
  _notice = nil;
  id target = [chosen objectForKey:@"to"];
  NSString *kind = [self kind:target];
  if ([kind isEqualToString:@"page"]) {
    NSUInteger index = [_stack indexOfObject:target];
    if (index != NSNotFound)
      [_stack removeObjectsInRange:NSMakeRange(index + 1, [_stack count] - index - 1)];
    else [_stack addObject:target];
    return @[];
  }
  if ([kind isEqualToString:@"call"]) {
    _activeStep = target;
    return [self directCall:[self purposeOf:target] event:event];
  }
  if ([kind isEqualToString:@"notify"]) {
    NSMutableArray *calls = [NSMutableArray arrayWithObject:@{ @"notify" : target }];
    NSDictionary *result = DBFlowDict([event objectForKey:@"notify_result"]) ?: @{ @"ok" : @YES };
    id after = [[self step:target] objectForKey:@"to"];
    if (!DBFlowTrue([result objectForKey:@"ok"]) || ![[self kind:after] isEqualToString:@"end"]) {
      // A message that could not be sent must not look delivered: ring instead.
      _activeStep = nil;
      [calls addObjectsFromArray:[self directCall:[self purposeOf:target] event:event]];
      return calls;
    }
    _mode = DBVisitorFlowModeEnd;
    _activeStep = after;
    return calls;
  }
  if ([kind isEqualToString:@"end"]) {
    _mode = DBVisitorFlowModeEnd;
    _activeStep = target;
    return @[];
  }
  // Unknown kind or a target that is not in the document: a visitor can always ring.
  _activeStep = nil;
  return [self directCall:@"" event:event];
}

- (void)callEnded:(NSString *)reason {
  if (![_mode isEqualToString:DBVisitorFlowModeCalling]) return;
  id unanswered = [[self step:_activeStep] objectForKey:@"on_unanswered"];
  [self home];
  if (![reason isEqualToString:@"timeout"] || ![_mode isEqualToString:DBVisitorFlowModePage]) return;
  if ([[self kind:unanswered] isEqualToString:@"page"]) {
    if (![unanswered isEqual:[_stack objectAtIndex:0]]) [_stack addObject:unanswered];
  } else {
    _notice = DBVisitorFlowNoAnswerNotice;
  }
}

- (void)replace:(NSDictionary *)flow {
  NSString *previousMode = _mode;
  NSArray *previousStack = [_stack copy];
  [self load:flow];
  if (![self active]) {
    if (![previousMode isEqualToString:DBVisitorFlowModeCalling]) [self home];
    return;
  }
  if ([previousMode isEqualToString:DBVisitorFlowModeCalling]) return;
  if ([previousMode isEqualToString:DBVisitorFlowModeEnd] &&
      [[self kind:_activeStep] isEqualToString:@"end"]) return;
  BOOL keep = [previousMode isEqualToString:DBVisitorFlowModePage] && [previousStack count] > 0 &&
      [[previousStack objectAtIndex:0] isEqual:[_flow objectForKey:@"start"]];
  for (id stepID in previousStack)
    if (![[self kind:stepID] isEqualToString:@"page"]) keep = NO;
  [self home];
  if (keep) {
    [_stack removeAllObjects];
    [_stack addObjectsFromArray:previousStack];
  }
}

- (NSArray *)applyEvent:(NSDictionary *)event {
  if ([event objectForKey:@"reply"] != nil) {
    _reply = DBFlowTrue([event objectForKey:@"reply"]);
    return @[];
  }
  if ([event objectForKey:@"lang"] != nil) {
    self.lang = DBFlowString([event objectForKey:@"lang"]);
    return @[];
  }
  if ([event objectForKey:@"flow_changed"] != nil) {
    [self replace:DBFlowDict([event objectForKey:@"flow_changed"])];
    return @[];
  }
  if ([event objectForKey:@"tap"] != nil) return [self tap:event];
  if (DBFlowTrue([event objectForKey:@"back"])) {
    if ([self canGoBack]) {
      [_stack removeLastObject];
      _notice = nil;
    }
    return @[];
  }
  if (DBFlowTrue([event objectForKey:@"idle_timeout"])) {
    if ([_mode isEqualToString:DBVisitorFlowModePage]) {
      [_stack removeObjectsInRange:NSMakeRange(1, [_stack count] - 1)];
      _notice = nil;
    }
    return @[];
  }
  if (DBFlowTrue([event objectForKey:@"done"]) || DBFlowTrue([event objectForKey:@"end_timeout"])) {
    if ([_mode isEqualToString:DBVisitorFlowModeEnd]) [self home];
    return @[];
  }
  if ([event objectForKey:@"call_ended"] != nil) {
    [self callEnded:DBFlowString([event objectForKey:@"call_ended"]) ?: @""];
    return @[];
  }
  if (DBFlowTrue([event objectForKey:@"press_failed"])) {
    // The press the walker asked for returned no call: the visitor stays on the page they were on.
    if ([_mode isEqualToString:DBVisitorFlowModeCalling] && [_stack count] > 0) {
      _mode = DBVisitorFlowModePage;
      _activeStep = nil;
      _notice = DBVisitorFlowCallFailedNotice;
    }
    return @[];
  }
  return @[];
}

@end
