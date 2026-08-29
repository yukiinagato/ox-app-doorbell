#import "DBInfoScreen.h"

#import "../Core/DBBootConfig.h"
#import "../Core/DBConfigUtil.h"
#import "../Core/DBCoreBridge.h"
#import "../Media/DBQrCode.h"
#import "DBRouter.h"
#import <arpa/inet.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>

// 127.0.0.1:port へ TCP 接続を試みて LISTEN 中か判定 (localhost なので即座)。
static BOOL DBPortListening(int port) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return NO;
  struct sockaddr_in a;
  memset(&a, 0, sizeof(a));
  a.sin_family = AF_INET;
  a.sin_port = htons((uint16_t)port);
  inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
  BOOL listening = (connect(fd, (struct sockaddr *)&a, sizeof(a)) == 0);
  close(fd);
  return listening;
}

@implementation DBInfoScreen {
  DBCoreBridge *_core;
  DBBootConfig *_boot;

  UIScrollView *_scroll;
  UILabel *_title;
  UILabel *_infoText;
  UILabel *_addrText;
  UISegmentedControl *_ipSeg;
  UIButton *_cycleBtn;
  UIImageView *_qr;
  UILabel *_qrUrl;
  UIButton *_close;
  UIButton *_refresh;

  NSMutableArray *_v4;
  NSMutableArray *_v6;
  NSInteger _choiceIdx;
}

- (id)initWithRouter:(DBRouter *)router {
  self = [super initWithFrame:[UIScreen mainScreen].bounds];
  if (self) {
    _router = router;
    _core = router.core;
    _boot = router.boot;
    _v4 = [[NSMutableArray alloc] init];
    _v6 = [[NSMutableArray alloc] init];
    [self buildUi];
  }
  return self;
}

- (NSString *)screenName {
  return @"info";
}

- (UIButton *)flatButton {
  UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];  // iOS5: System=白背景回避
  return b;
}

