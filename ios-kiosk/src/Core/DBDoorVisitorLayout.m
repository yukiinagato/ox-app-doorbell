#import <Foundation/Foundation.h>
#import "DBDoorVisitorLayout.h"
#import <math.h>
#import <string.h>

static DBDoorVisitorLayout DBDoorVisitorLayoutLegacy(CGSize size, BOOL showsSOS,
                                                     CGFloat actionScale, BOOL showsLanguage,
                                                     BOOL showsNotice, BOOL showsAir) {
  DBDoorVisitorLayout layout;
  memset(&layout, 0, sizeof(layout));
  BOOL shortScreen = size.height < 500;
  BOOL compact = size.width < 500 || shortScreen;
  BOOL sideBySide = size.width > size.height;
  CGFloat margin = compact ? 12 : 28;
  CGFloat gap = compact ? 8 : 12;
  CGFloat width = MAX(0, size.width - margin * 2);
  CGFloat scale = isfinite(actionScale) ? MAX(1, MIN(2, actionScale)) : 1;
  // A portrait phone has the least height to share, so its action is capped lower.
  CGFloat heightShare = (compact && !sideBySide) ? 0.2 : 0.28;
  CGFloat actionHeight = MIN((compact ? 76 : 96) * scale, size.height * heightShare);
  layout.size = size;
  layout.showsSOS = showsSOS;
  layout.showsAir = showsAir;
  layout.actionScale = actionScale;
  layout.margin = margin;
  layout.gap = gap;
  layout.compact = compact;
  layout.sideBySide = sideBySide;
  layout.topBar = CGRectMake(0, 0, size.width, 44);

  CGFloat bottom = size.height - margin;
  layout.version = CGRectMake(margin, bottom - 18, width, 18);
  bottom = CGRectGetMinY(layout.version) - gap;

  CGFloat columnWidth = sideBySide ? floor(MAX(160, MIN(420, size.width * 0.38))) : width;
  CGFloat columnX = sideBySide ? size.width - margin - columnWidth : margin;
  if (showsSOS) {
    // A compact secondary control at the leading edge of the action zone.
    CGFloat sosWidth = MIN(132, columnWidth);
    layout.sos = CGRectMake(columnX, bottom - 48, sosWidth, 48);
    bottom = CGRectGetMinY(layout.sos) - gap;
  }
  CGFloat actionWidth = MIN(560, columnWidth);
  layout.action = CGRectMake(columnX + (columnWidth - actionWidth) / 2, bottom - actionHeight,
                             actionWidth, actionHeight);
  CGFloat statusHeight = shortScreen ? 44 : 60;
  layout.status = CGRectMake(columnX, CGRectGetMinY(layout.action) - gap - statusHeight,
                             columnWidth, statusHeight);

  CGFloat top = CGRectGetMaxY(layout.topBar) + gap;
  CGFloat contentWidth = sideBySide ? MAX(0, columnX - margin * 2) : width;
  CGFloat contentBottom = sideBySide ? CGRectGetMinY(layout.version) - gap
                                     : CGRectGetMinY(layout.status) - gap;
  layout.content = CGRectMake(margin, top, contentWidth, MAX(44, contentBottom - top));

  CGFloat y = top;
  if (showsLanguage) {
    layout.language = CGRectMake(margin, y, contentWidth, 44);
    y += 44 + gap;
  }
  CGFloat headlineTop = y;
  CGFloat noticeHeight = compact ? 52 : 64;
  CGFloat clockHeight = compact ? 44 : 80;
  CGFloat dateHeight = compact ? 20 : 30;
  layout.purposeRowHeight = compact ? 72 : 88;
  CGFloat purposesMinimum = compact ? 44 : layout.purposeRowHeight * 2 + gap;
  CGFloat airHeight = compact ? 24 : 32;
  CGFloat reserved = showsNotice ? noticeHeight + gap : 0;
  CGFloat headerHeight = clockHeight + dateHeight + gap;
  if (contentBottom - y - reserved - headerHeight >= purposesMinimum) {
    BOOL air = showsAir &&
        contentBottom - y - reserved - headerHeight - airHeight >= purposesMinimum;
    layout.clock = CGRectMake(margin, y, contentWidth, clockHeight);
    y += clockHeight;
    layout.date = CGRectMake(margin, y, contentWidth, dateHeight);
    y += dateHeight;
    if (air) {
      layout.air = CGRectMake(margin, y, contentWidth, airHeight);
      y += airHeight;
    }
    y += gap;
  }
  if (showsNotice) {
    layout.notice = CGRectMake(margin, y, contentWidth, noticeHeight);
    y += noticeHeight + gap;
  }
  layout.purposes = CGRectMake(margin, y, contentWidth, MAX(44, contentBottom - y));
  if (y > headlineTop) {
    layout.headline = CGRectMake(margin, headlineTop, contentWidth, y - gap - headlineTop);
  } else {
    layout.headline = CGRectMake(margin, y, contentWidth,
                                 MIN(layout.purposes.size.height, compact ? 88 : 110));
  }
  layout.purposeColumns = contentWidth < 420 ? 2 : (contentWidth < 760 ? 3 : 4);
  return layout;
}

