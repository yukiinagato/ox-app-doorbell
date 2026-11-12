#import "DBEditor.h"

#import "../Core/DBConfigUtil.h"
#import "DBChrome.h"

@implementation DBEditField
@synthesize kind = _kind, title = _title, detail = _detail, value = _value, choices = _choices;
@synthesize placeholder = _placeholder, keyboard = _keyboard, destructive = _destructive;
@synthesize confirm = _confirm, checked = _checked, minimum = _minimum, maximum = _maximum;
@synthesize image = _image, onChange = _onChange, page = _page, action = _action;

+ (DBEditField *)kind:(DBEditKind)kind title:(NSString *)title value:(id)value {
  DBEditField *field = [[DBEditField alloc] init];
  field.kind = kind;
  field.title = title;
  field.value = value;
  field.keyboard = UIKeyboardTypeDefault;
  field.minimum = NSIntegerMin;
  field.maximum = NSIntegerMax;
  return field;
}
@end

@implementation DBEditSection
@synthesize title = _title, footer = _footer, fields = _fields;
@synthesize onDelete = _onDelete, onMove = _onMove;

+ (DBEditSection *)title:(NSString *)title fields:(NSArray *)fields {
  DBEditSection *section = [[DBEditSection alloc] init];
  section.title = title;
  section.fields = fields ?: @[];
  return section;
}
@end

@implementation DBEditPage
@synthesize title = _title, build = _build, onAdd = _onAdd, onDone = _onDone;
@synthesize searchable = _searchable, filtersItself = _filtersItself, headerView = _headerView;
@synthesize onAppear = _onAppear, searchPlaceholder = _searchPlaceholder;

+ (DBEditPage *)title:(NSString *)title build:(NSArray *(^)(void))build {
  DBEditPage *page = [[DBEditPage alloc] init];
  page.title = title;
  page.build = build;
  return page;
}
@end

#pragma mark - stock cell metrics

static const CGFloat kDBEditMinRowHeight = 44;
// A switch or a disclosure indicator with the gap the cell keeps beside it.
static const CGFloat kDBEditSwitchWidth = 104;
static const CGFloat kDBEditIndicatorWidth = 30;

CGFloat DBEditCellTextWidth(UITableView *table, CGFloat accessoryWidth, CGFloat imageWidth) {
  CGFloat width = CGRectGetWidth(table.bounds);
  CGFloat chrome = 30;
  if (!DBChromeIsFlat()) {
    // Before iOS 7 a grouped table insets its cells: 10 pt on a phone or a narrow table,
    // 6 % of the width clamped to 31...45 pt on a wide iPad table, plus 10 pt of cell padding
    // on either side.
    CGFloat margin = (!DBChromeIsPad() || width < 400) ? 10 : MAX(31, MIN(45, width * 0.06f));
    chrome = margin * 2 + 20;
  }
  return MAX(80, width - chrome - accessoryWidth - imageWidth);
}

static CGFloat DBEditWrappedHeight(NSString *text, UIFont *font, CGFloat width) {
  if ([text length] == 0) return 0;
  return ceil([text sizeWithFont:font constrainedToSize:CGSizeMake(width, 2000)
                   lineBreakMode:NSLineBreakByWordWrapping].height);
}

DBEditCellLayout DBEditCellLayoutMake(NSString *title, NSString *detail, CGFloat textWidth) {
  // The fonts the stock styles draw with; they are only measured here, never set.
  BOOL flat = DBChromeIsFlat();
  UIFont *titleFont = flat ? [UIFont systemFontOfSize:17] : [UIFont boldSystemFontOfSize:17];
  DBEditCellLayout layout;
  if ([detail length] == 0) {
    layout.style = UITableViewCellStyleDefault;
    layout.height = DBEditWrappedHeight(title, titleFont, textWidth);
  } else {
    CGFloat titleWidth = [title ?: @"" sizeWithFont:titleFont].width;
    CGFloat detailWidth = [detail sizeWithFont:[UIFont systemFontOfSize:17]].width;
    if (titleWidth + detailWidth + 16 <= textWidth) {
      layout.style = UITableViewCellStyleValue1;
      layout.height = 0;
    } else {
      layout.style = UITableViewCellStyleSubtitle;
      layout.height = DBEditWrappedHeight(title, titleFont, textWidth) + 2 +
          DBEditWrappedHeight(detail, [UIFont systemFontOfSize:(flat ? 12 : 14)], textWidth);
    }
  }
  layout.height = MAX(kDBEditMinRowHeight, layout.height + 22);
  return layout;
}

