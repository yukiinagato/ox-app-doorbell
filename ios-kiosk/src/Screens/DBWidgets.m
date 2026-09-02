#import "DBWidgets.h"

#import "../Core/DBTexts.h"
#import "../Core/DBUiTheme.h"
#import "../Media/DBQrCode.h"

UIColor *DBColorFromHex(NSString *hex, UIColor *fallback) {
  DBRgb rgb;
  if (![DBUiTheme parseHex:hex into:&rgb]) return fallback;
  return [UIColor colorWithRed:(CGFloat)rgb.r green:(CGFloat)rgb.g blue:(CGFloat)rgb.b alpha:1];
}

CGRect DBAspectFitRect(CGRect available, CGSize contentSize) {
  NSArray *rect = [DBUiTheme aspectFitRectForContentWidth:contentSize.width
                                            contentHeight:contentSize.height
                                           availableWidth:available.size.width
                                          availableHeight:available.size.height];
  return CGRectMake(available.origin.x + (CGFloat)[[rect objectAtIndex:0] doubleValue],
                    available.origin.y + (CGFloat)[[rect objectAtIndex:1] doubleValue],
                    (CGFloat)[[rect objectAtIndex:2] doubleValue],
                    (CGFloat)[[rect objectAtIndex:3] doubleValue]);
}

NSString *DBHexFromColor(UIColor *color) {
  if (color == nil) return nil;
  CGColorRef ref = color.CGColor;
  size_t count = CGColorGetNumberOfComponents(ref);
  const CGFloat *parts = CGColorGetComponents(ref);
  if (parts == NULL) return nil;
  DBRgb rgb;
  if (count >= 4) {
    rgb.r = parts[0];
    rgb.g = parts[1];
    rgb.b = parts[2];
  } else if (count >= 2) {
    rgb.r = rgb.g = rgb.b = parts[0];
  } else {
    return nil;
  }
  return [DBUiTheme hexFromRgb:rgb];
}

#pragma mark - palette

@implementation DBUiPalette {
  NSDictionary *_config;
  NSDictionary *_display;
  NSString *_deviceId;
  NSString *_mode;
  NSString *_surfaceHex;
}

@synthesize mode = _mode;
@synthesize surfaceHex = _surfaceHex;

+ (DBUiPalette *)paletteForConfig:(NSDictionary *)config
                         deviceId:(NSString *)deviceId
                          display:(NSDictionary *)display
                    backgroundHex:(NSString *)backgroundHex
                      minuteOfDay:(NSInteger)minuteOfDay {
  DBUiPalette *palette = [[DBUiPalette alloc] init];
  palette->_config = config;
  palette->_display = display;
  palette->_deviceId = [deviceId copy] ?: @"";
  palette->_mode = [[DBUiTheme appearanceModeForConfig:config deviceId:deviceId
                                               display:display
                                           minuteOfDay:minuteOfDay] copy];
  // Core measured the effective background, including averaging a theme image;
  // a caller's own sample is only used when core published none.
  NSString *effective = [DBUiTheme autoBackgroundHexInDisplay:display];
  DBRgb probe;
  if ([effective length] > 0)
    palette->_surfaceHex = [effective copy];
  else
    palette->_surfaceHex = [DBUiTheme parseHex:backgroundHex into:&probe]
        ? [backgroundHex copy]
        : [[DBUiTheme surfaceHexForMode:palette->_mode] copy];
  return palette;
}

- (BOOL)isLight {
  return [_mode isEqualToString:@"light"];
}

- (UIColor *)surface {
  return DBColorFromHex(_surfaceHex, [UIColor blackColor]);
}

- (UIColor *)elevated {
  return [self isLight] ? [UIColor colorWithWhite:0 alpha:0.06]
                        : [UIColor colorWithWhite:1 alpha:0.08];
}

- (UIColor *)separator {
  return [self isLight] ? [UIColor colorWithWhite:0 alpha:0.14]
                        : [UIColor colorWithWhite:1 alpha:0.16];
}

- (UIColor *)ink {
  return DBColorFromHex([DBUiTheme inkHexForMode:_mode], [UIColor whiteColor]);
}

- (UIColor *)mutedInk {
  return DBColorFromHex([DBUiTheme mutedInkHexForMode:_mode],
                        [UIColor colorWithWhite:0.6 alpha:1]);
}

