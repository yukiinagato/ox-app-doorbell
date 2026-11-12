#import <Foundation/Foundation.h>
#import "DBDoorVisitorLayout.h"
#import "DBSosSlideModel.h"

static int checks, failures;
#define CHECK(...) do { checks++; if (!(__VA_ARGS__)) { failures++; NSLog(@"FAIL %d: %s", __LINE__, #__VA_ARGS__); } } while (0)
static BOOL inside(CGRect frame, CGSize size) {
  return frame.origin.x >= 0 && frame.origin.y >= 0 &&
      CGRectGetMaxX(frame) <= size.width + 0.01 && CGRectGetMaxY(frame) <= size.height + 0.01;
}
static BOOL empty(CGRect frame) { return frame.size.width <= 0 || frame.size.height <= 0; }
static BOOL within(CGRect frame, CGRect outer) {
  return CGRectGetMinX(frame) >= CGRectGetMinX(outer) - 0.01 &&
      CGRectGetMinY(frame) >= CGRectGetMinY(outer) - 0.01 &&
      CGRectGetMaxX(frame) <= CGRectGetMaxX(outer) + 0.01 &&
      CGRectGetMaxY(frame) <= CGRectGetMaxY(outer) + 0.01;
}
static BOOL overlap(CGRect a, CGRect b) {
  if (empty(a) || empty(b)) return NO;
  CGRect shared = CGRectIntersection(a, b);
  return !CGRectIsNull(shared) && shared.size.width > 0.01 && shared.size.height > 0.01;
}
static void checkLayout(DBDoorVisitorLayout layout, CGSize size, BOOL sos, BOOL language,
                        BOOL notice) {
  BOOL pad = MIN(size.width, size.height) >= 768;
  CGRect frames[] = {layout.topBar, layout.language, layout.clock, layout.date, layout.notice,
                     layout.purposes, layout.status, layout.action, layout.sos, layout.version};
  NSUInteger count = sizeof(frames) / sizeof(frames[0]);
  for (NSUInteger a = 0; a < count; a++) {
    if (empty(frames[a])) continue;
    CHECK(inside(frames[a], size));
    for (NSUInteger b = a + 1; b < count; b++) CHECK(!overlap(frames[a], frames[b]));
  }
  CHECK(!empty(layout.topBar) && layout.topBar.origin.y == 0 &&
        layout.topBar.size.width == size.width);
  CHECK(!empty(layout.purposes) && !empty(layout.status) && !empty(layout.action) &&
        !empty(layout.version));
  CHECK(empty(layout.sos) == !sos);
  CHECK(empty(layout.language) == !language);
  CHECK(empty(layout.notice) == !notice);
  CHECK(empty(layout.clock) == empty(layout.date));
  CHECK(inside(layout.content, size) && layout.content.size.height >= 44);
  CGRect stacked[] = {layout.language, layout.clock, layout.date, layout.notice,
                      layout.purposes, layout.headline};
  for (NSUInteger a = 0; a < sizeof(stacked) / sizeof(stacked[0]); a++)
    if (!empty(stacked[a])) CHECK(within(stacked[a], layout.content));
  CGRect zone[] = {layout.topBar, layout.status, layout.action, layout.sos, layout.version};
  for (NSUInteger a = 0; a < sizeof(zone) / sizeof(zone[0]); a++)
    CHECK(!overlap(layout.content, zone[a]));
  // The expanded announcement and the reply may cover the clock, the date, and the collapsed
  // announcement, and nothing a visitor can press unless the screen has no other room.
  CHECK(layout.headline.size.height >= 44);
  CHECK(!overlap(layout.headline, layout.language));
  if (!empty(layout.clock) || !empty(layout.notice))
    CHECK(!overlap(layout.headline, layout.purposes));
  CHECK(layout.action.size.width >= 44 && layout.action.size.height >= 44);
  CHECK(layout.purposes.size.height >= 44 && layout.status.size.height >= 44);
  if (language) CHECK(layout.language.size.height >= 44);
  if (sos) CHECK(layout.sos.size.height >= 44);
  // SOS is a compact secondary control: never as wide or as tall as the primary action.
  if (sos) CHECK(layout.sos.size.width <= 132 && layout.sos.size.height < layout.action.size.height);
  CHECK(layout.sideBySide == (size.width > size.height));
  if (layout.sideBySide) CHECK(CGRectGetMaxX(layout.content) <= CGRectGetMinX(layout.action));
  else CHECK(CGRectGetMaxY(layout.content) <= CGRectGetMinY(layout.status));
  CHECK(CGRectGetMaxY(layout.status) <= CGRectGetMinY(layout.action));
  CHECK(CGRectGetMaxY(layout.action) <=
        (sos ? CGRectGetMinY(layout.sos) : CGRectGetMinY(layout.version)));
  if (pad) {
    CHECK(layout.action.size.height >= 72 && layout.action.size.width >= 72);
    CHECK(layout.purposeRowHeight >= 72);
    CHECK(layout.purposes.size.height >= layout.purposeRowHeight);
    CHECK(!empty(layout.clock));
    CHECK(layout.purposeColumns >= 3 && layout.purposeColumns <= 4);
  } else if (size.width < 500) {
    CHECK(layout.purposeColumns == 2);
  }
  CGFloat rows[] = {0, 72, 131.5};
  for (NSUInteger r = 0; r < sizeof(rows) / sizeof(rows[0]); r++) {
    CGRect previous = CGRectZero;
    for (NSInteger index = 0; index < 9; index++) {
      CGRect cell = DBDoorVisitorPurposeFrame(layout, index, rows[r]);
      CGFloat gridHeight = DBDoorVisitorPurposeGridHeight(layout, index + 1, rows[r]);
      CHECK(cell.origin.x >= 0 && cell.origin.y >= 0);
      CHECK(CGRectGetMaxX(cell) <= layout.purposes.size.width + 0.01);
      CHECK(fabs(CGRectGetMaxY(cell) - gridHeight) < 0.01);
      CHECK(cell.size.width >= 72 && cell.size.height >= 72 && cell.size.height >= rows[r]);
      CHECK(!overlap(cell, previous));
      for (NSInteger other = 0; other < index; other++)
        CHECK(!overlap(cell, DBDoorVisitorPurposeFrame(layout, other, rows[r])));
      previous = cell;
    }
    CHECK(DBDoorVisitorPurposeGridHeight(layout, 0, rows[r]) == 0);
  }
}
int main(void) { @autoreleasepool {
  CGSize sizes[] = {{320,480},{480,320},{320,568},{568,320},{375,667},{667,375},
                    {414,736},{736,414},{768,1024},{1024,768}};
  for (NSUInteger i = 0; i < sizeof(sizes)/sizeof(sizes[0]); i++) {
    for (int sos = 0; sos <= 1; sos++) for (int scale = 1; scale <= 2; scale++) {
      DBDoorVisitorLayout layout = DBDoorVisitorLayoutMake(sizes[i], sos, scale);
      checkLayout(layout, sizes[i], sos, YES, YES);
      for (int language = 0; language <= 1; language++) for (int notice = 0; notice <= 1; notice++) {
        DBDoorVisitorLayout fitted = DBDoorVisitorLayoutFit(layout, language, notice);
        checkLayout(fitted, sizes[i], sos, language, notice);
        // Geometry deliberately has no language, announcement, call phase or
        // purpose count input for the action zone; all of those share the same rectangles.
        CHECK(CGRectEqualToRect(fitted.action, layout.action));
        CHECK(CGRectEqualToRect(fitted.status, layout.status));
        CHECK(CGRectEqualToRect(fitted.sos, layout.sos));
        CHECK(CGRectEqualToRect(fitted.version, layout.version));
        CHECK(CGRectEqualToRect(fitted.content, layout.content));
        // A row that is not shown gives its space to the purposes, or to a clock that
        // did not fit before.
        CHECK(fitted.purposes.size.height >= layout.purposes.size.height ||
              (empty(layout.clock) && !empty(fitted.clock)));
        if (language && notice) CHECK(memcmp(&fitted, &layout, sizeof(layout)) == 0);
      }
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
