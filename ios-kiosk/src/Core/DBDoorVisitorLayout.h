#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

typedef struct {
  CGRect content;
  CGRect status;
  CGRect action;
  CGRect sos;
  CGRect version;
  CGFloat margin;
} DBDoorVisitorLayout;

// Calling and connected views share the same action rectangle. Secondary
// content scrolls independently so configured text cannot push it offscreen.
DBDoorVisitorLayout DBDoorVisitorLayoutMake(CGSize size, BOOL showsSOS, CGFloat actionScale);
