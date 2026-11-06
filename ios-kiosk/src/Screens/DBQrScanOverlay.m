#import "DBQrScanOverlay.h"
#import <AVFoundation/AVFoundation.h>
#import "../Core/DBConfigUtil.h"
#import "../Core/DBCoreBridge.h"
#import "../Core/DBTexts.h"
#import "../Media/DBCameraFeeder.h"
#import "../Support/DBAppDelegate.h"

static const NSTimeInterval kTickS = 0.25;
// Core stops scanning by itself after two minutes; re-arm well before that while visible.
static const NSTimeInterval kRearmS = 60;
// A camera that has not come up by then is reported instead of leaving a black square.
static const NSTimeInterval kCameraStartBudgetS = 5;

@implementation DBQrScanOverlay {
  DBCoreBridge *_core;
  DBTexts *_texts;
  UIView *_previewHost;
  CALayer *_preview;
  UIView *_finder;
  UILabel *_hint;
  UILabel *_status;
  UIButton *_cancel;
  NSTimer *_tick;
  NSDate *_openedAt;
  NSDate *_armedAt;
  BOOL _ownsCamera;
  BOOL _finished;
  BOOL _failed;
}

+ (BOOL)cameraAvailable {
  return [[AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo] count] > 0;
}

+ (NSDictionary *)parsePairPayload:(NSString *)text {
  static NSString *const kPrefix = @"doorbell-pair:";
  if (![text isKindOfClass:[NSString class]] || ![text hasPrefix:kPrefix]) return nil;
  NSArray *parts = [[text substringFromIndex:[kPrefix length]] componentsSeparatedByString:@"|"];
  if ([parts count] < 3) return nil;
  NSString *addr = [parts objectAtIndex:0];
  NSString *identifier = [parts objectAtIndex:1];
  if ([addr length] == 0 || [identifier length] == 0) return nil;
  return @{ @"addr" : addr, @"id" : identifier };
}