UITableViewCell *DBEditDequeueCell(UITableView *table, UITableViewCellStyle style,
                                   BOOL destructive) {
  NSString *base = style == UITableViewCellStyleValue1 ? @"edit.value"
      : (style == UITableViewCellStyleSubtitle ? @"edit.subtitle" : @"edit.default");
  // A destructive cell is its own reuse pool, so the red never has to be undone on a cell
  // that is reused for an ordinary row.
  NSString *identifier = destructive ? [base stringByAppendingString:@".destructive"] : base;
  UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:identifier];
  if (cell == nil) {
    cell = [[UITableViewCell alloc] initWithStyle:style reuseIdentifier:identifier];
    if (style != UITableViewCellStyleValue1) {
      cell.textLabel.numberOfLines = 0;
      cell.detailTextLabel.numberOfLines = 0;
    }
    if (destructive)
      cell.textLabel.textColor = [UIColor colorWithRed:1 green:0.231f blue:0.188f alpha:1];
  }
  cell.textLabel.text = nil;
  cell.detailTextLabel.text = nil;
  cell.imageView.image = nil;
  cell.accessoryView = nil;
  cell.accessoryType = UITableViewCellAccessoryNone;
  cell.selectionStyle = UITableViewCellSelectionStyleBlue;
  return cell;
}

// UIAlertView with its completion attached, so several prompts never share state.
@interface DBBlockAlert : UIAlertView
@property(nonatomic, copy) void (^completion)(NSInteger button, NSString *text);
@end
@implementation DBBlockAlert
@synthesize completion = _completion;
@end

static UIImage *DBSwatchImage(UIColor *color) {
  CGSize size = CGSizeMake(28, 28);
  UIGraphicsBeginImageContextWithOptions(size, NO, 0);
  [[UIColor colorWithWhite:0.5 alpha:0.6] setFill];
  UIRectFill(CGRectMake(1, 1, 26, 26));
  [color setFill];
  UIRectFill(CGRectMake(2, 2, 24, 24));
  UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  return image;
}

static NSString *DBChoiceLabel(NSArray *choices, id value) {
  for (NSArray *choice in choices) {
    if ([choice count] < 2) continue;
    if ([[choice objectAtIndex:0] isEqual:value]) return [choice objectAtIndex:1];
  }
  return [value isKindOfClass:[NSString class]] ? value : @"";
}

@interface DBEditorView () <UITableViewDataSource, UITableViewDelegate, UIAlertViewDelegate,
                            UISearchBarDelegate>
@end

@implementation DBEditorView {
  DBNavBar *_nav;
  NSMutableArray *_stack;   // DBEditPage
  NSMutableArray *_items;   // the UINavigationItem of each page, parallel to _stack
  NSArray *_sections;
  NSArray *_visible;      // per section, the field indexes shown after filtering
  NSString *_filter;
  UITableView *_table;
  UISearchBar *_search;
  CGFloat _layoutWidth;
}
@synthesize cancelTitle = _cancelTitle, okTitle = _okTitle, confirmTitle = _confirmTitle;
@synthesize setText = _setText, unsetText = _unsetText, customColorTitle = _customColorTitle;
@synthesize searchPlaceholder = _searchPlaceholder, onClose = _onClose;
@synthesize onMessage = _onMessage, onStackChanged = _onStackChanged;

