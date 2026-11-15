#import <Foundation/Foundation.h>

#import "DBFlowError.h"

static int failures = 0;

static void Require(BOOL condition, NSString *message) {
  if (!condition) {
    NSLog(@"FAIL: %@", message);
    failures++;
  }
}

static DBFlowError *Parse(NSString *err, NSDictionary *detail) {
  return [DBFlowError errorFromString:err detail:detail];
}

int main(void) {
  @autoreleasepool {
    Require(Parse(@"unresolved_config_conflict", nil) == nil, @"foreign error is not a flow error");
    Require([DBFlowError errorFromResult:@{ @"ok" : @NO }] == nil, @"missing err");

    DBFlowError *bare = Parse(@"visitor_flow.too_many_steps", @{ @"limit" : @32, @"value" : @33 });
    Require([bare.code isEqualToString:@"too_many_steps"], @"bare code");
    Require([bare.location length] == 0 && bare.stepID == nil, @"bare has no location");
    Require([[bare anchors] count] == 0, @"bare has no anchors");
    Require([[bare messageKey] isEqualToString:@"flow_error.too_many_steps"], @"message key");
    Require([[bare messageFromTemplate:@"limit {limit}, now {value}" langName:nil]
                isEqualToString:@"limit 32, now 33"], @"numbers filled");

    DBFlowError *option = Parse(@"visitor_flow.option_needs_label: s_home.o_a", nil);
    Require([option.stepID isEqualToString:@"s_home"] && [option.optionID isEqualToString:@"o_a"],
            @"option location");
    Require(option.field == nil && option.imageIndex == -1, @"option has no field");

    DBFlowError *label = Parse(@"visitor_flow.text_too_long: s_home.o_a.label.zh-Hans",
                               @{ @"lang" : @"zh-Hans", @"limit" : @40, @"value" : @51 });
    Require([label.optionID isEqualToString:@"o_a"] && [label.field isEqualToString:@"label"] &&
            [label.lang isEqualToString:@"zh-Hans"], @"label location");
    NSString *text = [label messageFromTemplate:@"{lang}: limit {limit}, now {value}"
                                       langName:^NSString *(NSString *lang) {
      return [lang isEqualToString:@"zh-Hans"] ? @"Chinese" : lang;
    }];
    Require([text isEqualToString:@"Chinese: limit 40, now 51"], @"language name filled");
    NSArray *anchors = [label anchors];
    Require([anchors count] == 4 &&
            [[anchors objectAtIndex:0] isEqualToString:@"s_home.o_a.label.zh-Hans"] &&
            [[anchors objectAtIndex:3] isEqualToString:@"s_home"], @"anchor chain");

    DBFlowError *title = Parse(@"visitor_flow.text_too_long: s_home.title.en", nil);
    Require(title.optionID == nil && [title.field isEqualToString:@"title"] &&
            [title.lang isEqualToString:@"en"], @"title location");

    DBFlowError *message = Parse(@"visitor_flow.text_required: n_ring.message", nil);
    Require([message.field isEqualToString:@"message"] && message.lang == nil, @"message location");

    DBFlowError *image = Parse(@"visitor_flow.unknown_asset: s_home.images[1]", nil);
    Require(image.imageIndex == 1 && image.field == nil && image.optionID == nil, @"image location");
    DBFlowError *alt = Parse(@"visitor_flow.text_too_long: s_home.images[0].alt.ja", nil);
    Require(alt.imageIndex == 0 && [alt.field isEqualToString:@"alt"] &&
            [alt.lang isEqualToString:@"ja"], @"alt location");

    DBFlowError *start = Parse(@"visitor_flow.unknown_start: doors.front.start", nil);
    Require(start.stepID == nil && [[[start anchors] objectAtIndex:0]
                                       isEqualToString:@"doors.front.start"], @"door start");
    DBFlowError *key = Parse(@"visitor_flow.unknown_key: visitor_flow.nope", nil);
    Require(key.stepID == nil, @"key location names no step");

    Require([[DBFlowError anchorForWarningKey:@"visitor_flow.steps.s_home.o_a"]
                isEqualToString:@"s_home.o_a"], @"warning anchor");
    Require([DBFlowError anchorForWarningKey:@"visitor_flow.enabled"] == nil, @"leaf warning");
  }
  if (failures != 0) return 1;
  printf("flow_error_test: ok\n");
  return 0;
}
