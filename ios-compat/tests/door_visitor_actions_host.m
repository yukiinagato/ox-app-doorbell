#import <Foundation/Foundation.h>

// The runner compiles the unmodified production selector bodies with these
// host substitutes. No device, network, audio or door action is performed.
static int failures, checks;
#define CHECK(...) do { checks++; if (!(__VA_ARGS__)) { failures++; NSLog(@"FAIL line %d: %s", __LINE__, #__VA_ARGS__); } } while (0)
typedef enum { DBDoorFlowIdle, DBDoorFlowCalling, DBDoorFlowInCall } DBDoorFlowState;
typedef enum { DBDoorPurposeAlertNone, DBDoorPurposeAlertLocal, DBDoorPurposeAlertActiveCall } DBDoorPurposeAlertMode;
static const NSInteger UIControlStateNormal = 0;
@interface FakeView : NSObject
@property BOOL hidden;
@property id backgroundColor;
@property id textColor;
@end
@implementation FakeView
@end
@interface UIButton : NSObject
@property NSInteger tag;
@property id backgroundColor;
@end
@implementation UIButton
- (void)setTitleColor:(id)color forState:(NSInteger)state { (void)color; (void)state; }
@end
@class UIAlertView;
static UIAlertView *shownAlert;
@interface UIAlertView : NSObject
@property NSInteger cancelButtonIndex;
@property NSInteger buttonCount;
@property(weak) id delegate;
@end
@implementation UIAlertView
- (id)initWithTitle:(NSString *)title message:(NSString *)message delegate:(id)delegate
    cancelButtonTitle:(NSString *)cancel otherButtonTitles:(NSString *)other, ... {
  (void)title; (void)message; (void)cancel; (void)other;
  if ((self = [super init])) { _delegate = delegate; _buttonCount = 1; } return self;
}
- (NSInteger)addButtonWithTitle:(NSString *)title { (void)title; return _buttonCount++; }
- (void)show { shownAlert = self; }
- (void)dismissWithClickedButtonIndex:(NSInteger)index animated:(BOOL)animated { (void)index; (void)animated; }
@end
@interface DBSosSlider : NSObject
@end
@implementation DBSosSlider
@end
@interface FakeBoot : NSObject
@property(copy) NSString *door;
@end
@implementation FakeBoot
@end
@interface FakeTexts : NSObject
- (NSString *)ts:(NSString *)key;
- (NSString *)t:(NSString *)key, ...;
@end
@implementation FakeTexts
- (NSString *)ts:(NSString *)key { return key; }
- (NSString *)t:(NSString *)key, ... { return key; }
@end
@interface FakeCore : NSObject
@property NSMutableArray *trace;
@property BOOL allowsCancel;
@property BOOL allowsPress;
@property BOOL allowsEmergency;
@end
@implementation FakeCore
- (id)init { if ((self = [super init])) { _trace = [NSMutableArray array]; _allowsCancel = YES; _allowsPress = YES; _allowsEmergency = YES; } return self; }
- (NSString *)pressV2:(NSString *)door purpose:(NSString *)purpose {
  [_trace addObject:@[@"press", door, purpose]]; return _allowsPress ? @"call-A" : @"";
}
- (BOOL)cancelCallV2:(NSString *)door callID:(NSString *)callID reason:(NSString *)reason {
  [_trace addObject:@[@"cancel", door, callID, reason]]; return _allowsCancel;
}
- (BOOL)selectPurposeV2:(NSString *)door callID:(NSString *)callID purpose:(NSString *)purpose {
  [_trace addObject:@[@"purpose", door, callID, purpose]]; return YES;
}
- (BOOL)emergency:(BOOL)active { [_trace addObject:@[@"emergency", @(active)]]; return _allowsEmergency; }
@end
@interface FakeRouter : NSObject
@property NSInteger hangups;
@property NSInteger pins;
@end
@implementation FakeRouter
- (void)sipListenerHangup { _hangups++; }
- (void)requestPinThen:(void (^)(void))block { _pins++; block(); }
@end
@interface FakeAudio : NSObject
@property NSInteger starts, stops;
@end
@implementation FakeAudio
- (void)playConfiguredSound:(NSString *)name loop:(BOOL)loop { (void)name; (void)loop; }
- (void)startSiren:(NSString *)path volume:(NSInteger)volume { (void)path; (void)volume; _starts++; }
- (void)stop { _stops++; }
@end
@interface DBConfigUtil : NSObject
@end
@implementation DBConfigUtil
+ (id)dig:(NSDictionary *)cfg path:(NSString *)path { return [cfg objectForKey:path]; }
+ (NSString *)str:(NSDictionary *)cfg path:(NSString *)path { id v = [cfg objectForKey:path]; return [v isKindOfClass:[NSString class]] ? v : nil; }
+ (BOOL)boolVal:(NSDictionary *)cfg path:(NSString *)path def:(BOOL)fallback { id v = [cfg objectForKey:path]; return v ? [v boolValue] : fallback; }
+ (NSString *)labelOf:(NSDictionary *)entry lang:(NSString *)lang fallback:(NSString *)fallback { (void)entry; (void)lang; return fallback; }
+ (BOOL)evBool:(NSDictionary *)event key:(NSString *)key { return [[event objectForKey:key] boolValue]; }
+ (NSString *)evStr:(NSDictionary *)event key:(NSString *)key { return [event objectForKey:key]; }
+ (NSInteger)intVal:(NSDictionary *)event path:(NSString *)path def:(NSInteger)value { return [event objectForKey:path] ? [[event objectForKey:path] integerValue] : value; }
+ (NSDictionary *)emergencyPalette:(NSDictionary *)event { (void)event; return @{@"background":@"emergency", @"foreground":@"white", @"accent":@"clear", @"accent_foreground":@"white"}; }
@end