// Phones in landscape have no height for a centred column, so they keep the two-column split
// above. Every other screen uses this single column: a top row (time at the leading edge,
// language at the trailing edge), the notice, then the hero (hint over the call button) with the
// purposes grid under it, and SOS alone in the bottom zone.
static DBDoorVisitorLayout DBDoorVisitorLayoutBuild(CGSize size, BOOL showsSOS,
                                                    CGFloat actionScale, BOOL showsLanguage,
                                                    BOOL showsNotice, BOOL showsAir,
                                                    NSInteger purposeCount) {
  if (size.height < 500)
    return DBDoorVisitorLayoutLegacy(size, showsSOS, actionScale, showsLanguage, showsNotice,
                                     showsAir);
  DBDoorVisitorLayout layout;
  memset(&layout, 0, sizeof(layout));
  BOOL compact = size.width < 500;
  CGFloat margin = compact ? 16 : 32;
  CGFloat gap = compact ? 8 : 12;
  CGFloat section = compact ? 12 : 24;
  CGFloat scale = isfinite(actionScale) ? MAX(1, MIN(2, actionScale)) : 1;
  CGFloat columnWidth = MAX(0, MIN(640, size.width - margin * 2));
  CGFloat columnX = floor((size.width - columnWidth) / 2);
  layout.size = size;
  layout.showsSOS = showsSOS;
  layout.showsAir = showsAir;
  layout.actionScale = actionScale;
  layout.margin = margin;
  layout.gap = gap;
  layout.compact = compact;
  layout.sideBySide = size.width > size.height;
  layout.purposeCount = purposeCount;
  // The stock navigation bar is not used here: the door name is the page title in the top row.
  layout.topBar = CGRectZero;

  CGFloat y = compact ? 20 : 28;
  CGFloat languageWidth = showsLanguage
      ? floor(compact ? columnWidth * 0.55 : MIN(264, columnWidth * 0.42)) : 0;
  if (showsLanguage)
    layout.language = CGRectMake(columnX + columnWidth - languageWidth, y, languageWidth, 44);
  // The time sits small beside the language control; phones have no room for it.
  CGFloat timeWidth = compact ? 0 : 120;
  CGFloat trailing = columnX + columnWidth - (showsLanguage ? languageWidth + gap : 0);
  if (timeWidth > 0) {
    layout.clock = CGRectMake(trailing - timeWidth, y, timeWidth, 26);
    layout.date = CGRectMake(trailing - timeWidth, y + 26, timeWidth, 18);
  }
  CGFloat titleRight = timeWidth > 0 ? CGRectGetMinX(layout.clock) - gap
      : (showsLanguage ? CGRectGetMinX(layout.language) - gap : columnX + columnWidth);
  layout.title = CGRectMake(columnX, y, MAX(0, titleRight - columnX), 44);
  y += 44;
  if (showsAir && layout.clock.size.width > 0) {
    CGFloat airHeight = compact ? 20 : 24;
    layout.air = CGRectMake(columnX, y + 4, columnWidth, airHeight);
    y += 4 + airHeight;
  }
  y += gap;
  CGFloat stageTop = y;
  if (showsNotice) {
    CGFloat noticeHeight = compact ? 52 : 64;
    layout.notice = CGRectMake(columnX, y, columnWidth, noticeHeight);
    y += noticeHeight + gap;
  }
  // One quiet caption line sits at the very bottom, inside the bottom margin.
  layout.version = CGRectMake(columnX, size.height - 12 - 16, columnWidth, 16);
  CGFloat bottom = CGRectGetMinY(layout.version) - 8;
  if (showsSOS) {
    layout.sos = CGRectMake(columnX, bottom - 48, MIN(132, columnWidth), 48);
    bottom = CGRectGetMinY(layout.sos) - gap;
  }

  CGFloat hintHeight = compact ? 44 : 48;
  CGFloat actionHeight = floor(MIN((compact ? 72 : 96) * scale, size.height * 0.22));
  CGFloat actionWidth = compact ? columnWidth : MIN(columnWidth, 440);
  CGFloat heroHeight = hintHeight + gap + actionHeight;
  layout.purposeColumns = columnWidth < 420 ? 2 : (columnWidth < 560 ? 3 : 4);
  layout.purposeRowHeight = compact ? 72 : 88;
  NSInteger rows = purposeCount > 0
      ? (purposeCount + layout.purposeColumns - 1) / layout.purposeColumns : 0;
  CGFloat gridHeight = rows > 0 ? rows * layout.purposeRowHeight + (rows - 1) * gap : 0;
  CGFloat zone = MAX(0, bottom - y);
  CGFloat need = heroHeight + (rows > 0 ? section + gridHeight : 0);
  CGFloat top = y;
  CGFloat purposesHeight = gridHeight;
  if (need <= zone) {
    top = y + floor((zone - need) / 2);
  } else if (rows > 0) {
    purposesHeight = MAX(44, zone - heroHeight - section);
  }
  layout.status = CGRectMake(columnX, top, columnWidth, hintHeight);
  layout.action = CGRectMake(columnX + floor((columnWidth - actionWidth) / 2),
                             top + hintHeight + gap, actionWidth, actionHeight);
  layout.purposes = rows > 0
      ? CGRectMake(columnX, CGRectGetMaxY(layout.action) + section, columnWidth, purposesHeight)
      : CGRectMake(columnX, CGRectGetMaxY(layout.action), columnWidth, 0);
  // The stage is everything between the top row and the action: the expanded announcement, the
  // reply text and the call-status plate use it, and none of them can reach a purpose.
  layout.content = CGRectMake(columnX, stageTop, columnWidth,
                              MAX(44, CGRectGetMinY(layout.action) - gap - stageTop));
  layout.headline = layout.content;
  return layout;
}

