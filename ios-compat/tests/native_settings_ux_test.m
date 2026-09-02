#import <Foundation/Foundation.h>

#import "DBBootConfig.h"
#import "DBCallHistoryModel.h"
#import "DBNoticeModel.h"
#import "DBPurposeModel.h"
#import "DBSafeModeRecovery.h"
#import "DBSosSlideModel.h"
#import "DBUiTheme.h"

// Host cover for the pure logic behind the batch-2 kiosk work package:
// automatic text contrast and its overrides, the appearance schedule, the
// computed call-button colour, deliberate two-part labels, the SOS slide and
// countdown state machine, call-history paging/filtering, announcement
// precedence and expiry, and the local safe-mode auto-clear timing.

static void Require(BOOL condition, NSString *message) {
  if (!condition) {
    NSLog(@"FAIL: %@", message);
    exit(1);
  }
}

static void RequireClose(double actual, double expected, double tolerance, NSString *message) {
  Require(fabs(actual - expected) <= tolerance,
          [NSString stringWithFormat:@"%@ (got %f, want %f)", message, actual, expected]);
}

#pragma mark - contrast maths

static void TestLuminanceAndContrastFixedVectors(void) {
  DBRgb white, black, mid;
  Require([DBUiTheme parseHex:@"#FFFFFF" into:&white], @"white parses");
  Require([DBUiTheme parseHex:@"#000" into:&black], @"a three digit hex expands");
  Require([DBUiTheme parseHex:@"777777" into:&mid], @"a hex without # parses");
  RequireClose([DBUiTheme relativeLuminance:white], 1.0, 0.0001, @"white luminance is 1");
  RequireClose([DBUiTheme relativeLuminance:black], 0.0, 0.0001, @"black luminance is 0");
  RequireClose([DBUiTheme contrastBetween:white and:black], 21.0, 0.01,
               @"white on black is 21:1");
  RequireClose([DBUiTheme contrastBetweenHex:@"#FFFFFF" andHex:@"#767676"], 4.54, 0.05,
               @"the WCAG reference grey is just above AA");

  DBRgb bad;
  Require(![DBUiTheme parseHex:@"#12345" into:&bad], @"a five digit hex is rejected");
  Require(![DBUiTheme parseHex:@"#nothex" into:&bad], @"a non-hex string is rejected");
  Require(![DBUiTheme parseHex:nil into:&bad], @"nil is rejected");
  RequireClose([DBUiTheme contrastBetweenHex:@"nope" andHex:@"#FFFFFF"], 0.0, 0.0001,
               @"an unparsable colour yields no ratio");
}

static void TestCustomColoursWarnButAreNeverRejected(void) {
  // Spec §5.2: every colour field saves; the UI shows a soft warning instead.
  Require([DBUiTheme contrastWarnsForForeground:@"#8A8A8A" background:@"#FFFFFF" large:NO],
          @"a low contrast body text pair warns");
  Require(![DBUiTheme contrastWarnsForForeground:@"#8A8A8A" background:@"#FFFFFF" large:YES],
          @"the same pair passes the 3:1 large-text threshold");
  Require(![DBUiTheme contrastWarnsForForeground:@"#101418" background:@"#FFFFFF" large:NO],
          @"a legible pair does not warn");
  Require(![DBUiTheme contrastWarnsForForeground:@"garbage" background:@"#FFFFFF" large:NO],
          @"an unparsable value is not reported as a contrast finding");
  RequireClose([DBUiTheme minimumContrastForLargeText:NO], 4.5, 0.001, @"AA body text");
  RequireClose([DBUiTheme minimumContrastForLargeText:YES], 3.0, 0.001, @"AA large text");
}

static void TestAutomaticInkPerRegionWithLocalFallback(void) {
  // Whichever ink reads better wins; the crossover is near Y = 0.18, not 0.5.
  Require([[DBUiTheme inkModeForLuminance:0.9] isEqualToString:@"dark"], @"light bg -> dark ink");
  Require([[DBUiTheme inkModeForLuminance:0.5] isEqualToString:@"dark"], @"a midtone -> dark ink");
  Require([[DBUiTheme inkModeForLuminance:0.05] isEqualToString:@"light"], @"dark bg -> light ink");

  NSDictionary *empty = [NSDictionary dictionary];
  NSString *onLight = [DBUiTheme inkHexForRegion:DBUiRegionClock config:empty deviceId:@"n1"
                                   backgroundHex:@"#F0F2F4" appearanceMode:@"light"];
  NSString *onDark = [DBUiTheme inkHexForRegion:DBUiRegionClock config:empty deviceId:@"n1"
                                  backgroundHex:@"#0B0E12" appearanceMode:@"dark"];
  Require(![onLight isEqualToString:onDark],
          @"a light image and a dark image produce opposite inks");
  Require([DBUiTheme contrastBetweenHex:onLight andHex:@"#F0F2F4"] >= 4.5,
          @"the locally computed ink is legible on the light background");
  Require([DBUiTheme contrastBetweenHex:onDark andHex:@"#0B0E12"] >= 4.5,
          @"the locally computed ink is legible on the dark background");

  // An old core publishes nothing; a new core publishes the agreed decision.
  NSDictionary *published = @{ @"display" : @{ @"theme" : @{
      @"auto_ink" : @{ @"clock" : @"light" } } } };
  NSString *fromCore = [DBUiTheme inkHexForRegion:DBUiRegionClock config:published deviceId:@"n1"
                                    backgroundHex:@"#F0F2F4" appearanceMode:@"light"];
  Require([fromCore isEqualToString:onDark],
          @"core's published ink wins over the local computation");

  // Admin override wins over everything, cluster first then the device.
  NSDictionary *clusterOverride = @{ @"display" : @{ @"theme" : @{
      @"auto_ink" : @{ @"clock" : @"light" },
      @"ink_override" : @{ @"clock" : @"#FF0000" } } } };
  Require([[DBUiTheme inkHexForRegion:DBUiRegionClock config:clusterOverride deviceId:@"n1"
                        backgroundHex:@"#F0F2F4" appearanceMode:@"light"]
              isEqualToString:@"#FF0000"],
          @"the cluster ink override wins");
  NSDictionary *deviceOverride = @{
    @"display" : @{ @"theme" : @{ @"ink_override" : @{ @"clock" : @"#FF0000" } } },
    @"devices" : @{ @"n1" : @{ @"local" : @{ @"theme" : @{
        @"ink_override" : @{ @"clock" : @"#00FF00" } } } } } };
  Require([[DBUiTheme inkHexForRegion:DBUiRegionClock config:deviceOverride deviceId:@"n1"
                        backgroundHex:@"#F0F2F4" appearanceMode:@"light"]
              isEqualToString:@"#00FF00"],
          @"the device ink override wins over the cluster one");
  NSDictionary *invalidOverride = @{ @"display" : @{ @"theme" : @{
      @"ink_override" : @{ @"clock" : @"not-a-colour" } } } };
  Require([[DBUiTheme inkHexForRegion:DBUiRegionClock config:invalidOverride deviceId:@"n1"
                        backgroundHex:@"#F0F2F4" appearanceMode:@"light"]
              isEqualToString:onLight],
          @"an unparsable override falls back to the computed ink");

  Require([DBUiTheme needsInkShadowForInk:@"#8A8A8A" background:@"#FFFFFF"],
          @"a marginal pair gets the 1 px opposite-ink shadow");
  Require(![DBUiTheme needsInkShadowForInk:@"#101418" background:@"#FFFFFF"],
          @"a legible pair needs no shadow");
}

