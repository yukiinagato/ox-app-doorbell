#import "DBChrome.h"

#import "../Core/DBBootConfig.h"
#import "../Core/DBIconAsset.h"
#import "../Core/DBTexts.h"
#import "DBRouter.h"

CGFloat DBChromeNavBarHeight(void) { return 44; }
CGFloat DBChromeTabBarHeight(void) { return 49; }

BOOL DBChromeIsPad(void) {
  return UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad;
}

BOOL DBChromeIsFlat(void) {
  static BOOL flat = NO;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    flat = [[[UIDevice currentDevice] systemVersion] floatValue] >= 7.0f;
  });
  return flat;
}

UIColor *DBChromeScreenBackground(void) {
  // UIKit before iOS 7 has no colour accessor for the iPad's grouped ground (the pinstripe
  // pattern belongs to the phone), so the iPad value is the measured match.
  if (DBChromeIsFlat() || !DBChromeIsPad()) return [UIColor groupTableViewBackgroundColor];
  return [UIColor colorWithRed:217.0f / 255.0f green:220.0f / 255.0f blue:226.0f / 255.0f
                         alpha:1];
}

UITableView *DBChromeGroupedTable(id<UITableViewDataSource> dataSource,
                                  id<UITableViewDelegate> delegate) {
  UITableView *table = [[UITableView alloc] initWithFrame:CGRectZero
                                                    style:UITableViewStyleGrouped];
  table.dataSource = dataSource;
  table.delegate = delegate;
  return table;
}

UIView *DBChromeInstallBackdrop(UIView *host) {
  UITableView *backdrop = [[UITableView alloc] initWithFrame:host.bounds
                                                       style:UITableViewStyleGrouped];
  backdrop.userInteractionEnabled = NO;
  backdrop.scrollEnabled = NO;
  backdrop.scrollsToTop = NO;
  backdrop.isAccessibilityElement = NO;
  backdrop.accessibilityElementsHidden = YES;
  backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [host insertSubview:backdrop atIndex:0];
  return backdrop;
}

void DBChromeClearTableBackground(UITableView *table) {
  table.backgroundView = nil;
  table.backgroundColor = [UIColor clearColor];
  table.opaque = NO;
}

static UILabel *DBChromeSectionLabel(BOOL footer) {
  UILabel *label = [[UILabel alloc] init];
  label.backgroundColor = [UIColor clearColor];
  label.numberOfLines = 0;
  if (DBChromeIsFlat()) {
    label.font = [UIFont systemFontOfSize:13];
    label.textColor = [UIColor colorWithRed:0.427f green:0.427f blue:0.447f alpha:1];
  } else {
    label.font = footer ? [UIFont systemFontOfSize:15] : [UIFont boldSystemFontOfSize:17];
    label.textColor = [UIColor colorWithRed:0.298f green:0.337f blue:0.424f alpha:1];
    label.shadowColor = [UIColor whiteColor];
    label.shadowOffset = CGSizeMake(0, 1);
    if (footer) label.textAlignment = NSTextAlignmentCenter;
  }
  return label;
}

UILabel *DBChromeSectionHeaderLabel(void) { return DBChromeSectionLabel(NO); }
UILabel *DBChromeSectionFooterLabel(void) { return DBChromeSectionLabel(YES); }

UIButton *DBChromeButton(NSString *title, CGFloat fontSize) {
  // UIButtonTypeRoundedRect and UIButtonTypeSystem are one enum value. On iOS 5 the button is
  // a white rounded rect whose default title is dark blue; it only looked empty when a caller
  // painted that title white, so no colour is set here.
  UIButton *button = [UIButton buttonWithType:UIButtonTypeRoundedRect];
  [button setTitle:title forState:UIControlStateNormal];
  if (fontSize > 0) {
    button.titleLabel.font = DBChromeIsFlat() ? [UIFont systemFontOfSize:fontSize]
                                              : [UIFont boldSystemFontOfSize:fontSize];
  }
  button.titleLabel.adjustsFontSizeToFitWidth = YES;
  button.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
  return button;
}

