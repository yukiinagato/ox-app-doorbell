#import <Foundation/Foundation.h>

#include <stdlib.h>

#import "DBBlurKernel.h"
#import "DBPixelRows.h"

static void require(BOOL condition, NSString *message) {
  if (!condition) {
    NSLog(@"FAIL: %@", message);
    exit(1);
  }
}

static void requireImpulseHasOneLobe(size_t width, size_t height) {
  const size_t radius = 40;
  const size_t centerX = width / 2, centerY = height / 2;
  size_t count = width * height * 4;
  unsigned char *input = (unsigned char *)calloc(count, 1);
  unsigned char *output = (unsigned char *)calloc(count, 1);
  require(input != NULL && output != NULL, @"allocates the large-radius fixture");
  input[(centerY * width + centerX) * 4] = 255;
  input[(centerY * width + centerX) * 4 + 3] = 255;
  require(DBBoxBlurRGBA(input, output, width, height, radius),
          @"the dense large-radius kernel completes");

  BOOL enteredLobe = NO, exitedLobe = NO;
  size_t lineLength = width > 1 ? width : height;
  for (size_t point = 0; point < lineLength; point++) {
    size_t x = width > 1 ? point : 0;
    size_t y = width > 1 ? centerY : point;
    unsigned char value = output[(y * width + x) * 4];
    if (value != 0) {
      require(!exitedLobe, @"a large-radius impulse has no second lobe or ghost copy");
      enteredLobe = YES;
    } else if (enteredLobe) {
      exitedLobe = YES;
    }
  }
  require(enteredLobe, @"the impulse produces one continuous blur lobe");
  free(input);
  free(output);
}

static void requireEdgeIsMonotonic(void) {
  const size_t width = 201, height = 1, radius = 40;
  size_t count = width * height * 4;
  unsigned char *input = (unsigned char *)calloc(count, 1);
  unsigned char *output = (unsigned char *)calloc(count, 1);
  require(input != NULL && output != NULL, @"allocates the large-radius edge fixture");
  for (size_t x = width / 2; x < width; x++) input[x * 4] = 255;
  require(DBBoxBlurRGBA(input, output, width, height, radius),
          @"the dense large-radius edge kernel completes");
  unsigned char previous = output[0];
  for (size_t x = 1; x < width; x++) {
    unsigned char value = output[x * 4];
    require(value >= previous, @"a large-radius edge never falls into a ghost lobe");
    previous = value;
  }
  free(input);
  free(output);
}

static void requireCpuRowsBecomeUpright(void) {
  // The CPU bitmap result has the physical bottom row first. This fixture is
  // intentionally raw, so it verifies the UIImage boundary independently of
  // CGContext's coordinate-system conventions.
  unsigned char cpuOutput[] = {
    0, 0, 0, 255, 0, 0, 0, 255,
    255, 255, 255, 255, 255, 255, 255, 255,
  };
  DBFlipPixelRows(cpuOutput, 2, 2);
  require(cpuOutput[0] == 255 && cpuOutput[4] == 255,
          @"CPU bottom-up rows normalize to an upright white top row");
  require(cpuOutput[8] == 0 && cpuOutput[12] == 0,
          @"CPU bottom-up rows normalize to a black bottom row");
}

int main(void) {
  @autoreleasepool {
    require(DBFrostedBlurUsesGPUForRadius(DB_FROSTED_BLUR_MAXIMUM_GPU_RADIUS),
            @"the dense GPU range remains enabled");
    require(!DBFrostedBlurUsesGPUForRadius(DB_FROSTED_BLUR_MAXIMUM_GPU_RADIUS + 1),
            @"sparse GPU radii intentionally use the CPU kernel");
    require(!DBFrostedBlurUsesGPUForRadius(32) && !DBFrostedBlurUsesGPUForRadius(40),
            @"default and maximum configured radii avoid GPU ghosting");
    requireImpulseHasOneLobe(201, 1);
    requireImpulseHasOneLobe(1, 201);
    requireEdgeIsMonotonic();
    requireCpuRowsBecomeUpright();
    puts("PASS: large-radius frosted blur uses one dense lobe");
  }
  return 0;
}
