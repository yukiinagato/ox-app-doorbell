#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <sys/utsname.h>
#import <mach/mach.h>
#import "DBDoorScreen.h"
#import "DBWidgets.h"
#import "DBBootConfig.h"
#import "DBTexts.h"
#import "DBUiTheme.h"
#import "DBCallTiming.h"
#import "DBSiren.h"
#import "DBMjpegClient.h"
#import "DBSnapshotPoller.h"
#import "DBRTSPH264Source.h"

// This executable links no production Core, SIP, audio or network implementation.
// Only those external boundaries are substituted; the UIKit screen is unmodified.
static NSString *const Output = @"/var/mobile/Library/DoorbellT35UIKit";
static NSMutableArray *checks, *boundaryCalls;
static NSString *currentCase;
static NSDictionary *accessibilityProbe;
static NSUInteger selectedCase;
static DBRgb RGB(UIColor *color) { CGFloat r=0,g=0,b=0,a=0; if (![color getRed:&r green:&g blue:&b alpha:&a]) { CGFloat w=0; [color getWhite:&w alpha:&a]; r=g=b=w; } DBRgb rgb={r,g,b}; return rgb; }
static void WriteJSON(id value, NSString *name);
static void Check(BOOL ok, NSString *name) {
  task_basic_info_data_t memory; mach_msg_type_number_t count=TASK_BASIC_INFO_COUNT; task_info(mach_task_self(),TASK_BASIC_INFO,(task_info_t)&memory,&count);
  [checks addObject:@{@"resident_bytes":@((unsigned long)memory.resident_size),@"case":currentCase ?: @"setup", @"name":name, @"pass":@(ok)}];
  NSLog(@"T35 %@ %@: %@", currentCase, ok ? @"PASS" : @"FAIL", name);
  WriteJSON(@{@"checks":checks,@"build":[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"],@"pid":@([[NSProcessInfo processInfo] processIdentifier])},@"progress.json");
}
static void Wait(NSTimeInterval seconds) {
  NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
  while ([until timeIntervalSinceNow] > 0) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}
static void WriteJSON(id value, NSString *name) {
  NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:nil];
  [data writeToFile:[Output stringByAppendingPathComponent:name] atomically:YES];
}
static void External(NSString *name) { [boundaryCalls addObject:name]; }
@implementation DBSiren
- (BOOL)playAssetPath:(NSString *)path { (void)path; External(@"audio.play"); return YES; }
- (BOOL)playConfiguredSound:(NSString *)sound loop:(BOOL)loop { (void)sound; (void)loop; External(@"audio.configured"); return YES; }
- (void)playChimeSound:(NSString *)sound assetPath:(NSString *)path { (void)sound; (void)path; External(@"audio.chime"); }
- (void)startSiren:(NSString *)path volume:(NSInteger)volume { (void)path; (void)volume; External(@"audio.siren"); }
- (void)stop {}
@end
@implementation DBMjpegClient
- (void)start { External(@"UNEXPECTED_NETWORK_MJPEG"); }
- (void)stop {}
@end
@implementation DBSnapshotPoller
- (void)start { External(@"UNEXPECTED_NETWORK_SNAPSHOT"); }
- (void)stop {}
@end
@implementation DBRTSPH264Source
- (void)start { External(@"UNEXPECTED_NETWORK_RTSP"); }
- (void)stop {}
- (BOOL)requestKeyFrame { return NO; }
@end

@interface T35Core : NSObject
@property NSDictionary *fixture;
@property NSMutableArray *trace;
@property NSString *callID;
@property BOOL allowPress, allowCancel, allowEmergency;
@property NSUInteger counter;
@end
@implementation T35Core
- (id)init { if ((self=[super init])) { _trace=[NSMutableArray array]; _allowPress=_allowCancel=_allowEmergency=YES; } return self; }
- (NSUInteger)lifecycleGeneration { return 1; }
- (BOOL)cameraActive { return NO; }
- (BOOL)h264CameraActive { return NO; }
- (NSDictionary *)config { return _fixture; }
- (NSDictionary *)lastConfig { return _fixture; }
- (NSDictionary *)pairingInfo { return @{@"state":@"ready"}; }
- (NSDictionary *)cachedLocalTime { return @{@"hh":@10,@"mm":@15,@"ss":@0,@"date":@"2026-09-23",@"offset_min":@540,@"weekday_num":@3}; }
- (NSDictionary *)powerStateNow { return @{@"battery_pct":@80,@"charging":@YES}; }
- (NSString *)coreVersion { return @"ISOLATED-UI-BOUNDARY"; }
- (DBCallTimingSnapshot *)callTimingSnapshot {
  NSArray *calls = _callID ? @[@{@"door":@"test-door",@"call_id":_callID,@"stage_revision":@0,@"state":@"ringing",@"origin":@"test-node",@"dialog_owner":@"",@"snapshot_generation":@"runner-snapshot",@"remaining_ms":@60000,@"recovery_remaining_ms":@10000}] : @[];
  return [[DBCallTimingSnapshot alloc] initWithDocument:@{@"node":@{@"id":@"test-node"},@"snapshot_generation":@"runner-snapshot",@"snapshot_age_ms":@0,@"active_calls":calls,@"emergency":@{@"cancel_requires_password":@YES}}
      coreGeneration:1 requestedAt:DBCallMonotonicTime()];
}
- (NSDictionary *)status { return [self callTimingSnapshot].document; }
- (NSString *)pressV2:(NSString *)door purpose:(NSString *)purpose {
  [_trace addObject:@[@"press",door,purpose]];
  if (!_allowPress) return @"";
  _callID=[NSString stringWithFormat:@"test-call-%lu",(unsigned long)++_counter]; return _callID;
}
- (BOOL)cancelCallV2:(NSString *)door callID:(NSString *)callID reason:(NSString *)reason {
  [_trace addObject:@[@"cancel",door,callID,reason]]; if (_allowCancel) _callID=nil; return _allowCancel;
}
- (BOOL)selectPurposeV2:(NSString *)door callID:(NSString *)callID purpose:(NSString *)purpose {
  [_trace addObject:@[@"purpose",door,callID,purpose]]; return YES;
}
- (void)setVisitorLang:(NSString *)door lang:(NSString *)lang { [_trace addObject:@[@"language",door,lang]]; }
- (BOOL)emergency:(BOOL)active { [_trace addObject:@[@"emergency",@(active)]]; return _allowEmergency; }
- (void)setRuntimeStatusSection:(NSString *)name value:(NSDictionary *)value { (void)name; (void)value; }
- (void)setRuntimeCapability:(NSString *)name enabled:(BOOL)enabled { (void)name; (void)enabled; }
- (BOOL)takeVideoKeyframeRequest { return NO; }
- (NSString *)loadSecret:(NSString *)key { (void)key; External(@"UNEXPECTED_SECRET_READ"); return nil; }
- (void)reportCallRecovery:(NSString *)call restored:(BOOL)restored expectedGeneration:(NSUInteger)generation { (void)call; (void)restored; (void)generation; }
@end

@interface T35Router : NSObject
@property T35Core *core;
@property DBBootConfig *boot;
@property DBTexts *texts;
@property NSUInteger hangups, pins;
@end
@implementation T35Router
- (id)init { if ((self=[super init])) { _core=[T35Core new]; _boot=[DBBootConfig new]; _boot.name=@"T35 isolated UIKit"; _boot.door=@"test-door"; _boot.role=@"door_station"; _boot.uiLang=@"en"; _boot.videoSource=@"none"; _texts=[DBTexts new]; } return self; }
- (void)sipListenerHangup { _hangups++; _core.callID=nil; }
- (void)requestPinThen:(void (^)(void))block { _pins++; block(); }
- (void)showPairing {}
- (void)showSettings {}
@end

static UIView *Find(UIView *view, NSString *identifier) {
  if ([view.accessibilityIdentifier isEqual:identifier]) return view;
  for (UIView *child in view.subviews) { UIView *found=Find(child,identifier); if (found) return found; }
  return nil;
}
static void Tap(UIControl *control) {
  Check([control isKindOfClass:[UIControl class]], @"Production UIControl exists");
  [control sendActionsForControlEvents:UIControlEventTouchDown];
  [control sendActionsForControlEvents:UIControlEventTouchUpInside];
}
static BOOL AlertTap(UIView *view, NSString *title) {
  if ([view isKindOfClass:[UIButton class]] && [[(UIButton *)view currentTitle] isEqual:title]) {
    [(UIButton *)view sendActionsForControlEvents:UIControlEventTouchUpInside]; return YES;
  }
  for (UIView *child in view.subviews) if (AlertTap(child,title)) return YES;
  return NO;
}
static UIAlertView *FindAlert(UIView *view) {
  if ([view isKindOfClass:[UIAlertView class]] && !view.hidden) return (UIAlertView *)view;
  for (UIView *child in view.subviews) { UIAlertView *found=FindAlert(child); if (found) return found; } return nil;
}
static BOOL PressAlert(NSString *title) {
  for (UIWindow *window in [UIApplication sharedApplication].windows) { UIAlertView *alert=FindAlert(window); if (alert && AlertTap(alert,title)) { Wait(0.35); return YES; } }
  return NO;
}
static NSDictionary *Tree(UIView *view) {
  NSMutableDictionary *result=[NSMutableDictionary dictionaryWithDictionary:@{@"class":NSStringFromClass([view class]),@"frame":NSStringFromCGRect(view.frame),@"bounds":NSStringFromCGRect(view.bounds),@"hidden":@(view.hidden),@"accessible":@(view.isAccessibilityElement),@"traits":@((unsigned long long)view.accessibilityTraits)}];
  if (view.accessibilityIdentifier) [result setObject:view.accessibilityIdentifier forKey:@"id"];
  if (view.accessibilityLabel) [result setObject:view.accessibilityLabel forKey:@"label"];
  if ([view isKindOfClass:[UILabel class]] && [(UILabel *)view text]) [result setObject:[(UILabel *)view text] forKey:@"text"];
  if ([view isKindOfClass:[UIButton class]]) {
    UIButton *button=(UIButton *)view; if (button.currentTitle) [result setObject:button.currentTitle forKey:@"title"];
    [result setObject:@(button.titleLabel.font.pointSize) forKey:@"font_size"];
    NSMutableArray *targets=[NSMutableArray array]; for (id target in button.allTargets)
      [targets addObjectsFromArray:[button actionsForTarget:target forControlEvent:UIControlEventTouchUpInside] ?: @[]];
    [result setObject:targets forKey:@"touch_up_actions"];
  }
  if ([view isKindOfClass:[UIScrollView class]]) [result setObject:NSStringFromCGSize([(UIScrollView *)view contentSize]) forKey:@"content_size"];
  NSMutableArray *children=[NSMutableArray array]; for (UIView *child in view.subviews) [children addObject:Tree(child)]; [result setObject:children forKey:@"children"]; return result;
}
static void Capture(UIView *view, NSString *name) { @autoreleasepool {
  [view setNeedsLayout]; [view layoutIfNeeded]; [CATransaction flush]; Wait(0.08);
  UIGraphicsBeginImageContextWithOptions(view.bounds.size, YES, 1);
  if ([view isKindOfClass:[UIWindow class]]) { for (UIWindow *window in [UIApplication sharedApplication].windows) if (!window.hidden) [window.layer renderInContext:UIGraphicsGetCurrentContext()]; } else [view.layer renderInContext:UIGraphicsGetCurrentContext()]; UIImage *image=UIGraphicsGetImageFromCurrentImageContext(); UIGraphicsEndImageContext();
  [UIImagePNGRepresentation(image) writeToFile:[Output stringByAppendingPathComponent:[name stringByAppendingString:@".png"]] atomically:YES];
  if ([view isKindOfClass:[UIWindow class]]) { NSMutableArray *windows=[NSMutableArray array]; for (UIWindow *window in [UIApplication sharedApplication].windows) [windows addObject:Tree(window)]; WriteJSON(@{@"windows":windows},[name stringByAppendingString:@".json"]); } else WriteJSON(Tree(view),[name stringByAppendingString:@".json"]);
}
}
static NSDictionary *Fixture(NSString *mode, BOOL large) {
  NSMutableDictionary *labels=[NSMutableDictionary dictionary], *overrides=[NSMutableDictionary dictionary];
  for (NSString *lang in @[@"en",@"ja",@"zh"]) {
    DBTexts *texts=[DBTexts new]; [texts setLang:lang]; NSString *unit=[texts ts:@"door.call_direct"];
    NSString *longText=large ? [@[unit,unit,unit,unit] componentsJoinedByString:@" "] : unit;
    [labels setObject:longText forKey:lang];
    [overrides setObject:@{@"door.call_direct":longText,@"idle.call":longText,@"calling.cancel":[texts ts:@"calling.cancel"],@"incall.end":[texts ts:@"incall.end"]} forKey:lang];
  }
  NSDictionary *style=@{@"font_scale":@(large ? 2 : 1),@"scale":@(large ? 2 : 1)};
  return @{@"ui":@{@"call_flow":mode,@"languages":@[@"en",@"ja",@"zh"]},@"doors":@{@"test-door":@{@"label":labels}},@"visit_purposes":@{@"p_delivery":@{@"label":labels,@"order":@0},@"p_visit":@{@"label":labels,@"order":@1},@"disabled":@{@"label":labels,@"enabled":@NO}},@"emergency":@{@"button_on_roles":@[@"door_station"],@"trigger":@{@"countdown_s":@2}},@"display":@{@"theme":@{@"bg_color":@"#111820"}},@"i18n_overrides":overrides,@"devices":@{@"test-node":@{@"local":@{@"ui":@{@"elements":@{@"call.primary":style,@"cancel.call":style,@"call.end":style,@"purpose.button":style}}}}}};
}

@interface T35Delegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property T35Router *router;
@property DBDoorScreen *screen;
@property NSUInteger sizeIndex;
@end
@implementation T35Delegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
  (void)options; app.idleTimerDisabled=YES;
  checks=[NSMutableArray array]; boundaryCalls=[NSMutableArray array];
  UIButton *probe=[UIButton buttonWithType:UIButtonTypeCustom]; probe.isAccessibilityElement=YES; probe.accessibilityLabel=@"Isolated probe";
  accessibilityProbe=@{@"voice_over_running":@(UIAccessibilityIsVoiceOverRunning()),@"explicit_button_accessible_getter":@(probe.isAccessibilityElement),@"explicit_button_label":probe.accessibilityLabel ?: @""};
  WriteJSON(accessibilityProbe,@"accessibility-probe.json");
  [[NSFileManager defaultManager] createDirectoryAtPath:Output withIntermediateDirectories:YES attributes:nil error:nil];
  _window=[[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
  UIViewController *controller=[UIViewController new]; controller.view=[[UIView alloc] initWithFrame:_window.bounds];
  _window.rootViewController=controller; [_window makeKeyAndVisible];
  selectedCase=[[[NSBundle mainBundle] objectForInfoDictionaryKey:@"T35Case"] unsignedIntegerValue];
  SEL entry=selectedCase==2 ? @selector(run2) : selectedCase==3 ? @selector(run3) : selectedCase==4 ? @selector(run4) : @selector(run1);
  [self performSelector:entry withObject:nil afterDelay:1]; return YES;
}
- (void)mount:(NSString *)mode large:(BOOL)large {
  [_screen removeFromSuperview]; _screen=nil;
  _router=[T35Router new]; _router.core.fixture=Fixture(mode,large);
  _screen=[[DBDoorScreen alloc] initWithRouter:(id)_router]; _screen.frame=_window.bounds;
  [_window.rootViewController.view addSubview:_screen]; [_screen refreshFromCore]; Wait(0.45); [_screen layoutIfNeeded];
}
- (void)run1 {
 @try { @autoreleasepool {
  UIButton *call=nil, *cancel=nil; CGRect anchor=CGRectZero; NSString *callID=nil;
  currentCase=@"T35-01"; [self mount:@"purpose_first" large:NO];
  Check(Find(_screen,@"purpose_disabled")==nil,@"Disabled purpose absent");
  Tap((UIControl *)Find(_screen,@"purpose_p_delivery"));
  Check([[_router.core.trace.lastObject lastObject] isEqual:@"p_delivery"],@"Purpose-first sends the selected purpose once");
  Check([_screen.screenName isEqual:@"door_calling"],@"Purpose-first enters ringing");
  Capture(_screen,@"01-purpose-first-ringing"); Tap((UIControl *)Find(_screen,@"door_cancel_call"));
  Check([_screen.screenName isEqual:@"door_idle"] && _router.hangups==1,@"Visitor cancellation returns idle");
  [self mount:@"ring_then_purpose" large:NO]; Tap((UIControl *)Find(_screen,@"door_call")); Wait(0.3);
  Check([_screen.screenName isEqual:@"door_calling"],@"Ring-first sends immediately");
  Capture(_window,@"01-ring-first-chooser");
  Check(PressAlert([_router.texts ts:@"purpose.skip"]),@"Actual UIKit skip button dispatched");
  Check(_router.core.trace.count==1 && [_screen.screenName isEqual:@"door_calling"],@"Skip preserves the call");
  Tap((UIControl *)Find(_screen,@"door_cancel_call"));
  [self mount:@"ring_then_purpose" large:NO]; Tap((UIControl *)Find(_screen,@"door_call")); Wait(0.3);
  NSString *purpose=[[[[Fixture(@"ring_then_purpose",NO) objectForKey:@"visit_purposes"] objectForKey:@"p_delivery"] objectForKey:@"label"] objectForKey:@"en"];
  Check(PressAlert(purpose),@"Actual UIKit purpose button dispatched");
  Check([[[_router.core.trace lastObject] objectAtIndex:0] isEqual:@"purpose"],@"Ring-first purpose updates existing call");
  Tap((UIControl *)Find(_screen,@"door_cancel_call"));

 }} @catch (NSException *error) { Check(NO,[NSString stringWithFormat:@"Exception %@: %@",error.name,error.reason]); [self finish]; return; }
 if (selectedCase) [self finish]; else [self performSelector:@selector(run2) withObject:nil afterDelay:0.3];
}

- (void)run2 {
 @try { @autoreleasepool {
  UIButton *call=nil, *cancel=nil; CGRect anchor=CGRectZero; NSString *callID=nil;
  currentCase=@"T35-02"; [self mount:@"purpose_first" large:NO];
  call=(UIButton *)Find(_screen,@"door_call"); anchor=call.frame;
  Tap(call); cancel=(UIButton *)Find(_screen,@"door_cancel_call"); [_screen layoutIfNeeded];
  Check(CGRectEqualToRect(anchor,cancel.frame),@"Call and cancel share the fixed action area");
  [cancel sendActionsForControlEvents:UIControlEventTouchDown]; callID=_router.core.callID;
  [_screen handleCallAnswered:@{@"door":@"test-door",@"call_id":callID}]; [cancel sendActionsForControlEvents:UIControlEventTouchUpInside];
  Check(_router.hangups==0 && [_screen.screenName isEqual:@"door_in_call"],@"Ringing touch cannot become connected end");
  Check(CGRectEqualToRect(anchor,cancel.frame),@"Connected end remains in the same area"); Capture(_screen,@"02-connected"); Tap(cancel);
  Check(_router.hangups==1 && [_screen.screenName isEqual:@"door_idle"],@"Fresh connected end works");
  [self mount:@"purpose_first" large:NO]; [_screen miniSipListenerStateChanged:DBMiniSipInCall mode:@"audio"];
  cancel=(UIButton *)Find(_screen,@"door_end_call"); Tap(cancel);
  Check(_router.hangups==1 && [_screen.screenName isEqual:@"door_idle"],@"Nil visitor ID native SIP call can end");
  [_screen miniSipListenerStateChanged:DBMiniSipInCall mode:@"audio"]; [cancel sendActionsForControlEvents:UIControlEventTouchDown];
  [_screen miniSipListenerStateChanged:DBMiniSipEnded mode:@"audio"];
  [_screen miniSipListenerStateChanged:DBMiniSipRinging mode:@"audio"];
  [_screen miniSipListenerStateChanged:DBMiniSipInCall mode:@"audio"];
  NSUInteger before=_router.hangups; [cancel sendActionsForControlEvents:UIControlEventTouchUpInside];
  Check(_router.hangups==before && [_screen.screenName isEqual:@"door_in_call"],@"Old nil-ID gesture cannot end the next SIP session"); Tap(cancel);

 }} @catch (NSException *error) { Check(NO,[NSString stringWithFormat:@"Exception %@: %@",error.name,error.reason]); [self finish]; return; }
 if (selectedCase) [self finish]; else [self performSelector:@selector(run3) withObject:nil afterDelay:0.3];
}

- (void)run3 {
 @try { @autoreleasepool {
  UIButton *call=nil, *cancel=nil; CGRect anchor=CGRectZero; NSString *callID=nil;
  currentCase=@"T35-03"; [self mount:@"purpose_first" large:NO]; _router.core.allowPress=NO; Tap((UIControl *)Find(_screen,@"door_call"));
  UIView *overlay=[_screen valueForKey:@"emergencyOverlay"];
  Check(overlay.hidden && [_screen.screenName isEqual:@"door_idle"],@"Ordinary network failure keeps neutral visitor page"); Capture(_screen,@"03-network-failure");
  [_screen handleEmergencyEvent:@{@"active":@YES,@"visual":@YES}];
  Check(!overlay.hidden,@"Authoritative SOS event shows emergency layer"); Capture(_screen,@"03-emergency");
  Tap((UIControl *)Find(_screen,@"door_sos_clear"));
  Check(_router.pins==1 && [[_router.core.trace.lastObject objectAtIndex:0] isEqual:@"emergency"],@"Existing SOS clear passes PIN boundary");
  [_screen handleEmergencyEvent:@{@"active":@NO}];
  DBSosSlider *slider=[_screen valueForKey:@"sos"]; UIControl *accessible=[slider valueForKey:@"accessibilityButton"];
  Check(accessible.isAccessibilityElement && (accessible.accessibilityTraits & UIAccessibilityTraitButton),@"SOS alternative is an explicit accessibility button");
  NSUInteger count=_router.core.trace.count; [accessible sendActionsForControlEvents:UIControlEventTouchUpInside]; Wait(0.3);
  Check(_router.core.trace.count==count,@"Accessible activation requires confirmation"); Capture(_window,@"03-sos-confirmation");
  Check(PressAlert([_router.texts ts:@"sos.accessibility_start"]),@"Actual UIKit SOS confirmation button dispatched");
  Check(_router.core.trace.count==count,@"Confirmed SOS observes countdown"); Wait(2.4);
  Check(_router.core.trace.count==count+1 && [[_router.core.trace.lastObject objectAtIndex:1] boolValue],@"SOS timer delivers once to isolated Core boundary");

 }} @catch (NSException *error) { Check(NO,[NSString stringWithFormat:@"Exception %@: %@",error.name,error.reason]); [self finish]; return; }
 if (selectedCase) [self finish]; else [self performSelector:@selector(run4) withObject:nil afterDelay:0.3];
}

- (void)run4 {
 @try { @autoreleasepool {
  UIButton *call=nil, *cancel=nil; CGRect anchor=CGRectZero; NSString *callID=nil;
  currentCase=@"T35-04"; NSString *lang=[@[@"en",@"ja",@"zh"] objectAtIndex:_sizeIndex/2]; NSNumber *landscape=@(_sizeIndex%2);
    [self mount:@"purpose_first" large:YES]; [_screen handleVisitorLangEvent:@{@"door":@"test-door",@"lang":lang}];
    _screen.frame=CGRectMake(0,0,[landscape boolValue]?1024:768,[landscape boolValue]?768:1024);
    [_screen setNeedsLayout]; [_screen layoutIfNeeded]; call=(UIButton *)Find(_screen,@"door_call"); anchor=call.frame;
    UILabel *hint=[_screen valueForKey:@"touchHint"];
    double contrast=[DBUiTheme contrastBetween:RGB(hint.textColor) and:RGB(_screen.backgroundColor)];
    Check(contrast>=4.5,@"Hint ink contrasts with the actual flat background");
    Check(CGRectContainsRect(_screen.bounds,anchor) && anchor.size.height>=44,@"Large multilingual call remains inside viewport");
    CGPoint center=CGPointMake(CGRectGetMidX(anchor),CGRectGetMidY(anchor)); UIView *hit=[_screen hitTest:center withEvent:nil];
    Check(hit==call || [hit isDescendantOfView:call],@"UIKit hit testing reaches the primary call");
    CGSize text=[call.currentTitle sizeWithFont:call.titleLabel.font constrainedToSize:CGSizeMake(call.bounds.size.width-24,1000) lineBreakMode:NSLineBreakByWordWrapping];
    Check(text.height<=call.bounds.size.height-16,@"Actual UIKit font measurement fits long call text");
    NSString *name=[NSString stringWithFormat:@"04-%@-%@-large",lang,[landscape boolValue]?@"landscape-size":@"portrait-size"]; Capture(_screen,name);
    Tap(call); cancel=(UIButton *)Find(_screen,@"door_cancel_call"); [_screen layoutIfNeeded];
    Check(CGRectEqualToRect(anchor,cancel.frame),@"Large cancel stays in the fixed area");
    Check(cancel.accessibilityLabel.length>0,@"Large cancel has its explicit accessibility label");
    Check(cancel.isAccessibilityElement && (cancel.accessibilityTraits & UIAccessibilityTraitButton),@"Large cancel is an explicit accessibility button");
    Capture(_screen,[name stringByAppendingString:@"-ringing"]); Tap(cancel);
    Check([_screen.screenName isEqual:@"door_idle"],@"Large multilingual cancellation completes");

 }} @catch (NSException *error) { Check(NO,[NSString stringWithFormat:@"Exception %@: %@",error.name,error.reason]); [self finish]; return; }
 if (++_sizeIndex<6) [self performSelector:@selector(run4) withObject:nil afterDelay:0.3]; else [self finish];
}

- (void)finish {
  NSUInteger failed=0; for (NSDictionary *check in checks) if (![[check objectForKey:@"pass"] boolValue]) failed++;
  struct utsname system; uname(&system);
  WriteJSON(@{@"selected_case":@(selectedCase),@"accessibility_probe":accessibilityProbe,@"pid":@([[NSProcessInfo processInfo] processIdentifier]),@"source_manifest":[[NSBundle mainBundle] objectForInfoDictionaryKey:@"T35SourceManifest"],@"bundle_id":[[NSBundle mainBundle] bundleIdentifier],@"version":[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"],@"build":[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"],@"system_version":[UIDevice currentDevice].systemVersion,@"machine":[NSString stringWithUTF8String:system.machine],@"checks":checks,@"failed":@(failed),@"boundary_calls":boundaryCalls,@"scope":@"Actual iPad UIKit hierarchy, production target/actions, dialogs, timers, hit-testing and rendering. UIControl events are programmatically dispatched; no HID injection, physical rotation, VoiceOver speech or external Core action."},@"result.json");
  NSLog(@"T35 COMPLETE: %lu checks, %lu failures",(unsigned long)checks.count,(unsigned long)failed);
}
@end
int main(int argc,char **argv) { @autoreleasepool { freopen("/var/mobile/Library/DoorbellT35UIKit/runner.log","w",stderr); fprintf(stderr,"T35 main entered\n"); fflush(stderr); return UIApplicationMain(argc,argv,nil,NSStringFromClass([T35Delegate class])); } }
