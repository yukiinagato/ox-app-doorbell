#import "DBInfoScreen.h"

#import "../Core/DBBootConfig.h"
#import "../Core/DBConfigUtil.h"
#import "../Core/DBCoreBridge.h"
#import "../Core/DBTexts.h"
#import "../Core/DBUiTheme.h"
#import "../Media/DBQrCode.h"
#import "DBChrome.h"
#import "DBRouter.h"
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/select.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>
#import <AVFoundation/AVFoundation.h>


// Non-blocking connect with a short timeout. Core may bind its listeners to the
// LAN address rather than loopback, so a refusal on 127.0.0.1 is retried on
// every IPv4 address Core reports. Runs on a background queue only.
static BOOL DBPortOpenOn(const char *host, int port) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return NO;
  int flags = fcntl(fd, F_GETFL, 0);
  fcntl(fd, F_SETFL, flags | O_NONBLOCK);
  struct sockaddr_in a;
  memset(&a, 0, sizeof(a));
  a.sin_family = AF_INET;
  a.sin_port = htons((uint16_t)port);
  if (inet_pton(AF_INET, host, &a.sin_addr) != 1) { close(fd); return NO; }
  BOOL open = NO;
  int rc = connect(fd, (struct sockaddr *)&a, sizeof(a));
  if (rc == 0) {
    open = YES;
  } else if (errno == EINPROGRESS) {
    fd_set w;
    FD_ZERO(&w);
    FD_SET(fd, &w);
    struct timeval tv = {0, 600000};
    if (select(fd + 1, NULL, &w, NULL, &tv) == 1) {
      int err = 0;
      socklen_t len = sizeof(err);
      if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0 && err == 0) open = YES;
    }
  }
  close(fd);
  return open;
}

static BOOL DBPortListening(int port, NSArray *hosts) {
  if (DBPortOpenOn("127.0.0.1", port)) return YES;
  for (NSString *host in hosts) {
    if (![host isKindOfClass:[NSString class]] || [host rangeOfString:@":"].location != NSNotFound)
      continue;
    if (DBPortOpenOn([host UTF8String], port)) return YES;
  }
  return NO;
}

static NSString *const kRowTitle = @"title";
static NSString *const kRowValue = @"value";
static NSString *const kRowAddress = @"address";
static NSString *const kRowCheck = @"check";
static NSString *const kSectionTitle = @"title";
static NSString *const kSectionFooter = @"footer";
static NSString *const kSectionRows = @"rows";

static const CGFloat kColumnMax = 700;
static const CGFloat kQrSide = 300;

@interface DBInfoScreen () <UITableViewDataSource, UITableViewDelegate>
@end

@implementation DBInfoScreen {
  DBCoreBridge *_core;
  DBBootConfig *_boot;

  DBNavBar *_nav;
  UITableView *_table;
  // The admin-page QR and its caption, hosted as the table's footer view.
  UIView *_qrHost;
  UIImageView *_qr;
  UILabel *_qrUrl;
  CGFloat _qrHostWidth;

  NSArray *_sections;
  NSMutableArray *_v4;
  NSMutableArray *_v6;
  // The address the admin QR points at; nil picks the first IPv4, then the first IPv6.
  NSString *_chosenAddress;
  NSString *_qrPayload;
  NSDictionary *_ports;
  NSInteger _portRetries;
}

- (id)initWithRouter:(DBRouter *)router {
  self = [super initWithFrame:[UIScreen mainScreen].bounds];
  if (self) {
    _router = router;
    _core = router.core;
    _boot = router.boot;
    _v4 = [[NSMutableArray alloc] init];
    _v6 = [[NSMutableArray alloc] init];
    _sections = @[];
    [self buildUi];
  }
  return self;
}

- (void)dealloc {
  _table.dataSource = nil;
  _table.delegate = nil;
}

- (NSString *)screenName {
  return @"info";
}

