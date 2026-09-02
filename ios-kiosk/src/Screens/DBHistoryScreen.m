#import "DBHistoryScreen.h"

#import "../Core/DBBootConfig.h"
#import "../Core/DBCallHistoryModel.h"
#import "../Core/DBConfigUtil.h"
#import "../Core/DBCoreBridge.h"
#import "../Core/DBTexts.h"
#import "../Core/DBUiTheme.h"
#import "DBRouter.h"
#import "DBWidgets.h"

static const NSInteger kPageSize = 50;

@interface DBHistoryScreen () <UITableViewDataSource, UITableViewDelegate>
@end

@implementation DBHistoryScreen {
  DBCoreBridge *_core;
  DBBootConfig *_boot;
  DBTexts *_texts;
  DBUiPalette *_palette;
  NSDictionary *_cfg;
  NSDictionary *_status;
  NSString *_nodeId;

  NSArray *_allRows;      // Everything fetched so far, newest first.
  NSArray *_sections;     // Rendered day sections for the active filter.
  NSString *_filter;
  NSInteger _tzOffsetMinutes;
  long long _nextBeforeMs;  // Paging cursor: rows strictly older than this.
  BOOL _mayHaveMore;
  BOOL _loading;
  NSInteger _loadGeneration;

  UILabel *_title;
  UIButton *_close;
  UIButton *_markSeen;
  UIScrollView *_filterBar;
  NSMutableArray *_filterButtons;
  UITableView *_table;
  UIButton *_loadMore;
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
    _filterButtons = [[NSMutableArray alloc] init];
    _nextBeforeMs = 0;
    _tzOffsetMinutes = 0;
    _nodeId = @"";
    [self buildUi];
  }
  return self;
}

- (NSString *)screenName {
  return @"history";
}

- (UIButton *)chipButton {
  UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
  button.titleLabel.font = [UIFont boldSystemFontOfSize:17];
  button.layer.cornerRadius = 8;
  button.clipsToBounds = YES;
  button.contentEdgeInsets = UIEdgeInsetsMake(6, 14, 6, 14);
  return button;
}

- (void)buildUi {
  _title = [[UILabel alloc] init];
  _title.backgroundColor = [UIColor clearColor];
  _title.font = [UIFont boldSystemFontOfSize:28];
  [self addSubview:_title];

  _close = [self chipButton];
  [_close addTarget:self action:@selector(onClose) forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_close];

  _markSeen = [self chipButton];
  [_markSeen addTarget:self action:@selector(onMarkSeen)
      forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_markSeen];

  _filterBar = [[UIScrollView alloc] init];
  _filterBar.showsHorizontalScrollIndicator = NO;
  [self addSubview:_filterBar];

  _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
  _table.dataSource = self;
  _table.delegate = self;
  _table.rowHeight = 72;
  _table.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
  [self addSubview:_table];

  _empty = [[UILabel alloc] init];
  _empty.backgroundColor = [UIColor clearColor];
  _empty.textAlignment = NSTextAlignmentCenter;
  _empty.font = [UIFont systemFontOfSize:20];
  _empty.hidden = YES;
  [self addSubview:_empty];

  _loadMore = [self chipButton];
  _loadMore.titleLabel.font = [UIFont boldSystemFontOfSize:19];
  [_loadMore addTarget:self action:@selector(onLoadMore)
      forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_loadMore];
}

- (void)onScreenWillAppear {
  [self reload];
}

- (void)reload {
  _nextBeforeMs = 0;
  _allRows = [NSArray array];
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
      screen->_nodeId = [DBConfigUtil str:status path:@"node.id"] ?: @"";
      screen->_tzOffsetMinutes = [DBConfigUtil intVal:localTime path:@"offset_min" def:0];
      screen->_allRows = merged;
      screen->_mayHaveMore = [DBCallHistoryModel pageMayHaveMore:page limit:kPageSize];
      long long cursor = [DBCallHistoryModel nextBeforeMsForPage:page];
      if (cursor > 0) screen->_nextBeforeMs = cursor;
      [screen applyPalette];
      [screen rebuildFilters];
      [screen applyStrings];
      [screen rebuildSections];
    });
  });
}

