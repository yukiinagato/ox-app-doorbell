#import <Foundation/Foundation.h>

#import "DBSettingsLogic.h"

static void require(BOOL condition, NSString *message) {
  if (!condition) {
    NSLog(@"FAIL: %@", message);
    exit(1);
  }
}

static NSDictionary *manifest(void) {
  NSArray *all = @[ @"scale", @"font_scale", @"foreground", @"background", @"accent", @"border",
                    @"radius" ];
  return @{
    @"schema_version" : @1, @"units" : @"pt",
    @"viewport" : @{ @"minimum_touch" : @44, @"scale_min" : @0.75, @"scale_max" : @2.0 },
    @"elements" : @{
      @"call.primary" : @{ @"properties" : all, @"safety_critical" : @NO, @"defaults" : @{} },
      @"call.end" : @{ @"properties" : @[ @"scale", @"background" ], @"safety_critical" : @YES,
                       @"defaults" : @{} },
    },
  };
}

static void testIdentity(void) {
  require([DBSettingsLogic validDoorId:@"d_front"], @"a plain door id is valid");
  require(![DBSettingsLogic validDoorId:@"-front"], @"a door id starts with a letter or digit");
  require(![DBSettingsLogic validDoorId:@"front door"], @"a door id has no spaces");
  require(![DBSettingsLogic validDoorId:@""], @"an empty door id is invalid");
  NSString *longId = [@"" stringByPaddingToLength:65 withString:@"a" startingAtIndex:0];
  require(![DBSettingsLogic validDoorId:longId], @"a door id has at most 64 characters");
  require([DBSettingsLogic validDeviceName:@" Kitchen "], @"a trimmed name is valid");
  require(![DBSettingsLogic validDeviceName:@"   "], @"a blank name is invalid");
  require(![DBSettingsLogic validDeviceName:longId], @"a name has at most 64 characters");
  require([[DBSettingsLogic suggestedDoorIdForDevice:@"787e-91b5aabbcc"]
              isEqualToString:@"door-787e91b5"],
          @"the suggested door takes the first eight alphanumerics");

  NSDictionary *config = @{
    @"doors" : @{
      @"d_front" : @{ @"order" : @2 }, @"d_back" : @{ @"order" : @1 },
      @"d_side" : @{ @"order" : @3 }, @"d_gate" : @{ @"order" : @4 },
    },
    @"devices" : @{
      @"door1" : @{ @"role" : @"door_station", @"door" : @"d_front" },
      @"door2" : @{ @"role" : @"door_station", @"door" : @"d_side" },
      @"door3" : @{ @"role" : @"door_station", @"door" : @"d_gate" },
      @"panel1" : @{ @"role" : @"indoor_panel", @"door" : @"" },
    },
  };
  NSDictionary *status = @{
    @"node" : @{ @"id" : @"panel1" },
    @"peers" : @[
      @{ @"id" : @"door1", @"status" : @"alive" },
      @{ @"id" : @"door2", @"status" : @"dead" },
      @{ @"id" : @"door3", @"status" : @"alive" },
      @{ @"id" : @"panel1", @"status" : @"alive" },
    ],
  };
  NSArray *forPanel = [DBSettingsLogic unservedDoorsInConfig:config status:status
                                                   forDevice:@"panel1"];
  require([forPanel isEqualToArray:(@[ @"d_back", @"d_side" ])],
          @"only doors without a live door station are offered, in display order");
  NSArray *forDoor3 = [DBSettingsLogic unservedDoorsInConfig:config status:status
                                                   forDevice:@"door3"];
  require([forDoor3 isEqualToArray:(@[ @"d_back", @"d_side", @"d_gate" ])],
          @"the target's own door stays selectable");
  require([[DBSettingsLogic deviceBoundToDoor:@"d_side" config:config excluding:@"panel1"]
              isEqualToString:@"door2"],
          @"an offline station bound to the door is named for the warning");
  require([DBSettingsLogic deviceBoundToDoor:@"d_back" config:config excluding:@"panel1"] == nil,
          @"a free door has no bound station");

  NSArray *toDoor = [DBSettingsLogic roleChangeOpsForDevice:@"panel1" role:@"door_station"
                                                      door:@"d_back"];
  require([toDoor count] == 2, @"a role change is one batch of two writes");
  require([[[toDoor objectAtIndex:0] objectForKey:@"key"] isEqualToString:@"devices.panel1.role"] &&
          [[[toDoor objectAtIndex:0] objectForKey:@"value"] isEqualToString:@"door_station"],
          @"the role is written first");
  require([[[toDoor objectAtIndex:1] objectForKey:@"key"] isEqualToString:@"devices.panel1.door"] &&
          [[[toDoor objectAtIndex:1] objectForKey:@"value"] isEqualToString:@"d_back"],
          @"the door is written in the same batch");
  NSArray *toIndoor = [DBSettingsLogic roleChangeOpsForDevice:@"door1" role:@"indoor_panel"
                                                        door:@"d_front"];
  require([[[toIndoor objectAtIndex:1] objectForKey:@"value"] isEqualToString:@""],
          @"an indoor panel gets an empty door");
  require([DBSettingsLogic roleChangeOpsForDevice:@"panel1" role:@"door_station" door:@""] == nil,
          @"a door station needs a door");
  require([DBSettingsLogic roleChangeOpsForDevice:@"panel1" role:@"monitor" door:@"d"] == nil,
          @"only the two roles exist");
  require([DBSettingsLogic roleChangeOpsForDevice:@"a.b" role:@"indoor_panel" door:@""] == nil,
          @"a device id never carries a dot into a key path");
  require(![DBSettingsLogic roleEditableForDevice:@{ @"platform" : @"tvOS" } peer:nil],
          @"a tvOS device keeps its fixed role");
  require([DBSettingsLogic roleEditableForDevice:@{ @"platform" : @"android" } peer:nil],
          @"other platforms take a remote role edit");

  NSDictionary *health = [DBSettingsLogic peerHealth:@{
    @"status" : @"alive", @"sw" : @"1.4.2",
    @"power" : @{ @"battery_pct" : @87.4, @"charging" : @YES } }];
  require([[health objectForKey:@"state"] isEqualToString:@"online"], @"alive is online");
  require([[health objectForKey:@"version"] isEqualToString:@"1.4.2"], @"the version is carried");
  require([[health objectForKey:@"battery"] integerValue] == 87, @"the battery is rounded");
  require([[health objectForKey:@"charging"] boolValue], @"charging is carried");
  NSDictionary *gone = [DBSettingsLogic peerHealth:nil];
  require([[gone objectForKey:@"state"] isEqualToString:@"offline"] &&
          [gone objectForKey:@"battery"] == nil && [gone objectForKey:@"version"] == nil,
          @"an unknown peer is offline with nothing else claimed");
  require([[[DBSettingsLogic peerHealth:@{ @"status" : @"suspect",
                                           @"power" : @{ @"battery_pct" : @-1 } }]
              objectForKey:@"state"] isEqualToString:@"suspect"],
          @"suspect is its own state");

  NSString *hex = [@"" stringByPaddingToLength:64 withString:@"0a" startingAtIndex:0];
  require([[DBSettingsLogic fingerprintText:hex] hasPrefix:@"0A:0A:0A"], @"fingerprint is paired");
  require([DBSettingsLogic fingerprintText:@"abc"] == nil, @"a short digest has no fingerprint");
  require([[DBSettingsLogic membershipState:@{ @"membership" : @"rekey_required" }]
              isEqualToString:@"rekey_required"], @"a known membership passes through");
  require([[DBSettingsLogic membershipState:@{ @"membership" : @"x" }] isEqualToString:@"unknown"],
          @"anything else is unknown");
}

