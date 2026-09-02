#import "DBNoticeDialog.h"

#import "../Core/DBConfigUtil.h"
#import "../Core/DBCoreBridge.h"
#import "../Core/DBNoticeModel.h"
#import "../Core/DBTexts.h"
#import "DBNumericKeypad.h"
#import "DBRouter.h"
#import "DBWidgets.h"

@implementation DBNoticeDialog {
  __weak DBRouter *_router;
  DBCoreBridge *_core;
  DBTexts *_texts;
  DBUiPalette *_palette;
  NSDictionary *_config;
  NSArray *_doorIds;
  NSDictionary *_doorLabels;
  NSString *_target;        // "" = global, otherwise a door id
  NSString *_expiryPreset;  // 1h | today | until_cleared | custom
  NSInteger _customHours;
  void (^_onFinished)(BOOL changed);
  BOOL _changed;

  UIButton *_backdrop;
  UIView *_panel;
  UILabel *_title;
  UIScrollView *_scroll;
  UILabel *_targetCaption;
  NSMutableArray *_targetButtons;
  UILabel *_presetCaption;
  NSMutableArray *_presetButtons;
  UITextField *_textField;
  UILabel *_expiryCaption;
  NSMutableArray *_expiryButtons;
  UILabel *_status;
  UIButton *_publish;
  UIButton *_clear;
  UIButton *_cancel;
  // Numbers are entered with the drawn keypad: the iOS 5 system keyboard has no
  // usable IME here and would cover the field.
  UIView *_keypadOverlay;
  UILabel *_keypadTitle;
  DBNumericKeypad *_keypad;
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
    _targetButtons = [[NSMutableArray alloc] init];
    _presetButtons = [[NSMutableArray alloc] init];
    _expiryButtons = [[NSMutableArray alloc] init];
    [self buildUi];
  }
  return self;
}

- (UIButton *)chipButton {
  UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
  button.titleLabel.font = [UIFont systemFontOfSize:17];
  button.titleLabel.adjustsFontSizeToFitWidth = YES;
  button.layer.cornerRadius = 8;
  button.clipsToBounds = YES;
  button.contentEdgeInsets = UIEdgeInsetsMake(6, 12, 6, 12);
  return button;
}

