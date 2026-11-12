#import "DBHistoryScreen.h"

#import "../Core/DBBootConfig.h"
#import "../Core/DBCallHistoryModel.h"
#import "../Core/DBConfigUtil.h"
#import "../Core/DBCoreBridge.h"
#import "../Core/DBTexts.h"
#import "DBRouter.h"
#import "DBChrome.h"

static const NSInteger kPageSize = 50;

@interface DBHistoryScreen () <UITableViewDataSource, UITableViewDelegate, UIActionSheetDelegate>
@end

// The filter control shows All, Missed, and the doors themselves while they fit; a larger
// household gets one "door stations" segment that opens the list.
static const NSUInteger kMaxDoorSegments = 3;

@implementation DBHistoryScreen {
  DBCoreBridge *_core;
  DBBootConfig *_boot;
  DBTexts *_texts;
  NSDictionary *_cfg;
  NSDictionary *_status;

  NSArray *_allRows;      // Everything fetched so far, newest first.
  NSArray *_sections;     // Rendered day sections for the active filter.
  NSString *_filter;
  NSArray *_doorIds;
  NSArray *_doorLabels;
  NSInteger _tzOffsetMinutes;
  long long _nextBeforeMs;  // Paging cursor: rows strictly older than this.
  BOOL _mayHaveMore;
  BOOL _loading;
  BOOL _seenDone;
  NSInteger _loadGeneration;
  CGSize _placedSize;

  DBNavBar *_nav;
  DBHomeTabs *_tabs;
  UISegmentedControl *_filterControl;
  UIBarButtonItem *_markSeenItem;
  UIActionSheet *_doorSheet;
  UITableView *_table;
  UILabel *_empty;
}

- (id)initWithRouter:(DBRouter *)router {
  self = [super initWithFrame:[UIScreen mainScreen].bounds];
  if (self) {
    _router = router;
    _core = router.core;
    _boot = router.boot;
    _texts = router.texts;
    _filter = DBCallHistoryFilterAll;
    _allRows = [NSArray array];
    _sections = [NSArray array];
    _doorIds = [NSArray array];
    _doorLabels = [NSArray array];
    [self buildUi];
  }
  return self;
}

- (NSString *)screenName {
  return @"history";
}

- (void)buildUi {
  self.backgroundColor = DBChromeScreenBackground();
  _table = DBChromeGroupedTable(self, self);
  _table.rowHeight = 64;
  [self addSubview:_table];

  _empty = DBChromeSectionFooterLabel();
  _empty.textAlignment = NSTextAlignmentCenter;
  _empty.font = [UIFont systemFontOfSize:20];

  _nav = [[DBNavBar alloc] init];
  [self addSubview:_nav.bar];
  _tabs = [[DBHomeTabs alloc] initWithRouter:_router tab:DBHomeTabHistory];
  [self addSubview:_tabs.bar];
  _markSeenItem = DBChromeBarItem(@"", self, @selector(onMarkSeen));
  [self applyNavigation];
}

// A door station has no tab bar, so its history goes back to the settings page that opened it.
- (void)applyNavigation {
  __weak DBHistoryScreen *weakSelf = self;
  BOOL tabs = [DBHomeTabs shownForRole:_boot.role];
  UINavigationItem *item = [_nav setRootTitle:[_texts ts:@"history.title"]
                                    backTitle:tabs ? nil : [_texts ts:@"ui.back"]
                                       onBack:^{ [weakSelf onClose]; }];
  if (_filterControl) item.titleView = _filterControl;
  [_markSeenItem setTitle:[_texts ts:@"history.mark_seen"]];
  item.rightBarButtonItem = _markSeenItem;
  [_tabs applyTexts:_texts];
}

- (void)onScreenWillAppear {
  [_tabs syncSelection];
  [self applyNavigation];
  [self reload];
}

- (void)onScreenWillDisappear {
  [_doorSheet dismissWithClickedButtonIndex:_doorSheet.cancelButtonIndex animated:NO];
  _doorSheet = nil;
}

- (void)reload {
  _nextBeforeMs = 0;
  _allRows = [NSArray array];
  _seenDone = NO;
  [self loadPageAndMarkSeen:YES];
}

- (void)onLoadMore {
  if (_loading || !_mayHaveMore || _nextBeforeMs <= 0) return;
  [self loadPageAndMarkSeen:NO];
}