DBDoorVisitorLayout DBDoorVisitorLayoutMake(CGSize size, BOOL showsSOS, CGFloat actionScale) {
  return DBDoorVisitorLayoutBuild(size, showsSOS, actionScale, YES, YES, NO, 6);
}

DBDoorVisitorLayout DBDoorVisitorLayoutFit(DBDoorVisitorLayout layout, BOOL showsLanguage,
                                           BOOL showsNotice) {
  return DBDoorVisitorLayoutBuild(layout.size, layout.showsSOS, layout.actionScale,
                                  showsLanguage, showsNotice, NO, layout.purposeCount);
}

DBDoorVisitorLayout DBDoorVisitorLayoutFitWithAir(DBDoorVisitorLayout layout, BOOL showsLanguage,
                                                  BOOL showsNotice, BOOL showsAir) {
  return DBDoorVisitorLayoutBuild(layout.size, layout.showsSOS, layout.actionScale,
                                  showsLanguage, showsNotice, showsAir, layout.purposeCount);
}

DBDoorVisitorLayout DBDoorVisitorLayoutFitContent(DBDoorVisitorLayout layout, BOOL showsLanguage,
                                                 BOOL showsNotice, BOOL showsAir,
                                                 NSInteger purposeCount) {
  return DBDoorVisitorLayoutBuild(layout.size, layout.showsSOS, layout.actionScale,
                                  showsLanguage, showsNotice, showsAir, purposeCount);
}

