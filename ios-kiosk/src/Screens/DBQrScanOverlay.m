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


void DBH264Dbg(NSString *fmt, ...);

@implementation DBQrScanOverlay {
  DBCoreBridge *_core;
  DBTexts *_texts;
  UIView *_previewHost;
  CALayer *_preview;
  UIView *_finder;
  UILabel *_hint;
  UILabel *_status;
  UIButton *_cancel;
  UIButton *_switchCamera;
  AVCaptureDevicePosition _originalPosition;
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

// iOS 7+ reads QR codes with AVFoundation's own detector, the one the iOS app uses. Only
// iOS 5/6 fall back to Core's decoder fed with camera frames.
+ (BOOL)nativeDetectorAvailable {
  return NSClassFromString(@"AVCaptureMetadataOutput") != nil;
}

+ (NSDictionary *)parsePairPayload:(NSString *)text {
  static NSString *const kPrefix = @"doorbell-pair:";
  if (![text isKindOfClass:[NSString class]] || ![text hasPrefix:kPrefix]) return nil;
  NSArray *parts = [[text substringFromIndex:[kPrefix length]] componentsSeparatedByString:@"|"];
  if ([parts count] < 3) return nil;
  NSString *addr = [parts objectAtIndex:0];
  NSString *identifier = [parts objectAtIndex:1];
  NSString *pk = [parts objectAtIndex:[parts count] - 1];
  if ([addr length] == 0 || [identifier length] == 0 || [pk length] != 64) return nil;
  return @{ @"addr" : addr, @"id" : identifier, @"pk" : pk };
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

    // A wall-mounted panel cannot be turned around, and a phone held up to the front lens is
    // awkward, so the scanner opens on the back camera and can flip to the front one.
    _switchCamera = [UIButton buttonWithType:UIButtonTypeCustom];
    _switchCamera.backgroundColor = [UIColor colorWithWhite:0.22 alpha:1];
    _switchCamera.layer.cornerRadius = 10;
    _switchCamera.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    [_switchCamera setTitle:[_texts ts:@"pair.scan_switch_camera"] forState:UIControlStateNormal];
    [_switchCamera setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [_switchCamera addTarget:self action:@selector(onSwitchCamera)
            forControlEvents:UIControlEventTouchUpInside];
    _switchCamera.accessibilityIdentifier = @"qr_scan_switch_camera";
    _switchCamera.hidden = ![DBCameraFeeder canSwitchPosition];
    [self addSubview:_switchCamera];
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
  _originalPosition = camera.preferredPosition;
  [self useCameraPosition:[DBCameraFeeder canSwitchPosition] ? AVCaptureDevicePositionBack
                                                             : _originalPosition];
  [self arm];
  _tick = [NSTimer scheduledTimerWithTimeInterval:kTickS target:self selector:@selector(onTick:)
                                         userInfo:nil repeats:YES];
  [self onTick:nil];
}

// Points the shared camera at one lens. A door station's running capture is restarted on the
// requested lens; dismiss puts its original lens back.
- (void)useCameraPosition:(AVCaptureDevicePosition)position {
  DBCameraFeeder *camera = [self camera];
  camera.preferredPosition = position;
  [self installDetector];
  BOOL detectorReady = ![DBQrScanOverlay nativeDetectorAvailable] || camera.qrDetectorActive;
  if (camera.running && camera.activePosition == position && detectorReady) return;
  [_preview removeFromSuperlayer];
  _preview = nil;
  _openedAt = [NSDate date];
  _status.text = [_texts ts:@"pair.scan_opening"];
  if (camera.running) [camera stop];
  [camera start];
}

- (void)onSwitchCamera {
  if (_finished || _failed) return;
  DBCameraFeeder *camera = [self camera];
  AVCaptureDevicePosition next = camera.activePosition == AVCaptureDevicePositionFront
      ? AVCaptureDevicePositionBack : AVCaptureDevicePositionFront;
  [self useCameraPosition:next];
}

- (void)arm {
  _armedAt = [NSDate date];
  if (![DBQrScanOverlay nativeDetectorAvailable]) [_core qrScanStart];
}

- (void)installDetector {
  if (![DBQrScanOverlay nativeDetectorAvailable]) return;
  __weak DBQrScanOverlay *weakSelf = self;
  [self camera].onQrCode = ^(NSString *text) { [weakSelf handleDecodedText:text]; };
}

- (void)removeDetector {
  [self camera].onQrCode = nil;
}

- (void)handleDecodedText:(NSString *)text {
  if (_finished || _failed) return;
  NSDictionary *payload = [DBQrScanOverlay parsePairPayload:text];
  if (!payload) {
    _status.text = [_texts ts:@"pair.scan_not_device_qr"];
    return;
  }
  DBH264Dbg(@"[qr] scanned Add QR for %@ at %@; inviting", [payload objectForKey:@"id"],
            [payload objectForKey:@"addr"]);
  [_core inviteDirectAddr:[payload objectForKey:@"addr"]
                   nodeId:[payload objectForKey:@"id"]
                publicKey:[payload objectForKey:@"pk"]];
  [self finishWithId:[payload objectForKey:@"id"] addr:[payload objectForKey:@"addr"]];
}

// The preview follows the screen, not the sensor; a landscape panel otherwise shows it rotated.
- (void)applyPreviewOrientation {
  if (!_preview) return;
  AVCaptureVideoOrientation orientation =
      (AVCaptureVideoOrientation)[[UIApplication sharedApplication] statusBarOrientation];
  if (orientation < AVCaptureVideoOrientationPortrait ||
      orientation > AVCaptureVideoOrientationLandscapeLeft) return;
  AVCaptureVideoPreviewLayer *layer = (AVCaptureVideoPreviewLayer *)_preview;
  if ([layer respondsToSelector:@selector(connection)]) {
    AVCaptureConnection *connection = layer.connection;
    if (connection.isVideoOrientationSupported) connection.videoOrientation = orientation;
  } else if ([layer respondsToSelector:@selector(setOrientation:)]) {
    // iOS 5: the pre-iOS 6 property on the layer itself.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    layer.orientation = orientation;
#pragma clang diagnostic pop
  }
}

- (void)onTick:(NSTimer *)timer {
  (void)timer;
  if (_finished || _failed) return;
  DBCameraFeeder *camera = [self camera];
  if (camera.running && _preview == nil) {
    _preview = [camera newPreviewLayer];
    if (_preview) {
      _preview.frame = _previewHost.bounds;
      [self applyPreviewOrientation];
      [_previewHost.layer addSublayer:_preview];
      DBH264Dbg(@"[qr] preview up; AVFoundation detector=%d", (int)camera.qrDetectorActive);
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
  DBCameraFeeder *camera = [self camera];
  AVCaptureDevicePosition original = _originalPosition;
  BOOL hadDetector = camera.qrDetectorActive;
  [self removeDetector];
  if (_ownsCamera) {
    [camera stop];
  } else if (camera.running && original != AVCaptureDevicePositionUnspecified &&
             (camera.activePosition != original || hadDetector)) {
    // Hand a door station back its visitor lens.
    camera.preferredPosition = original;
    [camera stop];
    [camera start];
  }
  if (original != AVCaptureDevicePositionUnspecified) camera.preferredPosition = original;
  _ownsCamera = NO;
  _originalPosition = AVCaptureDevicePositionUnspecified;
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
  [self applyPreviewOrientation];
  CGFloat side = MIN(MIN(size.width, size.height) * 0.6, 420);
  _finder.frame = CGRectMake((size.width - side) / 2, (size.height - side) / 2 - 20, side, side);
  CGFloat hintHeight = [_hint sizeThatFits:CGSizeMake(width, 9999)].height;
  CGFloat top = _failed ? (size.height - hintHeight) / 2 - 40 : 36;
  _hint.frame = CGRectMake(pad, top, width, hintHeight);
  CGFloat statusHeight = [_status sizeThatFits:CGSizeMake(width, 9999)].height;
  _status.frame = CGRectMake(pad, CGRectGetMaxY(_finder.frame) + 16, width, statusHeight);
  if (_switchCamera.hidden || _failed) {
    _switchCamera.hidden = YES;
    _cancel.frame = CGRectMake((size.width - 220) / 2, size.height - 84, 220, 56);
  } else {
    CGFloat buttonWidth = 220, gap = 16;
    CGFloat left = (size.width - buttonWidth * 2 - gap) / 2;
    _switchCamera.frame = CGRectMake(left, size.height - 84, buttonWidth, 56);
    _cancel.frame = CGRectMake(left + buttonWidth + gap, size.height - 84, buttonWidth, 56);
  }
}

@end