- (void)buildUi {
  self.backgroundColor = [UIColor colorWithRed:0.07 green:0.08 blue:0.10 alpha:1];

  _scroll = [[UIScrollView alloc] init];
  _scroll.alwaysBounceVertical = YES;
  [self addSubview:_scroll];

  _title = [[UILabel alloc] init];
  _title.text = @"本機情報 / Debug";
  _title.font = [UIFont boldSystemFontOfSize:28];
  _title.textColor = [UIColor whiteColor];
  [_scroll addSubview:_title];

  _infoText = [[UILabel alloc] init];
  _infoText.numberOfLines = 0;
  _infoText.font = [UIFont fontWithName:@"Courier" size:15] ?: [UIFont systemFontOfSize:15];
  _infoText.textColor = [UIColor colorWithWhite:0.92 alpha:1];
  [_scroll addSubview:_infoText];

  _addrText = [[UILabel alloc] init];
  _addrText.numberOfLines = 0;
  _addrText.font = [UIFont fontWithName:@"Courier" size:14] ?: [UIFont systemFontOfSize:14];
  _addrText.textColor = [UIColor colorWithRed:0.55 green:0.85 blue:1 alpha:1];
  [_scroll addSubview:_addrText];

  _ipSeg = [[UISegmentedControl alloc] initWithItems:@[ @"IPv4", @"IPv6" ]];
  _ipSeg.selectedSegmentIndex = 0;
  [_ipSeg addTarget:self action:@selector(onIpToggle)
   forControlEvents:UIControlEventValueChanged];
  [_scroll addSubview:_ipSeg];

  _cycleBtn = [self flatButton];
  _cycleBtn.titleLabel.font = [UIFont systemFontOfSize:16];
  [_cycleBtn setTitleColor:[UIColor colorWithRed:0.35 green:0.72 blue:1 alpha:1]
                  forState:UIControlStateNormal];
  [_cycleBtn addTarget:self action:@selector(onCycle) forControlEvents:UIControlEventTouchUpInside];
  [_scroll addSubview:_cycleBtn];

  _qr = [[UIImageView alloc] init];
  _qr.contentMode = UIViewContentModeCenter;
  _qr.backgroundColor = [UIColor whiteColor];
  _qr.layer.cornerRadius = 6;
  _qr.clipsToBounds = YES;
  [_scroll addSubview:_qr];

  _qrUrl = [[UILabel alloc] init];
  _qrUrl.numberOfLines = 0;
  _qrUrl.textAlignment = NSTextAlignmentCenter;
  _qrUrl.font = [UIFont fontWithName:@"Courier" size:15] ?: [UIFont systemFontOfSize:15];
  _qrUrl.textColor = [UIColor colorWithWhite:0.85 alpha:1];
  [_scroll addSubview:_qrUrl];

  _refresh = [self flatButton];
  [_refresh setTitle:@"更新" forState:UIControlStateNormal];
  _refresh.titleLabel.font = [UIFont systemFontOfSize:18];
  [_refresh setTitleColor:[UIColor colorWithRed:0.35 green:0.72 blue:1 alpha:1]
                 forState:UIControlStateNormal];
  [_refresh addTarget:self action:@selector(reload) forControlEvents:UIControlEventTouchUpInside];
  [_scroll addSubview:_refresh];

  _close = [self flatButton];
  [_close setTitle:@"閉じる" forState:UIControlStateNormal];
  _close.titleLabel.font = [UIFont boldSystemFontOfSize:18];
  [_close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
  _close.backgroundColor = [UIColor colorWithRed:0.20 green:0.24 blue:0.30 alpha:1];
  _close.layer.cornerRadius = 8;
  [_close addTarget:self action:@selector(onClose) forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_close];

  [self clearLabelBackgrounds:_scroll];
}
#pragma mark - データ収集 / 更新

- (void)reload {
  [_v4 removeAllObjects];
  [_v6 removeAllObjects];

  NSDictionary *st = [_core status];
  NSDictionary *node = [st objectForKey:@"node"];
  if (![node isKindOfClass:[NSDictionary class]]) node = nil;

  // アドレス収集 (core の local_addrs)
  id la = [node objectForKey:@"local_addrs"];
  if ([la isKindOfClass:[NSArray class]]) {
    for (id a in (NSArray *)la) {
      if (![a isKindOfClass:[NSString class]] || [(NSString *)a length] == 0) continue;
      if ([[self class] isV6:(NSString *)a]) {
        [_v6 addObject:a];
      } else {
        [_v4 addObject:a];
      }
    }
  }

  NSMutableString *info = [NSMutableString string];
  [info appendFormat:@"node    : %@ (%@)\n", [DBConfigUtil evStr:node key:@"name"],
                      [DBConfigUtil evStr:node key:@"id"] ?: @"-"];
  [info appendFormat:@"role    : %@\n", _boot.role];
  [info appendFormat:@"version : %@\n",
                      [[NSBundle mainBundle] objectForInfoDictionaryKey:
                                            @"CFBundleShortVersionString"] ?: @"-"];
  [info appendFormat:@"mic     : %@\n", _boot.micEnabled ? @"有 (外付け)" : @"無"];
  [info appendString:@"camera  : 無 (iPad1 はカメラ非搭載)\n"];

  // ネットワーク / Wi-Fi / 電池 (main スレッドで直接取得 — 安全)
  NSDictionary *device = [_core deviceInfoNow];
  if ([device isKindOfClass:[NSDictionary class]]) {
    NSString *gw = [device objectForKey:@"gateway"];
    NSDictionary *wifi = [device objectForKey:@"wifi"];
    NSDictionary *bat = [device objectForKey:@"battery"];
    [info appendString:@"\n── ネットワーク ──\n"];
    [info appendFormat:@"gateway : %@\n", gw ?: @"(不明)"];
    if ([wifi isKindOfClass:[NSDictionary class]]) {
      [info appendFormat:@"SSID    : %@\n", [wifi objectForKey:@"ssid"] ?: @"-"];
      [info appendFormat:@"BSSID   : %@\n", [wifi objectForKey:@"bssid"] ?: @"-"];
    }
    if ([bat isKindOfClass:[NSDictionary class]]) {
      id lvl = [bat objectForKey:@"level"];
      NSString *lvlStr =
          lvl ? [NSString stringWithFormat:@"%d%%", (int)([lvl floatValue] * 100)] : @"-";
      [info appendFormat:@"battery : %@  (%@)", lvlStr, [bat objectForKey:@"state"] ?: @"?"];
    }
  }

  // 監視ポート
  [info appendString:@"\n\n── 監視ポート ──\n"];
  [info appendFormat:@"http  %ld : %@\n", (long)_boot.httpPort,
                      DBPortListening((int)_boot.httpPort) ? @"LISTEN ✓" : @"閉"];
  [info appendFormat:@"mesh  47172 : %@\n", DBPortListening(47172) ? @"LISTEN ✓" : @"閉"];
  [info appendFormat:@"sip   %ld : UDP (直接呼)", (long)_boot.directPort];

  // 触発統計
  NSDictionary *dbg = [_core debugInfo];
  NSDictionary *trig =
      [dbg isKindOfClass:[NSDictionary class]] ? [dbg objectForKey:@"triggers"] : nil;
  if ([trig isKindOfClass:[NSDictionary class]]) {
    [info appendString:@"\n\n── 触発 ──\n"];
    [info appendFormat:@"累計触発回数 : %@\n", [trig objectForKey:@"total_press"] ?: @0];
    NSDictionary *last = [trig objectForKey:@"last"];
    if ([last isKindOfClass:[NSDictionary class]]) {
      NSNumber *wallMs = [last objectForKey:@"wall_ms"];
      NSString *timeStr = @"-";
      if ([wallMs isKindOfClass:[NSNumber class]]) {
        NSDate *d = [NSDate dateWithTimeIntervalSince1970:[wallMs doubleValue] / 1000.0];
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        [fmt setDateFormat:@"MM-dd HH:mm:ss"];
        timeStr = [fmt stringFromDate:d];
      }
      [info appendFormat:@"最新触発 : %@  door=%@", timeStr, [last objectForKey:@"door"] ?: @"-"];
    } else {
      [info appendString:@"最新触発 : (まだ無し)"];
    }
  }
  _infoText.text = info;

  // アドレス一覧
  NSMutableString *addr = [NSMutableString stringWithString:@"── 本機の全アドレス ──\n"];
  if ([_v4 count]) {
    [addr appendString:@"IPv4:\n"];
    for (NSString *s in _v4) [addr appendFormat:@"  %@\n", s];
  }
  if ([_v6 count]) {
    [addr appendString:@"IPv6:\n"];
    for (NSString *s in _v6) [addr appendFormat:@"  %@\n", s];
  }
  if (![_v4 count] && ![_v6 count]) [addr appendString:@"(取得中… ネットワーク未接続?)"];
  _addrText.text = addr;

  [_ipSeg setEnabled:([_v4 count] > 0) forSegmentAtIndex:0];
  [_ipSeg setEnabled:([_v6 count] > 0) forSegmentAtIndex:1];
  if (_ipSeg.selectedSegmentIndex == 1 && ![_v6 count]) _ipSeg.selectedSegmentIndex = 0;
  if (_ipSeg.selectedSegmentIndex == 0 && ![_v4 count] && [_v6 count]) _ipSeg.selectedSegmentIndex = 1;

  [self updateQr];
  [self setNeedsLayout];
}

+ (BOOL)isV6:(NSString *)addr {
  return [addr rangeOfString:@":"].location != NSNotFound;
}
- (NSString *)preferredV6 {
  // グローバル (2xxx/3xxx) を ULA(fd) より優先
  for (NSString *s in _v6) {
    unichar c = [s length] ? [s characterAtIndex:0] : 0;
    if (c == '2' || c == '3') return s;
  }
  return [_v6 count] ? [_v6 objectAtIndex:0] : nil;
}

- (NSArray *)currentList {
  return _ipSeg.selectedSegmentIndex == 1 ? _v6 : _v4;
}

- (void)onIpToggle {
  _choiceIdx = 0;
  [self updateQr];
}

- (void)onCycle {
  NSArray *list = [self currentList];
  if ([list count] > 1) _choiceIdx = (_choiceIdx + 1) % (NSInteger)[list count];
  [self updateQr];
}

- (void)updateQr {
  NSArray *list = [self currentList];
  if (_choiceIdx >= (NSInteger)[list count]) _choiceIdx = 0;
  NSString *addr = [list count] ? [list objectAtIndex:_choiceIdx] : nil;
  NSString *url = nil;
  if (addr) {
    if (_ipSeg.selectedSegmentIndex == 1)
      url = [NSString stringWithFormat:@"http://[%@]:%ld/admin/", addr, (long)_boot.httpPort];
    else
      url = [NSString stringWithFormat:@"http://%@:%ld/admin/", addr, (long)_boot.httpPort];
  }
  if ([list count] > 1) {
    _cycleBtn.hidden = NO;
    [_cycleBtn setTitle:[NSString stringWithFormat:@"アドレス切替 (%ld/%lu) ▸",
                         (long)(_choiceIdx + 1), (unsigned long)[list count]]
               forState:UIControlStateNormal];
  } else {
    _cycleBtn.hidden = YES;
  }
  if (url == nil) {
    _qr.image = nil;
    _qrUrl.text = @"(アドレス無し)";
    return;
  }
  _qrUrl.text = [@"スキャンで管理後台へ:\n" stringByAppendingString:url];
  // QR は iPad1 の CPU では重い → 背景生成 → main 反映。選択が変わっていたら破棄。
  _qr.image = nil;
  __weak DBInfoScreen *wself = self;
  NSString *want = [url copy];
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    UIImage *img = [DBQrCode imageForString:want targetPx:440];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBInfoScreen *s = wself;
      if (!s) return;
      if (s->_qrUrl.text && [s->_qrUrl.text rangeOfString:want].location != NSNotFound) {
        s->_qr.image = img;
        [s setNeedsLayout];
      }
    });
  });
  [self setNeedsLayout];
}