- (void)buildUi {
  DBTexts *texts = [_router texts];
  self.backgroundColor = DBChromeScreenBackground();
  DBChromeInstallBackdrop(self);

  _table = DBChromeGroupedTable(self, self);
  DBChromeClearTableBackground(_table);
  [self addSubview:_table];

  _nav = [[DBNavBar alloc] init];
  __weak DBInfoScreen *weakSelf = self;
  UINavigationItem *item = [_nav setRootTitle:[texts ts:@"info.title"]
                                    backTitle:[texts ts:@"ui.back"]
                                       onBack:^{ [weakSelf onClose]; }];
  UIBarButtonItem *refresh =
      DBChromeSystemBarItem(UIBarButtonSystemItemRefresh, self, @selector(reload));
  refresh.accessibilityLabel = [texts ts:@"info.refresh"];
  item.rightBarButtonItem = refresh;
  [self addSubview:_nav.bar];

  _qrHost = [[UIView alloc] init];
  _qr = [[UIImageView alloc] init];
  _qr.contentMode = UIViewContentModeCenter;
  [_qrHost addSubview:_qr];
  _qrUrl = DBChromeSectionFooterLabel();
  _qrUrl.textAlignment = NSTextAlignmentCenter;
  [_qrHost addSubview:_qrUrl];
}

#pragma mark - collection

- (void)reload {
  DBCoreBridge *core = _core;
  NSInteger httpPort = _boot.httpPort > 0 ? _boot.httpPort : 47180;
  __weak DBInfoScreen *wself = self;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSDictionary *st = [core status];
    NSDictionary *dbg = [core debugInfo];
    id hosts = [DBConfigUtil dig:st path:@"node.local_addrs"];
    if (![hosts isKindOfClass:[NSArray class]]) hosts = @[];
    NSMutableDictionary *ports = [NSMutableDictionary dictionary];
    for (NSNumber *port in @[@(httpPort), @47443, @47172]) {
      [ports setObject:@(DBPortListening([port intValue], hosts)) forKey:port];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      DBInfoScreen *s = wself;
      if (!s || !s.superview) return;
      s->_ports = ports;
      [s applyCollectedStatus:st debug:dbg];
      // Core may still be binding right after launch: re-probe a few times
      // while anything reads closed.
      if (![[ports allValues] containsObject:@NO]) s->_portRetries = 0;
      if ([[ports allValues] containsObject:@NO] && s->_portRetries < 5) {
        s->_portRetries++;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
          DBInfoScreen *again = wself;
          if (again && again.superview) [again reload];
        });
      }
    });
  });
}

static NSDictionary *DBInfoRow(NSString *title, NSString *value) {
  return @{ kRowTitle : title ?: @"", kRowValue : value ?: @"" };
}

static NSDictionary *DBInfoSection(NSString *title, NSString *footer, NSArray *rows) {
  return @{ kSectionTitle : title ?: @"", kSectionFooter : footer ?: @"", kSectionRows : rows };
}

- (NSString *)safeModeTextForStatus:(NSDictionary *)st {
  DBTexts *texts = [_router texts];
  NSString *state = [DBConfigUtil str:st path:@"runtime.safe_mode_state"];
  if ([state length] == 0 || [state isEqualToString:@"off"])
    return [texts ts:@"info.safe_mode_off"];
  if ([state isEqualToString:@"heartbeat_stalled"]) return [texts ts:@"info.safe_mode_heartbeat"];
  if ([state isEqualToString:@"crash_charged"]) return [texts ts:@"info.safe_mode_crash"];
  if ([state isEqualToString:@"helper_latched"]) return [texts ts:@"info.safe_mode_helper"];
  double remaining = [DBConfigUtil doubleVal:st path:@"runtime.safe_mode_remaining_s" def:600];
  long minutes = (long)((remaining + 59) / 60);
  if (minutes < 1) minutes = 1;
  return [texts t:@"info.safe_mode_wait", [NSString stringWithFormat:@"%ld", minutes], nil];
}