- (id)initWithNavBar:(DBNavBar *)navBar {
  self = [super initWithFrame:CGRectZero];
  if (self) {
    _nav = navBar;
    _stack = [[NSMutableArray alloc] init];
    _items = [[NSMutableArray alloc] init];
    _sections = @[];
    _visible = @[];
    _cancelTitle = @"Cancel";
    _okTitle = @"OK";
    _confirmTitle = @"OK";
    _setText = @"●●●●";
    _unsetText = @"—";
    _customColorTitle = @"#RRGGBB";
    _searchPlaceholder = @"";
    self.backgroundColor = DBChromeScreenBackground();
    self.hidden = YES;

    _table = DBChromeGroupedTable(self, self);
    _table.allowsSelectionDuringEditing = YES;
    [self addSubview:_table];

    _search = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
    _search.delegate = self;
    _search.autocorrectionType = UITextAutocorrectionTypeNo;
    _search.autocapitalizationType = UITextAutocapitalizationTypeNone;
  }
  return self;
}

- (void)dealloc {
  _table.dataSource = nil;
  _table.delegate = nil;
  _search.delegate = nil;
}

#pragma mark - navigation

- (DBEditPage *)currentPage {
  return [_stack lastObject];
}

- (NSUInteger)pageCount {
  return [_stack count];
}

- (NSString *)filterText {
  return _filter ?: @"";
}

- (void)resetPageState {
  _filter = nil;
  _search.text = @"";
  [_table setEditing:NO animated:NO];
}

- (void)pushPage:(DBEditPage *)page {
  if (page == nil) return;
  [self endEditing:YES];
  __weak DBEditorView *weakSelf = self;
  UINavigationItem *item = [_nav pushTitle:page.title onPop:^{ [weakSelf pageLeftByUser]; }];
  [_stack addObject:page];
  [_items addObject:item];
  self.hidden = NO;
  [self resetPageState];
  if (page.onAppear) page.onAppear();
  [self reloadPage];
  [_table setContentOffset:CGPointZero animated:NO];
  if (_onStackChanged) _onStackChanged();
}

// The bar has already dropped the page's item.
- (void)pageLeft {
  [_stack removeLastObject];
  [_items removeLastObject];
  [self resetPageState];
  if ([_stack count] == 0) {
    [self finishClose];
    return;
  }
  [self reloadPage];
  if (_onStackChanged) _onStackChanged();
}

- (void)finishClose {
  self.hidden = YES;
  _sections = @[];
  _visible = @[];
  _table.tableHeaderView = nil;
  [_table reloadData];
  if (_onStackChanged) _onStackChanged();
  if (_onClose) _onClose();
}

- (void)pageLeftByUser {
  if ([_stack count] == 0) return;
  [self endEditing:YES];
  [self pageLeft];
}

- (void)popPage {
  if ([_stack count] == 0) return;
  [self endEditing:YES];
  [_nav pop];
  [self pageLeft];
}

- (void)closeAllPages {
  if ([_stack count] == 0) return;
  [self endEditing:YES];
  while ([_stack count] > 0) {
    [_nav pop];
    [_stack removeLastObject];
    [_items removeLastObject];
  }
  [self resetPageState];
  [self finishClose];
}

- (void)onAdd {
  DBEditPage *page = [self currentPage];
  if (page.onAdd) page.onAdd();
}

- (void)onDone {
  DBEditPage *page = [self currentPage];
  if (page.onDone) page.onDone();
}

- (void)onEdit {
  [_table setEditing:!_table.editing animated:YES];
  [self updateBar];
}

- (BOOL)hasEditableSection {
  for (DBEditSection *section in _sections)
    if (section.onDelete || section.onMove) return YES;
  return NO;
}

- (void)updateBar {
  DBEditPage *page = [self currentPage];
  UINavigationItem *item = [_items lastObject];
  if (page == nil || item == nil) return;
  item.title = page.title;
  // The first item is the rightmost one.
  NSMutableArray *right = [NSMutableArray array];
  if (page.onDone)
    [right addObject:DBChromeSystemBarItem(UIBarButtonSystemItemDone, self, @selector(onDone))];
  if (page.onAdd)
    [right addObject:DBChromeSystemBarItem(UIBarButtonSystemItemAdd, self, @selector(onAdd))];
  if ([self hasEditableSection])
    [right addObject:DBChromeSystemBarItem(_table.editing ? UIBarButtonSystemItemDone
                                                          : UIBarButtonSystemItemEdit,
                                           self, @selector(onEdit))];
  item.rightBarButtonItems = right;
}

