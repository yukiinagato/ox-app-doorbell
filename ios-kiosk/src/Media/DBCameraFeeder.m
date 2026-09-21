#import "DBCameraFeeder.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <UIKit/UIKit.h>

@interface DBCameraFeeder () <AVCaptureVideoDataOutputSampleBufferDelegate>
@end

@implementation DBCameraFeeder {
  AVCaptureSession *_session;
  dispatch_queue_t _queue;
  void (^_frameHandler)(NSData *, int, int, int, int);
  void (^_stateHandler)(BOOL, NSString *);
  BOOL _accepting;
  BOOL _reportedActive;
  CFAbsoluteTime _lastFrame;
}

- (id)initWithFrameHandler:(void (^)(NSData *, int, int, int, int))frameHandler
              stateHandler:(void (^)(BOOL, NSString *))stateHandler {
  self = [super init];
  if (self) {
    _frameHandler = [frameHandler copy];
    _stateHandler = [stateHandler copy];
    _queue = dispatch_queue_create("doorbell.camera", DISPATCH_QUEUE_SERIAL);
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(runtimeError:)
        name:AVCaptureSessionRuntimeErrorNotification object:nil];
  }
  return self;
}

- (void)report:(BOOL)active reason:(NSString *)reason {
  dispatch_async(dispatch_get_main_queue(), ^{
    @synchronized(self) { if (active && !self->_accepting) return; }
    if (self->_stateHandler) self->_stateHandler(active, reason);
  });
}

- (void)runtimeError:(NSNotification *)note {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (note.object != self->_session) return;
    [self stop]; [self report:NO reason:@"runtime_failed"];
  });
}

- (void)start {
  if (_session) return;
  if ([AVCaptureDevice respondsToSelector:@selector(authorizationStatusForMediaType:)]) {
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (status == AVAuthorizationStatusNotDetermined) {
      __weak DBCameraFeeder *weakSelf = self;
      [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{
          if (granted && [UIApplication sharedApplication].applicationState == UIApplicationStateActive)
            [weakSelf start];
          else [weakSelf report:NO reason:@"permission_denied"];
        });
      }];
      return;
    }
    if (status != AVAuthorizationStatusAuthorized) { [self report:NO reason:@"permission_denied"]; return; }
  }
  AVCaptureDevice *device = nil;
  for (AVCaptureDevice *candidate in [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]) {
    if (!device || candidate.position == AVCaptureDevicePositionFront) device = candidate;
    if (candidate.position == AVCaptureDevicePositionFront) break;
  }
  if (!device) { [self report:NO reason:@"no_device"]; return; }
  AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:NULL];
  AVCaptureSession *session = [[AVCaptureSession alloc] init];
  if (!input || ![session canAddInput:input]) { [self report:NO reason:@"input_failed"]; return; }
  if ([session respondsToSelector:@selector(setAutomaticallyConfiguresApplicationAudioSession:)])
    session.automaticallyConfiguresApplicationAudioSession = NO;
  [session beginConfiguration];
  if ([session canSetSessionPreset:AVCaptureSessionPreset640x480])
    session.sessionPreset = AVCaptureSessionPreset640x480;
  else session.sessionPreset = AVCaptureSessionPresetLow;
  [session addInput:input];
  AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
  BOOL nativeYUV = [output.availableVideoCVPixelFormatTypes containsObject:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)];
  OSType format = nativeYUV ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA;
  output.videoSettings = @{(NSString *)kCVPixelBufferPixelFormatTypeKey: @(format)};
  output.alwaysDiscardsLateVideoFrames = YES;
  [output setSampleBufferDelegate:self queue:_queue];
  if (![session canAddOutput:output]) {
    [session commitConfiguration]; [self report:NO reason:@"output_failed"]; return;
  }
  [session addOutput:output];
  AVCaptureConnection *connection = [output connectionWithMediaType:AVMediaTypeVideo];
  if (connection.isVideoOrientationSupported) connection.videoOrientation = AVCaptureVideoOrientationPortrait;
  if (connection.isVideoMirroringSupported) {
    if ([connection respondsToSelector:@selector(setAutomaticallyAdjustsVideoMirroring:)])
      connection.automaticallyAdjustsVideoMirroring = NO;
    connection.videoMirrored = NO;
  }
  [session commitConfiguration];
  if ([device respondsToSelector:@selector(setActiveVideoMinFrameDuration:)] &&
      [device lockForConfiguration:NULL]) {
    for (AVFrameRateRange *range in device.activeFormat.videoSupportedFrameRateRanges) {
      if (range.minFrameRate <= 30 && range.maxFrameRate >= 30) {
        device.activeVideoMinFrameDuration = CMTimeMake(1, 30);
        device.activeVideoMaxFrameDuration = CMTimeMake(1, 30);
        break;
      }
    }
    [device unlockForConfiguration];
  }
  _session = session;
  @synchronized(self) { _accepting = YES; _reportedActive = NO; _lastFrame = 0; }
  [self report:NO reason:@"starting"];
  dispatch_async(_queue, ^{ [session startRunning]; });
}

- (void)stop {
  @synchronized(self) { _accepting = NO; _reportedActive = NO; }
  AVCaptureSession *session = _session;
  _session = nil;
  if (session) dispatch_async(_queue, ^{
    [session stopRunning];
    if (self->_onCaptureStopped) self->_onCaptureStopped();
  });
  [self report:NO reason:@"stopped"];
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
  (void)output; (void)connection;
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(sampleBuffer);
  if (!pixels) return;
  @synchronized(self) { if (!_accepting) return; }
  if (_onPixelBuffer) _onPixelBuffer(pixels, CMSampleBufferGetPresentationTimeStamp(sampleBuffer));
  @synchronized(self) {
    if (!_accepting || now - _lastFrame < 0.25) return;
    _lastFrame = now;
  }
  if (CVPixelBufferLockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return;
  int width = (int)CVPixelBufferGetWidth(pixels), height = (int)CVPixelBufferGetHeight(pixels);
  BOOL planar = CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
  NSData *data;
  int stride;
  if (planar) {
    stride = width;
    NSMutableData *packed = [NSMutableData dataWithLength:(NSUInteger)width * (height + (height + 1) / 2)];
    uint8_t *destination = [packed mutableBytes];
    for (size_t plane = 0; plane < 2; ++plane) {
      const uint8_t *source = CVPixelBufferGetBaseAddressOfPlane(pixels, plane);
      size_t sourceStride = CVPixelBufferGetBytesPerRowOfPlane(pixels, plane);
      size_t rows = plane == 0 ? height : (height + 1) / 2;
      for (size_t row = 0; row < rows; ++row) {
        memcpy(destination, source + row * sourceStride, width);
        destination += width;
      }
    }
    data = packed;
  } else {
    stride = (int)CVPixelBufferGetBytesPerRow(pixels);
    data = [NSData dataWithBytes:CVPixelBufferGetBaseAddress(pixels) length:(NSUInteger)stride * height];
  }
  CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
  if (_frameHandler) _frameHandler(data, planar ? 1 : 3, width, height, stride);
  @synchronized(self) {
    if (!_accepting || _reportedActive) return;
    _reportedActive = YES;
  }
  [self report:YES reason:@"active"];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
@end