- (void)applyCollectedStatus:(NSDictionary *)st debug:(NSDictionary *)dbg {
  [_v4 removeAllObjects];
  [_v6 removeAllObjects];
  DBTexts *texts = [_router texts];

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

  NSMutableArray *sections = [NSMutableArray array];

  NSMutableArray *device = [NSMutableArray array];
  [device addObject:DBInfoRow([texts ts:@"info.node"],
      [NSString stringWithFormat:@"%@ (%@)", [DBConfigUtil evStr:node key:@"name"] ?: @"",
                                 [DBConfigUtil evStr:node key:@"id"] ?: @"-"])];
  [device addObject:DBInfoRow([texts ts:@"info.role"], _boot.role)];
  // Every screen shows core and app versions side by side (spec §5.1).
  [device addObject:DBInfoRow([texts ts:@"info.core_version"], [_core coreVersion] ?: @"-")];
  [device addObject:DBInfoRow([texts ts:@"info.app_version"],
      [DBUiTheme appVersion:[[NSBundle mainBundle]
                                objectForInfoDictionaryKey:@"CFBundleShortVersionString"]
            withCoreVersion:[_core coreVersion]] ?: @"-")];
  // The kiosk's local safe mode is not an invisible latch: the state and the remaining
  // healthy window are shown here.
  [device addObject:DBInfoRow([texts ts:@"info.safe_mode"], [self safeModeTextForStatus:st])];
  [device addObject:DBInfoRow([texts ts:@"info.microphone"],
      [texts ts:_boot.micEnabled ? @"info.external_present" : @"info.absent"])];
  [device addObject:DBInfoRow([texts ts:@"info.camera"],
      [texts ts:[[AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo] count] > 0
                    ? @"info.builtin_present" : @"info.absent"])];
  [sections addObject:DBInfoSection([texts ts:@"info.device"], nil, device)];

  NSDictionary *deviceInfo = [_core deviceInfoNow];
  if ([deviceInfo isKindOfClass:[NSDictionary class]]) {
    NSMutableArray *network = [NSMutableArray array];
    NSString *gw = [deviceInfo objectForKey:@"gateway"];
    NSDictionary *wifi = [deviceInfo objectForKey:@"wifi"];
    NSDictionary *bat = [deviceInfo objectForKey:@"battery"];
    [network addObject:DBInfoRow(@"gateway", gw ?: [texts ts:@"info.unknown"])];
    if ([wifi isKindOfClass:[NSDictionary class]]) {
      [network addObject:DBInfoRow(@"SSID", [wifi objectForKey:@"ssid"] ?: @"-")];
      [network addObject:DBInfoRow(@"BSSID", [wifi objectForKey:@"bssid"] ?: @"-")];
    }
    if ([bat isKindOfClass:[NSDictionary class]]) {
      id lvl = [bat objectForKey:@"level"];
      NSString *lvlStr =
          lvl ? [NSString stringWithFormat:@"%d%%", (int)([lvl floatValue] * 100)] : @"-";
      [network addObject:DBInfoRow([texts ts:@"info.battery"],
          [NSString stringWithFormat:@"%@ (%@)", lvlStr, [bat objectForKey:@"state"] ?: @"?"])];
    }
    [sections addObject:DBInfoSection([texts ts:@"info.network"], nil, network)];
  }

  NSMutableArray *ports = [NSMutableArray array];
  NSInteger httpPort = _boot.httpPort > 0 ? _boot.httpPort : 47180;
  NSArray *probed = @[ @[ @"http", @(httpPort) ], @[ @"https", @47443 ], @[ @"mesh", @47172 ] ];
  for (NSArray *entry in probed) {
    NSNumber *open = [_ports objectForKey:[entry objectAtIndex:1]];
    NSString *state = open == nil ? @"…"
        : ([open boolValue] ? @"LISTEN" : [texts ts:@"info.port_closed"]);
    NSMutableDictionary *row = [DBInfoRow(
        [NSString stringWithFormat:@"%@ %@", [entry objectAtIndex:0], [entry objectAtIndex:1]],
        state) mutableCopy];
    if ([open boolValue]) [row setObject:@YES forKey:kRowCheck];
    [ports addObject:row];
  }
  [ports addObject:DBInfoRow([NSString stringWithFormat:@"sip %ld", (long)_boot.directPort],
                             [texts ts:@"info.sip_direct"])];
  [sections addObject:DBInfoSection([texts ts:@"info.ports"], nil, ports)];

  NSDictionary *trig =
      [dbg isKindOfClass:[NSDictionary class]] ? [dbg objectForKey:@"triggers"] : nil;
  if ([trig isKindOfClass:[NSDictionary class]]) {
    NSMutableArray *triggers = [NSMutableArray array];
    [triggers addObject:DBInfoRow([texts ts:@"info.total_press"],
        [NSString stringWithFormat:@"%@", [trig objectForKey:@"total_press"] ?: @0])];
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
      [triggers addObject:DBInfoRow([texts ts:@"info.last_press"],
          [NSString stringWithFormat:@"%@  door=%@", timeStr,
                                     [last objectForKey:@"door"] ?: @"-"])];
    } else {
      [triggers addObject:DBInfoRow([texts ts:@"info.last_press"], [texts ts:@"info.no_press"])];
    }
    [sections addObject:DBInfoSection([texts ts:@"info.triggers"], nil, triggers)];
  }

  // Tapping an address points the admin QR below at it.
  NSString *chosen = [self chosenAddress];
  NSMutableArray *addresses = [NSMutableArray array];
  for (NSArray *family in @[ @[ @"IPv4", _v4 ], @[ @"IPv6", _v6 ] ]) {
    for (NSString *address in [family objectAtIndex:1]) {
      NSMutableDictionary *row = [DBInfoRow([family objectAtIndex:0], address) mutableCopy];
      [row setObject:address forKey:kRowAddress];
      if ([address isEqualToString:chosen]) [row setObject:@YES forKey:kRowCheck];
      [addresses addObject:row];
    }
  }
  [sections addObject:DBInfoSection([texts ts:@"info.addresses"],
      [addresses count] == 0 ? [texts ts:@"info.addresses_loading"] : nil, addresses)];

  _sections = sections;
  [_table reloadData];
  [self updateQr];
}

