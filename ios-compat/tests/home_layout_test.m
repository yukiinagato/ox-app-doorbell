#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <string.h>

#import "DBHomeLayout.h"
#import "DBUiTheme.h"

static int failures = 0;
static int checks = 0;

static void Check(BOOL condition, NSString *what) {
  checks++;
  if (!condition) {
    failures++;
    NSLog(@"FAIL: %@", what);
  }
}

static CGRect RectFromArray(NSArray *rect) {
  return CGRectMake((CGFloat)[rect[0] doubleValue], (CGFloat)[rect[1] doubleValue],
                    (CGFloat)[rect[2] doubleValue], (CGFloat)[rect[3] doubleValue]);
}

static BOOL Overlaps(CGRect a, CGRect b) {
  if (CGRectIsEmpty(a) || CGRectIsEmpty(b)) return NO;
  CGRect both = CGRectIntersection(a, b);
  return !CGRectIsNull(both) && both.size.width > 0.5 && both.size.height > 0.5;
}

static void CheckSize(CGSize size, BOOL banner, BOOL missed, BOOL pager, BOOL sos,
                      NSInteger tiles, BOOL air) {
  const CGFloat nav = 44, tab = 49;
  BOOL portrait = size.height > size.width;
  NSDictionary *footer = [DBUiTheme footerLayoutForViewWidth:size.width
                                                  viewHeight:size.height - tab
                                                    portrait:portrait
                                                  sosVisible:NO];
  CGFloat footerHeight = (CGFloat)[footer[@"height"] doubleValue];
  DBHomeLayout plain = DBHomeLayoutMake(size, nav, tab, footerHeight, banner, missed, pager, sos);
  DBHomeLayout layout = DBHomeLayoutPlaceAir(plain, air ? 30 : 0);
  NSString *tag = [NSString stringWithFormat:@"%.0fx%.0f banner=%d missed=%d pager=%d sos=%d tiles=%ld air=%d",
      size.width, size.height, banner, missed, pager, sos, (long)tiles, air];
  if (!air) Check(memcmp(&plain, &layout, sizeof(layout)) == 0,
                  [tag stringByAppendingString:@": no air leaves the layout alone"]);
  // Every iPad orientation has room for the PM2.5 line directly under the date.
  if (air) Check(!CGRectIsEmpty(layout.air) &&
                 CGRectGetMinY(layout.air) >= CGRectGetMaxY(layout.date) &&
                 CGRectGetMinX(layout.air) == CGRectGetMinX(layout.date),
                 [tag stringByAppendingString:@": air row"]);
  CGRect bounds = CGRectMake(0, 0, size.width, size.height);

  NSMutableArray *names = [NSMutableArray array];
  NSMutableArray *rects = [NSMutableArray array];
  void (^add)(NSString *, CGRect) = ^(NSString *name, CGRect rect) {
    [names addObject:name];
    [rects addObject:[NSValue valueWithBytes:&rect objCType:@encode(CGRect)]];
  };
  add(@"navBar", layout.navBar);
  add(@"tabBar", layout.tabBar);
  add(@"clock", layout.clock);
  add(@"date", layout.date);
  add(@"air", layout.air);
  add(@"counters", layout.counters);
  add(@"banner", layout.banner);
  add(@"missed", layout.missed);
  add(@"pager", layout.pager);
  for (NSInteger i = 0; i < tiles; i++)
    add([NSString stringWithFormat:@"tile%ld", (long)i], DBHomeLayoutTileFrame(layout, i, tiles));
  CGRect block = CGRectUnion(RectFromArray(footer[@"qr"]), RectFromArray(footer[@"version"]));
  CGRect plate = DBHomeLayoutFooterPlate(size, tab, block.size.height);
  add(@"plate", plate);
  // The plate keeps the 20 pt margin of the tiles and 12 pt of air above it.
  Check(CGRectGetMinX(plate) == 20 && CGRectGetMaxX(plate) == size.width - 20 &&
        CGRectGetMaxY(plate) == size.height - tab - 20 &&
        CGRectGetMinY(plate) - layout.footerTop >= 12,
        [tag stringByAppendingString:@": plate margins"]);
  Check(CGRectGetMinX(layout.tiles) == 20 && CGRectGetMaxX(layout.tiles) == size.width - 20,
        [tag stringByAppendingString:@": tile margins"]);
  Check(CGRectGetMinX(layout.clock) == 20 && CGRectGetMaxX(layout.counters) == size.width - 20,
        [tag stringByAppendingString:@": header margins"]);
  add(@"sos", layout.sos);

  for (NSUInteger i = 0; i < [rects count]; i++) {
    CGRect a;
    [rects[i] getValue:&a];
    if (CGRectIsEmpty(a)) continue;
    Check(CGRectContainsRect(bounds, a),
          [NSString stringWithFormat:@"%@: %@ leaves the bounds", tag, names[i]]);
    for (NSUInteger j = i + 1; j < [rects count]; j++) {
      CGRect b;
      [rects[j] getValue:&b];
      Check(!Overlaps(a, b), [NSString stringWithFormat:@"%@: %@ overlaps %@", tag, names[i],
                                                        names[j]]);
    }
  }
  Check(CGRectIsEmpty(layout.banner) == !banner, [tag stringByAppendingString:@": banner"]);
  // SOS is a compact secondary control in the header, never a footer-wide bar.
  Check(sos == !CGRectIsEmpty(layout.sos), [tag stringByAppendingString:@": sos"]);
  Check(CGRectIsEmpty(RectFromArray(footer[@"sos"])), [tag stringByAppendingString:@": bar"]);
  if (sos) Check(layout.sos.size.height >= 44 && layout.sos.size.width >= 88 &&
                 layout.sos.size.width <= 160, [tag stringByAppendingString:@": sos size"]);
  // The header never touches the tiles.
  CGFloat headerBottom = MAX(MAX(CGRectGetMaxY(layout.date), CGRectGetMaxY(layout.air)),
                             MAX(CGRectGetMaxY(layout.pager), CGRectGetMaxY(layout.sos)));
  Check(CGRectGetMinY(layout.tiles) - headerBottom >= 12,
        [tag stringByAppendingString:@": header gap"]);
  Check(CGRectIsEmpty(layout.missed) == !missed, [tag stringByAppendingString:@": missed"]);
  Check(CGRectIsEmpty(layout.pager) == !pager, [tag stringByAppendingString:@": pager"]);
  if (missed) Check(layout.missed.size.height >= 44, [tag stringByAppendingString:@": missed"]);
  if (pager) Check(layout.pager.size.height >= 44, [tag stringByAppendingString:@": pager"]);
  // The tiles own the content area: each is a 16:9 picture and a generous touch target.
  for (NSInteger i = 0; i < tiles; i++) {
    CGRect tile = DBHomeLayoutTileFrame(layout, i, tiles);
    Check(tile.size.height >= 120 && tile.size.width >= 213 &&
          fabs(tile.size.width * 9.0 / 16.0 - tile.size.height) <= 1.0,
          [NSString stringWithFormat:@"%@: tile %ld too small", tag, (long)i]);
    Check(CGRectContainsRect(layout.tiles, tile),
          [NSString stringWithFormat:@"%@: tile %ld leaves the grid", tag, (long)i]);
  }
}

