#import "DBFrostedBlur.h"

#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>

static void DBFreePixels(void *info, const void *data, size_t size) {
  (void)info;
  (void)size;
  free((void *)data);
}

static UIImage *DBImageFromPixels(unsigned char *pixels, size_t width, size_t height) {
  if (pixels == NULL) return nil;
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGDataProviderRef provider = CGDataProviderCreateWithData(
      NULL, pixels, width * height * 4, DBFreePixels);
  CGImageRef cg = provider ? CGImageCreate(
      width, height, 8, 32, width * 4, space,
      kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast,
      provider, NULL, false, kCGRenderingIntentDefault) : NULL;
  UIImage *image = cg ? [UIImage imageWithCGImage:cg scale:1 orientation:UIImageOrientationUp] : nil;
  if (cg) CGImageRelease(cg);
  if (provider) CGDataProviderRelease(provider);
  else free(pixels);
  CGColorSpaceRelease(space);
  return image;
}

static unsigned char *DBCopyPixels(UIImage *image, size_t *outWidth, size_t *outHeight) {
  CGImageRef cg = image.CGImage;
  if (cg == NULL) return NULL;
  size_t width = CGImageGetWidth(cg), height = CGImageGetHeight(cg);
  if (width == 0 || height == 0 || width > 2048 || height > 2048) return NULL;
  unsigned char *pixels = (unsigned char *)calloc(width * height, 4);
  if (pixels == NULL) return NULL;
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGContextRef context = CGBitmapContextCreate(
      pixels, width, height, 8, width * 4, space,
      kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(space);
  if (context == NULL) {
    free(pixels);
    return NULL;
  }
  CGContextTranslateCTM(context, 0, (CGFloat)height);
  CGContextScaleCTM(context, 1, -1);
  CGContextDrawImage(context, CGRectMake(0, 0, width, height), cg);
  CGContextRelease(context);
  *outWidth = width;
  *outHeight = height;
  return pixels;
}

static GLuint DBCompile(GLenum type, const char *source) {
  GLuint shader = glCreateShader(type);
  glShaderSource(shader, 1, &source, NULL);
  glCompileShader(shader);
  GLint ok = 0;
  glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
  if (!ok) {
    glDeleteShader(shader);
    return 0;
  }
  return shader;
}

static GLuint DBProgram(void) {
  static const char *vertex =
      "attribute vec2 position; attribute vec2 texcoord; varying vec2 uv;"
      "void main(){ uv=texcoord; gl_Position=vec4(position,0.0,1.0); }";
  static const char *fragment =
      "precision mediump float; varying vec2 uv; uniform sampler2D image; uniform vec2 stepv;"
      "void main(){"
      "vec4 c=texture2D(image,uv)*0.227027;"
      "c+=texture2D(image,uv+stepv*1.384615)*0.316216;"
      "c+=texture2D(image,uv-stepv*1.384615)*0.316216;"
      "c+=texture2D(image,uv+stepv*3.230769)*0.070270;"
      "c+=texture2D(image,uv-stepv*3.230769)*0.070270;"
      "gl_FragColor=c; }";
  GLuint vs = DBCompile(GL_VERTEX_SHADER, vertex);
  GLuint fs = DBCompile(GL_FRAGMENT_SHADER, fragment);
  if (!vs || !fs) {
    if (vs) glDeleteShader(vs);
    if (fs) glDeleteShader(fs);
    return 0;
  }
  GLuint program = glCreateProgram();
  glAttachShader(program, vs);
  glAttachShader(program, fs);
  glBindAttribLocation(program, 0, "position");
  glBindAttribLocation(program, 1, "texcoord");
  glLinkProgram(program);
  glDeleteShader(vs);
  glDeleteShader(fs);
  GLint ok = 0;
  glGetProgramiv(program, GL_LINK_STATUS, &ok);
  if (!ok) {
    glDeleteProgram(program);
    return 0;
  }
  return program;
}

static void DBTexture(GLuint texture, size_t width, size_t height, const void *pixels) {
  glBindTexture(GL_TEXTURE_2D, texture);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, (GLsizei)width, (GLsizei)height, 0,
               GL_RGBA, GL_UNSIGNED_BYTE, pixels);
}

static BOOL DBDrawPass(GLuint framebuffer, GLuint target, GLuint source, GLuint program,
                       size_t width, size_t height, GLfloat stepX, GLfloat stepY) {
  static const GLfloat vertices[] = {-1,-1, 1,-1, -1,1, 1,1};
  static const GLfloat texcoords[] = {0,0, 1,0, 0,1, 1,1};
  glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, target, 0);
  if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) return NO;
  glViewport(0, 0, (GLsizei)width, (GLsizei)height);
  glUseProgram(program);
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, source);
  glUniform1i(glGetUniformLocation(program, "image"), 0);
  glUniform2f(glGetUniformLocation(program, "stepv"), stepX, stepY);
  glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, vertices);
  glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 0, texcoords);
  glEnableVertexAttribArray(0);
  glEnableVertexAttribArray(1);
  glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
  return glGetError() == GL_NO_ERROR;
}

