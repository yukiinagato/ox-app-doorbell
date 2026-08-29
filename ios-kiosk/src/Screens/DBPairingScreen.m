#import "DBPairingScreen.h"

#import "../Core/DBBootConfig.h"
#import "../Core/DBConfigUtil.h"
#import "../Core/DBCoreBridge.h"
#import "../Media/DBQrCode.h"
#import "DBRouter.h"

@implementation DBPairingScreen {
  UIScrollView *_scroll;
  UILabel *_title;
  UILabel *_subtitle;
  UIImageView *_qr;
  UILabel *_status;
  UILabel *_sep;
  UITextField *_host;
  UITextField *_pinField;
  UIButton *_join;
  UILabel *_foundSep;
  UIButton *_found;
  UILabel *_errorLabel;
  NSString *_lastQr;
  NSTimer *_poll;
  BOOL _confirmingFound;  // 親機化の 2 段確認
  BOOL _fetchBusy;        // 背景収集実行中 (重複 poll 防止)
}

- (id)initWithRouter:(DBRouter *)router {
  self = [super initWithFrame:[UIScreen mainScreen].bounds];
  if (self) {
    _router = router;
    _lastQr = @"";
    [self buildUi];
  }
  return self;
}

- (NSString *)screenName {
  return @"pairing";
}

- (UIButton *)flatButton {
  UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];  // iOS5: System=白背景回避
  return b;
}

- (UITextField *)textFieldWithPlaceholder:(NSString *)ph {
  UITextField *f = [[UITextField alloc] init];
  f.placeholder = ph;
  f.borderStyle = UITextBorderStyleRoundedRect;
  f.autocorrectionType = UITextAutocorrectionTypeNo;
  f.autocapitalizationType = UITextAutocapitalizationTypeNone;
  f.keyboardType = UIKeyboardTypeURL;
  return f;
}

