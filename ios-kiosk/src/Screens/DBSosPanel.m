#import "DBSosPanel.h"

#import "../Core/DBIconAsset.h"
#import "../Core/DBTexts.h"
#import "DBChrome.h"

static const NSTimeInterval kSosPanelIdleCloseS = 10.0;

static UIColor *DBSosNegativeColor(void) {
  return [UIColor colorWithRed:0.78f green:0.08f blue:0.06f alpha:1];
}

UIButton *DBSosTriggerButton(void) {
  UIButton *button = DBChromeButton(@"SOS", 18);
  UIColor *negative = DBSosNegativeColor();
  [button setTitleColor:negative forState:UIControlStateNormal];
  UIImage *icon = [DBIconAsset tintedImageNamed:@"bell" color:negative
                                           size:CGSizeMake(22, 22)];
  if (icon) {
    [button setImage:icon forState:UIControlStateNormal];
    button.titleEdgeInsets = UIEdgeInsetsMake(0, 8, 0, 0);
  }
  if (DBChromeIsFlat()) {
    // The flat system button is bare text; the outline is what makes it a control on a
    // wallpaper.
    button.backgroundColor = [UIColor whiteColor];
    button.layer.cornerRadius = 8;
    button.layer.borderWidth = 1;
    button.layer.borderColor = negative.CGColor;
  }
  return button;
}

@implementation DBSosPanel {
  DBSosSlider *_slider;
  __weak id<DBSosSliderDelegate> _forward;
  UIView *_panel;
  DBNavBar *_nav;
  UILabel *_message;
  NSTimer *_idleTimer;
}

- (id)initWithSlider:(DBSosSlider *)slider delegate:(id<DBSosSliderDelegate>)delegate {
  self = [super initWithFrame:CGRectZero];
  if (self) {
    _slider = slider;
    _forward = delegate;
    _slider.delegate = self;
    self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.accessibilityViewIsModal = YES;

    _panel = [[UIView alloc] init];
    _panel.backgroundColor = DBChromeScreenBackground();
    _panel.clipsToBounds = YES;
    [self addSubview:_panel];
    DBChromeInstallBackdrop(_panel);

    _message = DBChromeSectionFooterLabel();
    _message.font = [UIFont systemFontOfSize:17];
    _message.textAlignment = NSTextAlignmentCenter;
    [_panel addSubview:_message];

    _nav = [[DBNavBar alloc] init];
    [_panel addSubview:_nav.bar];
    UINavigationItem *item = [_nav setRootTitle:@"SOS" backTitle:nil onBack:nil];
    item.leftBarButtonItem = DBChromeBarItem(@"", self, @selector(onCancel));
  }
  return self;
}

- (void)dealloc {
  [_idleTimer invalidate];
}

- (BOOL)presented {
  return self.superview != nil;
}

- (void)applyTexts:(DBTexts *)texts {
  _nav.topItem.title = [texts ts:@"sos.title"];
  [_nav.topItem.leftBarButtonItem setTitle:[texts ts:@"sos.abort"]];
  _message.text = [texts ts:@"sos.hint"];
  [self setNeedsLayout];
}

- (void)presentInView:(UIView *)host below:(UIView *)below {
  if (host == nil) return;
  [_slider reset];
  self.frame = host.bounds;
  if (below != nil && below.superview == host)
    [host insertSubview:self belowSubview:below];
  else
    [host addSubview:self];
  _slider.hidden = NO;
  [_panel addSubview:_slider];
  [self setNeedsLayout];
  [self restartIdleTimer];
}

- (void)dismiss {
  [_idleTimer invalidate];
  _idleTimer = nil;
  if (self.superview == nil) return;
  [_slider reset];
  [self removeFromSuperview];
}

- (void)onCancel {
  [self dismiss];
}

- (void)restartIdleTimer {
  [_idleTimer invalidate];
  _idleTimer = [NSTimer scheduledTimerWithTimeInterval:kSosPanelIdleCloseS target:self
                                              selector:@selector(onIdleTimer:) userInfo:nil
                                               repeats:NO];
}

- (void)onIdleTimer:(NSTimer *)timer {
  if (timer != _idleTimer) return;
  _idleTimer = nil;
  // A finger still on the knob is input; a running countdown has its own Cancel.
  if (_slider.phase == DBSosPhaseSliding) {
    [self restartIdleTimer];
    return;
  }
  if (_slider.phase == DBSosPhaseIdle) [self dismiss];
}

- (void)layoutSubviews {
  [super layoutSubviews];
  CGRect bounds = self.bounds;
  CGFloat width = MIN(480, bounds.size.width - 24);
  CGFloat inner = width - 40;
  CGFloat messageHeight = ceilf([_message sizeThatFits:CGSizeMake(inner, CGFLOAT_MAX)].height);
  CGFloat navHeight = DBChromeNavBarHeight();
  CGFloat sliderHeight = 62;
  CGFloat height = MIN(bounds.size.height - 24,
                       navHeight + 20 + messageHeight + 20 + sliderHeight + 24);
  _panel.frame = CGRectMake(floorf((bounds.size.width - width) / 2),
                            floorf((bounds.size.height - height) / 2), width, height);
  [_nav layoutInBounds:_panel.bounds];
  // The slide keeps its place at the bottom edge; the text gives way on a short screen.
  CGFloat sliderY = height - 24 - sliderHeight;
  _slider.frame = CGRectMake(20, sliderY, inner, sliderHeight);
  _message.frame = CGRectMake(20, navHeight + 20, inner,
                              MAX(0, MIN(messageHeight, sliderY - 20 - (navHeight + 20))));
}

#pragma mark - slider callbacks, forwarded to the screen

- (void)sosSliderDidArm:(DBSosSlider *)slider {
  [_idleTimer invalidate];
  _idleTimer = nil;
  [_forward sosSliderDidArm:slider];
}

- (void)sosSliderDidCancel:(DBSosSlider *)slider {
  [_forward sosSliderDidCancel:slider];
  [self dismiss];
}

- (void)sosSliderDidFire:(DBSosSlider *)slider {
  [_forward sosSliderDidFire:slider];
  [self dismiss];
}

@end