static void TestAppearanceScheduleReplacesSystemDarkMode(void) {
  // iOS 5 has no system dark mode, so auto_system behaves as auto_schedule.
  Require([[DBUiTheme normalizedAppearance:@"auto_system"] isEqualToString:@"auto_schedule"],
          @"auto_system degrades to the schedule on this platform");
  Require([[DBUiTheme normalizedAppearance:nil] isEqualToString:@"auto_schedule"],
          @"an absent value uses the schedule");
  Require([[DBUiTheme normalizedAppearance:@"light"] isEqualToString:@"light"],
          @"an explicit mode is preserved");

  NSDictionary *config = @{ @"display" : @{ @"appearance" : @"auto_system" } };
  Require([[DBUiTheme appearanceModeForConfig:config deviceId:@"n1" minuteOfDay:20 * 60]
              isEqualToString:@"dark"], @"20:00 is inside the default dark window");
  Require([[DBUiTheme appearanceModeForConfig:config deviceId:@"n1" minuteOfDay:2 * 60]
              isEqualToString:@"dark"], @"02:00 is still inside the wrapped dark window");
  Require([[DBUiTheme appearanceModeForConfig:config deviceId:@"n1" minuteOfDay:12 * 60]
              isEqualToString:@"light"], @"midday is light");
  Require([[DBUiTheme appearanceModeForConfig:config deviceId:@"n1" minuteOfDay:6 * 60 + 30]
              isEqualToString:@"light"], @"light_from is inclusive");

  NSDictionary *custom = @{ @"display" : @{
      @"appearance" : @"auto_schedule",
      @"appearance_schedule" : @{ @"dark_from" : @"08:00", @"light_from" : @"17:00" } } };
  Require([[DBUiTheme appearanceModeForConfig:custom deviceId:@"n1" minuteOfDay:10 * 60]
              isEqualToString:@"dark"], @"a non wrapping window works too");
  Require([[DBUiTheme appearanceModeForConfig:custom deviceId:@"n1" minuteOfDay:18 * 60]
              isEqualToString:@"light"], @"and its light half");

  NSDictionary *deviceForced = @{
    @"display" : @{ @"appearance" : @"auto_schedule" },
    @"devices" : @{ @"n1" : @{ @"local" : @{ @"display" : @{ @"appearance" : @"light" } } } } };
  Require([[DBUiTheme appearanceModeForConfig:deviceForced deviceId:@"n1" minuteOfDay:23 * 60]
              isEqualToString:@"light"], @"the device override wins");
  Require([[DBUiTheme appearanceModeForConfig:deviceForced deviceId:@"other" minuteOfDay:23 * 60]
              isEqualToString:@"dark"], @"another device keeps the cluster schedule");

  Require([DBUiTheme minuteOfDayFromClock:@"19:00" fallback:0] == 19 * 60, @"19:00 parses");
  Require([DBUiTheme minuteOfDayFromClock:@"9:05" fallback:0] == 9 * 60 + 5, @"9:05 parses");
  Require([DBUiTheme minuteOfDayFromClock:@"25:00" fallback:42] == 42, @"an invalid hour falls back");
  Require([DBUiTheme minuteOfDayFromClock:@"ab:cd" fallback:42] == 42, @"garbage falls back");
  Require([DBUiTheme minuteOfDayFromClock:nil fallback:42] == 42, @"nil falls back");
}

static void TestComputedCallButtonColour(void) {
  NSString *accent = [DBUiTheme autoAccentForBackgroundHex:@"#9BD748"];
  NSString *text = [DBUiTheme accentTextHexForAccentHex:accent];
  Require([DBUiTheme contrastBetweenHex:accent andHex:@"#9BD748"] >= 3.0,
          @"the button separates from the background");
  Require([DBUiTheme contrastBetweenHex:text andHex:accent] >= 4.5,
          @"the button label is legible on the button");
  DBRgb accentRgb, bgRgb;
  Require([DBUiTheme parseHex:accent into:&accentRgb], @"the accent is a colour");
  Require([DBUiTheme parseHex:@"#9BD748" into:&bgRgb], @"the sample background parses");
  Require([DBUiTheme relativeLuminance:accentRgb] < [DBUiTheme relativeLuminance:bgRgb],
          @"a light background prefers the dark direction");

  NSString *onDark = [DBUiTheme autoAccentForBackgroundHex:@"#0B0E12"];
  Require([DBUiTheme contrastBetweenHex:onDark andHex:@"#0B0E12"] >= 3.0,
          @"a dark background also produces a separated button");
  Require([[DBUiTheme autoAccentForBackgroundHex:@"not a colour"] length] > 0,
          @"an unusable background still yields a local fallback accent");

  NSDictionary *published = @{ @"display" : @{ @"theme" : @{ @"auto_accent" : @"#391142" } } };
  Require([[DBUiTheme callButtonHexForConfig:published deviceId:@"n1" backgroundHex:@"#9BD748"]
              isEqualToString:@"#391142"], @"core's published accent is used as is");
  NSDictionary *override = @{ @"display" : @{ @"theme" : @{
      @"auto_accent" : @"#391142", @"call_button_bg" : @"#123456" } } };
  Require([[DBUiTheme callButtonHexForConfig:override deviceId:@"n1" backgroundHex:@"#9BD748"]
              isEqualToString:@"#123456"], @"the admin override wins over auto");
  NSDictionary *deviceOverride = @{
    @"display" : @{ @"theme" : @{ @"call_button_bg" : @"#123456" } },
    @"devices" : @{ @"n1" : @{ @"local" : @{ @"theme" : @{
        @"call_button_bg" : @"#654321" } } } } };
  Require([[DBUiTheme callButtonHexForConfig:deviceOverride deviceId:@"n1"
                               backgroundHex:@"#9BD748"] isEqualToString:@"#654321"],
          @"the device override wins over the cluster one");
  Require([[DBUiTheme callButtonHexForConfig:[NSDictionary dictionary] deviceId:@"n1"
                               backgroundHex:@"#9BD748"]
              isEqualToString:[DBUiTheme autoAccentForBackgroundHex:@"#9BD748"]],
          @"an old core without auto_accent recomputes locally");
}

