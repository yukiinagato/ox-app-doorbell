#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

// The pixel work behind the dashboard's theme picture, in CoreGraphics only so
// the result can be measured on the host rather than judged from a photograph
// of a panel.
//
// One aspect-filled copy of the wallpaper, bounded on its long side, with a
// black scrim composited over it. The scrim is what makes text and cards read
// over a bright picture, and "the darkening looks wrong" is a claim about a
// mean luminance, so the mean luminance is what the tests assert.
@interface DBBackdropCompositor : NSObject

// Fraction of black composited over the picture, 0..1.
+ (CGFloat)darkeningAlpha;
// The prepared bitmap never exceeds this on its long side.
+ (CGFloat)maximumLongSide;
// The view's size reduced to fit maximumLongSide, keeping its aspect ratio so
// the view's aspect fill maps the result back one to one.
+ (CGSize)preparedSizeForViewSize:(CGSize)size;
// Where an image of contentSize lands when aspect-filled into viewSize. The
// rect is centred, so it reads the same in flipped and unflipped spaces.
+ (CGRect)aspectFillRectForContentSize:(CGSize)contentSize viewSize:(CGSize)viewSize;

// The prepared, darkened backdrop for a view of viewSize. Returns NULL when
// source is NULL or viewSize is empty. The caller owns the result.
+ (CGImageRef)newBackdropFromImage:(CGImageRef)source
                          viewSize:(CGSize)viewSize CF_RETURNS_RETAINED;

// Mean relative luminance over every pixel, 0..1. This is the measurement the
// darkening is judged by.
+ (CGFloat)meanLuminanceOfImage:(CGImageRef)image;

@end
