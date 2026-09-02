#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

#import "DBBackdropCompositor.h"

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
    split = newSplitImage(64);
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

    // --- The bounded bitmap. ---
    CGSize prepared = [DBBackdropCompositor preparedSizeForViewSize:CGSizeMake(1024, 768)];
    require(near(prepared.width, 512, 0.5) && near(prepared.height, 384, 0.5),
            @"a 1024x768 panel prepares a 512x384 bitmap");
    require(near(prepared.width / prepared.height, 1024.0 / 768.0, 0.01),
            @"the prepared bitmap keeps the panel's aspect ratio");
    CGImageRef sized = [DBBackdropCompositor newBackdropFromImage:(white = newFlatImage(1.0, 64))
                                                         viewSize:CGSizeMake(1024, 768)];
    require(CGImageGetWidth(sized) == 512 && CGImageGetHeight(sized) == 384,
            @"the composited bitmap is the prepared size, not the panel size");
    CGImageRelease(sized);
    CGImageRelease(white);

    // A panel already within the bound is prepared at its own size.
    prepared = [DBBackdropCompositor preparedSizeForViewSize:CGSizeMake(480, 320)];
    require(near(prepared.width, 480, 0.5) && near(prepared.height, 320, 0.5),
            @"a small panel is not scaled up");
    require([DBBackdropCompositor maximumLongSide] == 512, @"the bound is 512 points");

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

    puts("PASS: DBBackdropCompositor darkens the theme picture by 62 per cent");
  }
  return 0;
}