static void TestDeliberateLineBreaksAndVersionLine(void) {
  NSArray *parts = [DBUiTheme labelPartsFor:@"スライドで SOS\n3 秒後に発報"];
  Require([[parts objectAtIndex:0] isEqualToString:@"スライドで SOS"], @"primary part");
  Require([[parts objectAtIndex:1] isEqualToString:@"3 秒後に発報"], @"secondary part");
  NSArray *single = [DBUiTheme labelPartsFor:@"開錠"];
  Require([[single objectAtIndex:0] isEqualToString:@"開錠"], @"a single line keeps its text");
  Require([[single objectAtIndex:1] length] == 0, @"and has no second line");
  NSArray *empty = [DBUiTheme labelPartsFor:nil];
  Require([empty count] == 2 && [[empty objectAtIndex:0] length] == 0,
          @"nil yields two empty parts instead of crashing");
  NSArray *three = [DBUiTheme labelPartsFor:@"a\nb\nc"];
  Require([[three objectAtIndex:1] isEqualToString:@"b c"],
          @"only the first authored break splits the label");
  RequireClose([DBUiTheme secondaryFontScale], 0.8, 0.001, @"the second line is smaller");

  Require([[DBUiTheme versionLineForName:@"居間" coreVersion:@"1.2.3" appVersion:@"0.9.1"
                              batteryPct:82 charging:NO]
              isEqualToString:@"居間 · core v1.2.3 · app v0.9.1 · 82%"],
          @"the footer carries core and app versions plus battery");
  Require([[DBUiTheme versionLineForName:@"居間" coreVersion:@"1.2.3" appVersion:@"0.9.1"
                              batteryPct:82 charging:YES] rangeOfString:@"⚡"].location
              != NSNotFound, @"charging is marked");
  Require([[DBUiTheme versionLineForName:@"門口" coreVersion:@"1.2.3" appVersion:@"0.9.1"
                              batteryPct:-1 charging:NO] rangeOfString:@"%"].location
              == NSNotFound, @"a device without a battery shows no battery text");
}

// Core computes the appearance, the averaged background, the per-region ink and
// the call-button colour once and publishes them as status.display, so every
// shell agrees instead of each deriving its own (batch-2 core delta).
static void TestCoreResolvedDisplayContractWins(void) {
  NSDictionary *config = @{ @"display" : @{ @"appearance" : @"auto_schedule" } };
  NSDictionary *display = @{
    @"appearance" : @{ @"configured" : @"auto_schedule", @"effective" : @"light",
                       @"follow_system" : @NO },
    @"theme" : @{
      @"auto_background" : @{ @"color" : @"#9BD748", @"source" : @"image" },
      @"auto_ink" : @{ @"clock" : @"dark" },
      @"auto_accent" : @{ @"call_button" : @"#391142", @"call_button_ink" : @"dark" },
      @"call_button_bg" : @"#391142",
      @"call_button_ink" : @"dark" } };

  // Midnight would be dark by the schedule; core says light and core wins.
  Require([[DBUiTheme appearanceModeForConfig:config deviceId:@"n1" display:display
                                  minuteOfDay:23 * 60] isEqualToString:@"light"],
          @"core's resolved appearance is used as is");
  Require([[DBUiTheme appearanceModeForConfig:config deviceId:@"n1" display:nil
                                  minuteOfDay:23 * 60] isEqualToString:@"dark"],
          @"an older core without the contract falls back to the local schedule");
  NSDictionary *forced = @{
    @"display" : @{ @"appearance" : @"auto_schedule" },
    @"devices" : @{ @"n1" : @{ @"local" : @{ @"display" : @{ @"appearance" : @"dark" } } } } };
  Require([[DBUiTheme appearanceModeForConfig:forced deviceId:@"n1" display:display
                                  minuteOfDay:12 * 60] isEqualToString:@"dark"],
          @"a device override is a local decision and still wins");

  Require([[DBUiTheme autoBackgroundHexInDisplay:display] isEqualToString:@"#9BD748"],
          @"the measured background is read from the contract");
  Require([DBUiTheme autoBackgroundHexInDisplay:nil] == nil,
          @"and is absent on an older core");

  Require([[DBUiTheme inkHexForRegion:DBUiRegionClock config:[NSDictionary dictionary]
                             deviceId:@"n1" display:display backgroundHex:@"#0B0E12"
                       appearanceMode:@"dark"] isEqualToString:[DBUiTheme darkInkHex]],
          @"core's per-region ink decision wins over the local sample");
  NSDictionary *adminInk = @{ @"theme" : @{ @"auto_ink" : @{ @"clock" : @"dark" },
                                            @"ink_override" : @{ @"clock" : @"#FF0000" } } };
  Require([[DBUiTheme inkHexForRegion:DBUiRegionClock config:[NSDictionary dictionary]
                             deviceId:@"n1" display:adminInk backgroundHex:@"#0B0E12"
                       appearanceMode:@"dark"] isEqualToString:@"#FF0000"],
          @"an administrator's override arrives already resolved");

  Require([[DBUiTheme callButtonHexForConfig:[NSDictionary dictionary] deviceId:@"n1"
                                     display:display backgroundHex:@"#9BD748"]
              isEqualToString:@"#391142"], @"the call button colour comes from core");
  // The ink is taken from the contract, never re-derived: on a mid-luminance
  // background core returns the best compromise rather than an unreadable pair.
  Require([[DBUiTheme callButtonInkHexForConfig:[NSDictionary dictionary] deviceId:@"n1"
                                        display:display backgroundHex:@"#9BD748"]
              isEqualToString:[DBUiTheme darkInkHex]], @"and so does its text colour");
  NSDictionary *deviceAccent = @{ @"devices" : @{ @"n1" : @{ @"local" : @{
      @"theme" : @{ @"call_button_bg" : @"#123456" } } } } };
  Require([[DBUiTheme callButtonHexForConfig:deviceAccent deviceId:@"n1" display:display
                               backgroundHex:@"#9BD748"] isEqualToString:@"#123456"],
          @"a per-device colour still wins");
  Require([[DBUiTheme callButtonHexForConfig:[NSDictionary dictionary] deviceId:@"n1"
                                     display:nil backgroundHex:@"#9BD748"]
              isEqualToString:[DBUiTheme autoAccentForBackgroundHex:@"#9BD748"]],
          @"an older core is served by the local computation");
}

static void TestVideoAspectIsPreserved(void) {
  // A portrait door camera in a landscape slot is letterboxed, never cropped.
  NSArray *portrait = [DBUiTheme aspectFitRectForContentWidth:480 contentHeight:640
                                               availableWidth:800 availableHeight:400];
  RequireClose([[portrait objectAtIndex:2] doubleValue], 300.0, 0.001, @"width follows height");
  RequireClose([[portrait objectAtIndex:3] doubleValue], 400.0, 0.001, @"height fills the slot");
  RequireClose([[portrait objectAtIndex:0] doubleValue], 250.0, 0.001, @"and is centred");
  RequireClose([[portrait objectAtIndex:1] doubleValue], 0.0, 0.001, @"with no vertical inset");

  NSArray *landscape = [DBUiTheme aspectFitRectForContentWidth:640 contentHeight:480
                                                availableWidth:800 availableHeight:400];
  RequireClose([[landscape objectAtIndex:2] doubleValue], 533.333, 0.01, @"landscape fits");
  RequireClose([[landscape objectAtIndex:3] doubleValue], 400.0, 0.001, @"to the slot height");

  NSArray *unknown = [DBUiTheme aspectFitRectForContentWidth:0 contentHeight:0
                                              availableWidth:800 availableHeight:400];
  RequireClose([[unknown objectAtIndex:2] doubleValue], 800.0, 0.001,
               @"an unknown aspect fills the slot instead of collapsing it");
  NSArray *empty = [DBUiTheme aspectFitRectForContentWidth:640 contentHeight:480
                                            availableWidth:0 availableHeight:0];
  RequireClose([[empty objectAtIndex:2] doubleValue], 0.0, 0.001, @"an empty slot stays empty");
}