- (void)buildUi {
  self.backgroundColor = [UIColor colorWithRed:0.055 green:0.086 blue:0.129 alpha:1];

  _scroll = [[UIScrollView alloc] init];
  _scroll.alwaysBounceVertical = YES;
  [self addSubview:_scroll];

  _title = [[UILabel alloc] init];
  _title.text = @"この端末を追加";
  _title.textColor = [UIColor whiteColor];
  _title.font = [UIFont boldSystemFontOfSize:26];
  _title.textAlignment = NSTextAlignmentCenter;
  [_scroll addSubview:_title];

  _subtitle = [[UILabel alloc] init];
  _subtitle.numberOfLines = 0;
  _subtitle.textColor = [UIColor colorWithWhite:0.65 alpha:1];
  _subtitle.font = [UIFont systemFontOfSize:14];
  _subtitle.textAlignment = NSTextAlignmentCenter;
  [_scroll addSubview:_subtitle];

  _qr = [[UIImageView alloc] init];
  _qr.contentMode = UIViewContentModeScaleAspectFit;
  _qr.backgroundColor = [UIColor whiteColor];
  [_scroll addSubview:_qr];

  _status = [[UILabel alloc] init];
  _status.numberOfLines = 0;
  _status.text = @"配対を待っています…\n管理画面の「デバイスを追加」でこの端末を承認するか、この QR を読み取ってください。";
  _status.textColor = [UIColor colorWithWhite:0.65 alpha:1];
  _status.font = [UIFont systemFontOfSize:14];
  _status.textAlignment = NSTextAlignmentCenter;
  [_scroll addSubview:_status];

  _sep = [[UILabel alloc] init];
  _sep.text = @"── または PIN で参加 ──";
  _sep.textColor = [UIColor colorWithWhite:0.4 alpha:1];
  _sep.font = [UIFont systemFontOfSize:13];
  _sep.textAlignment = NSTextAlignmentCenter;
  [_scroll addSubview:_sep];

  _host = [self textFieldWithPlaceholder:@"接続先 (例 10.0.1.5:47172)"];
  [_scroll addSubview:_host];

  _pinField = [self textFieldWithPlaceholder:@"PIN"];
  [_scroll addSubview:_pinField];

  _join = [self flatButton];
  [_join setTitle:@"PIN で参加" forState:UIControlStateNormal];
  _join.titleLabel.font = [UIFont boldSystemFontOfSize:18];
  [_join setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
  _join.backgroundColor = [UIColor colorWithRed:0.13 green:0.45 blue:0.85 alpha:1];
  _join.layer.cornerRadius = 10;
  [_join addTarget:self action:@selector(onJoin) forControlEvents:UIControlEventTouchUpInside];
  [_scroll addSubview:_join];

  _foundSep = [[UILabel alloc] init];
  _foundSep.text = @"── 新規クラスタ ──";
  _foundSep.textColor = [UIColor colorWithWhite:0.4 alpha:1];
  _foundSep.font = [UIFont systemFontOfSize:13];
  _foundSep.textAlignment = NSTextAlignmentCenter;
  [_scroll addSubview:_foundSep];

  _found = [self flatButton];
  [_found setTitle:@"この端末を親機にする" forState:UIControlStateNormal];
  _found.titleLabel.font = [UIFont boldSystemFontOfSize:16];
  [_found setTitleColor:[UIColor colorWithRed:0.85 green:0.55 blue:0.2 alpha:1]
               forState:UIControlStateNormal];
  [_found addTarget:self action:@selector(onFound)
   forControlEvents:UIControlEventTouchUpInside];
  [_scroll addSubview:_found];

  _errorLabel = [[UILabel alloc] init];
  _errorLabel.numberOfLines = 0;
  _errorLabel.textColor = [UIColor colorWithRed:0.88 green:0.36 blue:0.30 alpha:1];
  _errorLabel.font = [UIFont systemFontOfSize:15];
  _errorLabel.textAlignment = NSTextAlignmentCenter;
  _errorLabel.text = @" ";
  [_scroll addSubview:_errorLabel];

  [self clearLabelBackgrounds:_scroll];
}
#pragma mark - poll / 更新

- (void)startPolling {
  [self reload];
  if (!_poll) {
    _poll = [NSTimer scheduledTimerWithTimeInterval:2.0
                                             target:self
                                           selector:@selector(onPoll)
                                           userInfo:nil
                                            repeats:YES];
  }
}

- (void)stopPolling {
  [_poll invalidate];
  _poll = nil;
}

// core 呼び出しは main で行わない (mesh タイムアウト中に core ロックで main が
// 数秒〜15s+ 塞がる — 実機で watchdog 発火を確認)。背景収集 → main 反映。
- (void)onPoll {
  if (_fetchBusy) return;
  _fetchBusy = YES;
  DBCoreBridge *core = [_router core];  // block が強参照で保持 (ARC)
  __weak DBPairingScreen *wself = self;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSDictionary *p = [core pairingInfo];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBPairingScreen *s = wself;
      if (!s) return;
      s->_fetchBusy = NO;
      if (!s.superview) return;
      if ([p isKindOfClass:[NSDictionary class]] && [[p objectForKey:@"paired"] boolValue]) {
        // 配対済み → router の paired イベントが永続化と自動 close を行う (冪等)。
        [s.router closePairingAnimated:YES];
      } else {
        [s applyPairingInfo:p];
      }
    });
  });
}

- (void)reload {
  [self onPoll];
}

// main スレッド。背景収集済みの pairingInfo を反映。
- (void)applyPairingInfo:(NSDictionary *)p {
  if (![p isKindOfClass:[NSDictionary class]]) return;
  NSDictionary *selfInfo = [p objectForKey:@"self"];
  NSString *name = [selfInfo isKindOfClass:[NSDictionary class]]
                       ? [DBConfigUtil evStr:selfInfo key:@"name"]
                       : @"";
  NSString *selfAddr = [selfInfo isKindOfClass:[NSDictionary class]]
                           ? [DBConfigUtil evStr:selfInfo key:@"addr"]
                           : @"";
  if ([name length] > 0 && [selfAddr length] > 0)
    _subtitle.text = [NSString stringWithFormat:@"%@\n%@", name, selfAddr];
  else if ([selfAddr length] > 0)
    _subtitle.text = selfAddr;

  NSString *qr = [p objectForKey:@"pair_qr"];
  if ([qr isKindOfClass:[NSString class]] && [qr length] > 0 && ![qr isEqualToString:_lastQr]) {
    _lastQr = [qr copy];
    // iPad1 の QR 生成は重い → 背景で作り main で反映。
    __weak DBPairingScreen *wself = self;
    NSString *qrCopy = [qr copy];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      UIImage *img = [DBQrCode imageForString:qrCopy targetPx:480];
      dispatch_async(dispatch_get_main_queue(), ^{
        DBPairingScreen *s = wself;
        if (s && [s->_lastQr isEqualToString:qrCopy]) s->_qr.image = img;
      });
    });
  }
  [self setNeedsLayout];
}

