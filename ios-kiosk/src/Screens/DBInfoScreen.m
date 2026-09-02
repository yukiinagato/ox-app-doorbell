#import "DBInfoScreen.h"

#import "../Core/DBBootConfig.h"
#import "../Core/DBConfigUtil.h"
#import "../Core/DBCoreBridge.h"
#import "../Core/DBTexts.h"
#import "../Media/DBQrCode.h"
#import "DBRouter.h"
#import <arpa/inet.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>


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
  UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
  return b;
}

- (void)buildUi {
  self.backgroundColor = [UIColor colorWithRed:0.07 green:0.08 blue:0.10 alpha:1];

  _scroll = [[UIScrollView alloc] init];
  _scroll.alwaysBounceVertical = YES;
  [self addSubview:_scroll];

  _title = [[UILabel alloc] init];
  _title.text = [[_router texts] ts:@"info.title"];
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
  [_refresh setTitle:[[_router texts] ts:@"info.refresh"] forState:UIControlStateNormal];
  _refresh.titleLabel.font = [UIFont systemFontOfSize:18];
  [_refresh setTitleColor:[UIColor colorWithRed:0.35 green:0.72 blue:1 alpha:1]
                 forState:UIControlStateNormal];
  [_refresh addTarget:self action:@selector(reload) forControlEvents:UIControlEventTouchUpInside];
  [_scroll addSubview:_refresh];

  _close = [self flatButton];
  [_close setTitle:[[_router texts] ts:@"monitor.close"] forState:UIControlStateNormal];
  _close.titleLabel.font = [UIFont boldSystemFontOfSize:18];
  [_close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
  _close.backgroundColor = [UIColor colorWithRed:0.20 green:0.24 blue:0.30 alpha:1];
  _close.layer.cornerRadius = 8;
  [_close addTarget:self action:@selector(onClose) forControlEvents:UIControlEventTouchUpInside];
  [self addSubview:_close];

  [self clearLabelBackgrounds:_scroll];
}



- (void)reload {
  DBCoreBridge *core = _core;
  __weak DBInfoScreen *wself = self;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSDictionary *st = [core status];
    NSDictionary *dbg = [core debugInfo];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBInfoScreen *s = wself;
      if (!s || !s.superview) return;
      [s applyCollectedStatus:st debug:dbg];
    });
  });
}

