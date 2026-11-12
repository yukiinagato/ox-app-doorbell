#import "DBNoticeDialog.h"

#import "../Core/DBConfigUtil.h"
#import "../Core/DBCoreBridge.h"
#import "../Core/DBNoticeModel.h"
#import "../Core/DBTexts.h"
#import "DBChrome.h"
#import "DBRouter.h"

static NSString *const kSectionTarget = @"target";
static NSString *const kSectionPresets = @"presets";
static NSString *const kSectionText = @"text";
static NSString *const kSectionExpiry = @"expiry";
static NSString *const kSectionClear = @"clear";

static const NSInteger kExpiryHoursRow = 4;
static const CGFloat kSheetWidth = 540;
static const CGFloat kSheetHeight = 620;

@interface DBNoticeDialog () <UITableViewDataSource, UITableViewDelegate>
@end

@implementation DBNoticeDialog {
  __weak DBRouter *_router;
  DBCoreBridge *_core;
  DBTexts *_texts;
  NSDictionary *_config;
  NSArray *_doorIds;
  NSDictionary *_doorLabels;
  NSArray *_presets;        // [{id, text}]
  NSArray *_sections;
  NSArray *_expiryIds;
  NSString *_target;        // "" = global, otherwise a door id
  NSString *_expiryPreset;  // 1h | today | until_cleared | custom
  NSInteger _customHours;
  void (^_onFinished)(BOOL changed);
  BOOL _changed;

  UIButton *_dim;
  UIView *_panel;
  DBNavBar *_navBar;
  UITableView *_table;
  UITextField *_textField;
  UIStepper *_hoursStepper;
  CGFloat _keyboardHeight;
}

- (id)initWithRouter:(DBRouter *)router {
  self = [super initWithFrame:CGRectZero];
  if (self) {
    _router = router;
    _core = router.core;
    _texts = router.texts;
    _target = @"";
    _expiryPreset = @"until_cleared";
    _customHours = 3;
    _expiryIds = [NSArray arrayWithObjects:@"1h", @"today", @"until_cleared", @"custom", nil];
    _sections = [NSArray array];
    [self buildUi];
  }
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  _table.dataSource = nil;
  _table.delegate = nil;
}

- (void)buildUi {
  _dim = [UIButton buttonWithType:UIButtonTypeCustom];
  _dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
  [_dim addTarget:self action:@selector(onCancel) forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_dim];

  _panel = [[UIView alloc] init];
  _panel.backgroundColor = DBChromeScreenBackground();
  _panel.clipsToBounds = YES;
  [self addSubview:_panel];

  _navBar = [[DBNavBar alloc] init];
  [_panel addSubview:_navBar.bar];

  _table = DBChromeGroupedTable(self, self);
  [_panel addSubview:_table];

  _textField = [[UITextField alloc] init];
  _textField.clearButtonMode = UITextFieldViewModeWhileEditing;
  _textField.returnKeyType = UIReturnKeyDone;
  _textField.autocorrectionType = UITextAutocorrectionTypeNo;
  _textField.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
  _textField.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [_textField addTarget:self action:@selector(onTextDone)
       forControlEvents:UIControlEventEditingDidEndOnExit];

  _hoursStepper = [[UIStepper alloc] init];
  _hoursStepper.minimumValue = 1;
  _hoursStepper.maximumValue = 168;
  _hoursStepper.stepValue = 1;
  [_hoursStepper addTarget:self action:@selector(onHoursChanged)
          forControlEvents:UIControlEventValueChanged];

  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardChanged:)
      name:UIKeyboardWillChangeFrameNotification object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardChanged:)
      name:UIKeyboardWillHideNotification object:nil];
}

- (void)presentInView:(UIView *)parent
               config:(NSDictionary *)config
              doorIds:(NSArray *)doorIds
           doorLabels:(NSDictionary *)doorLabels
      preselectedDoor:(NSString *)preselectedDoor
              palette:(DBUiPalette *)palette
           onFinished:(void (^)(BOOL changed))onFinished {
  (void)palette;
  _config = config;
  _doorIds = doorIds ?: [NSArray array];
  _doorLabels = doorLabels ?: [NSDictionary dictionary];
  _onFinished = [onFinished copy];
  _changed = NO;
  _target = [preselectedDoor length] > 0 ? [preselectedDoor copy] : @"";
  _expiryPreset = @"until_cleared";
  _hoursStepper.value = (double)_customHours;
  _presets = [DBNoticeModel presetsFromConfig:_config] ?: [NSArray array];
  _sections = [_presets count] > 0
      ? [NSArray arrayWithObjects:kSectionTarget, kSectionPresets, kSectionText, kSectionExpiry,
                                  kSectionClear, nil]
      : [NSArray arrayWithObjects:kSectionTarget, kSectionText, kSectionExpiry, kSectionClear,
                                  nil];

  [self loadTextForTarget];
  [self applyStrings];
  [_table reloadData];
  [_table setContentOffset:CGPointZero animated:NO];

  self.frame = parent.bounds;
  self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [parent addSubview:self];
  [parent bringSubviewToFront:self];
  [self setNeedsLayout];
}