// A real-device finding on the Moto, which applies here: core computes
// display.theme.auto_ink from the whole background image because it has no
// layout geometry, so text over a light part of a mostly dark picture came back
// white and unreadable. The shell refines each region from the pixels behind it.
static void TestPerRegionBackgroundSampling(void) {
  // Aspect fill: the image covers the view and overflows on one axis.
  NSArray *wide = [DBUiTheme aspectFillDrawRectForImageWidth:1600 imageHeight:800
                                                  viewWidth:1024 viewHeight:768];
  RequireClose([[wide objectAtIndex:3] doubleValue], 768.0, 0.001, @"height fills the view");
  RequireClose([[wide objectAtIndex:2] doubleValue], 1536.0, 0.001, @"width overflows");
  RequireClose([[wide objectAtIndex:0] doubleValue], -256.0, 0.001,
               @"and the overflow is centred, so the sample keeps the visible half");
  RequireClose([[wide objectAtIndex:1] doubleValue], 0.0, 0.001, @"with no vertical offset");
  NSArray *tall = [DBUiTheme aspectFillDrawRectForImageWidth:600 imageHeight:1200
                                                  viewWidth:1024 viewHeight:768];
  RequireClose([[tall objectAtIndex:2] doubleValue], 1024.0, 0.001, @"width fills the view");
  RequireClose([[tall objectAtIndex:3] doubleValue], 2048.0, 0.001, @"height overflows");
  NSArray *noImage = [DBUiTheme aspectFillDrawRectForImageWidth:0 imageHeight:0
                                                     viewWidth:1024 viewHeight:768];
  RequireClose([[noImage objectAtIndex:2] doubleValue], 1024.0, 0.001,
               @"a flat colour covers the whole view");

  // A region's frame maps onto the proxy, rounded outwards so an edge pixel is
  // never dropped, and clamped to the proxy.
  NSArray *clock = [DBUiTheme samplePixelRectForViewX:0 y:0 width:512 height:384
                                            viewWidth:1024 viewHeight:768
                                           proxyWidth:64 proxyHeight:64];
  Require([[clock objectAtIndex:0] integerValue] == 0, @"top left starts at the origin");
  Require([[clock objectAtIndex:2] integerValue] == 32, @"half the width is half the proxy");
  Require([[clock objectAtIndex:3] integerValue] == 32, @"and half the height");

  NSArray *footer = [DBUiTheme samplePixelRectForViewX:20 y:750 width:600 height:18
                                             viewWidth:1024 viewHeight:768
                                            proxyWidth:64 proxyHeight:64];
  Require([[footer objectAtIndex:1] integerValue] == 62, @"a footer samples the bottom rows");
  Require([[footer objectAtIndex:1] integerValue] + [[footer objectAtIndex:3] integerValue]
              <= 64, @"and never reads past the proxy");

  // Off-screen and degenerate frames still produce one readable sample rather
  // than an empty average, so a region can never end up with no ink decision.
  NSArray *offscreen = [DBUiTheme samplePixelRectForViewX:-400 y:-400 width:10 height:10
                                                viewWidth:1024 viewHeight:768
                                               proxyWidth:64 proxyHeight:64];
  Require([[offscreen objectAtIndex:2] integerValue] >= 1, @"never an empty sample");
  Require([[offscreen objectAtIndex:3] integerValue] >= 1, @"in either axis");
  NSArray *empty = [DBUiTheme samplePixelRectForViewX:100 y:100 width:0 height:0
                                            viewWidth:1024 viewHeight:768
                                           proxyWidth:64 proxyHeight:64];
  Require([[empty objectAtIndex:2] integerValue] == 1, @"a zero width still samples a pixel");
  NSArray *degenerate = [DBUiTheme samplePixelRectForViewX:0 y:0 width:10 height:10
                                                 viewWidth:0 viewHeight:0
                                                proxyWidth:64 proxyHeight:64];
  Require([[degenerate objectAtIndex:2] integerValue] == 0, @"an empty view samples nothing");

  // The ink is whichever of the two reads better against the sample, not a
  // lightness threshold, so the crossover sits near Y = 0.18.
  Require([[DBUiTheme inkHexForSampledLuminance:0.9] isEqualToString:[DBUiTheme darkInkHex]],
          @"a light region takes the dark ink");
  Require([[DBUiTheme inkHexForSampledLuminance:0.5] isEqualToString:[DBUiTheme darkInkHex]],
          @"a midtone takes the dark ink, which a 0.5 threshold got wrong");
  Require([[DBUiTheme inkHexForSampledLuminance:0.05] isEqualToString:[DBUiTheme lightInkHex]],
          @"a dark region takes the light ink");
  double crossover = [DBUiTheme inkCrossoverLuminance];
  RequireClose(crossover, 0.18, 0.01,
               @"the crossover is where the two contrasts meet, near 0.179");
  Require([[DBUiTheme inkHexForSampledLuminance:crossover + 0.02]
              isEqualToString:[DBUiTheme darkInkHex]], @"just above it, dark ink");
  Require([[DBUiTheme inkHexForSampledLuminance:crossover - 0.02]
              isEqualToString:[DBUiTheme lightInkHex]], @"just below it, light ink");
  // Whatever the sample, the chosen ink is never the worse of the two: this
  // walks every grey and checks the choice against both real contrast ratios.
  for (int channel = 0; channel <= 255; channel++) {
    DBRgb grey;
    grey.r = grey.g = grey.b = channel / 255.0;
    NSString *hex = [DBUiTheme hexFromRgb:grey];
    NSString *chosen =
        [DBUiTheme inkHexForSampledLuminance:[DBUiTheme relativeLuminance:grey]];
    NSString *other = [chosen isEqualToString:[DBUiTheme darkInkHex]]
        ? [DBUiTheme lightInkHex] : [DBUiTheme darkInkHex];
    Require([DBUiTheme contrastBetweenHex:chosen andHex:hex] >=
                [DBUiTheme contrastBetweenHex:other andHex:hex] - 0.0001,
            [NSString stringWithFormat:@"the chosen ink wins on %@", hex]);
  }

  // The reported wallpaper: #BBBBB4 averages Y = 0.494, just under a 0.5
  // threshold, where white ink is about 1.9:1 and the dark ink about 9.6:1.
  DBRgb wallpaper;
  Require([DBUiTheme parseHex:@"#BBBBB4" into:&wallpaper], @"the wallpaper average parses");
  double wallpaperY = [DBUiTheme relativeLuminance:wallpaper];
  RequireClose(wallpaperY, 0.494, 0.005, @"and measures as reported");
  NSString *wallpaperInk = [DBUiTheme inkHexForSampledLuminance:wallpaperY];
  Require([wallpaperInk isEqualToString:[DBUiTheme darkInkHex]],
          @"a midtone wallpaper takes the dark ink, not white");
  Require([DBUiTheme contrastBetweenHex:wallpaperInk andHex:@"#BBBBB4"] >= 9.0,
          @"which is the legible choice");
  Require([DBUiTheme contrastBetweenHex:[DBUiTheme lightInkHex] andHex:@"#BBBBB4"] < 2.0,
          @"where the light ink would have been unreadable");

  // A genuinely dark region still takes the light ink.
  DBRgb darkPatch;
  Require([DBUiTheme parseHex:@"#404040" into:&darkPatch], @"the dark patch parses");
  NSString *darkPatchInk =
      [DBUiTheme inkHexForSampledLuminance:[DBUiTheme relativeLuminance:darkPatch]];
  Require([darkPatchInk isEqualToString:[DBUiTheme lightInkHex]],
          @"#404040 takes the light ink");
  Require([DBUiTheme contrastBetweenHex:darkPatchInk andHex:@"#404040"] >= 4.5,
          @"and reads well");

  Require(![DBUiTheme needsInkShadowForInk:wallpaperInk background:@"#BBBBB4"],
          @"a legible pair takes no shadow");
  // The only case that does is a background sitting at the crossover, where
  // even the better ink is short of AA: #767676 measures Y = 0.18 and gives
  // about 4.1:1 either way.
  DBRgb worst;
  Require([DBUiTheme parseHex:@"#767676" into:&worst], @"the crossover grey parses");
  double worstY = [DBUiTheme relativeLuminance:worst];
  RequireClose(worstY, crossover, 0.01, @"which is the crossover luminance");
  NSString *worstInk = [DBUiTheme inkHexForSampledLuminance:worstY];
  Require([DBUiTheme contrastBetweenHex:worstInk andHex:@"#767676"] < 4.5,
          @"neither ink reaches AA there");
  Require([DBUiTheme needsInkShadowForInk:worstInk background:@"#767676"],
          @"so that region takes the opposite-ink shadow");
  RequireClose([DBUiTheme inkShadowAlpha], 0.4, 0.001, @"at 40 %");
  Require([DBUiTheme maximumSampleEdge] == 16, @"the covered area is reduced to 16x16");

  // An administrator's colour outranks both core's decision and the sampling.
  NSDictionary *deviceOverride = @{
    @"devices" : @{ @"n1" : @{ @"local" : @{ @"theme" : @{
        @"ink_override" : @{ @"clock" : @"#00FF00" } } } } },
    @"display" : @{ @"theme" : @{ @"ink_override" : @{ @"clock" : @"#FF0000" } } } };
  Require([[DBUiTheme adminInkOverrideHexForRegion:DBUiRegionClock config:deviceOverride
                                          deviceId:@"n1" display:nil]
              isEqualToString:@"#00FF00"], @"the device override wins");
  Require([[DBUiTheme adminInkOverrideHexForRegion:DBUiRegionClock config:deviceOverride
                                          deviceId:@"other" display:nil]
              isEqualToString:@"#FF0000"], @"otherwise the cluster override");
  Require([DBUiTheme adminInkOverrideHexForRegion:DBUiRegionClock
                                           config:[NSDictionary dictionary]
                                         deviceId:@"n1" display:nil] == nil,
          @"and nil when an administrator set none, so sampling decides");
}