- (void)applyHeader {
  DBEditPage *page = [self currentPage];
  UIView *header = page.headerView ?: (page.searchable ? _search : nil);
  CGFloat width = CGRectGetWidth(_table.bounds);
  if (header != nil && width > 0 && CGRectGetWidth(header.frame) != width) {
    header.frame = CGRectMake(0, 0, width, CGRectGetHeight(header.frame));
    _table.tableHeaderView = header;
  } else if (_table.tableHeaderView != header) {
    _table.tableHeaderView = header;
  }
}

- (void)reloadPage {
  DBEditPage *page = [self currentPage];
  if (page == nil) return;
  NSArray *built = page.build ? page.build() : @[];
  _sections = built ?: @[];
  _search.placeholder = [page.searchPlaceholder length] > 0 ? page.searchPlaceholder
                                                            : _searchPlaceholder;
  [self applyHeader];
  [self applyFilter];
  if (_table.editing && ![self hasEditableSection]) [_table setEditing:NO animated:NO];
  [self updateBar];
  [_table reloadData];
}

- (void)applyFilter {
  NSMutableArray *visible = [NSMutableArray array];
  NSString *needle = [self currentPage].filtersItself ? @""
      : [[_filter stringByTrimmingCharactersInSet:
             [NSCharacterSet whitespaceCharacterSet]] lowercaseString];
  for (DBEditSection *section in _sections) {
    NSMutableArray *indexes = [NSMutableArray array];
    for (NSUInteger i = 0; i < [section.fields count]; i++) {
      DBEditField *field = [section.fields objectAtIndex:i];
      if ([needle length] > 0) {
        NSString *hay = [[NSString stringWithFormat:@"%@ %@", field.title ?: @"",
                             [self detailFor:field] ?: @""] lowercaseString];
        if ([hay rangeOfString:needle].location == NSNotFound) continue;
      }
      [indexes addObject:[NSNumber numberWithUnsignedInteger:i]];
    }
    [visible addObject:indexes];
  }
  _visible = visible;
}

#pragma mark - layout

- (void)layoutSubviews {
  [super layoutSubviews];
  _table.frame = self.bounds;
  CGFloat width = CGRectGetWidth(self.bounds);
  if (width == _layoutWidth) return;
  // Row heights and the header follow the width.
  _layoutWidth = width;
  [self applyHeader];
  [_table reloadData];
}

#pragma mark - values

- (NSString *)detailFor:(DBEditField *)field {
  if (field.detail) return field.detail;
  id value = field.value;
  switch (field.kind) {
    case DBEditKindSecret:
      return [value boolValue] ? _setText : _unsetText;
    case DBEditKindChoice:
      return DBChoiceLabel(field.choices, value);
    case DBEditKindMulti: {
      if (![value isKindOfClass:[NSArray class]]) return @"";
      NSMutableArray *labels = [NSMutableArray array];
      for (id item in (NSArray *)value) [labels addObject:DBChoiceLabel(field.choices, item)];
      return [labels componentsJoinedByString:@", "];
    }
    case DBEditKindNumber:
      return [value respondsToSelector:@selector(stringValue)] ? [value stringValue]
          : ([value isKindOfClass:[NSString class]] ? value : @"");
    case DBEditKindBool:
    case DBEditKindPage:
    case DBEditKindAction:
      return @"";
    default:
      return [value isKindOfClass:[NSString class]] ? value
          : ([value respondsToSelector:@selector(stringValue)] ? [value stringValue] : @"");
  }
}

- (DBEditField *)fieldAt:(NSIndexPath *)path {
  if (path.section < 0 || path.section >= (NSInteger)[_sections count] ||
      path.section >= (NSInteger)[_visible count]) return nil;
  DBEditSection *section = [_sections objectAtIndex:(NSUInteger)path.section];
  NSArray *indexes = [_visible objectAtIndex:(NSUInteger)path.section];
  if (path.row < 0 || path.row >= (NSInteger)[indexes count]) return nil;
  NSUInteger index = [[indexes objectAtIndex:(NSUInteger)path.row] unsignedIntegerValue];
  return index < [section.fields count] ? [section.fields objectAtIndex:index] : nil;
}

