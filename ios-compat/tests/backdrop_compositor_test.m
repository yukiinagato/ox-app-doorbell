#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

#include <stdlib.h>

#import "DBBackdropCompositor.h"
#import "DBPixelRows.h"
#import "DBUiTheme.h"

static void require(BOOL condition, NSString *message) {
  if (!condition) {
    NSLog(@"FAIL: %@", message);
    exit(1);
  }
}

// A flat source of a known luminance, so the measured result can be compared
// against arithmetic rather than against an opinion about a photograph.
static CGImageRef newFlatImage(CGFloat white, size_t side) CF_RETURNS_RETAINED {
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(NULL, side, side, 8, 0, space,
                                           (CGBitmapInfo)kCGImageAlphaNoneSkipFirst);
  CGColorSpaceRelease(space);
  if (ctx == NULL) return NULL;
  CGContextSetRGBFillColor(ctx, white, white, white, 1);
  CGContextFillRect(ctx, CGRectMake(0, 0, (CGFloat)side, (CGFloat)side));
  CGImageRef out = CGBitmapContextCreateImage(ctx);
  CGContextRelease(ctx);
  return out;
}

// Half black, half white, so a mapping bug that drops or doubles part of the
// picture moves the mean even though a flat source would not.
static CGImageRef newSplitImage(size_t side) CF_RETURNS_RETAINED {
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(NULL, side, side, 8, 0, space,
                                           (CGBitmapInfo)kCGImageAlphaNoneSkipFirst);
  CGColorSpaceRelease(space);
  if (ctx == NULL) return NULL;
  CGContextSetRGBFillColor(ctx, 0, 0, 0, 1);
  CGContextFillRect(ctx, CGRectMake(0, 0, (CGFloat)side, (CGFloat)side));
  CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
  CGContextFillRect(ctx, CGRectMake(0, 0, (CGFloat)side, (CGFloat)side / 2));
  CGImageRef out = CGBitmapContextCreateImage(ctx);
  CGContextRelease(ctx);
  return out;
}

static void freeFixturePixels(void *info, const void *data, size_t size) {
  (void)info;
  (void)size;
  free((void *)data);
}

// CGImage data providers define scanline zero as the top row. This fixture is
// deliberately raw data rather than a bitmap CGContext, so it cannot repeat a
// source-context coordinate-system mistake in the compositor.
static CGImageRef newTopWhiteBottomBlackFixture(void) CF_RETURNS_RETAINED {
  const size_t width = 64, height = 64, rowBytes = width * 4;
  unsigned char *pixels = (unsigned char *)malloc(height * rowBytes);
  if (pixels == NULL) return NULL;
  for (size_t y = 0; y < height; y++) {
    unsigned char value = y < height / 2 ? 255 : 0;
    for (size_t x = 0; x < width; x++) {
      unsigned char *pixel = pixels + y * rowBytes + x * 4;
      pixel[0] = value;
      pixel[1] = value;
      pixel[2] = value;
      pixel[3] = 255;
    }
  }
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGDataProviderRef provider = CGDataProviderCreateWithData(
      NULL, pixels, height * rowBytes, freeFixturePixels);
  CGImageRef image = provider ? CGImageCreate(
      width, height, 8, 32, rowBytes, space,
      kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast,
      provider, NULL, false, kCGRenderingIntentDefault) : NULL;
  if (provider) CGDataProviderRelease(provider);
  else free(pixels);
  CGColorSpaceRelease(space);
  return image;
}

static BOOL near(CGFloat value, CGFloat want, CGFloat tolerance) {
  return fabs(value - want) <= tolerance;
}