// The version/battery line ran underneath the SOS slider in portrait on a real
// device. The footer split is computed in one place and may never overlap.
static void TestFooterAndSosNeverOverlap(void) {
  double sizes[4][2] = { {1024, 768}, {768, 1024}, {480, 320}, {320, 480} };
  for (NSUInteger i = 0; i < 4; i++) {
    double width = sizes[i][0], height = sizes[i][1];
    BOOL portrait = height > width;
    for (int withSos = 0; withSos < 2; withSos++) {
      NSDictionary *layout = [DBUiTheme footerLayoutForViewWidth:width viewHeight:height
                                                        portrait:portrait
                                                      sosVisible:(withSos != 0)];
      NSArray *sos = [layout objectForKey:@"sos"];
      NSArray *qr = [layout objectForKey:@"qr"];
      NSArray *version = [layout objectForKey:@"version"];
      NSString *where = [NSString stringWithFormat:@"%.0fx%.0f sos=%d", width, height,
                                                   withSos];

      double sosX = [[sos objectAtIndex:0] doubleValue];
      double sosY = [[sos objectAtIndex:1] doubleValue];
      double sosW = [[sos objectAtIndex:2] doubleValue];
      double sosH = [[sos objectAtIndex:3] doubleValue];
      if (withSos) {
        Require(sosW > 0 && sosH > 0,
                [@"the slider is laid out: " stringByAppendingString:where]);
      } else {
        Require(sosW == 0 && sosH == 0,
                [@"a hidden slider takes no space: " stringByAppendingString:where]);
      }

      NSArray *others = [NSArray arrayWithObjects:version, qr, nil];
      for (NSArray *other in others) {
        double x = [[other objectAtIndex:0] doubleValue];
        double y = [[other objectAtIndex:1] doubleValue];
        double w = [[other objectAtIndex:2] doubleValue];
        double h = [[other objectAtIndex:3] doubleValue];
        Require(w >= 0 && h >= 0, [@"no negative box: " stringByAppendingString:where]);
        if (!withSos || w == 0 || h == 0) continue;
        BOOL separated = (x + w <= sosX) || (sosX + sosW <= x) ||
                         (y + h <= sosY) || (sosY + sosH <= y);
        Require(separated,
                [@"the footer never overlaps the SOS slider: "
                    stringByAppendingString:where]);
      }

      // The QR block and the version line are neighbours, not a pile.
      double qrRight = [[qr objectAtIndex:0] doubleValue] +
                       [[qr objectAtIndex:2] doubleValue];
      Require([[version objectAtIndex:0] doubleValue] >= qrRight,
              [@"the version line starts after the QR: " stringByAppendingString:where]);
      // Everything stays inside the view.
      Require([[version objectAtIndex:0] doubleValue] +
                  [[version objectAtIndex:2] doubleValue] <= width + 0.001,
              [@"the version line stays on screen: " stringByAppendingString:where]);
      Require(sosY + sosH <= height + 0.001,
              [@"the slider stays on screen: " stringByAppendingString:where]);
      Require([[layout objectForKey:@"height"] doubleValue] > 0,
              [@"the band reserves room: " stringByAppendingString:where]);
    }
  }
}

#pragma mark - SOS

static void TestSosSlideCountdownStateMachine(void) {
  DBSosSlideModel *sos = [[DBSosSlideModel alloc] init];
  [sos configureFromConfig:@{ @"emergency" : @{ @"trigger" : @{ @"countdown_s" : @3 } } }];
  Require(sos.countdownSeconds == 3, @"the countdown comes from configuration");

  // A short drag that stops before the arm point does nothing at all.
  [sos beginTouch];
  [sos updateFraction:0.5];
  Require(sos.phase == DBSosPhaseSliding, @"dragging is its own phase");
  Require(![sos endTouch], @"releasing early does not arm");
  Require(sos.phase == DBSosPhaseIdle, @"and returns to idle");

  [sos beginTouch];
  [sos updateFraction:1.4];
  RequireClose(sos.fraction, 1.0, 0.001, @"the fraction is clamped");
  Require([sos endTouch], @"a full slide arms the countdown");
  Require(sos.phase == DBSosPhaseCountdown, @"the countdown is running");
  Require(sos.remainingSeconds == 3, @"three seconds remain");
  Require(![sos tick], @"two");
  Require(sos.remainingSeconds == 2, @"the countdown is displayed");
  Require(![sos tick], @"one");
  Require([sos tick], @"reaching zero fires exactly once");
  Require(sos.phase == DBSosPhaseFired, @"and latches fired");
  Require(![sos tick], @"a late tick never fires a second alarm");

  // Cancel by tap during the countdown: core is never told.
  [sos reset];
  [sos beginTouch];
  [sos updateFraction:1.0];
  Require([sos endTouch], @"armed again");
  Require([sos cancel], @"a tap cancels the countdown");
  Require(sos.phase == DBSosPhaseIdle, @"and returns to idle");
  Require(![sos tick], @"a cancelled countdown never fires");
  Require(![sos cancel], @"cancelling an idle control reports nothing");

  // countdown_s = 0 fires on release; the value is clamped to 0..10.
  [sos setCountdownSeconds:0];
  [sos reset];
  [sos beginTouch];
  [sos updateFraction:0.95];
  Require([sos endTouch], @"a zero countdown fires on release");
  Require(sos.phase == DBSosPhaseFired, @"immediately");
  [sos setCountdownSeconds:99];
  Require(sos.countdownSeconds == 10, @"the countdown is clamped to ten seconds");
  [sos setCountdownSeconds:-4];
  Require(sos.countdownSeconds == 0, @"and never negative");
  [sos configureFromConfig:[NSDictionary dictionary]];
  Require(sos.countdownSeconds == 3, @"an absent key uses the documented default");
}

