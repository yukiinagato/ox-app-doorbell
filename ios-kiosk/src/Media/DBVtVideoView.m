#import "DBVtVideoView.h"

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CVOpenGLESTextureCache.h>
#import <OpenGLES/ES1/gl.h>
#import <dlfcn.h>

void DBH264Dbg(NSString *fmt, ...);

typedef struct OpaqueVTDecompressionSession *DbVTSessionRef;
typedef uint32_t DbVTDecodeFlags;
typedef uint32_t DbVTDecodeInfoFlags;
typedef void (*DbVTOutputCallback)(void *, void *, OSStatus, DbVTDecodeInfoFlags,
                                   CVImageBufferRef, CMTime, CMTime);
typedef struct {
  DbVTOutputCallback callback;
  void *refCon;
} DbVTOutputRecord;

static OSStatus (*DbVTCreate)(CFAllocatorRef, CMVideoFormatDescriptionRef,
                              CFDictionaryRef, CFDictionaryRef,
                              const DbVTOutputRecord *, DbVTSessionRef *);
static OSStatus (*DbVTDecode)(DbVTSessionRef, CMSampleBufferRef, DbVTDecodeFlags,
                              void *, DbVTDecodeInfoFlags *);
static void (*DbVTInvalidate)(DbVTSessionRef);
static OSStatus (*DbVTWait)(DbVTSessionRef);
static OSStatus (*DbVTSetProperty)(CFTypeRef, CFStringRef, CFTypeRef);
static CFStringRef const *DbVTHardwareKey;

static BOOL DbLoadVt(void) {
  static dispatch_once_t once;
  static BOOL ok;
  dispatch_once(&once, ^{
    void *vt = dlopen("/System/Library/PrivateFrameworks/VideoToolbox.framework/VideoToolbox",
                      RTLD_NOW);
    DbVTCreate = dlsym(vt, "VTDecompressionSessionCreate");
    DbVTDecode = dlsym(vt, "VTDecompressionSessionDecodeFrame");
    DbVTInvalidate = dlsym(vt, "VTDecompressionSessionInvalidate");
    DbVTWait = dlsym(vt, "VTDecompressionSessionWaitForAsynchronousFrames");
    DbVTSetProperty = dlsym(vt, "VTSessionSetProperty");
    DbVTHardwareKey = dlsym(
        vt, "kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder");
    ok = vt && DbVTCreate && DbVTDecode && DbVTInvalidate;
    DBH264Dbg(@"[vt] symbols create=%p decode=%p wait=%p ok=%d",
              DbVTCreate, DbVTDecode, DbVTWait, (int)ok);
  });
  return ok;
}

typedef struct {
  const uint8_t *bytes;
  NSUInteger length;
  NSUInteger bit;
  BOOL bad;
} DbBits;

static uint32_t DbReadBits(DbBits *b, NSUInteger count) {
  uint32_t value = 0;
  for (NSUInteger i = 0; i < count; i++) {
    if (b->bit >= b->length * 8) { b->bad = YES; return 0; }
    value = (value << 1) |
        ((b->bytes[b->bit >> 3] >> (7 - (b->bit & 7))) & 1);
    b->bit++;
  }
  return value;
}

static uint32_t DbReadUe(DbBits *b) {
  NSUInteger zeros = 0;
  while (!b->bad && DbReadBits(b, 1) == 0) {
    if (++zeros > 31) { b->bad = YES; return 0; }
  }
  return b->bad ? 0 : ((1u << zeros) - 1) + DbReadBits(b, zeros);
}

static int32_t DbReadSe(DbBits *b) {
  uint32_t value = DbReadUe(b);
  return (value & 1) ? (int32_t)((value + 1) / 2) : -(int32_t)(value / 2);
}

static void DbSkipScale(DbBits *b, int count) {
  int last = 8, next = 8;
  for (int i = 0; i < count && !b->bad; i++) {
    if (next) next = (last + DbReadSe(b) + 256) % 256;
    if (next) last = next;
  }
}

