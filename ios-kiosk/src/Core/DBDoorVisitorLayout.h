#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Every frame of the visitor screen, in screen coordinates.
//
// A landscape screen puts the action zone in a column at the right edge and a portrait screen
// puts it in a band at the bottom; the content zone takes the rest. An absent element has a
// zero rectangle.
typedef struct {
  CGRect topBar;
  // The zone between the navigation bar and the action zone. The call-status plate is placed
  // in it; language, clock, date, notice, and purposes are stacked inside it.
  CGRect content;
  CGRect language;
  // Zero when a phone-sized screen has no room left after the language and notice rows.
  CGRect clock;
  CGRect date;
  // The collapsed announcement card.
  CGRect notice;
  // The expanded announcement and the reply text. It deliberately covers clock, date, and
  // notice, and never a purpose or an action.
  CGRect headline;
  // The viewport of the purpose grid, which scrolls when the grid is taller.
  CGRect purposes;
  CGRect status;
  CGRect action;
  CGRect sos;
  CGRect version;
  CGFloat margin;
  CGFloat gap;
  NSInteger purposeColumns;
  // The shortest purpose target this screen class allows.
  CGFloat purposeRowHeight;
  BOOL compact;
  BOOL sideBySide;
  // The inputs, kept so DBDoorVisitorLayoutFit can lay the same screen out again.
  CGSize size;
  BOOL showsSOS;
  CGFloat actionScale;
} DBDoorVisitorLayout;

// The screen with a language control and an announcement, which is the tightest case. Calling
// and connected views share the same action rectangle, and nothing configured can push it
// offscreen.
DBDoorVisitorLayout DBDoorVisitorLayoutMake(CGSize size, BOOL showsSOS, CGFloat actionScale);

// The same screen without the rows it does not show; the purposes take the space.
DBDoorVisitorLayout DBDoorVisitorLayoutFit(DBDoorVisitorLayout layout, BOOL showsLanguage,
                                           BOOL showsNotice);

// One purpose target, in the coordinates of the grid's scrolling content. rowHeight is the
// height the longest label needs; the screen class minimum still applies.
CGRect DBDoorVisitorPurposeFrame(DBDoorVisitorLayout layout, NSInteger index, CGFloat rowHeight);
CGFloat DBDoorVisitorPurposeGridHeight(DBDoorVisitorLayout layout, NSInteger count,
                                       CGFloat rowHeight);
