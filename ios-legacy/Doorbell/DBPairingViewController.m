#import "DBPairingViewController.h"

#import "DBCoreBridge.h"
#import "DBBootConfig.h"
#import "DBInfoViewController.h"

@interface DBPairingViewController () <UIAlertViewDelegate>
@end

@implementation DBPairingViewController {
  DBCoreBridge *_core;
  DBBootConfig *_boot;
  UIScrollView *_scroll;
  UILabel *_title;
  UILabel *_subtitle;
  UIImageView *_qr;
  UILabel *_status;
  UILabel *_sep;
  UITextField *_host;
  UITextField *_pin;
  UIButton *_join;
  UILabel *_foundSep;
  UILabel *_foundHint;
  UIButton *_found;
  NSString *_lastQr;
  NSTimer *_poll;
  BOOL _dismissed;
}

- (id)initWithCore:(DBCoreBridge *)core boot:(DBBootConfig *)boot {
  self = [super init];
  if (self) {
    _core = [core retain];
    _boot = [boot retain];
    _lastQr = [@"" retain];
  }
  return self;
}

- (void)dealloc {
  [_poll invalidate];
  [_core removeHandler:@"pairing"];
  [_core release];
  [_boot release];
  [_scroll release];
  [_title release];
  [_subtitle release];
  [_qr release];
  [_status release];
  [_sep release];
  [_host release];
  [_pin release];
  [_join release];
  [_foundSep release];
  [_foundHint release];
  [_found release];
  [_lastQr release];
  [super dealloc];
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = [UIColor colorWithRed:0.055 green:0.086 blue:0.129 alpha:1];

  _scroll = [[UIScrollView alloc] init];
  _scroll.alwaysBounceVertical = YES;
  [self.view addSubview:_scroll];

  _title = [[UILabel alloc] init];
  _title.text = @"この端末を追加";
  _title.textColor = [UIColor whiteColor];
  _title.backgroundColor = [UIColor clearColor];
  _title.font = [UIFont boldSystemFontOfSize:26];
  _title.textAlignment = NSTextAlignmentCenter;
  [_scroll addSubview:_title];

  _subtitle = [[UILabel alloc] init];
  _subtitle.numberOfLines = 0;
  _subtitle.textColor = [UIColor colorWithWhite:0.65 alpha:1];
  _subtitle.backgroundColor = [UIColor clearColor];
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
  _status.backgroundColor = [UIColor clearColor];
  _status.font = [UIFont systemFontOfSize:14];
  _status.textAlignment = NSTextAlignmentCenter;
  [_scroll addSubview:_status];

  _sep = [[UILabel alloc] init];
  _sep.text = @"── または PIN で参加 ──";
  _sep.textColor = [UIColor colorWithWhite:0.4 alpha:1];
  _sep.backgroundColor = [UIColor clearColor];
  _sep.font = [UIFont systemFontOfSize:13];
  _sep.textAlignment = NSTextAlignmentCenter;
  [_scroll addSubview:_sep];

  _host = [[UITextField alloc] init];
  _host.placeholder = @"接続先 (例 10.0.1.5:47172)";
  _host.borderStyle = UITextBorderStyleRoundedRect;
  _host.autocorrectionType = UITextAutocorrectionTypeNo;
  _host.autocapitalizationType = UITextAutocapitalizationTypeNone;
  _host.keyboardType = UIKeyboardTypeURL;
  [_scroll addSubview:_host];

  _pin = [[UITextField alloc] init];
  _pin.placeholder = @"PIN (6 桁)";
  _pin.borderStyle = UITextBorderStyleRoundedRect;
  _pin.keyboardType = UIKeyboardTypeNumberPad;
  [_scroll addSubview:_pin];

  _join = [[UIButton buttonWithType:UIButtonTypeCustom] retain];  // iOS5: System=白背景回避
  [_join setTitle:@"参加する" forState:UIControlStateNormal];
  [_join setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
  _join.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:0.9 alpha:1];
  _join.layer.cornerRadius = 8;
  [_join addTarget:self action:@selector(onJoin) forControlEvents:UIControlEventTouchUpInside];
  [_scroll addSubview:_join];

  _foundSep = [[UILabel alloc] init];
  _foundSep.text = @"── はじめての 1 台 ──";
  _foundSep.textColor = [UIColor colorWithWhite:0.4 alpha:1];
  _foundSep.backgroundColor = [UIColor clearColor];
  _foundSep.font = [UIFont systemFontOfSize:13];
  _foundSep.textAlignment = NSTextAlignmentCenter;
  [_scroll addSubview:_foundSep];

  _foundHint = [[UILabel alloc] init];
  _foundHint.numberOfLines = 0;
  _foundHint.text = @"まだどの端末も設定していない場合は、この端末を親機にして新しく始めます。";
  _foundHint.textColor = [UIColor colorWithWhite:0.65 alpha:1];
  _foundHint.backgroundColor = [UIColor clearColor];
  _foundHint.font = [UIFont systemFontOfSize:13];
  _foundHint.textAlignment = NSTextAlignmentCenter;
  [_scroll addSubview:_foundHint];

  _found = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
  [_found setTitle:@"この端末で新規作成" forState:UIControlStateNormal];
  [_found setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
  _found.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1];
  _found.layer.cornerRadius = 8;
  [_found addTarget:self action:@selector(onFound) forControlEvents:UIControlEventTouchUpInside];
  [_scroll addSubview:_found];

  DBPairingViewController *__unsafe_unretained weakSelf = self;
  [_core addHandler:@"pairing" handler:^(NSDictionary *ev) { [weakSelf onUiEvent:ev]; }];

  [self reload];
  _poll = [NSTimer scheduledTimerWithTimeInterval:3.0 target:self selector:@selector(onPoll)
                                         userInfo:nil repeats:YES];
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  CGFloat w = self.view.bounds.size.width;
  CGFloat h = self.view.bounds.size.height;
  _scroll.frame = CGRectMake(0, 0, w, h);
  CGFloat pad = 24;
  CGFloat cw = w - pad * 2;
  CGFloat y = 40;
  _title.frame = CGRectMake(pad, y, cw, 34); y += 40;
  _subtitle.frame = CGRectMake(pad, y, cw, 40); y += 46;
  CGFloat qs = MIN(cw, 240);
  _qr.frame = CGRectMake((w - qs) / 2, y, qs, qs); y += qs + 16;
  _status.frame = CGRectMake(pad, y, cw, 56); y += 66;
  _sep.frame = CGRectMake(pad, y, cw, 20); y += 30;
  CGFloat fw = MIN(cw, 300);
  CGFloat fx = (w - fw) / 2;
  _host.frame = CGRectMake(fx, y, fw, 40); y += 48;
  _pin.frame = CGRectMake(fx, y, fw, 40); y += 48;
  _join.frame = CGRectMake(fx, y, fw, 46); y += 46 + 28;
  _foundSep.frame = CGRectMake(pad, y, cw, 20); y += 28;
  _foundHint.frame = CGRectMake(pad, y, cw, 40); y += 46;
  _found.frame = CGRectMake(fx, y, fw, 46); y += 46 + 40;
  _scroll.contentSize = CGSizeMake(w, y);
}

