#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>

@interface DBCameraFeeder : NSObject
@property(nonatomic, copy) void (^onPixelBuffer)(CVPixelBufferRef, CMTime);
@property(nonatomic, copy) void (^onCaptureStopped)(void);
- (id)initWithFrameHandler:(void (^)(NSData *, int, int, int, int))frameHandler
              stateHandler:(void (^)(BOOL, NSString *))stateHandler;
- (void)start;
- (void)stop;
/// Which lens start() opens. The visitor camera faces the visitor, so it defaults to the front
/// one; the QR scanner asks for the back one and lets the user flip. Falls back to any camera.
/// Takes effect on the next start().
@property(nonatomic, assign) AVCaptureDevicePosition preferredPosition;
/// The lens of the running session (AVCaptureDevicePositionUnspecified when stopped).
@property(nonatomic, readonly) AVCaptureDevicePosition activePosition;
/// YES when the device has both a front and a back camera.
+ (BOOL)canSwitchPosition;
/// YES while a capture session exists (it may still be starting).
@property(nonatomic, readonly) BOOL running;
/// A new preview layer bound to the running session, or nil when the camera is not running.
/// The QR scanner shows it so the user can aim; frames keep flowing to Core unchanged.
- (CALayer *)newPreviewLayer;
/// When set before start(), the session is built with AVFoundation's QR detector (iOS 7+) and
/// decoded strings go to this block on the main queue. Restart the camera after changing it.
@property(nonatomic, copy) void (^onQrCode)(NSString *text);
/// YES when the running session carries the QR detector.
@property(nonatomic, readonly) BOOL qrDetectorActive;
@end
