#import "DBCameraEncoder.h"
#import "../Core/DBCoreBridge.h"
#import <CoreMedia/CoreMedia.h>
#import <dlfcn.h>

typedef struct OpaqueVTCompressionSession *DBCompressionRef;
typedef void (*DBCompressionCallback)(void *, void *, OSStatus, uint32_t, CMSampleBufferRef);
static OSStatus (*DBCompressionCreate)(CFAllocatorRef, int32_t, int32_t, CMVideoCodecType,
    CFDictionaryRef, CFDictionaryRef, CFAllocatorRef, DBCompressionCallback, void *, DBCompressionRef *);
static OSStatus (*DBCompressionEncode)(DBCompressionRef, CVImageBufferRef, CMTime, CMTime,
    CFDictionaryRef, void *, uint32_t *);
static void (*DBCompressionInvalidate)(DBCompressionRef);
static OSStatus (*DBCompressionPrepare)(DBCompressionRef);
static OSStatus (*DBCompressionSet)(CFTypeRef, CFStringRef, CFTypeRef);
static OSStatus (*DBH264Parameters)(CMFormatDescriptionRef, size_t, const uint8_t **,
    size_t *, size_t *, int *);
static void *DBCompressionLibrary;

static CFStringRef DBCompressionString(const char *name) {
  CFStringRef *symbol = dlsym(DBCompressionLibrary, name);
  return symbol ? *symbol : NULL;
}

@interface DBCameraEncoder ()
- (void)emit:(CMSampleBufferRef)sample status:(OSStatus)status;
@end

static void DBCompressionOutput(void *refcon, void *frameRefcon, OSStatus status,
    uint32_t flags, CMSampleBufferRef sample) {
  (void)frameRefcon; (void)flags;
  @autoreleasepool { [(__bridge DBCameraEncoder *)refcon emit:sample status:status]; }
}

@implementation DBCameraEncoder {
  DBCoreBridge *_core;
  DBCompressionRef _session;
  BOOL _failed;
  BOOL _accepting;
  BOOL _measured;
  CMTime _firstTimestamp;
  int64_t _wallStartMs;
  int64_t _lastTimestampMs;
}

- (id)initWithCore:(DBCoreBridge *)core {
  self = [super init];
  if (self) {
    _core = core;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      DBCompressionLibrary = dlopen("/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox", RTLD_NOW);
      if (!DBCompressionLibrary) return;
      DBCompressionCreate = dlsym(DBCompressionLibrary, "VTCompressionSessionCreate");
      DBCompressionEncode = dlsym(DBCompressionLibrary, "VTCompressionSessionEncodeFrame");
      DBCompressionInvalidate = dlsym(DBCompressionLibrary, "VTCompressionSessionInvalidate");
      DBCompressionPrepare = dlsym(DBCompressionLibrary, "VTCompressionSessionPrepareToEncodeFrames");
      DBCompressionSet = dlsym(DBCompressionLibrary, "VTSessionSetProperty");
      DBH264Parameters = dlsym(RTLD_DEFAULT, "CMVideoFormatDescriptionGetH264ParameterSetAtIndex");
    });
  }
  return self;
}

- (void)setProperty:(const char *)name value:(CFTypeRef)value {
  CFStringRef key = DBCompressionString(name);
  if (key && value) DBCompressionSet(_session, key, value);
}

- (void)feed:(CVPixelBufferRef)pixels timestamp:(CMTime)timestamp {
  if (_failed || ![_core videoEncoderWanted]) return;
  if (!_session) {
    if (!DBCompressionCreate || !DBCompressionEncode || !DBCompressionInvalidate ||
        !DBCompressionSet || !DBCompressionPrepare || !DBH264Parameters) { _failed = YES; return; }
    OSStatus status = DBCompressionCreate(NULL, (int32_t)CVPixelBufferGetWidth(pixels),
        (int32_t)CVPixelBufferGetHeight(pixels), kCMVideoCodecType_H264, NULL, NULL,
        NULL, DBCompressionOutput, (__bridge void *)self, &_session);
    if (status != 0 || !_session) {
      NSLog(@"[doorbell] H.264 encoder create failed (%ld)", (long)status);
      _failed = YES; return;
    }
    [self setProperty:"kVTCompressionPropertyKey_RealTime" value:kCFBooleanTrue];
    [self setProperty:"kVTCompressionPropertyKey_AllowFrameReordering" value:kCFBooleanFalse];
    [self setProperty:"kVTCompressionPropertyKey_ProfileLevel"
        value:DBCompressionString("kVTProfileLevel_H264_Baseline_AutoLevel")];
    [self setProperty:"kVTCompressionPropertyKey_AverageBitRate" value:(__bridge CFTypeRef)@1000000];
    [self setProperty:"kVTCompressionPropertyKey_ExpectedFrameRate" value:(__bridge CFTypeRef)@30];
    [self setProperty:"kVTCompressionPropertyKey_MaxKeyFrameInterval" value:(__bridge CFTypeRef)@60];
    status = DBCompressionPrepare(_session);
    if (status != 0) { [self stop]; _failed = YES; return; }
    @synchronized(self) { _accepting = YES; }
  }
  NSDictionary *options = nil;
  CFStringRef forceKey = DBCompressionString("kVTEncodeFrameOptionKey_ForceKeyFrame");
  if (forceKey && [_core takeVideoKeyframeRequest]) options = @{(__bridge NSString *)forceKey: @YES};
  if (!CMTIME_IS_NUMERIC(timestamp)) return;
  if (!_wallStartMs) {
    _firstTimestamp = timestamp;
    _wallStartMs = (int64_t)([[NSDate date] timeIntervalSince1970] * 1000);
  }
  int64_t now = _wallStartMs + (int64_t)(CMTimeGetSeconds(CMTimeSubtract(timestamp, _firstTimestamp)) * 1000);
  if (now <= _lastTimestampMs) return;
  _lastTimestampMs = now;
  OSStatus status = DBCompressionEncode(_session, pixels, CMTimeMake(now, 1000),
      CMTimeMake(1, 30), (__bridge CFDictionaryRef)options, NULL, NULL);
  if (status != 0) { NSLog(@"[doorbell] H.264 encode failed (%ld)", (long)status); [self stop]; _failed = YES; }
}