- (void)dismiss {
  [_textField resignFirstResponder];
  [self removeFromSuperview];
  void (^finished)(BOOL) = _onFinished;
  _onFinished = nil;
  if (finished) finished(_changed);
}

- (void)applyStrings {
  UINavigationItem *item = [_navBar setRootTitle:[_texts ts:@"notice.title"] backTitle:nil
                                          onBack:nil];
  item.leftBarButtonItem = DBChromeBarItem([_texts ts:@"admin.cancel"], self,
                                           @selector(onCancel));
  item.rightBarButtonItem = DBChromeDoneBarItem([_texts ts:@"notice.publish"], self,
                                                @selector(onPublish));
  _textField.placeholder = [_texts ts:@"notice.text"];
}

- (void)loadTextForTarget {
  long long nowMs = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
  NSDictionary *existing = [DBNoticeModel effectiveNoticeForDoor:_target config:_config
                                                            nowMs:nowMs];
  _textField.text = existing ? [DBNoticeModel noticeText:existing] : @"";
}

- (void)showMessage:(NSString *)key {
  UIAlertView *alert = [[UIAlertView alloc] initWithTitle:[_texts ts:@"notice.title"]
                                                  message:[_texts ts:key]
                                                 delegate:nil
                                        cancelButtonTitle:[_texts ts:@"editor.ok"]
                                        otherButtonTitles:nil];
  [alert show];
}

#pragma mark - table

- (NSString *)sectionIdAtIndex:(NSInteger)section {
  if (section < 0 || section >= (NSInteger)[_sections count]) return @"";
  return [_sections objectAtIndex:(NSUInteger)section];
}

- (NSString *)targetIdAtRow:(NSInteger)row {
  if (row <= 0 || row > (NSInteger)[_doorIds count]) return @"";
  return [_doorIds objectAtIndex:(NSUInteger)(row - 1)];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  (void)tableView;
  return (NSInteger)[_sections count];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  (void)tableView;
  NSString *sid = [self sectionIdAtIndex:section];
  if ([sid isEqualToString:kSectionTarget]) return (NSInteger)[_doorIds count] + 1;
  if ([sid isEqualToString:kSectionPresets]) return (NSInteger)[_presets count];
  if ([sid isEqualToString:kSectionExpiry]) return (NSInteger)[_expiryIds count] + 1;
  return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
  (void)tableView;
  NSString *sid = [self sectionIdAtIndex:section];
  if ([sid isEqualToString:kSectionTarget]) return [_texts ts:@"notice.target"];
  if ([sid isEqualToString:kSectionPresets]) return [_texts ts:@"notice.presets"];
  if ([sid isEqualToString:kSectionText]) return [_texts ts:@"notice.text"];
  if ([sid isEqualToString:kSectionExpiry]) return [_texts ts:@"notice.expiry"];
  return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
  (void)tableView;
  if ([[self sectionIdAtIndex:section] isEqualToString:kSectionText])
    return [_texts ts:@"notice.limit"];
  return nil;
}