#pragma mark - history

static NSDictionary *Row(NSString *identifier, long long ts, NSString *door,
                          NSString *outcome) {
  return [NSDictionary dictionaryWithObjectsAndKeys:
      identifier, @"id", [NSNumber numberWithLongLong:ts], @"ts", door, @"door",
      outcome, @"outcome", [NSString stringWithFormat:@"hlc-%@", identifier], @"hlc", nil];
}

static void TestHistoryPagingFilteringAndGrouping(void) {
  NSMutableArray *raw = [NSMutableArray array];
  for (int i = 0; i < 120; i++) {
    [raw addObject:Row([NSString stringWithFormat:@"o:%d", i], 10000000LL - i * 1000LL,
                       (i % 2 == 0) ? @"d_front" : @"d_back",
                       (i % 3 == 0) ? @"missed" : @"answered")];
  }
  [raw addObject:@"not a row"];
  [raw addObject:[NSDictionary dictionaryWithObject:@"no ts" forKey:@"id"]];
  NSDictionary *log = [NSDictionary dictionaryWithObjectsAndKeys:
      raw, @"rows", [NSNumber numberWithInt:7], @"unread_missed", nil];

  NSArray *rows = [DBCallHistoryModel rowsFromLog:log];
  Require([rows count] == 120, @"malformed rows are dropped");
  Require([DBCallHistoryModel unreadMissedFromLog:log] == 7, @"the badge count is read");
  Require([[DBCallHistoryModel newestHlcInRows:rows] isEqualToString:@"hlc-o:0"],
          @"mark-seen uses the newest hlc");
  Require([DBCallHistoryModel unreadMissedFromLog:nil] == 0, @"a missing log means no badge");

  NSArray *first = [DBCallHistoryModel pageRows:rows beforeMs:0 limit:50];
  Require([first count] == 50, @"the first page holds fifty rows");
  Require([DBCallHistoryModel pageMayHaveMore:first limit:50], @"a full page may have more");
  long long cursor = [DBCallHistoryModel nextBeforeMsForPage:first];
  Require(cursor == 10000000LL - 49 * 1000LL, @"the cursor is the oldest row of the page");
  NSArray *second = [DBCallHistoryModel pageRows:rows beforeMs:cursor limit:50];
  Require([second count] == 50, @"the second page continues below the cursor");
  Require([[[second objectAtIndex:0] objectForKey:@"id"] isEqualToString:@"o:50"],
          @"paging is strictly older than the cursor, never repeating a row");
  NSArray *third = [DBCallHistoryModel pageRows:rows
                                       beforeMs:[DBCallHistoryModel nextBeforeMsForPage:second]
                                          limit:50];
  Require([third count] == 20, @"the last page is short");
  Require(![DBCallHistoryModel pageMayHaveMore:third limit:50],
          @"a short page ends the list");

  NSArray *merged = [DBCallHistoryModel mergeRows:first withPage:second];
  Require([merged count] == 100, @"pages merge without duplicates");
  NSArray *remerged = [DBCallHistoryModel mergeRows:merged withPage:first];
  Require([remerged count] == 100, @"a repeated page adds nothing");
  Require([[[remerged objectAtIndex:0] objectForKey:@"id"] isEqualToString:@"o:0"],
          @"the merged list stays newest first");

  NSArray *missed = [DBCallHistoryModel filterRows:rows filter:DBCallHistoryFilterMissed];
  Require([missed count] == 40, @"the missed filter keeps every third call");
  for (NSDictionary *row in missed)
    Require([DBCallHistoryModel rowIsMissed:row], @"and only missed calls");
  NSArray *byDoor = [DBCallHistoryModel filterRows:rows filter:@"d_back"];
  Require([byDoor count] == 60, @"the door filter keeps one door");
  Require([[DBCallHistoryModel filterRows:rows filter:DBCallHistoryFilterAll] count] == 120,
          @"the all filter keeps everything");

  NSArray *sections = [DBCallHistoryModel groupRowsByDay:first dayKey:^NSString *(long long ms) {
    return ms > 10000000LL - 25 * 1000LL ? @"today" : @"yesterday";
  }];
  Require([sections count] == 2, @"rows group into day sections in list order");
  Require([[[sections objectAtIndex:0] objectForKey:@"day"] isEqualToString:@"today"],
          @"the newest day comes first");
  Require([[[sections objectAtIndex:0] objectForKey:@"rows"] count] == 25,
          @"the first section holds its rows");
}

static void TestHistoryWallClockRendering(void) {
  // 2026-09-02T21:30:00+09:00 == 1788352200000 ms since the epoch.
  long long ms = 1788352200000LL;
  Require([[DBCallHistoryModel dayKeyForTs:ms offsetMinutes:540] isEqualToString:@"2026-09-02"],
          @"the day key is rendered in the cluster zone");
  Require([[DBCallHistoryModel clockForTs:ms offsetMinutes:540] isEqualToString:@"21:30"],
          @"and so is the clock");
  // The same instant is still the previous day in UTC.
  Require([[DBCallHistoryModel dayKeyForTs:ms offsetMinutes:0] isEqualToString:@"2026-09-02"],
          @"UTC is the same civil day here");
  Require([[DBCallHistoryModel clockForTs:ms offsetMinutes:0] isEqualToString:@"12:30"],
          @"but a different clock");
  // A negative offset that crosses back over midnight.
  Require([[DBCallHistoryModel dayKeyForTs:ms offsetMinutes:-780] isEqualToString:@"2026-09-01"],
          @"a negative offset can land on the previous day");
  Require([[DBCallHistoryModel clockForTs:ms offsetMinutes:-780] isEqualToString:@"23:30"],
          @"with the matching clock");
  Require([[DBCallHistoryModel durationTextForMs:65000] isEqualToString:@"1:05"],
          @"call durations read as minutes and seconds");
  Require([[DBCallHistoryModel durationTextForMs:0] length] == 0,
          @"a call without a duration shows nothing");
}

#pragma mark - announcements

