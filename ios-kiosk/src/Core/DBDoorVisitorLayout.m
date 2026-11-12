#import <Foundation/Foundation.h>
#import "DBDoorVisitorLayout.h"
#import <math.h>
#import <string.h>

static DBDoorVisitorLayout DBDoorVisitorLayoutBuild(CGSize size, BOOL showsSOS,
                                                    CGFloat actionScale, BOOL showsLanguage,
                                                    BOOL showsNotice) {
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
    CGFloat sosWidth = MIN(380, columnWidth);
    layout.sos = CGRectMake(columnX + (columnWidth - sosWidth) / 2, bottom - 56, sosWidth, 56);
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
  CGFloat reserved = showsNotice ? noticeHeight + gap : 0;
  if (contentBottom - y - reserved - (clockHeight + dateHeight + gap) >= purposesMinimum) {
    layout.clock = CGRectMake(margin, y, contentWidth, clockHeight);
    y += clockHeight;
    layout.date = CGRectMake(margin, y, contentWidth, dateHeight);
    y += dateHeight + gap;
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

DBDoorVisitorLayout DBDoorVisitorLayoutMake(CGSize size, BOOL showsSOS, CGFloat actionScale) {
  return DBDoorVisitorLayoutBuild(size, showsSOS, actionScale, YES, YES);
}

DBDoorVisitorLayout DBDoorVisitorLayoutFit(DBDoorVisitorLayout layout, BOOL showsLanguage,
                                           BOOL showsNotice) {
  return DBDoorVisitorLayoutBuild(layout.size, layout.showsSOS, layout.actionScale,
                                  showsLanguage, showsNotice);
}

static CGFloat DBDoorVisitorPurposeRow(DBDoorVisitorLayout layout, CGFloat rowHeight) {
  return isfinite(rowHeight) ? MAX(layout.purposeRowHeight, rowHeight) : layout.purposeRowHeight;
}

CGRect DBDoorVisitorPurposeFrame(DBDoorVisitorLayout layout, NSInteger index, CGFloat rowHeight) {
  NSInteger columns = MAX(1, layout.purposeColumns);
  if (index < 0) return CGRectZero;
  CGFloat height = DBDoorVisitorPurposeRow(layout, rowHeight);
  CGFloat width = floor((layout.purposes.size.width - layout.gap * (columns - 1)) / columns);
  return CGRectMake((index % columns) * (width + layout.gap),
                    (index / columns) * (height + layout.gap), MAX(0, width), height);
}

CGFloat DBDoorVisitorPurposeGridHeight(DBDoorVisitorLayout layout, NSInteger count,
                                       CGFloat rowHeight) {
  if (count <= 0) return 0;
  NSInteger columns = MAX(1, layout.purposeColumns);
  NSInteger rows = (count + columns - 1) / columns;
  return rows * DBDoorVisitorPurposeRow(layout, rowHeight) + (rows - 1) * layout.gap;
}