- (id)initWithCore:(DBCoreBridge *)core texts:(DBTexts *)texts {
  self = [super initWithFrame:CGRectZero];
  if (self) {
    _core = core;
    _texts = texts;
    self.backgroundColor = [UIColor blackColor];
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    _previewHost = [[UIView alloc] init];
    _previewHost.backgroundColor = [UIColor blackColor];
    _previewHost.clipsToBounds = YES;
    [self addSubview:_previewHost];

    _finder = [[UIView alloc] init];
    _finder.backgroundColor = [UIColor clearColor];
    _finder.userInteractionEnabled = NO;
    _finder.layer.borderColor = [UIColor colorWithRed:0.30 green:0.64 blue:1 alpha:1].CGColor;
    _finder.layer.borderWidth = 4;
    _finder.layer.cornerRadius = 12;
    [self addSubview:_finder];

    _hint = [self label:[UIFont boldSystemFontOfSize:20]];
    _hint.text = [_texts ts:@"pair.scan_hint"];
    [self addSubview:_hint];

    _status = [self label:[UIFont systemFontOfSize:16]];
    _status.textColor = [UIColor colorWithWhite:0.8 alpha:1];
    _status.text = [_texts ts:@"pair.scan_opening"];
    [self addSubview:_status];

    _cancel = [UIButton buttonWithType:UIButtonTypeCustom];
    _cancel.backgroundColor = [UIColor colorWithWhite:0.22 alpha:1];
    _cancel.layer.cornerRadius = 10;
    _cancel.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    [_cancel setTitle:[_texts ts:@"pair.scan_cancel"] forState:UIControlStateNormal];
    [_cancel setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [_cancel addTarget:self action:@selector(onCancel)
      forControlEvents:UIControlEventTouchUpInside];
    _cancel.accessibilityIdentifier = @"qr_scan_cancel";
    [self addSubview:_cancel];
  }
  return self;
}

- (UILabel *)label:(UIFont *)font {
  UILabel *label = [[UILabel alloc] init];
  label.font = font;
  label.textColor = [UIColor whiteColor];
  label.backgroundColor = [UIColor clearColor];
  label.textAlignment = NSTextAlignmentCenter;
  label.numberOfLines = 0;
  return label;
}

- (DBCameraFeeder *)camera {
  id delegate = [[UIApplication sharedApplication] delegate];
  if (![delegate respondsToSelector:@selector(sharedCamera)]) return nil;
  return [(DBAppDelegate *)delegate sharedCamera];
}

- (BOOL)cameraPermissionDenied {
  if (![AVCaptureDevice respondsToSelector:@selector(authorizationStatusForMediaType:)])
    return NO;  // iOS 5/6: no per-app camera permission
  AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
  return status == AVAuthorizationStatusDenied || status == AVAuthorizationStatusRestricted;
}

- (void)presentInView:(UIView *)host {
  self.frame = host.bounds;
  [host addSubview:self];
  _openedAt = [NSDate date];
  if (![DBQrScanOverlay cameraAvailable]) {
    [self fail:@"pair.scan_no_camera"];
    return;
  }
  if ([self cameraPermissionDenied]) {
    [self fail:@"pair.scan_camera_denied"];
    return;
  }
  DBCameraFeeder *camera = [self camera];
  if (!camera) {
    [self fail:@"pair.scan_no_camera"];
    return;
  }
  _ownsCamera = !camera.running;
  if (_ownsCamera) [camera start];
  [self arm];
  _tick = [NSTimer scheduledTimerWithTimeInterval:kTickS target:self selector:@selector(onTick:)
                                         userInfo:nil repeats:YES];
  [self onTick:nil];
}

- (void)arm {
  _armedAt = [NSDate date];
  [_core qrScanStart];
}

- (void)onTick:(NSTimer *)timer {
  (void)timer;
  if (_finished || _failed) return;
  DBCameraFeeder *camera = [self camera];
  if (camera.running && _preview == nil) {
    _preview = [camera newPreviewLayer];
    if (_preview) {
      _preview.frame = _previewHost.bounds;
      [_previewHost.layer addSublayer:_preview];
      _status.text = [_texts ts:@"pair.scanning"];
    }
  } else if (!camera.running && _preview != nil) {
    // The session went away underneath us (backgrounded, interrupted): start over.
    [_preview removeFromSuperlayer];
    _preview = nil;
    _status.text = [_texts ts:@"pair.scan_opening"];
    if (_ownsCamera && [UIApplication sharedApplication].applicationState ==
                           UIApplicationStateActive) [camera start];
  }
  if (_preview == nil && -[_openedAt timeIntervalSinceNow] > kCameraStartBudgetS) {
    [self fail:[self cameraPermissionDenied] ? @"pair.scan_camera_denied"
                                             : @"pair.scan_no_camera"];
    return;
  }
  if (-[_armedAt timeIntervalSinceNow] > kRearmS) [self arm];
}

- (void)fail:(NSString *)key {
  _failed = YES;
  [_tick invalidate];
  _tick = nil;
  [_core qrScanStop];
  [self releaseCamera];
  _finder.hidden = YES;
  _hint.text = [_texts ts:key];
  _status.text = @"";
  [self setNeedsLayout];
}

- (void)handleQrScanned:(NSDictionary *)ev {
  if (_finished) return;
  NSString *text = [DBConfigUtil evStr:ev key:@"text"];
  NSDictionary *payload = [DBQrScanOverlay parsePairPayload:text];
  if ([DBConfigUtil evBool:ev key:@"invited"] && payload) {
    [self finishWithId:[payload objectForKey:@"id"] addr:[payload objectForKey:@"addr"]];
    return;
  }
  // Any other QR (a pairing link, a URL): say so and keep scanning.
  _status.text = [_texts ts:@"pair.scan_not_device_qr"];
}

- (void)handleQrScanState:(NSDictionary *)ev {
  if (_finished || _failed) return;
  // Core's two-minute limit ran out while we were still open: re-arm at once.
  if (![DBConfigUtil evBool:ev key:@"active"]) [self arm];
}

- (void)onCancel {
  [self finishWithId:nil addr:nil];
}

- (void)finishWithId:(NSString *)identifier addr:(NSString *)addr {
  if (_finished) return;
  _finished = YES;
  [self dismiss];
  void (^done)(NSString *, NSString *) = self.onFinished;
  self.onFinished = nil;
  if (done) done(identifier, addr);
}

- (void)releaseCamera {
  if (_ownsCamera) [[self camera] stop];
  _ownsCamera = NO;
}

- (void)dismiss {
  [_tick invalidate];
  _tick = nil;
  [_core qrScanStop];
  [_preview removeFromSuperlayer];
  _preview = nil;
  [self releaseCamera];
  [self removeFromSuperview];
}

- (void)layoutSubviews {
  [super layoutSubviews];
  CGSize size = self.bounds.size;
  CGFloat pad = 24;
  CGFloat width = size.width - pad * 2;
  _previewHost.frame = self.bounds;
  _preview.frame = _previewHost.bounds;
  CGFloat side = MIN(MIN(size.width, size.height) * 0.6, 420);
  _finder.frame = CGRectMake((size.width - side) / 2, (size.height - side) / 2 - 20, side, side);
  CGFloat hintHeight = [_hint sizeThatFits:CGSizeMake(width, 9999)].height;
  CGFloat top = _failed ? (size.height - hintHeight) / 2 - 40 : 36;
  _hint.frame = CGRectMake(pad, top, width, hintHeight);
  CGFloat statusHeight = [_status sizeThatFits:CGSizeMake(width, 9999)].height;
  _status.frame = CGRectMake(pad, CGRectGetMaxY(_finder.frame) + 16, width, statusHeight);
  _cancel.frame = CGRectMake((size.width - 220) / 2, size.height - 84, 220, 56);
}

@end