- (void)emit:(CMSampleBufferRef)sample status:(OSStatus)status {
  @synchronized(self) { if (!_accepting) return; }
  if (status != 0 || !sample || !CMSampleBufferDataIsReady(sample)) return;
  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
  BOOL keyframe = !attachments || !CFArrayGetCount(attachments) ||
      !CFDictionaryContainsKey(CFArrayGetValueAtIndex(attachments, 0), kCMSampleAttachmentKey_NotSync);
  NSMutableData *annex = [NSMutableData data];
  const uint8_t start[] = {0, 0, 0, 1};
  int headerLength = 4;
  if (keyframe) {
    for (size_t index = 0; index < 2; ++index) {
      const uint8_t *parameter = NULL; size_t length = 0, count = 0;
      if (DBH264Parameters(CMSampleBufferGetFormatDescription(sample), index, &parameter,
          &length, &count, &headerLength) != 0 || !parameter || !length) return;
      [annex appendBytes:start length:4]; [annex appendBytes:parameter length:length];
    }
  }
  if (headerLength != 4) return;
  CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
  if (!block) return;
  size_t length = CMBlockBufferGetDataLength(block);
  if (!length || length > 2 * 1024 * 1024) return;
  char *contiguous = NULL; size_t contiguousLength = 0;
  NSMutableData *avcc = nil;
  if (CMBlockBufferGetDataPointer(block, 0, &contiguousLength, NULL, &contiguous) != 0 || contiguousLength < length) {
    avcc = [NSMutableData dataWithLength:length];
    if (CMBlockBufferCopyDataBytes(block, 0, length, [avcc mutableBytes]) != 0) return;
    contiguous = [avcc mutableBytes];
  }
  const uint8_t *bytes = (const uint8_t *)contiguous; size_t offset = 0;
  while (offset + 4 <= length) {
    uint32_t n = ((uint32_t)bytes[offset] << 24) | ((uint32_t)bytes[offset + 1] << 16) |
        ((uint32_t)bytes[offset + 2] << 8) | bytes[offset + 3];
    offset += 4;
    if (!n || n > length - offset) return;
    [annex appendBytes:start length:4]; [annex appendBytes:bytes + offset length:n]; offset += n;
  }
  if (offset != length) return;
  int64_t time = (int64_t)(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) * 1000);
  if (![_core trySubmitEncodedFrame:annex keyframe:keyframe timestampMs:time]) return;
  @synchronized(self) { if (_measured || !keyframe) return; _measured = YES; }
  _core.h264CameraActive = YES;
  [_core setRuntimeCapability:@"h264_camera_encoder" enabled:YES];
  NSLog(@"[doorbell] H.264 camera encoder delivered an IDR with SPS/PPS");
  dispatch_async(dispatch_get_main_queue(), ^{ if (self->_onStateChanged) self->_onStateChanged(YES); });
}

- (void)stop {
  @synchronized(self) { _accepting = NO; _measured = NO; }
  DBCompressionRef session = _session; _session = NULL;
  // Invalidate outside the callback-state lock because VideoToolbox can drain callbacks here.
  if (session) { DBCompressionInvalidate(session); CFRelease(session); }
  _wallStartMs = 0; _lastTimestampMs = 0;
  _failed = NO; _core.h264CameraActive = NO;
  [_core setRuntimeCapability:@"h264_camera_encoder" enabled:NO];
  dispatch_async(dispatch_get_main_queue(), ^{ if (self->_onStateChanged) self->_onStateChanged(NO); });
}
@end
