#import "DBEditor.h"

#import "../Core/DBConfigUtil.h"
#import "DBWidgets.h"

@implementation DBEditField
@synthesize kind = _kind, title = _title, detail = _detail, value = _value, choices = _choices;
@synthesize placeholder = _placeholder, keyboard = _keyboard, destructive = _destructive;
@synthesize confirm = _confirm, minimum = _minimum, maximum = _maximum, image = _image;
@synthesize onChange = _onChange, page = _page, action = _action;

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
@synthesize title = _title, build = _build, onAdd = _onAdd, searchable = _searchable;
@synthesize onAppear = _onAppear;

+ (DBEditPage *)title:(NSString *)title build:(NSArray *(^)(void))build {
  DBEditPage *page = [[DBEditPage alloc] init];
  page.title = title;
  page.build = build;
  return page;
}
@end

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
  UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(1, 1, 26, 26)
                                                  cornerRadius:6];
  [color setFill];
  [path fill];
  [[UIColor colorWithWhite:0.5 alpha:0.6] setStroke];
  path.lineWidth = 1;
  [path stroke];
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
  NSMutableArray *_stack;
  NSArray *_sections;
  NSArray *_visible;      // per section, the field indexes shown after filtering
  NSString *_filter;
  UIView *_bar;
  UIButton *_back;
  UIButton *_add;
  UIButton *_edit;
  UILabel *_title;
  UITableView *_table;
  UISearchBar *_search;
  UILabel *_message;
  UIView *_timeOverlay;
  UIDatePicker *_timePicker;
  UIButton *_timeOk;
  UIButton *_timeCancel;
  DBEditField *_timeField;
  DBUiPalette *_palette;
}
@synthesize backTitle = _backTitle, doneTitle = _doneTitle, editTitle = _editTitle;
@synthesize cancelTitle = _cancelTitle, okTitle = _okTitle, confirmTitle = _confirmTitle;
@synthesize setText = _setText, unsetText = _unsetText, customColorTitle = _customColorTitle;
@synthesize searchPlaceholder = _searchPlaceholder, onClose = _onClose;

- (UIButton *)barButton:(SEL)action {
  UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
  button.titleLabel.font = [UIFont boldSystemFontOfSize:18];
  button.layer.cornerRadius = 8;
  button.clipsToBounds = YES;
  [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
  [_bar addSubview:button];
  return button;
}

- (id)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    _stack = [[NSMutableArray alloc] init];
    _sections = @[];
    _visible = @[];
    _backTitle = @"‹";
    _doneTitle = @"Done";
    _editTitle = @"Edit";
    _cancelTitle = @"Cancel";
    _okTitle = @"OK";
    _confirmTitle = @"OK";
    _setText = @"●●●●";
    _unsetText = @"—";
    _customColorTitle = @"#RRGGBB";
    _searchPlaceholder = @"";
    _bar = [[UIView alloc] init];
    [self addSubview:_bar];
    _back = [self barButton:@selector(onBack)];
    _add = [self barButton:@selector(onAdd)];
    [_add setTitle:@"+" forState:UIControlStateNormal];
    _add.titleLabel.font = [UIFont boldSystemFontOfSize:28];
    _add.accessibilityLabel = @"add";
    _edit = [self barButton:@selector(onEdit)];
    _title = [[UILabel alloc] init];
    _title.backgroundColor = [UIColor clearColor];
    _title.font = [UIFont boldSystemFontOfSize:22];
    _title.textAlignment = NSTextAlignmentCenter;
    _title.adjustsFontSizeToFitWidth = YES;
    _title.minimumFontSize = 14;
    [_bar addSubview:_title];

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    _table.dataSource = self;
    _table.delegate = self;
    _table.allowsSelectionDuringEditing = YES;
    _table.backgroundView = [[UIView alloc] init];
    [self addSubview:_table];

    _search = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
    _search.delegate = self;
    _search.autocorrectionType = UITextAutocorrectionTypeNo;
    _search.autocapitalizationType = UITextAutocapitalizationTypeNone;

    _message = [[UILabel alloc] init];
    _message.textAlignment = NSTextAlignmentCenter;
    _message.font = [UIFont boldSystemFontOfSize:16];
    _message.numberOfLines = 2;
    _message.layer.cornerRadius = 10;
    _message.clipsToBounds = YES;
    _message.alpha = 0;
    [self addSubview:_message];

    _timeOverlay = [[UIView alloc] init];
    _timeOverlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.7];
    _timeOverlay.hidden = YES;
    [self addSubview:_timeOverlay];
    _timePicker = [[UIDatePicker alloc] init];
    _timePicker.datePickerMode = UIDatePickerModeTime;
    _timePicker.backgroundColor = [UIColor whiteColor];
    // A fixed zone and a 24-hour locale: the picker edits a wall-clock "HH:MM"
    // that Core interprets in the cluster zone, never an instant.
    _timePicker.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    _timePicker.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_GB"];
    _timePicker.minuteInterval = 5;
    [_timeOverlay addSubview:_timePicker];
    _timeOk = [UIButton buttonWithType:UIButtonTypeCustom];
    _timeOk.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    _timeOk.layer.cornerRadius = 8;
    _timeOk.clipsToBounds = YES;
    [_timeOk addTarget:self action:@selector(onTimeOk) forControlEvents:UIControlEventTouchUpInside];
    [_timeOverlay addSubview:_timeOk];
    _timeCancel = [UIButton buttonWithType:UIButtonTypeCustom];
    _timeCancel.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    _timeCancel.layer.cornerRadius = 8;
    _timeCancel.clipsToBounds = YES;
    [_timeCancel addTarget:self action:@selector(onTimeCancel)
          forControlEvents:UIControlEventTouchUpInside];
    [_timeOverlay addSubview:_timeCancel];
  }
  return self;
}