- (void)buildUi {
  _backdrop = [UIButton buttonWithType:UIButtonTypeCustom];
  _backdrop.backgroundColor = [UIColor colorWithWhite:0 alpha:0.72];
  [_backdrop addTarget:self action:@selector(onCancel)
      forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_backdrop];

  _panel = [[UIView alloc] init];
  _panel.layer.cornerRadius = 16;
  _panel.clipsToBounds = YES;
  [self addSubview:_panel];

  _title = [[UILabel alloc] init];
  _title.backgroundColor = [UIColor clearColor];
  _title.font = [UIFont boldSystemFontOfSize:24];
  [_panel addSubview:_title];

  _scroll = [[UIScrollView alloc] init];
  _scroll.alwaysBounceVertical = YES;
  [_panel addSubview:_scroll];

  _targetCaption = [[UILabel alloc] init];
  _targetCaption.backgroundColor = [UIColor clearColor];
  _targetCaption.font = [UIFont systemFontOfSize:15];
  [_scroll addSubview:_targetCaption];

  _presetCaption = [[UILabel alloc] init];
  _presetCaption.backgroundColor = [UIColor clearColor];
  _presetCaption.font = [UIFont systemFontOfSize:15];
  [_scroll addSubview:_presetCaption];

  _textField = [[UITextField alloc] init];
  _textField.borderStyle = UITextBorderStyleRoundedRect;
  _textField.font = [UIFont systemFontOfSize:19];
  _textField.clearButtonMode = UITextFieldViewModeWhileEditing;
  _textField.returnKeyType = UIReturnKeyDone;
  _textField.autocorrectionType = UITextAutocorrectionTypeNo;
  [_textField addTarget:self action:@selector(onTextChanged)
       forControlEvents:UIControlEventEditingChanged];
  [_textField addTarget:self action:@selector(onTextDone)
       forControlEvents:UIControlEventEditingDidEndOnExit];
  [_scroll addSubview:_textField];

  _expiryCaption = [[UILabel alloc] init];
  _expiryCaption.backgroundColor = [UIColor clearColor];
  _expiryCaption.font = [UIFont systemFontOfSize:15];
  [_scroll addSubview:_expiryCaption];

  _status = [[UILabel alloc] init];
  _status.backgroundColor = [UIColor clearColor];
  _status.font = [UIFont systemFontOfSize:15];
  _status.numberOfLines = 2;
  [_panel addSubview:_status];

  _publish = [self chipButton];
  _publish.titleLabel.font = [UIFont boldSystemFontOfSize:19];
  [_publish addTarget:self action:@selector(onPublish)
     forControlEvents:UIControlEventTouchUpInside];
  [_panel addSubview:_publish];

  _clear = [self chipButton];
  _clear.titleLabel.font = [UIFont boldSystemFontOfSize:19];
  [_clear addTarget:self action:@selector(onClear) forControlEvents:UIControlEventTouchUpInside];
  [_panel addSubview:_clear];

  _cancel = [self chipButton];
  _cancel.titleLabel.font = [UIFont boldSystemFontOfSize:19];
  [_cancel addTarget:self action:@selector(onCancel) forControlEvents:UIControlEventTouchUpInside];
  [_panel addSubview:_cancel];

  _keypadOverlay = [[UIView alloc] init];
  _keypadOverlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.86];
  _keypadOverlay.hidden = YES;
  [self addSubview:_keypadOverlay];

  _keypadTitle = [[UILabel alloc] init];
  _keypadTitle.backgroundColor = [UIColor clearColor];
  _keypadTitle.textColor = [UIColor whiteColor];
  _keypadTitle.textAlignment = NSTextAlignmentCenter;
  _keypadTitle.font = [UIFont boldSystemFontOfSize:22];
  [_keypadOverlay addSubview:_keypadTitle];

  _keypad = [[DBNumericKeypad alloc] initWithSubmitTitle:@""];
  _keypad.maxLength = 3;
  __weak DBNoticeDialog *weakSelf = self;
  _keypad.onSubmit = ^(NSString *value) {
    DBNoticeDialog *dialog = weakSelf;
    if (!dialog) return;
    NSInteger hours = [value integerValue];
    dialog->_customHours = MAX(1, MIN(168, hours));
    dialog->_keypadOverlay.hidden = YES;
    [dialog updateExpirySelection];
  };
  [_keypadOverlay addSubview:_keypad];
}