- (UIColor *)accent {
  NSString *hex = [DBUiTheme callButtonHexForConfig:_config deviceId:_deviceId
                                            display:_display backgroundHex:_surfaceHex];
  return DBColorFromHex(hex, [UIColor colorWithRed:0.12 green:0.44 blue:0.70 alpha:1]);
}

- (UIColor *)accentInk {
  return DBColorFromHex([DBUiTheme callButtonInkHexForConfig:_config deviceId:_deviceId
                                                     display:_display
                                               backgroundHex:_surfaceHex],
                        [UIColor whiteColor]);
}

- (UIColor *)danger {
  return [UIColor colorWithRed:0.78 green:0.08 blue:0.06 alpha:1];
}

- (UIColor *)dangerInk {
  return [UIColor whiteColor];
}

- (UIColor *)notice {
  return [self isLight] ? [UIColor colorWithRed:0.98 green:0.86 blue:0.55 alpha:1]
                        : [UIColor colorWithRed:0.62 green:0.47 blue:0.10 alpha:1];
}

- (UIColor *)noticeInk {
  return [self isLight] ? [UIColor colorWithRed:0.20 green:0.14 blue:0.02 alpha:1]
                        : [UIColor whiteColor];
}

- (NSString *)inkHexForRegion:(NSString *)region {
  return [DBUiTheme inkHexForRegion:region config:_config deviceId:_deviceId
                            display:_display backgroundHex:_surfaceHex appearanceMode:_mode];
}

- (UIColor *)inkForRegion:(NSString *)region {
  return DBColorFromHex([self inkHexForRegion:region], [self ink]);
}

- (BOOL)needsShadowForRegion:(NSString *)region {
  return [DBUiTheme needsInkShadowForInk:[self inkHexForRegion:region]
                              background:_surfaceHex];
}

+ (NSString *)averageHexForImage:(UIImage *)image {
  if (image == nil || image.CGImage == NULL) return nil;
  // 16x16 is the sampling budget the spec allows; anything larger is wasted
  // work on an SGX535 and the average is identical to two decimal places.
  const size_t side = 16;
  size_t bpr = side * 4;
  void *buffer = calloc(side * bpr, 1);
  if (buffer == NULL) return nil;
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(buffer, side, side, 8, bpr, space,
                                           (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(space);
  if (ctx == NULL) {
    free(buffer);
    return nil;
  }
  CGContextDrawImage(ctx, CGRectMake(0, 0, side, side), image.CGImage);
  CGContextRelease(ctx);
  unsigned char *pixels = (unsigned char *)buffer;
  double r = 0, g = 0, b = 0;
  for (size_t i = 0; i < side * side; i++) {
    r += pixels[i * 4 + 0];
    g += pixels[i * 4 + 1];
    b += pixels[i * 4 + 2];
  }
  free(buffer);
  double count = (double)(side * side) * 255.0;
  DBRgb average;
  average.r = r / count;
  average.g = g / count;
  average.b = b / count;
  return [DBUiTheme hexFromRgb:average];
}

@end

#pragma mark - padded label

@implementation DBPillLabel

@synthesize contentInsets = _contentInsets;

- (id)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    _contentInsets = UIEdgeInsetsMake((CGFloat)[DBUiTheme pillPaddingVertical],
                                      (CGFloat)[DBUiTheme pillPaddingHorizontal],
                                      (CGFloat)[DBUiTheme pillPaddingVertical],
                                      (CGFloat)[DBUiTheme pillPaddingHorizontal]);
    self.layer.cornerRadius = (CGFloat)[DBUiTheme pillRadius];
    self.clipsToBounds = YES;
  }
  return self;
}

- (void)drawTextInRect:(CGRect)rect {
  [super drawTextInRect:UIEdgeInsetsInsetRect(rect, _contentInsets)];
}

- (CGSize)sizeThatFits:(CGSize)size {
  CGFloat horizontal = _contentInsets.left + _contentInsets.right;
  CGFloat vertical = _contentInsets.top + _contentInsets.bottom;
  CGSize inner = [super sizeThatFits:CGSizeMake(MAX(0, size.width - horizontal),
                                                MAX(0, size.height - vertical))];
  return CGSizeMake(inner.width + horizontal, inner.height + vertical);
}

@end

#pragma mark - two-part button

@implementation DBTwoPartButton {
  UILabel *_secondary;
  CGFloat _secondaryHeight;
}

- (id)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    _secondary = [[UILabel alloc] init];
    _secondary.backgroundColor = [UIColor clearColor];
    _secondary.textAlignment = NSTextAlignmentCenter;
    _secondary.hidden = YES;
    [self addSubview:_secondary];
  }
  return self;
}