static BOOL DbSpsSize(NSData *spsData, int *widthOut, int *heightOut) {
  const uint8_t *sps = [spsData bytes];
  NSUInteger len = [spsData length];
  if (len < 4 || (sps[0] & 0x1f) != 7) return NO;
  NSMutableData *rbspData = [NSMutableData dataWithCapacity:len];
  NSUInteger zeros = 0;
  for (NSUInteger i = 1; i < len; i++) {
    uint8_t value = sps[i];
    if (zeros >= 2 && value == 3) { zeros = 0; continue; }
    [rbspData appendBytes:&value length:1];
    zeros = value == 0 ? zeros + 1 : 0;
  }
  DbBits b = {[rbspData bytes], [rbspData length], 0, NO};
  uint32_t profile = DbReadBits(&b, 8);
  DbReadBits(&b, 16);
  DbReadUe(&b);
  uint32_t chroma = 1;
  BOOL separate = NO;
  if (profile == 100 || profile == 110 || profile == 122 || profile == 244 ||
      profile == 44 || profile == 83 || profile == 86 || profile == 118 ||
      profile == 128 || profile == 138 || profile == 139 || profile == 134) {
    chroma = DbReadUe(&b);
    if (chroma == 3) separate = DbReadBits(&b, 1) != 0;
    DbReadUe(&b); DbReadUe(&b); DbReadBits(&b, 1);
    if (DbReadBits(&b, 1)) {
      int lists = chroma == 3 ? 12 : 8;
      for (int i = 0; i < lists; i++)
        if (DbReadBits(&b, 1)) DbSkipScale(&b, i < 6 ? 16 : 64);
    }
  }
  DbReadUe(&b);
  uint32_t poc = DbReadUe(&b);
  if (poc == 0) DbReadUe(&b);
  else if (poc == 1) {
    DbReadBits(&b, 1); DbReadSe(&b); DbReadSe(&b);
    uint32_t cycle = DbReadUe(&b);
    if (cycle > 256) return NO;
    for (uint32_t i = 0; i < cycle; i++) DbReadSe(&b);
  }
  DbReadUe(&b); DbReadBits(&b, 1);
  uint32_t mbsW = DbReadUe(&b) + 1;
  uint32_t mapH = DbReadUe(&b) + 1;
  uint32_t frameOnly = DbReadBits(&b, 1);
  if (!frameOnly) DbReadBits(&b, 1);
  DbReadBits(&b, 1);
  uint32_t left = 0, right = 0, top = 0, bottom = 0;
  if (DbReadBits(&b, 1)) {
    left = DbReadUe(&b); right = DbReadUe(&b);
    top = DbReadUe(&b); bottom = DbReadUe(&b);
  }
  if (b.bad) return NO;
  uint32_t subW = (chroma == 1 || chroma == 2) ? 2 : 1;
  uint32_t subH = chroma == 1 ? 2 : 1;
  if (chroma == 0 || separate) subW = subH = 1;
  int width = (int)(mbsW * 16 - (left + right) * subW);
  int height = (int)((2 - frameOnly) * mapH * 16 -
                     (top + bottom) * subH * (2 - frameOnly));
  if (width <= 0 || height <= 0 || width > 4096 || height > 4096) return NO;
  *widthOut = width; *heightOut = height;
  return YES;
}

typedef struct { int64_t captureMs; } DbFrameContext;
static void DbVtOutput(void *, void *, OSStatus, DbVTDecodeInfoFlags,
                       CVImageBufferRef, CMTime, CMTime);

@interface DBVtVideoView () <GLKViewDelegate>
- (void)acceptDecoded:(CVPixelBufferRef)pixel captureMs:(int64_t)captureMs;
@end

@implementation DBVtVideoView {
  DbVTSessionRef _session;
  CMFormatDescriptionRef _format;
  CVOpenGLESTextureCacheRef _textureCache;
  CVPixelBufferRef _latest;
  int64_t _latestCaptureMs;
  GLuint _uploadTexture;
  size_t _uploadWidth;
  size_t _uploadHeight;
  NSLock *_frameLock;
  NSUInteger _decodedFrames;
  NSUInteger _droppedFrames;
}

