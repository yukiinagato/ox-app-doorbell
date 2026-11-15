#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Every frame of the visitor screen, in screen coordinates. An absent element has a zero
// rectangle.
//
// Screens at least 500 pt tall use one centred column (at most 640 pt): the top row holds the
// time at the leading edge and the language control at the trailing edge, a full-width notice
// follows, then the hero (hint over the call button, which keeps its rectangle in every call
// state) and the purpose grid, with SOS alone at the leading edge of the bottom zone. The version
// and diagnostics line is one centred caption at the very bottom. Shorter phone landscapes keep a two-column split with the action zone in a
// column at the right edge.
typedef struct {
  CGRect topBar;
  // The zone between the navigation bar and the action zone. The call-status plate is placed
  // in it; language, clock, date, notice, and purposes are stacked inside it.
  CGRect content;
  CGRect language;
  // Zero when a phone-sized screen has no room left after the language and notice rows.
  CGRect clock;
  CGRect date;
  // The PM2.5 line under the date; zero unless requested and the clock row fits with it.
  CGRect air;
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
  BOOL showsAir;
  CGFloat actionScale;
  NSInteger purposeCount;
} DBDoorVisitorLayout;

// The screen with a language control and an announcement, which is the tightest case. Calling
// and connected views share the same action rectangle, and nothing configured can push it
// offscreen.
DBDoorVisitorLayout DBDoorVisitorLayoutMake(CGSize size, BOOL showsSOS, CGFloat actionScale);

// The same screen without the rows it does not show; the purposes take the space.
DBDoorVisitorLayout DBDoorVisitorLayoutFit(DBDoorVisitorLayout layout, BOOL showsLanguage,
                                           BOOL showsNotice);

// The same, with the PM2.5 line under the date. The expanded announcement and the reply cover it.
DBDoorVisitorLayout DBDoorVisitorLayoutFitWithAir(DBDoorVisitorLayout layout, BOOL showsLanguage,
                                                  BOOL showsNotice, BOOL showsAir);

// The same, for the number of purpose cards that are on screen. Zero centres the call button.
DBDoorVisitorLayout DBDoorVisitorLayoutFitContent(DBDoorVisitorLayout layout, BOOL showsLanguage,
                                                  BOOL showsNotice, BOOL showsAir,
                                                  NSInteger purposeCount);

// One purpose target, in the coordinates of the grid's scrolling content. rowHeight is the
// height the longest label needs; the screen class minimum still applies.
CGRect DBDoorVisitorPurposeFrame(DBDoorVisitorLayout layout, NSInteger index, CGFloat rowHeight);
CGFloat DBDoorVisitorPurposeGridHeight(DBDoorVisitorLayout layout, NSInteger count,
                                       CGFloat rowHeight);