- (void)setTwoPartTitle:(NSString *)title {
  NSArray *parts = [DBUiTheme labelPartsFor:title];
  [self setTitle:[parts objectAtIndex:0] forState:UIControlStateNormal];
  NSString *secondary = [parts objectAtIndex:1];
  _secondary.text = secondary;
  _secondary.hidden = ([secondary length] == 0);
  [self setNeedsLayout];
}

- (void)setPrimaryColor:(UIColor *)primary secondaryColor:(UIColor *)secondary {
  [self setTitleColor:primary forState:UIControlStateNormal];
  _secondary.textColor = secondary;
}

- (void)layoutSubviews {
  CGFloat primarySize = self.titleLabel.font.pointSize;
  CGFloat secondarySize = MAX(11, primarySize * (CGFloat)[DBUiTheme secondaryFontScale]);
  _secondary.font = [UIFont systemFontOfSize:secondarySize];
  _secondaryHeight = _secondary.hidden ? 0 : secondarySize + 4;
  // The primary title is lifted by exactly the second line's height so the
  // pair reads as one centred block instead of overlapping.
  self.titleEdgeInsets = UIEdgeInsetsMake(-_secondaryHeight, 0, _secondaryHeight, 0);
  [super layoutSubviews];
  CGSize size = self.bounds.size;
  _secondary.frame = CGRectMake(4, size.height / 2 + (primarySize / 2) - 2,
                                MAX(0, size.width - 8), _secondaryHeight);
}

@end

#pragma mark - SOS slider

@implementation DBSosSlider {
  DBSosSlideModel *_model;
  DBTexts *_texts;
  UIView *_track;
  UIView *_fill;
  UIView *_thumb;
  UILabel *_hint;
  UILabel *_hintSecondary;
  UILabel *_countdown;
  UILabel *_cancelHint;
  NSTimer *_timer;
  CGFloat _thumbSide;
  UIColor *_danger;
  UIColor *_dangerInk;
  UIColor *_trackColor;
}

- (id)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    _model = [[DBSosSlideModel alloc] init];
    _thumbSide = 56;
    _danger = [UIColor colorWithRed:0.78 green:0.08 blue:0.06 alpha:1];
    _dangerInk = [UIColor whiteColor];
    _trackColor = [UIColor colorWithWhite:1 alpha:0.14];

    _track = [[UIView alloc] init];
    _track.layer.cornerRadius = 14;
    _track.clipsToBounds = YES;
    [self addSubview:_track];

    _fill = [[UIView alloc] init];
    [_track addSubview:_fill];

    _hint = [[UILabel alloc] init];
    _hint.backgroundColor = [UIColor clearColor];
    _hint.textAlignment = NSTextAlignmentCenter;
    _hint.font = [UIFont boldSystemFontOfSize:20];
    [_track addSubview:_hint];

    _hintSecondary = [[UILabel alloc] init];
    _hintSecondary.backgroundColor = [UIColor clearColor];
    _hintSecondary.textAlignment = NSTextAlignmentCenter;
    _hintSecondary.font = [UIFont systemFontOfSize:16];
    [_track addSubview:_hintSecondary];

    _thumb = [[UIView alloc] init];
    _thumb.layer.cornerRadius = 12;
    [self addSubview:_thumb];

    _countdown = [[UILabel alloc] init];
    _countdown.backgroundColor = [UIColor clearColor];
    _countdown.textAlignment = NSTextAlignmentCenter;
    _countdown.font = [UIFont boldSystemFontOfSize:26];
    _countdown.hidden = YES;
    [self addSubview:_countdown];

    _cancelHint = [[UILabel alloc] init];
    _cancelHint.backgroundColor = [UIColor clearColor];
    _cancelHint.textAlignment = NSTextAlignmentCenter;
    _cancelHint.font = [UIFont boldSystemFontOfSize:18];
    _cancelHint.hidden = YES;
    [self addSubview:_cancelHint];

    [self applyState];
  }
  return self;
}

- (void)dealloc {
  [_timer invalidate];
}

- (DBSosPhase)phase {
  return _model.phase;
}

- (void)applyConfig:(NSDictionary *)config texts:(DBTexts *)texts {
  [_model configureFromConfig:config];
  _texts = texts;
  [self applyState];
}

- (void)applyPalette:(DBUiPalette *)palette {
  _danger = palette.danger;
  _dangerInk = palette.dangerInk;
  _trackColor = palette.elevated;
  [self applyState];
}

