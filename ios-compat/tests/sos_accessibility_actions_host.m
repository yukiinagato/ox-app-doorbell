#import <Foundation/Foundation.h>
#import "DBSosSlideModel.h"
static int checks, failures;
#define CHECK(...) do { checks++; if (!(__VA_ARGS__)) { failures++; NSLog(@"FAIL %d: %s", __LINE__, #__VA_ARGS__); } } while (0)
@interface FakeTexts : NSObject
@end
@implementation FakeTexts
- (NSString *)ts:(NSString *)key { return key; }
@end
@interface UIAlertView : NSObject
@property NSInteger cancelButtonIndex;
@property(weak) id delegate;
@property BOOL shown;
@end
@implementation UIAlertView
- (id)initWithTitle:(NSString *)title message:(NSString *)message delegate:(id)delegate
    cancelButtonTitle:(NSString *)cancel otherButtonTitles:(NSString *)other, ... {
  (void)title; (void)message; (void)cancel; (void)other;
  if ((self = [super init])) _delegate = delegate; return self;
}
- (void)show { _shown = YES; }
- (void)dismissWithClickedButtonIndex:(NSInteger)index animated:(BOOL)animated { (void)index; (void)animated; _shown = NO; }
@end
@interface FakeDelegate : NSObject
@property NSInteger arms, cancels, fires;
@end
@implementation FakeDelegate
- (void)sosSliderDidArm:(id)slider { (void)slider; _arms++; }
- (void)sosSliderDidCancel:(id)slider { (void)slider; _cancels++; }
- (void)sosSliderDidFire:(id)slider { (void)slider; _fires++; }
@end
@interface DBSosSlider : NSObject {
@public
  DBSosSlideModel *_model; FakeTexts *_texts; NSTimer *_timer; UIAlertView *_accessibilityConfirmation;
}
@property BOOL hidden;
@property NSObject *window;
@property FakeDelegate *delegate;
- (BOOL)accessibilityActivate;
- (void)finishArming;
- (void)reset;
@end
@implementation DBSosSlider
- (id)init { if ((self = [super init])) { _model = [DBSosSlideModel new]; _texts = [FakeTexts new]; _window = [NSObject new]; _delegate = [FakeDelegate new]; } return self; }
- (void)applyState {}
// PRODUCTION_SELECTORS
@end
int main(void) { @autoreleasepool {
  DBSosSlider *s = [DBSosSlider new];
  [s onAccessibleButton]; CHECK(s->_accessibilityConfirmation.shown); CHECK(s.delegate.fires == 0 && s.delegate.arms == 0);
  CHECK(![s accessibilityActivate]);
  [s alertView:s->_accessibilityConfirmation clickedButtonAtIndex:0]; CHECK(s->_model.phase == DBSosPhaseIdle);
  [s onAccessibleButton]; [s alertView:s->_accessibilityConfirmation clickedButtonAtIndex:1];
  CHECK(s.delegate.arms == 1 && s.delegate.fires == 0 && s->_model.phase == DBSosPhaseCountdown);
  [s onAccessibleButton]; CHECK(s.delegate.cancels == 1 && s.delegate.fires == 0 && s->_timer == nil);
  [s onAccessibleButton]; [s alertView:s->_accessibilityConfirmation clickedButtonAtIndex:1];
  [s onCountdownTick:nil]; [s onCountdownTick:nil]; CHECK(s.delegate.fires == 0);
  [s onCountdownTick:nil]; CHECK(s.delegate.fires == 1 && s->_timer == nil);
  [s onCountdownTick:nil]; CHECK(s.delegate.fires == 1);
  s->_model.countdownSeconds = 0; [s onAccessibleButton]; CHECK(s.delegate.fires == 1);
  [s alertView:s->_accessibilityConfirmation clickedButtonAtIndex:1]; CHECK(s.delegate.fires == 2);
  [s onAccessibleButton]; UIAlertView *old = s->_accessibilityConfirmation; [s reset];
  [s alertView:old clickedButtonAtIndex:1]; CHECK(s.delegate.fires == 2);
  s.hidden = YES; CHECK(![s accessibilityActivate]); s.hidden = NO; s.window = nil;
  CHECK(![s accessibilityActivate]);
  s.window = [NSObject new]; [s onAccessibleButton]; s.window = nil;
  [s alertView:s->_accessibilityConfirmation clickedButtonAtIndex:1]; CHECK(s.delegate.fires == 2);
  NSLog(@"SOS production accessibility selectors: %d checks, %d failures", checks, failures);
  return failures ? 1 : 0;
} }