- (id)initWithFrame:(CGRect)frame {
  EAGLContext *context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES1];
  self = [super initWithFrame:frame context:context];
  if (self) {
    _frameLock = [[NSLock alloc] init];
    self.delegate = self;
    self.enableSetNeedsDisplay = YES;
    self.drawableColorFormat = GLKViewDrawableColorFormatRGB565;
    [EAGLContext setCurrentContext:context];
    CVReturn result = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL,
        (CVEAGLContext)context, NULL, &_textureCache);
    [EAGLContext setCurrentContext:nil];
    DBH264Dbg(@"[vt] GL texture cache=%d", (int)result);
  }
  return self;
}

- (NSUInteger)decodedFrames { return _decodedFrames; }
- (NSUInteger)droppedFrames { return _droppedFrames; }

- (BOOL)startWithSps:(NSData *)sps pps:(NSData *)pps {
  if (_session) return YES;
  if (!DbLoadVt() || [sps length] < 4 || [pps length] == 0) return NO;
  int width = 0, height = 0;
  if (!DbSpsSize(sps, &width, &height)) return NO;
  const uint8_t *sp = [sps bytes];
  NSUInteger sl = [sps length], pl = [pps length];
  NSMutableData *avcC = [NSMutableData dataWithCapacity:11 + sl + pl];
  uint8_t head[8] = {1, sp[1], sp[2], sp[3], 0xff, 0xe1,
                     (uint8_t)(sl >> 8), (uint8_t)sl};
  [avcC appendBytes:head length:8]; [avcC appendData:sps];
  uint8_t middle[3] = {1, (uint8_t)(pl >> 8), (uint8_t)pl};
  [avcC appendBytes:middle length:3]; [avcC appendData:pps];
  NSDictionary *atoms = [NSDictionary dictionaryWithObject:avcC forKey:@"avcC"];
  // These CFString constants are weak imports when linking the iOS 7 SDK and
  // resolve to NULL on the real iOS 5.1 runtime. CoreMedia uses the string
  // values as dictionary keys, so spell them out instead of dereferencing a
  // missing exported constant.
  NSDictionary *extensions = [NSDictionary dictionaryWithObject:atoms
      forKey:@"SampleDescriptionExtensionAtoms"];
  OSStatus status = CMVideoFormatDescriptionCreate(kCFAllocatorDefault, 'avc1',
      width, height, (__bridge CFDictionaryRef)extensions, &_format);
  if (status || !_format) {
    DBH264Dbg(@"[vt] format %dx%d status=%d", width, height, (int)status);
    return NO;
  }
  NSDictionary *output = @{
    @"PixelFormatType": [NSNumber numberWithUnsignedInt:kCVPixelFormatType_32BGRA],
    @"OpenGLESCompatibility": @YES,
    @"Width": @(width),
    @"Height": @(height)
  };
  NSDictionary *decoder = nil;
  if (DbVTHardwareKey && *DbVTHardwareKey)
    decoder = @{(__bridge NSString *)*DbVTHardwareKey: @YES};
  DbVTOutputRecord callback = {DbVtOutput, (__bridge void *)self};
  status = DbVTCreate(kCFAllocatorDefault, _format,
      (__bridge CFDictionaryRef)decoder, (__bridge CFDictionaryRef)output,
      &callback, &_session);
  if (!status && _session && DbVTSetProperty)
    DbVTSetProperty(_session, CFSTR("RealTime"), kCFBooleanTrue);
  DBH264Dbg(@"[vt] session %dx%d status=%d ptr=%p", width, height,
            (int)status, _session);
  return status == 0 && _session;
}