- (void)onClose {
  [_router closeInfoAnimated:YES];
}

#pragma mark - layout

- (void)layoutSubviews {
  [super layoutSubviews];
  CGSize sz = self.bounds.size;
  CGFloat pad = 20;
  CGFloat w = sz.width - pad * 2;

  _close.frame = CGRectMake(sz.width - 100, 24, 80, 40);
  _scroll.frame = CGRectMake(0, 72, sz.width, sz.height - 72);

  CGFloat y = 8;
  _title.frame = CGRectMake(pad, y, w, 36);
  y += 44;

  CGSize infoSz = [_infoText sizeThatFits:CGSizeMake(w, 9999)];
  _infoText.frame = CGRectMake(pad, y, w, infoSz.height);
  y += infoSz.height + 14;

  CGSize addrSz = [_addrText sizeThatFits:CGSizeMake(w, 9999)];
  _addrText.frame = CGRectMake(pad, y, w, addrSz.height);
  y += addrSz.height + 16;

  _ipSeg.frame = CGRectMake(pad, y, MIN(w, 240), 34);
  y += 44;

  if (!_cycleBtn.hidden) {
    _cycleBtn.frame = CGRectMake(pad, y, w, 34);
    y += 40;
  }

  CGFloat qrDim = MIN(w, 460);
  _qr.frame = CGRectMake((sz.width - qrDim) / 2, y, qrDim, qrDim);
  y += qrDim + 10;

  CGSize urlSz = [_qrUrl sizeThatFits:CGSizeMake(w, 9999)];
  _qrUrl.frame = CGRectMake(pad, y, w, urlSz.height);
  y += urlSz.height + 16;

  _refresh.frame = CGRectMake(pad, y, 120, 40);
  y += 60;

  _scroll.contentSize = CGSizeMake(sz.width, y);

  for (UIView *v in [_scroll subviews])
    if ([v isKindOfClass:[UILabel class]]) v.backgroundColor = [UIColor clearColor];
}

@end