- (void)apply:(DBEditField *)field value:(id)value {
  if (field.onChange == nil) return;
  if (field.onChange(value)) [self reloadPage];
}

// Kinds that open a page of their own carry the disclosure indicator.
- (BOOL)opensPage:(DBEditField *)field {
  switch (field.kind) {
    case DBEditKindChoice:
    case DBEditKindMulti:
    case DBEditKindTime:
    case DBEditKindColor:
    case DBEditKindPage:
      return YES;
    default:
      return NO;
  }
}

- (DBEditCellLayout)layoutFor:(DBEditField *)field inTable:(UITableView *)tableView {
  CGFloat accessory = field.kind == DBEditKindBool ? kDBEditSwitchWidth
      : (([self opensPage:field] || field.checked) ? kDBEditIndicatorWidth : 0);
  CGFloat image = field.image ? field.image.size.width + 10 : 0;
  DBEditCellLayout layout = DBEditCellLayoutMake(
      field.title, [self detailFor:field], DBEditCellTextWidth(tableView, accessory, image));
  if (field.image) layout.height = MAX(layout.height, field.image.size.height + 16);
  return layout;
}

#pragma mark - table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  (void)tableView;
  return (NSInteger)[_sections count];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  (void)tableView;
  return section < (NSInteger)[_visible count]
      ? (NSInteger)[[_visible objectAtIndex:(NSUInteger)section] count] : 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
  (void)tableView;
  NSString *title = [(DBEditSection *)[_sections objectAtIndex:(NSUInteger)section] title];
  return [title length] > 0 ? title : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
  (void)tableView;
  NSString *footer = [(DBEditSection *)[_sections objectAtIndex:(NSUInteger)section] footer];
  return [footer length] > 0 ? footer : nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
  return [self layoutFor:[self fieldAt:indexPath] inTable:tableView].height;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  DBEditField *field = [self fieldAt:indexPath];
  DBEditCellLayout layout = [self layoutFor:field inTable:tableView];
  UITableViewCell *cell = DBEditDequeueCell(tableView, layout.style, field.destructive);
  cell.textLabel.text = field.title;
  cell.detailTextLabel.text = [self detailFor:field];
  cell.imageView.image = field.image;
  if (field.kind == DBEditKindBool) {
    UISwitch *toggle = [[UISwitch alloc] init];
    toggle.on = [field.value boolValue];
    toggle.tag = indexPath.section * 10000 + indexPath.row;
    toggle.accessibilityLabel = field.title;
    [toggle addTarget:self action:@selector(onSwitch:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
  } else if (field.kind == DBEditKindInfo) {
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
  } else if ([self opensPage:field]) {
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
  }
  if (field.checked) cell.accessoryType = UITableViewCellAccessoryCheckmark;
  return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
  (void)tableView;
  DBEditSection *section = [_sections objectAtIndex:(NSUInteger)indexPath.section];
  return section.onDelete != nil || section.onMove != nil;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView
           editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
  (void)tableView;
  DBEditSection *section = [_sections objectAtIndex:(NSUInteger)indexPath.section];
  return section.onDelete ? UITableViewCellEditingStyleDelete : UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tableView
    shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath {
  return [self tableView:tableView editingStyleForRowAtIndexPath:indexPath] !=
      UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
  (void)tableView;
  DBEditSection *section = [_sections objectAtIndex:(NSUInteger)indexPath.section];
  return section.onMove != nil && [_filter length] == 0;
}

- (NSIndexPath *)tableView:(UITableView *)tableView
    targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)source
                         toProposedIndexPath:(NSIndexPath *)proposed {
  if (proposed.section == source.section) return proposed;
  NSInteger last = [self tableView:tableView numberOfRowsInSection:source.section] - 1;
  return [NSIndexPath indexPathForRow:(proposed.section < source.section ? 0 : last)
                            inSection:source.section];
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)source
      toIndexPath:(NSIndexPath *)destination {
  (void)tableView;
  DBEditSection *section = [_sections objectAtIndex:(NSUInteger)source.section];
  if (section.onMove && source.row != destination.row) section.onMove(source.row, destination.row);
  __weak DBEditorView *weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf reloadPage]; });
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style
    forRowAtIndexPath:(NSIndexPath *)indexPath {
  (void)tableView;
  if (style != UITableViewCellEditingStyleDelete) return;
  DBEditSection *section = [_sections objectAtIndex:(NSUInteger)indexPath.section];
  NSArray *indexes = [_visible objectAtIndex:(NSUInteger)indexPath.section];
  if (section.onDelete == nil || indexPath.row >= (NSInteger)[indexes count]) return;
  NSInteger index = (NSInteger)[[indexes objectAtIndex:(NSUInteger)indexPath.row] integerValue];
  DBEditField *field = [self fieldAt:indexPath];
  __weak DBEditorView *weakSelf = self;
  [self confirmTitle:field.title message:nil then:^{
    if (section.onDelete(index)) [weakSelf reloadPage];
  }];
}