UIButton *DBChromeFilledButton(CGFloat fontSize) {
  UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
  button.titleLabel.font = [UIFont boldSystemFontOfSize:fontSize > 0 ? fontSize : 22];
  button.titleLabel.adjustsFontSizeToFitWidth = YES;
  button.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
  button.layer.cornerRadius = 10;
  button.clipsToBounds = YES;
  return button;
}

UIBarButtonItem *DBChromeBarItem(NSString *title, id target, SEL action) {
  return [[UIBarButtonItem alloc] initWithTitle:title style:UIBarButtonItemStyleBordered
                                         target:target action:action];
}

UIBarButtonItem *DBChromeDoneBarItem(NSString *title, id target, SEL action) {
  return [[UIBarButtonItem alloc] initWithTitle:title style:UIBarButtonItemStyleDone
                                         target:target action:action];
}

UIBarButtonItem *DBChromeSystemBarItem(UIBarButtonSystemItem item, id target, SEL action) {
  return [[UIBarButtonItem alloc] initWithBarButtonSystemItem:item target:target action:action];
}

UIBarButtonItem *DBChromeFlexibleSpace(void) {
  return [[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:NULL];
}

@implementation DBNavBar {
  UINavigationBar *_bar;
  // The parent placeholder (when the root has a back title), the root, then pushed pages.
  NSMutableArray *_items;
  // Parallel to _items: the block to run when that item is popped by the user, or NSNull.
  NSMutableArray *_handlers;
  BOOL _rootHasParent;
  BOOL _applying;
}

@synthesize bar = _bar;

- (id)init {
  self = [super init];
  if (self) {
    _bar = [[UINavigationBar alloc] initWithFrame:CGRectMake(0, 0, 320, DBChromeNavBarHeight())];
    _bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _bar.delegate = self;
    _items = [[NSMutableArray alloc] init];
    _handlers = [[NSMutableArray alloc] init];
  }
  return self;
}

- (void)dealloc {
  _bar.delegate = nil;
}

- (void)applyItems {
  _applying = YES;
  [_bar setItems:[NSArray arrayWithArray:_items] animated:NO];
  _applying = NO;
}

- (UINavigationItem *)topItem {
  return [_items lastObject];
}

- (NSUInteger)rootIndex {
  return _rootHasParent ? 1 : 0;
}

- (NSUInteger)depth {
  NSUInteger base = [self rootIndex] + 1;
  return [_items count] > base ? [_items count] - base : 0;
}

- (UINavigationItem *)setRootTitle:(NSString *)title
                         backTitle:(NSString *)backTitle
                            onBack:(void (^)(void))onBack {
  [_items removeAllObjects];
  [_handlers removeAllObjects];
  _rootHasParent = [backTitle length] > 0;
  if (_rootHasParent) {
    [_items addObject:[[UINavigationItem alloc] initWithTitle:backTitle]];
    [_handlers addObject:[NSNull null]];
  }
  UINavigationItem *root = [[UINavigationItem alloc] initWithTitle:title ?: @""];
  [_items addObject:root];
  [_handlers addObject:(_rootHasParent && onBack) ? (id)[onBack copy] : (id)[NSNull null]];
  [self applyItems];
  return root;
}

- (UINavigationItem *)pushTitle:(NSString *)title onPop:(void (^)(void))onPop {
  UINavigationItem *item = [[UINavigationItem alloc] initWithTitle:title ?: @""];
  [_items addObject:item];
  [_handlers addObject:onPop ? (id)[onPop copy] : (id)[NSNull null]];
  [self applyItems];
  return item;
}

- (void)pop {
  if ([self depth] == 0) return;
  [_items removeLastObject];
  [_handlers removeLastObject];
  [self applyItems];
}

- (void)popToRoot {
  if ([self depth] == 0) return;
  NSUInteger keep = [self rootIndex] + 1;
  while ([_items count] > keep) {
    [_items removeLastObject];
    [_handlers removeLastObject];
  }
  [self applyItems];
}

- (CGFloat)layoutInBounds:(CGRect)bounds {
  CGFloat height = DBChromeNavBarHeight();
  _bar.frame = CGRectMake(bounds.origin.x, bounds.origin.y, bounds.size.width, height);
  return height;
}

- (void)userTappedBackOnItem:(UINavigationItem *)item {
  if ([_items lastObject] != item) return;
  id handler = [_handlers lastObject];
  if ([self depth] > 0) {
    [_items removeLastObject];
    [_handlers removeLastObject];
  }
  // Re-applying the stack also rebuilds the back button, which iOS 7 and later leave dimmed
  // after a vetoed pop.
  [self applyItems];
  if (handler != [NSNull null]) ((void (^)(void))handler)();
}

- (BOOL)navigationBar:(UINavigationBar *)navigationBar shouldPopItem:(UINavigationItem *)item {
  (void)navigationBar;
  if (_applying) return YES;
  // The bar is still inside its own touch handling here; replacing its items waits for the
  // next run-loop turn.
  __weak DBNavBar *weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    [weakSelf userTappedBackOnItem:item];
  });
  return NO;
}