int main(void) {
  @autoreleasepool {
    CGSize sizes[] = { {1024, 768}, {768, 1024} };
    for (size_t s = 0; s < sizeof(sizes) / sizeof(sizes[0]); s++)
      for (int flags = 0; flags < 16; flags++)
        for (NSInteger tiles = 0; tiles <= 3; tiles++)
          for (int air = 0; air <= 1; air++)
            CheckSize(sizes[s], flags & 1, (flags >> 1) & 1, (flags >> 2) & 1, (flags >> 3) & 1,
                      tiles, air);
    // A single door gets most of the content area, not a thumbnail.
    DBHomeLayout wide = DBHomeLayoutMake(CGSizeMake(1024, 768), 44, 49, 104, NO, NO, NO, YES);
    Check(DBHomeLayoutTileFrame(wide, 0, 1).size.width >= 600, @"one landscape tile is large");
    // Degenerate bounds must not produce NaN or negative sizes.
    DBHomeLayout empty = DBHomeLayoutMake(CGSizeZero, 44, 49, 0, YES, YES, YES, YES);
    Check(CGRectIsEmpty(empty.tiles), @"zero size");
    DBHomeLayout phone = DBHomeLayoutMake(CGSizeMake(320, 480), 44, 49, 178, YES, YES, YES, YES);
    Check(phone.tiles.size.height >= 0, @"phone size");
    NSLog(@"home layout: %d checks, %d failures", checks, failures);
  }
  return failures == 0 ? 0 : 1;
}