- (void)applyPalette {
  _palette = [DBUiPalette paletteForConfig:_cfg deviceId:_nodeId
                                   display:[DBConfigUtil dig:_status path:@"display"]
                             backgroundHex:nil minuteOfDay:[self minuteOfDay]];
  self.backgroundColor = _palette.surface;
  _title.textColor = _palette.ink;
  _empty.textColor = _palette.mutedInk;
  _table.backgroundColor = _palette.surface;
  _table.separatorColor = _palette.separator;
  for (UIButton *button in @[ _close, _markSeen, _loadMore ]) {
    button.backgroundColor = _palette.elevated;
    [button setTitleColor:_palette.ink forState:UIControlStateNormal];
  }
}

- (NSInteger)minuteOfDay {
  NSDictionary *local = [_core cachedLocalTime];
  NSInteger hh = [DBConfigUtil intVal:local path:@"hh" def:-1];
  if (hh < 0) return 12 * 60;
  return hh * 60 + [DBConfigUtil intVal:local path:@"mm" def:0];
}

- (void)applyStrings {
  _title.text = [_texts ts:@"history.title"];
  [_close setTitle:[_texts ts:@"settings.close"] forState:UIControlStateNormal];
  [_markSeen setTitle:[_texts ts:@"history.mark_seen"] forState:UIControlStateNormal];
  [_loadMore setTitle:[_texts ts:@"history.load_more"] forState:UIControlStateNormal];
  _empty.text = [_texts ts:@"history.empty"];
}

- (void)rebuildFilters {
  for (UIButton *button in _filterButtons) [button removeFromSuperview];
  [_filterButtons removeAllObjects];
  NSMutableArray *entries = [NSMutableArray array];
  [entries addObject:@[ DBCallHistoryFilterAll, [_texts ts:@"history.filter_all"] ]];
  [entries addObject:@[ DBCallHistoryFilterMissed, [_texts ts:@"history.filter_missed"] ]];
  NSDictionary *doors = [DBConfigUtil dig:_cfg path:@"doors"];
  if ([doors isKindOfClass:[NSDictionary class]]) {
    for (NSString *door in [DBConfigUtil sortedByOrder:doors]) {
      NSString *label = [DBConfigUtil labelOf:[doors objectForKey:door] lang:_boot.uiLang
                                     fallback:door];
      [entries addObject:@[ door, label ]];
    }
  }
  for (NSArray *entry in entries) {
    UIButton *button = [self chipButton];
    [button setTitle:[entry objectAtIndex:1] forState:UIControlStateNormal];
    button.accessibilityIdentifier = [entry objectAtIndex:0];
    [button addTarget:self action:@selector(onFilter:)
     forControlEvents:UIControlEventTouchUpInside];
    [_filterBar addSubview:button];
    [_filterButtons addObject:button];
  }
  [self updateFilterSelection];
}

- (void)updateFilterSelection {
  for (UIButton *button in _filterButtons) {
    BOOL selected = [(button.accessibilityIdentifier ?: @"") isEqualToString:_filter];
    button.backgroundColor = selected ? _palette.accent : _palette.elevated;
    [button setTitleColor:(selected ? _palette.accentInk : _palette.ink)
                 forState:UIControlStateNormal];
  }
}

- (void)onFilter:(UIButton *)sender {
  _filter = [(sender.accessibilityIdentifier ?: DBCallHistoryFilterAll) copy];
  [self updateFilterSelection];
  [self rebuildSections];
}

- (void)rebuildSections {
  NSArray *filtered = [DBCallHistoryModel filterRows:_allRows filter:_filter];
  NSInteger offset = _tzOffsetMinutes;
  _sections = [DBCallHistoryModel groupRowsByDay:filtered dayKey:^NSString *(long long ms) {
    return [DBCallHistoryModel dayKeyForTs:ms offsetMinutes:offset];
  }];
  _empty.hidden = ([filtered count] > 0);
  _loadMore.hidden = !_mayHaveMore;
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
      screen->_empty.text = [screen->_texts ts:@"history.seen_done"];
    });
  });
}