// One page of fifty, strictly older than the cursor. Core's v2 export takes the
// cursor directly; on an older Core the model slices the wider read instead, so
// 「さらに読み込む」 behaves the same either way.
- (void)loadPageAndMarkSeen:(BOOL)markSeen {
  if (_loading) return;
  _loading = YES;
  NSInteger generation = ++_loadGeneration;
  long long beforeMs = _nextBeforeMs;
  NSArray *existing = _allRows;
  DBCoreBridge *core = _core;
  __weak DBHistoryScreen *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSInteger read = beforeMs > 0 ? MIN(500, (NSInteger)[existing count] + kPageSize)
                                  : kPageSize;
    NSDictionary *log = [core callLogSince:0 beforeMs:beforeMs limit:read];
    NSDictionary *cfg = [core config];
    NSDictionary *status = [core status];
    NSDictionary *localTime = [core localTimeJson:0];
    NSArray *fetched = [DBCallHistoryModel rowsFromLog:log];
    NSArray *page = [DBCallHistoryModel pageRows:fetched beforeMs:beforeMs limit:kPageSize];
    NSArray *merged = [DBCallHistoryModel mergeRows:existing withPage:page];
    NSString *newest = [DBCallHistoryModel newestHlcInRows:merged];
    if (markSeen && [newest length] > 0) [core markCallLogSeenUpTo:newest];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBHistoryScreen *screen = weakSelf;
      if (!screen || screen->_loadGeneration != generation) return;
      screen->_loading = NO;
      screen->_cfg = cfg;
      screen->_status = status;
      screen->_tzOffsetMinutes = [DBConfigUtil intVal:localTime path:@"offset_min" def:0];
      screen->_allRows = merged;
      screen->_mayHaveMore = [DBCallHistoryModel pageMayHaveMore:page limit:kPageSize];
      long long cursor = [DBCallHistoryModel nextBeforeMsForPage:page];
      if (cursor > 0) screen->_nextBeforeMs = cursor;
      [screen rebuildFilters];
      [screen rebuildSections];
    });
  });
}

- (void)rebuildFilters {
  NSMutableArray *ids = [NSMutableArray array];
  NSMutableArray *labels = [NSMutableArray array];
  NSDictionary *doors = [DBConfigUtil dig:_cfg path:@"doors"];
  if ([doors isKindOfClass:[NSDictionary class]]) {
    for (NSString *door in [DBConfigUtil sortedByOrder:doors]) {
      [ids addObject:door];
      [labels addObject:[DBConfigUtil labelOf:[doors objectForKey:door] lang:_boot.uiLang
                                     fallback:door]];
    }
  }
  _doorIds = ids;
  _doorLabels = labels;
  if (![_filter isEqualToString:DBCallHistoryFilterAll] &&
      ![_filter isEqualToString:DBCallHistoryFilterMissed] && ![ids containsObject:_filter])
    _filter = DBCallHistoryFilterAll;

  NSMutableArray *titles = [NSMutableArray arrayWithObjects:
      [_texts ts:@"history.filter_all"], [_texts ts:@"history.filter_missed"], nil];
  if ([ids count] <= kMaxDoorSegments) {
    [titles addObjectsFromArray:labels];
  } else {
    NSUInteger chosen = [ids indexOfObject:_filter];
    [titles addObject:chosen == NSNotFound ? [_texts ts:@"dash.doors"]
                                           : [labels objectAtIndex:chosen]];
  }
  // A fresh control with a real frame, assigned again: on iOS 5 the bar sizes a title view
  // only when it is set, so one that was empty at that moment stays invisible.
  [_filterControl removeTarget:self action:NULL forControlEvents:UIControlEventAllEvents];
  _filterControl = [[UISegmentedControl alloc] initWithItems:titles];
  _filterControl.segmentedControlStyle = UISegmentedControlStyleBar;
  [_filterControl addTarget:self action:@selector(onFilterChanged)
           forControlEvents:UIControlEventValueChanged];
  [self updateFilterSelection];
  [self placeFilterControl];
}

// The filter takes what the bar can give beside the back and mark-seen items, with segments
// wide enough to read and to touch.
- (void)placeFilterControl {
  CGFloat available = MAX(160, self.bounds.size.width - 400);
  CGFloat wanted = 120.0f * (CGFloat)MAX((NSUInteger)2, _filterControl.numberOfSegments);
  _filterControl.frame = CGRectMake(0, 0, MIN(available, wanted), 30);
  _nav.topItem.titleView = nil;
  _nav.topItem.titleView = _filterControl;
}

- (void)updateFilterSelection {
  NSInteger index = 0;
  if ([_filter isEqualToString:DBCallHistoryFilterMissed]) {
    index = 1;
  } else if (![_filter isEqualToString:DBCallHistoryFilterAll]) {
    NSUInteger door = [_doorIds indexOfObject:_filter];
    index = [_doorIds count] <= kMaxDoorSegments ? 2 + (NSInteger)door : 2;
  }
  if (index < (NSInteger)_filterControl.numberOfSegments)
    _filterControl.selectedSegmentIndex = index;
}

