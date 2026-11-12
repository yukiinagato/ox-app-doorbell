#import "DBHomeLayout.h"

#include <math.h>
#include <string.h>

DBHomeLayout DBHomeLayoutMake(CGSize size, CGFloat navHeight, CGFloat tabHeight,
                              CGFloat footerHeight, BOOL showsBanner, BOOL showsMissed,
                              BOOL showsPager, BOOL showsSOS) {
  DBHomeLayout layout;
  memset(&layout, 0, sizeof(layout));
  if (size.width <= 0 || size.height <= 0) return layout;
  const CGFloat pad = 20;
  layout.navBar = CGRectMake(0, 0, size.width, navHeight);
  layout.tabBar = CGRectMake(0, size.height - tabHeight, size.width, tabHeight);

  // Phone-sized bounds keep the same structure with a smaller clock.
  BOOL compact = size.width < 600 || size.height < 600;
  CGFloat clockHeight = compact ? 44 : 80;
  CGFloat dateHeight = compact ? 22 : 32;
  CGFloat top = navHeight + 8;
  CGFloat leftWidth = (CGFloat)floor(size.width * 0.55) - pad;
  layout.clock = CGRectMake(pad, top, leftWidth, clockHeight);
  layout.date = CGRectMake(pad, CGRectGetMaxY(layout.clock), leftWidth, dateHeight);
  CGFloat rightX = pad + leftWidth + pad;
  CGFloat rightWidth = MAX(0, size.width - pad - rightX);
  layout.counters = CGRectMake(rightX, top + 8, rightWidth, 34);
  // Secondary controls share one row under the counters: SOS at the trailing edge, the door
  // pager beside it.
  CGFloat rowY = CGRectGetMaxY(layout.counters) + 10;
  CGFloat rowRight = size.width - pad;
  if (showsSOS) {
    CGFloat sosWidth = MIN(rightWidth, 120);
    layout.sos = CGRectMake(rowRight - sosWidth, rowY, sosWidth, 44);
    rowRight = CGRectGetMinX(layout.sos) - 10;
  }
  if (showsPager) {
    CGFloat pagerWidth = MAX(0, MIN(rowRight - rightX, 220));
    layout.pager = CGRectMake(rowRight - pagerWidth, rowY, pagerWidth, 44);
  }
  CGFloat y = MAX(CGRectGetMaxY(layout.date),
                  MAX(CGRectGetMaxY(layout.pager), CGRectGetMaxY(layout.sos))) + 12;

  // The two notices share one row when both are present and the row is wide enough.
  CGFloat noticeWidth = MIN(size.width - 2 * pad, 560);
  if (showsBanner && showsMissed && size.width - 2 * pad >= 2 * 300 + 12) {
    CGFloat half = (CGFloat)floor((size.width - 2 * pad - 12) / 2);
    layout.banner = CGRectMake(pad, y, half, 44);
    layout.missed = CGRectMake(pad + half + 12, y, half, 44);
    y += 44 + 8;
  } else {
    if (showsBanner) {
      layout.banner = CGRectMake((CGFloat)floor((size.width - noticeWidth) / 2), y, noticeWidth,
                                 44);
      y += 44 + 8;
    }
    if (showsMissed) {
      layout.missed = CGRectMake((CGFloat)floor((size.width - noticeWidth) / 2), y, noticeWidth,
                                 44);
      y += 44 + 8;
    }
  }

  layout.footerTop = size.height - tabHeight - footerHeight;
  layout.tiles = CGRectMake(pad, y, size.width - 2 * pad, MAX(0, layout.footerTop - y));
  return layout;
}

static CGSize DBHomeTileSize(CGSize area, NSInteger columns, NSInteger count, CGFloat gap) {
  NSInteger rows = (count + columns - 1) / columns;
  CGFloat cellWidth = (area.width - gap * (columns - 1)) / columns;
  CGFloat cellHeight = (area.height - gap * (rows - 1)) / rows;
  if (cellWidth <= 0 || cellHeight <= 0) return CGSizeZero;
  CGFloat width = MIN(cellWidth, cellHeight * 16.0f / 9.0f);
  return CGSizeMake((CGFloat)floor(width), (CGFloat)floor(width * 9.0f / 16.0f));
}

CGRect DBHomeLayoutTileFrame(DBHomeLayout layout, NSInteger index, NSInteger count) {
  if (count <= 0 || index < 0 || index >= count) return CGRectZero;
  const CGFloat gap = 12;
  CGRect area = layout.tiles;
  NSInteger columns = 1;
  CGSize best = CGSizeZero;
  for (NSInteger candidate = 1; candidate <= count; candidate++) {
    CGSize tile = DBHomeTileSize(area.size, candidate, count, gap);
    if (tile.width > best.width) {
      best = tile;
      columns = candidate;
    }
  }
  if (best.width <= 0 || best.height <= 0) return CGRectZero;
  NSInteger rows = (count + columns - 1) / columns;
  // The grid as a whole is centred in the area; a short last row starts at the left.
  CGFloat gridWidth = best.width * columns + gap * (columns - 1);
  CGFloat gridHeight = best.height * rows + gap * (rows - 1);
  CGFloat originX = area.origin.x + (CGFloat)floor((area.size.width - gridWidth) / 2);
  CGFloat originY = area.origin.y + (CGFloat)floor((area.size.height - gridHeight) / 2);
  return CGRectMake(originX + (index % columns) * (best.width + gap),
                    originY + (index / columns) * (best.height + gap), best.width, best.height);
}