- (void)onSwitch:(UISwitch *)sender {
  NSIndexPath *path = [NSIndexPath indexPathForRow:sender.tag % 10000 inSection:sender.tag / 10000];
  DBEditField *field = [self fieldAt:path];
  if (field == nil) return;
  BOOL on = sender.on;
  __weak DBEditorView *weakSelf = self;
  // Rebuilding the table inside the switch's own event tears the control down mid-animation.
  dispatch_async(dispatch_get_main_queue(), ^{
    [weakSelf apply:field value:[NSNumber numberWithBool:on]];
  });
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  DBEditField *field = [self fieldAt:indexPath];
  if (field == nil) return;
  [_search resignFirstResponder];
  switch (field.kind) {
    case DBEditKindText:
    case DBEditKindNumber:
    case DBEditKindSecret: {
      BOOL secret = field.kind == DBEditKindSecret;
      NSString *current = secret ? @"" : [self detailFor:field];
      UIKeyboardType keyboard = field.kind == DBEditKindNumber ? UIKeyboardTypeNumberPad
                                                               : field.keyboard;
      __weak DBEditorView *weakSelf = self;
      [self promptTitle:field.title value:current placeholder:field.placeholder keyboard:keyboard
                 secure:secret then:^(NSString *text) {
        DBEditorView *editor = weakSelf;
        if (!editor) return;
        if (field.kind == DBEditKindNumber) {
          NSString *trimmed = [text stringByTrimmingCharactersInSet:
              [NSCharacterSet whitespaceCharacterSet]];
          NSInteger number = [trimmed integerValue];
          if ([trimmed length] == 0 || number < field.minimum || number > field.maximum) {
            [editor showMessage:[NSString stringWithFormat:@"%ld – %ld", (long)field.minimum,
                                                           (long)field.maximum]];
            return;
          }
          [editor apply:field value:[NSNumber numberWithInteger:number]];
        } else {
          [editor apply:field value:text];
        }
      }];
      break;
    }
    case DBEditKindBool:
      [self apply:field value:[NSNumber numberWithBool:![field.value boolValue]]];
      break;
    case DBEditKindChoice:
    case DBEditKindMulti:
      [self pushPage:[self choicePageFor:field]];
      break;
    case DBEditKindColor:
      [self pushPage:[self colorPageFor:field]];
      break;
    case DBEditKindTime:
      [self pushPage:[self timePageFor:field]];
      break;
    case DBEditKindPage:
      if (field.page) [self pushPage:field.page()];
      break;
    case DBEditKindAction:
      if (field.action == nil) break;
      if (field.confirm || field.destructive) {
        void (^action)(void) = field.action;
        [self confirmTitle:field.title message:nil then:action];
      } else {
        field.action();
      }
      break;
    default:
      break;
  }
}

#pragma mark - generated pages