- (void)pushSample:(NSData *)avcc captureMs:(int64_t)captureMs
             dtsMs:(int64_t)dtsMs durMs:(int64_t)durMs {
  if (!_session || ![avcc length]) return;
  size_t length = [avcc length];
  void *copy = malloc(length);
  if (!copy) return;
  memcpy(copy, [avcc bytes], length);
  CMBlockBufferRef block = NULL;
  OSStatus status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, copy,
      length, kCFAllocatorMalloc, NULL, 0, length, 0, &block);
  if (status || !block) { free(copy); _droppedFrames++; return; }
  CMSampleTimingInfo timing;
  timing.duration = CMTimeMake(durMs > 0 ? durMs : 1, 1000);
  timing.presentationTimeStamp = CMTimeMake(dtsMs, 1000);
  timing.decodeTimeStamp = timing.presentationTimeStamp;
  CMSampleBufferRef sample = NULL;
  status = CMSampleBufferCreate(kCFAllocatorDefault, block, YES, NULL, NULL,
      _format, 1, 1, &timing, 1, &length, &sample);
  CFRelease(block);
  if (status || !sample) { _droppedFrames++; return; }
  DbFrameContext *context = malloc(sizeof(*context));
  if (context) context->captureMs = captureMs;
  DbVTDecodeInfoFlags info = 0;
  status = DbVTDecode(_session, sample, 1, context, &info);
  CFRelease(sample);
  if (status) {
    free(context);
    _droppedFrames++;
    if (_droppedFrames < 8) DBH264Dbg(@"[vt] decode status=%d info=%u", (int)status, info);
  }
}

- (void)acceptDecoded:(CVPixelBufferRef)pixel captureMs:(int64_t)captureMs {
  if (_maxQueueAgeMs > 0 && captureMs > 0) {
    int64_t nowMs = (int64_t)([[NSDate date] timeIntervalSince1970] * 1000.0);
    int64_t age = nowMs - captureMs - _serverToClientOffsetMs;
    if (age > _maxQueueAgeMs) {
      _droppedFrames++;
      if (_droppedFrames < 8)
        DBH264Dbg(@"[vt] drop stale decoded frame age=%lldms", (long long)age);
      return;
    }
  }
  if (_decodedFrames == 0) {
    OSType fmt = CVPixelBufferGetPixelFormatType(pixel);
    DBH264Dbg(@"[vt] output pixel=%c%c%c%c %lux%lu planes=%lu stride=%lu",
              (char)(fmt >> 24), (char)(fmt >> 16), (char)(fmt >> 8), (char)fmt,
              (unsigned long)CVPixelBufferGetWidth(pixel),
              (unsigned long)CVPixelBufferGetHeight(pixel),
              (unsigned long)CVPixelBufferGetPlaneCount(pixel),
              (unsigned long)CVPixelBufferGetBytesPerRow(pixel));
  }
  [_frameLock lock];
  if (_latest) CVBufferRelease(_latest);
  _latest = CVBufferRetain(pixel);
  _latestCaptureMs = captureMs;
  _decodedFrames++;
  [_frameLock unlock];
  dispatch_async(dispatch_get_main_queue(), ^{ [self setNeedsDisplay]; });
}

static void DbVtOutput(void *refCon, void *frameRefCon, OSStatus status,
                       DbVTDecodeInfoFlags flags, CVImageBufferRef image,
                       CMTime pts, CMTime duration) {
  (void)flags; (void)pts; (void)duration;
  DbFrameContext *context = frameRefCon;
  int64_t captureMs = context ? context->captureMs : 0;
  free(context);
  if (!status && image)
    [(__bridge DBVtVideoView *)refCon acceptDecoded:image captureMs:captureMs];
  else if (status)
    DBH264Dbg(@"[vt] output status=%d", (int)status);
}