- (void)reload {
  NSDictionary *p = [_core pairingInfo];
  if (![p isKindOfClass:[NSDictionary class]]) return;
  if ([[p objectForKey:@"paired"] boolValue]) { [self dismissPaired]; return; }
  NSDictionary *self_ = [p objectForKey:@"self"];
  NSString *name = [self_ isKindOfClass:[NSDictionary class]] ? [self_ objectForKey:@"name"] : nil;
  NSString *addr = [self_ isKindOfClass:[NSDictionary class]] ? [self_ objectForKey:@"addr"] : nil;
  if ([name length] > 0 && [addr length] > 0)
    _subtitle.text = [NSString stringWithFormat:@"%@\n%@", name, addr];
  else if ([addr length] > 0)
    _subtitle.text = addr;
  NSString *qr = [p objectForKey:@"pair_qr"];
  if ([qr isKindOfClass:[NSString class]] && [qr length] > 0 && ![qr isEqualToString:_lastQr]) {
    [_lastQr release];
    _lastQr = [qr retain];
    // iPad1 の QR 生成は重い → 背景で作り main で反映 (デバッグ画面と同流儀)。
    // block が self を retain するので _qr は完了まで有効 (dangling 回避)。
    NSString *qrCopy = [qr copy];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      UIImage *img = [DBInfoViewController qrImageForString:qrCopy targetPx:480];
      dispatch_async(dispatch_get_main_queue(), ^{ self->_qr.image = img; });
      [qrCopy release];
    });
  }
}

- (void)onPoll {
  NSDictionary *p = [_core pairingInfo];
  if ([p isKindOfClass:[NSDictionary class]] && [[p objectForKey:@"paired"] boolValue]) {
    [self dismissPaired];
  } else {
    [self reload];
  }
}

- (void)onUiEvent:(NSDictionary *)ev {
  NSString *t = [ev objectForKey:@"t"];
  if ([t isEqualToString:@"paired"]) {
    // イベント配送ループの最中に dismiss/dealloc すると再入で落ちる → 次の runloop へ遅延
    [self performSelector:@selector(dismissPaired) withObject:nil afterDelay:0];
  } else if ([t isEqualToString:@"join_result"]) {
    if ([[ev objectForKey:@"ok"] boolValue]) {
      [self performSelector:@selector(dismissPaired) withObject:nil afterDelay:0];
    } else {
      UIAlertView *a = [[UIAlertView alloc]
              initWithTitle:@"参加できませんでした"
                    message:[NSString stringWithFormat:@"%@", [ev objectForKey:@"err"]]
                   delegate:nil
          cancelButtonTitle:@"OK"
          otherButtonTitles:nil];
      [a show];
      [a release];
    }
  }
}

- (void)dismissPaired {
  if (_dismissed) return;  // poll と paired イベントの二重呼び出しガード
  _dismissed = YES;
  [_poll invalidate];
  _poll = nil;
  [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)onFound {
  UIAlertView *a = [[UIAlertView alloc]
          initWithTitle:@"新規クラスタを作成"
                message:@"この端末を親機にして新しく始めますか?\n(既存のクラスタに参加する場合は、管理画面で承認してください)"
               delegate:self
      cancelButtonTitle:@"キャンセル"
      otherButtonTitles:@"作成", nil];
  [a show];
  [a release];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
  if (buttonIndex == alertView.cancelButtonIndex) return;
  if ([_core foundCluster]) {
    [self dismissPaired];  // 親機化 → 即 dismiss (paired イベントも届く)
  }
}

- (void)onJoin {
  NSString *host = [_host.text stringByTrimmingCharactersInSet:
                                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  NSString *pin = [_pin.text stringByTrimmingCharactersInSet:
                                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if ([host length] == 0 || [pin length] == 0) {
    UIAlertView *a = [[UIAlertView alloc] initWithTitle:nil
                                                message:@"接続先と PIN を入力してください"
                                               delegate:nil
                                      cancelButtonTitle:@"OK"
                                      otherButtonTitles:nil];
    [a show];
    [a release];
    return;
  }
  [_host resignFirstResponder];
  [_pin resignFirstResponder];
  [_core joinCluster:host pin:pin];
}

@end