- (void)applyFilter:(NSString *)filter {
  _filter = [filter copy];
  if ([_doorIds count] > kMaxDoorSegments) [self rebuildFilters];
  [self updateFilterSelection];
  [self rebuildSections];
}

- (void)onFilterChanged {
  NSInteger index = _filterControl.selectedSegmentIndex;
  if (index <= 0) {
    [self applyFilter:DBCallHistoryFilterAll];
  } else if (index == 1) {
    [self applyFilter:DBCallHistoryFilterMissed];
  } else if ([_doorIds count] <= kMaxDoorSegments) {
    NSUInteger door = (NSUInteger)(index - 2);
    if (door < [_doorIds count]) [self applyFilter:[_doorIds objectAtIndex:door]];
  } else {
    [self updateFilterSelection];
    [self presentDoorSheet];
  }
}

- (void)presentDoorSheet {
  UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:[_texts ts:@"dash.doors"]
                                                     delegate:self
                                            cancelButtonTitle:nil
                                       destructiveButtonTitle:nil
                                            otherButtonTitles:nil];
  for (NSString *label in _doorLabels) [sheet addButtonWithTitle:label];
  sheet.cancelButtonIndex = [sheet addButtonWithTitle:[_texts ts:@"admin.cancel"]];
  _doorSheet = sheet;
  CGRect anchor = [self convertRect:_filterControl.bounds fromView:_filterControl];
  if (DBChromeIsPad())
    [sheet showFromRect:anchor inView:self animated:NO];
  else
    [sheet showInView:self];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)buttonIndex {
  if (sheet != _doorSheet) return;
  _doorSheet = nil;
  if (buttonIndex < 0 || buttonIndex == sheet.cancelButtonIndex ||
      buttonIndex >= (NSInteger)[_doorIds count]) return;
  [self applyFilter:[_doorIds objectAtIndex:(NSUInteger)buttonIndex]];
}

- (void)rebuildSections {
  NSArray *filtered = [DBCallHistoryModel filterRows:_allRows filter:_filter];
  NSInteger offset = _tzOffsetMinutes;
  _sections = [DBCallHistoryModel groupRowsByDay:filtered dayKey:^NSString *(long long ms) {
    return [DBCallHistoryModel dayKeyForTs:ms offsetMinutes:offset];
  }];
  _empty.text = [_texts ts:_seenDone ? @"history.seen_done" : @"history.empty"];
  _table.tableHeaderView = [filtered count] > 0 ? nil : _empty;
  _markSeenItem.enabled = [_allRows count] > 0;
  [_table reloadData];
  [self setNeedsLayout];
}

- (void)onMarkSeen {
  NSString *newest = [DBCallHistoryModel newestHlcInRows:_allRows];
  if ([newest length] == 0) return;
  DBCoreBridge *core = _core;
  __weak DBHistoryScreen *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    BOOL ok = [core markCallLogSeenUpTo:newest];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBHistoryScreen *screen = weakSelf;
      if (!screen || !ok) return;
      screen->_seenDone = YES;
      screen->_empty.text = [screen->_texts ts:@"history.seen_done"];
      screen->_markSeenItem.enabled = NO;
    });
  });
}

- (void)onClose {
  [_router closeHistoryAnimated:YES];
}

#pragma mark - table

- (BOOL)isLoadMoreSection:(NSInteger)section {
  return _mayHaveMore && section == (NSInteger)[_sections count];
}