#pragma mark - 操作

- (void)handleJoinResult:(NSDictionary *)ev {
  if ([[ev objectForKey:@"ok"] boolValue]) {
    [_router closePairingAnimated:YES];  // paired イベントでも閉じるが冪等
  } else {
    _errorLabel.text = [NSString stringWithFormat:@"参加できませんでした: %@",
                        [ev objectForKey:@"err"] ?: @"?"];
  }
}

// 親機化は 2 段確認 (UIAlertView の代わりにボタン文言を変える)。
- (void)onFound {
  if (!_confirmingFound) {
    _confirmingFound = YES;
    _errorLabel.text = @" ";
    [_found setTitle:@"よろしければもう一度タップ (既存クラスタに参加する場合はキャンセル)"
            forState:UIControlStateNormal];
    return;
  }
  _confirmingFound = NO;
  [_found setTitle:@"この端末を親機にする" forState:UIControlStateNormal];
  if ([[_router core] foundCluster]) {
    [_router closePairingAnimated:YES];  // 親機化 → paired イベントも届く
  } else {
    _errorLabel.text = @"親機化できませんでした";
  }
}

- (void)onJoin {
  NSString *host =
      [_host.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  NSString *pin =
      [_pinField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if ([host length] == 0 || [pin length] == 0) {
    _errorLabel.text = @"接続先と PIN を入力してください";
    return;
  }
  [_host resignFirstResponder];
  [_pinField resignFirstResponder];
  _errorLabel.text = @" ";
  [[_router core] joinCluster:host pin:pin];
}

#pragma mark - layout

- (void)layoutSubviews {
  [super layoutSubviews];
  CGSize sz = self.bounds.size;
  CGFloat pad = 24;
  CGFloat w = sz.width - pad * 2;

  _scroll.frame = CGRectMake(0, 12, sz.width, sz.height - 12);

  CGFloat y = 8;
  _title.frame = CGRectMake(pad, y, w, 34); y += 42;
  CGSize subSz = [_subtitle sizeThatFits:CGSizeMake(w, 9999)];
  _subtitle.frame = CGRectMake(pad, y, w, subSz.height); y += subSz.height + 10;

  CGFloat qrDim = MIN(w * 0.72, 380);
  _qr.frame = CGRectMake((sz.width - qrDim) / 2, y, qrDim, qrDim); y += qrDim + 10;

  CGSize stSz = [_status sizeThatFits:CGSizeMake(w, 9999)];
  _status.frame = CGRectMake(pad, y, w, stSz.height); y += stSz.height + 14;

  _sep.frame = CGRectMake(pad, y, w, 20); y += 28;

  _host.frame = CGRectMake(pad, y, w, 40); y += 50;
  _pinField.frame = CGRectMake(pad, y, w, 40); y += 50;
  _join.frame = CGRectMake(pad, y, w, 46); y += 56;

  _foundSep.frame = CGRectMake(pad, y, w, 20); y += 28;
  _found.frame = CGRectMake(pad, y, w, 44); y += 54;

  CGSize errSz = [_errorLabel sizeThatFits:CGSizeMake(w, 9999)];
  _errorLabel.frame = CGRectMake(pad, y, w, MAX(errSz.height, 22)); y += MAX(errSz.height, 22) + 20;

  _scroll.contentSize = CGSizeMake(sz.width, y);

  for (UIView *v in [_scroll subviews])
    if ([v isKindOfClass:[UILabel class]]) v.backgroundColor = [UIColor clearColor];
}

@end