static void testAssets(void) {
  NSDictionary *config = @{
    @"display" : @{ @"theme" : @{ @"bg_image" : @"img1" } },
    @"devices" : @{ @"0123456789abcdef" : @{ @"local" : @{ @"theme" : @{ @"bg_image" : @"img1" } } } },
    @"quick_replies" : @{ @"qr_1" : @{ @"audio" : @{ @"ja" : @"snd1" } } },
    @"ui" : @{ @"ringtone" : @"asset:snd2", @"launch_sound" : @"title_display" },
    @"trigger_rules" : @{ @"r_1" : @{ @"actions" : @[
        @{ @"type" : @"chime", @"sound" : @"asset:snd2" },
        @{ @"type" : @"device_alert", @"presentation" : @{ @"sound" : @"asset:snd3" } } ] } },
    @"emergency" : @{ @"alarm_sound" : @"asset:snd3" },
  };
  NSDictionary *refs = [DBSettingsLogic assetReferencesInConfig:config];
  require([[refs objectForKey:@"img1"] isEqualToArray:(@[ @"display.theme", @"devices.01234567" ])],
          @"a wallpaper is referenced by the cluster theme and a device theme");
  require([[refs objectForKey:@"snd1"] isEqualToArray:(@[ @"quick_replies.qr_1 (ja)" ])],
          @"reply audio is referenced by reply and language");
  require([[refs objectForKey:@"snd2"] isEqualToArray:(@[ @"ui.ringtone", @"trigger_rules.r_1" ])],
          @"an asset sound is referenced by the ringtone and a chime");
  require([[refs objectForKey:@"snd3"] isEqualToArray:(@[ @"trigger_rules.r_1",
                                                          @"emergency.alarm_sound" ])],
          @"an alert sound and the SOS sound are references");
  require([refs objectForKey:@"title_display"] == nil, @"a built-in sound is not an asset");
  require([[DBSettingsLogic assetReferencesInConfig:nil] count] == 0, @"no config, no references");
}

