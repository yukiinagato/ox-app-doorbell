#import <Foundation/Foundation.h>
#import "DBDoorVisitorLayout.h"
#import "DBSosSlideModel.h"

static int checks, failures;
#define CHECK(...) do { checks++; if (!(__VA_ARGS__)) { failures++; NSLog(@"FAIL %d: %s", __LINE__, #__VA_ARGS__); } } while (0)
static BOOL inside(CGRect frame, CGSize size) {
  return frame.origin.x >= 0 && frame.origin.y >= 0 &&
      CGRectGetMaxX(frame) <= size.width + 0.01 && CGRectGetMaxY(frame) <= size.height + 0.01;
}
int main(void) { @autoreleasepool {
  CGSize sizes[] = {{320,480},{480,320},{320,568},{568,320},{375,667},{667,375},
                    {414,736},{736,414},{768,1024},{1024,768}};
  for (NSUInteger i = 0; i < sizeof(sizes)/sizeof(sizes[0]); i++) {
    for (int sos = 0; sos <= 1; sos++) for (int scale = 1; scale <= 2; scale++) {
      DBDoorVisitorLayout layout = DBDoorVisitorLayoutMake(sizes[i], sos, scale);
      CHECK(inside(layout.action, sizes[i])); CHECK(inside(layout.status, sizes[i]));
      CHECK(inside(layout.content, sizes[i])); CHECK(inside(layout.version, sizes[i]));
      CHECK(layout.action.size.width >= 44 && layout.action.size.height >= 44);
      CHECK(layout.content.size.height >= 44);
      CHECK(CGRectGetMaxY(layout.content) <= CGRectGetMinY(layout.status));
      CHECK(CGRectGetMaxY(layout.status) <= CGRectGetMinY(layout.action));
      CHECK(CGRectGetMaxY(layout.action) <= (sos ? CGRectGetMinY(layout.sos) : CGRectGetMinY(layout.version)));
      if (sos) { CHECK(inside(layout.sos, sizes[i])); CHECK(layout.sos.size.height >= 44); }
      // Geometry deliberately has no language, announcement, call phase or
      // purpose count input; all of those share the same action rectangle.
      CHECK(CGRectEqualToRect(layout.action, DBDoorVisitorLayoutMake(sizes[i], sos, scale).action));
    }
  }
  for (NSInteger seconds = 0; seconds <= 10; seconds++) {
    DBSosSlideModel *touch = [DBSosSlideModel new];
    DBSosSlideModel *accessible = [DBSosSlideModel new];
    touch.countdownSeconds = accessible.countdownSeconds = seconds;
    [touch beginTouch]; [touch updateFraction:1]; CHECK([touch endTouch]);
    CHECK([accessible confirmAccessibilityActivation]);
    CHECK(touch.phase == accessible.phase && touch.remainingSeconds == accessible.remainingSeconds);
    CHECK(![accessible confirmAccessibilityActivation]);
    for (NSInteger remaining = seconds; remaining > 0; remaining--) {
      CHECK([touch tick] == [accessible tick]);
      CHECK(touch.phase == accessible.phase && touch.remainingSeconds == accessible.remainingSeconds);
    }
    CHECK(accessible.phase == DBSosPhaseFired); CHECK(![accessible tick]);
    [accessible reset]; CHECK(accessible.phase == DBSosPhaseIdle);
  }
  DBSosSlideModel *cancel = [DBSosSlideModel new];
  CHECK([cancel confirmAccessibilityActivation]); CHECK([cancel cancel]); CHECK(![cancel tick]);
  CHECK(cancel.phase == DBSosPhaseIdle);
  NSLog(@"Visitor production layout and SOS model: %d checks, %d failures", checks, failures);
  return failures ? 1 : 0;
} }