static CGFloat DBDoorVisitorPurposeRow(DBDoorVisitorLayout layout, CGFloat rowHeight) {
  return isfinite(rowHeight) ? MAX(layout.purposeRowHeight, rowHeight) : layout.purposeRowHeight;
}

CGRect DBDoorVisitorPurposeFrame(DBDoorVisitorLayout layout, NSInteger index, CGFloat rowHeight) {
  NSInteger columns = MAX(1, layout.purposeColumns);
  if (index < 0) return CGRectZero;
  CGFloat height = DBDoorVisitorPurposeRow(layout, rowHeight);
  CGFloat width = floor((layout.purposes.size.width - layout.gap * (columns - 1)) / columns);
  // A short last row is centred under the full ones, as equal cards in one centred grid.
  CGFloat shift = 0;
  if (layout.purposeCount > 0 && index < layout.purposeCount) {
    NSInteger inRow = MIN(columns, layout.purposeCount - (index / columns) * columns);
    shift = floor((columns - inRow) * (width + layout.gap) / 2);
  }
  return CGRectMake(shift + (index % columns) * (width + layout.gap),
                    (index / columns) * (height + layout.gap), MAX(0, width), height);
}

CGFloat DBDoorVisitorPurposeGridHeight(DBDoorVisitorLayout layout, NSInteger count,
                                       CGFloat rowHeight) {
  if (count <= 0) return 0;
  NSInteger columns = MAX(1, layout.purposeColumns);
  NSInteger rows = (count + columns - 1) / columns;
  return rows * DBDoorVisitorPurposeRow(layout, rowHeight) + (rows - 1) * layout.gap;
}

DBDoorVisitorFlowLayout DBDoorVisitorFlowLayoutMake(DBDoorVisitorLayout layout,
                                                    CGFloat headerHeight, BOOL hasPrimary,
                                                    NSInteger secondaryCount,
                                                    CGFloat labelRowHeight, BOOL showsBack) {
  DBDoorVisitorFlowLayout flow;
  memset(&flow, 0, sizeof(flow));
  BOOL column = layout.title.size.width > 0 || layout.title.size.height > 0;
  CGFloat gap = layout.gap;
  CGFloat colX = layout.status.origin.x;
  CGFloat colW = layout.status.size.width;
  flow.columnX = colX;
  flow.columnWidth = colW;
  flow.gap = gap;
  CGFloat top;
  if (column) {
    top = layout.notice.size.height > 0 ? CGRectGetMaxY(layout.notice) + gap
                                        : layout.content.origin.y;
  } else {
    top = CGRectGetMaxY(layout.topBar) + gap;
  }
  if (headerHeight > 0) top += headerHeight + gap;
  CGFloat bottom = CGRectGetMinY(layout.version) - (column ? 8 : gap);
  BOOL sos = layout.sos.size.height > 0;
  if (sos) bottom = CGRectGetMinY(layout.sos) - gap;
  if (showsBack) {
    CGFloat width = MIN(132, colW);
    if (sos) {
      flow.back = CGRectMake(colX + colW - width, layout.sos.origin.y, width, layout.sos.size.height);
    } else {
      flow.back = CGRectMake(colX + colW - width, bottom - 48, width, 48);
      bottom = CGRectGetMinY(flow.back) - gap;
    }
  }
  CGFloat zoneHeight = MAX(0, bottom - top);
  flow.zone = CGRectMake(colX, top, colW, zoneHeight);

  // Equal cards: two columns on a phone, three on a tablet, as the purpose grid.
  flow.columns = layout.compact ? 2 : 3;
  // A lone card or a pair does not stretch into a wider row than the primary button.
  if (secondaryCount > 0) flow.columns = MIN(flow.columns, secondaryCount);
  flow.rowHeight = MAX(MAX(72, layout.purposeRowHeight),
                       isfinite(labelRowHeight) ? labelRowHeight : 0);
  flow.primaryHeight = hasPrimary ? layout.action.size.height : 0;
  CGFloat height = flow.primaryHeight;
  if (secondaryCount > 0) {
    NSInteger rows = (secondaryCount + flow.columns - 1) / flow.columns;
    height += (hasPrimary ? gap : 0) + rows * flow.rowHeight + (rows - 1) * gap;
  }
  flow.optionsContentHeight = height;
  CGFloat viewport = MIN(height, MIN(floor(layout.size.height * 0.5), MAX(0, zoneHeight - 44)));
  flow.options = CGRectMake(colX, bottom - viewport, colW, viewport);
  flow.content = CGRectMake(colX, top, colW, MAX(0, CGRectGetMinY(flow.options) - gap - top));
  return flow;
}