- (void)applyPalette:(DBUiPalette *)palette {
  _palette = palette;
  self.backgroundColor = palette.surface ?: [UIColor blackColor];
  _bar.backgroundColor = palette.surface;
  _title.textColor = palette.ink;
  for (UIButton *button in @[ _back, _add, _edit, _timeOk, _timeCancel ]) {
    button.backgroundColor = palette.elevated;
    [button setTitleColor:palette.ink forState:UIControlStateNormal];
  }
  _table.backgroundColor = palette.surface;
  _table.backgroundView.backgroundColor = palette.surface;
  _table.separatorColor = palette.separator;
  _message.backgroundColor = palette.plate;
  _message.textColor = palette.ink;
  [_table reloadData];
}

#pragma mark - navigation

- (DBEditPage *)currentPage {
  return [_stack lastObject];
}

- (void)pushPage:(DBEditPage *)page {
  if (page == nil) return;
  [_stack addObject:page];
  _filter = nil;
  _search.text = @"";
  [_table setEditing:NO animated:NO];
  if (page.onAppear) page.onAppear();
  [self reloadPage];
  [_table setContentOffset:CGPointZero animated:NO];
}

- (void)popPage {
  [self endEditing:YES];
  if ([_stack count] > 0) [_stack removeLastObject];
  if ([_stack count] == 0) {
    self.hidden = YES;
    if (_onClose) _onClose();
    return;
  }
  _filter = nil;
  _search.text = @"";
  [_table setEditing:NO animated:NO];
  [self reloadPage];
}

- (void)onBack {
  [self popPage];
}

- (void)onAdd {
  DBEditPage *page = [self currentPage];
  if (page.onAdd) page.onAdd();
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
  _title.text = page.title;
  [_back setTitle:[NSString stringWithFormat:@"‹ %@", _backTitle] forState:UIControlStateNormal];
  _add.hidden = page.onAdd == nil;
  _edit.hidden = ![self hasEditableSection];
  [_edit setTitle:(_table.editing ? _doneTitle : _editTitle) forState:UIControlStateNormal];
  [self setNeedsLayout];
}

- (void)reloadPage {
  DBEditPage *page = [self currentPage];
  NSArray *built = page.build ? page.build() : @[];
  _sections = built ?: @[];
  _table.tableHeaderView = page.searchable ? _search : nil;
  _search.placeholder = _searchPlaceholder;
  [self applyFilter];
  [self updateBar];
  if (_table.editing && ![self hasEditableSection]) [_table setEditing:NO animated:NO];
  [_table reloadData];
}