- (DBEditPage *)choicePageFor:(DBEditField *)field {
  __weak DBEditorView *weakSelf = self;
  __block id current = field.value;
  BOOL multi = field.kind == DBEditKindMulti;
  DBEditPage *page = [DBEditPage title:field.title build:^NSArray *{
    NSMutableArray *rows = [NSMutableArray array];
    for (NSArray *choice in field.choices) {
      if ([choice count] < 2) continue;
      id value = [choice objectAtIndex:0];
      DBEditField *row = [DBEditField kind:DBEditKindAction title:[choice objectAtIndex:1]
                                     value:value];
      row.checked = multi ? ([current isKindOfClass:[NSArray class]] &&
                             [(NSArray *)current containsObject:value])
                          : [value isEqual:current];
      row.action = ^{
        DBEditorView *editor = weakSelf;
        if (!editor) return;
        if (multi) {
          NSMutableArray *next = [NSMutableArray arrayWithArray:
              [current isKindOfClass:[NSArray class]] ? current : @[]];
          if ([next containsObject:value]) [next removeObject:value];
          else [next addObject:value];
          if (field.onChange && field.onChange(next)) current = next;
          [editor reloadPage];
        } else {
          if (field.onChange && field.onChange(value)) {
            current = value;
            [editor popPage];
          }
        }
      };
      [rows addObject:row];
    }
    return @[ [DBEditSection title:nil fields:rows] ];
  }];
  page.searchable = [field.choices count] > 12;
  return page;
}

- (DBEditPage *)colorPageFor:(DBEditField *)field {
  __weak DBEditorView *weakSelf = self;
  NSArray *swatches = @[ @"#101418", @"#000000", @"#1F2933", @"#2E3440", @"#3B4252", @"#102A43",
                         @"#0B3D2E", @"#3E2723", @"#4A148C", @"#8F1010", @"#F5F5F0", @"#FFFFFF",
                         @"#E3F2FD", @"#FFF8E1", @"#FFD166", @"#4DA3FF" ];
  return [DBEditPage title:field.title build:^NSArray *{
    NSMutableArray *rows = [NSMutableArray array];
    DBEditField *custom = [DBEditField kind:DBEditKindText title:weakSelf.customColorTitle
                                      value:field.value];
    custom.placeholder = @"#RRGGBB";
    custom.keyboard = UIKeyboardTypeASCIICapable;
    UIColor *now = [DBConfigUtil parseHexColor:field.value];
    if (now) custom.image = DBSwatchImage(now);
    custom.onChange = ^BOOL(id value) {
      NSString *hex = [[value description] uppercaseString];
      if (![hex hasPrefix:@"#"]) hex = [@"#" stringByAppendingString:hex];
      NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:
          @"#0123456789ABCDEF"] invertedSet];
      if ([hex length] != 7 || [hex rangeOfCharacterFromSet:bad].location != NSNotFound) {
        [weakSelf showMessage:@"#RRGGBB"];
        return NO;
      }
      if (field.onChange && field.onChange(hex)) {
        field.value = hex;
        return YES;
      }
      return NO;
    };
    [rows addObject:custom];
    NSMutableArray *swatchRows = [NSMutableArray array];
    for (NSString *hex in swatches) {
      DBEditField *row = [DBEditField kind:DBEditKindAction title:hex value:hex];
      row.checked = [[field.value description] caseInsensitiveCompare:hex] == NSOrderedSame;
      row.image = DBSwatchImage([DBConfigUtil parseHexColor:hex]);
      row.action = ^{
        if (field.onChange && field.onChange(hex)) field.value = hex;
        [weakSelf reloadPage];
      };
      [swatchRows addObject:row];
    }
    return @[ [DBEditSection title:nil fields:rows], [DBEditSection title:nil fields:swatchRows] ];
  }];
}