static void touchEvent(id target, NSString *name) {
  SEL action = NSSelectorFromString(name);
  if ([target respondsToSelector:action]) {
    void (*invoke)(id, SEL) = (void (*)(id, SEL))[target methodForSelector:action];
    invoke(target, action);
  }
}

@interface DBDoorScreen : NSObject {
@public
  FakeCore *_core; FakeBoot *_boot; FakeTexts *_texts; FakeRouter *_router; FakeAudio *_feedbackAudio;
  NSDictionary *_cfg, *_status;
  NSArray *_purposeIds, *_purposeAlertIDs;
  NSString *_activeCallID, *_visitorLang, *_purposePromptedCallID, *_callingTitleOverride, *_purposeAlertCallID;
  NSInteger _activeStageRevision, _purposeSkipIndex;
  DBDoorFlowState _flowState;
  BOOL _cancelTouchPending;
  DBDoorFlowState _cancelTouchPhase;
  NSString *_cancelTouchCallID;
  NSUInteger _cancelActionGeneration, _cancelTouchGeneration;
  DBDoorPurposeAlertMode _purposeAlertMode;
  UIAlertView *_purposeAlert;
  FakeView *_emergencyOverlay, *_emergencyTitle, *_emergencyNote;
  UIButton *_emergencyCancel;
  FakeAudio *_alarmAudio;
  BOOL ringFirst; NSInteger chooserCount; NSString *hint;
}
- (BOOL)beginCallWithPurpose:(NSString *)purpose;
- (void)onCancel;
- (void)presentPurposeAlertForActiveCall:(BOOL)active;
- (void)dismissPurposeAlert;
@end
@implementation DBDoorScreen
- (id)init {
  if ((self = [super init])) { _core = [FakeCore new]; _boot = [FakeBoot new]; _boot.door = @"front";
    _texts = [FakeTexts new]; _router = [FakeRouter new]; _feedbackAudio = [FakeAudio new];
    _cfg = @{}; _status = @{}; _purposeIds = @[@"delivery", @"visit"]; _visitorLang = @"en";
    _emergencyOverlay = [FakeView new]; _emergencyOverlay.hidden = YES;
    _emergencyTitle = [FakeView new]; _emergencyNote = [FakeView new];
    _emergencyCancel = [UIButton new]; _alarmAudio = [FakeAudio new]; }
  return self;
}
- (NSString *)callFlowMode { return ringFirst ? @"ring_then_purpose" : @"purpose_first"; }
- (BOOL)showsHomePurposes { return !ringFirst && [_purposeIds count] > 0; }
- (void)showCallingWithTitle:(NSString *)title { _flowState = DBDoorFlowCalling; _callingTitleOverride = title; }
- (void)showIdleWithHint:(NSString *)text { _flowState = DBDoorFlowIdle; _activeCallID = nil; hint = text; }
- (void)applyStrings {}
- (void)bringSubviewToFront:(id)view { (void)view; }
// PRODUCTION_SELECTORS
@end