- (void)glkView:(GLKView *)view drawInRect:(CGRect)rect {
  (void)view;
  [_frameLock lock];
  CVPixelBufferRef pixel = _latest ? CVBufferRetain(_latest) : NULL;
  int64_t captureMs = _latestCaptureMs;
  [_frameLock unlock];
  if (!pixel) return;
  // The main thread may have stalled after decoder callback. Re-check age at
  // the last possible moment; preserving the previous texture is preferable
  // to visibly moving backwards to an already stale frame.
  if (_maxQueueAgeMs > 0 && captureMs > 0) {
    int64_t nowMs = (int64_t)([[NSDate date] timeIntervalSince1970] * 1000.0);
    int64_t age = nowMs - captureMs - _serverToClientOffsetMs;
    if (age > _maxQueueAgeMs) {
      _droppedFrames++;
      CVBufferRelease(pixel);
      return;
    }
  }
  glClearColor(0, 0, 0, 1); glClear(GL_COLOR_BUFFER_BIT);
  size_t width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel);
  // iOS 5's CVOpenGLESTextureCache reports success for VideoToolbox BGRA
  // buffers but produces an all-white texture on the iPad 1 (SGX535). Upload
  // the already-decoded BGRA surface into one reusable GL texture instead.
  // This is one memcpy-equivalent GPU upload per frame, still no software H.264
  // decode, and is deterministic on the real target hardware.
  CVReturn lock = CVPixelBufferLockBaseAddress(pixel, kCVPixelBufferLock_ReadOnly);
  void *base = lock == kCVReturnSuccess ? CVPixelBufferGetBaseAddress(pixel) : NULL;
  size_t stride = CVPixelBufferGetBytesPerRow(pixel);
  if (base && stride == width * 4) {
    if (!_uploadTexture) glGenTextures(1, &_uploadTexture);
    glBindTexture(GL_TEXTURE_2D, _uploadTexture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
    if (_uploadWidth != width || _uploadHeight != height) {
      glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, (GLsizei)width, (GLsizei)height,
                   0, GL_BGRA, GL_UNSIGNED_BYTE, base);
      _uploadWidth = width;
      _uploadHeight = height;
    } else {
      glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, (GLsizei)width, (GLsizei)height,
                      GL_BGRA, GL_UNSIGNED_BYTE, base);
    }
    glViewport(0, 0, (GLsizei)rect.size.width, (GLsizei)rect.size.height);
    glMatrixMode(GL_PROJECTION); glLoadIdentity();
    glMatrixMode(GL_MODELVIEW); glLoadIdentity();
    glColor4f(1, 1, 1, 1);
    glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);
    CGRect bounds = self.bounds;
    CGFloat scale = MIN(bounds.size.width / width, bounds.size.height / height);
    GLfloat halfW = (GLfloat)(width * scale / bounds.size.width);
    GLfloat halfH = (GLfloat)(height * scale / bounds.size.height);
    GLfloat vertices[] = {-halfW,-halfH, halfW,-halfH,
                          -halfW, halfH, halfW, halfH};
    static const GLfloat coords[] = {0,1, 1,1, 0,0, 1,0};
    glEnable(GL_TEXTURE_2D);
    glEnableClientState(GL_VERTEX_ARRAY);
    glEnableClientState(GL_TEXTURE_COORD_ARRAY);
    glVertexPointer(2, GL_FLOAT, 0, vertices);
    glTexCoordPointer(2, GL_FLOAT, 0, coords);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glDisableClientState(GL_VERTEX_ARRAY);
    glDisableClientState(GL_TEXTURE_COORD_ARRAY);
    glDisable(GL_TEXTURE_2D);
    if (_onDisplayedFrame) _onDisplayedFrame(captureMs);
  }
  if (lock == kCVReturnSuccess)
    CVPixelBufferUnlockBaseAddress(pixel, kCVPixelBufferLock_ReadOnly);
  CVBufferRelease(pixel);
}

- (void)shutdownDecoder {
  if (_session) {
    if (DbVTWait) DbVTWait(_session);
    DbVTInvalidate(_session);
    _session = NULL;
  }
  if (_format) { CFRelease(_format); _format = NULL; }
  [_frameLock lock];
  if (_latest) { CVBufferRelease(_latest); _latest = NULL; }
  [_frameLock unlock];
}

- (void)dealloc {
  [self shutdownDecoder];
  if (_uploadTexture) {
    [EAGLContext setCurrentContext:self.context];
    glDeleteTextures(1, &_uploadTexture);
    [EAGLContext setCurrentContext:nil];
  }
  if (_textureCache) CFRelease(_textureCache);
}

@end