// The picker sits above an empty table; Done writes the time and the bar's back button
// leaves it unchanged.
- (DBEditPage *)timePageFor:(DBEditField *)field {
  UIDatePicker *picker = [[UIDatePicker alloc] init];
  picker.datePickerMode = UIDatePickerModeTime;
  // A fixed zone and a 24-hour locale: the picker edits a wall-clock "HH:MM"
  // that Core interprets in the cluster zone, never an instant.
  picker.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
  picker.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_GB"];
  picker.minuteInterval = 5;
  NSString *text = [field.value isKindOfClass:[NSString class]] ? field.value : @"00:00";
  NSArray *parts = [text componentsSeparatedByString:@":"];
  NSInteger hour = [parts count] > 0 ? [[parts objectAtIndex:0] integerValue] : 0;
  NSInteger minute = [parts count] > 1 ? [[parts objectAtIndex:1] integerValue] : 0;
  picker.date = [NSDate dateWithTimeIntervalSince1970:(hour * 60 + minute) * 60];

  CGSize size = picker.bounds.size;
  if (size.width <= 0 || size.height <= 0) size = CGSizeMake(320, 216);
  UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, size.width, size.height + 20)];
  header.backgroundColor = [UIColor clearColor];
  picker.frame = CGRectMake(0, 10, size.width, size.height);
  picker.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                            UIViewAutoresizingFlexibleRightMargin;
  [header addSubview:picker];

  DBEditPage *page = [DBEditPage title:field.title build:^NSArray *{ return @[]; }];
  page.headerView = header;
  __weak DBEditorView *weakSelf = self;
  page.onDone = ^{
    DBEditorView *editor = weakSelf;
    if (!editor) return;
    long seconds = (long)fmod([picker.date timeIntervalSince1970], 86400.0);
    if (seconds < 0) seconds += 86400;
    NSString *value = [NSString stringWithFormat:@"%02ld:%02ld", seconds / 3600,
                                                 (seconds / 60) % 60];
    [editor popPage];
    [editor apply:field value:value];
  };
  return page;
}

#pragma mark - search

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
  (void)searchBar;
  _filter = [searchText copy];
  DBEditPage *page = [self currentPage];
  if (page.filtersItself) _sections = (page.build ? page.build() : nil) ?: @[];
  [self applyFilter];
  [_table reloadData];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
  [searchBar resignFirstResponder];
}

#pragma mark - prompts

- (void)promptTitle:(NSString *)title value:(NSString *)value placeholder:(NSString *)placeholder
           keyboard:(UIKeyboardType)keyboard secure:(BOOL)secure
               then:(void (^)(NSString *text))then {
  DBBlockAlert *alert = [[DBBlockAlert alloc] initWithTitle:title message:nil delegate:self
                                          cancelButtonTitle:_cancelTitle
                                          otherButtonTitles:_okTitle, nil];
  alert.alertViewStyle = secure ? UIAlertViewStyleSecureTextInput : UIAlertViewStylePlainTextInput;
  UITextField *field = [alert textFieldAtIndex:0];
  field.text = value ?: @"";
  field.placeholder = placeholder;
  field.keyboardType = keyboard;
  field.autocorrectionType = UITextAutocorrectionTypeNo;
  field.autocapitalizationType = UITextAutocapitalizationTypeNone;
  field.clearButtonMode = UITextFieldViewModeWhileEditing;
  alert.completion = ^(NSInteger button, NSString *text) {
    if (button == 1 && then) then(text ?: @"");
  };
  [alert show];
}

- (void)confirmTitle:(NSString *)title message:(NSString *)message then:(void (^)(void))then {
  DBBlockAlert *alert = [[DBBlockAlert alloc] initWithTitle:title message:message delegate:self
                                          cancelButtonTitle:_cancelTitle
                                          otherButtonTitles:_confirmTitle, nil];
  alert.completion = ^(NSInteger button, NSString *text) {
    (void)text;
    if (button == 1 && then) then();
  };
  [alert show];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
  if (![alertView isKindOfClass:[DBBlockAlert class]]) return;
  DBBlockAlert *alert = (DBBlockAlert *)alertView;
  NSString *text = nil;
  if (alert.alertViewStyle != UIAlertViewStyleDefault) text = [alert textFieldAtIndex:0].text;
  void (^completion)(NSInteger, NSString *) = alert.completion;
  alert.completion = nil;
  if (completion) completion(buttonIndex, text);
}

- (void)showMessage:(NSString *)message {
  if ([message length] == 0) return;
  if (_onMessage) {
    _onMessage(message);
    return;
  }
  [[[UIAlertView alloc] initWithTitle:nil message:message delegate:nil
                    cancelButtonTitle:_okTitle otherButtonTitles:nil] show];
}

@end