static void testUiElements(void) {
  NSDictionary *m = manifest();
  require([DBSettingsLogic uiManifestError:m] == nil, @"a complete manifest is usable");
  require([[DBSettingsLogic uiManifestError:@{}] isEqualToString:@"unreported"],
          @"an empty manifest is unreported");
  NSMutableDictionary *bad = [m mutableCopy];
  [bad setObject:@2 forKey:@"schema_version"];
  require([[DBSettingsLogic uiManifestError:bad] isEqualToString:@"schema_version"],
          @"only schema version 1 is understood");
  require([[DBSettingsLogic uiPropertiesInManifest:m element:@"call.end"]
              isEqualToArray:(@[ @"scale", @"background" ])],
          @"only the properties the manifest states are offered");
  require([DBSettingsLogic uiValueErrorInManifest:m element:@"call.primary" property:@"scale"
                                            value:@0.75] == nil, @"the lower bound is allowed");
  require([[DBSettingsLogic uiValueErrorInManifest:m element:@"call.primary" property:@"scale"
                                             value:@2.01] isEqualToString:@"range"],
          @"above scale_max is refused");
  require([[DBSettingsLogic uiValueErrorInManifest:m element:@"call.end" property:@"scale"
                                             value:@0.9] isEqualToString:@"range"],
          @"a safety-critical element cannot shrink below 1");
  require([DBSettingsLogic uiValueErrorInManifest:m element:@"call.end" property:@"scale"
                                            value:@1.0] == nil, @"a safety-critical element may stay at 1");
  require([[DBSettingsLogic uiValueErrorInManifest:m element:@"call.end" property:@"radius"
                                             value:@4] isEqualToString:@"not_allowed"],
          @"a property the manifest omits is refused");
  require([[DBSettingsLogic uiValueErrorInManifest:m element:@"call.primary" property:@"radius"
                                             value:@45] isEqualToString:@"range"],
          @"radius stops at minimum_touch");
  require([DBSettingsLogic uiValueErrorInManifest:m element:@"call.primary" property:@"radius"
                                            value:@44] == nil, @"radius may equal minimum_touch");
  require([[DBSettingsLogic uiValueErrorInManifest:m element:@"call.primary" property:@"accent"
                                             value:@"red"] isEqualToString:@"color"],
          @"a colour is #RRGGBB");
  require([DBSettingsLogic uiValueErrorInManifest:m element:@"call.primary" property:@"accent"
                                            value:@"#4DA3FF"] == nil, @"a hex colour is accepted");
  require([[DBSettingsLogic uiValueErrorInManifest:m element:@"nope" property:@"scale" value:@1]
              isEqualToString:@"absent"], @"an element outside the manifest is refused");
  require([[DBSettingsLogic uiValueErrorInManifest:m element:@"call.primary" property:@"scale"
                                             value:@"1"] isEqualToString:@"range"],
          @"a scale is a number, not text");
  NSDictionary *whole = @{ @"call.primary" : @{ @"scale" : @1.1 } };
  NSDictionary *nested = @{ @"call" : @{ @"primary" : @{ @"scale" : @1.2 } } };
  require([[[DBSettingsLogic uiElementValue:whole element:@"call.primary"] objectForKey:@"scale"]
              doubleValue] == 1.1, @"an override keyed whole is found");
  require([[[DBSettingsLogic uiElementValue:nested element:@"call.primary"] objectForKey:@"scale"]
              doubleValue] == 1.2, @"an override nested by its dots is found");
  require([DBSettingsLogic uiElementValue:nested element:@"call.end"] == nil,
          @"an element without an override has none");
}