- (void)reset {
  [_timer invalidate];
  _timer = nil;
  [_model reset];
  [self applyState];
}

- (void)applyState {
  BOOL counting = (_model.phase == DBSosPhaseCountdown);
  _track.backgroundColor = _trackColor;
  _fill.backgroundColor = [_danger colorWithAlphaComponent:0.55];
  _thumb.backgroundColor = _danger;
  _hint.textColor = _dangerInk;
  _hintSecondary.textColor = [_dangerInk colorWithAlphaComponent:0.75];
  _countdown.textColor = _dangerInk;
  _cancelHint.textColor = [_dangerInk colorWithAlphaComponent:0.85];

  NSArray *parts = [DBUiTheme labelPartsFor:[_texts ts:@"sos.slide_hint"]];
  _hint.text = [parts objectAtIndex:0];
  _hintSecondary.text = [parts objectAtIndex:1];
  _hintSecondary.hidden = ([[parts objectAtIndex:1] length] == 0) || counting;
  _hint.hidden = counting;
  _thumb.hidden = counting;
  _countdown.hidden = !counting;
  _cancelHint.hidden = !counting;
  if (counting) {
    _track.backgroundColor = _danger;
    _countdown.text = [_texts t:@"sos.countdown",
        [NSString stringWithFormat:@"%ld", (long)_model.remainingSeconds], nil];
    _cancelHint.text = [_texts ts:@"emergency.cancel"];
  }
  [self setNeedsLayout];
}

- (void)layoutSubviews {
  [super layoutSubviews];
  CGSize size = self.bounds.size;
  _track.frame = self.bounds;
  CGFloat travel = MAX(0, size.width - _thumbSide - 8);
  CGFloat x = 4 + travel * (CGFloat)_model.fraction;
  _thumb.frame = CGRectMake(x, 4, _thumbSide, MAX(0, size.height - 8));
  _fill.frame = CGRectMake(0, 0, x + _thumbSide / 2, size.height);
  CGFloat textX = _thumbSide + 12;
  CGFloat textW = MAX(0, size.width - textX - 12);
  if (_hintSecondary.hidden) {
    _hint.frame = CGRectMake(textX, 0, textW, size.height);
  } else {
    _hint.frame = CGRectMake(textX, 6, textW, size.height / 2);
    _hintSecondary.frame = CGRectMake(textX, size.height / 2, textW, size.height / 2 - 6);
  }
  _countdown.frame = CGRectMake(8, 4, MAX(0, size.width - 16), size.height / 2);
  _cancelHint.frame = CGRectMake(8, size.height / 2, MAX(0, size.width - 16),
                                 size.height / 2 - 4);
}

- (double)fractionForTouch:(UITouch *)touch {
  CGPoint point = [touch locationInView:self];
  CGFloat travel = MAX(1, self.bounds.size.width - _thumbSide - 8);
  return (point.x - 4 - _thumbSide / 2) / travel;
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
  (void)event;
  if (_model.phase == DBSosPhaseCountdown) {
    // A tap anywhere on the control cancels the countdown; core is never told.
    [_timer invalidate];
    _timer = nil;
    if ([_model cancel]) [self.delegate sosSliderDidCancel:self];
    [self applyState];
    return;
  }
  [_model beginTouch];
  [_model updateFraction:[self fractionForTouch:[touches anyObject]]];
  [self applyState];
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
  (void)event;
  [_model updateFraction:[self fractionForTouch:[touches anyObject]]];
  [self setNeedsLayout];
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
  (void)touches;
  (void)event;
  if (![_model endTouch]) {
    [self applyState];
    return;
  }
  if (_model.phase == DBSosPhaseFired) {
    [self applyState];
    [self.delegate sosSliderDidFire:self];
    [self reset];
    return;
  }
  [self applyState];
  [self.delegate sosSliderDidArm:self];
  [_timer invalidate];
  _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self
                                          selector:@selector(onCountdownTick:)
                                          userInfo:nil repeats:YES];
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
  (void)touches;
  (void)event;
  if (_model.phase == DBSosPhaseSliding) [_model reset];
  [self applyState];
}

- (void)onCountdownTick:(NSTimer *)timer {
  (void)timer;
  BOOL fired = [_model tick];
  [self applyState];
  if (!fired) return;
  [_timer invalidate];
  _timer = nil;
  [self.delegate sosSliderDidFire:self];
  [self reset];
}