static void TestNoticePrecedenceExpiryAndPresets(void) {
  long long now = 1000000LL;
  NSDictionary *config = @{
    @"notice" : @{
      @"global" : @{ @"text" : @"全体のお知らせ", @"expires_ms" : @0 },
      @"presets" : @[
        @{ @"id" : @"p1", @"text" : @"不在です・荷物は玄関前へ" },
        @{ @"id" : @"p2", @"text" : @"裏口へお回りください" },
        @{ @"id" : @"p1", @"text" : @"duplicate" },
        @{ @"id" : @"p3", @"text" : @"   " },
        @"not a preset" ] },
    @"doors" : @{
      @"d_front" : @{ @"notice" : @{ @"text" : @"玄関のお知らせ", @"expires_ms" : @2000000 } },
      @"d_back" : @{ @"notice" : @{ @"text" : @"期限切れ", @"expires_ms" : @900000 } },
      @"d_annex" : @{} } };

  NSDictionary *front = [DBNoticeModel effectiveNoticeForDoor:@"d_front" config:config nowMs:now];
  Require([[DBNoticeModel noticeText:front] isEqualToString:@"玄関のお知らせ"],
          @"the door notice wins over the global one");
  Require([[front objectForKey:@"scope"] isEqualToString:@"door"], @"and says so");

  NSDictionary *back = [DBNoticeModel effectiveNoticeForDoor:@"d_back" config:config nowMs:now];
  Require([[DBNoticeModel noticeText:back] isEqualToString:@"全体のお知らせ"],
          @"an expired door notice falls back to the global one");
  Require([[back objectForKey:@"scope"] isEqualToString:@"global"], @"and says so");

  NSDictionary *annex = [DBNoticeModel effectiveNoticeForDoor:@"d_annex" config:config nowMs:now];
  Require([[DBNoticeModel noticeText:annex] isEqualToString:@"全体のお知らせ"],
          @"a door without its own notice shows the global one");

  // Core addresses the cluster-wide announcement with "*", stored at
  // notice.global; the shell must never emulate it by writing every door.
  Require([DBNoticeTargetGlobal isEqualToString:@"*"], @"the global target is \"*\"");
  NSDictionary *viaGlobal = [DBNoticeModel effectiveNoticeForDoor:DBNoticeTargetGlobal
                                                            config:config nowMs:now];
  Require([[DBNoticeModel noticeText:viaGlobal] isEqualToString:@"全体のお知らせ"],
          @"the global target resolves to notice.global");

  NSArray *active = [DBNoticeModel doorsWithActiveNoticeInConfig:config nowMs:now];
  Require([active count] == 1 && [[active objectAtIndex:0] isEqualToString:@"d_front"],
          @"only doors with a live notice get the tile chip");

  Require(![DBNoticeModel isNoticeActive:@{ @"text" : @"" } nowMs:now], @"empty text is inactive");
  Require([DBNoticeModel isNoticeActive:@{ @"text" : @"x" } nowMs:now],
          @"a notice without an expiry runs until cleared");
  Require(![DBNoticeModel isNoticeActive:nil nowMs:now], @"nil is inactive");

  NSArray *presets = [DBNoticeModel presetsFromConfig:config];
  Require([presets count] == 2, @"invalid, blank, and duplicate presets are dropped");
  Require([[[presets objectAtIndex:0] objectForKey:@"id"] isEqualToString:@"p1"],
          @"presets keep their configured order");
  Require([[DBNoticeModel presetsFromConfig:[NSDictionary dictionary]] count] == 0,
          @"an installation without presets renders none");

  Require([DBNoticeModel expiryMsForPreset:@"1h" nowMs:now endOfDayOffsetMs:0]
              == now + 3600000LL, @"the one hour preset");
  Require([DBNoticeModel expiryMsForPreset:@"today" nowMs:now endOfDayOffsetMs:7200000LL]
              == now + 7200000LL, @"the rest of today uses the local day end");
  Require([DBNoticeModel expiryMsForPreset:@"until_cleared" nowMs:now endOfDayOffsetMs:0] == 0,
          @"until cleared has no deadline");

  NSMutableString *tooLong = [NSMutableString string];
  for (int i = 0; i < 300; i++) [tooLong appendString:@"あ"];
  Require([[DBNoticeModel clampNoticeText:tooLong] length] == DBNoticeMaxTextLength,
          @"the text is clamped to the core limit");
  Require([[DBNoticeModel clampNoticeText:@"  x  "] isEqualToString:@"x"], @"and trimmed");
  Require([[DBNoticeModel clampNoticeText:nil] length] == 0, @"nil is not publishable");
}

#pragma mark - visit purposes

// `visit_purposes.<id>.enabled` is a cross-platform key introduced by the iOS
// package: a bool that defaults to true, so an installation that predates it
// keeps every purpose. A disabled purpose leaves every chooser.
static void TestDisabledVisitPurposesLeaveEveryChooser(void) {
  NSDictionary *config = @{ @"visit_purposes" : @{
      @"p_delivery" : @{ @"order" : @2, @"enabled" : @YES },
      @"p_post" : @{ @"order" : @1, @"enabled" : @NO },
      @"p_guest" : @{ @"order" : @3 },
      @"p_repair" : @{ @"order" : @3, @"enabled" : @"yes" },
      @"p_broken" : @"not an entry" } };

  NSArray *all = [DBPurposeModel allPurposeIdsInConfig:config];
  Require([all count] == 4, @"a malformed entry is dropped, a disabled one is not");
  Require([[all objectAtIndex:0] isEqualToString:@"p_post"], @"order comes first");
  Require([[all objectAtIndex:1] isEqualToString:@"p_delivery"], @"then the next order");
  // Equal order falls back to the identifier, so the list is stable.
  Require([[all objectAtIndex:2] isEqualToString:@"p_guest"], @"ties break by identifier");
  Require([[all objectAtIndex:3] isEqualToString:@"p_repair"], @"and stay stable");

  NSArray *enabled = [DBPurposeModel enabledPurposeIdsInConfig:config];
  Require([enabled count] == 3, @"the disabled purpose is not offered");
  Require([enabled indexOfObject:@"p_post"] == NSNotFound, @"specifically that one");
  Require([[enabled objectAtIndex:0] isEqualToString:@"p_delivery"],
          @"the remaining purposes keep their configured order");

  // Only an explicit false disables.
  Require([DBPurposeModel isPurposeEnabled:nil], @"an absent entry is enabled");
  Require([DBPurposeModel isPurposeEnabled:[NSDictionary dictionary]],
          @"an entry without the key is enabled, so old installations are unchanged");
  Require([DBPurposeModel isPurposeEnabled:@{ @"enabled" : @"no" }],
          @"a non-boolean value never disables a purpose by accident");
  Require(![DBPurposeModel isPurposeEnabled:@{ @"enabled" : @NO }], @"false disables");
  Require([DBPurposeModel isPurposeEnabled:@{ @"enabled" : @YES }], @"true enables");

  // The key the settings toggle writes through the config-write path.
  Require([[DBPurposeModel enabledKeyForPurpose:@"p_post"]
              isEqualToString:@"visit_purposes.p_post.enabled"], @"the written key");
  Require([[DBPurposeModel enabledKeyForPurpose:@""] length] == 0,
          @"an empty identifier never produces a writable key");

  Require([[DBPurposeModel allPurposeIdsInConfig:[NSDictionary dictionary]] count] == 0,
          @"an installation with no purposes renders none");
  Require([[DBPurposeModel enabledPurposeIdsInConfig:nil] count] == 0, @"and nil is safe");
}

#pragma mark - safe mode

