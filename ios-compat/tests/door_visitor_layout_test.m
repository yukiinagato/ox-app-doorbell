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
static void checkLegacy(DBDoorVisitorLayout layout, CGSize size, BOOL sos, BOOL language,
                        BOOL notice) {
  BOOL pad = MIN(size.width, size.height) >= 768;
  CGRect frames[] = {layout.topBar, layout.language, layout.clock, layout.date, layout.air,
                     layout.notice,
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
  CGRect stacked[] = {layout.language, layout.clock, layout.date, layout.air, layout.notice,
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
      if (layout.purposeCount > 0 && index >= layout.purposeCount) break;
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
static void checkGrid(DBDoorVisitorLayout layout, CGSize size) {
  CGFloat rows[] = {0, 72, 131.5};
  for (NSUInteger r = 0; r < sizeof(rows) / sizeof(rows[0]); r++) {
    CGRect previous = CGRectZero;
    for (NSInteger index = 0; index < 9; index++) {
      if (layout.purposeCount > 0 && index >= layout.purposeCount) break;
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
  (void)size;
}
// The single centred column used by every screen at least 500 pt tall.
static void checkColumn(DBDoorVisitorLayout layout, CGSize size, BOOL sos, BOOL language,
                        BOOL notice, NSInteger purposes) {
  BOOL pad = MIN(size.width, size.height) >= 768;
  CGFloat margin = pad ? 32 : 16;
  CGRect frames[] = {layout.topBar, layout.language, layout.clock, layout.date, layout.air,
                     layout.notice, layout.purposes, layout.status, layout.action, layout.sos,
                     layout.version, layout.title};
  NSUInteger count = sizeof(frames) / sizeof(frames[0]);
  for (NSUInteger a = 0; a < count; a++) {
    if (empty(frames[a])) continue;
    CHECK(inside(frames[a], size));
    // The status line is the hint; the stage is a region, not a control.
    for (NSUInteger b = a + 1; b < count; b++) CHECK(!overlap(frames[a], frames[b]));
    if (a > 0) CHECK(CGRectGetMinX(frames[a]) >= margin - 0.01 &&
                     CGRectGetMaxX(frames[a]) <= size.width - margin + 0.01);
  }
  // One centred caption line at the very bottom, below everything else.
  CHECK(!empty(layout.version) && layout.version.size.height >= 14 &&
        fabs(CGRectGetMidX(layout.version) - size.width / 2) <= 1 &&
        CGRectGetMaxY(layout.version) <= size.height - 12 + 0.01);
  CHECK(CGRectGetMaxY(layout.action) <= CGRectGetMinY(layout.version));
  CHECK(CGRectGetMaxY(layout.purposes) <= CGRectGetMinY(layout.version));
  // The door name leads the top row; the stock bar is gone.
  CHECK(empty(layout.topBar) && !empty(layout.title) && layout.title.size.height >= 44);
  CHECK(CGRectGetMinX(layout.title) == CGRectGetMinX(layout.status));
  CHECK(layout.title.origin.y >= 20 && layout.title.origin.y == layout.language.origin.y + 0 ||
        empty(layout.language));
  if (language) CHECK(CGRectGetMaxX(layout.title) <= CGRectGetMinX(layout.language));
  if (pad) CHECK(!empty(layout.clock) && CGRectGetMaxX(layout.clock) <= CGRectGetMinX(layout.language) ||
                 !language);
  CHECK(!empty(layout.status) && !empty(layout.action));
  CHECK(empty(layout.sos) == !sos);
  CHECK(empty(layout.language) == !language);
  CHECK(empty(layout.notice) == !notice);
  CHECK(empty(layout.clock) == empty(layout.date));
  // Centred column, at most 640 pt wide; hint, call button and grid share its axis.
  CHECK(layout.status.size.width <= 640.01 && layout.purposes.size.width <= 640.01);
  CHECK(fabs(CGRectGetMidX(layout.action) - size.width / 2) <= 1);
  CHECK(fabs(CGRectGetMidX(layout.status) - size.width / 2) <= 1);
  CHECK(fabs(CGRectGetMidX(layout.purposes) - size.width / 2) <= 1);
  if (notice) CHECK(fabs(CGRectGetMidX(layout.notice) - size.width / 2) <= 1);
  if (language) CHECK(CGRectGetMaxX(layout.language) == CGRectGetMaxX(layout.status));
  // Hint directly above the call button; the stage reaches down to the hint and no further.
  CHECK(CGRectGetMaxY(layout.status) <= CGRectGetMinY(layout.action));
  CHECK(CGRectGetMinY(layout.action) - CGRectGetMaxY(layout.status) <= layout.gap + 0.01);
  CHECK(layout.status.size.height >= 44);
  CHECK(inside(layout.content, size) && layout.content.size.height >= 44);
  CHECK(CGRectEqualToRect(layout.headline, layout.content));
  CHECK(within(layout.status, layout.content));
  CHECK(CGRectGetMaxY(layout.content) <= CGRectGetMinY(layout.action));
  CGRect above[] = {layout.title, layout.language, layout.clock, layout.date, layout.air};
  for (NSUInteger a = 0; a < sizeof(above) / sizeof(above[0]); a++)
    CHECK(!overlap(layout.content, above[a]));
  if (notice) CHECK(within(layout.notice, layout.content));
  CHECK(!overlap(layout.content, layout.purposes) && !overlap(layout.content, layout.sos));
  CHECK(layout.action.size.width >= 44 && layout.action.size.height >= 44);
  if (sos) CHECK(layout.sos.size.height >= 44 && layout.sos.size.width <= 132 &&
                 layout.sos.size.height < layout.action.size.height);
  CHECK(CGRectGetMinX(layout.sos) == CGRectGetMinX(layout.status) || !sos);
  CGFloat zoneBottom = sos ? CGRectGetMinY(layout.sos) - layout.gap
                           : CGRectGetMinY(layout.version) - 8;
  if (purposes > 0) {
    CHECK(!empty(layout.purposes) && layout.purposes.size.height >= 44);
    CHECK(CGRectGetMinY(layout.purposes) > CGRectGetMaxY(layout.action));
    CHECK(CGRectGetMaxY(layout.purposes) <= zoneBottom + 0.01);
    CHECK(layout.purposeColumns >= 2 && layout.purposeColumns <= 4);
  } else {
    // No purposes: the hero sits at the true centre of the zone below the top rows.
    CGFloat zoneTop = notice ? CGRectGetMaxY(layout.notice) + layout.gap : layout.content.origin.y;
    CHECK(fabs((CGRectGetMinY(layout.status) - zoneTop) -
               (zoneBottom - CGRectGetMaxY(layout.action))) <= 1);
  }
  if (pad) {
    CHECK(layout.action.size.height >= 96 && layout.action.size.width >= 320);
    CHECK(layout.purposeRowHeight >= 72);
    if (purposes > 0) CHECK(layout.purposes.size.height >= layout.purposeRowHeight);
    CHECK(!empty(layout.clock));
    CHECK(layout.purposeColumns == 4);
    CHECK(layout.margin == 32);
  } else {
    CHECK(layout.purposeColumns == 2);
  }
  // Every row of cards is centred on the column axis.
  for (NSInteger row = 0; row * layout.purposeColumns < purposes; row++) {
    NSInteger first = row * layout.purposeColumns;
    NSInteger last = MIN(purposes, first + layout.purposeColumns) - 1;
    CGRect a = DBDoorVisitorPurposeFrame(layout, first, 0), b = DBDoorVisitorPurposeFrame(layout, last, 0);
    CHECK(fabs((CGRectGetMinX(a) + CGRectGetMaxX(b)) / 2 - layout.purposes.size.width / 2) <= 1);
  }
  checkGrid(layout, size);
}
static void checkLayout(DBDoorVisitorLayout layout, CGSize size, BOOL sos, BOOL language,
                        BOOL notice) {
  if (size.height >= 500) checkColumn(layout, size, sos, language, notice, layout.purposeCount);
  else checkLegacy(layout, size, sos, language, notice);
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
        BOOL legacy = sizes[i].height < 500;
        CHECK(CGRectEqualToRect(fitted.sos, layout.sos));
        CHECK(CGRectEqualToRect(fitted.version, layout.version));
        if (legacy) {
          CHECK(CGRectEqualToRect(fitted.action, layout.action));
          CHECK(CGRectEqualToRect(fitted.status, layout.status));
          CHECK(CGRectEqualToRect(fitted.content, layout.content));
        }
        // A row that is not shown gives its space to the purposes, or to a clock that
        // did not fit before.
        if (legacy) CHECK(fitted.purposes.size.height >= layout.purposes.size.height ||
              (empty(layout.clock) && !empty(fitted.clock)));
        if (language && notice) CHECK(memcmp(&fitted, &layout, sizeof(layout)) == 0);
        DBDoorVisitorLayout plain = DBDoorVisitorLayoutFitWithAir(layout, language, notice, NO);
        CHECK(memcmp(&plain, &fitted, sizeof(fitted)) == 0);
        CHECK(empty(fitted.air));
        // The PM2.5 line sits under the date, inside the region the expanded notice covers.
        DBDoorVisitorLayout air = DBDoorVisitorLayoutFitWithAir(layout, language, notice, YES);
        checkLayout(air, sizes[i], sos, language, notice);
        if (legacy) CHECK(CGRectEqualToRect(air.action, layout.action));
        if (!empty(air.air) && legacy) {
          CHECK(!empty(air.date) && fabs(CGRectGetMinY(air.air) - CGRectGetMaxY(air.date)) < 0.01);
          CHECK(air.air.size.height >= 24);
          CHECK(within(air.air, air.headline));
          CHECK(!overlap(air.headline, air.purposes));
        }
        if (MIN(sizes[i].width, sizes[i].height) >= 768) CHECK(!empty(air.air));
        if (!legacy) {
          // Every purpose count, including none: the same column rules hold.
          for (NSInteger n = 0; n <= 9; n += 3) {
            DBDoorVisitorLayout counted = DBDoorVisitorLayoutFitContent(layout, language, notice,
                                                                        YES, n);
            checkColumn(counted, sizes[i], sos, language, notice, n);
          }
        }
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
  // The visitor-flow zone: options fixed at the bottom, never past half the screen, never over
  // SOS, Back or the caption, in every screen class.
  CGSize flowSizes[] = {{768, 1024}, {1024, 768}, {320, 568}, {375, 667}, {834, 1112}};
  for (NSUInteger s = 0; s < sizeof(flowSizes) / sizeof(flowSizes[0]); s++) {
    CGSize size = flowSizes[s];
    for (int sosShown = 0; sosShown < 2; sosShown++) {
      for (int back = 0; back < 2; back++) {
        for (NSInteger secondary = 0; secondary <= 12; secondary += 3) {
          DBDoorVisitorLayout base = DBDoorVisitorLayoutMake(size, sosShown != 0, 1);
          base = DBDoorVisitorLayoutFitContent(base, YES, secondary % 2 == 0, NO, 0);
          DBDoorVisitorFlowLayout flow =
              DBDoorVisitorFlowLayoutMake(base, 0, YES, secondary, 0, back != 0);
          CHECK(inside(flow.zone, size) && inside(flow.options, size));
          CHECK(flow.options.size.height <= floor(size.height * 0.5) + 0.01);
          CHECK(flow.options.size.height > 0);
          CHECK(!overlap(flow.options, base.sos) && !overlap(flow.options, base.version));
          CHECK(!overlap(flow.content, flow.options));
          CHECK(!overlap(flow.options, flow.back) && !overlap(flow.content, flow.back));
          if (back) CHECK(!empty(flow.back) && flow.back.size.height >= 44);
          if (back && sosShown) CHECK(!overlap(flow.back, base.sos));
          CHECK(flow.rowHeight >= 72);
          CHECK(flow.columns == (secondary > 0 ? MIN(base.compact ? 2 : 3, secondary) : (base.compact ? 2 : 3)));
          for (NSInteger i = 0; i < secondary; i++) {
            CGRect frame = DBDoorVisitorFlowOptionFrame(flow, YES, i, secondary);
            CHECK(frame.size.height >= 72 && frame.origin.y >= flow.primaryHeight);
            CHECK(CGRectGetMaxX(frame) <= flow.columnWidth + 0.01);
            CHECK(CGRectGetMaxY(frame) <= flow.optionsContentHeight + 0.01);
          }
          CGRect primary = DBDoorVisitorFlowPrimaryFrame(flow);
          CHECK(primary.size.height == base.action.size.height && primary.origin.y == 0);
        }
      }
    }
  }
  // The card and the options form one centred block, with or without a primary option.
  for (NSUInteger s = 0; s < sizeof(flowSizes) / sizeof(flowSizes[0]); s++) {
    CGSize size = flowSizes[s];
    DBDoorVisitorLayout base = DBDoorVisitorLayoutMake(size, NO, 1);
    base = DBDoorVisitorLayoutFitContent(base, YES, NO, NO, 0);
    for (NSInteger count = 1; count <= 12; count += 5) {
      for (int back = 0; back < 2; back++) {
        for (int primary = 0; primary < 2; primary++) {
        DBDoorVisitorFlowLayout flow =
            DBDoorVisitorFlowLayoutMake(base, 0, primary != 0, count, 0, back != 0);
        for (CGFloat cardHeight = 0; cardHeight <= 400; cardHeight += 100) {
          CGRect card, options;
          DBDoorVisitorFlowComposeBlock(flow, cardHeight, &card, &options);
          CHECK(inside(options, size) && !overlap(card, options) && !overlap(options, flow.back));
          CHECK(options.size.height == flow.options.size.height);
          CHECK(card.origin.y >= flow.zone.origin.y - 0.01 &&
                CGRectGetMaxY(options) <= CGRectGetMaxY(flow.zone) + 0.01);
          if (cardHeight > 0 && cardHeight + flow.gap + options.size.height <= flow.zone.size.height) {
            CHECK(card.size.height == cardHeight);
            CGFloat above = card.origin.y - flow.zone.origin.y;
            CGFloat below = CGRectGetMaxY(flow.zone) - CGRectGetMaxY(options);
            CHECK(fabs(above - below) <= 1.01);
            CHECK(fabs(options.origin.y - CGRectGetMaxY(card) - flow.gap) < 0.01);
          }
        }
        }
      }
    }
  }
  CHECK(DBDoorVisitorFlowImageHeight(CGSizeMake(400, 1200), 600, 1000) == 400);
  CHECK(DBDoorVisitorFlowImageHeight(CGSizeMake(400, 100), 400, 1000) == 100);
  CHECK(DBDoorVisitorFlowImageHeight(CGSizeZero, 400, 1000) == 0);
  NSLog(@"Visitor production layout and SOS model: %d checks, %d failures", checks, failures);
  return failures ? 1 : 0;
} }