- (void)willMoveToSuperview:(UIView *)newSuperview {
  [super willMoveToSuperview:newSuperview];
  // A screen transition must never leave a live one-second timer behind.
  if (newSuperview == nil) [self reset];
}

@end

#pragma mark - admin QR

@implementation DBAdminQrView {
  UIImageView *_image;
  UILabel *_urlLabel;
  UILabel *_caption;
  NSString *_url;
  NSInteger _generation;
}

@synthesize url = _url;

- (id)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    _url = @"";
    _image = [[UIImageView alloc] init];
    _image.backgroundColor = [UIColor whiteColor];
    _image.contentMode = UIViewContentModeScaleAspectFit;
    _image.layer.cornerRadius = 6;
    _image.clipsToBounds = YES;
    _image.accessibilityIdentifier = @"admin_page_qr";
    [self addSubview:_image];

    _caption = [[UILabel alloc] init];
    _caption.backgroundColor = [UIColor clearColor];
    _caption.font = [UIFont systemFontOfSize:12];
    _caption.numberOfLines = 2;
    [self addSubview:_caption];

    _urlLabel = [[UILabel alloc] init];
    _urlLabel.backgroundColor = [UIColor clearColor];
    _urlLabel.font = [UIFont systemFontOfSize:12];
    _urlLabel.numberOfLines = 2;
    _urlLabel.lineBreakMode = NSLineBreakByCharWrapping;
    [self addSubview:_urlLabel];
  }
  return self;
}

- (void)applyPalette:(DBUiPalette *)palette {
  _caption.textColor = palette.mutedInk;
  _urlLabel.textColor = palette.ink;
}

- (void)setUrl:(NSString *)url caption:(NSString *)caption {
  _caption.text = caption ?: @"";
  if ([url length] == 0) {
    _url = @"";
    _image.image = nil;
    _urlLabel.text = @"";
    return;
  }
  _urlLabel.text = url;
  if ([_url isEqualToString:url] && _image.image != nil) return;
  _url = [url copy];
  NSInteger generation = ++_generation;
  NSString *want = [url copy];
  __weak DBAdminQrView *weakSelf = self;
  // QR generation is pure CPU work and must never run on the main thread of an
  // A4 device that is also decoding video.
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
    UIImage *code = [DBQrCode imageForString:want targetPx:160];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBAdminQrView *view = weakSelf;
      if (!view || view->_generation != generation) return;
      view->_image.image = code;
    });
  });
}

- (void)layoutSubviews {
  [super layoutSubviews];
  CGSize size = self.bounds.size;
  CGFloat side = MIN(size.height, MAX(56, size.width * 0.42));
  _image.frame = CGRectMake(0, (size.height - side) / 2, side, side);
  CGFloat textX = side + 10;
  CGFloat textW = MAX(0, size.width - textX);
  _caption.frame = CGRectMake(textX, (size.height - side) / 2, textW, 30);
  _urlLabel.frame = CGRectMake(textX, (size.height - side) / 2 + 30, textW,
                               MAX(0, side - 30));
}

@end

#pragma mark - notice chip

@implementation DBNoticeChip {
  UIView *_dot;
}

- (id)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    self.layer.cornerRadius = (CGFloat)[DBUiTheme pillRadius];
    self.clipsToBounds = YES;
    self.contentEdgeInsets = UIEdgeInsetsMake((CGFloat)[DBUiTheme pillPaddingVertical],
                                              (CGFloat)[DBUiTheme pillPaddingHorizontal] + 14,
                                              (CGFloat)[DBUiTheme pillPaddingVertical],
                                              (CGFloat)[DBUiTheme pillPaddingHorizontal]);
    _dot = [[UIView alloc] init];
    _dot.layer.cornerRadius = 4;
    _dot.hidden = YES;
    _dot.userInteractionEnabled = NO;
    [self addSubview:_dot];
  }
  return self;
}

- (void)setChipTitle:(NSString *)title active:(BOOL)active {
  [self setTitle:title forState:UIControlStateNormal];
  _dot.hidden = !active;
  [self setNeedsLayout];
}

- (void)applyPalette:(DBUiPalette *)palette {
  self.backgroundColor = palette.elevated;
  [self setTitleColor:palette.ink forState:UIControlStateNormal];
  _dot.backgroundColor = palette.notice;
}

- (void)layoutSubviews {
  [super layoutSubviews];
  _dot.frame = CGRectMake(10, (self.bounds.size.height - 8) / 2, 8, 8);
  [self bringSubviewToFront:_dot];
}

@end