static void TestLocalSafeModeAutoClearTiming(void) {
  NSTimeInterval entered = 1000.0;
  Require(![DBSafeModeRecovery shouldClearSafeModeEnteredAt:entered lastHeartbeatAt:1590.0
                                         crashesSinceEntry:0 helperSafeModeActive:NO
                                                       now:1599.0],
          @"nine minutes fifty nine seconds is not yet enough");
  Require([DBSafeModeRecovery shouldClearSafeModeEnteredAt:entered lastHeartbeatAt:1595.0
                                        crashesSinceEntry:0 helperSafeModeActive:NO
                                                      now:1600.0],
          @"ten healthy minutes clear the latch");
  Require(![DBSafeModeRecovery shouldClearSafeModeEnteredAt:entered lastHeartbeatAt:1500.0
                                         crashesSinceEntry:0 helperSafeModeActive:NO
                                                       now:1600.0],
          @"a stalled heartbeat means the window was not actually healthy");
  Require(![DBSafeModeRecovery shouldClearSafeModeEnteredAt:entered lastHeartbeatAt:1595.0
                                         crashesSinceEntry:1 helperSafeModeActive:NO
                                                       now:1600.0],
          @"a crash charged during the window restarts it");
  Require(![DBSafeModeRecovery shouldClearSafeModeEnteredAt:entered lastHeartbeatAt:1595.0
                                         crashesSinceEntry:0 helperSafeModeActive:YES
                                                       now:1600.0],
          @"the app never clears the root helper's own latch");
  Require(![DBSafeModeRecovery shouldClearSafeModeEnteredAt:0 lastHeartbeatAt:1595.0
                                         crashesSinceEntry:0 helperSafeModeActive:NO
                                                       now:1600.0],
          @"an unknown entry time never clears");
  Require(![DBSafeModeRecovery shouldClearSafeModeEnteredAt:entered lastHeartbeatAt:0
                                         crashesSinceEntry:0 helperSafeModeActive:NO
                                                       now:1600.0],
          @"no heartbeat at all never clears");

  RequireClose([DBSafeModeRecovery remainingSecondsEnteredAt:entered now:1300.0], 300.0, 0.001,
               @"the remaining window is reported for 本機情報");
  RequireClose([DBSafeModeRecovery remainingSecondsEnteredAt:entered now:2000.0], 0.0, 0.001,
               @"and never goes negative");
  RequireClose([DBSafeModeRecovery healthyWindowSeconds], 600.0, 0.001, @"ten minutes");

  Require([[DBSafeModeRecovery stateForActive:NO enteredAt:entered lastHeartbeatAt:1595.0
                            crashesSinceEntry:0 helperSafeModeActive:NO now:1600.0]
              isEqualToString:@"off"], @"an inactive latch reports off");
  Require([[DBSafeModeRecovery stateForActive:YES enteredAt:entered lastHeartbeatAt:1595.0
                            crashesSinceEntry:0 helperSafeModeActive:NO now:1300.0]
              isEqualToString:@"healthy_wait"], @"a healthy wait is visible");
  Require([[DBSafeModeRecovery stateForActive:YES enteredAt:entered lastHeartbeatAt:1000.0
                            crashesSinceEntry:0 helperSafeModeActive:NO now:1300.0]
              isEqualToString:@"heartbeat_stalled"], @"a stalled heartbeat is visible");
  Require([[DBSafeModeRecovery stateForActive:YES enteredAt:entered lastHeartbeatAt:1295.0
                            crashesSinceEntry:2 helperSafeModeActive:NO now:1300.0]
              isEqualToString:@"crash_charged"], @"a charged crash is visible");
  Require([[DBSafeModeRecovery stateForActive:YES enteredAt:entered lastHeartbeatAt:1295.0
                            crashesSinceEntry:0 helperSafeModeActive:YES now:1300.0]
              isEqualToString:@"helper_latched"], @"the helper latch is visible");
}

#pragma mark - revoke is a factory reset (spec 5.4)

static void TestRevokeClearsClusterIdentityAndSetup(void) {
  NSString *provisioned = @"{\"name\":\"居間\",\"role\":\"indoor_panel\",\"door\":\"d_front\","
      "\"psk_ref\":\"secret:mesh.psk\",\"psk_hex\":\""
      "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\","
      "\"seed_peers\":[\"10.0.1.10:47172\"],\"setup_complete\":true,\"ui_lang\":\"ja\","
      "\"http_port\":47180}";
  NSString *reset = [DBBootConfig factoryResetJsonFromJson:provisioned];
  Require([reset length] > 0, @"the reset profile is produced");
  NSDictionary *out = [NSJSONSerialization
      JSONObjectWithData:[reset dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
  Require([out isKindOfClass:[NSDictionary class]], @"and is valid JSON");
  Require([out objectForKey:@"psk_ref"] == nil, @"the pairing secret reference is gone");
  Require([out objectForKey:@"psk_hex"] == nil, @"the legacy pairing key is gone");
  Require([out objectForKey:@"seed_peers"] == nil, @"the mesh seeds are gone");
  Require([out objectForKey:@"name"] == nil, @"the operator's device name is gone");
  Require([out objectForKey:@"role"] == nil, @"the role is gone");
  Require([out objectForKey:@"door"] == nil, @"the door assignment is gone");
  Require(![[out objectForKey:@"setup_complete"] boolValue],
          @"the device comes back up in first-run setup");
  // Non-identity local settings survive: they are not cluster membership.
  Require([[out objectForKey:@"ui_lang"] isEqualToString:@"ja"],
          @"the display language is not cluster identity");
  Require([[out objectForKey:@"http_port"] integerValue] == 47180,
          @"the local port is not cluster identity");

  // Reverting an already reset profile is a no-op, and garbage is refused.
  NSString *again = [DBBootConfig factoryResetJsonFromJson:reset];
  Require([again length] > 0, @"a second reset still produces a profile");
  Require([DBBootConfig factoryResetJsonFromJson:@"not json"] == nil,
          @"a corrupt profile is refused rather than half written");

  // The narrower pairing-only clear must not touch the setup fields.
  NSString *pairingOnly = [DBBootConfig unpairedJsonFromJson:provisioned];
  NSDictionary *narrow = [NSJSONSerialization
      JSONObjectWithData:[pairingOnly dataUsingEncoding:NSUTF8StringEncoding] options:0
                   error:NULL];
  Require([[narrow objectForKey:@"name"] isEqualToString:@"居間"],
          @"clearing only the pairing keeps the device identity");
  Require([[narrow objectForKey:@"setup_complete"] boolValue],
          @"and keeps setup complete");
}

int main(void) {
  @autoreleasepool {
    TestLuminanceAndContrastFixedVectors();
    TestCustomColoursWarnButAreNeverRejected();
    TestAutomaticInkPerRegionWithLocalFallback();
    TestAppearanceScheduleReplacesSystemDarkMode();
    TestComputedCallButtonColour();
    TestDeliberateLineBreaksAndVersionLine();
    TestCoreResolvedDisplayContractWins();
    TestVideoAspectIsPreserved();
    TestPerRegionBackgroundSampling();
    TestFooterAndSosNeverOverlap();
    TestSosSlideCountdownStateMachine();
    TestHistoryPagingFilteringAndGrouping();
    TestHistoryWallClockRendering();
    TestNoticePrecedenceExpiryAndPresets();
    TestDisabledVisitPurposesLeaveEveryChooser();
    TestLocalSafeModeAutoClearTiming();
    TestRevokeClearsClusterIdentityAndSetup();
    NSLog(@"native_settings_ux_test ok");
  }
  return 0;
}