CGRect DBDoorVisitorFlowPrimaryFrame(DBDoorVisitorFlowLayout flow) {
  CGFloat width = MIN(flow.columnWidth, 440);
  return CGRectMake(floor((flow.columnWidth - width) / 2), 0, width, flow.primaryHeight);
}

CGRect DBDoorVisitorFlowOptionFrame(DBDoorVisitorFlowLayout flow, BOOL hasPrimary,
                                    NSInteger index, NSInteger secondaryCount) {
  if (index < 0 || index >= secondaryCount) return CGRectZero;
  NSInteger columns = MAX(1, flow.columns);
  CGFloat width = floor((flow.columnWidth - flow.gap * (columns - 1)) / columns);
  if (columns == 1) width = MIN(width, 440);
  NSInteger inRow = MIN(columns, secondaryCount - (index / columns) * columns);
  CGFloat shift = floor((columns - inRow) * (width + flow.gap) / 2);
  if (columns == 1) shift = floor((flow.columnWidth - width) / 2);
  CGFloat y = (hasPrimary ? flow.primaryHeight + flow.gap : 0) +
      (index / columns) * (flow.rowHeight + flow.gap);
  return CGRectMake(shift + (index % columns) * (width + flow.gap), y, MAX(0, width),
                    flow.rowHeight);
}

CGFloat DBDoorVisitorFlowImageHeight(CGSize image, CGFloat width, CGFloat viewportHeight) {
  if (image.width <= 0 || image.height <= 0 || width <= 0) return 0;
  return floor(MIN(width * image.height / image.width, viewportHeight * 0.4));
}

void DBDoorVisitorFlowComposeBlock(DBDoorVisitorFlowLayout flow, CGFloat cardHeight, CGRect *card,
                                   CGRect *options) {
  CGFloat cardH = MAX(0, cardHeight);
  CGFloat optionsH = flow.options.size.height;
  CGFloat block = cardH + (cardH > 0 ? flow.gap : 0) + optionsH;
  if (block > flow.zone.size.height) {
    // Too tall to centre: the options keep the bottom and the card takes what is left above.
    cardH = MIN(cardH, flow.content.size.height);
    if (card) *card = CGRectMake(flow.content.origin.x, flow.content.origin.y +
                                 floor((flow.content.size.height - cardH) / 2),
                                 flow.content.size.width, cardH);
    if (options) *options = flow.options;
    return;
  }
  CGFloat top = flow.zone.origin.y + floor((flow.zone.size.height - block) / 2);
  if (card) *card = CGRectMake(flow.zone.origin.x, top, flow.zone.size.width, cardH);
  if (options) *options = CGRectMake(flow.options.origin.x, top + cardH + (cardH > 0 ? flow.gap : 0),
                                     flow.options.size.width, optionsH);
}