- (void)configureCell:(UITableViewCell *)cell section:(NSString *)sid row:(NSInteger)row {
  if ([sid isEqualToString:kSectionTarget]) {
    NSString *identifier = [self targetIdAtRow:row];
    if (row == 0) {
      cell.textLabel.text = [_texts ts:@"notice.target_global"];
    } else {
      NSString *label = [_doorLabels objectForKey:identifier];
      cell.textLabel.text =
          [_texts t:@"notice.target_door", ([label length] ? label : identifier), nil];
    }
    cell.accessoryType = [identifier isEqualToString:_target]
        ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
  } else if ([sid isEqualToString:kSectionPresets]) {
    NSDictionary *preset = [_presets objectAtIndex:(NSUInteger)row];
    cell.textLabel.text = [preset objectForKey:@"text"];
  } else if ([sid isEqualToString:kSectionExpiry]) {
    if (row == kExpiryHoursRow) {
      cell.textLabel.text = [_texts ts:@"notice.expiry_hours"];
      cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld", (long)_customHours];
      return;
    }
    NSString *identifier = [_expiryIds objectAtIndex:(NSUInteger)row];
    cell.textLabel.text = [_texts ts:[@"notice.expiry_" stringByAppendingString:identifier]];
    cell.accessoryType = [identifier isEqualToString:_expiryPreset]
        ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
  } else if ([sid isEqualToString:kSectionClear]) {
    cell.textLabel.text = [_texts ts:@"notice.clear"];
  }
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  NSString *sid = [self sectionIdAtIndex:indexPath.section];
  BOOL hoursRow = [sid isEqualToString:kSectionExpiry] && indexPath.row == kExpiryHoursRow;
  NSString *reuse = hoursRow ? @"hours" : sid;
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
  if (!cell) {
    cell = [[UITableViewCell alloc]
        initWithStyle:(hoursRow ? UITableViewCellStyleValue1 : UITableViewCellStyleDefault)
        reuseIdentifier:reuse];
    cell.textLabel.adjustsFontSizeToFitWidth = YES;
    if ([sid isEqualToString:kSectionClear]) {
      // The negative role is the one colour a cell label carries: system red where the OS has
      // one, a matching red before iOS 7.
      cell.textLabel.textAlignment = NSTextAlignmentCenter;
      cell.textLabel.textColor = DBChromeIsFlat()
          ? [UIColor colorWithRed:1.0f green:0.231f blue:0.188f alpha:1]
          : [UIColor colorWithRed:0.8f green:0.1f blue:0.1f alpha:1];
    }
    if (hoursRow) {
      cell.accessoryView = _hoursStepper;
      cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    if ([sid isEqualToString:kSectionText]) cell.selectionStyle = UITableViewCellSelectionStyleNone;
  }
  if ([sid isEqualToString:kSectionText]) {
    _textField.frame = CGRectInset(cell.contentView.bounds, 10, 0);
    [cell.contentView addSubview:_textField];
    return cell;
  }
  [self configureCell:cell section:sid row:indexPath.row];
  return cell;
}

// Selection changes update the rows on screen in place: reloading the table would pull the
// text field out of its cell and drop the keyboard in the middle of an edit.
- (void)refreshVisibleRows {
  for (UITableViewCell *cell in [_table visibleCells]) {
    NSIndexPath *path = [_table indexPathForCell:cell];
    if (!path) continue;
    NSString *sid = [self sectionIdAtIndex:path.section];
    if ([sid isEqualToString:kSectionText]) continue;
    [self configureCell:cell section:sid row:path.row];
    [cell setNeedsLayout];
  }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:NO];
  NSString *sid = [self sectionIdAtIndex:indexPath.section];
  if ([sid isEqualToString:kSectionTarget]) {
    _target = [[self targetIdAtRow:indexPath.row] copy];
    [self loadTextForTarget];
    [self refreshVisibleRows];
  } else if ([sid isEqualToString:kSectionPresets]) {
    NSDictionary *preset = [_presets objectAtIndex:(NSUInteger)indexPath.row];
    _textField.text = [preset objectForKey:@"text"] ?: @"";
  } else if ([sid isEqualToString:kSectionExpiry]) {
    if (indexPath.row == kExpiryHoursRow) return;
    _expiryPreset = [[_expiryIds objectAtIndex:(NSUInteger)indexPath.row] copy];
    [self refreshVisibleRows];
  } else if ([sid isEqualToString:kSectionClear]) {
    [self onClear];
  }
}

#pragma mark - actions

- (void)onHoursChanged {
  _customHours = MAX(1, MIN(168, (NSInteger)_hoursStepper.value));
  _expiryPreset = @"custom";
  [self refreshVisibleRows];
}

- (void)onTextDone {
  [_textField resignFirstResponder];
}

