#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Every frame of the indoor dashboard, computed in one place so a host test can prove that
// nothing overlaps or leaves the screen in either orientation.
typedef struct {
  CGRect navBar;
  CGRect tabBar;
  CGRect clock;
  CGRect date;
  CGRect air;            // Empty unless the PM2.5 line is shown under the date.
  CGRect counters;       // The fleet counters are right aligned inside this band.
  CGRect sos;            // The compact SOS button; empty unless SOS is configured here.
  CGRect pager;          // Empty unless the doors need more than one preview page.
  CGRect banner;         // Empty unless the "not set up" banner is shown.
  CGRect missed;         // Empty unless unread missed calls exist.
  CGRect tiles;          // The door tile grid: everything between the header and the footer.
  CGFloat footerTop;     // The footer band (admin QR, version, SOS) starts here.
} DBHomeLayout;

// At least 12 pt separates the header from the tiles. footerHeight is the band DBUiTheme's footer layout reserves above the tab bar; the plate's own 8 pt padding and the 12 pt gap above it are added here.
DBHomeLayout DBHomeLayoutMake(CGSize size, CGFloat navHeight, CGFloat tabHeight,
                              CGFloat footerHeight, BOOL showsBanner, BOOL showsMissed,
                              BOOL showsPager, BOOL showsSOS);
// Inserts the PM2.5 line under the date and moves the notices and the tiles down by whatever the
// header grew. A zero height returns the layout unchanged.
DBHomeLayout DBHomeLayoutPlaceAir(DBHomeLayout layout, CGFloat height);
// The frame of one door tile; count is how many tiles are on screen (at most three). The grid
// picks the column count that gives the largest 16:9 picture.
CGRect DBHomeLayoutTileFrame(DBHomeLayout layout, NSInteger index, NSInteger count);

// The frosted plate under the footer block: 20 pt from the sides and from the tab bar, the block
// inset 8 pt inside it, and always below layout.footerTop.
CGRect DBHomeLayoutFooterPlate(CGSize size, CGFloat tabHeight, CGFloat blockHeight);
