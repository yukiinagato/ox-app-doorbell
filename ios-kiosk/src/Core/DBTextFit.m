#import "DBTextFit.h"

CGFloat DBTextFitSize(CGSize box, CGFloat floorSize, CGFloat ceilingSize, DBTextMeasure measure) {
  NSInteger low = (NSInteger)floor(floorSize);
  NSInteger high = (NSInteger)floor(MIN(ceilingSize, box.height));
  if (high < low || box.width <= 0 || box.height <= 0) return (CGFloat)low;
  if (measure((CGFloat)low, box.width) > box.height) return (CGFloat)low;
  while (low < high) {
    NSInteger middle = (low + high + 1) / 2;
    if (measure((CGFloat)middle, box.width) <= box.height) low = middle;
    else high = middle - 1;
  }
  return (CGFloat)low;
}