static void testPlayback(void) {
  NSArray *defaults = [DBSettingsLogic normalizedPlaybackStrategies:nil];
  require([defaults count] == 3, @"three strategies exist");
  require([[[defaults objectAtIndex:0] objectForKey:@"id"] isEqualToString:@"h264_low_latency"] &&
          [[[defaults objectAtIndex:0] objectForKey:@"enabled"] boolValue] &&
          ![[[defaults objectAtIndex:1] objectForKey:@"enabled"] boolValue],
          @"an unwritten profile shows the built-in defaults");
  NSDictionary *stored = @{ @"note" : @"keep", @"strategies" : @[
      @{ @"id" : @"mjpeg", @"enabled" : @YES, @"startup_timeout_ms" : @2000, @"extra" : @1 },
      @{ @"id" : @"future", @"enabled" : @YES } ] };
  NSArray *normal = [DBSettingsLogic normalizedPlaybackStrategies:stored];
  require([[[normal objectAtIndex:0] objectForKey:@"id"] isEqualToString:@"mjpeg"] &&
          [[[normal objectAtIndex:0] objectForKey:@"stall_timeout_ms"] integerValue] == 3000,
          @"stored order is kept and missing timeouts take the default");
  require(![[[normal objectAtIndex:1] objectForKey:@"enabled"] boolValue],
          @"a strategy a stored profile omits is disabled");
  require([DBSettingsLogic playbackErrorForStrategies:normal] == nil, @"one enabled is enough");
  NSMutableArray *off = [NSMutableArray array];
  for (NSDictionary *strategy in normal) {
    NSMutableDictionary *copy = [strategy mutableCopy];
    [copy setObject:@NO forKey:@"enabled"];
    [off addObject:copy];
  }
  require([[DBSettingsLogic playbackErrorForStrategies:off] isEqualToString:@"one_required"],
          @"at least one strategy stays enabled");
  NSMutableArray *slow = [normal mutableCopy];
  NSMutableDictionary *first = [[slow objectAtIndex:0] mutableCopy];
  [first setObject:@99 forKey:@"startup_timeout_ms"];
  [slow replaceObjectAtIndex:0 withObject:first];
  require([[DBSettingsLogic playbackErrorForStrategies:slow] isEqualToString:@"timeout_range"],
          @"the first-frame timeout is 100 to 60000 ms");
  [first setObject:@100 forKey:@"startup_timeout_ms"];
  [first setObject:@999 forKey:@"stall_timeout_ms"];
  [slow replaceObjectAtIndex:0 withObject:first];
  require([[DBSettingsLogic playbackErrorForStrategies:slow] isEqualToString:@"timeout_range"],
          @"the stall timeout is 1000 to 60000 ms");
  NSDictionary *merged = [DBSettingsLogic playbackProfile:stored withStrategies:normal];
  require([[merged objectForKey:@"note"] isEqualToString:@"keep"], @"unknown profile fields survive");
  NSArray *strategies = [merged objectForKey:@"strategies"];
  require([strategies count] == 4, @"an unknown strategy is kept beside the three known ones");
  require([[[strategies objectAtIndex:0] objectForKey:@"extra"] integerValue] == 1,
          @"unknown strategy fields survive");
  require([[[strategies objectAtIndex:1] objectForKey:@"id"] isEqualToString:@"future"],
          @"an unknown strategy keeps its position");
}