static UIImage *DBGpuBlur(unsigned char *input, size_t width, size_t height, NSUInteger radius) {
  EAGLContext *previous = [EAGLContext currentContext];
  EAGLContext *context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
  if (context == nil || ![EAGLContext setCurrentContext:context]) return nil;
  GLint limit = 0;
  glGetIntegerv(GL_MAX_TEXTURE_SIZE, &limit);
  if (width > (size_t)limit || height > (size_t)limit) {
    [EAGLContext setCurrentContext:previous];
    return nil;
  }

  GLuint textures[3] = {0, 0, 0}, framebuffer = 0, program = DBProgram();
  glGenTextures(3, textures);
  DBTexture(textures[0], width, height, input);
  DBTexture(textures[1], width, height, NULL);
  DBTexture(textures[2], width, height, NULL);
  glGenFramebuffers(1, &framebuffer);
  GLfloat spread = MAX(1.0f, (GLfloat)radius / 4.0f);
  BOOL ok = program && DBDrawPass(framebuffer, textures[1], textures[0], program, width, height,
                                  spread / (GLfloat)width, 0) &&
      DBDrawPass(framebuffer, textures[2], textures[1], program, width, height,
                 0, spread / (GLfloat)height) &&
      DBDrawPass(framebuffer, textures[1], textures[2], program, width, height,
                 spread / (GLfloat)width, 0) &&
      DBDrawPass(framebuffer, textures[2], textures[1], program, width, height,
                 0, spread / (GLfloat)height);
  unsigned char *output = ok ? (unsigned char *)malloc(width * height * 4) : NULL;
  if (output) {
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glReadPixels(0, 0, (GLsizei)width, (GLsizei)height, GL_RGBA, GL_UNSIGNED_BYTE, output);
    ok = glGetError() == GL_NO_ERROR;
  }
  if (program) glDeleteProgram(program);
  if (framebuffer) glDeleteFramebuffers(1, &framebuffer);
  glDeleteTextures(3, textures);
  glFlush();
  [EAGLContext setCurrentContext:previous];
  if (!ok) {
    free(output);
    return nil;
  }
  return DBImageFromPixels(output, width, height);
}

static UIImage *DBCpuBlur(unsigned char *input, size_t width, size_t height, NSUInteger radius) {
  size_t count = width * height * 4;
  unsigned char *horizontal = (unsigned char *)malloc(count);
  unsigned char *output = (unsigned char *)malloc(count);
  if (!horizontal || !output) {
    free(horizontal);
    free(output);
    return nil;
  }
  NSUInteger span = radius * 2 + 1;
  for (size_t y = 0; y < height; y++) {
    NSUInteger sums[4] = {0,0,0,0};
    for (NSInteger x = -(NSInteger)radius; x <= (NSInteger)radius; x++) {
      size_t column = (size_t)MAX(0, MIN((NSInteger)width - 1, x));
      for (size_t c = 0; c < 4; c++) sums[c] += input[(y * width + column) * 4 + c];
    }
    for (size_t x = 0; x < width; x++) {
      for (size_t c = 0; c < 4; c++) horizontal[(y * width + x) * 4 + c] = sums[c] / span;
      size_t remove = (size_t)MAX(0, (NSInteger)x - (NSInteger)radius);
      size_t add = (size_t)MIN((NSInteger)width - 1, (NSInteger)x + (NSInteger)radius + 1);
      for (size_t c = 0; c < 4; c++) {
        sums[c] += input[(y * width + add) * 4 + c];
        sums[c] -= input[(y * width + remove) * 4 + c];
      }
    }
  }
  for (size_t x = 0; x < width; x++) {
    NSUInteger sums[4] = {0,0,0,0};
    for (NSInteger y = -(NSInteger)radius; y <= (NSInteger)radius; y++) {
      size_t row = (size_t)MAX(0, MIN((NSInteger)height - 1, y));
      for (size_t c = 0; c < 4; c++) sums[c] += horizontal[(row * width + x) * 4 + c];
    }
    for (size_t y = 0; y < height; y++) {
      for (size_t c = 0; c < 4; c++) output[(y * width + x) * 4 + c] = sums[c] / span;
      size_t remove = (size_t)MAX(0, (NSInteger)y - (NSInteger)radius);
      size_t add = (size_t)MIN((NSInteger)height - 1, (NSInteger)y + (NSInteger)radius + 1);
      for (size_t c = 0; c < 4; c++) {
        sums[c] += horizontal[(add * width + x) * 4 + c];
        sums[c] -= horizontal[(remove * width + x) * 4 + c];
      }
    }
  }
  free(horizontal);
  return DBImageFromPixels(output, width, height);
}

@implementation DBFrostedBlur

+ (UIImage *)blurredImage:(UIImage *)image radius:(NSUInteger)radius usedGPU:(BOOL *)usedGPU {
  if (usedGPU) *usedGPU = NO;
  if (image == nil) return nil;
  radius = MIN((NSUInteger)40, radius);
  if (radius == 0) return image;
  size_t width = 0, height = 0;
  unsigned char *pixels = DBCopyPixels(image, &width, &height);
  if (pixels == NULL) return nil;
  UIImage *blurred = DBGpuBlur(pixels, width, height, radius);
  if (blurred && usedGPU) *usedGPU = YES;
  if (!blurred) blurred = DBCpuBlur(pixels, width, height, radius);
  free(pixels);
  return blurred;
}

@end
