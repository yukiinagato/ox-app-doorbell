#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Returns the height the whole text needs when wrapped at `width` in a font of `size`.
typedef CGFloat (^DBTextMeasure)(CGFloat size, CGFloat width);

// The largest whole point size in [floorSize, ceilingSize] at which the text fits the box in
// width and height, by binary search; floorSize when even that does not fit (the caller
// scrolls). Pure: the measurement is injected, so one search costs O(log n) measurements.
CGFloat DBTextFitSize(CGSize box, CGFloat floorSize, CGFloat ceilingSize, DBTextMeasure measure);
