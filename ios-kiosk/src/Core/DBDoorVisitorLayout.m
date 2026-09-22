#import <Foundation/Foundation.h>
#import "DBDoorVisitorLayout.h"
#import <math.h>

DBDoorVisitorLayout DBDoorVisitorLayoutMake(CGSize size, BOOL showsSOS, CGFloat actionScale) {
  DBDoorVisitorLayout layout = {0};
  BOOL shortScreen = size.height < 500;
  BOOL compact = size.width < 500 || shortScreen;
  CGFloat margin = compact ? 12 : 28;
  CGFloat gap = compact ? 8 : 12;
  CGFloat width = MAX(0, size.width - margin * 2);
  CGFloat scale = isfinite(actionScale) ? MAX(1, MIN(2, actionScale)) : 1;
  CGFloat actionHeight = MIN((compact ? 76 : 96) * scale, size.height * 0.28);
  CGFloat versionHeight = 18;
  CGFloat bottom = size.height - margin;
  layout.margin = margin;
  layout.version = CGRectMake(margin, bottom - versionHeight, width, versionHeight);
  bottom = CGRectGetMinY(layout.version) - gap;
  if (showsSOS) {
    CGFloat sosWidth = MIN(380, width);
    layout.sos = CGRectMake((size.width - sosWidth) / 2, bottom - 56, sosWidth, 56);
    bottom = CGRectGetMinY(layout.sos) - gap;
  }
  CGFloat actionWidth = MIN(560, width);
  layout.action = CGRectMake((size.width - actionWidth) / 2, bottom - actionHeight,
                             actionWidth, actionHeight);
  CGFloat statusHeight = shortScreen ? 44 : 60;
  layout.status = CGRectMake(margin, CGRectGetMinY(layout.action) - gap - statusHeight,
                             width, statusHeight);
  layout.content = CGRectMake(0, margin, size.width,
      MAX(44, CGRectGetMinY(layout.status) - margin - gap));
  return layout;
}