- (void)applyCollectedStatus:(NSDictionary *)st debug:(NSDictionary *)dbg {
  [_v4 removeAllObjects];
  [_v6 removeAllObjects];

  NSDictionary *node = [st objectForKey:@"node"];
  if (![node isKindOfClass:[NSDictionary class]]) node = nil;


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
  DBTexts *texts = [_router texts];
  [info appendFormat:@"%@ : %@ (%@)\n", [texts ts:@"info.node"],
                      [DBConfigUtil evStr:node key:@"name"],
                      [DBConfigUtil evStr:node key:@"id"] ?: @"-"];
  [info appendFormat:@"%@ : %@\n", [texts ts:@"info.role"], _boot.role];
  // Every screen shows core and app versions side by side (spec §5.1).
  [info appendFormat:@"%@ : %@\n", [texts ts:@"info.core_version"],
                      [_core coreVersion] ?: @"-"];
  [info appendFormat:@"%@ : %@\n", [texts ts:@"info.app_version"],
                      [[NSBundle mainBundle] objectForInfoDictionaryKey:
                                            @"CFBundleShortVersionString"] ?: @"-"];
  // The kiosk's local safe mode is no longer an invisible latch: the state and
  // the remaining healthy window are shown here.
  NSString *safeModeState = [DBConfigUtil str:st path:@"runtime.safe_mode_state"];
  if ([safeModeState length] == 0 || [safeModeState isEqualToString:@"off"]) {
    [info appendFormat:@"%@ : %@\n", [texts ts:@"info.safe_mode"],
                        [texts ts:@"info.safe_mode_off"]];
  } else if ([safeModeState isEqualToString:@"heartbeat_stalled"]) {
    [info appendFormat:@"%@ : %@\n", [texts ts:@"info.safe_mode"],
                        [texts ts:@"info.safe_mode_heartbeat"]];
  } else if ([safeModeState isEqualToString:@"crash_charged"]) {
    [info appendFormat:@"%@ : %@\n", [texts ts:@"info.safe_mode"],
                        [texts ts:@"info.safe_mode_crash"]];
  } else if ([safeModeState isEqualToString:@"helper_latched"]) {
    [info appendFormat:@"%@ : %@\n", [texts ts:@"info.safe_mode"],
                        [texts ts:@"info.safe_mode_helper"]];
  } else {
    double remaining = [DBConfigUtil doubleVal:st path:@"runtime.safe_mode_remaining_s"
                                           def:600];
    long minutes = (long)((remaining + 59) / 60);
    if (minutes < 1) minutes = 1;
    [info appendFormat:@"%@ : %@\n", [texts ts:@"info.safe_mode"],
                        [texts t:@"info.safe_mode_wait",
                             [NSString stringWithFormat:@"%ld", minutes], nil]];
  }
  [info appendFormat:@"%@ : %@\n", [texts ts:@"info.microphone"],
                      [texts ts:_boot.micEnabled ? @"info.external_present" : @"info.absent"]];
  [info appendFormat:@"%@ : %@\n", [texts ts:@"info.camera"],
                      [texts ts:@"info.camera_absent_ipad1"]];


  NSDictionary *device = [_core deviceInfoNow];
  if ([device isKindOfClass:[NSDictionary class]]) {
    NSString *gw = [device objectForKey:@"gateway"];
    NSDictionary *wifi = [device objectForKey:@"wifi"];
    NSDictionary *bat = [device objectForKey:@"battery"];
    [info appendFormat:@"\n── %@ ──\n", [texts ts:@"info.network"]];
    [info appendFormat:@"gateway : %@\n", gw ?: [texts ts:@"info.unknown"]];
    if ([wifi isKindOfClass:[NSDictionary class]]) {
      [info appendFormat:@"SSID    : %@\n", [wifi objectForKey:@"ssid"] ?: @"-"];
      [info appendFormat:@"BSSID   : %@\n", [wifi objectForKey:@"bssid"] ?: @"-"];
    }
    if ([bat isKindOfClass:[NSDictionary class]]) {
      id lvl = [bat objectForKey:@"level"];
      NSString *lvlStr =
          lvl ? [NSString stringWithFormat:@"%d%%", (int)([lvl floatValue] * 100)] : @"-";
      [info appendFormat:@"%@ : %@  (%@)", [texts ts:@"info.battery"], lvlStr,
                         [bat objectForKey:@"state"] ?: @"?"];
    }
  }


  [info appendFormat:@"\n\n── %@ ──\n", [texts ts:@"info.ports"]];
  [info appendFormat:@"http  %ld : %@\n", (long)_boot.httpPort,
                      DBPortListening((int)_boot.httpPort) ? @"LISTEN ✓" :
                      [texts ts:@"info.port_closed"]];
  [info appendFormat:@"mesh  47172 : %@\n", DBPortListening(47172) ? @"LISTEN ✓" :
                      [texts ts:@"info.port_closed"]];
  [info appendFormat:@"sip   %ld : %@", (long)_boot.directPort,
                      [texts ts:@"info.sip_direct"]];


  NSDictionary *trig =
      [dbg isKindOfClass:[NSDictionary class]] ? [dbg objectForKey:@"triggers"] : nil;
  if ([trig isKindOfClass:[NSDictionary class]]) {
    [info appendFormat:@"\n\n── %@ ──\n", [texts ts:@"info.triggers"]];
    [info appendFormat:@"%@ : %@\n", [texts ts:@"info.total_press"],
                       [trig objectForKey:@"total_press"] ?: @0];
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
      [info appendFormat:@"%@ : %@  door=%@", [texts ts:@"info.last_press"], timeStr,
                         [last objectForKey:@"door"] ?: @"-"];
    } else {
      [info appendFormat:@"%@ : %@", [texts ts:@"info.last_press"],
                         [texts ts:@"info.no_press"]];
    }
  }
  _infoText.text = info;


  NSMutableString *addr = [NSMutableString stringWithFormat:@"── %@ ──\n",
                            [texts ts:@"info.addresses"]];
  if ([_v4 count]) {
    [addr appendString:@"IPv4:\n"];
    for (NSString *s in _v4) [addr appendFormat:@"  %@\n", s];
  }
  if ([_v6 count]) {
    [addr appendString:@"IPv6:\n"];
    for (NSString *s in _v6) [addr appendFormat:@"  %@\n", s];
  }
  if (![_v4 count] && ![_v6 count]) [addr appendString:[texts ts:@"info.addresses_loading"]];
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
    [_cycleBtn setTitle:[[_router texts] t:@"info.address_cycle",
                         [NSNumber numberWithLong:(long)(_choiceIdx + 1)],
                         [NSNumber numberWithUnsignedLong:(unsigned long)[list count]], nil]
               forState:UIControlStateNormal];
  } else {
    _cycleBtn.hidden = YES;
  }
  if (url == nil) {
    _qr.image = nil;
    _qrUrl.text = [[_router texts] ts:@"info.no_address"];
    return;
  }
  _qrUrl.text = [[[ _router texts] ts:@"info.scan_admin"] stringByAppendingFormat:@"\n%@", url];

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
