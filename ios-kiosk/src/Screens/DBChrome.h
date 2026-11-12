#import <UIKit/UIKit.h>

@class DBRouter;
@class DBTexts;

// Stock UIKit chrome for the kiosk screens. Every control made here is left to the system to
// render: no UIAppearance, no tint, and no palette colour is applied, so an iPad 1 shows the
// iOS 5 look and an iOS 9 device the flat look.
//
// Screens stay UIViews swapped by DBRouter (iOS 5 modal presentation is unreliable), so the
// navigation bar and the tab bar are hosted as plain subviews and never belong to a
// UINavigationController or a UITabBarController.

CGFloat DBChromeNavBarHeight(void);
CGFloat DBChromeTabBarHeight(void);
BOOL DBChromeIsPad(void);
// YES on iOS 7 and later, where bars and grouped tables are flat.
BOOL DBChromeIsFlat(void);

// The ground of a screen that does not draw the wallpaper. A grouped table paints its own
// system background; this is the matching colour for the area a table does not cover.
UIColor *DBChromeScreenBackground(void);

// The system's own grouped ground behind a whole screen. Before iOS 7 the iPad draws it as a
// gradient that no colour can match, so a screen whose table is narrower than the screen puts
// this behind everything and clears the table's own background; the seam then cannot exist.
// The returned view resizes with host.
UIView *DBChromeInstallBackdrop(UIView *host);

// A grouped table with the system background, section headers, and separators.
UITableView *DBChromeGroupedTable(id<UITableViewDataSource> dataSource,
                                  id<UITableViewDelegate> delegate);
// The same table without its background, so its cells sit as cards on the wallpaper.
void DBChromeClearTableBackground(UITableView *table);

// Free text above or below a grouped table, styled like the system's own section header and
// footer for the running OS. Use titleForHeaderInSection / titleForFooterInSection where a plain
// string is enough; these exist for a tableHeaderView or tableFooterView.
UILabel *DBChromeSectionHeaderLabel(void);
UILabel *DBChromeSectionFooterLabel(void);

// The stock button: rounded-rect on iOS 5 and 6, borderless system text on iOS 7 and later.
// Its colours are the system's; callers must not set a title colour or a background.
UIButton *DBChromeButton(NSString *title, CGFloat fontSize);
// The one coloured button: Answer, End, SOS, and Call have no system equivalent, so they keep a
// semantic fill. Callers set the fill and ink, normally through DBSemanticStyle.
UIButton *DBChromeFilledButton(CGFloat fontSize);

UIBarButtonItem *DBChromeBarItem(NSString *title, id target, SEL action);
UIBarButtonItem *DBChromeDoneBarItem(NSString *title, id target, SEL action);
UIBarButtonItem *DBChromeSystemBarItem(UIBarButtonSystemItem item, id target, SEL action);
UIBarButtonItem *DBChromeFlexibleSpace(void);

// A standalone UINavigationBar and its page stack.
//
// The bar draws the stock back button whenever a page sits above another item. Tapping it never
// lets the bar animate a pop by itself: the handler for the top page runs, then the stack is
// applied without animation, which keeps screen changes instant on the A4.
@interface DBNavBar : NSObject <UINavigationBarDelegate>

@property(nonatomic, readonly) UINavigationBar *bar;
// The item of the page on screen. Set its title and bar button items directly.
@property(nonatomic, readonly) UINavigationItem *topItem;
// Pages pushed above the root.
@property(nonatomic, readonly) NSUInteger depth;

// Replaces the whole stack with one root page. A non-nil backTitle places a parent item under
// the root, so the bar shows a back button with that title; tapping it calls onBack and leaves
// the stack alone, because the screen is about to be replaced by the router.
- (UINavigationItem *)setRootTitle:(NSString *)title
                         backTitle:(NSString *)backTitle
                            onBack:(void (^)(void))onBack;
// Adds a page. onPop runs after the user tapped back and the page left the stack.
- (UINavigationItem *)pushTitle:(NSString *)title onPop:(void (^)(void))onPop;
// Removes the top page without calling its handler.
- (void)pop;
- (void)popToRoot;
// Places the bar across the top of bounds and returns the height it occupies.
- (CGFloat)layoutInBounds:(CGRect)bounds;

@end

typedef enum {
  DBHomeTabHome = 0,
  DBHomeTabHistory,
  DBHomeTabSettings,
} DBHomeTab;

// The indoor panel's three destinations as a standalone UITabBar. Home, History, and Settings
// are separate router screens; each hosts its own instance with its own tab selected, and a tap
// asks the router to switch. Settings stays behind the admin password, so the selection snaps
// back until the router has actually changed screens.
@interface DBHomeTabs : NSObject <UITabBarDelegate>

@property(nonatomic, readonly) UITabBar *bar;

- (id)initWithRouter:(DBRouter *)router tab:(DBHomeTab)tab;
- (void)applyTexts:(DBTexts *)texts;
// The unread missed-call count on the History tab; zero clears the badge.
- (void)setMissedCount:(NSInteger)count;
// Re-selects this screen's own tab. Call when the screen appears.
- (void)syncSelection;
// Places the bar across the bottom of bounds and returns the height it occupies, or zero when
// the bar is hidden.
- (CGFloat)layoutInBounds:(CGRect)bounds;

// A door station's home is the visitor screen, which must have no route into settings, so only
// an indoor panel shows the tab bar.
+ (BOOL)shownForRole:(NSString *)role;

@end