// The end of the local day, expressed as an offset from now. Core owns the
// time zone, so the offset is computed from its local-time document instead of
// from the operating system's calendar.
- (long long)endOfDayOffsetMs {
  NSDictionary *local = [_core cachedLocalTime];
  if (![local isKindOfClass:[NSDictionary class]]) return 0;
  NSInteger hh = [DBConfigUtil intVal:local path:@"hh" def:-1];
  NSInteger mm = [DBConfigUtil intVal:local path:@"mm" def:0];
  NSInteger ss = [DBConfigUtil intVal:local path:@"ss" def:0];
  if (hh < 0 || hh > 23) return 0;
  long long remaining = (24 * 3600LL) - (hh * 3600LL + mm * 60LL + ss);
  return remaining * 1000LL;
}

- (NSArray *)targetDoors {
  // Core addresses the cluster-wide announcement with "*" and stores it at
  // notice.global; a door-specific one always overrides it, so the global
  // target must never be written by looping over the doors.
  if ([_target length] > 0) return [NSArray arrayWithObject:_target];
  return [NSArray arrayWithObject:DBNoticeTargetGlobal];
}

- (void)onPublish {
  NSString *text = [DBNoticeModel clampNoticeText:_textField.text];
  if ([text length] == 0) {
    [self showMessage:@"notice.empty"];
    return;
  }
  NSArray *doors = [self targetDoors];
  if ([doors count] == 0) {
    [self showMessage:@"notice.failed"];
    return;
  }
  long long nowMs = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
  long long expires = [_expiryPreset isEqualToString:@"custom"]
      ? nowMs + (long long)_customHours * 3600LL * 1000LL
      : [DBNoticeModel expiryMsForPreset:_expiryPreset nowMs:nowMs
                        endOfDayOffsetMs:[self endOfDayOffsetMs]];
  BOOL allOk = YES;
  for (NSString *door in doors) {
    BOOL ok = [door isEqualToString:DBNoticeTargetGlobal]
        ? [_core setGlobalNotice:text expiresMs:expires]
        : [_core setNotice:text forDoor:door expiresMs:expires];
    if (!ok) allOk = NO;
  }
  _changed = _changed || allOk;
  if (allOk) [self dismiss];
  else [self showMessage:@"notice.failed"];
}

- (void)onClear {
  NSArray *doors = [self targetDoors];
  BOOL allOk = ([doors count] > 0);
  for (NSString *door in doors) {
    BOOL ok = [door isEqualToString:DBNoticeTargetGlobal]
        ? [_core clearGlobalNotice] : [_core clearNoticeForDoor:door];
    if (!ok) allOk = NO;
  }
  _changed = _changed || allOk;
  if (allOk) [self dismiss];
  else [self showMessage:@"notice.failed"];
}

- (void)onCancel {
  [self dismiss];
}

#pragma mark - layout

- (void)keyboardChanged:(NSNotification *)note {
  CGRect keyboard = [self convertRect:[[note.userInfo objectForKey:UIKeyboardFrameEndUserInfoKey]
                                          CGRectValue]
                             fromView:nil];
  CGRect overlap = CGRectIntersection(self.bounds, keyboard);
  _keyboardHeight =
      [note.name isEqualToString:UIKeyboardWillHideNotification] || CGRectIsNull(overlap)
          ? 0 : CGRectGetHeight(overlap);
  [self setNeedsLayout];
  [self layoutIfNeeded];
  NSUInteger textSection = [_sections indexOfObject:kSectionText];
  if (_keyboardHeight > 0 && [_textField isFirstResponder] && textSection != NSNotFound) {
    [_table scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:0
                                                      inSection:(NSInteger)textSection]
                  atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
  }
}

// A form sheet centred in the space the keyboard leaves on an iPad; the whole of that space
// on bounds too small to hold one.
- (void)layoutSubviews {
  [super layoutSubviews];
  CGSize size = self.bounds.size;
  _dim.frame = self.bounds;
  CGFloat available = MAX(120, size.height - _keyboardHeight);
  CGFloat inset = 16;
  BOOL sheet = size.width >= kSheetWidth + 2 * inset && size.height >= 600;
  if (sheet) {
    CGFloat height = MAX(160, MIN(kSheetHeight, available - 2 * inset));
    _panel.frame = CGRectMake(floorf((size.width - kSheetWidth) / 2),
                              MAX(0, floorf((available - height) / 2)), kSheetWidth, height);
  } else {
    _panel.frame = CGRectMake(0, 0, size.width, available);
  }
  CGRect inner = _panel.bounds;
  CGFloat top = [_navBar layoutInBounds:inner];
  _table.frame = CGRectMake(0, top, inner.size.width, MAX(0, inner.size.height - top));
}

@end