- (void)applyFilter {
  NSMutableArray *visible = [NSMutableArray array];
  NSString *needle = [[_filter stringByTrimmingCharactersInSet:
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
  CGSize size = self.bounds.size;
  CGFloat pad = 16;
  _bar.frame = CGRectMake(0, 0, size.width, 64);
  CGSize backSize = [[_back titleForState:UIControlStateNormal] sizeWithFont:_back.titleLabel.font];
  CGFloat backWidth = MIN(220, MAX(88, ceil(backSize.width) + 28));
  _back.frame = CGRectMake(pad, 10, backWidth, 44);
  CGFloat right = size.width - pad;
  if (!_add.hidden) {
    _add.frame = CGRectMake(right - 56, 10, 56, 44);
    right -= 56 + 10;
  }
  if (!_edit.hidden) {
    CGSize editSize = [[_edit titleForState:UIControlStateNormal] sizeWithFont:_edit.titleLabel.font];
    CGFloat editWidth = MAX(80, ceil(editSize.width) + 28);
    _edit.frame = CGRectMake(right - editWidth, 10, editWidth, 44);
    right -= editWidth + 10;
  }
  CGFloat titleInset = MAX(backWidth + pad + 10, size.width - right);
  _title.frame = CGRectMake(titleInset, 16, MAX(40, size.width - titleInset * 2), 32);
  _table.frame = CGRectMake(0, 64, size.width, MAX(0, size.height - 64));
  _table.contentInset = UIEdgeInsetsZero;
  _search.frame = CGRectMake(0, 0, size.width, 44);
  _message.frame = CGRectMake(floor(size.width * 0.15), size.height - 96, floor(size.width * 0.7), 60);

  _timeOverlay.frame = self.bounds;
  CGFloat pickerWidth = MIN(360, size.width - 40);
  CGSize pickerSize = [_timePicker sizeThatFits:CGSizeMake(pickerWidth, 216)];
  CGFloat pickerHeight = pickerSize.height > 0 ? pickerSize.height : 216;
  CGFloat top = MAX(40, floor((size.height - pickerHeight - 70) / 2));
  _timePicker.frame = CGRectMake(floor((size.width - pickerWidth) / 2), top, pickerWidth,
                                 pickerHeight);
  CGFloat buttonWidth = floor((pickerWidth - 12) / 2);
  _timeCancel.frame = CGRectMake(CGRectGetMinX(_timePicker.frame), top + pickerHeight + 16,
                                 buttonWidth, 48);
  _timeOk.frame = CGRectMake(CGRectGetMaxX(_timeCancel.frame) + 12, top + pickerHeight + 16,
                             buttonWidth, 48);
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
  if (path.section < 0 || path.section >= (NSInteger)[_sections count]) return nil;
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

#pragma mark - table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return (NSInteger)[_sections count];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  return section < (NSInteger)[_visible count]
      ? (NSInteger)[[_visible objectAtIndex:(NSUInteger)section] count] : 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
  return [(DBEditSection *)[_sections objectAtIndex:(NSUInteger)section] title];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
  return [(DBEditSection *)[_sections objectAtIndex:(NSUInteger)section] footer];
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
  NSString *text = [self tableView:tableView titleForHeaderInSection:section];
  if ([text length] == 0) return nil;
  UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tableView.bounds.size.width, 40)];
  UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(48, 12, tableView.bounds.size.width - 96, 24)];
  label.backgroundColor = [UIColor clearColor];
  label.font = [UIFont boldSystemFontOfSize:16];
  label.textColor = _palette.mutedInk ?: [UIColor grayColor];
  label.text = text;
  label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  [header addSubview:label];
  return header;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
  return [[self tableView:tableView titleForHeaderInSection:section] length] > 0 ? 40 : 12;
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
  NSString *text = [self tableView:tableView titleForFooterInSection:section];
  if ([text length] == 0) return nil;
  CGFloat width = tableView.bounds.size.width - 96;
  CGSize fit = [text sizeWithFont:[UIFont systemFontOfSize:14]
                constrainedToSize:CGSizeMake(width, 400) lineBreakMode:NSLineBreakByWordWrapping];
  UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tableView.bounds.size.width,
                                                             ceil(fit.height) + 16)];
  UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(48, 6, width, ceil(fit.height))];
  label.backgroundColor = [UIColor clearColor];
  label.font = [UIFont systemFontOfSize:14];
  label.numberOfLines = 0;
  label.textColor = _palette.mutedInk ?: [UIColor grayColor];
  label.text = text;
  [footer addSubview:label];
  return footer;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
  NSString *text = [self tableView:tableView titleForFooterInSection:section];
  if ([text length] == 0) return 8;
  CGSize fit = [text sizeWithFont:[UIFont systemFontOfSize:14]
                constrainedToSize:CGSizeMake(tableView.bounds.size.width - 96, 400)
                    lineBreakMode:NSLineBreakByWordWrapping];
  return ceil(fit.height) + 16;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
  DBEditField *field = [self fieldAt:indexPath];
  NSString *detail = [self detailFor:field];
  CGFloat width = tableView.bounds.size.width - 140;
  CGSize titleSize = [field.title ?: @"" sizeWithFont:[UIFont systemFontOfSize:18]
                                  constrainedToSize:CGSizeMake(width * 0.55, 400)
                                      lineBreakMode:NSLineBreakByWordWrapping];
  CGSize detailSize = [detail ?: @"" sizeWithFont:[UIFont systemFontOfSize:16]
                              constrainedToSize:CGSizeMake(width * 0.45, 400)
                                  lineBreakMode:NSLineBreakByWordWrapping];
  CGFloat height = MAX(54, ceil(MAX(titleSize.height, detailSize.height)) + 26);
  if (field.image) height = MAX(height, field.image.size.height + 16);
  return height;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  static NSString *identifier = @"edit";
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
  if (cell == nil) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                  reuseIdentifier:identifier];
    cell.textLabel.font = [UIFont systemFontOfSize:18];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:16];
    cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.backgroundColor = [UIColor clearColor];
    cell.detailTextLabel.backgroundColor = [UIColor clearColor];
  }
  DBEditField *field = [self fieldAt:indexPath];
  cell.textLabel.text = field.title;
  cell.detailTextLabel.text = [self detailFor:field];
  cell.imageView.image = field.image;
  cell.backgroundColor = _palette.elevated;
  cell.textLabel.textColor = field.destructive ? (_palette.danger ?: [UIColor redColor])
      : (field.kind == DBEditKindAction ? (_palette.accent ?: _palette.ink) : _palette.ink);
  cell.detailTextLabel.textColor = _palette.mutedInk;
  cell.accessoryView = nil;
  cell.accessoryType = UITableViewCellAccessoryNone;
  cell.selectionStyle = UITableViewCellSelectionStyleBlue;
  if (field.kind == DBEditKindBool) {
    UISwitch *toggle = [[UISwitch alloc] init];
    toggle.on = [field.value boolValue];
    toggle.tag = indexPath.section * 10000 + indexPath.row;
    [toggle addTarget:self action:@selector(onSwitch:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
  } else if (field.kind == DBEditKindInfo) {
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
  } else if (field.kind != DBEditKindAction) {
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
  }
  return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
  DBEditSection *section = [_sections objectAtIndex:(NSUInteger)indexPath.section];
  return section.onDelete != nil || section.onMove != nil;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView
           editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
  DBEditSection *section = [_sections objectAtIndex:(NSUInteger)indexPath.section];
  return section.onDelete ? UITableViewCellEditingStyleDelete : UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath {
  return [self tableView:tableView editingStyleForRowAtIndexPath:indexPath] !=
      UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
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
  DBEditSection *section = [_sections objectAtIndex:(NSUInteger)source.section];
  if (section.onMove && source.row != destination.row) section.onMove(source.row, destination.row);
  __weak DBEditorView *weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf reloadPage]; });
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style
    forRowAtIndexPath:(NSIndexPath *)indexPath {
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
      [self presentTimeFor:field];
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
      BOOL selected = multi ? ([current isKindOfClass:[NSArray class]] &&
                               [(NSArray *)current containsObject:value])
                            : [value isEqual:current];
      DBEditField *row = [DBEditField kind:DBEditKindAction
                                     title:[NSString stringWithFormat:@"%@%@",
                                               selected ? @"✓  " : @"", [choice objectAtIndex:1]]
                                     value:value];
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
      BOOL selected = [[field.value description] caseInsensitiveCompare:hex] == NSOrderedSame;
      DBEditField *row = [DBEditField kind:DBEditKindAction
                                     title:[NSString stringWithFormat:@"%@%@",
                                               selected ? @"✓  " : @"", hex]
                                     value:hex];
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

#pragma mark - time

- (void)presentTimeFor:(DBEditField *)field {
  _timeField = field;
  NSString *text = [field.value isKindOfClass:[NSString class]] ? field.value : @"00:00";
  NSArray *parts = [text componentsSeparatedByString:@":"];
  NSInteger hour = [parts count] > 0 ? [[parts objectAtIndex:0] integerValue] : 0;
  NSInteger minute = [parts count] > 1 ? [[parts objectAtIndex:1] integerValue] : 0;
  _timePicker.date = [NSDate dateWithTimeIntervalSince1970:(hour * 60 + minute) * 60];
  [_timeOk setTitle:_okTitle forState:UIControlStateNormal];
  [_timeCancel setTitle:_cancelTitle forState:UIControlStateNormal];
  _timeOverlay.hidden = NO;
  [self bringSubviewToFront:_timeOverlay];
  [self setNeedsLayout];
}

- (void)onTimeOk {
  _timeOverlay.hidden = YES;
  DBEditField *field = _timeField;
  _timeField = nil;
  if (field == nil) return;
  long seconds = (long)fmod([_timePicker.date timeIntervalSince1970], 86400.0);
  if (seconds < 0) seconds += 86400;
  NSString *value = [NSString stringWithFormat:@"%02ld:%02ld", seconds / 3600, (seconds / 60) % 60];
  [self apply:field value:value];
}

- (void)onTimeCancel {
  _timeOverlay.hidden = YES;
  _timeField = nil;
}

#pragma mark - search

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
  _filter = [searchText copy];
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
  _message.text = message;
  [self bringSubviewToFront:_message];
  [UIView animateWithDuration:0.2 animations:^{ self->_message.alpha = 0.96; }];
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideMessage) object:nil];
  [self performSelector:@selector(hideMessage) withObject:nil afterDelay:2.4];
}

- (void)hideMessage {
  [UIView animateWithDuration:0.3 animations:^{ self->_message.alpha = 0; }];
}

@end