- (NSArray *)rowsInSection:(NSInteger)section {
  if (section < 0 || section >= (NSInteger)[_sections count]) return [NSArray array];
  return [[_sections objectAtIndex:(NSUInteger)section] objectForKey:@"rows"];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  (void)tableView;
  return (NSInteger)[_sections count] + (_mayHaveMore ? 1 : 0);
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  (void)tableView;
  if ([self isLoadMoreSection:section]) return 1;
  return (NSInteger)[[self rowsInSection:section] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
  (void)tableView;
  if (section < 0 || section >= (NSInteger)[_sections count]) return nil;
  NSString *day = [[_sections objectAtIndex:(NSUInteger)section] objectForKey:@"day"];
  long long nowMs = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
  NSString *today = [DBCallHistoryModel dayKeyForTs:nowMs offsetMinutes:_tzOffsetMinutes];
  NSString *yesterday = [DBCallHistoryModel dayKeyForTs:nowMs - 86400000LL
                                          offsetMinutes:_tzOffsetMinutes];
  if ([day isEqualToString:today]) return [_texts ts:@"history.today"];
  if ([day isEqualToString:yesterday]) return [_texts ts:@"history.yesterday"];
  return day;
}

// A node id is not something to show a resident: it is resolved to the device name, and a name
// that cannot be resolved is left out rather than printed as forty hex characters.
- (NSString *)deviceNameForId:(NSString *)identifier {
  if ([identifier length] == 0) return @"";
  NSString *name = [DBConfigUtil str:_cfg
      path:[NSString stringWithFormat:@"devices.%@.name", identifier]];
  if ([name length] > 0) return name;
  NSDictionary *peer = [DBConfigUtil findPeer:_status nodeId:identifier];
  name = [DBConfigUtil evStr:peer key:@"name"];
  if ([name length] > 0) return name;
  NSString *selfName = [DBConfigUtil str:_status path:@"node.name"];
  if ([[DBConfigUtil str:_status path:@"node.id"] isEqualToString:identifier] &&
      [selfName length] > 0)
    return selfName;
  return [identifier length] > 24 ? @"" : identifier;
}

- (NSString *)outcomeTextForRow:(NSDictionary *)row {
  NSString *outcome = [DBConfigUtil evStr:row key:@"outcome"];
  if ([outcome isEqualToString:@"answered"]) return [_texts ts:@"history.outcome_answered"];
  if ([outcome isEqualToString:@"replied"]) return [_texts ts:@"history.outcome_replied"];
  if ([outcome isEqualToString:@"missed"]) return [_texts ts:@"history.outcome_missed"];
  if ([outcome isEqualToString:@"cancelled"]) return [_texts ts:@"history.outcome_cancelled"];
  return outcome;
}

- (UITableViewCell *)loadMoreCellForTable:(UITableView *)tableView {
  static NSString *identifier = @"more";
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
  if (cell == nil) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                  reuseIdentifier:identifier];
    cell.textLabel.textAlignment = NSTextAlignmentCenter;
  }
  cell.textLabel.text = [_texts ts:@"history.load_more"];
  return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  if ([self isLoadMoreSection:indexPath.section]) return [self loadMoreCellForTable:tableView];
  static NSString *identifier = @"history";
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
  if (cell == nil) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                  reuseIdentifier:identifier];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.adjustsFontSizeToFitWidth = YES;
    cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
  }
  NSArray *rows = [self rowsInSection:indexPath.section];
  if (indexPath.row >= (NSInteger)[rows count]) return cell;
  NSDictionary *row = [rows objectAtIndex:(NSUInteger)indexPath.row];
  NSString *door = [DBConfigUtil evStr:row key:@"door"];
  NSDictionary *doorEntry = [DBConfigUtil dig:_cfg
      path:[NSString stringWithFormat:@"doors.%@", door]];
  NSString *doorLabel = [DBConfigUtil labelOf:doorEntry lang:_boot.uiLang fallback:door];
  long long ts = [DBConfigUtil longLongVal:row path:@"ts" def:0];
  cell.textLabel.text = [NSString stringWithFormat:@"%@   %@",
      [DBCallHistoryModel clockForTs:ts offsetMinutes:_tzOffsetMinutes], doorLabel];

  NSMutableArray *detail = [NSMutableArray array];
  [detail addObject:[self outcomeTextForRow:row]];
  NSString *answeredBy = [self deviceNameForId:[DBConfigUtil evStr:row key:@"answered_by"]];
  if ([answeredBy length] > 0)
    [detail addObject:[_texts t:@"history.answered_by", answeredBy, nil]];
  NSString *duration = [DBCallHistoryModel durationTextForMs:
      [DBConfigUtil longLongVal:row path:@"duration_ms" def:0]];
  if ([duration length] > 0) [detail addObject:[_texts t:@"history.duration", duration, nil]];
  cell.detailTextLabel.text = [detail componentsJoinedByString:@"  ·  "];
  // A missed call is the one row state with a colour: the negative role. Every other row keeps
  // the system's own detail colour, captured from a fresh cell.
  static UIColor *stockDetail = nil;
  if (stockDetail == nil) stockDetail = cell.detailTextLabel.textColor;
  cell.detailTextLabel.textColor = [DBCallHistoryModel rowIsMissed:row]
      ? [UIColor colorWithRed:0.78f green:0.11f blue:0.10f alpha:1] : stockDetail;
  return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:NO];
  if ([self isLoadMoreSection:indexPath.section]) [self onLoadMore];
}

#pragma mark - layout

- (void)layoutSubviews {
  [super layoutSubviews];
  CGRect bounds = self.bounds;
  CGFloat top = [_nav layoutInBounds:bounds];
  CGFloat bottom = [_tabs layoutInBounds:bounds];
  if (_filterControl && !CGSizeEqualToSize(_placedSize, bounds.size)) {
    _placedSize = bounds.size;
    [self placeFilterControl];
  }
  _table.frame = CGRectMake(0, top, bounds.size.width,
                            MAX(0, bounds.size.height - top - bottom));
  _empty.frame = CGRectMake(0, 0, bounds.size.width, 120);
}

@end
