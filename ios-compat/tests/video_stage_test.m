#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#import "DBVideoStage.h"

static int failures = 0;
static int checks = 0;
#define CHECK(condition) do { checks++; if (!(condition)) { failures++; \
  NSLog(@"FAIL line %d: %s", __LINE__, #condition); } } while (0)

static BOOL Near(CGFloat a, CGFloat b) { return fabs(a - b) <= 1.0; }

static void CheckSource(CGSize stage, CGSize source, NSInteger rotation) {
  CGSize upright = DBVideoStageUprightSize(source, rotation);
  CGSize fit = DBVideoStageFitSize(stage, source, rotation);
  // Fit at 1x: inside the stage, one axis filled, aspect kept, rotation applied first.
  CHECK(fit.width <= stage.width && fit.height <= stage.height);
  CHECK(Near(fit.width, stage.width) || Near(fit.height, stage.height));
  CHECK(fabs(fit.width / fit.height - upright.width / upright.height) < 0.01);

  for (int step = 0; step <= 12; step++) {
    CGFloat zoom = 1.0f + 0.25f * step;
    DBVideoStageAxis x = DBVideoStageAxisMake(stage.width, fit.width * zoom);
    DBVideoStageAxis y = DBVideoStageAxisMake(stage.height, fit.height * zoom);
    DBVideoStageAxis axes[2] = { x, y };
    CGFloat stageLength[2] = { stage.width, stage.height };
    CGFloat zoomed[2] = { fit.width * zoom, fit.height * zoom };
    for (int i = 0; i < 2; i++) {
      DBVideoStageAxis axis = axes[i];
      CHECK(axis.inset >= 0 && axis.minOffset <= axis.maxOffset);
      if (zoomed[i] <= stageLength[i]) {
        // Shorter than the stage: centred and immovable on this axis.
        CHECK(Near(axis.inset * 2 + zoomed[i], stageLength[i]));
        CHECK(axis.minOffset == axis.maxOffset && Near(axis.minOffset, -axis.inset));
        CHECK(Near(axis.visible, zoomed[i]));
      } else {
        // Longer than the stage: it covers the stage at both ends of the pan.
        CHECK(axis.inset == 0 && axis.minOffset == 0);
        CHECK(Near(axis.maxOffset + stageLength[i], zoomed[i]));
        CHECK(Near(axis.visible, stageLength[i]));
      }
      // The picture's leading edge (at -offset) and trailing edge never come inside the
      // stage once the picture is at least as long as the stage.
      for (int probe = -2; probe <= 2; probe++) {
        CGFloat offset = DBVideoStageClampOffset(axis, probe * 5000.0f);
        CGFloat leading = -offset;
        CGFloat trailing = leading + zoomed[i];
        if (zoomed[i] >= stageLength[i]) {
          CHECK(leading <= 0.5 && trailing >= stageLength[i] - 0.5);
        } else {
          CHECK(Near(leading, (stageLength[i] - zoomed[i]) / 2));
        }
      }
    }
    // The clip rectangle is the stage: zoomed, the picture on screen is never smaller than
    // the fitted 1x rectangle and never larger than the stage.
    CHECK(x.visible >= fit.width - 0.5 && y.visible >= fit.height - 0.5);
    CHECK(x.visible <= stage.width + 0.5 && y.visible <= stage.height + 0.5);
  }
}

int main(void) {
  @autoreleasepool {
    CGSize stages[] = { {650, 700}, {744, 620}, {1000, 500}, {300, 180} };
    CGSize sources[] = { {640, 480}, {1280, 720}, {640, 360} };
    NSInteger rotations[] = { 0, 90, 180, 270, -90, 450 };
    for (size_t s = 0; s < sizeof(stages) / sizeof(stages[0]); s++)
      for (size_t c = 0; c < sizeof(sources) / sizeof(sources[0]); c++)
        for (size_t r = 0; r < sizeof(rotations) / sizeof(rotations[0]); r++)
          CheckSource(stages[s], sources[c], rotations[r]);

    // A quarter turn swaps the picture before fitting: a 16:9 sensor turned 90 degrees is 9:16.
    CGSize turned = DBVideoStageFitSize(CGSizeMake(650, 700), CGSizeMake(1280, 720), 90);
    CHECK(turned.height == 700 && Near(turned.width, 393));
    CGSize level = DBVideoStageFitSize(CGSizeMake(650, 700), CGSizeMake(1280, 720), 180);
    CHECK(level.width == 650 && Near(level.height, 365));

    // A 4:3 picture in a tall stage fills the width at 1x; at 2x it has grown into the bars
    // and shows more than the fitted rectangle did, up to the whole stage.
    CGSize fit = DBVideoStageFitSize(CGSizeMake(650, 700), CGSizeMake(640, 480), 0);
    CHECK(fit.width == 650 && Near(fit.height, 487));
    DBVideoStageAxis grownY = DBVideoStageAxisMake(700, fit.height * 1.25f);
    CHECK(grownY.visible > fit.height && grownY.visible < 700 && grownY.inset > 0);
    DBVideoStageAxis fullY = DBVideoStageAxisMake(700, fit.height * 2);
    CHECK(fullY.visible == 700 && fullY.inset == 0);
    CHECK(fullY.visible * 650 > fit.width * fit.height);

    CHECK(CGSizeEqualToSize(DBVideoStageFitSize(CGSizeZero, CGSizeMake(4, 3), 0), CGSizeZero));
    CHECK(CGSizeEqualToSize(DBVideoStageFitSize(CGSizeMake(10, 10), CGSizeZero, 0), CGSizeZero));
    NSLog(@"video stage: %d checks, %d failures", checks, failures);
  }
  return failures == 0 ? 0 : 1;
}