- (void)presentInView:(UIView *)parent
               config:(NSDictionary *)config
              doorIds:(NSArray *)doorIds
           doorLabels:(NSDictionary *)doorLabels
      preselectedDoor:(NSString *)preselectedDoor
              palette:(DBUiPalette *)palette
           onFinished:(void (^)(BOOL changed))onFinished {
  _config = config;
  _doorIds = doorIds ?: [NSArray array];
  _doorLabels = doorLabels ?: [NSDictionary dictionary];
  _palette = palette;
  _onFinished = [onFinished copy];
  _changed = NO;
  _target = [preselectedDoor length] > 0 ? [preselectedDoor copy] : @"";
  _expiryPreset = @"until_cleared";
  _status.text = @"";

  long long nowMs = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
  NSDictionary *existing = [DBNoticeModel effectiveNoticeForDoor:_target config:_config
                                                            nowMs:nowMs];
  _textField.text = existing ? [DBNoticeModel noticeText:existing] : @"";

  [self applyPalette];
  [self rebuildTargets];
  [self rebuildPresets];
  [self rebuildExpiry];
  [self applyStrings];

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

- (void)applyPalette {
  _panel.backgroundColor = _palette ? _palette.surface
                                    : [UIColor colorWithWhite:0.1 alpha:1];
  UIColor *ink = _palette ? _palette.ink : [UIColor whiteColor];
  UIColor *muted = _palette ? _palette.mutedInk : [UIColor colorWithWhite:0.65 alpha:1];
  _title.textColor = ink;
  _targetCaption.textColor = muted;
  _presetCaption.textColor = muted;
  _expiryCaption.textColor = muted;
  _status.textColor = muted;
  _publish.backgroundColor = _palette ? _palette.accent : [UIColor colorWithWhite:0.3 alpha:1];
  [_publish setTitleColor:(_palette ? _palette.accentInk : [UIColor whiteColor])
                 forState:UIControlStateNormal];
  _clear.backgroundColor = _palette ? _palette.elevated : [UIColor colorWithWhite:0.2 alpha:1];
  [_clear setTitleColor:ink forState:UIControlStateNormal];
  _cancel.backgroundColor = _palette ? _palette.elevated : [UIColor colorWithWhite:0.2 alpha:1];
  [_cancel setTitleColor:ink forState:UIControlStateNormal];
}

- (void)applyStrings {
  _title.text = [_texts ts:@"notice.title"];
  _targetCaption.text = [_texts ts:@"notice.target"];
  _presetCaption.text = [_texts ts:@"notice.presets"];
  _expiryCaption.text = [_texts ts:@"notice.expiry"];
  _textField.placeholder = [_texts ts:@"notice.text"];
  [_publish setTitle:[_texts ts:@"notice.publish"] forState:UIControlStateNormal];
  [_clear setTitle:[_texts ts:@"notice.clear"] forState:UIControlStateNormal];
  [_cancel setTitle:[_texts ts:@"admin.cancel"] forState:UIControlStateNormal];
}

- (void)styleChoice:(UIButton *)button selected:(BOOL)selected {
  UIColor *ink = _palette ? _palette.ink : [UIColor whiteColor];
  button.backgroundColor = selected
      ? (_palette ? _palette.accent : [UIColor colorWithWhite:0.35 alpha:1])
      : (_palette ? _palette.elevated : [UIColor colorWithWhite:0.2 alpha:1]);
  [button setTitleColor:(selected ? (_palette ? _palette.accentInk : [UIColor whiteColor]) : ink)
               forState:UIControlStateNormal];
}

- (void)rebuildTargets {
  for (UIButton *button in _targetButtons) [button removeFromSuperview];
  [_targetButtons removeAllObjects];

  UIButton *global = [self chipButton];
  [global setTitle:[_texts ts:@"notice.target_global"] forState:UIControlStateNormal];
  global.accessibilityIdentifier = @"";
  [global addTarget:self action:@selector(onTarget:) forControlEvents:UIControlEventTouchUpInside];
  [_scroll addSubview:global];
  [_targetButtons addObject:global];

  for (NSString *door in _doorIds) {
    UIButton *button = [self chipButton];
    NSString *label = [_doorLabels objectForKey:door];
    [button setTitle:[_texts t:@"notice.target_door", ([label length] ? label : door), nil]
            forState:UIControlStateNormal];
    button.accessibilityIdentifier = door;
    [button addTarget:self action:@selector(onTarget:)
     forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:button];
    [_targetButtons addObject:button];
  }
  [self updateTargetSelection];
}

- (void)updateTargetSelection {
  for (UIButton *button in _targetButtons) {
    NSString *identifier = button.accessibilityIdentifier ?: @"";
    [self styleChoice:button selected:[identifier isEqualToString:_target]];
  }
}

- (void)rebuildPresets {
  for (UIButton *button in _presetButtons) [button removeFromSuperview];
  [_presetButtons removeAllObjects];
  for (NSDictionary *preset in [DBNoticeModel presetsFromConfig:_config]) {
    UIButton *button = [self chipButton];
    NSString *text = [preset objectForKey:@"text"];
    [button setTitle:text forState:UIControlStateNormal];
    button.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    button.accessibilityIdentifier = text;
    [button addTarget:self action:@selector(onPreset:)
     forControlEvents:UIControlEventTouchUpInside];
    [self styleChoice:button selected:NO];
    [_scroll addSubview:button];
    [_presetButtons addObject:button];
  }
  _presetCaption.hidden = ([_presetButtons count] == 0);
}

- (void)rebuildExpiry {
  for (UIButton *button in _expiryButtons) [button removeFromSuperview];
  [_expiryButtons removeAllObjects];
  NSArray *presets = [NSArray arrayWithObjects:
      [NSArray arrayWithObjects:@"1h", @"notice.expiry_1h", nil],
      [NSArray arrayWithObjects:@"today", @"notice.expiry_today", nil],
      [NSArray arrayWithObjects:@"until_cleared", @"notice.expiry_until_cleared", nil],
      [NSArray arrayWithObjects:@"custom", @"notice.expiry_custom", nil], nil];
  for (NSArray *entry in presets) {
    UIButton *button = [self chipButton];
    [button setTitle:[_texts ts:[entry objectAtIndex:1]] forState:UIControlStateNormal];
    button.accessibilityIdentifier = [entry objectAtIndex:0];
    [button addTarget:self action:@selector(onExpiry:)
     forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:button];
    [_expiryButtons addObject:button];
  }
  [self updateExpirySelection];
}

- (void)updateExpirySelection {
  for (UIButton *button in _expiryButtons)
    [self styleChoice:button
             selected:[(button.accessibilityIdentifier ?: @"") isEqualToString:_expiryPreset]];
}

#pragma mark - actions

- (void)onTarget:(UIButton *)sender {
  _target = [(sender.accessibilityIdentifier ?: @"") copy];
  long long nowMs = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
  NSDictionary *existing = [DBNoticeModel effectiveNoticeForDoor:_target config:_config
                                                            nowMs:nowMs];
  _textField.text = existing ? [DBNoticeModel noticeText:existing] : @"";
  _status.text = @"";
  [self updateTargetSelection];
}

- (void)onPreset:(UIButton *)sender {
  _textField.text = sender.accessibilityIdentifier ?: @"";
  _status.text = @"";
}

- (void)onExpiry:(UIButton *)sender {
  _expiryPreset = [(sender.accessibilityIdentifier ?: @"until_cleared") copy];
  [self updateExpirySelection];
  if (![_expiryPreset isEqualToString:@"custom"]) return;
  [_textField resignFirstResponder];
  _keypadTitle.text = [_texts ts:@"notice.expiry_hours"];
  [_keypad setSubmitTitle:[_texts ts:@"admin.save"]];
  [_keypad clear];
  _keypadOverlay.hidden = NO;
  [self bringSubviewToFront:_keypadOverlay];
  [self setNeedsLayout];
}

- (void)onTextChanged {
  _status.text = @"";
}

- (void)onTextDone {
  [_textField resignFirstResponder];
}

// The end of the local day, expressed as an offset from now. Core owns the
// time zone, so the offset is computed from its local-time document instead of
// from the operating system's calendar.
- (long long)endOfDayOffsetMs {
  NSDictionary *local = [_core localTimeJson:0];
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
  // notice.global; a door-specific one always overrides it, so 全体 must never
  // be written by looping over the doors.
  if ([_target length] > 0) return [NSArray arrayWithObject:_target];
  return [NSArray arrayWithObject:DBNoticeTargetGlobal];
}

- (void)onPublish {
  NSString *text = [DBNoticeModel clampNoticeText:_textField.text];
  if ([text length] == 0) {
    _status.text = [_texts ts:@"notice.empty"];
    return;
  }
  NSArray *doors = [self targetDoors];
  if ([doors count] == 0) {
    _status.text = [_texts ts:@"notice.failed"];
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
  _status.text = [_texts ts:(allOk ? @"notice.saved" : @"notice.failed")];
  if (allOk) [self dismiss];
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
  _status.text = [_texts ts:(allOk ? @"notice.cleared" : @"notice.failed")];
  if (allOk) [self dismiss];
}

- (void)onCancel {
  [self dismiss];
}

#pragma mark - layout

- (void)layoutRow:(NSArray *)buttons y:(CGFloat *)y width:(CGFloat)width {
  CGFloat x = 0;
  CGFloat rowHeight = 40;
  for (UIButton *button in buttons) {
    CGSize fit = [button sizeThatFits:CGSizeMake(width, rowHeight)];
    CGFloat buttonWidth = MIN(width, MAX(90, fit.width));
    if (x > 0 && x + buttonWidth > width) {
      x = 0;
      *y += rowHeight + 8;
    }
    button.frame = CGRectMake(x, *y, buttonWidth, rowHeight);
    x += buttonWidth + 8;
  }
  if ([buttons count] > 0) *y += rowHeight + 14;
}

- (void)layoutSubviews {
  [super layoutSubviews];
  CGSize size = self.bounds.size;
  _backdrop.frame = self.bounds;
  CGFloat panelWidth = MIN(660, size.width - 48);
  CGFloat panelHeight = MIN(size.height - 48, 520);
  _panel.frame = CGRectMake((size.width - panelWidth) / 2, (size.height - panelHeight) / 2,
                            panelWidth, panelHeight);
  CGFloat pad = 20;
  CGFloat contentWidth = panelWidth - 2 * pad;
  _title.frame = CGRectMake(pad, 14, contentWidth, 32);

  CGFloat buttonRow = 52;
  CGFloat statusHeight = 36;
  CGFloat scrollHeight = panelHeight - 58 - buttonRow - statusHeight - 12;
  _scroll.frame = CGRectMake(pad, 54, contentWidth, MAX(80, scrollHeight));

  CGFloat y = 0;
  _targetCaption.frame = CGRectMake(0, y, contentWidth, 20);
  y += 24;
  [self layoutRow:_targetButtons y:&y width:contentWidth];

  if (!_presetCaption.hidden) {
    _presetCaption.frame = CGRectMake(0, y, contentWidth, 20);
    y += 24;
    [self layoutRow:_presetButtons y:&y width:contentWidth];
  } else {
    _presetCaption.frame = CGRectZero;
  }

  _textField.frame = CGRectMake(0, y, contentWidth, 46);
  y += 58;

  _expiryCaption.frame = CGRectMake(0, y, contentWidth, 20);
  y += 24;
  [self layoutRow:_expiryButtons y:&y width:contentWidth];
  _scroll.contentSize = CGSizeMake(contentWidth, y);

  _status.frame = CGRectMake(pad, panelHeight - buttonRow - statusHeight - 6,
                             contentWidth, statusHeight);
  CGFloat buttonWidth = (contentWidth - 16) / 3;
  CGFloat buttonY = panelHeight - buttonRow;
  _publish.frame = CGRectMake(pad, buttonY, buttonWidth, 44);
  _clear.frame = CGRectMake(pad + buttonWidth + 8, buttonY, buttonWidth, 44);
  _cancel.frame = CGRectMake(pad + 2 * (buttonWidth + 8), buttonY, buttonWidth, 44);

  _keypadOverlay.frame = self.bounds;
  CGFloat keypadWidth = MIN(320, size.width - 80);
  CGFloat keypadHeight = [DBNumericKeypad heightForWidth:keypadWidth];
  CGFloat keypadY = MAX(60, (size.height - keypadHeight) / 2);
  _keypadTitle.frame = CGRectMake(0, keypadY - 46, size.width, 34);
  _keypad.frame = CGRectMake((size.width - keypadWidth) / 2, keypadY, keypadWidth, keypadHeight);
}

@end