@end

@implementation DBHomeTabs {
  UITabBar *_bar;
  __weak DBRouter *_router;
  DBHomeTab _tab;
  NSArray *_tabItems;
}

@synthesize bar = _bar;

+ (BOOL)shownForRole:(NSString *)role {
  return ![role isEqualToString:@"door_station"];
}

- (id)initWithRouter:(DBRouter *)router tab:(DBHomeTab)tab {
  self = [super init];
  if (self) {
    _router = router;
    _tab = tab;
    _bar = [[UITabBar alloc] initWithFrame:CGRectMake(0, 0, 320, DBChromeTabBarHeight())];
    _bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    // The tab bar masks each image by its alpha, so the vendored icons need no tinting.
    NSArray *icons = [NSArray arrayWithObjects:@"home", @"clock", @"settings", nil];
    NSMutableArray *items = [NSMutableArray array];
    for (NSUInteger i = 0; i < [icons count]; i++) {
      UITabBarItem *item = [[UITabBarItem alloc]
          initWithTitle:@"" image:[DBIconAsset imageNamed:[icons objectAtIndex:i]]
                    tag:(NSInteger)i];
      [items addObject:item];
    }
    _tabItems = items;
    _bar.items = items;
    _bar.delegate = self;
    _bar.hidden = ![DBHomeTabs shownForRole:router.boot.role];
    [self syncSelection];
  }
  return self;
}

- (void)dealloc {
  _bar.delegate = nil;
}

- (void)applyTexts:(DBTexts *)texts {
  NSArray *keys = [NSArray arrayWithObjects:@"nav.home", @"nav.history", @"nav.settings", nil];
  for (NSUInteger i = 0; i < [_tabItems count]; i++)
    [(UITabBarItem *)[_tabItems objectAtIndex:i] setTitle:[texts ts:[keys objectAtIndex:i]]];
}

- (void)setMissedCount:(NSInteger)count {
  UITabBarItem *history = [_tabItems objectAtIndex:DBHomeTabHistory];
  history.badgeValue = count > 0 ? [NSString stringWithFormat:@"%ld", (long)count] : nil;
}

- (void)syncSelection {
  _bar.selectedItem = [_tabItems objectAtIndex:_tab];
}

- (CGFloat)layoutInBounds:(CGRect)bounds {
  if (_bar.hidden) {
    _bar.frame = CGRectZero;
    return 0;
  }
  CGFloat height = DBChromeTabBarHeight();
  _bar.frame = CGRectMake(bounds.origin.x, CGRectGetMaxY(bounds) - height, bounds.size.width,
                          height);
  return height;
}

- (void)tabBar:(UITabBar *)tabBar didSelectItem:(UITabBarItem *)item {
  (void)tabBar;
  if (item.tag == (NSInteger)_tab) return;
  [self syncSelection];
  [_router selectHomeTab:item.tag];
}

@end