+ (BOOL)isV6:(NSString *)addr {
  return [addr rangeOfString:@":"].location != NSNotFound;
}

- (NSString *)chosenAddress {
  if (_chosenAddress &&
      ([_v4 containsObject:_chosenAddress] || [_v6 containsObject:_chosenAddress]))
    return _chosenAddress;
  if ([_v4 count]) return [_v4 objectAtIndex:0];
  return [_v6 count] ? [_v6 objectAtIndex:0] : nil;
}

- (void)updateQr {
  DBTexts *texts = [_router texts];
  NSString *addr = [self chosenAddress];
  NSString *url = nil;
  if (addr) {
    url = [[self class] isV6:addr]
        ? [NSString stringWithFormat:@"https://[%@]:47443/admin/", addr]
        : [NSString stringWithFormat:@"https://%@:47443/admin/", addr];
  }
  BOOL changed = url == nil ? _qrPayload != nil : ![url isEqualToString:_qrPayload];
  _qrPayload = [url copy];
  if (changed) _qr.image = nil;
  _qrUrl.text = url == nil
      ? [texts ts:@"info.no_address"]
      : [[texts ts:@"info.scan_admin"] stringByAppendingFormat:@"\n%@", url];
  [self layoutQrHost];
  if (!changed || url == nil) return;
  __weak DBInfoScreen *wself = self;
  NSString *want = [url copy];
  // The image view shows the bitmap unscaled, so it is rendered no larger than the view.
  CGFloat tableWidth = _table.bounds.size.width;
  CGFloat side = tableWidth > 0 ? MAX(120, MIN(kQrSide, tableWidth - 40)) : kQrSide;
  // Rasterizing a QR on the A4 main thread visibly stalls the UI.
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    UIImage *img = [DBQrCode imageForString:want targetPx:side];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBInfoScreen *s = wself;
      if (s && [s->_qrPayload isEqualToString:want]) s->_qr.image = img;
    });
  });
}

- (void)onClose {
  [_router closeInfoAnimated:YES];
}

#pragma mark - table

- (NSDictionary *)rowAt:(NSIndexPath *)indexPath {
  NSArray *rows = [[_sections objectAtIndex:(NSUInteger)indexPath.section]
      objectForKey:kSectionRows];
  return [rows objectAtIndex:(NSUInteger)indexPath.row];
}

// The width a cell's labels can use; the grouped inset differs by OS and idiom.
- (CGFloat)cellTextWidth {
  CGFloat width = _table.bounds.size.width;
  if (DBChromeIsFlat()) return width - 30;
  return width - (DBChromeIsPad() && width > 400 ? 110 : 40);
}

// A value that does not fit beside its label moves under it and wraps.
- (BOOL)rowWraps:(NSDictionary *)row {
  CGFloat title = [[row objectForKey:kRowTitle] sizeWithFont:[UIFont boldSystemFontOfSize:17]]
      .width;
  CGFloat value = [[row objectForKey:kRowValue] sizeWithFont:[UIFont systemFontOfSize:17]].width;
  CGFloat accessory = [row objectForKey:kRowCheck] ? 30 : 0;
  return title + value + 24 + accessory > [self cellTextWidth];
}

