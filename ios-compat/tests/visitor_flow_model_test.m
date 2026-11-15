#import <Foundation/Foundation.h>

#import "DBVisitorFlowModel.h"

// Runs the shared walk cases of tools/conformance/fixtures/visitor-flow-v1.json against the
// kiosk's flow model, the same cases the Python reference walker passes.

static int failures = 0;

static void require(BOOL condition, NSString *message) {
  if (!condition) {
    NSLog(@"FAIL: %@", message);
    failures++;
  }
}

static NSString *RepoRoot(void) {
  const char *env = getenv("DB_REPO_ROOT");
  if (env != NULL && env[0] != 0) return [NSString stringWithUTF8String:env];
  NSString *source = [NSString stringWithUTF8String:__FILE__];
  return [[[source stringByDeletingLastPathComponent] stringByDeletingLastPathComponent]
      stringByDeletingLastPathComponent];
}

int main(void) {
  @autoreleasepool {
    NSString *path = [RepoRoot() stringByAppendingPathComponent:
        @"tools/conformance/fixtures/visitor-flow-v1.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    require(data != nil, @"fixture readable");
    if (data == nil) return 1;
    NSDictionary *suite = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    NSMutableDictionary *flows = [NSMutableDictionary dictionary];
    for (NSDictionary *item in [suite objectForKey:@"resolve"])
      [flows setObject:[item objectForKey:@"expect"] forKey:[item objectForKey:@"name"]];
    NSArray *walks = [suite objectForKey:@"walk"];
    require([walks count] >= 20, @"the fixture carries the walk cases");

    NSUInteger checked = 0;
    for (NSDictionary *walk in walks) {
      NSString *name = [walk objectForKey:@"name"];
      NSDictionary *flow = [flows objectForKey:[walk objectForKey:@"flow"]];
      DBVisitorFlowModel *model = [[DBVisitorFlowModel alloc]
          initWithFlow:flow lang:[walk objectForKey:@"lang"] ?: @"ja"];
      NSDictionary *start = [walk objectForKey:@"start"];
      if (start != nil)
        require([[model snapshot] isEqualToDictionary:start],
                [NSString stringWithFormat:@"%@: start %@ vs %@", name, [model snapshot], start]);
      NSUInteger index = 0;
      for (NSDictionary *entry in [walk objectForKey:@"steps"]) {
        NSMutableDictionary *event = [[entry objectForKey:@"event"] mutableCopy];
        NSString *changed = [event objectForKey:@"flow_changed"];
        if (changed != nil) [event setObject:[flows objectForKey:changed] forKey:@"flow_changed"];
        // The plan is what the shell asks Core for before it applies the input.
        NSString *tap = [event objectForKey:@"tap"];
        NSDictionary *plan = tap != nil ? [model planForTap:tap] : nil;
        NSArray *calls = [model applyEvent:event];
        NSArray *expectedCalls = [entry objectForKey:@"calls"] ?: @[];
        require([calls isEqualToArray:expectedCalls],
                [NSString stringWithFormat:@"%@[%lu]: calls %@ vs %@", name, (unsigned long)index,
                 calls, expectedCalls]);
        if (plan != nil && [[plan objectForKey:@"action"] isEqual:@"notify"])
          require([[[calls firstObject] objectForKey:@"notify"]
                      isEqual:[plan objectForKey:@"step"]],
                  [NSString stringWithFormat:@"%@[%lu]: plan names the notify step", name,
                   (unsigned long)index]);
        if (plan != nil && [[plan objectForKey:@"action"] isEqual:@"press"] &&
            [event objectForKey:@"press_result"] == nil)
          require([[[calls firstObject] objectForKey:@"press"]
                      isEqual:[plan objectForKey:@"purpose"]],
                  [NSString stringWithFormat:@"%@[%lu]: plan names the purpose", name,
                   (unsigned long)index]);
        NSDictionary *expect = [entry objectForKey:@"expect"];
        NSDictionary *snapshot = [model snapshot];
        require([snapshot isEqualToDictionary:expect],
                [NSString stringWithFormat:@"%@[%lu]: snapshot %@ vs %@", name,
                 (unsigned long)index, snapshot, expect]);
        checked++;
        index++;
      }
    }
    require(checked >= 40, @"a meaningful number of steps was checked");

    // A document that is no flow, or one Core published with the flow off, is the classic screen.
    DBVisitorFlowModel *off = [[DBVisitorFlowModel alloc]
        initWithFlow:@{ @"schema_version" : @1, @"enabled" : @NO, @"reason" : @"disabled" } lang:@"en"];
    require(!off.active && [off.mode isEqualToString:DBVisitorFlowModeLegacy], @"disabled is classic");
    DBVisitorFlowModel *broken = [[DBVisitorFlowModel alloc] initWithFlow:(NSDictionary *)@"x" lang:@"en"];
    require(!broken.active, @"a non-object document is classic");
    DBVisitorFlowModel *noStart = [[DBVisitorFlowModel alloc]
        initWithFlow:@{ @"enabled" : @YES, @"start" : @"gone", @"steps" : @{} } lang:@"en"];
    require(!noStart.active, @"a start that is not a page is classic");

    // The press that fails after a tap leaves the visitor on the page with the notice.
    NSDictionary *explicit = [flows objectForKey:@"explicit-flow"];
    DBVisitorFlowModel *model = [[DBVisitorFlowModel alloc] initWithFlow:explicit lang:@"ja"];
    NSArray *calls = [model applyEvent:@{ @"tap" : @"o_visit" }];
    require([calls count] == 1 && [model.mode isEqualToString:DBVisitorFlowModeCalling], @"press taken");
    [model applyEvent:@{ @"press_failed" : @YES }];
    require([model.mode isEqualToString:DBVisitorFlowModePage] &&
            [model.notice isEqualToString:DBVisitorFlowCallFailedNotice], @"failed press stays");
    require([model idleSeconds] >= 15 && [model idleSeconds] <= 300, @"idle clamped");
    require([DBVisitorFlowModel text:@{ @"en" : @"", @"ja" : @"x" } lang:@"en"] != nil &&
            [[DBVisitorFlowModel text:@{ @"zh" : @"z" } lang:@"en"] isEqual:@"z"],
            @"text falls back to any value");

    if (failures == 0) NSLog(@"visitor_flow_model_test ok (%lu steps)", (unsigned long)checked);
  }
  return failures == 0 ? 0 : 1;
}