- (void)onClose {
  [_router closeHistoryAnimated:YES];
}

#pragma mark - table

- (NSArray *)rowsInSection:(NSInteger)section {
  if (section < 0 || section >= (NSInteger)[_sections count]) return [NSArray array];
  return [[_sections objectAtIndex:(NSUInteger)section] objectForKey:@"rows"];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  (void)tableView;
  return (NSInteger)[_sections count];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  (void)tableView;
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

- (NSString *)outcomeTextForRow:(NSDictionary *)row {
  NSString *outcome = [DBConfigUtil evStr:row key:@"outcome"];
  if ([outcome isEqualToString:@"answered"]) return [_texts ts:@"history.outcome_answered"];
  if ([outcome isEqualToString:@"replied"]) return [_texts ts:@"history.outcome_replied"];
  if ([outcome isEqualToString:@"missed"]) return [_texts ts:@"history.outcome_missed"];
  if ([outcome isEqualToString:@"cancelled"]) return [_texts ts:@"history.outcome_cancelled"];
  return outcome;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  static NSString *identifier = @"history";
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
  if (cell == nil) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                  reuseIdentifier:identifier];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
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
  cell.textLabel.font = [UIFont boldSystemFontOfSize:23];

  NSMutableArray *detail = [NSMutableArray array];
  [detail addObject:[self outcomeTextForRow:row]];
  NSString *answeredBy = [DBConfigUtil evStr:row key:@"answered_by"];
  if ([answeredBy length] > 0)
    [detail addObject:[_texts t:@"history.answered_by", answeredBy, nil]];
  NSString *duration = [DBCallHistoryModel durationTextForMs:
      [DBConfigUtil longLongVal:row path:@"duration_ms" def:0]];
  if ([duration length] > 0) [detail addObject:[_texts t:@"history.duration", duration, nil]];
  cell.detailTextLabel.text = [detail componentsJoinedByString:@"  ·  "];
  cell.detailTextLabel.font = [UIFont systemFontOfSize:19];

  cell.backgroundColor = _palette.surface;
  cell.textLabel.backgroundColor = [UIColor clearColor];
  cell.detailTextLabel.backgroundColor = [UIColor clearColor];
  cell.textLabel.textColor = _palette.ink;
  cell.detailTextLabel.textColor = [DBCallHistoryModel rowIsMissed:row]
      ? _palette.danger : _palette.mutedInk;
  return cell;
}

#pragma mark - layout

- (void)layoutSubviews {
  [super layoutSubviews];
  CGSize size = self.bounds.size;
  CGFloat pad = 20;
  _title.frame = CGRectMake(pad, 16, size.width - 2 * pad - 300, 36);
  _markSeen.frame = CGRectMake(size.width - pad - 300, 16, 190, 40);
  _close.frame = CGRectMake(size.width - pad - 100, 16, 100, 40);

  _filterBar.frame = CGRectMake(pad, 64, size.width - 2 * pad, 44);
  CGFloat x = 0;
  for (UIButton *button in _filterButtons) {
    CGSize fit = [button sizeThatFits:CGSizeMake(240, 40)];
    CGFloat width = MIN(240, MAX(88, fit.width));
    button.frame = CGRectMake(x, 2, width, 40);
    x += width + 8;
  }
  _filterBar.contentSize = CGSizeMake(x, 44);

  CGFloat footer = _loadMore.hidden ? 0 : 62;
  _table.frame = CGRectMake(0, 116, size.width, MAX(0, size.height - 116 - footer));
  _empty.frame = CGRectMake(pad, 200, size.width - 2 * pad, 40);
  _loadMore.frame = CGRectMake((size.width - 280) / 2, size.height - 54, 280, 46);
}

@end