int main(void) {
  @autoreleasepool {
    const CGFloat alpha = [DBBackdropCompositor darkeningAlpha];
    require(alpha >= 0.60 && alpha <= 0.65,
            @"the picture is darkened by 60 to 65 per cent");

    // --- The measurement the darkening is actually judged by. ---
    // White through a 62 % black scrim must measure 1 - 0.62 = 0.38. A scrim
    // that never composited would measure 1.0; a copy-blended fill would
    // measure 0.
    CGImageRef white = newFlatImage(1.0, 64);
    CGImageRef backdrop = [DBBackdropCompositor newBackdropFromImage:white
                                                            viewSize:CGSizeMake(1024, 768)];
    require(backdrop != NULL, @"a white source composites");
    CGFloat mean = [DBBackdropCompositor meanLuminanceOfImage:backdrop];
    require(near(mean, 1.0 - alpha, 0.02),
            [NSString stringWithFormat:@"white darkens to %.3f, wanted %.3f (measured %.3f)",
                                       1.0 - alpha, 1.0 - alpha, mean]);
    require(mean < 0.5, @"the scrim is composited, not skipped");
    require(mean > 0.05, @"the scrim blends, it does not paint flat black");
    CGImageRelease(backdrop);
    CGImageRelease(white);

    // Mid grey scales the same way: the scrim is a multiply over the picture,
    // not a fixed offset.
    CGImageRef grey = newFlatImage(0.5, 64);
    backdrop = [DBBackdropCompositor newBackdropFromImage:grey
                                                 viewSize:CGSizeMake(1024, 768)];
    mean = [DBBackdropCompositor meanLuminanceOfImage:backdrop];
    require(near(mean, 0.5 * (1.0 - alpha), 0.02),
            @"a mid grey source darkens by the same fraction");
    CGImageRelease(backdrop);
    CGImageRelease(grey);

    // Black stays black; there is nothing to darken.
    CGImageRef black = newFlatImage(0.0, 64);
    backdrop = [DBBackdropCompositor newBackdropFromImage:black
                                                 viewSize:CGSizeMake(1024, 768)];
    require(near([DBBackdropCompositor meanLuminanceOfImage:backdrop], 0, 0.01),
            @"a black source stays black");
    CGImageRelease(backdrop);
    CGImageRelease(black);

    // A square source aspect-filled into a landscape panel keeps the middle
    // band: half white and half black cropped to the centre still averages the
    // darkened half-grey, and a mapping that dropped the picture would not.
    CGImageRef split = newSplitImage(64);
    backdrop = [DBBackdropCompositor newBackdropFromImage:split
                                                 viewSize:CGSizeMake(1024, 768)];
    mean = [DBBackdropCompositor meanLuminanceOfImage:backdrop];
    require(near(mean, 0.5 * (1.0 - alpha), 0.03),
            @"an aspect-filled split source keeps both halves in view");
    CGImageRelease(backdrop);
    CGImageRelease(split);

    // --- Vertical orientation. ---
    // The draw moved from UIKit to CoreGraphics, whose bitmap contexts have the
    // opposite origin. Getting this wrong renders the wallpaper upside down, so
    // a source whose top half is white must come back with its top half bright.
    // A square view is used so aspect fill crops nothing.
    split = newTopWhiteBottomBlackFixture();
    backdrop = [DBBackdropCompositor newBackdropFromImage:split
                                                 viewSize:CGSizeMake(256, 256)];
    require(backdrop != NULL, @"a square view composites");
    size_t w = CGImageGetWidth(backdrop);
    size_t h = CGImageGetHeight(backdrop);
    // CGImageCreateWithImageInRect takes image coordinates, row 0 at the top,
    // which is the row UIImage puts at the top of the screen.
    CGImageRef top = CGImageCreateWithImageInRect(
        backdrop, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h / 2));
    CGImageRef bottom = CGImageCreateWithImageInRect(
        backdrop, CGRectMake(0, (CGFloat)h / 2, (CGFloat)w, (CGFloat)h / 2));
    CGFloat topMean = [DBBackdropCompositor meanLuminanceOfImage:top];
    CGFloat bottomMean = [DBBackdropCompositor meanLuminanceOfImage:bottom];
    require(near(topMean, 1.0 - alpha, 0.03),
            [NSString stringWithFormat:@"the white top half stays on top (%.3f)", topMean]);
    require(near(bottomMean, 0, 0.03),
            [NSString stringWithFormat:@"the black bottom half stays below (%.3f)", bottomMean]);
    require(topMean > bottomMean, @"the picture is not composited upside down");
    CGImageRelease(top);
    CGImageRelease(bottom);
    CGImageRelease(backdrop);
    CGImageRelease(split);

    // glReadPixels returns bottom-to-top rows. The GPU path reverses those
    // rows before DBImageFromPixels assigns UIImageOrientationUp, so its
    // output matches the CPU blur and the upright backdrop.
    unsigned char gpuReadback[] = {
      0, 0, 0, 255, 0, 0, 0, 255,
      255, 255, 255, 255, 255, 255, 255, 255,
    };
    DBFlipPixelRows(gpuReadback, 2, 2);
    require(gpuReadback[0] == 255 && gpuReadback[4] == 255,
            @"GPU readback restores the white top row before UIImage creation");
    require(gpuReadback[8] == 0 && gpuReadback[12] == 0,
            @"GPU readback restores the black bottom row before UIImage creation");

    // --- The bounded bitmap. ---
    CGSize prepared = [DBBackdropCompositor preparedSizeForViewSize:CGSizeMake(1024, 768)];
    require(near(prepared.width, 1024, 0.5) && near(prepared.height, 768, 0.5),
            @"an iPad 1 prepares its backdrop at native resolution");
    require(near(prepared.width / prepared.height, 1024.0 / 768.0, 0.01),
            @"the prepared bitmap keeps the panel's aspect ratio");
    CGImageRef sized = [DBBackdropCompositor newBackdropFromImage:(white = newFlatImage(1.0, 64))
                                                         viewSize:CGSizeMake(1024, 768)];
    require(CGImageGetWidth(sized) == 1024 && CGImageGetHeight(sized) == 768,
            @"the composited bitmap keeps the panel's native resolution");
    CGImageRelease(sized);
    CGImageRelease(white);

    // A panel already within the bound is prepared at its own size.
    prepared = [DBBackdropCompositor preparedSizeForViewSize:CGSizeMake(480, 320)];
    require(near(prepared.width, 480, 0.5) && near(prepared.height, 320, 0.5),
            @"a small panel is not scaled up");
    require([DBBackdropCompositor maximumLongSide] == 1024,
            @"the bound preserves an iPad 1 display");

    // Degenerate inputs return nothing rather than a bitmap of nothing.
    require([DBBackdropCompositor newBackdropFromImage:NULL
                                              viewSize:CGSizeMake(1024, 768)] == NULL,
            @"no source, no backdrop");
    CGImageRef any = newFlatImage(1.0, 8);
    require([DBBackdropCompositor newBackdropFromImage:any viewSize:CGSizeZero] == NULL,
            @"an empty view has no backdrop");
    CGImageRelease(any);
    require([DBBackdropCompositor meanLuminanceOfImage:NULL] == 0,
            @"a missing image measures zero");

    // --- The configured overlay: on, off, and something other than black. ---
    white = newFlatImage(1.0, 64);
    CGSize view = CGSizeMake(1024, 768);

    // Enabled with an explicit colour and opacity.
    NSDictionary *half = @{@"enabled" : @YES, @"color" : @"#000000", @"opacity" : @50};
    backdrop = [DBBackdropCompositor newBackdropFromImage:white viewSize:view overlay:half];
    require(near([DBBackdropCompositor meanLuminanceOfImage:backdrop], 0.5, 0.02),
            @"a 50 per cent black overlay halves a white picture");
    CGImageRelease(backdrop);

    // Disabled: the picture is untouched, which is not the same as opacity 0
    // being ignored.
    NSDictionary *off = @{@"enabled" : @NO, @"color" : @"#000000", @"opacity" : @62};
    backdrop = [DBBackdropCompositor newBackdropFromImage:white viewSize:view overlay:off];
    require(near([DBBackdropCompositor meanLuminanceOfImage:backdrop], 1.0, 0.02),
            @"a disabled overlay leaves the picture alone");
    CGImageRelease(backdrop);

    // A coloured overlay tints rather than only darkening: pure white under a
    // fully opaque red must measure red's own luminance, 0.2126.
    NSDictionary *red = @{@"enabled" : @YES, @"color" : @"#FF0000", @"opacity" : @100};
    backdrop = [DBBackdropCompositor newBackdropFromImage:white viewSize:view overlay:red];
    require(near([DBBackdropCompositor meanLuminanceOfImage:backdrop], 0.2126, 0.02),
            @"a fully opaque red overlay leaves red, not grey");
    CGImageRelease(backdrop);

    // Absent keys fall back to today's behaviour rather than to nothing.
    backdrop = [DBBackdropCompositor newBackdropFromImage:white viewSize:view overlay:@{}];
    require(near([DBBackdropCompositor meanLuminanceOfImage:backdrop], 1.0 - alpha, 0.02),
            @"an empty overlay dictionary is the 62 per cent default");
    CGImageRelease(backdrop);
    // Out-of-range opacity is clamped, not wrapped.
    backdrop = [DBBackdropCompositor newBackdropFromImage:white viewSize:view
                                                  overlay:@{@"opacity" : @999}];
    require(near([DBBackdropCompositor meanLuminanceOfImage:backdrop], 0, 0.02),
            @"an opacity above 100 clamps to fully opaque");
    CGImageRelease(backdrop);
    backdrop = [DBBackdropCompositor newBackdropFromImage:white viewSize:view
                                                  overlay:@{@"opacity" : @0}];
    require(near([DBBackdropCompositor meanLuminanceOfImage:backdrop], 1.0, 0.02),
            @"a zero opacity draws no overlay at all");
    CGImageRelease(backdrop);
    CGImageRelease(white);

    // --- Where the overlay is read from. ---
    NSDictionary *defaults = [DBUiTheme backdropOverlayForConfig:@{} deviceId:@"n1"
                                                         display:@{}];
    require([[defaults objectForKey:@"enabled"] boolValue] &&
            [[defaults objectForKey:@"color"] isEqualToString:@"#000000"] &&
            near((CGFloat)[[defaults objectForKey:@"opacity"] doubleValue], 62, 0.001),
            @"nothing configured means black at 62 per cent");

    // Core's resolved answer in status.display wins.
    NSDictionary *fromStatus = [DBUiTheme backdropOverlayForConfig:@{} deviceId:@"n1"
        display:@{@"theme" : @{@"backdrop" : @{@"enabled" : @YES, @"color" : @"#101418",
                                               @"opacity" : @40, @"source" : @"cluster"}}}];
    require([[fromStatus objectForKey:@"color"] isEqualToString:@"#101418"] &&
            near((CGFloat)[[fromStatus objectForKey:@"opacity"] doubleValue], 40, 0.001),
            @"status.display.theme.backdrop is read");

    // Then this device's own setting, then the cluster's.
    NSDictionary *config = @{
      @"display" : @{@"theme" : @{@"backdrop" : @{@"opacity" : @30}}},
      @"devices" : @{@"n1" : @{@"local" : @{@"theme" : @{@"backdrop" : @{@"opacity" : @80}}}}},
    };
    require(near((CGFloat)[[[DBUiTheme backdropOverlayForConfig:config deviceId:@"n1"
                                                        display:@{}]
                              objectForKey:@"opacity"] doubleValue], 80, 0.001),
            @"the device's own backdrop outranks the cluster's");
    require(near((CGFloat)[[[DBUiTheme backdropOverlayForConfig:config deviceId:@"other"
                                                        display:@{}]
                              objectForKey:@"opacity"] doubleValue], 30, 0.001),
            @"a device with no setting of its own takes the cluster's");
    require(![[[DBUiTheme backdropOverlayForConfig:@{} deviceId:@"n1"
                   display:@{@"theme" : @{@"backdrop" : @{@"enabled" : @NO}}}]
                  objectForKey:@"enabled"] boolValue],
            @"an administrator can turn the overlay off");

    // --- Cards follow the appearance, never the wallpaper. ---
    require([[DBUiTheme plateHexForMode:@"dark"] isEqualToString:@"#1A1E24"],
            @"a dark cluster gets a dark plate");
    require(![[DBUiTheme plateHexForMode:@"light"] isEqualToString:
                  [DBUiTheme plateHexForMode:@"dark"]],
            @"a light cluster gets a different plate");

    puts("PASS: DBBackdropCompositor darkens the theme picture by 62 per cent");
  }
  return 0;
}