static void testRawConfig(void) {
  NSDictionary *config = @{ @"ui" : @{ @"ringtone" : @"ding1", @"languages" : @[ @"ja", @"en" ] },
                            @"a" : @{ @"b" : @{ @"c" : @YES } }, @"empty" : @{}, @"n" : @5 };
  NSArray *flat = [DBSettingsLogic flattenConfig:config];
  NSMutableArray *keys = [NSMutableArray array];
  for (NSArray *row in flat) [keys addObject:[row objectAtIndex:0]];
  require([keys isEqualToArray:(@[ @"a.b.c", @"empty", @"n", @"ui.languages", @"ui.ringtone" ])],
          @"every leaf is listed once, sorted, and an array is one leaf");
  require([[[flat objectAtIndex:0] objectAtIndex:1] isEqualToString:@"true"], @"a boolean is JSON");
  require([[[flat objectAtIndex:3] objectAtIndex:1] isEqualToString:@"[\"ja\",\"en\"]"],
          @"an array is compact JSON");
  require([[[flat objectAtIndex:4] objectAtIndex:1] isEqualToString:@"\"ding1\""],
          @"a string keeps its quotes");
  id value = nil;
  require([DBSettingsLogic parseJsonValue:@" \"text\" " into:&value] &&
          [value isEqual:@"text"], @"a JSON string parses");
  require([DBSettingsLogic parseJsonValue:@"12" into:&value] && [value isEqual:@12],
          @"a JSON number parses");
  require([DBSettingsLogic parseJsonValue:@"{\"a\":[1,2]}" into:&value] &&
          [value isKindOfClass:[NSDictionary class]], @"a JSON object parses");
  require([DBSettingsLogic parseJsonValue:@"null" into:&value] && value == [NSNull null],
          @"null parses");
  require(![DBSettingsLogic parseJsonValue:@"text" into:&value], @"bare text is not JSON");
  require(![DBSettingsLogic parseJsonValue:@"1,2" into:&value], @"two values are not one");
  require(![DBSettingsLogic parseJsonValue:@"" into:&value], @"an empty value is refused");
  require([DBSettingsLogic validConfigKey:@"devices.abc.local.ui_lang"], @"a dotted key is valid");
  require(![DBSettingsLogic validConfigKey:@"devices..role"], @"an empty segment is refused");
  require(![DBSettingsLogic validConfigKey:@"a b"], @"whitespace is refused");
  require(![DBSettingsLogic validConfigKey:@""], @"an empty key is refused");
  double rate = 0;
  require([DBSettingsLogic parseSpeakingRate:@"1.25" into:&rate] && rate == 1.25,
          @"a rate inside the range parses");
  require(![DBSettingsLogic parseSpeakingRate:@"0.2" into:&rate], @"below 0.25 is refused");
  require(![DBSettingsLogic parseSpeakingRate:@"4.5" into:&rate], @"above 4 is refused");
  require(![DBSettingsLogic parseSpeakingRate:@"fast" into:&rate], @"text is refused");
}

int main(void) {
  @autoreleasepool {
    testIdentity();
    testAssets();
    testUiElements();
    testPlayback();
    testRawConfig();
    NSLog(@"kiosk_settings_pages_test ok");
  }
  return 0;
}