- (CGFloat)wrappedValueHeight:(NSDictionary *)row {
  CGFloat accessory = [row objectForKey:kRowCheck] ? 30 : 0;
  CGSize size = [[row objectForKey:kRowValue]
           sizeWithFont:[UIFont systemFontOfSize:14]
      constrainedToSize:CGSizeMake([self cellTextWidth] - accessory, 9999)
          lineBreakMode:NSLineBreakByCharWrapping];
  return ceilf(size.height);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  (void)tableView;
  return (NSInteger)[_sections count];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  (void)tableView;
  return (NSInteger)[[[_sections objectAtIndex:(NSUInteger)section] objectForKey:kSectionRows]
      count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
  (void)tableView;
  NSString *title = [[_sections objectAtIndex:(NSUInteger)section] objectForKey:kSectionTitle];
  return [title length] > 0 ? title : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
  (void)tableView;
  NSString *footer = [[_sections objectAtIndex:(NSUInteger)section] objectForKey:kSectionFooter];
  return [footer length] > 0 ? footer : nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
  (void)tableView;
  NSDictionary *row = [self rowAt:indexPath];
  if (![self rowWraps:row]) return 44;
  return MAX(44, 10 + 22 + [self wrappedValueHeight:row] + 10);
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  NSDictionary *row = [self rowAt:indexPath];
  BOOL wraps = [self rowWraps:row];
  NSString *identifier = wraps ? @"wrapped" : @"value";
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
  if (!cell) {
    cell = [[UITableViewCell alloc]
          initWithStyle:wraps ? UITableViewCellStyleSubtitle : UITableViewCellStyleValue1
        reuseIdentifier:identifier];
    if (wraps) {
      cell.detailTextLabel.numberOfLines = 0;
      cell.detailTextLabel.lineBreakMode = NSLineBreakByCharWrapping;
      cell.detailTextLabel.font = [UIFont systemFontOfSize:14];
    }
  }
  cell.textLabel.text = [row objectForKey:kRowTitle];
  cell.detailTextLabel.text = [row objectForKey:kRowValue];
  cell.accessoryType = [row objectForKey:kRowCheck] ? UITableViewCellAccessoryCheckmark
                                                    : UITableViewCellAccessoryNone;
  cell.selectionStyle = [row objectForKey:kRowAddress] ? UITableViewCellSelectionStyleBlue
                                                       : UITableViewCellSelectionStyleNone;
  return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:NO];
  NSString *address = [[self rowAt:indexPath] objectForKey:kRowAddress];
  if (!address || [address isEqualToString:[self chosenAddress]]) return;
  _chosenAddress = [address copy];
  NSMutableArray *sections = [NSMutableArray arrayWithArray:_sections];
  NSMutableDictionary *section = [[sections lastObject] mutableCopy];
  NSMutableArray *rows = [NSMutableArray array];
  for (NSDictionary *row in [section objectForKey:kSectionRows]) {
    NSMutableDictionary *copy = [row mutableCopy];
    if ([[row objectForKey:kRowAddress] isEqualToString:address])
      [copy setObject:@YES forKey:kRowCheck];
    else
      [copy removeObjectForKey:kRowCheck];
    [rows addObject:copy];
  }
  [section setObject:rows forKey:kSectionRows];
  [sections replaceObjectAtIndex:[sections count] - 1 withObject:section];
  _sections = sections;
  [_table reloadData];
  [self updateQr];
}

#pragma mark - layout

// Sizes the QR footer for the table width and hands it back to the table, which is how a
// table learns that its footer height changed.
- (void)layoutQrHost {
  CGFloat width = _table.bounds.size.width;
  if (width <= 0) return;
  CGFloat side = MIN(kQrSide, width - 40);
  CGFloat y = 8;
  BOOL hasQr = _qrPayload != nil;
  _qr.hidden = !hasQr;
  if (hasQr) {
    _qr.frame = CGRectMake(floorf((width - side) / 2), y, side, side);
    y += side + 8;
  }
  CGFloat textHeight = ceilf([_qrUrl sizeThatFits:CGSizeMake(width - 40, 9999)].height);
  _qrUrl.frame = CGRectMake(20, y, width - 40, textHeight);
  y += textHeight + 24;
  _qrHost.frame = CGRectMake(0, 0, width, y);
  _table.tableFooterView = _qrHost;
  _qrHostWidth = width;
}

- (void)layoutSubviews {
  [super layoutSubviews];
  CGRect bounds = self.bounds;
  CGFloat top = [_nav layoutInBounds:bounds];
  CGFloat width = MIN(kColumnMax, bounds.size.width);
  CGRect frame = CGRectMake(floorf((bounds.size.width - width) / 2), top, width,
                            bounds.size.height - top);
  if (!CGRectEqualToRect(_table.frame, frame)) {
    _table.frame = frame;
    // Row heights depend on the table width.
    [_table reloadData];
  }
  if (_qrHostWidth != width) [self layoutQrHost];
}

@end