int main(void) { @autoreleasepool {
  DBDoorScreen *s = [DBDoorScreen new]; UIButton *button = [UIButton new]; button.tag = 0;
  [s onPurpose:button];
  CHECK([s->_core.trace isEqual:@[@[@"press", @"front", @"delivery"]]]);
  CHECK(s->_flowState == DBDoorFlowCalling && s->chooserCount == 0);
  [s onCall]; CHECK(s->_core.trace.count == 1);
  [s onCancel]; CHECK([s->_core.trace.lastObject isEqual:@[@"cancel", @"front", @"call-A", @"visitor"]]);
  CHECK(s->_router.hangups == 1 && s->_flowState == DBDoorFlowIdle);
  s = [DBDoorScreen new]; [s onCall];
  CHECK([s->_core.trace.lastObject isEqual:@[@"press", @"front", @""]]); CHECK(s->chooserCount == 0);
  s = [DBDoorScreen new]; s->ringFirst = YES; [s onPurpose:button]; CHECK(s->_core.trace.count == 0);
  [s onCall]; CHECK(s->_purposeAlertMode == DBDoorPurposeAlertActiveCall); CHECK([s->_core.trace.lastObject isEqual:@[@"press", @"front", @""]]);
  [s alertView:shownAlert clickedButtonAtIndex:3]; CHECK(s->_core.trace.count == 1); CHECK(s->_flowState == DBDoorFlowCalling);
  [s presentPurposeAlertForActiveCall:YES]; [s alertView:shownAlert clickedButtonAtIndex:2];
  CHECK([s->_core.trace.lastObject isEqual:@[@"purpose", @"front", @"call-A", @"visit"]]); CHECK(s->_activeStageRevision == 1);
  [s presentPurposeAlertForActiveCall:YES]; [s alertView:shownAlert clickedButtonAtIndex:0];
  CHECK(s->_flowState == DBDoorFlowIdle && s->_router.hangups == 1);
  s = [DBDoorScreen new]; s->_core.allowsPress = NO; [s onCall];
  CHECK(s->_flowState == DBDoorFlowIdle && [s->hint isEqual:@"offline.body"]);
  s = [DBDoorScreen new]; [s onCall]; s->_core.allowsCancel = NO; [s onCancel];
  CHECK(s->_flowState == DBDoorFlowCalling && s->_router.hangups == 0);
  s = [DBDoorScreen new]; [s onCall]; s->_flowState = DBDoorFlowInCall; [s onCancel];
  CHECK(s->_core.trace.count == 1 && s->_router.hangups == 1 && s->_flowState == DBDoorFlowIdle);
  s = [DBDoorScreen new]; [s onCall]; touchEvent(s, @"onCancelTouchDown");
  s->_flowState = DBDoorFlowInCall; [s onCancel];
  CHECK(s->_router.hangups == 0 && s->_flowState == DBDoorFlowInCall && s->_core.trace.count == 1);
  [s onCancel]; CHECK(s->_router.hangups == 1 && s->_flowState == DBDoorFlowIdle);
  s = [DBDoorScreen new]; [s onCall]; touchEvent(s, @"onCancelTouchDown");
  s->_activeCallID = @"call-B"; [s onCancel];
  CHECK(s->_router.hangups == 0 && s->_flowState == DBDoorFlowCalling && s->_core.trace.count == 1);
  touchEvent(s, @"onCancelTouchDown"); [s onCancel];
  CHECK([s->_core.trace.lastObject isEqual:@[@"cancel", @"front", @"call-B", @"visitor"]]);
  s = [DBDoorScreen new]; [s onCall]; touchEvent(s, @"onCancelTouchDown");
  touchEvent(s, @"onCancelTouchCancel"); s->_flowState = DBDoorFlowInCall; [s onCancel];
  CHECK(s->_router.hangups == 1 && s->_flowState == DBDoorFlowIdle);
  s = [DBDoorScreen new]; touchEvent(s, @"onCancelTouchDown"); [s onCall]; [s onCancel];
  CHECK(s->_router.hangups == 0 && s->_flowState == DBDoorFlowCalling && s->_core.trace.count == 1);
  s = [DBDoorScreen new]; [s onCall]; touchEvent(s, @"onCancelTouchDown"); [s onCancel];
  CHECK(s->_router.hangups == 1 && s->_flowState == DBDoorFlowIdle);
  s = [DBDoorScreen new]; [s onCall]; s->_flowState = DBDoorFlowInCall;
  touchEvent(s, @"onCancelTouchDown"); [s onCancel];
  CHECK(s->_router.hangups == 1 && s->_flowState == DBDoorFlowIdle && s->_core.trace.count == 1);
  s = [DBDoorScreen new]; s->_flowState = DBDoorFlowInCall;
  touchEvent(s, @"onCancelTouchDown"); [s onCancel];
  CHECK(s->_router.hangups == 1 && s->_flowState == DBDoorFlowIdle && s->_core.trace.count == 0);
  s = [DBDoorScreen new]; s->_flowState = DBDoorFlowInCall;
  touchEvent(s, @"onCancelTouchDown"); s->_cancelActionGeneration++; [s onCancel];
  CHECK(s->_router.hangups == 0 && s->_flowState == DBDoorFlowInCall);
  s = [DBDoorScreen new]; s->ringFirst = YES; [s onCall]; s->_flowState = DBDoorFlowInCall;
  [s alertView:shownAlert clickedButtonAtIndex:1]; CHECK(s->_core.trace.count == 1);
  s = [DBDoorScreen new]; s->ringFirst = YES; [s onCall]; s->_activeCallID = @"call-B";
  [s alertView:shownAlert clickedButtonAtIndex:0]; CHECK(s->_core.trace.count == 1 && s->_router.hangups == 0);
  s = [DBDoorScreen new]; s->ringFirst = YES; [s onCall];
  UIAlertView *oldAlert = shownAlert; s->_activeCallID = @"call-B";
  [s presentPurposeAlertForActiveCall:YES];
  [s alertView:oldAlert clickedButtonAtIndex:0]; CHECK(s->_core.trace.count == 1 && s->_router.hangups == 0);
  s = [DBDoorScreen new]; [s onCancel]; CHECK(s->_router.hangups == 0);
  s = [DBDoorScreen new]; [s sosSliderDidFire:nil]; CHECK([s->_core.trace.lastObject isEqual:@[@"emergency", @YES]]);
  s->_status = @{@"emergency.cancel_requires_password": @YES}; [s onEmergencyCancel]; CHECK(s->_router.pins == 1);
  CHECK([s->_core.trace.lastObject isEqual:@[@"emergency", @NO]]);
  s->_status = @{@"emergency.cancel_requires_password": @NO}; [s onEmergencyCancel]; CHECK(s->_router.pins == 1);
  s = [DBDoorScreen new]; s->_core.allowsPress = NO; [s onCall]; CHECK(s->_emergencyOverlay.hidden);
  [s handleEmergencyEvent:@{@"active":@YES, @"visual":@YES}]; CHECK(!s->_emergencyOverlay.hidden);
  s->_core.allowsEmergency = NO; [s onEmergencyCancel]; CHECK(!s->_emergencyOverlay.hidden);
  [s handleEmergencyEvent:@{@"active":@YES, @"visual":@NO}]; CHECK(s->_emergencyOverlay.hidden);
  [s handleEmergencyEvent:@{@"active":@YES, @"visual":@YES, @"alarm_sound":@"siren"}];
  CHECK(!s->_emergencyOverlay.hidden && s->_alarmAudio.starts == 1);
  [s handleEmergencyEvent:@{@"active":@NO}]; CHECK(s->_emergencyOverlay.hidden && s->_alarmAudio.stops > 0);
  NSLog(@"Visitor production selectors: %d checks, %d failures", checks, failures);
  return failures ? 1 : 0;
} }
